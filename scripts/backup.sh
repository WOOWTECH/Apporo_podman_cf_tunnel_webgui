#!/usr/bin/env bash
# scripts/backup.sh: export the apporo-cf-tunnel data volume.
#
#   scripts/backup.sh [--keep N] [--dir DIR]     default: --keep 10, ~/backups/apporo-cf-tunnel
#
# The tarball holds /data: settings.json, **.tunnel_token (THE TUNNEL TOKEN)**, the platform
# link state (its OAuth tokens), .csrf_secret and, in local-managed mode, cert.pem /
# tunnel.json / config.json. It is written mode 0600 in a 0700 directory with a .sha256
# beside it. Never copy it off this host unencrypted; anyone holding it can run your
# tunnel. scripts/upgrade.sh runs this before every swap.
#
# The volume is exported while the container runs; these files are small and rarely
# written, so a hot export is consistent in practice. Prints the tarball path on stdout.
# It never exports a volume of WOOW's Cloudflare Tunnel Web GUI (cf_data, <project>_cf_data,
# woow*, or one that podman says is another app's), and never writes into its directories
# (--dir ~/backups/woow-cf-tunnel): WOOW's restore would find this app's tunnel token there.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=lib/quadlet-lib.sh
. "$HERE/lib/quadlet-lib.sh"
# shellcheck source=render-args.sh
. "$HERE/render-args.sh"
export QL_LOG_PREFIX=backup QL_APP=apporo-cf-tunnel

QUADLET_DIR=${QL_QUADLET_DIR:-$HOME/.config/containers/systemd}
ENV_FILE=$HOME/.config/apporo-cf-tunnel/apporo-cf-tunnel.env
dir=$HOME/backups/apporo-cf-tunnel
keep=10
while (($#)); do
  case $1 in
    --keep) keep=${2:?--keep needs a number}; shift ;;
    --dir) dir=${2:?--dir needs a path}; shift ;;
    -h | --help) sed -n '2,16p' "$0"; exit 0 ;;
    *) ql_die "unknown option $1 (see --help)" ;;
  esac
  shift
done
[[ $keep =~ ^[0-9]+$ ]] || ql_die "--keep needs a number"
if cf_foreign_path "$dir" || cf_foreign_path "$(readlink -m -- "$dir")"; then
  ql_die "--dir $dir is a directory of WOOW's Cloudflare Tunnel Web GUI; this package never writes its backups there"
fi

# cf_volume_name: what the installed unit adopts, else what the env file asks for
cf_volume_name() {
  local v=''
  [[ -f $QUADLET_DIR/apporo-cf-tunnel-data.volume ]] && v=$(sed -n 's/^VolumeName=//p' "$QUADLET_DIR/apporo-cf-tunnel-data.volume" | tail -n1)
  if [[ -z $v && -f $ENV_FILE ]]; then
    ql_env_load "$ENV_FILE"
    v=$(ql_env_get CF_DATA_VOLUME '')
  fi
  [[ -n $v ]] || ql_die "cannot tell which volume to back up: apporo-cf-tunnel is not installed and $ENV_FILE has no CF_DATA_VOLUME"
  if cf_foreign_volume "$v"; then
    ql_die "volume $v belongs to WOOW's Cloudflare Tunnel Web GUI; this package never exports it (set CF_DATA_VOLUME=apporo_cf_data and re-install)"
  fi
  # by what podman says about it too: another app's label, compose, or another container
  cf_check_volume "$v" exports "Point this app at a volume of its own (CF_DATA_VOLUME=apporo_cf_data) and re-install"
  printf '%s' "$v"
}

ql_lock apporo-cf-tunnel
vol=$(cf_volume_name)
out=$(ql_backup_volume "$vol" "$dir")

# rotation: keep the newest N tarballs (and their checksums)
mapfile -t old < <(find "$dir" -maxdepth 1 -name "$vol-*.tar" -printf '%f\n' | LC_ALL=C sort -r | tail -n +$((keep + 1)))
for f in "${old[@]:-}"; do
  [[ -n $f ]] || continue
  rm -f -- "$dir/$f" "$dir/$f.sha256"
  ql_info "rotated out $f"
done
ql_info "keep the tarball on this host: it contains the tunnel token"
printf '%s\n' "$out"
