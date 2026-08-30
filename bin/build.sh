#!/usr/bin/env bash
# One-shot: fetch -> unpack -> patch -> pack. Options pass through to pack.sh.
set -euo pipefail
SCRIPT_DIR="$(dirname "$0")"
# --stock: unpack.sh reads the stock package on the next line, so this lane
# needs one. The packaging lane does not, and gets it by never passing the flag.
"$SCRIPT_DIR/fetch-assets.sh" --stock
"$SCRIPT_DIR/unpack.sh"
"$SCRIPT_DIR/payload.sh"
"$SCRIPT_DIR/pack.sh" "$@"
