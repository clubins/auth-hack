# scripts/

Protocol tooling for the Logto/OIDC spike and everyday token debugging. All
configuration comes from the environment or `infra/.env` — no secrets in this
directory (CI enforces with gitleaks).

| Tool               | Purpose                                                          |
| ------------------ | ---------------------------------------------------------------- |
| `spike.sh`         | Verify the running Logto stack step by step (discovery → JWKS → token → claims) |
| `token-inspect.sh` | Decode a JWT's header/payload and flag its expiry — **decode only** |
| `lib.sh`           | Shared helpers (prefixed errors, base64url decode, PKCE helpers) |
| `test/`            | Docker-free harness + a stub Logto for end-to-end script testing  |

## token-inspect.sh

```bash
scripts/token-inspect.sh 'eyJhbGciOi...'   # token as an argument
curl -s .../oidc/token | jq -r .access_token | scripts/token-inspect.sh  # stdin
```

Prints the JOSE header and the payload pretty (via `jq`), states whether the
token is currently `VALID` or `EXPIRED` (against the local clock), and flags
`alg=none` tokens. It is a decoder, not a validator — the output always says
`signature NOT verified`. Only the Go API (`backend/internal/auth`) verifies
signatures; never make an authentication decision from this tool's output.

Exit status: `0` when the token decodes (expired or not), `1` when the input
is not a well-formed three-part base64url JWT.

## spike.sh

```bash
scripts/spike.sh                 # verify the compose stack at $LOGTO_ENDPOINT
scripts/spike.sh --user-flow     # EXPERIMENTAL: authorization code + PKCE with the seeded test user
scripts/spike.sh --stub          # self-test against a bundled stub Logto (no Docker)
```

Default configuration (`infra/.env` / environment):

| Variable              | Default                      |
| --------------------- | ---------------------------- |
| `LOGTO_ENDPOINT`      | `http://localhost:3301`      |
| `LOGTO_M2M_CLIENT_ID` / `LOGTO_M2M_CLIENT_SECRET` | from the M2M bootstrap (infra/README.md) |
| `LOGTO_NATIVE_CLIENT_ID` | seeded native client (idp/seed.sh) |
| `TEST_USER_EMAIL` / `TEST_USER_PASSWORD` | seeded test user |

Each step prints its name and `PASS`/`FAIL` (with the reason on failure); the
run exits `0` only when every step passes, otherwise `1` naming the **first
failed step**. Nothing here bypasses the API's own validation — a passing
spike says the issuer side of the contract works.

Steps, in order:

1. **discovery document** — `GET $LOGTO_ENDPOINT/oidc/.well-known/openid-configuration`
   returns 200 and its `issuer` equals `$LOGTO_ENDPOINT/oidc`.
2. **JWKS keys present** — the discovery `jwks_uri` serves at least one key.
3. **access token issuance** — see token paths below.
4. **claims decode and dump** — the token's header and payload, decoded and
   pretty-printed with `token-inspect.sh`.

### Token paths, honestly

**Default: M2M client_credentials.** Uses the seeded M2M app against the core
token endpoint with a resource indicator. Be aware of what this proves: the
seeded M2M app holds the Management API role, so the token it obtains scopes
to the **management indicator** (`https://default.logto.app/api`), *not*
`venues:read` — the Go API would reject it (audience mismatch). Step 3 proves
token issuance works, not API authorization. The output says this in so many
words; `--user-flow` is the path that produces the venues-scoped token.

**`--user-flow` (experimental):** drives Logto's authorization-code + PKCE
flow headlessly — `GET /oidc/auth`, password sign-in through Logto's
Experience API (`PUT /api/experience`, identification, password verification,
submit), code exchange, and dumps the resulting token's claims. The token is
the venues-scoped one a real customer session would carry
(`aud=https://api.clubins.de`, `scope=venues:read`). The Experience API
routes were checked against Logto v1.45.0's source, but live session/consent
behavior could not be verified without Docker — treat the flag as
experimental and prefer the Flutter app for a real end-to-end sign-in.

**`--stub`:** runs every step against `test/stub_logto.py` (a small Python
stub serving discovery, JWKS, client-credentials tokens, and a simplified
Experience API). This proves the *script logic* only — nothing about a live
Logto. The real compose-stack run belongs to the end-to-end smoke task.

### What is verified where

| Check                                   | Where it can run        |
| --------------------------------------- | ----------------------- |
| Script logic (all four steps, success and failure paths) | here, Docker-free (`scripts/test/run-tests.sh`, CI) |
| Real compose stack end to end           | e2e smoke task (needs Docker) |
| Signature verification                  | Go API only (`backend/internal/auth`) |

## Testing

```bash
scripts/test/run-tests.sh   # 26 assertions, no Docker: both tools, stub + failure paths
```

The harness covers: token-inspect on padded, unpadded, expired, and
`alg=none` tokens plus malformed input and stdin; spike `--stub` (M2M and
`--user-flow` paths) and the dead-endpoint contract (exit 1, first failed
step named). CI runs it on every PR touching `scripts/`
(`.github/workflows/scripts.yml`).
