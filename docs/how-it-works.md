# How it works

## Reusing FlashForge's own updater

We reuse FlashForge's updater rather than writing a parallel one. The stock
chain, recovered from `app_startup.sh`, the `unTar` binary and the rootfs
image:

```
busybox init → /etc/init.d/rcS → S99factory_test_shell
             → /usr/prog/app_startup.sh
                 ├─ mounts /dev/sda* on /mnt, globs Creator5Pro-*.tgz
                 ├─ /usr/prog/bin/unTar  (des3 decrypt → /usr/data/update)
                 └─ runFirmwareExe.sh Creator5Pro 0029
                        └─ per component: extract → md5 gate → run.sh
             → firmwareExe  ← the UI, and what starts Klipper
```

The mod's entire integration point is **one file**: it replaces
`/usr/prog/PROGRAM/software/firmwareExe` with a shell script that runs
HelixScreen. Because everything funnels through that binary, `app_startup.sh`,
`rcS` and the whole init chain stay **completely stock and unpatched**. The
genuine binary is not kept anywhere — the stock installer wipes the software
directory before `run.sh` runs, so nothing on the printer could ever be a
reliable backup of it. Flashing the stock FlashForge package, which still
ships it, is the uninstall.

Two properties come for free from keeping that name and that place:

* `app_startup.sh`'s own watchdog greps `ps` for `firmwareExe` five seconds
  after launch. The wrapper *is* `firmwareExe` and stays in the foreground, so
  the stock watchdog supervises the mod correctly.
* If the wrapper is ever removed, `app_startup.sh` restores a `firmwareExe`
  from the newest version directory — the stock recovery path still works.

## Services

Services are ordinary init.d-style scripts in `/usr/data/anvil/init.d/`, run in
filename order and individually restartable over ssh:

```
S50wifi      wlan0 + wpa_supplicant + udhcpc
S60web       nginx (Mainsail) + moonraker
S65camera    mjpg-streamer on :8080 (nginx proxies it at /webcam/)
S70klipper   Klipper
S80ui        decides whether the UI runs; owns SAFE-MODE
```

Everything the mod installs lives under `/usr/data/anvil` on the **data**
partition, which a FlashForge OTA cannot delete. The software component itself
goes to `/usr/prog` on the firmware partition, which keeps only one version
(the installer wipes every other version directory) and cannot fit ~100MB of
web UI — that is why Mainsail and HelixScreen ride in
the outer package instead.

## Moonraker

The mod ships its own Moonraker (pinned in `versions.env`) and installs it over
the stock one. FlashForge's is a 2022 build that reports API 1.0.5, old enough
that the current Mainsail hides features it cannot see. The visible one is the
camera: Moonraker only grew the webcam `enabled` flag in April 2023, Mainsail
filters its webcam list on exactly that field, and so every `[webcam]` entry is
discarded and the panel disappears — while the stream itself is perfectly
healthy behind nginx. No config change can fix that from either side.

Only the python package tree is replaced. The interpreter, the `moonraker-env`
beside it and `moonrakerDaemon` are FlashForge's and keep working, because the
pinned build runs on the libraries already installed — nothing has to be
cross-compiled for mipsel.

**The pin is a commit, not a release, and that is not a matter of taste.**
FlashForge built python 3.8.2 without the `_sqlite3` module — there is no
`_sqlite3*.so` in `lib-dynload` and no `libsqlite3` anywhere on the image, just
the pure-python `sqlite3/` wrapper that cannot work without it. Moonraker moved
its database from lmdb to sqlite in v0.9.0, so every release from there on gets
as far as loading the database component and dies with `ModuleNotFoundError: No
module named '_sqlite3'`. The last release still on lmdb is v0.8.0, which
predates the webcam flag. No release has both, so the pin is the newest commit
that does. The printer's lmdb store is used in place — nothing is converted,
and reverting to stock is a clean round trip.

This was not worked out in advance; v0.9.3 was built, shipped and tried on the
printer first, and that is what it said. Two things came out of it. The
installer now asks the printer's own python to import the tree *before* moving
anything, and keeps the stock server if it cannot — a bad pin refuses to
install instead of leaving the machine with no web UI. And when bumping the
pin, the blocker to check is native modules, not the python version.

Moonraker does not come from the update package at all — it exists only on the
factory image, and the stock `run.sh` copies a hand-written list of paths out
of the software component rather than extracting it over `/usr/prog`. So the
tree travels with the mod payload and `run-append.sh` puts it in place, moving
the old one aside first and restoring it if the copy does not complete.

`make test` covers this end to end on the printer replica: that the swap
happened, that the installed `webcam.py` has the `enabled` field, that the
shipped tree runs on the printer's own python3.8 **and is still running after a
settle**, and that its log has no import errors. The settle matters — a build
that dies on a missing module is alive for a second or two first, and checking
only "did it start" is what let the sqlite3 failure through.
`BUILD_MOONRAKER=0` builds a package that leaves the stock server alone.

## Five things the stock firmware does that will surprise you

Each of these silently breaks a package or a printer, and each is enforced by
a check in `make test`:

| | Reality |
|---|---|
| **`*.tar.xz` is not xz** | The components are plain tar archives carrying an `.xz` name. The installer runs a bare `tar -xvf`, so a genuinely xz-compressed file does not install. |
| **`.tgz` is not gzip** | DES3-encrypted plain tar. The key is hardcoded in the printer's own `unTar` binary. Modern OpenSSL needs `-md md5` to match its OpenSSL 1.0.2. |
| **Nothing in init starts Klipper** | `firmwareExe` runs `/usr/prog/klipper/start.sh`. Replace the UI without accounting for this and the printer boots to a working screen that cannot move or heat. |
| **The installer wipes the software dir first** | `ls \| grep -v temp \| xargs rm -rf` runs *before* `run.sh`, so the previous `firmwareExe` is already gone. Uninstalling means flashing the stock package, which still **ships** the genuine binary; nothing can back one up. |
| **Binaries must be nan2008** | The Ingenic X2000 kernel returns `ENOEXEC` for legacy-NaN MIPS. Debian's `gcc-mipsel-linux-gnu` cannot produce a usable binary — its libc is legacy-NaN. |

**And one pleasant surprise, found by unpacking `rootfs.squashfs` out of the
kernel component:** ssh needs no work at all. The stock rootfs already ships
`/usr/sbin/dropbear` and an enabled `/etc/init.d/S50dropbear`, so port 22 is
*already open* on a stock printer. There is simply no published root password.
Setting `ROOT_PW_HASH` is the whole feature.

## Two models, two packages

Creator 5 and Creator 5 Pro are **not interchangeable**. Each stock package
carries a `MACHINE=`/`PID=` gate that refuses to install on the other model,
and — the part that actually matters — they ship **different `firmwareExe`
binaries**. A package built for one model would hand the other the wrong
firmware, so each must be built from its own stock package.

| Model | MACHINE | PID | USB filename the printer looks for |
|---|---|---|---|
| Creator 5 | `Creator5` | `0028` | `/mnt/Creator5-*.tgz` |
| Creator 5 Pro | `Creator5Pro` | `0029` | `/mnt/Creator5Pro-*.tgz` |

The filename prefix and the gate inside must agree: `app_startup.sh` globs for
the prefix, and `runFirmwareExe.sh` checks the gate. A mismatch means the
printer picks the file up and then refuses it. `make verify` and
`bin/verify.sh` both check this.

## Recovery

Recovery is the stock FlashForge package for your model. Flashing it restores
every file the mod touches; the payload under `/usr/data/anvil` survives but is
inert. `make test-recovery` proves it, by doing exactly that inside the
replica and diffing the result against stock.
