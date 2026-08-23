# Building your own packages

You need a stock FlashForge update package for your model — this builds *from*
it, it does not replace it. Everything else is Docker.

```sh
cp config.env.example config.env     # what to build, and what ships
$EDITOR config.env                   # point it at your stock package
make probe                           # pre-flight: changes nothing, reports back
make default                         # the firmware
```

The package lands in `work/out/`. `make release PROFILE=<p>` builds both
models into `dist/`.

## Requirements

Docker. That is the whole list — the build image carries `openssl`, `tar`,
`xz`, `unzip`, `python3`, `binutils`, `squashfs-tools` and `qemu-user-static`,
and every target runs inside it. `make shell` drops you into it.
`LOCAL=1 make <target>` runs on the host instead.

Only the test targets get the docker socket mounted through, so they can start
the replica as a sibling container. A build cannot reach the docker daemon.

## The pipeline

```
fetch-assets.sh  download Mainsail + HelixScreen into vendor/ (see below)
unpack.sh   decrypt the stock .tgz, open the software component
patch.sh    apply the mods to work/software/ and build work/modpayload/
pack.sh     regenerate md5sum.list, tar, encrypt → work/out/<Model>-anvil-<date>.tgz
verify.sh   simulate every check the printer performs, against the built file
```

`make build` is all four. Each is idempotent and safe to re-run.

Packages carry only the **software** component by default. The stock installer
skips any component that is absent, so the kernel, the rootfs image and the
MCU/board firmware are left untouched — MCU flashing is the riskiest thing in
a package and there is no reason to run it for a userspace mod. `FULL=1 make
<target>` carries all four.

## Profiles

There are two, and only two. `profiles/*.env` set the `BUILD_*` flags:

| Profile | Klipper | Mainsail | HelixScreen | ssh | Report |
|---|---|---|---|---|---|
| `probe` | stock | – | – | – | ✓ |
| `default` | fork | ✓ | ✓ (as the UI) | ✓ | – |

`probe` is a pre-flight check: it reinstalls the stock software byte-for-byte
and writes a diagnostic report to the USB stick, proving the update chain
works on *your* machine before anything changes. `default` is the firmware.

There used to be five profiles — `ssh`, `web`, `full` and `helix` climbing one
feature at a time. They are collapsed into `default`: the intermediate rungs
each needed their own flash-and-verify cycle, and the recovery story is the
same at every rung (flash the stock package), so the extra loops bought
caution nobody was spending.

```sh
make probe                        # pre-flight
make default                      # the firmware
make all-profiles                 # both
make release PROFILE=default      # both models, into dist/
MODEL=Creator5 make default       # just the non-Pro
```

## Two kinds of flag

This distinction is the one to keep straight:

* **`BUILD_*`** decides what goes *into* a package. Read at build time only,
  owned by `profiles/*.env`, never present on the printer.
  (`BUILD_APPLY`, `BUILD_REPORT`, `BUILD_KLIPPER`, `BUILD_TOOLCHANGE`,
  `BUILD_MAINSAIL`, `BUILD_HELIX`.)
* **`MOD_*`** are runtime switches. They are written into
  `/usr/data/anvil/anvil.conf`, which the printer re-reads at every boot, so
  they can be changed over ssh afterwards and survive a mod update.
  (`MOD_UI`, `MOD_WEB`, `MOD_SSH`.)

`BUILD_REPORT` is the diagnostic report, and it is a debug payload:
`payload/report.sh` copies `/etc`, `passwd` and `shadow` onto the USB stick.
Only the `probe` profile turns it on.

## Third-party pieces are downloaded, not vendored

Mainsail and the HelixScreen build for this printer are large binaries, so the
repo does not carry them — and never has, so there is nothing in the git
history either. `versions.env` pins each one by version and sha256:

```sh
MAINSAIL_VERSION="v2.18.2"
HELIX_VERSION="v0.99.115-creator5"
```

`bin/fetch-assets.sh` downloads them into `vendor/` (gitignored) and refuses
anything whose sha256 does not match the pin. A cached file with the right
hash is never re-downloaded, so it is a no-op on every build after the first.
`bin/build.sh` calls it for you; `make vendor` pre-fetches everything.

To bump a version: edit `versions.env`, run `make vendor`, and paste the
sha256 it prints back into the file.

Setting `MAINSAIL_ZIP` or `HELIX_TGZ` in `config.env` overrides the download
and builds against your own local copy. An explicit path is used as-is and is
never checksummed.

If a profile asks for Mainsail or HelixScreen and the file is not there, the
build fails. It used to skip silently, which shipped a package with an empty
web root and no way to notice.

## The root password

`ROOT_PW_HASH` in `config.env` is written straight into the shipped shadow
file at build time. Leave it empty and the *installer* picks a random password
on the printer instead, and writes it to `anvil-password.txt` on the USB stick
it was flashed from.

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
  init.d/         S60web, S70klipper, S80ui
  anvil.conf      runtime switches, preserved across mod updates
  run-pre.sh      backups, injected at the TOP of the stock run.sh
  run-append.sh   payload install, injected before its exit
  report.sh       the pre-flight diagnostic (BUILD_REPORT=1 -- probe only)
assets/         nginx.conf, moonraker.conf
```

**Builds it** — host-side, never installed:

```
bin/            fetch-assets -> unpack -> patch -> pack, plus verify
profiles/       probe and default
versions.env    pinned Mainsail / HelixScreen versions + sha256
vendor/         where fetch-assets.sh caches them (gitignored)
config.env      your paths, the root password hash, the model
docker/         Dockerfile.build -- the container every target runs in
```

**Tests it** — never ships, and never touched by a build:

```
test/           the suite, the synthetic fixture, the brick lint
  printer/        the replica: binfmt, mount layout, its two Dockerfiles,
                  and the cases that run inside it on the printer's binaries
  extract-rootfs.sh       pulls the real rootfs out of the stock package
  build-printer-image.sh  bakes a prebuilt replica image
test.env        replica settings only -- factory image, partition sizes
docs/           the documentation
```

Two things keep the boundary from eroding: only `payload/` and `assets/` are
ever copied into a package by `patch.sh`, and `make verify` fails if a built
package contains any file byte-identical to one in `bin/`, `test/`, `docker/`
or `profiles/`.

## Rebuilding chelper

`klippy/chelper/c_helper.so` must be MIPS32r2 / nan2008 / o32 or klippy dies on
import — `patch.sh` refuses to build a package with anything else, and
`make test-abi` checks every shipped binary. Debian's cross-compiler cannot
produce one; use the Ingenic/K1 toolchain. See the Klipper fork's own notes.
