#!/bin/bash
# ---------------------------------------------------------------------------
# Cross-build libsodium for the Creator 5 Pro (Ingenic mipsel) into the mod's
# prefix root, so that libnacl -- and therefore Moonraker's `authorization`
# component -- stops needing /usr/prog/libsodium/lib.
#
# This is the LAST /usr/prog string in the phase-6 picture. Everything else
# the 3.13 interpreter and its extensions need is either static inside the
# interpreter or built by tools/python-packages/build.sh.
#
# Unlike the interpreter's seven static dependencies, this one MUST be shared:
# libnacl is pure Python and reaches it through ctypes.cdll.LoadLibrary, which
# is dlopen. So it ships as $MODDIR/lib/libsodium.so.26.2.0 with its soname
# symlink and the `libsodium.so` development symlink -- and that last one is
# not decoration, it is the FIRST name libnacl asks dlopen for.
#
# Same gcc-wrapper trick as tools/python/build.sh: -EL -mnan=2008 baked into
# the driver, so libsodium's libtool link lines cannot lose them. Gated at
# e_flags=0x70001407 (a shared object, so EF_MIPS_PIC is set and it reads
# ...07 where the interpreter's executable reads ...05) before anything ships.
#
#     ./build-libsodium.sh                 # in docker
#     ./build-libsodium.sh --in-container  # the actual build
# ---------------------------------------------------------------------------
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="${REPO:-/home/shish/firmware/.claude/worktrees/s6-vs-runit}"
TOOLCHAIN_HOST="$REPO/work/.mips-toolchain/mips-gcc720-glibc229"
SODIUM_VER="${SODIUM_VER:-1.0.20}"
SODIUM_SHA256=ebb65ef6ca439333c2bb41a0c1990587288da07f6c7fd07cb3a18cc18d30ce19
PREFIX=/usr/data/anvil

if [ "${1:-}" != "--in-container" ]; then
    [ -x "$TOOLCHAIN_HOST/bin/mips-linux-gnu-gcc" ] || {
        echo "!! no toolchain at $TOOLCHAIN_HOST" >&2; exit 1; }
    exec docker run --rm \
        -v "$TOOLCHAIN_HOST":/toolchain:ro \
        -v "$HERE":/work \
        -e SODIUM_VER="$SODIUM_VER" -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
        -w /work debian:bookworm bash /work/build-libsodium.sh --in-container
fi

# ======================================================= in the container ===
START=$(date +%s)
export DEBIAN_FRONTEND=noninteractive
TC=/toolchain; W=/work; SRC=$W/src; B=$W/b-sodium; OUT=$W/out
rm -rf "$B"; mkdir -p "$SRC" "$B" "$OUT"
log() { echo; echo "===== $* ====="; }

log "apt"
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
    build-essential curl ca-certificates file xz-utils >/dev/null

# ---- the wrappers: -EL -mnan=2008 on every compile AND every link ----------
log "toolchain wrappers"
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

# ---- gate the wrapper before building anything on top of it ---------------
eflags() { mips-linux-gnu-readelf -h "$1" | sed -n 's/.*Flags: *\(0x[0-9a-f]*\).*/\1/p'; }
echo 'int main(void){return 0;}' > /tmp/t.c
mips-linux-gnu-gcc /tmp/t.c -o /tmp/t
[ "$(eflags /tmp/t)" = "0x70001405" ] || {
    echo "!! wrapper produces $(eflags /tmp/t), not 0x70001405" >&2; exit 1; }
echo "wrapper gate ok: $(eflags /tmp/t)"

# ---- fetch ----------------------------------------------------------------
log "libsodium $SODIUM_VER"
TAR="$SRC/libsodium-$SODIUM_VER.tar.gz"
[ -f "$TAR" ] || curl -fsSL -o "$TAR" \
    "https://github.com/jedisct1/libsodium/releases/download/$SODIUM_VER-RELEASE/libsodium-$SODIUM_VER.tar.gz"
echo "$SODIUM_SHA256  $TAR" | sha256sum -c - || {
    echo "!! sha256 mismatch: $(sha256sum "$TAR")" >&2; exit 1; }
tar -xzf "$TAR" -C "$B"
cd "$B/libsodium-$SODIUM_VER"

# ---- configure ------------------------------------------------------------
# --disable-static: nothing links it statically and a .a would only be
#   trimmed away again.
# --host is what makes autoconf reach for the mips-linux-gnu- prefixed tools
#   in the wrapper directory, which is the whole point of the wrappers.
# libsodium's runtime feature probes are AC_RUN_IFELSE with cross defaults
#   supplied, so nothing here needs qemu.
log "configure"
./configure \
    --host=mips-linux-gnu \
    --prefix="$PREFIX" \
    --disable-static \
    --enable-shared \
    --with-pic \
    CFLAGS="-O2 -fPIC" \
    > "$W/sodium-configure.log" 2>&1 || { tail -40 "$W/sodium-configure.log"; exit 1; }

log "make"
make -j"$(nproc)" > "$W/sodium-make.log" 2>&1 || { tail -60 "$W/sodium-make.log"; exit 1; }

STAGE=$W/stage-sodium
rm -rf "$STAGE"; mkdir -p "$STAGE"
make install DESTDIR="$STAGE" >> "$W/sodium-make.log" 2>&1

# ---- the ABI gate, on the object that ships -------------------------------
log "ABI gate"
SO=$(readlink -f "$STAGE$PREFIX/lib/libsodium.so")
file "$SO"
mips-linux-gnu-readelf -h "$SO" | sed -n '/Class\|Data\|Type\|Flags/p'
F=$(eflags "$SO")
[ "$F" = "0x70001407" ] || { echo "!! e_flags $F, expected 0x70001407" >&2; exit 1; }
# The words that matter are decoded by readelf out of e_flags itself, on the
# header's Flags line -- `.MIPS.abiflags` (readelf -A) reports the ISA and the
# FP ABI but not the NaN encoding, so the header is where nan2008 is read.
FLAGLINE=$(mips-linux-gnu-readelf -h "$SO" | sed -n 's/.*Flags: *//p')
echo "  decoded: $FLAGLINE"
for w in nan2008 o32 mips32r2; do
    case ",$FLAGLINE," in
        *"$w"*) ;;
        *) echo "!! e_flags does not decode to $w: $FLAGLINE" >&2; exit 1 ;;
    esac
done
mips-linux-gnu-readelf -A "$SO" | sed -n '/ISA\|FP ABI/p'
echo "-- SONAME / NEEDED"
mips-linux-gnu-readelf -d "$SO" | sed -n '/SONAME\|NEEDED/p'

mips-linux-gnu-strip --strip-unneeded "$SO"

# ---- what ships: lib/ only. include/ and pkgconfig are build-time. --------
log "stage"
TREE=$W/sodium-tree
rm -rf "$TREE"; mkdir -p "$TREE/lib"
cp -a "$STAGE$PREFIX"/lib/libsodium.so* "$TREE/lib/"
rm -f "$TREE"/lib/*.la
ls -l "$TREE/lib"
tar -czf "$OUT/sodium.tgz" -C "$TREE" lib
chown -R "${HOST_UID:-0}:${HOST_GID:-0}" "$OUT" "$W"/sodium-*.log "$SRC" 2>/dev/null || true
echo
echo "sodium.tgz: $(du -h "$OUT/sodium.tgz" | cut -f1)   ($(($(date +%s)-START))s)"
