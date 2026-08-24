#!/usr/bin/env bash
# One-shot: fetch -> unpack -> patch -> pack.
#
#   ./bin/build.sh                  build the package
#   ./bin/build.sh --full           options are passed through to pack.sh
#                                   (--slim is accepted but is the default)
set -euo pipefail
D="$(dirname "$0")"
"$D/fetch-assets.sh"
"$D/unpack.sh"
"$D/patch.sh"
"$D/pack.sh" "$@"
