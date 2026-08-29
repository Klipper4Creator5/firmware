---
name: reforge-docs
description: The layout of Reforge's documentation — which sections exist, what belongs in each, and what must never appear there. Use when writing, revising, restructuring or de-jargoning any page under docs/, when adding a page or changing the mkdocs nav, when explaining a change to printer owners, or when the published site needs rebuilding or looks stale. Craft and voice live in the docs-writer agent; this is the map.
---

# Reforge documentation: the map

The docs are built from this repo by MkDocs (`mkdocs.yml`) and published at
reforge.readthedocs.io. This file says where things go. How to write them —
voice, honesty, verifying claims — is `.claude/agents/docs-writer.md`; read
that too if you are writing prose rather than moving it.

## The three sections

| Section | Reader | The test |
|---|---|---|
| **Using Reforge** | owns the printer, may never have used Klipper | can they act on it without knowing what Klipper is? |
| **For experienced users** | knows Klipper, wants to change what the machine does | is it mechanism or an override knob, rather than a walkthrough? |
| **For contributors** | builds, tests or changes the firmware | does it involve the build system or the binary? |

A reader should never fall from one section into the next. That is the whole
point of the split, and every rule below follows from it.

## What belongs in each, and what does not

### Using Reforge

Task-shaped and ordered by what the reader is doing, not by which subsystem
owns the answer. Someone whose printer will not boot should not have to know
that the symptom table lives in a file called `hardware-testing.md`.

- **The premise is that the machine works.** The factory calibration imports
  itself on the first boot, a bed mesh loads at the start of every print, and
  a stock-sliced file prints unchanged. Do not write pages that assume the
  printer arrives broken and must be proved safe.
- **Optional steps must say they are optional.** If a step is recommended
  rather than required, say which, and say why it is worth the minutes.
- **Filenames and internals only when the reader has to type them or look at
  them.** `anvil-password.txt` and `printer.cfg` earn their place. These do
  not: `[ff_legacy]`, `SAVE_CONFIG`, `dropbear`, `ROOT_PW_HASH`, `ff-*.cfg`
  inventories, Klipper section names, binary addresses.
- **No theory sections, expected-output dumps, parameter references or
  symptom tables.** Each of those was written here and removed. If the
  material is worth keeping, it belongs one section down.

### For experienced users

The mechanism, and the knobs that change it, for someone who already knows
Klipper and does not want a walkthrough.

- Explain how something behaves and how to override it. Config syntax and
  macro names are welcome here.
- Overrides go at the end of the reader's `printer.cfg`, restating only what
  changes — never by editing a shipped `ff-*.cfg`, which an update replaces.
- Not the build system, and not reverse-engineering detail: both are one
  section further down.

### For contributors

Building, testing, the printer replica, and the reverse-engineering notes in
`docs/notes/`. Nothing here should be a page an owner is sent to.

## Adding or moving a page

1. Pick the section with the table above. If two fit, the page is probably two
   pages.
2. Add a `nav:` entry in `mkdocs.yml`. **A page absent from the nav still
   builds, but nothing links to it and nobody will find it.**
3. Link it from a sibling page, so it is reachable by reading rather than only
   by navigating.
4. Check `docs/notes/` first — the material often already exists there, and
   the honest move is to lift and rewrite it rather than write it twice.

Two pages are parked in `not_in_nav` on purpose: **`printing.md`** and
**`upgrading.md`**. They were cryptic for the reader they were aimed at and
are kept to be rewritten, not deleted. `upgrading.md` also carries a stale
claim about FlashForge's Moonraker not surviving a recovery flash — fix that
before it is ever re-listed.

## Before you write a claim

Two checks, both cheap, both skipped here at least once:

- **"The mod gives you X" needs the ownership table.**
  `docs/notes/25-app-vs-klipper-ownership.md` marks which behaviour is
  **ported** from the stock application and which is genuinely absent from it.
  Tool calibration and input shaping are ports — the touchscreen's own
  sequences, recovered and reimplemented — and claiming them as gains is
  wrong. The real gains, so they need not be re-derived:
  - anything speaking Moonraker can drive the machine at all. FlashForge's
    Klipper does not toolchange: it raises a flag and waits for the
    application, so a Mainsail-started print hangs at the first `T2`
    (`docs/notes/20-klipper-fork.md`).
  - the print lifecycle exists as readable Klipper macros instead of policy
    inside a binary.
  - a current Moonraker, so a current Mainsail stops hiding features.
- **The premise check.** See *Using Reforge* above.

## Building and checking

```sh
python3 -m venv .venv && .venv/bin/pip install -r docs/requirements.txt
.venv/bin/mkdocs serve            # preview at 127.0.0.1:8000
.venv/bin/mkdocs build --strict   # what CI and Read the Docs run
```

**`--strict` validates markdown links and nothing else.** Raw HTML, images and
task lists are invisible to it — three render bugs shipped to master through
exactly that gap. Serve the site and look at it, and open a page that is *not*
the front page to confirm images resolve there too.

Mechanics worth knowing before they cost an hour:

- `hooks/mkdocs_readme.py` is imported once at startup. **Restart
  `mkdocs serve` after editing the hook**, or you will debug stale output.
- `docs/index.md` is generated from `README.md` on every build and gitignored.
  Edit the README.
- Write links repo-relative, the way they must read on GitHub. The hook
  rewrites the ones that leave `docs/` into GitHub URLs, and leaves a link
  whose target does not exist alone so `--strict` still fails on it.
- Anchors follow GitHub's slug rules, so `#runout--clog` resolves in both
  places.

## Editing safely

- **Anchor edits on unique strings, never line numbers.** A file rewritten
  earlier in the same session invalidates every offset — that caused a real
  bug here, where a section was rebuilt from a README that had already been
  replaced.
- When the working copy has already been rewritten, take the original from
  `git show HEAD:<path>` rather than from the file in front of you.
- **Write against the branch whose code ships.** `qa-suite-bridgehead`
  describes s6-rc services; master ships `init.d`. Before lifting text out of
  a page, `git diff origin/master..HEAD -- <file>`.

## When the published site looks stale

Check the builds before assuming a failure:

```sh
curl -s https://readthedocs.org/api/v3/projects/reforge/builds/
```

As of 2026-08-28 the repo had **no webhook**, so Read the Docs was never told
about pushes and the site sat on an old commit. Confirm whether that is still
true before diagnosing anything else.

## Known gaps

- Input shaping is described in *How calibration works* but has no procedure
  page. The material is in `docs/toolchange.md` §Input shaper.
- Whether HelixScreen's bed-mesh screen saves into `MESH_DATA` or `default` is
  unverified, and it matters: a print loads `MESH_DATA`.
