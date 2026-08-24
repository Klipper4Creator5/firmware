#!/usr/bin/env bash
# One-shot: fetch -> unpack -> patch -> pack.
#
#   ./bin/build.sh                  build the package
#   ./bin/build.sh --slim           options are passed through to pack.sh
set -euo pipefail
D="$(dirname "$0")"
"$D/fetch-assets.sh"
"$D/unpack.sh"
"$D/patch.sh"
"$D/pack.sh" "$@"
