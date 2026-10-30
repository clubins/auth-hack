#!/usr/bin/env bash
# Shared helpers for the scripts/ tools. Sourced by spike.sh and
# token-inspect.sh, never executed directly.
#
# Callers must set $PREFIX before sourcing: die/warn print through it.
# Requires: bash, jq.

set -euo pipefail

die() {
  printf '%s ERROR: %s\n' "$PREFIX" "$1" >&2
  exit 1
}

warn() {
  printf '%s WARN: %s\n' "$PREFIX" "$1" >&2
}

# require_tools TOOL... — die naming the missing tools before any request.
require_tools() {
  local tool missing=''
  for tool in "$@"; do
    command -v "$tool" >/dev/null 2>&1 || missing+="$tool "
  done
  [ -z "$missing" ] || die "required tools not found: $missing"
}

# b64url_decode STRING -> decoded bytes on stdout
# Base64url, tolerating missing padding (JWTs omit '='). Invalid input fails.
b64url_decode() {
  local input remainder decoded
  input="$(tr -d '[:space:]' <<<"$1")"
  remainder=$(( ${#input} % 4 ))
  case "$remainder" in
    0) : ;;
    2) input+='==' ;;
    3) input+='=' ;;
    *) return 1 ;; # a base64 string can never have length ≡ 1 (mod 4)
  esac
  decoded="$(tr '_-' '/+' <<<"$input" | base64 -d 2>/dev/null)" || return 1
  printf '%s' "$decoded"
}

# random_b64url BYTES -> random base64url string (no padding, no newlines)
random_b64url() {
  head -c "$1" /dev/urandom | base64 | tr '+/' '-_' | tr -d '= \n'
}

# s256_b64url STRING -> BASE64URL(SHA-256(STRING)) — the S256 code challenge.
s256_b64url() {
  printf '%s' "$1" | openssl dgst -binary -sha256 | base64 | tr '+/' '-_' | tr -d '= \n'
}
