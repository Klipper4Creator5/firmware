#!/bin/sh
# Same two stacks, built against musl instead of static glibc, with s6 and
# execline installed into SEPARATE prefixes so the size of s6 alone is visible.
set -e
HOST=mipsel-linux-musl
OUT=/out
SK=/build/sysroot        # skalibs (headers + .a only, not shipped)
EX=/build/execline        # execline (only needed if run scripts use it)
# s6 resolves its own helper programs (s6-ftrigrd, which every waiting verb
# needs) through a prefix baked in at compile time, so --prefix must be the
# path the printer will actually see. runit has no such constraint: its tools
# find each other on PATH.
# /usr/data/anvil is the mod's --prefix root: bin/, lib/, libexec/, share/,
# etc/ directly inside it, the way any ./configure --prefix install expects.
# Anything we build later (python, a newer moonraker) lands in the same tree.
S6=/usr/data/anvil
STAGE=/build/stage
mkdir -p $OUT/s6 $OUT/execline $OUT/runit /build/src
cd /build/src

fetch() { echo ">> fetching $1"; curl -sSLO "$1"; }
fetch https://skarnet.org/software/skalibs/skalibs-2.15.1.0.tar.gz
fetch https://skarnet.org/software/execline/execline-2.9.9.2.tar.gz
fetch https://skarnet.org/software/s6/s6-2.15.1.0.tar.gz
fetch http://smarden.org/runit/runit-2.1.2.tar.gz
for t in *.tar.gz; do tar -xzf "$t"; done

export CC=$HOST-gcc
# See build.sh: without LFS, readdir() returns EOVERFLOW on this box and no
# supervisor can scan its own service directory.
export CFLAGS="-Os -D_FILE_OFFSET_BITS=64"

SYSDEPS="--with-sysdep-devurandom=yes --with-sysdep-posixspawnearlyreturn=no --with-sysdep-procselfexe=/proc/self/exe --with-sysdep-selectinfinite=yes"

echo "===== skalibs (musl) ====="
cd /build/src/skalibs-2.15.1.0
./configure --host=$HOST --prefix=$SK --disable-shared --enable-static --enable-static-libc $SYSDEPS
make -j4
make install

echo "===== execline (musl) ====="
cd /build/src/execline-2.9.9.2
./configure --host=$HOST --prefix=$EX --with-sysdeps=$SK/lib/skalibs/sysdeps --with-include=$SK/include --with-lib=$SK/lib --disable-shared --enable-static --enable-static-libc
make -j4
make install

echo "===== s6 (musl) ====="
cd /build/src/s6-2.15.1.0
./configure --host=$HOST --prefix=$S6 --with-sysdeps=$SK/lib/skalibs/sysdeps --with-include=$SK/include --with-include=$EX/include --with-lib=$SK/lib --with-lib=$EX/lib --disable-shared --enable-static --enable-static-libc
make -j4
make install DESTDIR=$STAGE

echo "===== runit (musl) ====="
printf '#!/bin/sh\nexec %s-ar "$@"\n' "$HOST" > /usr/local/bin/ar
printf '#!/bin/sh\nexec %s-ranlib "$@"\n' "$HOST" > /usr/local/bin/ranlib
chmod +x /usr/local/bin/ar /usr/local/bin/ranlib
cd /build/src/admin/runit-2.1.2/src
echo "$HOST-gcc -Os -Wall -D_FILE_OFFSET_BITS=64" > conf-cc
echo "$HOST-gcc -static" > conf-ld
make || echo "RUNIT BUILD FAILED"

echo "===== collect ====="
mkdir -p $OUT/s6/bin $OUT/s6/libexec
cp $STAGE$S6/bin/* $OUT/s6/bin/
if [ -d $STAGE$S6/libexec ]; then
    cp $STAGE$S6/libexec/* $OUT/s6/libexec/
    echo "s6 libexec: `ls $STAGE$S6/libexec | tr '\n' ' '`"
else
    echo "s6 has no libexec dir; helpers live in bin"
fi
cp $EX/bin/* $OUT/execline/
for b in runsv runsvdir sv svlogd chpst; do
    if [ -f /build/src/admin/runit-2.1.2/src/$b ]; then cp /build/src/admin/runit-2.1.2/src/$b $OUT/runit/; else echo "MISSING $b"; fi
done
$HOST-strip $OUT/s6/bin/* $OUT/s6/libexec/* $OUT/execline/* $OUT/runit/* 2>/dev/null || true

echo "===== results ====="
echo "s6:       `ls $OUT/s6 | wc -l` binaries, `du -sb $OUT/s6 | cut -f1` bytes"
echo "execline: `ls $OUT/execline | wc -l` binaries, `du -sb $OUT/execline | cut -f1` bytes"
echo "runit:    `ls $OUT/runit | wc -l` binaries, `du -sb $OUT/runit | cut -f1` bytes"
echo "-- the s6 binaries we would actually ship --"
ls -l $OUT/s6 | head -50
file $OUT/s6/s6-supervise $OUT/runit/runsv
