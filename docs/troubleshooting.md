# When something goes wrong

Start here, in this order: the logs say what happened, the symptom table says
what to do, and the stock package undoes all of it.

There are people to ask on [the Discord](https://discord.gg/ggJyfgVA4v).
Bring the logs.

---

## The undo button

**Flash the stock FlashForge package for your model.** It restores everything
it carries and installs the same way — stick in, power on. Keep one on a
spare stick before you start; the stock packages are published at
[ghzserg/FF](https://github.com/ghzserg/FF/releases).

The one thing it cannot bring back is FlashForge's Moonraker: the stock
package does not carry it, so the mod's build stays — it works, and Mainsail
is happy with it ([details](how-it-works.md#recovery)). The symptom table,
the logs worth reading and the factory-restore last resort are below.

---

## Symptoms

| Symptom | Do this |
|---|---|
| Printer boots, screen blank | ssh in; `/usr/data/anvil/init.d/S80ui status` says whether the UI was even started. No on-device repair — reflash the mod, or flash the stock package to get FlashForge's UI back. ssh, Mainsail and printing are unaffected |
| No ssh, no screen | flash the stock package for your model |
| Recovery stick does not help | try a newer stock FlashForge package for your model |
| Still broken | factory package (`Creator5Pro-factory-*.tgz` **plus** the separate `Creator5Pro-factory.tar.xz` on the same stick; needs 800 MB free) |

The mod never creates a mount point named like a mod, specifically so that
FlashForge's factory-restore package — which greps the mount table for a
known community mod's name and refuses to run when it matches — remains
usable as a last resort.

---

## The logs

**Logs worth reading, all on the data partition and all surviving a reboot:**
```
/usr/data/anvil-install.log      what the installer did
/usr/data/logs/anvil-boot.log    services + UI choice at each boot
/usr/data/logs/printer.log     klipper
/usr/data/logs/helixscreen.log helixscreen
```

---

## A dark screen

**A bad UI is not repairable on the printer.** There is no fallback interface:
FlashForge's binary is replaced and HelixScreen is the only thing that draws on
the screen. ssh tells you *why* it is dark, but nothing you can set on the
machine will make it light up again:

```sh
ssh root@PRINTER
/usr/data/anvil/init.d/S80ui status        # what did it choose, and why
# chose "none"  -> MOD_UI=0, or HelixScreen is not installed
# chose "helix" -> it was started and failed on its own; see its log
```

`MOD_UI=0` only stops it being started at all — useful to silence a UI that
interferes with something else, not a repair. The actual fix is to flash a
package again: the mod, if you have a corrected build, or the stock FlashForge
package for your model to go back to FlashForge's own interface.
