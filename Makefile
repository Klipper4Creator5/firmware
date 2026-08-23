# creator5-custom-firmware
#
# Nothing runs on your machine except Docker. Every target below executes
# inside the pinned build image (docker/Dockerfile.build); the docker socket
# is mounted through so the simulation targets can start sibling containers.
#
#   make probe                  build the stage-0 package (changes nothing)
#   make test                   full brick-safety suite
#   make shell                  interactive shell in the build container
#
# Escape hatch: LOCAL=1 make <target> runs the scripts directly on the host.

PROFILE ?= probe
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
# elsewhere:  make ASSET_ROOT=/path/to/parent probe
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
          -e PROFILE -e MODEL -e TARGET_MACHINE -e CONFIG_ENV

ifeq ($(LOCAL),)
  RUN    = $(DOCKER_BASE) $(IMAGE)
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

.DEFAULT_GOAL := help
.PHONY: help image shell build probe ssh web full helix all-profiles \
        rootfs verify test test-lint test-install test-applets \
        printer-image printer-image-push \
        test-recovery test-ui test-ash test-abi test-model release clean distclean

help:
	@echo 'creator5-custom-firmware -- everything runs in Docker'
	@echo
	@echo 'Build (flash these in order -- see docs/hardware-testing.md):'
	@echo '  make probe        stage 0  changes nothing, reports back on a USB stick'
	@echo '  make ssh          stage 1  root password only'
	@echo '  make web          stage 2  + Mainsail / moonraker'
	@echo '  make full         stage 3  + forked Klipper, toolchanger'
	@echo '  make helix        stage 4  + HelixScreen as the UI'
	@echo '  make all-profiles'
	@echo '  make release PROFILE=<p>   build BOTH models into dist/'
	@echo
	@echo 'Models: packages are model-specific and refuse to install on the'
	@echo 'other one. MODEL=Creator5 make web  builds the non-Pro variant.'
	@echo
	@echo 'Recovery: keep a copy of the STOCK FlashForge .tgz on a spare stick.'
	@echo 'Flashing it restores every file the mod touches (see make test-recovery).'
	@echo
	@echo 'Test:'
	@echo '  make test             everything below'
	@echo '  make test-lint        brick-risk lint'
	@echo '  make test-install     install into a replica of the printer'
	@echo '  make test-recovery    install mod -> flash stock -> back to stock'
	@echo '  make test-ui          UI selection, crash fallback, SAFE-MODE'
	@echo '  make test-model       both models gated + firmware correct'
	@echo '  make test-applets     every command the payload uses exists on the printer'
	@echo '  make test-ash         parse the payload with the printer own busybox'
	@echo '  make test-abi         MIPS ELF ABI checks'
	@echo
	@echo 'test-install, test-recovery, test-ui and test-applets run inside a'
	@echo 'replica of the printer: the real rootfs.squashfs under qemu-mipsel,'
	@echo 'with /usr/prog installed by FlashForge own updater. They need'
	@echo 'make rootfs first, which needs the stock package.'
	@echo
	@echo 'Other:'
	@echo '  make rootfs       extract the real printer rootfs (enables test-ash)'
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

# ===========================================================================
#  BUILD LANE -- produces the package you flash. Reads config.env + profiles/,
#  ships payload/ and assets/, and touches nothing under test/.
# ===========================================================================

build: image config.env
	@PROFILE=$(PROFILE) $(RUN) ./bin/build.sh $(PACKARGS)

probe ssh web full helix: image config.env
	@PROFILE=$@ $(RUN) ./bin/build.sh $(PACKARGS)

all-profiles: image config.env
	@for p in probe ssh web full helix; do \
	   echo "=== $$p ==="; PROFILE=$$p $(RUN) ./bin/build.sh || exit 1; done

# One package per model, collected in dist/. They cannot share content: the
# two stock packages ship different firmwareExe binaries.
release: image config.env
	@rm -rf dist && mkdir -p dist
	@for m in Creator5Pro Creator5; do \
	   echo "=== $$m / $(PROFILE) ==="; \
	   MODEL=$$m PROFILE=$(PROFILE) $(RUN) ./bin/build.sh $(PACKARGS) || exit 1; \
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
	@$(RUN) ./test/extract-rootfs.sh

test: image
	@$(RUNSIM) ./test/run-tests.sh

# A Docker image that IS the printer: real rootfs, real /usr/prog and
# /usr/data, ready to run. Takes a replica run from ~1m35s to ~15s because
# the factory image is unpacked once at build time instead of every run.
#
#   make printer-image                 both models
#   make printer-image MODEL=Creator5Pro
#   make printer-image-push            build and push to Docker Hub
#
# The image contains proprietary FlashForge firmware.
printer-image: image
	@$(RUNSIM) ./test/build-printer-image.sh

printer-image-push: image
	@$(RUNSIM) ./test/build-printer-image.sh --push

test-lint: image
	@$(RUN) ./test/lint-danger.sh payload payload/init.d

test-model: image
	@$(RUN) ./test/test-model-gate.sh

test-ash: image
	@$(RUN) ./test/test-ash-conformance.sh

test-abi: image
	@$(RUN) ./test/test-abi.sh

test-applets: image
	@$(RUN) python3 ./test/test-applets.py

test-ui: image
	@$(RUNSIM) ./test/sim-ui-fallback.sh

# Packages land in dist/ after `make release` and in work/out after a single
# build (pack.sh clears work/out each run, so only the last model survives
# there). Look in both.
test-install: image
	@$(RUNSIM) bash -c 'pkg=$$(ls -1 dist/$(or $(MODEL),Creator5Pro)-*.tgz work/out/$(or $(MODEL),Creator5Pro)-*.tgz 2>/dev/null | head -1); \
	   [ -n "$$pkg" ] || { echo "build a package first: make probe (or make release)"; exit 1; }; \
	   echo "package: $$pkg"; ./test/sim-install.sh "$$pkg"'

# Recovery = flash the stock package you already have. This proves it works.
#
# It builds its own package rather than reusing whatever is lying around: the
# test is meaningless against a profile that does not replace the UI, and
# `probe` deliberately does not. RECOVERY_PROFILE=<p> to test another one.
RECOVERY_PROFILE ?= full
test-recovery: image config.env
	@MODEL=$(or $(MODEL),Creator5Pro) PROFILE=$(RECOVERY_PROFILE) $(RUNSIM) bash -c '. ./bin/common.sh; \
	   ./bin/build.sh $(PACKARGS) >/dev/null || exit 1; \
	   m=$$(ls -1 work/out/$$TARGET_MACHINE-*.tgz 2>/dev/null | head -1); \
	   [ -n "$$m" ] || { echo "no package built for $$TARGET_MACHINE"; exit 1; }; \
	   [ -f "$$STOCK_TGZ" ] || { echo "no stock package for $$TARGET_MACHINE"; exit 1; }; \
	   echo "mod:   $$m ($(RECOVERY_PROFILE))"; echo "stock: $$STOCK_TGZ"; \
	   ./test/sim-roundtrip.sh "$$m" "$$STOCK_TGZ"'

clean:
	@rm -rf work/stage work/out work/uninst work/uninst-sw work/modpayload
	@echo cleaned

distclean:
	@rm -rf work
	@echo "removed work/ (including the extracted rootfs)"
