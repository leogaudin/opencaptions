# OpenCaptions API

Python 3.14 + FastAPI backend.

## Structure

```
app/
├── main.py              # FastAPI app factory + /api/v1/health
├── core/
│   ├── config.py        # pydantic-settings env config
│   ├── celery_app.py    # Celery factory with two queues
│   └── db.py            # async SQLAlchemy engine + session
├── api/                 # REST routers
├── models/              # SQLAlchemy 2 models + Pydantic schemas
├── services/            # business logic
├── storage/             # boto3 S3-compatible wrapper
├── transcription/       # TranscriptionProvider ABC + impls
├── tasks/               # Celery tasks + shared TaskContext
└── migrations/          # alembic
```

## Local dev (outside Docker)

```bash
uv sync --all-extras --dev
uv run uvicorn app.main:app --reload
```

## Tests

```bash
uv run pytest
```

## Migrations

```bash
# Auto-generate from model diffs:
uv run alembic revision --autogenerate -m "add foo table"
# Apply:
uv run alembic upgrade head
```
