#!/usr/bin/env bash
# tests/harness/scenario.sh: run one upgrade.sh scenario against the mocks and print its
# outcome (phase, result, end state). Called by run-all.sh; usable on its own for debugging:
#
#   HARNESS_TMP=$(mktemp -d) tests/harness/scenario.sh upgrade happy direct
#
#   scenario.sh upgrade <scenario> <mode>   modes: direct swap sigterm abort
#                                                  soak_restart soak_lost postcommit_rollback
# Each scenario installs the current commit, makes a new one and upgrades to it. Scenarios
# pick how the NEW image behaves (MOCK_NEW_IMAGE): happy, never_ready, version_changed,
# public_mismatch, unhealthy, bad_image; or what the run meets: broken_config (an unreadable
# /config at baseline time), noop (nothing to upgrade).
#   coexist[_<scenario>]  the same with WOOW's GUI running on this host (woow_host): the
#                         report adds woow=untouched when nothing reached for it
#   env[_<scenario>]      ... from a shell that carries WOOW's unit, container and ports
#                         (woow_shell); after coexist, as in coexist_env[_<scenario>]
#   ports[_<scenario>]    the upgrade also moves the GUI and the metrics port (18101,
#                         127.0.0.1:20342); the report shows where the tunnel listens at the end
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=common.sh
. "$HERE/common.sh"
kind=$1 sc=$2 mode=${3:-direct}
[[ $kind == upgrade ]] || { echo "scenario.sh: unknown kind '$kind' (this fork has no legacy migration)" >&2; exit 64; }
old_image='' new_image='' woow=0 ports=0
snapshot_repo
sandbox "$kind-$sc-$mode"
if [[ $sc == coexist || $sc == coexist_* ]]; then
  woow=1
  woow_host
  sc=${sc#coexist}
  sc=${sc#_}
  sc=${sc:-happy}
fi
if [[ $sc == env || $sc == env_* ]]; then
  woow_shell
  sc=${sc#env}
  sc=${sc#_}
  sc=${sc:-happy}
fi
if [[ $sc == ports || $sc == ports_* ]]; then
  ports=1
  sc=${sc#ports}
  sc=${sc#_}
  sc=${sc:-happy}
fi
export MOCK_SCENARIO=$sc
# Short timings: the gate and soak logic is what is under test, not the clock.
export GATE_TIMEOUT=8 POLL=1 SOAK_SECONDS=${SOAKS:-4} SOAK_POLL=1 \
  RESTORE_TIMEOUT=6 CURL_PUBLIC_TIMEOUT=1 EXPECT_CONNS=4 MOCK_WARMUP=2
RUN=''

wait_phase() { # wait_phase <phase> <run>
  local n=0
  while ((n++ < 80)); do
    [[ $(cat "$2/PHASE" 2>/dev/null) == "$1" ]] && return 0
    sleep 0.25
  done
  return 1
}
wait_pid() { while kill -0 "$1" 2>/dev/null; do sleep 0.2; done; }

report() {
  local q
  q=$(QDIR)
  printf '  phase=%s\n  result=%s\n' "$(cat "$RUN/PHASE" 2>/dev/null)" "$(cat "$RUN/RESULT" 2>/dev/null)"
  printf '  end: new_active=%s auth_active=%s quadlet_files=[%s] image=%s backups=%s\n' \
    "$(cat "$MOCK_STATE/units/apporo-cf-tunnel.service/active" 2>/dev/null || echo 0)" \
    "$(cat "$MOCK_STATE/units/apporo-cf-tunnel-auth.service/active" 2>/dev/null || echo 0)" \
    "$(find "$q" -maxdepth 1 -type f -name 'apporo-cf-tunnel*' -printf '%f ' 2>/dev/null)" \
    "$(cat "$MOCK_STATE/running_image" 2>/dev/null || echo -)" \
    "$(find "$HOME/backups" -name '*.tar' 2>/dev/null | wc -l)"
  lbl() {
    case $1 in "$old_image") echo old ;; "$new_image") echo new ;; *) echo "other($1)" ;; esac
  }
  printf '  images: running=%s installed=%s\n' \
    "$(lbl "$(cat "$MOCK_STATE/running_image" 2>/dev/null)")" \
    "$(lbl "$(sed -n 's/^Image=//p' "$q/apporo-cf-tunnel.container" 2>/dev/null)")"
  printf '  ports: gui=%s metrics=%s\n' "$(cat "$MOCK_STATE/running_gui" 2>/dev/null)" \
    "$(cat "$MOCK_STATE/running_metrics" 2>/dev/null)"
  printf '  baseline: ready_conns=%s\n' "$(cat "$RUN/ready_conns" 2>/dev/null)"
  if ((woow)); then
    local out
    if out=$(woow_untouched); then echo "  woow=untouched"; else echo "  woow=TOUCHED"; printf '%s\n' "$out"; fi
  fi
  grep -hE 'outage|waiting|ROLLBACK' "$RUN/watchdog.log" 2>/dev/null | head -n 3 | sed 's/^/  log: /'
}

env_file
bash "$R/scripts/install.sh" --allow-dirty >/dev/null 2>&1 || { echo "  setup install failed"; exit 1; }
echo 10 >"$MOCK_STATE/new_ready_calls" # the pre-upgrade tunnel is warmed up
old_image=$(image_ref)
if ((ports)); then
  set_env UVICORN_PORT 18101
  set_env CF_METRICS_ADDR 127.0.0.1:20342
fi
[[ $sc != noop ]] && new_commit "upgrade-$sc"
new_image=$(image_ref)
# from here on, the new build is the one that misbehaves (MOCK_SCENARIO)
[[ $sc != noop ]] && export MOCK_NEW_IMAGE=$new_image
if [[ $sc == bad_image ]]; then
  MOCK_BAD_IMAGE=$(image_ref)
  export MOCK_BAD_IMAGE
fi
up=$(bash "$R/scripts/upgrade.sh" --prepare-only 2>&1)
RUN=$(sed -n 's/^upgrade: RUN=//p' <<<"$up")
if [[ -z $RUN ]]; then
  echo "  no upgrade run started (old=$old_image)"
  grep -E 'up to date|ERROR|FAIL' <<<"$up" | head -n 4 | sed 's/^/    /'
  if ((woow)); then
    if out=$(woow_untouched); then echo "  woow=untouched"; else echo "  woow=TOUCHED"; printf '%s\n' "$out"; fi
  fi
  exit 0
fi
script=$RUN/bin/upgrade.sh

case $mode in
  direct) bash "$script" __watchdog "$RUN" >>"$RUN/direct.log" 2>&1 ;;
  swap)
    bash "$R/scripts/upgrade.sh" swap "$RUN" >/dev/null 2>&1
    wait_pid "$(cat "$MOCK_STATE/detached.pid")" ;;
  postcommit_rollback)
    bash "$script" __watchdog "$RUN" >>"$RUN/direct.log" 2>&1
    echo "  (watchdog result: $(cat "$RUN/RESULT"))"
    bash "$R/scripts/upgrade.sh" --rollback "$RUN" >>"$RUN/direct.log" 2>&1 ;;
  sigterm | abort | soak_restart | soak_lost)
    bash "$script" __watchdog "$RUN" >>"$RUN/direct.log" 2>&1 &
    pid=$!
    want=gating
    [[ $mode == soak_* ]] && want=soaking
    wait_phase "$want" "$RUN" || echo "  never reached phase $want"
    case $mode in
      sigterm) kill -TERM "$pid" ;;
      abort) bash "$R/scripts/upgrade.sh" abort "$RUN" >/dev/null ;;
      soak_restart) echo 1 >"$MOCK_STATE/new_nrestarts" ;;
      soak_lost) touch "$MOCK_STATE/soaking" ;;
    esac
    wait "$pid" ;;
esac
report
