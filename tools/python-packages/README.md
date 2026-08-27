# The Python packages Moonraker and klippy need, cross-built for mipsel

The second half of phase 6. `tools/python/` builds the interpreter;
this builds what runs on it. **Not yet wired into `bin/patch.sh`** -- see
"What is left" at the bottom. `build.sh` is the measurement harness, preserved
here because it is where the findings live, exactly as `tools/supervisor/`
is for s6.

Everything below was run in the printer replica on the real
`rootfs.squashfs`, not read off a project page.
`test/integration/printer/case-pyext.sh` is that run, kept.

## What builds

19 packages, 12 mipsel extension modules, from a 56-second clean build in one
throwaway `debian:bookworm`. Every `.so` is gated at `e_flags=0x70001407`,
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

## The one unsolved dependency: libsodium

`libnacl` is pure Python and ctypes-loads libsodium, which exists on this box
**only at `/usr/prog/libsodium/lib`**. Measured both ways: it fails with an
empty path and works with that directory on it. So Moonraker's
`authorization` component keeps one `/usr/prog` dependency, and it is the last
one in the picture. Either cross-build libsodium into the prefix, or accept
`anvil-env.sh` keeping that single entry.

## What is left before FF_PYTHON can switch

1. **Boot Moonraker on 3.13 and hit the HTTP API.** Every component imports
   and the entry point loads, but importing is not serving: nothing has bound
   :7125 on 3.13. `case-moonraker.sh` already does this against 3.8; pointing
   it at 3.13 is the next gate and the honest remaining unknown.
2. Decide libsodium, above.
3. Wire into `bin/patch.sh`. Note the build needs the **untrimmed** interpreter
   stage -- `include/` and `config-3.13-*`, which section 5c's trim currently
   deletes -- and the pins want moving into `versions.env` with sha256s.
4. klippy is **not** blocked by packages: cffi, greenlet, jinja2, markupsafe
   and pyserial all build, and `c_helper.so` binds. `numpy` is the only gap,
   wanted solely by `extras/stepper_resonance_tester.py`, which Klipper loads
   on demand. numpy on 3.13 means numpy >= 2.1 and a Meson cross-file, and
   that genuinely is a multi-day rabbit hole. It costs input-shaper
   calibration, not printing.

Unverified: no real hardware, replica only; nothing has run under sustained
load; and the greenlet designator patch is a no-op by argument plus a working
switch test, not by upstream blessing.
