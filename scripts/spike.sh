#!/usr/bin/env bash
# Step-by-step verification of the Clubins auth stack, for use against the
# RUNNING compose stack (infra/docker-compose.yml):
#
#   scripts/spike.sh                default: M2M path (client_credentials)
#   scripts/spike.sh --user-flow    full customer-auth path: authorization
#                                   code + PKCE, password sign-in through
#                                   Logto's Experience API — EXPERIMENTAL
#   scripts/spike.sh --stub         run the same steps against the bundled
#                                   Logto stub (scripts/test/stub_logto.py)
#                                   instead of a real stack; no Docker needed
#
# Each step prints its name and PASS/FAIL. Exit 0 only when every step
# passes; otherwise exit 1, naming the first failed step.
#
# Honesty notes:
#   - The sandbox/CI has no Docker. A --stub pass proves the script logic,
#     not a live Logto; the compose e2e smoke owns the real run.
#   - The seeded M2M app holds the Management API role, so its token is
#     scoped to the Management API resource indicator — NOT venues:read.
#     Step 3 in the default path proves token issuance, not API
#     authorization; the Go API would reject that token (audience mismatch).
#     The --user-flow path is the one that yields a venues-scoped token.
#
# Config: environment, falling back to infra/.env (ENV_FILE overrides the
# path). Nothing is ever read from or written to git; secrets stay in .env.
# See scripts/README.md for the full variable table.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PREFIX='[spike]'
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

CURL_TIMEOUT=10
WORK="$(mktemp -d)"
DISCOVERY_FILE="$WORK/discovery.json"
STUB_PID=''

STUB=false
USER_FLOW=false

usage() {
  cat >&2 <<USAGE
$PREFIX verify the Clubins auth stack step by step.

Usage:
  scripts/spike.sh [--user-flow] [--stub]

Steps:
  1. discovery document      GET <endpoint>/oidc/.well-known/openid-configuration
                             must return 200 with issuer == <endpoint>/oidc
  2. JWKS keys present       the jwks_uri from discovery must return keys
  3. access token issuance   headless token: M2M client_credentials by
                             default; with --user-flow, authorization code +
                             PKCE + password sign-in via the Experience API
  4. claims decode and dump  JOSE header + payload, decoded and printed

Options:
  --user-flow  drive the customer-auth flow with the seeded test user
               (experimental: verified against the stub, not a live Logto)
  --stub       point the run at scripts/test/stub_logto.py (no Docker)
  -h, --help   this help

Config (environment, with infra/.env fallback — see scripts/README.md):
  LOGTO_ENDPOINT, LOGTO_M2M_CLIENT_ID, LOGTO_M2M_CLIENT_SECRET,
  LOGTO_MANAGEMENT_API_INDICATOR, LOGTO_NATIVE_CLIENT_ID,
  LOGTO_NATIVE_REDIRECT_URI, API_RESOURCE_INDICATOR, TEST_USER_EMAIL,
  TEST_USER_PASSWORD, ENV_FILE
USAGE
}

# load_env_file FILE — applies spike keys from FILE to the environment.
# Values already set in the environment win; the file never overrides them.
# Parsed conservatively — no eval, so stray shell syntax in .env is inert.
load_env_file() {
  local file="$1" line key value
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in ''|\#*) continue ;; esac
    case "$line" in *=*) ;; *) continue ;; esac
    key="${line%%=*}"
    value="${line#*=}"
    if [ "${#value}" -ge 2 ]; then
      case "$value" in
        '"'*'"') value="${value:1:$(( ${#value} - 2 ))}" ;;
        "'"*"'")  value="${value:1:$(( ${#value} - 2 ))}" ;;
      esac
    fi
    is_spike_key "$key" || continue
    [ -n "${!key:-}" ] || export "$key=$value"
  done < "$file"
  log "config: applied spike keys from $file"
}

SPIKE_ENV_KEYS=(
  LOGTO_ENDPOINT
  LOGTO_M2M_CLIENT_ID
  LOGTO_M2M_CLIENT_SECRET
  LOGTO_MANAGEMENT_API_INDICATOR
  LOGTO_NATIVE_CLIENT_ID
  LOGTO_NATIVE_REDIRECT_URI
  API_RESOURCE_INDICATOR
  AUDIENCE
  TEST_USER_EMAIL
  TEST_USER_PASSWORD
)

is_spike_key() {
  local wanted
  for wanted in "${SPIKE_ENV_KEYS[@]}"; do
    [ "$1" = "$wanted" ] && return 0
  done
  return 1
}

log() {
  printf '%s %s\n' "$PREFIX" "$*" >&2
}

cleanup() {
  if [ -n "$STUB_PID" ]; then
    kill "$STUB_PID" 2>/dev/null || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# ---- step framework ------------------------------------------------------
# Each step sets REASON on failure and returns nonzero; run_step records the
# first failure and keeps running the remaining steps for diagnostics.

STEP_TOTAL=4
STEP_NUM=0
FIRST_FAILED=''
REASON=''

run_step() {
  local name="$1" fn="$2" ok=0
  shift 2
  STEP_NUM=$((STEP_NUM + 1))
  REASON=''
  "$fn" "$@" || ok=1
  if [ "$ok" -eq 0 ]; then
    printf '%s step %s/%s: %s — PASS\n' "$PREFIX" "$STEP_NUM" "$STEP_TOTAL" "$name"
  else
    printf '%s step %s/%s: %s — FAIL (%s)\n' "$PREFIX" "$STEP_NUM" "$STEP_TOTAL" "$name" "${REASON:-unspecified}"
    if [ -z "$FIRST_FAILED" ]; then
      FIRST_FAILED="$name"
    fi
  fi
}

# ---- steps ----------------------------------------------------------------

# step_discovery: the discovery document must exist and name our issuer.
# Every component (Go API ISSUER_URL, Flutter CLUBINS_ISSUER) checks tokens
# against <endpoint>/oidc, so a mismatch here is the failure to catch first.
step_discovery() {
  local status issuer
  status="$(curl -sS --max-time "$CURL_TIMEOUT" -o "$DISCOVERY_FILE" -w '%{http_code}' \
    "$LOGTO_ENDPOINT/oidc/.well-known/openid-configuration")" \
    || { REASON="discovery request to $LOGTO_ENDPOINT failed — is the stack up?"; return 1; }
  [ "$status" = "200" ] || { REASON="discovery returned HTTP $status"; return 1; }
  issuer="$(jq -r '.issuer // ""' "$DISCOVERY_FILE" 2>/dev/null)" \
    || { REASON="discovery body is not JSON"; return 1; }
  [ "$issuer" = "$LOGTO_ENDPOINT/oidc" ] \
    || { REASON="issuer mismatch: discovery says \"$issuer\", expected \"$LOGTO_ENDPOINT/oidc\""; return 1; }
}

# step_jwks: the signing keys the Go API verifies against must be there.
step_jwks() {
  local jwks_uri status keys
  [ -s "$DISCOVERY_FILE" ] || { REASON="no discovery document from step 1"; return 1; }
  jwks_uri="$(jq -r '.jwks_uri // ""' "$DISCOVERY_FILE")"
  [ -n "$jwks_uri" ] || { REASON="discovery carries no jwks_uri"; return 1; }
  status="$(curl -sS --max-time "$CURL_TIMEOUT" -o "$WORK/jwks.json" -w '%{http_code}' "$jwks_uri")" \
    || { REASON="JWKS request to $jwks_uri failed"; return 1; }
  [ "$status" = "200" ] || { REASON="JWKS returned HTTP $status"; return 1; }
  keys="$(jq '.keys | length' "$WORK/jwks.json" 2>/dev/null || true)"
  [[ "$keys" =~ ^[0-9]+$ ]] || { REASON="JWKS body is not JSON with a .keys array"; return 1; }
  [ "$keys" -gt 0 ] || { REASON="JWKS has no keys"; return 1; }
}

# token_claim TOKEN NAME — a claim value from the token's payload, or empty.
token_claim() {
  local part payload
  part="${1#*.}"      # payload.signature
  part="${part%%.*}"  # payload
  payload="$(b64url_decode "$part")" || return 1
  jq -r --arg name "$2" '.[$name] // empty' <<<"$payload" || return 1
}

# body_head FILE — first line-ish of an error body, for FAIL reasons.
body_head() {
  head -c 200 "$1" 2>/dev/null | tr '\n\r\t' '   ' || true
}

# require_vars_step NAME... — step-aware config guard: sets REASON and
# returns 1 instead of dying, so the step framework keeps reporting. Names
# the missing variables, never their values.
require_vars_step() {
  local missing='' name
  for name in "$@"; do
    [ -n "${!name:-}" ] || missing+="$name "
  done
  if [ -n "$missing" ]; then
    REASON="missing required config: $missing (set them in the environment or infra/.env)"
    return 1
  fi
}

# issue_token_m2m — the default headless path: client_credentials with the
# seeded M2M app against the core token endpoint, resource indicator set.
issue_token_m2m() {
  local status aud
  require_vars_step LOGTO_M2M_CLIENT_ID LOGTO_M2M_CLIENT_SECRET || return 1

  status="$(curl -sS --max-time "$CURL_TIMEOUT" -o "$WORK/token.json" -w '%{http_code}' \
    -u "$LOGTO_M2M_CLIENT_ID:$LOGTO_M2M_CLIENT_SECRET" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data 'grant_type=client_credentials' \
    --data-urlencode "resource=$LOGTO_MANAGEMENT_API_INDICATOR" \
    "$LOGTO_ENDPOINT/oidc/token")" \
    || { REASON="token request to $LOGTO_ENDPOINT/oidc/token failed — is the stack up?"; return 1; }
  [ "$status" = "200" ] \
    || { REASON="token endpoint returned HTTP $status: $(body_head "$WORK/token.json")"; return 1; }
  ACCESS_TOKEN="$(jq -er '.access_token // empty' "$WORK/token.json")" \
    || { REASON="token response carried no access_token: $(body_head "$WORK/token.json")"; return 1; }
  TOKEN_KIND='client_credentials (M2M)'
  TOKEN_RESOURCE="$LOGTO_MANAGEMENT_API_INDICATOR"

  aud="$(token_claim "$ACCESS_TOKEN" 'aud')"
  [ "$aud" = "$TOKEN_RESOURCE" ] \
    || { REASON="token audience is \"$aud\", expected \"$TOKEN_RESOURCE\""; return 1; }

  printf '%s        token: kind=%s resource=%s\n' "$PREFIX" "$TOKEN_KIND" "$TOKEN_RESOURCE"
  printf '%s        note:  the seeded M2M app holds the Management API role, so this token\n' "$PREFIX"
  printf '%s               scopes to the management indicator, NOT venues:read — the Go\n' "$PREFIX"
  printf '%s               API would reject it (audience mismatch). This step proves\n' "$PREFIX"
  printf '%s               token issuance, not API authorization; use --user-flow for\n' "$PREFIX"
  printf '%s               the venues-scoped token a customer session would carry.\n' "$PREFIX"
}

# issue_token_user_flow — the full customer-auth path, headlessly. Route
# contract checked against the svhd/logto:1.45.0 source
# (packages/core/src/routes/experience): PUT /api/experience init, POST
# /api/experience/verification/password, POST /api/experience/identification,
# POST /api/experience/submit — all bound to the interaction-session cookies
# the authorize request set. EXPERIMENTAL: session/consent behavior of a live
# Logto could not be verified without Docker; logic-tested against the stub.
issue_token_user_flow() {
  require_tools openssl
  require_vars_step LOGTO_NATIVE_CLIENT_ID TEST_USER_EMAIL TEST_USER_PASSWORD || return 1

  local verifier challenge state cookie_jar="$WORK/cookies.txt"
  verifier="$(random_b64url 32)"
  challenge="$(s256_b64url "$verifier")"
  state="$(random_b64url 16)"

  # 1. Start the interaction: the authorize request creates the OIDC
  #    interaction session; its cookies bind every later Experience call.
  local authorize_url scope='openid profile email venues:read' status
  authorize_url="$LOGTO_ENDPOINT/oidc/auth?client_id=$(urlencode "$LOGTO_NATIVE_CLIENT_ID")&redirect_uri=$(urlencode "$LOGTO_NATIVE_REDIRECT_URI")&response_type=code&scope=$(urlencode "$scope")&resource=$(urlencode "$API_RESOURCE_INDICATOR")&state=$state&code_challenge=$challenge&code_challenge_method=S256"
  status="$(curl -sS --max-time "$CURL_TIMEOUT" -c "$cookie_jar" -o /dev/null -w '%{http_code}' "$authorize_url")" \
    || { REASON="authorize request to $LOGTO_ENDPOINT failed — is the stack up?"; return 1; }
  case "$status" in
    30*) : ;;
    *) REASON="authorize returned HTTP $status, expected a 3xx to the sign-in UI"; return 1 ;;
  esac

  # 2. Sign in: init the interaction, verify the password, identify, submit.
  exp_call PUT "$LOGTO_ENDPOINT/api/experience" '{"interactionEvent":"SignIn"}' \
    || return 1
  [ "$EXP_STATUS" = "204" ] \
    || { REASON="experience init returned HTTP $EXP_STATUS: $(body_head "$WORK/exp-body.json")"; return 1; }

  exp_call POST "$LOGTO_ENDPOINT/api/experience/verification/password" \
    "$(jq -cn --arg e "$TEST_USER_EMAIL" --arg p "$TEST_USER_PASSWORD" \
      '{identifier: {type: "email", value: $e}, password: $p}')" \
    || return 1
  [ "$EXP_STATUS" = "200" ] \
    || { REASON="password verification returned HTTP $EXP_STATUS (bad credentials?): $(body_head "$WORK/exp-body.json")"; return 1; }
  local verification_id
  verification_id="$(jq -er '.verificationId // empty' "$WORK/exp-body.json")" \
    || { REASON="password verification carried no verificationId"; return 1; }

  exp_call POST "$LOGTO_ENDPOINT/api/experience/identification" \
    "$(jq -cn --arg v "$verification_id" '{verificationId: $v}')" \
    || return 1
  [ "$EXP_STATUS" = "204" ] \
    || { REASON="identification returned HTTP $EXP_STATUS: $(body_head "$WORK/exp-body.json")"; return 1; }

  exp_call POST "$LOGTO_ENDPOINT/api/experience/submit" \
    || return 1
  [ "$EXP_STATUS" = "200" ] \
    || { REASON="submit returned HTTP $EXP_STATUS: $(body_head "$WORK/exp-body.json")"; return 1; }
  local redirect_to
  redirect_to="$(jq -er '.redirectTo // empty' "$WORK/exp-body.json")" \
    || { REASON="submit carried no redirectTo"; return 1; }
  case "$redirect_to" in
    /*) redirect_to="$LOGTO_ENDPOINT$redirect_to" ;;
  esac

  # 3. Resume the interaction and follow the redirects on the IdP until the
  #    client callback carries the code.
  local location hop=0 url="$redirect_to"
  while :; do
    location="$(curl -sS --max-time "$CURL_TIMEOUT" -b "$cookie_jar" -o /dev/null \
      -w '%{redirect_url}' "$url")" \
      || { REASON="following $url failed"; return 1; }
    [ -n "$location" ] \
      || { REASON="resume at $url produced no redirect — consent page or session issue?"; return 1; }
    case "$location" in
      "$LOGTO_ENDPOINT"*) : ;;
      *) break ;;
    esac
    hop=$((hop + 1))
    [ "$hop" -le 5 ] || { REASON="too many redirects before the code callback"; return 1; }
    url="$location"
  done
  case "$location" in
    "$LOGTO_NATIVE_REDIRECT_URI"*) : ;;
    *) REASON="expected redirect to $LOGTO_NATIVE_REDIRECT_URI, got: ${location:0:120}"; return 1 ;;
  esac

  local code returned_state
  code="$(query_param "$location" 'code')"
  [ -n "$code" ] || { REASON="callback carried no code: ${location:0:120}"; return 1; }
  returned_state="$(query_param "$location" 'state')"
  [ "$returned_state" = "$state" ] \
    || { REASON="state mismatch (got \"${returned_state:-empty}\")"; return 1; }

  # 4. Exchange the code (public client: PKCE, no secret).
  status="$(curl -sS --max-time "$CURL_TIMEOUT" -o "$WORK/token.json" -w '%{http_code}' \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data 'grant_type=authorization_code' \
    --data-urlencode "code=$code" \
    --data-urlencode "redirect_uri=$LOGTO_NATIVE_REDIRECT_URI" \
    --data-urlencode "client_id=$LOGTO_NATIVE_CLIENT_ID" \
    --data-urlencode "code_verifier=$verifier" \
    "$LOGTO_ENDPOINT/oidc/token")" \
    || { REASON="token exchange failed"; return 1; }
  [ "$status" = "200" ] \
    || { REASON="token exchange returned HTTP $status: $(body_head "$WORK/token.json")"; return 1; }
  ACCESS_TOKEN="$(jq -er '.access_token // empty' "$WORK/token.json")" \
    || { REASON="token exchange carried no access_token: $(body_head "$WORK/token.json")"; return 1; }
  TOKEN_KIND='authorization_code+PKCE (user flow)'
  TOKEN_RESOURCE="$API_RESOURCE_INDICATOR"

  local aud token_scope
  aud="$(token_claim "$ACCESS_TOKEN" 'aud')"
  [ "$aud" = "$TOKEN_RESOURCE" ] \
    || { REASON="access token audience is \"$aud\", expected \"$TOKEN_RESOURCE\""; return 1; }
  token_scope="$(token_claim "$ACCESS_TOKEN" 'scope')"
  case " $token_scope " in
    *" venues:read "*) : ;;
    *) REASON="access token scope is \"$token_scope\", missing venues:read"; return 1 ;;
  esac

  printf '%s        token: kind=%s resource=%s\n' "$PREFIX" "$TOKEN_KIND" "$TOKEN_RESOURCE"
  printf '%s        note:  this is the venues-scoped access token a real customer\n' "$PREFIX"
  printf '%s               session would carry (audience %s, scope venues:read).\n' "$PREFIX" "$TOKEN_RESOURCE"
}

# exp_call METHOD URL [JSON] — Experience API call with the interaction
# cookie jar; sets EXP_STATUS and writes the body to $WORK/exp-body.json.
exp_call() {
  local method="$1" url="$2" body="${3:-}"
  local args=(
    -sS --max-time "$CURL_TIMEOUT"
    -b "$WORK/cookies.txt" -c "$WORK/cookies.txt"
    -o "$WORK/exp-body.json" -w '%{http_code}'
    -X "$method" -H 'Content-Type: application/json'
  )
  [ -z "$body" ] || args+=(-d "$body")
  EXP_STATUS="$(curl "${args[@]}" "$url")" \
    || { REASON="request to $url failed"; return 1; }
}

# step_token — dispatch on the chosen path.
step_token() {
  if [ "$USER_FLOW" = true ]; then
    issue_token_user_flow
  else
    issue_token_m2m
  fi
}

# step_claims — the spike's evidence: decode the issued token's JOSE header
# and payload (delegated to token-inspect.sh, the single decode path).
step_claims() {
  if [ -z "${ACCESS_TOKEN:-}" ]; then
    REASON="no access token from step 3"
    return 1
  fi
  "$SCRIPT_DIR/token-inspect.sh" "$ACCESS_TOKEN" >"$WORK/claims.txt" 2>&1 \
    || { REASON="token-inspect.sh failed on the issued token"; cat "$WORK/claims.txt" >&2; return 1; }
  cat "$WORK/claims.txt"
}

# urlencode STRING — percent-encode for a query parameter.
urlencode() {
  jq -rn --arg v "$1" '$v | @uri'
}

# query_param URL NAME — value of a query parameter, or empty.
query_param() {
  jq -rn --arg u "$1" --arg n "$2" 'try ($u | capture("(?:^|[?&])" + $n + "=(?<v>[^&]*)").v) // empty'
}

# ---- stub mode ------------------------------------------------------------

# start_stub — boot the bundled Logto stub on a free port and point the run
# at it. The stub's dev-only credentials are printed literals, not secrets.
start_stub() {
  require_tools python3
  local stub_log="$WORK/stub.log" attempt=0
  python3 "$SCRIPT_DIR/test/stub_logto.py" --port 0 \
    --m2m-id spike-stub-m2m --m2m-secret stub-m2m-secret-dev-only \
    --test-email spike-stub@example.com --test-password stub-password-dev-only \
    >"$stub_log" 2>&1 &
  STUB_PID=$!
  until grep -qs '^listening ' "$stub_log"; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 50 ]; then
      cat "$stub_log" >&2
      die "stub did not start within 5s"
    fi
    if ! kill -0 "$STUB_PID" 2>/dev/null; then
      cat "$stub_log" >&2
      die "stub died on startup"
    fi
    sleep 0.1
  done
  LOGTO_ENDPOINT="$(sed -n 's/^listening //p' "$stub_log")"
  LOGTO_ENDPOINT="${LOGTO_ENDPOINT%/}"
  LOGTO_M2M_CLIENT_ID=spike-stub-m2m
  LOGTO_M2M_CLIENT_SECRET=stub-m2m-secret-dev-only
  LOGTO_NATIVE_CLIENT_ID=spike-stub-native
  LOGTO_NATIVE_REDIRECT_URI=clubins://login-callback
  TEST_USER_EMAIL=spike-stub@example.com
  TEST_USER_PASSWORD=stub-password-dev-only
}

# ---- main -----------------------------------------------------------------

main() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --user-flow) USER_FLOW=true ;;
      --stub) STUB=true ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown argument: $arg (see --help)" ;;
    esac
  done

  # The stub owns the whole config; nothing is loaded from infra/.env there.
  if [ "$STUB" = false ]; then
    load_env_file "${ENV_FILE:-$REPO_ROOT/infra/.env}"
  fi
  : "${LOGTO_MANAGEMENT_API_INDICATOR:=https://default.logto.app/api}"
  : "${API_RESOURCE_INDICATOR:=${AUDIENCE:-https://api.clubins.de}}"
  : "${LOGTO_NATIVE_REDIRECT_URI:=clubins://login-callback}"

  if [ "$STUB" = true ]; then
    start_stub
  else
    : "${LOGTO_ENDPOINT:=http://localhost:3301}"
    LOGTO_ENDPOINT="${LOGTO_ENDPOINT%/}"
  fi
  require_tools curl jq

  log "endpoint: $LOGTO_ENDPOINT"
  if [ "$USER_FLOW" = true ]; then
    log "path: authorization code + PKCE with the seeded test user (EXPERIMENTAL)"
  else
    log "path: M2M client_credentials"
  fi
  if [ "$STUB" = true ]; then
    log "mode: bundled stub — proves script logic only, NOT a live Logto"
  fi

  run_step "discovery document" step_discovery
  run_step "JWKS keys present" step_jwks
  run_step "access token issuance" step_token
  run_step "claims decode and dump" step_claims

  if [ -n "$FIRST_FAILED" ]; then
    printf '%s FAILED: first failed step: %s\n' "$PREFIX" "$FIRST_FAILED" >&2
    exit 1
  fi
  printf '%s all %s steps passed\n' "$PREFIX" "$STEP_TOTAL"
}

main "$@"
