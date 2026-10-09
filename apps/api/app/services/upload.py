"""Writing an upload to disk within a size limit."""

from __future__ import annotations

from typing import BinaryIO

_CHUNK = 1024 * 1024


class UploadTooLargeError(Exception):
    """The body is larger than the limit."""


def copy_capped(source: BinaryIO, destination: str, max_bytes: int) -> int:
    """Copy ``source`` to a file, stopping with UploadTooLargeError once it passes ``max_bytes``.

    The size an upload declares is a claim, and Starlette only learns it by taking
    the whole body in first; counting what is actually written is the limit. Blocking:
    call it with ``asyncio.to_thread``.
    """
    written = 0
    with open(destination, "wb") as out:
        while chunk := source.read(_CHUNK):
            written += len(chunk)
            if written > max_bytes:
                raise UploadTooLargeError
            out.write(chunk)
    return written
