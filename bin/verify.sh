#!/usr/bin/env bash
# Simulate every check the printer performs, against a built package.
#   ./bin/verify.sh [path/to/pkg.tgz]     default: work/out/<model>-*.tgz
set -uo pipefail
. "$(dirname "$0")/common.sh"

# The selected model's package, or a two-model release verifies one file twice.
PKG="${1:-$(ls -1 "work/out/${TARGET_MACHINE:-Creator5Pro}"-*.tgz 2>/dev/null | head -n1)}"
[ -f "${PKG:-}" ] || { echo "no package; run ./bin/pack.sh" >&2; exit 1; }
echo "verifying $PKG"; echo

FAIL=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAIL=1; }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$*"; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

# --- 1. decrypt
if openssl des3 -d -k "$FF_KEY" -salt -md md5 -in "$PKG" 2>/dev/null \
     | tar -xf - -C "$WORK" 2>/dev/null; then
    ok "decrypts with the firmware key and is a valid tar"
else
    bad "decrypt/untar failed -- the printer's unTar will reject this"; exit 1
fi

# --- 2. installer present
if [ -f "$WORK/runFirmwareExe.sh" ]; then
    ok "runFirmwareExe.sh present"
else
    bad "no runFirmwareExe.sh -- app_startup.sh falls back to plain tar and gives up"
fi

# --- 3. components are PLAIN tar, not xz
for f in "$WORK"/software-*.tar.xz "$WORK"/kernel-*.tar.xz "$WORK"/control-*.tar.xz "$WORK"/library-*.tar.xz; do
    [ -f "$f" ] || continue
    b=$(basename "$f")
    if tar -tf "$f" >/dev/null 2>&1; then
        ok "$b is a plain tar (stock installer runs bare 'tar -xvf')"
    else
        bad "$b is not a plain tar -- stock 'tar -xvf' cannot read it"
    fi
done

# --- 4. md5sum gate
SOFTWARE_TAR=$(ls -1 "$WORK"/software-*.tar.xz 2>/dev/null | head -n1)
if [ -n "$SOFTWARE_TAR" ]; then
    mkdir -p "$WORK/sw" && tar -xf "$SOFTWARE_TAR" -C "$WORK/sw"
    if [ -f "$WORK/sw/md5sum.list" ]; then
        # busybox md5sum spells quiet -s; GNU coreutils spells it --status.
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

# --- 5. shell syntax of scripts
# start.sh and firmwareExe are the payload's now, not the component's -- section
# 7 extracts and checks them there.
for s in "$WORK/runFirmwareExe.sh" "$WORK/sw/run.sh" "$WORK/sw/app_startup.sh"; do
    [ -f "$s" ] || continue
    if sh -n "$s" 2>/dev/null; then ok "syntax OK: $(basename "$s")"
    else bad "SYNTAX ERROR in $(basename "$s")"; sh -n "$s" 2>&1 | head -3 | sed 's/^/        /'; fi
done

# --- 6. boot chain actually hooks up
if [ -f "$WORK/sw/app_startup.sh" ]; then
    grep -q 'gt9xx_touch.ko' "$WORK/sw/app_startup.sh" \
        && ok "touchscreen driver still loaded at boot" \
        || bad "gt9xx_touch.ko insmod missing -- no touchscreen"
    grep -q 'firmwareExe' "$WORK/sw/app_startup.sh" \
        && ok "a UI is launched at boot" \
        || bad "nothing launches a UI -- printer boots to a blank screen"
fi

# --- 7. the payload's klippy tree
# The klippy tree is in the PAYLOAD now, not the software component: the
# klipper service execs $MODDIR/klipper/klippy, so the component copy and the
# chelper.tar that carried its .so are both gone. Unconditional, because
# v20260824 passed here by having every check below conditional on files the
# broken build did not contain. ./klipper alone, not the whole payload --
# section 8 answers the rest from a listing. ./prog rides along because the two
# stock-path scripts moved there and still need a syntax gate. Paths carry a
# leading ./ because bin/pack.sh tars `.` from inside $PAYLOAD_DIR.
PAYLOAD_TAR=$(ls -1 "$WORK"/anvil.tar.xz 2>/dev/null | head -n1)
if [ -n "$PAYLOAD_TAR" ]; then
    mkdir -p "$WORK/pl"
    xz -dc "$PAYLOAD_TAR" 2>/dev/null | tar -xf - -C "$WORK/pl" ./klipper ./prog ./etc 2>/dev/null \
        || tar -xf "$PAYLOAD_TAR" -C "$WORK/pl" ./klipper ./prog ./etc 2>/dev/null
fi
for s in "$WORK/pl/prog/start.sh" "$WORK/pl/prog/firmwareExe"; do
    [ -f "$s" ] || { bad "the payload carries no prog/$(basename "$s") -- link-prog has nothing to point the stock path at"; continue; }
    if sh -n "$s" 2>/dev/null; then ok "syntax OK: prog/$(basename "$s")"
    else bad "SYNTAX ERROR in prog/$(basename "$s")"; sh -n "$s" 2>&1 | head -3 | sed 's/^/        /'; fi
done
if [ -f "$WORK/pl/klipper/klippy/chelper/__init__.py" ]; then
    ok "payload carries the fork klippy tree"
else
    bad "no klippy tree in the payload -- anvil-klipper did not install; this is the stock-overlay build that shipped as v20260824"
fi
CHELPER="$WORK/pl/klipper/klippy/chelper/c_helper.so"
[ -f "$CHELPER" ] || bad "no c_helper.so in the payload klippy tree -- klippy cannot talk to an MCU"
# PRESENCE IS ALL THIS FILE ASKS OF IT. The ABI question -- o32/nan2008/
# mips32r2, which the kernel answers with ENOEXEC -- is asked once, of every ELF
# on the installed filesystem, in qa/replica/test_abi.py; a fourth partial copy
# of that rule lived here and read only this one object out of a payload full of
# them. The symbol check that sat beside it went with test/: every function
# klippy cdefs against the .so's dynamic symbols, because cffi resolves lazily
# and a stale .so imports cleanly. What keeps that out now is pkgs/klipper
# compiling the .so from the chelper sources of the very tree it ships, so a .so
# older than its klippy is not something a build can produce.
# The component must not carry one: two klippy trees under one version number
# is what this release removed, and a stray one is the copy a stock flash
# leaves running.
[ -e "$WORK/sw/klipper/klippy" ] \
    && bad "the software component still carries a klippy tree -- bin/patch.sh section 1 is staging one again" \
    || ok "no klippy tree in the software component (the payload is the only one)"
# Same rule for the two stock-path scripts: anvil-core owns them at
# $MODDIR/prog/ and link-prog symlinks them into place. A component copy of the
# wrapper is worse than none -- with no payload it never starts a UI, where an
# absent one lets app_startup.sh restore the stock binary.
for f in firmwareExe start.sh; do
    [ -e "$WORK/sw/$f" ] \
        && bad "the software component still carries $f -- bin/patch.sh section 8 is staging one again" \
        || ok "no $f in the software component (anvil-core's \$MODDIR/prog is the only one)"
done

# The oneshot runner's #!, which is the one thing about the compiled database a
# host can check: s6-rc-compile bakes in the execline of the stack it was linked
# against, so this line is what every oneshot on the printer will exec. It used
# to be asserted in bin/patch.sh, against a native compiler that could be built
# with the wrong --prefix. The database is compiled in the replica by the
# s6-rc-compile we ship now, so this should be true by construction -- which is
# exactly why it is cheap to keep, and it is the assertion that would catch the
# construction being broken.
S6RC_RUNNER=$(ls -d "$WORK/pl/etc/s6-rc/compiled"/db-*/servicedirs/s6rc-oneshot-runner/run 2>/dev/null | head -n1)
if [ -z "$S6RC_RUNNER" ]; then
    bad "the payload's s6-rc database has no oneshot runner -- has the source tree no oneshots?"
else
    S6RC_SHEBANG=$(head -1 "$S6RC_RUNNER")
    case "$S6RC_SHEBANG" in
        "#!$MODDIR/bin/execlineb"*)
            ok "the s6-rc database execs $MODDIR/bin/execlineb (the execline we ship)" ;;
        *)
            bad "the s6-rc database asks for '$S6RC_SHEBANG', not $MODDIR/bin/execlineb -- every oneshot would ENOENT" ;;
    esac
fi
# `current` must resolve, or s6-rc-init has nothing to read at boot.
if [ -d "$WORK/pl/etc/s6-rc/compiled/current" ]; then
    ok "compiled/current resolves ($(readlink "$WORK/pl/etc/s6-rc/compiled/current" 2>/dev/null))"
else
    bad "compiled/current does not resolve -- s6-rc-init finds no database at boot"
fi

# --- 8. mod payload
if [ -f "$WORK/anvil.tar.xz" ]; then
    if xz -t "$WORK/anvil.tar.xz" 2>/dev/null; then ok "anvil.tar.xz is valid xz"
    elif tar -tf "$WORK/anvil.tar.xz" >/dev/null 2>&1; then ok "anvil.tar.xz is a plain tar"
    else bad "anvil.tar.xz is neither valid xz nor tar"; fi

    LIST=$(xz -dc "$WORK/anvil.tar.xz" 2>/dev/null | tar -tf - 2>/dev/null || tar -tf "$WORK/anvil.tar.xz" 2>/dev/null)
    # Herestrings, NOT `echo | grep -q`: under pipefail, grep -q exiting at an
    # early match SIGPIPEs the echo and the pipeline returns 141.
    # The compiled s6-rc database IS the service set.
    grep -q 'etc/s6-rc/compiled/' <<<"$LIST" && ok "mod payload has the compiled s6-rc database" \
                                          || bad "mod payload has no s6-rc database -- no service would ever start"
    grep -q 'servicedirs/klipper/run' <<<"$LIST" && ok "mod payload owns Klipper startup" \
                                          || bad "mod payload has no klipper service -- Klipper would never start"
    # printer.base.cfg has a bare [include printer.chamber.cfg] and Klipper
    # treats a missing include as fatal. Without the ff-*.cfg, klippy starts
    # fine and the machine is silently single-tool.
    if [ "${BUILD_TOOLCHANGE:-1}" = "1" ]; then
        for _m in Creator5 Creator5Pro; do
            grep -q "config/chamber/$_m.cfg" <<<"$LIST" \
                && ok "mod payload carries the $_m chamber config" \
                || bad "mod payload has no config/chamber/$_m.cfg -- that model will not start klippy"
        done
        grep -q 'config/printer.base.cfg' <<<"$LIST" \
            && ok "mod payload carries printer.base.cfg (every other config hangs off it)" \
            || bad "mod payload has no config/printer.base.cfg -- klippy will not start"
        grep -q 'bin/anvil-link-prog.sh' <<<"$LIST" \
            && ok "the linker is in the payload (it resolves chamber/<MACHINE>.cfg on the printer)" \
            || bad "no bin/anvil-link-prog.sh -- nothing links a chamber config into /usr/data/config"
        grep -q 'config/ff-toolchange.cfg' <<<"$LIST" \
            && ok "mod payload carries the toolchanger config" \
            || bad "mod payload has no config/ff-*.cfg -- klippy starts as a single-tool printer, silently"
    fi
    # Without it run-append.sh falls back to the old seven-directory rm -rf,
    # forever, and that fallback eats whatever else lives in $MODDIR/bin.
    grep -q '\.install-manifest' <<<"$LIST" && ok "install manifest present (next update deletes by list, not by rm -rf)" \
                                          || bad "mod payload has no .install-manifest -- updates fall back to wiping whole directories"
    # s6-ftrigrd is on no PATH -- s6-svlisten spawns it from the compiled-in
    # libexecdir -- so bin/ without libexec/ supervises fine until every
    # waiting verb (s6-svc -w, s6-svwait) fails.
    grep -q 'bin/s6-svscan' <<<"$LIST" && ok "s6 supervision binaries present" \
                                          || bad "no s6 in the payload -- bin/patch.sh did not stage the cross-build"
    grep -q 'libexec/s6-ftrigrd' <<<"$LIST" && ok "s6-ftrigrd present in libexec (the waiting verbs can spawn it)" \
                                          || bad "no libexec/s6-ftrigrd -- s6-svwait and s6-svc -w will fail on the printer"
    # CPython 3.13, which FF_PYTHON points at -- klippy included now, since the
    # klipper service execs $FF_PYTHON against $MODDIR/klipper/klippy.
    # The second check is the one worth having: the interpreter runs perfectly
    # while _sqlite3 is absent, because a dropped -lm makes configure's link
    # probe fail and CPython records the module missing rather than stopping.
    grep -q 'bin/python3\.13$' <<<"$LIST" \
        && ok "CPython 3.13 present (FF_PYTHON -- Moonraker and the ff-startup scripts run on it)" \
        || bad "no bin/python3.13 in the payload -- bin/patch.sh did not stage the cross-build"
    grep -q 'lib-dynload/_sqlite3' <<<"$LIST" \
        && ok "python3.13 carries _sqlite3 (the module FlashForge's 3.8.2 has not got)" \
        || bad "python3.13 ships WITHOUT _sqlite3 -- the one module it exists for; check LIBS/LIBSQLITE3_LIBS in pkgs/3rdparty/python/build.sh"
    # No `python3` symlink: anvil-env.sh prepends $MODDIR/bin to PATH, so one
    # would silently put our interpreter ahead of FlashForge's for every process
    # that says `python3`. Its presence is the bug.
    grep -qE '(^|/)bin/python3$' <<<"$LIST" \
        && bad "payload ships bin/python3 -- it would shadow FlashForge's interpreter on PATH" \
        || ok "no bin/python3 symlink (nothing shadows FlashForge's python3 on PATH)"
    # lmdb is Moonraker's database at the pinned commit, _cffi_backend is what
    # klippy dlopens c_helper.so through -- the reason this interpreter had to
    # be glibc, not musl. Both are what a cross build resolving to a manylinux
    # wheel gets WRONG rather than missing, and the .so suffix is the
    # architecture: cpython-313-mipsel-linux-gnu.so, not x86_64.
    grep -q 'site-packages/lmdb/cpython.cpython-313-mipsel-linux-gnu\.so' <<<"$LIST" \
        && ok "lmdb's mipsel CPython extension present (Moonraker's database at this pin)" \
        || bad "no mipsel lmdb extension in site-packages -- Moonraker cannot open its database; check work/.pkg-python-lmdb/wheel-lmdb.log"
    grep -q 'site-packages/_cffi_backend.cpython-313-mipsel-linux-gnu\.so' <<<"$LIST" \
        && ok "cffi's mipsel extension present (klippy's route to c_helper.so)" \
        || bad "no mipsel _cffi_backend in site-packages -- klippy could not load chelper on 3.13"
    # The dev half must not ship: headers, pkgconfig and config-3.13-* exist so
    # the python-* recipes can compile on a BUILD machine. patch.sh prunes them
    # via PKG_DEV_FILES, and extra files in a payload ship silently.
    if grep -qE '(^|/)(include/python3\.13/|lib/pkgconfig/|config-3\.13-)' <<<"$LIST"; then
        bad "payload carries CPython's dev files (headers/pkgconfig/config-3.13-*) -- anvil-python-dev's half was not pruned"
    else
        ok "no CPython dev files in the payload (headers and build config stay in anvil-python-dev)"
    fi
    # The bare `libsodium.so` name is what libnacl's path fallback constructs; a
    # payload with only the versioned file fails at Moonraker's auth component.
    grep -qE 'lib/libsodium\.so\.[0-9]' <<<"$LIST" \
        && ok "libsodium present in lib/ (libnacl's ed25519, no /usr/prog needed)" \
        || bad "no lib/libsodium.so.* in the payload -- bin/patch.sh section 5d did not stage the cross-build"
    grep -qE 'lib/libsodium\.so$' <<<"$LIST" \
        && ok "lib/libsodium.so link present (the name libnacl's dlopen fallback builds)" \
        || bad "lib/libsodium.so link missing -- libnacl looks for that exact name and would fall through to /usr/prog"
    grep -q 'mainsail/index.html' <<<"$LIST" && ok "Mainsail present" || warn "no Mainsail in payload"
    grep -q 'helixscreen/bin/helix-screen' <<<"$LIST" && ok "HelixScreen present" || warn "no HelixScreen in payload"
    # We ship no dropbear -- the stock rootfs has one. Its PRESENCE is the bug,
    # hence the check reads the way round it does.
    grep -q 'bin/dropbear' <<<"$LIST" \
        && warn "dropbear in the payload -- we ship none; stock S50dropbear provides ssh" \
        || ok "no dropbear in the payload (stock S50dropbear provides ssh)"
    # Reads the PACKAGE: the init script starts $MODDIR/moonraker/moonraker.py
    # from where the payload landed, so the directory without that file ships
    # a Moonraker that cannot start.
    grep -q 'moonraker/moonraker.py' <<<"$LIST" && ok "Moonraker present" \
                                          || warn "no Moonraker in payload -- the stock 2022 build stays, and Mainsail will hide the webcam"
else
    warn "no anvil.tar.xz -- scripts only"
fi

# --- 8b. MODEL GATE
# A package built from the wrong model's firmware refuses to install.
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

# --- 9. USB names
# The prefix must match the model (app_startup.sh globs /mnt/Creator5Pro-*.tgz)
# AND the gate inside, or the printer picks the file up and then refuses it.
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

# --- 10. the ship boundary
# Only payload/ and assets/ may reach a printer. Compared by CONTENT, not name:
# a blacklist would trip over any file Mainsail happens to call common.sh.
mkdir -p "$WORK/ship"
tar -xf "$WORK"/software-*.tar.xz -C "$WORK/ship" 2>/dev/null || true
if [ -f "$WORK/anvil.tar.xz" ]; then
    mkdir -p "$WORK/ship/.anvil"
    xz -dc "$WORK/anvil.tar.xz" 2>/dev/null | tar -xf - -C "$WORK/ship/.anvil" 2>/dev/null \
        || tar -xf "$WORK/anvil.tar.xz" -C "$WORK/ship/.anvil" 2>/dev/null || true
fi
find bin docker -type f 2>/dev/null | xargs -r md5sum 2>/dev/null \
    | awk '{print $1}' | sort -u > "$WORK/host.md5"
find "$WORK/ship" -type f 2>/dev/null | xargs -r md5sum 2>/dev/null > "$WORK/ship.md5"
LEAK=$(awk 'NR==FNR{h[$1];next} $1 in h {print}' "$WORK/host.md5" "$WORK/ship.md5" \
       | sed "s|$WORK/ship/||")
# Those finds are RELATIVE: from any other cwd host.md5 comes out empty and
# this reports ok having compared nothing. common.sh cds to the root.
if [ ! -s "$WORK/host.md5" ]; then
    bad "ship-boundary check compared nothing (no files found under bin/, docker/ -- wrong cwd?)"
elif [ -z "$LEAK" ]; then
    ok "package carries nothing from bin/ or docker/"
else
    bad "host-side files leaked into the package:"
    echo "$LEAK" | head -10 | sed 's/^/          /'
fi

echo
if [ "$FAIL" = 0 ]; then echo "ALL CHECKS PASSED -- safe to copy to USB"; else echo "FAILURES ABOVE -- do not install"; exit 1; fi
