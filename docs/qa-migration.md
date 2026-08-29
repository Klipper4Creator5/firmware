# The qa suite, and what it replaces

`qa/` is the test suite. It was built beside `test/` rather than inside it, and
the migration is now done: every `case-*.sh` has been ported or retired, and
what remains of `test/` is 185 host-side pytest tests plus one packaging gate.

This document says why it exists, what it proves, and what is still owed.

## The problem it is answering

Three complaints, one cause.

**Two frameworks.** `test/run-tests.py` and `test/ffsim/` are 1,657 lines that
reimplement what pytest already does — skip accounting, gating, reporting, and
then parsing pytest's own JUnit XML back out — and they invoke pytest as gate
#5 of about twenty.

**Assertions in the wrong language.** `test/integration/printer/case-*.sh` was
6,280 lines of POSIX sh executing inside a qemu chroot, and between them they
reported **13 boolean bits**. `case-moonraker.sh` was 1,059 lines that
collapsed to one pass/fail. A failure tells you a case went wrong, not which of
its forty assertions did.

**No parallelism, no selection.** Each replica gate is its own
`docker run --privileged`, re-registering binfmt and re-assembling the mount
layout. Thirteen of those, strictly in sequence, all or nothing.

All three follow from one decision: **the replica container is treated as a
test runner instead of as a fixture.** That is what pushes assertions into ash,
which yields one bit per container, which then needs a bespoke framework above
pytest to aggregate the bits.

## Two rules

> **1. Shell inside the chroot performs actions. Python on the host makes
> assertions.**

Shell in qemu is irreplaceable for *doing* things — the printer's busybox, its
tar, its OpenSSL, and the fact that our scripts survive its ash is a large part
of what the suite proves. It is a bad place to *judge* things. Where a fact is
only observable inside the replica, `qa/lib/replica.py` exposes a typed probe
for it, and a case script never branches on it.

`qa/replica/actions/` is what remains of the shell — three files that drive the
machine and assert nothing. No `ok`/`bad`, no counter, no verdict.

> **2. The machine under test is one the real installer produced.**

The `printer` fixture is a replica with the package installed by the printer's
own `/usr/prog/app_startup.sh`, off a genuine FAT filesystem on `/dev/sda1`,
exactly as a user installs it from a USB stick.

An earlier version of this tree had `install-payload.sh`, which copied
`payload/*.sh` and `pkgs/anvil-core/payload/init.d/S*` into `$MODDIR` by hand —
the same shape `case-services.sh` used. Two things are wrong with it:

- It is a **second implementation of the install**, so everything downstream
  asserts against a layout the harness built rather than one the installer
  produced. The real installer could break and nothing here would go red.
- It can only place what a recipe keeps in the repo, so **anything the build produces is
  missing**. The cross-compiled s6 is the obvious one: it lives in `work/.s6`
  and `bin/patch.sh` stages it into the package, so a hand-placed payload has
  no supervisor at all — which is why the tests had to carry a stand-in
  scanner, and why one of them had to ask whether it was testing the stand-in
  before it could mean anything.

Installing for real fixes both at once, and deletes the stand-in. Compare what
lands in `/usr/data/anvil`:

| hand-placed | really installed |
|---|---|
| `anvil-env.sh anvil-service.sh anvil.conf init.d etc/s6` | `VERSION anvil-env.sh anvil-service.sh anvil.conf backup bin config config-installed etc helixscreen init.d lib libexec moonraker nginx www` |

`bin`, `lib` and `libexec` are the cross-built s6 and CPython 3.13. No amount
of copying a recipe's files produces them.

This repo has learned this once already, in `case-install.sh`'s own header:

> *An earlier version of this file replayed `app_startup.sh` by hand — which
> meant a bug in our reading of it could never be caught.*

## What the machine is

Unchanged. `qa/` reuses `test/integration/printer/`'s `Dockerfile`,
`entrypoint.sh`, `assemble.sh`, `binfmt.sh` and `seed-prog.sh` **as they are**,
and the `docker run` argv is deliberately the same one `test/ffsim/replica.py`
builds, minus `--rm` and plus `-d`. Same image, same `--privileged`, same
read-only squashfs root and writable prog/data partitions, same chroot onto the
printer's own busybox under qemu.

This matters more than it looks: while both suites run, they have to be testing
the *same machine*, or neither proves anything about the other.

The only new trick is how the container is held open. `entrypoint.sh` ends by
running the case script it was given; the one `qa/` gives it is
`qa/replica/actions/hold.sh`, which touches a marker and then sleeps. Setup runs
to completion exactly as it always has, and the container simply does not exit.
The marker is also the readiness signal, because setup ranges from under a
second (a prebuilt `PRINTER_IMAGE`) to over a minute (unpacking the factory
image and installing the stock package under qemu) and a constant would either
waste the fast case or fail the slow one.

## Lanes

| Lane | Needs | Marker |
|---|---|---|
| `static` | nothing but the checkout | `@pytest.mark.static` |
| `replica` | docker + qemu + the firmware | `@pytest.mark.replica` |

```sh
make qa            # both
make qa-static     # seconds, any machine, any clone
make qa-replica    # the gates that decide whether a package bricks
```

The replica lane needs two things.

**A base replica.** Quickest is the prebuilt image, which carries the firmware,
`/usr/prog` and `/usr/data` with the stock package already installed — put it in
`test.env` (see `test.env.example`) or pass it per-run:

```sh
PRINTER_IMAGE=monstrofil/creator5-printer:latest make qa-replica
```

Without it the lane builds the replica from `work/rootfs`, which needs
`make rootfs` and the stock package.

**A built package**, in `work/out/*.tgz` — because the lane installs it for
real. `make build` produces one; the newest by mtime is the one used, and the
run says which. It is never built on demand: `make build` cross-compiles s6 and
CPython and takes minutes, and a fixture that silently started that would turn
"the suite is slow today" into a mystery.

### The installed image

The install is the machine's own shell under qemu, so it is baked into an image
**once per package** and cached under a tag derived from the package's md5 —
the same trick `build-printer-image.sh` uses for the stock baseline:

```
qa: baking creator5-printer-anvil:ce5f8271ccca from monstrofil/creator5-printer:latest
    (Creator5Pro-anvil-20260827b.tgz) -- once per package, then cached
install: booting /usr/prog/app_startup.sh with the package on /dev/sda1
install: the machine's own updater installed the package
qa-bake: mod installed, VERSION anvil-env.sh anvil-service.sh ... lib libexec moonraker nginx www
```

Rebuild the package and the md5 changes, so the next run bakes again rather
than testing yesterday's build. That is deliberately not a hand-written
staleness check, because those are the ones that eventually get it wrong.

`qa/replica/actions/bake.sh` refuses to run with `USB_STICK` unset, and fails if
`/parts/data/anvil` is absent afterwards — a bake whose chroot unmounted early
would otherwise commit a *stock* machine under a name saying it has the mod,
and every test built on it would assert against firmware it was not told it had.

Selection is pytest's: `-k S62moonraker`, `-m static`, or a single test id.

Parallel runs **must** use `--dist loadscope`:

```sh
python3 -m pytest ./qa -n 4 --dist loadscope
```

The `printer` fixture is module-scoped and xdist's default `--dist load` hands
out individual tests, so four workers pulling from one module would assemble
four replicas of the same machine. `qa/conftest.py` refuses the default rather
than letting the suite get mysteriously slower when it is parallelised.

## Skips

**A missing tool, daemon or firmware image is a failure**, raised at the point
that needs it, with the fix in the message. There is no flag, no environment
variable and nothing to remember to pass.

This replaces `REQUIRE_PRINTER_SIM` and `ALLOW_SKIP`, and it preserves the
discipline they existed for — *a gate that did not run must never look green* —
by removing the mode in which it can. There is no configuration in which
running this suite without shellcheck, or without a replica, is a complete run,
so nothing needs to be told that.

An earlier version of this tree had a `--strict-skip=<lane|all>` flag. It was
the wrong shape and it lasted one commit. It was `ALLOW_SKIP` inverted, and
`ALLOW_SKIP`'s defect was never the direction it named things in — it was that
**the decision lived in the CI invocation**. An accept-list has to be edited
whenever a gate moves; a strict-list has to be remembered whenever a job is
added. Both degrade silently when the command line is wrong, which is the same
disease as the `printer-sim` job that was gated on an unset secret and
therefore never ran once in its entire existence.

`pytest.skip` stays available for what it is actually for: a question that does
not *apply* to this configuration, as opposed to one this machine happens to be
unequipped to ask. A test that only means something on a Creator5Pro would earn
it. "I could not find the tool" does not.

**There are three skips, and they do not meet that bar.**
`qa/static/test_ipk.py` reads `work/modpayload-root`, which only exists after
`bin/patch.sh` has run, and skips when it is absent. That is "this machine is
not set up", which the rule above says must fail -- but making it fail would
put a stock FlashForge package in the way of a lane whose whole point is that
it needs nothing.

So `make qa-static` reads 246 passed on a tree that has been built and
243 passed, 3 skipped on one that has not, with nothing at the end saying which
kind of run you just had. Either the payload questions move to a lane that can
require a build, or they fail with `make build` in the message the way the
replica lane does.

## What is proven so far

The migration is **done** apart from one gate. Every `case-*.sh` is either
ported or retired, and `test/run-tests.py` no longer drives a single replica
case.

| Lane | File | Tests | From |
|---|---|---|---|
| static | `test_shell_syntax.py` | 7, parametrised over every script | `run-tests.py`'s `check_shell_syntax`, `check_no_bashisms`, `check_undefined_names` -- now deleted |
| static | `test_ipk.py` | 32 | new -- the packages, the layout and the ABI string |
| static | `test_recipe_layout.py` | 9 | new -- a recipe's fixed shape |
| static | `test_s6rc_source.py` | 9 | new -- what the boot graph *says* |
| static | `test_probes.py` | 17 | new -- the harness's own parsers |
| replica | `test_install.py` | 22 | `case-install.sh`, 579 lines and 1 bit |
| replica | `test_supervisor.py` | 31 | `case-supervisor.sh`, 166 lines |
| replica | `test_upgrade.py` | 21 | `case-upgrade.sh`, 223 lines |
| replica | `test_boot_screen.py` | 17 | `case-boot-screen.sh`, 210 lines |
| replica | `test_s6rc.py` | 12 | new -- what the printer *does* |
| replica | `test_mcu_bringup.py` | 8 | `case-mcu-bringup.sh`, 129 lines |
| replica | `test_web.py` | 7 | `case-nginx.sh` + `case-moonraker313-s6.sh`, 1,124 lines and 2 bits |

Measured on `monstrofil/creator5-printer:latest`, off a real package built from
this tree:

| | |
|---|---|
| `qa/static` | **246 tests, 8s**, no docker |
| `qa/replica` | 118 tests, 3m40s -- 110 pass, 8 blocked on absent hardware |
| `test/` pytest | 185 tests, 0.4s |

`test/run-tests.py` is **322 lines** and `test/ffsim/` **483**, from 1,657
between them. What is left of the old harness runs the packaging build on a
synthetic stock package and calls pytest; it holds no replica gate at all.

### Three ports found assertions that had stopped meaning anything

Worth recording, because each had been green for months while asserting
nothing:

- **`case-mcu-bringup.sh`'s negative control had inverted.** It asserted the
  bring-up FAILS without `LD_LIBRARY_PATH`. Our CPython is built
  `--disable-shared` now and needs no library path, so the case's own `skip`
  branch was the one firing. The port asserts the direction that is true today
  -- it runs under `env -i` -- which still goes red if a future build
  reintroduces the dependency.
- **`case-upgrade.sh`'s headline assertion was vacuous.** It proved an update
  removes `init.d/S60web`; `run-append.sh:150` does `rm -rf $MODDIR/init.d`
  *unconditionally*, outside the manifest branch, so it would have passed on an
  installer whose entire manifest logic had been deleted. The port makes that
  claim against a path only the manifest governs, and gives the unconditional
  removal a test of its own.
- **`case-boot-screen.sh` confirmed its own arithmetic.** It computed the
  expected pixel packing by calling `ffscreen._pixel` *inside* the replica, so
  a swapped R/B would have matched itself perfectly. The port computes the
  expected bytes on the host.

### Two rakes in the replica, recorded so nobody steps on them twice

- **The install log double-counts.** FlashForge's `run.sh` runs under `set -x`
  and `run-append.sh` is spliced into it, so every `echo` appears twice -- once
  as the `+ echo ...` trace and once as output. Counting a string in
  `/usr/data/anvil-install.log` says two on one occurrence.
- **`/usr/bin/od` takes neither `-A` nor `-t`**, and `busybox od` resolves to
  the same binary, so the usual `od -An -tx1` returns a usage error -- which,
  parsed as bytes, is an empty list rather than a loud failure. `xxd -p` is
  present and does the job.

### The replica cannot boot the whole tree, and that is hardware

Eight of `test_s6rc.py`'s twelve need the WHOLE boot set and cannot pass on a
replica. Measured, in this order:

* there are no `/dev/ttyS4,5,7`, so `mcu-bringup` fails and klippy never gets
  past `disconnected`;
* there is no `/dev/video*`, so `camera` hits its 40s `timeout-up` and s6-rc
  reports `command exited 99`;
* `ff-startup` then waits out its own `timeout-up` of 300000ms for klipper --
  **holding the s6-rc lock**, which is why a poll during that window gets
  `unable to take locks: Device or resource busy` rather than a short list of
  what did come up.

`nginx` and `moonraker` do come up, and moonraker reaches `ready` -- which is
what `test_web.py` asserts against, by bringing up those two alone before
anything takes the lock. So the blocker is not the boot graph; it is that two
services need hardware the replica has not got. Closing it is the simulated-MCU
lane in *Not in scope* below, not a longer deadline in the fixture.

The four that ask only about what was installed pass, and one of them was
failing for a reason worth recording: `s6-rc-init`'s default deadline is
`TAIN_INFINITE_RELATIVE`, which does not fit this printer's 32-bit `time_t`, so
it died with `EOVERFLOW` before reaching its subject. Every `s6-rc-init` in the
suite now passes `-t`, the same fix `firmwareExe` carries.

`test_probes.py` has no counterpart in the old suite and is worth explaining:
`Printer.ps()` and `Printer.listening()` are parsers, and a parser is where a
harness goes quietly wrong. A `listening()` that never matches makes every
readiness assertion pass by the absence of contradiction. Neither failure looks
like a failure — they look like a green suite. So they are tested against
captured output, in the static lane, with no docker involved.

## What phase 8 did to both suites

`docs/notes/80-s6-migration.md` phase 8 deleted `payload/init.d/` and
`payload/anvil-service.sh` and made the boot a compiled s6-rc database. That is
not a refactor the suites can be patched through: a large part of what they
assert no longer exists to be asserted.

**Retired.** `qa/replica/test_services.py` is deleted. It was the port of
`case-services.sh` and its subject was the wrapper contract -- seven `S*`
scripts, each loading a shared library, answering `status`, naming itself, and
rejecting an unknown verb. There are no wrapper scripts. Three of its
assertions survived the move and live in `qa/replica/test_s6rc.py`: the scanner
is the cross-built ELF we shipped, its log is empty, and every `run` in the
scandir is executable. The rest describe a machine that cannot be built any
more.

**Replaced.** The contract that a `run` script is startable and a service comes
up is now asked two ways, and the split is deliberate:

| lane | file | asks |
|---|---|---|
| static | `test_s6rc_source.py` | what the database SAYS -- graph, bundle, timeouts, the generated shebang, and the shell inside each oneshot |
| replica | `test_s6rc.py` | what the printer DOES -- init, one transition, a killed daemon coming back |

The static half needs no docker and runs in about a second, which is where a
boot-order mistake should be caught. It compiles the real source tree with the
native `s6-rc-compile` that `bin/patch.sh` section 5b-2 builds, and reads the
answers back out with `s6-rc-db` -- never out of the source tree, because the
compiler is free to reject, rewrite, or silently drop what it was given.
`down` is the one that bit us: `s6-rc-compile` accepts a `down` file in a
definition directory and discards it, producing a byte-identical servicedir.

### The gates phase 8 killed have been retired

These `case-*.sh` asserted deleted architecture -- they drove `$MODDIR/init.d/S*`
or sourced `anvil-service.sh`, neither of which exists. The decision was made
against real output, not against a reading of the scripts:

```
make test-services  ->  FAIL  the payload ships no anvil-service.sh -- every service aborts
make test-nginx     ->  FAIL  the payload has no etc/s6/nginx/ -- nothing to supervise
                        cp: can't stat '/tmp/payload/anvil-service.sh'
```

| retired | lines | asserted | where that lives now |
|---|---|---|---|
| `case-services.sh` | 360 | the seven-script wrapper contract, `force-start` | nowhere -- the contract is deleted |
| `case-nginx.sh` | 416 | the `MOD_S6=0` unsupervised fallback | nowhere -- the fallback and the flag are deleted |
| `case-moonraker.sh` | 1,059 | the same fallback, plus `S62moonraker` | nowhere |
| `case-moonraker313-s6.sh` | 708 | Moonraker on 3.13 started by `S62moonraker` | needs a port once the replica can boot |
| `case-camera.sh` | 467 | `S40s6` and `S65camera` verbs | the readiness question survives; see below |
| `case-priority.sh` | 108 | `svc_start_daemon` niceness | unasserted; the surviving path is `-N` inside `etc/s6-rc/source/klipper/run` |

Retired in the same pass, for a different reason -- **no gate, no Makefile
target, no CI step, never run once**: `case-pyext.sh` (567) and
`case-moonraker313.sh` (487). Both were phase-6 spikes whose questions are
settled. A file that looks like coverage and is not is worse than no file.

With them went `gates.py`'s `services`, `camera`, `nginx`, `moonraker` and
`moonraker313_s6` (and `_prefix_tarball` / `_moonraker_tarball`, which nothing
else used), their `run-tests.py` calls, six `make test-*` targets, and
`sim-moonraker313.py`. About 4,200 lines of shell; the old suite's 13
replica bits are 8.

**Two of the three assertions they owned were carried across**, into
`qa/replica/test_web.py`: nginx coming back from a kill and staying stopped
after a deliberate stop, and Moonraker answering on `:7125` on the cross-built
3.13 rather than FlashForge's 3.8.2. Seven named tests where `case-nginx.sh`
and `case-moonraker313-s6.sh` were 1,124 lines and two bits.

That module brings up **only nginx and moonraker** rather than running the
whole boot, for the reason in the next section, and it says so in its header.
Bringing up a subset is a departure from *run the real boot, do not
reimplement it*; it goes through the same compiled database and the same
s6-rc, so only the transition's argument differs, and the alternative was
asserting nothing about supervision until somebody builds the MCU lane.

The third -- `s6-svwait -U` readiness gating rather than meaning "forked",
which `case-camera.sh` asked -- is still owed, and cannot be asked here: the
camera service needs a `/dev/video*` the replica has not got.

### case-install.sh was stale, not dead -- and it was the one that mattered

It was the last gate to go red, and the sweep above missed it because its stale
assertions name the wrapper scripts WITHOUT the `init.d/` prefix, so the grep
that classified every other case did not catch them. Its subject -- the
printer's own `app_startup.sh` installing a real package off a real FAT
filesystem -- was entirely alive, so it was **ported, not retired**:

| was | now, in `qa/replica/test_install.py` |
|---|---|
| `grep -q helix` on `firmwareExe` -- the wrapper launched the UI itself | the wrapper starts `s6-svscan` and asks `s6-rc` for a transition; the UI is a service in the compiled database |
| `[ -d $MODDIR/init.d ]`, else "no service dir exists to start Klipper" | `s6-rc-db list services` names `klipper`, and `s6-rc-db dependencies klipper` names `mcu-bringup` |
| `S60nginx S62moonraker S70klipper S80ui` each appear in the boot log | **not** replaced by a grep for the new names -- see below |

That last row is the one to be careful about. The boot log line reads
`s6-rc: bringing up: camera klipper moonraker nginx ui ff-startup wifi` and
names every service in the boot set INCLUDING THE ONES THAT THEN FAIL, so
grepping it for a service name yields an assertion that passes on a machine
where that service never started -- green, and unable to go red. The compiled
database is asked instead, which is a fact about what was installed rather than
an intention.

Most of the 579 lines were DRIVING the install -- attach the stick, run
app_startup.sh, wait, repeat. None of that survives, because the `printer`
fixture already is the result. What is left is the part that was always the
point: the assertions.

Two of its three boots could not come across. The re-install (boot 2) needs a
second package on a stick and the bake deletes `/stick.img` once the install
lands -- but the property it existed for, *an update keeps what the user edited
and drops only what the last package shipped*, is asserted directly in
`test_upgrade.py`. Boot 3's UI liveness needs `ok-all`, which is unreachable
on a replica; its no-stick half -- app_startup.sh must not go looking for an
update that is not there -- did come across, since the baked machine IS the
stick-pulled case.

### What was stale in the pytest half

`test_startup.py` built its `argparse.Namespace` by hand and had not been
taught `--only-bringup` / `--no-bringup`, so **43 of its tests failed with
`AttributeError` inside `run()`** -- the legacy suite was already red on this
branch. Its `FakeKlipper` also still modelled `start.sh` plus a separate
`stop`; klipper is restarted with one `s6-svc -wr -t` on its live servicedir
now, so the fake models that instead and `FF_SKIP_MCU_BRINGUP` -- recorded but
never asserted -- is gone. `test/` pytest is green again: 185 passed, 1 skipped.

`run-tests.py`'s shell globs had rotted the other way, and this one had teeth:
`pkgs/*/prog/*.sh` and `pkgs/*/prog/firmwareExe` matched **nothing**, because
`prog/` moved under `payload/`. `firmwareExe` -- the boot -- and `start.sh` were
being syntax-checked and bashism-checked by nothing at all. `check_shell_syntax`
guards only the union of its patterns, so it stayed green while covering less
than it claimed. `qa/static/test_shell_syntax.py` had the paths right already
and refuses any glob that matches nothing, which is the discipline that would
have caught it.

## What is left

Nothing. `test/run-tests.py` and `test/ffsim/report.py` are **deleted**, and
with them the JUnit-XML round trip that turned 185 pytest results into one
gate. `make test` is gone; `make qa` is the suite.

Three gates were dropped rather than ported, as a coverage decision:

| dropped | was | consequence |
|---|---|---|
| the pytest gate | `run-tests.py` ran pytest and re-parsed its XML | none -- `make test-py` and CI run pytest directly |
| the rootfs extraction | ran `unpack.sh` + `extract_rootfs` inline | none -- `make rootfs` does exactly this, and the replica lane already fails with that command in the message |
| **the packaging build on a synthetic stock package** | `make-stock-fixture.sh`, then `unpack`/`patch`/`pack`/`verify.sh` | **real: `bin/unpack.sh`, `patch.sh`, `pack.sh` and `verify.sh` now have no test at all** |

That last row is the one to be uneasy about, and it is recorded here rather
than buried in a commit message. The build path is what produces the `.tgz` a
user flashes, and nothing exercises it end to end any more.
`qa/static/test_ipk.py` covers package *building* -- the `.ipk` layout, the ABI
string, reproducibility -- but nothing runs the outer build. The CI job with no
firmware has lost most of its content as a result.

`test/integration/make-stock-fixture.sh` is deliberately **kept**. It is the
input a replacement needs -- a synthetic FlashForge package built from the
`versions.env` pins, so the build can be tested with no proprietary firmware --
and it is a fixture generator rather than a gate, so it is not a file
pretending to be coverage. Whoever ports this should note that
`make_fixture` staged into `work/.fixture` INSIDE the repo on purpose: sibling
containers resolve their mounts host-side, so a path under the build
container's `/tmp` does not exist as far as the daemon is concerned.

### What survives in test/

- **`test/integration/test_*.py`** -- 185 host-side tests. Already pytest, and
  adoptable by pointing `qa/` at them whenever that seems worth doing.
- **`test/ffsim/`** -- 678 lines, down from 1,657, and no longer a test
  framework. `extract_rootfs` is what `make rootfs` runs; `Replica` and the
  python-tarball helper are what `make boot-screen-sim` uses to render the boot
  frames with the cross-built interpreter.
- **`test/integration/printer/`** -- the `Dockerfile`, `entrypoint.sh`,
  `assemble.sh`, `binfmt.sh` and `seed-prog.sh` that BUILD the replica. `qa/`
  uses them unmodified; they were never the problem.
- **`test/test-chelper.py`** -- in neither suite. `bin/patch.sh` and
  `bin/verify.sh` call it directly at build time.

### Still owed

- **The build path**, above. The largest gap.
- **The rollback**, `case-recovery.sh`'s subject: install the mod, flash the
  stock package, be back byte-for-byte. Retired without a replacement.
- **`s6-svwait -U` readiness on the shipped camera definition**: the service
  needs a `/dev/video*` the replica has not got. `test_supervisor.py` asks the
  same question of a service it builds itself, which is close but not the same.
- **The MCU lane**, which would unblock the eight `test_s6rc.py` tests and let
  `test_install.py` assert a booted machine rather than an installed one.

## One thing found on the way

**`case-mcu-bringup.sh:4` says the handshake is "tested elsewhere against a
pty".** There is no pty anywhere in the repo. `test_ff_mcu_bringup.py` checks
the port tuple and the every-port-fails path, and its own comment concedes it.
Every documented past bug in `ff_mcu_bringup.py` lived in the code that comment
excuses from testing — and the missing `/dev/ttyS*` is now also what stops the
replica booting, so one lane would close both.

## Not in scope

A third lane — real klippy in batch mode against a simulated MCU — would close
the gap `docs/testing.md` names: *"the replica cannot, because it never starts
klippy."* The fork already ships the machinery (`scripts/test_klippy.py`,
klippy's `-i/-o/-d` batch mode) unused. It is a separate bet with its own
unknown (an MCU data dictionary for four MCUs, with no hardware to capture one
from), and it was deliberately left out so this change has one variable.

Note for whoever picks it up: `work/klipper-fork/klippy/chelper/c_helper.so` is
a **MIPS** binary. Host klippy cannot load it. Extract the fork tarball to a
separate tree and let klippy build the host one there; never build it inside
`work/klipper-fork`, whose artifact is a gated build output.
