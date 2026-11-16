"""Start, restart and stop cloudflared from the *current* settings.

Every start builds a fresh argv (ProcessManager.restart() reuses the previous
one, so a saved change would otherwise not take effect). In local mode the
ingress config is regenerated from settings.json and validated first, which is
what the HA add-on's prepare step does on every start.

On a host where the tunnel may be the only remote path (SSH), two things are
deliberately conservative:

- DNS routes are created only for hostnames that have not been routed yet, so
  a start never depends on the Cloudflare API being reachable.
- config.json is regenerated only when settings.json has routes or a
  catch-all. A host migrated from an older layout whose ingress lives only in
  config.json keeps it.

A GUI Stop is deliberately temporary: the healthcheck brings a configured
tunnel back within about two minutes (README, "Known behaviour"), so a
mis-click cannot lock a host out of its only remote path. An operator who
wants it to stay down creates /data/.tunnel_stopped by hand; the healthcheck
and the boot-time autostart both honour it, and Start removes it.
"""
import json
from pathlib import Path

from . import credentials
from .config_builder import build_ingress_config, write_config_json
from .process_manager import build_run_args, effective_metrics_addr

STOPPED_MARKER = ".tunnel_stopped"

# Last credential-permission failure, shown by GET /api/health. None when the
# last check passed.
credentials_error: "str | None" = None


class TunnelStartError(Exception):
    """Cannot start the tunnel with the current settings."""

    def __init__(self, status: int, message: str):
        super().__init__(message)
        self.status = status
        self.message = message


def check_credentials(data_dir: Path) -> None:
    """credentials.protect(), remembering the outcome for /api/health."""
    global credentials_error
    try:
        credentials.protect(data_dir)
    except credentials.CredentialError as exc:
        credentials_error = str(exc)
        raise TunnelStartError(409, f"The credential file check failed, so the tunnel will not start: {exc}") from exc
    credentials_error = None


def stopped_by_operator(data_dir: Path) -> bool:
    return (data_dir / STOPPED_MARKER).exists()


def _tunnel_uuid(data_dir: Path) -> str:
    tunnel_file = data_dir / "tunnel.json"
    if not tunnel_file.exists():
        raise TunnelStartError(409, "No tunnel has been created yet. Log in to Cloudflare and create a "
                                    "tunnel on the Setup page first.")
    try:
        return json.loads(tunnel_file.read_text())["TunnelID"]
    except (ValueError, KeyError) as exc:
        raise TunnelStartError(409, "tunnel.json is not valid. Create the tunnel again on the Setup page.") from exc


async def write_ingress(cfg: dict, cli, data_dir: Path, route_dns: bool = True) -> dict:
    """Regenerate and validate config.json, then route DNS for new hostnames.

    Returns the (possibly updated) cfg; the caller persists it so routed
    hostnames are remembered.
    """
    uuid = _tunnel_uuid(data_dir)
    config_path = data_dir / "config.json"
    if not cfg.get("routes") and not cfg.get("catch_all_service") and config_path.exists():
        return cfg
    config = build_ingress_config(
        tunnel_uuid=uuid,
        credentials_file=str(data_dir / "tunnel.json"),
        routes=cfg.get("routes", []),
        catch_all_service=cfg.get("catch_all_service") or None,
        no_tls_verify=cfg.get("no_tls_verify", True),
    )
    write_config_json(config, config_path)
    ok, output = await cli.ingress_validate(str(config_path))
    if not ok:
        raise TunnelStartError(422, f"Ingress validation failed: {output}")
    if route_dns:
        routed = set(cfg.get("dns_routed") or [])
        for route in cfg.get("routes", []):
            hostname = route["hostname"]
            if hostname in routed:
                continue
            try:
                await cli.route_dns(uuid, hostname)
            except RuntimeError as exc:
                raise TunnelStartError(502, f"Could not create the DNS route for {hostname}: {exc}") from exc
            routed.add(hostname)
        cfg = {**cfg, "dns_routed": sorted(routed)}
    return cfg


def build_args(cfg: dict, token_store, data_dir: Path) -> list[str]:
    common = dict(
        post_quantum=cfg.get("post_quantum", False),
        log_level=cfg.get("log_level", "info"),
        metrics=effective_metrics_addr(),
        run_parameters=cfg.get("run_parameters") or [],
    )
    if cfg.get("mode") == "token":
        if not token_store.has():
            raise TunnelStartError(409, "Token mode has no tunnel token yet. Paste one on the Config page.")
        return build_run_args(mode="token", token_file=str(token_store.path), **common)
    if not (data_dir / "cert.pem").exists():
        raise TunnelStartError(409, "Not logged in to Cloudflare yet. "
                                    "Complete the authorization on the Setup page first.")
    _tunnel_uuid(data_dir)
    if not (data_dir / "config.json").exists():
        raise TunnelStartError(409, "No routes are configured yet. Add a route on the Config or Setup page.")
    return build_run_args(
        mode="local",
        origincert=str(data_dir / "cert.pem"),
        config=str(data_dir / "config.json"),
        tunnel_name=cfg.get("tunnel_name", ""),
        **common,
    )


async def apply(pm, config_mgr, token_store, cli, data_dir: Path,
                new_cfg: "dict | None" = None) -> list[str]:
    """(Re)start cloudflared from the current settings.

    With new_cfg (the setup wizard), the settings are saved only after their
    ingress config validated and their DNS routes were created.
    """
    check_credentials(data_dir)
    cfg = new_cfg if new_cfg is not None else await config_mgr.load()
    if cfg.get("mode") != "token":
        cfg = await write_ingress(cfg, cli, data_dir)
    if new_cfg is not None or cfg.get("mode") != "token":
        cfg = await config_mgr.save(cfg)
    args = build_args(cfg, token_store, data_dir)
    (data_dir / STOPPED_MARKER).unlink(missing_ok=True)
    await pm.start(args)  # start() stops a running process first
    return args


async def stop(pm) -> None:
    await pm.stop()
