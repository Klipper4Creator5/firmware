# The printer replica

Everything in `test/integration/printer/` exists to answer one question honestly: **would
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

`test/integration/printer-exec.py` starts a privileged container that:

1. registers a `binfmt_misc` handler so MIPS binaries execute (see below),
2. builds the machine's mount layout,
3. installs the **stock FlashForge package** with FlashForge's own installer —
   only when `BASE_PKG` is set. The bring-up module does not need it, so the MCU
   gate skips this step,
4. `chroot`s in and runs the test case.

From step 4 onward there is no host shell involved. `sh`, `tar`, `md5sum`,
`find`, `cmp` and the `unTar` decryptor are all the printer's binaries,
executing under `qemu-mipsel` (`expr` and `unzip` are the printer's too, but
are reached only from inside the stock installer, not from any case script).

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

`/dev` is a tmpfs holding `null`, `zero`, `full`, `random`, `urandom`, `tty`,
a `devpts` at `pts`, a tmpfs at `shm`, and a regular file for `fb0` (the
installer does `cat start.img > /dev/fb0`). `/sys` is mounted read-only.

The one block device is the USB stick. With `USB_STICK=1` the harness formats
a FAT filesystem, copies the packages into it, attaches it to a loop device
and exposes it as `/dev/sda1` — the name `app_startup.sh` looks for. That is
what lets the end-to-end test run the boot script *verbatim* instead of
re-implementing it: the printer mounts the stick itself, globs for its own
filename pattern, and decides on its own whether there is an update. Nothing
that could reach an eMMC partition (`mmcblk*`) exists, so a stray write still
has nowhere to go.

`app_startup.sh` mounts the stick with `-o,codepage=936,iocharset=utf8`. The
printer's kernel has `nls_cp936` built in; container kernels usually do not,
so `/bin/mount` is wrapped to try the genuine options first and retry without
`codepage=` only if the kernel rejects them. The retry is recorded in
`/usr/prog/.SIMULATED` and in the neutered-calls log the test prints.

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
`test/integration/printer/binfmt.sh` registers a handler with that byte masked out.
Everything else is the stock mipsel matcher.

The handler is registered with the `F` (fix-binary) flag, so the kernel holds
the interpreter open and it resolves inside the chroot without copying qemu
into the printer's filesystem.

## Getting rid of the stubs entirely

`/usr/prog` is a factory image: update packages carry only slices of it, and
the full thing ships in the factory firmware (see below — it is published).
Two things supply it to the replica, and there is no third:

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

2. **FlashForge's own installer**, run inside the replica, which installs the
   parts an update package does carry on top of it.

There used to be a third: stubs, for whatever neither of those provided. They
are gone. A green run that came from a hand-written `python3` and an OpenSSL 3
pretending to be 1.0.2d is reassurance, not evidence — `test/integration/printer/seed-prog.sh`
now hard-fails when the prog partition is not real.

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

`/usr/prog` on a real printer is the factory image plus every update
installed since. The replica is assembled the same way — the published
factory image supplies the partition, and FlashForge's own installer lays
the update package on top:

* **Installed for real, by FlashForge's own `run.sh`**: `app_startup.sh`,
  `klipper/` (klippy, extras, kinematics, `chelper/c_helper.so`), `start.sh`,
  `klipper_pri.sh`, `unTar`, `wakeup_level`, `firmwareExe`, `passwd`,
  `shadow`, `modules/`, `PROGRAM/{software,library}/<version>/`, plus
  `ffmpeg-402` and the `firmwareRes` image set from the library component.
* **Genuine, from the factory image**: everything else on the prog partition —
  `klipperDaemon`, `moonrakerDaemon`, `checkEboard`, `nginx`, `python3`,
  `moonraker`, the stock `nginx.conf`, and the printer's OpenSSL 1.0.2d.
  (A mod install leaves all of this alone. Its own Moonraker is extracted to
  `/usr/data/anvil/moonraker` on the DATA partition and started from there —
  see how-it-works — so the factory tree here, the interpreter and
  `moonrakerDaemon` all stay stock, and `moonrakerDaemon` is simply never
  invoked. Nothing the mod installs is written to the prog partition's
  `moonraker/`, which is what makes it a useful baseline: `case-install.sh`
  asserts this tree is untouched after an install.)
* **Not present at all**: stubs. Without a real prog partition the replica
  refuses to start rather than substitute one.
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
  hardware procedure in `docs/hardware-testing.md` is still how you find out
  whether it *prints*.
* `firmwareExe` is a 20MB Qt binary that wants a framebuffer. It is checked
  for presence, executability and ELF-ness, never run.
* Timing-dependent boot races are not modelled.
* Partition sizes are unbounded unless you set `PROG_MB` and `DATA_MB` (in `test.env`) from
  what `df -h` reports on the printer itself. Until then an install that
  runs the data partition out of space passes here and fails on the machine.
  The replica says so in `/usr/prog/.SIMULATED`.

## Running it

```sh
make rootfs          # once -- extracts rootfs.squashfs from the stock package
make qa-replica      # the replica suite: install, upgrade, boot, supervision
make test-py         # klipper config, and rootfs paths when one is present
```

`make qa-replica` does not skip when a stock package is missing: it fails at
the point that needs one, with the command that fixes it in the message. There
is no flag and nothing for a workflow to remember to set, which is why
`ALLOW_SKIP` is gone entirely. `REQUIRE_PRINTER_SIM` survives only for the two
single-purpose wrappers that can still skip — `make rootfs` and
`make boot-screen-sim`.
