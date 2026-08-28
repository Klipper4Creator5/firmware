# Building your own packages

You need a stock FlashForge update package for your model — this builds *from*
it, it does not replace it. Everything else is Docker.

```sh
cp config.env.example config.env     # what to build, and what ships
$EDITOR config.env                   # point it at your stock package
make build                           # the firmware
```

The package lands in `work/out/`. `make release` builds both models into
`dist/`.

## Requirements

Docker. That is the whole list — the build image carries `openssl`, `tar`,
`xz`, `unzip`, `python3`, `binutils`, `squashfs-tools` and `qemu-user-static`,
and every target runs inside it. `make shell` drops you into it.
`LOCAL=1 make <target>` runs on the host instead.

The test targets get the docker socket mounted through, so they can start the
replica as a sibling container — and so does `make shell`, which shares their
run flags. A build cannot reach the docker daemon.

## The pipeline

```
fetch-assets.sh  download Mainsail + HelixScreen + Moonraker into vendor/
unpack.sh   decrypt the stock .tgz, open the software component
patch.sh    apply the mods to work/software/ and build work/modpayload/
pack.sh     regenerate md5sum.list, tar, encrypt → work/out/<Model>-anvil-<date>.tgz
verify.sh   simulate every check the printer performs, against the built file
```

`make build` runs the first four. `verify.sh` is NOT one of them -- run
`make verify` after it, as the hardware checklist does. Each is idempotent and
safe to re-run.

Packages carry only the **software** component by default. The stock installer
skips any component that is absent, so the kernel, the rootfs image and the
MCU/board firmware are left untouched — MCU flashing is the riskiest thing in
a package and there is no reason to run it for a userspace mod. `FULL=1 make
<target>` carries all four.

## One build

There is one package: the forked Klipper with toolchanger support,
Mainsail/Moonraker, ssh, and HelixScreen as the UI. `bin/common.sh` defaults
the `BUILD_*` flags to exactly that, and `config.env` can override any of
them if you want a piece left out.

There used to be a `profiles/` directory choosing between builds — five of
them at one point (`ssh`, `web`, `full`, `helix`) climbing one feature at a
time, then two (`probe`, `default`). The intermediate rungs each cost their
own flash-and-verify cycle while the recovery story stayed the same at every
one of them (flash the stock package), so they bought caution nobody was
spending; the last of them, `probe`, changed nothing on the printer and only
wrote a diagnostic report to the USB stick, which was a bring-up aid rather
than something to keep shipping. With one build left, the selection layer went
with them.

```sh
make build                        # the firmware
make release                      # both models, into dist/
MODEL=Creator5 make build         # just the non-Pro
```

## Cutting a release

Releases are built by `.github/workflows/release.yml`, on a pushed tag:

```sh
git tag v20260824-nova-kakhovka
git push origin v20260824-nova-kakhovka
```

The tag is `v<YYYYMMDD>-<city>`: the release date, and a Ukrainian city under
occupation. Write `docs/releases/<tag>.md` before you tag -- a short paragraph
on that city -- and the workflow appends it to the release notes; without one
it publishes a bare line saying releases are named this way, and warns in the
job log. Only the date reaches the package — FlashForge's installer reads
the version field as a number and compares it against what is on the machine,
so `anvil-20260824` is what the filename says and the codename lives in the
tag and the release title. A `workflow_dispatch` run has no tag; it builds and
uploads the packages as a workflow artefact and publishes nothing.

Nothing about the release job is privileged. The stock FlashForge packages and
the factory image it tests against are large but public (`ghzserg/FF`), pinned
by sha256 in the workflow exactly as `ci.yml` pins them. It reads one optional
secret, `ROOT_PW_HASH`, and deliberately has none set: released packages fall
back to a random root password written to `anvil-password.txt` on the stick,
which is the same thing a local build does and means no crackable hash ships
inside a public package.

The job publishes only if the whole brick-safety suite passes on the replica,
and then re-runs the end-to-end install against the exact `dist/*.tgz` files
that get attached — not against a package built from the same tree, but those
files. Releases are marked pre-release.

## Two kinds of flag

This distinction is the one to keep straight:

* **`BUILD_*`** decides what goes *into* a package. Read at build time only,
  defaulted in `bin/common.sh`, never present on the printer.
  (`BUILD_KLIPPER`, `BUILD_TOOLCHANGE`, `BUILD_MAINSAIL`, `BUILD_MOONRAKER`,
  `BUILD_HELIX`.)
* **`MOD_*`** are runtime switches. They are written into
  `/usr/data/anvil/anvil.conf`, which the printer re-reads at every boot, so
  they can be changed over ssh afterwards and survive a mod update.
  (`MOD_WEB`, `MOD_CAM`, `MOD_UI`, `MOD_WIFI`, plus the `MOD_CAM_*` tunables.)
  `MOD_SSH` is the odd one out: it is written to the same file, but nothing on
  the printer reads it — it is consumed at build time by `bin/patch.sh` to
  decide whether to set a root password, and ssh itself comes from the stock
  `/etc/init.d/S50dropbear` regardless.

## Third-party pieces are downloaded, not vendored

Mainsail, the HelixScreen build for this printer and Moonraker are large
third-party trees, so the repo does not carry them — and never has, so there is
nothing in the git history either. `versions.env` pins each one by version and
sha256:

```sh
MAINSAIL_VERSION="v2.18.2"
HELIX_VERSION="v0.99.115-creator5.1"
MOONRAKER_VERSION="v0.9.3"
```

Moonraker is here because the printer's own is a 2022 build that predates the
webcam `enabled` flag Mainsail filters on, so the camera panel never appears.
`BUILD_MOONRAKER=0` leaves the stock server alone.

`bin/fetch-assets.sh` downloads them into `vendor/` (gitignored) and refuses
anything whose sha256 does not match the pin. A cached file with the right
hash is never re-downloaded, so it is a no-op on every build after the first.
`bin/build.sh` calls it for you; `make vendor` pre-fetches everything.

To bump a version: edit `versions.env` — for HelixScreen that means both
`HELIX_VERSION` and `HELIX_FILE`, which embeds the version in the filename —
set the matching sha256 to `SKIP`, and run `make vendor`. It downloads the new
file and prints its hash for you to paste back over the `SKIP`. With a stale
hash left in place `make vendor` fails instead of printing anything.

Setting `MAINSAIL_ZIP`, `HELIX_TGZ` or `MOONRAKER_TGZ` in `config.env` points
the build at your own local copy. It is still checksummed against `versions.env`, and on a
mismatch `fetch-assets.sh` **overwrites your file** with the pinned release —
`SKIP` re-downloads too. To build against your own file, put its sha256 in
`versions.env` as well; only an exact match is left alone.

If the build asks for Mainsail, HelixScreen or Moonraker and the file is not
there, it fails. It used to skip silently, which shipped a package with an empty
web root and no way to notice.

## The root password

`ROOT_PW_HASH` in `config.env` is written straight into the shipped shadow
file at build time — `make passwd` prompts for one and prints the hash, using
the build image's python so the result is the same on every host. Leave it
empty and the *installer* picks a random password on the printer instead, on
the **first** install only, and writes it to `anvil-password.txt` on the USB
stick it was flashed from. An update finds the printer already has a password
— the random one, or one set by hand with `passwd` — and keeps it: the
pre-block records the live hash before the stock installer replaces the
shadow file, and the post-block puts it back.

The reason it works that way: a package is one file that many people flash, so
any password baked into it would be the same on every machine. Generating it on
the device is what makes it per-printer, and the stick is the one channel back
to the person standing at the machine.

If the stick cannot be written, no password is set — a password nobody can read
is no better than no access, and leaving a guessable one behind would be worse
than saying so.

`bin/patch.sh` decides which of the two applies and sets `MOD_PW_AUTO` in the
injected install block; `payload/run-append.sh` does the on-device half with
the printer's own `mkpasswd`.

## Two config files

| | |
|---|---|
| `config.env` | The **build** config: where your stock package and source trees are, which model, the root password hash. Some of it ships. |
| `test.env` | The **replica** config: the factory image, the partition sizes, an optional prebuilt printer image. None of it ships, ever. |

Both are gitignored; copy the `.example` of each. `CONFIG_ENV=<path>` and
`TEST_ENV=<path>` override the locations.

## Layout

The repo has two lanes, and the directory a file sits in says which one it
belongs to. Nothing from the test lane can reach a printer.

**Ships** — everything that ends up inside the `.tgz` and runs on the machine:

```
payload/        POSIX sh, busybox ash -- runs ON the printer
  firmwareExe     the wrapper that replaces the stock binary
  start.sh        replaces the stock Klipper launcher (priority, MCU bring-up)
  init.d/         S50wifi, S60nginx, S62moonraker, S65camera, S70klipper, S80ui
  anvil-env.sh    PATH/LD_LIBRARY_PATH/FF_PYTHON -- sourced, not executable
  anvil-service.sh the start/stop/status/liveness shape every service shares
                  -- sourced, not executable
  bin/            ff_mcu_bringup.py, wifi-action.sh
  klipper/        extras/ff_*.py and config/ff-*.cfg + printer.base.cfg
  helixscreen/    the printer-database entry that makes it a toolchanger
  anvil.conf      runtime switches, preserved across mod updates
  run-pre.sh      backups, injected at the TOP of the stock run.sh
  run-append.sh   payload install, injected before its exit
assets/         nginx.conf, moonraker.conf, moonraker-custom.conf
```

**Builds it** — host-side, never installed:

```
bin/            fetch-assets -> unpack -> patch -> pack, plus verify
                build-packages.sh is the packaging lane below -- not part of
                the four-step build
versions.env    pinned Mainsail / HelixScreen / Moonraker versions + sha256
vendor/         where fetch-assets.sh caches them (gitignored), plus the
                opkg-utils checkout -- the one entry pinned by git commit
                rather than sha256, because it has no release tarball
config.env      your paths, the root password hash, the model
docker/         Dockerfile.build -- the container every target runs in
pkg/            package recipes: one directory per cross-build, each a
                build.sh producing a $MODDIR-relative tree and a pkg.conf
                naming it. `make packages` builds them into .ipk files in
                work/packages/ with a feed index, using upstream's opkg-build.
                A PROOF OF CONCEPT -- nothing on the release path reads it
                yet, and the tarball `make build` produces is unchanged.
                See docs/notes/85-packaging.md.
  lib.sh          the part of a cross-build every recipe shares: the
                  toolchains, the compiler wrappers and their ABI self-test,
                  configure/make/install, the build cache. A recipe that
                  needs something this cannot express should grow it --
                  qa/static/test_ipk.py fails a recipe that goes around it.
  libsodium/      bin/patch.sh section 5d's build, moved. patch.sh runs it,
                  so the payload's copy and the packaged copy are one build.
  opkg/           the package manager itself: static musl, with zlib and
                  libarchive as build-only dependencies linked into it.
  ipk-install     the exception in here: POSIX sh, runs ON the printer, and
                  needs no opkg and no `ar`. It is how the first packages get
                  onto a machine that has neither. Not under payload/
                  because it does not ship yet.
```

**Tests it** — never ships, and never touched by a build:

```
test/           run-tests.py, and the shared pytest fixtures
  ffsim/          the host side of the harness, as a python package:
                  config loading, the docker plumbing, gate reporting
  integration/    the suite
    test_chamber.py         the Klipper config gate -- no firmware needed
    test_paths.py           payload paths against the real rootfs
    test_includes.py        the [include ff-*.cfg] block, exact set and order
    test_config_ownership.py  DO-NOT-EDIT banners on the mod-owned configs
    test_gcode.py           gcode/*.gcode against the macros we define
    test_harness.py         static checks on the harness itself
    make-stock-fixture.sh   synthetic stand-in for a stock package
    printer/        the replica itself: binfmt, mount layout, its two
                    Dockerfiles, and the cases that run inside it on the
                    printer's own binaries -- SHELL, because the printer's
                    busybox ash is the only interpreter that matters there
    extract-rootfs.py       pulls the real rootfs out of the stock package
    sim-*.py, printer-exec.py   host-side launchers, via the docker socket
    build-printer-image.sh  bakes a prebuilt replica image
test.env        replica settings only -- factory image, partition sizes
docs/           the documentation
```

Not everything in there needs the firmware — the config gate needs only
python3 and jinja2, and runs on a bare checkout. It briefly had a directory of
its own, `test/unit`, so that a pull request had something to run; with one
maintainer who always has the firmware, that was a boundary kept in sync for
nobody. `run-tests.py` extracts the rootfs before it runs pytest, so a single
invocation covers as much as the machine allows and reports the rest as gates
that did not run.

The line between Python and shell here is not taste. Everything that runs on
YOUR machine is Python; everything executed by the printer's own busybox under
qemu stays shell, because the fact that it survives that is a large part of
what the suite proves. See [testing.md](testing.md#why-the-harness-is-python)
for why the host half moved.

Two things keep the boundary from eroding: only `payload/` and `assets/` are
ever copied into a package by `patch.sh`, and `make verify` fails if a built
package contains any file byte-identical to one in `bin/`, `test/` or
`docker/`.

## Rebuilding chelper

`klippy/chelper/c_helper.so` must be MIPS32r2 / nan2008 / o32 or klippy dies on
import — `patch.sh` refuses to build a package with anything else, and
`test-install` checks the copy that lands on the machine. Debian's
cross-compilers cannot produce one (big-endian or legacy-nan); the Ingenic
gcc 7.2.0 / glibc 2.29 toolchain for the X2000 can, and it is pinned by
sha256 in `versions.env` and fetched into `vendor/` like every other asset.

You do not rebuild it by hand any more. `patch.sh` compiles the .so from the
chelper sources of the very tree it is about to ship — the pinned fork
tarball, or your `KLIPPER_FORK` checkout — whenever the .so is missing or
older than any `chelper/*.c`/`*.h` beside it. Two gates then run before
anything is packaged: the ELF-flag check above, and `test/test-chelper.py`,
which checks every function the klippy tree cdefs against the .so's dynamic
symbol table. The symbol gate exists because cffi resolves lazily: a stale
.so imports cleanly and dies only at `Internal error during connect` on the
printer, with a traceback that names cffi and not the build. Both a stale
prebuilt .so (v0.12 binary under a v0.13 tree) and a package that skipped
the fork entirely (v20260824-nova-kakhovka) have shipped; the compile-fresh
rule plus these gates are what make the third time structurally hard.
