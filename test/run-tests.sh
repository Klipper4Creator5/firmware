#!/usr/bin/env bash
# Full suite, in two halves.
#
#   1. Static and packaging checks. No proprietary firmware needed: a
#      synthetic fixture stands in for the stock package. These run on every
#      pull request.
#
#   2. The printer replica. The real rootfs.squashfs is extracted from the
#      stock package and chrooted under qemu-mipsel, so the installer runs on
#      the printer's own busybox, tar, md5sum and unTar. This is the half that
#      can actually tell you whether a package bricks a machine, and it needs
#      the stock FlashForge package to exist.
#
#   ./test/run-tests.sh                       runs half 2 if a stock package is configured
#   REQUIRE_PRINTER_SIM=1 ./test/run-tests.sh fails instead of skipping it
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PASS=0; FAIL=0
# Every section carries the elapsed time. The suite is mostly waiting on qemu
# and xz, and without a clock in the output it is guesswork which.
T0=$(date +%s)
hdr()  { printf '\n\033[1m== %s ==\033[0m \033[90m[%ss]\033[0m\n' "$*" "$(( $(date +%s) - T0 ))"; }
pass() { printf '  \033[32mok\033[0m   %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
run()  { if "$@" >/tmp/c5t.$$ 2>&1; then pass "$*"; else fail "$*"; tail -25 /tmp/c5t.$$ | sed 's/^/       /'; fi; rm -f /tmp/c5t.$$; }
sub()  { local name="$1"; shift
         if "$@" 2>&1 | sed 's/^/  /'; then pass "$name"; else fail "$name"; fi; }

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
         test/*.sh test/printer/*.sh test/fixtures/*.sh; do
    [ -f "$f" ] || continue
    bash -n "$f" 2>/dev/null || { SYNTAX_BAD="$SYNTAX_BAD $f"; bash -n "$f" 2>&1 | sed 's/^/       /'; }
done
[ -z "$SYNTAX_BAD" ] && pass "every script parses" || fail "syntax errors in:$SYNTAX_BAD"

hdr "no bashisms in the on-printer payload"
# This is a cheap heuristic that runs without the firmware. The real check is
# test-ash-conformance.sh, which parses these files with the printer's own
# busybox -- but that needs the proprietary rootfs, so on a plain pull request
# this grep is all there is.
#
# `local` is NOT listed: busybox ash supports it and the payload uses it.
BASHISM_BAD=""
for f in payload/*.sh payload/init.d/S* payload/firmwareExe; do
    [ -f "$f" ] || continue
    if grep -nE '\[\[|<<<|\bfunction [a-z]|\$\{[A-Za-z_]+\[|declare |\bsource ' "$f" >/dev/null 2>&1; then
        BASHISM_BAD="$BASHISM_BAD $f"
        grep -nE '\[\[|<<<|\bfunction [a-z]|\$\{[A-Za-z_]+\[|declare |\bsource ' "$f" | head -3 | sed 's/^/       /'
    fi
done
[ -z "$BASHISM_BAD" ] && pass "no bash-only constructs in the payload" \
                      || fail "bashisms in:$BASHISM_BAD"

hdr "brick-risk lint"
sub "lint-danger" ./test/lint-danger.sh payload payload/init.d

# ================================================== packaging, on a fixture ==
hdr "synthetic stock package"
# The fixture must live INSIDE the repo: the simulations start sibling
# containers through the docker socket, and those mounts are resolved by the
# host daemon, where a path under this container's /tmp does not exist.
FXDIR="$ROOT/work/.fixture"
run ./test/fixtures/make-stock-fixture.sh "$FXDIR"
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
TOOLCHANGE=""
HELIX_TGZ="$FXASSETS/helixscreen.tar.gz"
MAINSAIL_ZIP="$FXASSETS/mainsail.zip"
BUSYBOX_BIN=""
DEFAULT_PROFILE=probe
TARGET_MACHINE=Creator5Pro
MOD_UI=stock
ROOT_PW_HASH='\$6\$ci\$abcdefghijklmnopqrstuvwxyz'
FF_KEY='FFP0331&*%root'
CFG
export CONFIG_ENV="$FIXTURE_CFG"

for PROF in probe default; do
    hdr "profile: $PROF"
    export PROFILE="$PROF"
    run ./bin/unpack.sh
    run ./bin/patch.sh
    run ./bin/pack.sh
    PKG=$(ls -1 work/out/Creator5Pro-*.tgz 2>/dev/null | head -n1)
    if [ -n "$PKG" ]; then run ./bin/verify.sh "$PKG"; else fail "no package produced for $PROF"; fi
done

hdr "the probe profile must change nothing"
export PROFILE=probe
./bin/unpack.sh >/dev/null 2>&1
cp -r work/software "$TMP/sw-before"
./bin/patch.sh >/dev/null 2>&1
DIFF=$(diff -rq "$TMP/sw-before" work/software 2>&1 | grep -vE 'run\.sh|md5sum\.list' || true)
if [ -z "$DIFF" ]; then pass "probe touches only run.sh (adds the report step)"
else fail "probe modified more than run.sh"; echo "$DIFF" | sed 's/^/       /'; fi

hdr "model gates"
sub "model gate" ./test/test-model-gate.sh

# ============================================================ the replica ====
# Back to the real config for the replica half: it needs the actual stock
# package, which no fixture can stand in for.
unset CONFIG_ENV PROFILE TARGET_MACHINE

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
        printf '  \033[33mskipped\033[0m -- no stock package in config.env.\n'
        printf '  These are the tests that decide whether a package bricks a printer.\n'
        printf '  Set STOCK_TGZ_CREATOR5PRO in config.env and re-run.\n'
    fi
else
    hdr "extracting the printer rootfs"
    if [ -d work/rootfs/bin ]; then pass "rootfs already extracted"
    else
        run ./bin/unpack.sh
        run ./test/extract-rootfs.sh
    fi

    if [ -d work/rootfs/bin ]; then
        hdr "commands the payload uses exist on the printer"
        sub "applets" python3 ./test/test-applets.py

        hdr "busybox ash conformance (printer's own shell)"
        sub "ash conformance" ./test/test-ash-conformance.sh

        hdr "MIPS ABI"
        sub "abi" ./test/test-abi.sh

        hdr "UI selection and fallback (on the printer's shell)"
        sub "ui fallback" ./test/sim-ui-fallback.sh

        for PROF in probe default; do
            hdr "end-to-end update on the printer replica: $PROF"
            export PROFILE="$PROF"
            run ./bin/unpack.sh
            run ./bin/patch.sh
            run ./bin/pack.sh
            P=$(ls -1 work/out/*-*.tgz 2>/dev/null | head -n1)
            if [ -n "$P" ]; then sub "boot -> install -> re-install -> boot ($PROF)" ./test/sim-install.sh "$P"
            else fail "no package produced for $PROF"; fi
        done

        hdr "recovery: a stock package reverts the mod"
        P=$(ls -1 work/out/*-*.tgz 2>/dev/null | head -n1)
        sub "install mod -> flash stock -> back to stock" ./test/sim-roundtrip.sh "$P" "$STOCK"
    else
        fail "could not extract the printer rootfs from $STOCK"
    fi
fi

printf '\n\033[1m%d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
