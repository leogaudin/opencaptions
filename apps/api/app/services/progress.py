"""The phases of a job, each named by the message shown while it runs.

A job's progress bar is simply the fraction its one long step reports, a render
or a transcription moving 0..1, not several steps squeezed into sub-ranges of
the bar. The short phases around it (preparing, downloading the model) report no
fraction of their own: the bar waits at 0 and only the message changes. The task
and the endpoint that receives a sub-task's reports name the same phase, so the
stored message and the broadcast one cannot drift apart.
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class Stage:
    """A phase of a job, named by the message shown while it runs."""

    message: str


DONE = 1.0

# The engine posts its own 0..1 to /jobs/{id}/progress as it renders.
RENDER_PREPARING = Stage("Preparing render")
RENDERING = Stage("Rendering")

# The transcription provider reports its own 0..1 as segments stream in.
TRANSCRIBE_STARTING = Stage("Starting")
TRANSCRIBE_DOWNLOADING = Stage("Downloading video")
TRANSCRIBE_EXTRACTING = Stage("Extracting audio")
# Loading cached weights is a moment; fetching them is minutes and gigabytes.
# Only the message distinguishes them, and neither reports a fraction.
TRANSCRIBE_LOADING_MODEL = Stage("Loading model")
TRANSCRIBE_FETCHING_MODEL = Stage("Downloading model, first use only, this takes a while")
TRANSCRIBING = Stage("Transcribing")
