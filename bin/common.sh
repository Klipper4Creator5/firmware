# Sourced by every script in bin/. Resolves the repo root, loads config.env
# and the selected profile, and exports the feature flags.
#
# Profile selection, in order of precedence:
#   PROFILE=web ./bin/build.sh      environment
#   ./bin/build.sh --profile web    argument (parsed by the caller)
#   PROFILE in config.env           default
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
cd "$ROOT"

# CONFIG_ENV=<path> points at a different one. The test suite uses it to run
# against a throwaway config instead of writing over the one you edited.
CONFIG_ENV="${CONFIG_ENV:-$ROOT/config.env}"
if [ ! -f "$CONFIG_ENV" ]; then
    if [ -f config.env.example ]; then
        echo "no config.env -- copy config.env.example and edit the paths:" >&2
        echo "    cp config.env.example config.env" >&2
    fi
    exit 1
fi
# shellcheck disable=SC1090
. "$CONFIG_ENV"

PROFILE="${PROFILE:-${DEFAULT_PROFILE:-full}}"
if [ -f "profiles/$PROFILE.env" ]; then
    # shellcheck disable=SC1090
    . "profiles/$PROFILE.env"
else
    echo "unknown profile '$PROFILE' (have: $(ls profiles/*.env 2>/dev/null | xargs -n1 basename 2>/dev/null | sed 's/\.env$//' | tr '\n' ' '))" >&2
    exit 1
fi

# Replica-only settings: the factory image and the partition sizes. They exist
# for the tests and never reach a printer, so they live in their own file --
# see test.env.example. Values left in config.env keep working.
TEST_ENV="${TEST_ENV:-$ROOT/test.env}"
# shellcheck disable=SC1090
[ -f "$TEST_ENV" ] && . "$TEST_ENV"

# The version is the release date, 20260823. It only ever appears in the
# outer filename -- the stock installer reads the software component's own
# version, never this one -- so a date says something true about the build,
# where a semver would just be a number nobody remembers to bump.
#
# Set MOD_VER explicitly to pin it: for a reproducible rebuild of an old
# release, or for a second release on the same day (20260823b).
MOD_VER="${MOD_VER:-$(date -u +%Y%m%d)}"
export MOD_VER

# Which model are we building for? Packages are model-specific: the two
# stock packages carry different firmwareExe binaries and each refuses to
# install on the other model, so one build can never serve both.
TARGET_MACHINE="${MODEL:-${TARGET_MACHINE:-Creator5Pro}}"
case "$TARGET_MACHINE" in
    Creator5Pro) TARGET_PID=0029; _stock="${STOCK_TGZ_CREATOR5PRO:-}" ;;
    Creator5)    TARGET_PID=0028; _stock="${STOCK_TGZ_CREATOR5:-}" ;;
    *) echo "TARGET_MACHINE must be Creator5 or Creator5Pro (got '$TARGET_MACHINE')" >&2; exit 1 ;;
esac
# An explicit STOCK_TGZ always wins; otherwise use the per-model one.
if [ -z "${STOCK_TGZ:-}" ] && [ -n "$_stock" ]; then
    STOCK_TGZ="$_stock"
fi

# PROG_DUMP is a real /usr/prog for the printer replica. One factory image
# serves both models: only the Pro's was ever published, and the replica
# installs the model's own stock package on top of it, which replaces every
# model-specific file it contains.
export TARGET_MACHINE TARGET_PID STOCK_TGZ PROG_DUMP

WORK="${WORK:-work}"
