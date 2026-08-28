# Migrating to s6 and a real prefix root

The plan for turning `/usr/data/anvil` into a `--prefix` install root and
handing process supervision to s6. Written 2026-08-26, after the measurements
in `tools/supervisor/README.md`.

Each phase below is independently shippable and independently revertable, and
each names the gate that proves it. Do not start a phase whose predecessor's
gate is not passing.

## Why, in one paragraph

`pkgs/anvil-core/payload/anvil-service.sh` hand-rolls in `ash` what a supervisor does in C:
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
* ~~Static glibc is the wrong libc here: s6 came to 73MB, musl to 3.6MB. Use
  the musl mipsel toolchain.~~ **Superseded.** That measurement is real and
  its conclusion no longer follows: it compared two STATIC builds, and dynamic
  glibc was never in it. Measured since, linked dynamically against the
  printer's own glibc 2.29 -- the same libc.so.6 the interpreter already
  links -- s6's shipped tree is 696KB, against ~930KB for the static musl one
  it replaces. The whole supervision stack including execline and s6-rc is
  2.0MB. The musl toolchain is gone and this tree has one libc again.
* We do **not** install Klipper. `bin/patch.sh` stages a *software component*
  and FlashForge's own stock `run.sh` copies it onto `/usr/prog/klipper`. That
  is why Klipper sits on the firmware partition -- inherited, not chosen.
* `pkgs/klipper/prog/start.sh` already **is** `/usr/prog/klipper/start.sh`; the mod
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

**Do this first.** `installer/run-append.sh` currently does

    rm -rf $MODDIR/bin $MODDIR/www $MODDIR/nginx $MODDIR/helixscreen \
           $MODDIR/config $MODDIR/moonraker $MODDIR/init.d

before extracting. The moment s6 -- or later a Python -- lives in
`$MODDIR/bin`, that line destroys it on every update. Replace directory-wipes
with a manifest: ship the list of paths this payload installs, and on upgrade
delete what the *previous* manifest listed. Nothing else.

Keep the property the current code was written for: the installed set must end
up exactly the shipped set, so a renamed init script cannot leave a stale twin
behind (that is why `init.d` is in the list at all).

*Files:* `installer/run-append.sh`, `bin/patch.sh` (emit the manifest).
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

Ship only the supervision subset plus `libexec/s6-ftrigrd`.

**Both halves of this have since changed.** The subset is 21 binaries, not 13:
s6-rc's generated scripts exec `s6-sudo`, `s6-sudoc`, the `s6-ipcserver-*`
chain, `s6-sudod` and `s6-fdholder-daemon`, which was found by running a real
s6-rc up/down cycle with a restricted PATH rather than by reading the docs. And
execline **is** needed -- s6-rc has no `--disable-execline`, links it
unconditionally, and writes execline scripts into every database it compiles.
`run` scripts are still plain `#!/bin/sh`; that was never the whole question.
All four are recipes under `pkgs/` now.

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

*Files:* `pkgs/anvil-core/payload/init.d/S40s6` (new), `pkgs/anvil-core/payload/anvil-service.sh`,
`pkgs/anvil-core/prog/firmwareExe`.
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

## Phase 5 -- moonraker

**The config move was planned for here and has moved to phase 7.** The reason
is a dependency this plan originally missed: `klipperDaemon` is FlashForge's
script, not ours, and it hardcodes

    KLIPPER_CONF=/usr/data/config/printer.cfg

so moving the directory while klippy is still launched through that script
produces a printer that cannot find its own config. Taking over the launch is
phase 7 work -- it also means owning what `S70klipper` and `bin/ff-startup.py`
call, since both drive `klipperDaemon` directly -- and pulling it forward to
satisfy a directory rename would make the riskiest phase bigger rather than
smaller. Moonraker is entangled too: it is invoked with `-d /usr/data`, so its
own config path moves with the same change.

So phase 5 is moonraker onto s6 and nothing else. The argument for moving the
config is unchanged and is restated in phase 7.

## Phase 7a -- move the Klipper config

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

*Gate:* a migration case -- install the old layout with a hand-edited
`printer.override.cfg`, upgrade, assert the edit survived at the new path and
that klippy still parses the tree.

Moonraker's `run` script is written in phase 5 against `/usr/data/config` and
is repointed here, in the same change that moves the directory. That costs one
edited line and is the price of not entangling a user-data migration with a
supervision change.

## Phase 5, continued -- moonraker onto s6

Same shape as nginx: a service directory whose `run` execs moonraker in the
foreground under `$FF_PYTHON`, `MOD_WEB` honoured through a shipped `down`
file, and `S62moonraker` kept as a thin wrapper so the verbs people use do not
change. Moonraker's own readiness -- it serves an HTTP API and klippy connects
to it over `/tmp/uds` -- makes it a genuine `notification-fd` candidate, which
matters because `bin/ff-startup.py` currently polls its API to learn
`klippy_state`.

*Gate:* `case-moonraker.sh`, extended rather than replaced -- it already proves
moonraker runs from `/usr/data` on the printer's own Python.

## Phase 6 -- own the Python environment (separate project)

**DONE, by 6b: CPython is built here.** `pkgs/3rdparty/python` cross-compiles 3.13.7
against the seven static libraries this feed already builds, and each of the
eighteen third-party packages is a `pkgs/3rdparty/python-*` recipe with its own version
and its own `.ipk`. `anvil-env.sh` points `FF_PYTHON` at it. What is written
below is the scoping that produced that decision, kept because the premises it
corrects are still the ones somebody would reach for -- in particular why musl
was never an option here, which is the paragraph that decided phase 7 too.

Scoped, in the replica, before starting. The scoping changed the shape of this
phase and corrected a premise, so read this before writing any of it.

**THE PREMISE THAT DID NOT SURVIVE.** "Owning Python makes the mod survive a
stock flash" is false, and so is that framing for phases 6 and 7 generally.
`firmwareExe` lives on `/usr/prog`, a stock flash overwrites it with
FlashForge's binary, and after that nothing runs `$MODDIR/init.d/S*` at all --
the mod is already dead whatever else survived. The flash also restores a
working `/usr/prog/Python-3.8.2` at the same path, so today's arrangement
recovers the moment the mod package is reinstalled. Do not justify this phase
that way.

**What it actually buys**, in order of value:

1. It unfreezes Moonraker. The pin is stuck at commit 9d0d09d (Dec 2023) for
   exactly one reason: FlashForge's Python has no `_sqlite3` and there is no
   `libsqlite3` anywhere on the box, while Moonraker v0.9.0 moved its database
   off lmdb onto sqlite. That is a compounding cost paid every release.
2. It removes two FlashForge version strings -- `Python-3.8.2` and
   `openssl-1.0.2d` -- hardcoded into `anvil-env.sh`. FlashForge demonstrably
   bumps these (they already ship `opencv-4.10` beside `opencv-4.2`), and an
   OTA that does breaks every modded printer that takes it before our next
   release.
3. Modern OpenSSL. Marginal for what Moonraker actually does.

**What is measured, and what it rules out.** Only four of the ten `ANVIL_LIBS`
are ever mapped: Python, openssl, libffi, libsodium. The other six have one
consumer between them -- FlashForge's `firmwareExe`, which we replace. There is
NO usable prebuilt Python for this target: python-build-standalone has no mips
at all, and OpenWrt's `mipsel_24kc` build is `e_flags=0x74001005`, legacy-NaN
soft-float musl, wrong three ways. The target ABI is NAN2008, O32, hard-float,
glibc 2.33. And a musl-built CPython is **fatal for phase 7**: it cannot
`dlopen` a glibc `c_helper.so`, which is exactly how klippy loads it. If
CPython is ever built here it must use the Ingenic glibc toolchain that already
builds `c_helper.so`.

**The option this plan originally missed, and the one to do first.**

* **6a -- relocate, do not build.** Copy FlashForge's own interpreter and the
  three native libraries into the prefix at INSTALL time, repoint
  `anvil-env.sh`, and leave `/usr/prog` unreferenced. Measured end to end in
  the replica: all 16 Moonraker components import, klippy's `chelper.get_ffi()`
  works, Moonraker answers `/server/info`, and its `/proc/PID/maps` holds no
  `/usr/prog` library. Buys benefit 2 in full, costs no cross-compiling.
  ~2-3 days, nearly all of it install/upgrade code and gates. Copying on the
  printer rather than shipping FlashForge's binaries also avoids
  redistributing them. Hard dependency on phase 1's manifest: ~3000 files of
  Python in `$MODDIR` is not survivable under a directory wipe.
* **6b -- `_sqlite3` alone, when a newer Moonraker is wanted.** One extension
  module plus a static sqlite amalgamation, built against 3.8.2's headers with
  the Ingenic toolchain, dropped into the relocated `lib-dynload/`. That is the
  narrow route to benefit 1 -- one `.so`, not an interpreter. ~1-2 days.
* **6c -- cross-build CPython 3.13.** Only if 6b fails or something demands
  >3.8. Ingenic glibc toolchain, never musl. 1-3 weeks, most of it fighting the
  build: the interpreter is the easy half, the seven hand-cross-built C
  extensions and the missing distutils are the hard half.

**BLOCKING UNKNOWN: free space on `/usr/data`.** A trimmed relocation is
73-112MB and ~3084 files. `DATA_MB` is unset in `test.env.example`, the
replica's partitions are unbounded overlays, and no document in this repo
records `df` from a real printer. Measure that before 6a, not during it.

**Do the gate first, not the installer.** A `case-python.sh` that relocates,
moves `/usr/prog/Python-3.8.2` aside, and then asserts the four things above,
with the pre-relocation run as its negative control. It makes every later step
falsifiable and it is a few hours' work.

One trap already found: dropping `setuptools`/`pkg_resources` while trimming
breaks the `lmdb` egg, which then falls back to lmdb's cffi path and tries to
invoke `mips-linux-gnu-gcc` ON THE PRINTER at Moonraker startup. A trim gate
has to catch that class of failure.

## Phase 7 -- own Klipper

**Now reachable: phase 6 is done.** The interpreter it needs is `pkgs/3rdparty/python`,
built with the Ingenic glibc toolchain -- the requirement the paragraph above
calls fatal if got wrong, since klippy `dlopen`s a glibc `c_helper.so`.

Ship the klippy tree into `$MODDIR` instead of
handing it to FlashForge's `run.sh`; replace `klipperDaemon` with an s6 `run`
script (the command line is quoted above); turn `S70klipper`'s retry loop into
an s6 restart policy plus readiness. `checkEboard`, `libmcu-bare.bin` and
`cmd_mcu` stay where they are -- they are version-matched to the firmware and
reading them from the firmware partition is correct.

At that point `firmwareExe` is the only file we place outside `/usr/data` --
which is the goal, but be clear about what it is worth. It does NOT make the
mod survive a stock flash: the flash replaces `firmwareExe` itself, and with it
the only thing that runs any of this. What owning everything else buys is a
mod that depends on no FlashForge version string, so a stock OTA cannot break a
modded printer between our releases, and a single place to look when something
does not start. That is worth having. "Survives a flash" is not the reason.

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
