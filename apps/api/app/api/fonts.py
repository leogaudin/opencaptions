"""/api/v1/fonts: the Google Fonts catalog, font files and name previews."""

from __future__ import annotations

import asyncio
from collections.abc import Callable
from typing import Annotated

from fastapi import APIRouter, Depends, Path
from fastapi.responses import Response
from pydantic import BaseModel

from app.api.deps import get_current_user
from app.api.errors import ApiError
from app.models import User
from app.services import fonts
from app.storage import s3

router = APIRouter(prefix="/fonts", tags=["fonts"])

# Bytes for a family never change once stored, so the browser may keep them.
_IMMUTABLE = {"Cache-Control": "private, max-age=31536000, immutable"}


class FontFamily(BaseModel):
    """One Google Fonts family."""

    family: str
    category: str


async def _resolve[T](fn: Callable[[], T]) -> T:
    try:
        return await asyncio.to_thread(fn)
    except fonts.FontUnavailableError as e:
        raise ApiError.FONT_UNAVAILABLE.exc(str(e)) from e


@router.get(
    "",
    response_model=list[FontFamily],
    responses={**ApiError.docs(ApiError.FONT_UNAVAILABLE)},
    summary="List fonts",
)
async def list_fonts(_user: Annotated[User, Depends(get_current_user)]) -> list[FontFamily]:
    """Every Google Fonts family, most popular first."""
    families = await _resolve(fonts.catalog)
    return [FontFamily(family=f.family, category=f.category) for f in families]


async def _font(key: Callable[[], str]) -> Response:
    body = await asyncio.to_thread(s3.get_object_bytes, await _resolve(key))
    return Response(body, media_type=fonts.FONT_TYPE, headers=_IMMUTABLE)


_FAMILY = Annotated[str, Path(max_length=100)]


@router.get(
    "/{family}/file",
    response_class=Response,
    responses={200: {"content": {fonts.FONT_TYPE: {}}}, **ApiError.docs(ApiError.FONT_UNAVAILABLE)},
    summary="Font file",
)
async def font_file(family: _FAMILY, _user: Annotated[User, Depends(get_current_user)]) -> Response:
    """The family at caption weight, as TrueType, for the editor preview."""
    return await _font(lambda: fonts.file_key(family))


@router.get(
    "/{family}/sample",
    response_class=Response,
    responses={200: {"content": {fonts.FONT_TYPE: {}}}, **ApiError.docs(ApiError.FONT_UNAVAILABLE)},
    summary="Font name preview",
)
async def font_sample(
    family: _FAMILY, _user: Annotated[User, Depends(get_current_user)]
) -> Response:
    """A subset able to draw only the family's own name, for the font picker."""
    return await _font(lambda: fonts.sample_key(family))
