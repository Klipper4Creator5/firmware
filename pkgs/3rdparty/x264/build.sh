#!/usr/bin/env bash
# x264 -- static H.264 encoder for anvil-ffmpeg.
#
# NOT AUTOTOOLS, like zlib: x264's configure is hand-written. It does take
# --host, but it wants --cross-prefix rather than finding $host-gcc on PATH,
# and it rejects the --prefix pkg_build would prepend alongside. So
# PKG_CONFIGURE_AUTO=0 and the flags are spelled here.
#
# --disable-asm: the assembly paths are x86/ARM only, and the MIPS build has
# no hand-written ones to lose. Left on, configure probes for nasm and fails
# on a machine that has it.
#
# --disable-cli: we want libx264.a, not the x264 program. That also removes the
# only thing in the tree that wants a demuxer.
set -euo pipefail
. ./bin/common.sh
. pkgs/lib.sh

pkg_begin x264 || exit 0
pkg_toolchain
pkg_unpack "$X264_TGZ"

PKG_CONFIGURE_AUTO=0
export CFLAGS="-O2 -fPIC -D_FILE_OFFSET_BITS=64"

pkg_build "x264-$X264_VERSION" \
    --host="$PKG_HOST" \
    --cross-prefix="$PKG_HOST-" \
    --prefix="$MODDIR" \
    --enable-static \
    --enable-pic \
    --disable-cli \
    --disable-asm \
    --disable-opencl

pkg_ship "include/x264.h" "include/x264_config.h" \
         "lib/libx264.a" "lib/pkgconfig/x264.pc"
pkg_end
