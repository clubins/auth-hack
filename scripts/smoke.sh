#!/usr/bin/env bash
# smoke.sh — end-to-end smoke for the Clubins auth stack, in two phases.
#
#   --phase=a    REAL stack: docker compose up (Logto OSS, Postgres, Go API),
#                seed Logto via its Management API, run spike.sh against the
#                real issuer, assert /healthz and the unauthenticated guard.
#                Token issuance SKIPs without LOGTO_M2M_CLIENT_ID/SECRET (see
#                idp/README.md for the one-time Admin Console bootstrap).
#   --phase=b    Same backend binary against the bundled Python Logto stub
#                (RS256 + JWKS) over real HTTP: token verification, negative
#                paths, renter grants (create, single-venue scope, TTL floor,
#                expiry, revoke). Docker-free by design.
#   --phase=all  both, in order.
#
# Every step prints PASS/FAIL/SKIP with its name; the first failure is
# reported at the end and the script exits 1 naming it.
#
# Phase A proves real-Logto discovery/JWKS/guard wiring. Phase B proves the
# full authenticated flow with a stubbed IdP. A token ISSUED BY REAL LOGTO
# being accepted by the backend is proven once the one-time M2M bootstrap
# exists and the seed has run against a real Logto (idp/README.md).
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

PREFIX='[smoke]'
PHASE='all'
BACKEND_PORT="${BACKEND_PORT:-8090}"
STUB_PORT="${STUB_PORT:-0}"            # 0 = pick a free port
CURL_TIMEOUT="${CURL_TIMEOUT:-3}"
GRANT_MIN_TTL="${GRANT_MIN_TTL:-1s}"   # test floor; prod default is 8h
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-420}"
AUDIENCE=''                            # default set in main
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d /tmp/auth-smoke.XXXXXX)"
API_BODY="$WORK/api-body.json"
ENV_FILE_PATH=''                     # set by step_a_env; cleanup guards on it
PIDS=()
STEP_TOTAL=0
STEP_NUM=0
FIRST_FAILED=''
SKIP_COUNT=0
SMOKE_FAILED=0
STUB_BASE=''
STUB_PID=''
BACKEND_PID=''
STUB_ACCESS_TOKEN=''
READ_TOKEN=''
OWNER_TOKEN=''
WRONG_AUD_TOKEN=''
GRANT_TOKEN=''
GRANT_ID=''
# The v-001 renter grant from step 9, captured because later steps create
# MORE grants (ttl floor, short TTL) and create_grant overwrites the globals.
V001_GRANT_ID=''
V001_GRANT_TOKEN=''
API_BASE=''

usage() {
  cat >&2 <<USAGE
$PREFIX end-to-end smoke for the Clubins auth stack (two phases).

Usage: scripts/smoke.sh --phase=a|b|all

Environment:
  BACKEND_PORT     port for the phase-B backend   (default 8090)
  STUB_PORT        stub IdP port, 0 = free port  (default 0)
  CURL_TIMEOUT     curl --max-time seconds       (default 3)
  GRANT_MIN_TTL    phase-B grant floor           (default 1s)
  HEALTH_TIMEOUT   phase-A compose wait seconds  (default 420)
  AUDIENCE         token audience                (default https://api.clubins.de)
  LOGTO_M2M_CLIENT_ID / LOGTO_M2M_CLIENT_SECRET
                   optional: enable real token issuance in phase A. Create
                   them via the one-time Admin Console bootstrap documented
                   in idp/README.md.
USAGE
}

cleanup() {
  local pid
  for pid in "${PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    kill "$pid" 2>/dev/null || true
  done
  if [ -n "${STUB_PID:-}" ]; then kill "$STUB_PID" 2>/dev/null || true; fi
  if [ -n "${BACKEND_PID:-}" ]; then kill "$BACKEND_PID" 2>/dev/null || true; fi
  if [ -n "$ENV_FILE_PATH" ]; then
    (cd "$REPO_ROOT/infra" && docker compose --env-file "$ENV_FILE_PATH" down --volumes --timeout 10 >/dev/null 2>&1) || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

log() {
  printf '%s %s\n' "$PREFIX" "$*"
}

# ---- step framework (same contract as spike.sh) -----------------------------
#
# run_step NAME FUNCTION — runs one smoke step. A step returns
#   0 = pass, 1 = fail (REASON says why), 2 = skip (REASON says why).
# Assertions inside steps set REASON before returning nonzero.

run_step() {
  local name="$1" fn="$2" rc=0
  STEP_NUM=$((STEP_NUM + 1))
  REASON=''
  "$fn" || rc=$?
  case "$rc" in
    0)
      printf '%s step %s/%s: %s — PASS\n' "$PREFIX" "$STEP_NUM" "$STEP_TOTAL" "$name"
      ;;
    2)
      SKIP_COUNT=$((SKIP_COUNT + 1))
      printf '%s step %s/%s: %s — SKIP (%s)\n' "$PREFIX" "$STEP_NUM" "$STEP_TOTAL" "$name" "${REASON:-unspecified}"
      ;;
    *)
      printf '%s step %s/%s: %s — FAIL (%s)\n' "$PREFIX" "$STEP_NUM" "$STEP_TOTAL" "$name" "${REASON:-unspecified}"
      if [ -z "$FIRST_FAILED" ]; then
        FIRST_FAILED="$name"
      fi
      ;;
  esac
}

# have_vars NAME... — true when every variable is set and non-empty.
have_vars() {
  local name
  for name in "$@"; do
    [ -n "${!name:-}" ] || return 1
  done
}

# m2m_usable — true when both M2M credentials look like real values. A copied
# .env.example can carry replace-me-* placeholders; those must not count as
# credentials, or the smoke tries them on the real issuer and fails with a
# confusing invalid_client instead of the documented SKIP.
m2m_usable() {
  have_vars LOGTO_M2M_CLIENT_ID LOGTO_M2M_CLIENT_SECRET || return 1
  local var
  for var in "$LOGTO_M2M_CLIENT_ID" "$LOGTO_M2M_CLIENT_SECRET"; do
    case "$var" in replace-me-*) return 1 ;; esac
  done
}

# env_value FILE KEY — the value of KEY in a .env file, or empty.
env_value() {
  sed -n "s/^${2}=//p" "$1" 2>/dev/null | head -1 | tr -d '"' || true
}

require_tools() {
  local t
  for t in "$@"; do
    command -v "$t" >/dev/null 2>&1 \
      || die "required tool not found: $t"
  done
}

free_port() {
  python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}

wait_http_ok() {
  # wait_http_ok URL ATTEMPTS — poll until URL answers 200.
  local url="$1" attempts="$2" attempt=0
  until [ "$(curl -sS --max-time "$CURL_TIMEOUT" -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || true)" = "200" ]; do
    attempt=$((attempt + 1))
    [ "$attempt" -lt "$attempts" ] || return 1
    sleep 0.5
  done
}

# api METHOD PATH [TOKEN] [BODY] — request against $API_BASE; PATH is a path
# like /venues, never a full URL (a URL here would double the base and fail
# with a confusing curl port error). Sets API_STATUS and writes the body to
# $WORK/api-body.json.
api() {
  local method="$1" path="$2" token="${3:-}" body="${4:-}"
  case "$path" in
    http*) REASON="api() takes a path, not a URL (got: ${path:0:40})"; return 1 ;;
  esac
  # Clear previous-call evidence first: a failed request must never leave a
  # stale status/body for the caller's assertions to misread.
  API_STATUS=''
  : > "$API_BODY"
  local args=(-sS --max-time "$CURL_TIMEOUT" -o "$API_BODY" -w '%{http_code}' -X "$method" "$API_BASE$path")
  [ -z "$token" ] || args+=(-H "Authorization: Bearer $token")
  [ -z "$body" ] || args+=(-H 'Content-Type: application/json' -d "$body")
  API_STATUS="$(curl "${args[@]}")" \
    || { REASON="request to $path failed (network/timeout): $(tail -c 120 "$API_BODY" 2>/dev/null | tr '\n' ' ')"; return 1; }
}

# stub_token SCOPE [RESOURCE] — mint an access token via the phase-B stub's
# client_credentials endpoint; sets STUB_ACCESS_TOKEN.
stub_token() {
  local scope="$1" resource="${2:-$AUDIENCE}" status
  status="$(curl -sS --max-time "$CURL_TIMEOUT" -u "$STUB_M2M_ID:$STUB_M2M_SECRET" \
    -d grant_type=client_credentials \
    --data-urlencode "resource=$resource" \
    --data-urlencode "scope=$scope" \
    "$STUB_BASE/oidc/token" -o "$WORK/stub-token.json" -w '%{http_code}')" \
    || { REASON="stub token request failed"; return 1; }
  [ "$status" = "200" ] \
    || { REASON="stub token endpoint returned HTTP $status: $(body_head "$WORK/stub-token.json")"; return 1; }
  STUB_ACCESS_TOKEN="$(jq -er '.access_token // empty' "$WORK/stub-token.json")" \
    || { REASON="stub token response carried no access_token: $(body_head "$WORK/stub-token.json")"; return 1; }
}

# create_grant OWNER_TOKEN VENUE_ID TTL — POST a renter grant; sets
# GRANT_ID and GRANT_TOKEN (token returned only at creation).
create_grant() {
  local owner="$1" venue="$2" ttl="$3"
  api POST "/venues/$venue/grants" "$owner" "{\"ttl\":\"$ttl\"}" || return 1
  [ "$API_STATUS" = "201" ] \
    || { REASON="POST /venues/$venue/grants (ttl $ttl) returned HTTP ${API_STATUS:-none}, expected 201: $(body_head "$API_BODY")"; return 1; }
  GRANT_ID="$(jq -er '.id // empty' "$API_BODY")" \
    || { REASON="grant response carried no id: $(body_head "$API_BODY")"; return 1; }
  GRANT_TOKEN="$(jq -er '.token // empty' "$API_BODY")" \
    || { REASON="grant response carried no token (tokens are returned only at creation): $(body_head "$API_BODY")"; return 1; }
}

body_head() {
  head -c 200 "$1" 2>/dev/null | tr '\n\r\t' '   ' || true
}

# ---- phase A steps: the REAL compose stack ----------------------------------

step_a_docker() {
  command -v docker >/dev/null 2>&1 \
    || { REASON="docker not found — phase A needs Docker (compose) to boot the real stack"; return 1; }
  docker compose version >/dev/null 2>&1 \
    || { REASON="docker compose plugin not available"; return 1; }
}

step_a_env() {
  local pw
  if [ ! -f "$REPO_ROOT/infra/.env" ]; then
    cp "$REPO_ROOT/infra/.env.example" "$REPO_ROOT/infra/.env"
  fi
  pw="$(env_value "$REPO_ROOT/infra/.env" LOGTO_DB_PASSWORD)"
  if [ -z "$pw" ]; then
    printf 'LOGTO_DB_PASSWORD=%s\n' "$(openssl rand -hex 16 2>/dev/null || echo "smoke-$(date +%s)")" >> "$REPO_ROOT/infra/.env"
    pw="$(env_value "$REPO_ROOT/infra/.env" LOGTO_DB_PASSWORD)"
  fi
  [ -n "$pw" ] || { REASON="could not establish LOGTO_DB_PASSWORD in infra/.env"; return 1; }
  ENV_FILE_PATH="$REPO_ROOT/infra/.env"
  export LOGTO_DB_PASSWORD="$pw"
  # Mirror spike.sh: M2M credentials may live in infra/.env rather than the
  # environment. Export real values from the file so m2m_usable sees them;
  # empty values stay unset (no credentials = documented SKIPs).
  local key value
  for key in LOGTO_M2M_CLIENT_ID LOGTO_M2M_CLIENT_SECRET; do
    if [ -z "${!key:-}" ]; then
      value="$(env_value "$ENV_FILE_PATH" "$key")"
      [ -n "$value" ] || continue
      export "$key=$value"
    fi
  done
  # Phase A curls the compose-PUBLISHED API port (host side), which defaults
  # to 8080 via infra/.env — distinct from BACKEND_PORT, the phase-B
  # standalone backend's port.
  local api_port
  api_port="$(env_value "$ENV_FILE_PATH" API_PORT)"
  API_BASE="http://localhost:${api_port:-8080}"
}

step_a_compose_up() {
  local attempt=0 statuses
  (cd "$REPO_ROOT/infra" && docker compose --env-file "$ENV_FILE_PATH" up -d --wait --wait-timeout "$HEALTH_TIMEOUT") >"$WORK/compose-up.log" 2>&1 \
    || { REASON="docker compose up --wait did not reach healthy within ${HEALTH_TIMEOUT}s: $(tail -c 300 "$WORK/compose-up.log" | tr '\n' ' ')"; return 1; }
  statuses="$( { cd "$REPO_ROOT/infra" && docker compose --env-file "$ENV_FILE_PATH" ps --format '{{.Service}} {{.Health}}'; } 2>/dev/null || true )"
  attempt="$(printf '%s\n' "$statuses" | grep -cv 'healthy$' || true)"
  [ "${attempt:-0}" = "0" ] \
    || { REASON="$(printf '%s\n' "$statuses" | grep -v 'healthy$' | tr '\n' ' ') are not healthy"; return 1; }
}

step_a_seed() {
  if ! m2m_usable; then
    REASON="no M2M credentials (LOGTO_M2M_CLIENT_ID, LOGTO_M2M_CLIENT_SECRET) — the one-time Admin Console bootstrap in idp/README.md provides them; without them nothing can be seeded, and token issuance below skips too"
    return 2
  fi
  bash "$REPO_ROOT/idp/seed.sh" >"$WORK/seed.log" 2>&1 \
    || { REASON="idp/seed.sh failed: $(tail -c 300 "$WORK/seed.log" | tr '\n' ' ')"; return 1; }
}

step_a_spike() {
  local args=()
  # Credentials may come from the environment or infra/.env (spike loads it).
  if ! m2m_usable; then
    args+=(--token-optional)
  fi
  bash "$REPO_ROOT/scripts/spike.sh" "${args[@]}" >"$WORK/spike.log" 2>&1 \
    || { REASON="$(grep -m1 'FAIL (' "$WORK/spike.log" || echo "spike.sh exited nonzero")"; cat "$WORK/spike.log" >&2; return 1; }
  grep -q 'SKIP (' "$WORK/spike.log" \
    && log "spike note: $(grep -m1 'SKIP (' "$WORK/spike.log" | sed 's/^.*steps\/[0-9]*: //' || true)"
  return 0
}

step_a_healthz() {
  api GET "/healthz"
  [ "$API_STATUS" = "200" ] \
    || { REASON="GET /healthz returned HTTP ${API_STATUS:-none}, expected 200: $(body_head "$API_BODY")"; return 1; }
}

step_a_venues_401() {
  api GET "/venues"
  [ "$API_STATUS" = "401" ] \
    || { REASON="GET /venues unauthenticated returned HTTP ${API_STATUS:-none}, expected 401 — the OIDC guard is not wired: $(body_head "$API_BODY")"; return 1; }
}

phase_a() {
  STEP_TOTAL=7
  STEP_NUM=0
  FIRST_FAILED=''
  SKIP_COUNT=0
  log "phase A: REAL compose stack (docker compose up, seed, spike, guard wiring)"
  run_step "docker + compose available" step_a_docker
  run_step "compose environment ready" step_a_env
  run_step "compose stack reaches healthy" step_a_compose_up
  run_step "Logto seed (idp/seed.sh)" step_a_seed
  run_step "spike: discovery issuer match, JWKS keys, token issuance" step_a_spike
  run_step "GET /healthz is 200" step_a_healthz
  run_step "GET /venues unauthenticated is 401" step_a_venues_401
  finish_phase "A"
}

# ---- phase B steps ----------------------------------------------------------

# start_stub — boot the bundled Logto stub (dev-only literal credentials, as
# in spike.sh) and set STUB_BASE.
start_stub() {
  local stub_log="$WORK/stub-b.log" attempt=0
  python3 "$SCRIPT_DIR/test/stub_logto.py" --port "$STUB_PORT" \
    --m2m-id "$STUB_M2M_ID" --m2m-secret "$STUB_M2M_SECRET" \
    --test-email smoke-stub@example.com --test-password smoke-stub-password-dev-only \
    >"$stub_log" 2>&1 &
  STUB_PID=$!
  until grep -qs '^listening ' "$stub_log"; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 50 ]; then
      REASON="stub did not start within 5s: $(tail -c 200 "$stub_log" | tr '\n' ' ')"
      return 1
    fi
    if ! kill -0 "$STUB_PID" 2>/dev/null; then
      REASON="stub died on startup: $(tail -c 200 "$stub_log" | tr '\n' ' ')"
      return 1
    fi
    sleep 0.1
  done
  STUB_BASE="$(sed -n 's/^listening //p' "$stub_log")"
  STUB_BASE="${STUB_BASE%/}"
}

start_backend() {
  local backend_log="$WORK/backend-b.log" attempt=0
  PORT="$BACKEND_PORT" \
    ISSUER_URL="$STUB_BASE/oidc" \
    AUDIENCE="$AUDIENCE" \
    GRANT_MIN_TTL="$GRANT_MIN_TTL" \
    LOG_LEVEL=info \
    "$WORK/smoke-api" >"$backend_log" 2>&1 &
  BACKEND_PID=$!
  until [ "$(curl -sS --max-time "$CURL_TIMEOUT" -o /dev/null -w '%{http_code}' "http://localhost:${BACKEND_PORT}/healthz" 2>/dev/null || true)" = "200" ]; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 30 ]; then
      REASON="backend did not become healthy within 15s: $(tail -c 300 "$backend_log" | tr '\n' ' ')"
      return 1
    fi
    if ! kill -0 "$BACKEND_PID" 2>/dev/null; then
      # A dead process is the loud failure mode the spec wants: discovery or
      # JWKS mis-wiring fails the boot, and the log names it.
      REASON="backend exited during boot (discovery/JWKS wiring?): $(tail -c 300 "$backend_log" | tr '\n' ' ')"
      return 1
    fi
    sleep 0.5
  done
}

step_b_python() {
  command -v python3 >/dev/null 2>&1 \
    || { REASON="python3 not found — phase B needs it for the stub IdP"; return 1; }
}

step_b_build() {
  command -v go >/dev/null 2>&1 \
    || { REASON="go toolchain not found on PATH — phase B builds the backend from ./backend"; return 1; }
  (cd "$REPO_ROOT/backend" && go build -o "$WORK/smoke-api" ./cmd/api) >"$WORK/build.log" 2>&1 \
    || { REASON="go build ./cmd/api failed: $(tail -c 300 "$WORK/build.log" | tr '\n' ' ')"; return 1; }
}

step_b_stub_up() {
  start_stub || return 1
}

step_b_backend_up() {
  start_backend || return 1
}

step_b_venues_200() {
  stub_token "$AUDIENCE/venues:read" || return 1
  READ_TOKEN="$STUB_ACCESS_TOKEN"
  api GET "/venues" "$READ_TOKEN"
  [ "$API_STATUS" = "200" ] \
    || { REASON="GET /venues with a venues:read token returned HTTP ${API_STATUS:-none}, expected 200 — the stub-issued RS256 token was not accepted: $(body_head "$API_BODY")"; return 1; }
  grep -q '"v-001"' "$API_BODY" \
    || { REASON="GET /venues response does not contain the seeded venue v-001: $(body_head "$API_BODY")"; return 1; }
}

step_b_unauth_401() {
  api GET "/venues"
  [ "$API_STATUS" = "401" ] \
    || { REASON="GET /venues unauthenticated returned HTTP ${API_STATUS:-none}, expected 401: $(body_head "$API_BODY")"; return 1; }
}

step_b_wrong_aud_401() {
  stub_token "$AUDIENCE/venues:read" "https://other.example.invalid" || return 1
  WRONG_AUD_TOKEN="$STUB_ACCESS_TOKEN"
  api GET "/venues" "$WRONG_AUD_TOKEN"
  [ "$API_STATUS" = "401" ] \
    || { REASON="GET /venues with a wrong-audience token returned HTTP ${API_STATUS:-none}, expected 401: $(body_head "$API_BODY")"; return 1; }
}

step_b_write_only_403() {
  stub_token "$AUDIENCE/venues:write" || return 1
  OWNER_TOKEN="$STUB_ACCESS_TOKEN"
  api GET "/venues" "$OWNER_TOKEN"
  [ "$API_STATUS" = "403" ] \
    || { REASON="GET /venues with a venues:write-only token returned HTTP ${API_STATUS:-none}, expected 403: $(body_head "$API_BODY")"; return 1; }
}

step_b_create_grant() {
  create_grant "$OWNER_TOKEN" "v-001" "8h" || return 1
  # Capture before any later step creates another grant.
  V001_GRANT_ID="$GRANT_ID"
  V001_GRANT_TOKEN="$GRANT_TOKEN"
}

step_b_grant_reads_own_venue() {
  api GET "/venues/v-001" "$V001_GRANT_TOKEN"
  [ "$API_STATUS" = "200" ] \
    || { REASON="grant token GET /venues/v-001 returned HTTP ${API_STATUS:-none}, expected 200: $(body_head "$API_BODY")"; return 1; }
  jq -e '.id == "v-001"' "$API_BODY" >/dev/null \
    || { REASON="grant token response is not venue v-001: $(body_head "$API_BODY")"; return 1; }
}

step_b_grant_reads_readings() {
  api GET "/venues/v-001/readings" "$V001_GRANT_TOKEN"
  [ "$API_STATUS" = "200" ] \
    || { REASON="grant token GET /venues/v-001/readings returned HTTP ${API_STATUS:-none}, expected 200: $(body_head "$API_BODY")"; return 1; }
  jq -e 'length > 0 and .[0].temperatureC != null' "$API_BODY" >/dev/null \
    || { REASON="readings response is empty or carries no temperatureC: $(body_head "$API_BODY")"; return 1; }
}

step_b_grant_denied_other_venue() {
  api GET "/venues/v-002" "$V001_GRANT_TOKEN"
  [ "$API_STATUS" = "403" ] \
    || { REASON="grant token GET /venues/v-002 returned HTTP ${API_STATUS:-none}, expected 403 (single-venue scope): $(body_head "$API_BODY")"; return 1; }
}

step_b_grant_denied_management() {
  api GET "/venues/v-001/grants" "$V001_GRANT_TOKEN"
  [ "$API_STATUS" = "401" ] \
    || { REASON="grant token GET /venues/v-001/grants returned HTTP ${API_STATUS:-none}, expected 401 (management routes are OIDC-only): $(body_head "$API_BODY")"; return 1; }
}

step_b_ttl_floor_422() {
  stub_token "$AUDIENCE/venues:write" || return 1
  api POST "/venues/v-002/grants" "$STUB_ACCESS_TOKEN" '{"ttl":"500ms"}' || return 1
  [ "$API_STATUS" = "422" ] \
    || { REASON="grant with ttl 500ms below GRANT_MIN_TTL ($GRANT_MIN_TTL) returned HTTP ${API_STATUS:-none}, expected 422: $(body_head "$API_BODY")"; return 1; }
}

step_b_expiry() {
  stub_token "$AUDIENCE/venues:write" || return 1
  local owner="$STUB_ACCESS_TOKEN"
  create_grant "$owner" "v-002" "2s" || return 1
  local short_token="$GRANT_TOKEN" status="" poll=0
  status="$(curl -sS --max-time "$CURL_TIMEOUT" -o "$API_BODY" -w '%{http_code}' -H "Authorization: Bearer $short_token" "$API_BASE/venues/v-002")" \
    || { REASON="GET /venues/v-002 with the fresh short-TTL grant failed"; return 1; }
  [ "$status" = "200" ] \
    || { REASON="short-TTL grant did not work when fresh (got HTTP $status, expected 200): $(body_head "$API_BODY")"; return 1; }
  while [ "$status" != "403" ]; do
    poll=$((poll + 1))
    if [ "$poll" -ge 20 ]; then
      REASON="short-TTL grant (2s) still not expired after 20s — last status $status"
      return 1
    fi
    sleep 1
    status="$(curl -sS --max-time "$CURL_TIMEOUT" -o "$API_BODY" -w '%{http_code}' -H "Authorization: Bearer $short_token" "$API_BASE/venues/v-002")" \
      || { REASON="GET /venues/v-002 failed while polling for expiry"; return 1; }
  done
  grep -q 'expired' "$API_BODY" \
    || log "note: expiry returned 403 with body: $(body_head "$API_BODY")"
}

step_b_revoke() {
  stub_token "$AUDIENCE/venues:write" || return 1
  local owner="$STUB_ACCESS_TOKEN" status
  status="$(curl -sS --max-time "$CURL_TIMEOUT" -o "$API_BODY" -w '%{http_code}' -X DELETE -H "Authorization: Bearer $owner" "$API_BASE/grants/$V001_GRANT_ID")" \
    || { REASON="DELETE /grants/$V001_GRANT_ID failed"; return 1; }
  [ "$status" = "200" ] \
    || { REASON="DELETE /grants/$V001_GRANT_ID returned HTTP $status, expected 200: $(body_head "$API_BODY")"; return 1; }
  jq -e '.revokedAt != null' "$API_BODY" >/dev/null \
    || { REASON="revoke response carries no revokedAt: $(body_head "$API_BODY")"; return 1; }
  api GET "/venues/v-001" "$V001_GRANT_TOKEN"
  [ "$API_STATUS" = "410" ] \
    || { REASON="revoked grant token GET /venues/v-001 returned HTTP ${API_STATUS:-none}, expected 410: $(body_head "$API_BODY")"; return 1; }
}

phase_b() {
  STEP_TOTAL=16
  STEP_NUM=0
  FIRST_FAILED=''
  SKIP_COUNT=0
  API_BASE="http://localhost:${BACKEND_PORT}"
  log "phase B: authenticated flow over real HTTP — backend binary + stub IdP (issuer <stub>/oidc bound in step 3, GRANT_MIN_TTL=$GRANT_MIN_TTL)"
  run_step "python3 available (stub IdP runtime)" step_b_python
  run_step "backend builds (go build ./cmd/api)" step_b_build
  run_step "stub IdP up (free port, RS256 JWKS)" step_b_stub_up
  run_step "backend boots against stub discovery + JWKS" step_b_backend_up
  run_step "venues:read token verifies and lists venues (200)" step_b_venues_200
  run_step "GET /venues unauthenticated is 401" step_b_unauth_401
  run_step "wrong-audience token is 401" step_b_wrong_aud_401
  run_step "write-only token cannot read venues (403)" step_b_write_only_403
  run_step "owner creates a renter grant on v-001 (201)" step_b_create_grant
  run_step "grant token reads v-001 (200)" step_b_grant_reads_own_venue
  run_step "grant token reads v-001 readings (200)" step_b_grant_reads_readings
  run_step "grant token denied on v-002 (403)" step_b_grant_denied_other_venue
  run_step "grant token denied on management route (401)" step_b_grant_denied_management
  run_step "ttl below GRANT_MIN_TTL is 422" step_b_ttl_floor_422
  run_step "short-TTL grant expires (200 then 403)" step_b_expiry
  run_step "revoke works (200 then 410)" step_b_revoke
  finish_phase "B"
}

finish_phase() {
  local label="$1"
  if [ -n "$FIRST_FAILED" ]; then
    printf '%s phase %s FAILED: first failed step: %s\n' "$PREFIX" "$label" "$FIRST_FAILED" >&2
    SMOKE_FAILED=1
  elif [ "$SKIP_COUNT" -gt 0 ]; then
    printf '%s phase %s: all %s steps settled (%s passed, %s skipped — see SKIP reasons above)\n' \
      "$PREFIX" "$label" "$STEP_TOTAL" "$((STEP_TOTAL - SKIP_COUNT))" "$SKIP_COUNT"
  else
    printf '%s phase %s: all %s steps passed\n' "$PREFIX" "$label" "$STEP_TOTAL"
  fi
}

# ---- main -------------------------------------------------------------------

main() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --phase=a|--phase=A) PHASE=a ;;
      --phase=b|--phase=B) PHASE=b ;;
      --phase=all) PHASE=all ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown argument: $arg (see --help)" ;;
    esac
  done

  : "${AUDIENCE:=https://api.clubins.de}"
  # Dev-only literals for the stub's client_credentials, as in spike.sh's
  # stub mode — the stub is a local test double, these are not secrets.
  STUB_M2M_ID=smoke-stub-m2m
  STUB_M2M_SECRET=smoke-stub-secret-dev-only

  require_tools curl jq

  case "$PHASE" in
    a) phase_a ;;
    b) phase_b ;;
    all)
      phase_a
      phase_b
      ;;
  esac

  if [ "$SMOKE_FAILED" != 0 ]; then
    exit 1
  fi
}

main "$@"
