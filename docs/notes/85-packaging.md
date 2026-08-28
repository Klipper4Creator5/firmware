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
| Making a package               | `ar` + two `tar.gz` + a 3-byte version file. No keys, no distro host.            | three concatenated gzip streams with an RSA signature over the control stream |
| Build-side tooling needed      | none — `bin/mkipk.sh` is 120 lines of shell                                      | realistically `abuild` + `abuild-sign` + a keypair, and `abuild` assumes an Alpine host |
| Cross-building the packages    | irrelevant; we stage a tree and wrap it                                          | same, if you hand-roll; painful if you use `abuild`            |
| On-device client               | `opkg` (thin) + `libopkg` + **libarchive**                                       | `apk-tools` + zlib + **openssl**                               |
| ...and what we already build   | libarchive: nothing. New cross-build.                                            | openssl 3.0.15 and zlib **are already cross-built** for CPython |
| Offline install into a prefix  | `--offline-root DIR`, and `opkg install ./file.ipk` needs no feed at all         | `apk add --root DIR --allow-untrusted ./file.apk`              |
| Signing                        | optional; signs the **index**, so the packages need no signature each            | expected; `--allow-untrusted` to skip                          |
| Format stability               | unchanged for over a decade; also Yocto/OpenEmbedded's native format             | apk-tools 3 introduced a new package format; v2/v3 coexistence is live churn |
| Home turf                      | embedded MIPS with a read-only rootfs — exactly this device class                | a full musl distro root                                        |

Two honest points for apk, since it is the more actively developed tool: its
`world` model (a declarative "these are the packages I want", reconciled on
every operation) is genuinely nicer than opkg's imperative install/remove, and
**its runtime dependencies are ones this repo already cross-builds** while
opkg's libarchive is not. If the deciding factor were the on-device client,
apk would win.

It is not. The deciding factor is that every package has to be produced here,
by us, on every build, in CI, and `.ipk` production is a shell script with no
keypair and no distro-specific build framework in it. `.apk` production means
either implementing a signed three-stream format by hand or importing Alpine's
`abuild` into a Debian-based build image. That cost is paid on every build and
every recipe; the client is paid once.

The format-churn line matters more than it looks, too. A format with no users
on our architecture and an in-progress v2→v3 transition is a thing to track
forever for no benefit, since we can never consume anyone else's packages
anyway.

## Decision

**opkg, and the `.ipk` format.**

With one refinement that falls out of the table above: the **format** and the
**client** are separable, and they cost very different amounts. Producing real
`.ipk` files is done and gated. Getting the `opkg` binary onto the printer is a
second cross-build with its own ABI gates, and it is not required to start
getting value — see phase 2.

## Facts established by measurement, not by reading

Each of these was run, not assumed. They constrain the phases below.

* **The packages this repo produces are installed and removed by real opkg.**
  opkg 0.6.3, built from source, `--offline-root` install of
  `libsodium_1.0.20-1_mipsel_xburst2.ipk`: it installed, both symlinks survived
  as symlinks, `opkg list-installed` and `opkg files libsodium` reported it,
  and `opkg remove` left nothing behind under `/usr/data`. `dpkg-deb -I` also
  reads the file — the container format is Debian's.
* **opkg 0.6.3 will not configure without libarchive.** Measured: `./configure`
  hard-fails at the `pkg-config` check for it. So phase 2's cost is
  libarchive-for-mipsel, not opkg — the `opkg` binary itself is ~33KB stripped,
  with the substance in `libopkg.so` and libarchive.
* **opkg bakes its state directory in at compile time.** An opkg configured
  `--prefix=/usr/local` looks for its status file in
  `/usr/local/var/lib/opkg` regardless of what `--offline-root` it is given.
  This is *exactly* the s6 `libexecdir` trap recorded in `versions.env`, one
  layer up: a phase-2 opkg must be configured `--prefix=/usr/data/anvil`, or it
  comes up believing nothing is installed and reinstalls the world.
* **The printer's busybox cannot be assumed to have `ar`.** It is 1.31.1 built
  small — no `timeout`, no `nc`, no `ionice`, all measured on the replica. So
  `pkg/ipk-install` walks the ar headers itself with `tail`/`head` and needs
  only `tar` and `gzip`, which the stock FlashForge installer already proves
  are present.
* **libsodium cross-builds and packages in ~25s**, toolchain already unpacked,
  producing a 212KB `.ipk` for 416KB of installed library. A warm cache makes a
  rebuild 0.3s.
* **The whole thing is reproducible end to end.** `rm -rf work/.sodium` and a
  full recompile produce a byte-identical `.ipk` — same sha256, not merely the
  same contents. That is stronger than `bin/mkipk.sh` alone promises (it only
  guarantees same tree → same package) and it means a pin bump can be reviewed
  as a hash diff. It is a measurement of *this* library and this toolchain, not
  a property of the build system: a package whose upstream embeds a timestamp
  or a build path will not have it, and the honest response is to record which
  ones do rather than to claim the fleet is reproducible.

## Phase 0 — the proof of concept  *(implemented)*

One package, end to end, beside the existing build and changing nothing about
it.

    make packages            # or ./bin/build-packages.sh

Needs **no stock FlashForge package**, which is most of the point: packaging
has to be runnable in CI on a bare checkout, or the gate only runs where the
proprietary firmware is and stops being a gate.

What landed:

| file | what it is |
| ---- | ---------- |
| `bin/mkipk.sh` | the packager. Knows nothing about libsodium. Deterministic: two builds of one tree are byte-identical. |
| `bin/build-packages.sh` | the driver: runs each recipe, ABI-gates its tree, packages it, writes the feed index. |
| `pkg/libsodium/build.sh` | **`bin/patch.sh` section 5d's build block, moved.** |
| `pkg/libsodium/pkg.conf` | the control metadata. Version comes from `versions.env`, so it cannot be set twice. |
| `pkg/ipk-install` | installs and removes `.ipk` on the printer with no opkg, writing opkg's own database layout. |
| `qa/static/test_ipk.py` | 18 tests, no toolchain needed. |

The one property everything else rests on: **libsodium is compiled once.**
`bin/patch.sh` runs `pkg/libsodium/build.sh` and stages its output into the
payload exactly as before; `bin/build-packages.sh` runs the same recipe and
wraps the same tree. While that holds, the tarball's copy and the package's
copy cannot be different libraries wearing one version number — and
`test_the_package_and_the_payload_share_one_build` asserts it rather than
trusting it.

Also moved to `bin/common.sh` so the two lanes cannot disagree: `MODDIR`,
`PY_HOST`, `PY_TOOLCHAIN_DIR`, and `mips_abi_gate`. A package is a shipping
vehicle, so it is ABI-gated like one — `make packages` on a machine that never
runs `patch.sh` still checks nan2008/o32/mips32r2.

`IPK_ARCH` is `mipsel_xburst2` and is deliberately **not** an OpenWrt name; see
the comment on it in `bin/common.sh`. `pkg/ipk-install` refuses anything else.

**Gate:** `pytest qa/static/test_ipk.py` (18 tests) plus `make packages`
producing a package that real opkg installs. Both pass.

## Phase 1 — a recipe per cross-build  *(~3–5 days)*

Turn the rest of `bin/patch.sh`'s builds into recipes, the same way libsodium
became one: `pkg/<name>/build.sh` produces a `$MODDIR`-relative tree,
`pkg/<name>/pkg.conf` names it. Roughly ten packages —

    klipper-fork  toolchange-config  mainsail  moonraker  helixscreen
    s6 (+execline +s6-rc)  python3  python3-site-packages  libsodium ✔  anvil

`patch.sh` keeps staging the payload from those same trees, so the shipped
tarball does not change. The work is mechanical; the risk is in the two builds
with the most measured constraints behind them (5b's s6 prefix, 5c's CPython
cross-build), which should go last.

**Gate:** the `anvil.tar.xz` built after this phase is byte-identical to the
one built before it. Anything else is a change nobody asked for.

## Phase 2 — install packages on the printer  *(~0.5 day, or ~2–3 days)*

Two routes, and the cheap one is not a hack:

**(a) Ship `pkg/ipk-install`** — it exists, it round-trips install / upgrade /
remove against real packages, and it writes opkg's on-disk database
(`$MODDIR/var/lib/opkg/{status,info/*.{control,list}}`) so a real opkg can
adopt it later. Moving it to `payload/bin/` and having `run-append.sh` install
the payload's packages in order replaces the hand-rolled install-manifest prune
with a per-package one. Remaining work is a replica run, which is the only
place the printer's own busybox and tar get a vote.

**(b) Cross-build real opkg** — needs libarchive for mipsel first, then opkg
configured `--prefix=/usr/data/anvil` (see the trap above), then the ABI gate,
then a replica run. Buys dependency resolution and `opkg update/upgrade` from a
feed, neither of which is useful until phase 3.

Recommend (a) now and (b) when phase 3 is actually wanted. The packages are
identical either way, which is the point of having chosen a real format.

**Gate:** a replica install driven by packages leaves the same tree the
tarball leaves, and an upgrade removes exactly what the previous version
installed — the property `test-upgrade` already checks for the tarball.

## Phase 3 — a feed  *(~2–3 days)*

`bin/build-packages.sh` already writes `Packages` and `Packages.gz`. Serving
that directory over HTTP from CI, teaching the printer an `opkg.conf` that
points at it, and signing the index with `usign` makes partial over-the-network
updates real: `opkg upgrade moonraker` instead of a 53MB tarball and a reboot.

Signing the **index** is what makes this safe, and it is one signature for the
whole feed rather than one per package — the index carries each package's
sha256, so a trusted index makes untrusted packages verifiable. That is the
same argument `versions.env` makes about vendored tarballs.

Requires route (b) of phase 2.

## What this does not fix, and is not meant to

* **It does not shrink the build.** Every package is still cross-compiled here,
  by us, from a pinned and hashed source. That was never going to change; see
  the fact that decides the comparison.
* **It does not replace `versions.env`.** Pins and hashes stay exactly where
  they are; `pkg.conf` reads them rather than restating them.
* **It does not make the printer able to install other people's packages.** The
  architecture string is chosen specifically to make that fail loudly.
