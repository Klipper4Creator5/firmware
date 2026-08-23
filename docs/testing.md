# Testing: how we know it does not brick

The suite has two halves, and only one of them can answer the question.

**Half 1 — static and packaging.** Needs no printer and no proprietary
firmware: a synthetic fixture (`test/fixtures/make-stock-fixture.sh`)
reproduces the package *structure*, so shell syntax, bashism and brick-pattern
lint, the packaging pipeline and the model gates all run in CI on a clean
machine.

**Half 2 — the printer replica.** The real `rootfs.squashfs`, extracted from
the stock package, chrooted under `qemu-mipsel`, with `/usr/prog` installed by
FlashForge's own updater. The installer under test runs on the printer's
busybox, tar, md5sum and `unTar` — not on Debian stand-ins — with a read-only
root and writable prog/data partitions, exactly like the machine. This is the
half that can catch a brick, it needs the stock package, and
`.github/workflows/release.yml` refuses to publish without it.

With `PROG_DUMP` (in `test.env`) pointed at a factory image, the replica has
essentially nothing invented left: the klipper daemons, `nginx`, `python3`,
`moonraker` and the printer's **own OpenSSL 1.0.2d** are all genuine, so
package decryption is verified against the real implementation. What remains
substituted is `insmod`/`reboot`/`cmd_mcu`, neutered because they would act on
the host kernel or real hardware, and the partition sizes.

See **[printer-replica.md](printer-replica.md)** for what is authentic, what
is stubbed, and what it still cannot tell you.

## The tests

```sh
make test            # everything below
```

| Test | What it does | Replica |
|---|---|:-:|
| `test-lint` | Scans on-printer scripts for brick patterns: raw block-device writes, `rm -rf` of top-level paths, unguarded `rm -rf $VAR/`, missing backups, a boot chain that could end with no UI | |
| `test-model` | Each package's filename prefix matches the gate inside, the PID matches the model, and the two models ship **different** `firmwareExe` binaries | |
| `test-install` | Replays what `app_startup.sh` does with a USB stick — its own glob, its own `unTar`, its own `runFirmwareExe.sh` — then asserts the printer would still boot: UI present and executable, boot scripts unmodified and still parsing, Klipper owned by a service, `c_helper.so` still nan2008 MIPS, user `printer.cfg` preserved, re-install idempotent | ✓ |
| `test-recovery` | Installs the mod, then flashes the **stock** package, and asserts the machine is genuinely back to stock byte-for-byte and the leftover payload is inert | ✓ |
| `test-ui` | Drives the UI selection logic on the printer's shell: helix missing, crash-loop, SAFE-MODE latch and release, **and the no-UI-at-all case** | ✓ |
| `test-applets` | Every command the payload runs exists on the printer. Its busybox has no `timeout`, no `bash`, no `systemctl`; reaching for one is a blank screen at boot | ✓ |
| `test-ash` | Parses every on-printer script with the printer's own busybox 1.31.1 ash | ✓ |
| `test-abi` | Every shipped MIPS binary is `nan2008`/`mips32r2`/`o32`, and executes under `qemu-mipsel` | ✓ |

The replica tests need `make rootfs` first, which extracts the printer's
genuine root filesystem from the stock package's `kernel-*.tar.xz`. It is
never committed — it is FlashForge's firmware. `make test` skips the replica
half with a loud message when no stock package is configured;
`REQUIRE_PRINTER_SIM=1` turns that skip into a failure.

`make printer-image` bakes the whole thing — rootfs, `/usr/prog`, `/usr/data`
— into a Docker image, which takes a replica run from ~1m35s to ~15s. That
image contains proprietary FlashForge firmware.

## Bugs these caught

Not theoretical. Writing them caught real bugs before any hardware was
involved:

- backups were taken *after* the stock `run.sh` had already overwritten the
  files, so a restore would have restored the modified versions
- `rm -rf $MODDIR/bin` with an unset `MODDIR` expands to `rm -rf /bin`
- a crashed UI is a *zombie*, and `kill -0` succeeds on a zombie — the crash
  detector called a dead UI healthy
- the packer emitted both models' filenames from one build, which would have
  handed a Creator 5 the Pro's firmware
- three checks in the brick lint had been quietly dead for months: two were
  guarded on a `payload/boot.sh` that no longer existed, and the file glob
  never matched `firmwareExe` or the `init.d/S*` scripts at all
