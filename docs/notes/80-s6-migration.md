# Migrating to s6 and a real prefix root

The plan for turning `/usr/data/anvil` into a `--prefix` install root and
handing process supervision to s6. Written 2026-08-26, after the measurements
in `tools/supervisor/README.md`.

Each phase below is independently shippable and independently revertable, and
each names the gate that proves it. Do not start a phase whose predecessor's
gate is not passing.

## Why, in one paragraph

`payload/anvil-service.sh` hand-rolls in `ash` what a supervisor does in C:
liveness, a stop that waits, a respawn loop. Two real bugs lived in that code
before it was consolidated. s6 was measured against runit on the replica and
won on one thing that matters here -- readiness notification: a service can
declare itself ready and `s6-svwait -U` blocks until it does. Our boot order is
currently expressed as filenames and our waiting is hand-rolled (`S65camera`
polls `/dev/video0` for 30s; `S70klipper` retries an MCU handshake), so
readiness is the piece worth buying.

## The end state

`/usr/data/anvil` behaves like any `./configure --prefix` target:

    /usr/data/anvil/
        bin/        our scripts AND third-party binaries (s6, later python)
        lib/        libraries for the above
        libexec/    helper programs (s6-ftrigrd lives here)
        etc/        the mod's own configuration
            s6/     the s6 scandir: one directory per service
            klipper/  printer.cfg and friends (phase 4)
        share/
        www/, nginx/, helixscreen/, moonraker/   unchanged

The long-term goal is that **`firmwareExe` is the only file the mod places
outside `/usr/data`**. We are not there at the end of this plan -- phases 6 and
7 are what close it -- but every phase below moves toward it and none moves
away.

## Facts that constrain every phase

These were established by running things on the replica, not by reading code.
Get them wrong and the phase fails on a printer, not in CI.

* `firmwareExe` runs `$MODDIR/init.d/S*` **one at a time, in the foreground, in
  filename order**. Anything that blocks there blocks the whole boot. Filenames
  are load-bearing until readiness replaces them.
* Cross-compiled 32-bit MIPS binaries need `-D_FILE_OFFSET_BITS=64`. Without
  it `readdir()` returns `EOVERFLOW` on this box and a supervisor cannot see
  its own service directory. It starts fine and then does nothing.
* s6 resolves `s6-ftrigrd` through a prefix baked in at compile time. Built for
  the wrong prefix, `status` and respawn still work and every *waiting* verb
  fails. Always configure `--prefix=/usr/data/anvil` and stage with `DESTDIR`.
* Static glibc is the wrong libc here: s6 came to 73MB, musl to 3.6MB. Use the
  musl mipsel toolchain.
* We do **not** install Klipper. `bin/patch.sh` stages a *software component*
  and FlashForge's own stock `run.sh` copies it onto `/usr/prog/klipper`. That
  is why Klipper sits on the firmware partition -- inherited, not chosen.
* `payload/start.sh` already **is** `/usr/prog/klipper/start.sh`; the mod
  replaces it. What we do not own are the FlashForge pieces it calls:
  `klipperDaemon`, `klipper_pri.sh`, `checkEboard`, `libmcu-bare.bin`.
  `cmd_mcu` is at `/usr/bin/cmd_mcu`, on the rootfs, not `/usr/prog`.
* `klipperDaemon` is a shell script. Its entire payload is:

      start-stop-daemon -S -b -m -p $PID_FILE -N $KLIPPER_NICENESS \
          --exec /usr/prog/Python-3.8.2/bin/python3 -- \
          /usr/prog/klipper/klippy/klippy.py /usr/data/config/printer.cfg \
          -l /usr/data/logs/printer.log -a /tmp/uds

  Drop the `-b` and that is an s6 `run` script.
* Every path in `anvil-env.sh` -- interpreter, openssl, libffi, curl, ffmpeg,
  opencv -- is on `/usr/prog`. Klippy could move tomorrow and would still run
  under FlashForge's Python. That is the real blocker, and it is phase 6.

## Phase 1 -- the install manifest

**Do this first.** `payload/run-append.sh` currently does

    rm -rf $MODDIR/bin $MODDIR/www $MODDIR/nginx $MODDIR/helixscreen \
           $MODDIR/config $MODDIR/moonraker $MODDIR/init.d

before extracting. The moment s6 -- or later a Python -- lives in
`$MODDIR/bin`, that line destroys it on every update. Replace directory-wipes
with a manifest: ship the list of paths this payload installs, and on upgrade
delete what the *previous* manifest listed. Nothing else.

Keep the property the current code was written for: the installed set must end
up exactly the shipped set, so a renamed init script cannot leave a stale twin
behind (that is why `init.d` is in the list at all).

*Files:* `payload/run-append.sh`, `bin/patch.sh` (emit the manifest).
*Gate:* a replica case that installs the old layout, upgrades, and asserts (a)
a file the previous payload shipped and this one does not is gone, (b) a file
nothing shipped -- drop one in `bin/` by hand -- survives, (c) `anvil.conf` and
`config-installed` still survive as they do today.

## Phase 2 -- build s6 into the package

Pin `skalibs` and `s6` in `versions.env` with sha256s; fetch in
`bin/fetch-assets.sh`; build in the docker build image, cross-compiled for
mipsel-musl with `--prefix=/usr/data/anvil`, `make install DESTDIR=`, stripped.
This mirrors how `c_helper.so` is already built from pinned sources with a
pinned toolchain -- follow that precedent rather than inventing a second one.

Ship only the supervision subset (13 binaries, ~813KB) plus
`libexec/s6-ftrigrd` (~116KB). execline is **not** needed: `run` scripts are
plain `#!/bin/sh`.

*Files:* `versions.env`, `bin/fetch-assets.sh`, `bin/patch.sh`,
`tools/supervisor/`.
*Gate:* `test/integration/printer/case-supervisor.sh` (exists) run against the
binaries the real build produced, not a hand-made tarball.

## Phase 3 -- s6-svscan running, supervising nothing

One new init script starts `s6-svscan` on an empty scandir at
`$MODDIR/etc/s6/`. It must be backgrounded -- `firmwareExe` runs these in the
foreground and a scanner in the foreground never returns.

Decide and write down: **what restarts the scanner if it dies?** We are not
PID 1 and nothing supervises the supervisor. The cheap answer is a check in
`firmwareExe` on the next boot; the honest answer may be that a dead scanner is
a dead printer either way.

`anvil-service.sh` grows `svc_s6_*` helpers so the `S*` scripts can talk to the
scanner. It does not shrink yet.

*Files:* `payload/init.d/S40s6` (new), `payload/anvil-service.sh`,
`payload/firmwareExe`.
*Gate:* extend `case-services.sh`: the scanner is running after the init
sequence, and the init sequence still returns promptly.

## Phase 4 -- move nginx and camera

Not moonraker yet -- see phase 5. One service at a time. Each gets a service
directory under `etc/s6/` with a `run` script, and a `down` file when its
`MOD_*` gate says it is disabled.

**Keep the `S*` scripts.** `S60nginx restart` over ssh is in the docs and in
people's hands; the script becomes a thin wrapper over `s6-svc`. Changing the
supervisor is not a reason to change the interface.

Camera is the interesting one: its 30-second `/dev/video0` poll becomes a
readiness notification, so whatever waits for the camera waits for *ready*
rather than for *forked*.

*Gate:* `case-services.sh` and a camera case that proves readiness actually
gates -- not that the file exists.

## Phase 5 -- move the Klipper config, then moonraker

Klipper's live config is `/usr/data/config/`. Every `[include]` in it is
relative and the only absolute path anywhere is `/usr/data/gcodes`, so the
directory can move without rewriting a single user file. Move it to
`$MODDIR/etc/klipper/`.

The reason is not tidiness. FlashForge's stock `run.sh` does

    cp $WORK_DIR/klipper/config/* /usr/data/config/ -rf

on **every flash**, so today a stock firmware update overwrites our shipped
`.cfg` files in place. Moving out of `/usr/data/config` is how that stops --
the same class of fix as moving Moonraker off `/usr/prog`.

Requires: migrating existing printers' hand-edited files once (idempotently,
and never clobbering a file the user changed), repointing Moonraker (it is
invoked with `-d /usr/data`), and updating the `config-installed` three-way
diff in `run-append.sh`. The `/usr/prog/klipper/runConfig` pristine-template
lookup can stay -- it is read-only and only used on a fresh install.

Moonraker moves to s6 **after** the config move, so its `run` script is written
once against the final path.

*Gate:* a migration case -- install the old layout with a hand-edited
`printer.override.cfg`, upgrade, assert the edit survived at the new path and
that klippy still parses the tree. Plus `case-moonraker.sh` unchanged in intent.

## Phase 6 -- own the Python environment (separate project)

Build Python into the prefix and repoint `anvil-env.sh` at `$MODDIR/lib` and
`$MODDIR/bin/python3`. Everything the mod runs -- moonraker, `ff-startup.py`,
the MCU bring-up, and eventually klippy -- runs under it.

Worth scoping first: of the ten library paths in `anvil-env.sh`, find out which
are genuinely loaded at runtime and which are dead entries. That sizes the work
before it starts.

## Phase 7 -- own Klipper

Only reachable after phase 6. Ship the klippy tree into `$MODDIR` instead of
handing it to FlashForge's `run.sh`; replace `klipperDaemon` with an s6 `run`
script (the command line is quoted above); turn `S70klipper`'s retry loop into
an s6 restart policy plus readiness. `checkEboard`, `libmcu-bare.bin` and
`cmd_mcu` stay where they are -- they are version-matched to the firmware and
reading them from the firmware partition is correct.

At that point `firmwareExe` is the only file we place outside `/usr/data`.

## How this gets implemented

Phases 1, 2 and 3 are sequential and all touch `run-append.sh`, `patch.sh` and
`anvil-service.sh`. One worker, one phase at a time, gates run between them --
parallel agents there produce merge conflicts, not speed.

Phase 4 is a clean fan-out: one agent per service, each owning exactly one init
script, one service directory and one gate, each in its own worktree.

Phase 5 is one worker again: it touches user data and deserves undivided
attention.

Every agent follows the rule this project already has -- install the payload
and run the real tools in the replica, assert on behaviour, always with a
negative control. Never grep a shipped script to decide whether it works.
