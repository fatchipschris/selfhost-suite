# Self-Hosted Productivity Suite

> **Davenport Software — "Deploy your own private productivity suite."**
> One repo, one `deploy.sh`, fresh secrets, your domain. Photos, files +
> collaborative office, webmail, SSO, passwords, a wiki, notes, and a launcher
> — all self-hosted behind a Cloudflare Tunnel.

This is a **reusable** deployment package distilled from a live production
install. It ships **no real secrets**: every password/key/token is **generated
fresh** by `deploy.sh` into per-service `.env` files (chmod 600, git-ignored).

---

## 1. What you get

| Service | What it does | Image | Public host (default) | Local port |
|---|---|---|---|---|
| **Authentik** | SSO / Identity Provider (OIDC) | `ghcr.io/goauthentik/server` | `auth.<domain>` | 9000 |
| **Immich** | Photo & video library (+ ML) | `ghcr.io/immich-app/immich-server` | `photos.<domain>` | 2283 |
| **OpenCloud** | File sync & share | `opencloudeu/opencloud-rolling` | `files.<domain>` | 9200 |
| ↳ **Collabora CODE** | In-browser office editor | `collabora/code` | `collabora.<domain>` | 9980 |
| ↳ **WOPI / collaboration** | OpenCloud↔Collabora bridge | `opencloudeu/opencloud-rolling` | `wopi.<domain>` | 9300 |
| **Rolltop** | Webmail client (IMAP/SMTP) | `ghcr.io/grahamsz/rolltop` (patched) | `mail.<domain>` | 8090 |
| **Vaultwarden** | Password manager (Bitwarden-compatible) | `vaultwarden/server` | `vault.<domain>` | 8089 |
| **Outline** | Team knowledge base / wiki | `outlinewiki/outline` | `outline.<domain>` | 3300 |
| **SilverBullet** | Markdown notes | `ghcr.io/silverbulletmd/silverbullet` | `notes.<domain>` | 8091 |
| **Homepage** | Dashboard / app launcher | `ghcr.io/gethomepage/homepage` | `home.<domain>` | 3010 |

All containers bind to **`127.0.0.1` only**. The internet reaches them solely
through the **Cloudflare Tunnel**, which terminates TLS. Nothing listens on a
public interface; no inbound ports are opened on the host firewall.

---

## 2. Architecture & dependencies

```
                         Internet (HTTPS)
                               │
                    Cloudflare edge (TLS)
                               │  cloudflared tunnel
                               ▼
        ┌──────────────── host: 127.0.0.1 ────────────────┐
        │                                                  │
   Authentik (IdP) ◀───OIDC─── Outline                     │
        ▲                                                  │
        │ (optional OIDC for other apps later)             │
        │                                                  │
   OpenCloud ◀──WOPI──▶ collaboration ◀──▶ Collabora CODE  │
        │  (built-in IdP; OC_DOMAIN baked into OIDC issuer) │
        │                                                  │
   Immich   Vaultwarden   Rolltop   SilverBullet   Homepage │
        └──────────────────────────────────────────────────┘
```

**Hard dependencies:**
- **Outline → Authentik** — Outline has *no* local password login; it requires
  the Authentik OIDC provider. Authentik must be up and its provider created
  before Outline login works.
- **OpenCloud → Collabora + WOPI** — office editing needs all three of
  `opencloud`, `collaboration` (WOPI), and `collabora` containers, plus the
  three public hostnames (`files`, `collabora`, `wopi`) reachable over HTTPS.
- Immich, Outline each run their **own** Postgres + Redis; Authentik runs its
  own Postgres. No shared database.

**Deploy order** (`deploy.sh` does this automatically):
1. **Phase A** — Authentik (IdP) + its DB.
2. **Phase B** — the standalone apps (Immich, OpenCloud+Collabora, Rolltop,
   Vaultwarden, SilverBullet, Homepage), each with its own DB/Redis.
3. **Phase C** — OIDC consumers (Outline), once Authentik is reachable.

---

## 3. Quick start

```bash
git clone <this-repo> selfhost-suite && cd selfhost-suite

cp config.env.example config.env
$EDITOR config.env          # set BASE_DOMAIN, ADMIN_EMAIL, pick services

./deploy.sh                 # installs Docker if needed, generates secrets, brings stacks up
```

Useful flags:

| Flag | Effect |
|---|---|
| `--yes` / `-y` | Non-interactive (assume "yes" to prompts, e.g. Docker install). |
| `--render-only` | Generate `.env` files + the cloudflared config, but **don't** `docker compose up`. Great for inspecting first. |
| `--tunnel` | Also run `cloudflared tunnel create` + route DNS (requires `cloudflared` logged in). |

Re-running `deploy.sh` is **idempotent for secrets**: an already-rendered
`.env` is preserved (it will **not** rotate a DB password and orphan its data).
Delete a service's `.env` to force-regenerate it.

---

## 4. Configuration (`config.env`)

Copy `config.env.example` → `config.env`. Key fields:

- `BASE_DOMAIN` — your apex domain; every service defaults to a subdomain of it.
- `ADMIN_EMAIL` — bootstrap admin + SMTP "from" default.
- `ENABLE_<SERVICE>="true"/"false"` — **pick your subset.** Disabled services
  are skipped entirely and left out of the tunnel config.
- Per-service `*_DOMAIN` overrides — only if you don't want the default subdomain.
- Storage paths (`IMMICH_UPLOAD_LOCATION`, `OPENCLOUD_DATA_DIR`, …) — point big
  data at a dedicated disk; blank = `./data` under the service dir.
- `SMTP_*` — optional; wired into Outline, Vaultwarden, OpenCloud notifications.

> **No secrets live in `config.env`.** Everything secret is generated.

---

## 5. How secrets are handled

`deploy.sh` renders each `services/<svc>/.env.template` → `.env`, substituting
`__PLACEHOLDER__` values from `config.env`, then replacing every `__GENERATE__`
marker with a **fresh** `openssl rand` value (each marker gets its own distinct
secret). Format-specific secrets are then strengthened:

| Secret | Generation |
|---|---|
| DB passwords (Immich, Outline, Authentik, OpenCloud admin, Collabora admin) | `openssl rand` url-safe, 24 B |
| `AUTHENTIK_SECRET_KEY` | `openssl rand -hex 64` |
| `AUTHENTIK_BOOTSTRAP_TOKEN` | `openssl rand -hex 32` (also saved to `services/authentik/.apitoken`) |
| Outline `SECRET_KEY` / `UTILS_SECRET` | `openssl rand -hex 32` |
| Vaultwarden `ADMIN_TOKEN` | `openssl rand -base64 48` |
| Rolltop `ROLLTOP_MASTER_KEY` | `openssl rand -hex 32` |
| SilverBullet basic-auth | `<admin-localpart>:<random>` |

Rendered `.env`, `out/`, and all data dirs are **git-ignored**. Templates are
committed (no real values). **Back up the rendered `.env` files** somewhere
safe — losing e.g. the Vaultwarden `ADMIN_TOKEN` or Authentik `SECRET_KEY` is
disruptive; losing `ROLLTOP_MASTER_KEY` means re-adding all webmail accounts.

---

## 6. Cloudflare Tunnel + DNS

`deploy.sh` always renders `out/cloudflared/config.yml` containing an ingress
rule per **enabled** service (hostname → `http://127.0.0.1:<port>`), ending in
a `404` catch-all. The hostname→port mapping matches the table in §1.

### Automated (`./deploy.sh --tunnel`)
Requires `cloudflared` installed and `cloudflared tunnel login` done. The script
will `tunnel create "$CF_TUNNEL_NAME"`, splice the tunnel UUID into the config,
and `tunnel route dns` each hostname. Then install it:

```bash
sudo cp out/cloudflared/config.yml /etc/cloudflared/config.yml
sudo cloudflared service install     # or run: cloudflared tunnel run <name>
```

### Manual
```bash
cloudflared tunnel login
cloudflared tunnel create selfhost-suite          # note the UUID it prints
# edit out/cloudflared/config.yml: replace __SET_BY_cloudflared_tunnel_create__
#   with the UUID (both the `tunnel:` line and the credentials-file path)
sudo cp out/cloudflared/config.yml /etc/cloudflared/config.yml
sudo cp ~/.cloudflared/<UUID>.json /etc/cloudflared/<UUID>.json
for h in auth photos files collabora wopi mail vault outline notes home; do
  cloudflared tunnel route dns selfhost-suite "$h.<your-domain>"
done
sudo cloudflared service install
```

Each `tunnel route dns` creates a proxied `CNAME` → `<UUID>.cfargotunnel.com`
in Cloudflare DNS. Confirm the records are **proxied (orange cloud)**.

---

## 7. First-login wiring (post-deploy)

### 7.1 Authentik (do this first)
1. Browse to `https://auth.<domain>/`. Log in as **`akadmin`** with
   `AUTHENTIK_BOOTSTRAP_PASSWORD` from `services/authentik/.env`.
   > **GOTCHA:** the bootstrap password / token / email apply **only on the
   > first DB init** (empty `pgdata`). Changing them in `.env` afterward does
   > nothing — reset via the Authentik UI or `ak` CLI instead.
2. Set up your own admin user + (recommended) MFA.

### 7.2 Outline ↔ Authentik OIDC
Outline can't log anyone in until this is done.
1. In Authentik: **Applications → Providers → Create → OAuth2/OpenID Provider**.
   - Redirect URI: `https://outline.<domain>/auth/oidc.callback`
   - Note the generated **Client ID** and **Client Secret**.
   - Scopes: `openid profile email`.
2. Create an **Application** bound to that provider (slug e.g. `outline`).
3. Put the values in `services/outline/.env`:
   ```
   OIDC_CLIENT_ID=<from authentik>
   OIDC_CLIENT_SECRET=<from authentik>
   ```
   (The auth/token/userinfo URIs are already templated to `auth.<domain>`.)
4. Restart Outline: `(cd services/outline && docker compose up -d)`.
5. Visit `https://outline.<domain>/` → "Continue with Authentik".

### 7.3 OpenCloud ↔ Collabora (secure-view office editing)
Mostly automatic via the `weboffice/collabora.yml` + `external-proxy` overlays.
After `up`, verify:
- `https://collabora.<domain>/hosting/discovery` returns XML (CODE is healthy).
- In OpenCloud, opening a `.docx`/`.odt` offers **Collabora** as an editor.
- Admin console: `https://collabora.<domain>/browser/dist/admin/admin.html`
  (user/pass = `COLLABORA_ADMIN_*` in `services/opencloud/.env`).
> **GOTCHA:** `OC_DOMAIN` is baked into the OpenCloud OIDC issuer + built-in IdP
> on **first init**. Decide the final `files.<domain>` hostname *before* the
> first `up`; changing it later breaks login and the WOPI/CSP frame rules.

### 7.4 OpenCloud admin login
User `admin`, password = `INITIAL_ADMIN_PASSWORD` in `services/opencloud/.env`
(first-init-only, like Authentik).

### 7.5 Vaultwarden
1. Browse `https://vault.<domain>/`, create your account while
   `SIGNUPS_ALLOWED=true`.
2. Then set `SIGNUPS_ALLOWED=false` in `services/vaultwarden/.env` and
   `docker compose up -d` to lock down registration.
3. Admin panel: `https://vault.<domain>/admin` with `ADMIN_TOKEN`.

### 7.6 Rolltop (webmail)
Per-user IMAP/SMTP client — users add their own mail accounts at login. No
server-side mailboxes. See the patch note in §8.

### 7.7 SilverBullet / Homepage
- SilverBullet: HTTP basic-auth, creds in `services/silverbullet/.env`
  (`SB_USER=user:pass`).
- Homepage: edit `services/homepage/config/services.yaml` to add tiles/links to
  your other services (icons, hrefs). It's a static dashboard.

---

## 8. Known gotchas (lessons from the production build)

- **Rolltop missing-plugin patch.** Upstream `ghcr.io/grahamsz/rolltop:latest`
  ships the `mail_filters` plugin *manifest* but not the compiled `.so`, so the
  loader aborts at startup with `realpath failed`. `services/rolltop/Dockerfile`
  builds a local image that deletes `/app/plugins/mail_filters` so the loader
  skips it. (That's why Rolltop is `build: .`, not a bare image.)
- **SOGo vs IMAP → use Rolltop.** An earlier attempt used SOGo as the webmail/
  groupware layer; it was heavy and fought the IMAP setup. Rolltop (a thin
  per-user IMAP/SMTP webmail client) was the right altitude for "webmail in
  front of existing mailboxes." This package ships Rolltop.
- **OpenCloud `OC_DOMAIN` is immutable-ish.** Baked into the OIDC issuer + IdP
  on first init. Pick the hostname before first `up`. See §7.3.
- **Authentik bootstrap is first-init-only.** `AUTHENTIK_BOOTSTRAP_PASSWORD` /
  `_TOKEN` / `_EMAIL` only apply when `pgdata` is empty. After that, manage
  users/tokens in the UI. The generated token is stashed at
  `services/authentik/.apitoken` for first-boot API automation.
- **Collabora needs privileges.** The CODE container runs with `SYS_ADMIN` +
  `seccomp:unconfined` + `apparmor:unconfined` (its sandbox needs them). Expected.
- **Everything binds 127.0.0.1.** If you front this with something other than
  Cloudflare Tunnel (e.g. a local reverse proxy), it must reach the loopback
  ports in §1; do **not** publish these ports publicly without TLS + auth.
- **`home.<domain>` port.** Homepage listens on `3010`. (The source production
  tunnel had a stale `home → 9000` rule pointing at Authentik; this package
  routes `home.<domain>` to `3010` correctly.)

---

## 9. Repository layout

```
selfhost-suite/
├── deploy.sh                     # master one-shot deployer
├── config.env.example            # copy → config.env (domains, toggles, SMTP)
├── lib/common.sh                 # helpers: secret gen, env render, compose, healthchecks
├── cloudflared/
│   └── config.yml.template       # tunnel ingress template (rendered to out/)
└── services/
    ├── authentik/   { docker-compose.yml, .env.template }
    ├── immich/      { docker-compose.yml, .env.template }
    ├── opencloud/   { docker-compose.yml, .env.template,
    │                  weboffice/collabora.yml, external-proxy/{opencloud,collabora}.yml,
    │                  config/opencloud/{csp.yaml,banned-password-list.txt} }
    ├── rolltop/     { docker-compose.yml, Dockerfile, .env.rolltop.template }
    ├── vaultwarden/ { docker-compose.yml, .env.template }
    ├── outline/     { docker-compose.yml, .env.template }
    ├── silverbullet/{ docker-compose.yml, .env.template }
    └── homepage/    { docker-compose.yml, config/* }
```

Rendered `.env` files, `out/`, and data directories are git-ignored and never
contain template placeholders after a successful deploy.

---

## 10. Day-2 operations

```bash
# status / logs for one service
(cd services/immich && docker compose ps)
(cd services/outline && docker compose logs -f)

# update a service to the latest pinned tag
(cd services/<svc> && docker compose pull && docker compose up -d)

# stop / start a service
(cd services/<svc> && docker compose down)
```

To add or remove a service later, flip its `ENABLE_*` in `config.env`, re-run
`./deploy.sh` (existing secrets preserved), and re-install the regenerated
`out/cloudflared/config.yml`.
