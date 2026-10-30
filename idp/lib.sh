#!/usr/bin/env bash
# Shared helpers for the idp/ seed scripts: config loading, Logto Management
# API access (M2M token, paginated listing), and create-if-absent guards.
#
# Sourced by seed.sh, never executed directly. Requires bash, curl, jq.

set -euo pipefail

PAGE_SIZE=20   # matches the Management API default page size
MAX_PAGES=10   # defensive cap; a fresh instance never reaches page 2

API_STATUS=''  # HTTP status of the last api_call
API_BODY=''    # body of the last api_call

log()  { printf '[seed] %s\n' "$*" >&2; }
warn() { printf '[seed] WARN: %s\n' "$*" >&2; }
die()  { printf '[seed] ERROR: %s\n' "$*" >&2; exit 1; }

# Keys the seed reads from infra/.env. Compose-only keys (LOGTO_DB_PASSWORD,
# ports, ...) are ignored — the compose stack owns those.
SEED_ENV_KEYS=(
  LOGTO_ENDPOINT
  LOGTO_MANAGEMENT_ENDPOINT
  LOGTO_MANAGEMENT_API_INDICATOR
  LOGTO_M2M_CLIENT_ID
  LOGTO_M2M_CLIENT_SECRET
  AUDIENCE
  API_RESOURCE_INDICATOR
  API_RESOURCE_NAME
  LOGTO_APP_NAME
  LOGTO_APP_TYPE
  LOGTO_APP_REDIRECT_URI
  LOGTO_APP_POST_LOGOUT_REDIRECT_URI
  TEST_USER_ID
  TEST_USER_NAME
  TEST_USER_EMAIL
  TEST_USER_PASSWORD
)

is_seed_key() {
  local wanted
  for wanted in "${SEED_ENV_KEYS[@]}"; do
    [ "$1" = "$wanted" ] && return 0
  done
  return 1
}

# load_env_file FILE
# Applies KEY=VALUE lines to the environment for keys in SEED_ENV_KEYS.
# Values already set in the environment win; the file never overrides them.
# Parsed conservatively — no eval, so stray shell syntax in .env is inert.
load_env_file() {
  local file="$1"
  local line key value
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in ''|\#*) continue ;; esac
    case "$line" in *=*) ;; *) continue ;; esac
    key="${line%%=*}"
    value="${line#*=}"
    # Strip one pair of matching surrounding quotes, if present.
    if [ "${#value}" -ge 2 ]; then
      case "$value" in
        '\"'*'\"') value="${value:1:$(( ${#value} - 2 ))}" ;;
        "'"*"'" )  value="${value:1:$(( ${#value} - 2 ))}" ;;
      esac
    fi
    is_seed_key "$key" || continue
    [ -n "${!key:-}" ] || export "$key=$value"
  done < "$file"
  log "config: applied seed keys from $file"
}

# require_vars NAME...
# Fails with the missing names (never their values) before any request is made.
require_vars() {
  local missing='' name
  for name in "$@"; do
    [ -n "${!name:-}" ] || missing+="$name "
  done
  [ -z "$missing" ] || die "missing required config: $missing(set them in the environment or infra/.env)"
}

# fetch_management_token -> prints the access token
# client_credentials grant against the core OIDC token endpoint, scoped to the
# Management API resource indicator (OSS: https://default.logto.app/api).
fetch_management_token() {
  local response scope
  response="$(curl -sS --max-time 30 \
      -u "$LOGTO_M2M_CLIENT_ID:$LOGTO_M2M_CLIENT_SECRET" \
      -H 'Content-Type: application/x-www-form-urlencoded' \
      --data 'grant_type=client_credentials' \
      --data-urlencode "resource=$LOGTO_MANAGEMENT_API_INDICATOR" \
      "$LOGTO_ENDPOINT/oidc/token")" \
    || die "token request to $LOGTO_ENDPOINT/oidc/token failed — is the Logto container up?"
  scope="$(jq -r '.scope // ""' <<<"$response")"
  [ "$scope" = "all" ] \
    || warn "token scope is \"$scope\" (expected \"all\") — the M2M app may be missing the Management API role"
  jq -er '.access_token // empty' <<<"$response" \
    || die "token response carried no access_token — check the M2M credentials"
}

# api_call METHOD PATH [JSON_BODY]
# On success: API_STATUS and API_BODY hold the response. curl transport
# failures die; HTTP error statuses are returned to the caller for branching
# (create-if-absent tolerates 4xx conflicts on purpose).
api_call() {
  local method="$1" path="$2" status
  local -a args=(
    -sS --max-time 30 -X "$method"
    -H "Authorization: Bearer ${MGMT_TOKEN:?}"
    -H 'Content-Type: application/json'
    -o "$API_BODY_FILE" -w '%{http_code}'
    "$MANAGEMENT_API$path"
  )
  [ "$#" -lt 3 ] || args+=(-d "$3")
  status="$(curl "${args[@]}")" \
    || die "request to $path failed (curl transport error against $MANAGEMENT_API)"
  API_STATUS="$status"
  API_BODY="$(cat "$API_BODY_FILE")"
}

# api_list PATH -> prints every page of a paginated endpoint as one JSON array
api_list() {
  local path="$1" page=1 items='' acc=''
  while :; do
    api_call GET "$path?page=$page&page_size=$PAGE_SIZE"
    [ "$API_STATUS" = "200" ] || die "listing $path failed (HTTP $API_STATUS): $API_BODY"
    items="$(jq -ce '.[]' <<<"$API_BODY")" || die "$path returned a non-array body: $API_BODY"
    if [ -n "$items" ]; then
      acc+="${items}"$'\n'
    fi
    # A short page means we have everything.
    [ "$(jq 'length' <<<"$API_BODY")" -eq "$PAGE_SIZE" ] || break
    page=$((page + 1))
    [ "$page" -le "$MAX_PAGES" ] || die "pagination on $path exceeded $MAX_PAGES pages"
  done
  jq -s '.' <<<"${acc:-[]}"
}

# find_by_field JSON_ARRAY_FIELD VALUE ARRAY_JSON -> object or empty string
find_by_field() {
  local field="$1" value="$2" array_json="$3"
  jq -c --arg f "$field" --arg v "$value" 'map(select(.[$f] == $v))[0] // empty' <<<"$array_json"
}
