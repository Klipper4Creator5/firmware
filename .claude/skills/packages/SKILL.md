---
name: packages
description: Build the .ipk feed, or add a new package recipe under pkg/. Use when asked to package something, add a library or component to the feed, bump a pinned version, or debug a recipe or the build environment.
---

# Packages

`pkg/<id>/` is one recipe. It builds one source and produces one or two
`.ipk` files into `work/packages/`, which is a local opkg feed.

## Building

```
make packages              # everything, plus the feed index
make packages PKG=<id>     # that recipe and what it builds against
```

**Always through `make`.** It runs inside `docker/Dockerfile.build`, which is
the only supported build environment. Running `./bin/build-packages.sh`
directly uses whatever the host happens to have and produces different
packages.

A warm recipe is skipped. To force one, `rm -rf work/pkg/<id>`.

## Adding a recipe

Two files. No other file in the repo needs editing.

`pkg/<id>/pkg.conf` — what the package is:

```sh
PKG_NAME=anvil-<id>
PKG_VERSION="$FOO_VERSION"      # from versions.env
PKG_RELEASE=1
PKG_SECTION=libs
PKG_EXCLUDE=".version"
PKG_DEPENDS=""                  # opkg install-time deps, by package name
PKG_BUILD_DEPENDS=""            # other recipe ids, by directory name
PKG_DESCRIPTION="One sentence."
```

`pkg/<id>/build.sh` — how to build it:

```sh
#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../../bin/common.sh"
. pkg/lib.sh

pkg_begin <id> || exit 0
pkg_toolchain                   # omit if nothing is compiled
pkg_deps                        # omit if PKG_BUILD_DEPENDS is empty
pkg_unpack "$FOO_TGZ"
pkg_build "foo-$FOO_VERSION" --disable-shared --enable-static
pkg_ship "lib/libfoo.a" "include/foo.h"
pkg_end
```

`chmod +x build.sh`. A new pinned download also needs `FOO_VERSION` /
`FOO_SHA256` in `versions.env` and a `get` line in `bin/fetch-assets.sh`.

## Verbs

| verb | what it does |
| --- | --- |
| `pkg_begin <id>` | read pkg.conf, check the cache, make the scratch tree. Returns non-zero when current, hence `\|\| exit 0` |
| `pkg_toolchain` | unpack the cross toolchain, put it on PATH and in `$CC`/`$AR`/… |
| `pkg_deps` | unpack each `PKG_BUILD_DEPENDS` package from the feed into a sysroot |
| `pkg_unpack <archive>` | extract the one pinned source (tar or zip) |
| `pkg_intree` | source is this checkout rather than a download |
| `pkg_build <srcdir> [args]` | configure, make, install into the staging tree |
| `pkg_stage <src> <dest>` | put a tree into the staging tree, for things with no build |
| `pkg_ship <glob>...` | copy from staging into the package; globs are relative to the prefix |
| `pkg_end` | seal the cache |

Three more exist only for python packages:

| verb | what it does |
| --- | --- |
| `pkg_buildpython` | build (once, cached) an x86-64 CPython of the same version and export `$HOSTPY` |
| `pkg_pytarget` | make that interpreter's sysconfig answer for mipsel, using the headers `pkg_deps` unpacked |
| `pkg_pywheel <name>` | build one wheel and unpack it into the staging site-packages |

Exactly one source verb per recipe — `pkg_unpack` **or** `pkg_intree`.

## When `pkg_build` needs help

Set these before calling it. Do not run a configure script yourself.

| variable | default | for |
| --- | --- | --- |
| `PKG_CONFIGURE` | `./configure` | `./Configure` (openssl), `none` (bzip2) |
| `PKG_CONFIGURE_AUTO` | `1` | `0` when the project rejects `--host` (zlib, openssl) |
| `PKG_MAKE_TARGET` | all | `libbz2.a` |
| `PKG_INSTALL_TARGET` | `install` | `install_sw`, or `none` to place files yourself |
| `PKG_MAKE_ARGS` | — | `LDLIBS=-lpthread` (s6) |
| `PKG_STRIP_ARGS` | `--strip-unneeded` | `""` to strip executables fully |
| `PKG_PY_SETUP_ARGS` | — | drive `setup.py build_ext` instead of pip (pillow) |
| `PKG_CC_SHARED` | — | the whole link line, after `$CC -shared -fPIC`, for a project with no build system at all (klipper's chelper). Skips configure and make |

`pkg_build` returns non-zero rather than dying, so `if ! pkg_build ...` can
retry with different flags. See `pkg/openssl/build.sh`.

## Optional pkg.conf fields

| field | for |
| --- | --- |
| `PKG_ARCH=all` | nothing in the package is compiled |
| `PKG_DEV_FILES="include lib"` | split headers and `.a` into `<name>-dev`, which no printer installs |
| `PKG_WHEN='[ "${BUILD_X:-1}" = "1" ]'` | recipe only exists when a flag is on |
| `PKG_STAMP_EXTRA` | cache key for sources with no version (see `pkg/anvil-core`) |

## Rules

1. One recipe builds one source. Need another library? It is another recipe,
   named in `PKG_BUILD_DEPENDS`.
2. No recipe runs a configure script, unpacks a toolchain, or spells compiler
   ABI flags. If `pkg_build` cannot express the project, add a knob to
   `pkg_build` — not a verb for that one project.
3. Everything installs under `/usr/data/anvil`. Nothing else is packageable.

## Copy from

- plain autotools — `pkg/libffi`
- builds against another package — `pkg/s6`
- no compiler, just files — `pkg/moonraker`
- from this repo, not a download — `pkg/anvil-core`
- awkward build — `pkg/openssl`, `pkg/bzip2`, `pkg/zlib`
- no build system, one link line — `pkg/klipper`
- a python package — `pkg/python-distro` (pure), `pkg/python-cffi` (native)

## Adding a python package

Four steps, and the first two are not in `pkg/`:

1. `PYPKG_<NAME>_FILE` and `_SHA256` in `versions.env`, and the name on
   `PYPKG_LIST`. The version is read out of the file name.
2. `./bin/fetch-assets.sh` to download it.
3. `pkg/python-<name>/`, copied from `pkg/python-distro`. Name any other
   package it imports in `PKG_DEPENDS`; add `PKG_ARCH=all` if it compiles
   nothing.
4. `make packages PKG=python-<name>`.

The list in `versions.env` and the recipe directories are checked against each
other by `qa/static`, so a half-done addition fails there rather than on a
printer.

## Checking

```
python3 -m pytest qa/static -q
```

Every recipe is checked for shape automatically. The ABI gate reads every ELF
in every package and refuses anything that is not nan2008/o32/mips32r2 — it
has caught a library built with the host compiler more than once.

Two cold builds must produce byte-identical `.ipk` files. If one does not, the
cause is usually an embedded timestamp or a mode that came from the builder's
umask.
