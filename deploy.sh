#!/usr/bin/env bash
# =============================================================================
#  Self-Hosted Productivity Suite — one-shot deployer
#  Davenport Software · "Deploy your own private productivity suite"
# -----------------------------------------------------------------------------
#  Reads ./config.env, renders per-service .env files (GENERATING fresh secrets),
#  and brings the enabled stacks up in dependency order (Authentik + DBs first,
#  then the OIDC/WOPI consumers).
# =============================================================================
#: USAGE
#  Reads ./config.env, renders per-service .env files (GENERATING fresh secrets),
#  and brings the enabled stacks up in dependency order.
#
#  Usage:
#     cp config.env.example config.env && $EDITOR config.env
#     ./deploy.sh                 # interactive
#     ./deploy.sh --yes           # non-interactive (assume yes to prompts)
#     ./deploy.sh --render-only    # render .env + cloudflared config, don't `up`
#     ./deploy.sh --tunnel         # also create/configure the Cloudflare Tunnel
#
#  Idempotent where it matters: existing secrets in already-rendered .env files
#  are PRESERVED (re-running won't rotate a DB password and orphan its data).
#: END USAGE
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib/common.sh"

# ---- args ------------------------------------------------------------------
ASSUME_YES=0; RENDER_ONLY=0; DO_TUNNEL=0
for a in "$@"; do
  case "$a" in
    --yes|-y) ASSUME_YES=1 ;;
    --render-only) RENDER_ONLY=1 ;;
    --tunnel) DO_TUNNEL=1 ;;
    -h|--help) sed -n '/^#: USAGE/,/^#: END USAGE/{/^#: /d;s/^# \{0,1\}//;p;}' "$0"; exit 0 ;;
    *) die "Unknown arg: $a" ;;
  esac
done
export ASSUME_YES

# ---- load config -----------------------------------------------------------
[ -f "$HERE/config.env" ] || die "Missing config.env. Run: cp config.env.example config.env && edit it."
# shellcheck disable=SC1091
set -a; source "$HERE/config.env"; set +a
[ "${BASE_DOMAIN:-}" != "example.com" ] || warn "BASE_DOMAIN is still 'example.com' — did you edit config.env?"
[ -n "${ADMIN_EMAIL:-}" ] || die "ADMIN_EMAIL is required in config.env."
: "${TZ:=America/New_York}"

OUT="$HERE/out"; mkdir -p "$OUT/cloudflared"
SVC="$HERE/services"

# Resolve storage paths (default to ./data under the service dir).
: "${IMMICH_UPLOAD_LOCATION:=$SVC/immich/data/upload}"
: "${IMMICH_DB_DATA_LOCATION:=$SVC/immich/data/pgdata}"
: "${OPENCLOUD_CONFIG_DIR:=$SVC/opencloud/oc-config}"
: "${OPENCLOUD_DATA_DIR:=$SVC/opencloud/oc-data}"

# ---------------------------------------------------------------------------
#  Template renderer: copy <tpl> -> <dest>, substitute __PLACEHOLDERS__, then
#  replace every __GENERATE__ with a freshly generated secret. An EXISTING,
#  fully-rendered dest is preserved untouched (idempotent) so re-running never
#  rotates a DB password and orphans its data.
# ---------------------------------------------------------------------------
# Exit status:
#   RENDER_FRESH (0)     — dest was (re)rendered; caller SHOULD apply fixup_secret.
#   RENDER_PRESERVED (1) — dest already existed and was kept; caller must NOT
#                          rotate secrets.
RENDER_FRESH=0
RENDER_PRESERVED=1
render() {
  local tpl="$1" dest="$2"
  # Preserve an existing dest only once it is FULLY rendered (no markers left).
  # A freshly copied template still carries markers, so it always renders.
  if [ -f "$dest" ] && ! grep -q '__[A-Z0-9_]\+__' "$dest" 2>/dev/null; then
    ok "$(basename "$(dirname "$dest")")/.env already rendered — keeping existing secrets"
    return "$RENDER_PRESERVED"
  fi
  secure_cp "$tpl" "$dest"
  # Plain substitutions from config.env. User-supplied SMTP values may contain
  # sed metacharacters, so escape them for the replacement side.
  local smtp_sender; smtp_sender="$(sed_escape_repl "${SMTP_FROM:-$ADMIN_EMAIL}")"
  local smtp_host;   smtp_host="$(sed_escape_repl "${SMTP_HOST:-}")"
  local smtp_user;   smtp_user="$(sed_escape_repl "${SMTP_USERNAME:-}")"
  local smtp_pass;   smtp_pass="$(sed_escape_repl "${SMTP_PASSWORD:-}")"
  local smtp_sec;    smtp_sec="$(sed_escape_repl "${SMTP_SECURITY:-starttls}")"
  sed -i \
    -e "s|__BASE_DOMAIN__|${BASE_DOMAIN}|g" \
    -e "s|__ADMIN_EMAIL__|${ADMIN_EMAIL}|g" \
    -e "s|__TZ__|${TZ}|g" \
    -e "s|__AUTH_DOMAIN__|${AUTH_DOMAIN}|g" \
    -e "s|__PHOTOS_DOMAIN__|${PHOTOS_DOMAIN}|g" \
    -e "s|__FILES_DOMAIN__|${FILES_DOMAIN}|g" \
    -e "s|__COLLABORA_DOMAIN__|${COLLABORA_DOMAIN}|g" \
    -e "s|__WOPI_DOMAIN__|${WOPI_DOMAIN}|g" \
    -e "s|__MAIL_DOMAIN__|${MAIL_DOMAIN}|g" \
    -e "s|__VAULT_DOMAIN__|${VAULT_DOMAIN}|g" \
    -e "s|__OUTLINE_DOMAIN__|${OUTLINE_DOMAIN}|g" \
    -e "s|__NOTES_DOMAIN__|${NOTES_DOMAIN}|g" \
    -e "s|__HOME_DOMAIN__|${HOME_DOMAIN}|g" \
    -e "s|__UPLOAD_LOCATION__|${IMMICH_UPLOAD_LOCATION}|g" \
    -e "s|__DB_DATA_LOCATION__|${IMMICH_DB_DATA_LOCATION}|g" \
    -e "s|__OC_CONFIG_DIR__|${OPENCLOUD_CONFIG_DIR}|g" \
    -e "s|__OC_DATA_DIR__|${OPENCLOUD_DATA_DIR}|g" \
    -e "s|__AUTH_PORT_HTTP__|9000|g" \
    -e "s|__AUTH_PORT_HTTPS__|9443|g" \
    -e "s|__SMTP_HOST__|${smtp_host}|g" \
    -e "s|__SMTP_PORT__|${SMTP_PORT:-587}|g" \
    -e "s|__SMTP_USERNAME__|${smtp_user}|g" \
    -e "s|__SMTP_PASSWORD__|${smtp_pass}|g" \
    -e "s|__SMTP_FROM__|${smtp_sender}|g" \
    -e "s|__SMTP_SECURITY__|${smtp_sec}|g" \
    "$dest"

  # Secret generation: replace each __GENERATE__ with its OWN fresh value.
  # Loop replaces the FIRST remaining marker per pass, so every marker (even on
  # the same line) gets a distinct secret.
  while grep -q '__GENERATE__' "$dest"; do
    local secret; secret="$(gen_pass 24)"
    local esc; esc=$(sed_escape_repl "$secret")
    sed -i "0,/__GENERATE__/s||${esc}|" "$dest"
  done
  # Basic-auth credential (user:password) for SilverBullet.
  if grep -q '__GENERATE_BASIC_AUTH__' "$dest"; then
    local user="${ADMIN_EMAIL%%@*}" pw; pw="$(gen_pass 18)"
    sed -i "s|__GENERATE_BASIC_AUTH__|$(sed_escape_repl "${user}:${pw}")|" "$dest"
  fi
  # Shared DB password: ONE value substituted into every __DB_PASSWORD__ slot
  # (e.g. Outline's DATABASE_URL and POSTGRES_PASSWORD) so they stay in sync.
  if grep -q '__DB_PASSWORD__' "$dest"; then
    local dbpw; dbpw="$(gen_pass 24)"
    sed -i "s|__DB_PASSWORD__|$(sed_escape_repl "$dbpw")|g" "$dest"
  fi

  # A leftover __...__ marker means an unfilled placeholder slipped through.
  local leftover
  leftover="$(grep -oE '__[A-Z0-9_]+__' "$dest" | grep -v '__GENERATE' | sort -u | tr '\n' ' ' || true)"
  [ -z "$leftover" ] || warn "$(basename "$(dirname "$dest")")/.env still has unfilled markers: $leftover"
  return "$RENDER_FRESH"
}

# Stronger, purpose-specific secrets where length/format matters.
fixup_secret() {  # fixup_secret <file> <key> <value>
  set_kv "$1" "$2" "$3"
}

# ---------------------------------------------------------------------------
#  1. Prerequisites
# ---------------------------------------------------------------------------
log "Checking prerequisites…"
need_cmd openssl || die "openssl is required."
need_cmd curl || warn "curl not found — Docker install + healthchecks may degrade."
if [ "$RENDER_ONLY" = "1" ]; then
  ok "--render-only: skipping Docker prerequisite check."
else
  install_docker
fi

# ---------------------------------------------------------------------------
#  2. Render per-service .env files (generate fresh secrets)
# ---------------------------------------------------------------------------
log "Rendering service configs and generating secrets…"

if [ "${ENABLE_AUTHENTIK:-true}" = "true" ]; then
  mkdir -p "$SVC/authentik"/{data,certs,custom-templates,pgdata}
  if render "$SVC/authentik/.env.template" "$SVC/authentik/.env"; then
    # Replace the generic generated values with stronger, format-specific ones.
    fixup_secret "$SVC/authentik/.env" AUTHENTIK_SECRET_KEY "$(gen_hex 64)"
    fixup_secret "$SVC/authentik/.env" AUTHENTIK_BOOTSTRAP_TOKEN "$(gen_hex 32)"
    # Stash the bootstrap token where the operator can find it later.
    grep '^AUTHENTIK_BOOTSTRAP_TOKEN=' "$SVC/authentik/.env" | cut -d= -f2- \
      | secure_write "$SVC/authentik/.apitoken"
  fi
fi

if [ "${ENABLE_IMMICH:-true}" = "true" ]; then
  mkdir -p "$IMMICH_UPLOAD_LOCATION" "$IMMICH_DB_DATA_LOCATION"
  render "$SVC/immich/.env.template" "$SVC/immich/.env" || true
fi

if [ "${ENABLE_OPENCLOUD:-true}" = "true" ]; then
  mkdir -p "$OPENCLOUD_CONFIG_DIR" "$OPENCLOUD_DATA_DIR"
  render "$SVC/opencloud/.env.template" "$SVC/opencloud/.env" || true
fi

if [ "${ENABLE_ROLLTOP:-true}" = "true" ]; then
  mkdir -p "$SVC/rolltop/data"
  if render "$SVC/rolltop/.env.rolltop.template" "$SVC/rolltop/.env.rolltop"; then
    fixup_secret "$SVC/rolltop/.env.rolltop" ROLLTOP_MASTER_KEY "$(gen_hex 32)"
  fi
fi

if [ "${ENABLE_VAULTWARDEN:-true}" = "true" ]; then
  mkdir -p "$SVC/vaultwarden/data"
  if render "$SVC/vaultwarden/.env.template" "$SVC/vaultwarden/.env"; then
    # Modern Vaultwarden wants ADMIN_TOKEN as an argon2id PHC hash, produced by
    # `/vaultwarden hash` inside the image. The value is consumed via env_file,
    # so the '$'-laden hash is passed literally (no compose interpolation).
    vw_token="$(gen_b64 48)"
    # `hash` reads the token from stdin (twice — entry + confirmation), so feed
    # it on two lines. A non-zero exit / missing flag yields no $argon2 line and
    # falls through to the plain-token branch with manual instructions.
    if [ "$RENDER_ONLY" != "1" ] && need_cmd docker \
       && vw_hash="$(printf '%s\n%s\n' "$vw_token" "$vw_token" | docker run --rm -i vaultwarden/server /vaultwarden hash --preset owasp 2>/dev/null \
                     | grep -m1 '^[$]argon2')"; then
      fixup_secret "$SVC/vaultwarden/.env" ADMIN_TOKEN "$vw_hash"
      ok "Vaultwarden ADMIN_TOKEN stored as argon2id hash (admin password: $vw_token)"
      warn "Save the Vaultwarden /admin password now — only the hash is persisted: $vw_token"
    else
      fixup_secret "$SVC/vaultwarden/.env" ADMIN_TOKEN "$vw_token"
      warn "Vaultwarden ADMIN_TOKEN stored as a plain token (could not run the argon2 hasher)."
      warn "Hash it before exposing /admin:"
      warn "  echo -n '$vw_token' | docker run --rm -i vaultwarden/server /vaultwarden hash --preset owasp"
      warn "  then replace ADMIN_TOKEN= in $SVC/vaultwarden/.env with the printed \$argon2id\$... hash."
    fi
  fi
fi

if [ "${ENABLE_SILVERBULLET:-true}" = "true" ]; then
  mkdir -p "$SVC/silverbullet/space"
  render "$SVC/silverbullet/.env.template" "$SVC/silverbullet/.env" || true
fi

if [ "${ENABLE_HOMEPAGE:-true}" = "true" ]; then
  mkdir -p "$SVC/homepage/config"
fi

if [ "${ENABLE_OUTLINE:-true}" = "true" ]; then
  [ "${ENABLE_AUTHENTIK:-true}" = "true" ] || warn "Outline needs Authentik for login but ENABLE_AUTHENTIK is false."
  if render "$SVC/outline/.env.template" "$SVC/outline/.env"; then
    # render() already filled the shared __DB_PASSWORD__ (URL + POSTGRES var).
    # These two need hex, not the generic generated value.
    fixup_secret "$SVC/outline/.env" SECRET_KEY "$(gen_hex 32)"
    fixup_secret "$SVC/outline/.env" UTILS_SECRET "$(gen_hex 32)"
  fi
fi

# ---------------------------------------------------------------------------
#  3. Render the Cloudflare Tunnel ingress config (enabled services only)
# ---------------------------------------------------------------------------
log "Rendering Cloudflare Tunnel ingress config…"
ingress_file="$(mktemp)"
trap 'rm -f "$ingress_file"' EXIT
add_rule() { printf '  - hostname: %s\n    service: http://127.0.0.1:%s\n' "$1" "$2" >> "$ingress_file"; }
[ "${ENABLE_HOMEPAGE:-true}"    = "true" ] && add_rule "$HOME_DOMAIN" 3010
[ "${ENABLE_IMMICH:-true}"      = "true" ] && add_rule "$PHOTOS_DOMAIN" 2283
[ "${ENABLE_OPENCLOUD:-true}"   = "true" ] && { add_rule "$FILES_DOMAIN" 9200; add_rule "$COLLABORA_DOMAIN" 9980; add_rule "$WOPI_DOMAIN" 9300; }
[ "${ENABLE_ROLLTOP:-true}"     = "true" ] && add_rule "$MAIL_DOMAIN" 8090
[ "${ENABLE_AUTHENTIK:-true}"   = "true" ] && add_rule "$AUTH_DOMAIN" 9000
[ "${ENABLE_OUTLINE:-true}"     = "true" ] && add_rule "$OUTLINE_DOMAIN" 3300
[ "${ENABLE_VAULTWARDEN:-true}" = "true" ] && add_rule "$VAULT_DOMAIN" 8089
[ "${ENABLE_SILVERBULLET:-true}" = "true" ] && add_rule "$NOTES_DOMAIN" 8091

TUNNEL_UUID="${TUNNEL_UUID:-__SET_BY_cloudflared_tunnel_create__}"
sed -e "s|__TUNNEL_UUID__|${TUNNEL_UUID}|g" "$HERE/cloudflared/config.yml.template" \
  | awk -v rf="$ingress_file" '/__INGRESS_RULES__/{while((getline line < rf)>0) print line; next} {print}' \
  > "$OUT/cloudflared/config.yml"
ok "Wrote $OUT/cloudflared/config.yml"

# ---------------------------------------------------------------------------
#  4. Optionally create the Cloudflare Tunnel
# ---------------------------------------------------------------------------
if [ "$DO_TUNNEL" = "1" ]; then
  if need_cmd cloudflared; then
    log "Creating Cloudflare Tunnel '${CF_TUNNEL_NAME}'…"
    # `tunnel login` is an interactive browser flow; only run it if cloudflared
    # is not already authenticated (no cert / API list fails).
    if [ -f "${HOME}/.cloudflared/cert.pem" ] || cloudflared tunnel list >/dev/null 2>&1; then
      ok "cloudflared already authenticated — skipping browser login."
    elif [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && [ "$ASSUME_YES" != "1" ]; then
      cloudflared tunnel login || die "cloudflared tunnel login failed."
    else
      die "cloudflared is not authenticated and no display is available for the browser login.
       Run 'cloudflared tunnel login' on a machine with a browser, copy ~/.cloudflared/cert.pem here, then re-run with --tunnel."
    fi
    cloudflared tunnel create "${CF_TUNNEL_NAME}" || warn "Tunnel may already exist."
    uuid="$(cloudflared tunnel list 2>/dev/null | awk -v n="${CF_TUNNEL_NAME}" '$2==n{print $1}')"
    if [ -n "$uuid" ]; then
      sed -i "s|__SET_BY_cloudflared_tunnel_create__|$uuid|g" "$OUT/cloudflared/config.yml"
      log "Routing DNS for each hostname to the tunnel…"
      for h in $(grep 'hostname:' "$OUT/cloudflared/config.yml" | awk '{print $3}'); do
        cloudflared tunnel route dns "${CF_TUNNEL_NAME}" "$h" || warn "DNS route for $h failed (may exist)."
      done
      warn "Install the tunnel: sudo cp $OUT/cloudflared/config.yml /etc/cloudflared/config.yml && sudo cloudflared service install"
    fi
  else
    warn "cloudflared not installed; skipping automated tunnel. See README for manual steps."
  fi
fi

if [ "$RENDER_ONLY" = "1" ]; then
  log "--render-only: stopping before bringing stacks up."
  exit 0
fi

# ---------------------------------------------------------------------------
#  5. Bring stacks up in DEPENDENCY ORDER
#     Phase A: Authentik (IdP) + each app's own DB come up with the app.
#     Phase B: OIDC/WOPI consumers (Outline needs Authentik reachable).
# ---------------------------------------------------------------------------
AUTHENTIK_HEALTHY=1
log "Bringing up Phase A: identity provider…"
if [ "${ENABLE_AUTHENTIK:-true}" = "true" ]; then
  dc "$SVC/authentik" up -d
  if ! wait_healthy authentik-server-1 60 \
     && ! wait_healthy "$(docker ps --format '{{.Names}}' | grep -m1 authentik-server)" 60; then
    AUTHENTIK_HEALTHY=0
    warn "=========================================================================="
    warn "Authentik never became healthy. OIDC logins (Outline) WILL fail until it is."
    warn "Check: (cd $SVC/authentik && docker compose logs --tail=50 server worker)"
    warn "=========================================================================="
  fi
fi

log "Bringing up Phase B: applications…"
[ "${ENABLE_IMMICH:-true}"       = "true" ] && dc "$SVC/immich" up -d
[ "${ENABLE_OPENCLOUD:-true}"    = "true" ] && dc "$SVC/opencloud" up -d
[ "${ENABLE_ROLLTOP:-true}"      = "true" ] && dc "$SVC/rolltop" up -d --build
[ "${ENABLE_VAULTWARDEN:-true}"  = "true" ] && dc "$SVC/vaultwarden" up -d
[ "${ENABLE_SILVERBULLET:-true}" = "true" ] && dc "$SVC/silverbullet" up -d
[ "${ENABLE_HOMEPAGE:-true}"     = "true" ] && dc "$SVC/homepage" up -d

log "Bringing up Phase C: OIDC consumers…"
if [ "$AUTHENTIK_HEALTHY" != "1" ] && [ "${ENABLE_AUTHENTIK:-true}" = "true" ]; then
  warn "Phase C starting with Authentik UNHEALTHY — OIDC consumers will start but login is broken until Authentik recovers."
fi
if [ "${ENABLE_OUTLINE:-true}" = "true" ]; then
  if grep -q 'TODO_FROM_AUTHENTIK' "$SVC/outline/.env"; then
    warn "Outline OIDC client id/secret not set yet — Outline will start but login fails."
    warn "Create the Authentik provider (README §First-login), put the values in"
    warn "  $SVC/outline/.env, then: (cd $SVC/outline && docker compose up -d)"
  fi
  dc "$SVC/outline" up -d
fi

log "Done."
echo
ok  "Next steps:"
echo "  • Cloudflare Tunnel: install $OUT/cloudflared/config.yml (README §Tunnel)."
echo "  • Authentik admin (akadmin) password: services/authentik/.env  (first-init only)."
echo "  • Wire Outline OIDC + OpenCloud↔Collabora secure-view (README §First-login)."
echo "  • Per-app admin passwords / tokens are in each services/<svc>/.env (chmod 600)."
