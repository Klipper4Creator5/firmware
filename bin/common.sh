# Sourced by every script in bin/. Resolves the repo root, loads config.env
# and the selected profile, and exports the feature flags.
#
# Profile selection, in order of precedence:
#   PROFILE=web ./bin/build.sh      environment
#   ./bin/build.sh --profile web    argument (parsed by the caller)
#   PROFILE in config.env           default
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
cd "$ROOT"

if [ ! -f config.env ]; then
    if [ -f config.env.example ]; then
        echo "no config.env -- copy config.env.example and edit the paths:" >&2
        echo "    cp config.env.example config.env" >&2
    fi
    exit 1
fi
# shellcheck disable=SC1091
. ./config.env

PROFILE="${PROFILE:-${DEFAULT_PROFILE:-full}}"
if [ -f "profiles/$PROFILE.env" ]; then
    # shellcheck disable=SC1090
    . "profiles/$PROFILE.env"
else
    echo "unknown profile '$PROFILE' (have: $(ls profiles/*.env 2>/dev/null | xargs -n1 basename 2>/dev/null | sed 's/\.env$//' | tr '\n' ' '))" >&2
    exit 1
fi

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
export TARGET_MACHINE TARGET_PID STOCK_TGZ

WORK="${WORK:-work}"
