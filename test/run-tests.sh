#!/usr/bin/env bash
# Full suite, in two halves.
#
#   1. test/unit -- static and packaging checks. Nothing proprietary needed:
#      a synthetic fixture stands in for the stock package. These run on every
#      pull request.
#
#   2. test/integration -- the printer replica. The real rootfs.squashfs is
#      extracted from the stock package and chrooted under qemu-mipsel, so the
#      installer runs on the printer's own busybox, tar, md5sum and unTar. This
#      is the half that can actually tell you whether a package bricks a
#      machine, and it needs the stock FlashForge package to exist.
#
#   The two halves are two directories: unit and integration. Everything
#   under test/unit runs against this checkout alone; everything under
#   test/integration needs the printer's real rootfs, and most of it also
#   needs the docker socket to start the replica as a sibling container. This
#   file is the only thing in test/ that spans both.
#
#   ./test/run-tests.sh                       runs the integration half when a
#                                             stock package is configured
#   REQUIRE_PRINTER_SIM=1 ./test/run-tests.sh fails instead of skipping it
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PASS=0; FAIL=0; SKIP=0
# Every section carries the elapsed time. The suite is mostly waiting on qemu
# and xz, and without a clock in the output it is guesswork which.
T0=$(date +%s)
hdr()  { printf '\n\033[1m== %s ==\033[0m \033[90m[%ss]\033[0m\n' "$*" "$(( $(date +%s) - T0 ))"; }
pass() { printf '  \033[32mok\033[0m   %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
skip() { printf '  \033[33mSKIP\033[0m %s\n' "$*"; SKIP=$((SKIP+1)); }
run()  { if "$@" >/tmp/c5t.$$ 2>&1; then pass "$*"; else fail "$*"; tail -25 /tmp/c5t.$$ | sed 's/^/       /'; fi; rm -f /tmp/c5t.$$; }

# A test that decides it cannot run exits 0 and says "SKIP:". This used to be
# reported as `ok`, so `test-abi.sh` sat in the suite for a long time printing
# green while checking nothing at all -- the wiring deleted work/modpayload
# immediately before it ran, and CI set KLIPPER_FORK="", so it had no targets
# on any run. Four gates now carry the whole suite; a gate that silently does
# not run is the one failure mode that must never look like success, so a skip
# is counted apart from a pass and the summary refuses to call the run clean.
sub()  { local name="$1"; shift
         local out="$TMP/sub.$$"
         if "$@" >"$out" 2>&1; then
             sed 's/^/  /' "$out"
             # Both dialects of "did not run": the shell launchers print
             # "SKIP:", pytest summarises "N skipped".
             if grep -qE '^[[:space:]]*SKIP:|[0-9]+ skipped' "$out"
             then skip "$name"; else pass "$name"; fi
         else
             sed 's/^/  /' "$out"; fail "$name"
         fi
         rm -f "$out"; }

TMP=$(mktemp -d)
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# The fixture half runs against a throwaway config passed through CONFIG_ENV.
# It used to overwrite ./config.env and copy it back afterwards, which put the
# config you edited one crashed run away from being replaced by a fixture one.
FIXTURE_CFG="$TMP/config.env"

# ============================================================ static checks ==
# One line per check, not one per file: 25 green lines saying "syntax ok" hide
# the two that matter.
hdr "shell syntax"
SYNTAX_BAD=""
for f in bin/*.sh payload/*.sh payload/init.d/S* payload/firmwareExe \
         test/*.sh test/unit/*.sh test/integration/*.sh \
         test/integration/printer/*.sh; do
    [ -f "$f" ] || continue
    bash -n "$f" 2>/dev/null || { SYNTAX_BAD="$SYNTAX_BAD $f"; bash -n "$f" 2>&1 | sed 's/^/       /'; }
done
[ -z "$SYNTAX_BAD" ] && pass "every script parses" || fail "syntax errors in:$SYNTAX_BAD"

hdr "no bashisms in the on-printer payload"
# The dash dialect of shellcheck knows every "not supported in POSIX sh"
# construct (the SC3xxx family). dash, not sh: busybox ash, like dash,
# supports `local`, which the payload uses.
#
# This is now the only syntax gate that runs without the firmware.
# test-ash-conformance.sh used to parse the same files with the printer's own
# busybox, but case-install.sh already runs `sh -n` over every installed
# script with that same qemu'd busybox and greps the boot log for
# "Syntax error", so it was the weaker copy of a check that survives.
if command -v shellcheck >/dev/null 2>&1; then
    BASHISMS=$(shellcheck -s dash -f gcc payload/*.sh payload/init.d/S* payload/firmwareExe 2>&1 \
                   | grep -E 'SC3[0-9]{3}|SC2039' || true)
    [ -z "$BASHISMS" ] && pass "no bash-only constructs in the payload" \
                       || { fail "bashisms in the payload"
                            echo "$BASHISMS" | head -10 | sed 's/^/       /'; }
else
    fail "shellcheck not installed (the build image has it -- run through 'make test')"
fi

# The unit lane. Needs no firmware -- python3, jinja2 and the configs in the
# repo -- so it runs here, in the half that works on a plain pull request. It
# used to sit behind the rootfs extraction, which meant the one safety-relevant
# check in the suite (a chamber heater declared on a machine that has no
# element for it) never ran on a PR at all. The tests that need the printer's
# rootfs are in test/integration and are simply not named here, so a skip in this
# lane still means something went wrong rather than being the expected state.
hdr "python checks (klipper config)"
sub "pytest (unit)" python3 -m pytest ./test/unit -q

# ================================================== packaging, on a fixture ==
hdr "synthetic stock package"
# The fixture must live INSIDE the repo: the simulations start sibling
# containers through the docker socket, and those mounts are resolved by the
# host daemon, where a path under this container's /tmp does not exist.
FXDIR="$ROOT/work/.fixture"
run ./test/unit/make-stock-fixture.sh "$FXDIR"
FIXTURE="$FXDIR/Creator5Pro-stock-fixture.tgz"
export TARGET_MACHINE=Creator5Pro
[ -f "$FIXTURE" ] || { echo "no fixture -- aborting"; exit 1; }

# Stand-ins for Mainsail and HelixScreen. The real ones are a 3MB zip and a
# 60MB tarball downloaded into vendor/; the tests must not need the network,
# but they DO need the unpack paths in patch.sh to run, so point the build at
# two tiny archives with the same shape.
FXASSETS="$FXDIR/assets"
mkdir -p "$FXASSETS/ms" "$FXASSETS/hs/helixscreen/bin"
echo '<html>mainsail fixture</html>' > "$FXASSETS/ms/index.html"
# python3, not zip(1): the build image ships unzip but not zip.
python3 -c 'import sys,zipfile;z=zipfile.ZipFile(sys.argv[1],"w");z.write(sys.argv[2],"index.html");z.close()' \
    "$FXASSETS/mainsail.zip" "$FXASSETS/ms/index.html"
echo '#!/bin/sh' > "$FXASSETS/hs/helixscreen/bin/helix-screen"
chmod +x "$FXASSETS/hs/helixscreen/bin/helix-screen"
tar -czf "$FXASSETS/helixscreen.tar.gz" -C "$FXASSETS/hs" helixscreen

cat > "$FIXTURE_CFG" <<CFG
MOD_NAME=anvil
MOD_VER=ci
SW_VER=""
STOCK_TGZ="$FIXTURE"
KLIPPER_FORK=""
HELIX_TGZ="$FXASSETS/helixscreen.tar.gz"
MAINSAIL_ZIP="$FXASSETS/mainsail.zip"
BUSYBOX_BIN=""
TARGET_MACHINE=Creator5Pro
ROOT_PW_HASH='\$6\$ci\$abcdefghijklmnopqrstuvwxyz'
FF_KEY='FFP0331&*%root'
CFG
export CONFIG_ENV="$FIXTURE_CFG"

hdr "build on the fixture"
run ./bin/unpack.sh
run ./bin/patch.sh
run ./bin/pack.sh
PKG=$(ls -1 work/out/Creator5Pro-*.tgz 2>/dev/null | head -n1)
if [ -n "$PKG" ]; then run ./bin/verify.sh "$PKG"; else fail "no package produced"; fi

# The model gate used to get its own section here. bin/verify.sh above already
# compares MACHINE=/PID= inside the package against TARGET_MACHINE (§8b) and
# against the filename prefix (§9), and bin/pack.sh exits on MODEL MISMATCH
# before a package exists at all -- three checks of one invariant.

# ============================================================ the replica ====
# Back to the real config for the replica half: it needs the actual stock
# package, which no fixture can stand in for.
unset CONFIG_ENV TARGET_MACHINE

# Throw away everything the fixture half built. bin/ hardcodes work/, so those
# packages land in the same work/out that a real build uses -- and a 380KB
# `Creator5Pro-anvil-ci.tgz` sitting there is one `make test-install` away
# from being mistaken for something shippable. The replica half unpacks the
# real stock package from scratch anyway.
rm -rf work/out work/stage work/software work/outer work/modpayload

STOCK=""
if [ -f config.env ]; then
    # shellcheck disable=SC1091
    . ./config.env
    STOCK="${STOCK_TGZ_CREATOR5PRO:-${STOCK_TGZ:-}}"
fi

if [ -z "$STOCK" ] || [ ! -f "$STOCK" ]; then
    hdr "printer replica"
    if [ "${REQUIRE_PRINTER_SIM:-0}" = 1 ]; then
        fail "no stock package configured -- the replica tests cannot run, and this build requires them"
    else
        # Counted, not just narrated: three of the four gates live in here.
        skip "the printer replica (no stock package in config.env)"
        printf '  These are the gates that decide whether a package bricks a printer.\n'
        printf '  Set STOCK_TGZ_CREATOR5PRO in config.env and re-run.\n'
    fi
else
    hdr "extracting the printer rootfs"
    if [ -d work/rootfs/bin ]; then pass "rootfs already extracted"
    else
        run ./bin/unpack.sh
        run ./test/integration/extract-rootfs.sh
    fi

    if [ -d work/rootfs/bin ]; then
        # The rootfs exists now, so the integration lane can run.
        hdr "python checks against the printer rootfs"
        sub "pytest (integration)" python3 -m pytest ./test/integration -q

        hdr "MCU bring-up runs on the printer's own Python"
        sub "mcu bring-up" ./test/integration/printer-exec.sh ./test/integration/printer/case-mcu-bringup.sh

        hdr "end-to-end update on the printer replica"
        run ./bin/unpack.sh
        run ./bin/patch.sh
        run ./bin/pack.sh
        P=$(ls -1 work/out/*-*.tgz 2>/dev/null | head -n1)
        if [ -n "$P" ]; then sub "boot -> install -> re-install -> boot" ./test/integration/sim-install.sh "$P"
        else fail "no package produced"; fi

        hdr "recovery: a stock package reverts the mod"
        P=$(ls -1 work/out/*-*.tgz 2>/dev/null | head -n1)
        sub "install mod -> flash stock -> back to stock" ./test/integration/sim-roundtrip.sh "$P" "$STOCK"
    else
        fail "could not extract the printer rootfs from $STOCK"
    fi
fi

printf '\n\033[1m%d passed, %d failed, %d skipped\033[0m\n' "$PASS" "$FAIL" "$SKIP"

# A skip is a gate that did not run. With four gates carrying the suite that is
# not a detail to note in passing, so it is not silently forgiven: say what was
# skipped and how to make it stop. ALLOW_SKIP=1 accepts it deliberately, which
# is what a laptop without docker or without the stock package wants.
if [ "$SKIP" -gt 0 ] && [ "${ALLOW_SKIP:-0}" != 1 ]; then
    printf '\033[33m%d gate(s) did not run.\033[0m Set STOCK_TGZ_CREATOR5PRO in config.env\n' "$SKIP"
    printf 'and make docker available, or pass ALLOW_SKIP=1 to accept the gap.\n'
    exit 1
fi
[ "$FAIL" = 0 ]
