#!/usr/bin/env bash
# One-shot: fetch -> unpack -> patch -> pack.
#
#   ./bin/build.sh                  build the package
#   ./bin/build.sh --full           options are passed through to pack.sh
#                                   (--slim is accepted but is the default)
set -euo pipefail
SCRIPT_DIR="$(dirname "$0")"
"$SCRIPT_DIR/fetch-assets.sh"
"$SCRIPT_DIR/unpack.sh"
"$SCRIPT_DIR/patch.sh"
"$SCRIPT_DIR/pack.sh" "$@"
