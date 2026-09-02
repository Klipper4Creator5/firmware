# Changelog

All notable Reforge changes are recorded here. The project is in beta: a
feature can be implemented and replica-tested without yet being validated on
both printer models or through every real-world workflow.

## Unreleased

Release preparation and documentation sweep. No firmware behavior is changed
by this entry.

## v20260827c-melitopol — 2026-08-27

### Added

- HelixScreen’s Filament page now follows the selected tool for material,
  spool, temperatures, loading, and retracting.
- Installed packages record the Reforge APK feed location for future updates.

### Fixed

- A selected tool with no resolvable heater is logged and ignored instead of
  heating the wrong hotend.

## v20260827d-melitopol — 2026-08-27

### Added

- HelixScreen pressure-advance calibration integration and per-tool Z
  correction selection in the tune overlay.

### Fixed

- Pressure-advance calibration restores the previous heater target, including
  when a sweep fails partway through.
- Calibration documentation now explains that results belong in the slicer’s
  filament profile rather than being saved to `printer.cfg`.

## v20260827-melitopol — 2026-08-27

### Added

- s6-rc supervision for the web stack, camera, Moonraker, Wi-Fi, and related
  services, with readiness checks based on actual service readiness.
- A printer-local CPython 3.13 runtime for Moonraker with working SQLite.
- CPU priority controls that let Moonraker and the camera yield to Klipper.
- HelixScreen settings persistence across firmware updates.

### Changed

- Reforge owns and starts the camera and web stack rather than stock
  `firmwareExe`.
- Startup retries until MCU boards answer and shows boot progress.

## v20260825b-nova-kakhovka — 2026-08-25

### Fixed

- `TOOL_OFFSET_CALIBRATE` no longer shuts Klipper down on completion.

## v20260825-nova-kakhovka — 2026-08-25

### Added

- First-boot import of factory per-unit calibration into Klipper config.
- Toolchanger-aware calibration, status commands, and safe plate checks.
- An update path that preserves the root password and user configuration.

### Fixed

- Release builds can no longer silently fall back to the stock Klipper tree.

## v20260824-nova-kakhovka — 2026-08-24

### Added

- USB packages for Creator 5 and Creator 5 Pro with model guards.
- Current Klipper with Creator 5 toolchanger support, Mainsail, Moonraker,
  HelixScreen, camera streaming, Wi-Fi, and root SSH.
- Stock slicer compatibility through `[ff_print]`, `START_PRINT`, and
  `END_PRINT`, including preparation, mesh loading, nozzle cleaning, tool
  checks, and safe cancellation.
- Tool-aware filament load, unload, purge, runout, and clog handling.
- Automatic pressure-advance calibration and VFA calibration support.
- Timelapse support, signed APK packages, pinned inputs, and Docker plus
  printer-replica QA.

### Known release issue

The original packages were withdrawn because they could install a mixed
Klipper tree. Use the rebuilt release or a later release; see its release note.

## Project start — 2026-08-20

- Initial reverse-engineering notes and USB-installable firmware builder.
