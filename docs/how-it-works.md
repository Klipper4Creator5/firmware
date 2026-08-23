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
S60web       nginx (Mainsail) + moonraker
S70klipper   Klipper
S80ui        decides whether the UI runs; owns SAFE-MODE
```

Everything the mod installs lives under `/usr/data/anvil` on the **data**
partition, which a FlashForge OTA cannot delete. The software component itself
goes to `/usr/prog` on the firmware partition, which only holds two versions
and cannot fit ~100MB of web UI — that is why Mainsail and HelixScreen ride in
the outer package instead.

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
`make test-model` both check this.

## Recovery

Recovery is the stock FlashForge package for your model. Flashing it restores
every file the mod touches; the payload under `/usr/data/anvil` survives but is
inert. `make test-recovery` proves it, by doing exactly that inside the
replica and diffing the result against stock.
