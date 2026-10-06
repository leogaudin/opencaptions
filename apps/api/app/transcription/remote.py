"""OpenCaptionsRemoteProvider: transcribe on another OpenCaptions backend.

The audio goes to the transcription API of the instance at ``TRANSCRIPTION_REMOTE_URL``
(see app.api.transcriptions), this side polls the job, and the result comes back as a
``Transcript``: the schema every OpenCaptions component already speaks, so nothing is
mapped. A laptop stack with no GPU can hand its transcriptions to one that has.

Privacy: the audio leaves this machine for the remote instance, so the UI names its
host when this provider is selected.
"""

from __future__ import annotations

import contextlib
import logging
import time
from typing import Any
from urllib.parse import urlparse

import httpx

from app.core.config import settings
from app.models.schemas import Transcript
from app.services.video_fetch import UnsafeURLError, validate_url
from app.transcription.base import ProgressCallback, TranscriptionProvider, register

logger = logging.getLogger(__name__)

# The transcription API versions this provider speaks (a major version it does not know
# is refused with a message, rather than misread).
SUPPORTED_API_VERSION = 1
HOP_HEADER = "X-OpenCaptions-Hop"
POLL_SECONDS = 1.5
# A job that has been neither finished nor failed for this long is given up on.
GIVE_UP_AFTER_S = 3 * 60 * 60
_TIMEOUT = httpx.Timeout(600.0, connect=15.0)


class RemoteTranscriptionError(RuntimeError):
    """The remote instance could not be used; the message says why, for the user."""


def configured() -> bool:
    return bool(settings.transcription_remote_url and settings.transcription_remote_key)


def _base_url() -> str:
    """The remote's origin, checked like any address this server is asked to reach."""
    if not configured():
        raise RemoteTranscriptionError(
            "The opencaptions provider needs TRANSCRIPTION_REMOTE_URL and "
            "TRANSCRIPTION_REMOTE_KEY to be set."
        )
    url = settings.transcription_remote_url.strip().rstrip("/")
    try:
        validate_url(url)
    except UnsafeURLError as exc:
        raise RemoteTranscriptionError(f"The remote address is not allowed: {exc}") from exc
    return url


def _client() -> httpx.Client:
    # No redirects: the address was checked, and a redirect could lead anywhere.
    return httpx.Client(
        timeout=_TIMEOUT,
        follow_redirects=False,
        headers={
            "Authorization": f"Bearer {settings.transcription_remote_key}",
            HOP_HEADER: "1",
        },
    )


def _explain(resp: httpx.Response) -> str:
    """The remote's own message for an error response, else the status."""
    try:
        detail = resp.json().get("detail")
        if isinstance(detail, dict) and detail.get("detail"):
            return str(detail["detail"])
    except Exception:  # noqa: BLE001
        pass
    return f"HTTP {resp.status_code}"


def _capabilities(client: httpx.Client, base: str) -> dict[str, Any]:
    try:
        resp = client.get(f"{base}/api/v1/transcription/capabilities")
    except httpx.HTTPError as exc:
        host = urlparse(base).netloc
        raise RemoteTranscriptionError(f"Could not reach {host}: {exc}") from exc
    if resp.status_code == 401:
        raise RemoteTranscriptionError("The remote instance rejected the key (revoked or wrong).")
    if resp.status_code != 200:
        raise RemoteTranscriptionError(f"The remote instance answered: {_explain(resp)}")
    caps: dict[str, Any] = resp.json()
    if caps.get("api_version") != SUPPORTED_API_VERSION:
        raise RemoteTranscriptionError(
            f"The remote instance speaks transcription API version {caps.get('api_version')}; "
            f"this one speaks {SUPPORTED_API_VERSION}. Update the older of the two."
        )
    return caps


def check_connection() -> dict[str, Any]:
    """What GET /settings/transcription/test reports: the remote's name and models, or why not."""
    base = _base_url()
    with _client() as client:
        caps = _capabilities(client, base)
    return {
        "instance_name": caps.get("instance_name"),
        "api_version": caps.get("api_version"),
        "models": caps.get("models", []),
    }


class OpenCaptionsRemoteProvider(TranscriptionProvider):
    """Transcription on another OpenCaptions backend, through its transcription API."""

    name = "opencaptions"

    def transcribe(
        self,
        audio_path: str,
        *,
        language: str = "auto",
        model: str | None = None,
        on_progress: ProgressCallback | None = None,
    ) -> Transcript:
        base = _base_url()

        def report(fraction: float, message: str) -> None:
            if on_progress:
                on_progress(fraction, message)

        with _client() as client:
            caps = _capabilities(client, base)
            # A model id is meaningful to the instance that lists it: send ours only if the
            # remote offers it, else leave the choice to the remote.
            offered = {m.get("id") for m in caps.get("models", [])}
            data: dict[str, str] = {"language": language}
            if model and model in offered:
                data["model"] = model

            report(0.02, f"Uploading audio to {caps.get('instance_name') or 'the remote instance'}")
            with open(audio_path, "rb") as fh:
                resp = client.post(
                    f"{base}/api/v1/transcriptions",
                    data=data,
                    files={"audio": ("audio.wav", fh, "audio/wav")},
                )
            if resp.status_code != 202:
                raise RemoteTranscriptionError(f"The remote instance refused it: {_explain(resp)}")
            job_id = resp.json()["job_id"]
            try:
                self._wait(client, base, job_id, report)
                result = client.get(f"{base}/api/v1/transcriptions/{job_id}")
                if result.status_code != 200:
                    raise RemoteTranscriptionError(
                        f"The remote transcript could not be fetched: {_explain(result)}"
                    )
                transcript = Transcript.model_validate_json(result.content)
            finally:
                with contextlib.suppress(httpx.HTTPError):
                    client.delete(f"{base}/api/v1/transcriptions/{job_id}")
        report(1.0, f"Transcribed {len(transcript.segments)} segments remotely")
        return transcript

    def _wait(self, client: httpx.Client, base: str, job_id: str, report: Any) -> None:
        deadline = time.monotonic() + GIVE_UP_AFTER_S
        while True:
            try:
                resp = client.get(f"{base}/api/v1/jobs/{job_id}")
            except httpx.HTTPError as exc:
                raise RemoteTranscriptionError(
                    f"Lost contact with the remote instance: {exc}"
                ) from exc
            if resp.status_code != 200:
                raise RemoteTranscriptionError(
                    f"The remote job could not be followed: {_explain(resp)}"
                )
            job = resp.json()
            status = job.get("status")
            if status == "completed":
                return
            if status in ("failed", "cancelled"):
                raise RemoteTranscriptionError(
                    f"The remote transcription {status}: {job.get('error') or job.get('message') or ''}".strip()
                )
            # The upload is the first few percent; the remote's own progress fills the rest.
            report(0.05 + 0.9 * float(job.get("progress") or 0.0), str(job.get("message") or ""))
            if time.monotonic() > deadline:
                raise RemoteTranscriptionError("The remote transcription took too long; gave up.")
            time.sleep(POLL_SECONDS)


register(OpenCaptionsRemoteProvider())
