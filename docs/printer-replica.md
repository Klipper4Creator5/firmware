# The printer replica

Everything in `test/printer/` exists to answer one question honestly: **would
this package brick the machine?**

A Debian container with hand-written stand-ins cannot answer it. The stock
installer is shell, and shell behaviour is not portable in the ways that
matter here — Debian's `/bin/sh` is dash, which rejects
`${file_name:${#start_head}:${version_length}}` with *Bad substitution*, while
the printer's busybox accepts it. Get that wrong in either direction and the
simulation and the printer disagree about whether an update installs at all.

So the replica runs the printer's own userland.

## What it is

```
work/rootfs/          rootfs.squashfs, extracted from the stock package's
                      kernel component -- the printer's real root filesystem
                      (busybox 1.31.1, glibc 2.33, MIPS32r2 nan2008, mipsel)
```

`test/printer-exec.sh` starts a privileged container that:

1. registers a `binfmt_misc` handler so MIPS binaries execute (see below),
2. builds the machine's mount layout,
3. installs the **stock FlashForge package** with FlashForge's own installer,
4. `chroot`s in and runs the test case.

From step 4 onward there is no host shell involved. `sh`, `tar`, `md5sum`,
`expr`, `find`, `cmp`, `unzip` and the `unTar` decryptor are all the
printer's binaries, executing under `qemu-mipsel`.

## The mount layout

Copied from the machine (`/etc/fstab`, `/etc/init.d/S09mount_mmc_prog`,
`/etc/init.d/S21mount_mmc_ext4`):

| path | what it is | mode |
|---|---|---|
| `/` | `rootfs.squashfs` | **read-only** |
| `/usr/prog` | ext4 `usershare` partition | rw |
| `/usr/data` | ext4 `userdata` partition | rw |
| `/tmp`, `/run` | tmpfs | rw |
| `/mnt` | the USB stick | rw |

Root is read-only on purpose. On the printer a write to `/bin` or `/etc`
silently fails; a mod that depended on one would pass a permissive sandbox and
fail on the machine.

`/dev` is a tmpfs holding only `null`, `zero`, `random`, `urandom`, `tty` and
a regular file for `fb0` (the installer does `cat start.img > /dev/fb0`).
There are **no block devices**, and `/sys` is mounted read-only, so nothing
inside the replica can reach a real disk.

## The one-byte reason this did not work before

`qemu-user-static` registers a binfmt matcher for mipsel whose mask requires
`e_ident[EI_ABIVERSION]` — byte 8 of the ELF header — to be `0`. Every binary
the Ingenic toolchain produced for this printer has `3` there:

```
00000000: 7f45 4c46 0101 0100 0300 0000 0000 0000  .ELF............
                            ^^ EI_ABIVERSION = 3
```

So the stock handler never matched, and every attempt to run a printer binary
came back `exec format error` — with qemu installed, registered and enabled.
`test/printer/binfmt.sh` registers a handler with that byte masked out.
Everything else is the stock mipsel matcher.

The handler is registered with the `F` (fix-binary) flag, so the kernel holds
the interpreter open and it resolves inside the chroot without copying qemu
into the printer's filesystem.

## Getting rid of the stubs entirely

`/usr/prog` is a factory image that no update package contains. Three things
can supply it, in descending order of authenticity, and the replica takes the
best one available:

1. **`PROG_DUMP`** — a real `/usr/prog` off a printer, used verbatim:

   ```sh
   ssh root@printer 'tar -cf - /usr/prog' > prog.tar
   # then in test.env:
   PROG_DUMP="/path/to/prog.tar"
   ```

   With one, nothing below is stubbed: the klipper daemons, `nginx`,
   `python3`, `checkEboard` and the printer's own OpenSSL 1.0.2d all become
   genuine, and the `-md md5` substitution disappears because the real 1.0.2d
   binary runs under qemu. This is the single highest-value artefact you can
   hand the test suite.

2. **FlashForge's own installer**, run inside the replica.

3. **Stubs**, for whatever neither of those provides.

A full-filesystem factory image works too, and one is published:

```
https://github.com/ghzserg/FF/releases/download/R/Creator5Pro-factory.tar.xz
md5 d2fdc0e1deb17c41cbb6016d55ab3031   182MB compressed, 828MB extracted
```

It is the genuine `/usr/prog` and `/usr/data` off a Creator 5 Pro —
`Python-3.8.2`, `nginx`, `openssl-1.0.2d`, `moonraker`, `qt-4.8.6`,
`ffmpeg-4.0.2`, `opencv-4.10`, the klipper tree, `firmwareRes`, the stock
configs. Point `PROG_DUMP` (in `test.env`) at the `.tar.xz` directly; the replica works out
whether an archive is a whole-filesystem image or the contents of `/usr/prog`
and unpacks it accordingly.

With it, the replica decrypts packages using the printer's **own** OpenSSL
1.0.2d binary under qemu — so the `-md md5` packing is verified against the
real implementation rather than against an assumption about it.

## What is authentic and what is not

`/usr/prog` on a real printer is a factory image that no update package
contains. The replica gets as close as the packages allow:

* **Installed for real, by FlashForge's own `run.sh`**: `app_startup.sh`,
  `klipper/` (klippy, extras, kinematics, `chelper/c_helper.so`), `start.sh`,
  `klipper_pri.sh`, `unTar`, `wakeup_level`, `firmwareExe`, `passwd`,
  `shadow`, `modules/`, `PROGRAM/{software,library}/<version>/`, plus
  `ffmpeg-402` and the `firmwareRes` image set from the library component.
* **Genuine, with `PROG_DUMP` set**: everything else on the prog partition —
  `klipperDaemon`, `moonrakerDaemon`, `checkEboard`, `nginx`, `python3`,
  `moonraker`, the stock `nginx.conf`, and the printer's OpenSSL 1.0.2d.
* **Stubbed, only without a dump**: those same files, plus a
  `/usr/prog/openssl-1.0.2d/bin/openssl` that is OpenSSL 3 pinned to
  `-md md5`. `unTar` runs `openssl des3 -d -k … -salt` with no `-md` and
  relies on OpenSSL 1.0.2's MD5 key derivation, so pinning makes the replica
  accept exactly the packages the printer accepts.
* **Neutered, always**: `insmod`, `rmmod`, `modprobe`, `reboot`, `poweroff`,
  `halt` and `cmd_mcu`. The first six would act on the host kernel; `cmd_mcu`
  is called by klipper's `start.sh` as `cmd_mcu write_firmware`, and the
  genuine binary is neutered in place rather than shadowed, so nothing depends
  on PATH order.

Every one of these is listed inside the replica at `/usr/prog/.SIMULATED`, so
a test can never quietly depend on a stub without it being visible.

The baseline install deliberately skips the `kernel-*` and `control-*`
components: one rewrites eMMC partitions, the other flashes MCUs over
`/dev/ttyS*`. Neither can do anything useful in a container, and both are
destructive if they ever found real hardware.

## Why not full-system emulation

The obvious next step would be `qemu-system-mipsel` booting the printer's own
kernel. It does not help. The kernel in the stock package is built for the
Ingenic X2000 SoC and there is no QEMU machine for it; booting the userland
under `qemu-system-mipsel` would mean supplying some *other* mipsel kernel
(malta, say), which is no more the printer's kernel than the host's is. What
it would cost is a boot cycle per test and a second kernel to maintain.

The install path is file operations and shell, and those run on the printer's
own binaries here. The host kernel serves the syscalls; the printer's kernel
is 5.6 and the host's is newer, which is a real difference but not one the
installer can see. Where it *would* matter — module loading, MTD writes, MCU
serial — the replica refuses to pretend, and those calls are neutered and
logged instead.

## What it still cannot tell you

* Nothing here drives the screen, the MCUs, the toolchanger or a real print.
  The replica proves the *install* is safe and the machine would *boot*; the
  hardware ladder in `docs/hardware-testing.md` is still how you find out
  whether it *prints*.
* `firmwareExe` is a 20MB Qt binary that wants a framebuffer. It is checked
  for presence, executability and ELF-ness, never run.
* Timing-dependent boot races are not modelled.
* Partition sizes are unbounded unless you set `PROG_MB` and `DATA_MB` (in `test.env`) from
  the `df -h` block in the stage-0 probe report. Until then an install that
  runs the data partition out of space passes here and fails on the machine.
  The replica says so in `/usr/prog/.SIMULATED`.

## Running it

```sh
make rootfs          # once -- extracts rootfs.squashfs from the stock package
make test-install    # install the built package into the replica
make test-recovery   # mod in, stock package back out
make test-ui         # UI selection and crash fallback, on the printer's shell
make test-applets    # every command the payload uses exists on the printer
make test            # all of it
```

`make test` skips the replica half with a loud message if no stock package is
configured. `REQUIRE_PRINTER_SIM=1` turns that skip into a failure — which is
what `.github/workflows/release.yml` sets, so a release cannot ship without
it.
