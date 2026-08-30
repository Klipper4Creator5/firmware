# Wipe and extract: retiring .install-manifest

On update, delete `/usr/data/anvil` outright and extract the new payload into
the empty directory. No manifest, no selective delete, no compatibility
branch. Written and implemented 2026-08-30.

Same rules as `80-s6-migration.md` and `85-packaging.md`: the change names the
gate that proves it, and the reasoning that got here is recorded because most
of it is an argument about files that turned out not to matter.

## The whole of it

    rm -rf $MODDIR
    mkdir -p $MODDIR
    xz -dc "$MODTAR" | tar -xf - -C $MODDIR

That is the whole deletion strategy, and it is what the installer does now.
The audit below is why it is safe, kept because the question "what was that
manifest protecting?" is the one anybody reading the change will ask.

## What the manifest was for

Everything in this section describes the installer as it stood before this
change, so it names things rather than lines -- the lines are gone. `git log`
on `installer/runFirmwareExe.sh` is the place to read the code itself.

`80-s6-migration.md:93` introduced the manifest, replacing a sweep of seven
named directories that survived to the end as its compatibility branch:

    rm -rf $MODDIR/bin $MODDIR/www $MODDIR/nginx $MODDIR/helixscreen \
           $MODDIR/config $MODDIR/moonraker $MODDIR/init.d

It was asked to keep two properties at once:

* **(a) the installed set must end up exactly the shipped set** — a file the
  last release shipped under a different name must not survive beside the one
  that replaced it.
* **(b) a file nobody shipped must survive** — the sweep deletes whole
  directories, and `$MODDIR/bin` is where s6 and our Python live.

A full wipe gives (a) perfectly and for free: the installed set is the shipped
set because nothing else is there. It gives up (b) entirely. Everything below
is the audit of what (b) was actually protecting.

## What (b) protects, measured

Against that sweep the manifest rescued almost nothing:
`$MODDIR/nginx/logs/error.log` and `$MODDIR/nginx/tmp/*`, created every boot by
`pkgs/anvil-core/payload/etc/s6-rc/source/nginx/run` and in no manifest because
the package ships only `nginx/nginx.conf`; plus whatever an owner had dropped
into one of those seven directories by hand.

Against a **full wipe** it also rescued printer-local state that lived under
`$MODDIR` and was in no payload, so a wipe deletes it rather than replacing it.
That, not the nginx log, is why the manifest looked load-bearing. There were
two such files, and neither survived examination.

HelixScreen's settings were a third candidate and were already handled by a
mechanism this change does not touch: `settings.json`, `settings.json.backup`,
`helixscreen.env`, `.disabled_services`, `tool_spools.json` and
`crash_history.json` are copied to `/tmp/anvil-helix-keep` before the deletion
and put back after extraction. Every deletion path there has ever been removes
`$MODDIR/helixscreen`, so a wipe costs nothing here. It is now the only
preservation the installer does, and it is the precedent for how the other two
could have been handled, had either needed it.

### backup/stock — nothing reads it

The installer copied the first install's backup to `$MODDIR/backup/stock`,
guarded so a later re-flash could not overwrite it: only the first install sees
genuinely stock files, because by the second one `/usr/prog` holds our own. A
test in `qa/replica/test_install.py` asserted it existed.

That was the entire lifecycle. **No script ever restored from it.** The
documented recovery is `docs/hardware-testing.md:11-13` — flashing the stock
package back from a USB stick, "the only recovery step that needs nothing but a
USB port". It captured `start.sh`, `passwd` and `shadow`, and not
`firmwareExe`: that path is a symlink into `$MODDIR` and the genuine binary
went the first time a component was installed over it.

**Decision: stop creating it.** The stamp directory, the copy loop, the
`backup/stock` promotion and the test all go. The timestamped
`backup/<STAMP>` directories go too — they were snapshots of an already-modded
printer, which is what the `stock` guard existed to say.

### .prev-root-hash — already resolved

Releases before this one recorded the printer's root password hash here so the
install could put it back, and that had already been replaced by a hardcoded
stock hash applied only when the live one is unchanged. What was left was three
lines deleting the file as a secret older installs had abandoned.

So there was no in-flight state for a wipe to destroy, and no ordering
constraint against anything. The wipe subsumes the cleanup too: a directory
deleted wholesale cannot be carrying a stale secret.

### config-installed — dies with the compare it serves

The installer snapshotted `$MODDIR/config/*` into `$MODDIR/config-installed`
after each install, so the next update could ask whether a live config still
matched what the last package wrote. A test pinned it, and the comment beside
it stated the stake: *"Without it a config we own could be written only once,
then land as .mod-new forever."*

**It was a twelve-file directory answering one question about one file.** The
`case` in that loop `continue`d on `moonraker-custom.conf`,
`ff-*.cfg`, `printer.base.cfg`, `printer.chamber.cfg` and `chamber`. Every file
any package ships into `config/` is one of those — `ff-chamber`, `ff-filament`,
`ff-legacy`, `ff-print-macros`, `ff-runout`, `ff-toolchange`, `ff-tool-offset`,
`printer.base.cfg`, `chamber/Creator5.cfg`, `chamber/Creator5Pro.cfg` — except
`moonraker.conf`. Eleven of the twelve copies were read by no branch.

And the one question it answered should not have been asked at all:

* **The shipped file contradicted itself.** `moonraker.conf`'s header promised
  the compare-and-`.mod-new` treatment, and credited it to `run.sh`, which had
  already stopped being the installer. Its footer — the paragraph directly
  above `[include moonraker-custom.conf]`, where someone looking for where to
  put a setting actually lands — said the file is mod-owned and every update
  overwrites it. Two mechanisms cannot both be described by one file; the
  footer is the one that is now true.
* **The docs say overwritten, for what that is worth.**
  `docs/upgrading.md:16` lists `moonraker.conf` in the same row as `ff-*.cfg`
  and `printer.base.cfg`: "**The mod's** — overwritten on every update; do not
  edit." Line 49 repeats it. Weigh this lightly: `upgrading.md` is parked in
  `not_in_nav` (`mkdocs.yml:61`), so it builds but nothing links to it and no
  owner is likely to have read it. It shows what the mod *intends*, not what
  anyone was told.
* **The stated rationale was obsolete.** The installer justified the net with
  "There is no include-and-override seam for it, and a printer reached through
  a tuned `trusted_clients` or `cors_domains` block would lose that access on
  an update." That seam exists: `[include moonraker-custom.conf]` is the last
  line of `moonraker.conf`, applied last, so exactly that block belongs there.
  `docs/upgrading.md:52` documents it.
* **The net inverted its own purpose.** A printer that tripped it kept its old
  `moonraker.conf` for ever, so the `[webcam]` block and the API lockdown never
  reached it — which `docs/upgrading.md:49` says is the point of overwriting.

**Decision: `moonraker.conf` joins `ff-*.cfg` and is simply overwritten.** No
comparison, no `$prev`, no `$stock` runConfig-template branch, no `.mod-new`,
no `config-installed`. An owner who edited it against two explicit warnings
loses those edits silently; their seam is `moonraker-custom.conf` and it is
documented in three places.

### Owner-dropped files — an accepted loss

Property (b) in general. Preserving an arbitrary owner file *anywhere* under
`$MODDIR` requires knowing which files are ours, which is the manifest again —
the requirement is circular, so a wipe cannot satisfy it partially.

**Decision: accept the loss.** `$MODDIR` is our install tree; `/usr/data` is
where an owner's own files belong. The negative control in
`qa/replica/test_upgrade.py` is inverted rather than deleted: it is now
`test_a_file_nothing_ever_shipped_is_gone_too`, still planted in `$MODDIR/bin`
beside one that also has to go.

## What went

| Where | What | Why it could go |
|---|---|---|
| `bin/payload.sh` | manifest generation | nothing reads a manifest |
| `installer/runFirmwareExe.sh` | both delete passes, the forged-path guard, the reverse-sort `rmdir` pass, the pre-manifest branch | replaced by one `rm -rf` |
| | unconditional `rm -rf` of `init.d`, `anvil-service.sh`, `anvil.conf` | subsumed by the wipe |
| | the `etc/s6` scandir sweep | existed *only* because a manifest cannot remove a directory `s6-supervise` wrote into at runtime. `firmwareExe` makes the scandir itself when it starts `s6-svscan` |
| | the config compare, the `runConfig` template branch, `.mod-new`, `config-installed` | `moonraker.conf` is overwritten like every other mod-owned config |
| | the `$MODDIR` `__pycache__` sweep | existed *only* because bytecode written at runtime is in no manifest. The `/usr/prog` sweep stays — different tree, not wiped |
| | the backup stamp dir, the copy loop, `backup/stock` | no restore path existed |
| | the `.prev-root-hash` cleanup | a wiped directory cannot hold a stale secret |
| `qa/replica/test_upgrade.py` | rewritten | see the gate below |
| `qa/replica/test_install.py` | the `backup/stock` assertion | the thing it asserted is gone |

Also: the `.install-manifest` allowlist entry in `qa/static/test_ipk.py`, the
`moonraker.conf` header that described the compare, the two `firmwareExe`
comments about the scandir sweep, and the rows in `docs/testing.md`,
`docs/upgrading.md` and `docs/qa-migration.md` that described any of it.

## What this cancelled

`85-packaging.md:506` scopes phase 2's on-printer half as replacing
`.install-manifest` with opkg's own `.list` files, "a separate change with a
different risk profile". **That phase is cancelled, not deferred.** There is
nothing to replace: the printer never deletes selectively again, so it needs no
file database of ours *or* of opkg's for that purpose. The `.list` files still
ship and still describe the payload; nothing on the printer reads them at
upgrade time.

`85-packaging.md:620` records a known gap — a printer that runs `opkg install`
for something extra and then flashes a `.tgz` keeps that package's files but
loses its stanza. Under a wipe the gap closes in the other direction: the files
go too, and the printer's opkg database once again describes the filesystem
exactly. That is a better answer than the one that phase was going to give.

Both notes point here: phase 1 in `80-s6-migration.md` shipped and is now
retired, phase 2's on-printer half in `85-packaging.md` is cancelled rather
than done. Neither is edited to pretend the manifest never existed — it
shipped, it worked, and this note is the argument that it could go.

## The field-upgrade path

Every printer takes the same path, whatever it is upgrading from. A
pre-manifest install, a manifest install and a fresh flash are
indistinguishable to `runFirmwareExe.sh` once the directory is deleted
wholesale, so there is no compatibility branch — the one the installer used to
describe as "the one piece of this installer that can still destroy a file
nobody asked it to" had nothing left to be compatible with.

**No migration is needed.** Printers carrying `$MODDIR/backup/`,
`$MODDIR/config-installed`, `$MODDIR/.prev-root-hash` or
`$MODDIR/.install-manifest` from an earlier release have them removed by the
first wipe, which is the correct outcome for all four.

## Risks

* **The `/tmp` HelixScreen stash is the only preservation mechanism in the
  installer.** A bug in it has no second line of defence, so the gate asserts
  it with a value that could only have come from the printer: the payload ships
  a `settings.json` of its own, and a restore that silently did nothing would
  leave that one in place.
* **An owner who edited `moonraker.conf` loses those edits with no copy left
  behind.** Chosen deliberately over a `.mod-old` courtesy copy: the docs say
  not to edit it, and the seam is `moonraker-custom.conf`.
* **Anyone who later adds printer-local state under `$MODDIR` loses it
  silently on the next update.** The manifest failed the same way — it could
  not see runtime-created paths either, which is exactly why the `etc/s6` and
  `__pycache__` sweeps had to be written by hand beside it. This note and the
  gate are the mitigation; `/usr/data` is where such state belongs.
* **A power cut between the wipe and the extraction leaves no mod at all.** Not
  a regression: the manifest pass deleted essentially the whole tree before
  extracting too, so the exposure window is unchanged. `app_startup.sh`
  restores a stock `firmwareExe` from a version directory and the printer
  still boots.

## The gate

`qa/replica/test_upgrade.py`, rewritten against the same method: two synthetic
payloads built on the printer, the real `runFirmwareExe.sh` run over them by
the printer's own busybox, every question put to the filesystem afterwards. The
pair of claims changes shape — the "and only that" half is gone, so the
negative control is inverted, from "a file nobody shipped survives" to "a file
nobody shipped is removed too". The `legacy` fixture and its four tests are
deleted outright: there is one path now, so there is nothing to distinguish.

It asserts:

* a file the previous payload shipped and this one does not is gone
* a renamed file leaves no stale twin
* a file nobody ever shipped is **also** gone (the inverted `bin/not-ours` case)
* HelixScreen's user files survive the wipe and are restored over the tarball's
  defaults, and `helixscreen.env` still lands as `.mod-new` when it changed
* `moonraker.conf` is overwritten even when the live copy was edited
* `/usr/data/config/printer.cfg` and `moonraker-custom.conf` are untouched —
  they sit outside `$MODDIR`, so nothing in the installer's deletion path
  protects them, and this is the assertion that nothing needs to
* no `.install-manifest` is written, and the log says the wipe ran

`test_every_payload_file_is_owned_by_a_package` in `qa/static/test_ipk.py`
loses `.install-manifest` from its allowlist, leaving four —
`config/moonraker-custom.conf` and opkg's own `var`, `var/lib`, `var/run`. Its
docstring says that list "should shrink and must not grow by accident". This
shrinks it, and what remains is one user file plus scaffolding opkg makes for
itself.

**Not run here.** The replica lane needs a built package in `work/out`, which
needs `config.env` with `FF_KEY` and `STOCK_TGZ`; the static lane (112 tests,
including `sh -n` over the installer under busybox rules) is green.
