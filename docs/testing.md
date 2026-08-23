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
root and writable prog/data partitions, exactly like the machine, and the
package reaches it the way it reaches a real printer: on a FAT filesystem that
the machine's own boot script finds and mounts. This is the
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
| `test-install` | **End-to-end.** The package sits on a real FAT filesystem exposed as `/dev/sda1`, and the machine's own `app_startup.sh` runs verbatim through three boots: stick in → it installs; stick still in → it installs again (idempotence); stick pulled → the machine boots with the mod running and the stock `ps`-watchdog satisfied. Asserts along the way: UI present and executable, boot scripts unmodified and still parsing, Klipper owned by a service, `c_helper.so` still nan2008 MIPS, user `printer.cfg` preserved, `firmwareExe.stock` never overwritten | ✓ |
| `test-recovery` | Installs the mod, then flashes the **stock** package, and asserts the machine is genuinely back to stock byte-for-byte and the leftover payload is inert | ✓ |
| `test-ui` | Drives the UI selection logic on the printer's shell: helix missing, crash-loop, SAFE-MODE latch and release, **and the no-UI-at-all case** | ✓ |
| `test-applets` | Every command the payload runs exists on the printer. Its busybox has no `timeout`, no `bash`, no `systemctl`; reaching for one is a blank screen at boot | ✓ |
| `test-ash` | Parses every on-printer script with the printer's own busybox 1.31.1 ash | ✓ |
| `test-abi` | Every shipped MIPS binary is `nan2008`/`mips32r2`/`o32` | |

The replica tests need `make rootfs` first, which extracts the printer's
genuine root filesystem from the stock package's `kernel-*.tar.xz`. It is
never committed — it is FlashForge's firmware. `make test` skips the replica
half with a loud message when no stock package is configured;
`REQUIRE_PRINTER_SIM=1` turns that skip into a failure.

## Speed

Almost all of a replica run used to be setup, repeated per test case:

| | per run |
|---|---|
| unpack the 182MB factory image into `/usr/prog` | 22s |
| install the stock package into it, under qemu | 37s |
| **the test itself** (three boots, install, re-install) | ~30s |

`make printer-image` does both of those once, at build time, and publishes the
result. `test/printer/bake.sh` is the part that cannot be a `docker build`
step — the stock install needs `binfmt_misc` and `chroot`, so it runs in a
privileged container and the result is committed. The md5 of the package that
was installed is recorded in `/usr/prog/.BASELINE`; `entrypoint.sh` reinstalls
only if a run asks for a different one.

With `PRINTER_IMAGE` set in `test.env`, a replica starts in **0.7s** and the
whole end-to-end update test takes **~70s**. Without it, the same test spends
a minute on setup before it begins. That image contains proprietary FlashForge
firmware.

`make test` end to end, measured, with the image: **5m26s**, and the sections
say where it goes — `run-tests.sh` stamps every header with elapsed seconds:

```
== brick-risk lint ==                                    [0s]
== profile: probe / default (on the fixture) ==          [1s]
== extracting the printer rootfs ==                     [16s]
== applets / ash / ABI / UI fallback ==                 [18s]
== end-to-end update on the replica: probe ==           [28s]
== end-to-end update on the replica: default ==        [111s]
== recovery: a stock package reverts the mod ==        [250s]
                                                       [326s]
```

What is left is real work: two full package builds (the `default` payload is
55MB through `xz`) and three replica runs. If it needs to get faster again,
that is where to look — not in the harness.

## What was dropped, and why

Tests that cannot fail are worse than no tests, because they read as coverage:

- **`test-abi`'s execution half.** It was `qemu "$f" -h || [ $? -lt 126 ]`,
  which accepts nearly every exit status — it could only fail if qemu itself
  was missing. Running the binaries for real is what the replica does.
- **`test-ash`'s `md5sum -s` probe.** It printed "inconclusive" on every path
  and could not fail.
- **The per-file `sh -n` "POSIX" loop in `run-tests.sh`.** `sh` is bash on the
  build image, so it proved nothing that `test-ash` does not prove properly
  with the printer's own busybox. Its bashism grep also flagged `local`, which
  busybox ash supports.
- **`test-install`'s hand-written replay of `app_startup.sh`.** It re-derived
  the glob, `MACHINE` and `PID` with `sed` and then called the installer
  itself — so a mistake in our reading of the boot script could never be
  caught. It now runs the boot script.
- **The release workflow's final `sim-install` loop** ignored the exit status
  of every run, so the last gate before publishing could not fail. It now
  stops on the first failure and runs with `REQUIRE_PRINTER_SIM=1`, which
  turns a skip into a failure too.

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
