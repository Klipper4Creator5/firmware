#!/usr/bin/env bash
# One-shot: fetch -> unpack -> patch -> pack, for one profile.
#
#   ./bin/build.sh                  the profile from config.env (DEFAULT_PROFILE)
#   ./bin/build.sh probe            pre-flight: changes nothing
#   ./bin/build.sh default --slim   pass-through options go to pack.sh
set -euo pipefail
case "${1:-}" in
    ''|-*) : ;;
    *) export PROFILE="$1"; shift ;;
esac
D="$(dirname "$0")"
"$D/fetch-assets.sh"
"$D/unpack.sh"
"$D/patch.sh"
"$D/pack.sh" "$@"
