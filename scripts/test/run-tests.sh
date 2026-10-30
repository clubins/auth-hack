#!/usr/bin/env bash
# Test harness for scripts/, no Docker required:
#
#   1. token-inspect.sh decodes a padded AND an unpadded token, flags an
#      expired one, rejects malformed input, and reads tokens from stdin
#   2. spike.sh --stub exits 0 with every step PASS (M2M path)
#   3. spike.sh --stub --user-flow exits 0 (authorization code + PKCE +
#      password sign-in through the Experience API, against the stub)
#   4. spike.sh against a dead endpoint exits 1 naming the first failed step
#   5. spike.sh --token-optional turns missing issuance credentials into
#      SKIP steps (exit 0), while the same run without the flag fails
#
# The tokens are minted locally; their signatures are fake blobs — decode
# only, nothing verifies them (same honesty as the tools under test).
#
# Exit status: number of failed assertions.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOKEN_INSPECT="$HERE/../token-inspect.sh"
SPIKE="$HERE/../spike.sh"

FAILURES=0
WORK="$(mktemp -d)"
STUB_PID=''

# shellcheck disable=SC2317  # invoked via the EXIT trap
cleanup() {
  if [ -n "$STUB_PID" ]; then
    kill "$STUB_PID" 2>/dev/null || true
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

# shellcheck disable=SC2317  # run through assert's "$@" indirection
is_zero() { [ "$1" -eq 0 ]; }
# shellcheck disable=SC2317
is_nonzero() { [ "$1" -ne 0 ]; }
# shellcheck disable=SC2317
output_has() { grep -q "$1" "$2"; }
# shellcheck disable=SC2317
output_lacks() { ! grep -q "$1" "$2"; }
# shellcheck disable=SC2317
output_pass_count_is() { [ "$(grep -c 'PASS' "$1")" -eq "$2" ]; }
# shellcheck disable=SC2317
output_has_one_first_failed_line() { [ "$(grep -c 'first failed step:' "$1")" -eq 1 ]; }
# shellcheck disable=SC2317
disclaimer_in_all_three() {
  [ "$(grep -l 'signature NOT verified' "$1" "$2" "$3" | wc -l)" -eq 3 ]
}

# mint_token EXP_DELTA ALG -> three-part base64url JWT (fake signature)
mint_token() {
  python3 - "$1" "$2" <<'PY'
import base64, json, sys, time

exp_delta = int(sys.argv[1])
alg = sys.argv[2]
now = int(time.time())

def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode()  # WITH padding

header = {"alg": alg, "kid": "harness-1", "typ": "JWT"}
payload = {
    "iss": "http://127.0.0.1:1/oidc",
    "aud": "https://api.clubins.de",
    "sub": "inspector-test-user",
    "iat": now + exp_delta - 60,
    "exp": now + exp_delta,
    "scope": "venues:read",
}
signature = base64.urlsafe_b64encode(b"harness-fake-signature").decode()
print(".".join([
    b64url(json.dumps(header).encode()),
    b64url(json.dumps(payload).encode()),
    signature,
]))
PY
}

run_inspect() { # $1 = log file, remaining = args to token-inspect.sh
  local log_file="$1"
  shift
  "$TOKEN_INSPECT" "$@" >"$log_file" 2>&1
}

run_spike() { # $1 = log file, remaining = args to spike.sh
  local log_file="$1"
  shift
  bash "$SPIKE" "$@" >"$log_file" 2>&1
}

# boot_stub — start the Logto stub WITHOUT letting spike inject credentials
# (unlike spike --stub): the harness controls the environment explicitly so
# the --token-optional skip path can actually trigger.
boot_stub() {
  local log="$WORK/stub-manual.log" attempt=0
  python3 "$HERE/stub_logto.py" --port 0 \
    --m2m-id harness-m2m --m2m-secret harness-m2m-secret \
    --test-email harness@example.com --test-password harness-password \
    >"$log" 2>&1 &
  STUB_PID=$!
  until grep -qs '^listening ' "$log"; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 50 ]; then
      cat "$log" >&2
      echo "stub did not start within 5s" >&2
      exit 1
    fi
    if ! kill -0 "$STUB_PID" 2>/dev/null; then
      cat "$log" >&2
      echo "stub died on startup" >&2
      exit 1
    fi
    sleep 0.1
  done
  MANUAL_STUB_BASE="$(sed -n 's/^listening //p' "$log")"
}

# --- token-inspect.sh -------------------------------------------------------

PADDED="$(mint_token 3600 RS256)"
UNPADDED="$(tr -d '=' <<<"$PADDED")"
EXPIRED="$(mint_token -3600 RS256)"
UNSIGNED="$(mint_token 3600 none)"

set +e
run_inspect "$WORK/padded.log" "$PADDED"
RC_PADDED=$?
run_inspect "$WORK/unpadded.log" "$UNPADDED"
RC_UNPADDED=$?
run_inspect "$WORK/expired.log" "$EXPIRED"
RC_EXPIRED=$?
run_inspect "$WORK/unsigned.log" "$UNSIGNED"
RC_UNSIGNED=$?
printf '%s' 'not-a-jwt' | run_inspect "$WORK/garbage.log"
RC_GARBAGE=$?
printf '%s' "$PADDED" | run_inspect "$WORK/stdin.log"
RC_STDIN=$?
set -e

assert "padded token decodes with exit 0" is_zero "$RC_PADDED"
assert "padded token output shows the payload claims" output_has 'inspector-test-user' "$WORK/padded.log"
assert "padded token output flags exp as still valid" output_has 'VALID' "$WORK/padded.log"
assert "unpadded token decodes with exit 0" is_zero "$RC_UNPADDED"
assert "unpadded token output shows the same claims" output_has 'inspector-test-user' "$WORK/unpadded.log"
assert "expired token decodes with exit 0" is_zero "$RC_EXPIRED"
assert "expired token is flagged EXPIRED" output_has 'EXPIRED' "$WORK/expired.log"
assert "expired token is not flagged valid" output_lacks 'VALID' "$WORK/expired.log"
assert "alg=none token decodes with exit 0" is_zero "$RC_UNSIGNED"
assert "alg=none token is flagged unsigned" output_has 'UNSIGNED' "$WORK/unsigned.log"
assert "every decode output carries the no-verification disclaimer" \
  disclaimer_in_all_three "$WORK/padded.log" "$WORK/unpadded.log" "$WORK/expired.log"
assert "malformed input exits nonzero" is_nonzero "$RC_GARBAGE"
assert "malformed input names the problem" output_has 'not a three-part compact JWT' "$WORK/garbage.log"
assert "token on stdin decodes with exit 0" is_zero "$RC_STDIN"

# --- spike.sh --stub ---------------------------------------------------------

set +e
run_spike "$WORK/spike-stub.log" --stub
RC_STUB=$?
run_spike "$WORK/spike-userflow.log" --stub --user-flow
RC_USERFLOW=$?
# Dead endpoint: connection refused is immediate (port 9 = discard, unbound).
LOGTO_ENDPOINT=http://127.0.0.1:9 run_spike "$WORK/spike-dead.log"
RC_DEAD=$?
set -e

assert "spike --stub exits 0" is_zero "$RC_STUB"
assert "spike --stub passes exactly the four steps" output_pass_count_is "$WORK/spike-stub.log" 4
assert "spike --stub reports no failures" output_lacks 'FAIL' "$WORK/spike-stub.log"
assert "spike --stub says all steps passed" output_has 'all 4 steps passed' "$WORK/spike-stub.log"
assert "spike --stub names the management resource on the token" \
  output_has 'resource=https://default.logto.app/api' "$WORK/spike-stub.log"
assert "spike --stub is honest that the M2M token is not a venues token" \
  output_has 'NOT venues:read' "$WORK/spike-stub.log"

assert "spike --stub --user-flow exits 0" is_zero "$RC_USERFLOW"
assert "spike --stub --user-flow passes exactly the four steps" output_pass_count_is "$WORK/spike-userflow.log" 4
assert "spike --stub --user-flow yields the venues-scoped token" \
  output_has 'resource=https://api.clubins.de' "$WORK/spike-userflow.log"

assert "spike against a dead endpoint exits 1" is_nonzero "$RC_DEAD"
assert "spike names the first failed step (discovery)" \
  output_has 'first failed step: discovery document' "$WORK/spike-dead.log"
assert "spike reports the first failed step exactly once" output_has_one_first_failed_line "$WORK/spike-dead.log"

# --- spike.sh --token-optional ------------------------------------------------

boot_stub
set +e
LOGTO_ENDPOINT="$MANUAL_STUB_BASE" run_spike "$WORK/spike-optional.log" --token-optional
RC_OPTIONAL=$?
LOGTO_ENDPOINT="$MANUAL_STUB_BASE" run_spike "$WORK/spike-nocreds.log"
RC_NOCREDS=$?
set -e

assert "spike --token-optional without credentials exits 0" is_zero "$RC_OPTIONAL"
assert "spike --token-optional still passes discovery and JWKS" output_pass_count_is "$WORK/spike-optional.log" 2
assert "spike --token-optional reports token issuance as SKIP with the reason" \
  output_has 'access token issuance — SKIP (no M2M credentials' "$WORK/spike-optional.log"
assert "spike --token-optional reports the claims step as SKIP" \
  output_has 'claims decode and dump — SKIP' "$WORK/spike-optional.log"
assert "spike --token-optional points at the documented bootstrap" \
  output_has 'idp/README.md' "$WORK/spike-optional.log"
assert "spike --token-optional summarizes the skip" \
  output_has '2 passed, 2 skipped' "$WORK/spike-optional.log"

assert "spike without credentials still fails without the flag" is_nonzero "$RC_NOCREDS"
assert "spike without credentials names token issuance as the first failure" \
  output_has 'first failed step: access token issuance' "$WORK/spike-nocreds.log"

printf '\n'
if [ "$FAILURES" -eq 0 ]; then
  echo "scripts test harness: all assertions passed"
else
  echo "scripts test harness: $FAILURES assertion(s) failed"
  for log in "$WORK"/*.log; do
    echo "--- $log ---"
    cat "$log"
  done
fi
exit "$FAILURES"
