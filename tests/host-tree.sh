#!/usr/bin/env bash
# tests/host-tree.sh: pins the guards about where the scripts run from and what the tunnel
# unit binds (scripts/install.sh, the vendored ql_require_own_lineage, quadlet/):
#   - a script run out of a tree that is not a complete clone of this repo refuses with a
#     diagnosis: a bare "No such file or directory" when the lib is missing, or a deployment
#     tree that was hand-copied (a .deployed-commit stamp) running scripts it did not come with
#   - the tunnel unit hard-codes UVICORN_HOST=127.0.0.1: the GUI has no login, so no rendered
#     value may widen its bind
#
# The probes for the legacy migration (rescue path, legacy unit and uvicorn readers) left with
# scripts/migrate-legacy.sh: this fork has no legacy deployment to move. What the scripts may
# touch on a host shared with WOOW's GUI is pinned by tests/coexist.sh.
#
# No tunnel, no tailnet, no user manager: everything runs against stubs.
#
#   tests/host-tree.sh [filter]
#
# Every case runs in its own subshell (own HOME, own PATH), so:
# shellcheck disable=SC2030,SC2031
# shellcheck source-path=SCRIPTDIR
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
REPO=$(cd "$HERE/.." && pwd -P)
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/cf-host-tree.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
filter=${1:-}
npass=0 nfail=0
FAILED=()

die_t() { printf 'ASSERTION FAILED: %s\n' "$*" >&2; exit 1; }
has() { [[ $1 == *"$2"* ]] || die_t "${3:-output} lacks [$2] in:"$'\n'"$1"; }
hasnt() { [[ $1 != *"$2"* ]] || die_t "${3:-output} must not contain [$2] in:"$'\n'"$1"; }
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

load() {
  # shellcheck source=../scripts/lib/quadlet-lib.sh
  . "$REPO/scripts/lib/quadlet-lib.sh"
}

mk_home() {
  local h
  h=$(mktemp -d "$ROOT/home.XXXXXX")
  mkdir -p "$h/.config/systemd/user"
  printf '%s' "$h"
}

# ---- the tunnel unit really does hard-code a loopback bind --------------------------------
# The GUI has no login and can replace the tunnel token. The bind is a literal in quadlet/,
# not a render var, so no env file can publish it on the LAN.
t_staged_unit_hardcodes_loopback() {
  local u=$REPO/quadlet/apporo-cf-tunnel.container
  has "$(cat "$u")" "Environment=UVICORN_HOST=127.0.0.1" "the hard-coded loopback bind"
  hasnt "$(cat "$REPO/quadlet/render-vars")" "UVICORN_HOST" "quadlet/render-vars"
}

# ---- lineage ------------------------------------------------------------------------------
t_lineage_accepts_this_repo() {
  load
  ql_require_own_lineage "$REPO" WOOWTECH/Apporo_podman_cf_tunnel_webgui \
    || die_t "this checkout must pass its own lineage check"
}

# A copy of the scripts without the lib beside them: say what is wrong, not ENOENT.
t_install_from_a_tree_without_the_lib() {
  HOME=$(mk_home)
  export HOME
  local tree=$HOME/apporo_cf_tunnel_web out rc=0
  mkdir -p "$tree/scripts"
  cp "$REPO/scripts/install.sh" "$tree/scripts/install.sh"
  out=$( (bash "$tree/scripts/install.sh" --help) 2>&1) || rc=$?
  eq "$rc" 1 "install.sh must refuse to run without scripts/lib/quadlet-lib.sh"
  hasnt "$out" "No such file or directory" "the bare ENOENT must be gone"
  has "$out" "not a complete checkout of WOOWTECH/Apporo_podman_cf_tunnel_webgui" "the diagnosis"
}

# A hand-copied deployment tree that does carry a lib copy: the vendored lineage check refuses
# it before anything else runs (here before --help is even parsed).
t_install_from_a_deployed_tree() {
  HOME=$(mk_home)
  export HOME
  local tree=$HOME/apporo_cf_tunnel_web out rc=0
  mkdir -p "$tree/scripts/lib"
  printf '0123456789abcdef\n' >"$tree/.deployed-commit"
  cp "$REPO/scripts/install.sh" "$REPO/scripts/render-args.sh" "$tree/scripts/"
  cp "$REPO/scripts/lib/quadlet-lib.sh" "$tree/scripts/lib/"
  out=$( (bash "$tree/scripts/install.sh" --help) 2>&1) || rc=$?
  eq "$rc" 1 "install.sh must refuse a tree that carries a .deployed-commit stamp"
  has "$out" "pre-Quadlet deployment tree" "the diagnosis"
  has "$out" "WOOWTECH/Apporo_podman_cf_tunnel_webgui" "the repo to clone instead"
}

case_ staged-unit-hardcodes-loopback t_staged_unit_hardcodes_loopback
case_ lineage-accepts-this-repo t_lineage_accepts_this_repo
case_ install-from-a-tree-without-the-lib t_install_from_a_tree_without_the_lib
case_ install-from-a-deployed-tree t_install_from_a_deployed_tree

printf '\n%s: %d passed, %d failed\n' "${0##*/}" "$npass" "$nfail"
((nfail == 0)) || { printf 'failed: %s\n' "${FAILED[*]}"; exit 1; }
