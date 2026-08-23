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

# firmwareExe and the init.d/S* scripts have no .sh suffix, and an earlier
# version of this glob therefore never scanned them -- the UI wrapper and every
# service script went unchecked. They run on the printer, so they are scanned.
FILES=$(find "${TARGETS[@]}" -type f \
            \( -name '*.sh' -o -name 'run.sh' -o -name 'firmwareExe' \
               -o -name 'S[0-9][0-9]*' \) 2>/dev/null | sort -u)
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
    # Only MODIFYING app_startup.sh is a risk; report.sh merely cats it.
    if grep -nE '(cp|mv|install|tee|sed[[:space:]]+-i|>>?[[:space:]]*)[^|;]*app_startup\.sh' "$f" >/dev/null \
       && ! grep -qE 'firmwareExe|helix' "$f"; then
        warn "$f" "modifies app_startup.sh but never mentions a UI launcher"
    fi
done <<< "$FILES"

# --- the boot chain must always end with something on screen ----------------
# This used to be guarded on `[ -f payload/boot.sh ]`. boot.sh was replaced by
# the firmwareExe wrapper long ago, so the guard was false and the whole check
# silently passed on every run. It is now pinned to the files that exist, and
# their absence is itself a failure.
UIW=payload/firmwareExe
if [ ! -f "$UIW" ]; then
    bad "payload/firmwareExe" "missing -- nothing replaces the stock UI binary"
else
    grep -q 'firmwareExe.stock' "$UIW" \
        && ok "firmwareExe falls back to the stock UI" \
        || bad "$UIW" "no stock-UI fallback -- a missing HelixScreen means a blank screen"
    grep -qE '^[[:space:]]*set -e' "$UIW" \
        && warn "$UIW" "an early exit here can leave the printer with no UI" \
        || ok "$UIW has no bare 'set -e'"
    # It must hold the foreground: app_startup.sh greps ps for firmwareExe and
    # re-execs us if we exit, which would restart every service underneath.
    # Matched on the loop, not on `sleep 3600`: the number is an arbitrary
    # detail and pinning the check to it turns a change of interval into a
    # brick warning.
    grep -qE 'while +(true|:) *(;| ) *do' "$UIW" \
        && ok "firmwareExe holds the process when the UI exits" \
        || bad "$UIW" "returns when the UI exits -- app_startup.sh restarts everything"
fi

UISEL=payload/init.d/S80ui
if [ ! -f "$UISEL" ]; then
    bad "payload/init.d/S80ui" "missing -- nothing chooses the UI or latches SAFE-MODE"
else
    grep -q 'SAFE-MODE' "$UISEL" \
        && ok "S80ui latches SAFE-MODE on a crash loop" \
        || bad "$UISEL" "no SAFE-MODE latch -- a crash-looping UI cannot be recovered"
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
# The backups moved to run-pre.sh, which runs at the TOP of run.sh while the
# files are still stock. This check used to read run-append.sh, where none of
# these names appear any more, so it matched nothing and reported nothing.
# app_startup.sh is deliberately absent: the mod replaces firmwareExe instead
# and never touches the stock boot scripts.
PRE=payload/run-pre.sh
if [ ! -f "$PRE" ]; then
    bad "payload/run-pre.sh" "missing -- the stock files are replaced with no backup"
else
    grep -q 'BACKUP' "$PRE" \
        && ok "run-pre.sh has a backup step" \
        || bad "$PRE" "no BACKUP step"
    for target in start.sh passwd shadow; do
        grep -q "$target" "$PRE" \
            && ok "backup covers $target" \
            || bad "$PRE" "$target is replaced but never backed up"
    done
    grep -q 'backup/stock' "$PRE" \
        && ok "pristine backup/stock kept from the first install" \
        || warn "$PRE" "no pristine copy -- a re-flash overwrites the only stock backup"
fi

echo
[ "$FAIL" = 0 ] && echo "no brick risks found" || echo "BRICK RISKS FOUND"
exit $FAIL
