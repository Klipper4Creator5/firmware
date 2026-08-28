# Support

Two things between them cover most of what can go wrong: the logs say what
happened, and flashing the stock package undoes everything.

There are people to ask on [the Discord](https://discord.gg/ggJyfgVA4v).
Bring the logs.

---

## The undo button

**Flash the stock FlashForge package for your model.** It restores everything
it carries and installs the same way — stick in, power on. Keep a copy
downloaded before you start; the stock packages are published at
[ghzserg/FF](https://github.com/ghzserg/FF/releases).

---

## The logs

All on the data partition, and all surviving a reboot:

```
/usr/data/anvil-install.log      what the installer did
/usr/data/logs/anvil-boot.log    services + UI choice at each boot
/usr/data/logs/printer.log       klipper
/usr/data/logs/helixscreen.log   helixscreen
```
