# Packaging: apk vs opkg, and the .ipk proof of concept

Whether to stop hand-building Python, Moonraker, s6 and libsodium into one
tarball and start building *packages* instead. Written 2026-08-28. The
comparison below is settled; the migration after it is a proposal, and only
phase 0 is implemented.

Same rules as `80-s6-migration.md`: each phase is independently shippable and
names the gate that proves it.

## Why, in one paragraph

`bin/patch.sh` is 1,900 lines and eleven cross-builds deep, and its output is a
single 53MB `anvil.tar.xz` that the printer's installer unpacks whole. Changing
one line of `anvil.conf` ships all 53MB. There is no way to install just a new
Moonraker onto a printer you are debugging, no record on the machine of what
version of anything is on it, and the "remove what the last release installed"
problem has already been solved once by hand — `installer/run-append.sh` reads an
install manifest and prunes by it, which is a package manager's file database
with one package in it. The question is whether to keep growing that or to
adopt the format that already means it.

## The fact that decides the comparison

**Neither package manager brings any software with it.** This is the whole
argument and it is worth stating before the table, because every "apk vs opkg"
discussion elsewhere on the internet is really about which distro's *repository*
you want, and neither repository can be used here:

* **Alpine has no MIPS port at all.** Not "an old one" or "a community one" —
  mips is not among the architectures Alpine builds. There is no `apk` repo to
  point at.
* **OpenWrt does have `mipsel_24kc`**, which is the same ISA and the same o32
  ABI as this printer — and is built against **musl**. This printer's rootfs is
  glibc 2.29, and the reason that matters is written down at length in
  `versions.env`: klippy's `c_helper.so` is dlopened by a glibc interpreter, so
  glibc is not a preference here. An OpenWrt package would unpack perfectly and
  produce a library nothing can load.

So every package will be cross-built by this repo either way. A package manager
buys **packaging, versioning and installation**. It does not buy software, and
adopting one does not make `bin/patch.sh`'s cross-builds go away — it
reorganises them into units with names and versions.

That reframes the choice entirely: the winner is whichever format is cheapest
to *produce* and *install* on a machine we control, not whichever has the
better ecosystem.

## The comparison

|                                | **opkg / .ipk**                                                                 | **apk / .apk (Alpine)**                                       |
| ------------------------------ | ------------------------------------------------------------------------------- | ------------------------------------------------------------- |
| Upstream binaries we can use   | none (musl)                                                                     | none (no mips port)                                            |
| Making a package               | `ar` + two `tar.gz` + a 3-byte version file                                     | three concatenated gzip streams with an RSA signature over the control stream |
| ...and the tool that does it   | **`opkg-build`, upstream, 423 lines of POSIX sh**                               | realistically `abuild` + `abuild-sign` + a keypair, and `abuild` assumes an Alpine host |
| Indexing a feed                | `opkg-make-index`, from the same upstream                                       | `apk index`, needs the signing key                             |
| Cross-building the packages    | irrelevant; we stage a tree and hand it over                                    | same, if you hand-roll; painful through `abuild`               |
| On-device client               | `opkg` + **libarchive** + zlib                                                  | `apk-tools` + zlib + **openssl**                               |
| ...and what we already build   | libarchive: nothing. New cross-build.                                            | openssl 3.0.15 and zlib **are already cross-built** for CPython |
| Offline install into a prefix  | `--offline-root DIR`, and `opkg install ./file.ipk` needs no feed at all         | `apk add --root DIR --allow-untrusted ./file.apk`              |
| Signing                        | optional; signs the **index**, so packages need no signature each                | expected; `--allow-untrusted` to skip                          |
| Format stability               | unchanged for over a decade; also Yocto/OpenEmbedded's native format             | apk-tools 3 introduced a new package format; v2/v3 coexistence is live churn |
| Home turf                      | embedded MIPS with a read-only rootfs — exactly this device class                | a full musl distro root                                        |

Two honest points for apk, since it is the more actively developed tool: its
`world` model (a declarative "these are the packages I want", reconciled on
every operation) is genuinely nicer than opkg's imperative install/remove, and
**its runtime dependencies are ones this repo already cross-builds** while
opkg's libarchive is not. If the deciding factor were the on-device client,
apk would win.

It is not. The deciding factor is that every package has to be produced here,
by us, on every build, in CI — and for `.ipk` there is an upstream tool that
does it, needing no keypair and no distro-specific build framework. For `.apk`
the equivalent is either implementing a signed three-stream format by hand or
importing Alpine's `abuild` into a Debian-based build image. That cost is paid
on every build and every recipe; the client is paid once.

The format-churn line matters more than it looks, too. A format with no users
on our architecture and an in-progress v2→v3 transition is a thing to track
forever for no benefit, since we can never consume anyone else's packages
anyway.

## Decision

**opkg, and the `.ipk` format**, with **`opkg-utils` as the packager** — we
drive upstream's `opkg-build` and `opkg-make-index` rather than assembling
archives ourselves. An earlier revision of this work did hand-roll the
ar-and-two-tarballs step; it worked, and it was still this repo re-deriving a
format somebody else maintains, including the parts whose failure mode is a
package that inspects fine and installs nowhere.

## Facts established by measurement, not by reading

Each of these was run, not assumed. They constrain the phases below.

* **Our cross-built opkg installs our packages, on mipsel** — measured when
  opkg was still a *static musl* binary. Run under `qemu-mipsel-static` against
  an `--offline-root`, it installed both packages of the day, reported them
  under `list-installed`, listed their files, and removed both leaving nothing
  behind; the opkg it installed then ran and reported its own version. The
  whole loop, closed on the target architecture.

  **This has not been re-run since opkg moved to dynamic glibc**, and the
  command changed with it — a dynamic binary needs `qemu -L <sysroot>`. See the
  end of phase 0. Nothing suggests it broke; nobody has checked.
* **opkg bakes its state directory in at compile time.** Its status file
  landed at `/usr/data/anvil/var/lib/opkg` because it was configured
  `--prefix=/usr/data/anvil` — `--offline-root` does not move it. Built with
  any other prefix it comes up believing nothing is installed and reinstalls
  the world. This is the *third* instance of the same trap on this printer,
  after s6's `libexecdir` and execline's `shebangdir` (both in `versions.env`).
  On this machine the `--prefix` is not a preference, and that is why `$MODDIR`
  now lives in `bin/common.sh` where a recipe cannot spell it differently.
* **opkg 0.7.0, not 0.6.3, if you build against musl.** Two files in 0.6.3
  (`opkg_remove.c`, `opkg_archive.c`) call `basename()` without including
  `<libgen.h>`, getting away with it only because glibc's `<string.h>` also
  declares a differently-behaved `basename`. musl does not, so gcc 14 stops at
  "implicit declaration" — and on a compiler that merely warned, the returned
  pointer would have been truncated through an implicit `int`. 0.7.0 adds both
  includes. That was the difference between a pin bump and carrying a patch.
* **opkg will not configure without libarchive.** Measured: `./configure`
  hard-fails at the `pkg-config` check. There is no internal tar fallback any
  more. libarchive and zlib are therefore build dependencies, cut down to
  gzip-and-tar and linked *into* the static binary; neither ships as a file.
* **libtool eats `-static`.** A program configured `LDFLAGS=-static` comes out
  dynamically linked anyway, because libtool defines that flag to mean
  "prefer static libtool libraries" and does not pass it to gcc. `-all-static`
  is the one that means it, and it cannot go through `./configure` (configure's
  own link probes call gcc directly, which rejects it), so it goes to `make`.
  Nothing relies on this any more — opkg links glibc dynamically now and gets
  its static zlib and libarchive simply by there being no `.so` of either in
  the sysroot — but the *check* it motivated stayed, inverted: `readelf -d` on
  the finished binary, expecting `libc.so.6` and nothing of ours. The lesson is
  the check, not the flag. A link that is not what it was asked to be shows up
  as a `NEEDED` entry nobody looks at, and then as a missing `.so` on a
  printer.
* **opkg-utils has no release tarball, anywhere.** Upstream's cgit has
  snapshots disabled (every format returns "Unsupported snapshot format"),
  `downloads.yoctoproject.org` carries opkg but not opkg-utils, and the GitHub
  mirror at `shr-project/opkg-utils` last saw a commit in 2012 and has no tags.
  So it is pinned by **git commit** — a hash of the whole tree, the same
  guarantee the sha256s give, in git's spelling — and `bin/fetch-assets.sh`
  verifies `HEAD` against it and refuses a dirty checkout.
* **The printer's busybox cannot be assumed to have `ar`.** It is 1.31.1 built
  small — no `timeout`, no `nc`, no `ionice`, all measured on the replica.
  That is why the printer gets a real cross-built opkg (`pkgs/3rdparty/opkg/`),
  which reads `.ipk` through its own linked-in libarchive rather than shelling
  out to tools the busybox may not have.
* **All four packages are reproducible.** `rm -rf work/pkg work/packages` and a
  full recompile produce byte-identical `.ipk` files. That is a measurement of
  *these* packages and this toolchain, not a property of the build system — a
  package whose upstream embeds a timestamp will not have it, and the honest
  response is to record which ones do rather than to claim the fleet is
  reproducible.
* **A static archive is not reproducible until it is made so, and this
  toolchain cannot do it alone.** `ar` stores an mtime and the builder's
  uid/gid in every member header, plus another timestamp in the symbol index —
  none of which `SOURCE_DATE_EPOCH` or `opkg-build`'s `-o 0 -g 0` reaches,
  because they are *inside* a file the tarball merely contains. Measured: two
  cold builds of `pkgs/3rdparty/zlib` produced different sha256, every member reading
  `1000/1000 Aug 28 15:10`. `objcopy -D` normalises the member headers, but the
  cross binutils is **2.27** and its `ranlib -D` writes a *fresh current*
  timestamp into the index instead of zeroing it. The index is therefore
  rewritten with the build machine's `ranlib` (2.40 in `docker/Dockerfile.build`),
  which is version-sensitive and worth knowing before anyone changes the image.
  The proof it produces a valid index is downstream: opkg links against both
  archives, and a broken index fails that link.
* **The ABI gate's `e_flags` whitelist was a proxy, and object files exposed
  it.** It accepted exactly `0x70001405` and `0x70001407`, both measured from
  linked *binaries* — where crt startup objects set `EF_MIPS_NOREORDER`, so
  every executable and shared object read one or the other. Individual objects
  need not: libarchive's `xxhash.o` is `0x70001406`, identical ABI, no
  NOREORDER, and the old gate called it wrong. The ABI is the high bits
  (`0x70001400` = arch32r2 | o32 | nan2008); the low three (noreorder, pic,
  cpic) say nothing about whether the kernel will exec the file. The gate now
  masks them, and reads **every** header rather than one — `readelf -h` on an
  archive prints one per member, 122 for `libarchive.a`, and the single-line
  version handed a multi-line string to a comparison expecting one word.
* **A cache stamp compared by one file and written by another will drift.**
  `bin/fetch-assets.sh` compared `work/.s6/.version` against
  `"$SKALIBS_VERSION $S6_VERSION"` while `bin/patch.sh` wrote three fields into
  it. The test could therefore never be false: a 71MB toolchain was re-hashed
  on every run, downloaded on every cold one, and the comment above the
  condition described a fast path that had never once been taken. `$S6_STAMP`
  now lives in `bin/common.sh`, the recipes compute theirs in `pkg_stamp`, and
  `test_no_cache_stamp_is_spelled_in_two_places` keeps it that way.

## Phase 0 — the proof of concept  *(implemented)*

Four packages, end to end, beside the existing build and changing nothing that
ships.

    make packages            # or ./bin/build-packages.sh [name...]

    work/packages/anvil-zlib_1.3.1-1_mipsel_xburst2.ipk
    work/packages/anvil-libarchive_3.7.9-1_mipsel_xburst2.ipk
    work/packages/anvil-libsodium_1.0.20-1_mipsel_xburst2.ipk
    work/packages/anvil-opkg_0.7.0-1_mipsel_xburst2.ipk
    work/packages/Packages{,.gz}

Needs **no stock FlashForge package**, which is most of the point: packaging
has to be runnable in CI on a bare checkout, or the gate only runs where the
proprietary firmware is and stops being a gate.

| file | what it is |
| ---- | ---------- |
| `pkgs/lib.sh` | the part of a cross-build that is the same for every package |
| `pkgs/3rdparty/zlib/` | the library that was cross-built **twice**, now built once |
| `pkgs/3rdparty/libarchive/` | what opkg reads `.ipk` files with; builds against `anvil-zlib` |
| `pkgs/3rdparty/opkg/` | opkg itself; builds against both of the above |
| `pkgs/3rdparty/libsodium/` | `build.sh` + `pkg.conf`. **`bin/patch.sh` section 5d's build, moved.** |
| `bin/build-packages.sh` | orders the recipes, lays out each tree, drives `opkg-build`, indexes the feed |
| `qa/static/test_ipk.py` | 112 tests, no toolchain needed |

### One recipe builds one package

This is the rule the layout exists to enforce, and it did not hold at first.
`pkgs/3rdparty/opkg/build.sh` used to unpack zlib, build it into a private sysroot,
unpack libarchive, build that against it, and only then build the binary it
shipped: one script, three libraries, one package. Section 5b still does the
same thing with skalibs and s6.

What that costs is not tidiness. A library built inside somebody else's recipe
has no version, no package and no way to be reused, so the next consumer builds
its own — **zlib was cross-built twice in this tree**, once in section 5c for
CPython and once here for libarchive, from one pinned tarball with the same
flags, and neither copy could see the other. Splitting them is what makes the
feed the interface between recipes rather than an output nobody reads.

So a recipe now declares `PKG_BUILD_DEPENDS`, and `pkg_deps` fills its sysroot
by unpacking those packages **out of the feed**. Building against the package
rather than against the build tree is the part worth paying for: a package that
forgets to ship a header fails the next recipe's configure, on the build that
produced it.

### opkg is not special, and nothing waits for it

The obvious objection to a feed-based build is that it needs a package manager
to install the build dependencies, and the package manager is itself a package.
It does not. `opkg-unbuild` is upstream's own inverse of `opkg-build` and comes
from the same pinned `opkg-utils` checkout, so a sysroot can be filled without
a working opkg existing anywhere. There is no bootstrap stage, no ordering rule
beyond declared dependencies, and no qemu in the build path.

`bin/build-packages.sh` topologically sorts the recipes and packages each one
before the next is built, because the next one reads it out of the feed.
Alphabetical order — what iterating `pkgs/*/` gives you — puts libarchive before
the zlib it needs.

### The split in `pkgs/lib.sh`

* `pkg_conf` / `pkg_stamp` — a recipe's metadata and its cache key, both read
  from `pkg.conf`. The stamp includes the toolchain and, recursively, the
  stamps of everything the recipe builds against, so a zlib bump rebuilds
  libarchive and opkg with nobody maintaining a composite stamp by hand.
* `pkg_order` — dependency-first build order, and the closure of a single
  named recipe so that `PKG=opkg` builds what opkg needs.
* `pkg_begin` / `pkg_end` — the stamped build cache, which is what lets
  `bin/fetch-assets.sh` skip a 203MB toolchain download.
* `pkg_toolchain` — unpack, write the gcc wrappers that bake `-EL -mnan=2008`
  into the *driver* (autotools link lines do not all forward `CFLAGS`), and
  then **prove the wrapper emits the right ABI** before anything is built on
  it. That step existed in section 5b and was missing from 5d; the copies had
  drifted before there was anywhere to put them.
* `pkg_deps` — unpack this recipe's build dependencies out of the feed with
  `opkg-unbuild` and point `CPPFLAGS`, `LDFLAGS` and pkg-config at the result.
  The sysroot mirrors the printer, dependencies living under `$MODDIR` inside
  it, which is why `PKG_CONFIG_SYSROOT_DIR` is set to the sysroot rather than
  emptied: the `.pc` files say `prefix=/usr/data/anvil` and that variable is
  what turns them into paths that exist on the build machine.
* `pkg_autotools` — configure, make, install into the staging tree.
* `pkg_ship` — copy out what the package contains, normalise static archives,
  strip ELF with the *cross* strip. What a package contains depends on what it
  is for: a library that ships to the printer ships its `.so`, and a library
  that exists to be built against ships headers, `.a` and `.pc`.

`qa/static/test_ipk.py` gates this directly: a recipe that does not source
`pkgs/lib.sh`, spells its own `-mnan=2008`, unpacks its own toolchain, calls
`./configure` itself, or unpacks more than one source tarball fails the suite.
The one named exception is zlib, whose configure has never accepted `--host`.
A recipe that needs something `pkgs/lib.sh` cannot express should *grow*
`pkgs/lib.sh` — that is what the gate is for.

**Not yet shared:** `bin/patch.sh` section 5b (s6 and skalibs) still carries
its own copy of all of this, and is the remaining instance of one script
building two libraries. Phase 1 is what turns it into recipes.

### The property everything rests on

**A library is compiled once, whichever vehicle it ships in.** `bin/patch.sh`
runs `pkgs/3rdparty/libsodium/build.sh` and stages its output into the payload exactly as
before, and `bin/build-packages.sh` packages the same tree. Section 5c now does
the same with zlib: it runs `pkgs/3rdparty/zlib/build.sh` and stages the result into
CPython's dependency sysroot instead of compiling its own copy. While that
holds, the tarball's copy and the package's copy cannot be different libraries
wearing one version number — and
`test_the_package_and_the_payload_share_one_build` asserts it rather than
trusting it.

**Gate:** `pytest qa/static` (127 tests, 29 of them packaging) plus `make
packages` from a cold cache producing four byte-reproducible `.ipk` files and
an index. Both pass.

**Not re-run since opkg moved to glibc:** the end-to-end check where our own
cross-built opkg installs and removes this feed. It used to be a bare
`qemu-mipsel-static` invocation because opkg was a static musl binary; a
dynamic one needs a sysroot, so the command is now

    qemu-mipsel-static -L work/.mips-toolchain/mips-gcc720-glibc229/mips-linux-gnu/libc \
        work/pkg/opkg/bin/opkg --offline-root <tmpdir> install work/packages/*.ipk

(`readelf -l` says the interpreter is `/lib/ld-linux-mipsn8.so.1`, the nan2008
loader, which that sysroot provides and the printer's rootfs must too — the
same loader the interpreter already links.) Worth running before anyone leans
on this.

## Phase 1 — a recipe per cross-build  *(~3–5 days)*

Turn the rest of `bin/patch.sh`'s builds into recipes, the way libsodium
became one —

    klipper ✔  toolchange-config
    python ✔  python-<18 packages> ✔
    openssl ✔  libffi ✔  sqlite ✔  xz ✔  expat ✔  bzip2 ✔
    zlib ✔  libarchive ✔  libsodium ✔  opkg ✔
    skalibs ✔  execline ✔  s6 ✔  s6-rc ✔
    mainsail ✔  moonraker ✔  helixscreen ✔  anvil-core ✔

**Done: 38 recipes producing 41 packages.**
Section 5b — the last place where one script built two libraries — is four
recipes (`skalibs`, `execline`, `s6`, `s6-rc`), and moving them off the musl
toolchain removed the second libc from this tree entirely. Section 5c, which
was 825 lines, is `pkgs/3rdparty/python` plus eighteen `pkgs/3rdparty/python-*` and 115 lines of
staging.

**What splitting CPython actually bought.** Not tidiness. The old section had
one cache and two stamps, and its own comment explained that a bumped Pillow
rebuilt the interpreter and all eighteen packages — because a wheel could only
be cross-built during the few minutes when an untrimmed staging tree, a private
sysroot of static libraries and a throwaway x86-64 build-python happened to
exist at once. Those are now, respectively: the feed's `anvil-python-dev`
package, each recipe's own sysroot, and `pkg_buildpython`'s shared cache. None
of them is a passing moment, so `make packages PKG=python-pillow` is a Pillow
build and nothing else.

It also made eighteen invisible things visible. Each package now carries its
upstream version into the index, `anvil-moonraker` declares the thirteen it
imports, and a printer that does not want gcode thumbnails can leave the 500KB
of Pillow uninstalled — a decision that could not previously be expressed.

**Klipper was the last one, and it needed one new knob.** `klippy/chelper` has
no Makefile and never has: on a machine with a compiler klippy builds
`c_helper.so` at first run from the argument list in
`klippy/chelper/__init__.py`, and this printer has no compiler. So the build
system for that `.so` genuinely is one `gcc` line, which `pkg_build` could not
express — it always ran `make`. `PKG_CC_SHARED` is that line, appended to
`$CC -shared -fPIC`: the recipe states Klipper's own `COMPILE_ARGS` and
`pkg_build` keeps ownership of the compiler, so the ABI flags stay spelled in
exactly one place. A knob, not a verb, for the reason the header of
`pkg_build` gives about the three mechanisms with one user each.

Two things the recipe took with it. `KLIPPER_FORK` — the `config.env` knob
that pointed the build at a local checkout instead of the pin — is **gone**: a
recipe names its source exactly once, a checkout beside a pinned tarball is
the second source that rule forbids, and it is the *same* variable that let
v20260824 ship a klippy tree nobody had built. And `test/test-chelper.py` no
longer falls back to reading `KLIPPER_FORK` out of `config.env` when given no
argument — that fallback printed `SKIP: no KLIPPER_FORK configured`, a green
line for a check that had not run.

The package installs the tree under `$MODDIR/klipper`, where nothing reads it
yet: klippy is still started by the stock `/usr/prog/klipper/klipperDaemon`,
so `bin/patch.sh` stages the recipe's output into the SOFTWARE component as
before. Phase 7 of `docs/notes/80-s6-migration.md` is what makes the installed
copy the live one. [Superseded: phase 7 landed. The `klipper` s6-rc service
execs `$FF_PYTHON` against `$MODDIR/klipper/klippy`, and the software-component
copy is gone.]

`patch.sh` keeps staging the payload from those same trees, so the shipped
tarball does not change. The work is mechanical; the risk is in the two builds
with the most measured constraints behind them (5b's s6 prefix, 5c's CPython
cross-build), which should go last — and both are exactly the shape
`pkgs/lib.sh` already handles, since it was written from them.

**Gate, corrected.** This used to read "the `anvil.tar.xz` built after this
phase is byte-identical to the one built before it". That cannot be the gate,
for two independent reasons, and stating it that way meant nobody could tell a
real regression from an expected difference:

* Moving s6 to dynamic glibc changes those binaries **by design**. A tarball
  that did not change would mean the change had not happened.
* `bin/pack.sh` builds `anvil.tar.xz` with a bare `tar -cf`, with no
  `--sort=name`, `--mtime` or `--owner`. It carries filesystem order and
  per-file mtimes, so it has never been byte-reproducible and the stated gate
  could never have passed.

What is checked instead: the assembled `work/modpayload-root` **tree** — file list,
modes and content hashes — is unchanged except for the components a change
deliberately rebuilt. The `.ipk` files themselves ARE byte-reproducible and
that is checked directly: two cold `make packages` runs produce identical
archives. Measured over all 40 with `work/pkg`, the shared build-python and
the unpacked toolchain all deleted in between — so the x86-64 interpreter that
generates every mipsel extension module is itself rebuilt rather than reused.

### A recipe owns its files, and the directory says how they ship

The recipes came first and the repository's own files stayed where they were:
one top-level `payload/` tree organised by DESTINATION (`init.d/`, `bin/`,
`etc/s6/`, `klipper/config/`) plus an `assets/` directory of three .conf
files. That was right when there was one owner. With 38 recipes it hid three
different kinds of file behind identical-looking paths, and the only thing
recording which package owned any of them was a thirty-line comment at the top
of `pkgs/anvil-core/build.sh`.

Files now live with the recipe that owns them, in one of three subtrees:

    pkgs/<recipe>/payload/   staged into the .ipk, laid out as it lands under
                            $MODDIR -- payload/init.d/S60nginx installs as
                            $MODDIR/init.d/S60nginx and no recipe says so
    pkgs/<recipe>/prog/      placed on /usr/prog by bin/patch.sh
    pkgs/<recipe>/seed/      templated or seeded user state

Recipes themselves sit at two depths, and `pkgs/lib.sh`'s `pkg_dir` is the
only thing that knows it: `pkgs/<name>/` for a recipe that carries files of
this repo (four), `pkgs/3rdparty/<name>/` for one that builds a pinned tarball
and carries none (thirty-four). That is for `ls pkgs/` and nothing else — no
package, no dependency and no stamp knows which side a recipe is on. The line
is deliberately mechanical rather than "do we modify it", which drifts: the
day somebody patches zlib nobody would agree on which side it belongs, whereas
"does it carry files of ours" is a fact about the tree and a test can demand
the move.

`installer/` holds the two files that are never files on a printer at all:
`run-pre.sh` and `run-append.sh` are spliced into FlashForge's own `run.sh`.
`qa/static/test_recipe_layout.py` fails if a fourth kind of directory appears,
which is the failure this layout is actually for — a misfiled file is caught
by a build, an unruled directory is caught by nothing.

**prog/ and seed/ are the not-yet-packaged residue, and that is the point of
naming them.** Both empty out on the way to the end state: `seed/` when
maintainer-script support lands and a postinst seeds `anvil.conf.default` only
when the real file is absent; `prog/` when a postinst run against a STAGING
ROOT places `/usr/prog/PROGRAM/software/firmwareExe` as a symlink into
`$MODDIR`. The second is the interesting one, and it is only possible because
`/usr/prog` is written by a tarball this repo bakes, not by a flash we do not
control: the install can happen in the build container, which is what "the
tarball becomes a view of the feed" below already assumes. The trap there is
`$IPKG_INSTROOT` -- a postinst that writes a bare `/usr/prog/...` symlinks the
BUILD CONTAINER's root, the staging tree gets nothing, and the build stays
green.

**Ownership followed, once the files could be seen.** `anvil-core` had held
everything of ours for no better reason than being the first recipe written,
and with the files visible per-recipe the misfilings were obvious:
`moonraker.conf` went to `pkgs/moonraker` with the server it configures, the
`ff-*.cfg` to `pkgs/klipper-config`, and the two per-model chamber configs
became `anvil-klipper-creator5-config` and `anvil-klipper-creator5pro-config`
— which is the first use of `Provides`/`Conflicts` in this feed, on a virtual
`anvil-klipper-chamber-config` that either satisfies and neither may share.
The dependency runs from the model package to the shared one and not the
other way: `opkg install anvil-klipper-config` would otherwise resolve the
virtual name by picking whichever provider it found first, which is a coin
flip between two files describing different hardware. The model is the one
fact opkg cannot work out for itself, so it is the name you install.
The model stopped being a property of the build: two builds of one commit used
to produce different bytes under one version number, with nothing in the feed
or on the printer recording which machine they were for.

Two flags became honest as a side effect, and both are behaviour changes worth
knowing about. `BUILD_TOOLCHANGE=0` used to ship the toolchanger's `.cfg`
anyway, because they rode in `anvil-core` while everything else the flag
controls was gated; it no longer does. `BUILD_MOONRAKER=0` used to overwrite
the printer's `moonraker.conf` with one written for a server it was not going
to install; it no longer does, which is what `docs/building.md` already said
the flag meant.

**What it cost and what it caught.** Nothing shipped changed: all 41 packages
are byte-identical across the move. It did surface one live bug --
HelixScreen's `printer_database.d` entry was hashed into ANVIL-CORE's
`PKG_STAMP_EXTRA`, so editing the json rebuilt a package that does not contain
it and left the one that does sitting in the cache. `pkg_payload_hash` is now
the one way a recipe keys its own files, and a recipe cannot hash somebody
else's.

## Phase 2 — the payload is the feed  *(assembly half: done)*

Split in two, and only the first half is done.

**The assembly half — done.** `bin/patch.sh` no longer stages anything. It
installs the feed into a staging root and ships what lands there:

    ./bin/build-packages.sh                       # the feed
    opkg --conf <generated> --force-postinstall \
         install <the runtime set>                # into work/modpayload-root
    tar -C work/modpayload-root/usr/data/anvil    # the payload

Eight sections that each ran a recipe and copied its build tree are gone, and
with them the hand-written `PKG_DEV_FILES` prune, three partial ABI gates and
the last `pkg_out` call. `patch.sh` went from 793 lines to about 700, and what
is left of it writes `/usr/prog` — FlashForge's tree, which no package of ours
may touch — plus the three files that are in the payload and in no package.

**The on-printer half — not started.** `.install-manifest` still exists and
`installer/run-append.sh` still deletes by it. Replacing it with opkg's own
`.list` files changes what happens on real printers during an upgrade and
rewrites `test/integration/printer/case-upgrade.sh`; it is a separate change
with a different risk profile. Keeping the halves apart is what made the first
one provable: on-printer behaviour is unchanged, so correctness reduced to a
payload diff.

### What it is assembled with

**A host opkg.** `pkg_buildopkg` (`pkgs/lib.sh`) builds an x86-64 opkg from
the same pinned tarball the mipsel one comes from, cached at `work/.opkg-host`,
shaped as `pkg_buildpython`'s twin. It resolves `Depends`, enforces
`Conflicts`, reads `Provides` and handles `conffiles` — all of which decide
what the payload should contain.

The database is therefore written by the same program that will later read it
on the printer, which is what makes "phase 2 is a swap rather than a
migration" true rather than an argument about format compatibility.

**`--prefix=$MODDIR`, and it is the trap.** opkg bakes its state directory in
at compile time (`libopkg/Makefile.am`: `-DVARDIR="@localstatedir@"`). Built
with any other prefix it looks for its status file somewhere else no matter
what `--offline-root` it is given, comes up believing nothing is installed,
and reinstalls the world. `--disable-shared` is the second half: the prefix
goes into `libopkg` too, so a shared build produces a `bin/opkg` that looks
for `libopkg.so.1` at a path that exists on the printer and not here.
`pkg_buildopkg` checks both against the binary it produced.

**A chroot was tried and rejected.** It works, and it marks packages
`installed` without `--force-postinstall`, but it needs root: unprivileged
`chroot` is `Operation not permitted` and `unshare -Ur` is blocked by Docker's
seccomp profile. The payload then comes out root-owned and the build-lane user
cannot delete it, so the next `make build` dies on its own `rm -rf` — the
failure `Makefile:48-61` exists to prevent. It is also more code: opkg plus an
`ldd` loop for ten shared libraries, against a nine-line config file.

### What the set is

`bin/patch.sh` names twelve packages and lets `Depends` bring the rest: 31
installed, 19 of them pulled in and marked `Auto-Installed: yes`. The feed is
indexed (`src anvil file:$PKG_FEED` plus `opkg update`), so this is the same
resolution an `opkg install anvil-moonraker` performs on a printer — which
means the dependency metadata is exercised by every build instead of only when
somebody tries it.

`file:` is answered before curl is reached at all
(`libopkg/opkg_download.c:134`), which is why a `--disable-curl` opkg can
still resolve a feed.

**The gates reach here by absence.** A `PKG_WHEN`-gated recipe leaves no
`.ipk` in the feed, so `BUILD_HELIX=0` simply has no `anvil-helixscreen` to
install, with no `BUILD_*` flag restated outside the `pkg.conf` that owns it. The cost is that a *misspelled* root drops out
just as quietly, which is what `test_the_payload_roots_name_real_packages`
exists for. A missing **dependency** is still a hard error, raised by opkg.

**Four roots are Recommends, a field opkg does not have.**
`anvil-python-pillow` and `anvil-python-preprocess-cancellation` are
Moonraker's thumbnail path, which `pkgs/moonraker/pkg.conf` argues out of
`Depends` on the grounds that a printer without them still serves;
`anvil-python-greenlet` and `anvil-python-cffi` are klippy's, and
`pkgs/klipper/pkg.conf` cannot declare them while klippy still runs under
FlashForge's interpreter.

**An earlier version enumerated the closure by hand**, filtering
`pkg_recipes`. It worked and it hid the thing worth testing. It also had a trap
in it: `-dev` had to be filtered by package NAME, not by "has a runtime half",
because `execline`, `s6` and CPython ship both halves while `zlib`, `openssl`,
`sqlite`, `expat`, `libffi`, `xz`, `bzip2`, `libarchive` and `skalibs` ship
*only* a dev package and say so by setting `PKG_NAME=anvil-<x>-dev` outright.
Asking the first question installed all nine — 40 packages and 2165 ELF
objects where there should be 31 and 154. Roots and `Depends` cannot make that
mistake: nothing depends on a `-dev` package.

The one version that cannot be left to opkg is `anvil-core`'s. Its
`PKG_VERSION` is `MOD_VER`, which defaults to today's date, so a feed built
yesterday would resolve and install yesterday's `anvil-core` without
complaint. `patch.sh` checks for the expected filename before installing and
names `./bin/build-packages.sh` if it is absent.

The model is the one fact opkg cannot work out for itself: both chamber
configs are built every time, they own the same `config/printer.chamber.cfg`,
and they `Conflict`. opkg refuses the pair with exit 255 — measured — so
`$TARGET_MACHINE` picks one.

### The database ships

`$MODDIR/var/lib/opkg/{status,info/*}` is in the payload and in
`.install-manifest`. This is coherent with `installer/run-append.sh`: pass 1
deletes what the *old* manifest named, including the old database, and the new
tarball then extracts one that exactly describes the payload being extracted.
A `.tgz` flash is a full reset of `/usr/data/anvil`.

The alternatives are worse. Leaving it out defeats the point — an opkg with no
`status` believes nothing is installed. Keeping it out of the *manifest* only
is worse still: a package release N shipped and N+1 dropped would keep its
stanza forever while its files were gone.

**Known gap.** A printer that runs `opkg install` for something extra and then
flashes a `.tgz` keeps that package's files — they are in no manifest of ours
— but loses its stanza. That is inherent to running two install mechanisms at
once, and it dissolves when the manifest gives way to opkg's `.list` files.

**`Installed-Time` is normalised** after installing. opkg takes it from
`time()` and honours `SOURCE_DATE_EPOCH` only for a man-page date at configure
time, so two builds of one commit differed by one line per package — measured,
fixed, measured again.

### Maintainer scripts: what we learned, and what it costs

**opkg 0.7.0 does not run maintainer scripts under `--offline-root`**
(`libopkg/pkg.c:1339`, `opkg_cmd.c:342`) unless `--force-postinstall`, and it
**sets no `IPKG_INSTROOT` at all** — the variable does not appear anywhere in
its source.

The install passes `--force-postinstall`, but only to make opkg mark packages
`installed` rather than `unpacked`: nothing runs opkg on the printer after
`run-append.sh` extracts the tarball, so the extraction *is* the install and a
database saying otherwise would make the first real `opkg upgrade` argue with
the filesystem. No recipe defines a maintainer script, so nothing runs.

This contradicts an assumption made earlier in this document. The plan for
`firmwareExe` and `start.sh` was to package them and let a postinst place them
on `/usr/prog` from a staging root. That does not work as written: the script
would run on the build host with no `IPKG_INSTROOT` to tell it where the root
is. The options when that step arrives are to set an environment variable of
our own and have the script read it, or to leave those two files as the
`prog/` copies they are today. It needs its own design; it is not free.

### The gate this cleared

A payload built from the parent commit and from the migration, on the
synthetic stock fixture with the real vendored assets:

| | |
|---|---|
| files removed | 0 |
| content changes among 2778 shared files | 1 — `.install-manifest`, which lists the payload |
| mode changes | 0 |
| symlink changes | 0 |
| added | `klipper/**`, `var/lib/opkg/**`, `bin/opkg` |
| two builds in a row | byte-identical |

`bin/verify.sh` passes every check including the ship boundary; `make test`
runs `build-packages → unpack → patch → pack → verify` with 9 gates green.

**One bug fell out of it.** `PKG_EXCLUDE` was applied with `find -name`, which
matches a basename at any depth, so `.version` deleted Mainsail's own
`www/mainsail/.version` along with the recipe stamp. `anvil-mainsail` had been
shipping without it, invisibly, because the payload was copied from
`work/pkg` where the file survived. Making the package's contents the
payload's contents is what surfaced it.

**Still owed by this phase**, and the allowlist in
`test_every_payload_file_is_owned_by_a_package` is the list: `.install-manifest`
(generated), `anvil.conf` and `config/moonraker-custom.conf` (user state, and
arguably `conffiles` once the on-printer half lands), `bin/busybox` (optional,
from `config.env`), and opkg's own `var`, `var/lib`, `var/run`. Six entries,
three of them opkg's.

## Phase 3 — a feed  *(~2–3 days)*

`bin/build-packages.sh` already writes `Packages` and `Packages.gz` with
`opkg-make-index`, carrying both MD5 and **sha256** per package (sha256 is not
the default and has to be asked for). Serving that directory over HTTP from CI,
teaching the printer an `opkg.conf` that points at it, and signing the index
with `usign` makes partial over-the-network updates real: `opkg upgrade
moonraker` instead of a 53MB tarball and a reboot.

Signing the **index** is what makes this safe, and it is one signature for the
whole feed rather than one per package — the index carries each package's
sha256, so a trusted index makes untrusted packages verifiable. Same argument
`versions.env` makes about vendored tarballs.

Note that `--disable-curl` and `--disable-gpg` in `pkgs/3rdparty/opkg/build.sh` are what
this phase turns back on; they are off now so that a static binary does not
carry libcurl and OpenSSL for a capability nothing uses yet.

## What this does not fix, and is not meant to

* **It does not shrink the build.** Every package is still cross-compiled here,
  from a pinned and hashed source. That was never going to change; see the fact
  that decides the comparison.
* **It does not replace `versions.env`.** Pins and hashes stay exactly where
  they are; `pkg.conf` reads them rather than restating them.
* **It does not make the printer able to install other people's packages.** The
  architecture string is chosen specifically to make that fail loudly.
