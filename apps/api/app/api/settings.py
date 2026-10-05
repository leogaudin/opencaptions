"""/api/v1/settings router."""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends

from app.api.deps import get_current_user
from app.core.config import settings as env_settings
from app.models import User
from app.models.schemas import (
    AppSettingsResponse,
    LanguageOption,
    LimitsSettings,
    ModelOption,
    TranscriptionSettings,
)
from app.services.languages import all_languages
from app.services.whisper_models import all_models

router = APIRouter(prefix="/settings", tags=["settings"])


@router.get("", response_model=AppSettingsResponse)
async def get_settings(
    _user: Annotated[User, Depends(get_current_user)],
) -> AppSettingsResponse:
    """Return effective application settings, sourced entirely from environment
    configuration.

    Auth-required but read-only: these are deployment settings (env vars), not
    per-user preferences, so there is nothing here for an ordinary user to
    mutate at runtime. Secrets like OPENAI_API_KEY are never returned — only a
    redacted `openai_configured` boolean.
    """
    # In hosted mode the provider and model are fixed and the hardware is the
    # operator's business, so those details are withheld here exactly as
    # /health withholds them; POST /transcribe enforces the same restriction.
    hosted = env_settings.hosted_mode
    return AppSettingsResponse(
        transcription=TranscriptionSettings(
            provider=env_settings.transcription_provider,
            model=None if hosted else env_settings.whisper_model,
            device=None if hosted else env_settings.whisper_device,
            openai_configured=False if hosted else bool(env_settings.openai_api_key),
            supported_languages=[
                LanguageOption(code=lang.code, label=lang.label) for lang in all_languages()
            ],
            available_models=[]
            if hosted
            else [ModelOption(id=m.id, label=m.label, note=m.note) for m in all_models()],
        ),
        limits=LimitsSettings(
            max_upload_size_mb=env_settings.max_upload_size_mb,
            max_video_duration_s=env_settings.max_video_duration_s,
        ),
        registration_enabled=env_settings.registration_enabled,
        hosted_mode=env_settings.hosted_mode,
    )
