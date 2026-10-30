# auth-hack

Clubins' customer-auth reference implementation: a self-hosted **Logto OSS**
issuer, a **Go REST API** that validates Logto-issued JWTs, and a **Flutter
client** that signs in through Logto's hosted UI with authorization code +
PKCE. The venue domain is the representative product surface: owners and
staff read venue data and temperature readings with Logto-scoped tokens, and
time-limited renter access — read-only, one venue, 8 to 24 hours — is
enforced application-side as venue access grants in the Go API. No paid
Logto features.

Everything speaks standard OIDC — discovery, JWKS, RS256, code + PKCE — and
the Go API carries no SDK coupling to Logto: it validates tokens like any
third party would, which keeps the issuer swappable.

**Status.** Complete through the two-phase e2e smoke. Two limits are stated
up front rather than discovered later: all API stores are in-memory (this is
a reference, not a service), and a token issued by a *real* Logto has not
yet been proven accepted by the backend end to end — that proof lands as
soon as the one-time bootstrap in the [runbook](docs/RUNBOOK.md) is done.
See the [architecture](docs/ARCHITECTURE.md) for both.

## Quickstart (local stack)

```bash
# 1. Logto + its Postgres + the Go API
cd infra && cp .env.example .env
$EDITOR .env                          # set LOGTO_DB_PASSWORD (any dev value)
docker compose up -d --build
curl -fsS http://localhost:3301/oidc/.well-known/openid-configuration   # issuer discovery
curl -fsS http://localhost:8080/healthz                                 # Go API

# 2. One-time: bootstrap a Management API credential in the Admin Console
#    (exact click-path in docs/RUNBOOK.md), then seed Logto
$EDITOR .env                          # LOGTO_M2M_CLIENT_ID / _SECRET / TEST_USER_*
../idp/seed.sh                        # idempotent; prints the Flutter client ID

# 3. The app
flutter run --dart-define=CLUBINS_CLIENT_ID=<printed id>

# 4. End-to-end smoke — phase A needs docker; phase B needs go + python3
cd .. && scripts/smoke.sh --phase=all
```

## Component map

| Path | Component | Check |
| --- | --- | --- |
| `backend/` | Go API: OIDC guard, venues + readings, renter grants | `go test ./...` |
| `frontend/` | Flutter app: hosted-UI sign-in, venues UI, token inspector | `flutter analyze && flutter test` |
| `idp/` | Logto config-as-data: idempotent Management API seed | `idp/test/run-mock-tests.sh` |
| `infra/` | Local compose stack (Logto, Postgres, API) | `docker compose up -d --build` |
| `infra/nixos/` | Prod-shaped NixOS modules (oci-containers, Caddy TLS, SOPS) | `bash scripts/check-nix.sh` |
| `scripts/` | Spike tooling: `spike.sh`, `token-inspect.sh`, two-phase smoke | `scripts/test/run-tests.sh` |
| `.github/workflows/` | CI: per-component gates + gitleaks on every PR | runs on each PR |

## Where to read next

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — system shape, trust
  boundaries, the dual-credential venue-read composition, grant lifecycle,
  routes, CI gates, NixOS deploy path.
- [docs/RUNBOOK.md](docs/RUNBOOK.md) — operations: local stack, the one-time
  Admin Console bootstrap click-path, running the smoke, token inspection
  for support, secrets, rotating the M2M credential.
- [infra/README.md](infra/README.md) — the issuer wiring (the one subtle
  bit) and compose stack details.
- [idp/README.md](idp/README.md) — the seed and the one-time bootstrap.
- [scripts/README.md](scripts/README.md) — `spike.sh`, `token-inspect.sh`,
  and the smoke in detail.
- [frontend/AUTH.md](frontend/AUTH.md) — the Flutter side: OIDC
  configuration, redirects, scopes.
- [infra/nixos/README.md](infra/nixos/README.md) — production deploy on
  NixOS.
