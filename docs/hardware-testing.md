# Hardware testing

CI installs the package into a replica of the printer -- the real
`rootfs.squashfs` running under qemu-mipsel, on the printer's own busybox and
`unTar` (see [printer-replica.md](printer-replica.md)) -- and proves the
machine would still boot. What it cannot do is drive the screen, the MCUs, the
toolchanger or a print. This is the on-hardware procedure.

There is one flash: the firmware package for your model.

**Rule: have the stock FlashForge package for your model on a spare stick
before you flash anything.** Flashing it back is the uninstall, and it is the
only recovery step that needs nothing but a USB port — no ssh, no screen.

It used to be proven by `make test-recovery`, which installed the mod into the
replica and flashed the stock package over it. **That gate has been retired
and nothing has replaced it yet** — see
[qa-migration.md](qa-migration.md). It passed on its last run, but treat the
rollback as unverified against the current build.

---

## Step zero: check the model gate

Every package carries a gate. Its `runFirmwareExe.sh` has `MACHINE=` / `PID=`
baked in, and compares them against the values `app_startup.sh` passes from
the firmware already on the printer. A mismatch is **refused** with
"Firmware does not match machine type" — it will not install, and it is not a
valid recovery image either.

| Model | MACHINE | PID |
|---|---|---|
| Creator 5 | `Creator5` | `0028` |
| Creator 5 Pro | `Creator5Pro` | `0029` |

The gate is not cosmetic: the two models ship **different `firmwareExe`
binaries**, so a package must be built from the stock package for its own
model. `make release` builds both.

Find yours in Settings → About, or in
`/usr/data/firmwareRes/config/general.json` (`machineName`), and set
`TARGET_MACHINE` in `config.env`. Then:

```sh
make build && make verify          # one model
make release                       # both, into dist/
```

`verify.sh` fails loudly on a mismatch. **You must start from a stock package
built for your own model** — the mod inherits the gate from whatever package
you unpack.

## Before the first flash

- [ ] Put a copy of the **stock FlashForge package for your model** on a spare
      USB stick and keep it physically separate. That is your recovery image:
      flashing it restores every file the mod touches. Check it is the right
      model first — see above.
- [ ] Note your printer's serial number (Settings → About). The factory image
      restores a placeholder serial and you may need to put yours back.
- [ ] Confirm you can reach the printer's IP.
- [ ] `make qa` passes.
- [ ] `make rootfs && make qa-replica` passes — this parses every script that
      will run on the printer using the printer's own busybox ash.

Two USB sticks, FAT32, both packages at the **root** of the stick (not in a
folder). Ship both filenames (`Creator5-*` and `Creator5Pro-*`): the Pro's
boot script globs `Creator5Pro-*.tgz`, the non-Pro globs `Creator5-*.tgz`.

---

## The flash

One flash brings up everything: a root password you know, Mainsail and
moonraker, the forked Klipper with the toolchanger extras, and HelixScreen on
the touchscreen in place of FlashForge's UI.

From here the procedure is the one an owner follows, and it is written for
them rather than repeated here:

| | |
|---|---|
| [Installing](installing.md) | the flash itself, the first boot, the root password |
| [Your first print](first-print.md) | the go/no-go checks, calibration, and the two files under `gcode/` |
| [Support](support.md) | the logs, and the way back to stock |

What follows is the part that is ours rather than theirs: keeping those two
verification files honest as the macros change.

## Keeping the verification files honest

`make test-py` checks both files against the shipped macros and the configured
axis limits: every command in them must be one the mod's Klipper config or
`pkgs/klipper/payload/klipper/klippy/extras/` defines (bar an explicit allowlist of Klipper
built-ins, currently just `SET_PRESSURE_ADVANCE`), `TOOLS=` must list every
tool the feature print uses, and the safe file's own lines must stay cold and
above Z50 — the check reads the file, so it does not see what an implicit
`START_PRINT` does before it. A renamed macro breaks the suite rather than the
print.
