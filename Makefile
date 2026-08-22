# creator5-custom-firmware
#
#   make build PROFILE=probe     build one profile's USB package
#   make test                    full suite (fixture-based, no stock firmware)
#   make uninstall-pkg           build the revert package
#   make shell                   a shell in the reproducible build container

PROFILE ?= probe
SHELL   := /bin/bash
DOCKER  ?= docker
IMAGE   ?= creator5-fw-build

.DEFAULT_GOAL := help
.PHONY: help build probe ssh web full helix all-profiles unpack patch pack \
        verify uninstall-pkg test test-lint test-install test-roundtrip \
        test-ui test-abi image shell clean distclean

help:
	@echo 'creator5-custom-firmware'
	@echo
	@echo '  make build PROFILE=<p>   build a package   (p: probe ssh web full helix)'
	@echo '  make probe|ssh|web|full|helix'
	@echo '  make all-profiles        build every profile'
	@echo '  make uninstall-pkg       build the revert package'
	@echo
	@echo '  make test                run the whole suite'
	@echo '  make test-lint           brick-risk lint only'
	@echo '  make test-install        install simulation only'
	@echo '  make test-roundtrip      install + uninstall round trip'
	@echo '  make test-ui             UI selection / fallback'
	@echo '  make test-abi            MIPS ELF ABI checks'
	@echo
	@echo '  make image / make shell  reproducible build container'
	@echo '  make clean / distclean'
	@echo
	@echo 'Flash order matters -- see docs/hardware-testing.md'

config.env:
	@echo 'no config.env -- copy the example and edit the paths:'; \
	 echo '    cp config.env.example config.env'; exit 1

build: config.env
	@PROFILE=$(PROFILE) ./bin/build.sh

probe ssh web full helix: config.env
	@PROFILE=$@ ./bin/build.sh

all-profiles: config.env
	@for p in probe ssh web full helix; do \
	   echo "=== $$p ==="; PROFILE=$$p ./bin/build.sh || exit 1; done

unpack patch pack verify: config.env
	@PROFILE=$(PROFILE) ./bin/$@.sh

uninstall-pkg: config.env
	@PROFILE=$(PROFILE) ./bin/unpack.sh >/dev/null
	@PROFILE=$(PROFILE) ./bin/make-uninstall.sh

test:
	@./test/run-tests.sh

test-lint:
	@./test/lint-danger.sh payload payload/init.d

test-install:
	@pkg=$$(ls -1 work/out/Creator5Pro-*.tgz 2>/dev/null | grep -v uninstall | head -1); \
	 [ -n "$$pkg" ] || { echo 'build a package first: make build'; exit 1; }; \
	 ./test/sim-install.sh "$$pkg"

test-roundtrip:
	@m=$$(ls -1 work/out/Creator5Pro-*.tgz 2>/dev/null | grep -v uninstall | head -1); \
	 u=work/out/Creator5Pro-uninstall.tgz; \
	 [ -n "$$m" ] && [ -f "$$u" ] || { echo 'need: make build && make uninstall-pkg'; exit 1; }; \
	 ./test/sim-roundtrip.sh "$$m" "$$u"

test-ui:
	@./test/sim-ui-fallback.sh

test-abi:
	@./test/test-abi.sh

image:
	$(DOCKER) build -t $(IMAGE) -f docker/Dockerfile.build docker

shell: image
	$(DOCKER) run --rm -it -v "$$PWD:/src" -w /src $(IMAGE) bash

clean:
	rm -rf work/stage work/out work/uninst work/uninst-sw work/modpayload

distclean: clean
	rm -rf work
