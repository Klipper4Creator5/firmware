#!/usr/bin/env bash
# Scan every script that will RUN ON THE PRINTER for operations that could
# brick it. This is a static gate: it runs before anything is packed.
#
#   ./test/lint-danger.sh <dir-of-scripts>...
set -uo pipefail
FAIL=0
bad()  { printf '  \033[31mDANGER\033[0m %s\n          %s\n' "$1" "$2"; FAIL=1; }
warn() { printf '  \033[33mWARN\033[0m   %s\n          %s\n' "$1" "$2"; }
ok()   { printf '  \033[32mOK\033[0m     %s\n' "$1"; }

TARGETS=("$@")
[ ${#TARGETS[@]} -gt 0 ] || TARGETS=(payload bin/../payload)

FILES=$(find "${TARGETS[@]}" -type f \( -name '*.sh' -o -name 'run.sh' \) 2>/dev/null | sort -u)
[ -n "$FILES" ] || { echo "no scripts found in ${TARGETS[*]}"; exit 1; }

echo "scanning $(echo "$FILES" | wc -l) script(s) for brick risks"
echo

# --- things that destroy the device outright --------------------------------
while IFS= read -r f; do
    # Writing to raw block devices / MTD / bootloader
    if grep -nE '(^|[^#])(dd[[:space:]]+.*of=/dev/(mmcblk|mtd|sd)|mkfs|fdisk[[:space:]]+[^-]|flash_erase|nandwrite)' "$f" >/dev/null; then
        bad "$f" "writes to a raw block device / formats a partition"
        grep -nE 'dd[[:space:]]+.*of=/dev/|mkfs|flash_erase|nandwrite' "$f" | head -3 | sed 's/^/            /'
    fi
    # rm -rf on a root-level path
    if grep -nE 'rm[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*(/|/usr|/usr/prog|/etc|/bin|/lib|/usr/data)[[:space:]]*($|[;&])' "$f" >/dev/null; then
        bad "$f" "rm -rf of a top-level directory"
        grep -nE 'rm[[:space:]]+-[a-zA-Z]*[[:space:]]*(/|/usr|/etc)[[:space:]]*($|[;&])' "$f" | head -3 | sed 's/^/            /'
    fi
    # Unquoted rm with a variable that could be empty -> "rm -rf /"
    if grep -nE 'rm[[:space:]]+-[a-zA-Z]*r[a-zA-Z]*[[:space:]]+\$[A-Za-z_]+/' "$f" >/dev/null \
       && ! grep -qE 'refusing to run|:\?|\[ -n "\$[A-Za-z_]+" \]' "$f"; then
        warn "$f" "rm -rf \$VAR/... -- if VAR is empty this becomes rm -rf /..."
        grep -nE 'rm[[:space:]]+-[a-zA-Z]*r[a-zA-Z]*[[:space:]]+\$[A-Za-z_]+/' "$f" | head -3 | sed 's/^/            /'
    fi
    # Replacing the init/boot chain without restoring a UI
    if grep -q 'app_startup.sh' "$f" && ! grep -qE 'firmwareExe|boot\.sh|helix' "$f"; then
        warn "$f" "touches app_startup.sh but never mentions a UI launcher"
    fi
done <<< "$FILES"

# --- the boot chain must always end with something on screen ----------------
if [ -f payload/boot.sh ]; then
    if grep -q 'firmwareExe' payload/boot.sh; then
        ok "boot.sh falls back to the stock UI"
    else
        bad "payload/boot.sh" "no stock-UI fallback -- a missing HelixScreen means a blank screen"
    fi
    if grep -qE 'exit[[:space:]]+1|set -e' payload/boot.sh; then
        warn "payload/boot.sh" "an early exit here can leave the printer with no UI"
    fi
fi

# --- the installer must not hard-fail into a boot loop ----------------------
for f in payload/run-append.sh payload/report.sh; do
    [ -f "$f" ] || continue
    if grep -qE '^[[:space:]]*set -e' "$f"; then
        bad "$f" "'set -e' in an installer fragment aborts run.sh mid-way, leaving a half-installed system"
    else
        ok "$f has no bare 'set -e'"
    fi
done

# --- every stock file we replace must be backed up first --------------------
if [ -f payload/run-append.sh ]; then
    for target in app_startup.sh start.sh passwd shadow; do
        if grep -q "$target" payload/run-append.sh; then
            grep -q 'BACKUP' payload/run-append.sh \
                && ok "backup step present before replacing $target" \
                || bad "payload/run-append.sh" "replaces $target with no backup"
        fi
    done
fi

echo
[ "$FAIL" = 0 ] && echo "no brick risks found" || echo "BRICK RISKS FOUND"
exit $FAIL
