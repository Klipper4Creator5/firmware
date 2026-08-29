# Off-the-shelf process supervision for the Creator 5 Pro

An investigation, not yet an adoption. It answers one question: instead of
`payload/anvil-service.sh` hand-rolling liveness checks, bounded stop waits and
respawn loops in `ash`, can we ship a supervisor that already solves those?

Everything below was measured on the printer replica (real `rootfs.squashfs`
under qemu-mipsel), not read off a project page. `build.sh` rebuilds both
stacks; `test/integration/printer/case-supervisor.sh` is the gate that proves
they work on the printer's own kernel.

## There is nothing on the printer to reuse

busybox 1.31.1 is PID 1. No systemd, runit, s6, supervisord, monit, procd or
daemontools exists anywhere on the rootfs. busybox init *does* implement
`respawn`, but only from `/etc/inittab`, and `/etc` is inside the read-only
squashfs a stock flash overwrites -- so the one supervisor already on the box
is unreachable to us. Anything we want, we cross-compile ourselves.

## Both stacks build and run

The Klipper `c_helper.so` step already unpacks an Ingenic MIPS toolchain, but
static glibc is the wrong libc here: s6 came to **73MB**. Built against musl
(`musl.cc` mipsel cross toolchain, `-Os`, static-PIE, stripped) the same tree
is **3.6MB**, and the supervision subset we would actually ship is:

| | binaries | size |
|---|---|---|
| s6 (subset: svscan, supervise, svc, svstat, svwait, svok, svlisten, ftrig-listen1, mkfifodir, cleanfifodir, notifyoncheck, svscanctl) | 13 | 813KB |
| s6 `libexec/s6-ftrigrd` | 1 | 116KB |
| runit (runsv, runsvdir, sv, svlogd, chpst) | 5 | 335KB |

execline was measured here at 53 binaries / 2.1MB and judged unnecessary --
s6 run
<!-- SUPERSEDED: that figure is an UNSTRIPPED STATIC MUSL build. Built the
way the tree builds now (Ingenic glibc, dynamic libc, cross-stripped) all 53
come to 1008KB, and s6-rc requires execline unconditionally -- it has no
--disable-execline and compiles execline scripts into every database. It is
pkg/execline now. -->
scripts can be plain `#!/bin/sh`.

## Two findings that cost real time

**Large-file support is mandatory.** Built without it, *both* supervisors die
identically the moment they scan their own service directory:

    s6-svscan: fatal: unable to readdir .: Value too large for defined data type
    runsvdir: warning: unable to read directory ...: unknown error

That is `readdir()` returning `EOVERFLOW` -- a 32-bit build meeting 64-bit
inodes. `-D_FILE_OFFSET_BITS=64` fixes both. Nothing about it is s6- or
runit-specific, and it would not have shown up in a build test, only in a run.

**s6 bakes its prefix in at compile time.** Its waiting verbs (`s6-svc -w`,
`s6-svwait`) exec `s6-svlisten`, which spawns `s6-ftrigrd` from the
`libexecdir` chosen by `./configure --prefix`. Ship s6 anywhere other than the
prefix it was built for and every waiting verb fails with

    s6-svlisten: fatal: unable to ftrigr_startf: No such file or directory

while `status` and respawn keep working -- so it fails *late* and *partially*.
runit has no such constraint; its tools find each other on `PATH`. This is why
`build.sh` configures `--prefix=/usr/data/anvil`: the mod's install root has to
be a real prefix root (`bin/`, `lib/`, `libexec/`, `etc/`, `share/`), which is
also what lets us drop a newer Python and Moonraker into the same tree later.

## What each one buys us

Both supervise correctly on the replica: `status` answers, a `kill -9` is
respawned, and -- the thing `svc_stop_daemon` hand-rolls -- a stop that does
not return until the process is really gone (`sv -w 20 stop`, `s6-svc -wD -d`).
Either would delete the two bugs fixed by hand in `anvil-service.sh`: busybox
`start-stop-daemon -K` returning early, and klippy's stale `/tmp/uds`.

The difference is **readiness**. s6 services can declare themselves ready over
a `notification-fd`, and `s6-svwait -U` blocks until they do -- measured at 5s
against a service that waits 5s before declaring itself. runit has no such
concept: `sv start` returns when the process has been forked, which says
nothing about whether it is usable.

That matters here because our boot order is currently expressed as filenames
(`S60nginx` before `S62moonraker` before `S65camera` before `S70klipper`) and
the waiting is hand-rolled: `S65camera` polls `/dev/video0` for up to 30s,
`S70klipper` retries an MCU handshake. Readiness notification is the piece that
would let those waits be declared instead of coded.

## What neither one replaces

`anvil-service.sh` is not only supervision. The prerequisite checks each init
script makes before it brings its service up, `anvil-env.sh`'s library path and
`FF_PYTHON`, `S70klipper`'s `force-start` handoff to `bin/ff-startup.py`, and
the MCU-retry that counts attempts and gives up all remain ours. A supervisor restarts blindly; it cannot tell "MCU
handshake failed" from "clean exit".

And `firmwareExe` runs `$MODDIR/init.d/S*` one at a time in the foreground, in
filename order. Handing everything to one `s6-svscan` discards that ordering,
which is load-bearing. Replacing it with readiness waits is the actual work in
adopting s6 -- not the supervisor itself.

## Reproducing

    docker build -f tools/supervisor/Dockerfile -t svcbuild-musl tools/supervisor
    docker run --rm -v "$PWD/tools/supervisor:/build/in" -v "$PWD/work/sup:/out" \
        svcbuild-musl sh /build/in/build.sh

then pack `bin/`, `libexec/` and `runit/` into a tarball and run the gate.

That is how the COMPARISON above was measured, and it is kept here for the
record. It is no longer how s6 is built: the answer is s6, so `bin/patch.sh`
now cross-compiles skalibs and s6 from the tarballs pinned in `versions.env`,
inside the repo's own build image, caches the result in `work/.s6` and stages
it into the payload. Nothing builds runit or execline any more, and
`case-supervisor.sh` accordingly expects only `bin/` and `libexec/` -- the
two directories that cache holds:

    tar -czf work/sup.tgz -C work/.s6 bin libexec
    PRINTER_IMAGE=monstrofil/creator5-printer:latest \
        ./test/integration/printer-exec.py \
        test/integration/printer/case-supervisor.sh sup.tgz=work/sup.tgz
