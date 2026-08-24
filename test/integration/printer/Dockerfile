# Image that can execute the printer's real MIPS userland.
#
# Build context is test/integration/printer/.
#
# It carries qemu-mipsel-static and nothing else of consequence: every command
# the tests care about is executed by the printer's OWN busybox/coreutils out of
# the extracted rootfs.squashfs, under chroot. See test/integration/printer-exec.sh.
FROM debian:bookworm-slim

RUN apt-get update -qq \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
        qemu-user-static \
        rsync \
        xz-utils \
        openssl \
        ca-certificates \
        dosfstools \
        mount \
 && rm -rf /var/lib/apt/lists/*

COPY . /opt/printer/
RUN chmod +x /opt/printer/*.sh
ENTRYPOINT ["/opt/printer/entrypoint.sh"]
