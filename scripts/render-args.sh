# shellcheck shell=bash
# scripts/render-args.sh: install-time values that are computed, not typed (decision D2).
# Sourced by scripts/install.sh and tests/dryrun.sh (after scripts/lib/quadlet-lib.sh), so
# CI renders exactly what a host gets; backup.sh, restore.sh, uninstall.sh, upgrade.sh (and
# the frozen watchdog copy that cf_freeze puts in $RUN/bin) and auth-passwd.sh source it for
# the WOOW guards below.
#
#   render_args <envfile>  validate the loaded env (ql_env_load it first) and set
#                          RENDER_ARGS=(CF_IMAGE=<ref>)
#   cf_image_ref           print localhost/apporo-cf-tunnel:<VERSION>-<git-sha12>[-dirty]
#   cf_foreign_volume NAME / cf_foreign_path PATH / cf_foreign_port PORT
#                          true for a volume name, path or default port of WOOW's Cloudflare
#                          Tunnel Web GUI (cf_resolved_foreign PATH: also through symlinks)
#   cf_require_own_dirs    die when a fixed directory of this app leads into one of WOOW's
#   cf_check_volume NAME VERB [HINT]
#                          die unless the volume is missing or, by what podman says about it,
#                          ours (needs podman)
#
# APPORO_CF_IMAGE overrides the computed image (install.sh / upgrade.sh --image), for
# example to roll back to an earlier local build. It must be a localhost/apporo-cf-tunnel tag.

CF_REPO=${CF_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}
CF_IMAGE_NAME=localhost/apporo-cf-tunnel

# ---- WOOW's Cloudflare Tunnel Web GUI may run on this host too -------------------------------
# It is not ours to touch. Its names never appear in our units; these catch the values a
# person types (the env file, ENV_FILE=...): a second connector on WOOW's /data would run
# WOOW's tunnel token, and backup/restore/uninstall --purge would act on WOOW's data.
# cf_foreign_volume <name>: cf_data ("podman run -v cf_data:/data" and upstream's default),
# woow* (its compose project woow_cloudflare_tunnel_webgui_cf_data), <project>_cf_data (what
# compose names that volume under any other project name; apporo_* is ours), cf-tunnel-webgui*,
# systemd-woow* (a Quadlet volume without VolumeName=)
cf_foreign_volume() {
  local v=${1,,}
  [[ $v == cf_data || $v == woow* || $v == cf-tunnel-webgui* || $v == systemd-woow* ]] && return 0
  [[ $v == *_cf_data && $v != apporo_* ]]
}
# cf_foreign_path <path>: inside ~/.config/woow-cf-tunnel or ~/.config/cf-tunnel-webgui
# (by path component, so a home directory such as /home/woowtech is not caught)
cf_foreign_path() { [[ /$1/ == */woow-cf-tunnel/* || /$1/ == */cf-tunnel-webgui/* ]]; }
# cf_resolved_foreign <path>: cf_foreign_path for <path> as typed and with its symlinks
# resolved (%h is $HOME), so a path of ours that is a symlink into WOOW's dirs is caught too
cf_resolved_foreign() {
  local p=${1//%h/$HOME}
  cf_foreign_path "$p" || cf_foreign_path "$(readlink -m -- "$p")"
}
# cf_foreign_own_dir: print the first fixed directory of this app that leads into a directory
# of WOOW's GUI and return 0; return 1 when none does. An operator who symlinked
# ~/.config/apporo-cf-tunnel or ~/.local/state/apporo-cf-tunnel to WOOW's, to carry its
# settings over, would otherwise have these scripts write, back up or delete WOOW's files.
# (A CF_STATE_ROOT set in the environment has its own guard in lib/cf-gate.sh.)
cf_foreign_own_dir() {
  local d
  for d in "$HOME/.config/apporo-cf-tunnel" "$HOME/.local/state/apporo-cf-tunnel" \
    "$HOME/backups/apporo-cf-tunnel" "${QL_STATE_ROOT:-$HOME/.local/state/woow-quadlet}/apporo-cf-tunnel"; do
    if cf_resolved_foreign "$d"; then
      printf '%s\n' "$d"
      return 0
    fi
  done
  return 1
}
# cf_require_own_dirs: die (ql_die) when cf_foreign_own_dir finds one
cf_require_own_dirs() {
  local d
  if d=$(cf_foreign_own_dir); then
    ql_die "$d leads into a directory of WOOW's Cloudflare Tunnel Web GUI ($(readlink -m -- "$d")); this package never writes there. Make it a directory of its own"
  fi
}
# cf_foreign_port <port>: a default port of WOOW's GUI: 18000 (GUI), 20241 (cloudflared
# --metrics), 8888 (auth proxy; also the GUI port of its old compose file). None of this
# app's ports may be one, even while WOOW's GUI is stopped and nothing holds it: its
# uvicorn and its pinned --metrics address could then not bind on their next start (its
# tunnel would stay down in a restart loop), and its healthcheck and upgrade gate would read
# this app's /ready. Compared as numbers, so 08888 is 8888.
cf_foreign_port() { [[ $1 =~ ^[0-9]+$ ]] && ((10#$1 == 18000 || 10#$1 == 20241 || 10#$1 == 8888)); }

# cf_check_volume <name> <verb> [hint]: an existing volume is used only when podman says it
# is ours. The names refused above are the ones WOOW's GUI ships with, but its operator can
# name its volume anything, and Quadlet's `podman volume create --ignore` would silently
# reuse whatever volume has our name: a second connector on WOOW's /data, and backup.sh,
# restore.sh and uninstall.sh --purge acting on WOOW's tunnel token. So this dies, before
# the volume is used, when it carries another app's ownership label (WOOW's Quadlet volume
# has io.woowtech.app=woow-cf-tunnel; ours has apporo-cf-tunnel), was created by compose
# (this package never uses compose; WOOW's old deployment did), or is mounted by any
# container other than apporo-cf-tunnel, running or stopped. A missing volume is fine:
# the volume unit creates it. <verb> says what the caller was about to do ("adopts",
# "exports", "restores into", "deletes").
cf_check_volume() {
  local vol=${1:?usage: cf_check_volume <name> <verb> [hint]} verb=${2:?usage: cf_check_volume <name> <verb> [hint]} hint=${3:-}
  local rc=0 owner proj users c why=''
  podman volume exists "$vol" >/dev/null 2>&1 || rc=$?
  ((rc == 1)) && return 0
  ((rc == 0)) || ql_die "podman volume exists $vol failed (rc=$rc)"
  owner=$(_ql_label_owner volume "$vol")
  proj=$(podman volume inspect --format '{{with .Labels}}{{or (index . "com.docker.compose.project") (index . "io.podman.compose.project")}}{{end}}' "$vol" 2>/dev/null) || proj=''
  users=$(podman ps -a --filter "volume=$vol" --format '{{.Names}}' 2>/dev/null) \
    || ql_die "cannot tell which containers mount volume $vol (podman ps failed)"
  if [[ -n $owner && $owner != apporo-cf-tunnel ]]; then
    why="is labelled for '$owner' (io.woowtech.app), not apporo-cf-tunnel"
  elif [[ -n $proj ]]; then
    why="was created by compose project '$proj' (this app never uses compose)"
  else
    while IFS= read -r c; do
      [[ -z $c || $c == apporo-cf-tunnel ]] && continue
      why="is mounted by container '$c', not only by apporo-cf-tunnel"
      break
    done <<<"$users"
  fi
  [[ -z $why ]] || ql_die "volume $vol $why. This package never $verb a volume that another app owns or another container uses${hint:+. $hint}"
}

# cf_version: the pinned release from VERSION (x.y.z)
cf_version() {
  local v
  v=$(tr -d '[:space:]' <"$CF_REPO/VERSION" 2>/dev/null) || ql_die "cannot read $CF_REPO/VERSION"
  [[ $v =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || ql_die "VERSION must be x.y.z, got '$v'"
  printf '%s' "$v"
}

# cf_image_ref: the tag a build of this checkout gets. A tree with uncommitted changes
# gets a -dirty suffix (install.sh refuses it without --allow-dirty); a copy without
# git metadata gets -nogit. Both are rebuilt on every run.
cf_image_ref() {
  local ver sha
  ver=$(cf_version) || return 1
  if sha=$(git -C "$CF_REPO" rev-parse --short=12 HEAD 2>/dev/null); then
    if [[ -n $(git -C "$CF_REPO" status --porcelain 2>/dev/null) ]]; then sha+=-dirty; fi
  else
    sha=nogit
  fi
  printf '%s:%s-%s' "$CF_IMAGE_NAME" "$ver" "$sha"
}

# _cf_port <label> <value>: 1024..65535 (rootless podman cannot bind lower ports)
_cf_port() {
  ql_assert_match "$1" "$2" '[0-9]{4,5}'
  ((10#$2 >= 1024 && 10#$2 <= 65535)) || ql_die "$1: port $2 is outside 1024-65535"
}

# cf_validate_env: every value that reaches a unit or the nginx config (dies on the first bad one)
cf_validate_env() {
  local gui metrics vol listen ht kp
  gui=$(ql_env_get UVICORN_PORT) || ql_die "UVICORN_PORT is missing from the env file"
  metrics=$(ql_env_get CF_METRICS_ADDR) || ql_die "CF_METRICS_ADDR is missing from the env file"
  vol=$(ql_env_get CF_DATA_VOLUME) || ql_die "CF_DATA_VOLUME is missing from the env file"
  listen=$(ql_env_get AUTH_LISTEN 127.0.0.1:8988)
  ht=$(ql_env_get AUTH_HTPASSWD '%h/.config/apporo-cf-tunnel/htpasswd')
  _cf_port UVICORN_PORT "$gui"
  # host networking: a non-loopback metrics port would publish /config (the ingress map)
  ql_assert_match CF_METRICS_ADDR "$metrics" '127\.0\.0\.1:[0-9]{4,5}'
  _cf_port CF_METRICS_ADDR "${metrics##*:}"
  ql_assert_match CF_DATA_VOLUME "$vol" '[A-Za-z0-9][A-Za-z0-9_.-]*'
  if cf_foreign_volume "$vol"; then
    ql_die "CF_DATA_VOLUME=$vol is a volume name of WOOW's Cloudflare Tunnel Web GUI (cf_data, <project>_cf_data, woow*, cf-tunnel-webgui*); this package never adopts its data. Use apporo_cf_data"
  fi
  ql_assert_match AUTH_LISTEN "$listen" '(127\.0\.0\.1|0\.0\.0\.0|([0-9]{1,3}\.){3}[0-9]{1,3}):[0-9]{4,5}'
  _cf_port AUTH_LISTEN "${listen##*:}"
  # install.sh's busy-port check only sees WOOW's defaults while WOOW's GUI holds them
  for kp in "UVICORN_PORT $gui" "CF_METRICS_ADDR ${metrics##*:}" "AUTH_LISTEN ${listen##*:}"; do
    if cf_foreign_port "${kp#* }"; then
      ql_die "${kp%% *}: port ${kp#* } is a default port of WOOW's Cloudflare Tunnel Web GUI (18000 / 20241 / 8888); this package never listens on one, even while that GUI is stopped. Use 18100 / 20341 / 8988"
    fi
  done
  ql_assert_match AUTH_HTPASSWD "$ht" '(%h|/)[A-Za-z0-9._/@+-]*'
  if cf_resolved_foreign "$ht"; then
    ql_die "AUTH_HTPASSWD=$ht is inside the config dir of WOOW's Cloudflare Tunnel Web GUI; this package never writes there. Use %h/.config/apporo-cf-tunnel/htpasswd"
  fi
  [[ $gui != "${metrics##*:}" ]] || ql_die "UVICORN_PORT and CF_METRICS_ADDR use the same port $gui"
  [[ $gui != "${listen##*:}" && ${metrics##*:} != "${listen##*:}" ]] \
    || ql_die "AUTH_LISTEN port ${listen##*:} collides with UVICORN_PORT or CF_METRICS_ADDR"
}

# render_args <envfile>: validate, then set RENDER_ARGS for ql_render
render_args() {
  local img
  cf_validate_env
  img=${APPORO_CF_IMAGE:-}
  if [[ -z $img ]]; then img=$(cf_image_ref) || ql_die "cannot compute the image tag"; fi
  ql_assert_match "image" "$img" "${CF_IMAGE_NAME//./\\.}:[A-Za-z0-9][A-Za-z0-9._-]*"
  [[ $img != *:latest ]] || ql_die "image $img: pin a version, not :latest"
  # shellcheck disable=SC2034 # RENDER_ARGS is read by the caller (install.sh, tests/dryrun.sh)
  RENDER_ARGS=("CF_IMAGE=$img")
}
