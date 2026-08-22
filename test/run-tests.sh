#!/usr/bin/env bash
# Full suite. Runs on a clean machine and in GitHub Actions with NO
# proprietary firmware: a synthetic fixture stands in for the stock package.
#
#   ./test/run-tests.sh                            fixture-based (what CI runs)
#   REAL_PKG=/path/to/stock ./test/run-tests.sh    also exercise the real package
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PASS=0; FAIL=0
hdr()  { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
pass() { printf '  \033[32mok\033[0m   %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
run()  { if "$@" >/tmp/c5t.$$ 2>&1; then pass "$*"; else fail "$*"; tail -25 /tmp/c5t.$$ | sed 's/^/       /'; fi; rm -f /tmp/c5t.$$; }
# For sub-suites that print their own PASS/FAIL lines, show them inline.
sub()  { local name="$1"; shift
         if "$@" 2>&1 | sed 's/^/  /'; then pass "$name"; else fail "$name"; fi; }

TMP=$(mktemp -d)
SAVED=""
[ -f config.env ] && { SAVED="$TMP/config.env.saved"; cp config.env "$SAVED"; }
cleanup() { [ -n "$SAVED" ] && cp "$SAVED" config.env 2>/dev/null || rm -f config.env; rm -rf "$TMP"; }
trap cleanup EXIT

hdr "shell syntax"
for f in bin/*.sh payload/*.sh payload/init.d/S* payload/firmwareExe test/*.sh test/fixtures/*.sh; do
    [ -f "$f" ] || continue
    if bash -n "$f" 2>/dev/null; then pass "syntax $f"; else fail "syntax $f"; bash -n "$f" 2>&1 | sed 's/^/       /'; fi
done

hdr "payload runs under busybox ash -- POSIX sh only, no bashisms"
for f in payload/*.sh payload/init.d/S* payload/firmwareExe; do
    [ -f "$f" ] || continue
    if sh -n "$f" 2>/dev/null; then pass "posix $f"; else fail "posix $f"; fi
    if grep -nE '\[\[|<<<|\bfunction [a-z]|\$\{[A-Za-z_]+\[|declare |local ' "$f" >/dev/null 2>&1; then
        fail "bashism in $f"; grep -nE '\[\[|<<<|\bfunction [a-z]|declare ' "$f" | head -3 | sed 's/^/       /'
    else pass "no bashisms in $f"; fi
done

hdr "brick-risk lint"
sub "lint-danger" ./test/lint-danger.sh payload payload/init.d

hdr "synthetic stock package"
run ./test/fixtures/make-stock-fixture.sh "$TMP/fx"
FIXTURE="$TMP/fx/Creator5Pro-stock-fixture.tgz"
[ -f "$FIXTURE" ] || { echo "no fixture -- aborting"; exit 1; }

cat > config.env <<CFG
MOD_NAME=anvil
MOD_VER=ci
SW_VER=""
STOCK_TGZ="$FIXTURE"
KLIPPER_FORK=""
TOOLCHANGE=""
HELIX_TGZ=""
MAINSAIL_ZIP=""
BUSYBOX_BIN=""
DEFAULT_PROFILE=probe
MOD_UI=stock
ROOT_PW_HASH='\$6\$ci\$abcdefghijklmnopqrstuvwxyz'
FF_KEY='FFP0331&*%root'
CFG

for PROF in probe ssh web full helix; do
    hdr "profile: $PROF"
    export PROFILE="$PROF"
    run ./bin/unpack.sh
    run ./bin/patch.sh
    run ./bin/pack.sh
    PKG=$(ls -1 work/out/Creator5Pro-*.tgz 2>/dev/null | grep -v uninstall | head -n1)
    if [ -n "$PKG" ]; then
        run ./bin/verify.sh "$PKG"
        sub "install simulation ($PROF)" ./test/sim-install.sh "$PKG"
    else
        fail "no package produced for $PROF"
    fi
done

hdr "the probe profile must change nothing"
export PROFILE=probe
./bin/unpack.sh >/dev/null 2>&1
cp -r work/software "$TMP/sw-before"
./bin/patch.sh >/dev/null 2>&1
DIFF=$(diff -rq "$TMP/sw-before" work/software 2>&1 | grep -vE 'run\.sh|md5sum\.list' || true)
if [ -z "$DIFF" ]; then pass "probe touches only run.sh (adds the report step)"
else fail "probe modified more than run.sh"; echo "$DIFF" | sed 's/^/       /'; fi

hdr "uninstall round trip"
export PROFILE=full
run ./bin/unpack.sh
run ./bin/patch.sh
run ./bin/pack.sh
MODPKG=$(ls -1 work/out/Creator5Pro-*.tgz | grep -v uninstall | head -n1)
run ./bin/make-uninstall.sh
UNI=work/out/Creator5Pro-uninstall.tgz
run ./bin/verify.sh "$UNI"
sub "install -> uninstall -> stock" ./test/sim-roundtrip.sh "$MODPKG" "$UNI"

hdr "UI selection and fallback"
sub "ui fallback" ./test/sim-ui-fallback.sh

hdr "busybox ash conformance (printer's own shell)"
sub "ash conformance" ./test/test-ash-conformance.sh

hdr "MIPS ABI"
sub "abi" ./test/test-abi.sh

if [ -n "${REAL_PKG:-}" ] && [ -f "$REAL_PKG" ]; then
    hdr "REAL stock package"
    cleanup_saved="$SAVED"; [ -n "$cleanup_saved" ] && cp "$cleanup_saved" config.env
    export PROFILE="${REAL_PROFILE:-probe}"
    run ./bin/unpack.sh
    run ./bin/patch.sh
    run ./bin/pack.sh --slim
    P=$(ls -1 work/out/Creator5Pro-*.tgz | grep -v uninstall | head -n1)
    run ./bin/verify.sh "$P"
    sub "install simulation (real)" ./test/sim-install.sh "$P"
fi

printf '\n\033[1m%d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
