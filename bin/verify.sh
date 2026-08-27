#!/usr/bin/env bash
# Simulate every check the printer performs, against a built package.
#   ./bin/verify.sh                      verify work/out/Creator5Pro-*.tgz
#   ./bin/verify.sh path/to/pkg.tgz
set -uo pipefail
. "$(dirname "$0")/common.sh"

# Default to the package for the model currently selected, not a hardcoded
# one -- otherwise a two-model release verifies the same file twice.
PKG="${1:-$(ls -1 "work/out/${TARGET_MACHINE:-Creator5Pro}"-*.tgz 2>/dev/null | head -n1)}"
[ -f "${PKG:-}" ] || { echo "no package; run ./bin/pack.sh" >&2; exit 1; }
echo "verifying $PKG"; echo

FAIL=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAIL=1; }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$*"; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

# 1 ---------------------------------------------------------------- decrypt
if openssl des3 -d -k "$FF_KEY" -salt -md md5 -in "$PKG" 2>/dev/null \
     | tar -xf - -C "$WORK" 2>/dev/null; then
    ok "decrypts with the firmware key and is a valid tar"
else
    bad "decrypt/untar failed -- the printer's unTar will reject this"; exit 1
fi

# 2 ------------------------------------------------------- installer present
if [ -f "$WORK/runFirmwareExe.sh" ]; then
    ok "runFirmwareExe.sh present"
else
    bad "no runFirmwareExe.sh -- app_startup.sh falls back to plain tar and gives up"
fi

# 3 ----------------------------------------- components are PLAIN tar, not xz
for f in "$WORK"/software-*.tar.xz "$WORK"/kernel-*.tar.xz "$WORK"/control-*.tar.xz "$WORK"/library-*.tar.xz; do
    [ -f "$f" ] || continue
    b=$(basename "$f")
    if tar -tf "$f" >/dev/null 2>&1; then
        ok "$b is a plain tar (stock installer runs bare 'tar -xvf')"
    else
        bad "$b is not a plain tar -- stock 'tar -xvf' cannot read it"
    fi
done

# 4 ------------------------------------------------------------- md5sum gate
SOFTWARE_TAR=$(ls -1 "$WORK"/software-*.tar.xz 2>/dev/null | head -n1)
if [ -n "$SOFTWARE_TAR" ]; then
    mkdir -p "$WORK/sw" && tar -xf "$SOFTWARE_TAR" -C "$WORK/sw"
    if [ -f "$WORK/sw/md5sum.list" ]; then
        # NB: the printer's busybox md5sum takes -s for quiet; GNU coreutils
        # spells it --status. Use whichever this host has.
        if ( cd "$WORK/sw" && md5sum --status -c md5sum.list 2>/dev/null ) \
           || ( cd "$WORK/sw" && md5sum -s -c md5sum.list 2>/dev/null ); then
            ok "md5sum.list verifies ($(wc -l < "$WORK/sw/md5sum.list") entries)"
        else
            bad "md5sum.list does NOT verify -- installer aborts and deletes the payload"
            ( cd "$WORK/sw" && md5sum -c md5sum.list 2>&1 | grep -v ': OK$' | head -5 | sed 's/^/        /' )
        fi
        grep -q 'md5sum.list' "$WORK/sw/md5sum.list" && bad "md5sum.list lists itself (can never match)"
    else
        bad "no md5sum.list in the software component"
    fi
fi

# 5 -------------------------------------------------- shell syntax of scripts
for s in "$WORK/runFirmwareExe.sh" "$WORK/sw/run.sh" "$WORK/sw/start.sh" "$WORK/sw/app_startup.sh"; do
    [ -f "$s" ] || continue
    if sh -n "$s" 2>/dev/null; then ok "syntax OK: $(basename "$s")"
    else bad "SYNTAX ERROR in $(basename "$s")"; sh -n "$s" 2>&1 | head -3 | sed 's/^/        /'; fi
done

# 6 ---------------------------------------------- boot chain actually hooks up
if [ -f "$WORK/sw/app_startup.sh" ]; then
    grep -q 'gt9xx_touch.ko' "$WORK/sw/app_startup.sh" \
        && ok "touchscreen driver still loaded at boot" \
        || bad "gt9xx_touch.ko insmod missing -- no touchscreen"
    grep -q 'firmwareExe' "$WORK/sw/app_startup.sh" \
        && ok "a UI is launched at boot" \
        || bad "nothing launches a UI -- printer boots to a blank screen"
fi

# 7 ------------------------------------------------- MIPS ABI of any binaries
# A fork build that ships no fork is a broken package, not an optional check:
# the v20260824 release passed here precisely because everything below was
# conditional on files that the broken build simply did not contain.
if [ "${BUILD_KLIPPER:-fork}" = "fork" ]; then
    if [ -f "$WORK/sw/klipper/klippy/chelper/__init__.py" ]; then
        ok "package carries the fork klippy tree"
    else
        bad "BUILD_KLIPPER=fork but no klippy tree in the package -- this is the stock-overlay build that shipped as v20260824"
    fi
    [ -f "$WORK/sw/klipper/chelper.tar" ] \
        || bad "BUILD_KLIPPER=fork but no chelper.tar in the package"
fi
if [ -f "$WORK/sw/klipper/chelper.tar" ]; then
    mkdir -p "$WORK/ch" && tar -xf "$WORK/sw/klipper/chelper.tar" -C "$WORK/ch"
    CHELPER=$(find "$WORK/ch" -name 'c_helper.so' | head -n1)
    if [ -n "$CHELPER" ] && ! head -c 4 "$CHELPER" | grep -q ELF; then
        warn "c_helper.so is not an ELF (synthetic fixture) -- ABI check skipped"
        CHELPER=""
    fi
    if [ -n "$CHELPER" ]; then
        if readelf -h "$CHELPER" 2>/dev/null | grep -q nan2008; then
            ok "c_helper.so is nan2008 MIPS32r2 (kernel will load it)"
        else
            bad "c_helper.so is NOT nan2008 -- kernel returns ENOEXEC, klippy dies"
        fi
        # The failure mode that reached a printer: a .so from older sources
        # than the klippy tree beside it. cffi resolves lazily, so only a
        # symbol-table check catches it before the machine does.
        if [ -f "$WORK/sw/klipper/klippy/chelper/__init__.py" ]; then
            if python3 "$ROOT/test/test-chelper.py" "$WORK/sw/klipper" >/dev/null 2>&1; then
                ok "c_helper.so exports everything the shipped klippy declares"
            else
                bad "c_helper.so does not match the shipped klippy tree (stale build)"
            fi
        fi
    fi
fi

# 8 ------------------------------------------------------------ mod payload
if [ -f "$WORK/anvil.tar.xz" ]; then
    if xz -t "$WORK/anvil.tar.xz" 2>/dev/null; then ok "anvil.tar.xz is valid xz"
    elif tar -tf "$WORK/anvil.tar.xz" >/dev/null 2>&1; then ok "anvil.tar.xz is a plain tar"
    else bad "anvil.tar.xz is neither valid xz nor tar"; fi

    LIST=$(xz -dc "$WORK/anvil.tar.xz" 2>/dev/null | tar -tf - 2>/dev/null || tar -tf "$WORK/anvil.tar.xz" 2>/dev/null)
    # Herestrings, NOT `echo "$LIST" | grep -q`: under pipefail, grep -q
    # exiting at an early match SIGPIPEs the echo and the pipeline returns
    # 141 -- a race that stayed invisible until the fork klippy tree tripled
    # the listing, then intermittently reported Mainsail/Moonraker missing
    # from packages that carried both.
    grep -q 'init.d/S80ui' <<<"$LIST" && ok "mod payload has the service scripts" \
                                          || bad "mod payload missing init.d services"
    grep -q 'init.d/S70klipper' <<<"$LIST" && ok "mod payload owns Klipper startup" \
                                          || bad "mod payload missing S70klipper -- Klipper would never start"
    # The manifest is what the NEXT update deletes before it extracts. A
    # payload shipping without one still installs fine -- run-append.sh falls
    # back to the old seven-directory rm -rf -- but every printer that takes
    # it keeps falling back on every update after that, and the fallback is
    # the thing that eats whatever else lives in $MODDIR/bin. So this is a
    # build bug, not a warning.
    grep -q '\.install-manifest' <<<"$LIST" && ok "install manifest present (next update deletes by list, not by rm -rf)" \
                                          || bad "mod payload has no .install-manifest -- updates fall back to wiping whole directories"
    # s6. Two checks and not one, because the second is the one that catches
    # the failure nobody sees coming: s6-ftrigrd is not on anyone's PATH and
    # nothing calls it by name -- s6-svlisten spawns it out of the libexecdir
    # compiled into the binaries. A payload with bin/ and no libexec/ supervises
    # perfectly well and then every WAITING verb (s6-svc -w, s6-svwait) fails,
    # which is exactly the half of s6 we are adopting it for. Build bugs both:
    # a package that ships neither cannot be fixed on the printer.
    grep -q 'bin/s6-svscan' <<<"$LIST" && ok "s6 supervision binaries present" \
                                          || bad "no s6 in the payload -- bin/patch.sh did not stage the cross-build"
    grep -q 'libexec/s6-ftrigrd' <<<"$LIST" && ok "s6-ftrigrd present in libexec (the waiting verbs can spawn it)" \
                                          || bad "no libexec/s6-ftrigrd -- s6-svwait and s6-svc -w will fail on the printer"
    # CPython 3.13. anvil-env.sh points FF_PYTHON here -- Moonraker,
    # ff-startup.py, ffscreen.py and ff_mcu_bringup.py all run on it -- so a
    # package missing it breaks the boot, not just a future release. klippy is
    # not among FF_PYTHON's callers: it stays on FlashForge's 3.8.2, started by
    # /usr/prog/klipper/start.sh independently (see init.d/S70klipper).
    #
    # Two checks, not one, and the second is the one worth having. The
    # interpreter can be present and perfectly runnable while _sqlite3 is
    # absent, because a dropped -lm makes configure's link probe fail and
    # CPython records the module as "missing" rather than stopping -- see the
    # LIBS comment in patch.sh. sqlite3 is the entire reason this interpreter
    # is built (it is what eventually unpins MOONRAKER_VERSION), so a tree
    # without it is a 30MB payload that bought nothing. Build bugs both: a
    # package that ships neither cannot be fixed on the printer.
    grep -q 'bin/python3\.13$' <<<"$LIST" \
        && ok "CPython 3.13 present (FF_PYTHON -- Moonraker and the ff-startup scripts run on it)" \
        || bad "no bin/python3.13 in the payload -- bin/patch.sh did not stage the cross-build"
    grep -q 'lib-dynload/_sqlite3' <<<"$LIST" \
        && ok "python3.13 carries _sqlite3 (the module FlashForge's 3.8.2 has not got)" \
        || bad "python3.13 ships WITHOUT _sqlite3 -- the one module it exists for; check LIBS/LIBSQLITE3_LIBS in patch.sh"
    # And the other half of the same decision: the interpreter goes into the
    # prefix root's bin/ like everything else, but WITHOUT the `python3`
    # symlink CPython installs beside it. $MODDIR/bin is prepended to PATH by
    # anvil-env.sh (s6 needs that), so shipping one would silently put our
    # interpreter ahead of FlashForge's for every process that says `python3`
    # -- an accidental switch, on a printer whose klippy still needs 3.8's
    # site-packages (it is started separately, by FlashForge's own
    # start.sh, and never goes through FF_PYTHON). Reads the way round it
    # does for the same reason the dropbear check below does: its presence is
    # the bug.
    grep -qE '(^|/)bin/python3$' <<<"$LIST" \
        && bad "payload ships bin/python3 -- it would shadow FlashForge's interpreter on PATH" \
        || ok "no bin/python3 symlink (nothing shadows FlashForge's python3 on PATH)"
    # The half of the 3.13 story that is not the interpreter: what runs ON it.
    # Same shape of check and the same reason -- Moonraker is live on this
    # interpreter now, so a missing extension here is a Moonraker that will
    # not start on the very next boot, not a future release's problem.
    #
    # Two of the twelve extension modules by name rather than a count, and
    # these two: lmdb is Moonraker's DATABASE at the pinned commit (no lmdb,
    # no Moonraker at all, not a degraded one) and _cffi_backend is what
    # klippy dlopens c_helper.so through, which is the entire reason this
    # interpreter had to be glibc rather than musl. They are also the two that
    # a "cross build" quietly resolving to a manylinux wheel gets WRONG rather
    # than missing -- and the .so suffix is what says which: a mipsel build
    # spells itself cpython-313-mipsel-linux-gnu.so, an x86-64 wheel spells
    # itself cpython-313-x86_64-linux-gnu.so, so the name is the architecture.
    grep -q 'site-packages/lmdb/cpython.cpython-313-mipsel-linux-gnu\.so' <<<"$LIST" \
        && ok "lmdb's mipsel CPython extension present (Moonraker's database at this pin)" \
        || bad "no mipsel lmdb extension in site-packages -- Moonraker cannot open its database; check bin/patch.sh section 5c step 4"
    grep -q 'site-packages/_cffi_backend.cpython-313-mipsel-linux-gnu\.so' <<<"$LIST" \
        && ok "cffi's mipsel extension present (klippy's route to c_helper.so)" \
        || bad "no mipsel _cffi_backend in site-packages -- klippy could not load chelper on 3.13"
    # libsodium is the one library of ours that ships as a .so, because libnacl
    # dlopens it -- and the bare `libsodium.so` name is not decoration, it is
    # the exact name libnacl's path fallback constructs. A payload with the
    # versioned file and no symlink would pass a naive "is libsodium there"
    # check and fail at Moonraker's authorization component.
    grep -qE 'lib/libsodium\.so\.[0-9]' <<<"$LIST" \
        && ok "libsodium present in lib/ (libnacl's ed25519, no /usr/prog needed)" \
        || bad "no lib/libsodium.so.* in the payload -- bin/patch.sh section 5d did not stage the cross-build"
    grep -qE 'lib/libsodium\.so$' <<<"$LIST" \
        && ok "lib/libsodium.so link present (the name libnacl's dlopen fallback builds)" \
        || bad "lib/libsodium.so link missing -- libnacl looks for that exact name and would fall through to /usr/prog"
    grep -q 'mainsail/index.html' <<<"$LIST" && ok "Mainsail present" || warn "no Mainsail in payload"
    grep -q 'helixscreen/bin/helix-screen' <<<"$LIST" && ok "HelixScreen present" || warn "no HelixScreen in payload"
    # We deliberately ship no dropbear: the stock rootfs already has one, with
    # an enabled S50dropbear, so ssh is up before the mod does anything. A
    # dropbear in the payload would mean something unexpected, not something
    # missing -- hence the check reads the way round it does.
    grep -q 'bin/dropbear' <<<"$LIST" \
        && warn "dropbear in the payload -- we ship none; stock S50dropbear provides ssh" \
        || ok "no dropbear in the payload (stock S50dropbear provides ssh)"
    # This reads the PACKAGE, not a printer: it asks whether the tarball we
    # just built carries moonraker/moonraker.py. That is now the whole
    # installation -- the payload extracts to /usr/data/anvil and the init
    # script starts $MODDIR/moonraker/moonraker.py from where it landed, so a
    # payload carrying the directory but not that file ships a Moonraker that
    # cannot start, which looks identical to a dead printer from the outside.
    # (It used to be phrased as "the file moonrakerDaemon execs by absolute
    # path" from /usr/prog; moonrakerDaemon is never invoked any more and
    # nothing is copied to /usr/prog, but the file the check looks for is the
    # same one, so the assertion itself is unchanged.)
    grep -q 'moonraker/moonraker.py' <<<"$LIST" && ok "Moonraker present" \
                                          || warn "no Moonraker in payload -- the stock 2022 build stays, and Mainsail will hide the webcam"
else
    warn "no anvil.tar.xz -- scripts only"
fi

# 8b ------------------------------------------------------- MODEL GATE
# The most easily missed failure: a package built from the wrong model's
# firmware refuses to install, and a package built from the RIGHT model but
# flashed to the wrong one would install the wrong binaries.
PKG_MACHINE=$(sed -n 's/^MACHINE=//p' "$WORK/runFirmwareExe.sh" 2>/dev/null | head -n1)
PKG_PID=$(sed -n 's/^PID=//p' "$WORK/runFirmwareExe.sh" 2>/dev/null | head -n1)
if [ -n "$PKG_MACHINE" ]; then
    echo "         package installs on: $PKG_MACHINE (PID $PKG_PID)"
    if [ -n "${TARGET_MACHINE:-}" ]; then
        if [ "$PKG_MACHINE" = "$TARGET_MACHINE" ]; then
            ok "model gate matches TARGET_MACHINE=$TARGET_MACHINE"
        else
            bad "MODEL MISMATCH: package is for '$PKG_MACHINE' but TARGET_MACHINE='$TARGET_MACHINE'"
            bad "  this package will be REFUSED by your printer (\"Firmware does not match machine type\")"
            bad "  you need a stock package built for $TARGET_MACHINE to start from"
        fi
    else
        warn "TARGET_MACHINE not set in config.env -- cannot check this against your printer"
    fi
else
    warn "no MACHINE= gate found in runFirmwareExe.sh"
fi

# 9 --------------------------------------------------------------- USB names
# The filename prefix must match the model, because app_startup.sh globs for
# it: the Pro looks for /mnt/Creator5Pro-*.tgz, the non-Pro for
# /mnt/Creator5-*.tgz. It must ALSO match the gate inside, or the printer
# picks the file up and then refuses it.
PKG_NAME=$(basename "$PKG")
case "$PKG_NAME" in
    Creator5Pro-*.tgz) FN_MACHINE=Creator5Pro ;;
    Creator5-*.tgz)    FN_MACHINE=Creator5 ;;
    *) FN_MACHINE=""; bad "filename '$PKG_NAME' matches no glob -- app_startup.sh will ignore it" ;;
esac
if [ -n "$FN_MACHINE" ]; then
    if [ -z "$PKG_MACHINE" ] || [ "$FN_MACHINE" = "$PKG_MACHINE" ]; then
        ok "filename prefix matches the model gate ($FN_MACHINE)"
    else
        bad "filename says $FN_MACHINE but the gate inside says $PKG_MACHINE"
        bad "  the printer would pick this file up and then refuse it"
    fi
fi

# 10 --------------------------------------------------- the ship boundary
# Only payload/ and assets/ may end up on a printer; bin/, test/ and docker/
# are host-side. Nothing enforces that except this check.
#
# It compares by CONTENT, not by name: a name blacklist would trip over any
# file Mainsail or HelixScreen happens to call common.sh, while a byte-for-byte
# match against a host-lane file is exactly the thing we are trying to catch.
mkdir -p "$WORK/ship"
tar -xf "$WORK"/software-*.tar.xz -C "$WORK/ship" 2>/dev/null || true
if [ -f "$WORK/anvil.tar.xz" ]; then
    mkdir -p "$WORK/ship/.anvil"
    xz -dc "$WORK/anvil.tar.xz" 2>/dev/null | tar -xf - -C "$WORK/ship/.anvil" 2>/dev/null \
        || tar -xf "$WORK/anvil.tar.xz" -C "$WORK/ship/.anvil" 2>/dev/null || true
fi
find bin test docker -type f 2>/dev/null | xargs -r md5sum 2>/dev/null \
    | awk '{print $1}' | sort -u > "$WORK/host.md5"
find "$WORK/ship" -type f 2>/dev/null | xargs -r md5sum 2>/dev/null > "$WORK/ship.md5"
LEAK=$(awk 'NR==FNR{h[$1];next} $1 in h {print}' "$WORK/host.md5" "$WORK/ship.md5" \
       | sed "s|$WORK/ship/||")
# Those finds are RELATIVE, so from any cwd but the repo root host.md5 comes
# out empty, the join matches nothing and this reports ok having compared
# nothing -- retiring the only check that keeps config.env and the host tooling
# off a USB stick. common.sh cds to the root, so this is a guard against a
# future caller that does not.
if [ ! -s "$WORK/host.md5" ]; then
    bad "ship-boundary check compared nothing (no files found under bin/, test/, docker/ -- wrong cwd?)"
elif [ -z "$LEAK" ]; then
    ok "package carries nothing from bin/, test/ or docker/"
else
    bad "host-side files leaked into the package:"
    echo "$LEAK" | head -10 | sed 's/^/          /'
fi

echo
if [ "$FAIL" = 0 ]; then echo "ALL CHECKS PASSED -- safe to copy to USB"; else echo "FAILURES ABOVE -- do not install"; exit 1; fi
