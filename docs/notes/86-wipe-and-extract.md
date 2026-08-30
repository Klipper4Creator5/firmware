# Wipe and extract: retiring .install-manifest

On update, delete `/usr/data/anvil` outright and extract the new payload into
the empty directory. No manifest, no selective delete, no compatibility
branch. Written 2026-08-30. This is a proposal; no code has moved yet.

Same rules as `80-s6-migration.md` and `85-packaging.md`: the change names the
gate that proves it, and the reasoning that got here is recorded because most
of it is an argument about files that turned out not to matter.

## The proposal in one line

    rm -rf $MODDIR
    mkdir -p $MODDIR
    xz -dc "$MODTAR" | tar -xf - -C $MODDIR

That is the whole deletion strategy. `installer/runFirmwareExe.sh` loses about
240 lines and `bin/payload.sh` loses eleven.

## What the manifest was for

`80-s6-migration.md:93` introduced it, replacing the seven-directory sweep that
still survives as the compatibility branch at
`installer/runFirmwareExe.sh:309`:

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

Against the seven-directory sweep the manifest rescues almost nothing:
`$MODDIR/nginx/logs/error.log` and `$MODDIR/nginx/tmp/*`, created every boot by
`pkgs/anvil-core/payload/etc/s6-rc/source/nginx/run:29` and listed in no
manifest because the package ships only `nginx/nginx.conf`; plus whatever an
owner has dropped into one of those seven directories by hand.

Against a **full wipe** it also rescues printer-local state that lives under
`$MODDIR` and is in no payload, so a wipe deletes it rather than replacing it.
That, not the nginx log, is the reason the manifest looks load-bearing. There
are two such files left, and neither survives examination.

HelixScreen's settings are a third candidate and are already handled:
`runFirmwareExe.sh:225-233` copies `settings.json`, `settings.json.backup`,
`helixscreen.env`, `.disabled_services`, `tool_spools.json` and
`crash_history.json` to `/tmp/anvil-helix-keep` before *either* deletion path
runs, and `:356-369` puts them back after extraction. Both existing branches
already remove `$MODDIR/helixscreen`, so a wipe costs nothing here and this
mechanism is unchanged by this proposal. It is also the precedent for how the
other two could have been handled, had either needed it.

### backup/stock — nothing reads it

`installer/runFirmwareExe.sh:165` copies the first install's backup to
`$MODDIR/backup/stock`, guarded by `if [ ! -d ... ]` for a stated reason: only
the first install sees genuinely stock files, because by the second one
`/usr/prog` holds our own. `qa/replica/test_install.py:332` asserts it exists.

That is the entire lifecycle. **No script restores from it.** The documented
recovery is `docs/hardware-testing.md:11-13` — flashing the stock package back
from a USB stick, "the only recovery step that needs nothing but a USB port".
It captures `start.sh`, `passwd` and `shadow`, and explicitly *not*
`firmwareExe`, which the script itself explains at `:157-161`: that path is a
symlink into `$MODDIR` and the genuine binary went the first time a component
was installed over it.

**Decision: stop creating it.** `runFirmwareExe.sh:149-167` loses the `BACKUP=`
stamp directory, the three-file copy loop and the `backup/stock` promotion;
`qa/replica/test_install.py:332-340` goes with them. The timestamped
`backup/<STAMP>` directories go too — they are snapshots of an already-modded
printer, which is what the `stock` guard exists to say.

### .prev-root-hash — already resolved

Earlier releases recorded the printer's root password hash here so the install
could put it back. That is gone: `runFirmwareExe.sh:169-171` now only deletes
the file, with the reason in the comment — *"A password hash left on disk by
installs that predate this one. Nothing reads it; do not leave a secret lying
in `$MODDIR`."*

So there is no in-flight state for a wipe to destroy, and no ordering
constraint against any other branch. The wipe subsumes those three lines as
well: a directory that is deleted wholesale cannot be carrying a stale secret,
so the cleanup can go with everything else.

### config-installed — dies with the compare it serves

`runFirmwareExe.sh:505-507` snapshots `$MODDIR/config/*` into
`$MODDIR/config-installed` after each install, so the next update can ask
whether a live config still matches what the last package wrote.
`qa/replica/test_upgrade.py:406` pins it, and `runFirmwareExe.sh:442` states
the stake: *"Without it a config we own could be written only once, then land
as .mod-new forever."*

**It is a twelve-file directory answering one question about one file.** The
`case` at `runFirmwareExe.sh:456-481` `continue`s on `moonraker-custom.conf`,
`ff-*.cfg`, `printer.base.cfg`, `printer.chamber.cfg` and `chamber`. Every file
any package ships into `config/` is one of those — `ff-chamber`, `ff-filament`,
`ff-legacy`, `ff-print-macros`, `ff-runout`, `ff-toolchange`, `ff-tool-offset`,
`printer.base.cfg`, `chamber/Creator5.cfg`, `chamber/Creator5Pro.cfg` — except
`moonraker.conf`. Eleven of the twelve copies are never read by any branch.

And the one question it answers should not be asked at all:

* **The shipped file contradicts itself, and the footer is the half an owner
  reads.** `moonraker.conf`'s header promises the compare-and-`.mod-new`
  treatment — and still credits it to `run.sh`, which stopped being the
  installer. Its footer — the paragraph sitting directly above
  `[include moonraker-custom.conf]`, where someone looking for where to put a
  setting actually lands — says "this file is mod-owned and every update
  overwrites it." Two mechanisms cannot both be described by one file.
* **The docs say overwritten, for what that is worth.**
  `docs/upgrading.md:16` lists `moonraker.conf` in the same row as `ff-*.cfg`
  and `printer.base.cfg`: "**The mod's** — overwritten on every update; do not
  edit." Line 49 repeats it. Weigh this lightly: `upgrading.md` is parked in
  `not_in_nav` (`mkdocs.yml:61`), so it builds but nothing links to it and no
  owner is likely to have read it. It shows what the mod *intends*, not what
  anyone was told.
* **The stated rationale is obsolete.** `runFirmwareExe.sh:436` justifies the
  net with "There is no include-and-override seam for it, and a printer reached
  through a tuned `trusted_clients` or `cors_domains` block would lose that
  access on an update." That seam exists now: `[include moonraker-custom.conf]`
  is the last line of `moonraker.conf`, applied last, so exactly that block
  belongs there. `docs/upgrading.md:52` documents it.
* **The net inverts its own purpose.** A printer that trips it keeps its old
  `moonraker.conf` for ever, so the `[webcam]` block and the API lockdown never
  reach it — which `docs/upgrading.md:49` says is the point of overwriting.

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
where an owner's own files belong. `qa/replica/test_upgrade.py:357`
(`test_a_file_nothing_ever_shipped_survives`) inverts to assert the wipe
removes it, and `docs/testing.md:41` loses its "and **only** that" claim.

## What this deletes

All line numbers are `installer/runFirmwareExe.sh` unless said otherwise.

| Where | What | Why it can go |
|---|---|---|
| `bin/payload.sh:101-111` | manifest generation | nothing reads a manifest any more |
| `:234-311` | both delete passes, the forged-path guard, the reverse-sort `rmdir` pass, the pre-manifest branch | replaced by one `rm -rf` |
| `:312-335` | unconditional `rm -rf` of `init.d`, `anvil-service.sh`, `anvil.conf` | subsumed by the wipe |
| `:372-384` | the `etc/s6` scandir sweep | existed *only* because the manifest cannot remove a directory `s6-supervise` wrote into at runtime |
| `:416-508` | the config compare, `$stock` template branch, `.mod-new`, `config-installed` | `moonraker.conf` is overwritten like every other mod-owned config |
| `:511-520` | the `$MODDIR` `__pycache__` sweep | existed *only* because bytecode written at runtime is in no manifest. The `/usr/prog` sweep at `:524` stays — different tree, not wiped |
| `:149-167` | the backup stamp dir, the copy loop, `backup/stock` | no restore path exists |
| `:169-171` | the `.prev-root-hash` cleanup | a wiped directory cannot hold a stale secret |
| `qa/replica/test_upgrade.py` | rewritten | see the gate below |
| `qa/replica/test_install.py:332-340` | the `backup/stock` assertion | the thing it asserts is gone |

Docs: `docs/testing.md:41`, `docs/upgrading.md:56-57` (the `.mod-new`
footnote), `docs/qa-migration.md:73`, and the phase notes below.

## What this cancels

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

Both notes carry a pointer here, each marked as a proposal rather than a
decision: phase 1 in `80-s6-migration.md` shipped and this would retire it,
phase 2's on-printer half in `85-packaging.md` would be cancelled rather than
done. Neither is edited to pretend the manifest never existed — it shipped, it
works, and this note is the argument that it can go.

## The field-upgrade path

Every printer takes the same path, whatever it is upgrading from. A
pre-manifest install, a manifest install and a fresh flash are indistinguishable
to `runFirmwareExe.sh` once the directory is deleted wholesale, so the
compatibility branch — which the code itself calls "the one piece of this
installer that can still destroy a file nobody asked it to" — has nothing left
to be compatible with.

**No migration is needed.** Printers carrying `$MODDIR/backup/`,
`$MODDIR/config-installed`, `$MODDIR/.prev-root-hash` or
`$MODDIR/.install-manifest` from an earlier release have them removed by the
first wipe, which is the correct outcome for all four.

## Risks

* **The `/tmp` HelixScreen stash becomes the only preservation mechanism in the
  installer.** It already is in practice — both current branches delete
  `$MODDIR/helixscreen` — but after this change a bug in it has no second line
  of defence. It should keep its own assertions in the rewritten gate.
* **An owner who edited `moonraker.conf` loses those edits with no copy left
  behind.** Chosen deliberately over a `.mod-old` courtesy copy: the docs say
  not to edit it, and the seam is `moonraker-custom.conf`.
* **Anyone who later adds printer-local state under `$MODDIR` loses it
  silently on the next update.** The manifest failed the same way — it could
  not see runtime-created paths either, which is exactly why the `etc/s6` and
  `__pycache__` sweeps had to be written by hand. This note and the gate are
  the mitigation; `/usr/data` is where such state belongs.
* **A power cut between the wipe and the extraction leaves no mod at all.** Not
  a regression: the manifest pass already deletes essentially the whole tree
  before extracting, so the exposure window is the same one that exists today.
  `app_startup.sh` restores a stock `firmwareExe` from a version directory and
  the printer still boots.

## The gate

`qa/replica/test_upgrade.py` rewritten against the same method it uses now: two
synthetic payloads built on the printer, the real `runFirmwareExe.sh` run over
them by the printer's own busybox, every question put to the filesystem
afterwards. The pair of claims it must hold changes shape — the "and only that"
half is gone, so the negative control moves from "a file nobody shipped
survives" to "a file nobody shipped is removed too":

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

`qa/static/test_ipk.py:457` (`test_every_payload_file_is_owned_by_a_package`)
loses `.install-manifest` from its allowlist, which shrinks that list to four —
`config/moonraker-custom.conf` and opkg's own `var`, `var/lib`, `var/run`.
Its own docstring at `qa/static/test_ipk.py:463` says that list "should shrink
and must not grow by accident". This shrinks it, and what remains is one user
file plus scaffolding opkg makes for itself.
