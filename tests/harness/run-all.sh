#!/usr/bin/env bash
# tests/harness/run-all.sh: control-flow tests for install.sh, upgrade.sh and uninstall.sh
# against mocked podman / systemctl / curl / ss / loginctl / systemd-run.
# Needs bash, git, python3, the podman 4.9.3 Quadlet generator and systemd-analyze
# (apt install podman); creates no containers and touches nothing outside a temp dir.
#
#   tests/harness/run-all.sh [filter]     run the cases whose name matches the filter
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
export HARNESS_TMP
HARNESS_TMP=$(mktemp -d "${TMPDIR:-/tmp}/cf-harness.XXXXXX")
trap 'rm -rf "$HARNESS_TMP"' EXIT
# shellcheck source=common.sh
. "$HERE/common.sh"
# shellcheck source=cases-install.sh
. "$HERE/cases-install.sh"
filter=${1:-}
fails=0 ran=0
snapshot_repo

run_case() {
  local name=$1 out rc=0
  [[ -z $filter || $name == *"$filter"* ]] || return 0
  ran=$((ran + 1))
  out=$( (A_FAILS=0; "$name") 2>&1) || rc=$?
  if ((rc == 0)); then
    echo "ok    ${name#case_}"
  else
    echo "FAIL  ${name#case_}"
    printf '%s\n' "$out" | tail -n 30 | sed 's/^/      /'
    fails=$((fails + 1))
  fi
}

for c in "${INSTALL_CASES[@]}"; do run_case "$c"; done

# expect <kind> <scenario> <mode> <regex>...: run the scenario once; every regex must match
expect() {
  local kind=$1 sc=$2 mode=$3 name="$1/$2/$3" out re bad=''
  shift 3
  [[ -z $filter || $name == *"$filter"* ]] || return 0
  ran=$((ran + 1))
  out=$(SOAKS=${SOAKS:-4} bash "$HERE/scenario.sh" "$kind" "$sc" "$mode" 2>&1)
  for re in "$@"; do grep -qE "$re" <<<"$out" || bad+="
      wanted /$re/"; done
  if [[ -z $bad ]]; then
    echo "ok    $name"
  else
    echo "FAIL  $name$bad"
    printf '%s\n' "$out" | tail -n 20 | sed 's/^/      /'
    fails=$((fails + 1))
  fi
}

# upgrade of an installed apporo-cf-tunnel: commits
expect upgrade happy direct 'phase=committed' 'images: running=new installed=new'
expect upgrade happy swap 'phase=committed'
# automatic rollbacks, back to the units that were installed before (the gate and the soak
# in scripts/lib/cf-gate.sh)
expect upgrade bad_image direct 'ROLLED_BACK \(gate timeout' 'images: running=old installed=old' 'new_active=1'
expect upgrade never_ready direct 'ROLLED_BACK \(gate timeout.*readyConnections=0' 'images: running=old installed=old'
expect upgrade version_changed direct 'ROLLED_BACK \(gate timeout.*config version 29 != baseline 28'
expect upgrade public_mismatch direct 'ROLLED_BACK \(gate timeout.*public hostnames differ'
expect upgrade unhealthy direct 'ROLLED_BACK \(gate timeout.*podman health'
expect upgrade happy sigterm 'ROLLED_BACK \(watchdog exited unexpectedly'
expect upgrade happy soak_restart 'ROLLED_BACK \(apporo-cf-tunnel.service restarted during soak'
SOAKS=10 expect upgrade happy soak_lost 'ROLLED_BACK \(tunnel not ready for 3'
expect upgrade never_ready abort 'ROLLED_BACK \(operator abort'
expect upgrade happy postcommit_rollback 'ROLLED_BACK \(manual rollback' 'images: running=old installed=old'
# refusals that change nothing
expect upgrade noop direct 'no upgrade run started' 'already up to date'
expect upgrade broken_config direct 'no upgrade run started' 'baseline is not usable'
# the upgrade also moves the GUI and the metrics port: the baseline reads the running tunnel
# on the ports it was installed with (and so finds its edge connections), the gate reads the
# new ports, and a rollback checks the old ports again
expect upgrade ports direct 'phase=committed' 'baseline: ready_conns=4' 'ports: gui=18101 metrics=127.0.0.1:20342'
expect upgrade ports_never_ready direct 'ROLLED_BACK \(gate timeout.*readyConnections=0' \
  'images: running=old installed=old' 'ports: gui=18100 metrics=127.0.0.1:20341'
# WOOW's GUI running on the same host: committing, rolling back automatically and rolling
# back by hand all leave it exactly as it was
expect upgrade coexist direct 'phase=committed' 'images: running=new installed=new' 'woow=untouched'
expect upgrade coexist swap 'phase=committed' 'woow=untouched'
expect upgrade coexist_never_ready direct 'ROLLED_BACK \(gate timeout' 'images: running=old installed=old' 'woow=untouched'
expect upgrade coexist postcommit_rollback 'ROLLED_BACK \(manual rollback' 'woow=untouched'
# ... and from a shell that carries WOOW's unit, container and ports: the run still prepares,
# restarts, gates, soaks and rolls back this app's units only
expect upgrade coexist_env direct 'phase=committed' 'images: running=new installed=new' 'woow=untouched'
expect upgrade coexist_env swap 'phase=committed' 'woow=untouched'
expect upgrade coexist_env_never_ready direct 'ROLLED_BACK \(gate timeout' 'images: running=old installed=old' 'woow=untouched'
expect upgrade coexist_env postcommit_rollback 'ROLLED_BACK \(manual rollback' 'woow=untouched'

if ((fails == 0)); then echo "harness: $ran case(s) passed"; else echo "harness: $fails of $ran case(s) failed"; exit 1; fi
