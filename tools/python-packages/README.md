# The Python packages Moonraker and klippy need, cross-built for mipsel

The second half of phase 6. `tools/python/` builds the interpreter;
this builds what runs on it. **Now wired into `bin/patch.sh` section 5c,
step 4** -- see "What is left" at the bottom for what that did and did not
settle. `build.sh` is the measurement harness, preserved here because it is
where the findings live, exactly as `tools/supervisor/` is for s6; it is not
what a release runs any more, and the two have drifted on purpose (patch.sh
builds offline from `vendor/` and needs no docker, because the build lane has
no docker socket). `fill-designators.py` is the exception: it is a real build
input, called by `patch.sh` for greenlet.

Everything below was run in the printer replica on the real
`rootfs.squashfs`, not read off a project page.
`test/integration/printer/case-pyext.sh` is that run, kept.

## What builds

18 sdists, 12 mipsel extension modules, from a 56-second clean build in one
throwaway `debian:bookworm`. (This said 19 for a while; the list below is 18,
and `versions.env` -- which is now the list that matters -- pins 18.) Every
`.so` is gated at `e_flags=0x70001407`,
`nan2008/o32/mips32r2` -- shared objects carry `EF_MIPS_PIC`, so they read
`…07` where an executable reads `…05`.

Native: cffi, greenlet, lmdb, markupsafe, streaming-form-data, tornado
speedups, pillow. Pure: jinja2, distro, inotify-simple, libnacl, dbus-next,
preprocess-cancellation, pyserial, pyserial-asyncio, pycparser, smart_open,
setuptools.

**The list is deliberately not `moonraker-requirements.txt`**, which installs
every optional component's dependencies. It is the closure of what the
*enabled* component set imports -- `moonraker.conf`'s sections plus
`CORE_COMPONENTS` -- plus klippy's. So no apprise, ldap3, paho-mqtt, zeroconf
or python-periphery. `msgspec` and `uvloop` are skipped on purpose: Moonraker
guards both with `contextlib.suppress(ImportError)` and falls back to the
stdlib, measured.

## The method

No crossenv. The staged interpreter already carries
`_sysconfigdata__linux_mipsel-linux-gnu`, so exporting
`_PYTHON_SYSCONFIGDATA_NAME` at an x86-64 build-python **of the same 3.13.7**
makes setuptools answer every question for the target. The stage is
bind-mounted at `/usr/data/anvil` so `INCLUDEPY` resolves unmodified. Plus the
gcc-wrapper trick from `tools/python/build.sh`, which is what gets
`-EL -mnan=2008` onto the link lines.

## What fought back, and what it cost

* **greenlet was the expected blocker, for an unexpected reason.** The MIPS
  stack-switching assembly was never a problem. greenlet 3.x is C++ and writes
  its `PyTypeObject`s as designated initializers, which gcc 7.2 accepts only
  in declaration order with no gaps:

      sorry, unimplemented: non-trivial designated initializers not supported

  The exact rule was probed rather than assumed: in-order contiguous is fine,
  a *trailing* gap is fine, an *interior* or *leading* gap is refused.
  `fill-designators.py` writes the skipped fields back as explicit zeros,
  taking field order from the target's own headers and refusing to guess when
  a designator is not in them. 55 fields across two files, semantically a
  no-op -- static storage duration, those fields were already zero -- and the
  result switches out and back, in order, on the printer.

* **pip silently downloaded x86-64 manylinux wheels** for cffi, greenlet and
  tornado on the first run. Three wrong-architecture `.so` files sailed
  straight through the build and only the ABI gate caught them.
  `--no-binary :all:` is mandatory here, not caution.

* **lmdb chose its cffi backend** and produced a `py3-none-any` wheel with
  `mdb.c` inside -- which is phase 6's recorded trap rebuilt from scratch: on
  the printer that path tries to invoke a compiler that does not exist.
  `LMDB_FORCE_CPYTHON=1` fixes it. Note `LMDB_FORCE_CFFI=0` makes it *worse*:
  the variable is tested for presence, so `"0"` selects cffi.

* **pillow 10.3.0 cannot be built by any 3.13**, cross or not: its `setup.py`
  does `exec(...)` then reads `locals()["__version__"]`, which PEP 667 broke.
  11.0.0 is the first version that works.

* **streaming-form-data 1.13.0** (Moonraker's pin) ships pregenerated Cython C
  calling the 4-argument `_PyLong_AsByteArray`, which grew a fifth parameter in
  3.13. 1.19.1 instead, which then wants `smart_open` at module scope.

## What it proves

Beyond "it imports", which proves very little on its own:

* cffi does `cdef` + `dlopen` + call through libm -- klippy's exact ABI-mode
  usage.
* **cffi dlopens the printer's own `/usr/prog/klipper/klippy/chelper/c_helper.so`,
  resolves `stepcompress_alloc`, `steppersync_alloc` and
  `itersolve_generate_steps`, and calls one.** That is phase 7's central
  question -- whether a Python we built can drive FlashForge's C helper --
  answered yes, and it is the reason the interpreter had to be glibc and not
  musl.
* lmdb writes and a *second process* reads back.
* pillow decodes, resizes and re-encodes a PNG: the real thumbnail path.
* **all 16 Moonraker components import on 3.13**, the list taken from
  `CORE_COMPONENTS` + `moonraker.conf` rather than written down here.
* zero `/usr/prog` libraries mapped, with every extension imported.
* Negative control: move the tree aside and every third-party import fails.

## Size

13.5MB built, 2.9MB gzipped, 1073 files; 18.2MB on the printer once
`__pycache__` exists. With the interpreter, about 50MB.

`setuptools`/`pkg_resources` are 4.9MB of that -- 36% -- and are not needed at
runtime: measured, with them removed lmdb still loads its CPython extension
and all 16 components still import. The phase-6 trap was the lmdb *egg*'s cffi
fallback, and installing lmdb as a wheel removes it. Dropping them is a size
decision, not a correctness one.

## Moonraker SERVES on 3.13 -- settled, not assumed

Importing is not serving, so it was run. `test/integration/printer/case-moonraker313.sh`
starts Moonraker on the exact command line `payload/etc/s6/moonraker/run`
execs, only with our interpreter, against the mod's own `assets/moonraker.conf`:

* bound :7125 in 3s, `/proc/PID/cmdline` confirming our interpreter and our
  entry point
* `GET /server/info` 200 with **23 components loaded and 0 failed**;
  `/machine/system_info` (a different component, reading this box's /proc)
  reports `cpu: mips`, `python 3.13.7 [GCC 7.2.0]`
* the **database really works**: POST wrote a namespace, GET read it back, the
  namespace appears beside Moonraker's own, and `data.mdb` is 147456 bytes on
  disk -- through `lmdb/cpython.cpython-313-mipsel-linux-gnu.so`, not the
  compile-at-import cffi fallback
* alive and still answering **120 seconds later**, zero tracebacks in its log,
  and SIGTERM released the port in 2s
* **the running process maps 0 libraries under `/usr/prog`**, with
  `LD_LIBRARY_PATH` completely unset -- not merely purged of `/usr/prog`
* negative controls: nothing on :7125 beforehand, and with `site-packages`
  moved aside it never binds

What is still unproven is endurance and integration, not capability: no real
hardware, no live klippy attached (`klippy_connected=False` throughout, so the
klippy_apis paths loaded but were never exercised), no upload through
streaming_form_data, no websocket client, and it has not been run through
`S62moonraker` under s6 on 3.13 -- the entry point was driven directly, on
purpose, so that a failure would be the interpreter and not an init script.

## libsodium: built into the prefix, and it costs anvil-env.sh nothing

`build-libsodium.sh` cross-builds libsodium 1.0.20 with the Ingenic toolchain
(24s), gated at `0x70001407` nan2008/o32/mips32r2, SONAME `libsodium.so.26`,
needing only libpthread, libc and the loader. 406KB stripped, into
`$MODDIR/lib`.

It does not need a new `LD_LIBRARY_PATH` entry, which is the pleasant part.
libnacl's third fallback is `__file__[0:__file__.find("lib")+3] +
"/libsodium.so"`, and `__file__` is
`$MODDIR/lib/python3.13/site-packages/libnacl/__init__.py`, so it resolves
`$MODDIR/lib/libsodium.so` **by absolute path** -- measured working with
`LD_LIBRARY_PATH` unset entirely. Worth writing down that this works because
the prefix happens to contain the string `lib`; a prefix without it would
break silently. Adding `$MODDIR/lib` to the path also works and is the
belt-and-braces option, but it would put our libraries in front of everything
for every mod process, which is the kind of entry this file's own history
argues against.

It computes as well as loads: `sodium_version_string()` is 1.0.20, its
BLAKE2b-256 matches CPython's own `_blake2` on the same kernel, and
`libnacl.sign.Signer/Verifier` -- the exact ed25519 pair `authorization.py`
imports -- signs, verifies and rejects a tampered message. With it,
`/usr/prog/libsodium/lib` can come off `ANVIL_LIBS`, though only as part of the
same one-line `FF_PYTHON` switch, since 3.8's libnacl still needs it.

## What was left before FF_PYTHON could switch

**Done as of the commit that flips `FF_PYTHON` in `payload/anvil-env.sh`.**
Capability was settled first -- Moonraker serves, the database works,
libsodium is ours -- and packaging and integration followed:

1. ~~**Wire into `bin/patch.sh`.**~~ **Done.** The package build runs inside
   5c against the untrimmed stage, BEFORE the trim, which was the
   recommendation here and is still the only place all three things it needs
   exist at once: the headers `INCLUDEPY` points at, the static C libraries in
   `work/.py-dep` (pillow's zlib, cffi's libffi) and the x86-64 build-python.
   The consequence is that `work/.py313` has **two stamps** -- `.version` for
   the interpreter and `.pkg-version` for the packages -- and a package bump
   rebuilds CPython too, which is the price of not caching a second untrimmed
   tree. libsodium is its own section, 5d, cached separately in
   `work/.sodium`. Every pin is in `versions.env` with a sha256 and
   `bin/fetch-assets.sh` fetches them, so **patch.sh no longer talks to a
   network**: no `get-pip.py`, no PyPI, `pip --no-index` against hashed
   sdists. The build-python gets its pip from `--with-ensurepip=install` out
   of the same pinned CPython tarball. Two build-image packages were needed
   and are in `docker/Dockerfile.build` with the reason beside them:
   `zlib1g-dev` (a build-python without zlib cannot unpack a wheel, or pip
   itself) and `patch` (lmdb's `setup.py` shells out to `/usr/bin/patch`).
2. ~~**Extend the ABI gate's reach.**~~ **Done**, as described: same rule,
   pointed at the staged payload instead of the build cache -- the
   interpreter, `lib/python3.13` (stdlib *and* site-packages) and libsodium's
   resolved `.so`. Originally not `$MOD_PAYLOAD/bin/s6-*`: s6 was believed
   exempt, reading `e_flags=0x1007` (legacy-NaN) from a plain mips32r1 musl
   toolchain on the theory that a supervisor doing no floating point cannot
   care about NaN encoding. True of the arithmetic, false of exec() -- a
   nan2008-only kernel can refuse a legacy-NaN binary outright, which
   qemu-mipsel-static's user-mode emulation never enforced, so this shipped
   before it was caught. s6 is IN the gate now, built with Bootlin's
   mips32r5el toolchain (nan2008 by construction), same rule as everything
   else in 5b.
3. ~~**Run it through `S62moonraker` under s6 on 3.13.**~~ **Done.**
   `test/integration/printer/case-moonraker313-s6.sh` drives the real boot
   path -- S40s6's scandir, S62moonraker, readiness gating on `:7125`
   actually listening rather than the process forking, a `kill -9` respawn
   back onto 3.13, and a stop that stays stopped -- and all of it passed on
   the replica.
4. ~~Then the switch itself.~~ **Done**: `FF_PYTHON` in `anvil-env.sh` and
   `/usr/prog/libsodium/lib` off `ANVIL_LIBS`, in the same commit.
5. klippy is **not** blocked by packages, and was never part of this switch:
   it keeps running on FlashForge's 3.8.2, started independently by
   `/usr/prog/klipper/start.sh` (see `init.d/S70klipper`), not by
   `FF_PYTHON`. cffi, greenlet, jinja2, markupsafe
   and pyserial all build, and `c_helper.so` binds. `numpy` is the only gap,
   wanted solely by `extras/stepper_resonance_tester.py`, which Klipper loads
   on demand. numpy on 3.13 means numpy >= 2.1 and a Meson cross-file, and
   that genuinely is a multi-day rabbit hole. It costs input-shaper
   calibration, not printing.

Unverified: no real hardware, replica only; nothing has run under sustained
load; and the greenlet designator patch is a no-op by argument plus a working
switch test, not by upstream blessing.
