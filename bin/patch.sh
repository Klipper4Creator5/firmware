#!/usr/bin/env bash
# 2/3 -- apply the mods to work/software/.
# Idempotent: safe to re-run after editing config.env or assets.
set -euo pipefail
. "$(dirname "$0")/common.sh"

SW=work/software
[ -d "$SW" ] || { echo "run bin/unpack.sh first" >&2; exit 1; }

echo "profile: $PROFILE -- ${PROFILE_DESC:-}"
echo

MARK_BEGIN="# >>> anvil begin >>>"
MARK_END="# <<< anvil end <<<"

say() { printf '>> %s\n' "$*"; }
skip() { printf '   (skip) %s\n' "$*"; }

# Everything we add to the printer lives under this one directory on the DATA
# partition, so a FlashForge OTA cannot delete it.
MODDIR=/usr/data/anvil
# The mod payload is built OUTSIDE the software component on purpose. The
# software component is extracted to /usr/prog/PROGRAM/software/<ver>/ -- the
# firmware partition, of which the installer keeps two versions. Mainsail and
# HelixScreen are ~100MB and would overflow it. They ride in the outer package
# instead, land in /usr/data/update/ (data partition), and are moved to
# /usr/data/anvil from there.
MP=work/modpayload
rm -rf "$MP" "$SW/mod"   # $SW/mod: leftover from an older layout
mkdir -p "$MP/bin" "$MP/nginx" "$MP/www" "$MP/config"

# ---------------------------------------------------------------------------
# BUILD_APPLY=0 (the "probe" profile): reinstall the stock component untouched
# and add only a diagnostic report. Nothing on the printer changes.
# ---------------------------------------------------------------------------
if [ "${BUILD_APPLY:-1}" = "0" ]; then
    say "BUILD_APPLY=0 -- stock component left byte-for-byte unmodified"
    if [ "${BUILD_REPORT:-0}" = "1" ]; then
        say "adding diagnostic report step"
        python3 - "$SW/run.sh" payload/report.sh <<'PY2'
import sys, re
run, extra = sys.argv[1], sys.argv[2]
B, E = "# >>> anvil begin >>>", "# <<< anvil end <<<"
s = open(run, encoding='utf-8', errors='surrogateescape').read()
s = re.sub(re.escape(B) + r".*?" + re.escape(E) + r"\n?", "", s, flags=re.S)
block = open(extra, encoding='utf-8').read()
m = list(re.finditer(r"^exit 0\s*$", s, flags=re.M))
i = m[-1].start() if m else len(s)
s = s[:i] + B + "\n" + block + E + "\n\n" + s[i:]
open(run, 'w', encoding='utf-8', errors='surrogateescape').write(s)
PY2
    fi
    rm -rf "$MP"
    echo
    echo "Patched (probe profile -- no changes to the printer)."
    echo "  software component: $(du -sh "$SW" | cut -f1)"
    echo "Now run bin/pack.sh"
    exit 0
fi

# ---------------------------------------------------------------- 1. Klipper
if [ "${BUILD_KLIPPER:-fork}" = "fork" ] && [ -d "${KLIPPER_FORK:-}/klippy" ]; then
    say "Klipper: installing fork tree from $KLIPPER_FORK"
    # Stock ships only a handful of klippy files as an overlay; the fork is a
    # different Klipper generation (v0.13 vs v0.12), so ship the WHOLE tree.
    rm -rf "$SW/klipper/klippy"
    mkdir -p "$SW/klipper/klippy"
    ( cd "$KLIPPER_FORK/klippy" && tar -cf - \
        --exclude='__pycache__' --exclude='*.pyc' --exclude='chelper/*.o' . ) \
      | tar -xf - -C "$SW/klipper/klippy"

    # c_helper.so must be MIPS32r2 / nan2008 / o32 or klippy dies on import.
    CH="$KLIPPER_FORK/klippy/chelper/c_helper.so"
    if [ -f "$CH" ]; then
        # The ABI is necessary but not sufficient: a .so with the right ABI
        # and older sources than the klippy tree beside it installs, boots and
        # then dies at connect, because cffi resolves symbols lazily. Check
        # the symbols too, here, where it is still a build failure.
        if ! python3 test/test-chelper.py "$KLIPPER_FORK"; then
            echo "   !! c_helper.so does not match klippy -- rebuild it" >&2
            exit 1
        fi
        if readelf -h "$CH" 2>/dev/null | grep -q nan2008; then
            say "Klipper: c_helper.so is nan2008 MIPS32r2 -- good"
            mkdir -p work/.chelper/chelper
            cp -f "$CH" work/.chelper/chelper/c_helper.so
            tar -cf "$SW/klipper/chelper.tar" -C work/.chelper chelper
            rm -rf work/.chelper
        else
            echo "   !! c_helper.so is NOT nan2008 -- the kernel will refuse it" >&2
            exit 1
        fi
    else
        echo "   !! no c_helper.so in the fork; see README 'Rebuilding chelper'" >&2
        exit 1
    fi
    # klippy/ now contains the fork's own extras+kinematics, so the stock
    # overlay dirs would only re-inject 0.12-era files on top. Drop them.
    rm -rf "$SW/klipper/extras" "$SW/klipper/kinematics"
    mkdir -p "$SW/klipper/extras"
else
    skip "Klipper: keeping stock tree"
fi

# ----------------------------------------------------------- 2. Toolchanger
# Lives in this repo under payload/klipper/ -- it used to be the separate
# creator5-toolchange checkout, pointed at by TOOLCHANGE= in config.env.
if [ "${BUILD_TOOLCHANGE:-1}" = "1" ]; then
    say "Toolchange: ff_*.py + configs"
    mkdir -p "$SW/klipper/extras"
    cp -f payload/klipper/extras/ff_*.py "$SW/klipper/extras/"
    # .cfg files belong on the data partition; run.sh installs them without
    # clobbering a config the user already tuned.
    cp -f payload/klipper/config/ff-*.cfg "$MP/config/"
else
    skip "Toolchange"
fi

# -------------------------------------------------------------- 3. Mainsail
if [ "${BUILD_MAINSAIL:-1}" = "1" ]; then
    # The profile asked for Mainsail, so a missing file is a broken build, not
    # a reason to ship a package with an empty web root. bin/fetch-assets.sh
    # should have put it here.
    [ -f "${MAINSAIL_ZIP:-}" ] || { echo "BUILD_MAINSAIL=1 but no Mainsail zip at '${MAINSAIL_ZIP:-}' -- run ./bin/fetch-assets.sh" >&2; exit 1; }
    say "Mainsail: unpacking $(basename "$MAINSAIL_ZIP")"
    mkdir -p "$MP/www/mainsail"
    unzip -q -o "$MAINSAIL_ZIP" -d "$MP/www/mainsail"
    cp -f assets/nginx.conf "$MP/nginx/nginx.conf"
    du -sh "$MP/www/mainsail" | awk '{print "   "$1}'
else
    skip "Mainsail"
fi
[ -f assets/moonraker.conf ] && cp -f assets/moonraker.conf "$MP/config/moonraker.conf"

# ----------------------------------------------------------- 4. HelixScreen
if [ "${BUILD_HELIX:-1}" = "1" ]; then
    [ -f "${HELIX_TGZ:-}" ] || { echo "BUILD_HELIX=1 but no HelixScreen tarball at '${HELIX_TGZ:-}' -- run ./bin/fetch-assets.sh" >&2; exit 1; }
    say "HelixScreen: unpacking $(basename "$HELIX_TGZ")"
    mkdir -p "$MP/helixscreen"
    tar -xzf "$HELIX_TGZ" -C "$MP" # yields mod/helixscreen/
    # Printer-database entry so it detects the Creator 5 Pro as a tool changer
    mkdir -p "$MP/helixscreen/config/printer_database.d"
    cp -f payload/helixscreen/printer_database.d/*.json \
          "$MP/helixscreen/config/printer_database.d/"
    [ -f assets/hooks-creator5.sh ] && \
        cp -f assets/hooks-creator5.sh "$MP/helixscreen/assets/config/platform/"
    du -sh "$MP/helixscreen" | awk '{print "   "$1}'
else
    skip "HelixScreen"
fi

# ------------------------------------------------------------------- 5. SSH
# Nothing to install. The stock rootfs (kernel-*.tar.xz -> rootfs.squashfs)
# already ships /usr/sbin/dropbear, /usr/bin/dropbearkey AND an enabled
# /etc/init.d/S50dropbear that busybox init runs at every boot. SSH is
# therefore ALREADY LISTENING on port 22 of a stock printer.
#
# The only thing missing is a root password anyone knows: stock /etc/shadow
# carries an unpublished hash. Setting ROOT_PW_HASH below is the entire
# "enable ssh" feature -- no cross-compiled binaries, no init script.
if [ "${MOD_SSH:-1}" = "1" ]; then
    if [ -n "${ROOT_PW_HASH:-}" ]; then
        say "SSH: stock dropbear is already running; setting a known root password"
    else
        say "SSH: no ROOT_PW_HASH -- the installer will pick a random root password"
        say "     and write it to anvil-password.txt on the USB stick."
        say "     Set ROOT_PW_HASH to choose your own instead."
    fi
else
    skip "SSH"
fi
if [ -n "${BUSYBOX_BIN:-}" ] && [ -f "$BUSYBOX_BIN" ]; then
    cp -f "$BUSYBOX_BIN" "$MP/bin/busybox"; chmod +x "$MP/bin/busybox"
fi

# --------------------------------------------------------- 6. root password
if [ -n "${ROOT_PW_HASH:-}" ]; then
    say "Accounts: setting root password hash"
    # /etc is a bind mount of /usr/prog/etc (app_startup.sh), and this file is
    # what dropbear reads at authentication time -- so this is the live shadow
    # even though dropbear started earlier from the read-only squashfs.
    # /etc is a bind mount of /usr/prog/etc, so this file IS the live shadow.
    awk -v h="$ROOT_PW_HASH" 'BEGIN{FS=OFS=":"} $1=="root"{$2=h} {print}' \
        "$SW/shadow" > "$SW/shadow.new" && mv -f "$SW/shadow.new" "$SW/shadow"
else
    skip "root password (set ROOT_PW_HASH)"
fi

# ------------------------------------------------ 7. start.sh (web stack on)
say "start.sh: enabling nginx + moonraker"
cp -f payload/start.sh "$SW/start.sh"
chmod +x "$SW/start.sh"

# ------------------------------------- 8. firmwareExe -> our wrapper script
# The stock chain is rcS -> S99factory_test_shell -> app_startup.sh ->
# firmwareExe, and firmwareExe is also what starts Klipper. Replacing this
# one file is therefore enough to own the whole userspace boot, which means
# app_startup.sh, rcS and the init chain are left COMPLETELY STOCK.
say "firmwareExe: installing wrapper (original kept as firmwareExe.stock)"
if [ -f "$SW/firmwareExe" ] && ! head -c 2 "$SW/firmwareExe" | grep -q '#!'; then
    mv -f "$SW/firmwareExe" "$SW/firmwareExe.stock"
    echo "   stock binary -> firmwareExe.stock ($(du -h "$SW/firmwareExe.stock" | cut -f1))"
fi
cp -f payload/firmwareExe "$SW/firmwareExe"
chmod +x "$SW/firmwareExe"

# ------------------------------------------------------ 9. mod service dir
mkdir -p "$MP/init.d"
cp -f payload/init.d/S* "$MP/init.d/"
chmod +x "$MP/init.d"/S*
sed -e "s/^MOD_UI=.*/MOD_UI=${MOD_UI:-stock}/" \
    -e "s/^MOD_WEB=.*/MOD_WEB=${MOD_WEB:-1}/" \
    -e "s/^MOD_SSH=.*/MOD_SSH=${MOD_SSH:-1}/" \
    -e "s/^MOD_WIFI=.*/MOD_WIFI=${MOD_WIFI:-1}/" \
    payload/anvil.conf > "$MP/anvil.conf"

# --------------------------------------------------- 10. run.sh install step
say "run.sh: injecting mod install blocks (pre + post)"
# The diagnostic report is a DEBUG payload: report.sh copies /etc, passwd and
# shadow onto the USB stick. Only the probe profile turns it on -- see
# profiles/*.env. It rides at the end of the post block rather than in one of
# its own, so there is still exactly one injected region to strip on re-run.
POST=work/.run-post.sh
# 1 only when ssh is on and nothing was baked in: a package is one file that
# many people flash, so a baked-in default would be the same password on every
# printer. The installer picks a random per-machine one instead and writes it
# onto the USB stick it was flashed from.
if [ "${MOD_SSH:-1}" = "1" ] && [ -z "${ROOT_PW_HASH:-}" ]; then
    PW_AUTO=1
else
    PW_AUTO=0
fi
sed -e "s/^MOD_PW_AUTO=.*/MOD_PW_AUTO=$PW_AUTO/" \
    payload/run-append.sh > "$POST"
if [ "${BUILD_REPORT:-0}" = "1" ]; then
    say "run.sh: including the diagnostic report step (BUILD_REPORT=1)"
    cat payload/report.sh >> "$POST"
fi
python3 - "$SW/run.sh" payload/run-pre.sh "$POST" <<'PY'
import sys, re
run, pre_f, post_f = sys.argv[1], sys.argv[2], sys.argv[3]
B1, E1 = "# >>> anvil pre >>>",  "# <<< anvil pre <<<"
B2, E2 = "# >>> anvil begin >>>", "# <<< anvil end <<<"
src = open(run, encoding='utf-8', errors='surrogateescape').read()
# idempotent: strip any previous injection
for b, e in ((B1, E1), (B2, E2)):
    src = re.sub(re.escape(b) + r".*?" + re.escape(e) + r"\n?", "", src, flags=re.S)

pre  = B1 + "\n" + open(pre_f,  encoding='utf-8').read() + E1 + "\n"
post = B2 + "\n" + open(post_f, encoding='utf-8').read() + E2 + "\n\n"

# The pre-block must land AFTER WORK_DIR is defined (it uses $WORK_DIR's
# siblings) but BEFORE the first cp into /usr/prog.
m = re.search(r"^WORK_DIR=.*$", src, flags=re.M)
if not m:
    raise SystemExit("run.sh has no WORK_DIR assignment -- cannot place the pre-block")
i = m.end()
src = src[:i] + "\n\n" + pre + src[i:]
print("   pre-block inserted after WORK_DIR")

m = list(re.finditer(r"^exit 0\s*$", src, flags=re.M))
j = m[-1].start() if m else len(src)
src = src[:j] + post + src[j:]
print("   post-block inserted before exit")
open(run, 'w', encoding='utf-8', errors='surrogateescape').write(src)
PY
chmod +x "$SW/run.sh"
rm -f "$POST"

echo
echo "Patched."
echo "  software component: $(du -sh "$SW" | cut -f1)  (-> /usr/prog, firmware partition)"
echo "  mod payload:        $(du -sh "$MP" | cut -f1)  (-> /usr/data/anvil, data partition)"
echo "Now run ./pack.sh"
