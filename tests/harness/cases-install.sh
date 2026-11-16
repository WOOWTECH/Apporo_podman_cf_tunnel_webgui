# shellcheck shell=bash
# tests/harness/cases-install.sh: cases for scripts/install.sh, scripts/uninstall.sh and
# scripts/auth-passwd.sh (sourced by run-all.sh). Each case_* function returns the number
# of failed assertions.

STAGED() { printf '%s' "$HOME/.local/state/apporo-cf-tunnel/staged"; }
valid_htpasswd() {
  mkdir -p "$HOME/.config/apporo-cf-tunnel"
  echo 'correct-horse-battery' | bash "$R/scripts/auth-passwd.sh" admin >/dev/null
}
# refuses <ERE> <cmd...>: the command fails, and its output says why
refuses() {
  local want=$1 out
  shift
  if out=$("$@" 2>&1); then
    echo "  accepted, want refused: $*"
    A_FAILS=$((A_FAILS + 1))
  elif ! grep -qE -- "$want" <<<"$out"; then
    echo "  refused without /$want/: $*"
    printf '%s\n' "$out" | tail -n 3 | sed 's/^/    /'
    A_FAILS=$((A_FAILS + 1))
  fi
  return 0
}
# fake_cloudflared <pid> <cgroup> <arg>...: a cloudflared process in $SMOKE_PROC
fake_cloudflared() {
  local d=$SMOKE_PROC/$1 cg=$2
  shift 2
  mkdir -p "$d"
  echo cloudflared >"$d/comm"
  printf '0::%s\n' "$cg" >"$d/cgroup"
  printf '%s\0' cloudflared "$@" >"$d/cmdline"
}

case_install_first_run_creates_env_and_stops() {
  sandbox first-run
  t "$R/scripts/install.sh"
  t test "$(stat -c %a "$HOME/.config/apporo-cf-tunnel/apporo-cf-tunnel.env")" = 600
  tnot test -e "$(QDIR)/apporo-cf-tunnel.container"
  t test "$(calls 'podman build')" = 0
  return "$A_FAILS"
}

case_install_stage_builds_and_renders_only() {
  sandbox stage
  env_file
  t "$R/scripts/install.sh" --stage
  local s img
  s=$(STAGED) img=$(image_ref)
  t has_line "Image=$img" "$s/apporo-cf-tunnel.container"
  t has_line 'Pull=never' "$s/apporo-cf-tunnel.container"
  t has_line 'Environment=UVICORN_PORT=18100' "$s/apporo-cf-tunnel.container"
  t has_line 'Environment=CF_METRICS_ADDR=127.0.0.1:20341' "$s/apporo-cf-tunnel.container"
  t has_line 'VolumeName=apporo_cf_data' "$s/apporo-cf-tunnel-data.volume"
  tnot test -e "$s/apporo-cf-tunnel-auth.container"
  t test "$(calls "podman build .* -t $img")" = 1
  t test "$(calls 'systemctl --user (start|restart|stop|enable|disable|daemon-reload)')" = 0
  tnot test -e "$(QDIR)/apporo-cf-tunnel.container"
  # a second --stage reuses the built image
  t "$R/scripts/install.sh" --stage
  t test "$(calls 'podman build')" = 1
  return "$A_FAILS"
}

# WOOW's GUI runs on the same host (both shapes, see woow_host). Upstream refused to install
# next to its legacy unit and pointed at migrate-legacy.sh; this fork has no migration, so the
# install goes ahead on its own names and ports and never so much as asks about WOOW's.
case_install_leaves_a_woow_install_alone() {
  sandbox install-next-to-other
  woow_host
  env_file
  t "$R/scripts/install.sh"
  t test "$(cat "$MOCK_STATE/units/apporo-cf-tunnel.service/active")" = 1
  t has_line 'VolumeName=apporo_cf_data' "$(QDIR)/apporo-cf-tunnel-data.volume"
  valid_htpasswd
  t "$R/scripts/install.sh" --with-auth
  t test "$(cat "$MOCK_STATE/units/apporo-cf-tunnel-auth.service/active")" = 1
  t woow_untouched
  return "$A_FAILS"
}

case_install_fresh_then_idempotent() {
  sandbox fresh
  env_file
  t "$R/scripts/install.sh"
  t test -f "$(QDIR)/apporo-cf-tunnel.container"
  t test -f "$(QDIR)/apporo-cf-tunnel-data.volume"
  t test "$(cat "$MOCK_STATE/units/apporo-cf-tunnel.service/active")" = 1
  t test "$(cat "$MOCK_STATE/running_image")" = "$(image_ref)"
  t grep -q apporo-cf-tunnel.container "$HOME/.local/state/woow-quadlet/apporo-cf-tunnel/manifest"
  : >"$MOCK_STATE/calls.log"
  t "$R/scripts/install.sh"
  t test "$(calls 'systemctl --user (start|restart|stop)')" = 0
  t test "$(calls 'podman build')" = 0
  return "$A_FAILS"
}

case_install_never_rewrites_a_running_tunnel() {
  sandbox running-change
  env_file
  t "$R/scripts/install.sh"
  local before out
  before=$(sha256sum "$(QDIR)/apporo-cf-tunnel.container")
  set_env UVICORN_PORT 18101
  : >"$MOCK_STATE/calls.log"
  out=$("$R/scripts/install.sh" 2>&1) && { echo "  install rewrote a running tunnel"; A_FAILS=$((A_FAILS + 1)); }
  t grep -q 'upgrade.sh' <<<"$out"
  t test "$(sha256sum "$(QDIR)/apporo-cf-tunnel.container")" = "$before"
  t test "$(calls 'systemctl --user (restart|stop)')" = 0
  # a new commit (new image tag) is refused the same way
  set_env UVICORN_PORT 18100
  new_commit install-running
  out=$("$R/scripts/install.sh" 2>&1) && { echo "  install applied a new image to a running tunnel"; A_FAILS=$((A_FAILS + 1)); }
  t grep -q 'upgrade.sh' <<<"$out"
  t test "$(sha256sum "$(QDIR)/apporo-cf-tunnel.container")" = "$before"
  return "$A_FAILS"
}

case_install_refuses_bad_settings() {
  sandbox bad-settings
  env_file
  set_env CF_METRICS_ADDR 0.0.0.0:20341
  tnot "$R/scripts/install.sh"
  set_env CF_METRICS_ADDR 127.0.0.1:20341
  tnot "$R/scripts/install.sh" --image localhost/apporo-cf-tunnel:latest
  tnot "$R/scripts/install.sh" --image localhost/apporo-cf-tunnel:0.0.0-missing
  # WOOW's image is not ours to run, even when it is built on this host
  tnot "$R/scripts/install.sh" --image localhost/woow-cf-tunnel:1.2.1-e6226c5aaaaa
  export MOCK_BUSY_PORTS=18100
  tnot "$R/scripts/install.sh"
  unset MOCK_BUSY_PORTS
  tnot test -e "$(QDIR)/apporo-cf-tunnel.container"
  return "$A_FAILS"
}

# Upstream adopted an existing volume here (cf_data, or its compose project's). Pointing this
# fork at one of WOOW's would run WOOW's tunnel token twice, so it is refused before the build.
case_install_refuses_woow_volumes_and_paths() {
  sandbox refuse-foreign-names
  env_file
  local v
  for v in cf_data woow_cloudflare_tunnel_webgui_cf_data; do
    set_env CF_DATA_VOLUME "$v"
    tnot "$R/scripts/install.sh" --stage
  done
  set_env CF_DATA_VOLUME apporo_cf_data
  set_env AUTH_HTPASSWD '%h/.config/woow-cf-tunnel/htpasswd'
  tnot "$R/scripts/install.sh" --with-auth
  t test "$(calls 'podman (build|unshare chgrp)')" = 0
  tnot test -e "$(STAGED)/apporo-cf-tunnel-data.volume"
  tnot test -e "$(QDIR)/apporo-cf-tunnel.container"
  return "$A_FAILS"
}

# A port the rendered units would listen on must be free, with --stage too (upgrade.sh
# applies what it stages) and while the tunnel runs. Only the ports our running units were
# installed with are theirs. Here another process holds 18101, 20342 and 8990; WOOW's GUI
# runs on its defaults too (woow_host), and those are refused by value whether it runs or not
# (see the next case). Either way it is refused before anything changes.
case_install_refuses_moving_onto_a_busy_port() {
  sandbox busy-port
  woow_host
  export MOCK_BUSY_PORTS="18101 20342 8990"
  env_file
  t "$R/scripts/install.sh"
  valid_htpasswd
  t "$R/scripts/install.sh" --with-auth
  local conf=$HOME/.config/apporo-cf-tunnel/auth-nginx.conf kv
  # unchanged: the ports are held by our own running units, which is fine
  t "$R/scripts/install.sh" --stage
  t "$R/scripts/install.sh"
  for kv in CF_METRICS_ADDR=127.0.0.1:20342 UVICORN_PORT=18101; do
    set_env "${kv%%=*}" "${kv#*=}"
    refuses "port ${kv##*[:=]} is already in use" "$R/scripts/install.sh" --stage
    env_file
  done
  for kv in CF_METRICS_ADDR=127.0.0.1:20241 UVICORN_PORT=18000; do
    set_env "${kv%%=*}" "${kv#*=}"
    refuses "port ${kv##*[:=]} is a default port of WOOW's" "$R/scripts/install.sh" --stage
    env_file
  done
  set_env AUTH_LISTEN 127.0.0.1:8990
  refuses 'port 8990 is already in use' "$R/scripts/install.sh" --stage
  refuses 'port 8990 is already in use' "$R/scripts/install.sh"
  set_env AUTH_LISTEN 127.0.0.1:8888
  refuses "port 8888 is a default port of WOOW's" "$R/scripts/install.sh" --stage
  refuses "port 8888 is a default port of WOOW's" "$R/scripts/install.sh"
  # nothing was installed or staged: both still say 8988
  t has_line '        listen 127.0.0.1:8988;' "$conf"
  t has_line '        listen 127.0.0.1:8988;' "$(STAGED)/config/auth-nginx.conf"
  # a free port is fine
  set_env AUTH_LISTEN 127.0.0.1:8989
  t "$R/scripts/install.sh" --stage
  t grep -q 'listen 127.0.0.1:8989;' "$(STAGED)/config/auth-nginx.conf"
  t woow_untouched
  return "$A_FAILS"
}

# WOOW's GUI is stopped (between its restarts, or in its own upgrade swap): nothing holds its
# default ports, so no busy-port check can see them. They are refused by value, with --stage
# too: an install on one would keep WOOW's GUI or connector from binding it on its next start.
case_install_refuses_woows_ports_while_it_is_stopped() {
  sandbox woow-ports
  env_file
  local kv p
  for kv in UVICORN_PORT=18000 CF_METRICS_ADDR=127.0.0.1:20241 AUTH_LISTEN=127.0.0.1:8888; do
    p=${kv##*[:=]}
    set_env "${kv%%=*}" "${kv#*=}"
    refuses "port $p is a default port of WOOW's" "$R/scripts/install.sh"
    refuses "port $p is a default port of WOOW's" "$R/scripts/install.sh" --stage
    env_file
  done
  t test "$(calls 'podman build')" = 0
  tnot test -e "$(QDIR)/apporo-cf-tunnel.container"
  tnot test -e "$(STAGED)/apporo-cf-tunnel.container"
  return "$A_FAILS"
}

# A volume name the guard in render-args.sh cannot place is judged by what podman says about
# the volume: another app's ownership label, a compose project, or a container other than
# apporo-cf-tunnel that mounts it. `podman volume create --ignore` would otherwise hand it to
# this app's container without a word. A volume nobody else claims is reused, as after an
# uninstall without --purge, and so is ours once our container mounts it.
case_install_refuses_a_volume_that_is_not_ours() {
  sandbox foreign-volume
  env_file
  set_env CF_DATA_VOLUME tunnel_data
  export MOCK_VOLUMES="apporo_cf_data tunnel_data" MOCK_VOLUME_LABELS=tunnel_data=woow-cf-tunnel
  refuses "volume tunnel_data is labelled for 'woow-cf-tunnel'" "$R/scripts/install.sh"
  refuses "volume tunnel_data is labelled for 'woow-cf-tunnel'" "$R/scripts/install.sh" --stage
  export MOCK_VOLUME_LABELS='' MOCK_VOLUME_COMPOSE=tunnel_data=cloudflare_tunnel_webgui
  refuses "volume tunnel_data was created by compose project 'cloudflare_tunnel_webgui'" "$R/scripts/install.sh"
  export MOCK_VOLUME_COMPOSE='' MOCK_VOLUME_USERS=tunnel_data=cf-tunnel-webgui
  refuses "volume tunnel_data is mounted by container 'cf-tunnel-webgui'" "$R/scripts/install.sh"
  t test "$(calls 'podman build')" = 0
  tnot test -e "$(QDIR)/apporo-cf-tunnel.container"
  export MOCK_VOLUME_USERS=''
  t "$R/scripts/install.sh"
  t has_line 'VolumeName=tunnel_data' "$(QDIR)/apporo-cf-tunnel-data.volume"
  t "$R/scripts/install.sh" --stage
  t "$R/scripts/install.sh"
  return "$A_FAILS"
}

# --stage deletes its directory before it writes the new set: only a directory that holds
# what an earlier --stage left there (or nothing) may go. The live Quadlet dir never does.
case_install_stage_dir_is_replaced_only_when_it_is_a_stage() {
  sandbox stage-dir
  env_file
  local d=$HOME/my-stage
  mkdir -p "$d"
  echo keep >"$d/notes.txt"
  tnot "$R/scripts/install.sh" --stage --stage-dir "$d"
  t test -f "$d/notes.txt"
  rm "$d/notes.txt"
  t "$R/scripts/install.sh" --stage --stage-dir "$d"
  t test -f "$d/apporo-cf-tunnel.container"
  t "$R/scripts/install.sh" --stage --stage-dir "$d"
  t "$R/scripts/install.sh"
  local before
  before=$(sha256sum "$(QDIR)/apporo-cf-tunnel.container")
  tnot "$R/scripts/install.sh" --stage --stage-dir "$(QDIR)"
  t test "$(sha256sum "$(QDIR)/apporo-cf-tunnel.container")" = "$before"
  return "$A_FAILS"
}

# tests/smoke.sh fails when this app's cloudflared has the tunnel token on its command line.
# WOOW's older cf-tunnel-webgui connector passes --token, and so does a host-wide
# `cloudflared service install`: neither is this app's to judge, and neither may fail its
# install (install.sh runs smoke.sh after the first start) or a restore.
case_smoke_judges_only_our_cloudflared() {
  sandbox smoke-token
  woow_host
  env_file
  local u=/user.slice/user-1000.slice/user@1000.service out
  local ours=$u/app.slice/apporo-cf-tunnel.service/libpod-payload-0123456789abcdef0123456789abcdef
  fake_cloudflared 3909 "$u/user.slice/libpod-fedcba9876543210fedcba9876543210.scope/container" \
    tunnel --no-autoupdate run --token not-a-real-token
  fake_cloudflared 3950 /system.slice/cloudflared.service tunnel run --token=not-a-real-token
  fake_cloudflared 4100 "$ours" tunnel --metrics 127.0.0.1:20341 run --token-file /data/.tunnel_token
  t "$R/scripts/install.sh"
  out=$(bash "$R/tests/smoke.sh" 2>&1)
  t grep -q "^ok    tunnel token not in the argv of this app's cloudflared" <<<"$out"
  t grep -q '^info  cloudflared outside apporo-cf-tunnel.service (pid 3909, 3950) has a --token argument' <<<"$out"
  # this app's own connector with --token is a failure
  fake_cloudflared 4100 "$ours" tunnel run --token not-a-real-token
  out=$(bash "$R/tests/smoke.sh" 2>&1) && { echo "  smoke passed with --token on our own cloudflared"; A_FAILS=$((A_FAILS + 1)); }
  t grep -q "^FAIL  tunnel token not in the argv of this app's cloudflared" <<<"$out"
  t woow_untouched
  return "$A_FAILS"
}

case_install_auth_refuses_malformed_htpasswd() {
  sandbox auth-bad
  env_file
  t "$R/scripts/install.sh"
  printf 'admin:plaintext-password\n' >"$HOME/.config/apporo-cf-tunnel/htpasswd"
  : >"$MOCK_STATE/calls.log"
  tnot "$R/scripts/install.sh" --with-auth
  tnot test -e "$(QDIR)/apporo-cf-tunnel-auth.container"
  tnot test -e "$HOME/.config/apporo-cf-tunnel/auth-nginx.conf"
  rm -f "$HOME/.config/apporo-cf-tunnel/htpasswd"
  tnot "$R/scripts/install.sh" --with-auth
  return "$A_FAILS"
}

case_install_auth_adds_proxy_without_touching_the_tunnel() {
  sandbox auth-ok
  env_file
  t "$R/scripts/install.sh"
  valid_htpasswd
  : >"$MOCK_STATE/calls.log"
  t "$R/scripts/install.sh" --with-auth
  local conf=$HOME/.config/apporo-cf-tunnel/auth-nginx.conf
  t test -f "$(QDIR)/apporo-cf-tunnel-auth.container"
  t has_line '        listen 127.0.0.1:8988;' "$conf"
  t has_line '            proxy_pass http://127.0.0.1:18100;' "$conf"
  t test "$(stat -c %a "$HOME/.config/apporo-cf-tunnel/htpasswd")" = 640
  t grep -q "chgrp 101 $HOME/.config/apporo-cf-tunnel/htpasswd" "$MOCK_STATE/chgrp.log"
  t test "$(cat "$MOCK_STATE/units/apporo-cf-tunnel-auth.service/active")" = 1
  t test "$(calls 'systemctl --user (restart|stop) .*apporo-cf-tunnel.service')" = 0
  t test "$(calls 'podman pull docker.io/library/nginx:1.30.4-alpine')" = 1
  # stays selected on a plain re-run; --without-auth removes it
  t "$R/scripts/install.sh"
  t test -f "$(QDIR)/apporo-cf-tunnel-auth.container"
  t "$R/scripts/install.sh" --without-auth
  tnot test -e "$(QDIR)/apporo-cf-tunnel-auth.container"
  tnot test -e "$conf"
  t test "$(cat "$MOCK_STATE/units/apporo-cf-tunnel.service/active")" = 1
  return "$A_FAILS"
}

case_install_dry_run_changes_nothing() {
  sandbox dry-run
  t "$R/scripts/install.sh" --dry-run
  tnot test -e "$HOME/.config/apporo-cf-tunnel/apporo-cf-tunnel.env"
  tnot test -e "$(QDIR)"
  t test "$(calls 'podman build')" = 0
  return "$A_FAILS"
}

case_uninstall_keeps_the_data_volume() {
  sandbox uninstall-keep
  env_file
  t "$R/scripts/install.sh"
  : >"$MOCK_STATE/calls.log"
  t "$R/scripts/uninstall.sh"
  tnot test -e "$(QDIR)/apporo-cf-tunnel.container"
  tnot test -e "$(QDIR)/apporo-cf-tunnel-data.volume"
  t test "$(cat "$MOCK_STATE/units/apporo-cf-tunnel.service/active")" = 0
  t test "$(calls 'podman volume rm')" = 0
  t test -f "$HOME/.config/apporo-cf-tunnel/apporo-cf-tunnel.env"
  return "$A_FAILS"
}

case_uninstall_purge_backs_up_then_removes_the_volume() {
  sandbox uninstall-purge
  env_file
  t "$R/scripts/install.sh"
  : >"$MOCK_STATE/calls.log"
  t "$R/scripts/uninstall.sh" --purge --yes
  t test "$(calls 'podman volume export apporo_cf_data')" -ge 1
  t test "$(calls 'podman volume rm apporo_cf_data')" = 1
  tnot test -e "$(QDIR)/apporo-cf-tunnel.container"
  t test "$(find "$HOME/backups" -name 'apporo_cf_data-*.tar' | wc -l)" -ge 1
  return "$A_FAILS"
}

case_uninstall_purge_with_no_metrics_endpoint() {
  # The unit is active but cloudflared is not running (unconfigured, bogus token, crashed),
  # so the edge-connection probe gets a refused connection. uninstall.sh must still remove
  # everything instead of dying on curl's exit status.
  sandbox uninstall-no-metrics
  env_file
  t "$R/scripts/install.sh"
  export MOCK_NO_METRICS=1
  : >"$MOCK_STATE/calls.log"
  t "$R/scripts/uninstall.sh" --purge --yes
  tnot test -e "$(QDIR)/apporo-cf-tunnel.container"
  t test "$(calls 'podman volume rm apporo_cf_data')" = 1
  return "$A_FAILS"
}

# --purge next to WOOW's running install: our units, files and volume go; WOOW's units keep
# running, and its files, manifest and cf_data volume are never named to podman or systemctl.
case_uninstall_purge_leaves_a_woow_install_alone() {
  sandbox uninstall-next-to-other
  woow_host
  env_file
  t "$R/scripts/install.sh"
  t "$R/scripts/uninstall.sh" --purge --yes
  tnot test -e "$(QDIR)/apporo-cf-tunnel.container"
  tnot test -e "$(QDIR)/apporo-cf-tunnel-data.volume"
  t test "$(calls 'podman volume rm apporo_cf_data')" = 1
  t woow_untouched
  return "$A_FAILS"
}

# --purge exports the volume (the final backup) and deletes it: never one that podman says is
# another app's. Here a container of WOOW's GUI mounts the volume this app was installed on.
case_uninstall_purge_refuses_a_volume_that_is_not_ours() {
  sandbox purge-foreign-volume
  env_file
  t "$R/scripts/install.sh"
  export MOCK_VOLUME_USERS=apporo_cf_data=woow-cf-tunnel
  : >"$MOCK_STATE/calls.log"
  refuses "volume apporo_cf_data is mounted by container 'woow-cf-tunnel'" "$R/scripts/uninstall.sh" --purge --yes
  t test "$(calls 'podman volume (export|rm)')" = 0
  t test "$(calls 'systemctl --user (stop|disable|daemon-reload)')" = 0
  t test -e "$(QDIR)/apporo-cf-tunnel.container"
  t test "$(cat "$MOCK_STATE/units/apporo-cf-tunnel.service/active")" = 1
  return "$A_FAILS"
}

# From a shell that carries WOOW's unit, container and ports (woow_shell), next to WOOW's
# running install: --purge counts the edge connections on our metrics address and stops,
# backs up and removes this app's unit and volume only.
case_uninstall_purge_ignores_woows_exported_settings() {
  sandbox uninstall-woow-shell
  woow_host
  env_file
  t "$R/scripts/install.sh"
  woow_shell
  : >"$MOCK_STATE/calls.log"
  t "$R/scripts/uninstall.sh" --purge --yes
  t test "$(calls '^curl http://127\.0\.0\.1:20341/ready')" -ge 1
  t test "$(calls '^systemctl --user stop apporo-cf-tunnel.service')" -ge 1
  t test "$(calls '^podman volume rm apporo_cf_data')" = 1
  tnot test -e "$(QDIR)/apporo-cf-tunnel.container"
  t woow_untouched
  return "$A_FAILS"
}

# Both remote-access paths reach sshd from 127.0.0.1 (tailscaled runs with
# --tun=userspace-networking, so it re-dials loopback exactly as cloudflared does). The
# address therefore decides nothing; the process holding the client end of that pair does.
case_uninstall_refuses_over_a_tunnel_ssh_session() {
  sandbox uninstall-session
  env_file
  t "$R/scripts/install.sh"
  export SSH_CONNECTION="127.0.0.1 50642 127.0.0.1 22" MOCK_SSH_CARRIER=cloudflared
  local out
  out=$("$R/scripts/uninstall.sh" 2>&1) && { echo "  uninstall ran over a tunnel session"; A_FAILS=$((A_FAILS + 1)); }
  t grep -q 'reconnect over another path\|Reconnect over another path' <<<"$out"
  t grep -q 'held by cloudflared (pid' <<<"$out" # it says what it saw, not just "loopback"
  t test -e "$(QDIR)/apporo-cf-tunnel.container"
  t test "$(cat "$MOCK_STATE/units/apporo-cf-tunnel.service/active")" = 1
  return "$A_FAILS"
}

case_uninstall_runs_over_a_loopback_tailnet_session() {
  sandbox uninstall-tailnet
  env_file
  t "$R/scripts/install.sh"
  # The rescue path: same loopback address as the tunnel, carried by tailscaled. Refusing it
  # would leave --force as the only way out, exactly when the guard matters most.
  export SSH_CONNECTION="127.0.0.1 55996 127.0.0.1 22" MOCK_SSH_CARRIER=tailscaled
  : >"$MOCK_STATE/calls.log"
  t "$R/scripts/uninstall.sh"
  tnot test -e "$(QDIR)/apporo-cf-tunnel.container"
  t test "$(cat "$MOCK_STATE/units/apporo-cf-tunnel.service/active")" = 0
  return "$A_FAILS"
}

# shellcheck disable=SC2034 # read by run-all.sh
INSTALL_CASES=(
  case_install_first_run_creates_env_and_stops
  case_install_stage_builds_and_renders_only
  case_install_leaves_a_woow_install_alone
  case_install_fresh_then_idempotent
  case_install_never_rewrites_a_running_tunnel
  case_install_refuses_bad_settings
  case_install_refuses_woow_volumes_and_paths
  case_install_refuses_moving_onto_a_busy_port
  case_install_refuses_woows_ports_while_it_is_stopped
  case_install_refuses_a_volume_that_is_not_ours
  case_install_stage_dir_is_replaced_only_when_it_is_a_stage
  case_smoke_judges_only_our_cloudflared
  case_install_auth_refuses_malformed_htpasswd
  case_install_auth_adds_proxy_without_touching_the_tunnel
  case_install_dry_run_changes_nothing
  case_uninstall_keeps_the_data_volume
  case_uninstall_purge_backs_up_then_removes_the_volume
  case_uninstall_purge_with_no_metrics_endpoint
  case_uninstall_purge_leaves_a_woow_install_alone
  case_uninstall_purge_refuses_a_volume_that_is_not_ours
  case_uninstall_purge_ignores_woows_exported_settings
  case_uninstall_refuses_over_a_tunnel_ssh_session
  case_uninstall_runs_over_a_loopback_tailnet_session
)
