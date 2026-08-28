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

* **Our cross-built opkg installs our packages, on mipsel.** The `opkg` this
  repo builds — static, musl, mips32r2/nan2008/o32 — run under
  `qemu-mipsel-static` against an `--offline-root`: it installed
  `libsodium_1.0.20-1_mipsel_xburst2.ipk` and `opkg_0.7.0-1_mipsel_xburst2.ipk`,
  reported both under `list-installed`, listed their files, and removed both
  leaving nothing behind. The opkg it installed then ran and reported its own
  version. That is the whole loop closed on the target architecture.
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
  The only symptom of getting this wrong is a `NEEDED` entry nobody looks at —
  hence the explicit check in `pkg/opkg/build.sh`.
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
* **Both packages are reproducible.** `rm -rf work/.sodium` and a full
  recompile produce a byte-identical `.ipk`. That is a measurement of *these*
  packages and this toolchain, not a property of the build system — a package
  whose upstream embeds a timestamp will not have it, and the honest response
  is to record which ones do rather than to claim the fleet is reproducible.

## Phase 0 — the proof of concept  *(implemented)*

Two packages, end to end, beside the existing build and changing nothing about
it.

    make packages            # or ./bin/build-packages.sh [name...]

    work/packages/libsodium_1.0.20-1_mipsel_xburst2.ipk
    work/packages/opkg_0.7.0-1_mipsel_xburst2.ipk
    work/packages/Packages{,.gz}

Needs **no stock FlashForge package**, which is most of the point: packaging
has to be runnable in CI on a bare checkout, or the gate only runs where the
proprietary firmware is and stops being a gate.

| file | what it is |
| ---- | ---------- |
| `pkg/lib.sh` | the part of a cross-build that is the same for every package |
| `pkg/libsodium/` | `build.sh` + `pkg.conf`. **`bin/patch.sh` section 5d's build, moved.** |
| `pkg/opkg/` | opkg itself: static musl, with zlib and libarchive as build-only dependencies |
| `pkg/ipk-install` | installs/removes `.ipk` with no opkg present, writing opkg's own database layout |
| `bin/build-packages.sh` | lays out the tree, drives `opkg-build`, indexes the feed |
| `qa/static/test_ipk.py` | 18 tests, no toolchain needed |

### Why the second package is opkg

Two reasons, and the second is the one that mattered.

It is **phase 2's deliverable**, so building it now retires the biggest unknown
in the plan — and it turned up three findings above (the compile-time prefix,
the musl `basename` bug, libtool eating `-static`) that would otherwise have
been discovered later and under more pressure.

And it is the only honest test of whether `pkg/lib.sh` is a shared build
library or just libsodium's build with the comments moved. opkg shares
*nothing* with libsodium except that file: a different toolchain (Bootlin musl,
not Ingenic glibc), a different libc, a different link mode (static, not
shared), and a dependency chain three builds deep instead of none. Both recipes
are now short enough to read in one screen, and everything they have in common
is in one place.

The split that fell out:

* `pkg_begin` / `pkg_end` — the version-stamped build cache, which is what lets
  `bin/fetch-assets.sh` skip a 203MB toolchain download.
* `pkg_toolchain ingenic|musl` — unpack, write the gcc wrappers that bake
  `-EL -mnan=2008` into the *driver* (autotools link lines do not all forward
  `CFLAGS`), and then **prove the wrapper emits the right ABI** before anything
  is built on it. That last step existed in section 5b and was missing from 5d;
  the copies had already drifted before there was anywhere to put them.
* `pkg_autotools` / `pkg_dep_autotools` / `pkg_dep_paths` — configure, make,
  install, either into the staging tree or into the recipe's private sysroot.
* `pkg_ship` — copy out what ships, strip it with the *cross* strip, and leave
  `include/`, `pkgconfig/` and `.la` files behind.

`qa/static/test_ipk.py` gates this directly: a recipe that does not source
`pkg/lib.sh`, or that spells its own `-mnan=2008`, unpacks its own toolchain,
or calls `./configure` itself, fails the suite. The one named exception is
zlib, whose configure has never accepted `--host`. A recipe that needs
something `pkg/lib.sh` cannot express should *grow* `pkg/lib.sh` — that is what
the gate is for.

**Not yet shared:** `bin/patch.sh` sections 5b (s6) and 5c (CPython) still
carry their own copies of all of this. Phase 1 is what turns them into recipes.
Claiming otherwise would be claiming the duplication is already gone.

### The property everything rests on

**libsodium is compiled once.** `bin/patch.sh` runs `pkg/libsodium/build.sh`
and stages its output into the payload exactly as before;
`bin/build-packages.sh` runs the same recipe and packages the same tree. While
that holds, the tarball's copy and the package's copy cannot be different
libraries wearing one version number — and
`test_the_package_and_the_payload_share_one_build` asserts it rather than
trusting it.

**Gate:** `pytest qa/static/test_ipk.py` (18 tests) plus `make packages`
producing packages that our own cross-built opkg installs and removes under
qemu. Both pass.

## Phase 1 — a recipe per cross-build  *(~3–5 days)*

Turn the rest of `bin/patch.sh`'s builds into recipes, the way libsodium
became one. Roughly ten packages —

    klipper-fork  toolchange-config  mainsail  moonraker  helixscreen
    s6 (+execline +s6-rc)  python3  python3-site-packages
    libsodium ✔  opkg ✔  anvil

`patch.sh` keeps staging the payload from those same trees, so the shipped
tarball does not change. The work is mechanical; the risk is in the two builds
with the most measured constraints behind them (5b's s6 prefix, 5c's CPython
cross-build), which should go last — and both are exactly the shape
`pkg/lib.sh` already handles, since it was written from them.

**Gate:** the `anvil.tar.xz` built after this phase is byte-identical to the
one built before it. Anything else is a change nobody asked for.

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
