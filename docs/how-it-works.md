# How it works

## Reusing FlashForge's own updater

We reuse FlashForge's updater rather than writing a parallel one. The stock
chain, recovered from `app_startup.sh`, the `unTar` binary and the rootfs
image:

```
busybox init → /etc/init.d/rcS → S99factory_test_shell
             → /usr/prog/app_startup.sh
                 ├─ mounts /dev/sda* on /mnt, globs Creator5Pro-*.tgz
                 ├─ /usr/prog/bin/unTar  (des3 decrypt → /usr/data/update)
                 └─ runFirmwareExe.sh Creator5Pro 0029
                        └─ per component: extract → md5 gate → run.sh
             → firmwareExe  ← the UI, and what starts Klipper
```

The mod's entire integration point is **one file**: it replaces
`/usr/prog/PROGRAM/software/firmwareExe` with a shell script that runs
HelixScreen. Because everything funnels through that binary, `app_startup.sh`,
`rcS` and the whole init chain stay **completely stock and unpatched**. The
genuine binary is not kept anywhere — the stock installer wipes the software
directory before `run.sh` runs, so nothing on the printer could ever be a
reliable backup of it. Flashing the stock FlashForge package, which still
ships it, is the uninstall.

Two properties come for free from keeping that name and that place:

* `app_startup.sh`'s own watchdog greps `ps` for `firmwareExe` five seconds
  after launch. The wrapper *is* `firmwareExe` and stays in the foreground, so
  the stock watchdog supervises the mod correctly.
* If the wrapper is ever removed, `app_startup.sh` restores a `firmwareExe`
  from a version directory — the last entry of a plain `ls -ld [0-9]*`, which
  is alphabetical rather than version-sorted, though since the installer keeps
  only one directory there is normally just the one candidate. The stock
  recovery path still works.

## Services

Services are ordinary init.d-style scripts in `/usr/data/anvil/init.d/`, run in
filename order and individually restartable over ssh:

```
S50wifi      wlan0 + wpa_supplicant + udhcpc
S60nginx     nginx (Mainsail) on :80
S62moonraker moonraker on :7125
S65camera    mjpg-streamer on :8080 (nginx proxies it at /webcam/)
S70klipper   Klipper
S80ui        decides whether the UI runs (MOD_UI, HelixScreen installed?)
```

nginx and moonraker were one script, `S60web`, until they were split. They fail
separately and are debugged separately — nginx not starting is a missing config
or a port already bound, and you know within a second; moonraker not starting
is a component that failed to import, and it takes a background check and a log
tail to even notice. One script had to say `web: stopped` for both, and
`status` reported on two unrelated things at once. Now `S62moonraker restart`
over ssh — the one you run over and over while chasing a moonraker config — no
longer takes the web UI down with it. The numbering keeps the order: nginx
first, because it proxies the other two, so a browser gets a page saying the
backend is not up yet rather than a refused connection.

Two sourced libraries sit beside them, both installed to `/usr/data/anvil` and
neither executable:

* **`anvil-env.sh`** — `PATH`, `LD_LIBRARY_PATH` and `FF_PYTHON`, in the one
  place that defines them. `run-append.sh`, `firmwareExe`, `start.sh` and every
  service script source it. A private copy per script is how the installer's
  check and the boot script came to disagree about the library list, with
  moonraker dying on `libpython3.8.so.1.0: cannot open shared object file`.
* **`anvil-service.sh`** — the shape every service script has: `svc_say` /
  `svc_warn` for the boot log, `svc_pid_alive` and `svc_proc_alive` for
  liveness, `svc_start_daemon` / `svc_stop_daemon` around busybox
  `start-stop-daemon`, `svc_detach` for a wait that must not hold the boot up,
  and `svc_dispatch` for the `start|stop|restart|status` block. The scripts
  were written months apart and had arrived at four different answers to "is it
  still running?" and two to `restart`; none of those differences were
  decisions. The library also carries the two corrections busybox needs —
  `start-stop-daemon -K` returns before the process is dead, and does not
  remove the pidfile, which is how `restart` raced its own start and how
  `status` came to report a recycled pid as a running service. A script that
  cannot find this file says so and exits rather than half-starting.

Everything the mod installs lives under `/usr/data/anvil` on the **data**
partition, which a FlashForge OTA cannot delete. The software component itself
goes to `/usr/prog` on the firmware partition, which keeps only one version
(the installer wipes every other version directory) and cannot fit ~100MB of
web UI — that is why Mainsail and HelixScreen ride in
the outer package instead.

## Moonraker

The mod ships its own Moonraker (pinned in `versions.env`) and runs it from
`/usr/data/anvil/moonraker/moonraker.py`. FlashForge's is a 2022 build that reports API 1.0.5, old enough
that the current Mainsail hides features it cannot see. The visible one is the
camera: Moonraker only grew the webcam `enabled` flag in April 2023, Mainsail
filters its webcam list on exactly that field, and so every `[webcam]` entry is
discarded and the panel disappears — while the stream itself is perfectly
healthy behind nginx. No config change can fix that from either side.

**It is installed by being extracted.** The tree rides in the mod payload, the
payload unpacks to `/usr/data/anvil`, and that is the whole installation —
there is no separate Moonraker step that can fail on its own. Nothing is
written to `/usr/prog`: FlashForge's tree at `/usr/prog/moonraker/moonraker/`
is left exactly where it is and simply never used again, and
`S62moonraker` starts ours by absolute path with no fallback.

An earlier release copied the same tree over `/usr/prog/moonraker` as well.
That is gone. It put a second, byte-identical Moonraker on the one partition
with no room to spare — the only step of the install that could fail on disk
space, failing as "no working web UI" — and because `/usr/prog` is what a stock
FlashForge flash overwrites while `/usr/data/anvil` survives one, it made
"which Moonraker is this printer running?" depend on what was flashed last.
Both things thought to require that location turned out not to: the
`moonraker-env` virtualenv beside it was never on `sys.path` (checked by
running the printer's own interpreter against the real image), and
`moonrakerDaemon`, the one thing that did exec that tree by absolute path, is
never invoked — `S62moonraker` starts the server itself.

**FlashForge's python 3.8.2 is not what this runs on any more.** `FF_PYTHON`
in `anvil-env.sh` names a CPython 3.13 of our own, cross-built for mipsel by
`pkg/python`, with every third-party C extension Moonraker needs beside it in
`$MODDIR/lib/python3.13/site-packages` — eighteen packages, one `pkg/python-*`
recipe and one `.ipk` each — and libsodium in `$MODDIR/lib`; none of it
borrowed from `/usr/prog`. Measured through the
real boot path (S40s6's scandir, `S62moonraker`, readiness gating on `:7125`
actually listening, a `kill -9` respawn, a stop that stays stopped) in
`test/integration/printer/case-moonraker313-s6.sh`. klippy is not part of
this: it stays on FlashForge's 3.8.2, started independently by
`/usr/prog/klipper/start.sh`.

**The Moonraker commit pin is still a 2023 one, though the reason it exists
has changed.** FlashForge built python 3.8.2 without the `_sqlite3` module,
and Moonraker moved its database from lmdb to sqlite in v0.9.0, so on 3.8.2
every release from there on got as far as loading the database component and
died with `ModuleNotFoundError: No module named '_sqlite3'`. Our 3.13 has a
working `_sqlite3` (measured in `case-python.sh`: create, insert, select,
reopen), which is what unpins this -- but the pin has not moved yet: nobody
has taken a newer Moonraker through this build and its replica gates, and a
version bump is exactly the kind of change that wants its own measurement,
not a side effect of an interpreter switch. Until it does, the printer's lmdb
store is used in place -- nothing is converted, and reverting to stock is a
clean round trip.

This was not worked out in advance; v0.9.3 was built, shipped and tried on the
printer first, and that is what it said. Two things came out of it. The
installer now asks the printer's own python to import the tree *before* moving
anything, and keeps the stock server if it cannot — a bad pin refuses to
install instead of leaving the machine with no web UI. And when bumping the
pin, the blocker to check is native modules, not the python version.

Moonraker does not come from the update package at all — it exists only on the
factory image, and the stock `run.sh` copies a hand-written list of paths out
of the software component rather than extracting it over `/usr/prog`. So the
tree travels with the mod payload and `run-append.sh` puts it in place, moving
the old one aside first and restoring it if the copy does not complete.

`make test` covers this end to end on the printer replica: that the swap
happened, that the installed `webcam.py` has the `enabled` field, that the
shipped tree runs on the printer's own python3.8 **and is still running after a
settle**, and that its log has no import errors. The settle matters — a build
that dies on a missing module is alive for a second or two first, and checking
only "did it start" is what let the sqlite3 failure through.
`BUILD_MOONRAKER=0` builds a package that leaves the stock server alone.

## Five things the stock firmware does that will surprise you

Each of these silently breaks a package or a printer, and each is enforced by
a check in `make test`:

| | Reality |
|---|---|
| **`*.tar.xz` is not xz** | The components are plain tar archives carrying an `.xz` name. The installer runs a bare `tar -xvf`, so a genuinely xz-compressed file does not install. |
| **`.tgz` is not gzip** | DES3-encrypted plain tar. The key is hardcoded in the printer's own `unTar` binary. Modern OpenSSL needs `-md md5` to match its OpenSSL 1.0.2. |
| **Nothing in init starts Klipper** | `firmwareExe` runs `/usr/prog/klipper/start.sh`. Replace the UI without accounting for this and the printer boots to a working screen that cannot move or heat. |
| **The installer wipes the software dir first** | `ls \| grep -v temp \| xargs rm -rf` runs *before* `run.sh`, so the previous `firmwareExe` is already gone. Uninstalling means flashing the stock package, which still **ships** the genuine binary; nothing can back one up. |
| **Binaries must be nan2008** | The Ingenic X2000 kernel returns `ENOEXEC` for legacy-NaN MIPS. Debian's `gcc-mipsel-linux-gnu` cannot produce a usable binary — its libc is legacy-NaN. |

**And one pleasant surprise, found by unpacking `rootfs.squashfs` out of the
kernel component:** ssh needs no work at all. The stock rootfs already ships
`/usr/sbin/dropbear` and an enabled `/etc/init.d/S50dropbear`, so port 22 is
*already open* on a stock printer. There is simply no published root password.
Setting `ROOT_PW_HASH` is the whole feature.

## Two models, two packages

Creator 5 and Creator 5 Pro are **not interchangeable**. Each stock package
carries a `MACHINE=`/`PID=` gate that refuses to install on the other model,
and — the part that actually matters — they ship **different `firmwareExe`
binaries**. A package built for one model would hand the other the wrong
firmware, so each must be built from its own stock package.

| Model | MACHINE | PID | USB filename the printer looks for |
|---|---|---|---|
| Creator 5 | `Creator5` | `0028` | `/mnt/Creator5-*.tgz` |
| Creator 5 Pro | `Creator5Pro` | `0029` | `/mnt/Creator5Pro-*.tgz` |

The filename prefix and the gate inside must agree: `app_startup.sh` globs for
the prefix, and `runFirmwareExe.sh` checks the gate. A mismatch means the
printer picks the file up and then refuses it. `make verify` and
`bin/verify.sh` both check this.

## Recovery

Recovery is the stock FlashForge package for your model. Flashing it restores
the files the mod replaced out of that package; the payload under
`/usr/data/anvil` survives but is inert. `make test-recovery` does exactly that
inside the replica and compares `firmwareExe`, `app_startup.sh` and
`klipper/start.sh` byte for byte, and checks that nothing stock still
references the leftovers.

One thing it does not cover, worth knowing before you rely on it:

* **Moonraker.** The mod's Moonraker lives on the data partition at
  `/usr/data/anvil/moonraker`, and it is started by
  `/usr/data/anvil/init.d/S62moonraker` — which a stock flash removes along
  with the rest of the mod's boot path. So a stock reflash goes back to
  FlashForge's own 2022 tree at `/usr/prog/moonraker/moonraker/`, which was
  never touched and is still exactly what the factory image shipped. The mod's
  copy is left behind on `/usr/data` and is inert: nothing stock knows the path.

  This used to be a caveat in the other direction. An earlier release installed
  its Moonraker over `/usr/prog/moonraker`, keeping the stock tree beside it as
  `moonraker.modold` and deleting that once the copy succeeded — so a stock
  reflash silently kept running the mod's build, and losing power mid-swap left
  the printer with no Moonraker at all and needed a hand-run `mv` over ssh to
  put the `.modold` tree back. Neither the `.modold` path nor the recovery
  instruction exists any more. If Moonraker is missing or broken now, the fix
  is to reflash the mod package: it carries the whole tree, and extracting the
  payload is the entire installation.
