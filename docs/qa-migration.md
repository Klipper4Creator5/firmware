# The qa suite, and what it replaces

`qa/` is a second test suite, built beside `test/` rather than inside it. Both
run in CI. `test/` is still the release gate. Nothing has been deleted.

This document says why it exists, what is proven so far, and the rule for
moving the rest.

## The problem it is answering

Three complaints, one cause.

**Two frameworks.** `test/run-tests.py` and `test/ffsim/` are 1,657 lines that
reimplement what pytest already does — skip accounting, gating, reporting, and
then parsing pytest's own JUnit XML back out — and they invoke pytest as gate
#5 of about twenty.

**Assertions in the wrong language.** `test/integration/printer/case-*.sh` is
6,280 lines of POSIX sh executing inside a qemu chroot, and between them they
report **13 boolean bits**. `case-moonraker.sh` is 1,059 lines that collapse to
one pass/fail. A failure tells you a case went wrong, not which of its forty
assertions did.

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
`payload/*.sh` and `pkgs/anvil-core/payload/init.d/S*` into `$MODDIR` by hand — the same shape
`case-services.sh` uses today. Two things are wrong with it:

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
it. "I could not find the tool" does not. **There are currently no skips in this
suite**, and that is the honest state rather than a target.

## What is proven so far

| Ported | From | Was | Is |
|---|---|---|---|
| `qa/static/test_shell_syntax.py` | `run-tests.py`'s `check_shell_syntax`, `check_no_bashisms`, `check_undefined_names` | 3 gates over ~40 files | 69 named tests |
| `qa/replica/test_services.py` | `case-services.sh` (360 lines) | 1 bit | 44 named tests |
| `qa/static/test_probes.py` | new | — | 18 tests of the harness's own parsers |

`test_services.py` is *shorter* than the case script it replaces despite
reporting 44 results instead of one, because installing for real deleted the
payload-copying, the stand-in `s6-svscan`, the stand-in `s6-svscanctl` and the
branching that asked which of them was in use.

Measured on `monstrofil/creator5-printer:latest`, both suites agreeing on the
same machine:

| | |
|---|---|
| whole qa suite (131 tests) | **44s**, all green, no skips |
| `qa/static` alone | 1.3s, no docker |
| `qa/replica` alone (44 tests) | 40s |
| one assertion by node id | **2.9s** |
| baking the installed image | once per package, then a cache hit |

That last row is the point of the exercise. The equivalent in the old suite is
`make test-services`: the whole 360-line case, all or nothing, and a log to read
afterwards.

Checked by injecting a real regression — deleting `SVC_EXTRA_VERBS="|force-start"`
from `pkgs/anvil-core/payload/init.d/S70klipper`, which is the drift `case-services.sh` was
written to catch. One named test failed
(`test_klipper_advertises_force_start`), the assertion printed the usage line
that actually came back, the other 41 still reported, and re-running just that
test took 4s.

`test_probes.py` has no counterpart in the old suite and is worth explaining:
`Printer.ps()` and `Printer.listening()` are parsers, and a parser is where a
harness goes quietly wrong. A `listening()` that never matches makes every
readiness assertion pass by the absence of contradiction. Neither failure looks
like a failure — they look like a green suite. So they are tested against
captured output, in the static lane, with no docker involved.

## Moving the rest

**A `case-*.sh` is deleted only when its replacement here has been green in the
`printer-sim` job.** Until then both run and both assert the same things. There
is never a window where coverage drops.

Order, by payoff:

`services` (done) → `priority` → `nginx` → `libpath` → `camera` → `upgrade` →
`supervisor` → `python` → `moonraker` → `moonraker313` → `install` →
`roundtrip`

When the last one moves, `test/run-tests.py` and `test/ffsim/` are deleted.
`test/integration/printer/`'s setup scripts stay — they were never the problem.

The pytest files already in `test/integration/` (`test_startup.py`,
`test_ffscreen.py`, `test_tool_transform.py` and the rest) are **not** part of
this. They are already pytest, already well-seamed, and moving them would be
churn for its own sake. They can be adopted by pointing `qa/` at them, or left
where they are.

## Two things found on the way

- **`test/integration/printer/case-pyext.sh` is orphaned.** 567 lines, no gate
  in `gates.py`, no Makefile target, no CI step. It has never run. Wire it up
  or delete it — either is better than a file that looks like coverage.
- **`case-mcu-bringup.sh:4` says the handshake is "tested elsewhere against a
  pty".** There is no pty anywhere in the repo. `test_ff_mcu_bringup.py` checks
  the port tuple and the every-port-fails path, and its own comment concedes it.
  Every documented past bug in `ff_mcu_bringup.py` lived in the code that
  comment excuses from testing.

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
