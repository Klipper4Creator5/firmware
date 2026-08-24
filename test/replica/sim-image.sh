# Sourced by every replica launcher. One place for the config and the docker
# plumbing they used to duplicate. Needs $ROOT set; leaves $DOCKER, $IMAGE and
# $PREBUILT defined, and the config files loaded.
#
#   config     config.env is the BUILD config -- needed here only for FF_KEY
#              and the stock packages the replica installs as its baseline.
#              test.env holds what exists ONLY for the tests and never reaches
#              a printer: the factory image and the partition sizes. Keeping
#              them apart is the point -- nothing in test.env can end up in a
#              package. Values still set in config.env keep working, since it
#              is loaded first.
#
#              THE ENVIRONMENT WINS OVER BOTH FILES. `PRINTER_IMAGE=` sitting
#              empty in test.env used to overwrite an explicit
#              `PRINTER_IMAGE=foo ./test/replica/sim-install.sh ...`, so the override
#              silently did nothing and the run tested a different image than
#              the one that was named.
#
#   skip()     A skip here is a test that did not run. That is fine on a
#              laptop and fatal in a release, so REQUIRE_PRINTER_SIM=1 turns
#              every skip into a failure -- for EVERY launcher, not just the
#              install simulation.
#   IMAGE      PRINTER_IMAGE names a prebuilt image that already carries the
#              firmware (rootfs, /usr/prog, /usr/data -- see
#              test/replica/build-printer-image.sh); PREBUILT=1 then. Otherwise the
#              local sim image is built from test/replica/printer/Dockerfile, which
#              needs the extracted rootfs at work/rootfs.

skip() {
    if [ "${REQUIRE_PRINTER_SIM:-0}" = 1 ]; then echo "  FAIL: $*" >&2; exit 1; fi
    echo "  SKIP: $*"; exit 0
}

# An empty string in the environment is still a decision, so remember anything
# that was set AT ALL -- not just anything that was non-empty -- and put it
# back after the files have been read.
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

[ -n "${_HAD_PRINTER_IMAGE:-}" ] && PRINTER_IMAGE="$_SAVE_PRINTER_IMAGE"
[ -n "${_HAD_PROG_DUMP:-}" ]     && PROG_DUMP="$_SAVE_PROG_DUMP"
[ -n "${_HAD_PROG_MB:-}" ]       && PROG_MB="$_SAVE_PROG_MB"
[ -n "${_HAD_DATA_MB:-}" ]       && DATA_MB="$_SAVE_DATA_MB"
[ -n "${_HAD_FF_KEY:-}" ]        && FF_KEY="$_SAVE_FF_KEY"
unset _SAVE_PRINTER_IMAGE _SAVE_PROG_DUMP _SAVE_PROG_MB _SAVE_DATA_MB _SAVE_FF_KEY
unset _HAD_PRINTER_IMAGE _HAD_PROG_DUMP _HAD_PROG_MB _HAD_DATA_MB _HAD_FF_KEY

export PRINTER_IMAGE="${PRINTER_IMAGE:-}" PROG_DUMP="${PROG_DUMP:-}" \
       PROG_MB="${PROG_MB:-}" DATA_MB="${DATA_MB:-}"

DOCKER=docker
command -v docker >/dev/null 2>&1 || DOCKER=docker.exe
command -v $DOCKER >/dev/null 2>&1 || skip "docker not available"
$DOCKER info >/dev/null 2>&1 || skip "docker daemon not running"

IMAGE="${PRINTER_IMAGE:-}"
PREBUILT=1
if [ -z "$IMAGE" ]; then
    PREBUILT=0
    IMAGE=creator5-printer-sim
    if [ ! -d "$ROOT/work/rootfs/bin" ]; then
        skip "no printer rootfs -- run 'make rootfs' first (needs the stock package),
        or set PRINTER_IMAGE to a prebuilt printer image"
    fi
    # Always rebuild: it is a cache hit in about a second, and a stale image
    # silently testing yesterday's harness is not a trade worth making.
    $DOCKER build -q -t "$IMAGE" -f "$ROOT/test/replica/printer/Dockerfile" "$ROOT/test/printer" >/dev/null \
        || { echo "  FAIL: could not build $IMAGE"; exit 1; }
fi
