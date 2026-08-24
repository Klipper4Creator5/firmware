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
.PHONY: help image shell build vendor \
        rootfs verify test test-py test-install \
        printer-image printer-image-push \
        test-recovery test-mcu release clean distclean

help:
	@echo 'creator5-custom-firmware -- everything runs in Docker'
	@echo
	@echo 'Build (see docs/hardware-testing.md before you flash):'
	@echo '  make build        the firmware  Klipper fork, toolchanger, Mainsail,'
	@echo '                                  ssh and HelixScreen'
	@echo '  make release      build BOTH models into dist/'
	@echo
	@echo 'Models: packages are model-specific and refuse to install on the'
	@echo 'other one. MODEL=Creator5 make build  builds the non-Pro variant.'
	@echo
	@echo 'Recovery: keep a copy of the STOCK FlashForge .tgz on a spare stick.'
	@echo 'Flashing it restores every file the mod touches (see make test-recovery).'
	@echo
	@echo 'Test:'
	@echo '  make test             all of them, and the shell/bashism/packaging'
	@echo '                        passes that have no target of their own'
	@echo '  make test-py          pytest: the whole test/ tree'
	@echo '  make test-install     end-to-end: USB stick -> update -> reboot'
	@echo '  make test-mcu         ff-mcu-bringup.py runs on the printer own python'
	@echo '  make test-recovery    install mod -> flash stock -> back to stock'
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

# ===========================================================================
#  BUILD LANE -- produces the package you flash. Reads config.env, ships
#  payload/ and assets/, and touches nothing under test/.
# ===========================================================================

# Mainsail, HelixScreen and Moonraker are not vendored in the repo. bin/build.sh fetches
# what the build needs; this target pre-fetches everything, and is a
# no-op once vendor/ holds files with the sha256 that versions.env pins.
vendor: image config.env
	@$(RUN) ./bin/fetch-assets.sh --all

build: image config.env
	@$(RUN) ./bin/build.sh $(PACKARGS)

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
	@rm -rf work/stage work/out work/modpayload
	@echo cleaned

distclean:
	@rm -rf work
	@echo "removed work/ (including the extracted rootfs)"
