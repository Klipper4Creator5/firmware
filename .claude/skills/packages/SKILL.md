---
name: packages
description: Build the .ipk feed, or add a new package recipe under pkgs/. Use when asked to package something, add a library or component to the feed, bump a pinned version, or debug a recipe or the build environment.
---

# Packages

`pkgs/<id>/` is one recipe. It builds one source and produces one or two
`.ipk` files into `work/packages/`, which is a local opkg feed.

## Building

```
make vendor                # once -- the pinned sources and the toolchain
make packages              # everything, plus the feed index
make packages PKG=<id>     # that recipe and what it builds against
```

`make vendor` first on a cold checkout: `build-packages.sh` does not fetch,
and dies naming `./bin/fetch-assets.sh` when opkg-utils or a pinned tarball
is missing.

**The feed is a prerequisite of `make build`, not a side quest.** `bin/patch.sh`
builds the payload by *installing* the feed with the printer's own opkg, and
refuses to start when `work/packages` holds no `.ipk`. Recipes with
`PKG_BUILD_DEPENDS` also resolve them out of that directory. Order is
`make vendor` -> `make packages` -> `make build`.

Unlike `build`, this target needs no stock FlashForge package, which is what
lets CI build the feed on a bare checkout.

**Always through `make`.** It runs inside `docker/Dockerfile.build`, which is
the only supported build environment. Running `./bin/build-packages.sh`
directly uses whatever the host happens to have and produces different
packages.

A warm recipe is skipped. To force one, `rm -rf work/pkg/<id>`.

## Adding a recipe

Two files. No other file in the repo needs editing.

`pkgs/<id>/pkg.conf` — what the package is:

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

`pkgs/<id>/build.sh` — how to build it:

```sh
#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../../bin/common.sh"
. pkgs/lib.sh

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
| `pkg_payload_hash` | cache key over `$PKG_DIR/payload` — for a recipe that ships files of ours |
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
retry with different flags. See `pkgs/3rdparty/openssl/build.sh`.

## Optional pkg.conf fields

| field | for |
| --- | --- |
| `PKG_ARCH=all` | nothing in the package is compiled |
| `PKG_DEV_FILES="include lib"` | split headers and `.a` into `<name>-dev`, which no printer installs |
| `PKG_WHEN='[ "${BUILD_X:-1}" = "1" ]'` | recipe only exists when a flag is on |
| `PKG_STAMP_EXTRA` | cache key for sources with no version (see `pkgs/anvil-core`) |

## Rules

1. One recipe builds one source. Need another library? It is another recipe,
   named in `PKG_BUILD_DEPENDS`.
2. No recipe runs a configure script, unpacks a toolchain, or spells compiler
   ABI flags. If `pkg_build` cannot express the project, add a knob to
   `pkg_build` — not a verb for that one project.
3. Everything installs under `/usr/data/anvil`. Nothing else is packageable.
4. A recipe directory holds `build.sh`, `pkg.conf`, and up to three subtrees —
   nothing else, and `qa/static/test_recipe_layout.py` fails if a fourth
   appears:

   | directory | where its contents end up |
   | --- | --- |
   | `payload/` | staged into the .ipk, laid out exactly as it lands under `$MODDIR` |
   | `prog/` | placed on `/usr/prog` by `bin/patch.sh` — not packageable, because every path in a package of ours is under the prefix |
   | `seed/` | templated or seeded user state, deliberately not a package member |

   A recipe with a `payload/` needs `PKG_STAMP_EXTRA="$(pkg_payload_hash)"`.
   Its version number describes an upstream and cannot see those files, and a
   stamp that cannot see an input does not fail — it reports "already current"
   and hands over the previous build.

## Copy from

- plain autotools — `pkgs/3rdparty/libffi`
- builds against another package — `pkgs/3rdparty/s6`
- no compiler, just files — `pkgs/moonraker`
- from this repo, not a download — `pkgs/anvil-core`
- a download plus files of ours — `pkgs/helixscreen`
- awkward build — `pkgs/3rdparty/openssl`, `pkgs/3rdparty/bzip2`, `pkgs/3rdparty/zlib`
- no build system, one link line — `pkgs/klipper`
- a python package — `pkgs/3rdparty/python-distro` (pure), `pkgs/3rdparty/python-cffi` (native)

## Adding a python package

Four steps, and the first two are not in `pkgs/`:

1. `PYPKG_<NAME>_FILE` and `_SHA256` in `versions.env`, and the name on
   `PYPKG_LIST`. The version is read out of the file name.
2. `./bin/fetch-assets.sh` to download it.
3. `pkgs/3rdparty/python-<name>/`, copied from `pkgs/3rdparty/python-distro`. Name any other
   package it imports in `PKG_DEPENDS`; add `PKG_ARCH=all` if it compiles
   nothing.
4. `make packages PKG=python-<name>`.

The list in `versions.env` and the recipe directories are checked against each
other by `qa/static`, so a half-done addition fails there rather than on a
printer.

## Checking

```
make packages && python3 -m pytest qa/static -q
```

In that order, and it matters. Every recipe is checked for shape with nothing
but the checkout, but the questions about what is *inside* an `.ipk` — the
dev-split partition, `Architecture: all` carrying no ELF, the feed comparison
— return quietly when `work/packages` does not exist. Run the static lane on
a bare tree and it reports a pass having never opened a package.

**The ABI gate is not here.** It is `qa/replica/test_abi.py`, and it is the
only one: it reads every ELF on the *installed filesystem* — ours, the stock
tree's, and whatever `bin/patch.sh` staged — and refuses anything that is not
nan2008/o32/mips32r2. There were six partial versions of it once, spread over
`bin/`, `tools/` and the recipes, and between them they still could not see
the largest binary we ship. `qa/static` now only asserts that a seventh does
not grow back (`test_there_is_exactly_one_abi_gate_and_it_is_the_replica_one`),
which is why `nan2008` is a forbidden word in the build scripts.

Two cold builds must produce byte-identical `.ipk` files. If one does not, the
cause is usually an embedded timestamp or a mode that came from the builder's
umask.
