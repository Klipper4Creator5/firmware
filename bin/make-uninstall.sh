#!/usr/bin/env bash
# Build a USB package that reverts the mod and returns the printer to stock.
#
# Design note, learned from test/sim-roundtrip.sh: the stock installer runs
#     cd /usr/prog/PROGRAM/software && ls | grep -v temp | xargs rm -rf
# which deletes the top-level firmwareExe as well as the old version dirs.
# It only survives because the stock run.sh copies it back out of the payload.
# So an uninstall package that ships only a revert script leaves the printer
# with no UI binary at all -- a blank screen.
#
# Therefore the uninstall package is the PRISTINE stock software component
# (which restores the stock app_startup.sh, start.sh, passwd, shadow and
# firmwareExe by itself, simply by being installed) plus a small cleanup
# block that removes the mod payload.
set -euo pipefail
. "$(dirname "$0")/common.sh"

[ -d work/outer ] || { echo "run bin/unpack.sh first" >&2; exit 1; }
SW_TARBALL=$(ls -1 work/outer/software-*.tar.xz 2>/dev/null | head -n1)
[ -n "$SW_TARBALL" ] || { echo "no stock software component in work/outer" >&2; exit 1; }

rm -rf work/uninst work/uninst-sw
mkdir -p work/uninst work/uninst-sw work/out

echo ">> extracting PRISTINE stock component (not the patched tree)"
tar -xf "$SW_TARBALL" -C work/uninst-sw
echo "   $(find work/uninst-sw -type f | wc -l) files"

echo ">> appending cleanup block"
cat > work/.uninst-block.sh <<'EOF'
# Remove the mod payload. The stock files (app_startup.sh, start.sh, passwd,
# shadow, firmwareExe) have already been restored by the stock run.sh above,
# simply because this package carries the pristine originals.
MODDIR=/usr/data/mod
case "$MODDIR" in
    /usr/data/?*) ;;
    *) exit 0 ;;
esac
{
  echo "=== mod uninstall `date 2>/dev/null` ==="
  [ -f $MODDIR/nginx/logs/nginx.pid ] && kill `cat $MODDIR/nginx/logs/nginx.pid` 2>/dev/null
  killall dropbear helix-screen helix-watchdog helix-splash 2>/dev/null
  # Keep backup/ and the logs; drop everything we installed.
  rm -rf $MODDIR/bin $MODDIR/www $MODDIR/nginx $MODDIR/helixscreen \
         $MODDIR/config $MODDIR/boot.sh $MODDIR/mod.conf $MODDIR/VERSION
  echo "mod payload removed; /usr/data/config and $MODDIR/backup kept"
  echo "=== uninstall done ==="
} >> /usr/data/mod-uninstall.log 2>&1
sync
EOF
python3 - work/uninst-sw/run.sh work/.uninst-block.sh <<'PY'
import sys, re
run, extra = sys.argv[1], sys.argv[2]
B, E = "# >>> anvil uninstall >>>", "# <<< anvil uninstall <<<"
s = open(run, encoding='utf-8', errors='surrogateescape').read()
s = re.sub(re.escape(B) + r".*?" + re.escape(E) + r"\n?", "", s, flags=re.S)
block = open(extra, encoding='utf-8').read()
m = list(re.finditer(r"^exit 0\s*$", s, flags=re.M))
i = m[-1].start() if m else len(s)
s = s[:i] + B + "\n" + block + E + "\n\n" + s[i:]
open(run, 'w', encoding='utf-8', errors='surrogateescape').write(s)
print("   cleanup block appended to the stock run.sh")
PY
rm -f work/.uninst-block.sh
chmod +x work/uninst-sw/run.sh

echo ">> regenerating md5sum.list"
( cd work/uninst-sw && rm -f md5sum.list && \
  find . -type f ! -name md5sum.list -print0 | sort -z | xargs -0 md5sum > md5sum.list )

STOCK_SW_VER=$(cat work/.stock_sw_ver 2>/dev/null || echo 1.9.7)
# Plain tar -- the stock installer runs a bare `tar -xvf` (see bin/pack.sh).
tar -cf "work/uninst/software-${STOCK_SW_VER}.tar.xz" -C work/uninst-sw .
cp -f work/outer/runFirmwareExe.sh work/uninst/
for f in start.img end.img play; do
    [ -f "work/outer/$f" ] && cp -f "work/outer/$f" work/uninst/
done

tar -cf - -C work/uninst . | openssl des3 -salt -md md5 -k "$FF_KEY" \
    > work/out/Creator5Pro-uninstall.tgz 2>/dev/null
cp -f work/out/Creator5Pro-uninstall.tgz work/out/Creator5-uninstall.tgz

echo
echo "Uninstall packages:"
ls -lh work/out/*uninstall*.tgz | awk '{print "   "$9"  "$5}'
echo
echo "Put these on a spare USB stick BEFORE you flash anything else."
echo "They reinstall the stock component and delete the mod payload."
