"""Unit tests for the language registry and transcribe endpoint validation."""

from __future__ import annotations

from app.services.languages import (
    LANGUAGE_CODES,
    LANGUAGES,
    all_languages,
    is_valid_language,
)

# === Language Registry Tests ===


class TestLanguageRegistry:
    def test_registry_is_non_empty(self) -> None:
        """The registry must contain at least one language."""
        assert len(LANGUAGES) > 0

    def test_registry_has_expected_count(self) -> None:
        """faster-whisper ships 100 language codes (as of v1.x)."""
        # Allow ≥99 to accommodate minor version differences.
        assert len(LANGUAGES) >= 99

    def test_codes_are_unique(self) -> None:
        """Every code must appear exactly once."""
        codes = [lang.code for lang in LANGUAGES]
        assert len(codes) == len(set(codes))

    def test_no_auto_entry(self) -> None:
        """'auto' is a mode, not a language — must not appear in the registry."""
        assert "auto" not in LANGUAGE_CODES
        for lang in LANGUAGES:
            assert lang.code != "auto"

    def test_sorted_by_label(self) -> None:
        """Entries must be sorted alphabetically by English label."""
        labels = [lang.label for lang in LANGUAGES]
        assert labels == sorted(labels)

    def test_common_languages_present(self) -> None:
        """Smoke-check that well-known languages are in the set."""
        for code in ("en", "fr", "es", "de", "zh", "ja", "ko", "pt", "ru"):
            assert code in LANGUAGE_CODES, f"{code} missing"

    def test_all_languages_returns_same_list(self) -> None:
        """all_languages() is just the module-level LANGUAGES list."""
        assert all_languages() is LANGUAGES

    def test_language_codes_frozenset_matches(self) -> None:
        """LANGUAGE_CODES must exactly match the codes in LANGUAGES."""
        assert frozenset(lang.code for lang in LANGUAGES) == LANGUAGE_CODES


# === Validation Helper Tests ===


class TestIsValidLanguage:
    def test_accepts_known_code(self) -> None:
        assert is_valid_language("en") is True
        assert is_valid_language("fr") is True
        assert is_valid_language("zh") is True

    def test_rejects_auto(self) -> None:
        """is_valid_language does NOT accept 'auto' — callers check that separately."""
        assert is_valid_language("auto") is False

    def test_rejects_unknown_code(self) -> None:
        assert is_valid_language("zz") is False
        assert is_valid_language("xx") is False
        assert is_valid_language("") is False

    def test_rejects_garbage(self) -> None:
        assert is_valid_language("not-a-language") is False
        assert is_valid_language("123") is False
