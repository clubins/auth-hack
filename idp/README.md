# idp/ — Logto config-as-data

Everything the Clubins Logto OSS instance needs, applied through the
Management API with an M2M token. No console click-paths to reproduce by
hand, no state that lives only in someone's browser: the configuration is
the code in this directory, and the seed is idempotent — run it as many
times as you like; a second run creates nothing and exits 0.

## Contents

| Script | Purpose |
| --- | --- |
| `lib.sh` | Shared helpers, sourced by `seed.sh`: conservative `.env` loading (seed keys only, no eval), required-variable checks, M2M token acquisition, paginated Management API listing, colored logging. Not run directly. |
| `seed.sh` | The seed entrypoint. Creates (if absent): the `https://api.clubins.de` API resource with scopes `venues:read`/`venues:write`, the native Flutter application with its PKCE redirect URIs, and one test user. Prints a summary with the generated client ID at the end. |
| `test/mock_logto.py` | In-process mock of the exact Management API surface the seed uses (Logto response shapes, 422-on-duplicate semantics, `/oidc/token` with Basic auth). Used by the idempotency harness; needs no Docker. |
| `test/run-mock-tests.sh` | Idempotency harness: runs `seed.sh` twice against the mock (second run must create nothing and exit 0), asserts the exact creation count, and checks that bad M2M credentials fail loudly. |

## One-time bootstrap (per fresh Logto instance)

The Management API is itself protected by an M2M application, and the first
one cannot be created through the API it unlocks. We do that first step once
in the Admin Console rather than writing into Logto's PostgreSQL schema —
schema-coupled bootstrapping breaks silently across Logto releases.

1. `cd infra && docker compose up -d` and wait for Logto to be up
   (`curl localhost:3301/oidc/.well-known/openid-configuration`).
2. Open the Admin Console at `http://localhost:3302` (production:
   `https://admin.login.clubins.de`) and finish the first-boot admin setup
   if the instance is brand new.
3. **Applications → Create application → Machine-to-machine**. Name it
   `Logto seed M2M` (any name works).
4. On the application's page, open the **Roles** tab and assign the built-in
   role **`Logto Management API access`**. Without this role the token
   endpoint answers, but every `/api/*` call is denied.
5. Copy the **Endpoint** (the resource indicator, `https://default.logto.app/api`
   in OSS), the **App ID**, and the **App secret** into `infra/.env` as
   `LOGTO_M2M_CLIENT_ID` and `LOGTO_M2M_CLIENT_SECRET` (see
   `infra/.env.example`).

From here on, `idp/seed.sh` runs fully unattended.

## Running the seed

```bash
cd infra && cp .env.example .env && $EDITOR .env   # fill the M2M + test-user values
docker compose up -d logto postgres                 # or the whole stack
../idp/seed.sh                                      # from anywhere; paths are resolved
```

Expect a `created` line per object on the first run and an `exists` line per
object on every later run, then a summary that prints the generated
**client ID** — pass it to the Flutter app at build time:

```bash
flutter run --dart-define=CLUBINS_CLIENT_ID=<printed id>
```

## What the seed creates

| Object | Identifier | Notes |
| --- | --- | --- |
| API resource | indicator `https://api.clubins.de` (config: `API_RESOURCE_INDICATOR`, defaults to `AUDIENCE`) | Scopes: `venues:read` (read venue data), `venues:write` (manage venue data). Matches the Go API's audience check. |
| Application | name `Clubins Flutter`, type `Native` | PKCE, custom-scheme redirects: `clubins://login-callback` and `clubins://logout-callback` — exactly what `frontend/lib/auth/auth_config.dart` expects. Logto auto-generates the client ID; it cannot be pinned to the literal `clubins-flutter` via the Management API, so the seed matches by name and prints the generated ID. |
| Test user | id `seed-test-user`, email/password from `TEST_USER_EMAIL`/`TEST_USER_PASSWORD` | For local sign-in testing. The password is never hardcoded; it comes from the environment on every run. |

Create-if-absent everywhere: the seed lists before it creates and treats a
duplicate as success (it re-checks and continues). Parallel seed runs are
tolerated; existing objects are never mutated (drift is reported as a
warning, not "fixed" — silent edits to live tenants are not what a seed
should do).

## Environment variables

Read from the environment, with `infra/.env` (or `ENV_FILE`) as fallback.
See `infra/.env.example` for the copy-paste version.

| Variable | Required | Default | Meaning |
| --- | --- | --- | --- |
| `LOGTO_ENDPOINT` | no | `http://localhost:3301` | Public base URL of the Logto core app. |
| `LOGTO_MANAGEMENT_ENDPOINT` | no | `LOGTO_ENDPOINT` | Base URL of the Management API (all seed paths already start with `/api`). |
| `LOGTO_M2M_CLIENT_ID` / `LOGTO_M2M_CLIENT_SECRET` | **yes** | — | The bootstrapped M2M application (above). |
| `LOGTO_MANAGEMENT_API_INDICATOR` | no | `https://default.logto.app/api` | Resource indicator for the M2M token request. |
| `TEST_USER_EMAIL` / `TEST_USER_PASSWORD` | **yes** | — | Credentials for the seeded test user. |
| `API_RESOURCE_INDICATOR` | no | `AUDIENCE` (`https://api.clubins.de`) | Indicator of the Clubins API resource. |
| `API_RESOURCE_NAME` | no | `Clubins API` | Display name of the API resource. |
| `LOGTO_APP_NAME` | no | `Clubins Flutter` | Application name the seed matches on. |
| `LOGTO_APP_TYPE` | no | `Native` | Logto application type (Native = PKCE, custom schemes). |
| `LOGTO_APP_REDIRECT_URI` / `LOGTO_APP_POST_LOGOUT_REDIRECT_URI` | no | `clubins://login-callback` / `clubins://logout-callback` | Flutter redirect URIs (see `frontend/lib/auth/auth_config.dart`). |
| `TEST_USER_ID` / `TEST_USER_NAME` | no | `seed-test-user` / `Clubins Test User` | Stable id (idempotency anchor) and display name of the test user. |
| `ENV_FILE` | no | `../infra/.env` relative to the seed | Where the seed loads config from. |

## Verification status

Verified without Docker (this repo's sandboxes have no container runtime —
the compose bring-up itself is covered by the e2e smoke task):

- `idp/test/run-mock-tests.sh`: seed run #1 against the mock creates exactly
  1 API resource + 2 scopes + 1 application + 1 user and exits 0; run #2
  creates nothing and exits 0 (mock state is byte-identical); wrong M2M
  credentials exit nonzero with a clear error. All 8 assertions pass.
- `shellcheck` (v0.10.0, pinned in CI): clean on `lib.sh`, `seed.sh`,
  `run-mock-tests.sh`.
- `bash -n`: clean on every shell script; `py_compile` clean on the mock.

Not yet verified here: a real end-to-end run against
`svhd/logto:1.45.0` (token endpoint response-shape drift, role-assignment
semantics, redirect-URI validation quirks). The API surface the seed uses —
endpoints, auth scheme, pagination, status codes — was checked against the
Logto v1.45.0 source and OpenAPI spec at authoring time, and the mock
encodes those exact shapes, but the compose smoke task is what retires the
runtime risk.
