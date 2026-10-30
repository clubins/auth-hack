# Architecture

Logto OSS owns identity; the Go API owns authorization. Logto answers *who
the caller is*: it runs the hosted sign-in UI, issues RS256 access tokens,
and publishes discovery and JWKS. The Go API trusts none of that until it
has verified the token itself — signature against the issuer's fetched
keys, then issuer, audience, expiry, and the route's scope. Nothing in the
API is coupled to Logto beyond configuration; it consumes standard OIDC
(discovery, JWKS, authorization code + PKCE for users, client_credentials
for the seed), so the issuer is swappable by env var.

The venue domain is the representative product surface: venues with
temperature readings, owners and staff holding Logto-scoped tokens, and
renters holding time-limited, read-only, single-venue **access grants**
enforced application-side. (Logto Organizations — the paid mechanism for
this — is out: it is a paid add-on, and even licensed it has no native
expiring membership, so the window lives in a plain table in the Go API
either way.)

## System shape

```
                      ┌─────────────────────────────────┐
                      │ Logto OSS — the identity issuer │
                      │ discovery · JWKS · authorize ·  │
                      │ token · hosted sign-in UI       │
                      └────────▲───────────────▲────────┘
           authorization code  │               │ M2M client_credentials
           + PKCE (user        │               │ (idp/seed.sh only —
            sign-in)           │               │  never an API credential)
                       ┌───────┴──────┐        │
                       │ Flutter app  │        │
                       └───────┬──────┘        │
                               │               │
        Bearer access token (Logto JWT, RS256) │
        or renter grant token (opaque, not a JWT)
                               │               │
                               ▼               ▼
                  ┌─────────────────────────────────┐
                  │ Go API — authorization + data   │
                  │ verifies signature, iss, aud,   │
                  │ exp, scope; resolves renter     │
                  │ grants; serves venues, readings │
                  └─────────────────────────────────┘
```

| Component | Where it runs | Responsibility |
| --- | --- | --- |
| Logto OSS (`svhd/logto:1.45.0`) + PostgreSQL 16 | compose (dev), oci-containers (NixOS) | Identity: discovery, JWKS, authorize, token, hosted sign-in UI, admin console |
| Go API (`backend/`, Go 1.23, `golang-jwt/jwt/v5` v5.3.1) | compose, standalone binary, CI | Verification, scope checks, venues + readings data, renter grants |
| Flutter app (`frontend/`, `oidc` package) | device | Sign-in via the system browser (external user agent, RFC 8252), venues UI, token inspector, share-access screen |
| `idp/seed.sh` | operator | Idempotent provisioning — API resource, scopes, native app, test user — via the Management API |

## Trust boundaries

**Logto never makes authorization decisions.** It attests identity (the
`sub` claim) and mints tokens carrying the requested scopes. Whether a
subject may read venue v-001 is decided only by the Go API.

**The API trusts only verified token content.** Allowed algorithms are
pinned to RS256 and ES256 before any key lookup — `none` and HMAC are
rejected outright, which rules out algorithm-confusion attacks. Every check
must pass: `iss` equals the configured issuer exactly, `aud` equals the
configured audience, `exp` allows a 30-second clock skew, and the route's
scope must be present. Discovery and the first JWKS fetch run at boot, so a
broken issuer fails the startup loudly instead of failing every request
quietly later. Cached keys refresh on a TTL (1 hour default) and
immediately on an unknown key id.

**The seed's M2M credential is admin-plane only.** `idp/seed.sh` drives the
Management API with a client_credentials token scoped to
`https://default.logto.app/api`. That token is worthless against the
product API: the Go API expects audience `https://api.clubins.de`, so a
stray use of the admin credential on a venues route dies on the audience
check.

**Logs stay outside the credential plane.** Request logging records method,
path, status, and duration — never headers, query strings, or bodies — and
grant-store errors never echo tokens.

## Sign-in flow

| # | Step | Who |
| --- | --- | --- |
| 1 | Open the hosted sign-in page (authorize endpoint, `code_challenge` S256) | Flutter → Logto |
| 2 | Sign up or sign in (email + password today; MFA and passkeys are Logto product surface later) | user, on Logto's UI |
| 3 | Code redirect (state checked) | Logto → Flutter |
| 4 | Token exchange (`code_verifier`); tokens into device secure storage; silent refresh via `offline_access` | Flutter → Logto |
| 5 | Authenticated call, `Authorization: Bearer <access token>` | Flutter → Go API |
| 6 | Verify: RS256 via cached JWKS, then `iss`, `aud`, `exp`; scope per route; 401 on any failure | Go API |

The app requests `openid profile email offline_access` plus the
API-resource scope `https://api.clubins.de/venues:read`. The API's scopes
are derived from its audience — `https://api.clubins.de/venues:read` and
`https://api.clubins.de/venues:write` — so scope and audience always agree
on the API's origin.

## Credential composition: the dual-credential venue reads

Two bearer credentials can reach the API:

- a **Logto access token** — a JWT, RS256-signed, audience
  `https://api.clubins.de`;
- a **renter grant token** — an opaque random string the API mints itself.
  Not a JWT.

`GET /venues/{id}` and `GET /venues/{id}/readings` accept either. The order
of checks is load-bearing: **grant tokens are resolved before the OIDC
guard sees the request.** An opaque grant token could never verify as a
Logto JWT, so if the guard ran first it would 401 every grant holder before
the resolver got a chance. These routes therefore try the grant resolver
first; anything that resolves to no grant — Logto JWTs among them — falls
through to the OIDC guard and its scope check.

How the resolver answers (`grants.VenueReadGuard`):

| Bearer token presented | Result |
| --- | --- |
| No `Authorization: Bearer` header | fall through → OIDC guard rejects (401) |
| Token resolves to no grant | fall through → OIDC path (401 for junk, 200 for a valid Logto token) |
| Grant expired | 403 — credential understood, no longer honored |
| Grant revoked | 410 — credential explicitly withdrawn |
| Valid grant, different venue | 403 — outside the grant's scope |
| Valid grant, this venue | 200 — subject is the grant's subject |

**Grant management is strictly OIDC-only.** Creating, listing, and
revoking grants requires a verified Logto token (`venues:write` to create
or revoke, `venues:read` to list). A grant token presented to a management
route fails OIDC verification and gets 401 — a renter can never read, let
alone mint, grants.

Effective route map (guarded mode):

| Method | Path | Credential | Scope |
| --- | --- | --- | --- |
| GET | `/healthz` | public | — |
| GET | `/venues` | Logto JWT | `venues:read` |
| GET | `/venues/{id}` | grant token (that venue) **or** Logto JWT | `venues:read` on the JWT path |
| GET | `/venues/{id}/readings` | same as above | `venues:read` on the JWT path |
| POST | `/venues/{id}/grants` | Logto JWT | `venues:write` |
| GET | `/venues/{id}/grants` | Logto JWT | `venues:read` |
| DELETE | `/grants/{id}` | Logto JWT | `venues:write` |

With no guard configured — local development and tests without an IdP —
the same routes mount unguarded; grant creation still demands a context
principal, so unguarded callers get the same 401 they would behind a guard
that injected nothing.

Readings deserve one note: existence is decided by the venues store, so an
unknown venue is 404 on `/venues/{id}/readings` exactly as on
`/venues/{id}` — one notion of which venues exist. Readings are served
oldest first with the wire shape `id`, `measuredAt`, `temperatureC`.

## Grant lifecycle

A grant is read-only, bound to exactly one venue, and bounded in time.
Creation is the only moment of power.

**Creation.** `POST /venues/{id}/grants` with an optional `{"ttl": "8h"}`
body. An omitted TTL defaults to the minimum (8 hours). The window is
enforced server-side at creation from config bounds — 8 to 24 hours by
default; a TTL outside the bounds is 422, a malformed body 400. The
response (201, `Location: /grants/{id}`) carries the grant token **exactly
once**.

**Redaction.** Every other surface returns a projection without the token —
`id`, `venueId`, `subject`, `expiresAt`, `createdAt`, `revokedAt`. A list
response must not hand a venue-read-scoped caller the way to impersonate a
renter, and a revoke response only needs the revocation stamp. The token is
opaque, minted with crypto/rand, and never appears in logs. Owners share it
out of band: the Flutter app's share-access screen shows it once with a
copy button, and the renter presents it as `Authorization: Bearer <grant
token>`.

**Expiry and revocation at use time.** Whether a grant is honored is
decided when a request arrives, not by a cleanup job: the resolver compares
the caller's clock against expiry, so an expired grant is inert the moment
it expires even though the row still exists. Revocation takes precedence
over expiry when both apply; revoking is idempotent and keeps the first
timestamp; a revoked grant's next venue read is 410.

**Storage — an explicit reference limitation.** All three stores (venues,
readings, grants) are in-memory, seeded at boot with sample venues
`v-001` and `v-002`. A restart drops every grant — renter access ends with
the process — and resets sample data. The store interfaces are the seam a
Postgres implementation plugs into; none exists in this repo yet.

## Configuration

All environment, all optional; defaults follow the local stack (pulled from
`backend/internal/config/config.go`):

| Variable | Default | Meaning |
| --- | --- | --- |
| `PORT` | `8080` | Listen port |
| `LOG_LEVEL` | `info` | `debug`, `info`, `warn`, or `error` |
| `ISSUER_URL` | `http://localhost:3301/oidc` | Expected `iss`; production uses `https://login.clubins.de/oidc` |
| `AUDIENCE` | `https://api.clubins.de` | Expected `aud`; the API's scopes derive from it |
| `JWKS_URL` | unset → issuer discovery | Pin the key location; compose pins it to the service-internal path |
| `JWKS_CACHE_TTL` | `1h` | Signing-key cache lifetime; unknown key ids refetch immediately |
| `GRANT_MIN_TTL` | `8h` | Grant floor at creation; lower it only for tests and e2e |
| `GRANT_MAX_TTL` | `24h` | Grant ceiling at creation |

Invalid values fail the boot: malformed URLs, non-positive durations, or a
min above a max all refuse to start rather than get silently corrected.
Why `JWKS_URL` exists and why `LOGTO_ENDPOINT` and `ISSUER_URL` must change
together: [infra/README.md](../infra/README.md).

## CI gates

| Workflow | Runs on | What it does |
| --- | --- | --- |
| `backend.yml` | `backend/**` | `go test ./...`, golangci-lint, govulncheck |
| `frontend.yml` | `frontend/**` | `flutter pub get`, `flutter analyze`, `flutter test` |
| `idp.yml` | `idp/**` | `bash -n`, shellcheck (v0.10.0, digest-pinned), seed idempotency against the Management API mock |
| `scripts.yml` | `scripts/**` | `bash -n`, shellcheck, stub byte-compile, the 26-assertion Docker-free harness |
| `e2e.yml` | `scripts/`, `infra/`, `idp/`, `backend/**` | the two-phase smoke (below) |
| `security.yml` | every PR and push | gitleaks full-history scan — the pinned, checksum-verified binary, because the official action needs a paid license for organization repos, which the $0 budget rules out |

Actions are pinned to commit SHAs and every workflow runs least-privilege
(`contents: read`). There is no Nix runner in CI;
`scripts/check-nix.sh` is the parse gate wherever Nix is available.

### The two-phase e2e, plainly

**Phase A — the real stack.** Boots the compose stack (`--wait` until every
service is healthy), seeds Logto through its Management API, runs the spike
against the real issuer (discovery returns 200 with the exact expected
issuer, the JWKS serves keys, a token is issued), and asserts `/healthz` is
200 and unauthenticated `/venues` is 401. This tier proves the real wiring:
a live Logto serving OIDC, three components agreeing on the issuer string,
and the deployed API container actually enforcing its guard — an
unauthenticated 200 here would mean the guard is not wired. Without M2M
credentials the seed and token-issuance steps SKIP with that reason; the
rest still runs.

**Phase B — the stub IdP.** Builds the backend from source and boots it
against a bundled Python stub Logto (RS256 + JWKS) over real HTTP. This
tier proves the verification logic and the whole authorization surface over
the wire: a stub-issued `venues:read` token verifies and lists venues; no
token is 401; a wrong-audience token is 401; a write-only token reading
venues is 403; and the full grant lifecycle — create 201, own-venue reads
200 (venue and readings), other-venue 403, management route 401, TTL floor
422, real-time expiry (200 then 403), revoke (200 then 410).

**What neither proves today:** a token issued by a *real* Logto being
accepted by the backend end to end. The stub emits the token shapes we
believe Logto emits; the proof lands as soon as the one-time M2M bootstrap
is done and the seed has run against the real issuer — the spike's
token-issuance step turns from SKIP to PASS.

## NixOS deploy path

The prod shape mirrors compose. `infra/nixos/modules/logto.nix` runs Logto
+ Postgres as podman oci-containers with the core published on loopback
only; `caddy.nix` terminates TLS for `login.clubins.de` (Logto) and
`api.clubins.de` (the Go API); `sops.nix` decrypts the Logto database env
from SOPS at boot. Secrets never appear as inline config, and the repo's
`.sops.yaml` carries a placeholder recipient until a host's age key
replaces it. The one-time host setup — importing the modules plus sops-nix,
provisioning the age key, encrypting `logto-env`, creating the podman
network, pointing DNS — is walked step by step in
[infra/nixos/README.md](../infra/nixos/README.md). In production, Logto's
`ENDPOINT` is `https://login.clubins.de`, so the issuer is
`https://login.clubins.de/oidc` — matching the Flutter app's `CLUBINS_ISSUER`
and the API's `ISSUER_URL`.
