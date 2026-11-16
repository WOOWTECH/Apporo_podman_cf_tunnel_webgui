# Changelog

## 1.0.0 — Apporo fork of Woow_cloudflare_tunnel_webgui 1.2.1

First release of Apporo CF Tunnel Web, forked from
[WOOWTECH/Woow_cloudflare_tunnel_webgui](https://github.com/WOOWTECH/Woow_cloudflare_tunnel_webgui)
1.2.1 (commit `e6226c5`). Every upstream feature is kept. The changes:

**Platform**
- The platform link connects to the Apporo platform (Security Access on
  `https://www.apporo.ai`) instead of WOOW PaaS (`https://aiot.woowtech.io`). Portal links
  open `https://www.apporo.ai/woow#/...`, and device sign-in happens on the page the platform
  returns (`https://www.apporo.ai/device`).
- The device is labelled `Apporo CF Tunnel Web (Podman)` on the platform (upstream:
  `Woow Cloudflared (Podman)`).
- The platform contract is unchanged: the OAuth client `woow-ha-smart-home` (the Apporo
  platform uses the same id), the scopes
  `workspace:read security-access:read security-access:tunnel`, the device-code grant, and
  every `/api` and `/oauth2` path and payload key.

**Interface**
- The UI is in English throughout; upstream mixed Traditional Chinese and English. The
  platform page is now **Apporo Link** (upstream: "PaaS 連結").
- Apporo branding: gold `#8B6B24` as the primary colour, text `#212121`, a warm `#fbf8f2`
  background and the "Apporo" wordmark.

**Deployment**
- Every `woow-cf-tunnel` name is now `apporo-cf-tunnel`: the unit `apporo-cf-tunnel.service`,
  the container `apporo-cf-tunnel`, the Quadlet files `apporo-cf-tunnel.container`,
  `apporo-cf-tunnel-data.volume` and the optional `apporo-cf-tunnel-auth.container`, the env
  file `~/.config/apporo-cf-tunnel/apporo-cf-tunnel.env`, the state directory
  `~/.local/state/apporo-cf-tunnel`, the backups in `~/backups/apporo-cf-tunnel`, and the image
  `localhost/apporo-cf-tunnel:<VERSION>-<sha12>`.
- New defaults, so that the fork can run on the same host as WOOW's GUI: the data volume
  `apporo_cf_data` (upstream: `cf_data`), the GUI/API on `127.0.0.1:18100` (18000), cloudflared
  metrics on `127.0.0.1:20341` (20241), and the optional Basic-auth proxy on `127.0.0.1:8988`
  (8888).
- The CSRF cookie is `apporo_csrftoken` (upstream: `csrftoken`). Browsers share cookies
  between the ports of one host, so with one name, whichever of the two GUIs was opened
  second answered 403 to every change.
- The scripts refuse values that point at WOOW's install, before they change anything: a WOOW
  `--stage-dir` (and `install.sh --stage` replaces only a directory that holds an earlier
  stage), one of WOOW's backups in `restore.sh`, a WOOW directory for `backup.sh --dir`,
  WOOW's upgrade runs or state directory in `upgrade.sh`, and WOOW's env file as `ENV_FILE`
  in `auth-passwd.sh`. A directory of this app that is a symlink into one of WOOW's (config,
  state, backups) is refused by every script, and paths are checked with symlinks resolved.
- WOOW's default ports (18000, 20241, 8888) are refused for `UVICORN_PORT`, `CF_METRICS_ADDR`
  and `AUTH_LISTEN` even when nothing holds them: with WOOW's GUI stopped, the busy-port check
  could not see them, and WOOW's GUI and connector would then fail to bind on their next start.
- The data volume is checked by what podman says about it before `install.sh`, `backup.sh`,
  `restore.sh` or `uninstall.sh --purge` uses it: a volume labelled for another app, created by
  compose, or mounted by any container other than `apporo-cf-tunnel` is refused whatever its
  name. Compose's `<project>_cf_data` names are refused by name too. `restore.sh --replace`
  re-creates the volume with this app's `io.woowtech.app` label.
- The unit and container the scripts act on are fixed (`apporo-cf-tunnel.service`,
  `apporo-cf-tunnel`), no longer taken from `NEW_UNIT` / `NEW_CONTAINER` in the environment.
  `upgrade.sh swap`, its watchdog and `--rollback` refuse a `run.env` that names any other unit
  or container, and `uninstall.sh` counts edge connections at the installed unit's metrics
  address rather than an inherited `METRICS_ADDR`.
- `install.sh` refuses a port that another process holds with `--stage` and while the tunnel
  runs, not only while the tunnel is stopped. `upgrade.sh` takes its baseline, and checks a
  rollback, on the ports the running tunnel was installed with, so a port change is gated on
  the edge connections.
- `tests/smoke.sh` checks the command line of this app's cloudflared only. Another connector
  on the host, such as WOOW's older `cf-tunnel-webgui`, may pass `--token`; that is reported.

**Removed**
- `scripts/migrate-legacy.sh`, and the legacy guards and paths that existed only for it. The
  deployments it migrated (the `cf-tunnel-webgui` container and units, the `cf_data` volume,
  the compose project) are WOOW's. The Apporo scripts never detect, stop, adopt, migrate or
  remove any WOOW resource: `woow-*`, `cf-tunnel-webgui*`, `cf_data`,
  `~/.config/woow-cf-tunnel`.

**Unchanged**
- The vendored files listed in `scripts/lib/quadlet-lib.manifest`, including
  `scripts/lib/quadlet-lib.sh` 1.8.0, its versions ledger and `.github/workflows/quadlet-ci.yml`.
- cloudflared 2026.6.1, pinned by version and SHA256; the liveness chain; the credential-file
  guard; the token in `/data/.tunnel_token` (mode 0600, passed with `--token-file`).

**Version**
- Numbering starts again at 1.0.0 (`VERSION` and the backend `__version__`).

---

## Upstream history (WOOWTECH/Woow_cloudflare_tunnel_webgui)

The entries below are upstream's changelog up to the fork point. Only their heading level was
changed. The names in them (`woow-cf-tunnel`, `cf_data`, ports 18000 / 20241 / 8888,
WOOW PaaS, `migrate-legacy.sh`) describe upstream, not this fork.

### 1.2.1 — PaaS routes without Access seats

- A subscription with zero Access seats can now link when its routes are explicitly public. Each protected route still requires an Access seat, a login method and a specific email allow policy.
- Review and connection status distinguish public routes from Access-protected routes. Both the UI and backend require explicit confirmation before claiming a service with public hostnames.
- Public routes can be claimed while PaaS keeps publication pending; the origin remains closed until the connector is live and PaaS finishes publishing. Missing hostnames, origins, or ambiguous protection state still block the claim.
- Existing PaaS bindings, token files, Quadlet units and data volumes require no migration. This release preserves the connector and its remote binding during the image upgrade.

### 1.2.0 — feature parity with the Woow Cloudflared HA add-on (1.1.1)

**Added**
- **WOOW PaaS link** (`/paas` page, `/api/paas/*`). It uses the same flow and PaaS API as the
  add-on: device authorization, workspace and service selection, and a per-route Access
  review that refuses unprotected routes, `everyone` / bypass policies, routes with no login
  method, zero-seat plans, unpaid subscriptions and binding conflicts. It also covers the
  claim, anonymous external checks of the public hostnames, disconnect and OAuth revocation.
  - The claimed token goes to `/data/.tunnel_token` (0600) and cloudflared starts in token
    mode at once. A failed start rolls back and releases the new binding.
  - On disconnect, the connector is stopped and confirmed gone (process exited, `/ready`
    closed) before the remote binding is released, in the same request. The add-on has to
    wait for a restart instead. Disconnect also clears the local routes, as the add-on does.
  - A route that is still `access_publish_pending` does not block the claim when its own
    protection is complete: an email allow-list, a login method, nothing broad, nothing lost
    and no unresolved IdP. After an authorization change, PaaS re-publishes Access only once a
    live connector is present, and it keeps the origin closed as `http_status:503` until then.
    Waiting for pending to clear before connecting was a deadlock for any newly protected
    route. The page shows such a route as awaiting publication. The add-on 1.1.1 has the same
    gate.
  - The device is labelled `Woow Cloudflared (Podman)`. The OAuth client is the add-on's
    (`woow-ha-smart-home`); override it with `PAAS_CLIENT_ID`.
- **Edge-connection status.** `GET /api/health` returns `version`, `tunnel.status`
  (running / starting / stopped), `tunnel.ready_connections`, `stopped_by_operator` and
  `credentials_error`. The status comes from cloudflared's `/ready`, the same signal the
  healthcheck reads. The Dashboard and the nav-bar status dot show it.
- `GET /api/logs`: a snapshot of the buffered cloudflared output.
- `PUT /api/config?restart=true` (Config "Save & Apply") saves the settings and applies them.

**Fixed**
- Restart and "Save & Restart" re-ran the previous cloudflared argv, so saved changes
  (post-quantum, log level, routes) did not take effect. Every start now builds the argv from
  the current settings.
- In local mode, routes edited on the Config page were never written to `config.json`; only
  the wizard did that. A start now regenerates and validates the ingress config from
  `settings.json`. DNS routes are created only for hostnames not routed before, so a start
  does not depend on the Cloudflare API. A host whose ingress lives only in `config.json`
  (no routes in `settings.json`) keeps it untouched.
- `run_parameters` was stored but never passed to cloudflared.
- The log-level list offered `trace`, `notice` and `warning`, which cloudflared rejects at
  start. Only `debug`, `info`, `warn`, `error` and `fatal` remain.
- The token file was written and then chmod'ed. It is now created 0600 atomically.

**Security**
- At startup, at every start and after Cloudflare login or tunnel creation, `cert.pem`,
  `tunnel.json`, `.tunnel_token`, `paas-link.json` and `.csrf_secret` are re-owned and set to
  0600 without reading them. A symlink, a hardlink or a non-regular file blocks the start,
  and the Dashboard shows the reason. These are the add-on 1.1.1 credential-guard rules. The
  process umask is 077.
- 422 responses no longer echo the submitted value. FastAPI's default response returned the
  pasted tunnel token.
- Log lines are redacted before they are buffered or streamed: `--token`, `TunnelSecret`,
  `tunnel_token` and bare `eyJ…` tokens.
- `run_parameters` is limited to the add-on's allow-list (`--edge-bind-address`,
  `--edge-ip-version`, `--grace-period`, `--ha-connections`, `--logfile`, `--loglevel`,
  `--pidfile`, `--protocol`, `--region`, `--retries`, `--tag`). The token, token-file and
  metrics flags cannot be overridden.
- Pasted tokens are normalized: a whole `cloudflared service install eyJ…` command is
  accepted, and a value that is not a tunnel token is refused.

**Behaviour changes and migration**
- `PUT /api/config` `tunnel_token`: omitted or `null` keeps the stored token, `""` removes
  it, and a value replaces it. Token mode without a token is refused with 422. While a PaaS
  link is active, the token and the mode are locked; disconnect on the PaaS page first.
- `run_parameters` is now a list of `--flag=value` strings. The 1.1.0 string form in
  `settings.json` is converted on read, and `--flag value` pairs are joined.
- Stored log levels `trace`, `notice` and `warning` read as `debug`, `info` and `warn`.
- `POST /api/tunnel/start` and `restart` answer 409 with the reason when the tunnel is not
  configured, instead of starting a cloudflared that exits.
- A GUI Stop stays temporary, as in 1.1.0: the healthcheck brings a configured tunnel back
  within about two minutes. A hand-made `/data/.tunnel_stopped` now also stops the boot-time
  autostart, not only the healthcheck, and Start removes it.
- HA-only add-on options have no counterpart here. Use a route for `external_hostname`, and
  a catch-all such as `http://localhost:80` for `nginx_proxy_manager`.

**Shared library**
- The vendored `scripts/lib/quadlet-lib.sh` is now **1.8.0**, not 1.7.0. Two different files
  were released as 1.7.0: the copy vendored here, and the canonical one that had since gained
  `ql_require_healthcheck_timers`, `ql_stop_healthcheck_timer` and an *active*
  `ql_wait_container_healthy` (it runs `podman healthcheck run` itself instead of waiting on
  `.State.Health.Status`, which never moves off `starting` on woowtechopenclaw). That content
  is re-released as 1.8.0; **1.7.0 is withdrawn** and every copy claiming it is now refused.
  The call sites here already passed `QL_HEALTH_ACTIVE=1` explicitly, so the behaviour of this
  package's scripts is unchanged - what changes is that the version string is true again.
- New `scripts/lib/quadlet-lib.versions` (the canonical ledger of released
  `(version, sha256)` pairs) and `tests/lib-version.sh`, which CI now runs. `sha256sum -c` on
  `quadlet-lib.manifest` only ever proved "not edited since it was copied here" - the manifest
  is written by this repo - so it stayed green through the whole collision.

### 1.1.0 — Quadlet + systemd as the primary deployment

**Deployment**
- Rootless Podman Quadlet units under user systemd: `woow-cf-tunnel.container` (host
  network, GUI pinned to 127.0.0.1) and `woow-cf-tunnel-data.volume`, which adopts the
  existing data volume in place. Optional `woow-cf-tunnel-auth.container` adds an nginx
  Basic-auth front door.
- `scripts/`: `install.sh`, `upgrade.sh`, `uninstall.sh`, `backup.sh`, `restore.sh`,
  `migrate-legacy.sh`, `auth-passwd.sh`. Per-host values are rendered into the units at
  install time from `~/.config/woow-cf-tunnel/woow-cf-tunnel.env`.
- The image is built locally as `localhost/woow-cf-tunnel:<VERSION>-<git-sha12>` and the
  unit pins it with `Pull=never`. Publishing to GHCR is future work.
- Upgrades and legacy migrations run in a detached `systemd-run --user` watchdog that
  gates on edge connections, the ingress config version, the hostname map, podman health
  and every public hostname's HTTP code, soaks for 10 minutes, and rolls back on its own.

**Liveness**
- New container healthcheck (`/usr/local/bin/cf-webui-healthcheck`): the backend **and**
  cloudflared `/ready`. With `HealthOnFailure=kill` + `Restart=always`, a dead connector
  now recovers by itself; before this it stayed down while `/api/health` returned 200.

**Security**
- The tunnel token is passed to cloudflared with `--token-file`, so it no longer appears
  in any process argv (`ps`, `podman top`, `systemctl --user status`).
- cloudflared is pinned by version **and** SHA256; 2026.8.0 and 2026.8.1, which Cloudflare
  marked "Do not use", are refused at build time.
- The image's default command binds 127.0.0.1 instead of 0.0.0.0.
- Docs no longer claim the token is a Podman secret that never touches disk: it is a 0600
  file in the data volume, and the GUI has no login, so exposure rules are spelled out.

**Breaking**
- `docker-compose.yml` is gone; the last commit that ships it is tagged `compose-final`.
- `build_run_args()` no longer takes `token=`; callers pass `token_file=`.

### 1.0.0
- Single-container FastAPI + Vue GUI that supervises cloudflared directly, with token and
  local-managed modes, the setup wizard, live logs and the compose deployment.
