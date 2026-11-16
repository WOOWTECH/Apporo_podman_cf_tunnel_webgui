#!/usr/bin/env bash
# scripts/install.sh: install apporo-cf-tunnel (Apporo CF Tunnel Web) as rootless Quadlet
# units (podman 4.9.3, systemd --user, linger). Idempotent: an unchanged re-run changes nothing.
#
#   scripts/install.sh [--with-auth | --without-auth] [--image REF] [--allow-dirty]
#                      [--stage [--stage-dir DIR]] [--no-start] [--dry-run]
#
#   --with-auth     also install the optional Basic-auth proxy. Needs a valid htpasswd
#                   (scripts/auth-passwd.sh USER). Once installed it stays selected.
#   --without-auth  remove the auth proxy
#   --image REF     use an existing local build (localhost/apporo-cf-tunnel:<tag>) instead
#                   of building this checkout
#   --allow-dirty   build a checkout with uncommitted changes (tag suffix -dirty)
#   --stage         build, render and dry-run into ~/.local/state/apporo-cf-tunnel/staged
#                   (or --stage-dir, which it replaces) for upgrade.sh; no systemd changes
#   --no-start      install the files and daemon-reload only
#   --dry-run       render, validate and report; build and change nothing
#
# The image is built locally (decision D3): localhost/apporo-cf-tunnel:<VERSION>-<git-sha12>,
# Pull=never. The build runs before any unit is touched.
#
# It never restarts a running apporo-cf-tunnel.service (QL_HOLD_UNITS), and refuses to
# rewrite its files while it runs: a restart drops the tunnel, which may carry your SSH
# session. scripts/upgrade.sh applies such changes, detached, with automatic rollback.
#
# WOOW's Cloudflare Tunnel Web GUI (woow-cf-tunnel, or the older cf-tunnel-webgui) may run
# on the same host. There is no migration from it: nothing here looks for it, stops it,
# adopts its volume or removes anything of it. Our names and default ports differ; its
# default ports are refused, and so is an existing volume that podman says is not ours.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# Lineage guard, ahead of the library source on purpose: a tree without
# scripts/lib/quadlet-lib.sh (a partial copy of the scripts) would otherwise die with a bare
# "No such file or directory" instead of saying what is wrong. ql_require_own_lineage below
# refuses a hand-copied deployment tree that does carry a lib copy.
[[ -r $REPO/scripts/lib/quadlet-lib.sh ]] || {
  printf '%s: ERROR: %s\n' "${0##*/}" "no scripts/lib/quadlet-lib.sh under $REPO: this is not a complete checkout of WOOWTECH/apporo_cf_tunnel_web. Run it from a fresh clone (git clone https://github.com/WOOWTECH/apporo_cf_tunnel_web)" >&2
  exit 1
}
# shellcheck source=lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
ql_require_own_lineage "$REPO" WOOWTECH/apporo_cf_tunnel_web
# shellcheck source=render-args.sh
. "$REPO/scripts/render-args.sh"

# ---- per-repo settings -----------------------------------------------------------------
APP=apporo-cf-tunnel
ENV_FILE=$HOME/.config/$APP/$APP.env
PODMAN_MIN=4.9
TUNNEL_UNIT=apporo-cf-tunnel.service
TUNNEL_CONTAINER=apporo-cf-tunnel
AUTH_UNIT=apporo-cf-tunnel-auth.service
AUTH_CONTAINER=apporo-cf-tunnel-auth
STAGE_DIR=$HOME/.local/state/apporo-cf-tunnel/staged
NGINX_GID=${NGINX_GID:-101}   # gid of "nginx" in nginx:*-alpine; the htpasswd gets this group
# ------------------------------------------------------------------------------------------

with_auth=0 without_auth=0 image='' allow_dirty=0 stage=0 no_start=0
while (($#)); do
  case $1 in
    --with-auth) with_auth=1 ;;
    --without-auth) without_auth=1 ;;
    --image) image=${2:?--image needs a value}; shift ;;
    --allow-dirty) allow_dirty=1 ;;
    --stage) stage=1 ;;
    --stage-dir)
      STAGE_DIR=${2:?--stage-dir needs a value}; stage=1; shift
      # --stage replaces this directory: never one of WOOW's (typed, or reached via a symlink)
      if cf_foreign_path "$STAGE_DIR" || cf_foreign_path "$(readlink -m -- "$STAGE_DIR")"; then
        ql_die "--stage-dir $STAGE_DIR is inside a directory of WOOW's Cloudflare Tunnel Web GUI; --stage replaces the directory it is given, and this package never writes there"
      fi ;;
    --no-start) no_start=1 ;;
    --dry-run) export QL_DRY_RUN=1 ;;
    -h | --help) sed -n '2,28p' "$0"; exit 0 ;;
    *) ql_die "unknown option $1 (see --help)" ;;
  esac
  shift
done
((!(with_auth && without_auth))) || ql_die "--with-auth and --without-auth exclude each other"
export QL_APP=$APP QL_HOLD_UNITS=$TUNNEL_UNIT
dry=0
[[ ${QL_DRY_RUN:-0} == 1 ]] && dry=1
QDIR=${QL_QUADLET_DIR:-$HOME/.config/containers/systemd}

port_busy() { [[ -n $(ss -ltnH "( sport = :$1 )" 2>/dev/null) ]]; }
# installed_value <file> <sed script>: what an installed file says now ("" when it is absent)
installed_value() { if [[ -f $1 ]]; then sed -n "$2" "$1" | tail -n1; fi; }
AUTH_CONF=${QL_CONFIG_ROOT:-$HOME/.config}/$APP/auth-nginx.conf
unit_up() {
  local s
  s=$(systemctl --user is-active "$1" 2>/dev/null || true)
  [[ $s == active || $s == activating || $s == reloading ]]
}

# ---- 1. host preflight ---------------------------------------------------------------------
ql_preflight "$PODMAN_MIN"
ql_enable_linger
# upgrade.sh runs this script with --stage while it holds the app lock; ql_lock sees its
# QL_LOCK_HELD and keeps that lock instead of taking a second one.
ql_lock "$APP"

# ---- 2. per-host settings (D2: rendered from the env file, never committed) ---------------
ql_env_ensure "$REPO/config/$APP.env.example" "$ENV_FILE"
if [[ $QL_ENV_CREATED == 1 ]]; then
  ql_info "review $ENV_FILE (data volume, ports, htpasswd path), then run $0 again"
  exit 0
fi
if ((dry)) && [[ ! -f $ENV_FILE ]]; then
  ql_info "[dry-run] using the example settings"
  ENV_FILE=$REPO/config/$APP.env.example
  export QL_ENV_MODE_CHECK=0
fi
ql_env_load "$ENV_FILE"
[[ -z $image ]] || export APPORO_CF_IMAGE=$image
RENDER_ARGS=()
render_args "$ENV_FILE"
IMAGE=${RENDER_ARGS[0]#CF_IMAGE=}
GUI_PORT=$(ql_env_get UVICORN_PORT)
METRICS=$(ql_env_get CF_METRICS_ADDR)
VOLUME=$(ql_env_get CF_DATA_VOLUME)
AUTH_LISTEN=$(ql_env_get AUTH_LISTEN 127.0.0.1:8988)
HTPASSWD=$(ql_expand_home "$(ql_env_get AUTH_HTPASSWD '%h/.config/apporo-cf-tunnel/htpasswd')")

# The auth proxy stays selected once installed; --with-auth / --without-auth change that.
auth=0
[[ -f $QDIR/apporo-cf-tunnel-auth.container ]] && auth=1
((with_auth)) && auth=1
((without_auth)) && auth=0

tunnel_up=0
unit_up "$TUNNEL_UNIT" && tunnel_up=1

# ---- 3. conflict guards -------------------------------------------------------------------
# Only our own names and ports are checked. Another tunnel GUI on this host, such as WOOW's,
# is left alone; it conflicts only if it holds one of these ports, and then nothing changes.
# The ports the running tunnel was installed with are its own. Every other port the rendered
# unit listens on must be free, with --stage too: upgrade.sh applies what it stages, and a
# cloudflared that cannot bind its --metrics address would leave the gate, the baseline and
# the healthcheck reading whichever connector holds that port.
tunnel_ports=' '
if ((tunnel_up)); then
  tunnel_ports+="$(installed_value "$QDIR/apporo-cf-tunnel.container" 's/^Environment=UVICORN_PORT=//p') "
  p=$(installed_value "$QDIR/apporo-cf-tunnel.container" 's/^Environment=CF_METRICS_ADDR=//p')
  tunnel_ports+="${p##*:} "
fi
for p in "$GUI_PORT" "${METRICS##*:}"; do
  [[ $tunnel_ports == *" $p "* ]] && continue
  if port_busy "$p"; then ql_die "port $p is already in use (another cloudflared or tunnel GUI?); free it or change $ENV_FILE"; fi
done
# The data volume: missing (the volume unit creates it) or ours by what podman says about it.
# A name that passed render-args.sh can still be another app's volume, and
# `podman volume create --ignore` would hand it to this container without a word.
cf_check_volume "$VOLUME" adopts "Set CF_DATA_VOLUME in $ENV_FILE to a volume of its own (default apporo_cf_data)"
if ((tunnel_up)) && [[ $IMAGE == *-dirty || $IMAGE == *-nogit ]]; then
  ql_die "$TUNNEL_UNIT is running; rebuilding $IMAGE in place would apply at its next restart, unsupervised. Commit your changes and use scripts/upgrade.sh"
fi
ql_check_container_collision "$TUNNEL_CONTAINER" "$TUNNEL_UNIT"
((auth)) && ql_check_container_collision "$AUTH_CONTAINER" "$AUTH_UNIT"

# ---- 4. image: built locally before any unit changes (D3) ----------------------------------
build_image() {
  local img=$1 rebuild=0
  case $img in *-dirty | *-nogit) rebuild=1 ;; esac
  if [[ -n ${APPORO_CF_IMAGE:-} ]]; then
    podman image exists "$img" || ql_die "--image $img does not exist locally (podman images localhost/apporo-cf-tunnel)"
    return 0
  fi
  if [[ $img == *-dirty ]] && ((!allow_dirty)); then
    ql_die "the checkout has uncommitted changes; commit them, or pass --allow-dirty for a dev build"
  fi
  if ((!rebuild)) && podman image exists "$img"; then
    ql_info "image $img is already built"
    return 0
  fi
  if ((dry)); then ql_info "[dry-run] would build $img"; return 0; fi
  ql_info "building $img from $REPO (the running service is not touched; a few minutes)"
  podman build --pull=missing \
    --label "org.opencontainers.image.revision=$(git -C "$REPO" rev-parse HEAD 2>/dev/null || echo unknown)" \
    --label "org.opencontainers.image.version=$(cf_version)" \
    -t "$img" "$REPO" >&2 || ql_die "podman build failed; nothing was changed"
}
build_image "$IMAGE"
if ((!dry)) || podman image exists "$IMAGE" 2>/dev/null; then
  # shellcheck disable=SC2016 # expanded by the inner sh
  podman unshare sh -c 'm=$(podman image mount "$1") && test -x "$m/usr/local/bin/cf-webui-healthcheck"; r=$?; podman image unmount "$1" >/dev/null; exit $r' _ "$IMAGE" \
    || ql_die "$IMAGE lacks /usr/local/bin/cf-webui-healthcheck; HealthOnFailure=kill would restart it in a loop"
fi

# ---- 5. optional auth proxy: validate before rendering -------------------------------------
check_htpasswd() {
  local bad
  [[ -s $HTPASSWD ]] || ql_die "--with-auth: $HTPASSWD is missing or empty (create it: scripts/auth-passwd.sh USER)"
  # shellcheck disable=SC2016 # literal $ in the crypt-format regex
  bad=$(grep -vnE '^[A-Za-z0-9._@-]+:\$(2[aby]\$[0-9]{2}\$[./A-Za-z0-9]{53}|6\$[^$:]+\$[./A-Za-z0-9]{86}|5\$[^$:]+\$[./A-Za-z0-9]{43}|apr1\$[./A-Za-z0-9]{1,8}\$[./A-Za-z0-9]{22})$' "$HTPASSWD" | cut -d: -f1 | tr '\n' ' ' || true)
  [[ -z $bad ]] || ql_die "--with-auth: $HTPASSWD has malformed line(s) $bad(want user:bcrypt | sha512-crypt | sha256-crypt | apr1)"
  # the port a running proxy was installed with is its own; a new one must be free
  local cur=''
  unit_up "$AUTH_UNIT" && cur=$(installed_value "$AUTH_CONF" 's/^[[:space:]]*listen[[:space:]][[:space:]]*\([^;[:space:]]*\).*/\1/p')
  if [[ ${AUTH_LISTEN##*:} != "${cur##*:}" ]] && port_busy "${AUTH_LISTEN##*:}"; then
    ql_die "--with-auth: port ${AUTH_LISTEN##*:} is already in use (set AUTH_LISTEN in $ENV_FILE)"
  fi
  if ((dry)); then ql_info "[dry-run] would set $HTPASSWD to mode 0640, group = nginx subgid"; return 0; fi
  chmod 640 "$HTPASSWD"
  podman unshare chgrp "$NGINX_GID" "$HTPASSWD" || ql_die "cannot give $HTPASSWD the nginx group (podman unshare chgrp $NGINX_GID)"
}
((auth)) && check_htpasswd

# ---- 6. render the selected units, validate with the 4.9.3 generator ------------------------
WORK=$(mktemp -d "${TMPDIR:-/tmp}/$APP-install.XXXXXX")
ql_cleanup work rm -rf "$WORK"
mkdir -p "$WORK/src" "$WORK/out"
cp -p "$REPO"/quadlet/*.container "$REPO"/quadlet/*.volume "$WORK/src/"
((auth)) && cp -p "$REPO/quadlet/optional/apporo-cf-tunnel-auth.container" "$WORK/src/"
VARS=$REPO/quadlet/render-vars
ql_render "$WORK/src" "$ENV_FILE" "$VARS" "$WORK/out" "${RENDER_ARGS[@]}"
((auth)) && ql_render "$REPO/config/auth/auth-nginx.conf" "$ENV_FILE" "$VARS" "$WORK/out/config"
refs=()
[[ -d $QDIR ]] && refs=(--ref-dir "$QDIR")
ql_dryrun "$WORK/out" --verify "${refs[@]}" || ql_die "the rendered units failed the dry-run; nothing was installed"
for f in "$WORK/out"/*; do
  u=$(ql_unit_for "$f")
  [[ -z $u ]] || ql_check_unit_shadow "$u" "$APP"
done

# stage_dir_replaceable <dir>: --stage deletes <dir> first, so it must hold nothing but what
# an earlier --stage left there: missing or empty, under our state dir, or only our rendered
# units and config/auth-nginx.conf. The live Quadlet dir is never a stage, even when it holds
# only our units.
stage_dir_replaceable() {
  local d=$1 real root extra
  [[ -e $d || -L $d ]] || return 0
  [[ -d $d && ! -L $d ]] || return 1
  real=$(cd -- "$d" && pwd -P) || return 1
  [[ $real != "$(cd -- "$QDIR" 2>/dev/null && pwd -P)" ]] || return 1
  root=$(cd -- "$HOME/.local/state/$APP" 2>/dev/null && pwd -P) || root=''
  [[ -n $root && $real == "$root"/* ]] && return 0
  # grep -v reads all of find's output: no early exit, so no SIGPIPE status under pipefail
  extra=$(find "$d" -mindepth 1 -printf '%y %P\n' | grep -vxE "f ${APP}[A-Za-z0-9._-]*\.(container|volume)|d config|f config/auth-nginx\.conf" || true)
  [[ -z $extra ]]
}

if ((stage)); then
  if ((dry)); then ql_info "[dry-run] would stage into $STAGE_DIR"; exit 0; fi
  stage_dir_replaceable "$STAGE_DIR" \
    || ql_die "--stage replaces $STAGE_DIR, which is not an earlier stage of $APP (it holds other files, is a symlink or is the live Quadlet dir); nothing was deleted. Give --stage-dir a new or empty directory"
  rm -rf -- "$STAGE_DIR"
  mkdir -p -- "$STAGE_DIR"
  chmod 700 "$STAGE_DIR"
  cp -a -- "$WORK/out/." "$STAGE_DIR/"
  ql_info "staged in $STAGE_DIR: image $IMAGE, volume $VOLUME, GUI 127.0.0.1:$GUI_PORT, metrics $METRICS$( ((auth)) && echo ", auth proxy $AUTH_LISTEN")"
  exit 0
fi

# ---- 7. never rewrite a running tunnel's units --------------------------------------------
if ((tunnel_up)); then
  for f in apporo-cf-tunnel.container apporo-cf-tunnel-data.volume; do
    if ! cmp -s "$WORK/out/$f" "$QDIR/$f"; then
      ql_die "$TUNNEL_UNIT is running and $f would change (new image or settings). Apply it with scripts/upgrade.sh; nothing was changed"
    fi
  done
fi

# ---- 8. images, then files; start or restart only what changed ------------------------------
if ((dry)); then
  ql_info "[dry-run] would pull: $(grep -h '^Image=' "$WORK/out"/*.container | grep -v "$IMAGE" | tr '\n' ' ')"
else
  ql_pull_images "$WORK/out"
fi
changed=$(ql_install_files "$WORK/out" "$APP")
[[ -z $changed ]] || ql_info "changed: $(tr '\n' ' ' <<<"$changed")"
if ((without_auth)) && [[ -f $QDIR/apporo-cf-tunnel-auth.container ]]; then
  ql_remove_files "$APP" apporo-cf-tunnel-auth.container config/auth-nginx.conf
fi
if grep -qx 'config/auth-nginx.conf' <<<"$changed"; then ql_mark_changed "$APP" "$AUTH_UNIT"; fi
if ((dry)); then
  ql_info "dry-run complete; nothing was changed"
  exit 0
fi
units=("$TUNNEL_UNIT")
((auth)) && units+=("$AUTH_UNIT")
if ((no_start)); then
  systemctl --user daemon-reload
  ql_info "installed; not started (--no-start). Start with: systemctl --user start ${units[*]}"
  exit 0
fi
auth_was_up=0
unit_up "$AUTH_UNIT" && auth_was_up=1
ql_apply_units "$APP" "${units[@]}"

# ---- 9. smoke -------------------------------------------------------------------------------
if ((!tunnel_up)) || { ((auth)) && [[ -n $changed || $auth_was_up == 0 ]]; }; then
  "$REPO/tests/smoke.sh" || ql_die "smoke checks failed; see: journalctl --user -u $TUNNEL_UNIT -n 100"
fi
ql_info "installed. Open the GUI through an SSH port-forward: ssh -L $GUI_PORT:127.0.0.1:$GUI_PORT <this host>, then http://localhost:$GUI_PORT"
