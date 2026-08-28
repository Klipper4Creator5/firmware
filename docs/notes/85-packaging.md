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
problem has already been solved once by hand — `payload/run-append.sh` reads an
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
  small — no `timeout`, no `nc`, no `ionice`, all measured on the replica. So
  `pkg/ipk-install` walks the ar headers itself with `tail`/`head` and needs
  only `tar` and `gzip`, which the stock FlashForge installer already proves
  are present.
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
  cold builds of `pkg/zlib` produced different sha256, every member reading
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
| `pkg/lib.sh` | the part of a cross-build that is the same for every package |
| `pkg/zlib/` | the library that was cross-built **twice**, now built once |
| `pkg/libarchive/` | what opkg reads `.ipk` files with; builds against `anvil-zlib` |
| `pkg/opkg/` | opkg itself; builds against both of the above |
| `pkg/libsodium/` | `build.sh` + `pkg.conf`. **`bin/patch.sh` section 5d's build, moved.** |
| `pkg/ipk-install` | installs/removes `.ipk` with no opkg present, writing opkg's own database layout |
| `bin/build-packages.sh` | orders the recipes, lays out each tree, drives `opkg-build`, indexes the feed |
| `qa/static/test_ipk.py` | 29 tests, no toolchain needed |

### One recipe builds one package

This is the rule the layout exists to enforce, and it did not hold at first.
`pkg/opkg/build.sh` used to unpack zlib, build it into a private sysroot,
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
Alphabetical order — what iterating `pkg/*/` gives you — puts libarchive before
the zlib it needs.

### The split in `pkg/lib.sh`

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
`pkg/lib.sh`, spells its own `-mnan=2008`, unpacks its own toolchain, calls
`./configure` itself, or unpacks more than one source tarball fails the suite.
The one named exception is zlib, whose configure has never accepted `--host`.
A recipe that needs something `pkg/lib.sh` cannot express should *grow*
`pkg/lib.sh` — that is what the gate is for.

**Not yet shared:** `bin/patch.sh` section 5b (s6 and skalibs) still carries
its own copy of all of this, and is the remaining instance of one script
building two libraries. Phase 1 is what turns it into recipes.

### The property everything rests on

**A library is compiled once, whichever vehicle it ships in.** `bin/patch.sh`
runs `pkg/libsodium/build.sh` and stages its output into the payload exactly as
before, and `bin/build-packages.sh` packages the same tree. Section 5c now does
the same with zlib: it runs `pkg/zlib/build.sh` and stages the result into
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
became one. Roughly ten packages —

    klipper-fork  toolchange-config
    python3  python3-site-packages
    openssl  libffi  sqlite  xz  expat  bzip2
    zlib ✔  libarchive ✔  libsodium ✔  opkg ✔
    skalibs ✔  execline ✔  s6 ✔  s6-rc ✔
    mainsail ✔  moonraker ✔  helixscreen ✔  anvil-core ✔

Twelve of the nineteen are done. Section 5b — the last place where one script
built two libraries — is four recipes now (`skalibs`, `execline`, `s6`,
`s6-rc`), and moving them off the musl toolchain removed the second libc from
this tree entirely. What is left is CPython and the six static libraries under
it, and then Klipper, which `docs/notes/80-s6-migration.md` phase 7 makes
reachable only after CPython.

`patch.sh` keeps staging the payload from those same trees, so the shipped
tarball does not change. The work is mechanical; the risk is in the two builds
with the most measured constraints behind them (5b's s6 prefix, 5c's CPython
cross-build), which should go last — and both are exactly the shape
`pkg/lib.sh` already handles, since it was written from them.

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

What is checked instead: the staged `work/modpayload` **tree** — file list,
modes and content hashes — is unchanged except for the components a change
deliberately rebuilt. The `.ipk` files themselves ARE byte-reproducible and
that is checked directly: two cold `make packages` runs produce twelve
identical archives.

## Phase 2 — install packages on the printer  *(~1–2 days)*

Most of this phase is now done: `opkg` builds, is packaged, and works on
mipsel. What remains is the bootstrap and the replica proof.

The bootstrap is the only genuinely interesting part, and it is a chicken and
egg: opkg cannot install the package that contains opkg. Two answers, and they
compose —

1. The tarball payload ships `$MODDIR/bin/opkg` directly, as it ships every
   other binary today. From the second update onward opkg manages everything,
   including itself.
2. `pkg/ipk-install` — POSIX sh, no opkg and no `ar` — installs the first
   packages onto a machine that has neither. It writes opkg's own on-disk
   database (`$MODDIR/var/lib/opkg/{status,info/*.{control,list}}`), so opkg
   adopts what it installed rather than disagreeing with it.

Route 1 is simpler and route 2 is what makes a hand-repaired printer
recoverable. Both are cheap; ship 1 and keep 2.

**Gate:** a replica install driven by packages leaves the same tree the
tarball leaves, and an upgrade removes exactly what the previous version
installed — the property `test-upgrade` already checks for the tarball. The
replica is the only place the printer's own busybox and tar get a vote, and
neither has been asked yet.

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

Note that `--disable-curl` and `--disable-gpg` in `pkg/opkg/build.sh` are what
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
