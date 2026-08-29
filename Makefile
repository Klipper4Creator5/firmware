# creator5-custom-firmware
#
# Nothing runs on your machine except Docker. Every target below executes
# inside the pinned build image (docker/Dockerfile.build); the docker socket
# is mounted through so the simulation targets can start sibling containers.
#
#   make build                  build the firmware package
#   make test                   full brick-safety suite
#   make shell                  interactive shell in the build container
#
# Escape hatch: LOCAL=1 make <target> runs the scripts directly on the host.

# Packages carry only the software component by default: the stock installer
# skips absent components, so the kernel and the MCU/board firmware are left
# alone. FULL=1 carries all four (and reflashes the MCU).
FULL    ?=
PACKARGS = $(if $(FULL),--full,)
DOCKER  ?= docker
IMAGE   ?= creator5-fw-build
LOCAL   ?=

DOCKER_SOCK := /var/run/docker.sock

# The repo is mounted AT ITS REAL HOST PATH, not at /src. The test targets
# start sibling containers through the mounted docker socket, and those are
# created by the host daemon -- which resolves -v paths on the HOST. If the
# build container saw the repo as /src it would ask the daemon to mount a
# /src that does not exist there, and the sibling would get empty
# directories. Keeping the path identical on both sides avoids that entirely.
# config.env usually points at a stock package OUTSIDE this repo, so the
# directory holding it must be mounted too. Override when yours lives
# elsewhere:  make ASSET_ROOT=/path/to/parent build
ASSET_ROOT ?= $(firstword $(wildcard /mnt/c /Users /home))

# Two runners, because the two lanes need different things:
#
#   RUN     builds the thing you flash. No docker socket, no replica settings.
#   RUNSIM  runs the test replica. It starts SIBLING containers through the
#           mounted socket, so it needs that plus the replica's own knobs.
#
# Keeping them apart is the point of the split: a build cannot reach the docker
# daemon, and test-only variables never enter a build.
DOCKER_BASE = $(DOCKER) run --rm -i \
          -v "$(CURDIR)":"$(CURDIR)" -w "$(CURDIR)" \
          $(if $(ASSET_ROOT),-v "$(ASSET_ROOT)":"$(ASSET_ROOT)",) \
          -e MODEL -e TARGET_MACHINE -e CONFIG_ENV

# THE BUILD LANE RUNS AS YOU, NOT AS root. Without this every `make build` and
# `make packages` fills work/ with root-owned files that the user who started
# it cannot delete -- so the next `rm -rf work/pkg` fails, and the tempting fix
# is to run the build outside the container instead. That is how a project ends
# up with two build environments and packages that differ depending on which
# one produced them, which is exactly what this image exists to prevent.
#
# HOME is set because a container user with no passwd entry has none, and
# anything that wants a dotfile (perl, pip) writes to / and fails.
#
# BUILD LANE ONLY. RUNSIM below keeps root: it talks to the docker socket to
# start sibling containers, and the socket's ownership inside the container is
# not the host user's.
DOCKER_USER = --user $(shell id -u):$(shell id -g) -e HOME=/tmp

ifeq ($(LOCAL),)
  RUN    = $(DOCKER_BASE) $(DOCKER_USER) $(IMAGE)
  RUNSIM = $(DOCKER_BASE) \
          -v $(DOCKER_SOCK):$(DOCKER_SOCK) \
          -e TEST_ENV -e PRINTER_IMAGE -e REAL_PKG -e SIM_IMAGE \
          -e SIM_VERBOSE -e PROG_MB -e DATA_MB -e PROG_DUMP -e REQUIRE_PRINTER_SIM \
          $(IMAGE)
  RUNTTY = $(subst --rm -i,--rm -it,$(RUNSIM))
else
  RUN =
  RUNSIM =
  RUNTTY =
endif

# The build-lane runner with a tty, for targets that prompt. Derived from RUN,
# not RUNSIM: prompting needs no docker socket and no replica knobs.
RUNBLDTTY = $(subst --rm -i,--rm -it,$(RUN))

.DEFAULT_GOAL := help
.PHONY: help image shell passwd build vendor packages \
        rootfs verify test test-py test-install \
        printer-image printer-image-push \
        test-recovery test-mcu test-boot-screen test-moonraker test-services \
        test-libpath \
        test-upgrade test-supervisor test-nginx test-camera test-python \
        test-moonraker313 test-priority \
        boot-screen boot-screen-sim \
        qa qa-static qa-replica \
        release clean distclean

help:
	@echo 'creator5-custom-firmware -- everything runs in Docker'
	@echo
	@echo 'Build (see docs/hardware-testing.md before you flash):'
	@echo '  make build        the firmware  Klipper fork, toolchanger, Mainsail,'
	@echo '                                  ssh and HelixScreen'
	@echo '  make release      build BOTH models into dist/'
	@echo '  make packages     .ipk packages + feed index into work/packages/'
	@echo '                    (make build INSTALLS these to make the payload,'
	@echo '                     so run this first; needs no stock package.'
	@echo '                     PKG=<name> builds that recipe and the ones'
	@echo '                     it builds against -- see'
	@echo '                     docs/notes/85-packaging.md)'
	@echo
	@echo 'Models: packages are model-specific and refuse to install on the'
	@echo 'other one. MODEL=Creator5 make build  builds the non-Pro variant.'
	@echo
	@echo 'Recovery: keep a copy of the STOCK FlashForge .tgz on a spare stick.'
	@echo 'Flashing it restores every file the mod touches (see make test-recovery).'
	@echo
	@echo 'Test (qa/ -- the new suite, one framework, per-assertion results):'
	@echo '  make qa               both lanes'
	@echo '  make qa-static        needs nothing: parses, bashisms, names, probes'
	@echo '  make qa-replica       needs docker + the firmware'
	@echo '                        pytest selection works: -k, -m, a single test id'
	@echo
	@echo 'Test (test/ -- the old suite, still the release gate; being migrated):'
	@echo '  make test             all of them, and the shell/bashism/packaging'
	@echo '                        passes that have no target of their own'
	@echo '  make test-py          pytest: the whole test/ tree'
	@echo '  make test-install     end-to-end: USB stick -> update -> reboot'
	@echo '  make test-mcu         ff_mcu_bringup.py runs on the printer own python'
	@echo '  make test-boot-screen the first-boot screen draws on the replica fb0'
	@echo '  make test-moonraker   S62moonraker starts moonraker on the printer own python'
	@echo '  make test-services    every init.d service dispatches the same way'
	@echo '  make test-libpath     every library on LD_LIBRARY_PATH is one something maps'
	@echo '  make test-upgrade     an update deletes what it installed, and only that'
	@echo '  make test-supervisor  the s6 we cross-compiled supervises and waits'
	@echo '  make test-nginx       nginx runs under s6, and a stop stays stopped'
	@echo '  make test-camera      readiness gates: ready means serving, not forked'
	@echo '  make test-python      the cross-built CPython 3.13 runs, with a real sqlite3'
	@echo '  make test-moonraker313 the real moonraker on that 3.13, supervised by s6'
	@echo '  make test-priority    services start at the nice value anvil.conf sets'
	@echo '  make test-recovery    install mod -> flash stock -> back to stock'
	@echo
	@echo 'Look at things:'
	@echo '  make boot-screen      render the first-boot screen to work/boot-screen/*.png'
	@echo '  make boot-screen-sim  the same, drawn by the printer own python in the replica'
	@echo
	@echo 'test-py needs python3, pytest and jinja2; its rootfs checks skip'
	@echo 'until make rootfs has run. The other'
	@echo 'three run inside a replica of the printer: the real rootfs.squashfs'
	@echo 'under qemu-mipsel, with /usr/prog installed by FlashForge own updater.'
	@echo 'test-install goes the whole way -- the package sits on a real FAT'
	@echo 'filesystem at /dev/sda1 and the printer own app_startup.sh finds it,'
	@echo 'installs it, and boots. They need make rootfs first (or PRINTER_IMAGE),'
	@echo 'which needs the stock package.'
	@echo
	@echo 'A gate that cannot run is reported SKIP, not ok, and make test then'
	@echo 'fails. ALLOW_SKIP=1 accepts any gap; ALLOW_SKIP="a,b" accepts only'
	@echo 'the gates named, which is what CI uses. Either way every skip is'
	@echo 'listed again at the end, with its reason.'
	@echo
	@echo 'Other:'
	@echo '  make passwd       a ROOT_PW_HASH for config.env (prompts, echoes the hash)'
	@echo '  make vendor       download Mainsail + HelixScreen + Moonraker'
	@echo '  make rootfs       extract the real printer rootfs (enables the replica gates)'
	@echo '  make image        build the build container'
	@echo '  make shell        shell inside it'
	@echo '  make clean | distclean'
	@echo
	@echo 'Packages carry only the software component; the kernel and MCU are'
	@echo 'left untouched. FULL=1 make <target> carries all four components.'
	@echo
	@echo 'Config: config.env is the BUILD config (what ships). test.env holds'
	@echo 'the replica settings, which never reach a printer. Copy the .example'
	@echo 'of each. LOCAL=1 make <target> runs on the host instead of in Docker.'

image:
	@$(DOCKER) build -q -t $(IMAGE) -f docker/Dockerfile.build docker >/dev/null && echo "image $(IMAGE) ready"

config.env:
	@echo 'no config.env -- copy the example and edit the paths:'; \
	 echo '    cp config.env.example config.env'; exit 1

shell: image
	@$(RUNTTY) bash

# A ROOT_PW_HASH for config.env, generated INSIDE the pinned build image so
# the same python makes the same $6$ sha512-crypt everywhere. Host tools are
# not dependable here: LibreSSL's openssl has no `passwd -6` at all.
passwd: image
	@$(RUNBLDTTY) python3 -W ignore -c 'import crypt, getpass; print(crypt.crypt(getpass.getpass("password: "), crypt.mksalt(crypt.METHOD_SHA512)))'

# ===========================================================================
#  BUILD LANE -- produces the package you flash. Reads config.env, ships
#  payload/ and assets/, and touches nothing under test/.
# ===========================================================================

# Mainsail, HelixScreen and Moonraker are not vendored in the repo. bin/build.sh fetches
# what the build needs; this target pre-fetches everything, and is a
# no-op once vendor/ holds files with the sha256 that versions.env pins.
vendor: image config.env
	@$(RUN) ./bin/fetch-assets.sh --all

# A THIRD LANE, and it exists because the build now needs both halves of the
# split above. bin/patch.sh assembles the payload by starting the printer
# replica and letting the machine's own opkg install the feed, so this lane
# needs the docker socket -- and it still has to run AS YOU, or every build
# leaves a root-owned work/ that the next one cannot delete.
#
# --group-add is what makes those compatible. RUNSIM keeps root purely because
# the socket is root:docker and a --user container has no supplementary
# groups; handing it the socket's own gid answers that without handing it
# root. The gid is read from the socket rather than assumed, because it is
# 999 on some distributions and 1001 here.
RUNBUILD = $(DOCKER_BASE) $(DOCKER_USER) \
          --group-add $(shell stat -c %g $(DOCKER_SOCK)) \
          -v $(DOCKER_SOCK):$(DOCKER_SOCK) \
          -e TEST_ENV -e PRINTER_IMAGE -e SIM_VERBOSE -e PROG_MB -e DATA_MB \
          -e PROG_DUMP \
          $(IMAGE)

build: image config.env
	@$(RUNBUILD) ./bin/build.sh $(PACKARGS)

# The package feed (docs/notes/85-packaging.md). Builds every
# recipe under pkgs/ into work/packages/ as .ipk files plus the feed index that
# makes that directory an opkg repository.
#
# THE RELEASE PATH IS BUILT ON THIS. It used to say the opposite -- "nothing
# on the release path depends on this" -- and that was already false when it
# was written: pkgs/3rdparty/python declares seven build dependencies, pkg_deps
# resolves them by unpacking their .ipk out of work/packages, and bin/patch.sh
# builds none of the seven. `make build` on a cold checkout has never worked
# without this target; it failed deep inside a recipe instead of saying so.
# bin/patch.sh now checks for the feed up front and names this command.
#
# It still, unlike `build`, needs NO stock FlashForge package -- which is most
# of the point: packaging has to be runnable in CI on a bare checkout, or the
# gate only runs where the proprietary firmware is and stops being a gate.
packages: image config.env
	@$(RUN) ./bin/build-packages.sh $(PKG)

# One package per model, collected in dist/. They cannot share content: the
# two stock packages ship different firmwareExe binaries.
release: image config.env
	@rm -rf dist && mkdir -p dist
	@for m in Creator5Pro Creator5; do \
	   echo "=== $$m ==="; \
	   MODEL=$$m $(RUN) ./bin/build.sh $(PACKARGS) || exit 1; \
	   MODEL=$$m $(RUN) ./bin/verify.sh || exit 1; \
	   cp work/out/$$m-*.tgz dist/ || exit 1; \
	 done
	@echo; echo "dist/:"; ls -lh dist | awk 'NR>1{print "   "$$9"  "$$5}'
	@echo; echo "Each file installs ONLY on the model in its name."

verify: image
	@$(RUN) ./bin/verify.sh

# ===========================================================================
#  TEST LANE -- never ships. Reads test.env for the replica settings; the only
#  targets allowed to reach the docker daemon ($(RUNSIM)).
# ===========================================================================

# The replica needs this: rootfs.squashfs is the printer's real userland and
# it only exists inside the stock package's kernel component.
rootfs: image config.env
	@$(RUN) ./bin/unpack.sh >/dev/null
	@$(RUN) ./test/integration/extract-rootfs.py

test: image
	@$(RUNSIM) ./test/run-tests.py

# ---------------------------------------------------------------------------
#  THE qa SUITE -- the replacement, running beside the one above.
#
#  Same machine, same gates, one framework. See qa/conftest.py for the lanes
#  and docs/qa-migration.md for what moves when. Both suites run in CI until a
#  case-*.sh has a green replacement here, and then that case script is
#  deleted -- so there is never a window where coverage drops.
#
#    make qa           both lanes
#    make qa-static    needs nothing: parses, bashisms, names, the probes
#    make qa-replica   needs docker + the firmware
#
#  There is no strictness flag and there is nothing to remember to pass. A
#  missing tool, daemon, replica image or package FAILS, at the point that
#  needs it, with the fix in the message. Skips are reserved for a question
#  that does not apply to this configuration, and there are currently none.
#
#  The replica lane needs two things, and says so if either is absent:
#
#    a base replica   PRINTER_IMAGE in test.env (see test.env.example), or
#                     `make rootfs` from the stock package
#    a package        work/out/*.tgz, from `make build`
#
#  It needs the package because it INSTALLS it, through the printer's own
#  app_startup.sh off a real FAT stick, rather than hand-placing payload/.
#  That way the install is under test too, and the payload under test is the
#  built artefact -- s6 and CPython included, neither of which exists in
#  payload/. Baked into an image once per package and cached on its md5.
# ---------------------------------------------------------------------------
qa: image
	@$(RUNSIM) python3 -m pytest ./qa -q

qa-static: image
	@$(RUN) python3 -m pytest ./qa/static -q

qa-replica: image
	@$(RUNSIM) python3 -m pytest ./qa/replica -q

# A Docker image that IS the printer: real rootfs, real /usr/prog and
# /usr/data, with the stock package already installed on top of them.
#
# Both of those are per-run costs it removes. Measured on this repo:
#
#   unpacking the 182MB factory image        22s   every run
#   installing the stock package under qemu   37s   every run
#   with the image                           0.7s   once, at build time
#
#   make printer-image           build (one image serves both models)
#   make printer-image-push      build and push to Docker Hub
#
# Point PRINTER_IMAGE in test.env at it to use it.
#
# The image contains proprietary FlashForge firmware.
printer-image: image
	@$(RUNSIM) ./test/integration/build-printer-image.sh

printer-image-push: image
	@$(RUNSIM) ./test/integration/build-printer-image.sh --push

# The Python gate. The checks that read the printer's rootfs skip without one;
# everything else runs on any checkout.
test-py: image
	@$(RUN) python3 -m pytest ./test -q

test-mcu: image
	@$(RUNSIM) ./test/integration/printer-exec.py ./test/integration/printer/case-mcu-bringup.sh

# The first-boot screen, drawn by the printer's own python onto the replica's
# /dev/fb0. `make boot-screen` needs nothing but this checkout and renders the
# same frames to PNGs you can look at.
test-boot-screen: image
	@$(RUNSIM) ./test/integration/printer-exec.py ./test/integration/printer/case-boot-screen.sh

test-moonraker: image
	@$(RUNSIM) ./test/integration/printer-exec.py ./test/integration/printer/case-moonraker.sh

test-services: image
	@$(RUNSIM) ./test/integration/printer-exec.py ./test/integration/printer/case-services.sh

# ANVIL_LIBS, asked of the loader rather than of the file. Needs no s6 and no
# tarball: what is under test is which libraries a running process maps.
test-libpath: image
	@$(RUNSIM) ./test/integration/printer-exec.py ./test/integration/printer/case-libpath.sh

# THE SUPERVISION TARBALL, merged from three recipe outputs -- execline, s6 and
# s6-rc (skalibs ships nothing). The .version stamps are dropped on the way:
# they are build artefacts, and one arriving on the replica would be a file
# under $MODDIR that no install manifest accounts for.
work/.s6-gate.tgz: FORCE
	@rm -rf work/.s6-gate && mkdir -p work/.s6-gate
	@for t in work/pkg/execline work/pkg/s6 work/pkg/s6-rc; do \
		[ -d $$t ] || { echo "!! $$t is missing -- run 'make packages' first" >&2; exit 1; }; \
		cp -a $$t/. work/.s6-gate/; \
	done
	@rm -f work/.s6-gate/.version
	@tar -czf $@ -C work/.s6-gate bin libexec
FORCE:

# s6 itself, as the build produced it -- not a stand-in. Needs the recipe
# outputs under work/pkg, which `make packages` fills; the full suite builds this
# tarball for itself, this target is for running the one gate on its own.
test-supervisor: image work/.s6-gate.tgz
	@$(RUNSIM) ./test/integration/printer-exec.py ./test/integration/printer/case-supervisor.sh sup.tgz=work/.s6-gate.tgz

# The two services that moved into the scandir. Same tarball, same reason:
# what is under test is s6 supervising OUR service definitions, so a stand-in
# supervisor would be testing the wrong half.
test-nginx: image work/.s6-gate.tgz
	@$(RUNSIM) ./test/integration/printer-exec.py ./test/integration/printer/case-nginx.sh sup.tgz=work/.s6-gate.tgz

test-camera: image work/.s6-gate.tgz
	@$(RUNSIM) ./test/integration/printer-exec.py ./test/integration/printer/case-camera.sh sup.tgz=work/.s6-gate.tgz

# EVERY PYTHON RECIPE OUTPUT, MERGED, exactly as work/.s6-gate.tgz merges
# three. CPython is pkgs/3rdparty/python and each third-party package a
# pkgs/3rdparty/python-* of its own, so what a printer sees is the union of
# their bin/ and lib/ -- which is what the payload gets by installing them
# and what test/ffsim/gates.py packs for the suite.
work/.py-gate.tgz: FORCE
	@rm -rf work/.py-gate && mkdir -p work/.py-gate
	@[ -d work/pkg/python ] || { echo "!! work/pkg/python is missing -- run 'make packages' first" >&2; exit 1; }
	@for t in work/pkg/python work/pkg/python-*; do \
		[ -d $$t ] || continue; \
		cp -a $$t/. work/.py-gate/; \
	done
	@rm -f work/.py-gate/.version
	@tar -czf $@ -C work/.py-gate bin lib

# The CPython 3.13 the build cross-compiles, on the printer's own kernel.
# Needs the recipe outputs under work/pkg, which `make packages` fills -- the same
# relationship test-supervisor has to work/pkg/s6. See the header of
# case-python.sh for why this has a gate of its own.
test-python: image work/.py-gate.tgz
	@$(RUNSIM) ./test/integration/printer-exec.py ./test/integration/printer/case-python.sh py.tgz=work/.py-gate.tgz

# The real Moonraker, on the 3.13 we built, under the s6 we built, started by
# init.d/S62moonraker. Three build outputs and no stand-ins, which is why it
# needs three tarballs where every other target needs one or none: the s6
# recipes, the python recipes + work/.sodium, and the pinned Moonraker sdist in
# vendor/. Two of
# the three are assembled by test/ffsim/gates.py rather than by a `tar -czf`
# here, so this runs the gate through a thin wrapper instead of calling
# printer-exec.py -- see sim-moonraker313.py for that argument written out.
test-moonraker313: image
	@$(RUNSIM) ./test/integration/sim-moonraker313.py

# The installer, run for real over two payloads: what the last one shipped
# goes, what nobody shipped stays.
test-upgrade: image
	@$(RUNSIM) ./test/integration/printer-exec.py ./test/integration/printer/case-upgrade.sh

# Every service's nice value, read back out of /proc/<pid>/stat on the
# printer's own busybox -- see anvil-service.sh's svc_start_daemon for why
# this cannot be a grep for "-N".
test-priority: image
	@$(RUNSIM) ./test/integration/printer-exec.py ./test/integration/printer/case-priority.sh

boot-screen:
	@./bin/preview-boot-screen.py

# The same frames, drawn by the PRINTER's python inside the replica. Slower,
# and the only render that proves what the panel would really show.
boot-screen-sim: image
	@$(RUNSIM) ./test/integration/sim-boot-screen.py

# Packages land in dist/ after `make release` and in work/out after a single
# build (pack.sh clears work/out each run, so only the last model survives
# there). Look in both.
test-install: image
	@$(RUNSIM) bash -c 'pkg=$$(ls -1 dist/$(or $(MODEL),Creator5Pro)-*.tgz work/out/$(or $(MODEL),Creator5Pro)-*.tgz 2>/dev/null | head -1); \
	   [ -n "$$pkg" ] || { echo "build a package first: make build (or make release)"; exit 1; }; \
	   echo "package: $$pkg"; ./test/integration/sim-install.py "$$pkg"'

# Recovery = flash the stock package you already have. This proves it works.
#
# It builds its own package rather than reusing whatever is lying around: the
# test is only meaningful against a package that really does replace the UI,
# and whatever is in work/out may be anything.
test-recovery: image config.env
	@MODEL=$(or $(MODEL),Creator5Pro) $(RUNSIM) bash -c '. ./bin/common.sh; \
	   ./bin/build.sh $(PACKARGS) >/dev/null || exit 1; \
	   m=$$(ls -1 work/out/$$TARGET_MACHINE-*.tgz 2>/dev/null | head -1); \
	   [ -n "$$m" ] || { echo "no package built for $$TARGET_MACHINE"; exit 1; }; \
	   [ -f "$$STOCK_TGZ" ] || { echo "no stock package for $$TARGET_MACHINE"; exit 1; }; \
	   echo "mod:   $$m"; echo "stock: $$STOCK_TGZ"; \
	   ./test/integration/sim-roundtrip.py "$$m" "$$STOCK_TGZ"'

clean:
	@rm -rf work/stage work/out work/modpayload-root
	@echo cleaned

distclean:
	@rm -rf work
	@echo "removed work/ (including the extracted rootfs)"
