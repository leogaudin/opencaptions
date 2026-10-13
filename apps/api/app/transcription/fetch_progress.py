"""How far a model download has got, for the bar that would otherwise sit at zero for minutes.

Hugging Face writes a file into the cache's `blobs` folder as it arrives, so the bytes on disk
against the size of the files about to be fetched are the fraction done. The same measure the
iPhone app uses.
"""

from __future__ import annotations

import contextlib
import logging
import threading
from collections.abc import Callable, Iterator
from dataclasses import dataclass
from fnmatch import fnmatch
from pathlib import Path

logger = logging.getLogger(__name__)

# Asking the Hub how big the files are must not hold up the download it describes.
_LOOKUP_TIMEOUT_S = 5.0
_POLL_S = 1.0
# The last stretch (checking the files, putting them in place) has no fraction to show.
_CEILING = 0.99


@dataclass(frozen=True, slots=True)
class FetchPlan:
    """The files a model needs from a Hugging Face repository, and where they are cached."""

    repo: str
    cache_dir: str
    revision: str | None = None
    # Only the files these match are fetched; None for the whole repository.
    patterns: tuple[str, ...] | None = None


def expected_bytes(plan: FetchPlan) -> int | None:
    """The size of the files to fetch, or None when the Hub cannot say."""
    try:
        from huggingface_hub import HfApi

        info = HfApi().model_info(
            plan.repo, revision=plan.revision, files_metadata=True, timeout=_LOOKUP_TIMEOUT_S
        )
    except Exception:  # noqa: BLE001, a download with no fraction is better than none
        logger.info("Could not size %s; the download reports no fraction", plan.repo)
        return None
    total = sum(
        s.size or 0
        for s in info.siblings or []
        if plan.patterns is None or any(fnmatch(s.rfilename, p) for p in plan.patterns)
    )
    return total or None


def bytes_on_disk(plan: FetchPlan) -> int:
    """What the repository's cache folder holds now, finished files and partial ones alike."""
    blobs = Path(plan.cache_dir) / f"models--{plan.repo.replace('/', '--')}" / "blobs"
    try:
        return sum(f.stat().st_size for f in blobs.iterdir() if f.is_file())
    except OSError:
        return 0


@contextlib.contextmanager
def watching(plan: FetchPlan | None, report: Callable[[float], None]) -> Iterator[None]:
    """Call `report(fraction)` as the plan's files arrive, for as long as the block runs."""
    total = expected_bytes(plan) if plan else None
    if plan is None or total is None:
        yield
        return
    done = threading.Event()

    def poll() -> None:
        last = -1.0
        while not done.wait(_POLL_S):
            fraction = min(_CEILING, bytes_on_disk(plan) / total)
            if fraction - last >= 0.01:
                last = fraction
                with contextlib.suppress(Exception):
                    report(fraction)

    thread = threading.Thread(target=poll, daemon=True)
    thread.start()
    try:
        yield
    finally:
        done.set()
        thread.join(timeout=_POLL_S * 2)
