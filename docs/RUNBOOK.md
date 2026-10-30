# Runbook

Operating the auth-hack reference stack. Audience: a human with Docker,
plus Go and python3 for the smoke's second phase. Deep references:
[infra/README.md](../infra/README.md) (issuer wiring),
[idp/README.md](../idp/README.md) (seed),
[scripts/README.md](../scripts/README.md) (spike and smoke internals),
[infra/nixos/README.md](../infra/nixos/README.md) (production deploy),
[frontend/AUTH.md](../frontend/AUTH.md) (Flutter OIDC).

## 1. Local dev stack

Prereq: Docker Engine with Compose v2 (`docker compose version`).

```bash
cd infra
cp .env.example .env
$EDITOR .env                        # set LOGTO_DB_PASSWORD (any throwaway dev value)
docker compose up -d --build
```

First boot takes a minute or two: Logto seeds its database schema and the
sign-in experience before the core serves, and the backend waits for
Logto's health check before booting. Then verify — all three services
healthy, discovery answering, API healthy:

```bash
docker compose ps          # postgres, logto, backend all (healthy)
curl -fsS http://localhost:3301/oidc/.well-known/openid-configuration
#   → 200 JSON, "issuer": "http://localhost:3301/oidc"
curl -fsS http://localhost:8080/healthz
#   → {"status":"ok"}
```

| Surface | URL |
| --- | --- |
| Logto core (OIDC) | http://localhost:3301 |
| Logto admin console | http://localhost:3302 |
| Go API | http://localhost:8080 (`GET /healthz` public; everything else bearer-guarded) |

Teardown: `docker compose down` keeps the Logto database volume;
`docker compose down -v` drops it.

## 2. One-time Logto bootstrap, then seed (fresh instance)

The Management API is itself protected by an M2M application, and the first
one cannot be created through the API it unlocks. That first credential is
created once in the Admin Console — never by writing into Logto's
PostgreSQL schema, which breaks silently across Logto releases.

1. Stack up (section 1) and wait for discovery to answer.
2. Open the Admin Console at `http://localhost:3302` (production:
   `https://admin.login.clubins.de`) and finish the first-boot admin setup
   if the instance is brand new.
3. **Applications → Create application → Machine-to-machine**. Name it
   `Logto seed M2M` (any name works).
4. On the application's page, open the **Roles** tab and assign the
   built-in role **`Logto Management API access`**. Without this role the
   token endpoint answers, but every `/api/*` call is denied.
5. Copy the **Endpoint** (the resource indicator, `https://default.logto.app/api`
   in OSS — also the compiled-in default, so nothing to configure),
   the **App ID**, and the **App secret** into `infra/.env` as
   `LOGTO_M2M_CLIENT_ID` and `LOGTO_M2M_CLIENT_SECRET`.
6. In the same file, set `TEST_USER_EMAIL` and `TEST_USER_PASSWORD` (the
   seeded test user; the password comes from the environment on every run,
   never hardcoded).

Then seed — idempotent, safe to run any number of times:

```bash
../idp/seed.sh        # from infra/, or idp/seed.sh from anywhere
```

The first run prints one `created` line per object; every later run prints
`exists` and creates nothing. The summary ends with the generated **client
ID** — Logto generates it and it cannot be pinned, so the seed matches the
app by name and prints the ID. Build the app with it:

```bash
flutter run --dart-define=CLUBINS_CLIENT_ID=<printed id>
```

What the seed creates: the API resource `https://api.clubins.de` (scopes
`venues:read` and `venues:write`), the native Flutter application (PKCE,
redirects `clubins://login-callback` and `clubins://logout-callback`), and
the test user.

## 3. End-to-end smoke

```bash
scripts/smoke.sh --phase=all    # or --phase=a / --phase=b
```

Phase A needs Docker; Phase B needs `go` and `python3` on PATH (both phases
need `curl` and `jq`). Every step prints PASS/FAIL/SKIP with its name; the
run exits 1 naming the first failed step.

**Phase A — real compose stack.** Boots Logto + Postgres + the API with
`--wait`, seeds Logto via the Management API, runs the spike against the
real issuer (discovery issuer match, JWKS keys present, token issuance),
then asserts `/healthz` is 200 and unauthenticated `/venues` is 401.
Without M2M credentials the seed and token-issuance steps report SKIP with
that reason — everything else still runs. Placeholder values
(`replace-me-*`) copied from `.env.example` do not count as credentials:
you get the documented SKIP, not a confusing `invalid_client` from the
issuer.

**Phase B — stub IdP.** Builds the backend (`go build ./cmd/api`), boots a
Python stub Logto (RS256 + JWKS) on a free port, and runs the same binary
against it over real HTTP: token acceptance, the negative paths (401 for
missing or wrong-audience tokens, 403 for write-only tokens), and the full
grant lifecycle — create 201, single-venue scope, TTL floor 422, real-time
expiry (200 then 403), revoke (200 then 410).

Defaults are sane (backend on 8090, the grant floor lowered to 1 s for
Phase B, a 420 s compose wait); see `scripts/smoke.sh --help` for the
knobs. CI runs both phases on every PR touching `scripts/`, `infra/`,
`idp/`, or `backend/` (`.github/workflows/e2e.yml`).

## 4. Token inspection (support)

```bash
scripts/token-inspect.sh 'eyJhbGciOi...'    # token as an argument
curl -s .../oidc/token | jq -r .access_token | scripts/token-inspect.sh   # or on stdin
```

Decodes the JOSE header and payload (pretty via `jq`), states whether the
token is `VALID` or `EXPIRED` against the local clock, and flags `alg=none`
tokens. It is a decoder, not a validator — the output always says
`signature NOT verified`. Never make an authentication decision from this
tool; only the Go API (`backend/internal/auth`) verifies signatures. Exit
status: 0 on any decodable token (expired or not), 1 on malformed input.

## 5. Secrets hygiene

- **No secrets in git.** `infra/.env` is git-ignored; `.env.example`
  carries placeholders only. CI scans full history with gitleaks (the
  pinned, checksum-verified binary) on every PR and push.
- The M2M app secret and test-user password live only in `infra/.env` (or
  your secret store of choice).
- Production (NixOS) reads secrets from SOPS-encrypted files
  (`infra/secrets/*.enc.*`), decrypted by sops-nix from the host age key at
  `/var/lib/sops-nix/key.txt`. The repo's `.sops.yaml` carries a placeholder
  recipient — replace it with the host's public key before encrypting
  anything. Until then there is no real key material anywhere in the repo.

## 6. Rotating the seeded M2M secret

The M2M credential is the only long-lived secret the seed depends on. To
rotate it:

1. In the Admin Console, create a replacement M2M application with the same
   built-in `Logto Management API access` role (section 2, steps 3–4) — or,
   if your Logto version offers secret regeneration on the application's
   page, the one you bootstrapped, use that.
2. Put the new ID and secret in `infra/.env`
   (`LOGTO_M2M_CLIENT_ID` / `LOGTO_M2M_CLIENT_SECRET`).
3. Verify with `idp/seed.sh`: a run that prints `exists` per object proves
   the new credential reaches the Management API (and creates nothing).
4. Remove the old credential — delete the old M2M application if you made a
   replacement.

On a NixOS host the same values live wherever the operator runs the seed
from; the SOPS scaffold today carries only the Logto database env
(`logto-env`), not the M2M credential.

## 7. Honest status

- **Tokens issued by a real Logto have not yet been proven accepted by the
  backend end to end.** That proof lands right after the one-time
  bootstrap (section 2) is done: the spike's token-issuance step turns from
  SKIP to PASS, and the smoke's Phase A stops skipping the seed and
  issuance steps.
- Everything else in the authenticated path is proven over real HTTP
  (Phase B) and in unit tests — RS256 verification, the negative paths, the
  grant lifecycle.
- All API stores are in-memory; restarts drop grants and reset sample data.
- The NixOS modules are prod-shaped but unevaluated in CI (no Nix runner
  yet); `scripts/check-nix.sh` parse-checks them wherever Nix is available.
