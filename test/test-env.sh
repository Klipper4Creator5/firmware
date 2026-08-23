# Sourced by the replica launchers. Loads, in order:
#
#   config.env   the BUILD config -- needed here only for FF_KEY and the stock
#                packages, which the replica installs as its baseline
#   test.env     everything that exists ONLY for the tests and never reaches a
#                printer: the factory image and the partition sizes
#
# Keeping them apart is the point: nothing in test.env can end up in a package.
# Values still set in config.env keep working (they are loaded first), but
# test.env is where they belong.
#
# THE ENVIRONMENT WINS OVER BOTH FILES. `PRINTER_IMAGE=` sitting empty in
# test.env used to overwrite an explicit
# `PRINTER_IMAGE=foo ./test/sim-install.sh ...`, so the override silently did
# nothing and the run tested a different image than the one you named.
_SAVE_PRINTER_IMAGE="${PRINTER_IMAGE-}"; _HAD_PRINTER_IMAGE="${PRINTER_IMAGE+y}"
_SAVE_PROG_DUMP="${PROG_DUMP-}";         _HAD_PROG_DUMP="${PROG_DUMP+y}"
_SAVE_PROG_MB="${PROG_MB-}";             _HAD_PROG_MB="${PROG_MB+y}"
_SAVE_DATA_MB="${DATA_MB-}";             _HAD_DATA_MB="${DATA_MB+y}"
_SAVE_FF_KEY="${FF_KEY-}";               _HAD_FF_KEY="${FF_KEY+y}"

CONFIG_ENV="${CONFIG_ENV:-$ROOT/config.env}"
TEST_ENV="${TEST_ENV:-$ROOT/test.env}"
# shellcheck disable=SC1090
[ -f "$CONFIG_ENV" ] && . "$CONFIG_ENV"
# shellcheck disable=SC1090
[ -f "$TEST_ENV" ] && . "$TEST_ENV"

# An empty string in the environment is still a decision, so restore anything
# that was set at all -- not just anything that was non-empty.
[ -n "${_HAD_PRINTER_IMAGE:-}" ] && PRINTER_IMAGE="$_SAVE_PRINTER_IMAGE"
[ -n "${_HAD_PROG_DUMP:-}" ]     && PROG_DUMP="$_SAVE_PROG_DUMP"
[ -n "${_HAD_PROG_MB:-}" ]       && PROG_MB="$_SAVE_PROG_MB"
[ -n "${_HAD_DATA_MB:-}" ]       && DATA_MB="$_SAVE_DATA_MB"
[ -n "${_HAD_FF_KEY:-}" ]        && FF_KEY="$_SAVE_FF_KEY"
unset _SAVE_PRINTER_IMAGE _SAVE_PROG_DUMP _SAVE_PROG_MB _SAVE_DATA_MB _SAVE_FF_KEY
unset _HAD_PRINTER_IMAGE _HAD_PROG_DUMP _HAD_PROG_MB _HAD_DATA_MB _HAD_FF_KEY

export PRINTER_IMAGE="${PRINTER_IMAGE:-}" PROG_DUMP="${PROG_DUMP:-}" \
       PROG_MB="${PROG_MB:-}" DATA_MB="${DATA_MB:-}"
