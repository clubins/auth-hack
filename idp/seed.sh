#!/usr/bin/env bash
# Seed the Clubins Logto OSS instance with everything the reference stack
# needs, via the Management API:
#
#   1. API resource https://api.clubins.de with scopes venues:read/venues:write
#   2. Native application for the Flutter client (PKCE, custom-scheme redirects)
#   3. One test user (email + password from the environment)
#
# Create-if-absent throughout: safe to run any number of times; a second run
# creates nothing and exits 0.
#
# Usage: idp/seed.sh
# Config: environment, falling back to infra/.env (see idp/README.md).
# Prereq: a one-time M2M bootstrap in the admin console (idp/README.md).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=idp/lib.sh
source "$SCRIPT_DIR/lib.sh"

API_BODY_FILE="$(mktemp)"
trap 'rm -f "$API_BODY_FILE"' EXIT

RESOURCE_ID=''
APP_ID=''
TEST_USER_EMAIL_FOUND=''

main() {
  load_env_file "${ENV_FILE:-$REPO_ROOT/infra/.env}"

  : "${LOGTO_ENDPOINT:=http://localhost:3301}"
  # In OSS v1.45.0 the Management API is mounted on the tenant app at the root
  # (/api/... paths), so the base equals LOGTO_ENDPOINT by default. All seed
  # paths below already start with /api — override only for exotic deployments.
  : "${LOGTO_MANAGEMENT_ENDPOINT:=$LOGTO_ENDPOINT}"
  : "${LOGTO_MANAGEMENT_API_INDICATOR:=https://default.logto.app/api}"
  : "${API_RESOURCE_INDICATOR:=${AUDIENCE:-https://api.clubins.de}}"
  : "${API_RESOURCE_NAME:=Clubins API}"
  : "${LOGTO_APP_NAME:=Clubins Flutter}"
  : "${LOGTO_APP_TYPE:=Native}"
  # Defaults match frontend/lib/auth/auth_config.dart.
  : "${LOGTO_APP_REDIRECT_URI:=clubins://login-callback}"
  : "${LOGTO_APP_POST_LOGOUT_REDIRECT_URI:=clubins://logout-callback}"
  : "${TEST_USER_ID:=seed-test-user}"
  : "${TEST_USER_NAME:=Clubins Test User}"

  MANAGEMENT_API="$LOGTO_MANAGEMENT_ENDPOINT"

  require_vars LOGTO_ENDPOINT LOGTO_MANAGEMENT_ENDPOINT LOGTO_M2M_CLIENT_ID \
    LOGTO_M2M_CLIENT_SECRET TEST_USER_EMAIL TEST_USER_PASSWORD
  require_tools

  guard_redirect_type

  MGMT_TOKEN="$(fetch_management_token)"

  ensure_api_resource
  ensure_application
  ensure_test_user

  print_summary
}

require_tools() {
  local tool missing=''
  for tool in curl jq; do
    command -v "$tool" >/dev/null 2>&1 || missing+="$tool "
  done
  [ -z "$missing" ] || die "required tools not found: $missing"
}

# Custom-scheme redirects only pass Logto's validation for Native apps; fail
# early with the reason instead of a bare 400 from the API.
guard_redirect_type() {
  case "$LOGTO_APP_TYPE" in
    Native) return 0 ;;
    *)
      case "$LOGTO_APP_REDIRECT_URI" in
        https://*|http://localhost:*|http://localhost/*) return 0 ;;
        *) warn "type $LOGTO_APP_TYPE with custom-scheme redirect \"$LOGTO_APP_REDIRECT_URI\" will be rejected by Logto (Native apps only)" ;;
      esac
      ;;
  esac
}

ensure_api_resource() {
  local found
  found="$(find_by_field indicator "$API_RESOURCE_INDICATOR" "$(api_list /api/resources)")"
  if [ -n "$found" ]; then
    RESOURCE_ID="$(jq -r '.id' <<<"$found")"
    log "api resource $API_RESOURCE_INDICATOR: exists (id $RESOURCE_ID)"
  else
    local payload
    payload="$(jq -cn --arg n "$API_RESOURCE_NAME" --arg i "$API_RESOURCE_INDICATOR" \
      '{name: $n, indicator: $i}')"
    api_call POST /api/resources "$payload"
    if [[ "$API_STATUS" =~ ^2 ]]; then
      RESOURCE_ID="$(jq -r '.id' <<<"$API_BODY")"
      log "api resource $API_RESOURCE_INDICATOR: created (id $RESOURCE_ID)"
    else
      # Tolerate a lost create race (parallel seed run): re-check once.
      found="$(find_by_field indicator "$API_RESOURCE_INDICATOR" "$(api_list /api/resources)")"
      [ -n "$found" ] || die "creating api resource failed (HTTP $API_STATUS): $API_BODY"
      RESOURCE_ID="$(jq -r '.id' <<<"$found")"
      log "api resource $API_RESOURCE_INDICATOR: already existed (concurrent run)"
    fi
  fi

  ensure_scope "venues:read" "Read venue data"
  ensure_scope "venues:write" "Manage venue data"
}

ensure_scope() {
  local name="$1" description="$2" found
  found="$(find_by_field name "$name" "$(api_list "/api/resources/$RESOURCE_ID/scopes")")"
  if [ -n "$found" ]; then
    log "scope $name: exists"
    return 0
  fi
  api_call POST "/api/resources/$RESOURCE_ID/scopes" \
    "$(jq -cn --arg n "$name" --arg d "$description" '{name: $n, description: $d}')"
  if [[ "$API_STATUS" =~ ^2 ]]; then
    log "scope $name: created"
    return 0
  fi
  found="$(find_by_field name "$name" "$(api_list "/api/resources/$RESOURCE_ID/scopes")")"
  [ -n "$found" ] || die "creating scope $name failed (HTTP $API_STATUS): $API_BODY"
  log "scope $name: already existed (concurrent run)"
}

# Logto auto-generates the OAuth client id (the application's `id`); it cannot
# be pinned to a literal like "clubins-flutter" through the Management API.
# We match on the app name and print the generated id for the Flutter build.
ensure_application() {
  local found
  found="$(find_by_field name "$LOGTO_APP_NAME" "$(api_list /api/applications)")"
  if [ -n "$found" ]; then
    APP_ID="$(jq -r '.id' <<<"$found")"
    log "application $LOGTO_APP_NAME: exists (id $APP_ID)"
    check_application_shape "$found"
  else
    local payload
    payload="$(jq -cn --arg n "$LOGTO_APP_NAME" --arg t "$LOGTO_APP_TYPE" \
        --arg r "$LOGTO_APP_REDIRECT_URI" --arg p "$LOGTO_APP_POST_LOGOUT_REDIRECT_URI" \
        '{name: $n, type: $t, description: "Clubins Flutter client (created by idp/seed.sh)",
          oidcClientMetadata: {redirectUris: [$r], postLogoutRedirectUris: [$p]}}')"
    api_call POST /api/applications "$payload"
    if [[ "$API_STATUS" =~ ^2 ]]; then
      APP_ID="$(jq -r '.id' <<<"$API_BODY")"
      log "application $LOGTO_APP_NAME: created (id $APP_ID)"
    else
      found="$(find_by_field name "$LOGTO_APP_NAME" "$(api_list /api/applications)")"
      [ -n "$found" ] || die "creating application failed (HTTP $API_STATUS): $API_BODY"
      APP_ID="$(jq -r '.id' <<<"$found")"
      log "application $LOGTO_APP_NAME: already existed (concurrent run)"
    fi
  fi
}

# Warn (never mutate) when an existing app drifted from the desired shape:
# the seed is create-if-absent, but silent redirect-URI drift causes confusing
# sign-in failures later.
check_application_shape() {
  local app_json="$1" type uris
  type="$(jq -r '.type' <<<"$app_json")"
  [ "$type" = "$LOGTO_APP_TYPE" ] \
    || warn "application $LOGTO_APP_NAME has type $type (expected $LOGTO_APP_TYPE)"
  uris="$(jq -r '.oidcClientMetadata.redirectUris | join(" ")' <<<"$app_json")"
  [[ " $uris " == *" $LOGTO_APP_REDIRECT_URI "* ]] \
    || warn "application $LOGTO_APP_NAME lacks redirect URI \"$LOGTO_APP_REDIRECT_URI\" (has: $uris)"
  uris="$(jq -r '.oidcClientMetadata.postLogoutRedirectUris | join(" ")' <<<"$app_json")"
  [[ " $uris " == *" $LOGTO_APP_POST_LOGOUT_REDIRECT_URI "* ]] \
    || warn "application $LOGTO_APP_NAME lacks post-logout URI \"$LOGTO_APP_POST_LOGOUT_REDIRECT_URI\" (has: $uris)"
}

# The test user gets a stable id, so GET-by-id is the whole existence check.
ensure_test_user() {
  api_call GET "/api/users/$TEST_USER_ID"
  case "$API_STATUS" in
    200)
      TEST_USER_EMAIL_FOUND="$(jq -r '.primaryEmail // ""' <<<"$API_BODY")"
      log "test user $TEST_USER_ID: exists"
      [ "$TEST_USER_EMAIL_FOUND" = "$TEST_USER_EMAIL" ] \
        || warn "test user $TEST_USER_ID has email \"$TEST_USER_EMAIL_FOUND\" (expected \"$TEST_USER_EMAIL\")"
      ;;
    404)
      api_call POST /api/users \
        "$(jq -cn --arg id "$TEST_USER_ID" --arg e "$TEST_USER_EMAIL" \
            --arg p "$TEST_USER_PASSWORD" --arg n "$TEST_USER_NAME" \
            '{id: $id, primaryEmail: $e, password: $p, name: $n}')"
      if [[ "$API_STATUS" =~ ^2 ]]; then
        log "test user $TEST_USER_ID: created ($TEST_USER_EMAIL)"
      else
        api_call GET "/api/users/$TEST_USER_ID"
        [ "$API_STATUS" = "200" ] \
          || die "creating test user failed (HTTP $API_STATUS): $API_BODY"
        log "test user $TEST_USER_ID: already existed (concurrent run)"
      fi
      ;;
    *)
      die "checking test user failed (HTTP $API_STATUS): $API_BODY"
      ;;
  esac
}

print_summary() {
  printf '%s\n' "──────────────────────────────────────────────────────────"
  printf 'Seed complete — Logto at %s\n' "$LOGTO_ENDPOINT"
  printf '  API resource: %s (id %s), scopes: venues:read, venues:write\n' \
    "$API_RESOURCE_INDICATOR" "$RESOURCE_ID"
  printf '  Application:  %s (%s)\n' "$LOGTO_APP_NAME" "$LOGTO_APP_TYPE"
  printf '    clientId:   %s\n' "$APP_ID"
  printf '    → run the app with: --dart-define=CLUBINS_CLIENT_ID=%s\n' "$APP_ID"
  printf '    redirect:   %s   post-logout: %s\n' \
    "$LOGTO_APP_REDIRECT_URI" "$LOGTO_APP_POST_LOGOUT_REDIRECT_URI"
  printf '  Test user:    %s (%s) — password from TEST_USER_PASSWORD\n' \
    "$TEST_USER_ID" "$TEST_USER_EMAIL"
  printf '%s\n' "──────────────────────────────────────────────────────────"
}

main "$@"
