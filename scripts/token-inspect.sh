#!/usr/bin/env bash
# Decode a JWT (Logto access token or any compact-serialisation JWT) and show
# its JOSE header and claims payload, plus its exp status against the current
# time.
#
# DECODE ONLY: this script never fetches a JWKS and never verifies the
# signature. Its output must not be used for authentication decisions — that
# is the Go API's job (backend/internal/auth).
#
# Usage:
#   token-inspect.sh <jwt>        # token as an argument
#   ... | token-inspect.sh        # token on stdin (pasted or piped)
#
# Exit status: 0 when the token decodes (expired or not), 1 when the input is
# not a well-formed three-part JWT or its parts are not decodable JSON.
# Requires: bash, jq, base64 (coreutils).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PREFIX='[token-inspect]'
DISCLAIMER='decode only — signature NOT verified; do not use for authentication decisions'

# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat >&2 <<USAGE
$PREFIX decode a JWT's header and payload. ${DISCLAIMER}.

Usage:
  token-inspect.sh <jwt>    token as an argument
  <jwt> | token-inspect.sh  token on stdin
  token-inspect.sh --help
USAGE
}

main() {
  local token="$1"

  if [ -z "$token" ] && [ ! -t 0 ]; then
    token="$(cat)"
  fi
  [ -n "$token" ] || { usage; die "no token given (pass it as \$1 or on stdin)"; }

  # Compact serialisation: header.payload.signature, all base64url, with or
  # without '=' padding (JWTs omit it; a pasted token may carry it). The
  # signature part may be empty ("alg":"none").
  token="$(tr -d '[:space:]' <<<"$token")"
  local pattern='^[A-Za-z0-9_-]+=*\.[A-Za-z0-9_-]+=*\.[A-Za-z0-9_-]*=*$'
  [[ "$token" =~ $pattern ]] \
    || die "input is not a three-part compact JWT (expected header.payload.signature in base64url)"

  local header_b64 payload_b64 signature_b64
  header_b64="${token%%.*}"
  payload_b64="${token#*.}"
  payload_b64="${payload_b64%%.*}"
  signature_b64="${token##*.}"

  local header payload
  header="$(b64url_decode "$header_b64")" || die "token header is not valid base64url"
  payload="$(b64url_decode "$payload_b64")" || die "token payload is not valid base64url"
  jq -e . <<<"$header" >/dev/null 2>&1 || die "token header is not valid JSON"
  jq -e . <<<"$payload" >/dev/null 2>&1 || die "token payload is not valid JSON"

  printf '%s NOTE: %s\n' "$PREFIX" "$DISCLAIMER"

  local alg
  alg="$(jq -r '.alg // "absent"' <<<"$header")"
  if [ "$alg" = "none" ]; then
    printf '%s WARNING: header declares alg=none — this token is UNSIGNED\n' "$PREFIX"
  fi

  printf '%s header:\n%s\n' "$PREFIX" "$(jq . <<<"$header")"
  printf '%s payload:\n%s\n' "$PREFIX" "$(jq . <<<"$payload")"

  local now exp delta exp_iso
  now="$(date +%s)"
  exp="$(jq -r 'if has("exp") and (.exp | type == "number") then .exp else empty end' <<<"$payload")"
  if [ -z "$exp" ]; then
    printf '%s exp: not present in payload\n' "$PREFIX"
  else
    delta=$(( exp - now ))
    exp_iso="$(jq -rn --argjson t "$exp" '$t | strftime("%Y-%m-%dT%H:%M:%SZ")')"
    if [ "$delta" -gt 0 ]; then
      printf '%s exp: %s — VALID for %s more seconds (until %s)\n' "$PREFIX" "$exp" "$delta" "$exp_iso"
    else
      printf '%s exp: %s — EXPIRED %s seconds ago (at %s)\n' "$PREFIX" "$exp" "$(( -delta ))" "$exp_iso"
    fi
  fi

  if [ -z "$signature_b64" ]; then
    printf '%s signature: empty (unsigned token)\n' "$PREFIX"
  else
    printf '%s signature: present (%s base64url chars) — not verified\n' "$PREFIX" "${#signature_b64}"
  fi
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  *) main "${1:-}" ;;
esac
