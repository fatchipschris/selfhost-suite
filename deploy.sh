#!/usr/bin/env bash
# =============================================================================
#  Self-Hosted Productivity Suite — one-shot deployer
#  Davenport Software · "Deploy your own private productivity suite"
# -----------------------------------------------------------------------------
#  Reads ./config.env, renders per-service .env files (GENERATING fresh secrets),
#  and brings the enabled stacks up in dependency order (Authentik + DBs first,
#  then the OIDC/WOPI consumers).
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
# =============================================================================
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
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
#  replace every __GENERATE__ with a freshly generated secret. Secrets already
#  present in an EXISTING dest are preserved (idempotent) by skipping the file's
#  secret regen when dest already has non-placeholder values.
# ---------------------------------------------------------------------------
# Returns 0 if it freshly rendered (caller should apply fixup_secret), or 1 if
# the dest already existed and was preserved (caller must NOT rotate secrets).
render() {
  local tpl="$1" dest="$2"
  if [ -f "$dest" ] && ! grep -q '__GENERATE__\|__GENERATE_BASIC_AUTH__' "$dest" 2>/dev/null; then
    ok "$(basename "$(dirname "$dest")")/.env already rendered — keeping existing secrets"
    return 1
  fi
  cp "$tpl" "$dest"; chmod 600 "$dest"
  # Plain substitutions from config.env.
  local smtp_sender="${SMTP_FROM:-$ADMIN_EMAIL}"
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
    -e "s|__SMTP_HOST__|${SMTP_HOST:-}|g" \
    -e "s|__SMTP_PORT__|${SMTP_PORT:-587}|g" \
    -e "s|__SMTP_USERNAME__|${SMTP_USERNAME:-}|g" \
    -e "s|__SMTP_PASSWORD__|${SMTP_PASSWORD:-}|g" \
    -e "s|__SMTP_FROM__|${smtp_sender}|g" \
    -e "s|__SMTP_SECURITY__|${SMTP_SECURITY:-starttls}|g" \
    "$dest"

  # Secret generation: replace each __GENERATE__ with its OWN fresh value.
  # Loop replaces the FIRST remaining marker per pass, so every marker (even on
  # the same line) gets a distinct secret.
  while grep -q '__GENERATE__' "$dest"; do
    local secret; secret="$(gen_pass 24)"
    local esc; esc=$(printf '%s' "$secret" | sed -e 's/[\/&|]/\\&/g')
    sed -i "0,/__GENERATE__/s||${esc}|" "$dest"
  done
  # Basic-auth credential (user:password) for SilverBullet.
  if grep -q '__GENERATE_BASIC_AUTH__' "$dest"; then
    local user="${ADMIN_EMAIL%%@*}" pw; pw="$(gen_pass 18)"
    sed -i "s|__GENERATE_BASIC_AUTH__|${user}:${pw}|" "$dest"
  fi
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
    grep '^AUTHENTIK_BOOTSTRAP_TOKEN=' "$SVC/authentik/.env" | cut -d= -f2- > "$SVC/authentik/.apitoken"
    chmod 600 "$SVC/authentik/.apitoken"
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
    fixup_secret "$SVC/vaultwarden/.env" ADMIN_TOKEN "$(gen_b64 48)"
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
    # App secrets must be hex; DB password must match in URL + PG var.
    OUTLINE_DB_PW="$(gen_pass 24)"
    sed -i "s|__DB_PASSWORD__|${OUTLINE_DB_PW}|g" "$SVC/outline/.env"
    fixup_secret "$SVC/outline/.env" SECRET_KEY "$(gen_hex 32)"
    fixup_secret "$SVC/outline/.env" UTILS_SECRET "$(gen_hex 32)"
  fi
fi

# ---------------------------------------------------------------------------
#  3. Render the Cloudflare Tunnel ingress config (enabled services only)
# ---------------------------------------------------------------------------
log "Rendering Cloudflare Tunnel ingress config…"
ingress=""
add_rule() { ingress+="  - hostname: $1\n    service: http://127.0.0.1:$2\n"; }
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
  | awk -v rules="$ingress" '/__INGRESS_RULES__/{printf "%s", rules; next} {print}' \
  > "$OUT/cloudflared/config.yml"
ok "Wrote $OUT/cloudflared/config.yml"

# ---------------------------------------------------------------------------
#  4. Optionally create the Cloudflare Tunnel
# ---------------------------------------------------------------------------
if [ "$DO_TUNNEL" = "1" ]; then
  if need_cmd cloudflared; then
    log "Creating Cloudflare Tunnel '${CF_TUNNEL_NAME}' (login browser will open if needed)…"
    cloudflared tunnel login || warn "cloudflared login may already be done."
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
log "Bringing up Phase A: identity provider…"
if [ "${ENABLE_AUTHENTIK:-true}" = "true" ]; then
  dc "$SVC/authentik" up -d
  wait_healthy authentik-server-1 60 || wait_healthy "$(docker ps --format '{{.Names}}' | grep -m1 authentik-server)" 60 || true
fi

log "Bringing up Phase B: applications…"
[ "${ENABLE_IMMICH:-true}"       = "true" ] && dc "$SVC/immich" up -d
[ "${ENABLE_OPENCLOUD:-true}"    = "true" ] && dc "$SVC/opencloud" up -d
[ "${ENABLE_ROLLTOP:-true}"      = "true" ] && dc "$SVC/rolltop" up -d --build
[ "${ENABLE_VAULTWARDEN:-true}"  = "true" ] && dc "$SVC/vaultwarden" up -d
[ "${ENABLE_SILVERBULLET:-true}" = "true" ] && dc "$SVC/silverbullet" up -d
[ "${ENABLE_HOMEPAGE:-true}"     = "true" ] && dc "$SVC/homepage" up -d

log "Bringing up Phase C: OIDC consumers…"
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
