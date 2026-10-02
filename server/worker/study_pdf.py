"""Extract positioned Japanese text from a study PDF page.

Text-backed PDFs use PDFium's native character boxes. Pages without an
extractable Japanese text layer are rendered and passed through EasyOCR. Sparse
or low-confidence EasyOCR results fall back to manga bubble detection and
Manga-OCR. Character boxes are estimated and marked as approximate so clients
can distinguish them from native PDF geometry.
"""

from __future__ import annotations

import logging
import math
import os
import threading
import time
from typing import Any, Callable

log = logging.getLogger(__name__)

MAX_PDF_PAGES = 500
MAX_NATIVE_CHARS_PER_PAGE = 50_000
MAX_OCR_GLYPHS_PER_PAGE = 50_000
MAX_RENDER_PIXELS = 32_000_000
DEFAULT_RENDER_SCALE = 2.5
_japanese_reader = None
_japanese_tagger = None
_tagger_lock = threading.Lock()


def _normalized_rect(
    left: float,
    bottom: float,
    right: float,
    top: float,
    page_width: float,
    page_height: float,
) -> list[float]:
    """Return [left, top, right, bottom] fractions, origin at top-left."""
    if page_width <= 0 or page_height <= 0:
        return [0.0, 0.0, 0.0, 0.0]
    return [
        max(0.0, min(1.0, left / page_width)),
        max(0.0, min(1.0, 1.0 - top / page_height)),
        max(0.0, min(1.0, right / page_width)),
        max(0.0, min(1.0, 1.0 - bottom / page_height)),
    ]


def _has_japanese(text: str) -> bool:
    return any(_is_japanese_character(character) for character in text)


def _is_japanese_character(character: str) -> bool:
    codepoint = ord(character)
    return (
        0x3040 <= codepoint <= 0x30FF
        or 0x3400 <= codepoint <= 0x4DBF
        or 0x4E00 <= codepoint <= 0x9FFF
        or 0xF900 <= codepoint <= 0xFAFF
        or 0x20000 <= codepoint <= 0x323AF
    )


def _utf16_length(text: str) -> int:
    """Dart/Flutter string indexes use UTF-16 code units."""
    return len(text.encode("utf-16-le")) // 2


def _native_layout(page: Any, page_number: int) -> dict[str, Any]:
    width, height = page.get_size()
    text_page = page.get_textpage()
    try:
        char_count = text_page.count_chars()
        if char_count > MAX_NATIVE_CHARS_PER_PAGE:
            raise ValueError(
                f"PDF page exceeds the {MAX_NATIVE_CHARS_PER_PAGE}-character study limit"
            )
        full_text = text_page.get_text_range()
        one_to_one_text = len(full_text) == char_count
        glyphs: list[dict[str, Any]] = []
        text_parts: list[str] = []
        text_index = 0

        for pdf_index in range(char_count):
            # Avoid one native PDFium call per glyph for normal BMP text pages.
            # Fall back to PDFium's indexed range API when supplementary
            # characters make Python codepoint indices differ from PDFium's.
            character = (
                full_text[pdf_index]
                if one_to_one_text
                else text_page.get_text_range(pdf_index, 1)
            )
            if not character:
                continue
            box = text_page.get_charbox(pdf_index)
            if box is None:
                continue
            left, bottom, right, top = box
            # PDFium text coordinates use a bottom-left origin. The API contract
            # uses normalized top-left coordinates, matching image/OCR results.
            glyphs.append({
                "index": text_index,
                "text": character,
                "bbox": _normalized_rect(left, bottom, right, top, width, height),
                "approximate": False,
                "confidence": 1.0,
            })
            text_parts.append(character)
            text_index += _utf16_length(character)
    finally:
        text_page.close()

    text = "".join(text_parts)
    return {
        "schema_version": 1,
        "page_number": page_number,
        "width": width,
        "height": height,
        "source": "pdf_text",
        "text": text,
        "glyphs": glyphs,
    }


def _get_japanese_reader():
    global _japanese_reader
    if _japanese_reader is None:
        import easyocr
        from webtoon.config import EASYOCR_GPU

        log.info("Loading EasyOCR Japanese reader (gpu=%s)...", EASYOCR_GPU)
        _japanese_reader = easyocr.Reader(["ja"], gpu=EASYOCR_GPU)
    return _japanese_reader


def _tokenize_text(text: str, glyphs: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Add UniDic lemmas/readings while leaving definitions on the client."""
    global _japanese_tagger
    try:
        import fugashi

        if _japanese_tagger is None:
            with _tagger_lock:
                if _japanese_tagger is None:
                    _japanese_tagger = fugashi.Tagger()
        with _tagger_lock:
            parsed = list(_japanese_tagger(text))
    except Exception:
        # OCR/text layouts remain useful without morphology; the client can
        # still perform exact-form and character lookup from the local DB.
        log.warning("Could not tokenize study page text", exc_info=True)
        return []

    tokens: list[dict[str, Any]] = []
    cursor = 0
    for token in parsed:
        surface = str(token.surface)
        if not surface or not _has_japanese(surface):
            continue
        start = text.find(surface, cursor)
        if start < 0:
            continue
        end = start + len(surface)
        cursor = end
        start_units = _utf16_length(text[:start])
        end_units = _utf16_length(text[:end])
        covered = [
            glyph for glyph in glyphs
            if start_units <= int(glyph["index"]) < end_units
        ]
        bbox = None
        if covered:
            boxes = [glyph["bbox"] for glyph in covered]
            bbox = [
                min(box[0] for box in boxes),
                min(box[1] for box in boxes),
                max(box[2] for box in boxes),
                max(box[3] for box in boxes),
            ]
        feature = token.feature
        lemma = str(getattr(feature, "lemma", "") or surface)
        if lemma == "*":
            lemma = surface
        reading = str(getattr(feature, "kana", "") or "")
        parts_of_speech = [
            str(value)
            for value in (getattr(feature, f"pos{index}", "") for index in range(1, 5))
            if value and value != "*"
        ]
        tokens.append({
            "surface": surface,
            "lemma": lemma,
            "reading": reading,
            "part_of_speech": parts_of_speech,
            "start": start_units,
            "end": end_units,
            "bbox": bbox,
        })
    return tokens


def _ocr_layout(
    image: Any,
    page_number: int,
    page_width: float,
    page_height: float,
    reader: Any,
) -> dict[str, Any]:
    import numpy as np

    image_width, image_height = image.size
    detections = reader.readtext(
        np.asarray(image.convert("RGB")),
        detail=1,
        paragraph=False,
        rotation_info=[90, 270],
    )
    blocks: list[dict[str, Any]] = []
    glyphs: list[dict[str, Any]] = []
    text_parts: list[str] = []
    text_index = 0

    for polygon, raw_text, raw_confidence in detections:
        block_text = str(raw_text).strip()
        if not block_text:
            continue
        if text_index + _utf16_length(block_text) > MAX_OCR_GLYPHS_PER_PAGE:
            raise ValueError(
                f"OCR output exceeds the {MAX_OCR_GLYPHS_PER_PAGE}-glyph page limit"
            )
        if text_parts:
            # `text` joins OCR regions with one newline, so the following
            # block's glyph indexes must include that separator.
            text_index += 1
        points = [(float(point[0]), float(point[1])) for point in polygon]
        x0 = max(0.0, min(x for x, _ in points))
        x1 = min(float(image_width), max(x for x, _ in points))
        y0 = max(0.0, min(y for _, y in points))
        y1 = min(float(image_height), max(y for _, y in points))
        if x1 <= x0 or y1 <= y0:
            continue

        vertical = (y1 - y0) > (x1 - x0) * 1.35
        normalized_block = _normalized_rect(
            x0 * page_width / image_width,
            page_height - y1 * page_height / image_height,
            x1 * page_width / image_width,
            page_height - y0 * page_height / image_height,
            page_width,
            page_height,
        )
        confidence = max(0.0, min(1.0, float(raw_confidence)))
        characters = list(block_text)
        count = len(characters)
        glyph_index = text_index

        for character_index, character in enumerate(characters):
            if vertical:
                char_y0 = y0 + (y1 - y0) * character_index / count
                char_y1 = y0 + (y1 - y0) * (character_index + 1) / count
                char_x0, char_x1 = x0, x1
            else:
                char_x0 = x0 + (x1 - x0) * character_index / count
                char_x1 = x0 + (x1 - x0) * (character_index + 1) / count
                char_y0, char_y1 = y0, y1
            glyph = {
                "index": glyph_index,
                "text": character,
                "bbox": _normalized_rect(
                    char_x0 * page_width / image_width,
                    page_height - char_y1 * page_height / image_height,
                    char_x1 * page_width / image_width,
                    page_height - char_y0 * page_height / image_height,
                    page_width,
                    page_height,
                ),
                "approximate": True,
                "confidence": confidence,
            }
            glyphs.append(glyph)
            glyph_index += _utf16_length(character)

        blocks.append({
            "text": block_text,
            "bbox": normalized_block,
            "direction": "vertical-rtl" if vertical else "horizontal",
            "confidence": confidence,
            "approximate_glyph_boxes": True,
            "glyph_start": text_index,
            "glyph_count": count,
        })
        text_parts.append(block_text)
        text_index += sum(_utf16_length(character) for character in characters)

    return {
        "schema_version": 1,
        "page_number": page_number,
        "width": page_width,
        "height": page_height,
        "source": "ocr",
        "text": "\n".join(text_parts),
        "blocks": blocks,
        "glyphs": glyphs,
    }


def _ocr_needs_manga_fallback(layout: dict[str, Any]) -> bool:
    """Identify scan OCR that is too sparse to support reliable lookup."""
    japanese_characters = sum(
        1 for character in layout["text"] if _is_japanese_character(character)
    )
    confidences = [
        float(block["confidence"])
        for block in layout.get("blocks", [])
        if "confidence" in block
    ]
    mean_confidence = sum(confidences) / len(confidences) if confidences else 0.0
    return japanese_characters < 2 or (
        japanese_characters < 6 and mean_confidence < 0.85
    )


def _manga_ocr_layout(
    image: Any,
    page_number: int,
    page_width: float,
    page_height: float,
    region_detector: Callable[[Any], list[dict[str, Any]]],
    region_ocr: Callable[[Any, tuple[int, int, int, int]], str],
) -> dict[str, Any]:
    """Read detected manga text regions and estimate tap-target glyph boxes."""
    import numpy as np

    image_width, image_height = image.size
    regions = region_detector(np.asarray(image.convert("RGB"))[:, :, ::-1])
    blocks: list[dict[str, Any]] = []
    glyphs: list[dict[str, Any]] = []
    text_parts: list[str] = []
    text_index = 0

    for region in regions:
        raw_bbox = region.get("bbox")
        if not isinstance(raw_bbox, (list, tuple)) or len(raw_bbox) != 4:
            continue
        x0 = max(0, min(image_width, int(raw_bbox[0])))
        y0 = max(0, min(image_height, int(raw_bbox[1])))
        x1 = max(0, min(image_width, int(raw_bbox[2])))
        y1 = max(0, min(image_height, int(raw_bbox[3])))
        if x1 <= x0 or y1 <= y0:
            continue

        block_text = region_ocr(image, (x0, y0, x1, y1)).strip()
        if not _has_japanese(block_text):
            continue
        if text_index + _utf16_length(block_text) > MAX_OCR_GLYPHS_PER_PAGE:
            raise ValueError(
                f"OCR output exceeds the {MAX_OCR_GLYPHS_PER_PAGE}-glyph page limit"
            )
        if text_parts:
            text_index += 1

        vertical = (y1 - y0) > (x1 - x0) * 1.2
        characters = list(block_text)
        count = len(characters)
        glyph_index = text_index
        # Manga-OCR has no character boxes. For vertical dialogue, distribute
        # characters across a right-to-left grid with roughly square cells.
        columns = max(1, round(math.sqrt(count * (x1 - x0) / (y1 - y0)))) if vertical else count
        rows = math.ceil(count / columns) if vertical else 1

        for character_index, character in enumerate(characters):
            if vertical:
                column = character_index // rows
                row = character_index % rows
                char_x1 = x1 - (x1 - x0) * column / columns
                char_x0 = x1 - (x1 - x0) * (column + 1) / columns
                char_y0 = y0 + (y1 - y0) * row / rows
                char_y1 = y0 + (y1 - y0) * (row + 1) / rows
            else:
                char_x0 = x0 + (x1 - x0) * character_index / count
                char_x1 = x0 + (x1 - x0) * (character_index + 1) / count
                char_y0, char_y1 = y0, y1
            glyphs.append({
                "index": glyph_index,
                "text": character,
                "bbox": _normalized_rect(
                    char_x0 * page_width / image_width,
                    page_height - char_y1 * page_height / image_height,
                    char_x1 * page_width / image_width,
                    page_height - char_y0 * page_height / image_height,
                    page_width,
                    page_height,
                ),
                "approximate": True,
                "confidence": max(0.0, min(1.0, float(region.get("score", 0.0)))),
            })
            glyph_index += _utf16_length(character)

        blocks.append({
            "text": block_text,
            "bbox": _normalized_rect(
                x0 * page_width / image_width,
                page_height - y1 * page_height / image_height,
                x1 * page_width / image_width,
                page_height - y0 * page_height / image_height,
                page_width,
                page_height,
            ),
            "direction": "vertical-rtl" if vertical else "horizontal",
            "confidence": max(0.0, min(1.0, float(region.get("score", 0.0)))),
            "approximate_glyph_boxes": True,
            "glyph_start": text_index,
            "glyph_count": count,
        })
        text_parts.append(block_text)
        text_index += sum(_utf16_length(character) for character in characters)

    return {
        "schema_version": 1,
        "page_number": page_number,
        "width": page_width,
        "height": page_height,
        "source": "manga_ocr",
        "text": "\n".join(text_parts),
        "blocks": blocks,
        "glyphs": glyphs,
    }


def inspect_pdf_page(
    pdf_path: str,
    page_number: int,
    *,
    ocr_reader: Any | None = None,
    render_scale: float = DEFAULT_RENDER_SCALE,
    reader_factory: Callable[[], Any] | None = None,
    manga_region_detector: Callable[[Any], list[dict[str, Any]]] | None = None,
    manga_region_ocr: Callable[[Any, tuple[int, int, int, int]], str] | None = None,
) -> dict[str, Any]:
    """Return positioned Japanese text for one 1-based PDF page number."""
    if page_number < 1:
        raise ValueError("page number must be positive")

    import pypdfium2 as pdfium

    document = pdfium.PdfDocument(pdf_path)
    try:
        page_count = len(document)
        if page_count > MAX_PDF_PAGES:
            raise ValueError(f"PDF exceeds the {MAX_PDF_PAGES}-page study limit")
        if page_number > page_count:
            raise ValueError(f"page {page_number} is outside the {page_count}-page PDF")

        page = document[page_number - 1]
        try:
            width, height = page.get_size()
            if (not math.isfinite(width) or not math.isfinite(height) or
                    width <= 0 or height <= 0):
                raise ValueError("PDF page has invalid dimensions")
            native = _native_layout(page, page_number)
            if _has_japanese(native["text"]):
                native["tokens"] = _tokenize_text(native["text"], native["glyphs"])
                return native
            if math.ceil(width * render_scale) * math.ceil(height * render_scale) > MAX_RENDER_PIXELS:
                raise ValueError("PDF page is too large to render for OCR")

            bitmap = page.render(scale=render_scale)
            try:
                image = bitmap.to_pil()
                reader = ocr_reader or (reader_factory or _get_japanese_reader)()
                layout = _ocr_layout(image, page_number, width, height, reader)
                if _ocr_needs_manga_fallback(layout):
                    if manga_region_detector is None or manga_region_ocr is None:
                        from kindle.bubble_detector import detect_bubbles
                        from kindle.ocr import extract_text_from_region

                        manga_region_detector = manga_region_detector or detect_bubbles
                        manga_region_ocr = manga_region_ocr or extract_text_from_region
                    manga_layout = _manga_ocr_layout(
                        image,
                        page_number,
                        width,
                        height,
                        manga_region_detector,
                        manga_region_ocr,
                    )
                    if manga_layout["glyphs"]:
                        log.info(
                            "Using manga OCR fallback for study page %d (%d glyphs)",
                            page_number,
                            len(manga_layout["glyphs"]),
                        )
                        layout = manga_layout
                if _has_japanese(layout["text"]):
                    layout["tokens"] = _tokenize_text(layout["text"], layout["glyphs"])
                return layout
            finally:
                bitmap.close()
        finally:
            page.close()
    finally:
        document.close()


def inspect_pdf_page_count(pdf_path: str) -> int:
    """Read and validate the page count before any per-page jobs are queued."""
    import pypdfium2 as pdfium

    document = pdfium.PdfDocument(pdf_path)
    try:
        count = len(document)
        if count < 1:
            raise ValueError("PDF contains no pages")
        if count > MAX_PDF_PAGES:
            raise ValueError(f"PDF exceeds the {MAX_PDF_PAGES}-page study limit")
        return count
    finally:
        document.close()


def cleanup_stale_uploads(cache_dir: str, *, max_age_seconds: int = 7 * 24 * 60 * 60) -> int:
    """Remove staged originals orphaned by a long worker outage or crash."""
    incoming = os.path.join(cache_dir, "study", "incoming")
    if not os.path.isdir(incoming):
        return 0
    cutoff = time.time() - max_age_seconds
    removed = 0
    for name in os.listdir(incoming):
        if not name.endswith(".pdf"):
            continue
        path = os.path.join(incoming, name)
        try:
            if os.path.isfile(path) and os.path.getmtime(path) < cutoff:
                os.remove(path)
                removed += 1
        except OSError:
            log.warning("Could not clean expired study upload %s", path, exc_info=True)
    return removed
