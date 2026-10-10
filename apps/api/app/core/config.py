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

    # Voice-activity filtering is off: it decides what is speech with a model that
    # takes shouting or speech over loud music for non-speech, and what it drops is
    # never decoded, so whole lines go missing (on a test film it lost five of six
    # lines that decoding everything found, whatever the threshold). Decoding
    # everything costs more CPU on content with long silences; turn the filter on
    # (WHISPER_VAD_FILTER=true) for talking-head recordings where that matters.
    whisper_vad_filter: bool = False
    whisper_vad_threshold: float = 0.5
    # A window whose no-speech probability exceeds this, and whose average log
    # probability is below the log-prob floor, is treated as silence and skipped.
    # Raising it makes the decoder keep more marginal audio.
    whisper_no_speech_threshold: float = 0.6
    # With word timings on, Whisper looping over silence or music is cut where a
    # silence this long (seconds) follows a suspect segment. Without the voice filter
    # this is what keeps invented text out of the quiet stretches.
    whisper_hallucination_silence_s: float = 2.0

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
    engine_token: str = "opencaptions-dev-engine-token-change-me-for-any-exposed-host"
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

    # Credentials the shipped defaults name: public in this repository, so not secrets.
    _DEV_CREDENTIALS = ("postgres_password", "s3_secret_key", "engine_token")

    @property
    def default_credentials_in_use(self) -> list[str]:
        """Which of the development credentials are still the shipped ones, by setting name."""
        return [
            name
            for name in self._DEV_CREDENTIALS
            if getattr(self, name) == type(self).model_fields[name].default
        ]

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
