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
CONFIG_ENV="${CONFIG_ENV:-$ROOT/config.env}"
TEST_ENV="${TEST_ENV:-$ROOT/test.env}"
# shellcheck disable=SC1090
[ -f "$CONFIG_ENV" ] && . "$CONFIG_ENV"
# shellcheck disable=SC1090
[ -f "$TEST_ENV" ] && . "$TEST_ENV"
export PROG_DUMP="${PROG_DUMP:-}" PROG_MB="${PROG_MB:-}" DATA_MB="${DATA_MB:-}"
