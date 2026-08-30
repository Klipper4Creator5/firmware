# creator5-custom-firmware
#
# Nothing runs on your machine except Docker. Every target below executes
# inside the pinned build image (docker/Dockerfile.build); the docker socket
# is mounted through so the simulation targets can start sibling containers.
#
#   make build                  build the firmware package
#   make qa                     full brick-safety suite
#   make shell                  interactive shell in the build container
#
# Escape hatch: LOCAL=1 make <target> runs the scripts directly on the host.

# A package carries our installer and our payload and no FlashForge component
# at all: the stock installer skips absent ones, so /usr/prog, the kernel and
# the MCU/board firmware are left alone. FULL=1 carries the kernel, control and
# library components too (and reflashes the MCU).
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

# Three runners, because the lanes need different things:
#
#   RUN       the parts of a build that touch no daemon: the feed, unpack,
#             pack. No docker socket, no replica settings.
#   RUNSIM    the test replica. It starts SIBLING containers through the
#             mounted socket, so it needs that plus the replica's own knobs.
#   RUNBUILD  `make build`, which needs both: the payload is assembled inside
#             the replica, and the output has to belong to you. Defined below
#             the two it borrows from.
#
# Test-only variables never enter a build, which is the point of the split.
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
        rootfs \
        printer-image printer-image-push \
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
	@echo 'Flashing it restores every file the mod touches.'
	@echo
	@echo 'Test:'
	@echo '  make qa               both lanes'
	@echo '  make qa-static        needs nothing: parses, names, packaging, the boot graph'
	@echo '  make qa-replica       needs docker + the firmware: install, upgrade, boot'
	@echo
	@echo 'Look at things:'
	@echo '  make boot-screen      render the first-boot screen to work/boot-screen/*.png'
	@echo '  make boot-screen-sim  the same, drawn by the printer own python in the replica'
	@echo
	@echo 'qa-replica runs inside a replica of the printer: the real'
	@echo 'rootfs.squashfs under qemu-mipsel, with the package'
	@echo 'installed by the printer own app_startup.sh off a real FAT filesystem'
	@echo 'at /dev/sda1. It needs make build, plus make rootfs or PRINTER_IMAGE.'
	@echo
	@echo 'qa has no ALLOW_SKIP: a missing tool, daemon or image FAILS at the'
	@echo 'point that needs it, so a gate that did not run cannot look green.'
	@echo
	@echo 'Other:'
	@echo '  make passwd       a ROOT_PW_HASH for config.env (prompts, echoes the hash)'
	@echo '  make vendor       download Mainsail + HelixScreen + Moonraker'
	@echo '  make rootfs       extract the real printer rootfs (enables the replica gates)'
	@echo '  make image        build the build container'
	@echo '  make shell        shell inside it'
	@echo '  make clean | distclean'
	@echo
	@echo 'Packages carry the installer and the payload; /usr/prog, the kernel'
	@echo 'and the MCU are left untouched. FULL=1 also flashes the kernel and MCU.'
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
#  payload/ and assets/, and touches nothing under qa/.
# ===========================================================================

# Mainsail, HelixScreen and Moonraker are not vendored in the repo. bin/build.sh fetches
# what the build needs; this target pre-fetches everything, and is a
# no-op once vendor/ holds files with the sha256 that versions.env pins.
vendor: image config.env
	@$(RUN) ./bin/fetch-assets.sh --all

# A THIRD LANE, because the build needs both halves of the split above.
# bin/payload.sh assembles the payload by starting the printer replica, so this
# lane needs the docker socket -- and it still has to run AS YOU, or every
# build leaves a root-owned work/ the next one cannot delete.
#
# --group-add is what makes those compatible: the socket is root:docker and a
# --user container has no supplementary groups, so it gets the socket's own
# gid instead of root. Read from the socket rather than assumed -- it is 999
# on some distributions and 1001 here.
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
# THE RELEASE PATH IS BUILT ON THIS. pkgs/3rdparty/python declares seven build
# dependencies, pkg_deps resolves them by unpacking their .ipk out of
# work/packages, and bin/payload.sh builds none of the seven. `make build` on a
# cold checkout does not work without this target.
# bin/payload.sh now checks for the feed up front and names this command.
#
# It still, unlike `build`, needs NO stock FlashForge package -- which is most
# of the point: packaging has to be runnable in CI on a bare checkout, or the
# gate only runs where the proprietary firmware is and stops being a gate.
packages: image config.env
	@$(RUN) ./bin/build-packages.sh $(PKG)

# One package per model, collected in dist/. They cannot share content: the
# two stock packages ship different firmwareExe binaries.
#
# It checks nothing itself: `make qa-replica` has the printer perform its own
# install, so THAT is the gate before a release goes out.
release: image config.env
	@rm -rf dist && mkdir -p dist
	@for m in Creator5Pro Creator5; do \
	   echo "=== $$m ==="; \
	   MODEL=$$m $(RUN) ./bin/build.sh $(PACKARGS) || exit 1; \
	   cp work/out/$$m-*.tgz dist/ || exit 1; \
	 done
	@echo; echo "dist/:"; ls -lh dist | awk 'NR>1{print "   "$$9"  "$$5}'
	@echo; echo "Each file installs ONLY on the model in its name."

# ===========================================================================
#  TEST LANE -- never ships. Reads test.env for the replica settings; the only
#  targets allowed to reach the docker daemon ($(RUNSIM)).
# ===========================================================================

# The replica needs this: rootfs.squashfs is the printer's real userland and
# it only exists inside the stock package's kernel component.
rootfs: image config.env
	@$(RUN) ./bin/unpack.sh >/dev/null
	@$(RUN) ./tools/replica/extract-rootfs.py

# ---------------------------------------------------------------------------
#  THE qa SUITE
#
#  Same machine, same gates, one framework. `make qa` is the suite; see
#  qa/conftest.py for the lanes.
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
	@$(RUNSIM) ./tools/replica/build-printer-image.sh

printer-image-push: image
	@$(RUNSIM) ./tools/replica/build-printer-image.sh --push

boot-screen:
	@./bin/preview-boot-screen.py

# The same frames, drawn by the PRINTER's python inside the replica. Slower,
# and the only render that proves what the panel would really show.
boot-screen-sim: image
	@$(RUNSIM) ./tools/replica/sim-boot-screen.py

clean:
	@rm -rf work/stage work/out work/modpayload-root
	@echo cleaned

distclean:
	@rm -rf work
	@echo "removed work/ (including the extracted rootfs)"
