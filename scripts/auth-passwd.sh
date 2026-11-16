#!/usr/bin/env bash
# scripts/auth-passwd.sh USER: add USER to, or change USER's password in, the htpasswd
# of the optional auth proxy (AUTH_HTPASSWD in ~/.config/apporo-cf-tunnel/apporo-cf-tunnel.env,
# default ~/.config/apporo-cf-tunnel/htpasswd).
#
# The password is read from the terminal (asked twice), or from stdin when piped. It is
# never taken from argv. The hash is SHA-512-crypt ($6$) from `openssl passwd -6 -stdin`:
# openssl ships with Ubuntu, and nginx:alpine (musl crypt) verifies $6$. The file gets
# mode 0640 and the nginx subgid as its group, so nginx workers can read it.
# nginx reads the file on every request: no restart is needed.
# It never reads the env file or writes the htpasswd of WOOW's Cloudflare Tunnel Web GUI
# (~/.config/woow-cf-tunnel): ENV_FILE=<WOOW's env file> is refused whatever htpasswd it names.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=render-args.sh
. "$HERE/render-args.sh"
user=${1:?usage: auth-passwd.sh USER}
[[ $user =~ ^[A-Za-z0-9._@-]+$ ]] || { echo "auth-passwd: invalid user name (use A-Z a-z 0-9 . _ @ -)" >&2; exit 64; }
env_file=${ENV_FILE:-$HOME/.config/apporo-cf-tunnel/apporo-cf-tunnel.env}
if d=$(cf_foreign_own_dir); then
  echo "auth-passwd: $d leads into a directory of WOOW's Cloudflare Tunnel Web GUI ($(readlink -m -- "$d")); this package never writes there. Make it a directory of its own" >&2
  exit 1
fi
if cf_resolved_foreign "$env_file"; then
  echo "auth-passwd: $env_file is an env file of WOOW's Cloudflare Tunnel Web GUI; this package never reads it, nor writes the htpasswd it names (unset ENV_FILE to use ~/.config/apporo-cf-tunnel/apporo-cf-tunnel.env)" >&2
  exit 1
fi
ht=''
[[ -r $env_file ]] && ht=$(sed -n 's/^AUTH_HTPASSWD=//p' "$env_file" | tail -n1)
ht=${ht:-%h/.config/apporo-cf-tunnel/htpasswd}
if cf_resolved_foreign "$ht"; then
  echo "auth-passwd: $ht is in the config dir of WOOW's Cloudflare Tunnel Web GUI; this package never writes there (set AUTH_HTPASSWD=%h/.config/apporo-cf-tunnel/htpasswd in $env_file)" >&2
  exit 1
fi
ht=${ht//%h/$HOME}
dir=$(dirname -- "$ht")
mkdir -p -- "$dir"
if [[ -t 0 ]]; then
  read -rsp "password for $user: " pw
  echo
  read -rsp "again: " pw2
  echo
  [[ $pw == "$pw2" ]] || { echo "auth-passwd: the passwords differ" >&2; exit 1; }
else
  IFS= read -r pw || true
fi
((${#pw} >= 12)) || { echo "auth-passwd: use at least 12 characters" >&2; exit 1; }
hash=$(printf '%s\n' "$pw" | openssl passwd -6 -stdin)
unset pw pw2
tmp=$(mktemp "$dir/.htpasswd.XXXXXX")
trap 'rm -f "$tmp"' EXIT
{
  if [[ -f $ht ]]; then grep -v "^${user}:" "$ht" || true; fi
  printf '%s:%s\n' "$user" "$hash"
} >"$tmp"
chmod 640 "$tmp"
mv -f -- "$tmp" "$ht"
trap - EXIT
podman unshare chgrp "${NGINX_GID:-101}" "$ht"
echo "auth-passwd: updated $ht (user $user). First time? Run: scripts/install.sh --with-auth"
