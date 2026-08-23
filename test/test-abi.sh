#!/usr/bin/env bash
# Every binary we ship must be MIPS32r2 / o32 / nan2008, because the Ingenic
# X2000 kernel returns ENOEXEC for legacy-NaN executables. A wrong-ABI binary
# is not a warning on this printer -- it simply will not run.
#
# This reads the ELF header flags. It used to also try executing each binary
# under qemu-mipsel and call that a second level of checking, but the test was
# `qemu "$f" -h || [ $? -lt 126 ]` -- which accepts almost every exit status
# and so could only fail if qemu itself was missing. Running the binaries for
# real is what the printer replica does; see test/sim-install.sh.
#
#   ./test/test-abi.sh [dir|file]...
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
FAIL=0; CHECKED=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAIL=1; }
note() { printf '  \033[90m....\033[0m  %s\n' "$*"; }

TARGETS=("$@")
if [ ${#TARGETS[@]} -eq 0 ]; then
    TARGETS=()
    [ -d assets/mips ] && TARGETS+=(assets/mips)
    [ -d assets/dropbear ] && TARGETS+=(assets/dropbear)
    [ -f config.env ] && . ./config.env 2>/dev/null
    [ -n "${KLIPPER_FORK:-}" ] && [ -f "$KLIPPER_FORK/klippy/chelper/c_helper.so" ] \
        && TARGETS+=("$KLIPPER_FORK/klippy/chelper/c_helper.so")
    [ -d work/modpayload ] && TARGETS+=(work/modpayload)
fi
if [ ${#TARGETS[@]} -eq 0 ]; then
    echo "  SKIP: no MIPS binaries available to check"
    echo "        (they are built artifacts, never committed -- see docs)"
    exit 0
fi

command -v readelf >/dev/null 2>&1 || { echo "  SKIP: readelf not installed (binutils)"; exit 0; }

FILES=$(find "${TARGETS[@]}" -type f 2>/dev/null | while read -r f; do
    head -c 4 "$f" 2>/dev/null | grep -q $'\x7fELF' && echo "$f"
done)
[ -n "$FILES" ] || { echo "  SKIP: no ELF files found in ${TARGETS[*]}"; exit 0; }

echo "checking ELF ABI of $(echo "$FILES" | wc -l) binaries"
while IFS= read -r f; do
    [ -n "$f" ] || continue
    CHECKED=$((CHECKED+1))
    H=$(readelf -h "$f" 2>/dev/null)
    FLAGS=$(echo "$H" | sed -n 's/.*Flags: *//p')
    MACH=$(echo "$H" | sed -n 's/.*Machine: *//p')
    case "$MACH" in
        *MIPS*) ;;
        *) note "$(basename "$f"): not MIPS ($MACH) -- skipped"; continue ;;
    esac
    echo "$FLAGS" | grep -q 'nan2008' \
        && ok "$(basename "$f"): nan2008" \
        || bad "$(basename "$f"): legacy NaN -- kernel returns ENOEXEC. Flags: $FLAGS"
    echo "$FLAGS" | grep -q 'mips32r2' \
        && ok "$(basename "$f"): mips32r2" \
        || bad "$(basename "$f"): not mips32r2. Flags: $FLAGS"
    echo "$FLAGS" | grep -q 'o32' \
        || bad "$(basename "$f"): not o32 ABI. Flags: $FLAGS"
done <<< "$FILES"

echo
[ "$FAIL" = 0 ] && echo "  ABI checks passed ($CHECKED binaries)" || echo "  ABI CHECKS FAILED"
exit $FAIL
