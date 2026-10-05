"""Google Fonts, served through this instance.

The catalog, each font file and each name-only preview are fetched from Google
once and kept in object storage, so the browser never contacts Google, renders
read the same bytes the preview drew, and an instance keeps working with
everything it has already used if Google becomes unreachable.

The CSS API answers a non-browser client with TrueType, the one format every
consumer here (the engine and the browser) can read.
"""

from __future__ import annotations

import hashlib
import json
import logging
import re
from dataclasses import dataclass
from functools import cache

import httpx

from app.storage import s3

logger = logging.getLogger(__name__)

CATALOG_URL = "https://fonts.google.com/metadata/fonts"
CSS_URL = "https://fonts.googleapis.com/css2"
CATALOG_KEY = "fonts/catalog.json"
TIMEOUT = httpx.Timeout(20.0, connect=5.0)
# Pinned, because the CSS API picks the format from it: a client it does not
# recognise as a browser gets TrueType, which the engine can parse and woff2 is not.
HEADERS = {"User-Agent": "OpenCaptions"}
# The first four bytes of a TrueType or OpenType file.
SFNT = (b"\x00\x01\x00\x00", b"OTTO", b"true")
# Captions are drawn heavy; each family is fetched at its weight nearest this.
TARGET_WEIGHT = 800
FONT_TYPE = "font/ttf"


@dataclass(frozen=True)
class Family:
    family: str
    category: str
    weight: int


class FontUnavailableError(Exception):
    """A family is unknown, or Google could not be reached to fetch it."""


def _nearest_weight(styles: dict[str, object]) -> int:
    upright = [int(k) for k in styles if k.isdigit()]
    # Ties go to the heavier weight, which reads better as a caption.
    return min(upright, key=lambda w: (abs(w - TARGET_WEIGHT), -w), default=400)


def _parse_catalog(body: str) -> list[Family]:
    data = json.loads(body.removeprefix(")]}'"))
    rows = sorted(data["familyMetadataList"], key=lambda f: f.get("popularity", 1 << 30))
    return [
        Family(f["family"], f.get("category", ""), _nearest_weight(f.get("fonts", {})))
        for f in rows
    ]


@cache
def catalog() -> tuple[Family, ...]:
    """Every family, most popular first. Cached in storage, then in memory."""
    if s3.object_exists(CATALOG_KEY):
        return tuple(Family(**f) for f in json.loads(s3.get_object_bytes(CATALOG_KEY)))
    try:
        resp = httpx.get(CATALOG_URL, headers=HEADERS, timeout=TIMEOUT)
        resp.raise_for_status()
    except httpx.HTTPError as e:
        raise FontUnavailableError(f"Google Fonts catalog unreachable: {e}") from e
    families = _parse_catalog(resp.text)
    body = json.dumps([f.__dict__ for f in families]).encode()
    s3.put_object_bytes(CATALOG_KEY, body, "application/json")
    return tuple(families)


def find(family: str) -> Family | None:
    # A failure is not cached, so an unreachable Google is retried next time.
    return next((f for f in catalog() if f.family == family), None)


def _key(kind: str, family: str) -> str:
    # Readable, and unique: the hash keeps two families that slug alike apart.
    slug = re.sub(r"[^A-Za-z0-9]+", "-", family)
    digest = hashlib.sha256(family.encode()).hexdigest()[:8]
    return f"fonts/{kind}/{slug}-{digest}.ttf"


def _fetch(family: Family, text: str | None) -> bytes:
    params = {"family": f"{family.family}:wght@{family.weight}"}
    if text:
        params["text"] = text
    try:
        css = httpx.get(CSS_URL, params=params, headers=HEADERS, timeout=TIMEOUT)
        css.raise_for_status()
        url = re.search(r"url\((https://fonts\.gstatic\.com/[^)]+)\)", css.text)
        if not url:
            raise FontUnavailableError(f"No font file offered for {family.family}")
        font = httpx.get(url.group(1), headers=HEADERS, timeout=TIMEOUT)
        font.raise_for_status()
    except httpx.HTTPError as e:
        raise FontUnavailableError(f"Google Fonts unreachable for {family.family}: {e}") from e
    if not font.content.startswith(SFNT):
        raise FontUnavailableError(f"Google Fonts did not send TrueType for {family.family}")
    return font.content


def _stored(kind: str, name: str, text: str | None) -> str:
    family = find(name)
    if family is None:
        raise FontUnavailableError(f"Unknown font family {name!r}")
    key = _key(kind, family.family)
    if not s3.object_exists(key):
        s3.put_object_bytes(key, _fetch(family, text), FONT_TYPE)
        logger.info("cached font kind=%s family=%s weight=%s", kind, family.family, family.weight)
    return key


def file_key(name: str) -> str:
    """Storage key of a family's caption-weight font file, fetching it once."""
    return _stored("files", name, None)


def sample_key(name: str) -> str:
    """Storage key of a tiny subset that can only draw the family's own name."""
    return _stored("samples", name, name)
