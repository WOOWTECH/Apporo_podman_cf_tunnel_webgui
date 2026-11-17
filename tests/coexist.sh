#!/usr/bin/env bash
# tests/coexist.sh: this fork shares a host with WOOW's Cloudflare Tunnel Web GUI and never
# acts on it. There is no legacy migration here: nothing may stop, adopt, back up, restore
# into, migrate or delete a WOOW resource - the woow-cf-tunnel* units, containers, images and
# files, cf-tunnel-webgui*, the cf_data volume, ~/.config/woow-cf-tunnel.
#
#   names    every unit, container, volume, image, directory and default port is our own
#   guards   the values a person types (CF_DATA_VOLUME, the ports, AUTH_HTPASSWD, --image,
#            ENV_FILE, --stage-dir, a backup tarball, an upgrade RUN, CF_STATE_ROOT) are
#            refused when they point at WOOW's, before podman or systemd is asked anything that
#            changes state; so is an existing volume that podman says is not ours, whatever its
#            name, and a run.env that names another unit
#   scripts  install / backup / restore / upgrade / uninstall [--purge] / auth-passwd, run
#            against stubbed podman and systemctl on a HOME that also holds a WOOW install,
#            leave every WOOW file as it was and never name a WOOW resource to podman or
#            systemctl, even from a shell that exports WOOW's unit, container and ports
#
# tests/harness repeats the flows with a running WOOW install next to ours (install, upgrade,
# uninstall --purge); it needs the Quadlet generator. This file needs no podman, no systemd
# and no network.
#
#   tests/coexist.sh [filter]
#
# Every case runs in its own subshell (own HOME, own PATH), so:
# shellcheck disable=SC2030,SC2031
# shellcheck source-path=SCRIPTDIR
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
REPO=$(cd "$HERE/.." && pwd -P)
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/cf-coexist.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
filter=${1:-}
npass=0 nfail=0
FAILED=()

die_t() { printf 'ASSERTION FAILED: %s\n' "$*" >&2; exit 1; }
has() { [[ $1 == *"$2"* ]] || die_t "${3:-output} lacks [$2] in:"$'\n'"$1"; }
eq() { [[ $1 == "$2" ]] || die_t "${3:-value}: expected [$2] got [$1]"; }

case_() {
  local name=$1
  shift
  if [[ -n $filter && $name != *"$filter"* ]]; then return 0; fi
  local out
  if out=$( ("$@") 2>&1); then
    npass=$((npass + 1))
    printf 'ok   %s\n' "$name"
  else
    nfail=$((nfail + 1))
    FAILED+=("$name")
    printf 'FAIL %s\n%s\n' "$name" "$out"
  fi
}

# A WOOW resource name as it appears in a file or on a command line. io.woowtech.app, the
# ownership label key the vendored lib reads, is not one, and apporo_cf_data is not cf_data.
WOOW_RE='woow[-_*]|cf-tunnel-webgui|(^|[^A-Za-z0-9_])cf_data([^A-Za-z0-9_]|$)'

load() {
  # shellcheck source=../scripts/lib/quadlet-lib.sh
  . "$REPO/scripts/lib/quadlet-lib.sh"
  # shellcheck source=../scripts/render-args.sh
  . "$REPO/scripts/render-args.sh"
  export QL_ENV_MODE_CHECK=0
}

# code_lines <file>...: "<file>:<n>:<line>" for every line that is neither blank nor a # comment
code_lines() { grep -nH -v -E '^[[:space:]]*(#|$)' "$@" || true; }

# refused <what> <expected text> <cmd...>: the command must fail, and say why
refused() {
  local what=$1 want=$2 out rc=0
  shift 2
  out=$( ("$@") 2>&1) || rc=$?
  ((rc != 0)) || die_t "$what: accepted, want refused"
  [[ $out == *"$want"* ]] || die_t "$what: refused, but without [$want]:"$'\n'"$out"
}

# ---- a HOME with a WOOW install next to ours, and stubs that log what they are asked ------
# The two shapes WOOW's GUI is deployed in: its Quadlet install (woow-cf-tunnel, with its
# manifest in the state root quadlet-lib shares between apps, its env file and htpasswd, and
# a prepared upgrade run in its own state dir) and the older hand-written cf-tunnel-webgui
# unit; plus a backup of its volume. .config/nginx is an htpasswd a WOOW env file may name
# outside WOOW's config dir (t_auth_passwd_never_writes_woows_htpasswd writes it).
WOOW_RUN=.local/state/woow-cf-tunnel/upgrade-20261101-000000
WOOW_PATHS=(.config/containers/systemd/woow-cf-tunnel.container
  .config/containers/systemd/woow-cf-tunnel-data.volume .local/state/woow-quadlet/woow-cf-tunnel
  .config/woow-cf-tunnel .config/systemd/user/cf-tunnel-webgui.service backups/woow-cf-tunnel
  .local/state/woow-cf-tunnel .config/nginx)
woow_install() {
  local h=$1 q=$1/.config/containers/systemd m=$1/.local/state/woow-quadlet/woow-cf-tunnel
  local c=$1/.config/woow-cf-tunnel r=$1/$WOOW_RUN
  mkdir -p "$q" "$m" "$c" "$h/.config/systemd/user" "$h/backups/woow-cf-tunnel" "$r/previous" "$r/bin"
  printf '[Container]\nContainerName=woow-cf-tunnel\nImage=localhost/woow-cf-tunnel:1.2.1-e6226c5aaaaa\nPull=never\nVolume=woow-cf-tunnel-data.volume:/data\n' \
    >"$q/woow-cf-tunnel.container"
  printf '[Volume]\nVolumeName=cf_data\nLabel=io.woowtech.app=woow-cf-tunnel\n' >"$q/woow-cf-tunnel-data.volume"
  sha256sum "$q/woow-cf-tunnel.container" "$q/woow-cf-tunnel-data.volume" >"$m/manifest"
  printf 'CF_DATA_VOLUME=cf_data\nUVICORN_PORT=18000\nCF_METRICS_ADDR=127.0.0.1:20241\nAUTH_LISTEN=127.0.0.1:8888\n' >"$c/woow-cf-tunnel.env"
  printf 'AUTH_HTPASSWD=%%h/.config/woow-cf-tunnel/htpasswd\n' >>"$c/woow-cf-tunnel.env"
  printf 'admin:woow-hash-placeholder\n' >"$c/htpasswd"
  chmod 600 "$c/woow-cf-tunnel.env" "$c/htpasswd"
  printf '[Service]\nExecStart=/usr/bin/podman run --rm --name cf-tunnel-webgui -v cf_data:/data localhost/cf-webui:8214177d40f4\n' \
    >"$h/.config/systemd/user/cf-tunnel-webgui.service"
  printf 'tar\n' >"$h/backups/woow-cf-tunnel/cf_data-20261101-000000.tar"
  # prepared by WOOW's upgrade.sh --prepare-only: its watchdog has not started yet
  printf 'NEW_UNIT=woow-cf-tunnel.service\nPREV_UNITS=woow-cf-tunnel.service\n' >"$r/run.env"
  cp "$q/woow-cf-tunnel.container" "$r/previous/"
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

# stubs: podman, systemctl, loginctl, ss, curl and a Quadlet generator that only log to
# $STUB_LOG. Every volume "exists", so a guard that let a WOOW name through would go on to
# export, import or remove it, and the log would show it. What podman says about a volume
# comes from STUB_VOLUME_LABELS (its io.woowtech.app label), STUB_VOLUME_COMPOSE (its compose
# project) and STUB_VOLUME_USERS (the containers that mount it), each "<volume>=<value> ...".
# STUB_ACTIVE lists the active units (none by default); nothing a script does changes it.
stubs() {
  local b=$HOME/bin
  mkdir -p "$b"
  cat >"$b/podman" <<'STUB'
#!/usr/bin/env bash
echo "podman $*" >>"${STUB_LOG:?}"
# of <list> <volume>: the values "<volume>=<value>" entries of the list give it
of() { local e; for e in $1; do [[ ${e%%=*} == "$2" ]] && printf '%s\n' "${e#*=}"; done; return 0; }
prev=''
case ${1:-} in
  --version) echo "podman version 4.9.3" ;;
  volume)
    case ${2:-} in
      export) for a in "$@"; do [[ $prev == -o ]] && printf 'tar\n' >"$a"; prev=$a; done ;;
      inspect) if [[ $* == *compose* ]]; then of "${STUB_VOLUME_COMPOSE:-}" "${!#}"; else of "${STUB_VOLUME_LABELS:-}" "${!#}"; fi ;;
    esac ;;
  ps) for a in "$@"; do [[ $a == volume=* ]] && of "${STUB_VOLUME_USERS:-}" "${a#volume=}"; done ;;
  container | image) [[ ${2:-} == exists ]] && exit 1 ;;
  inspect) exit 125 ;;
esac
exit 0
STUB
  cat >"$b/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "systemctl $*" >>"${STUB_LOG:?}"
[[ ${1:-} == --user ]] && shift
up() { [[ " ${STUB_ACTIVE:-} " == *" $1 "* ]]; }
case ${1:-} in
  is-active)
    q=0 u=${2:-}
    [[ $u == --quiet ]] && q=1 u=${3:-}
    if up "$u"; then ((q)) || echo active; exit 0; fi
    ((q)) || echo inactive
    exit 3 ;;
  is-enabled) echo disabled; exit 1 ;;
  show)
    p='' u=''
    shift
    while (($#)); do case $1 in -p) p=${2:-}; shift ;; --value) ;; *) u=$1 ;; esac; shift; done
    case $p in
      LoadState) echo loaded ;;
      FragmentPath) echo "/run/user/1000/systemd/generator/$u" ;;
      NRestarts) echo 0 ;;
    esac ;;
esac
exit 0
STUB
  cat >"$b/quadlet" <<'STUB'
#!/usr/bin/env bash
echo "quadlet $*" >>"${STUB_LOG:?}"
exit 1
STUB
  # never the real one: it would start a transient unit on this host
  cat >"$b/systemd-run" <<'STUB'
#!/usr/bin/env bash
echo "systemd-run $*" >>"${STUB_LOG:?}"
exit 0
STUB
  printf '#!/usr/bin/env bash\necho yes\n' >"$b/loginctl"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$b/ss"
  # nothing answers anywhere; the URL is logged, so a probe of WOOW's GUI or metrics shows up
  cat >"$b/curl" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do case $a in http*) echo "curl $a" >>"${STUB_LOG:?}" ;; esac; done
exit 7
STUB
  chmod +x "$b"/*
}

# sandbox: a fresh HOME with a WOOW install and the stubs first on PATH (in the case's subshell)
sandbox() {
  HOME=$(mktemp -d "$ROOT/home.XXXXXX")
  export HOME XDG_RUNTIME_DIR=$HOME/run STUB_LOG=$HOME/calls.log
  mkdir -p "$XDG_RUNTIME_DIR"
  woow_install "$HOME"
  stubs
  export PATH=$HOME/bin:$PATH QL_QUADLET_BIN=$HOME/bin/quadlet QL_USER_GENERATOR=$HOME/bin/quadlet
  # a session from another host: the access-path guard answers "does not ride the tunnel"
  export SSH_CONNECTION="192.0.2.10 50000 192.0.2.20 22"
  unset QL_DRY_RUN APPORO_CF_IMAGE ENV_FILE QL_LOCK_HELD NEW_UNIT NEW_CONTAINER GUI_PORT \
    METRICS_ADDR CF_STATE_ROOT STUB_ACTIVE STUB_VOLUME_LABELS STUB_VOLUME_COMPOSE STUB_VOLUME_USERS
  : >"$STUB_LOG"
  BEFORE=$(woow_state)
}
# woow_shell: this shell carries WOOW's GUI's unit, container and ports, as one set up to tune
# WOOW's own upgrade would, and WOOW's tunnel is up: a script that so much as asked about
# WOOW's unit would go on to stop it
woow_shell() {
  export NEW_UNIT=woow-cf-tunnel.service NEW_CONTAINER=woow-cf-tunnel GUI_PORT=18000 \
    METRICS_ADDR=127.0.0.1:20241 STUB_ACTIVE=woow-cf-tunnel.service
}
# untouched: every WOOW file as the sandbox wrote it, and no WOOW name in any podman /
# systemctl call (the sandbox and repo paths are cut out of the log first)
untouched() {
  local now calls
  now=$(woow_state)
  [[ $now == "$BEFORE" ]] || die_t "WOOW's files changed:"$'\n'"$(diff <(printf '%s\n' "$BEFORE") <(printf '%s\n' "$now"))"
  calls=$(sed -e "s|$ROOT||g" -e "s|$REPO||g" "$STUB_LOG")
  if grep -E "$WOOW_RE" <<<"$calls"; then die_t "the calls above name a WOOW resource"; fi
}
# never_called <ERE>: no logged podman / systemctl call matches
never_called() {
  if grep -E -- "$1" "$STUB_LOG"; then die_t "unexpected call(s) above, matching /$1/"; fi
}
# our_env [KEY VALUE]...: our env file from the example, with these keys replaced
our_env() {
  local f=$HOME/.config/apporo-cf-tunnel/apporo-cf-tunnel.env
  mkdir -p "${f%/*}"
  chmod 700 "${f%/*}"
  cp "$REPO/config/apporo-cf-tunnel.env.example" "$f"
  chmod 600 "$f"
  while (($# >= 2)); do
    sed -i "/^$1=/d" "$f"
    printf '%s=%s\n' "$1" "$2" >>"$f"
    shift 2
  done
}
# installed_volume <name>: our installed volume unit, as a hand edit could leave it
installed_volume() {
  mkdir -p "$HOME/.config/containers/systemd"
  printf '[Volume]\nVolumeName=%s\nLabel=io.woowtech.app=apporo-cf-tunnel\n' "$1" \
    >"$HOME/.config/containers/systemd/apporo-cf-tunnel-data.volume"
}
# tunnel_unit <image tag>: our rendered tunnel unit, the lines the scripts read from it
tunnel_unit() {
  printf '[Container]\nContainerName=apporo-cf-tunnel\nImage=localhost/apporo-cf-tunnel:%s\nPull=never\nVolume=apporo-cf-tunnel-data.volume:/data\nEnvironment=UVICORN_PORT=18100\nEnvironment=CF_METRICS_ADDR=127.0.0.1:20341\n' "$1"
}
# prepared_run <run>: a run dir as `upgrade.sh --prepare-only` leaves it: the rendered new set,
# the installed set as the rollback target, the frozen scripts, and the run.env that
# cf-gate.sh records under whatever this shell exports. (The prepare step itself needs the
# Quadlet generator; tests/harness runs it.) Short timings: no stubbed unit ever comes up.
prepared_run() {
  local run=$1 q=$HOME/.config/containers/systemd
  mkdir -p "$run/new" "$run/previous" "$q"
  tunnel_unit 1.0.0-0123456789ab >"$run/previous/apporo-cf-tunnel.container"
  tunnel_unit 1.0.0-ba9876543210 >"$run/new/apporo-cf-tunnel.container"
  [[ -f $q/apporo-cf-tunnel.container ]] || cp "$run/previous/apporo-cf-tunnel.container" "$q/"
  (
    load
    # shellcheck source=../scripts/lib/cf-gate.sh
    . "$REPO/scripts/lib/cf-gate.sh"
    # what cmd_prepare sets: the ports from the rendered unit, the units from units_of
    # shellcheck disable=SC2034 # recorded by name: cf_write_run_env reads ${!name}
    GUI_PORT=18100 METRICS_ADDR=127.0.0.1:20341 EXTRA_UNITS='' UNITS=$NEW_UNIT PREV_UNITS=$NEW_UNIT
    # shellcheck disable=SC2034 # recorded by name: cf_write_run_env reads ${!name}
    QUADLET_DIR=$q RESTORE_TIMEOUT=1 GATE_TIMEOUT=1 SOAK_SECONDS=1 POLL=0.2 SOAK_POLL=0.2 \
      PREV_GUI_PORT=18100 PREV_METRICS_ADDR=127.0.0.1:20341 BASELINE_TUNNEL=0 BASELINE_VERSION=-1 \
      BASELINE_INGRESS_SHA=''
    cf_write_run_env "$run" QUADLET_DIR RESTORE_TIMEOUT UNITS PREV_UNITS PREV_GUI_PORT \
      PREV_METRICS_ADDR BASELINE_TUNNEL BASELINE_VERSION BASELINE_INGRESS_SHA
    cf_freeze "$run" "$REPO/scripts/upgrade.sh"
  ) || die_t "cannot prepare $run"
}

# ---- names --------------------------------------------------------------------------------
t_units_and_config_name_only_this_app() {
  local f hits
  for f in "$REPO"/quadlet/*.container "$REPO"/quadlet/*.volume "$REPO"/quadlet/optional/* \
    "$REPO"/config/*.env.example; do
    [[ ${f##*/} == apporo-cf-tunnel* ]] || die_t "${f#"$REPO"/} is not named after apporo-cf-tunnel"
  done
  hits=$(code_lines "$REPO"/quadlet/*.container "$REPO"/quadlet/*.volume "$REPO"/quadlet/render-vars \
    "$REPO"/quadlet/optional/* "$REPO"/config/*.env.example "$REPO"/config/auth/* "$REPO"/Dockerfile |
    grep -E "$WOOW_RE" || true)
  [[ -z $hits ]] || die_t "WOOW names outside comments:"$'\n'"$hits"
  has "$(cat "$REPO/quadlet/apporo-cf-tunnel.container")" "ContainerName=apporo-cf-tunnel" "the tunnel unit"
  has "$(cat "$REPO/quadlet/apporo-cf-tunnel.container")" "Volume=apporo-cf-tunnel-data.volume:/data" "the tunnel unit"
  has "$(cat "$REPO/quadlet/optional/apporo-cf-tunnel-auth.container")" "ContainerName=apporo-cf-tunnel-auth" "the auth unit"
  has "$(cat "$REPO/Dockerfile")" 'org.opencontainers.image.source="https://github.com/WOOWTECH/Apporo_podman_cf_tunnel_webgui"' "the Dockerfile"
}

# The scripts name WOOW's resources in one place only: the guard that refuses them.
t_scripts_name_woow_only_in_the_guard() {
  local hits
  hits=$(code_lines "$REPO"/scripts/*.sh "$REPO"/scripts/lib/cf-gate.sh "$REPO"/scripts/healthcheck.py |
    grep -E "$WOOW_RE" | grep -v "^$REPO/scripts/render-args.sh:" || true)
  [[ -z $hits ]] || die_t "WOOW names outside comments and outside the render-args.sh guard:"$'\n'"$hits"
  [[ ! -e $REPO/scripts/migrate-legacy.sh ]] || die_t "this fork has no legacy migration"
}

t_defaults_are_not_woows() {
  load
  ql_env_load "$REPO/config/apporo-cf-tunnel.env.example"
  eq "$(ql_env_get CF_DATA_VOLUME)" apporo_cf_data "CF_DATA_VOLUME (WOOW: cf_data)"
  eq "$(ql_env_get UVICORN_PORT)" 18100 "UVICORN_PORT (WOOW: 18000)"
  eq "$(ql_env_get CF_METRICS_ADDR)" 127.0.0.1:20341 "CF_METRICS_ADDR (WOOW: 127.0.0.1:20241)"
  eq "$(ql_env_get AUTH_LISTEN)" 127.0.0.1:8988 "AUTH_LISTEN (WOOW: 127.0.0.1:8888)"
  eq "$(ql_env_get AUTH_HTPASSWD)" '%h/.config/apporo-cf-tunnel/htpasswd' "AUTH_HTPASSWD"
  eq "$CF_IMAGE_NAME" localhost/apporo-cf-tunnel "the image name (WOOW: localhost/woow-cf-tunnel)"
  # the fallbacks the scripts use when a setting is missing
  (
    unset NEW_UNIT NEW_CONTAINER GUI_PORT METRICS_ADDR CF_STATE_ROOT
    # shellcheck source=../scripts/lib/cf-gate.sh
    . "$REPO/scripts/lib/cf-gate.sh"
    eq "$CF_APP $NEW_UNIT $NEW_CONTAINER" "apporo-cf-tunnel apporo-cf-tunnel.service apporo-cf-tunnel" "cf-gate.sh names"
    eq "$GUI_PORT $METRICS_ADDR" "18100 127.0.0.1:20341" "cf-gate.sh ports"
    eq "$CF_STATE_ROOT" "$HOME/.local/state/apporo-cf-tunnel" "cf-gate.sh state dir"
  ) || exit 1
  # the unit and the container are not settings: a shell that carries WOOW's keeps ours
  (
    export NEW_UNIT=woow-cf-tunnel.service NEW_CONTAINER=woow-cf-tunnel
    # shellcheck source=../scripts/lib/cf-gate.sh
    . "$REPO/scripts/lib/cf-gate.sh"
    eq "$NEW_UNIT $NEW_CONTAINER" "apporo-cf-tunnel.service apporo-cf-tunnel" "cf-gate.sh names, WOOW's exported"
  ) || exit 1
  has "$(cat "$REPO/scripts/healthcheck.py")" 'or "127.0.0.1:20341"' "the healthcheck's metrics default"
}

# ---- the env guard (scripts/render-args.sh) -----------------------------------------------
# validate KEY=VALUE...: cf_validate_env over the example env with these keys replaced
validate() {
  local f=$ROOT/env.$BASHPID kv
  grep -vE "^($(printf '%s|' "${@%%=*}")NONE)=" "$REPO/config/apporo-cf-tunnel.env.example" >"$f"
  for kv in "$@"; do printf '%s\n' "$kv" >>"$f"; done
  ql_env_load "$f"
  cf_validate_env
}

t_env_guard_refuses_woow_volumes() {
  load
  local v
  # compose names WOOW's volume <project>_cf_data, the project being the directory it ran in
  for v in cf_data CF_DATA woow_cloudflare_tunnel_webgui_cf_data woow-cf-tunnel-data WOOW_custom \
    systemd-woow-cf-tunnel-data cf-tunnel-webgui-data cloudflare_tunnel_webgui_cf_data \
    cloudflare_cf_data tunnel_cf_data webgui_cf_data my_cf_data; do
    refused "CF_DATA_VOLUME $v" "never adopts" validate "CF_DATA_VOLUME=$v"
  done
  for v in apporo_cf_data apporo_cf_data_custom apporo_tunnel_cf_data apporo-cf-data-2 cf_data2 \
    cf_data_old; do
    (validate "CF_DATA_VOLUME=$v") || die_t "CF_DATA_VOLUME $v must be accepted"
  done
}

# WOOW's GUI listens on 18000, 20241 and 8888 by default. While it is stopped (between its
# restarts, during its own upgrade swap) nothing holds them and install.sh's busy-port check
# cannot see them, so they are refused by value, for every port this app listens on.
t_env_guard_refuses_woow_ports() {
  load
  local kv
  for kv in UVICORN_PORT=18000 UVICORN_PORT=20241 UVICORN_PORT=8888 UVICORN_PORT=08888 \
    CF_METRICS_ADDR=127.0.0.1:20241 CF_METRICS_ADDR=127.0.0.1:18000 CF_METRICS_ADDR=127.0.0.1:8888 \
    AUTH_LISTEN=127.0.0.1:8888 AUTH_LISTEN=0.0.0.0:8888 AUTH_LISTEN=127.0.0.1:18000 \
    AUTH_LISTEN=127.0.0.1:20241; do
    refused "$kv" "is a default port of WOOW's" validate "$kv"
  done
  for kv in UVICORN_PORT=18001 UVICORN_PORT=18080 CF_METRICS_ADDR=127.0.0.1:20242 \
    AUTH_LISTEN=127.0.0.1:8889 AUTH_LISTEN=0.0.0.0:8000; do
    (validate "$kv") || die_t "$kv must be accepted"
  done
}

t_env_guard_refuses_woow_paths() {
  load
  local home=/home/woowtech p
  for p in '%h/.config/woow-cf-tunnel/htpasswd' /srv/u/.config/woow-cf-tunnel/htpasswd \
    '%h/.config/cf-tunnel-webgui/htpasswd'; do
    refused "AUTH_HTPASSWD $p" "never writes there" validate "AUTH_HTPASSWD=$p"
  done
  # a home directory or a folder of your own that merely contains "woow" is not WOOW's
  for p in '%h/.config/apporo-cf-tunnel/htpasswd' "$home/.config/apporo-cf-tunnel/htpasswd" \
    '%h/woow-notes/htpasswd'; do
    (validate "AUTH_HTPASSWD=$p") || die_t "AUTH_HTPASSWD $p must be accepted"
  done
}

# image_ref_with <ref>: what install.sh / upgrade.sh --image <ref> renders
image_ref_with() { APPORO_CF_IMAGE=$1 render_args "$REPO/config/apporo-cf-tunnel.env.example"; }

t_image_guard_refuses_woows() {
  load
  ql_env_load "$REPO/config/apporo-cf-tunnel.env.example"
  refused "WOOW's image" "must match localhost/apporo-cf-tunnel:" image_ref_with localhost/woow-cf-tunnel:1.2.1-e6226c5aaaaa
  refused "WOOW's image name with our tag" "must match localhost/apporo-cf-tunnel:" image_ref_with localhost/woow-cf-tunnel:1.0.0-0123456789ab
  refused "a pulled image" "must match localhost/apporo-cf-tunnel:" image_ref_with docker.io/cloudflare/cloudflared:2026.6.1
  (image_ref_with localhost/apporo-cf-tunnel:1.0.0-0123456789ab) || die_t "our own build must be accepted"
}

# ---- the scripts, on a HOME that also holds a WOOW install ---------------------------------
t_install_refuses_a_woow_volume_before_anything() {
  sandbox
  our_env CF_DATA_VOLUME cf_data
  refused "install.sh with CF_DATA_VOLUME cf_data" "never adopts" bash "$REPO/scripts/install.sh"
  never_called 'podman (build|volume|image|unshare|pull)|systemctl --user (start|restart|stop|enable|disable|daemon-reload)'
  [[ ! -e $HOME/.config/containers/systemd/apporo-cf-tunnel.container ]] || die_t "a unit was installed"
  untouched
}

t_install_refuses_a_woow_htpasswd() {
  sandbox
  our_env AUTH_HTPASSWD '%h/.config/woow-cf-tunnel/htpasswd'
  refused "install.sh --with-auth, AUTH_HTPASSWD in WOOW's dir" "never writes there" \
    bash "$REPO/scripts/install.sh" --with-auth
  never_called 'podman (build|unshare|pull)'
  untouched
}

t_install_refuses_woows_image() {
  sandbox
  our_env
  refused "install.sh --image <WOOW's image>" "must match localhost/apporo-cf-tunnel:" \
    bash "$REPO/scripts/install.sh" --image localhost/woow-cf-tunnel:1.2.1-e6226c5aaaaa
  never_called 'podman (build|image|volume|unshare|pull|run)'
  untouched
}

t_backup_refuses_a_woow_volume() {
  sandbox
  installed_volume cf_data
  refused "backup.sh, our unit naming cf_data" "never exports" bash "$REPO/scripts/backup.sh"
  rm -f "$HOME/.config/containers/systemd/apporo-cf-tunnel-data.volume"
  our_env CF_DATA_VOLUME woow_cloudflare_tunnel_webgui_cf_data
  refused "backup.sh, our env naming WOOW's compose volume" "never exports" bash "$REPO/scripts/backup.sh"
  never_called 'podman (volume|ps)'
  untouched
}

# our tarball holds our tunnel token: never written where WOOW's restore would find it
t_backup_never_writes_into_woows_dirs() {
  sandbox
  installed_volume apporo_cf_data
  local d
  for d in "$HOME/backups/woow-cf-tunnel" "$HOME/.config/woow-cf-tunnel/backups"; do
    refused "backup.sh --dir $d" "never writes its backups there" bash "$REPO/scripts/backup.sh" --dir "$d"
  done
  never_called 'podman (volume|ps)'
  untouched
  bash "$REPO/scripts/backup.sh" >/dev/null 2>&1 || die_t "backup.sh into our own dir failed"
  has "$(cat "$STUB_LOG")" "podman volume export apporo_cf_data -o $HOME/backups/apporo-cf-tunnel/apporo_cf_data-" "the backup"
  untouched
}

t_restore_refuses_a_woow_volume() {
  sandbox
  installed_volume woow_cloudflare_tunnel_webgui_cf_data
  printf 'tar\n' >"$HOME/restore-me.tar"
  refused "restore.sh into WOOW's volume" "never restores into" \
    bash "$REPO/scripts/restore.sh" "$HOME/restore-me.tar" --yes --force
  never_called 'podman volume|systemctl --user (start|stop|restart)'
  untouched
}

t_uninstall_purge_refuses_a_woow_volume() {
  sandbox
  installed_volume cf_data
  refused "uninstall.sh --purge, our unit naming cf_data" "never deletes" \
    bash "$REPO/scripts/uninstall.sh" --purge --yes
  never_called 'podman volume|systemctl --user (stop|disable|daemon-reload)'
  [[ -f $HOME/.config/containers/systemd/apporo-cf-tunnel-data.volume ]] || die_t "the refusal still removed our unit"
  untouched
}

# A real uninstall --purge next to WOOW's install: the files in our manifest go, our volume is
# backed up and removed; WOOW's units, manifest, volume and backups stay.
t_uninstall_purge_removes_only_ours() {
  sandbox
  our_env
  local q=$HOME/.config/containers/systemd m=$HOME/.local/state/woow-quadlet/apporo-cf-tunnel calls
  mkdir -p "$m"
  printf '[Container]\nContainerName=apporo-cf-tunnel\nVolume=apporo-cf-tunnel-data.volume:/data\n' >"$q/apporo-cf-tunnel.container"
  installed_volume apporo_cf_data
  sha256sum "$q/apporo-cf-tunnel.container" "$q/apporo-cf-tunnel-data.volume" >"$m/manifest"
  bash "$REPO/scripts/uninstall.sh" --purge --yes || die_t "uninstall.sh --purge failed"
  [[ ! -e $q/apporo-cf-tunnel.container && ! -e $q/apporo-cf-tunnel-data.volume ]] || die_t "our units are still installed"
  calls=$(cat "$STUB_LOG")
  has "$calls" "podman volume export apporo_cf_data" "the final backup"
  has "$calls" "podman volume rm apporo_cf_data" "the purge"
  has "$calls" "systemctl --user stop apporo-cf-tunnel.service" "the stop"
  untouched
}

# passwd_with [VAR=value]...: scripts/auth-passwd.sh admin, the password piped in
# shellcheck disable=SC2120 # the VAR=value arguments come through refused "$@"
passwd_with() { printf 'correct-horse-battery\n' | env "$@" bash "$REPO/scripts/auth-passwd.sh" admin; }

t_auth_passwd_never_writes_woows_htpasswd() {
  sandbox
  # A WOOW env file may name an htpasswd outside ~/.config/woow-cf-tunnel, where no check of
  # the AUTH_HTPASSWD value can tell it is WOOW's: the env file itself is refused.
  mkdir -p "$HOME/.config/nginx"
  printf 'admin:woow-hash-placeholder\n' >"$HOME/.config/nginx/htpasswd"
  printf 'AUTH_HTPASSWD=%%h/.config/nginx/htpasswd\n' >>"$HOME/.config/woow-cf-tunnel/woow-cf-tunnel.env"
  BEFORE=$(woow_state)
  refused "auth-passwd.sh with ENV_FILE set to WOOW's env file" "never reads it" \
    passwd_with ENV_FILE="$HOME/.config/woow-cf-tunnel/woow-cf-tunnel.env"
  never_called 'chgrp'
  our_env AUTH_HTPASSWD '%h/.config/woow-cf-tunnel/htpasswd'
  refused "auth-passwd.sh, our env pointing at WOOW's htpasswd" "never writes there" passwd_with
  our_env
  # shellcheck disable=SC2119 # no VAR=value: our own env file
  passwd_with >/dev/null || die_t "auth-passwd.sh must write our own htpasswd"
  [[ -s $HOME/.config/apporo-cf-tunnel/htpasswd ]] || die_t "our htpasswd was not written"
  has "$(cat "$STUB_LOG")" "podman unshare chgrp 101 $HOME/.config/apporo-cf-tunnel/htpasswd" "the nginx group on ours"
  untouched
}

# WOOW's backups hold WOOW's tunnel token; restored into our volume, it would run a second
# connector on WOOW's tunnel. Refused by directory and by the volume named in the file name.
t_restore_refuses_a_woow_backup() {
  sandbox
  installed_volume apporo_cf_data
  local woow_tar=$HOME/backups/woow-cf-tunnel/cf_data-20261101-000000.tar n ours
  refused "restore.sh of WOOW's backup" "never restores it" \
    bash "$REPO/scripts/restore.sh" "$woow_tar" --yes --force
  mkdir -p "$HOME/elsewhere"
  for n in cf_data woow_cloudflare_tunnel_webgui_cf_data cf-tunnel-webgui-data; do
    cp "$woow_tar" "$HOME/elsewhere/$n-20261101-000000.tar"
    refused "restore.sh of a copy exported from WOOW's volume $n" "never restores it" \
      bash "$REPO/scripts/restore.sh" "$HOME/elsewhere/$n-20261101-000000.tar" --yes --force
  done
  never_called 'podman volume|systemctl --user (start|stop|restart)'
  untouched
  # a backup of ours still restores
  ours=$HOME/backups/apporo-cf-tunnel/apporo_cf_data-20261101-000000.tar
  mkdir -p "${ours%/*}"
  printf '{}\n' >"$HOME/settings.json"
  tar -cf "$ours" -C "$HOME" settings.json
  bash "$REPO/scripts/restore.sh" "$ours" --yes >/dev/null 2>&1 || die_t "restore.sh of our own backup failed"
  has "$(cat "$STUB_LOG")" "podman volume import apporo_cf_data $ours" "the restore"
  untouched
}

# WOOW's GUI keeps upgrade runs of its own, ~/.local/state/woow-cf-tunnel/upgrade-*. Its
# watchdog acts on ROLLBACK and COMMIT there, and its run.env names its units. A RUN argument
# (or CF_STATE_ROOT) pointing there is refused; only $CF_STATE_ROOT/upgrade-* is ours.
t_upgrade_refuses_woows_runs() {
  sandbox
  local wrun=$HOME/$WOOW_RUN c ours=$HOME/.local/state/apporo-cf-tunnel/upgrade-20261101-000000
  for c in abort commit swap status --rollback; do
    refused "upgrade.sh $c <WOOW's run>" "is not an apporo-cf-tunnel upgrade run" \
      bash "$REPO/scripts/upgrade.sh" "$c" "$wrun"
  done
  refused "upgrade.sh abort, CF_STATE_ROOT at WOOW's state dir" "never acts on its runs" \
    env CF_STATE_ROOT="${wrun%/*}" bash "$REPO/scripts/upgrade.sh" abort
  mkdir -p "$HOME/elsewhere/upgrade-20261101-000000"
  refused "upgrade.sh commit <a run dir outside our state dir>" "is not an apporo-cf-tunnel upgrade run" \
    bash "$REPO/scripts/upgrade.sh" commit "$HOME/elsewhere/upgrade-20261101-000000"
  [[ ! -e $HOME/elsewhere/upgrade-20261101-000000/COMMIT ]] || die_t "commit reached a run that is not ours"
  never_called 'systemd-run|systemctl --user (start|stop|restart|daemon-reload)|podman'
  untouched
  # a run of ours is still accepted
  mkdir -p "$ours"
  bash "$REPO/scripts/upgrade.sh" abort "$ours" >/dev/null || die_t "abort of our own run failed"
  [[ -e $ours/ROLLBACK ]] || die_t "abort did not reach our own run"
}

# --stage replaces the directory --stage-dir names. One of WOOW's, typed or behind a symlink,
# is refused before install.sh does anything else (tests/harness covers a directory that
# holds more than an earlier stage).
t_install_refuses_a_woow_stage_dir() {
  sandbox
  our_env
  local d
  ln -s "$HOME/.config/woow-cf-tunnel" "$HOME/stage-link"
  for d in "$HOME/.local/state/woow-cf-tunnel/staged" "$HOME/.config/woow-cf-tunnel" "$HOME/$WOOW_RUN" \
    "$HOME/stage-link" "$HOME/stage-link/staged"; do
    refused "install.sh --stage-dir $d" "this package never writes there" \
      bash "$REPO/scripts/install.sh" --stage --stage-dir "$d"
  done
  never_called 'podman (build|image|volume|unshare|pull)|systemctl --user (start|restart|stop|enable|disable|daemon-reload)'
  untouched
}

# WOOW's GUI is stopped here: nothing listens on any port (the ss stub). Its default ports are
# refused anyway, before anything is built or installed: an install on one would keep WOOW's
# GUI or connector from binding it when it next starts.
t_install_refuses_woows_ports_while_it_is_stopped() {
  sandbox
  local kv
  for kv in UVICORN_PORT=18000 CF_METRICS_ADDR=127.0.0.1:20241 AUTH_LISTEN=127.0.0.1:8888; do
    our_env "${kv%%=*}" "${kv#*=}"
    refused "install.sh with $kv" "is a default port of WOOW's" bash "$REPO/scripts/install.sh"
    refused "install.sh --stage with $kv" "is a default port of WOOW's" bash "$REPO/scripts/install.sh" --stage
  done
  never_called 'podman (build|volume|image|unshare|pull)|systemctl --user (start|restart|stop|enable|disable|daemon-reload)'
  [[ ! -e $HOME/.config/containers/systemd/apporo-cf-tunnel.container ]] || die_t "a unit was installed"
  untouched
}

# A volume name no guard can place (WOOW's operator may name its volume anything) is judged by
# what podman says about the volume: another app's ownership label, a compose project, or a
# container other than apporo-cf-tunnel that mounts it, running or stopped. install.sh,
# backup.sh, restore.sh and uninstall.sh --purge refuse it before they use it.
t_scripts_refuse_a_volume_that_is_not_ours() {
  sandbox
  local tar=$HOME/restore-me.tar s want
  printf 'tar\n' >"$tar"
  for s in "STUB_VOLUME_LABELS=tunnel_data=woow-cf-tunnel|is labelled for 'woow-cf-tunnel'" \
    "STUB_VOLUME_COMPOSE=tunnel_data=cloudflare_tunnel_webgui|was created by compose project 'cloudflare_tunnel_webgui'" \
    "STUB_VOLUME_USERS=tunnel_data=cf-tunnel-webgui|is mounted by container 'cf-tunnel-webgui'" \
    "STUB_VOLUME_USERS=tunnel_data=apporo-cf-tunnel tunnel_data=woow-cf-tunnel|is mounted by container 'woow-cf-tunnel'"; do
    unset STUB_VOLUME_LABELS STUB_VOLUME_COMPOSE STUB_VOLUME_USERS
    export "${s%%|*}"
    want="volume tunnel_data ${s#*|}"
    our_env CF_DATA_VOLUME tunnel_data
    refused "install.sh: $want" "$want" bash "$REPO/scripts/install.sh"
    installed_volume tunnel_data
    refused "backup.sh: $want" "$want" bash "$REPO/scripts/backup.sh"
    refused "restore.sh: $want" "$want" bash "$REPO/scripts/restore.sh" "$tar" --yes --force
    refused "uninstall.sh --purge: $want" "$want" bash "$REPO/scripts/uninstall.sh" --purge --yes
  done
  never_called 'podman (build|unshare|pull|volume (create|export|import|rm))|systemctl --user (start|restart|stop|enable|disable|daemon-reload)'
  [[ -f $HOME/.config/containers/systemd/apporo-cf-tunnel-data.volume ]] || die_t "a refusal removed our unit"
  untouched
  # ours: labelled for this app and mounted by its container, or unlabelled and unused (kept
  # by an uninstall without --purge, or re-created by an older restore --replace)
  unset STUB_VOLUME_LABELS STUB_VOLUME_COMPOSE STUB_VOLUME_USERS
  export STUB_VOLUME_LABELS=tunnel_data=apporo-cf-tunnel STUB_VOLUME_USERS=tunnel_data=apporo-cf-tunnel
  bash "$REPO/scripts/backup.sh" >/dev/null 2>&1 || die_t "backup.sh of our own volume failed"
  unset STUB_VOLUME_LABELS STUB_VOLUME_USERS
  # (a directory of its own: two tarballs of one volume within a second would share a name)
  bash "$REPO/scripts/backup.sh" --dir "$HOME/backups/second" >/dev/null 2>&1 \
    || die_t "backup.sh of our unlabelled volume failed"
  [[ $(grep -c "^podman volume export tunnel_data -o " "$STUB_LOG") == 2 ]] || die_t "our volume was not backed up twice"
  # restore --replace re-creates ours with this app's label, so it stays recognisably ours
  tar -cf "$tar" -C "$HOME" .config/apporo-cf-tunnel/apporo-cf-tunnel.env
  bash "$REPO/scripts/restore.sh" "$tar" --yes --replace >/dev/null 2>&1 || die_t "restore.sh --replace failed"
  has "$(cat "$STUB_LOG")" "podman volume create --label io.woowtech.app=apporo-cf-tunnel tunnel_data" "the re-created volume"
  untouched
}

# restore.sh, from a shell that carries WOOW's settings (woow_shell): it asks about, and would
# stop and start, this app's unit only
t_restore_ignores_woows_exported_settings() {
  sandbox
  woow_shell
  installed_volume apporo_cf_data
  local ours=$HOME/backups/apporo-cf-tunnel/apporo_cf_data-20261101-000000.tar calls
  mkdir -p "${ours%/*}"
  printf '{}\n' >"$HOME/settings.json"
  tar -cf "$ours" -C "$HOME" settings.json
  bash "$REPO/scripts/restore.sh" "$ours" --yes >/dev/null 2>&1 || die_t "restore.sh of our own backup failed"
  calls=$(cat "$STUB_LOG")
  has "$calls" "systemctl --user is-active --quiet apporo-cf-tunnel.service" "the unit restore.sh stops"
  has "$calls" "podman volume import apporo_cf_data $ours" "the restore"
  untouched
}

# uninstall.sh --purge, from a shell that carries WOOW's settings, with both tunnels up: it
# counts the edge connections on our metrics address, stops our unit, removes our volume
t_uninstall_purge_ignores_woows_exported_settings() {
  sandbox
  woow_shell
  our_env
  local q=$HOME/.config/containers/systemd m=$HOME/.local/state/woow-quadlet/apporo-cf-tunnel calls
  mkdir -p "$q" "$m"
  tunnel_unit 1.0.0-0123456789ab >"$q/apporo-cf-tunnel.container"
  installed_volume apporo_cf_data
  sha256sum "$q/apporo-cf-tunnel.container" "$q/apporo-cf-tunnel-data.volume" >"$m/manifest"
  STUB_ACTIVE="woow-cf-tunnel.service apporo-cf-tunnel.service" \
    bash "$REPO/scripts/uninstall.sh" --purge --yes >/dev/null 2>&1 || die_t "uninstall.sh --purge failed"
  calls=$(cat "$STUB_LOG")
  has "$calls" "curl http://127.0.0.1:20341/ready" "the edge-connection count on our metrics address"
  has "$calls" "systemctl --user stop apporo-cf-tunnel.service" "the stop"
  has "$calls" "podman volume rm apporo_cf_data" "the purge"
  never_called '^curl http://127\.0\.0\.1:(18000|20241|8888)/'
  untouched
}

# upgrade.sh from a shell that carries WOOW's settings: the run.env our prepare step records,
# and so swap, the detached watchdog and --rollback, name this app's unit and container only.
# The stubbed unit never comes up, so the watchdog and --rollback run to a rollback result.
t_upgrade_ignores_woows_exported_settings() {
  sandbox
  woow_shell
  local st=$HOME/.local/state/apporo-cf-tunnel calls r
  for r in 1 2 3; do prepared_run "$st/upgrade-20261101-00000$r"; done
  grep -qx 'NEW_UNIT=apporo-cf-tunnel.service' "$st/upgrade-20261101-000001/run.env" || die_t "run.env does not record our unit"
  grep -qx 'NEW_CONTAINER=apporo-cf-tunnel' "$st/upgrade-20261101-000001/run.env" || die_t "run.env does not record our container"
  bash "$REPO/scripts/upgrade.sh" swap "$st/upgrade-20261101-000001" >/dev/null 2>&1 || die_t "upgrade.sh swap failed"
  bash "$st/upgrade-20261101-000002/bin/upgrade.sh" __watchdog "$st/upgrade-20261101-000002" >/dev/null 2>&1
  bash "$REPO/scripts/upgrade.sh" --rollback "$st/upgrade-20261101-000003" >/dev/null 2>&1
  for r in 2 3; do
    grep -q '^ROLL' "$st/upgrade-20261101-00000$r/RESULT" 2>/dev/null \
      || die_t "run $r did not run its course: $(cat "$st/upgrade-20261101-00000$r/RESULT" 2>/dev/null)"
  done
  calls=$(cat "$STUB_LOG")
  has "$calls" "systemd-run --user --collect --unit=apporo-cf-tunnel-upgrade-20261101-000001" "the swap"
  has "$calls" "systemctl --user restart apporo-cf-tunnel.service" "the watchdog's restart"
  has "$calls" "systemctl --user is-active --quiet apporo-cf-tunnel.service" "the gate"
  never_called '^curl http://127\.0\.0\.1:(18000|20241|8888)/'
  untouched
}

# A run.env that names another unit or container (edited by hand, or recorded by a shell that
# carried WOOW's names) is refused by swap, the watchdog and --rollback before any unit is
# touched. The refused watchdog still leaves a RESULT, so a following upgrade.sh stops.
t_upgrade_refuses_a_run_env_naming_another_unit() {
  sandbox
  local run=$HOME/.local/state/apporo-cf-tunnel/upgrade-20261101-000000 kv
  prepared_run "$run"
  cp "$run/run.env" "$HOME/run.env.ours"
  : >"$STUB_LOG"
  for kv in NEW_UNIT=woow-cf-tunnel.service NEW_CONTAINER=woow-cf-tunnel UNITS=woow-cf-tunnel.service \
    'PREV_UNITS=apporo-cf-tunnel.service woow-cf-tunnel.service' EXTRA_UNITS=cf-tunnel-webgui.service \
    'UNITS=apporo-cf-tunnel.service woow-cf-tunnel-auth.service'; do
    cp "$HOME/run.env.ours" "$run/run.env"
    printf '%s=%q\n' "${kv%%=*}" "${kv#*=}" >>"$run/run.env"
    rm -f "$run/PHASE" "$run/RESULT"
    refused "upgrade.sh swap, $kv" "not this app's" bash "$REPO/scripts/upgrade.sh" swap "$run"
    refused "upgrade.sh --rollback, $kv" "not this app's" bash "$REPO/scripts/upgrade.sh" --rollback "$run"
    refused "the watchdog, $kv" "not this app's" bash "$run/bin/upgrade.sh" __watchdog "$run"
    grep -q '^ABORTED_BEFORE_CHANGE' "$run/RESULT" || die_t "the refused watchdog left no RESULT ($kv)"
  done
  never_called 'systemd-run|systemctl|podman'
  untouched
}

case_ units-and-config-name-only-this-app t_units_and_config_name_only_this_app
case_ scripts-name-woow-only-in-the-guard t_scripts_name_woow_only_in_the_guard
case_ defaults-are-not-woows t_defaults_are_not_woows
# An operator who symlinked our config or state directory to WOOW's, to carry its settings
# over: every script stops before it writes, backs up or deletes anything there.
t_scripts_refuse_own_dirs_that_lead_into_woows() {
  sandbox
  ln -s "$HOME/.config/woow-cf-tunnel" "$HOME/.config/apporo-cf-tunnel"
  refused "install.sh, config dir a symlink to WOOW's" "leads into a directory of WOOW's" \
    bash "$REPO/scripts/install.sh"
  # shellcheck disable=SC2119 # no VAR=value: our own (symlinked) env file
  refused "auth-passwd.sh, config dir a symlink to WOOW's" "leads into a directory of WOOW's" passwd_with
  refused "backup.sh, config dir a symlink to WOOW's" "leads into a directory of WOOW's" \
    bash "$REPO/scripts/backup.sh"
  rm -- "$HOME/.config/apporo-cf-tunnel"
  ln -s "$HOME/.local/state/woow-cf-tunnel" "$HOME/.local/state/apporo-cf-tunnel"
  refused "install.sh --stage, state dir a symlink to WOOW's" "leads into a directory of WOOW's" \
    bash "$REPO/scripts/install.sh" --stage
  refused "uninstall.sh --purge, state dir a symlink to WOOW's" "leads into a directory of WOOW's" \
    bash "$REPO/scripts/uninstall.sh" --purge
  never_called 'podman (build|volume|image|unshare|pull|rm)|systemctl --user (start|restart|stop|enable|disable|daemon-reload)'
  untouched
}

case_ env-guard-refuses-woow-volumes t_env_guard_refuses_woow_volumes
case_ env-guard-refuses-woow-ports t_env_guard_refuses_woow_ports
case_ env-guard-refuses-woow-paths t_env_guard_refuses_woow_paths
case_ image-guard-refuses-woows t_image_guard_refuses_woows
case_ install-refuses-a-woow-volume-before-anything t_install_refuses_a_woow_volume_before_anything
case_ install-refuses-a-woow-htpasswd t_install_refuses_a_woow_htpasswd
case_ install-refuses-woows-image t_install_refuses_woows_image
case_ backup-refuses-a-woow-volume t_backup_refuses_a_woow_volume
case_ backup-never-writes-into-woows-dirs t_backup_never_writes_into_woows_dirs
case_ restore-refuses-a-woow-volume t_restore_refuses_a_woow_volume
case_ uninstall-purge-refuses-a-woow-volume t_uninstall_purge_refuses_a_woow_volume
case_ uninstall-purge-removes-only-ours t_uninstall_purge_removes_only_ours
case_ auth-passwd-never-writes-woows-htpasswd t_auth_passwd_never_writes_woows_htpasswd
case_ restore-refuses-a-woow-backup t_restore_refuses_a_woow_backup
case_ upgrade-refuses-woows-runs t_upgrade_refuses_woows_runs
case_ install-refuses-a-woow-stage-dir t_install_refuses_a_woow_stage_dir
case_ install-refuses-woows-ports-while-it-is-stopped t_install_refuses_woows_ports_while_it_is_stopped
case_ scripts-refuse-a-volume-that-is-not-ours t_scripts_refuse_a_volume_that_is_not_ours
case_ restore-ignores-woows-exported-settings t_restore_ignores_woows_exported_settings
case_ uninstall-purge-ignores-woows-exported-settings t_uninstall_purge_ignores_woows_exported_settings
case_ upgrade-ignores-woows-exported-settings t_upgrade_ignores_woows_exported_settings
case_ upgrade-refuses-a-run-env-naming-another-unit t_upgrade_refuses_a_run_env_naming_another_unit
case_ scripts-refuse-own-dirs-that-lead-into-woows t_scripts_refuse_own_dirs_that_lead_into_woows

printf '\n%s: %d passed, %d failed\n' "${0##*/}" "$npass" "$nfail"
((nfail == 0)) || { printf 'failed: %s\n' "${FAILED[*]}"; exit 1; }
