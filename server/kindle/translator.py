"""Japanese to English translation using Ollama."""

import logging
import re

import requests

from .config import OLLAMA_BASE_URL, TRANSLATE_MODEL, TRANSLATE_OPTIONS, TRANSLATE_THINK, REVIEW_ENABLED

log = logging.getLogger(__name__)

LANG_MAP = {
    "en": ("en", "English"),
    "pt-br": ("pt", "Brazilian Portuguese"),
}


def translate(japanese_text: str, target_lang: str = "en") -> str:
    """Translate Japanese text to the target language using Ollama."""
    _, lang_name = LANG_MAP.get(target_lang, ("en", "English"))
    prompt = (
        f"Translate this Japanese manga dialogue to natural, fluent {lang_name}.\n"
        "Guidelines:\n"
        "- Convey the MEANING and TONE, not a word-for-word literal translation.\n"
        f"- Use natural spoken {lang_name} that fits a manga speech bubble.\n"
        "- Keep Japanese names exactly as-is (e.g. Katsuki, Deku, Sensei).\n"
        "- Preserve Japanese nicknames and honorific-based names (e.g. Kacchan, "
        "Onee-chan) — do NOT translate or replace them.\n"
        "- Keep it concise — speech bubbles have limited space.\n"
        f"Output ONLY the {lang_name} translation, nothing else.\n"
        f"\nJapanese: {japanese_text}"
    )

    payload = {
        "model": TRANSLATE_MODEL,
        "messages": [{"role": "user", "content": prompt}],
        "stream": False,
        "options": TRANSLATE_OPTIONS,
    }
    if TRANSLATE_THINK is not None:
        payload["think"] = TRANSLATE_THINK

    try:
        resp = requests.post(
            f"{OLLAMA_BASE_URL}/api/chat",
            json=payload,
            timeout=120,
        )
        resp.raise_for_status()
        raw = resp.json().get("message", {}).get("content", "")
        result = _clean_response(raw)
        if result:
            return result
    except Exception as e:
        log.warning("Ollama translation failed: %s, trying fallback", e)

    return _fallback_translate(japanese_text, target_lang)


def review_translations(
    pairs: list[tuple[str, str]],
    source_lang: str = "Japanese",
    target_lang: str = "en",
) -> dict[int, str]:
    """Review draft translations in context and return corrections.

    Takes a list of (original_text, draft_translation) pairs representing
    all bubbles on a page in reading order.  Returns a dict mapping
    bubble index -> corrected translation for only the lines that changed.
    An empty dict means all drafts were acceptable.
    """
    if not REVIEW_ENABLED or len(pairs) < 2:
        return {}

    _, lang_name = LANG_MAP.get(target_lang, ("en", "English"))

    lines = []
    for i, (orig, draft) in enumerate(pairs, 1):
        lines.append(f"[{i}] {orig} -> {draft}")
    numbered = "\n".join(lines)

    prompt = (
        f"You are reviewing {source_lang}-to-{lang_name} manga translations.\n"
        f"Below are all speech bubbles on a single page in reading order, "
        f"each showing the {source_lang} original and its draft {lang_name} "
        f"translation.\n\n"
        f"{numbered}\n\n"
        "Check for:\n"
        "- Pronouns that contradict the conversation flow\n"
        "- Inconsistent tone or register between lines in the same dialogue\n"
        "- Ambiguous references that the surrounding lines clarify\n"
        "- Names or terms translated inconsistently across bubbles\n\n"
        "For each line that needs correction, output ONLY:\n"
        "[N] corrected translation\n\n"
        "If all translations are acceptable, output ONLY the word: OK"
    )

    payload = {
        "model": TRANSLATE_MODEL,
        "messages": [{"role": "user", "content": prompt}],
        "stream": False,
        "options": TRANSLATE_OPTIONS,
    }
    if TRANSLATE_THINK is not None:
        payload["think"] = TRANSLATE_THINK

    try:
        resp = requests.post(
            f"{OLLAMA_BASE_URL}/api/chat",
            json=payload,
            timeout=120,
        )
        resp.raise_for_status()
        raw = resp.json().get("message", {}).get("content", "")
        return _parse_review_response(raw, len(pairs))
    except Exception as e:
        log.warning("Review pass failed (keeping drafts): %s", e)
        return {}


def _parse_review_response(raw: str, count: int) -> dict[int, str]:
    """Parse the reviewer output into {0-based index: corrected text}."""
    cleaned = _clean_response(raw)
    if not cleaned or cleaned.upper() == "OK":
        return {}

    corrections: dict[int, str] = {}
    for match in re.finditer(r"\[(\d+)\]\s*(.+)", cleaned):
        idx = int(match.group(1)) - 1  # convert to 0-based
        text = match.group(2).strip()
        if 0 <= idx < count and text:
            corrections[idx] = text
    return corrections


def _clean_response(text: str) -> str:
    """Strip thinking tags and clean up translation output."""
    text = re.sub(r"<think>.*?</think>", "", text, flags=re.DOTALL)
    text = re.sub(r"<[^>]+>", "", text)
    # Remove quotes the model sometimes wraps around translations
    text = text.strip().strip('"').strip("'")
    return text.strip()


def _fallback_translate(japanese_text: str, target_lang: str = "en") -> str:
    """Fallback using deep-translator (Google Translate)."""
    try:
        from deep_translator import GoogleTranslator
        gt_code, _ = LANG_MAP.get(target_lang, ("en", "English"))
        result = GoogleTranslator(source="ja", target=gt_code).translate(japanese_text)
        return result or japanese_text
    except Exception as e:
        log.error("Fallback translation also failed: %s", e)
        return japanese_text
