"""Application configuration via pydantic-settings."""

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Defaults that run when nothing overrides them, which is the normal case.

    There is no env file: a setting is changed by naming it in the
    ``environment:`` block of the services that read it.
    """

    model_config = SettingsConfigDict(
        extra="ignore",
        case_sensitive=False,
    )

    # ----- Database -----
    postgres_user: str = "opencaptions"
    postgres_password: str = "opencaptions"
    postgres_db: str = "opencaptions"
    postgres_host: str = "postgres"
    postgres_port: int = 5432

    # ----- Redis -----
    redis_url: str = "redis://redis:6379/0"

    # ----- Storage -----
    # Empty endpoint means real AWS S3; any URL means an S3-compatible store.
    s3_endpoint_url: str = "http://garage:3900"
    s3_access_key: str = "GK0pencaptions00000000000000000dev"
    s3_secret_key: str = "opencaptions-dev-secret-key-change-me-for-any-exposed-host"
    s3_bucket: str = "opencaptions"
    s3_region: str = "us-east-1"

    # ----- Transcription -----
    transcription_provider: str = "local"  # 'local', 'openai' or 'opencaptions'
    whisper_model: str = "large-v3-turbo"
    whisper_device: str = "auto"  # 'auto', 'cpu', 'cuda', 'cuda:0', etc.
    whisper_compute_type: str = "int8"
    openai_api_key: str = ""

    # Another OpenCaptions backend to transcribe on (provider 'opencaptions'): its
    # public origin and an API key minted there. A private address is refused unless
    # its host is in SSRF_ALLOWED_HOSTS, as for any other URL this server is asked to reach.
    transcription_remote_url: str = ""
    transcription_remote_key: str = ""
    # What this instance offers to others through POST /transcriptions: how long a
    # finished transcript is kept for its client to fetch, and how many jobs one
    # user may have running at once.
    instance_name: str = "OpenCaptions"
    transcription_result_ttl_h: int = 24
    transcription_max_concurrent: int = 2
    # The address clients outside the stack reach this instance at, for pairing links;
    # empty means the address the request came in on.
    public_url: str = ""

    # Voice-activity filtering drops non-speech before decoding, which keeps
    # Whisper from inventing words over music. It can also drop real speech under
    # a loud bed, so it is switchable, and its threshold tunable: lower keeps more
    # audio. Set WHISPER_VAD_FILTER=false to decode everything.
    whisper_vad_filter: bool = True
    whisper_vad_threshold: float = 0.5
    # A window whose no-speech probability exceeds this, and whose average log
    # probability is below the log-prob floor, is treated as silence and skipped.
    # Raising it makes the decoder keep more marginal audio.
    whisper_no_speech_threshold: float = 0.6

    # ----- Entitlements -----
    # Policy name registered in app.services.entitlements; 'unlimited' never denies.
    entitlement_provider: str = "unlimited"

    # ----- Limits -----
    max_upload_size_mb: int = 2048
    max_video_duration_s: int = 3600

    # ----- SSRF protection (video URL fetch) -----
    # Comma-separated hosts allowed even when they resolve to private addresses,
    # for pulling from a LAN NAS: "192.168.1.50,my-nas.local".
    ssrf_allowed_hosts: str = ""

    # ----- Auth / sessions -----
    registration_enabled: bool = True

    # Self-hosted (False) or run for other people (True). See docs/DESIGN.md.
    hosted_mode: bool = False

    # False so one code path serves http://localhost; authentication never
    # depends on it.
    session_cookie_secure: bool = False

    # ----- Login / registration throttling -----
    # Per-identifier credential-guessing budget; see app.core.throttle.
    auth_throttle_max_attempts: int = 5
    auth_throttle_window_s: int = 15 * 60

    # Separate per-source ceiling on Argon2id work. Loose on purpose so a whole
    # office behind one NAT address is never affected.
    auth_ip_throttle_max_attempts: int = 50
    auth_ip_throttle_window_s: int = 5 * 60

    # ----- Email (SMTP), optional -----
    # Setting a host is what turns password reset on. Left empty the feature is
    # absent rather than broken, and recovery is scripts/reset_password.py.
    smtp_host: str = ""
    smtp_port: int = 587
    smtp_username: str = ""
    smtp_password: str = ""
    smtp_from: str = ""  # falls back to smtp_username
    smtp_use_tls: bool = True

    # Used to build reset links; falls back to the first CORS origin.
    public_base_url: str = ""

    # ----- CORS -----
    cors_origins: str = "http://localhost:5173"

    # ----- Rendering -----
    engine_url: str = "http://engine:3001"
    # Where renders run. 'local' posts to the engine above, the only backend the
    # core ships; see app.services.render_backend for registering another.
    render_backend: str = "local"

    # ----- Logging -----
    log_level: str = "INFO"

    @property
    def database_url(self) -> str:
        """SQLAlchemy async DSN for asyncpg."""
        return (
            f"postgresql+asyncpg://{self.postgres_user}:{self.postgres_password}"
            f"@{self.postgres_host}:{self.postgres_port}/{self.postgres_db}"
        )

    @property
    def database_url_sync(self) -> str:
        """Sync DSN for alembic."""
        return (
            f"postgresql+psycopg://{self.postgres_user}:{self.postgres_password}"
            f"@{self.postgres_host}:{self.postgres_port}/{self.postgres_db}"
        )

    @property
    def smtp_configured(self) -> bool:
        """Whether the password-reset flow is available at all."""
        return bool(self.smtp_host.strip())

    @property
    def reset_link_base_url(self) -> str:
        """Base URL for reset links, without a trailing slash."""
        base = self.public_base_url.strip()
        if not base:
            base = next((o.strip() for o in self.cors_origins.split(",") if o.strip()), "")
        return base.rstrip("/")


settings = Settings()
