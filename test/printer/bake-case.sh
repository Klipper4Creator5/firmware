#!/bin/sh
# Runs inside the chroot at image-bake time, after the stock baseline install.
# Its only job is to leave a marker saying which package produced this state,
# so entrypoint.sh can skip a 37-second reinstall of the same thing.
echo "${BASELINE_ID:-unknown}" > /usr/prog/.BASELINE
exit 0
