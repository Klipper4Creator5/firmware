Releases are named for a Ukrainian city under occupation. This one is
**Melitopol** again, taken by russian forces on the first day of the full-scale
invasion, 24 February 2022, and occupied ever since. Its mayor was abducted
within days for refusing to cooperate; the city has been under occupation
longer than almost any other in Ukraine.

*https://www.youtube.com/watch?v=w3uaZEQKJpY*

---

**HelixScreen moves to v0.99.115-creator5.4**, and the Filament screen is
rebuilt around the tool it acts on. It was designed for a printer with one
hotend: a single nozzle reading and a Load button that never said which head
they meant. It now opens with a row of tool chips — one per tool, carrying its
material, spool remaining and an amber border while that head holds a heat
target — and the nozzle reading, the graph and the preheat presets all follow
the tool you pick rather than whichever head is on the carriage. Extrude and
Retract stay disabled unless the selected tool is the mounted one.

The fix underneath it matters more than the layout: **preheat resolved "the
nozzle" to the active extruder**, so selecting T2 and pressing preheat heated
T0. Every nozzle target now goes to the selected tool's own heater, cooldown
builds its heater name the same way, and where no heater resolves the command
is dropped with a log line instead of being sent to the wrong hotend.

**A printer now ships knowing where its updates come from.** `anvil-core`
carries `/usr/data/anvil/etc/apk/repositories` naming the Reforge package
feed, so a machine installed from this release can fetch updates over the
network instead of needing a USB stick to learn that a feed exists. The host
it names is not answering yet — the pointer has to ship first, because a feed
cannot tell a printer where the feed is — and until it does, `apk upgrade`
reports the repository as unavailable and nothing else changes. Installing
from a stick works exactly as before.
