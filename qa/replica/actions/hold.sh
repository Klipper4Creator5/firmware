#!/bin/sh
# The "case script" that turns the replica from a test runner into a fixture.
#
# entrypoint.sh's last act is to chroot in and run the script it was given.
# Every other case script tests there and exits, which is why one container
# yields exactly one bit. This one does nothing and never returns, so the
# machine stays assembled and `docker exec` can reach into it as many times as
# the tests need.
#
# Reusing entrypoint.sh unmodified is the point: the binfmt registration, the
# mount layout, the /usr/prog seeding and the stock baseline install must stay
# identical to what the old suite tests.
#
# The marker is the readiness signal. Setup runs anywhere from under a second
# (a prebuilt PRINTER_IMAGE) to over a minute, so the host polls for this
# rather than sleeping on a guess.
: > /tmp/qa-replica-ready

# `sh -c 'while :; do sleep 3600; done'` rather than `sleep infinity`: this is
# the printer's busybox 1.31.1, whose sleep takes a number of seconds and
# nothing else.
while :; do
    sleep 3600
done
