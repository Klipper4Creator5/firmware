# Documentation & comment drift audit — RESOLVED

> **Every finding below has been applied.** This file is the record of what was
> wrong and why, not a list of open work. See the audit commits on this branch
> (`git log --oneline master..HEAD`); `make test` is 12/12 green with them in.
>
> Line and commit references inside the sections below were written against the
> tree BEFORE the fixes, so some no longer point where they did. They are kept
> as the record of what was found, not as current citations.
>
> Decisions taken on the items that were not simply wrong prose:
>
> | | |
> |---|---|
> | A1 motion sensors | fixed in config — each `fm_ex*` now watches its own extruder |
> | A2 motion inserts | fixed in config — `_FF_INSERT` gained its motion branch |
> | A3 `TOOL=ALL` staging | fixed in code — staged only after every tool validates |
> | A4 plate check | kept one-sided (a plate can only read high); documented |
> | A5 `make test` timing | figure dropped rather than re-measured |
> | A6 gate count | number dropped from docs and Makefile |
> | A7 `initial_WHITE` | removed from `printer.base.cfg`; `ff-chamber.cfg` alone sets it, so the file is FlashForge's again and the drift check is quiet |
> | A8 SAFE-MODE | **removed entirely**, not repaired — it never worked. Replaced by `MOD_UI` in `anvil.conf`, which stops the UI starting but does not pretend to repair one |



Six read-only agents checked every `.md`, every config comment block and every
docstring in the repo against the code as ground truth. ~140 findings.

`docs/notes/*` are reverse-engineering notes about FlashForge's stock
`firmwareExe`, which is not in this repo. Claims about stock internals are
marked UNVERIFIABLE and are **not** proposed for change. Everything below is a
claim about something this repo actually ships.

Each item below carries the proposed fix as it was written at the time.

---

## A. Decisions needed — these change behaviour, not prose

### A1. All four motion sensors watch extruder0
`fm_ex0..3` in the stock `printer.filament.cfg` each carry `extruder: extruder`.
`ff-runout.cfg` never overrides it, so a clog on T1/T2/T3 is detected against
**T0's** filament movement. `docs/notes/49:9` documents them as
`extruder1/2/3`.

* **Fix A** — add `extruder: extruder1|2|3` overrides for `fm_ex1..3` in
  `ff-runout.cfg`. Makes the code match the doc and makes per-tool clog
  detection actually work. Untested on hardware.
* **Fix B** — correct `docs/notes/49:9` to record the real wiring and add a
  known-limitation note in `ff-runout.cfg`.

### A2. `_FF_INSERT` silently ignores motion-sensor events
The whole body is wrapped in `{% if kind == 'switch' %}`, yet
`insert_gcode: _FF_INSERT TOOL=n KIND=motion` is wired on all four `fm_ex*`.
A motion insert produces no output at all, while `ff-runout.cfg:152` describes
it as telling the user what to do next.

* **Fix A** — add a `motion` branch that emits an equivalent message.
* **Fix B** — drop the `insert_gcode` from the `fm_ex*` sections and correct
  the comment.

### A3. `TOOL_OFFSET_CALIBRATE TOOL=ALL` is not atomic
`docs/toolchange.md:274` promises a failed validation aborts "with nothing
staged". Per tool that holds, but under `TOOL=ALL` earlier tools are already
staged by `set_nozzle()` before a later tool's gap check raises, so a T2 failure
leaves T0/T1 pending for `SAVE_CONFIG`.

* **Fix A** — collect all tools' results and stage only after every tool
  validates.
* **Fix B** — document the partial-staging behaviour and tell the operator to
  re-run or discard.

### A4. The plate-removed Z check is one-sided
`docs/toolchange.md:222` describes a +/-0.8 mm band; the code is
`if zp > expected + self.plate_z_tolerance`. A probe reading *low* is accepted.

* **Fix A** — make it two-sided.
* **Fix B** — document it as an upper bound only. (A low reading may be
  physically meaningful — plate genuinely absent — so this may be deliberate.)

### A5. `make test` runtime
`docs/testing.md:156` records 5m26s and a `[326s]` stamp. That number is
unverified here. Proposal: run `make test` once and write the measured number
back, or drop the figure.

### A6. "Four gates" vs twelve
`docs/testing.md:56,69` and `Makefile:82` say "four gates, deliberately";
`run-tests.py` emits twelve gate lines. Four is the count of `make test-*`
targets.

* **Fix A** — docs are stale: reword to "four entry points, twelve gates".
* **Fix B** — the four-gate design is intended and the reporting drifted:
  regroup `run-tests.py`'s output into four gates.

### A7. Every unpack now warns on our own edit
`printer.base.cfg:149` says the file is "FlashForge's printer.base.cfg
verbatim", and `bin/unpack.sh` diffs it against each stock package on that
premise. Since `f10d002` added `initial_WHITE: 1.0` at line 159 the warning
`!! printer.base.cfg DIFFERS` fires on **every** unpack, so a real upstream
change would no longer stand out.

* **Fix A** — diff against a stored baseline of our own edits so the warning
  only fires on genuine upstream drift.
* **Fix B** — keep the noise, correct the three comments that claim "verbatim".

### A8. `S80ui` crash-loop latch does not work as described
`S80ui:39-41` says "the UI clears it once it has been alive for a while". The
settle check is `( sleep 90; if [ -s "$CHOICE" ]; then rm -f "$FAILFILE"; fi ) &`
— S80ui deletes its own counter after 90 s, and `.ui-choice` is always non-empty
because line 57 just wrote it (including a verdict of `none`). Nothing checks
whether helix-screen is alive. SAFE-MODE therefore only latches if the box
reboots within 90 s.

* **Fix A** — gate the clear on helix-screen still running.
* **Fix B** — correct the comment to describe the 90-second reboot window.

---

## B. Install instructions that are wrong as written

These are the highest-priority prose fixes: a user following them fails or
breaks their config.

| # | Where | Says | Actually | Proposed fix |
|---|---|---|---|---|
| B1 | `config.env.example:40` | `STOCK_TGZ_CREATOR5=".../Creator5-1.9.7-1.2.9-20260810"` | missing `.tgz`; `unpack.sh:14` fails | append `.tgz` |
| B2 | `config.env.example:2` | "run `./build.sh`" | no such file; it is `make build` | correct to `make build` |
| B3 | six files | `cp klippy-extras/ff_*.py ...`, `klippy-extras/ff_tool.py` etc | no `klippy-extras/` since `0ef9d6b`; it is `payload/klipper/extras/` | rewrite all six paths |
| B4 | `docs/notes/45:58` | `STATION_CALIBRATE` / `TOOL_OFFSET_CALIBRATE TOOL=ALL` | both refused without `PLATE_REMOVED=1` | add the parameter |
| B5 | `docs/notes/45:15,25-29` | `dock_x/dock_y` hand-written into `ff-toolchange.cfg` | forbidden by `ff-toolchange.cfg:47`; breaks `SAVE_CONFIG` | rewrite the storage table |
| B6 | `ff-runout.cfg:40`, `ff-filament.cfg:57`, `ff-toolchange.cfg:52`, `docs/notes/49:90` | "add `[include ...]` to printer.cfg" | `printer.base.cfg:416-422` ships the whole set; following this double-includes | delete the instructions, point at the shipped block |
| B7 | `docs/building.md:93` | "`make vendor`, paste the sha256 it prints" | only prints on `SKIP`; with a stale pin it exits 1. Also `HELIX_FILE` must be bumped with `HELIX_VERSION` | document the `SKIP` step and both variables |
| B8 | `docs/building.md:97`, `bin/common.sh:45`, `config.env.example:59` | explicit `MAINSAIL_ZIP`/`HELIX_TGZ` "used as-is, never checksummed" | it *is* checksummed and the user's file is **overwritten** with the pinned release | correct all three; consider a genuine no-fetch escape hatch (decision) |
| B9 | `bin/unpack.sh:4`, `pack.sh:4`, `verify.sh:3`, `patch.sh:263` | `./pack.sh` etc | they live in `bin/` and `cd` to repo root | prefix `bin/` |

---

## C. Self-contradictions — the same file states it correctly elsewhere

Mechanical; low risk. Proposed fix in every case: delete the wrong statement and
keep the file's own correct one.

* `ff-tool-offset.cfg:32` "ESTOP Z to -5" — default is `-3` (:92 and :67 correct)
* `ff-tool-offset.cfg:34,38` `t<n>_offset_x/y/z`, `x/y/z_station_pos` — code writes
  `nozzle_x/y/z` and `station_x/y/z` (:44-47 correct). Same error at `ff_tool_offset.py:19` (:31 correct)
* `ff-chamber.cfg:24-26` "both models, heater in printer.base.cfg" — (:47-50 correct)
* `ff-chamber.cfg:119-124` "base declares the LED and stops there / light comes up OFF" —
  `printer.base.cfg:159` now sets `initial_WHITE: 1.0`
* `ff-chamber.cfg:129-131` + `printer.base.cfg:149-151` "FlashForge's file verbatim" — see A7
* `test_includes.py:31` "ff-runout and ff-chamber are last" — `EXPECTED` ends `ff-legacy.cfg`
* `docs/notes/00:45`, `10:95`, `60:9` "`gear_stepper` = filament feed hub" — it is the tool
  **lock** motor (`ff-filament.cfg:31`, `ff-toolchange.cfg:197`, `notes/25:14` all correct)
* `docs/notes/10:91` lists `extruder_grab`, `servo_min/max`, `extruder_check_pos` as present —
  `ff-toolchange.cfg:187-190` says none of them exist
* `docs/notes/10:10`, `00:33` eddy probe "bed leveling + nozzle offset sensing" — `notes/25:63-67`
  and `printer.base.cfg:346-374` correct this (offsets use the fixed `levelboard` cylinder)
* `bin/patch.sh:78-79` ".cfg installed without clobbering a tuned config" — `run-append.sh:97-103`
  `cp -f`s unconditionally, and `test_config_ownership.py` enforces that
* `docs/how-it-works.md:51` + `bin/patch.sh:22` "keeps two versions" — keeps one
  (`config.env.example:11` correct)
* `payload/start.sh:9` "Two changes from stock" — there are three
* `ff_legacy.py:3-5` "Nothing here runs during normal operation" — `auto_import` defaults True
  and runs on every `klippy:ready` until a nozzle is saved
* `ff-legacy.cfg:37` "afterwards the include can be removed" — `printer.base.cfg:398` says the
  set is mandatory and legacy stays permanently

---

## D. Dangling references

Proposed fix: repoint at the real path, or delete the pointer.

* `OKF/31-recovered-toolchange-sequences.md` (`ff_toolchange.py:6`, `ff-toolchange.cfg:30`) -> `docs/notes/30-toolchange.md`
* `OKF/33-per-tool-offsets.md` (`ff_toolchange.py:190`) -> `docs/notes/40-offsets.md`
* `OKF/62` (`ff_toolchange.py:1108`) — no such note exists; delete
* `OKF/61-print-lifecycle-verified.md` (`ff-print-macros.cfg:24,40`, `ff_print.py:10`) -> `docs/notes/50-print-lifecycle.md`
* `OKF/32-config-provenance.md` (`ff_legacy.py:28`)
* `firmwareExe-decompiled/recovered/toolchange.c` (`ff_toolchange.py:7`)
* `firmwareExe-decompiled/recovered/offset-calibration.md` (`ff_tool_offset.py:10,45`, `ff-tool-offset.cfg:24`) -> `docs/notes/46-...`
* `firmwareExe-decompiled/recovered/filament-load.md` (`ff-filament.cfg:26`) -> `docs/notes/47-...`
* `assets/orca/machine-start-gcode.txt` (`ff-print-macros.cfg:59`, `docs/notes/50b:64`) — never existed
* `case-boot.sh` (`entrypoint.sh:24`), `sim-image.sh` (`docs/testing.md:202`),
  `printer-exec.sh` (`Dockerfile:7`, it is `.py`), `test/printer` build context (`Dockerfile.full:77`)
* `wait_for_banner` (`ff-mcu-bringup.py:234`) — no such function; the ready phase is `Port.poll()`
* `ff_toolchanger_compat` + "github: creator5-toolchange" (`flashforge_creator5.json`) — neither exists
* `README` "Rebuilding chelper" (`bin/patch.sh:60`) -> `docs/building.md:203`
* `FF_IMPORT_FIRMWARE_CONFIG` "(see README)" (`ff-toolchange.cfg:109`) — README never mentions it
* `assets/hooks-creator5.sh` (`bin/patch.sh:140`) — not in `assets/`; `[ -f ]`-guarded so it silently never runs
* `printer.chamber.cfg (line 132)` (`printer.base.cfg:405`) — the include is at line 152
* `printer.base.cfg:278-287` for the door buttons (`docs/notes/25:13`) — now 286-294
* a pty-based handshake test (`case-mcu-bringup.sh:4`) — no such test exists

---

## E. Wrong values, counts and sizes

| Where | Says | Actually | Fix |
|---|---|---|---|
| `docs/notes/50b:18` | `M400` in START_PRINT prologue; idle timeout `1800000` | no `M400`; timeout `864000` | correct both |
| `docs/notes/50b:39` | `TEMPS` falls back to `TEMP` | material table is consulted first — `NOZZLE=240` cleans at 220 | rewrite precedence |
| `docs/notes/50b:12` | `TOOLS=0,2 TEMPS=220,0,240,0` | paired form `TOOLS=0:220,2:240` | update signature |
| `docs/notes/50b:34,47` | wipe Z in the homed frame | raw eddy frame (`clean_wipe_z - homing_origin.z`) | correct frame |
| `docs/notes/49:96` | `M117 E0162/E0163` | `M117 T{n} clog` / `T{n} out of filament` | quote the real strings |
| `docs/notes/30:29` | grab-verify failure -> `E0143` | `E0051+tool` | correct code |
| `docs/notes/30:8`, `00:41` | docks at X 250-280 | 250/280 are staging; dock is ~296.5 | correct |
| `docs/toolchange.md:61` | print-offset terms "< 0.1 mm" | its own example reaches ~0.125 | restate |
| `ff-print-macros.cfg:395` | 9 `printer.ff_print.*` fields | `get_status` returns 7; 3 do not exist; `active` undocumented | sync list |
| `ff_print.py:31` | `FF_BEFORE_PRINT_START ... [TOOLS=]` | `TOOLS` never emitted | drop from signature |
| `bin/pack.sh:4` | default package "~28MB" | also carries `anvil.tar.xz`; ~80-93MB elsewhere | pick one measured number repo-wide |
| `ci.yml:98` | "~280MB of release assets" | ~368MB (2x93 + 182) | correct |
| `Dockerfile.full:19` | "88MB package", "90 seconds" | ~93MB; 22s+37s=59s measured | correct |
| `Makefile:89` | "test-py needs only python3 and jinja2" | needs pytest; runs the whole `test/` tree | correct |
| `docs/testing.md:51` | pytest = chamber + paths | also gcode, includes, config-ownership, harness; 44 tests | list all |
| `docs/testing.md:159-167` | sample `make test` output | matches no header the code prints; wrong order | regenerate from a real run |
| `docs/testing.md:12` | "roughly half the gates" | 10 of 11 non-replica gates run | correct |
| `test_harness.py:123` | "Two host-side shell scripts" | one; the vacuity guard passes on one hit | correct, and consider asserting the count |
| `printer-replica.md:51` | `/dev` holds "only" 5 nodes | also `full`, `pts`, `shm` | correct |
| `S50wifi:16-19` | "inline, that is ~20s" | waits are sequential: ~35s | correct |
| `docs/notes/10:86`, `00:42`, `25:26` | `temperature_sensor motor_value` on `eboard:PA1` | no such section ships; nearest is `extruder_servo_value` on `PA0` | mark unverified or drop |

---

## F. Stale "not yet ported" / "missing" claims

* `docs/notes/25:43` "Missing: a START_PRINT gate ... (`_FF_PREFLIGHT`)" — it exists and is invoked twice
* `docs/notes/25:10,19` chamber heaters and LEDs still marked app-only — both ported (`ff-chamber.cfg`, `M141`/`M191`)
* `docs/notes/60:3-4` "NOT (yet) ported — the stock touchscreen still handles this" — two of four are ported, and the
  stock UI no longer exists on a modded printer
* `docs/notes/60:29` "JSON imported once and not consulted afterwards" — imported every boot until a nozzle is saved
* `docs/notes/20:35` `SDCARD_SET_CHANNEL` "still issued" — removed in `764af2a`; absent from `payload/`
* `docs/notes/20:77` "the app and Moonraker coexist" — the app is replaced outright
* `docs/notes/30:76`, `ff-tool-offset.cfg:40` — `*_STATUS` compares against firmwareExe JSON; that reader was removed
* `docs/notes/50-print-lifecycle.md` — never mentions `[ff_print]`, `FF_BEFORE_PRINT_START`, `FF_AFTER_PRINT_END`
  or the `CANCEL_PRINT` override, which are now the default entry points
* `docs/notes/48:48` "Verified (mock render harness, 23 checks)" — harness deleted in `91604c2`
* `docs/notes/48:42` `PURGE` — now also runs the cold wipe by default (`WIPE=1`)
* `ff-print-macros.cfg:58-62` documents the slicer-start-gcode form as primary — the design is now automatic
  (`prepare: 1`) precisely so the Orca profile stays stock
* dead "profiles" concept: `fetch-assets.sh:4`, `patch.sh:116`, and `case-install.sh:138` which **prints**
  "no UI replacement in this profile" on every replica run
* `docs/building.md:143-172` trees — omit `payload/start.sh`, `payload/klipper/`, `S50wifi`, `S65camera`,
  `MOD_CAM`, and three test files
* `docs/notes/00:58-66` notes map — lists 7 of 16 notes
* `bin/common.sh:59,65` — "The version is the release date, 20260823" for `date -u +%Y%m%d`

---

## G. Overclaims worth softening

* `README.md:26-29` "replaces one file / puts the printer back **exactly** as it was" — patch.sh also
  replaces `start.sh`, the klippy tree, `shadow`, and injects into `run.sh`; `/usr/data/anvil`,
  `/usr/data/config/ff-*.cfg` and the logs survive a stock reflash (the recovery test asserts this).
  `docs/how-it-works.md:21` has the honest framing ("integration point").
* `README.md:21` random ssh password stated unconditionally — only when `ROOT_PW_HASH` is unset;
  releases bake in a secret. `docs/building.md:107` is correct.
* `docs/building.md:22` "only the test targets get the docker socket" — `make shell` does too.
* `docs/how-it-works.md:33` "newest version directory" — `app_startup.sh` takes the last `ls` entry
  (alphabetical), and there is only ever one.
* `bin/verify.sh:194` warns "no dropbear -- ssh will not start" on every build; the mod ships none
  deliberately because stock dropbear is already listening. The message says the opposite of the truth.
* `case-install.sh:296-302` claims to assert the root is read-only; the block asserts nothing and
  never sets `FAIL`. The real guarantee is in `assemble.sh:74-75`.
* `docs/printer-replica.md:23` stock-package install stated unconditionally — gated on `BASE_PKG`,
  which `make test-mcu` never sets.
* `anvil.conf:1,17` "runtime switches, edit on the printer" — `MOD_SSH` is build-time only and inert
  at runtime; its three siblings are genuinely runtime-read.
* `ff_toolchange.py:489,1368`, `ff-toolchange.cfg:68`, `_derive_offsets` docstring — "zero offset" for
  an uncalibrated tool; it actually contributes `z_adjust`. Two of these are operator-facing strings.
* `ff_tool_offset.py:632` `_report_diffs` "base T0" — base is the configurable `offset_base`.
* `ff-legacy.cfg:34-36` — claims dock coords and station point are "deliberately not autosaved";
  both are staged via `configfile.set()`, and the printed snippet is `[ff_toolchange]`-only.
* `docs/hardware-testing.md:208` "every command must be one our configs define" — `test_gcode.py:28`
  has a `KLIPPER_BUILTINS` escape hatch.
* `gcode/creator5-safe-moves.gcode:4` "no move below Z50" — its bare `START_PRINT` runs `G1 Z10 F1200`
  under the shipped `prepare: 1`; the test only checks the file's own lines.
* `ff-filament.cfg:315` `PURGE` header omits the `WIPE` parameter the body reads.
* `ff-tool-offset.cfg` / `docs/toolchange.md:233` "nozzle-to-eddy-trigger gap" — `notes/46:92` says the
  station measures a carriage feature ~12.4 mm +X of the nozzle, explicitly not an eddy measurement.
* `docs/toolchange.md:457` "`status` is `changing` until sensors confirm" — `TOOLCHANGE_PARK` /
  `UNSELECT_TOOL` never set it, so a park reports `ready` throughout.
* `docs/toolchange.md:213-239` never mentions `CALIBRATE_TOOL_OFFSETS`, the macro HelixScreen's
  wizard actually calls.
* `docs/notes/50b:25` "with neither, no gate" — `_FF_PREFLIGHT` runs unconditionally.
* `ff-toolchange.cfg:140` "the choice cancels out" — the base does not cancel for X/Y.
* `docs/notes/30:25-28` grab sequence documented in the wrong order vs `_grab`.
* `ff_toolchange.py:199` mentions `heat_fan0`; the fans are `heat_fan`, `heat_fan1..3`.
* `ffsim/gates.py:7` "the scripts in test/integration are thin wrappers" — 3 of 6 are.
* `bin/common.sh:19-39` claims to list every build flag; `MOD_CAM`/`MOD_WIFI` are defined only in patch.sh.
* `entrypoint.sh:46` cites stubs that were removed; `seed-prog.sh` hard-fails instead.

---

## H. Dead code found along the way

Not documentation, but each has a comment implying it is live.

* `ff_print.py:78` `TAIL_BYTES` — nothing reads the tail; the rationale comment at :75 is stale too
* `ff_tool_offset.py:48,61` `Z_TARGET_APP`, `APP_ACCEL_RESTORE` — unreferenced, in a live-looking block
* `bin/patch.sh:10-11` `MARK_BEGIN`/`MARK_END` — the real markers are hardcoded in the inline Python,
  with four different literals. Editing the constants does nothing.
* `bin/common.sh:89` `WORK="${WORK:-work}"` — nothing reads it; `bin/` hardcodes `work/`
* `Makefile:223` cleans `work/uninst work/uninst-sw` — nothing ever creates them
* `payload/run-append.sh:282-288` ssh host-key block guarded on `dropbearkey`, which is never installed
* `config.env.example:45` `STOCK_SOFTWARE` — referenced nowhere
* `test/ffcfg.py:19` assigns `name` in `sections()` and never uses it
* `bin/patch.sh:174-177` — the `/etc` bind-mount comment is written twice
* `bin/build.sh:5` — the one documented pass-through option, `--slim`, is a no-op; `--full` is the real one
