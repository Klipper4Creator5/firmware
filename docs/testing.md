# Testing: how we know it does not brick

**`qa/` is the suite.** One framework (pytest), two lanes, and a result per
assertion rather than per case script.

```sh
make qa            # both lanes
make qa-static     # seconds, any machine, any clone -- no docker
make qa-replica    # the gates that decide whether a package bricks a printer
```

Selection is pytest's: `-k nginx`, `-m static`, or a single test id.
[qa-migration.md](qa-migration.md) is the design and the history.

## The lanes

| Lane | Needs | What it asks |
|---|---|---|
| `static` | nothing but the checkout | every shipped script parses and is free of bashisms, every name resolves, the recipe layout holds, and the `.ipk`s are what we mean to ship |
| `replica` | docker + qemu + the firmware | what the printer *does* -- on a machine the real `app_startup.sh` installed the real package onto |

The replica lane needs a built package in `work/out/*.tgz` (`make build`) and a
base image: put `PRINTER_IMAGE` in `test.env`, or let it build one from
`work/rootfs` after `make rootfs`. The install is baked into an image once per
package, keyed on the package's md5, so rebuilding gets you a fresh bake and
not yesterday's.

### The replica lane, module by module

| module | asks |
|---|---|
| `test_install.py` | what the machine's own installer produced: the stock boot chain is untouched and still parses, the wrapper is installed and starts the supervisor, every installed script is `sh -n`-clean under the printer's own busybox, `c_helper.so` is still nan2008 MIPS, klipper and the UI are services in the compiled database, klipper depends on the bring-up, the config include set is wired up, the user's `printer.cfg` survived, a pristine `backup/stock` was kept, and a boot with no stick does not go looking for an update |
| `test_upgrade.py` | an update deletes what the last package shipped and **only** that -- the user's edits, their `moonraker-custom.conf`, their HelixScreen settings and anything nobody shipped all survive, over both the manifest path and the pre-manifest sweep |
| `test_supervisor.py` | the s6 we cross-compiled: all 13 binaries load on the printer's kernel, and `s6-svwait -U` really waits for readiness rather than returning on the fork |
| `test_boot_screen.py` | the first-boot screen renders on our own CPython 3.13, one screen's worth of correctly packed bytes, and degrades to "no screen" rather than raising when there is no panel |
| `test_web.py` | nginx and moonraker come up under s6, nginx comes back from a kill and stays down after a stop, and moonraker serves on `:7125` on our interpreter |
| `test_s6rc.py` | the boot itself -- the scanner answers, `s6-rc-init` lays the scandir down, a killed daemon comes back |
| `test_mcu_bringup.py` | `ff_mcu_bringup.py` runs on `FF_PYTHON` in the shipped environment and names every port it could not open |

**Eight of `test_s6rc.py`'s twelve cannot pass on a replica**, and that is
hardware, not a bug: there are no `/dev/ttyS4,5,7` and no `/dev/video*`, so
klippy never connects, `camera` times out, and the `ok-all` bundle is
unreachable. See [qa-migration.md](qa-migration.md). Everything else is green.

## What is left in `test/`

`test/run-tests.py` is **gone**, and `make test` with it. What remains is not a
suite -- it is 28 host-side unit tests over our own Python, which need neither
docker nor the firmware:

```sh
make test-py   # 28 tests, well under a second
```

| file | tests | what it is for |
|---|---|---|
| `test_startup.py` | 8 | the stamp discipline in `ff-startup.py`: no stamp is written unless the values are verifiably saved, because a stamp written early is a printer that has silently lost its factory calibration for good. Plus the handover order -- the boards, then klipper, again on every retry |
| `test_tool_transform.py` | 7 | the per-tool frame arithmetic in `ff_toolchange`, whose failures are a nozzle in the wrong place |
| `test_ffscreen.py` | 5 | restraint: never write outside the framebuffer, never guess at a pixel format, never raise into the migration it decorates |
| `test_chamber.py` | 4 | the chamber macros branching on the model, whose failures are silent until they have cost a print |
| `test_gcode.py` | 4 | the two `gcode/` files name commands we ship, and the safe one is cold and stays above its floor |

This was 186 tests in twelve files as recently as the qa migration. The cut to
28 was deliberate and is recorded in
[qa-migration.md](qa-migration.md#the-second-cut): what went was everything
whose subject had become the fake it was built on, or whose failure the printer
reports loudly the first time. What is kept is the mistakes that RUN
PERFECTLY and are wrong.

`test/test-chelper.py` sits outside both suites: `pkgs/klipper/build.sh` and
`bin/verify.sh` call it directly at build time.

## The replica is a tool, not a test

`tools/replica/` builds the machine both suites run against, and the build
uses it too -- `bin/patch.sh` assembles the payload by running the printer's
own `opkg` inside it. It is not under `test/` because nothing in it is a test:

```
tools/replica/
  printer/                  the replica itself: the Dockerfile, binfmt.sh,
                            assemble.sh, entrypoint.sh, seed-prog.sh, bake.sh
  ffsim/                    the host half -- config loading and the docker
                            plumbing. NOT a test framework; it was one, and
                            what is left of it launches containers
  build-printer-image.sh    bakes a prebuilt replica image
  extract-rootfs.py         `make rootfs`
  sim-boot-screen.py        `make boot-screen-sim`
```

`qa/lib/replica.py` drives `tools/replica/printer/` unmodified; it holds a
container open where `ffsim` runs one case script and exits.

## Why the harness is Python

The host half of the harness — the orchestrator and the replica launchers —
was shell until August 2026. It moved to Python for one specific reason, and
it is worth stating because the rule it enforces is the one above.

In the shell suite, "this gate did not run" travelled between processes as the
string `SKIP:` on stdout, and the runner decided by grepping for it:

```sh
if "$@" >"$out" 2>&1; then
    if grep -qE '^[[:space:]]*SKIP:|[0-9]+ skipped' "$out"
    then skip "$name"; else pass "$name"; fi
```

Text on stdout cannot tell you what happened inside a process. A launcher that
had **already failed** would reach the same line by a different road: the file
that sources `config.env` failed to load, so `STOCK_TGZ_*` was never set, so
the launcher concluded there was nothing to test, printed those five
characters and exited 0 — on a machine with docker and the firmware sitting
right there. That is not a hypothetical; it is how five broken launchers
shipped and stayed broken.

What changed:

- **A skip is an exception** (`ffsim.Skip`), not a string. Output cannot
  imitate it, and a gate that fails cannot accidentally claim it was skipped.
- **The repo root is found by searching** upward for `bin/common.sh`, not by
  counting `..` from `$0`. Moving a launcher to a different depth used to
  break it silently; now it cannot.
- **A broken config is not an absent one.** Sourcing a file with a syntax
  error returns non-zero and does *not* stop the shell, so the old code
  carried on with half a config. `ffsim.config` checks each source and names
  the file that failed.
- **pytest results are read from JUnit XML**, not from grepping `N skipped`.
- **The suite calls the gates as functions.** There is no subprocess between a
  gate and the thing counting results, so there is no format to agree on.

The four things that used to be reported as skips and are now failures:
a `config.env` that does not parse, a missing case script, a missing package,
and a missing baseline. A genuinely absent precondition — no docker, no stock
package — is still a skip, because that is still the truth.

## Speed

Almost all of a replica run used to be setup, repeated per test case:

| | per run |
|---|---|
| unpack the 182MB factory image into `/usr/prog` | 22s |
| install the stock package into it, under qemu | 37s |
| **the test itself** (three boots, install, re-install) | ~30s |

`make printer-image` does both of those once, at build time, and publishes the
result. `tools/replica/printer/bake.sh` is the part that cannot be a `docker build`
step — the stock install needs `binfmt_misc` and `chroot`, so it runs in a
privileged container and the result is committed. The md5 of the package that
was installed is recorded in `/usr/prog/.BASELINE`; `entrypoint.sh` reinstalls
only if a run asks for a different one.

With `PRINTER_IMAGE` set in `test.env`, a replica starts in **0.7s** and the
whole end-to-end update test takes **~70s**. Without it, the same test spends
a minute on setup before it begins. That image contains proprietary FlashForge
firmware.

`run-tests.py` stamps every header with elapsed seconds, so a run says for
itself where the time went. The headers, in the order they are printed:

```
== shell syntax ==
== no bashisms in the on-printer payload ==
== extracting the printer rootfs ==            (skipped if already extracted)
== python checks ==
== packaging, on a synthetic stock package ==
== build on the fixture ==
== printer replica ==                          (or: MCU bring-up runs on the
                                                printer's own Python)
== end-to-end update on the printer replica ==
== recovery: a stock package reverts the mod ==
```

What takes the time is real work: two full package builds (the payload is
55MB through `xz`) and two replica runs. If it needs to get faster again,
that is where to look — not in the harness.

## What was dropped, and why

Tests that cannot fail are worse than no tests, because they read as coverage:

- **`test-abi`'s execution half.** It was `qemu "$f" -h || [ $? -lt 126 ]`,
  which accepts nearly every exit status — it could only fail if qemu itself
  was missing. Running the binaries for real is what the replica does.
- **`test-ash`'s `md5sum -s` probe.** It printed "inconclusive" on every path
  and could not fail.
- **The per-file `sh -n` "POSIX" loop in `run-tests.sh`.** `sh` is bash on the
  build image, so it proved nothing that `test-ash` does not prove properly
  with the printer's own busybox. Its bashism grep also flagged `local`, which
  busybox ash supports.
- **`test-install`'s hand-written replay of `app_startup.sh`.** It re-derived
  the glob, `MACHINE` and `PID` with `sed` and then called the installer
  itself — so a mistake in our reading of the boot script could never be
  caught. The replica now runs the boot script itself, and
  `qa/replica/test_install.py` asserts against what it produced.
- **The release workflow's final `sim-install` loop** ignored the exit status
  of every run, so the last gate before publishing could not fail. It stops on
  the first failure now, and it is `REAL_PKG=<pkg> pytest ./qa/replica` per
  model -- 22 named results for each package that ships, where the loop gave
  one exit code it was throwing away.
- **`test-printer-db`, all of it.** It began as a re-implementation of
  PrinterDetector's scoring formula, mirroring `printer_detector.cpp` line for
  line, so a change to the HelixScreen fork's formula left the test passing
  while reality moved. Narrowing it to scoring-independent invariants kept it
  honest but not useful enough to earn its place, and the whole check is gone.
- **The hand-rolled bashism grep in `run-tests.sh`.** It knew five constructs;
  `shellcheck -s dash` knows the whole SC3xxx family and now stands in its
  place. The same pass gave every replica launcher one shared home for the
  docker plumbing — now `tools/replica/ffsim/replica.py` — which also fixed two `make
  test-ash` bugs: it ran without the docker socket (so it always silently
  skipped), and it never read `test.env`, so it ignored `PRINTER_IMAGE` and
  rebuilt the local sim image every run.

- **Eight checks, in one pass, once each had been read properly.** The suite
  had grown to twelve gates and most of them were the weaker copy of a gate
  that survives:
  - `test-abi` had **never asserted anything in CI**. `run-tests.sh` deleted
    `work/modpayload` immediately before it ran and CI set `KLIPPER_FORK=""`,
    so it had no targets on any run, skipped, exited 0 and was printed as
    `ok`. `bin/patch.sh` refuses to build a non-nan2008 `c_helper.so` anyway,
    and `qa/replica/test_install.py` reads the ELF header of the file that
    actually landed.
  - `test-macros` used `jinja2.Environment()` — the default `{{ }}` syntax.
    The configs contain **no** `{{` at all, only single-brace expressions, so
    it validated `{% %}` block structure and never once looked inside an
    expression. `test_default_delimiters_are_blind` now pins that.
  - `test-ash-conformance` parsed the payload with the printer's busybox;
    `qa/replica/test_install.py` runs `sh -n` over every *installed* script
    with the same qemu'd busybox.
  - `test-model-gate` checked what `verify.sh` §8b/§9 checks and what
    `pack.sh` already refuses to build. Its header claimed it proved the two
    models ship different files; no such check existed in it.
  - `test-base-cfg` compared our `printer.base.cfg` against
    `work/software/.../printer.base.cfg` — which `bin/patch.sh` overwrites
    *with our own file* before the test reads it. It had been diffing our file
    against itself: green on a cold tree, red on a second build, and
    blind to real drift either way. The comparison moved into `bin/unpack.sh`,
    where a pristine stock tree actually exists.
  - `test-applets`' command-word scan only extracted the first word of a
    simple, unprefixed command: `if timeout 5 foo; then` yielded
    `['if','echo','fi']`, so the one failure its docstring named was invisible
    to it. Its allowlist had drifted to nine entries that excused nothing. The
    absolute-path half survives, because `S50wifi`'s binaries sit on a branch
    no simulation reaches.
  - `lint-danger`'s structural greps were satisfiable by comments — the
    comments in `firmwareExe` and `S80ui` *mention* `helix` and (at the time)
    `SAFE-MODE`, so the checks passed with the logic deleted.
  - `case-ui` went with the helix-only decision.

## Bugs these caught

Not theoretical. Writing them caught real bugs before any hardware was
involved:

- backups were taken *after* the stock `run.sh` had already overwritten the
  files, so a restore would have restored the modified versions
- `rm -rf $MODDIR/bin` with an unset `MODDIR` expands to `rm -rf /bin`
- a crashed UI is a *zombie*, and `kill -0` succeeds on a zombie — the crash
  detector called a dead UI healthy
- the packer emitted both models' filenames from one build, which would have
  handed a Creator 5 the Pro's firmware
- three checks in the brick lint had been quietly dead for months: two were
  guarded on a `payload/boot.sh` that no longer existed, and the file glob
  never matched `firmwareExe` or the `init.d/S*` scripts at all
- a skip counted as a pass for the whole life of the suite, which is how
  `test-abi` sat in it for months checking nothing while printing green
