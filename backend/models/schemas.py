from pydantic import BaseModel, Field, field_validator
from enum import Enum
from typing import Any, Optional, List
import base64
import binascii
import json
import re


class LogLevel(str, Enum):
    """cloudflared --loglevel values. cloudflared rejects anything else."""
    debug = "debug"
    info = "info"
    warn = "warn"
    error = "error"
    fatal = "fatal"


# Values that settings.json from 1.1.0 and older may hold. They were offered by
# the GUI but cloudflared refuses them, so they map to the nearest real level.
LEGACY_LOG_LEVELS = {"trace": "debug", "notice": "info", "warning": "warn"}


def normalize_log_level(value: Any) -> Any:
    if isinstance(value, str):
        return LEGACY_LOG_LEVELS.get(value, value)
    return value


# Same allow-list as the HA add-on's run_parameters schema. Credential and
# metrics flags are not on it: the token file and the metrics address are
# pinned by this app (the healthcheck depends on the metrics address).
RUN_PARAMETER_RE = re.compile(
    r"^(--edge-bind-address|--edge-ip-version|--grace-period|--ha-connections"
    r"|--logfile|--loglevel|--pidfile|--protocol|--region|--retries|--tag)=.*$"
)
RUN_PARAMETER_ERROR = (
    "Not an allowed run parameter. Allowed flags: --edge-bind-address, --edge-ip-version, "
    "--grace-period, --ha-connections, --logfile, --loglevel, --pidfile, --protocol, "
    "--region, --retries, --tag (format: --flag=value, one per line)."
)


def split_legacy_run_parameters(value: str) -> list[str]:
    """1.1.0 stored run_parameters as one string ("--protocol quic --tag x").
    Turn it into the list form, joining "--flag value" pairs as --flag=value."""
    words = value.split()
    params: list[str] = []
    i = 0
    while i < len(words):
        word = words[i]
        if "=" not in word and i + 1 < len(words) and not words[i + 1].startswith("--"):
            params.append(f"{word}={words[i + 1]}")
            i += 2
        else:
            params.append(word)
            i += 1
    return params


def validate_run_parameters(value: Any) -> list[str]:
    if value is None:
        return []
    if isinstance(value, str):
        value = split_legacy_run_parameters(value)
    cleaned = []
    for param in value:
        param = str(param).strip()
        if not param:
            continue
        if not RUN_PARAMETER_RE.match(param):
            raise ValueError(RUN_PARAMETER_ERROR)
        cleaned.append(param)
    return cleaned


TOKEN_RE = re.compile(r"eyJ[A-Za-z0-9+/=_-]+")
TOKEN_ERROR = (
    "This does not look like a valid Cloudflare tunnel token. Copy the whole token that "
    "starts with eyJ from the Cloudflare Zero Trust dashboard (you can also paste the "
    "cloudflared service install command as it is)."
)


def normalize_tunnel_token(raw: str) -> str:
    """Extract and check a tunnel token from what the user pasted.

    People paste the whole install command (``cloudflared service install
    eyJ...``) or add whitespace; a broken token makes cloudflared exit at start.
    A tunnel token is base64 JSON with the account, tunnel and secret fields.
    """
    match = TOKEN_RE.search(raw)
    if not match:
        raise ValueError(TOKEN_ERROR)
    candidate = match.group(0)
    try:
        padded = candidate + "=" * (-len(candidate) % 4)
        data = json.loads(base64.b64decode(padded))
    except (binascii.Error, ValueError):
        raise ValueError(TOKEN_ERROR) from None
    if not isinstance(data, dict) or not {"a", "t", "s"} <= set(data):
        raise ValueError(TOKEN_ERROR)
    return candidate


class TunnelMode(str, Enum):
    local = "local"
    token = "token"


class AdditionalHost(BaseModel):
    hostname: str = Field(description="Public hostname for this route")
    service: str = Field(description="Local service URL, e.g. http://localhost:8080")
    disableChunkedEncoding: bool = Field(
        default=False,
        description="Disable chunked transfer encoding for this host",
    )

    @field_validator("hostname")
    @classmethod
    def validate_hostname(cls, v: str) -> str:
        v = v.strip()
        if not v:
            raise ValueError("Hostname cannot be empty")
        return v

    @field_validator("service")
    @classmethod
    def validate_service(cls, v: str) -> str:
        v = v.strip()
        if not v:
            raise ValueError("Service URL cannot be empty")
        return v


VALID_HOSTNAME_RE = re.compile(
    r"^(([a-z0-9]|[a-z0-9][a-z0-9\-]*[a-z0-9])\.)*"
    r"([a-z0-9]|[a-z0-9][a-z0-9\-]*[a-z0-9])$"
)


class Route(BaseModel):
    hostname: str
    service: str
    disableChunkedEncoding: bool = False

    @field_validator("hostname")
    @classmethod
    def _valid_hostname(cls, v: str) -> str:
        v = v.strip().lower()
        if not v:
            raise ValueError("hostname cannot be empty")
        if not VALID_HOSTNAME_RE.match(v):
            raise ValueError("hostname must be a bare host name such as app.example.com, "
                             "without a scheme (http://), a port (:8123) or a path")
        return v

    @field_validator("service")
    @classmethod
    def _valid_service(cls, v: str) -> str:
        v = v.strip()
        if not v:
            raise ValueError("service cannot be empty")
        return v


class TunnelConfigRead(BaseModel):
    """Response model for GET /api/config — token is always masked."""

    mode: TunnelMode = TunnelMode.local
    tunnel_name: str = ""
    routes: List[Route] = []
    catch_all_service: str = ""
    post_quantum: bool = False
    log_level: LogLevel = LogLevel.info
    run_parameters: List[str] = []
    no_tls_verify: bool = True
    tunnel_token_masked: str = Field(default="", description="Masked token value")
    tunnel_token_set: bool = False
    tunnel_token_managed_by_paas: bool = False

    @field_validator("log_level", mode="before")
    @classmethod
    def _legacy_log_level(cls, v: Any) -> Any:
        return normalize_log_level(v)

    @field_validator("run_parameters", mode="before")
    @classmethod
    def _legacy_run_parameters(cls, v: Any) -> list[str]:
        # Reading must not fail on a stored value that is no longer allowed.
        if isinstance(v, str):
            return split_legacy_run_parameters(v)
        return v or []


class TunnelConfigWrite(BaseModel):
    """Request model for PUT /api/config.

    tunnel_token: omitted or null keeps the stored token, "" removes it, any
    other value replaces it (after normalize_tunnel_token).
    """

    tunnel_token: Optional[str] = Field(
        None, description="null keeps the stored token, \"\" removes it, a value replaces it."
    )
    mode: TunnelMode = TunnelMode.local
    tunnel_name: str = ""
    routes: List[Route] = []
    catch_all_service: str = ""
    post_quantum: bool = False
    log_level: LogLevel = LogLevel.info
    run_parameters: List[str] = []
    no_tls_verify: bool = True

    @field_validator("catch_all_service")
    @classmethod
    def validate_catch_all_service(cls, v: str) -> str:
        return v.strip()

    @field_validator("tunnel_token")
    @classmethod
    def _tunnel_token(cls, v: Optional[str]) -> Optional[str]:
        if v is None:
            return None
        v = v.strip()
        if not v:
            return ""
        return normalize_tunnel_token(v)

    @field_validator("log_level", mode="before")
    @classmethod
    def _legacy_log_level(cls, v: Any) -> Any:
        return normalize_log_level(v)

    @field_validator("run_parameters", mode="before")
    @classmethod
    def _run_parameters(cls, v: Any) -> list[str]:
        return validate_run_parameters(v)


class SetupState(BaseModel):
    has_cert: bool
    has_tunnel: bool
    tunnel_uuid: Optional[str] = None
    mode: TunnelMode = TunnelMode.local


class ContainerStatus(str, Enum):
    running = "running"
    stopped = "stopped"
    exited = "exited"
    created = "created"
    paused = "paused"
    restarting = "restarting"
    removing = "removing"
    dead = "dead"
    not_found = "not_found"
    unknown = "unknown"


class TunnelStatusResponse(BaseModel):
    status: ContainerStatus
    container_id: Optional[str] = None
    image: Optional[str] = None
    started_at: Optional[str] = None
    uptime_seconds: Optional[int] = None
    restart_count: int = 0
    exit_code: Optional[int] = None


class ActionResponse(BaseModel):
    success: bool
    message: str
    container_id: Optional[str] = None


class TunnelStatus(BaseModel):
    status: str = "stopped"  # "running" | "starting" | "stopped"
    ready_connections: int = 0
    metrics_reachable: bool = False


class HealthResponse(BaseModel):
    status: str = "ok"
    version: str = ""
    process_running: bool = False
    stopped_by_operator: bool = False
    tunnel: TunnelStatus = Field(default_factory=TunnelStatus)
    credentials_error: Optional[str] = None
