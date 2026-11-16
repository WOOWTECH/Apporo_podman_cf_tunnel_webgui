# shellcheck shell=bash
# tests/dryrun.local.sh: apporo-cf-tunnel invariants on top of the vendored tests/dryrun.sh.
# Sourced at its end; uses $REPO $WORK $VARS, render_variant, and its failures/variants
# counters. Each check renders the units the way scripts/install.sh does, runs the
# podman 4.9.3 generator, and asserts on what the running tunnel and the upgrade gate depend
# on, and that nothing rendered can point at WOOW's GUI on the same host: not its names,
# not its volume, not its default ports.

# _cf_env_of <envfile> <KEY> [default]: one value, without touching the caller's QL_ENV
_cf_env_of() { (ql_env_load "$1" && ql_env_get "$2" "${@:3}"); }

# cf_check <name> <envfile> <with_auth:0|1>
cf_check() {
  local name=$1 env=$2 auth=$3
  local d=$WORK/cf-$name
  local src=$d/src out=$d/out gen=$d/gen
  mkdir -p "$src" "$out"
  cp -p "$REPO"/quadlet/*.container "$REPO"/quadlet/*.volume "$src/"
  if ((auth)); then cp -p "$REPO/quadlet/optional/apporo-cf-tunnel-auth.container" "$src/"; fi
  variants=$((variants + 1))
  echo "== cf-$name (apporo-cf-tunnel invariants, env ${env#"$REPO"/}, auth=$auth)"
  local -a bad=()
  if ! (render_variant "$src" "$env" "$out"); then
    echo "FAIL cf-$name: render"; failures=$((failures + 1)); return 0
  fi
  if ((auth)) && ! ql_render "$REPO/config/auth/auth-nginx.conf" "$env" "$VARS" "$out/config"; then
    echo "FAIL cf-$name: render auth-nginx.conf"; failures=$((failures + 1)); return 0
  fi
  if ! ql_dryrun "$out" --verify --keep "$gen" >/dev/null 2>"$d/dryrun.err"; then
    cat "$d/dryrun.err" >&2
    echo "FAIL cf-$name: dry-run"; failures=$((failures + 1)); return 0
  fi

  local port metrics vol listen ht img es woow svc=$gen/apporo-cf-tunnel.service
  port=$(_cf_env_of "$env" UVICORN_PORT)
  metrics=$(_cf_env_of "$env" CF_METRICS_ADDR)
  vol=$(_cf_env_of "$env" CF_DATA_VOLUME)
  listen=$(_cf_env_of "$env" AUTH_LISTEN)
  ht=$(_cf_env_of "$env" AUTH_HTPASSWD)
  img=$(cf_image_ref)
  es=$(grep '^ExecStart=' "$svc")
  has() { [[ $es == *"$1"* ]] || bad+=("ExecStart lacks: $1"); }
  lacks() { [[ $es != *"$1"* ]] || bad+=("ExecStart must not contain: $1"); }

  has '--network=host'
  has "-v $vol:/data"
  has '--env UVICORN_HOST=127.0.0.1'
  has "--env UVICORN_PORT=$port"
  has "--env CF_METRICS_ADDR=$metrics"
  has '--health-cmd /usr/local/bin/cf-webui-healthcheck'
  has '--health-on-failure kill'
  has '--pull never'
  has '--cap-drop=all'
  has '--security-opt=no-new-privileges'
  has '--stop-timeout=20'
  lacks '--env-file'
  lacks '--publish'
  [[ $es == *" $img uvicorn backend.main:app" ]] || bad+=("ExecStart does not end with '$img uvicorn backend.main:app'")
  grep -qx 'Restart=always' "$svc" || bad+=("Restart=always missing")
  grep -qx 'WantedBy=default.target' "$svc" || bad+=("WantedBy=default.target missing")
  grep -qx 'StartLimitIntervalSec=0' "$svc" || bad+=("StartLimitIntervalSec=0 missing")
  grep -q "^ExecStart=.*podman volume create --ignore .* $vol\$" "$gen/apporo-cf-tunnel-data-volume.service" \
    || bad+=("volume unit does not create/keep $vol")
  # WOOW's GUI may run next to this one: no generated directive may name its units,
  # containers, image, volume (cf_data) or config dir. Comments copied from the sources do.
  woow=$(grep -hvE '^[[:space:]]*[#;]' "$gen"/*.service |
    grep -E 'woow[-_]|cf-tunnel-webgui|(^|[^A-Za-z0-9_])cf_data([^A-Za-z0-9_]|$)' || true)
  [[ -z $woow ]] || bad+=("a generated unit names a resource of WOOW's GUI: $(head -n 2 <<<"$woow" | tr '\n' ' ')")

  if ((auth)); then
    local asvc=$gen/apporo-cf-tunnel-auth.service conf=$out/config/auth-nginx.conf
    grep -qx "AssertFileNotEmpty=$ht" "$asvc" || bad+=("auth unit lacks AssertFileNotEmpty=$ht")
    grep -qx 'AssertFileNotEmpty=%h/.config/apporo-cf-tunnel/auth-nginx.conf' "$asvc" || bad+=("auth unit lacks the nginx.conf assertion")
    grep -qE '^(Requires|BindsTo|PartOf)=.*apporo-cf-tunnel\.service' "$asvc" && bad+=("auth unit must not be coupled to the tunnel unit")
    grep -q -- "-v $ht:/etc/nginx/htpasswd:ro" "$asvc" || bad+=("auth unit does not mount $ht")
    grep -qx "        listen $listen;" "$conf" || bad+=("auth-nginx.conf does not listen on $listen")
    grep -qx "            proxy_pass http://127.0.0.1:$port;" "$conf" || bad+=("auth-nginx.conf does not proxy to :$port")
  else
    [[ ! -e $gen/apporo-cf-tunnel-auth.service ]] || bad+=("auth unit rendered without --with-auth")
  fi

  if ((${#bad[@]})); then
    printf '  FAIL %s\n' "${bad[@]}" >&2
    echo "FAIL cf-$name"; failures=$((failures + 1))
  else
    echo "ok   cf-$name"
  fi
}

# cf_refuse <description> <KEY=VALUE for the env file | APPORO_CF_IMAGE=ref>: render_args must fail
cf_refuse() {
  local desc=$1 kv=$2 f=$WORK/refuse-$variants.env
  variants=$((variants + 1))
  if [[ ${kv%%=*} == APPORO_CF_IMAGE ]]; then
    cp "$EXAMPLE_ENV" "$f"
    if (export APPORO_CF_IMAGE=${kv#*=}; ql_env_load "$f"; render_args "$f") 2>/dev/null; then
      echo "FAIL refuse: $desc"; failures=$((failures + 1)); return 0
    fi
  else
    grep -v "^${kv%%=*}=" "$EXAMPLE_ENV" >"$f"
    printf '%s\n' "$kv" >>"$f"
    if (ql_env_load "$f"; render_args "$f") 2>/dev/null; then
      echo "FAIL refuse: $desc"; failures=$((failures + 1)); return 0
    fi
  fi
  echo "ok   refuse: $desc"
}

cf_check example "$EXAMPLE_ENV" 0
cf_check example-auth "$EXAMPLE_ENV" 1
cf_check custom-ports-auth "$REPO/tests/fixtures/custom-ports.env" 1

cf_refuse "metrics on 0.0.0.0" CF_METRICS_ADDR=0.0.0.0:20341
cf_refuse "privileged GUI port" UVICORN_PORT=80
cf_refuse "GUI and metrics on one port" CF_METRICS_ADDR=127.0.0.1:18100
cf_refuse "auth proxy on the GUI port" AUTH_LISTEN=127.0.0.1:18100
cf_refuse "volume name with a slash" CF_DATA_VOLUME=../apporo_cf_data
cf_refuse "WOOW's volume (podman run -v cf_data:/data)" CF_DATA_VOLUME=cf_data
cf_refuse "WOOW's compose volume" CF_DATA_VOLUME=woow_cloudflare_tunnel_webgui_cf_data
cf_refuse "WOOW's compose volume under another project name" CF_DATA_VOLUME=cloudflare_tunnel_webgui_cf_data
# WOOW's default ports, refused even when nothing holds them (its GUI stopped)
cf_refuse "WOOW's GUI port" UVICORN_PORT=18000
cf_refuse "WOOW's metrics port" CF_METRICS_ADDR=127.0.0.1:20241
cf_refuse "WOOW's auth proxy port" AUTH_LISTEN=127.0.0.1:8888
cf_refuse "WOOW's auth proxy port on the LAN" AUTH_LISTEN=0.0.0.0:8888
cf_refuse "WOOW's metrics port for the GUI" UVICORN_PORT=20241
cf_refuse "an htpasswd in WOOW's config dir" AUTH_HTPASSWD=%h/.config/woow-cf-tunnel/htpasswd
cf_refuse "floating image tag" APPORO_CF_IMAGE=localhost/apporo-cf-tunnel:latest
cf_refuse "WOOW's image" APPORO_CF_IMAGE=localhost/woow-cf-tunnel:1.2.1-e6226c5aaaaa
cf_refuse "foreign image" APPORO_CF_IMAGE=docker.io/cloudflare/cloudflared:2026.6.1
