#!/usr/bin/env bash
# Model-gate regression test.
#
# The two models are NOT interchangeable: Creator5 and Creator5Pro ship
# different firmwareExe binaries, and each package's runFirmwareExe.sh carries
# a MACHINE=/PID= gate that refuses to install on the other one. An earlier
# version of pack.sh emitted BOTH filenames from a single build, which would
# have handed one model the other's firmware.
#
# Asserts, for every package in dist/ (or work/out):
#   * the filename prefix matches the gate inside
#   * a Pro package and a non-Pro package are not the same file
#   * each carries the firmwareExe from its own stock package
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
KEY="${FF_KEY:-FFP0331&*%root}"
FAIL=0
ok()  { printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAIL=1; }

DIR=dist; [ -d "$DIR" ] && [ -n "$(ls -1 "$DIR"/*.tgz 2>/dev/null)" ] || DIR=work/out
PKGS=$(ls -1 "$DIR"/Creator5*-*.tgz 2>/dev/null || true)
[ -n "$PKGS" ] || { echo "  SKIP: no packages (run 'make release')"; exit 0; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
declare -A FEMD5

while IFS= read -r p; do
    [ -n "$p" ] || continue
    b=$(basename "$p")
    case "$b" in
        Creator5Pro-*) want=Creator5Pro ;;
        Creator5-*)    want=Creator5 ;;
        *) bad "$b: filename matches no model glob"; continue ;;
    esac
    d="$T/$want"; mkdir -p "$d/sw"
    openssl des3 -d -k "$KEY" -salt -md md5 -in "$p" 2>/dev/null | tar -xf - -C "$d" || {
        bad "$b: cannot decrypt"; continue; }
    gate=$(sed -n 's/^MACHINE=//p' "$d/runFirmwareExe.sh" 2>/dev/null | head -1)
    pid=$(sed -n 's/^PID=//p' "$d/runFirmwareExe.sh" 2>/dev/null | head -1)

    if [ "$gate" = "$want" ]; then
        ok "$b: filename prefix matches the gate inside ($gate/$pid)"
    else
        bad "$b: filename says $want but the gate says '$gate' -- the printer would pick it up and refuse it"
    fi
    case "$want/$pid" in
        Creator5Pro/0029|Creator5/0028) ok "$b: PID matches the model" ;;
        *) bad "$b: PID '$pid' is wrong for $want" ;;
    esac

    tar -xf "$d"/software-*.tar.xz -C "$d/sw" 2>/dev/null
    if [ -f "$d/sw/firmwareExe" ]; then
        # The wrapper is installed as firmwareExe; the genuine per-model
        # binary must be alongside it.
        real="$d/sw/firmwareExe.stock"
        [ -f "$real" ] || real="$d/sw/firmwareExe"
        FEMD5[$want]=$(md5sum "$real" | cut -d' ' -f1)
        ok "$b: carries a firmwareExe (${FEMD5[$want]:0:12})"
    else
        bad "$b: no firmwareExe in the software component"
    fi
done <<< "$PKGS"

if [ -n "${FEMD5[Creator5Pro]:-}" ] && [ -n "${FEMD5[Creator5]:-}" ]; then
    if [ "${FEMD5[Creator5Pro]}" = "${FEMD5[Creator5]}" ]; then
        bad "both models ship the SAME firmwareExe -- one of them got the wrong firmware"
    else
        ok "the two models ship different firmwareExe binaries (as they must)"
    fi
else
    echo "  ....  only one model built; run 'make release' to check both"
fi

echo
[ "$FAIL" = 0 ] && echo "  model gates are correct" || echo "  MODEL GATE TEST FAILED"
exit $FAIL
