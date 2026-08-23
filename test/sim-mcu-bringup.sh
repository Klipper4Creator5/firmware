#!/usr/bin/env bash
# ff-mcu-bringup.py must actually run on the printer: right interpreter,
# right library path, no traceback. Exercised against the real /usr/prog.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
. "$ROOT/test/test-env.sh"

exec "$ROOT/test/printer-exec.sh" "$ROOT/test/printer/case-mcu-bringup.sh"
