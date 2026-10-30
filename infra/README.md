# infra/

Deployment-shaped infrastructure for the Clubins customer-auth stack.

- `docker-compose.yml` — local dev stack: Logto OSS + its PostgreSQL + the Go API
- `nixos/` — prod-shaped NixOS modules (oci-containers, Caddy, SOPS) that mirror this layout
- `.env.example` — template for the stack's local configuration

## Quickstart (local dev stack)

Prereq: Docker Engine with Compose v2 (`docker compose version`).

```bash
cd infra
cp .env.example .env    # then edit LOGTO_DB_PASSWORD (any throwaway dev value)
docker compose up -d --build
```

Wait for health, then verify — expect HTTP 200 and `"issuer":
"http://localhost:3301/oidc"`:

```bash
docker compose ps   # postgres, logto, backend all (healthy)
curl -fsS http://localhost:3301/oidc/.well-known/openid-configuration
curl -fsS http://localhost:8080/healthz
```

| Surface                  | URL                                    |
| ------------------------ | -------------------------------------- |
| Logto core (OIDC)        | http://localhost:3301                  |
| Logto admin console      | http://localhost:3302                  |
| Go API                   | http://localhost:8080 (`GET /healthz` public, everything else bearer-guarded) |

Teardown: `docker compose down` keeps the Logto database volume;
`docker compose down -v` drops it.

First boot takes a minute or two: Logto seeds its database schema and the
sign-in experience before the core serves, and the backend waits for Logto's
health check before booting (its JWKS fetch fails closed otherwise).

## How the issuer wiring fits together

Logto serves OIDC under `<ENDPOINT>/oidc` and reports that URL as the
`issuer` in its discovery document. Three components must agree on it, or
validation fails closed by design:

| Component            | Setting                            | Local default                    |
| -------------------- | ---------------------------------- | -------------------------------- |
| Logto                | `ENDPOINT` env                     | `http://localhost:3301`          |
| Go API               | `ISSUER_URL` env (checks `iss`)    | `http://localhost:3301/oidc`     |
| Flutter app          | `CLUBINS_ISSUER` dart-define       | `http://localhost:3301/oidc`     |

One asymmetry is deliberate: inside the compose network the API cannot reach
`http://localhost:3301` (the container's own loopback), so its JWKS fetch is
pinned to the service-internal path with the `JWKS_URL` env
(`http://logto:3001/oidc/jwks`, default supplied by the compose file). Token
checks — RS256 signature against the fetched keys, `iss`, `aud`, `exp` — all
still enforce the public issuer URL. When the API runs on the host instead of
compose, leave `JWKS_URL` unset and discovery is used, as in production.

If you move Logto off the default port (a device on your LAN needs to reach
it, say), change `LOGTO_ENDPOINT` **and** `ISSUER_URL` together in `.env` —
the admin `ENDPOINT`/`ISSUER_URL` coupling note in `.env.example` repeats
this.

## Scope of this stack

- **Postgres serves Logto only.** The Go API uses in-memory stores in this
  reference; no backend database configuration exists.
- The admin console at `localhost:3302` is for local configuration (register
  the Flutter app, create the venues API resource). The `idp/` seed scripts
  (API resource, app registration, roles) replace this click-path once they
  land.
- No secrets belong in git: `.env` is ignored, the NixOS shape reads SOPS
  secrets, and `.env.example` carries placeholders only.
