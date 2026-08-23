#!/usr/bin/env bash
# Recovery test on the real printer userland: mod in, stock back out.
#
#   ./test/sim-roundtrip.sh <mod.tgz> <stock.tgz>
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MOD="${1:?usage: sim-roundtrip.sh <mod.tgz> <stock.tgz>}"
STOCK="${2:?usage: sim-roundtrip.sh <mod.tgz> <stock.tgz>}"
# shellcheck disable=SC1091
. "$ROOT/test/test-env.sh"

A="$(cd "$(dirname "$MOD")" && pwd)/$(basename "$MOD")"
B="$(cd "$(dirname "$STOCK")" && pwd)/$(basename "$STOCK")"

BASE_PKG="$B" exec "$ROOT/test/printer-exec.sh" \
    "$ROOT/test/printer/case-recovery.sh" "mod.tgz=$A" "stock.tgz=$B"
