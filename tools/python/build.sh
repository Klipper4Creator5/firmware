#!/bin/bash
# ---------------------------------------------------------------------------
# Cross-build CPython 3.13 for the FlashForge Creator 5 Pro (Ingenic mipsel).
#
# THIS IS THE MEASUREMENT HARNESS, NOT THE BUILD. pkg/python produces the
# interpreter a package ships; this is the same build -- same flags, wrappers
# and gates -- re-exec'd inside a throwaway debian:bookworm, which is how the
# numbers in README.md were measured and the fastest way to try a change.
#
# Target ABI, measured, non-negotiable:
#   e_flags = 0x70001405  =  ELF32 / little-endian / NAN2008 / O32 /
#                            hard-float / mips32r2
#   loader  = /lib/ld-linux-mipsn8.so.1 , rootfs glibc 2.33
#
# Toolchain: the repo's Ingenic gcc 7.2 / glibc 2.29 cross compiler. musl is
# forbidden -- a musl-linked interpreter cannot dlopen a glibc c_helper.so,
# which is exactly how klippy loads it.
#
# `-EL -mnan=2008` must reach BOTH the compile and the link of every object.
# Several build systems do not forward CFLAGS to their link line, so PATH
# wrappers bake the two flags into the driver itself.
#
# Usage:
#     ./tools/python/build.sh                  # the whole thing, in docker
#     ./tools/python/build.sh --in-container   # the actual build
# ---------------------------------------------------------------------------
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="${REPO:-$(cd "$HERE/../.." && pwd)}"
TOOLCHAIN_HOST="$REPO/work/.mips-toolchain/mips-gcc720-glibc229"

# --------------------------------------------------------------- versions ---
# Kept in step with versions.env by hand, duplicated rather than sourced so a
# version can be bumped HERE first to see what breaks before it becomes a pin.
PY_VER="${PY_VER:-3.13.7}"
ZLIB_VER=1.3.1
OSSL_VER=3.0.15
FFI_VER=3.4.6
SQLITE_TAR=sqlite-autoconf-3460100      # 3.46.1
XZ_VER=5.4.7
BZIP2_VER=1.0.8
EXPAT_VER=2.6.4
EXPAT_TAG=R_2_6_4
# The mod's prefix root on the printer, and the same --prefix bin/payload.sh
# builds with. The one difference: payload.sh deletes the `python3` symlink (and
# idle3/pydoc3/*-config) before staging, so $MODDIR/bin on PATH cannot quietly
# change what `python3` means. This harness leaves the tree as `make install`
# produced it, because the sizes reported below are of that tree.
PREFIX=/usr/data/anvil

# ------------------------------------------------------- docker wrapper -----
if [ "${1:-}" != "--in-container" ]; then
    [ -x "$TOOLCHAIN_HOST/bin/mips-linux-gnu-gcc" ] || {
        echo "!! no toolchain at $TOOLCHAIN_HOST" >&2
        echo "   run ./bin/fetch-assets.sh, then any build (bin/payload.sh unpacks it)" >&2
        exit 1; }
    exec docker run --rm \
        -v "$TOOLCHAIN_HOST":/toolchain:ro \
        -v "$HERE":/work \
        -e PY_VER="$PY_VER" -e PY_EXTRA_CONFIGURE="${PY_EXTRA_CONFIGURE:-}" \
        -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
        -w /work debian:bookworm \
        bash /work/build.sh --in-container
fi

# =========================== everything below runs inside the container ======
START=$(date +%s)
export DEBIAN_FRONTEND=noninteractive
TC=/toolchain
W=/work
SRC=$W/src            # tarball cache (survives between runs)
B=$W/build            # scratch: unpacked trees
HOSTPY=$W/hostpy      # the x86-64 build-Python 3.13 (--with-build-python)
DEP=$W/deproot        # cross-built C libraries, STATIC.  Not shipped.
STAGE=$W/stage        # DESTDIR: what actually goes on the printer
OUT=$W/out
mkdir -p "$SRC" "$B" "$HOSTPY" "$DEP" "$OUT"

log() { echo; echo "===== $* ====="; }

log "apt: build dependencies"
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
    build-essential curl ca-certificates pkg-config perl file xz-utils \
    zlib1g-dev libssl-dev libffi-dev >/dev/null

# ------------------------------------------------------- the wrappers -------
# -EL -mnan=2008 on every invocation, compile or link.  Without -mnan=2008 the
# objects are legacy-NaN and the kernel refuses to load the result.
log "toolchain wrappers (-EL -mnan=2008 baked in)"
mkdir -p /opt/xw/bin
for t in gcc g++ cpp; do
    cat > /opt/xw/bin/mips-linux-gnu-$t <<EOF
#!/bin/sh
exec $TC/bin/mips-linux-gnu-$t -EL -mnan=2008 "\$@"
EOF
    chmod +x /opt/xw/bin/mips-linux-gnu-$t
done
for t in ar as ld nm objcopy objdump ranlib readelf strip strings size; do
    ln -sf $TC/bin/mips-linux-gnu-$t /opt/xw/bin/mips-linux-gnu-$t
done
export PATH=/opt/xw/bin:$PATH
mips-linux-gnu-gcc --version | head -1

# gate the wrapper itself before building 300MB on top of it
echo 'int main(void){return 0;}' > /tmp/abi.c
mips-linux-gnu-gcc /tmp/abi.c -o /tmp/abi.out
FLAGS=$(mips-linux-gnu-readelf -h /tmp/abi.out | awk '/Flags:/{print $2}' | tr -d ,)
echo "wrapper produces e_flags=$FLAGS"
[ "$FLAGS" = "0x70001405" ] || { echo "!! wrong ABI from the wrapper"; exit 1; }

# No sha256 here on purpose: versions.env holds the pins and
# bin/fetch-assets.sh enforces them for anything that ships. This harness
# downloads whatever version you point it at, which is what makes it useful
# for deciding whether a bump is safe BEFORE it becomes a pin.
fetch() {  # fetch <url>  -> $SRC/<basename>, cached
    local url=$1 f="$SRC/$(basename "$1")"
    [ -s "$f" ] || { echo ">> $url"; curl -sSLf -o "$f.part" "$url" && mv "$f.part" "$f"; }
}
log "fetch sources"
fetch https://www.python.org/ftp/python/$PY_VER/Python-$PY_VER.tgz
fetch https://github.com/madler/zlib/releases/download/v$ZLIB_VER/zlib-$ZLIB_VER.tar.gz
fetch https://github.com/openssl/openssl/releases/download/openssl-$OSSL_VER/openssl-$OSSL_VER.tar.gz
fetch https://github.com/libffi/libffi/releases/download/v$FFI_VER/libffi-$FFI_VER.tar.gz
fetch https://www.sqlite.org/2024/$SQLITE_TAR.tar.gz
fetch https://github.com/tukaani-project/xz/releases/download/v$XZ_VER/xz-$XZ_VER.tar.gz
fetch https://sourceware.org/pub/bzip2/bzip2-$BZIP2_VER.tar.gz
fetch https://github.com/libexpat/libexpat/releases/download/$EXPAT_TAG/expat-$EXPAT_VER.tar.gz

unpack() { rm -rf "$B/${2}"; tar -xf "$SRC/$1" -C "$B"; }

# ============================================ 1. host CPython 3.13 ==========
# Cross-building CPython needs a build-Python of the *same* version: the
# Makefile runs it to freeze modules, generate deepfreeze sources and byte
# compile the stdlib.  A distro python3.11 will not do.
if [ ! -x "$HOSTPY/bin/python3.13" ]; then
    log "host CPython $PY_VER (x86-64, for --with-build-python)"
    unpack Python-$PY_VER.tgz Python-$PY_VER
    cd "$B/Python-$PY_VER"
    ./configure --prefix="$HOSTPY" --without-ensurepip >/dev/null
    make -j"$(nproc)" >/dev/null
    make install >/dev/null
    cd /
else
    log "host CPython already built -- reusing $HOSTPY"
fi
"$HOSTPY/bin/python3.13" -VV

# All STATIC (-fPIC) into $DEP, so the shipped tree has no .so of ours to find
# at runtime: no LD_LIBRARY_PATH for dependencies, no chance of picking up
# FlashForge's /usr/prog copies, nothing to version-skew. The cost is a few MB
# of duplicated libcrypto between _ssl.so and _hashlib.so.
export CC=mips-linux-gnu-gcc
export CXX=mips-linux-gnu-g++
export AR=mips-linux-gnu-ar
export RANLIB=mips-linux-gnu-ranlib
export STRIP=mips-linux-gnu-strip
export CFLAGS="-O2 -fPIC -D_FILE_OFFSET_BITS=64"
export CPPFLAGS="-I$DEP/include"
export LDFLAGS="-L$DEP/lib"
# pkg-config must see ONLY our sysroot, never the container's /usr/lib.
export PKG_CONFIG_LIBDIR="$DEP/lib/pkgconfig"
export PKG_CONFIG_PATH="$DEP/lib/pkgconfig"
HOSTTRIPLE=mips-linux-gnu
BUILDTRIPLE=x86_64-linux-gnu

log "zlib $ZLIB_VER"
unpack zlib-$ZLIB_VER.tar.gz zlib-$ZLIB_VER
cd "$B/zlib-$ZLIB_VER"
CHOST=$HOSTTRIPLE ./configure --prefix="$DEP" --static >/dev/null
make -j"$(nproc)" >/dev/null && make install >/dev/null

log "openssl $OSSL_VER"
unpack openssl-$OSSL_VER.tar.gz openssl-$OSSL_VER
cd "$B/openssl-$OSSL_VER"
# linux-mips32 is the O32 target. openssldir points at where the interpreter
# will look for certs ON THE PRINTER, not at a build path.
#
# Two traps, both hit for real:
#  * `no-docs` only exists from OpenSSL 3.1; on 3.0.15 it is a hard error.
#  * the linux-mips32 target hardcodes `-mips2` into its cflags, and this
#    toolchain defaults to -mfp64, which gcc rejects below mips32r2. User
#    cflags land AFTER the target's, so appending -mips32r2 puts the ISA back.
#    If a future OpenSSL orders them the other way, linux-generic32 (portable
#    C) is the fallback and is exercised below.
OSSL_TARGET=linux-mips32
OSSL_ISA=-mips32r2
./Configure $OSSL_TARGET \
    --prefix="$DEP" --libdir=lib --openssldir=$PREFIX/ssl \
    no-shared no-tests \
    -fPIC -O2 $OSSL_ISA -D_FILE_OFFSET_BITS=64 >/dev/null
if ! make -j"$(nproc)" >"$OUT/openssl.log" 2>&1; then
    echo "!! $OSSL_TARGET failed; falling back to linux-generic32 (no mips asm)"
    tail -20 "$OUT/openssl.log"
    make distclean >/dev/null 2>&1 || true
    ./Configure linux-generic32 \
        --prefix="$DEP" --libdir=lib --openssldir=$PREFIX/ssl \
        no-shared no-tests no-asm \
        -fPIC -O2 -D_FILE_OFFSET_BITS=64 >/dev/null
    make -j"$(nproc)" >"$OUT/openssl.log" 2>&1
fi
make install_sw >/dev/null

log "libffi $FFI_VER"
unpack libffi-$FFI_VER.tar.gz libffi-$FFI_VER
cd "$B/libffi-$FFI_VER"
./configure --host=$HOSTTRIPLE --build=$BUILDTRIPLE --prefix="$DEP" \
    --disable-shared --enable-static --with-pic --disable-docs >/dev/null
make -j"$(nproc)" >/dev/null && make install >/dev/null

log "sqlite ($SQLITE_TAR) -- THE reason this whole exercise exists"
unpack $SQLITE_TAR.tar.gz $SQLITE_TAR
cd "$B/$SQLITE_TAR"
./configure --host=$HOSTTRIPLE --build=$BUILDTRIPLE --prefix="$DEP" \
    --disable-shared --enable-static --with-pic \
    --disable-readline --disable-editline >/dev/null
make -j"$(nproc)" >/dev/null && make install >/dev/null

log "xz (liblzma) $XZ_VER"
unpack xz-$XZ_VER.tar.gz xz-$XZ_VER
cd "$B/xz-$XZ_VER"
./configure --host=$HOSTTRIPLE --build=$BUILDTRIPLE --prefix="$DEP" \
    --disable-shared --enable-static --with-pic \
    --disable-xz --disable-xzdec --disable-lzmadec --disable-lzmainfo \
    --disable-scripts --disable-doc --disable-nls >/dev/null
make -j"$(nproc)" >/dev/null && make install >/dev/null

log "bzip2 $BZIP2_VER"
unpack bzip2-$BZIP2_VER.tar.gz bzip2-$BZIP2_VER
cd "$B/bzip2-$BZIP2_VER"
# bzip2 has no configure; drive its Makefile directly.
make -j"$(nproc)" libbz2.a CC="$CC" AR="$AR" RANLIB="$RANLIB" \
    CFLAGS="-O2 -fPIC -D_FILE_OFFSET_BITS=64 -Wall -Winline" >/dev/null
install -m644 libbz2.a "$DEP/lib/"
install -m644 bzlib.h  "$DEP/include/"

log "expat $EXPAT_VER"
unpack expat-$EXPAT_VER.tar.gz expat-$EXPAT_VER
cd "$B/expat-$EXPAT_VER"
./configure --host=$HOSTTRIPLE --build=$BUILDTRIPLE --prefix="$DEP" \
    --disable-shared --enable-static --with-pic \
    --without-docbook --without-examples --without-tests >/dev/null
make -j"$(nproc)" >/dev/null && make install >/dev/null

echo "-- $DEP/lib --"; ls "$DEP/lib"

# ============================================ 3. CPython, cross =============
log "CPython $PY_VER cross for $HOSTTRIPLE"
unpack Python-$PY_VER.tgz Python-$PY_VER
cd "$B/Python-$PY_VER"

# Answers configure cannot probe because it may not run target binaries.
cat > "$B/config.site" <<'EOF'
ac_cv_file__dev_ptmx=yes
ac_cv_file__dev_ptc=no
ac_cv_buggy_getaddrinfo=no
ac_cv_little_endian_double=yes
ac_cv_big_endian_double=no
ac_cv_mixed_endian_double=no
ac_cv_working_tzset=yes
ac_cv_have_long_long_format=yes
ac_cv_no_strict_aliasing=no
ac_cv_pthread_system_supported=yes
EOF

export CONFIG_SITE="$B/config.site"
export CPPFLAGS="-I$DEP/include"
export LDFLAGS="-L$DEP/lib"
# -latomic: 64-bit atomics on mips32 are out-of-line calls into libatomic, and
#   CPython 3.13's _Py_atomic_* on 64-bit types needs them.
# -lm: the sqlite/lzma/expat libraries here are STATIC, and a .a carries no
#   DT_NEEDED on libm, so configure's sqlite3 link probe fails with undefined
#   references and 3.13 silently records _sqlite3 as "missing" -- the one
#   module this whole build exists for. A probe failure, not a compile
#   failure, so nothing in the build output says why.
export LIBS="-latomic -lm"
export CFLAGS="-O2 -D_FILE_OFFSET_BITS=64"
# Bypass pkg-config for sqlite and state the static link line outright, so the
# -lm above cannot be reordered out from under the probe.
export LIBSQLITE3_CFLAGS="-I$DEP/include"
export LIBSQLITE3_LIBS="-L$DEP/lib -lsqlite3 -lm"

./configure \
    --host=$HOSTTRIPLE --build=$BUILDTRIPLE \
    --with-build-python="$HOSTPY/bin/python3.13" \
    --prefix=$PREFIX \
    --disable-shared \
    --without-ensurepip \
    --disable-test-modules \
    --with-openssl="$DEP" \
    --with-system-expat \
    ${PY_EXTRA_CONFIGURE:-} 2>&1 | tee "$OUT/configure.log" | tail -60

echo "-- configure: modules it decided it could not build --"
grep -iE 'could not be built|missing|failed to build' -A6 "$OUT/configure.log" | tail -40 || true

make -j"$(nproc)" 2>&1 | tee "$OUT/make.log" | tail -40
echo "-- build: modules that failed --"
grep -iE 'necessary bits|could not be found|failed to build these' -A10 "$OUT/make.log" | tail -40 || true

rm -rf "$STAGE"
make install DESTDIR="$STAGE" 2>&1 | tail -20

# ============================================ 4. gates + package ============
# NO ABI GATE HERE. This used to pin e_flags per ELF type -- strict enough to
# be wrong, since the low three bits are NOREORDER/PIC/CPIC and vary between
# objects of identical ABI. qa/replica/test_abi.py asks the question once,
# over the installed filesystem, masking those bits off.

# _sqlite3 is the reason this build exists.  Its absence must be a hard error,
# not a line in a 400-line make log that nobody reads.
if ! ls "$STAGE$PREFIX/lib/python3.13/lib-dynload/"_sqlite3*.so >/dev/null 2>&1; then
    echo "!! NO _sqlite3 MODULE WAS BUILT -- see $OUT/configure.log and config.log"
    exit 1
fi
echo "_sqlite3 present: $(basename "$(ls "$STAGE$PREFIX/lib/python3.13/lib-dynload/"_sqlite3*.so)")"

echo "-- NEEDED of the interpreter --"
mips-linux-gnu-readelf -d "$STAGE$PREFIX/bin/python3.13" | grep -E 'NEEDED|RPATH|RUNPATH' || true
echo "-- lib-dynload --"
ls "$STAGE$PREFIX/lib/python3.13/lib-dynload/" | sed 's/\.cpython.*//' | sort | tr '\n' ' '; echo

log "sizes"
FULL=$(du -sm "$STAGE" | cut -f1)
# trimmed: what would actually ship
rm -rf "$W/stage-trim"
cp -a "$STAGE" "$W/stage-trim"
rm -rf "$W/stage-trim$PREFIX/lib/python3.13/test" \
       "$W/stage-trim$PREFIX/lib/python3.13/idlelib" \
       "$W/stage-trim$PREFIX/lib/python3.13/tkinter" \
       "$W/stage-trim$PREFIX/lib/python3.13/turtledemo" \
       "$W/stage-trim$PREFIX/lib/python3.13/config-"* \
       "$W/stage-trim$PREFIX/include" \
       "$W/stage-trim$PREFIX/share"
find "$W/stage-trim" -name '__pycache__' -prune -exec rm -rf {} + 2>/dev/null || true
find "$W/stage-trim" -name '*.a' -delete
mips-linux-gnu-strip "$W/stage-trim$PREFIX/bin/python3.13" 2>/dev/null || true
find "$W/stage-trim$PREFIX/lib/python3.13/lib-dynload" -name '*.so' \
    -exec mips-linux-gnu-strip {} + 2>/dev/null || true
TRIM=$(du -sm "$W/stage-trim" | cut -f1)
echo "staged  : ${FULL} MB, $(find "$STAGE" -type f | wc -l) files"
echo "trimmed : ${TRIM} MB, $(find "$W/stage-trim" -type f | wc -l) files"

log "tarballs"
# The tarball's root is 'usr/data/anvil/...' relative -- unpack with -C /
( cd "$STAGE" && tar -czf "$OUT/py313-full.tgz" usr )
( cd "$W/stage-trim" && tar -czf "$OUT/py313.tgz" usr )
ls -l "$OUT"/*.tgz
chown -R "${HOST_UID:-0}:${HOST_GID:-0}" "$W" 2>/dev/null || true

END=$(date +%s)
log "done in $(( (END-START)/60 ))m $(( (END-START)%60 ))s"
