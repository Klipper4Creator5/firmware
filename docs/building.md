# Building your own packages

This builds *from* the stock FlashForge update package for your model — it
does not replace it — but you no longer have to go and find one. It is pinned
in `versions.env` and downloaded into `vendor/` with everything else. Docker is
the only requirement.

```sh
cp config.env.example config.env     # what to build, and what ships
make build                           # the firmware
```

There is nothing to edit in `config.env` for a default build; open it to
change the model, the root password hash, or to leave a component out.

The package lands in `work/out/`. `make release` builds both models into
`dist/`.

## Requirements

Docker. That is the whole list — the build image carries `openssl`, `tar`,
`xz`, `unzip`, `python3`, `binutils`, `squashfs-tools` and `qemu-user-static`,
and every target runs inside it. `make shell` drops you into it.
`LOCAL=1 make <target>` runs on the host instead.

The test targets get the docker socket mounted through, so they can start the
replica as a sibling container — and so does `make shell`, which shares their
run flags. So does `make build`, which is newer: `payload.sh` assembles the
payload by installing the feed *inside* the replica, so the build lane needs
the daemon too. Only the feed, the unpack and the pack run without it.

## The pipeline

```
fetch-assets.sh  download the pinned sources into vendor/ -- Mainsail,
            HelixScreen, Moonraker, and the stock FlashForge package
unpack.sh   decrypt the stock .tgz for the boot images and the two facts
            pack.sh reads out of FlashForge's software component
payload.sh  install the .apk feed into work/modpayload-root/ to make the
            payload
pack.sh     generate runFirmwareExe.sh, tar, encrypt
            → work/out/<Model>-anvil-<date>.tgz
```

`make build` runs all four. It needs the .apk feed to exist first --
`payload.sh` assembles the payload by installing it -- so `make packages`
comes before a cold `make build`; payload.sh says so if it is missing. Each is
idempotent and safe to re-run.

There is no host-side check of the built file. `make qa-replica` has the
printer perform its own install, and that is the gate.

Packages carry **no FlashForge component at all** — the installer and the
payload, and nothing that lands on the firmware partition. The stock installer
skips any component that is absent, so `/usr/prog`, the kernel, the rootfs
image and the MCU/board firmware are left untouched — MCU flashing is the
riskiest thing in a package and there is no reason to run it for a userspace
mod. `FULL=1 make
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

## Publishing the feed

A release attaches two `.tgz` installers and one more file:
`reforge-apk-feed.tar.gz`, which is the `.apk` feed those installers were
built from, laid out the way the printer expects to fetch it. Unpacking that
tarball into a web root is the whole publish step.

The URL printers ask is `bin/common.sh`'s `FEED_URL`, and every build bakes it
into `anvil-core` as `/usr/data/anvil/etc/apk/repositories`:

```
http://reforge.8941973.xyz/apk/mipsel_xburst2/anvil.adb
```

Serve the tarball's contents at `http://reforge.8941973.xyz/apk/` — the arch
directory comes out of the tarball — and printers pick the feed up with
`apk update && apk upgrade`. The entry ends in the index file rather than
naming a directory because that is how apk tells the two layouts apart: a
`.adb` path is read as an index in place with the packages beside it, and
anything else sends it looking for `<url>/<arch>/APKINDEX.tar.gz`.

From a local build, the same layout without the tarball:

```sh
./bin/publish-feed.sh                          # stage work/feed-site/ only
./bin/publish-feed.sh user@host:/srv/apk       # stage, then rsync it there
```

It uploads the packages first and the index last, on purpose: the index names
every package by sha256, so a mirror carrying a new index and old packages
hands printers a checksum for a file that is not there. Nothing is deleted at
the far end. It refuses to publish an unsigned feed — `ALLOW_UNSIGNED=1` to
insist — because a printer verifies against the public key that shipped in its
own `anvil-core`, and packages nothing signed are packages it will not install.

**Plain HTTP, deliberately.** apk's libfetch verifies TLS peers against a
certificate bundle this printer does not have, and every package is signed —
the signature, not the transport, is what decides whether a printer installs
one. `docs/notes/85-packaging.md` has the detail.

**The host does not exist yet.** The URL ships anyway, and that is the point: a
feed cannot tell a printer where the feed is, so the pointer has to travel in
the `.tgz`. Machines installed today start fetching the day the host answers.
Until then `apk upgrade` reports the repository as unavailable, and every other
apk command — `apk add ./file.apk` included — is unaffected.

## One kind of flag

There used to be two, and the distinction was the thing to keep straight.
There is one now:

* **`BUILD_*`** decides what goes *into* a package. Read at build time only,
  defaulted in `bin/common.sh`, never present on the printer.
  (`BUILD_TOOLCHANGE`, `BUILD_MAINSAIL`, `BUILD_MOONRAKER`,
  `BUILD_HELIX`.)

The other kind was `MOD_*`: runtime switches written into
`/usr/data/anvil/anvil.conf`, which the printer re-read at every boot. **That
file is gone**, and so is every switch that lived in it — the whole of
`MOD_SPLASH`, `MOD_STARTUP`, `MOD_IMPORT`, `MOD_S6`, the `MOD_CAM_*` camera
settings, the `NICE_*` priorities, and before them `MOD_WEB`, `MOD_CAM`,
`MOD_UI`, `MOD_SSH` and `MOD_WIFI`.

Every one of them defaulted to on, and what each described was a
half-installed printer: Mainsail with no moonraker behind it, a screen dark on
purpose, a camera installed and switched off, a root password deliberately not
set on a machine whose recovery story is ssh. Nobody chose that state on
purpose, and everything downstream had to carry a second answer for it.

So the components run because they are installed, and the settings that were
worth keeping — the startup timeout, the camera's resolution, the nice values
— are each stated once, in the service that uses them, under
`pkgs/anvil-core/payload/etc/s6-rc/source/`. Changing one is an edit there and
a rebuild, not a file on the printer.

**To leave a piece out, leave it out** — that is what the `BUILD_*` flags are
for — or `apk del` it on the printer.

Upgrading a printer that has an `anvil.conf` needs nothing: the installer
deletes it, edits and all, because nothing reads it any more and a file that
still looks editable is worse than no file.

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

### The stock package is one of them

The stock FlashForge `.tgz` is pinned the same way, one per model:

```sh
STOCK_VERSION="1.9.7-1.2.9-20260810"
STOCK_FILE_CREATOR5PRO="Creator5Pro-$STOCK_VERSION.tgz"
STOCK_FILE_CREATOR5="Creator5-$STOCK_VERSION.tgz"
```

Nothing out of it ships — a release carries no FlashForge component at all —
but `unpack.sh` reads two things out of it: the `printer.base.cfg` ours is
diffed against, and the stock root hash the installer compares a live shadow
to. So the build lane needs one and the packaging lane does not, which is why
it has its own flag rather than a `BUILD_*` one: `make packages` still runs on
a bare checkout with no firmware anywhere.

`make build` fetches the package for the model it is building; `make vendor`
fetches both, about 186MB. They come from
[ghzserg/FF](https://github.com/ghzserg/FF/releases), the public archive
[Support](support.md) already sends you to for the undo button — nothing
proprietary is redistributed from this repo, and the sha256 is what makes
building from somebody else's mirror safe.

Two differences from the pieces above. The release tag is a rolling `R` holding
every FlashForge model at once, so the pin is the *filename* plus the sha256 —
there is no per-release tag to move to, and a withdrawn asset breaks the fetch
loudly rather than quietly. And `STOCK_TGZ_CREATOR5PRO` (or `_CREATOR5`) in
`config.env` is the one override that is **never overwritten**: it names 93MB
of firmware you downloaded by hand, so a hash mismatch skips it instead of
replacing it. That also means nothing checks it — it is your file.

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

`bin/pack.sh` decides which of the two applies and bakes `MOD_PW_AUTO` into
`installer/runFirmwareExe.sh`, which does the on-device half with the printer's
own `mkpasswd`.

## Two config files

| | |
|---|---|
| `config.env` | The **build** config: which model, the root password hash, which components to leave out. Some of it ships. Carries no paths — every source is pinned in `versions.env`. |
| `test.env` | The **replica** config: the factory image, the partition sizes, an optional prebuilt printer image. None of it ships, ever. |

Both are gitignored; copy the `.example` of each. `CONFIG_ENV=<path>` and
`TEST_ENV=<path>` override the locations.

## Layout

The repo has two lanes, and the directory a file sits in says which one it
belongs to. Nothing from the test lane can reach a printer.

**Ships** — everything that ends up inside the `.tgz` and runs on the machine:

Files that run on the printer live with the RECIPE THAT OWNS THEM, and the
directory inside that recipe says how they get there. Three names, no fourth
(`qa/static/test_recipe_layout.py` holds this):

```
pkgs/<recipe>/payload/   staged into the .apk, laid out as it lands under
                        $MODDIR: payload/etc/s6-rc/source/nginx installs as
                        $MODDIR/etc/s6-rc/source/nginx and no recipe says so
pkgs/<recipe>/payload/prog/
                        package files the printer reads from somebody else's
                        filesystem: anvil-link-prog.sh symlinks them to the
                        absolute paths under /usr/prog that FlashForge's own
                        scripts open
pkgs/<recipe>/seed/      templated or seeded user state: not a package member,
                        because a member is overwritten on every upgrade
pkgs/<recipe>/control/   maintainer scripts, read INTO the .apk by name --
                        `postinst` becomes both post-install and post-upgrade,
                        because apk splits what opkg ran once

installer/              runFirmwareExe.sh -- THE installer. app_startup.sh
                        runs whatever it finds under this name in the package
                        it decrypted, so this file is the whole install;
                        pack.sh bakes the model gate into it
```

Which is to say:

```
pkgs/anvil-core/            what makes the machine ours, and nothing else
  payload/  anvil-env.sh      PATH/LD_LIBRARY_PATH/FF_PYTHON -- sourced
            bin/              ff-startup.py, ff_mcu_bringup.py, ffscreen.py,
                              wifi-action.sh
            etc/s6-rc/source/ one directory per service: wifi, wifi-dhcp,
                              nginx, moonraker, camera, klipper, ui, ntp,
                              mcu-bringup, ff-startup, ok-all
            nginx/nginx.conf
            bin/anvil-link-prog.sh  links the two below, and the configs, into
                              the absolute paths the stock scripts read
            prog/firmwareExe  the wrapper that replaces the stock binary
            prog/start.sh     replaces the stock Klipper launcher
pkgs/klipper/
  payload/  klipper/klippy/extras/  ff_*.py
pkgs/klipper-config/        every Klipper config the mod owns
  payload/  config/ff-*.cfg          the toolchanger's includes
            config/printer.base.cfg  the hub the rest hang off
            config/chamber/Creator5.cfg , Creator5Pro.cfg
                              both ship; anvil-link-prog.sh symlinks the one
                              app_startup.sh's MACHINE names
pkgs/moonraker/
  payload/  config/moonraker.conf   the server's own config, with the server
  seed/     moonraker-custom.conf   the user's own Moonraker settings
pkgs/helixscreen/
  payload/  helixscreen/config/printer_database.d/
                              the entry that makes it a toolchanger
```

The service definitions stay with `anvil-core` and do NOT move to the
components they start, which looks inconsistent and is not. They are one
source tree, and `bin/payload.sh` compiles the whole of it into a single s6-rc
database on the build host. A tree split across packages would be a database
assembled from whichever of them happened to be installed — and there is no
compiler on the printer to assemble it with.

**Builds it** — host-side, never installed:

```
bin/            fetch-assets -> unpack -> patch -> pack.
                build-packages.sh is the packaging lane below, and the four
                steps need it to have run: payload.sh checks for the feed and
                refuses without one
versions.env    every third-party source, pinned by version and sha256 --
                including the stock FlashForge package, one per model
vendor/         where fetch-assets.sh caches them (gitignored), plus the
                apk-tools checkout -- pinned by git commit rather than
                sha256, because GitLab regenerates tag archives
config.env      the root password hash, the model, the BUILD_* flags
docker/         Dockerfile.build -- the container every target runs in
pkgs/           package recipes: one directory per component, each a
                build.sh producing a $MODDIR-relative tree and a pkg.conf
                naming it, plus whatever files of ours that component ships.
                `make packages` builds them into .apk files in work/packages/
                with a feed index, using apk's own mkpkg and mkndx. The release
                path depends on this: recipes resolve their build
                dependencies out of the feed, so `make packages` comes first.
                See docs/notes/85-packaging.md.
  3rdparty/       the recipes that build a pinned tarball and carry no files
                  of this repo -- thirty-four of the thirty-eight. They are
                  one level down so that `ls pkgs/` is the four components a
                  person edits rather than those four buried in the rest.
                  The line is mechanical, not editorial: a recipe belongs up
                  a level when it grows a payload/, prog/ or seed/, and
                  qa/static/test_recipe_layout.py enforces it in both
                  directions.
  lib.sh          the part of a cross-build every recipe shares: the
                  toolchains, the compiler wrappers and their ABI self-test,
                  configure/make/install, the build cache. A recipe that
                  needs something this cannot express should grow it --
                  qa/static/test_apk.py fails a recipe that goes around it.
  libsodium/      bin/payload.sh section 5d's build, moved. payload.sh runs it,
                  so the payload's copy and the packaged copy are one build.
  apk-tools/      the package manager itself, with zlib and openssl linked
                  in and one carried patch: apk resolves its database from
                  --root and / here is read-only, so the patch defaults that
                  database to $MODDIR while files still extract at /.
```

**Tests it** — never ships, and never touched by a build:

```
qa/             THE SUITE. static/ needs nothing but a checkout;
                replica/ needs docker and the firmware. `make qa`
tools/replica/  THE REPLICA, which is a build tool as much as a test one --
                bin/payload.sh assembles the payload inside it
  printer/        the machine: binfmt, the mount layout, Dockerfile.full and
                  the entrypoint that runs inside it on the printer's own
                  binaries -- SHELL, because the printer's busybox ash is the
                  only interpreter that matters there
  ffsim/          the host half: config loading and the docker plumbing
  sim-boot-screen.py      renders the boot frames, via the docker socket
  build-printer-image.sh  bakes the replica image, fetching the firmware itself
test.env        replica settings only -- the replica image, partition sizes
docs/           the documentation
```

Nothing left under `test/` needs the firmware, or docker, or a network: the
config gates need python3 and jinja2, and the rest exercise our own Python
directly. It briefly had a directory of its own, `test/unit`, for exactly that
distinction; with one maintainer who always has the firmware, that was a
boundary kept in sync for nobody. Everything that needs a real machine is in
`qa/`, and the machine itself is in `tools/replica/`.

The line between Python and shell here is not taste. Everything that runs on
YOUR machine is Python; everything executed by the printer's own busybox under
qemu stays shell, because the fact that it survives that is a large part of
what the suite proves. See [testing.md](testing.md#why-the-harness-is-python)
for why the host half moved.

Two things keep the boundary from eroding: the only files of ours that
`payload.sh` copies into a package are the ones under a recipe's `payload/`,
`prog/` or `seed/`, and `qa/replica/test_what_ships.py` fails if any file on
the installed printer is byte-identical to one in `bin/` or `docker/`.

## Rebuilding chelper

`klippy/chelper/c_helper.so` must be MIPS32r2 / nan2008 / o32 or klippy dies on
import — `pkgs/klipper` refuses to seal a package with anything else, and
`test-install` checks the copy that lands on the machine. Debian's
cross-compilers cannot produce one (big-endian or legacy-nan); the Ingenic
gcc 7.2.0 / glibc 2.29 toolchain for the X2000 can, and it is pinned by
sha256 in `versions.env` and fetched into `vendor/` like every other asset.

You do not rebuild it by hand any more. `pkgs/klipper` compiles the .so from
the chelper sources of the very tree it is about to ship — the fork tarball
pinned in `versions.env`, which since the recipe landed is the only source
there is. One gate then runs inside the recipe, so `make packages` enforces
it as well as a firmware build: the ELF-flag check above.

A symbol gate used to run beside it, comparing the .so's dynamic symbols
against what klippy cdefs, because cffi resolves lazily -- a stale .so imports
cleanly and dies only at `Internal error during connect` on the printer, with
a traceback that names cffi and not the build. It is gone. What stands in its
place is the compile-fresh rule itself: the .so is built from the chelper
sources of the tree that ships, so a .so older than its klippy is not
something this recipe can produce. Both a stale prebuilt .so (v0.12 binary
under a v0.13 tree) and a package that skipped the fork entirely
(v20260824-nova-kakhovka) have shipped, and that rule is what makes the third
time structurally hard.

## The docs site

These pages are the site at
[reforge.readthedocs.io](https://reforge.readthedocs.io/). Read the Docs
builds `mkdocs.yml` out of this repo on every push to `master` and once per
tag, so a page and the code it describes move in the same commit and the same
review, and an owner running an older package can read that package's docs
from the version switcher rather than master's.

To preview locally:

```sh
python3 -m venv .venv && .venv/bin/pip install -r docs/requirements.txt
.venv/bin/mkdocs serve          # http://127.0.0.1:8000
.venv/bin/mkdocs build --strict # what CI and RTD run
```

Three things about it are worth knowing before you add a page.

**The nav is split by audience, and the split is the point.** `mkdocs.yml` has
a *Using Reforge* section for someone who owns the printer and a *For
contributors* section for someone building or testing the firmware, with the
`docs/notes/` internals nested inside the second. A new page that is not in
that nav is built but unreachable. Put it in the section its reader is
standing in.

**Links stay repo-relative.** Write `../payload/klipper/extras/ff_tool.py` and
`notes/40-offsets.md` exactly as you would for someone reading the page on
GitHub; `hooks/mkdocs_readme.py` turns the ones that leave `docs/` into GitHub
URLs at build time. Anchors use GitHub's slug rules, so `#runout--clog` for
`## Runout / clog` works in both places. The same hook generates
`docs/index.md` from `README.md` on every build — edit the README, never that
file, which is gitignored.

**A dead link fails the build.** CI's `docs` job and RTD both build with
`--strict`, so renaming a file in `payload/` breaks the build rather than
leaving a doc pointing at nothing. It cannot check that the prose is still
true; only a reader can.
