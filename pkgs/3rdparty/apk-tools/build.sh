#!/usr/bin/env bash
# apk-tools, cross-compiled for the printer into $APK_TOOLS_BUILD.
#
# THE PACKAGE MANAGER THE PRINTER CARRIES, and the one package here a printer
# actually installs. docs/notes/85-packaging.md records why this replaced opkg.
#
# WHY IT NEEDS A PATCH. apk resolves lib/apk/db, etc/apk/world, etc/apk/arch
# and its lock relative to --root, and takes the SAME root as the destination
# for package files. On this printer / is a read-only squashfs -- measured;
# neither /lib/apk nor /etc/apk can be created -- so the database has to live
# under $MODDIR while files still land at /. Upstream already separates those
# two internally (root_fd and dest_fd, split for `apk extract`);
# prefix.patch defaults the first to $MODDIR and points the second at /.
#
# The build system is upstream's own Makefile rather than its meson: no
# configure step, so pkg_build drives make directly, and no meson cross file
# to keep in step with pkg_toolchain's wrappers.
set -euo pipefail
. ./bin/common.sh
. pkgs/lib.sh

pkg_begin apk-tools || exit 0
pkg_toolchain
pkg_deps
pkg_checkout "$APK_TOOLS_DIR" "apk-tools-$APK_TOOLS_VERSION"

# -p1 and --forward: a patch that has already applied is an error here, not a
# no-op, because the only way that happens is a source tree that was not
# scratch -- and then what builds is not what the pin says.
patch -p1 --forward --directory="$PKG_WORK/src/apk-tools-$APK_TOOLS_VERSION" \
    < "$PKG_DIR/prefix.patch" \
    || pkg_die "prefix.patch does not apply to apk-tools $APK_TOOLS_VERSION -- rebase it against the new pin"

# THE PREFIX IS PASSED IN, not written into the patch: $MODDIR lives in
# bin/common.sh so a recipe cannot spell it differently, which is the trap
# opkg's baked VARDIR, s6's libexecdir and execline's shebangdir all sprang.
# Undefined, prefix.patch folds away to upstream's behaviour.
#
# THROUGH CPPFLAGS, which Make.rules already threads into every compile
# (c_flags), rather than through PKG_MAKE_ARGS: pkg_build expands that
# unquoted, so a -D carrying a quoted string would split into a second word
# and make would take it for a target. The inner '"..."' survives make's
# textual expansion into the recipe's shell, which is what leaves the C
# preprocessor a string literal rather than a bare token.
export CPPFLAGS="-DAPK_DEFAULT_DB_ROOT='\"$MODDIR\"' ${CPPFLAGS:-}"

# THE LEGACY MAKEFILE ASSUMES ALPINE, and this is where it shows. Upstream's
# portability/ shims -- strlcpy among them -- are wired into the MESON build
# only (portability/meson.build probes for each); the Makefile never compiles
# them, because on musl there is nothing to shim. Against this printer's
# glibc 2.29 the link fails on strlcpy alone: memrchr, strchrnul, reallocarray,
# qsort_r and getrandom all predate it.
#
# So one object, compiled from upstream's own shim rather than written here,
# and handed to the link through LDFLAGS.
_src="$PKG_WORK/src/apk-tools-$APK_TOOLS_VERSION"
$CC -O2 -fPIC -I"$_src/portability" -c "$_src/portability/strlcpy.c" \
    -o "$_src/portability/strlcpy.o" \
    || pkg_die "could not compile upstream's strlcpy shim"

# -lpthread -ldl: SEPARATE LIBRARIES on glibc 2.29. They were folded into libc
#   in 2.34, so an Alpine or modern-Debian build links without naming them and
#   this one does not.
# -latomic: mips32 has no 64-bit atomic instructions, so __atomic_load_8 and
#   friends are library calls. Nothing in the error message says "mips"; it
#   says undefined reference, which is why this is written down.
export LDFLAGS="${LDFLAGS:-} $PWD/$_src/portability/strlcpy.o -lpthread -ldl -latomic"

# LUA=no        the lua binding needs an interpreter and ships nothing here.
# ZSTD=no       one more cross-build for a compressor no package of ours uses.
# SCDOC=/bin/true
#               doc/ builds forty man pages with a tool the build image does
#               not carry, and `subdirs` cannot be trimmed from the command
#               line -- Make.rules resets it per recursion level, so a
#               command-line value would be sticky and recurse forever. The
#               empty files this leaves are never shipped: pkg_ship names the
#               binary and nothing else.
# CROSS_COMPILE the Makefile spells $(CROSS_COMPILE)gcc itself; pkg_toolchain's
#               wrappers are what that has to resolve to, so the ABI flags stay
#               in the driver rather than in a CFLAGS line that not every link
#               forwards.
PKG_CONFIGURE=none
# LIBS_apk=-l:libapk.a -- LINK THE LIBRARY IN, do not ship it beside.
# src/Makefile says `LIBS_apk := -lapk` with both libapk.so and libapk.a in the
# output directory, so the linker takes the shared one and the binary comes out
# needing $MODDIR/lib on the loader path. Measured: bare, it dies with
# "libapk.so.3.0.0: cannot open shared object file". $MODDIR/lib is not on the
# default path and anvil-env.sh's ANVIL_LIBS deliberately lists only what some
# process was measured to map -- so the fix is to need nothing, which is what
# CPython already does with its own seven static dependencies.
#
# The value is ONE WHITESPACE-FREE TOKEN because pkg_build expands
# PKG_MAKE_ARGS unquoted, and it needs two archives in dependency order:
# libapk.a calls into libfetch, which is a separate archive the shared build
# had linked for it. --start-group is what makes the order stop mattering,
# and -Wl, is what gets both past make and the shell in one word.
#
# ssl, crypto and z are in the GROUP rather than left to $(LIBS) for the same
# reason: cmd_ld puts $(LIBS) BEFORE $(LIBS_apk), so with everything static
# the archives that need those symbols are read after the archives that
# define them and the linker has already moved on. It is the .so build that
# hid this -- a shared libapk carried its own DT_NEEDED and needed no order.
# SBINDIR IS $MODDIR/bin, NOT $MODDIR/sbin, because anvil-env.sh puts only
# bin/ on PATH -- and an `apk` a printer owner cannot type is not a package
# manager.
PKG_MAKE_ARGS="CROSS_COMPILE=$PKG_HOST- LUA=no ZSTD=no SCDOC=/bin/true
               LIBS_apk=-Wl,--start-group,-l:libapk.a,libfetch/libfetch.a,-lssl,-lcrypto,-lz,--end-group
               SBINDIR=$MODDIR/bin LIBDIR=$MODDIR/lib CONFDIR=$MODDIR/etc/apk
               MANDIR=$MODDIR/share/man DOCDIR=$MODDIR/share/doc/apk
               INCLUDEDIR=$MODDIR/include PKGCONFIGDIR=$MODDIR/lib/pkgconfig"

pkg_build "apk-tools-$APK_TOOLS_VERSION"

# WHAT IT MAY LINK AGAINST, checked rather than assumed. zlib, openssl and
# libapk are meant to be INSIDE this binary; a build that picked up a shared
# one instead still runs here and fails on a printer, as a missing .so that
# nothing on the loader path provides. The old opkg recipe carried the same
# gate for the same reason -- a link that is not what it was asked to be shows
# up as a NEEDED entry nobody looks at.
#
# The four that ARE allowed are the printer's own glibc, all measured present
# on the machine: libatomic is there because mips32 has no 64-bit atomics.
_needed=$("$PKG_HOST-readelf" -d "$PKG_WORK/stage$MODDIR/bin/apk" 2>/dev/null \
    | awk '/NEEDED/{gsub(/[][]/,"",$5); print $5}')
for _n in $_needed; do
    case "$_n" in
        libc.so.6|libpthread.so.0|libdl.so.2|libatomic.so.1) ;;
        *) printf '%s\n' "$_needed" >&2
           pkg_die "bin/apk links $_n -- zlib, openssl and libapk are meant to be inside it, and nothing else is on this printer's loader path" ;;
    esac
done
pkg_say "$PKG_ID: links only the rootfs's own libraries ($(echo $_needed | tr '\n' ' '))"

# The binary alone. libapk.a is linked into it and libapk.so is not shipped:
# nothing on a printer links against apk, so a .so here would be a file to
# find on the loader path for no reader.
pkg_ship "bin/apk"

pkg_end
