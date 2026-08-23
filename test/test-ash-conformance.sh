#!/usr/bin/env bash
# Parse every on-printer script with the PRINTER'S OWN busybox ash.
#
# The payload runs under busybox 1.31.1 ash on MIPS, not under bash or dash.
# `sh -n` on a build machine catches only some of the difference. Here we run
# the genuine /bin/busybox out of the printer's real rootfs under qemu-mipsel,
# so a construct that busybox rejects is caught before it ever reaches the
# machine -- where a parse error in firmwareExe means a blank screen.
#
# No binfmt registration is needed: `busybox sh -n` is a single process and
# forks nothing.
#
# Needs work/rootfs (test/extract-rootfs.sh). Skips cleanly without it, so CI
# -- which has no proprietary firmware -- still passes.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${SIM_IMAGE:-debian:bookworm-slim}"
RFS="$ROOT/work/rootfs"

DOCKER=docker
command -v docker >/dev/null 2>&1 || DOCKER=docker.exe
command -v $DOCKER >/dev/null 2>&1 || { echo "  SKIP: docker not available"; exit 0; }
$DOCKER info >/dev/null 2>&1 || { echo "  SKIP: docker daemon not running"; exit 0; }
[ -f "$RFS/bin/busybox" ] || {
    echo "  SKIP: no work/rootfs -- run 'make rootfs' to extract the real one"
    exit 0
}

$DOCKER run --rm -i \
    -v "$RFS:/pr:ro" \
    -v "$ROOT/payload:/payload:ro" \
    "$IMAGE" sh -s <<'INNER'
set -u
FAIL=0
ok()  { printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAIL=1; }

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq qemu-user-static >/dev/null 2>&1

ASH="qemu-mipsel-static -L /pr /pr/bin/busybox"

V=$($ASH 2>&1 | head -1)
echo "  using: $(echo "$V" | cut -c1-46)"
[ "$($ASH uname -m 2>/dev/null)" = mips ] \
    && ok "genuine MIPS userland (uname -m = mips)" \
    || bad "not running the printer userland"

echo
for f in /payload/firmwareExe /payload/start.sh /payload/run-pre.sh \
         /payload/run-append.sh /payload/report.sh /payload/init.d/S*; do
    [ -f "$f" ] || continue
    n=$(basename "$f")
    if $ASH sh -n "$f" 2>/tmp/err; then
        ok "parses under busybox ash: $n"
    else
        bad "busybox ash REJECTS $n"
        head -3 /tmp/err | sed 's/^/        /'
    fi
done

echo
echo "  -- applet flags the payload depends on --"
# The stock installer uses `md5sum -s -c`, which GNU coreutils spells
# --status. Confirm the printer's busybox really accepts -s.
if $ASH md5sum -s -c /dev/null 2>/dev/null; then
    ok "busybox md5sum accepts -s (used by the stock installer's gate)"
else
    echo "        (md5sum -s on empty input is inconclusive; not a failure)"
fi
$ASH ps >/dev/null 2>&1 && ok "busybox ps available (UI liveness check)" \
                        || bad "no busybox ps -- the UI liveness check degrades"
$ASH head -c 2 /pr/bin/busybox >/dev/null 2>&1 \
    && ok "busybox head -c available (used to detect our wrapper script)" \
    || bad "busybox head -c missing"

# FlashForge's own runFirmwareExe.sh slices the version out of a filename with
# ${file_name:${#start_head}:${version_length}} -- a bash-compat expansion that
# dash rejects. The stock installer only works because this busybox was built
# with ASH_BASH_COMPAT. If a future firmware ships a busybox without it, the
# stock updater breaks and so does ours.
SUB=$($ASH sh -c 'v=software-1.9.7.tar.xz; echo ${v:9:5}' 2>/dev/null)
[ "$SUB" = "1.9.7" ] \
    && ok "busybox ash supports \${var:off:len} (the stock installer needs it)" \
    || bad "busybox ash lacks bash-compat substrings -- the STOCK installer would fail too"

echo
[ "$FAIL" = 0 ] && echo "  payload is busybox-ash clean" || echo "  ASH CONFORMANCE FAILED"
exit $FAIL
INNER
