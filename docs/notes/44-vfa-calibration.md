# VFA calibration — what the stock app automates, and how it was brought back

"VFA" in FlashForge's UI is **Vertical Fine Artifacts**: the fine vertical banding a
stepper's torque ripple prints onto a wall. The stock firmware calls it *VFA vertical
stripe compensation*, and it is **not input shaping** — input shaping is the separate
"Vibration Compensation" item in the same menu. The two are different mechanisms,
different Klipper modules and different MCU paths, and conflating them is the first
mistake available here.

The compensation is a **current-waveform correction inside the closed-loop stepper
driver**: a small sinusoid added to the phase current at 1×, 2× and 4× the electrical
frequency, with a per-direction phase, chosen to cancel the motor's own torque ripple.

## The chain, end to end

```
CalibrationPage / MainCalibration      firmwareExe, LVGL UI
  └─ MainCalibration::testVfa()        0x00b2688c
      └─ CommMgr::calibration_vfa()    0x0075e694  — sends five G-code strings
          ├─ G1 Z100 F1200 ; M400
          ├─ G1 X130 Y130 F6000 ; M400
          └─ STEPPER_RESONANCE_FACTORY_CALIBRATE
                └─ [gcode_macro] in printer.vibration.cfg:45-66
                    ├─ MCLIB_SET_RESONANCE_DAMP … AMP=0 ×6   (zero x/y, td1/2/4)
                    ├─ STEPPER_RESONANCE_SEARCH_CALIBRATE STEPPER=stepper_x
                    └─ STEPPER_RESONANCE_SEARCH_CALIBRATE STEPPER=stepper_y
                          └─ klippy/extras/stepper_resonance_tester.py  (1926 lines)
                                ├─ measures with [lis2dw] on the carriage
                                └─ MCLIB_SET_RESONANCE_DAMP  →  klippy/extras/mclib.py
                                      └─ MCU cmd  mclib_set_resonance_damp
                                         oid=%c tdx=%c amp=%u phase1=%u phase2=%u
                                         (mainBoardGD — stock, we do not build it)
```

**`SAVE_CONFIG` is not in the macro** — the macro's own `#SAVE_CONFIG` is commented
out. The app issues it separately from `CommMgr::klipperSaveConfig()` (`0x007877d8`,
the only reference to the bare `SAVE_CONFIG` string in the binary), called from
`MainCalibration::doMainCalibrationFinished(ErrorBak)` at the end of the whole
calibration run. So the macro alone tunes the motors for **this boot only**; without a
later `SAVE_CONFIG` the result is lost on restart. Anything we build must supply that
step itself.

`CalibrationPage::doVfa()` / `initVfa()` (`0x00951c94` / `0x0095187c`) are icon layout
only — the user-facing calibration page draws the VFA tile, and only
`MainCalibration::doMainCalibrationMgr()` actually runs the test.

## What the algorithm does

Per motor (`stepper_x`, `stepper_y`), per harmonic (`td1`, `td2`, `td4`), per direction
(forward/backward — the two `PHASE1`/`PHASE2` slots):

1. **Excite.** Move the toolhead 100 mm through a fixed centre at the CoreXY belt angle
   (±45°) so exactly one motor dominates. Speed is chosen so the motor's electrical
   frequency lands on its resonance: `vel = res_freq/50/tdx * rotation_distance /
   vel_ratio`. With the stock numbers (`stepper_*_freq: 200`, `rotation_distance
   40.318`, `vel_ratio √2`) that is ≈114 / 57 / 28.5 mm/s for td1 / td2 / td4.
   The `50` is electrical cycles per revolution: 200 full steps ÷ 4 steps per cycle.
2. **Measure.** `[lis2dw]` samples through the constant-velocity segment only; a
   Hann-windowed rFFT picks the bin at the target frequency, with 3-point parabolic
   interpolation to beat the picket fence. That scalar is the *residual*.
3. **Search** (`search_calibrate_one_direction`, ~19 moves per harmonic per direction):
   - measure bare distortion with AMP=0; bail if below `min_distortion_threshold` (100)
   - **Round 1** — 4-point quadrature probe at 0/90/180/270°. Because
     `R²(φ) = R₀² − R₁·cos(φ − φ_opt)` is exactly sinusoidal, `φ_opt = atan2(−b, −a)`
     falls straight out of the four points. Deliberately only 4 moves, at a small trial
     amplitude, because two of them are in the *bad* phase where compensation adds
     vibration. Auto-shrinks the trial amplitude and retries (≤3×) if all four come out
     worse than bare.
   - **Round 2** — 5-point fine phase sweep at φ_opt ±30°, parabolic refine.
   - **Round 3** — amplitude sweep at the good phase.
   - **Round 4** — 3-point final phase refine at the chosen amplitude.
4. **Apply and record.** `MCLIB_SET_RESONANCE_DAMP` pushes the result to the MCU live,
   and `configfile.set('mclib stepper_x', 'td2_amp', …)` stages it for `SAVE_CONFIG`.
   A per-run CSV of every measurement lands in `/tmp/`.

## What consumes the numbers — none of it is stock Klipper

The calibration produces six numbers per motor (`amp`, `phase1`, `phase2` × td1/td2/td4).
Two layers consume them, and only the first is ours to touch.

**Layer 1 — `klippy/extras/mclib.py`, the transport.** A fork-only extra; upstream
Klipper has nothing like it. Its header names the author:

```
# GD32 mcu motor control library configuration
# Copyright (C) 2024  Dongzhi Yu <dongzhi.yu@gigadevice.com>
```

so `mclib` is **GigaDevice's** motor-control library, not FlashForge's. `MCLIB` binds to
a `[stepper_x]`-style section, resolves the real stepper at `klippy:mcu_identify`, and in
`_build_config` emits the whole motor description as **`add_config_cmd`** — the config
block Klipper replays on every MCU connect. That is the persistence path: `SAVE_CONFIG`
writes `td*_amp` / `td*_phase1` / `td*_phase2` into printer.cfg's autosave, `mclib.py`
reads them back at startup (`mclib.py:40-48`) and re-sends them (`mclib.py:90-95`) before
the first move. `MCLIB_SET_RESONANCE_DAMP` is the same message sent live, which is how
the search loop probes a candidate without a restart.

**Layer 2 — the GD32 firmware, where it is actually applied.** The main board is a
**GD32H757ZG at 600 MHz** (Cortex-M7), and its command set is not a step/dir driver's:

```
config_mclib            oid stepper rs ls km      ; phase R, phase L, torque constant
mclib_set_current       oid run_current hold_current
mclib_set_pid_params    oid kp ki                 ; current-loop PI
mclib_identify_motor    oid umax umin             ; motor parameter identification
mclib_config_microstep  oid interpolate mstep
mclib_config_stalldetect oid stallthrs
mclib_set_resonance_damp oid tdx amp phase1 phase2
```

Feeding a firmware winding resistance, inductance, torque constant, bus voltage and
current-loop gains means it is synthesising phase currents, not toggling a step pin —
a closed-loop, current-controlled driver in place of a TMC-class chip. The harmonic
injection itself lives in that loop: `amp`/`phase` are added to the commutation waveform
at 1×, 2× and 4× electrical frequency, in real time, on the MCU. `stepper=%u` resolves
through the dictionary's own enumeration (`stepper_x: 0, stepper_y: 1, stepper_z: 2,
extruder: 3`).

**That layer is closed, and it does not matter.** The fork's tarball ships upstream's
`src/` (atsam, atsamd, ar100, …) but **no GD32 port and no `mclib.c`** — the only mclib
artifact anywhere in it is the host-side `mclib.py`. We cannot rebuild `mainBoardGD.bin`
and cannot read the injection maths. We also never flash it: `ff_mcu_bringup.py`
"flashes nothing", so the printer keeps FlashForge's firmware, whose dictionary already
carries `mclib_set_resonance_damp`. The black box is on the far side of a wire we only
ever write to.

One consequence worth stating plainly: **the compensation is a property of the motors,
applied by the driver, and it is live whether or not `stepper_resonance_tester.py` can
import numpy.** A printer with saved `td*` values in printer.cfg keeps them. Only the
*calibration* needs numpy — `mclib.py` itself imports nothing but `logging` and
`stepper`.

Phases are normalised before they leave: `_quadrature_estimate` and the final
`_r2_sinusoidal_fit` both `% (2*np.pi)`, so nothing negative reaches
`int(phase * 1000)` and the `%u` field on the wire.

## Where Reforge stands

Already present, no work needed:

- `stepper_resonance_tester.py` — **byte-identical** in our vendored fork
  (`klipper-b722a4c8…`) and in stock. Same for `mclib.py`.
- `printer.vibration.cfg` — FlashForge's, copied to `/usr/data/config` by their
  `run.sh:156`, and our `printer.base.cfg:19` still includes it. It carries `[lis2dw]`,
  `[resonance_tester]`, `[stepper_resonance_tester]` and the
  `STEPPER_RESONANCE_FACTORY_CALIBRATE` macro.
- `[mclib stepper_x]` / `[mclib stepper_y]` — in our `printer.base.cfg:66,97`.
- The MCU command. We do not build or flash `mainBoardGD`; the printer keeps
  FlashForge's, and its dictionary carries
  `mclib_set_resonance_damp oid=%c tdx=%c amp=%u phase1=%u phase2=%u`. **Zero MCU work.**

So the mechanism is all there. What is missing is one import.

## The blocker: numpy, and it is worse than "loses resonance testing"

`stepper_resonance_tester.py` line 1 is a bare `import numpy as np` — no guard. That is
unlike upstream's `shaper_calibrate.py`, which imports numpy lazily inside
`_init_numpy()` and degrades to a runtime error message.

`klippy.py:122-123` loads **every** config section, and `load_object` (`klippy.py:103`)
calls `importlib.import_module` with no `except ImportError`. The `default=None` third
argument only covers a *missing file*; the file exists, so the ImportError propagates
out of `_read_config` and past `_connect`'s `config_error` handler.

Verified by import, with numpy blocked at `sys.meta_path`:

```
stepper_resonance_tester     FAILS: ImportError: No module named 'numpy'
```

and there is no numpy anywhere in `pkgs/3rdparty/` — the recipe does not exist.

The consequence is not a degraded feature. `[stepper_resonance_tester]` is in the config
we ship an include for, so on a printer whose klippy runs on our CPython 3.13
**klippy does not come up at all**. This became live with the `$FF_PYTHON` switch
(`53292b4`, `c92b3c9`); FlashForge's own 3.8.2 has numpy in its rootfs and our 3.13 does
not, and a 3.8 `.so` is not importable from 3.13 in any case.

Two comments in this repo claimed the opposite — "the module guards its own import,
so the printer runs without it and loses resonance testing" in `anvil-env.sh`, and
"both are import-guarded" in `pkgs/klipper/pkg.conf`. Both were wrong; both are
corrected in the commit that adds this note.

That is the failure this note was opened for, and it is closed below — but the
diagnosis was never confirmed against a real `printer.log`. Every gate listed at the
end of this note passes, which says a printer built from this tree starts; it does not
prove that one built before it did not. If you have a machine that was running the
numpy-less build, its `printer.log` is still worth reading.

## How it was closed

numpy is packaged. `pkgs/3rdparty/python-numpy/` builds numpy 2.1.3 for
`mipsel_xburst2`, `anvil-klipper` depends on it, and the calibration is reachable
again — along with `SHAPER_CALIBRATE` and `TEST_RESONANCES`, which had been dead for
exactly the same reason.

Two alternatives were considered and dropped. Dropping numpy from
`stepper_resonance_tester.py` was feasible — every measurement asks for the amplitude
at **one** known frequency, so the rFFT collapses to three Goertzel evaluations — but it
leaves `SHAPER_CALIBRATE` broken and is a second DSP implementation to carry, the kind
`consolidate-dont-carry-two` argues against. Guarding the import stops the boot failure
and restores nothing; it remains the right emergency patch if a release is ever due
before a numpy build lands.

### What it took, and what was not obvious

**numpy 2.x builds with meson-python, not setuptools**, so the
`_PYTHON_SYSCONFIGDATA_NAME` trick every other `python-*` recipe relies on is not enough
on its own — meson has never heard of that variable. `pkg_mesoncross` in `pkgs/lib.sh`
writes a real cross file instead, and `pkg_pywheel` grew a `PKG_PY_PIP_ARGS` branch to
hand it over as `--config-settings`.

**The `python =` line in that cross file is `$HOSTPY`, and that is not a mistake.**
Meson introspects an interpreter by *running* it and asking `sysconfig`, and
`pkg_pytarget` has already made the host interpreter's sysconfig answer for mipsel. So
the existing cross trick does extend to meson — just not by the variable's own
mechanism.

**numpy's `meson.build` hard-errors on GCC below 8.4 and ours is 7.2.** The gate is
conservative rather than load-bearing: it comes from the SciPy Toolchain Roadmap, which
says what the project supports, not what the code needs. Probed before it was lowered —
this toolchain compiles `if constexpr`, structured bindings, `std::optional`,
`std::string_view`, and `pocketfft_hdronly.h`, 3635 lines of the heaviest template C++
in the tree and the half `np.fft.rfft` needs. The recipe lowers the floor to 7.2 behind
a guard that fails loudly if upstream moves the check.

**meson-python is self-hosting** (`backend-path = ['.']`), so `pkg_buildpython` runs
meson and ninja just to *install the backend* — which is why `ninja-build` is in
`docker/Dockerfile.build` and why the four new `PYPKG_HOST_LIST` entries are in
dependency order rather than alphabetical.

**pip puts `meson` and `cython` in `work/.py-host/bin`, which nothing had ever looked
in.** Without that directory on PATH, meson-python fails to install with
`meson executable "meson" not found` while `pip list` shows meson installed and
importable. `pkg_buildpython` prepends it.

Result: 19 extension modules, every one ELF32 MIPS32r2 little-endian at `e_flags`
`0x70001405`/`0x70001407`, 14 MB shipped after the recipe prunes `tests/`, `f2py/`,
`.pyi` stubs and the static libs.

## Using it

The commands are FlashForge's and already on the printer; nothing here is a wizard.
From the Mainsail console:

```
STEPPER_RESONANCE_FACTORY_CALIBRATE
SAVE_CONFIG
```

**`SAVE_CONFIG` is required and is deliberately not in any macro.** The search applies
its result live with `MCLIB_SET_RESONANCE_DAMP` and stages it with `configfile.set`,
which only `SAVE_CONFIG` writes — so without one the calibration is lost on the next
restart. The stock app had the same split (see above), and `SAVE_CONFIG` restarts
klippy, which is not something a macro should do to somebody mid-session.

`ff-toolchange.cfg` wraps `STEPPER_RESONANCE_SEARCH_CALIBRATE` and
`STEPPER_RESONANCE_REFINE_CALIBRATE` in `_FF_SHAPER_PREP`, the same prep
`SHAPER_CALIBRATE` already gets: home if needed, grab `shaper_tool` if nothing is
mounted, because an empty carriage measures the wrong moving mass.

`STEPPER_RESONANCE_FACTORY_CALIBRATE` is **not** wrapped, and the obvious edit there is
wrong. It is a `[gcode_macro]` in FlashForge's `printer.vibration.cfg`, not a
Python-registered command, and Klipper parses with `RawConfigParser(strict=False)` — so
a second section of the same name *merges* with the first rather than wrapping it, and
`rename_existing` would point the macro at itself. It needs no wrapper anyway: its whole
body is two `STEPPER_RESONANCE_SEARCH_CALIBRATE` calls, and those are wrapped.

### Still worth a dry run

The move geometry is FlashForge's and has not been checked on a real Creator 5 Pro by
anyone here. The stock centres (`stepper_x_center_xy: 40,220`,
`stepper_y_center_xy: 220,220`) with `move_distance` 100 at ±45° sweep X 4.6→75.4 and
Y 184.6→255.4, against our `position_max` of X 310 / Y 260. It fits, but Y clears by
4.6 mm, and `x_range`/`y_range` in the config are sanity-checked at load and then
**never used to clamp the move**. On a toolchanger with docks at X≈297 that is worth
watching once before it is offered to owners.

Nothing in the replica can tell you whether the calibration produces *good numbers* —
that needs a printer, an accelerometer and real motion. What the gates below prove is
that klippy starts and that numpy computes correctly, which is a different and smaller
claim.

## The gates that would have caught this

- `qa/replica/test_klippy_extras_import.py` — walks the real `/usr/data/config` include
  graph, maps every section to `extras/<name>.py`, and imports each on the printer's own
  interpreter. Needs no MCU: config load happens in `_read_config`, before
  `klippy:mcu_identify`. This is the test whose absence let two wrong comments stand.
- `qa/replica/test_numpy.py` — asks for numeric answers rather than a module object.
  `np.linalg.lstsq` is in there specifically because `-Dallow-noblas=true` selects the
  bundled `lapack_lite`, and `_r2_sinusoidal_fit` calls `lstsq` on every calibration
  round.
- `qa/replica/test_install.py::test_every_include_resolves_not_just_ours` — the old
  check read only `ff-*.cfg`, so FlashForge's four includes, `printer.vibration.cfg`
  among them, were never asked about at all.
- `qa/static/test_recipe_layout.py::test_klipper_still_depends_on_numpy` — the cheapest
  gate on the most expensive mistake.
- `qa/replica/test_abi.py` needed no change: it sweeps every ELF object on the
  filesystem, so numpy's 19 extensions are covered the moment they ship.

The import gate was checked in both directions before it was trusted. On the baked
replica, with the real shipped tree under qemu: `extras.stepper_resonance_tester`
imports with numpy present, and with `site-packages/numpy` moved aside it raises

```
ModuleNotFoundError: No module named 'numpy'   (line 1, import numpy as np)
```

— an `ImportError`, which is what `load_object` does not catch. That is the original
diagnosis reproduced on the machine rather than argued from source, and it is why the
test asserts `stepper_resonance_tester` specifically imported rather than only that
nothing failed: a section whose module is absent is *skipped*, so without that
assertion the gate could go green having never asked.

## Address-verified symbols

| Symbol | Address | Size |
|---|---|---|
| `CommMgr::calibration_vfa()` | `0x0075e694` | 2416 |
| `CommMgr::klipperSaveConfig()` (ref site) | `0x007877d8` | — |
| `MainCalibration::testVfa()` | `0x00b2688c` | 620 |
| `MainCalibration::testVibration()` | `0x00b26700` | 396 |
| `CalibrationPage::doVfa()` | `0x00951c94` | 1552 |
| `CalibrationPage::initVfa()` | `0x0095187c` | 1048 |
| `CalibrationPage::testVibration()` | `0x0095bce4` | 396 |

Callers of `klipperSaveConfig`: `CalibrationPage::doCalibrationFinished`,
`GuideCalibration::doCalibrationFinished`, `MainCalibration::doMainCalibrationFinished`,
`DebugDialog::threadTestBedPID`, `DebugDialog::threadTestNewVibration`.
