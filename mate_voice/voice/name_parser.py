"""Conservative spoken-name extraction for voice enrollment.

The parser intentionally accepts only clear self-identification phrases. If a
sentence is ambiguous, returning None is safer than storing the wrong speaker
name.
"""

from __future__ import annotations

import re
import unicodedata
from typing import Optional


_FILLER_WORDS = {
    "şey", "sey", "ya", "yani", "işte", "iste", "aslında", "aslinda",
    "hımm", "hmm", "ıı", "ee", "evet", "tamam", "merhaba", "selam",
    "ben", "benim", "adım", "adim", "ismim", "ismin", "isim",
    "actually", "well", "um", "uh", "yes", "yeah", "ok", "okay",
    "hello", "hi", "my", "name", "is", "i", "am", "im", "i'm",
}
_BOUNDARY_WORDS = {
    "ama", "fakat", "ve", "de", "da", "diye", "olarak", "kaydet",
    "kaydedebilirsin", "çağır", "cagir", "dersin", "diyebilirsin",
    "but", "and", "as", "please", "thanks", "thank", "you", "call",
    "me",
}
_NAME_TOKEN_RE = re.compile(r"^[A-Za-zÇĞİÖŞÜçğıöşü][A-Za-zÇĞİÖŞÜçğıöşü'’-]{1,31}$")
_PREFIX_PATTERNS = (
    r"\b(?:benim\s+)?(?:adım|adim|ismim|isimim)\s+(.+)$",
    r"\bben\s+([A-Za-zÇĞİÖŞÜçğıöşü][A-Za-zÇĞİÖŞÜçğıöşü'’-]*(?:\s+[A-Za-zÇĞİÖŞÜçğıöşü][A-Za-zÇĞİÖŞÜçğıöşü'’-]*)?)\b",
    r"\b(?:bana|beni)\s+(.+?)\s+(?:de|diye\s+çağır|diye\s+cagir|olarak\s+kaydet|kaydet)\b",
    r"\bmy\s+name\s+is\s+(.+)$",
    r"\bi\s*(?:am|'m|m)\s+(.+)$",
    r"\b(?:call\s+me|it's|it\s+is|this\s+is)\s+(.+)$",
)


def _normalize(text: str) -> str:
    text = unicodedata.normalize("NFKC", text or "")
    text = text.replace("’", "'")
    text = re.sub(r"[\"“”‘]", " ", text)
    text = re.sub(r"[.!?,;:]+", " ", text)
    return re.sub(r"\s+", " ", text).strip()


def _clean_candidate(candidate: str) -> list[str]:
    words = []
    for raw in re.split(r"\s+", _normalize(candidate)):
        word = raw.strip("-_ ")
        low = word.casefold()
        if not word:
            continue
        if low in _FILLER_WORDS:
            continue
        if low in _BOUNDARY_WORDS:
            break
        if not _NAME_TOKEN_RE.match(word):
            break
        words.append(word)
        if len(words) == 2:
            break
    return words


def _starts_with_rejected_word(candidate: str) -> bool:
    parts = [p for p in re.split(r"\s+", _normalize(candidate)) if p]
    if not parts:
        return True
    first = parts[0].casefold()
    return first in _FILLER_WORDS or first in _BOUNDARY_WORDS


def _format_name(words: list[str]) -> Optional[str]:
    if not words:
        return None
    if any(w.casefold() in _FILLER_WORDS or w.casefold() in _BOUNDARY_WORDS for w in words):
        return None
    name = " ".join(words).strip()
    return name[:40].title() if name else None


def parse_spoken_name(text: str) -> Optional[str]:
    normalized = _normalize(text)
    if not normalized:
        return None
    for pattern in _PREFIX_PATTERNS:
        match = re.search(pattern, normalized, flags=re.IGNORECASE)
        if not match:
            continue
        original_candidate = normalized[match.start(1):match.end(1)]
        if _starts_with_rejected_word(original_candidate):
            continue
        name = _format_name(_clean_candidate(original_candidate))
        if name:
            return name

    words = _clean_candidate(normalized)
    # Bare-name mode is intentionally strict: only "Ayşe" or "Ayşe Yılmaz",
    # not a sentence whose first word merely looks like a name.
    if len(words) in {1, 2} and len(words) == len(normalized.split()):
        return _format_name(words)
    return None
