# Sourced by every script in bin/. Resolves the repo root, loads config.env
# and exports the feature flags.
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

# WHAT GOES INTO THE PACKAGE. There is exactly one build -- the firmware:
# forked Klipper with toolchanger support, Mainsail/Moonraker, ssh, and
# HelixScreen driving the touchscreen in place of FlashForge's UI.
#
# These used to live in profiles/*.env, chosen by a PROFILE variable, back
# when a second "changes nothing, writes a report" package existed alongside
# this one. With one build left the indirection bought nothing but a layer to
# read through, so the flags are plain defaults here and config.env -- sourced
# above -- still overrides any of them.
#
# FlashForge's firmwareExe is REPLACED, not kept: HelixScreen is the only UI.
# If it will not start, set MOD_UI=0 in /usr/data/anvil/anvil.conf to boot
# headless. ssh and Mainsail are your recovery path if the screen is dark, and
# a USB stick with the STOCK FlashForge package on it is the uninstall (proven
# by `make test-recovery`).
BUILD_KLIPPER="${BUILD_KLIPPER:-fork}"
BUILD_TOOLCHANGE="${BUILD_TOOLCHANGE:-1}"
BUILD_MAINSAIL="${BUILD_MAINSAIL:-1}"
BUILD_MOONRAKER="${BUILD_MOONRAKER:-1}"
BUILD_HELIX="${BUILD_HELIX:-1}"
MOD_SSH="${MOD_SSH:-1}"
MOD_WEB="${MOD_WEB:-1}"
MOD_UI="${MOD_UI:-1}"

# Third-party payload pieces (Mainsail, HelixScreen, Moonraker). They are
# downloaded on demand rather than vendored, so the repo carries no binaries
# and no binary history. versions.env pins the version and the sha256;
# bin/fetch-assets.sh puts the file in vendor/. Point MAINSAIL_ZIP /
# HELIX_TGZ / MOONRAKER_TGZ at your own build in config.env to override --
# but an explicit path is checksummed like any other, and fetch-assets.sh
# overwrites it with the pinned release when the hash does not match. Put
# your file's own sha256 in versions.env to keep it.
# shellcheck disable=SC1091
[ -f "$ROOT/versions.env" ] && . "$ROOT/versions.env"
MAINSAIL_ZIP="${MAINSAIL_ZIP:-$ROOT/vendor/mainsail-${MAINSAIL_VERSION:-unpinned}.zip}"
HELIX_TGZ="${HELIX_TGZ:-$ROOT/vendor/${HELIX_FILE:-helixscreen.tar.gz}}"
MOONRAKER_TGZ="${MOONRAKER_TGZ:-$ROOT/vendor/moonraker-${MOONRAKER_VERSION:-unpinned}.tar.gz}"
export MAINSAIL_ZIP HELIX_TGZ MOONRAKER_TGZ

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
