# shellcheck shell=bash
# tests/harness/common.sh: shared setup for the harness (sourced by run-all.sh and
# scenario.sh). Every case runs the real scripts against mocked podman, systemctl, curl,
# ss, loginctl and systemd-run (tests/harness/bin), under a throwaway HOME. The Quadlet
# generator and systemd-analyze are real; no container is ever created.

HARNESS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
SRC_REPO=$(cd "$HARNESS/../.." && pwd -P)
: "${HARNESS_TMP:?HARNESS_TMP must be set}"
ORIG_PATH=${ORIG_PATH:-$PATH}
export ORIG_PATH
R=$HARNESS_TMP/repo

# snapshot_repo: a clean git copy of the working tree (tracked + untracked, not ignored),
# so image tags are <VERSION>-<sha> whatever state the dev checkout is in.
snapshot_repo() {
  [[ -d $R/.git ]] && return 0
  mkdir -p "$R"
  (cd "$SRC_REPO" && git ls-files -z -co --exclude-standard |
    while IFS= read -r -d '' f; do [[ -e $f ]] && printf '%s\0' "$f"; done |
    tar --null -T - -cf -) | tar -xf - -C "$R"
  git -C "$R" init -q
  git -C "$R" add -A
  git -C "$R" -c user.name=harness -c user.email=harness@localhost commit -qm snapshot
}

# new_commit: move the snapshot to a new commit (an upgrade produces a new image tag)
new_commit() {
  echo "$1" >>"$R/.harness-bump"
  git -C "$R" add .harness-bump
  git -C "$R" -c user.name=harness -c user.email=harness@localhost commit -qm "$1"
}

image_ref() { printf 'localhost/apporo-cf-tunnel:%s-%s' "$(tr -d '[:space:]' <"$R/VERSION")" "$(git -C "$R" rev-parse --short=12 HEAD)"; }

# sandbox <name>: fresh HOME and mock state; the mocks first on PATH; a tailnet SSH session
sandbox() {
  local d=$HARNESS_TMP/case-$1
  rm -rf "$d"
  mkdir -p "$d/state" "$d/home/.config/systemd/user" "$d/run" "$d/proc"
  export MOCK_STATE=$d/state HOME=$d/home XDG_RUNTIME_DIR=$d/run SMOKE_PROC=$d/proc
  export PATH=$HARNESS/bin:$ORIG_PATH USER=harness
  export SSH_CONNECTION="100.113.239.105 50000 100.112.215.78 22"
  unset QL_DRY_RUN APPORO_CF_IMAGE MOCK_SCENARIO MOCK_BAD_IMAGE MOCK_NEW_IMAGE MOCK_WOOW \
    MOCK_VOLUMES MOCK_BUSY_PORTS MOCK_FAIL_START MOCK_NO_METRICS MOCK_SSH_CARRIER \
    MOCK_VOLUME_LABELS MOCK_VOLUME_COMPOSE MOCK_VOLUME_USERS \
    NEW_UNIT NEW_CONTAINER GUI_PORT METRICS_ADDR EXTRA_UNITS HTTP_OVERRIDES EXPECT_CONNS
  export MOCK_WARMUP=0
  : >"$MOCK_STATE/calls.log"
}

# ---- WOOW's GUI on the same host -------------------------------------------------------------
# This fork has no legacy migration: whatever WOOW runs here is not ours to look at, stop,
# adopt or remove. woow_host sets it up in both shapes it ships in, running: the Quadlet
# install (woow-cf-tunnel.service with its auth proxy, GUI 18000, metrics 20241, auth 8888,
# volume cf_data, its manifest in the quadlet-lib state root it shares with us) and the older
# hand-written cf-tunnel-webgui.service. woow_untouched then checks that it still is.
WOOW_RE='woow[-_*]|cf-tunnel-webgui|(^|[^A-Za-z0-9_])cf_data([^A-Za-z0-9_]|$)'
WOOW_PATHS=(.config/containers/systemd/woow-cf-tunnel.container
  .config/containers/systemd/woow-cf-tunnel-data.volume
  .config/containers/systemd/woow-cf-tunnel-auth.container
  .local/state/woow-quadlet/woow-cf-tunnel .config/woow-cf-tunnel
  .config/systemd/user/cf-tunnel-webgui.service)
WOOW_UNITS=(woow-cf-tunnel.service woow-cf-tunnel-auth.service woow-cf-tunnel-data-volume.service
  cf-tunnel-webgui.service)
WOOW_BEFORE=''
woow_host() {
  local q=$HOME/.config/containers/systemd m=$HOME/.local/state/woow-quadlet/woow-cf-tunnel
  local c=$HOME/.config/woow-cf-tunnel u
  export MOCK_WOOW=1 MOCK_VOLUMES="apporo_cf_data cf_data woow_cloudflare_tunnel_webgui_cf_data"
  mkdir -p "$q" "$m" "$c" "$MOCK_STATE/woow"
  printf '[Unit]\nDescription=WOOW Cloudflare Tunnel Web GUI\n[Container]\nContainerName=woow-cf-tunnel\nImage=localhost/woow-cf-tunnel:1.2.1-e6226c5aaaaa\nPull=never\nNetwork=host\nVolume=woow-cf-tunnel-data.volume:/data\n[Service]\nRestart=always\n[Install]\nWantedBy=default.target\n' \
    >"$q/woow-cf-tunnel.container"
  printf '[Volume]\nVolumeName=cf_data\nLabel=io.woowtech.app=woow-cf-tunnel\n' >"$q/woow-cf-tunnel-data.volume"
  printf '[Unit]\nDescription=WOOW auth proxy\n[Container]\nContainerName=woow-cf-tunnel-auth\nImage=docker.io/library/nginx:1.30.4-alpine\nNetwork=host\n[Service]\nRestart=always\n[Install]\nWantedBy=default.target\n' \
    >"$q/woow-cf-tunnel-auth.container"
  sha256sum "$q/woow-cf-tunnel.container" "$q/woow-cf-tunnel-data.volume" "$q/woow-cf-tunnel-auth.container" >"$m/manifest"
  printf 'CF_DATA_VOLUME=cf_data\nUVICORN_PORT=18000\nCF_METRICS_ADDR=127.0.0.1:20241\nAUTH_LISTEN=127.0.0.1:8888\n' >"$c/woow-cf-tunnel.env"
  printf 'admin:woow-hash-placeholder\n' >"$c/htpasswd"
  chmod 600 "$c/woow-cf-tunnel.env" "$c/htpasswd"
  printf '[Unit]\nDescription=legacy cf-tunnel-webgui\n[Service]\nExecStart=/usr/bin/podman run --rm --name cf-tunnel-webgui -v cf_data:/data localhost/cf-webui:8214177d40f4\n[Install]\nWantedBy=default.target\n' \
    >"$HOME/.config/systemd/user/cf-tunnel-webgui.service"
  for u in "${WOOW_UNITS[@]}"; do echo 1 >"$MOCK_STATE/woow/$u"; done
  WOOW_BEFORE=$(woow_state)
}
# woow_state: every WOOW path with its mode, and every WOOW file's sha256
woow_state() {
  local p
  for p in "${WOOW_PATHS[@]}"; do
    if [[ -e $HOME/$p ]]; then
      (cd "$HOME" && find "$p" -printf '%p %m\n' && find "$p" -type f -exec sha256sum {} +)
    else
      printf '%s MISSING\n' "$p"
    fi
  done | LC_ALL=C sort
}
# woow_untouched: WOOW's files as woow_host wrote them, its units still active, and no podman /
# systemctl call that names one of its resources, nor a probe of its GUI, metrics or auth port
woow_untouched() {
  local u hits bad=0
  [[ $(woow_state) == "$WOOW_BEFORE" ]] || { echo "  WOOW's files changed"; bad=1; }
  for u in "${WOOW_UNITS[@]}"; do
    [[ $(cat "$MOCK_STATE/woow/$u" 2>/dev/null) == 1 ]] || { echo "  $u is no longer active"; bad=1; }
  done
  # the case's own directory is cut out first: only what the scripts name counts
  hits=$(sed -e "s|${MOCK_STATE%/state}||g" -e "s|$HARNESS_TMP||g" "$MOCK_STATE/calls.log" |
    grep -E "$WOOW_RE|^curl http://127\.0\.0\.1:(18000|20241|8888)/" || true)
  if [[ -n $hits ]]; then
    echo "  calls that reach for WOOW's GUI:"
    printf '%s\n' "$hits" | sed 's/^/    /'
    bad=1
  fi
  return "$bad"
}

# woow_shell: this shell carries WOOW's unit, container and ports, as one set up to tune
# WOOW's own upgrade would. None of it may steer this app's scripts.
woow_shell() {
  export NEW_UNIT=woow-cf-tunnel.service NEW_CONTAINER=woow-cf-tunnel GUI_PORT=18000 \
    METRICS_ADDR=127.0.0.1:20241
}

env_file() {
  mkdir -p "$HOME/.config/apporo-cf-tunnel"
  chmod 700 "$HOME/.config/apporo-cf-tunnel"
  install -m 600 "$R/config/apporo-cf-tunnel.env.example" "$HOME/.config/apporo-cf-tunnel/apporo-cf-tunnel.env"
}
set_env() { sed -i "s|^$1=.*|$1=$2|" "$HOME/.config/apporo-cf-tunnel/apporo-cf-tunnel.env"; }
calls() { grep -cE -- "$1" "$MOCK_STATE/calls.log" 2>/dev/null || true; }
QDIR() { printf '%s' "$HOME/.config/containers/systemd"; }

# assertions: a case function runs them, then returns $A_FAILS
A_FAILS=0
t() { "$@" || { echo "  assert failed: $*"; A_FAILS=$((A_FAILS + 1)); }; }
tnot() { if "$@"; then echo "  assert should have failed: $*"; A_FAILS=$((A_FAILS + 1)); fi; }
has_line() { grep -qx -- "$1" "$2"; }
