#!/usr/bin/env bash
# Recovery test on the real printer userland: mod in, stock back out.
#
#   ./test/replica/sim-roundtrip.sh <mod.tgz> <stock.tgz>
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MOD="${1:?usage: sim-roundtrip.sh <mod.tgz> <stock.tgz>}"
STOCK="${2:?usage: sim-roundtrip.sh <mod.tgz> <stock.tgz>}"
# config.env and test.env, and the skip policy. Both packages arrive as
# arguments, so this is here for FF_KEY and PRINTER_IMAGE.
# shellcheck disable=SC1091
. "$ROOT/test/replica/sim-image.sh"

A="$(cd "$(dirname "$MOD")" && pwd)/$(basename "$MOD")"
B="$(cd "$(dirname "$STOCK")" && pwd)/$(basename "$STOCK")"

BASE_PKG="$B" exec "$ROOT/test/replica/printer-exec.sh" \
    "$ROOT/test/replica/printer/case-recovery.sh" "mod.tgz=$A" "stock.tgz=$B"
