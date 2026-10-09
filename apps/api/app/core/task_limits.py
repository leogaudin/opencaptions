"""How long a Celery task may run, in one place.

The limits used to be one pair for every task (15 and 20 minutes), shorter than
what the product itself allows: a video up to ``MAX_VIDEO_DURATION_S`` long, and
a render the engine is given ``RENDER_REQUEST_TIMEOUT_S`` to finish. A job that
legitimately ran longer was marked failed while the engine kept encoding, or
killed with its row left ``running``.

Soft limit first (the task fails with a message and cleans up), then the hard one.
"""

from __future__ import annotations

from app.core.config import settings

_GRACE_S = 120

# How long the render worker waits for the engine's answer; the engine answers when
# the whole video is encoded.
RENDER_REQUEST_TIMEOUT_S = 30 * 60
RENDER_SOFT_LIMIT_S = RENDER_REQUEST_TIMEOUT_S + _GRACE_S
RENDER_HARD_LIMIT_S = RENDER_SOFT_LIMIT_S + _GRACE_S

# A CPU transcribes at a few times real time, so the longest accepted video sets this.
TRANSCRIBE_SOFT_LIMIT_S = max(900, settings.max_video_duration_s * 3)
TRANSCRIBE_HARD_LIMIT_S = TRANSCRIBE_SOFT_LIMIT_S + _GRACE_S

# A running job whose row has not changed for longer than any task may run is not running.
STALE_AFTER_S = max(RENDER_HARD_LIMIT_S, TRANSCRIBE_HARD_LIMIT_S) + 600
