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

WORK="${WORK:-work}"
