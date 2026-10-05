"""Language registry for transcription.

Codes are read from faster-whisper's tokenizer at runtime so the list cannot
drift from what the model actually accepts; labels are ours.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass

logger = logging.getLogger(__name__)

# English labels for every Whisper-supported language code.
# Source: https://github.com/openai/whisper/blob/main/whisper/tokenizer.py
# (LANGUAGES dict, which maps English name → ISO code).
_CODE_TO_LABEL: dict[str, str] = {
    "af": "Afrikaans",
    "am": "Amharic",
    "ar": "Arabic",
    "as": "Assamese",
    "az": "Azerbaijani",
    "ba": "Bashkir",
    "be": "Belarusian",
    "bg": "Bulgarian",
    "bn": "Bengali",
    "bo": "Tibetan",
    "br": "Breton",
    "bs": "Bosnian",
    "ca": "Catalan",
    "cs": "Czech",
    "cy": "Welsh",
    "da": "Danish",
    "de": "German",
    "el": "Greek",
    "en": "English",
    "es": "Spanish",
    "et": "Estonian",
    "eu": "Basque",
    "fa": "Persian",
    "fi": "Finnish",
    "fo": "Faroese",
    "fr": "French",
    "gl": "Galician",
    "gu": "Gujarati",
    "ha": "Hausa",
    "haw": "Hawaiian",
    "he": "Hebrew",
    "hi": "Hindi",
    "hr": "Croatian",
    "ht": "Haitian Creole",
    "hu": "Hungarian",
    "hy": "Armenian",
    "id": "Indonesian",
    "is": "Icelandic",
    "it": "Italian",
    "ja": "Japanese",
    "jw": "Javanese",
    "ka": "Georgian",
    "kk": "Kazakh",
    "km": "Khmer",
    "kn": "Kannada",
    "ko": "Korean",
    "la": "Latin",
    "lb": "Luxembourgish",
    "ln": "Lingala",
    "lo": "Lao",
    "lt": "Lithuanian",
    "lv": "Latvian",
    "mg": "Malagasy",
    "mi": "Maori",
    "mk": "Macedonian",
    "ml": "Malayalam",
    "mn": "Mongolian",
    "mr": "Marathi",
    "ms": "Malay",
    "mt": "Maltese",
    "my": "Myanmar",
    "ne": "Nepali",
    "nl": "Dutch",
    "nn": "Nynorsk",
    "no": "Norwegian",
    "oc": "Occitan",
    "pa": "Punjabi",
    "pl": "Polish",
    "ps": "Pashto",
    "pt": "Portuguese",
    "ro": "Romanian",
    "ru": "Russian",
    "sa": "Sanskrit",
    "sd": "Sindhi",
    "si": "Sinhala",
    "sk": "Slovak",
    "sl": "Slovenian",
    "sn": "Shona",
    "so": "Somali",
    "sq": "Albanian",
    "sr": "Serbian",
    "su": "Sundanese",
    "sv": "Swedish",
    "sw": "Swahili",
    "ta": "Tamil",
    "te": "Telugu",
    "tg": "Tajik",
    "th": "Thai",
    "tk": "Turkmen",
    "tl": "Tagalog",
    "tr": "Turkish",
    "tt": "Tatar",
    "uk": "Ukrainian",
    "ur": "Urdu",
    "uz": "Uzbek",
    "vi": "Vietnamese",
    "yi": "Yiddish",
    "yo": "Yoruba",
    "zh": "Chinese",
    "yue": "Cantonese",
}


@dataclass(frozen=True, slots=True)
class Language:
    """Immutable descriptor for a supported transcription language."""

    code: str
    label: str


def _build_registry() -> list[Language]:
    """Build the list from faster-whisper's codes, falling back to the label table."""
    try:
        from faster_whisper.tokenizer import _LANGUAGE_CODES

        codes: tuple[str, ...] = _LANGUAGE_CODES
    except ImportError:
        logger.warning("faster-whisper not importable — falling back to hardcoded language codes")
        codes = tuple(_CODE_TO_LABEL.keys())

    languages: list[Language] = []
    for code in codes:
        label = _CODE_TO_LABEL.get(code)
        if label is None:
            # Defensive fallback: new code added upstream but not in our table.
            label = code.title()
            logger.warning(
                "Language code %r has no label in the registry — using %r. "
                "Please update _CODE_TO_LABEL in app/services/languages.py.",
                code,
                label,
            )
        languages.append(Language(code=code, label=label))

    # Sort by English label for stable, predictable ordering.
    languages.sort(key=lambda lang: lang.label)
    return languages


# Module-level singleton — built once at import time.
LANGUAGES: list[Language] = _build_registry()

# Fast O(1) lookup set for validation.
LANGUAGE_CODES: frozenset[str] = frozenset(lang.code for lang in LANGUAGES)


def is_valid_language(code: str) -> bool:
    """Return True if *code* is a known Whisper language code.

    Does NOT accept "auto" — callers must check for that separately.
    """
    return code in LANGUAGE_CODES


def all_languages() -> list[Language]:
    """Return all supported languages, sorted by label."""
    return LANGUAGES
