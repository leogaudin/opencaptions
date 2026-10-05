"""Fetch a video from a user-supplied URL with SSRF protection and size limits.

The sole entry point for fetching external URLs: every safety check lives here.
"""

from __future__ import annotations

import ipaddress
import logging
import mimetypes
import os
import socket
import tempfile
from pathlib import Path
from urllib.parse import urlparse

import httpx

from app.core.config import settings

logger = logging.getLogger(__name__)

# Constants

# Maximum redirect hops to follow — keeps an attacker from bouncing through
# many public hosts before landing on an internal one.
_MAX_REDIRECTS = 5

# Status codes treated as redirects when following hops manually.
_REDIRECT_STATUSES = frozenset({301, 302, 303, 307, 308})

# Download chunk size (256 KiB) — balances memory usage against syscall count.
_CHUNK_SIZE = 256 * 1024

# Connect + read timeouts (seconds).
_CONNECT_TIMEOUT = 10.0
_READ_TIMEOUT = 60.0


# Exceptions


class VideoFetchError(Exception):
    """Base exception for all fetch-related failures."""

    def __init__(self, message: str, *, code: str) -> None:
        super().__init__(message)
        self.code = code


class UnsafeURLError(VideoFetchError):
    """The URL targets a disallowed host or scheme."""

    def __init__(self, message: str) -> None:
        super().__init__(message, code="invalid_video_url")


class FetchFailedError(VideoFetchError):
    """The remote server returned an error or was unreachable."""

    def __init__(self, message: str) -> None:
        super().__init__(message, code="video_fetch_failed")


class UnsupportedMediaError(VideoFetchError):
    """The remote Content-Type clearly indicates a non-video resource."""

    def __init__(self, message: str) -> None:
        super().__init__(message, code="unsupported_media")


class FileTooLargeError(VideoFetchError):
    """The remote file exceeds the configured size cap."""

    def __init__(self, message: str) -> None:
        super().__init__(message, code="upload_too_large")


# The server fetches a URL the caller supplies, so without these checks it is an
# SSRF probe for cloud metadata, localhost debug endpoints and private databases.


def _is_ip_allowed(ip_str: str) -> bool:
    """Whether the address is globally routable, unless allow-listed."""
    try:
        addr = ipaddress.ip_address(ip_str)
    except ValueError:
        return False

    # Check the env-driven allowlist first — self-hosters may explicitly
    # permit specific private IPs (e.g., a LAN NAS hosting videos).
    if settings.ssrf_allowed_hosts:
        allowed = {h.strip() for h in settings.ssrf_allowed_hosts.split(",") if h.strip()}
        if ip_str in allowed:
            return True

    # is_global covers loopback, RFC 1918, link-local, reserved and multicast.
    return addr.is_global


def validate_url(url: str) -> str:
    """Return the normalized URL, or raise UnsafeURLError."""
    parsed = urlparse(url)

    # Only http and https schemes are allowed.
    if parsed.scheme not in ("http", "https"):
        raise UnsafeURLError(
            f"Unsupported URL scheme '{parsed.scheme}' — only http and https are allowed"
        )

    hostname = parsed.hostname
    if not hostname:
        raise UnsafeURLError("URL has no hostname")

    # Check hostname allowlist before DNS resolution (allows hostnames too).
    if settings.ssrf_allowed_hosts:
        allowed = {h.strip() for h in settings.ssrf_allowed_hosts.split(",") if h.strip()}
        if hostname in allowed:
            return url

    # Every resolved address must be safe, or a hostname could resolve public
    # here and internal at request time (DNS rebinding).
    try:
        addrinfos = socket.getaddrinfo(hostname, parsed.port or 443, proto=socket.IPPROTO_TCP)
    except socket.gaierror as e:
        raise UnsafeURLError(f"DNS resolution failed for '{hostname}': {e}") from e

    if not addrinfos:
        raise UnsafeURLError(f"DNS resolution returned no addresses for '{hostname}'")

    for _family, _type, _proto, _canonname, sockaddr in addrinfos:
        # sockaddr[0] is always the host IP string in both IPv4 (str, int)
        # and IPv6 (str, int, int, int) tuples, but mypy sees the union.
        ip_str = str(sockaddr[0])
        if not _is_ip_allowed(ip_str):
            raise UnsafeURLError(
                f"URL resolves to non-public address {ip_str} — "
                "requests to private/loopback/link-local networks are blocked"
            )

    return url


def _validate_redirect(url: str) -> None:
    """Re-check a redirect target, so a public URL cannot 302 into the LAN."""
    validate_url(url)


# Content-Type validation

# Content-Types that clearly indicate a non-video resource. We reject these
# to avoid fetching HTML error pages, JSON API responses, etc.
_BLOCKED_CONTENT_TYPES = frozenset(
    {
        "text/html",
        "text/xml",
        "application/xml",
        "application/json",
        "application/javascript",
        "text/css",
        "text/plain",
    }
)


def _is_content_type_acceptable(content_type: str | None) -> bool:
    """Whether the Content-Type could be video. Missing or octet-stream passes,
    since some CDNs send neither."""
    if not content_type:
        return True

    # Strip parameters like charset
    media_type = content_type.split(";")[0].strip().lower()

    if media_type.startswith("video/"):
        return True
    if media_type == "application/octet-stream":
        return True

    # Reject Content-Types that are clearly NOT video. Unknown types are
    # allowed (could be a custom video MIME).
    return media_type not in _BLOCKED_CONTENT_TYPES


# Extension derivation


def derive_extension(url: str, content_type: str | None) -> str:
    """Extension from the URL path or Content-Type, defaulting to .mp4."""
    # Try URL path first
    parsed = urlparse(url)
    path = parsed.path.rstrip("/")
    if "." in path.split("/")[-1]:
        ext = "." + path.rsplit(".", 1)[-1].lower()
        # Only accept reasonable video extensions
        if ext in _VIDEO_EXTENSIONS:
            return ext

    # Try Content-Type
    if content_type:
        media_type = content_type.split(";")[0].strip().lower()
        guessed = mimetypes.guess_extension(media_type)
        if guessed and guessed in _VIDEO_EXTENSIONS:
            return guessed

    # Fallback
    return ".mp4"


# Common video file extensions for validation.
_VIDEO_EXTENSIONS = frozenset(
    {
        ".mp4",
        ".mkv",
        ".mov",
        ".avi",
        ".webm",
        ".flv",
        ".wmv",
        ".m4v",
        ".ts",
        ".mts",
        ".3gp",
        ".ogv",
    }
)


# Streaming download


def _client() -> httpx.Client:
    """HTTP client with redirects disabled so each hop can be re-validated."""
    return httpx.Client(
        timeout=httpx.Timeout(connect=_CONNECT_TIMEOUT, read=_READ_TIMEOUT, pool=10.0, write=30.0),
        follow_redirects=False,
    )


def _resolve_final_url(url: str) -> str:
    """Follow redirects by hand, re-validating each hop.

    httpx exposes no per-redirect hook, so redirects are disabled and walked here.
    """
    current_url = url
    with _client() as client:
        for hop in range(_MAX_REDIRECTS + 1):
            try:
                response = client.stream("GET", current_url).__enter__()
            except httpx.RequestError as e:
                raise FetchFailedError(f"Request failed: {e}") from e

            status = response.status_code
            if status not in _REDIRECT_STATUSES:
                response.close()
                if status >= 400:
                    raise FetchFailedError(f"Remote server returned HTTP {status}")
                return current_url

            response.close()
            if hop >= _MAX_REDIRECTS:
                raise FetchFailedError(f"Too many redirects ({hop + 1}) — aborting")
            location = response.headers.get("location")
            if not location:
                raise FetchFailedError("Redirect response missing Location header")
            current_url = str(response.url.join(location))

            logger.debug("video_fetch: redirect hop %d -> %s", hop + 1, current_url)
            try:
                _validate_redirect(current_url)
            except UnsafeURLError as e:
                raise UnsafeURLError(f"Redirect to disallowed address: {e}") from e

    raise FetchFailedError("Too many redirects — aborting")


def _validate_media_headers(response: httpx.Response, url: str, max_bytes: int) -> str:
    """Reject non-video or oversized responses before any body is downloaded."""
    content_type = response.headers.get("content-type")
    if not _is_content_type_acceptable(content_type):
        raise UnsupportedMediaError(f"Remote Content-Type '{content_type}' is not a video type")

    content_length = response.headers.get("content-length")
    if content_length:
        try:
            declared_size = int(content_length)
        except ValueError:
            pass  # Malformed Content-Length — enforce during streaming instead.
        else:
            if declared_size > max_bytes:
                raise FileTooLargeError(
                    f"Remote file declares {declared_size} bytes (limit: {max_bytes} bytes)"
                )

    return derive_extension(url, content_type)


def _stream_to_tempfile(response: httpx.Response, extension: str, max_bytes: int) -> str:
    """Write the response body to a temp file, enforcing the size cap per chunk."""
    fd, tmp_path = tempfile.mkstemp(prefix="opencaptions-fetch-", suffix=extension)
    os.close(fd)

    downloaded = 0
    try:
        with open(tmp_path, "wb") as out:
            for chunk in response.iter_bytes(chunk_size=_CHUNK_SIZE):
                downloaded += len(chunk)
                if downloaded > max_bytes:
                    raise FileTooLargeError(
                        f"Download exceeded size cap at {downloaded} bytes "
                        f"(limit: {max_bytes} bytes)"
                    )
                out.write(chunk)
    except (FileTooLargeError, httpx.RequestError) as e:
        Path(tmp_path).unlink(missing_ok=True)
        if isinstance(e, httpx.RequestError):
            raise FetchFailedError(f"Download failed: {e}") from e
        raise

    logger.info("video_fetch: downloaded %d bytes to %s", downloaded, tmp_path)
    return tmp_path


def fetch_video_to_tempfile(url: str) -> tuple[str, str]:
    """Download a URL to a temp file, returning (path, extension).

    BLOCKING — call via asyncio.to_thread. Raises UnsafeURLError,
    FetchFailedError, UnsupportedMediaError or FileTooLargeError.
    """
    validate_url(url)

    max_bytes = settings.max_upload_size_mb * 1024 * 1024
    logger.info(
        "video_fetch: starting download from %s (cap: %d MB)",
        url,
        settings.max_upload_size_mb,
    )

    final_url = _resolve_final_url(url)

    try:
        with _client() as client, client.stream("GET", final_url) as response:
            if response.status_code >= 400:
                raise FetchFailedError(f"Remote server returned HTTP {response.status_code}")
            extension = _validate_media_headers(response, final_url, max_bytes)
            return _stream_to_tempfile(response, extension, max_bytes), extension
    except (UnsupportedMediaError, FileTooLargeError, FetchFailedError):
        raise
    except httpx.RequestError as e:
        raise FetchFailedError(f"Request failed: {e}") from e
