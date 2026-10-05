"""Unit tests for the URL fetch service. The network layer is always mocked."""

from __future__ import annotations

from unittest.mock import MagicMock, patch

import pytest

from app.services.video_fetch import (
    FileTooLargeError,
    UnsafeURLError,
    UnsupportedMediaError,
    _is_ip_allowed,
    derive_extension,
    fetch_video_to_tempfile,
    validate_url,
)

# SSRF guard: _is_ip_allowed


def test_is_ip_allowed_public_ipv4() -> None:
    """Public internet IPs are allowed."""
    assert _is_ip_allowed("8.8.8.8") is True
    assert _is_ip_allowed("1.1.1.1") is True
    assert _is_ip_allowed("93.184.216.34") is True  # example.com


def test_is_ip_allowed_rejects_loopback() -> None:
    """Loopback addresses (127.x.x.x, ::1) must be rejected."""
    assert _is_ip_allowed("127.0.0.1") is False
    assert _is_ip_allowed("127.0.0.2") is False
    assert _is_ip_allowed("::1") is False


def test_is_ip_allowed_rejects_private_rfc1918() -> None:
    """RFC 1918 private ranges must be rejected."""
    assert _is_ip_allowed("10.0.0.1") is False
    assert _is_ip_allowed("10.255.255.255") is False
    assert _is_ip_allowed("172.16.0.1") is False
    assert _is_ip_allowed("172.31.255.255") is False
    assert _is_ip_allowed("192.168.0.1") is False
    assert _is_ip_allowed("192.168.1.100") is False


def test_is_ip_allowed_rejects_link_local() -> None:
    """Link-local (169.254.x.x, fe80::) must be rejected — includes cloud metadata."""
    assert _is_ip_allowed("169.254.169.254") is False  # AWS metadata
    assert _is_ip_allowed("169.254.0.1") is False
    assert _is_ip_allowed("fe80::1") is False


def test_is_ip_allowed_rejects_unique_local_ipv6() -> None:
    """IPv6 unique-local (fd00::/8) must be rejected."""
    assert _is_ip_allowed("fd00::1") is False
    assert _is_ip_allowed("fdff:ffff:ffff:ffff:ffff:ffff:ffff:ffff") is False


def test_is_ip_allowed_rejects_unspecified() -> None:
    """Unspecified addresses (0.0.0.0, ::) must be rejected."""
    assert _is_ip_allowed("0.0.0.0") is False
    assert _is_ip_allowed("::") is False


def test_is_ip_allowed_rejects_invalid_input() -> None:
    """Garbage input must be rejected, not crash."""
    assert _is_ip_allowed("not-an-ip") is False
    assert _is_ip_allowed("") is False


def test_is_ip_allowed_allowlist_overrides(monkeypatch: pytest.MonkeyPatch) -> None:
    """The SSRF_ALLOWED_HOSTS setting allows specific private IPs."""
    from app.core import config

    monkeypatch.setattr(config.settings, "ssrf_allowed_hosts", "192.168.1.50,10.0.0.5")
    assert _is_ip_allowed("192.168.1.50") is True
    assert _is_ip_allowed("10.0.0.5") is True
    # Other private IPs still blocked
    assert _is_ip_allowed("192.168.1.51") is False


# SSRF guard: validate_url


def test_validate_url_rejects_non_http_schemes() -> None:
    """Only http/https are allowed."""
    with pytest.raises(UnsafeURLError, match="scheme"):
        validate_url("ftp://example.com/video.mp4")
    with pytest.raises(UnsafeURLError, match="scheme"):
        validate_url("file:///etc/passwd")
    with pytest.raises(UnsafeURLError, match="scheme"):
        validate_url("gopher://evil.com/data")


def test_validate_url_rejects_missing_hostname() -> None:
    with pytest.raises(UnsafeURLError, match="hostname"):
        validate_url("http:///no-host/video.mp4")


@patch("app.services.video_fetch.socket.getaddrinfo")
def test_validate_url_accepts_public_host(mock_gai: MagicMock) -> None:
    """A URL resolving to a public IP passes validation."""
    mock_gai.return_value = [
        (2, 1, 6, "", ("93.184.216.34", 443)),
    ]
    result = validate_url("https://example.com/video.mp4")
    assert result == "https://example.com/video.mp4"


@patch("app.services.video_fetch.socket.getaddrinfo")
def test_validate_url_rejects_private_resolution(mock_gai: MagicMock) -> None:
    """A URL that resolves to a private IP is blocked."""
    mock_gai.return_value = [
        (2, 1, 6, "", ("192.168.1.1", 443)),
    ]
    with pytest.raises(UnsafeURLError, match="non-public"):
        validate_url("https://malicious.example.com/video.mp4")


@patch("app.services.video_fetch.socket.getaddrinfo")
def test_validate_url_rejects_metadata_address(mock_gai: MagicMock) -> None:
    """Cloud metadata endpoint (169.254.169.254) must be blocked."""
    mock_gai.return_value = [
        (2, 1, 6, "", ("169.254.169.254", 80)),
    ]
    with pytest.raises(UnsafeURLError, match="non-public"):
        validate_url("http://metadata.internal/latest/")


@patch("app.services.video_fetch.socket.getaddrinfo")
def test_validate_url_rejects_dns_failure(mock_gai: MagicMock) -> None:
    """DNS resolution failure raises UnsafeURLError."""
    import socket

    mock_gai.side_effect = socket.gaierror("Name or service not known")
    with pytest.raises(UnsafeURLError, match="DNS resolution failed"):
        validate_url("https://nonexistent.invalid/video.mp4")


@patch("app.services.video_fetch.socket.getaddrinfo")
def test_validate_url_hostname_allowlist_bypasses_dns(
    mock_gai: MagicMock, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Hostname in SSRF_ALLOWED_HOSTS skips DNS resolution check."""
    from app.core import config

    monkeypatch.setattr(config.settings, "ssrf_allowed_hosts", "my-nas.local")
    result = validate_url("http://my-nas.local/videos/cat.mp4")
    assert result == "http://my-nas.local/videos/cat.mp4"
    # DNS was never called
    mock_gai.assert_not_called()


# Extension derivation


def test_derive_extension_from_url_path() -> None:
    """Extension is taken from URL path when it's a known video extension."""
    assert derive_extension("https://cdn.example.com/clip.webm", None) == ".webm"
    assert derive_extension("https://cdn.example.com/my-video.mov?t=123", None) == ".mov"
    assert derive_extension("https://cdn.example.com/path/file.mkv", "video/x-matroska") == ".mkv"


def test_derive_extension_from_content_type() -> None:
    """Falls back to Content-Type when URL has no valid extension."""
    assert derive_extension("https://cdn.example.com/video", "video/webm") == ".webm"
    assert derive_extension("https://cdn.example.com/stream/12345", "video/mp4") == ".mp4"


def test_derive_extension_fallback_mp4() -> None:
    """Falls back to .mp4 when neither URL nor Content-Type is useful."""
    assert derive_extension("https://cdn.example.com/blob/abc123", None) == ".mp4"
    assert (
        derive_extension("https://cdn.example.com/blob/abc123", "application/octet-stream")
        == ".mp4"
    )


def test_derive_extension_ignores_non_video_url_extensions() -> None:
    """URL extensions that aren't video types are ignored."""
    # .html is not a video extension — falls to Content-Type or .mp4
    assert derive_extension("https://example.com/page.html", "video/mp4") == ".mp4"
    assert derive_extension("https://example.com/page.html", None) == ".mp4"


# Size-cap enforcement (via fetch_video_to_tempfile)


@patch("app.services.video_fetch.validate_url")
@patch("app.services.video_fetch.httpx.Client")
def test_size_cap_rejects_large_content_length(
    mock_client_cls: MagicMock,
    mock_validate: MagicMock,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Files declaring a Content-Length above the cap are rejected immediately."""
    from app.core import config

    monkeypatch.setattr(config.settings, "max_upload_size_mb", 1)  # 1 MB cap
    mock_validate.return_value = "https://example.com/huge.mp4"

    # Set up the mock client to return a response with large Content-Length
    mock_response = MagicMock()
    mock_response.status_code = 200
    mock_response.headers = {"content-length": str(100 * 1024 * 1024), "content-type": "video/mp4"}
    mock_response.url = MagicMock()
    mock_response.url.join = lambda x: x

    mock_client = MagicMock()
    # First call: the redirect-handling loop
    mock_stream_ctx = MagicMock()
    mock_stream_ctx.__enter__ = MagicMock(return_value=mock_response)
    mock_stream_ctx.__exit__ = MagicMock(return_value=False)
    mock_client.stream.return_value = mock_stream_ctx

    mock_client_instance = MagicMock()
    mock_client_instance.__enter__ = MagicMock(return_value=mock_client)
    mock_client_instance.__exit__ = MagicMock(return_value=False)
    mock_client_cls.return_value = mock_client_instance

    with pytest.raises(FileTooLargeError, match="declares"):
        fetch_video_to_tempfile("https://example.com/huge.mp4")


@patch("app.services.video_fetch.validate_url")
@patch("app.services.video_fetch.httpx.Client")
def test_size_cap_rejects_during_streaming(
    mock_client_cls: MagicMock,
    mock_validate: MagicMock,
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: pytest.TempPathFactory,
) -> None:
    """Files exceeding the cap mid-download are aborted during streaming."""
    from app.core import config

    monkeypatch.setattr(config.settings, "max_upload_size_mb", 1)  # 1 MB cap
    mock_validate.return_value = "https://example.com/sneaky.mp4"

    # Simulate a response that doesn't declare Content-Length but streams
    # more than 1 MB of data.
    mock_response = MagicMock()
    mock_response.status_code = 200
    mock_response.headers = {"content-type": "video/mp4"}  # No content-length
    mock_response.url = MagicMock()
    mock_response.url.join = lambda x: x

    # Each chunk is 512 KB — third chunk pushes past 1 MB
    chunk_512k = b"x" * (512 * 1024)
    mock_response.iter_bytes.return_value = iter([chunk_512k, chunk_512k, chunk_512k])

    mock_client = MagicMock()
    mock_stream_ctx = MagicMock()
    mock_stream_ctx.__enter__ = MagicMock(return_value=mock_response)
    mock_stream_ctx.__exit__ = MagicMock(return_value=False)
    mock_client.stream.return_value = mock_stream_ctx

    mock_client_instance = MagicMock()
    mock_client_instance.__enter__ = MagicMock(return_value=mock_client)
    mock_client_instance.__exit__ = MagicMock(return_value=False)
    mock_client_cls.return_value = mock_client_instance

    with pytest.raises(FileTooLargeError, match="exceeded size cap"):
        fetch_video_to_tempfile("https://example.com/sneaky.mp4")


# Content-Type validation


@patch("app.services.video_fetch.validate_url")
@patch("app.services.video_fetch.httpx.Client")
def test_rejects_html_content_type(
    mock_client_cls: MagicMock,
    mock_validate: MagicMock,
) -> None:
    """Responses with text/html Content-Type are rejected as unsupported media."""
    mock_validate.return_value = "https://example.com/video"

    mock_response = MagicMock()
    mock_response.status_code = 200
    mock_response.headers = {"content-type": "text/html; charset=utf-8"}
    mock_response.url = MagicMock()
    mock_response.url.join = lambda x: x

    mock_client = MagicMock()
    mock_stream_ctx = MagicMock()
    mock_stream_ctx.__enter__ = MagicMock(return_value=mock_response)
    mock_stream_ctx.__exit__ = MagicMock(return_value=False)
    mock_client.stream.return_value = mock_stream_ctx

    mock_client_instance = MagicMock()
    mock_client_instance.__enter__ = MagicMock(return_value=mock_client)
    mock_client_instance.__exit__ = MagicMock(return_value=False)
    mock_client_cls.return_value = mock_client_instance

    with pytest.raises(UnsupportedMediaError, match="text/html"):
        fetch_video_to_tempfile("https://example.com/video")


# Redirect re-validation (SSRF bypass prevention)


@patch("app.services.video_fetch.socket.getaddrinfo")
@patch("app.services.video_fetch.httpx.Client")
def test_redirect_into_private_network_is_blocked(
    mock_client_cls: MagicMock,
    mock_gai: MagicMock,
) -> None:
    """A public URL that redirects to a private IP is blocked.

    The redirect is the bypass: validating only the first URL is not enough.
    """

    # First call to validate_url (initial URL) — public IP, passes
    # Second call to validate_url (redirect target) — metadata IP, blocked
    def gai_side_effect(hostname, *args, **kwargs):
        if hostname == "evil.com":
            return [(2, 1, 6, "", ("93.184.216.34", 443))]
        elif hostname == "169.254.169.254":
            return [(2, 1, 6, "", ("169.254.169.254", 80))]
        return [(2, 1, 6, "", ("93.184.216.34", 443))]

    mock_gai.side_effect = gai_side_effect

    # Set up the redirect response
    redirect_response = MagicMock()
    redirect_response.status_code = 302
    redirect_response.headers = {"location": "http://169.254.169.254/latest/meta-data/"}
    redirect_response.url = MagicMock()
    redirect_response.url.join = MagicMock(return_value="http://169.254.169.254/latest/meta-data/")
    redirect_response.close = MagicMock()

    mock_stream_ctx = MagicMock()
    mock_stream_ctx.__enter__ = MagicMock(return_value=redirect_response)
    mock_stream_ctx.__exit__ = MagicMock(return_value=False)

    mock_client = MagicMock()
    mock_client.stream.return_value = mock_stream_ctx

    mock_client_instance = MagicMock()
    mock_client_instance.__enter__ = MagicMock(return_value=mock_client)
    mock_client_instance.__exit__ = MagicMock(return_value=False)
    mock_client_cls.return_value = mock_client_instance

    with pytest.raises(UnsafeURLError, match="disallowed"):
        fetch_video_to_tempfile("https://evil.com/video.mp4")
