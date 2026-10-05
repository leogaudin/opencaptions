"""/api/v1/api-keys — mint, list and revoke the caller's API keys.

Session-only: a key cannot be used to manage keys, so a leaked one can be
revoked from the browser and cannot mint a replacement for itself.
"""

from __future__ import annotations

from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, Path, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import db_session, get_session_user, http_error
from app.models import ApiKey, User
from app.models.schemas import ApiKeyCreate, ApiKeyCreated, ApiKeyRead, _err
from app.services import api_keys

router = APIRouter(prefix="/api-keys", tags=["api-keys"])

_404_KEY = _err(404, "No such key (`error: api_key_not_found`)")


@router.get("", response_model=list[ApiKeyRead], summary="List API keys")
async def list_keys(
    user: Annotated[User, Depends(get_session_user)],
    session: Annotated[AsyncSession, Depends(db_session)],
) -> list[ApiKey]:
    rows = await session.scalars(
        select(ApiKey).where(ApiKey.user_id == user.id).order_by(ApiKey.created_at.desc())
    )
    return list(rows)


@router.post(
    "",
    response_model=ApiKeyCreated,
    status_code=status.HTTP_201_CREATED,
    summary="Create an API key",
)
async def create_key(
    body: ApiKeyCreate,
    user: Annotated[User, Depends(get_session_user)],
    session: Annotated[AsyncSession, Depends(db_session)],
) -> ApiKeyCreated:
    """Mint a key. The response is the only time the key itself is ever returned."""
    key, prefix, key_hash = api_keys.mint()
    row = ApiKey(user_id=user.id, name=body.name.strip(), prefix=prefix, key_hash=key_hash)
    session.add(row)
    await session.flush()
    return ApiKeyCreated(**ApiKeyRead.model_validate(row).model_dump(), key=key)


@router.delete(
    "/{key_id}",
    status_code=status.HTTP_204_NO_CONTENT,
    responses={**_404_KEY},
    summary="Revoke an API key",
)
async def revoke_key(
    key_id: Annotated[UUID, Path()],
    user: Annotated[User, Depends(get_session_user)],
    session: Annotated[AsyncSession, Depends(db_session)],
) -> None:
    row = await session.get(ApiKey, key_id)
    # Another user's key is answered exactly like a missing one.
    if row is None or row.user_id != user.id:
        raise http_error(404, "api_key_not_found", "No such key")
    await session.delete(row)
