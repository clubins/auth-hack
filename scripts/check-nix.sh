#!/usr/bin/env bash
# Parse-checks every tracked .nix file in the repo (nix-instantiate --parse).
#
# The dev sandbox and the GitHub runners have no Nix installed yet, so this
# script is the parse gate wherever Nix is available. Exits nonzero on the
# first unparsable file.
#
# Run with Nix in PATH, or inside the official container:
#   docker run --rm -v "$PWD:/w" -w /w nixos/nix bash scripts/check-nix.sh
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

if ! command -v nix-instantiate >/dev/null 2>&1; then
  echo "error: nix-instantiate not found in PATH" >&2
  echo "install Nix (https://nixos.org/download) or run this script inside" >&2
  echo "the nixos/nix container (command in the file header above)" >&2
  exit 1
fi

mapfile -t files < <(git ls-files -- '*.nix')
if [ "${#files[@]}" -eq 0 ]; then
  echo "no .nix files tracked — nothing to check"
  exit 0
fi

status=0
for f in "${files[@]}"; do
  if nix-instantiate --parse "$f" >/dev/null 2>&1; then
    echo "OK   $f"
  else
    echo "FAIL $f" >&2
    # Re-run un-silenced so the Nix error reaches the output.
    nix-instantiate --parse "$f" >&2 || true
    status=1
  fi
done

if [ "$status" -eq 0 ]; then
  echo "all ${#files[@]} .nix files parse cleanly"
fi
exit "$status"
