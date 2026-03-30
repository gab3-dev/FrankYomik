"""Generate scene descriptions from page images using a vision-language model."""

import base64
import io
import logging
import re

import requests
from PIL import Image

from .config import (
    OLLAMA_BASE_URL,
    SCENE_DESCRIPTION_ENABLED,
    SCENE_MODEL,
    TRANSLATE_OPTIONS,
    TRANSLATE_THINK,
)

log = logging.getLogger(__name__)

_SCENE_PROMPT = (
    "You are analysing a manga/comic page for translation context.\n"
    "Describe the scene briefly:\n"
    "- How many characters are visible and their apparent gender/age\n"
    "- What is happening (action, conversation, emotion)\n"
    "- The setting (indoor, outdoor, school, etc.)\n"
    "- If speech bubbles are visible, try to identify which character "
    "is speaking each one (e.g. 'top-left bubble: the girl', "
    "'bottom bubble: the boy')\n\n"
    "Keep it under 100 words. Be factual, not interpretive."
)


def describe_scene(page_image: Image.Image,
                    bbox: tuple[int, int, int, int] | None = None) -> str:
    """Send a page image (or cropped region) to the VL model for a scene description.

    When *bbox* is provided, the image is cropped around that region with
    generous padding (2x the bubble dimensions) so the VL model sees the
    speaker and surrounding panel context rather than the entire page.

    Returns an empty string if scene description is disabled, the model
    does not support vision, or the call fails.
    """
    if not SCENE_DESCRIPTION_ENABLED:
        return ""

    try:
        img = _crop_around_bbox(page_image, bbox) if bbox else page_image
        img_b64 = _encode_image(img)

        payload = {
            "model": SCENE_MODEL,
            "messages": [
                {
                    "role": "user",
                    "content": _SCENE_PROMPT,
                    "images": [img_b64],
                }
            ],
            "stream": False,
            "options": {
                "temperature": TRANSLATE_OPTIONS.get("temperature", 0.3),
                "num_predict": 256,
            },
        }
        if TRANSLATE_THINK is not None:
            payload["think"] = TRANSLATE_THINK

        resp = requests.post(
            f"{OLLAMA_BASE_URL}/api/chat",
            json=payload,
            timeout=120,
        )
        resp.raise_for_status()
        raw = resp.json().get("message", {}).get("content", "")
        result = _clean_description(raw)
        if result:
            log.info("Scene description (%d chars): %s", len(result), result[:120])
        return result

    except Exception as e:
        log.warning("Scene description failed (non-fatal): %s", e)
        return ""


def _crop_around_bbox(img: Image.Image,
                      bbox: tuple[int, int, int, int]) -> Image.Image:
    """Crop around a bbox with 2x padding on each side for panel context."""
    x1, y1, x2, y2 = bbox
    bw, bh = x2 - x1, y2 - y1
    pad_x = bw * 2
    pad_y = bh * 2
    w, h = img.size
    crop_box = (
        max(0, x1 - pad_x),
        max(0, y1 - pad_y),
        min(w, x2 + pad_x),
        min(h, y2 + pad_y),
    )
    return img.crop(crop_box)


def _encode_image(img: Image.Image) -> str:
    """Encode a PIL image to base64 JPEG for the Ollama API."""
    buf = io.BytesIO()
    rgb = img.convert("RGB") if img.mode != "RGB" else img
    # Resize large images to limit token cost while keeping enough detail
    max_side = 1024
    if max(rgb.size) > max_side:
        rgb.thumbnail((max_side, max_side), Image.LANCZOS)
    rgb.save(buf, format="JPEG", quality=85)
    return base64.b64encode(buf.getvalue()).decode("ascii")


def _clean_description(text: str) -> str:
    """Strip thinking tags and clean up description output."""
    text = re.sub(r"<think>.*?</think>", "", text, flags=re.DOTALL)
    text = re.sub(r"<[^>]+>", "", text)
    return text.strip()
