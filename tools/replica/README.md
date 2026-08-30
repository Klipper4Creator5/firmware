# The printer replica

A container that runs the printer's **own** userland: the real
`rootfs.squashfs` extracted from FlashForge's package, chrooted, with its
MIPS binaries executing under qemu. `uname -m` says mips and busybox applets
behave exactly as they do on the machine.

It lives under `tools/` rather than `test/` because it is not a test. Three
different things drive it, and only one of them is a suite:

| driver | what it does with it |
|---|---|
| `bin/payload.sh` -> `bin/build-payload.py` | **the build path.** The payload is assembled by running the PRINTER'S OWN `opkg` against `/`, inside here. Nothing on the host can do that |
| `qa/lib/replica.py` | the `replica` lane's `printer` fixture -- holds one container open and probes it |
| `make rootfs`, `make boot-screen-sim` | unpacking the real userland; rendering the boot frames on the cross-built CPython |

```
printer/                  the machine itself, SHELL on purpose: it is executed
                          by the printer's ash under qemu, and that it survives
                          that is a large part of what the suite proves
  Dockerfile              the container: qemu-user-static, rsync, openssl,
                          dosfstools. It contributes no userland worth speaking
                          of -- everything real comes from the chroot
  Dockerfile.full         the same, plus the firmware baked in: a prebuilt
                          PRINTER_IMAGE, so a run does not unpack 93MB
  binfmt.sh               registers a handler for the printer's binaries. The
                          stock qemu-mipsel registration does not match them:
                          its mask requires e_ident[EI_ABIVERSION] == 0 and
                          every binary the Ingenic toolchain built has 3 there
  assemble.sh             the mount layout -- read-only root, writable prog and
                          data partitions, optionally a real FAT USB stick
  seed-prog.sh            a /usr/prog that looks like a printer's
  entrypoint.sh           setup, then the case script it was given
  entrypoint-out.sh       the same, plus a writable /out inside the chroot
  bake.sh, bake-case.sh   install a package and commit the result as an image
ffsim/                    the host half. NOT a test framework -- it was one,
                          and 1,657 lines of it are gone; what is left starts
                          containers and reads config.env/test.env
build-printer-image.sh    bakes a prebuilt replica image (`make printer-image`)
extract-rootfs.py         `make rootfs`
sim-boot-screen.py        `make boot-screen-sim`
```

`--privileged` buys exactly two things: the binfmt registration, and the mount
layout. Nothing here needs it for any other reason.

See [docs/printer-replica.md](../../docs/printer-replica.md) for what the
replica can and cannot prove, and [docs/testing.md](../../docs/testing.md) for
the suites.
