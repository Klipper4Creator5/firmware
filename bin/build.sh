#!/usr/bin/env bash
# One-shot: unpack -> patch -> pack, for one profile.
#
#   ./bin/build.sh                  the profile from config.env (DEFAULT_PROFILE)
#   ./bin/build.sh probe            stage 0: changes nothing
#   ./bin/build.sh full --slim      pass-through options go to pack.sh
set -euo pipefail
case "${1:-}" in
    ''|-*) : ;;
    *) export PROFILE="$1"; shift ;;
esac
D="$(dirname "$0")"
"$D/unpack.sh"
"$D/patch.sh"
"$D/pack.sh" "$@"
