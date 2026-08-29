# A Python for the Creator 5 Pro that has sqlite3

An adoption, not an investigation -- but it started as one, and this is what
the investigation measured. It answers one question: can we put an interpreter
on this printer that is not FlashForge's, and does it have the module whose
absence has been shaping this repo's decisions for two releases?

Everything below was measured on the printer replica (real `rootfs.squashfs`
under qemu-mipsel) or read out of the objects with `readelf`, not off a
project page. `build.sh` beside this file rebuilds the whole thing in a
throwaway container and is where the numbers came from;
`pkg/python` is the same build wired into the real build lane,
and `test/integration/printer/case-python.sh` is the gate that proves the
result works on the printer's own kernel.

## Why: one missing module, two releases of consequences

FlashForge built `/usr/prog/Python-3.8.2` **without `_sqlite3`**, and shipped
no `libsqlite3` anywhere on the rootfs. Measured on the replica, with the
library path the interpreter needs to start at all:

    ModuleNotFoundError: No module named '_sqlite3'

That single omission is why `MOONRAKER_VERSION` in `versions.env` is a
2023 commit rather than a release: every Moonraker from v0.9.0 onward keeps
its database in sqlite, and v0.9.0 is where it moved off lmdb. The pin is the
last commit that still uses lmdb *and* has the webcam fix Mainsail needs. No
release has both. That is not a Moonraker problem; it is this problem, seen
from downstream.

The alternatives were: build a `_sqlite3` for 3.8.2 (a module against an
interpreter we did not build, whose ABI we would be guessing at), or build a
whole interpreter. A from-source cross-build costs the same either way, so it
is a whole interpreter -- and a current one, which also ends 3.8's end-of-life
status as a thing anyone has to think about.

## What it is

CPython **3.13.7**, `--disable-shared`, cross-compiled with the repo's pinned
Ingenic gcc 7.2 / glibc 2.29 toolchain, against seven static C libraries built
alongside it (OpenSSL 3.0.15, sqlite 3.46.1, zlib 1.3.1, libffi 3.4.6,
xz 5.4.7, bzip2 1.0.8, expat 2.6.4). Everything is pinned by sha256 in
`versions.env`.

`lib-dynload` comes to 60 extension modules, including the ones this printer
could never have had: `_sqlite3`, `_ssl`, `_hashlib`, `_ctypes`, `_lzma`,
`_bz2`, `zlib`, `pyexpat`, `_asyncio`, `_decimal`, `_multiprocessing`.

## The ABI, which is the whole game

The printer's kernel loads **little-endian, NAN2008, o32, mips32r2** and
nothing else. It refuses everything else with `ENOEXEC` -- "cannot execute
binary file" -- and explains nothing.

    e_flags = 0x70001405   an EXECUTABLE
    e_flags = 0x70001407   a SHARED OBJECT -- 0x2 more, EF_MIPS_PIC
    loader  = /lib/ld-linux-mipsn8.so.1      rootfs glibc 2.33

Both words are correct and any ABI gate must accept both, or it fails on every
one of the 56 extension modules in the tree. `c_helper.so` reads `0x70001407`
too, for the same reason.

**`-EL -mnan=2008` are mandatory in CFLAGS *and* in LDFLAGS.** This toolchain
defaults to big-endian legacy-NaN; the flags are what move it. Passing them in
`CFLAGS` is not enough, because several of the eight projects here do not
forward `CFLAGS` to their link line, and an object linked without them is
legacy-NaN however it was compiled.

So the build does not pass the flags at all. It installs **PATH wrapper
scripts that bake them into the gcc driver**:

    #!/bin/sh
    exec /toolchain/bin/mips-linux-gnu-gcc -EL -mnan=2008 "$@"

and no build system gets a vote. That is the single most important trick in
either copy of this build. The wrapper is itself gated -- compile
`int main(void){return 0;}`, read `e_flags`, refuse to continue unless it is
`0x70001405` -- before 300MB of anything is built on top of it.

## musl is forbidden here

s6 is built against musl in this same repo, and s6 is 73MB with static glibc
versus 3.6MB with musl. None of that applies to the interpreter: klippy
`dlopen`s `c_helper.so`, which is a **glibc** shared object, and a musl-linked
process cannot dlopen it. So this uses the Ingenic glibc toolchain -- the same
one that builds `c_helper.so`, which is also what makes them a matched pair.

glibc 2.29 (toolchain) against 2.33 (rootfs) is forward compatible, and the
measured `NEEDED` list is six ordinary sonames:

    libpthread.so.0  libdl.so.2  libatomic.so.1  libm.so.6  libutil.so.1  libc.so.6

`libatomic.so.1` is the one worth naming. 64-bit atomics on mips32 are
out-of-line calls into libatomic and CPython 3.13's `_Py_atomic_*` needs them.
It **is** on the rootfs -- `/lib/libatomic.so.1.2.0`, measured -- but it is
the only one of the six that is not obviously part of a base system, so the
gate says so out loud.

## Static dependencies, and a static libpython

All seven C libraries are built `-fPIC` and linked in as `.a`. Nothing of ours
ships as a `.so`, and `--disable-shared` puts libpython inside the executable
rather than beside it.

The reason is not size, it is **isolation**. A shared build needs an
`LD_LIBRARY_PATH`, and on this printer that path is a minefield: `/usr/prog`
carries `libffi.so.8` while the rootfs carries `libffi.so.7`, FlashForge's
openssl is 1.0.2d, and a stock OTA can replace any of it. Statically linked,
the interpreter maps *nothing* under `/usr/prog` -- which
`case-python.sh` section 3 proves by reading `/proc/self/maps` of a process
that has imported `ssl`, `ctypes`, `sqlite3`, `lzma`, `zlib` and `hashlib`
first. Zero mappings. It also means it starts with `LD_LIBRARY_PATH` empty,
which FlashForge's cannot.

The cost is a few MB of duplicated libcrypto between `_ssl.so` and
`_hashlib.so`. At 30MB that is a good trade.

A `--disable-shared` interpreter is not automatically usable by third-party
extension modules -- they resolve Python's symbols out of the running
executable, which only works if it was linked `-export-dynamic`. That was
checked, not assumed: an out-of-tree extension module was cross-compiled
against the staged `include/` and imported successfully on the replica.

## The trap that costs a day: `_sqlite3` and `-lm`

**The one module this entire build exists for goes missing silently.**

A shared `libsqlite3.so` carries its own `DT_NEEDED` on libm. A
`libsqlite3.a` does not. So CPython's

    checking for sqlite3_bind_double in -lsqlite3

link probe fails with a wall of `undefined reference to floor/log/pow/...`,
and CPython 3.13 **records `_sqlite3` as "missing" and carries on**. It is a
probe failure, not a compile failure. Nothing in 400 lines of build output
says why. You get a clean build, a working interpreter, and no sqlite3.

The fix is two exports:

    LIBS="-latomic -lm"
    LIBSQLITE3_LIBS="-L$DEP/lib -lsqlite3 -lm"

the second stating the link line outright so pkg-config cannot reorder `-lm`
out from under the probe. And because a silent failure fixed by an
easily-deleted export is a silent failure waiting to come back, **both copies
of this build hard-fail when `_sqlite3` is absent**, `bin/verify.sh` checks
the packaged tree for it, and `case-python.sh` does not merely import it: it
creates a database, inserts rows, closes it, and reopens it from disk **in a
second process**. An import proves the `.so` loaded. Only the second process
proves there is a database.

## Two OpenSSL traps

Both hit for real on 3.0.15:

* **`no-docs` does not exist before OpenSSL 3.1.** On 3.0.x it is an
  "Unsupported options" *hard error*, not a warning.
* **The `linux-mips32` target hardcodes `-mips2`** into its cflags. This
  toolchain defaults to `-mfp64`, and gcc rejects the combination below
  mips32r2: *"'-mgp32' and '-mfp64' can only be combined if the target
  supports the mfhc1 and mthc1 instructions"*. User cflags land *after* the
  target's on the command line, so appending `-mips32r2` puts the ISA back
  where the printer is. If a future OpenSSL orders them the other way,
  `linux-generic32` (portable C, no mips assembly) is the fallback -- and both
  copies of the build take it automatically rather than leaving it as a note,
  because the failure is a screenful of assembler errors that says nothing
  about ISA levels.

This is why `OPENSSL_VERSION` is pinned to the 3.0 LTS branch and not bumped
casually.

## The gap: there are no CA certificates

`--openssldir` points at `/usr/data/anvil/ssl`, which is where the
interpreter looks for a trust store **on the printer**. Nothing installs one
there, and the rootfs has none to borrow.

So: `import ssl` works, TLS works, and **verifying a certificate chain does
not**. `ssl.create_default_context()` builds a context with an empty trust
store and every verified connection fails. Anything that fetches over https on
this interpreter has to be handed a `cafile` of its own until somebody ships a
`ca-certificates` bundle into that directory -- which is ~200KB and an open
piece of work, not a decision.

`case-python.sh` prints the trust-store paths and says which of the two states
the printer is in, rather than asserting either, so the day someone ships a
bundle the gate reports it instead of failing.

## Sizes and time

| | files | on disk |
|---|---|---|
| `make install` output | 2909 | 183 MB |
| trimmed -- what ships | 608 | 30 MB |
| trimmed, gzipped | | 10.4 MB |

The trim drops the CPython test package and `idlelib` (nothing on a printer
runs either), `tkinter` (there is no X11), `include/` and `config-*/` (they
exist to *build* extension modules, which happens on a developer's machine),
every `.a`, and every `__pycache__` -- 12MB of `.pyc` for modules that will be
imported once if ever, and which the interpreter regenerates on demand anyway.
The interpreter and every `lib-dynload/*.so` are stripped.

It also empties `bin/` of everything except `python3.13` itself -- the
`python3` symlink, `idle3`, `pydoc3` and the `*-config` scripts -- and drops
`lib/pkgconfig`. Those are all build-time or convenience files, and in a
*shared* prefix root they are not neutral: `bin/` and `lib/` here also hold
s6's binaries and, through `anvil-env.sh`, sit on every mod process's PATH.
See "Where it lands" above. The build asserts `bin/` holds exactly one name
afterwards, so a future CPython that installs one more launcher fails the
build rather than quietly adding a name to PATH.

**Cold build: 142 seconds** (`tools/python/build.sh`, 16 cores), of which about
90 is the x86-64 build-python. In the build lane it is ~100s and it happens
**once**: `bin/patch.sh` caches the cross-built tree in `work/.py313` under a
stamp of all eight versions, so every later build copies rather than compiles.
The stamp is all eight and not just CPython's, because a bumped OpenSSL under
an unchanged `PY_VERSION` has to rebuild.

Cross-building CPython needs a build-python of the **same** version -- the
Makefile runs it to freeze modules, generate the deepfreeze sources and
byte-compile the stdlib, and `configure` hard-errors when the version does not
match. That is why `docker/Dockerfile.build` carries a host C compiler, and why
`PY_VERSION` moves both halves of the build at once.

## Where it lands

`$MODDIR` -- `/usr/data/anvil` -- is a `--prefix` root. That is the whole
reason s6 was configured for it, and it is why the mod's tree has `bin/`,
`lib/`, `libexec/` and `etc/` directly inside it rather than a directory per
package. The interpreter is configured `--prefix=/usr/data/anvil` like
everything else, so it installs as `bin/python3.13` beside `bin/s6-svscan`,
with its stdlib in `lib/python3.13/`. One prefix, one place to look.

That path is **compiled in** -- `sys.prefix` and the stdlib search that follows
from it -- so moving the directory on the printer breaks the interpreter the
way moving s6 breaks its waiting verbs. It has to be rebuilt, not renamed;
which is itself an argument for keeping it in the one prefix the mod already
guarantees rather than inventing a second one.

**One thing does not ship: the `python3` symlink.** `make install` puts it
beside `python3.13`, along with `idle3`, `pydoc3` and the `*-config` scripts.
`anvil-env.sh` prepends `$MODDIR/bin` to `PATH` -- it has to, because
`s6-svscan` execs `s6-supervise` by name -- so a `bin/python3` of ours would
sit *in front of* FlashForge's for every process that sources it, and anything
saying `python3` rather than `"$FF_PYTHON"` would change interpreter without
anyone deciding to. The build deletes it before staging and asserts that
`bin/` contains `python3.13` and nothing else; `bin/verify.sh` checks the
packaged tree for it; and `case-python.sh` section 6 asks the *shell*, with
the mod's own PATH in force, what `python3` resolves to. The answer is still
FlashForge's binary.

## It ships. Nothing runs it.

*[Superseded: `FF_PYTHON` is `$MODDIR/bin/python3.13` now, and Moonraker,
klippy, `ff-startup.py`, `ffscreen.py` and the MCU bring-up all run on it. What
follows is the state this investigation ended in.]*

`payload/anvil-env.sh` still points `FF_PYTHON` at
`/usr/prog/Python-3.8.2/bin/python3`. That is timing, not preference: klippy,
Moonraker and `ff-startup.py` import third-party C extensions -- tornado,
lmdb, cffi, greenlet, pillow, libnacl -- which exist on this printer only as
mipsel `.so` files built against 3.8. None has been cross-built for 3.13.
Switching before they exist is a dark screen and an ImportError in a log
nobody reads.

FlashForge's tree is left alone in both directions: nothing writes to
`/usr/prog`, and our interpreter lives entirely under `/usr/data/anvil` like
everything else this mod installs. This is deliberately the same shape as
phase 2, which shipped s6 without starting it -- the artefact reaches real
printers where it can be measured, and the switch stays a one-line change
instead of a build change and a boot change arriving together. Cross-building
the extensions is the actual work in adopting this; not the interpreter.

## Reproducing

    ./bin/fetch-assets.sh --all          # pins + the Ingenic toolchain
    ./tools/python/build.sh              # 142s, artefacts in tools/python/out/

That is how the numbers above were measured, and it is kept here for the
record and for trying a version bump before it becomes a pin. It is not how
the shipped interpreter is built: `pkg/python` compiles it inside the repo's
own build image, from the sha256-pinned tarballs, against the seven static
libraries the feed builds as their own `-dev` packages, and caches it in
`work/pkg/python`. `bin/patch.sh` section 5c runs that recipe and stages what
it produced; it no longer contains a compiler invocation of its own.

The gate, against the tree the build actually produced:

    tar -czf work/.py-gate.tgz -C work/.py313 python3.13
    PRINTER_IMAGE=monstrofil/creator5-printer:latest \
        ./test/integration/printer-exec.py \
        test/integration/printer/case-python.sh py.tgz=work/.py-gate.tgz

or `make test-python`, which does both.
