import os
import sys
import types
from pathlib import Path

import pytest

from worker.study_pdf import (
    _native_layout,
    _normalized_rect,
    _tokenize_text,
    cleanup_stale_uploads,
    inspect_pdf_page,
    inspect_pdf_page_count,
)


PDF_FIXTURE = (
    Path(__file__).parents[2]
    / "fonts"
    / "comicneue-master"
    / "Booklet-ComicNeue.pdf"
)


class FakeReader:
    def readtext(self, image, **kwargs):
        assert kwargs["detail"] == 1
        assert kwargs["paragraph"] is False
        return [
            (
                [[10, 10], [70, 10], [70, 30], [10, 30]],
                "日本",
                0.92,
            )
        ]


class FakeMultiBlockReader:
    def readtext(self, image, **kwargs):
        return [
            ([[10, 10], [70, 10], [70, 30], [10, 30]], "日本", 0.92),
            ([[10, 40], [40, 40], [40, 60], [10, 60]], "語", 0.88),
        ]


class FakeSupplementaryReader:
    def readtext(self, image, **kwargs):
        return [
            ([[10, 10], [70, 10], [70, 30], [10, 30]], "𠮷日", 0.9),
        ]


def test_normalized_rect_converts_pdf_bottom_left_to_image_top_left():
    assert _normalized_rect(10, 20, 30, 80, 100, 100) == pytest.approx(
        [0.1, 0.2, 0.3, 0.8]
    )


def test_pdfium_native_layout_has_one_positioned_glyph_per_character():
    import pypdfium2 as pdfium

    document = pdfium.PdfDocument(str(PDF_FIXTURE))
    try:
        page = document[0]
        try:
            layout = _native_layout(page, 1)
        finally:
            page.close()
    finally:
        document.close()

    assert layout["source"] == "pdf_text"
    assert "Comic Neue" in layout["text"]
    assert len(layout["glyphs"]) == len(layout["text"])
    assert layout["glyphs"][0]["approximate"] is False
    left, top, right, bottom = layout["glyphs"][0]["bbox"]
    assert 0 <= left < right <= 1
    assert 0 <= top < bottom <= 1


def test_scanned_page_returns_ocr_text_and_approximate_glyph_boxes():
    layout = inspect_pdf_page(str(PDF_FIXTURE), 1, ocr_reader=FakeReader())

    assert layout["source"] == "ocr"
    assert layout["text"] == "日本"
    assert layout["blocks"][0]["direction"] == "horizontal"
    assert layout["blocks"][0]["confidence"] == pytest.approx(0.92)
    assert [glyph["text"] for glyph in layout["glyphs"]] == ["日", "本"]
    assert all(glyph["approximate"] for glyph in layout["glyphs"])
    first, second = layout["glyphs"]
    assert first["bbox"][2] == pytest.approx(second["bbox"][0])


def test_ocr_glyph_indexes_account_for_inter_block_newlines():
    layout = inspect_pdf_page(str(PDF_FIXTURE), 1, ocr_reader=FakeMultiBlockReader())

    assert layout["text"] == "日本\n語"
    assert [glyph["index"] for glyph in layout["glyphs"]] == [0, 1, 3]


def test_glyph_indexes_use_flutter_utf16_offsets_for_supplementary_kanji():
    layout = inspect_pdf_page(str(PDF_FIXTURE), 1, ocr_reader=FakeSupplementaryReader())

    assert layout["text"] == "𠮷日"
    assert [glyph["index"] for glyph in layout["glyphs"]] == [0, 2]


def test_sparse_scan_ocr_uses_manga_regions_with_vertical_tap_boxes():
    class SparseReader:
        def readtext(self, image, **kwargs):
            return [([[10, 10], [20, 10], [20, 30], [10, 30]], "糞", 0.2)]

    def detect_regions(image):
        return [{"bbox": (10, 10, 90, 190), "score": 0.8}]

    def read_region(image, bbox):
        assert bbox == (10, 10, 90, 190)
        return "日本語学習中"

    layout = inspect_pdf_page(
        str(PDF_FIXTURE),
        1,
        ocr_reader=SparseReader(),
        manga_region_detector=detect_regions,
        manga_region_ocr=read_region,
    )

    assert layout["source"] == "manga_ocr"
    assert layout["text"] == "日本語学習中"
    assert layout["blocks"][0]["direction"] == "vertical-rtl"
    assert [glyph["text"] for glyph in layout["glyphs"]] == list("日本語学習中")
    assert all(glyph["approximate"] for glyph in layout["glyphs"])
    # A vertical region is divided right-to-left so each character remains tappable.
    assert layout["glyphs"][0]["bbox"][0] > layout["glyphs"][3]["bbox"][0]


def test_token_layout_preserves_lemma_reading_and_page_coordinates(monkeypatch):
    class Feature:
        lemma = "食べる"
        kana = "タベマシタ"
        pos1 = "動詞"
        pos2 = "一般"
        pos3 = "*"
        pos4 = "*"

    class Token:
        surface = "食べました"
        feature = Feature()

    class Tagger:
        def __call__(self, text):
            assert text == "食べました"
            return [Token()]

    fake_fugashi = types.ModuleType("fugashi")
    fake_fugashi.Tagger = Tagger
    monkeypatch.setitem(sys.modules, "fugashi", fake_fugashi)
    import worker.study_pdf as study_pdf

    monkeypatch.setattr(study_pdf, "_japanese_tagger", None)
    glyphs = [
        {"index": index, "bbox": [index / 5, 0.2, (index + 1) / 5, 0.4]}
        for index in range(5)
    ]

    tokens = _tokenize_text("食べました", glyphs)

    assert tokens == [{
        "surface": "食べました",
        "lemma": "食べる",
        "reading": "タベマシタ",
        "part_of_speech": ["動詞", "一般"],
        "start": 0,
        "end": 5,
        "bbox": [0, 0.2, 1, 0.4],
    }]


def test_pdf_page_count_is_bounded():
    assert inspect_pdf_page_count(str(PDF_FIXTURE)) == 9
    with pytest.raises(ValueError, match="positive"):
        inspect_pdf_page(str(PDF_FIXTURE), 0, ocr_reader=FakeReader())


def test_stale_uploaded_pdf_is_removed_but_recent_file_is_kept(tmp_path):
    incoming = tmp_path / "study" / "incoming"
    incoming.mkdir(parents=True)
    expired = incoming / f"{'c' * 32}.pdf"
    recent = incoming / f"{'d' * 32}.pdf"
    expired.write_bytes(b"stale")
    recent.write_bytes(b"current")
    old_time = 1
    os.utime(expired, (old_time, old_time))

    assert cleanup_stale_uploads(str(tmp_path), max_age_seconds=10) == 1
    assert not expired.exists()
    assert recent.exists()
