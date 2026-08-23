#!/usr/bin/env bash
# UI selection and crash-fallback, exercised on the printer's own shell.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
. "$ROOT/test/test-env.sh"

exec "$ROOT/test/printer-exec.sh" "$ROOT/test/printer/case-ui.sh"
