# Testing: how we know it does not brick

Everything lives in `test/integration`, and `test/run-tests.py` runs it. There
is still a real seam inside it, though — what needs the proprietary firmware
and what does not — and it is worth knowing which side of that seam a failure
is on.

**Without firmware.** A synthetic fixture
(`test/integration/make-stock-fixture.sh`) reproduces the package *structure*,
so shell syntax, the bashism pass, the pytest config gate and the whole
packaging pipeline run in CI on a clean machine. This is the half that catches
a chamber heater declared on a machine
that has no element for it — the replica cannot, because it never starts
klippy.

These used to live in a directory of their own, `test/unit`. The split was
there so a plain pull request had something to run; this repo has one
maintainer who always has the firmware to hand, so it was a boundary being
maintained for a contributor who never arrived. The tests moved rather than
went away.

**With firmware — the printer replica.** The real
`rootfs.squashfs`, extracted from
the stock package, chrooted under `qemu-mipsel`, with `/usr/prog` installed by
FlashForge's own updater. The installer under test runs on the printer's
busybox, tar, md5sum and `unTar` — not on Debian stand-ins — with a read-only
root and writable prog/data partitions, exactly like the machine, and the
package reaches it the way it reaches a real printer: on a FAT filesystem that
the machine's own boot script finds and mounts. This is the
half that can catch a brick, it needs the stock package, and
`.github/workflows/release.yml` refuses to publish without it.

With `PROG_DUMP` (in `test.env`) pointed at a factory image, the replica has
essentially nothing invented left: the klipper daemons, `nginx`, `python3`,
`moonraker` and the printer's **own OpenSSL 1.0.2d** are all genuine, so
package decryption is verified against the real implementation. What remains
substituted is `insmod`/`reboot`/`cmd_mcu`, neutered because they would act on
the host kernel or real hardware, and the partition sizes.

See **[printer-replica.md](printer-replica.md)** for what is authentic, what
is stubbed, and what it still cannot tell you.

## The tests

```sh
make test            # the gates below, and more besides
```

`make test` does not invoke these targets: `test/run-tests.py` re-implements
the work inline, and adds three things the table has no row for — a shell
syntax parse, a `shellcheck -s dash` bashism pass over the on-printer payload,
and a full unpack/patch/pack/verify build on a synthetic stock fixture.

| Gate | What it does | Replica |
|---|---|:-:|
| `test-py` | pytest, the whole `test/` tree — 53 tests in six files (five of them skip until `make rootfs` has run). The Klipper config gate (`test_chamber.py`): every `ff-*.cfg` gcode body parses in **Klipper's** Jinja dialect, and the chamber macros are rendered per model to prove a chamber target is refused on a Creator 5 that has no heating element. Plus `test_paths.py` (every absolute path the payload names exists on the printer, once a rootfs has been extracted), `test_includes.py` (the `[include ff-*.cfg]` block is exactly the expected set, in order), `test_config_ownership.py` (every mod-owned config carries its DO-NOT-EDIT banner and `moonraker.conf` does not), `test_gcode.py` (every command in `gcode/*.gcode` is one our configs define) and `test_harness.py` (the harness's own self-checks) | partly |
| `test-install` | **End-to-end.** The package sits on a real FAT filesystem exposed as `/dev/sda1`, and the machine's own `app_startup.sh` runs verbatim through three boots: stick in -> it installs; stick still in -> it installs again (idempotence); stick pulled -> the machine boots with the mod running and the stock `ps`-watchdog satisfied. Asserts along the way: UI present and executable, boot scripts unmodified and still parsing, every installed script `sh -n`-clean under the printer's own busybox, Klipper owned by a service, `c_helper.so` still nan2008 MIPS, user `printer.cfg` preserved, the wrapper unchanged by a re-install | yes |
| `test-mcu` | Runs `ff-mcu-bringup.py` on the printer's **own** Python 3.8.2 in the exact environment `start.sh` sets — the only gate that executes our Python on the real interpreter, and the one that pins the `LD_LIBRARY_PATH` regression that shipped broken once | yes |
| `test-recovery` | Installs the mod, then flashes the **stock** package, and asserts the machine is genuinely back to stock byte-for-byte and the leftover payload is inert | yes |

Few entry points, deliberately. `test-install` boots the machine, so it independently
covers what `verify.sh` checks, parses every installed script with the same
busybox that `test-ash` used, and reads `c_helper.so`'s ELF header the way
`test-abi` did — the separate checks were the weaker copies.

The replica gates need `make rootfs` first, which extracts the printer's
genuine root filesystem from the stock package's `kernel-*.tar.xz`. It is
never committed — it is FlashForge's firmware. `make test` skips the replica
half with a loud message when no stock package is configured;
`REQUIRE_PRINTER_SIM=1` turns that skip into a failure.

**A skip is not a pass.** `run-tests.py` counts skips separately and exits
non-zero if any gate did not run. This matters more the fewer gates there are
— and it is not hypothetical, see `test-abi` below.

Accepting a gap is deliberate and has two forms:

```sh
ALLOW_SKIP=1                              accept any gate that did not run
ALLOW_SKIP="pytest,the printer replica"   accept exactly these
```

Use the named form anywhere the setting outlives the moment — CI does. `1` is
a standing promise never to notice a skip again: put it in a workflow and a
replica gate that starts skipping on a machine that has the firmware is
accepted in silence, forever. The named form fails on anything else.

Either way **every skip is listed again in the summary, with its reason and
whether it was accepted**, and under GitHub Actions each becomes an
annotation. Nobody reads a green job's log, so a gap that exists only in
stdout is a gap accepted invisibly — which is the failure this whole harness
is built around. The pytest gate names the individual tests that skipped
rather than reporting a count.

<a name="why-the-harness-is-python"></a>
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
result. `test/integration/printer/bake.sh` is the part that cannot be a `docker build`
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
  caught. It now runs the boot script.
- **The release workflow's final `sim-install` loop** ignored the exit status
  of every run, so the last gate before publishing could not fail. It now
  stops on the first failure and runs with `REQUIRE_PRINTER_SIM=1`, which
  turns a skip into a failure too.
- **`test-printer-db`, all of it.** It began as a re-implementation of
  PrinterDetector's scoring formula, mirroring `printer_detector.cpp` line for
  line, so a change to the HelixScreen fork's formula left the test passing
  while reality moved. Narrowing it to scoring-independent invariants kept it
  honest but not useful enough to earn its place, and the whole check is gone.
- **The hand-rolled bashism grep in `run-tests.sh`.** It knew five constructs;
  `shellcheck -s dash` knows the whole SC3xxx family and now stands in its
  place. The same pass gave every replica launcher one shared home for the
  docker plumbing — now `test/ffsim/replica.py` — which also fixed two `make
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
    and `test-install` reads the ELF header of the file that actually landed.
  - `test-macros` used `jinja2.Environment()` — the default `{{ }}` syntax.
    The configs contain **no** `{{` at all, only single-brace expressions, so
    it validated `{% %}` block structure and never once looked inside an
    expression. `test_default_delimiters_are_blind` now pins that.
  - `test-ash-conformance` parsed the payload with the printer's busybox;
    `test-install` runs `sh -n` over every *installed* script with the same
    qemu'd busybox and then greps the boot log for `Syntax error`.
  - `test-model-gate` checked what `verify.sh` §8b/§9 checks and what
    `pack.sh` already refuses to build. Its header claimed it proved the two
    models ship different files; no such check existed in it.
  - `test-base-cfg` compared our `printer.base.cfg` against
    `work/software/.../printer.base.cfg` — which `bin/patch.sh` overwrites
    *with our own file* before the test reads it. It had been diffing our file
    against itself: green on a cold tree, red on a second `make test`, and
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
