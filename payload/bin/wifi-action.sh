#!/bin/sh
# wpa_cli action script -- run by `wpa_cli -a` on every association change.
#
# wpa_supplicant only ASSOCIATES; it never asks for an IP address. On stock
# firmware firmwareExe watched for that and ran udhcpc itself (it is full of
# "udhcpc -i wlan0" strings), and FlashForge shipped their own action script
# at /usr/prog/wifi/bin/wifi_reconnect for the same hook.
#
# Without this, joining a network from the HelixScreen WiFi panel associates
# and then sits there with no address, which the UI reports as a connection
# timeout -- associated, but no route to anything.
#
# Called as: wifi-action.sh <interface> <event>
IFACE="$1"
EVENT="$2"

exec >>/usr/data/logs/anvil-wifi.log 2>&1
echo "`date 2>/dev/null` $IFACE $EVENT"

case "$EVENT" in
    CONNECTED)
        # Replace any previous client: a lease from the old network is worse
        # than none, because it looks like success.
        killall udhcpc 2>/dev/null
        sleep 1
        /sbin/udhcpc -i "$IFACE" -b -t 10 -A 5
        echo "udhcpc requested a lease on $IFACE"
        ;;
    DISCONNECTED)
        killall udhcpc 2>/dev/null
        /sbin/ifconfig "$IFACE" 0.0.0.0 2>/dev/null
        echo "released $IFACE"
        ;;
esac
