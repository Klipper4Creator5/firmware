# Migrating to s6 and a real prefix root

The plan for turning `/usr/data/anvil` into a `--prefix` install root and
handing process supervision to s6. Written 2026-08-26, after the measurements
in `tools/supervisor/README.md`.

Each phase below is independently shippable and independently revertable, and
each names the gate that proves it. Do not start a phase whose predecessor's
gate is not passing.

**Where this ended up.** The plan is kept as written. Two things about it have
since gone the other way, so read the phases as a record rather than as a
description of the tree: `anvil.conf` and every `MOD_*` switch in it were
removed outright — a component runs because it is installed, and the settings
worth keeping are stated in the service that uses them — so the phases below
that read `anvil.conf` at runtime describe an intermediate state that no longer
exists. The gates named as `test/integration/printer/case-*.sh` are modules
under `qa/replica/` now.

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
  **Superseded by phase 7:** `anvil-klipper` installs the tree at
  `$MODDIR/klipper` and the `klipper` service runs it from there.
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

> **REVERSED IN PHASE 8, deliberately.** The rule was right while a wrapper
> still did something -- prerequisites, the `MOD_*` gate, a liveness check.
> Once every one of those moved into the `run` script (where it has to live
> anyway, because s6 restarts a service without going near a shell script),
> the wrapper was verb translation and nothing else, in a directory whose
> `S<NN>` numbering encoded an ordering that no longer existed. `init.d/` is
> deleted and `s6-rc` is the interface. The cost is real and is paid once:
> `S60nginx restart` is gone from people's hands and from the docs.

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
foreground under `$FF_PYTHON`, a shipped `down` file so the scanner does not
start it before its prerequisites exist, and `S62moonraker` kept as a thin
wrapper so the verbs people use do not change. (Written when `MOD_WEB` still
existed, which is what the `down` file was argued from at the time; the flag is
gone and the `down` file is not — ordering was always the real reason.) Moonraker's own readiness -- it serves an HTTP API and klippy connects
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

**DONE.** The interpreter it needed is `pkgs/3rdparty/python`, built with the
Ingenic glibc toolchain -- the requirement the paragraph above calls fatal if
got wrong, since klippy `dlopen`s a glibc `c_helper.so`.

It landed in two halves and the gap between them is the part worth recording.
The `klipperDaemon` replacement, the s6 `run` script and the move onto
`$FF_PYTHON` went in together; the klippy TREE stayed at
`/usr/prog/klipper/klippy` for a while afterwards, staged there by
`bin/patch.sh` out of the very `anvil-klipper` package that also installed it
under `$MODDIR`. So the printer ran our Klipper, on our Python, out of a copy
on the firmware partition that a stock flash could overwrite -- and because
nothing declared it, `anvil-klipper` carried no dependency on the interpreter
it had already moved to. `KLIPPY=$MODDIR/klipper/klippy/klippy.py` closed
both: it deleted sections 1 and 2 of `bin/patch.sh` (~85 lines, the software
component's whole `klipper/` directory and the `chelper.tar` that fed stock
`run.sh`) and let `pkgs/klipper` declare `anvil-python`, `-cffi`, `-greenlet`,
`-pyserial` and `-jinja2` for real. Until then `cffi` and `greenlet` reached
the printer only via a hardcoded list in `patch.sh`, and `pyserial` and
`jinja2` only as `anvil-moonraker`'s Depends -- so a `BUILD_MOONRAKER=0` build
shipped a klippy that dies the first time it opens an MCU.

**The lesson, stated once:** moving what a program RUNS ON without moving what
it RUNS leaves the dependency graph lying, and nothing fails until a
configuration nobody builds gets built.

Still open: `S70klipper`'s retry loop is not yet an s6 restart policy plus
readiness. `checkEboard`, `libmcu-bare.bin` and
`cmd_mcu` stay where they are -- they are version-matched to the firmware and
reading them from the firmware partition is correct.

At that point `firmwareExe` is the only file we place outside `/usr/data` --
which is the goal, but be clear about what it is worth. It does NOT make the
mod survive a stock flash: the flash replaces `firmwareExe` itself, and with it
the only thing that runs any of this. What owning everything else buys is a
mod that depends on no FlashForge version string, so a stock OTA cannot break a
modded printer between our releases, and a single place to look when something
does not start. That is worth having. "Survives a flash" is not the reason.

## Phase 8 -- hand the boot to s6-rc

**Numbered last because it was written last, not because it must run last.**
Its hard predecessors are phases 1, 3, 4 and 5: it needs the manifest (shipped
-- `payload/run-append.sh` is on the manifest path today), a scanner (shipped
-- `payload/init.d/S40s6`), and the three services already living in the
scandir. It needs nothing from phase 6 and nothing from phase 7, and phase 7
does not need it. It can go before either, after either, or between them.
**Klipper came in after all, and phase 7 did not get bigger.** The plan said
Klipper was explicitly out of this phase. It is in it: an ordinary longrun
whose `run` script is `klipperDaemon`'s command line with the `-b` removed,
exactly as the fact list above predicted it would be. What phase 7 was actually
about -- shipping the klippy tree into `$MODDIR`, owning the Python, moving
`/usr/data/config` -- is untouched and still ahead. Supervising a program is
not the same as owning where it lives, and conflating the two is what kept
Klipper out of a phase it belonged in.

**What it is for.** `firmwareExe` runs seven `init.d/S*` scripts one at a time
in the foreground and that loop IS the boot order (`payload/firmwareExe` lines
63-69). Three of those seven are already thin -- `S60nginx`, `S62moonraker` and
`S65camera` are `svc_s6_*` wrappers over a supervisor that is already running.
What is left in the loop is not supervision, it is *sequencing*, and it is
sequencing expressed as filenames. This phase moves the sequencing into a
compiled s6-rc database, so that `firmwareExe` asks for a machine STATE
(`s6-rc -u change ok-all`) instead of running seven programs and hoping.

### The graph, and what its edges do NOT promise

**There is a real dependency graph now, and it is small.** Written out, with
the reason for every edge that exists and every one that does not:

    mcu-bringup  oneshot   no dependencies
    klipper      longrun   dependencies.d/mcu-bringup
    wifi         oneshot   no dependencies
    nginx        longrun   no dependencies
    moonraker    longrun   no dependencies
    camera       longrun   no dependencies
    ff-startup   oneshot   dependencies.d/{klipper,moonraker}
    ui           longrun   dependencies.d/ff-startup
    ok-all       bundle    contents.d/{wifi,nginx,moonraker,camera,klipper,
                                       ff-startup,ui}

`mcu-bringup` is not in the bundle: it is pulled in as klipper's dependency,
which is the point of having one.

**The three edges are ORDERING, and only one of them is also readiness.** This
distinction is the whole honesty of the section and it is easy to lose:

* `s6-rc` counts a **longrun** up as soon as it is forked, *unless* its
  servicedir carries a `notification-fd`, in which case it waits for the
  service to say it is ready.
* `moonraker` and `camera` have one. Their readiness is real: `moonraker` is
  counted up when it has BOUND :7125, the camera when the streamer has bound
  :8080 with a device behind it.
* `klipper` does **not**. klippy's "ready" is a state on Moonraker's API --
  there is no "Printer is ready" line even in `printer.log`, which is why
  `S70klipper` used to tail for `Stats <n>:` -- so `ff-startup` depending on
  `klipper` means "after klippy was LAUNCHED", not "after klippy is usable".
  `bin/ff-startup.py` therefore keeps its own poll of `klippy_state` and its
  own retry loop. Giving klipper a real `notification-fd` means teaching
  klippy to write to one, and that is a separate change; it is not attempted
  here and it must not be claimed.

So `ui` depending on `ff-startup` genuinely does mean "the screen appears when
the printer is ready", because `ff-startup` is a oneshot and a oneshot is not
done until its `up` has returned -- and its `up` is the program that waits.
That is the edge the phase was worth doing for.

**nginx before moonraker is still NOT an edge, for the reason it never was.**
`S60nginx`'s header argues that nginx should start first because it proxies
both moonraker and the camera, and a browser then gets a page saying the
backend is not answering rather than a refused connection. That is a
PREFERENCE, not a dependency, and encoding it as one has a price: a
`dependencies.d/nginx` under moonraker means `s6-rc -d change nginx` also stops
moonraker, so `S60nginx stop` would take the API down with the UI -- the exact
thing splitting `S60web` into two scripts was done to prevent. So the edge is
not written, s6-rc brings those two up in parallel, and the cost is a second or
two in which a reloading browser gets a refused connection instead of a 502.

**What the edges cost, said plainly.** `s6-rc -d change moonraker` now also
stops `ff-startup` and therefore the UI, because both depend on it. That is
correct -- there is nothing for a printer UI to show when there is no printer
-- but it is a behaviour change from the days when each `S*` script stopped one
thing, and both `S62moonraker` and `S70klipper` say so in their `stop()`.

**And a boot that waits.** The transition is what `firmwareExe` blocks on, so
readiness that used to be reported by a detached background job is now
something the boot pays for: moonraker's up to `timeout-up` = 120s, the
camera's 40s on a printer that has no camera, `ff-startup`'s up to 300s. Every
one of those services has a `timeout-up`, and that is not tidiness -- without
one, a camera that never appears would hold the transition open for ever and
the UI would never start.

### Does s6-rc need execline? Yes, and here is the bill

Phase 2 says "execline is **not** needed: `run` scripts are plain `#!/bin/sh`".
That survives for longruns and fails for everything else, and both halves were
read out of the s6-rc 0.7.0.0 source rather than assumed.

* **Longruns keep plain `#!/bin/sh`.** `s6-rc-compile` only wraps a `run`
  script in an execlineb wrapper when the service is *pipelined*
  (`src/s6-rc/s6-rc-compile.c` lines 1375-1379, guarded on `ispipelined`).
  Pipelines are s6-rc's logger mechanism and we ship no loggers, so our three
  existing `run` scripts are copied verbatim. Nothing about phase 4 or 5 has to
  be rewritten.
* **execline is a build-time AND run-time requirement anyway.** skarnet says so
  outright on <https://skarnet.org/software/s6-rc/>, `package/deps-build` lists
  `execline 2.9.9.2`, and `s6-rc-compile` links `-lexecline`
  (`package/deps.mak` line 136). The runtime half is concrete rather than
  theoretical: `write_oneshot_runner` is called unconditionally
  (`s6-rc-compile.c` line 1592) and emits a servicedir whose `run` begins
  `#!<execlinebprefix>execlineb -s1` and then execs `fdmove`,
  `s6-ipcserver-socketbinder`, `s6-ipcserverd`, `s6-ipcserver-access`,
  `s6-sudod` and `libexec/s6-rc-oneshot-run` (lines 1083-1092). Every oneshot's
  `up` runs through that service. We are adding a oneshot, so we are adding
  execline.
* **The oneshot `up` file itself does not have to be execline.** It is lexed by
  execlineb at compile time and stored as an argv, and skarnet documents
  `/bin/sh -c "script"` and "just call a script stored somewhere else" as
  supported shapes. Every `up` we write will be the latter, so no execline
  command beyond `execlineb` and `fdmove` is ever exec'd.

The bill, against the ~813KB + 116KB s6 already costs: two more pinned tarballs
with sha256s (`execline`, `s6-rc`), two more cross-builds in `bin/patch.sh`
section 5b -- the same toolchain, the same wrapper discipline, the same cache
stamp -- and more entries in the ABI gate, whose expected-count assertion
(`bin/patch.sh`, the `S6_ELF` check) has to move with them.

**The binary set was MEASURED, and it is bigger than reading the oneshot
runner alone suggests.** The estimate above -- four new s6 names and two
execline binaries -- was made from `write_oneshot_runner`. `s6-rc-compile` also
emits an `s6rc-fdholder` servicedir, and that one execs `pipeline`, `if`,
`forstdin`, `exit`, `redirfd`, `s6-ipcclient`, `s6-fdholder-daemon`, `s6-svc`
and `libexec/s6-rc-fdholder-filler`. Read off the generated `servicedirs/*/run`
of a real compile, the additions are **seven** execline binaries (`execlineb`,
`fdmove`, `pipeline`, `if`, `forstdin`, `exit`, `redirfd`), six s6 binaries we
build but do not ship today (`s6-ipcserver-socketbinder`, `s6-ipcserverd`,
`s6-ipcserver-access`, `s6-sudod`, `s6-fdholder-daemon`, `s6-ipcclient`),
`s6-rc`, `s6-rc-init` and `s6-rc-db`, and two `libexec` helpers
(`s6-rc-oneshot-run`, `s6-rc-fdholder-filler`). Stripped, for this target:

    today, the s6 subset + s6-ftrigrd     1434 KB
    added by s6-rc                        1309 KB

So s6-rc roughly DOUBLES what supervision costs on the data partition, and it
does so to buy a boot order that is three real edges wide (see the section
above) and was previously spelled as filenames. That is the honest trade and it should be read next to the
free-space unknown phase 6 records: nobody has ever run `df` on a real printer.
`s6-rc-compile` (131KB) is host-side only and is not shipped. [Superseded: it
ships. `pkgs/3rdparty/s6-rc/build.sh` keeps it deliberately -- it is the only
way to fix a printer whose database is wrong without a laptop.]

**Both new packages must be configured `--prefix=/usr/data/anvil`, for a reason
one level worse than the `s6-ftrigrd` trap.** execline's `--shebangdir`
defaults to `$bindir` and is baked into `EXECLINE_SHEBANGPREFIX`
(`execline-2.9.9.2/configure` lines 152, 587); `s6-rc-compile` pastes that
string into the `#!` line of the oneshot runner it generates. So the prefix
that ends up INSIDE the shipped database is a property of the execline that the
*compiler* was linked against, not of the execline we ship. Get it wrong and
every oneshot fails at exec with ENOENT while every longrun keeps working --
late and partial, exactly as `tools/supervisor/README.md` describes for the
waiting verbs.

### Where the database lives, and when it is compiled

**Compiled on the build host, in `bin/patch.sh`, and shipped.** The database
files are architecture-neutral by construction: `s6-rc-compile` writes every
integer with `uint32_pack_big` (`s6-rc-compile.c` lines 1037-1042, 1199, 1214,
1482) and the runtime reads them back with `uint32_unpack_big`
(`src/libs6rc/s6rc_db_read_uint32.c` line 12), so nothing native-word-sized or
host-endian reaches the file; `resolve.cdb` is djb's fixed cdb format. What is
NOT neutral is the `servicedirs/` subdirectory, because of the shebang above --
which is a configure problem, not a portability problem, and is solved by
building s6-rc twice from one tarball: once for the host to get a
`s6-rc-compile` configured with the printer's prefixes, once for mipsel to get
`s6-rc`, `s6-rc-init`, `s6-rc-db` and `libexec/s6-rc-oneshot-run`. That is the
shape section 5c already uses for CPython, where a throwaway x86-64 3.13.7 is
built from the same tarball as the shipped mipsel one.

Compiling on the printer at install time was the alternative and is rejected:
it means shipping `s6-rc-compile` plus the execline lexer plus the whole source
tree, and it adds a way for `run-append.sh` to fail that ends in a printer with
no services and a log nobody will read. The database is a build artefact. Build
artefacts are built where the build is.

**Paths.** The compiled database ships at
`$MODDIR/etc/s6-rc/compiled/<version>` with
`$MODDIR/etc/s6-rc/compiled/current` a symlink to it -- skarnet's own advice on
the `s6-rc-init` page, so the boot command never has to change when the
database does. It is under `$MODDIR/etc/`, not `/etc/s6-rc/`, which is
`s6-rc-init`'s default and is unreachable: `/etc` is inside the read-only
squashfs (`docs/printer-replica.md`, the mount table). Configure with
`--bootdb=/usr/data/anvil/etc/s6-rc/compiled/current` so a hand-run
`s6-rc-init` over ssh is right too, and pass `-c` explicitly anyway.

**The live directory is `/run/s6-rc`**, which is s6-rc's own default.
`s6-rc-init` needs it writable and skarnet recommends a RAM filesystem; `/run`
is tmpfs on this machine (`docs/printer-replica.md`, mount table, copied from
`/etc/fstab` and `/etc/init.d/S21mount_mmc_ext4`). That gives the reboot answer
for free: tmpfs comes up empty, so `s6-rc-init`'s requirement that the live
directory "should not exist prior" holds by construction on every boot, and
nothing has to clean up after a crash. Across an UPGRADE the live directory
survives, still pointing at a compiled database the manifest pass is about to
delete -- see below.

### What starts the tree, and what happens when it dies

**This is where the plan changed, and it changed for the better.** Phase 3 said
nothing supervises the supervisor, that a respawn loop in `ash` would hide a
real fault, and that the honest fix would be inittab-style respawn. There is
one, and it was already on the printer.

`firmwareExe` starts `s6-svscan` AS ITS OWN CHILD, runs `s6-rc-init`, issues
one `s6-rc -u change` for the boot set, and then blocks in `wait
"$SCANNER_PID"`. That `wait` is what holds the foreground for the stock
`app_startup.sh` watchdog, which greps `ps` for the name `firmwareExe` five
seconds after launch -- the job the old `while true; do sleep 3600; done` tail
did, now done by waiting on something real.

When the scanner dies, `wait` returns, `firmwareExe` exits, and
`app_startup.sh` -- FlashForge's own stock init, which the mod never patches --
re-execs it. The whole tree comes back. That is not a hand-rolled supervisor:
there is no loop, nothing is retried in place, and nothing is hidden.

Three details are load-bearing:

* **The scanner must be `firmwareExe`'s own child.** `wait` only works on a
  process the calling shell forked. Backgrounding it inside `S40s6 start`, as
  phase 3 did, puts it in a subshell of another program. `S40s6` keeps its own
  copy of the sequence for the ssh path, and every step of it is a no-op when
  the step has already happened.
* **Not `exec s6-svscan`.** The watchdog greps for the name; `exec` would make
  `$0` `s6-svscan`, and busybox `ash` has no `exec -a`. The shell also has to
  run `s6-rc-init` *after* the scanner is up, which an `exec` forecloses.
* **`wait "$SCANNER_PID"`, not bare `wait`.** Services and `ff-startup` leave
  background children around; a bare `wait` would return on the wrong one.

What it does NOT buy: it is one restart of EVERYTHING, not a targeted restart
of the scanner. klippy goes down with it, mid-print. A printer whose scanner
dies twice has a real fault -- realistically the `-D_FILE_OFFSET_BITS=64` build
trap -- and the second time round this looks like a boot loop, which is what a
boot loop is for.

### `init.d/` is deleted

Phase 4 promised the `S*` scripts would survive as thin wrappers. They did not,
and the reason is worth stating because it is the same argument the `run`
scripts already make: a service that only works when a shell script happened to
run first is not supervised, it is lucky. Every prerequisite a wrapper did --
the `mkdir`, the leftover sweep, the binary check -- has to be in the `run`
script anyway, because s6 restarts a service without going near a shell. Once
they moved, the wrappers were verb translation in a directory whose `S<NN>`
numbering encoded an ordering that no longer existed.

So `s6-rc` is the interface. `s6-rc -u change nginx`, `s6-rc -d change nginx`,
`s6-svc -r $SCANDIR/nginx`, `s6-svstat $SCANDIR/nginx`. `S60nginx restart` is
gone from people's hands and from `docs/`.

* **`payload/anvil-service.sh` is deleted too.** With the wrappers gone its
  only caller was `firmwareExe`, and a shared library for one consumer is the
  redundancy the wrappers were. What `firmwareExe` uses is inlined there: the
  paths, the `PATH` prepend, the scanner fork, `s6-rc-init`, the boot set.
* **The tree-starter exists once**, in `firmwareExe`. There is no `S40s6` and
  no replacement helper. The ssh recovery path is plain `s6-rc` commands.
* **`bin/ff-startup.py` is two services**, `mcu-bringup` and `ff-startup`. A
  compiled database cannot read `anvil.conf`, so `MOD_STARTUP`, `MOD_IMPORT`,
  `MOD_STARTUP_TIMEOUT` and `MOD_KLIPPER_TRIES` become argv inside the two
  `up` files, which source `anvil.conf` at runtime.
* **wifi is a oneshot**, not a "do the work then sleep forever" longrun -- s6
  would respawn a longrun that had finished. Its `up` returns when the
  supplicant is launched, not when there is an address, which is safe only
  because NOTHING DEPENDS ON WIFI. A oneshot that returns early lies to its
  dependents.
* **klipper loses its retry loop and `force-start`** -- `ff-startup` owns the
  retry, with moonraker to ask instead of `printer.log` to tail, and nothing
  stands aside from anything any more. It restarts with `s6-svc -wr -t` rather
  than two s6-rc transitions, because `ff-startup` calls it from inside one and
  `s6-rc` takes an exclusive lock on the live directory.
* **`klipperDaemon` is replaced with a no-op `start`.** It is FlashForge's
  script and off-repo callers remain -- stock `start.sh`, the UI's restart
  path, habits over ssh -- and every one of them would fork a second,
  unsupervised klippy beside the supervised one. `stop`, `restart` and `status`
  redirect at the service rather than reimplementing pidfile semantics nothing
  writes any more.
* **The UI is a supervised longrun.** The plan said it could not be: the UI had
  to hold `firmwareExe`'s foreground for the watchdog. `firmwareExe` holds its
  own foreground on `wait` now, so the foreground is not available to lend and
  `$MODDIR/.ui-choice` is deleted rather than left unread.

**BLOCKING UNKNOWN: does `helix-screen` run under `s6-supervise`?** Nothing has
proved it. A supervised process gets the descriptors `s6-supervise` hands it,
no controlling terminal, and a session it did not create; until now the UI
inherited `firmwareExe`'s. The environment half is easy and is in
`etc/s6-rc/source/ui/run` -- `HELIX_DATA_DIR`, `HELIX_LOG_DEST`,
`HELIX_LOG_FILE`, `HELIX_DISABLE_AUTO_UPDATES`, exactly what `firmwareExe`
exported. A tty is not something a `run` script can conjure. This has to be
settled on the replica before the change ships; if it turns out a terminal is
needed, the answer is s6's own tty handling or a small wrapper, NOT a return to
the foreground, which no longer exists.

`firmwareExe`'s loop over `$MODDIR/init.d/S*` is gone and nothing replaces it:
the body is the scanner, `s6-rc-init`, one `s6-rc -u change`, and `wait`.

### The `MOD_WEB` / `MOD_CAM` gate survives, and gets better

**The three `down` files are deleted, and the reason is not the one the manual
gives.** MEASURED: `s6-rc-compile` does not refuse a `down` file in a definition
directory -- it ACCEPTS it and SILENTLY DROPS it, producing a byte-identical
servicedir. So "not started by default" in s6-rc is not a file at all; it is
membership of the `ok-all` bundle. The mechanism whose long argument was
written inside `payload/etc/s6/nginx/down` stops existing either way.

What replaces it is strictly better, and it is worth being explicit because the
`down` file's own text spends thirty lines on this exact point: the gate has to
be a RUNTIME read of `anvil.conf`, because the payload is built once and
`anvil.conf` is edited over ssh. Under s6-rc the gate is the ARGUMENT LIST of
`s6-rc -u change` -- `svc_rc_enabled` in `anvil-service.sh` reads the switches
at runtime, `svc_rc_boot_set` expands the `ok-all` bundle with `s6-rc-db
contents` and drops what is switched off, and both `firmwareExe` and each
`S*` script's `start()` ask the same function, so they cannot disagree. `MOD_CAM=0` means camera is never named, so it never starts;
`MOD_WEB=0` means neither nginx nor moonraker is named. A printer upgrading
with `MOD_CAM=0` already set needs no action at all and behaves identically.
That is the whole upgrade path for the flags, and it is why they are kept
rather than dropped.

The one thing genuinely lost is the corner case the `down` file's own "THE
COST" paragraph describes -- and it is lost by being FIXED. There, a killed
`s6-supervise` was replaced by a fresh one that re-read `down` and left the
service stopped; under s6-rc the live servicedir's `down` file is managed
against s6-rc's current state, so the replacement supervisor reads what the
machine is supposed to be doing. The reasoning in the deleted file does not
disappear: it moves to `svc_rc_enabled` and `svc_rc_boot_set` in
`anvil-service.sh`, which is where the decision now lives.

### Upgrade

Phase 1 is already shipped, which is what makes this section short. The
compiled database, the source definitions and everything else are staged under
`$MOD_PAYLOAD` and therefore named in `.install-manifest` (`bin/patch.sh`
section 10b), so `run-append.sh`'s manifest pass deletes the previous
database and extracts the new one with no new code. **`s6-rc-update` is
deliberately not used**: it exists to swap a compiled database under a live
machine, and a flash ends in a reboot. Reaching for it would mean the installer
mutating a running supervision tree on a machine that is about to restart
anyway.

Two things do need writing.

* **The scandir MUST be swept, and the manifest cannot do it.** MEASURED:
  `s6-rc-init` creates one symlink per service in the scandir and fails
  outright -- `unable to supervise service directories ...: File exists` -- if
  a name is taken. A printer upgrading from the pre-s6-rc payload has `nginx`,
  `moonraker` and `camera` sitting there as real directories. The manifest pass
  deletes every FILE it listed and then `rmdir`s the directories, but
  `s6-supervise` created `supervise/` and `event/` inside each of them at
  RUNTIME, and no manifest can list a file the previous install did not write
  -- so the `rmdir` correctly refuses and leaves exactly the name `s6-rc-init`
  collides with. `run-append.sh` therefore does `rm -rf $MODDIR/etc/s6` and
  recreates it, after extraction, plus `rm -rf /run/s6-rc` for the person who
  runs `sh run.sh` over ssh instead of rebooting.
* **The legacy sweeps stay.** `S62moonraker`'s `/run/moonraker.pid` cleanup
  (lines 369-388) and `S65camera`'s `LEGACY_PIDFILE` block (lines 225-238) are
  the same class of problem one release further on, and this phase adds a third
  instance of it: a printer that boots the new payload while an old
  `s6-supervise` from the pre-s6-rc scandir is still alive has two supervisors
  fighting for `:80`. The reboot settles it; the ssh path has to sweep it.

### SETTLED: both of this phase's blocking unknowns were measured

Run on 2026-08-28, in the replica, against the real cross-built stack --
skalibs 2.15.1.0, execline 2.9.9.2, s6 2.15.1.0 and s6-rc 0.7.0.0, all four
built twice from ONE set of tarballs (the skalibs and s6 sha256s are the ones
already pinned in `versions.env`): natively, to get an `s6-rc-compile` that
runs on the build host, and for `mipsel-buildroot-linux-musl` with the Bootlin
toolchain `versions.env` pins, both configured `--prefix=/usr/data/anvil`.

**A host-compiled database IS accepted, byte for byte.** The same two-service
source tree -- one oneshot, one longrun, the shapes `S50wifi` and `S60nginx`
become -- was compiled by the host `s6-rc-compile` and by the target one under
qemu. `db`, `n` and `resolve.cdb` are identical (`db` md5
`80f5261437191fa591744ada6087c6f7` both ways) and `diff -r` reports the
generated `servicedirs/` trees identical too. The endianness argument holds.
Then the HOST-compiled database was run: `s6-rc-init` returned 0, `s6-rc -u
change ok-all` returned 0 with no warnings, the longrun came up with a
`supervise/` directory, and the oneshot's `up` actually executed -- its stamp
file was written -- which is the half that goes through execline. `s6-svscan`'s
log stayed empty. **Nothing about the database needs to be compiled on the
printer, and `s6-rc-update` is not needed to make one usable.**

**`/run` is a tmpfs and is writable.** `rw,seclabel,relatime,inode64`, no
`noexec`, and a write to it succeeded. Use `/run/s6-rc` as the live directory
as designed; the `/tmp/s6-rc` fallback is not needed. Note this was measured in
the replica, which models the machine but is not one -- the replica does mount
the chroot root READ-ONLY (`overlay ... (ro)`), which is the property that
matters here, and only `/usr/data`, `/tmp`, `/run` and `/dev` are writable.

**Two traps found by running it, both of which would have cost a day on a
printer.** Neither is a reason not to do the phase; both are things the gate
must assert.

* **`s6-svscan` resolves `s6-supervise` through `PATH`.** Started from a shell
  without `$MODDIR/bin` on `PATH`, the scanner answers `s6-svscanctl -a`
  perfectly and then fails every spawn with `unable to spawn s6-supervise for
  X: No such file or directory`, forever, in a log nobody is reading.
  `s6-rc-init` hangs rather than fails while this is true. This is the same
  class as the `s6-ftrigrd` trap and `payload/anvil-env.sh` lines 160-174
  already documents it for `s6-svlisten` -- but it applies to the scanner
  itself, and `S40s6` must not assume its caller's environment.
* **`s6-rc-init` creates one symlink per service in the scandir it is given,
  and collides with what is already there.** Pointed at a live
  `$MODDIR/etc/s6` that already holds `nginx`, `moonraker` and `camera` from
  phases 4 and 5, it fails with `unable to supervise service directories ...:
  File exists`. So the cutover is not additive: the phase-4/5 servicedirs must
  be REMOVED from the scandir in the same change that introduces the database,
  and an upgrade that leaves them behind produces a printer whose supervision
  tree never initialises. This is the sharpest edge in the phase.

*Files:* `versions.env` and `bin/fetch-assets.sh` (execline, s6-rc),
`bin/patch.sh` (5b grows a host and a target s6-rc, `S6_BINS` grows by the
fifteen names the measurement above lists, the ABI gate count moves, a new step
compiles the database),
`payload/etc/s6-rc/source/` (new: the definition directories),
`payload/etc/s6/*/down` (deleted), `payload/anvil-service.sh` (`svc_rc_*`),
`payload/init.d/S40s6`, `S50wifi`, `S60nginx`, `S62moonraker`, `S65camera`,
`payload/firmwareExe` (the loop goes).

*Gate:* `qa/replica/test_s6rc.py`, in `qa/` rather than as a new
`case-*.sh` -- this phase's failures are per-assertion and
`docs/qa-migration.md` is explicit about where an assertion belongs. Against a
machine the real installer produced, it must show: the database the BUILD
produced is the one running (`s6-rc-db -c .../current list all` from inside the
chroot); `s6-rc -a list` reports the four services after the boot; with
`MOD_CAM=0` it reports three and there is no `mjpg_streamer`, which is the
negative control; `S60nginx stop` leaves moonraker answering, which is the
property the `S60web` split bought and the property a wrong dependency edge
would silently destroy; `kill -9` on nginx is respawned; the wifi oneshot
reports up and the init sequence still returned promptly; and `S40s6 start`
twice in a row does not fail. Two more, one per trap the experiment found:
`S40s6` brings the tree up when invoked from an environment with an empty
`PATH` (the scanner-spawn trap, which otherwise hangs `s6-rc-init` rather than
failing it), and an upgrade FROM a phase-4/5 payload -- whose scandir still
holds `nginx`, `moonraker` and `camera` -- initialises rather than colliding on
`File exists`. Then one negative control on the phase itself:
move the compiled database aside and assert the boot says so with `!!` and that
Klipper still comes up, because Klipper is not in the database and must not
care.

## How this gets implemented

Phases 1, 2 and 3 are sequential and all touch `run-append.sh`, `patch.sh` and
`anvil-service.sh`. One worker, one phase at a time, gates run between them --
parallel agents there produce merge conflicts, not speed.

Phase 4 is a clean fan-out: one agent per service, each owning exactly one init
script, one service directory and one gate, each in its own worktree.

Phase 5 is one worker again: it touches user data and deserves undivided
attention.

Phase 8 is one worker as well, and in two sittings with a review between them:
the portability probe first (host-compiled database, run in the replica,
nothing else touched), then everything else. It rewrites the boot path and
touches `patch.sh`, `anvil-service.sh` and five init scripts at once, so
fanning it out produces merge conflicts in exactly the files a bad merge is
hardest to notice in.

Every agent follows the rule this project already has -- install the payload
and run the real tools in the replica, assert on behaviour, always with a
negative control. Never grep a shipped script to decide whether it works.
