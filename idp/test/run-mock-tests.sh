#!/usr/bin/env bash
# Idempotency harness for idp/seed.sh, run against a local mock of the Logto
# Management API (no Docker required):
#
#   1. seed run #1 on a fresh mock — exits 0 and creates exactly the expected
#      objects (1 API resource, 2 scopes, 1 application, 1 test user)
#   2. seed run #2 on the same mock — exits 0 and creates nothing new
#   3. bad M2M credentials — exits nonzero with a clear failure
#
# Exit status: number of failed assertions.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SEED="$HERE/../seed.sh"
PORT="${MOCK_PORT:-4390}"
BASE="http://127.0.0.1:$PORT"
M2M_ID="seed-mock-m2m"
M2M_SECRET="mock-m2m-secret-dev-only"
EXPECTED_CREATIONS=5 # 1 resource + 2 scopes + 1 application + 1 user

FAILURES=0
WORK="$(mktemp -d)"
MOCK_PID=''

# Invoked via the EXIT trap, which shellcheck cannot see as a call site.
# shellcheck disable=SC2317
cleanup() {
  if [ -n "$MOCK_PID" ]; then
    kill "$MOCK_PID" 2>/dev/null || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

assert() {
  local name="$1"
  shift
  if "$@"; then
    printf 'PASS  %s\n' "$name"
  else
    printf 'FAIL  %s\n' "$name"
    FAILURES=$((FAILURES + 1))
  fi
}

# These helpers run through assert's "$@" indirection — shellcheck cannot
# see those call sites, hence the SC2317 directives.
# shellcheck disable=SC2317
is_zero() { [ "$1" -eq 0 ]; }
# shellcheck disable=SC2317
is_nonzero() { [ "$1" -ne 0 ]; }
# shellcheck disable=SC2317
log_has_no_creations() {
  grep -q 'exists' "$1" && ! grep -q 'created' "$1"
}

wait_for_mock() {
  local attempt=0
  until curl -fsS "$BASE/__state" >/dev/null 2>&1; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 50 ]; then
      echo "mock failed to start; log:" >&2
      cat "$WORK/mock.log" >&2
      return 1
    fi
    sleep 0.2
  done
}

run_seed() {
  # $1 = log file, remaining args = extra env for the run
  local log_file="$1"
  shift
  env "$@" bash "$SEED" >"$log_file" 2>&1
}

python3 "$HERE/mock_logto.py" --port "$PORT" --m2m-id "$M2M_ID" --m2m-secret "$M2M_SECRET" \
  >"$WORK/mock.log" 2>&1 &
MOCK_PID=$!
wait_for_mock

# Config goes through a .env file on purpose — it exercises the same
# load_env_file path a fresh-clone run would take.
cat >"$WORK/seed.env" <<ENV
LOGTO_ENDPOINT=$BASE
LOGTO_M2M_CLIENT_ID=$M2M_ID
LOGTO_M2M_CLIENT_SECRET=$M2M_SECRET
TEST_USER_EMAIL=seed-test@example.com
TEST_USER_PASSWORD=mock-password-dev-only
ENV

set +e
run_seed "$WORK/run1.log" ENV_FILE="$WORK/seed.env"
RC1=$?
run_seed "$WORK/run2.log" ENV_FILE="$WORK/seed.env"
RC2=$?
set -e

STATE1="$(curl -fsS "$BASE/__state")"
STATE2="$(curl -fsS "$BASE/__state")"

assert "first seed run exits 0" is_zero "$RC1"
assert "second seed run exits 0" is_zero "$RC2"
assert "first run creates exactly the expected objects" \
  test "$(jq '.creations' <<<"$STATE1")" -eq "$EXPECTED_CREATIONS"
assert "second run creates nothing new" test "$STATE1" = "$STATE2"
assert "first run's log reports the clientId for the Flutter build" \
  grep -q 'CLUBINS_CLIENT_ID=' "$WORK/run1.log"
assert "second run's log reports everything as already present" \
  log_has_no_creations "$WORK/run2.log"

# Wrong secret must fail loudly, not silently "succeed".
cat >"$WORK/bad.env" <<ENV
LOGTO_ENDPOINT=$BASE
LOGTO_M2M_CLIENT_ID=$M2M_ID
LOGTO_M2M_CLIENT_SECRET=wrong-secret
TEST_USER_EMAIL=seed-test@example.com
TEST_USER_PASSWORD=mock-password-dev-only
ENV
set +e
run_seed "$WORK/bad.log" ENV_FILE="$WORK/bad.env"
BAD_RC=$?
set -e
assert "bad M2M credentials exit nonzero" is_nonzero "$BAD_RC"
assert "bad M2M credentials produce a clear error" \
  grep -q 'token response carried no access_token\|token request.*failed' "$WORK/bad.log"

printf '\n'
if [ "$FAILURES" -eq 0 ]; then
  echo "idp mock harness: all assertions passed"
else
  echo "idp mock harness: $FAILURES assertion(s) failed"
  echo "--- run1.log ---"; cat "$WORK/run1.log"
  echo "--- run2.log ---"; cat "$WORK/run2.log"
  echo "--- bad.log ---"; cat "$WORK/bad.log"
fi
exit "$FAILURES"
