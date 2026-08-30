#!/usr/bin/env bash
# One-shot: fetch -> unpack -> patch -> pack. Options pass through to pack.sh.
set -euo pipefail
SCRIPT_DIR="$(dirname "$0")"
"$SCRIPT_DIR/fetch-assets.sh"
"$SCRIPT_DIR/unpack.sh"
"$SCRIPT_DIR/payload.sh"
"$SCRIPT_DIR/pack.sh" "$@"
