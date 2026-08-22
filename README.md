# creator5-custom-firmware

Build custom firmware for the FlashForge **Creator 5 / Creator 5 Pro**: take
the stock update package, modify it, pack it back up, copy it to a USB stick.
The printer installs it by itself on the next power-on — no jailbreak, no ssh,
no opening the case.

```sh
cp config.env.example config.env     # point it at your stock package
make probe                           # stage 0: changes nothing, reports back
make test                            # full brick-safety suite
```

**Nothing runs on your machine except Docker.** Every make target executes
inside a pinned build image; the docker socket is mounted through so the test
targets can start sibling containers. `LOCAL=1 make <target>` opts out.

> **Unofficial and unaffiliated with FlashForge.** It voids your warranty and
> you are responsible for your machine. Nothing here has been run on hardware
> yet — see [Status](#status).

---

## How it works

We reuse FlashForge's own updater rather than writing a parallel one. The
stock chain, recovered from `app_startup.sh`, the `unTar` binary and the
rootfs image:

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
`/usr/prog/PROGRAM/software/firmwareExe` with a shell script. Because
everything funnels through that binary, `app_startup.sh`, `rcS` and the whole
init chain stay **completely stock and unpatched**. The genuine binary is kept
beside it as `firmwareExe.stock` and remains the default UI.

Services are ordinary init.d-style scripts in `/usr/data/mod/init.d/`, run in
filename order and individually restartable over ssh:

```
S60web       nginx (Mainsail) + moonraker
S70klipper   Klipper
S80ui        decides which UI runs; owns SAFE-MODE
```

Everything the mod installs lives under `/usr/data/mod` on the **data**
partition, which a FlashForge OTA cannot delete.

---

## Five things the stock firmware does that will surprise you

Each of these silently breaks a package or a printer, and each is enforced by
a check in `make test`:

| | Reality |
|---|---|
| **`*.tar.xz` is not xz** | The components are plain tar archives carrying an `.xz` name. The installer runs a bare `tar -xvf`, so a genuinely xz-compressed file does not install. |
| **`.tgz` is not gzip** | DES3-encrypted plain tar. The key is hardcoded in the printer's own `unTar` binary. Modern OpenSSL needs `-md md5` to match its OpenSSL 1.0.2. |
| **Nothing in init starts Klipper** | `firmwareExe` runs `/usr/prog/klipper/start.sh`. Replace the UI without accounting for this and the printer boots to a working screen that cannot move or heat. |
| **The installer wipes the software dir first** | `ls \| grep -v temp \| xargs rm -rf` runs *before* `run.sh`, so the previous `firmwareExe` is already gone. An uninstall package must **ship** the genuine binary; it cannot back one up. |
| **Binaries must be nan2008** | The Ingenic X2000 kernel returns `ENOEXEC` for legacy-NaN MIPS. Debian's `gcc-mipsel-linux-gnu` cannot produce a usable binary — its libc is legacy-NaN. |

**And one pleasant surprise, found by unpacking `rootfs.squashfs` out of the
kernel component:** ssh needs no work at all. The stock rootfs
already ships `/usr/sbin/dropbear` and an enabled `/etc/init.d/S50dropbear`,
so port 22 is *already open* on a stock printer. There is simply no published
root password. Setting `ROOT_PW_HASH` is the whole feature.

---

## Profiles: a ladder, not a menu

Each profile is a rung. Flash them in order — every rung makes the next one
recoverable. Full procedure with go/no-go checks:
**[docs/hardware-testing.md](docs/hardware-testing.md)**.

| Profile | What it changes | Why this rung |
|---|---|---|
| `probe` | **nothing** | Proves the chain works on your unit and reports partition sizes, the init layout and the stock nginx config back onto the USB stick |
| `ssh` | root password | Gives you a recovery channel before anything risky |
| `web` | + Mainsail/moonraker | Uncomments what stock already ships; Klipper untouched |
| `full` | + forked Klipper, toolchanger | First rung that changes how the machine moves |
| `helix` | + HelixScreen as the UI | First rung where the stock UI stops driving the screen |

```sh
make probe            # or: make build PROFILE=probe
make all-profiles
```

**Recovery** is the stock FlashForge package for your model — keep a copy on a
spare stick. Flashing it restores every file the mod touches; the payload
under `/usr/data/mod` survives but is inert. `make test-recovery` proves it.

### Two models, two packages

Creator 5 and Creator 5 Pro are **not interchangeable**. Each stock package
carries a `MACHINE=`/`PID=` gate that refuses to install on the other model,
and — the part that actually matters — they ship **different `firmwareExe`
binaries**. A package built for one model would hand the other the wrong
firmware, so each must be built from its own stock package.

```sh
make release PROFILE=web     # builds BOTH into dist/
MODEL=Creator5 make web      # just the non-Pro
```

| Model | MACHINE | PID | USB filename the printer looks for |
|---|---|---|---|
| Creator 5 | `Creator5` | `0028` | `/mnt/Creator5-*.tgz` |
| Creator 5 Pro | `Creator5Pro` | `0029` | `/mnt/Creator5Pro-*.tgz` |

Set `TARGET_MACHINE` in `config.env`; `make verify` fails on a mismatch, and
`make test-model` asserts each package is gated correctly and carries its own
model's firmware.

---

## Testing: how we know it does not brick

`make test` needs no printer and no proprietary firmware — a synthetic fixture
(`test/fixtures/make-stock-fixture.sh`) reproduces the package *structure*, so
the whole pipeline runs in CI on a clean machine.

| Test | What it does |
|---|---|
| `test-lint` | Scans on-printer scripts for brick patterns: raw block-device writes, `rm -rf` of top-level paths, unguarded `rm -rf $VAR/`, missing backups |
| `test-install` | **Runs the installer for real** in a container with a fake printer rootfs, then asserts the printer would still boot: UI present and executable, touchscreen driver intact, boot scripts unmodified, user `printer.cfg` preserved, re-install idempotent |
| `test-recovery` | Installs the mod, then flashes the **stock** package, and asserts the machine is genuinely back to stock and the leftover payload is inert |
| `test-ui` | Drives the UI selection logic: helix missing, crash-loop, SAFE-MODE latch and release, **and the no-UI-at-all case** |
| `test-model` | Each package's filename prefix matches the gate inside, the PID matches the model, and the two models ship **different** `firmwareExe` binaries |
| `test-ash` | Parses every on-printer script with the **printer's own busybox 1.31.1 ash**, extracted from the stock `rootfs.squashfs` and run under `qemu-mipsel` — a parse error in `firmwareExe` means a blank screen |
| `test-abi` | Every shipped MIPS binary is `nan2008`/`mips32r2`/`o32`, and executes under `qemu-mipsel` |

These are not theoretical. Writing them caught four real bugs before any
hardware was involved:

- backups were taken *after* the stock `run.sh` had already overwritten the
  files, so the uninstall package would have restored the modified versions
- the uninstall package shipped no `firmwareExe`, so uninstalling would have
  left a blank screen
- `rm -rf $MODDIR/bin` with an unset `MODDIR` expands to `rm -rf /bin`
- a crashed UI is a *zombie*, and `kill -0` succeeds on a zombie — the crash
  detector called a dead UI healthy

---

## Requirements

Docker. That is the whole list — the build image carries `openssl`, `tar`,
`xz`, `unzip`, `python3`, `binutils`, `squashfs-tools` and `qemu-user-static`,
and every target runs inside it. `make shell` drops you into it.

`make rootfs` extracts the printer's genuine root filesystem from the stock
package's `kernel-*.tar.xz` (it contains `rootfs.squashfs`) and enables
`make test-ash`. It is never committed — it is FlashForge's firmware.

---

## Layout

```
bin/            unpack → patch → pack, plus verify / make-uninstall
payload/        what runs ON the printer (POSIX sh, busybox ash)
  firmwareExe     the wrapper that replaces the stock binary
  init.d/         S60web, S70klipper, S80ui
  run-pre.sh      backups, injected at the TOP of the stock run.sh
  run-append.sh   payload install, injected before its exit
  report.sh       the stage-0 diagnostic report
profiles/       the ladder
assets/         nginx.conf, moonraker.conf
test/           the suite above + the synthetic fixture
docs/           hardware-testing.md
```

---

## Status

The build pipeline and the full test suite pass on a development machine
(75 checks). **No package has been installed on a printer yet.** The Klipper
`creator5` branch this builds on is itself documented as not yet run on
hardware.

Start at stage 0, and build the uninstall stick before you start.
