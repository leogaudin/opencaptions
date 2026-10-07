"""Celery application configured for transcription + rendering queues."""

from celery import Celery

from app.core.config import settings

celery_app = Celery(
    "opencaptions",
    broker=settings.redis_url,
    backend=settings.redis_url,
    include=["app.tasks.transcribe", "app.tasks.render"],
)

celery_app.conf.update(
    # Two queues, so a backlog of renders never starves transcription.
    task_routes={
        "app.tasks.transcribe.transcribe_video": {"queue": "transcription"},
        "app.tasks.render.render_video": {"queue": "rendering"},
    },
    task_default_queue="transcription",
    # Reliability: workers acknowledge tasks AFTER completion to survive crashes.
    task_acks_late=True,
    task_reject_on_worker_lost=True,
    # Don't prefetch into limited GPU VRAM.
    worker_prefetch_multiplier=1,
    # Serialization
    task_serializer="json",
    result_serializer="json",
    accept_content=["json"],
    timezone="UTC",
    enable_utc=True,
    # Time limits, render and transcribe can take minutes.
    task_soft_time_limit=900,  # 15 min soft
    task_time_limit=1200,  # 20 min hard
    # Result backend
    result_expires=3600,
    result_extended=True,
)
