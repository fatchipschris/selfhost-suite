#!/usr/bin/env bash
# Shared helpers for deploy.sh. Sourced, not executed.

set -euo pipefail

# ---- pretty output ---------------------------------------------------------
c_reset='\033[0m'; c_blue='\033[1;34m'; c_grn='\033[1;32m'; c_yel='\033[1;33m'; c_red='\033[1;31m'
log()  { printf "${c_blue}==>${c_reset} %s\n" "$*"; }
ok()   { printf "${c_grn}  ok${c_reset} %s\n" "$*"; }
warn() { printf "${c_yel}  !!${c_reset} %s\n" "$*" >&2; }
die()  { printf "${c_red}ERROR${c_reset} %s\n" "$*" >&2; exit 1; }

# ---- secret generators -----------------------------------------------------
# All real secrets in the source stacks were generated with openssl rand.
# We regenerate fresh ones here so the repo NEVER ships a real secret.
gen_hex()    { openssl rand -hex "${1:-32}"; }            # hex string, N bytes
gen_b64()    { openssl rand -base64 "${1:-32}" | tr -d '\n'; }
gen_pass()   { openssl rand -base64 "${1:-24}" | tr -d '\n/+='; }  # url/path-safe password
gen_uuid()   { cat /proc/sys/kernel/random/uuid; }

# ---- safe file creation ----------------------------------------------------
# Copy a template to dest so dest is never group/other-readable, even briefly.
# (umask 077 governs the create mode of the new file.)
secure_cp() {
  local src="$1" dest="$2"
  ( umask 077; cp "$src" "$dest" )
}

# Write stdin to dest with mode 600 from the moment of creation.
secure_write() {
  local dest="$1"
  ( umask 077; cat > "$dest" )
}

# Escape a string so it is safe as the REPLACEMENT half of `sed s|...|REPL|`.
# Neutralizes the delimiters we use (| and /), the escape char, the match-group
# ampersand, and embedded newlines.
sed_escape_repl() {
  printf '%s' "$1" | sed -e 's/[\/&|]/\\&/g' -e ':a' -e 'N' -e '$!ba' -e 's/\n/\\n/g'
}

# Write KEY=VALUE into an env file ONLY if the key is absent or empty there.
# Makes secret generation idempotent: re-running deploy.sh keeps existing
# secrets (so you don't lock yourself out / orphan a DB password).
ensure_kv() {
  local file="$1" key="$2" val="$3"
  ( umask 077; touch "$file" )
  if grep -qE "^${key}=.+" "$file" 2>/dev/null; then
    return 0  # already set with a non-empty value, keep it
  fi
  # remove any empty placeholder line, then append
  sed -i "/^${key}=$/d" "$file" 2>/dev/null || true
  printf '%s=%s\n' "$key" "$val" >> "$file"
}

# Plain (non-secret) KEY=VALUE: always overwrite to reflect config.env.
set_kv() {
  local file="$1" key="$2" val="$3"
  ( umask 077; touch "$file" )
  if grep -qE "^${key}=" "$file" 2>/dev/null; then
    local esc; esc=$(sed_escape_repl "$val")
    sed -i "s/^${key}=.*/${key}=${esc}/" "$file"
  else
    printf '%s=%s\n' "$key" "$val" >> "$file"
  fi
}

# ---- prerequisites ---------------------------------------------------------
need_cmd() { command -v "$1" >/dev/null 2>&1; }

install_docker() {
  if need_cmd docker && docker compose version >/dev/null 2>&1; then
    ok "docker + compose present ($(docker --version | awk '{print $3}' | tr -d ,))"
    return 0
  fi
  log "Installing Docker Engine + compose plugin (official convenience script)…"
  if [ "${ASSUME_YES:-0}" != "1" ]; then
    read -r -p "  Run get.docker.com install script with sudo? [y/N] " a
    [[ "$a" =~ ^[Yy]$ ]] || die "Docker required. Install it manually and re-run."
  fi
  curl -fsSL https://get.docker.com | sudo sh
  sudo usermod -aG docker "$USER" || true
  need_cmd docker || die "Docker install failed."
  ok "Docker installed (you may need to re-login for group membership)."
}

# ---- compose wrapper -------------------------------------------------------
# dc <service-dir> <compose args...>
dc() {
  local dir="$1"; shift
  ( cd "$dir" && docker compose "$@" )
}

# Wait until a container reports healthy (or running, if no healthcheck).
wait_healthy() {
  local name="$1" tries="${2:-60}" st
  log "Waiting for '$name' to become healthy…"
  for _ in $(seq 1 "$tries"); do
    st=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$name" 2>/dev/null || echo "missing")
    case "$st" in
      healthy|running) ok "$name is $st"; return 0 ;;
      missing) sleep 3 ;;
      *) sleep 3 ;;
    esac
  done
  warn "$name did not report healthy in time (status: ${st:-unknown})."
  return 1
}
