#!/usr/bin/env bash
# scripts/restore.sh: restore the apporo-cf-tunnel data volume from a backup.sh tarball.
#
#   scripts/restore.sh <backup.tar> [--replace] [--yes] [--force]
#
#   --replace  recreate the volume first, so files that are not in the tarball disappear
#              (an exact restore). Without it, podman volume import overwrites in place.
#   --yes      do not ask for confirmation
#   --force    allow running it over an SSH session that rides this tunnel (it will drop)
#
# This stops the tunnel for the duration: on a host whose SSH rides the tunnel, run it
# over another path (the tailnet). The checksum next to the tarball is verified first.
# It never writes into a volume of WOOW's GUI (cf_data, woow*, or one podman says is another
# app's), and never restores one of its backups (~/backups/woow-cf-tunnel, cf_data-<ts>.tar):
# the tarball holds WOOW's tunnel token, which would run a second connector on WOOW's tunnel.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=lib/quadlet-lib.sh
. "$HERE/lib/quadlet-lib.sh"
# shellcheck source=lib/cf-gate.sh
. "$HERE/lib/cf-gate.sh"
# shellcheck source=render-args.sh
. "$HERE/render-args.sh"
cf_require_own_dirs
export QL_LOG_PREFIX=restore QL_APP=$CF_APP

QUADLET_DIR=${QL_QUADLET_DIR:-$HOME/.config/containers/systemd}
ENV_FILE=$HOME/.config/$CF_APP/$CF_APP.env
tar_path='' replace=0 yes=0 force=0
while (($#)); do
  case $1 in
    --replace) replace=1 ;;
    --yes) yes=1 ;;
    --force) force=1 ;;
    -h | --help) sed -n '2,15p' "$0"; exit 0 ;;
    -*) ql_die "unknown option $1 (see --help)" ;;
    *) [[ -z $tar_path ]] || ql_die "one tarball only"; tar_path=$1 ;;
  esac
  shift
done
[[ -n $tar_path ]] || { sed -n '2,15p' "$0"; exit 64; }
[[ -f $tar_path ]] || ql_die "$tar_path does not exist"
dir=$(cd "$(dirname "$tar_path")" && pwd -P)
base=${tar_path##*/}
# backup.sh names a tarball <volume>-<YYYYmmdd-HHMMSS>.tar
src=''
[[ $base =~ ^(.+)-[0-9]{8}-[0-9]{6}\.tar$ ]] && src=${BASH_REMATCH[1]}
why=''
if cf_foreign_path "$tar_path" || cf_foreign_path "$dir/$base"; then
  why="it is in a directory of that GUI"
elif [[ -n $src ]] && cf_foreign_volume "$src"; then
  why="it was exported from that GUI's volume $src"
fi
[[ -z $why ]] || ql_die "$tar_path is a backup of WOOW's Cloudflare Tunnel Web GUI ($why); this package never restores it, because it holds WOOW's tunnel token. Restore one of ours, from ~/backups/$CF_APP"
ql_require_rootless
ql_lock "$CF_APP"

vol=''
[[ -f $QUADLET_DIR/apporo-cf-tunnel-data.volume ]] && vol=$(sed -n 's/^VolumeName=//p' "$QUADLET_DIR/apporo-cf-tunnel-data.volume" | tail -n1)
if [[ -z $vol && -f $ENV_FILE ]]; then
  ql_env_load "$ENV_FILE"
  vol=$(ql_env_get CF_DATA_VOLUME '')
fi
[[ -n $vol ]] || ql_die "cannot tell which volume to restore into (install apporo-cf-tunnel first)"
if cf_foreign_volume "$vol"; then
  ql_die "volume $vol belongs to WOOW's Cloudflare Tunnel Web GUI; this package never restores into it (set CF_DATA_VOLUME=apporo_cf_data and re-install)"
fi
# by what podman says about it too: another app's label, compose, or another container
cf_check_volume "$vol" "restores into" "Point this app at a volume of its own (CF_DATA_VOLUME=apporo_cf_data) and re-install; nothing was changed"
[[ -z $src || $src == "$vol" ]] || ql_warn "$base was exported from volume $src; it is restored into $vol"

if [[ -f $dir/$base.sha256 ]]; then
  (cd "$dir" && sha256sum -c "$base.sha256" >/dev/null) || ql_die "checksum mismatch for $base"
  ql_info "checksum ok"
else
  ql_warn "no $base.sha256 next to the tarball: its integrity is unverified"
fi
ql_info "contents: $(tar -tf "$tar_path" | tr '\n' ' ')"

if cf_session_rides_tunnel && ((!force)); then
  ql_die "the restart would drop this session: $CF_SESSION_WHY. Reconnect over another path (the tailnet), or pass --force"
fi
if ((!yes)); then
  [[ -t 0 ]] || ql_die "not a terminal; pass --yes to confirm overwriting volume $vol"
  ql_warn "this overwrites the live tunnel token and settings in volume $vol"
  read -r -p "Type '$vol' to restore into it: " answer
  [[ $answer == "$vol" ]] || ql_die "aborted; nothing was changed"
fi

was_active=0
if systemctl --user is-active --quiet "$NEW_UNIT"; then
  was_active=1
  ql_info "stopping $NEW_UNIT (the tunnel goes down now)"
  systemctl --user stop "$NEW_UNIT" || ql_die "cannot stop $NEW_UNIT"
fi
if ((replace)); then
  podman volume rm "$vol" >/dev/null 2>&1 || ql_warn "could not remove volume $vol (in use?); importing in place"
  # with the label the volume unit gives it, which tells this app's volume from another's
  podman volume create --label "io.woowtech.app=$CF_APP" "$vol" >/dev/null 2>&1 || true
fi
podman volume import "$vol" "$tar_path" || ql_die "podman volume import failed; the unit is still stopped"
ql_info "restored $vol from $base"
if ((was_active)); then
  systemctl --user start "$NEW_UNIT" || ql_die "cannot start $NEW_UNIT; see journalctl --user -u $NEW_UNIT -n 50"
  "$HERE/../tests/smoke.sh" || ql_die "the tunnel did not come back healthy after the restore"
else
  ql_info "$NEW_UNIT was not running; start it with: systemctl --user start $NEW_UNIT"
fi
