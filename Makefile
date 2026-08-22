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

ifeq ($(LOCAL),)
  RUN = $(DOCKER) run --rm -i \
          -v "$(CURDIR)":"$(CURDIR)" -w "$(CURDIR)" \
          $(if $(ASSET_ROOT),-v "$(ASSET_ROOT)":"$(ASSET_ROOT)",) \
          -v $(DOCKER_SOCK):$(DOCKER_SOCK) \
          -e PROFILE -e REAL_PKG -e SIM_IMAGE \
          $(IMAGE)
  RUNTTY = $(subst --rm -i,--rm -it,$(RUN))
else
  RUN =
  RUNTTY =
endif

.DEFAULT_GOAL := help
.PHONY: help image shell build probe ssh web full helix all-profiles \
        rootfs verify test test-lint test-install \
        test-recovery test-ui test-ash test-abi clean distclean

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
	@echo
	@echo 'Recovery: keep a copy of the STOCK FlashForge .tgz on a spare stick.'
	@echo 'Flashing it restores every file the mod touches (see make test-recovery).'
	@echo
	@echo 'Test:'
	@echo '  make test             everything below'
	@echo '  make test-lint        brick-risk lint'
	@echo '  make test-install     run the installer against a fake printer'
	@echo '  make test-recovery    install mod -> flash stock -> back to stock'
	@echo '  make test-ui          UI selection, crash fallback, SAFE-MODE'
	@echo '  make test-ash         parse the payload with the printer own busybox'
	@echo '  make test-abi         MIPS ELF ABI checks'
	@echo
	@echo 'Other:'
	@echo '  make rootfs       extract the real printer rootfs (enables test-ash)'
	@echo '  make image        build the build container'
	@echo '  make shell        shell inside it'
	@echo '  make clean | distclean'
	@echo
	@echo 'LOCAL=1 make <target> runs on the host instead of in Docker.'

image:
	@$(DOCKER) build -q -t $(IMAGE) -f docker/Dockerfile.build docker >/dev/null && echo "image $(IMAGE) ready"

config.env:
	@echo 'no config.env -- copy the example and edit the paths:'; \
	 echo '    cp config.env.example config.env'; exit 1

shell: image
	@$(RUNTTY) bash

build: image config.env
	@PROFILE=$(PROFILE) $(RUN) ./bin/build.sh

probe ssh web full helix: image config.env
	@PROFILE=$@ $(RUN) ./bin/build.sh

all-profiles: image config.env
	@for p in probe ssh web full helix; do \
	   echo "=== $$p ==="; PROFILE=$$p $(RUN) ./bin/build.sh || exit 1; done

rootfs: image config.env
	@$(RUN) ./bin/unpack.sh >/dev/null
	@$(RUN) ./bin/extract-rootfs.sh

verify: image
	@$(RUN) ./bin/verify.sh

test: image
	@$(RUN) ./test/run-tests.sh

test-lint: image
	@$(RUN) ./test/lint-danger.sh payload payload/init.d

test-ash: image
	@$(RUN) ./test/test-ash-conformance.sh

test-abi: image
	@$(RUN) ./test/test-abi.sh

test-ui: image
	@$(RUN) ./test/sim-ui-fallback.sh

test-install: image
	@$(RUN) sh -c 'pkg=$$(ls -1 work/out/Creator5Pro-*.tgz 2>/dev/null | grep -v uninstall | head -1); \
	   [ -n "$$pkg" ] || { echo "build a package first: make probe"; exit 1; }; \
	   ./test/sim-install.sh "$$pkg"'

# Recovery = flash the stock package you already have. This proves it works.
test-recovery: image config.env
	@$(RUN) sh -c '. ./config.env; \
	   m=$$(ls -1 work/out/Creator5Pro-*.tgz 2>/dev/null | head -1); \
	   [ -n "$$m" ] || { echo "build a package first: make full"; exit 1; }; \
	   [ -f "$$STOCK_TGZ" ] || { echo "STOCK_TGZ not found: $$STOCK_TGZ"; exit 1; }; \
	   ./test/sim-roundtrip.sh "$$m" "$$STOCK_TGZ"'

clean:
	@rm -rf work/stage work/out work/uninst work/uninst-sw work/modpayload
	@echo cleaned

distclean:
	@rm -rf work
	@echo "removed work/ (including the extracted rootfs)"
