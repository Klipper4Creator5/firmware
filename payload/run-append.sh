# Runs near the END of the stock run.sh, after it has installed its own
# files. Backups already happened in the pre-block at the top.
MODDIR=/usr/data/mod
case "$MODDIR" in
    /usr/data/?*) ;;
    *) echo "refusing to run: MODDIR='$MODDIR' is not under /usr/data"; exit 0 ;;
esac
exec >>/usr/data/mod-install.log 2>&1

# ---- the mod payload -------------------------------------------------------
# Shipped as mod.tar.xz in the OUTER package, so it is already sitting on the
# data partition next to us (/usr/data/update). Never unpacked into /usr/prog:
# the firmware partition has no room for ~100MB of web UI.
MODTAR=""
for c in /usr/data/update/mod.tar.xz /mnt/mod.tar.xz $WORK_DIR/mod.tar.xz; do
    [ -f "$c" ] && { MODTAR="$c"; break; }
done

if [ -n "$MODTAR" ]; then
    NEED=`ls -l "$MODTAR" | tr -s ' ' | cut -d' ' -f5`
    NEED=$((NEED / 1024 * 4))          # xz payload expands ~3-4x
    FREE=`df /usr/data | tail -1 | tr -s ' ' | cut -d' ' -f4`
    echo "mod payload: $MODTAR (need ~${NEED}KB, free ${FREE}KB)"
    if [ "${FREE:-0}" -lt "$NEED" ]; then
        echo "!! not enough space on /usr/data -- skipping mod payload"
    else
        # Keep user-editable state; replace everything we own.
        [ -f $MODDIR/mod.conf ] && cp -f $MODDIR/mod.conf /tmp/mod.conf.keep
        rm -rf $MODDIR/bin $MODDIR/www $MODDIR/nginx $MODDIR/helixscreen $MODDIR/config
        mkdir -p $MODDIR
        # Try xz first (FlashForge's own factory installer uses `xz -dc`, so
        # it exists), then fall back to plain tar in case a build shipped it
        # uncompressed.
        if xz -dc "$MODTAR" 2>/dev/null | tar -xf - -C $MODDIR; then
            echo "extracted (xz)"
        elif tar -xf "$MODTAR" -C $MODDIR; then
            echo "extracted (plain tar)"
        else
            echo "!! could not extract $MODTAR"
        fi
        [ -f /tmp/mod.conf.keep ] && mv -f /tmp/mod.conf.keep $MODDIR/mod.conf
        chmod a+x $MODDIR/boot.sh $MODDIR/bin/* 2>/dev/null
        echo "mod payload installed"
    fi
else
    echo "!! no mod.tar.xz found -- scripts only, no Mainsail/HelixScreen"
fi
sync

# ---- the real UI binary, kept beside our wrapper -------------------------
# The stock run.sh copied our wrapper to firmwareExe; put the genuine binary
# next to it so the wrapper (and SAFE-MODE) can always fall back to it.
if [ -f "$WORK_DIR/firmwareExe.stock" ]; then
    cp -f "$WORK_DIR/firmwareExe.stock" /usr/prog/PROGRAM/software/firmwareExe.stock
    chmod +x /usr/prog/PROGRAM/software/firmwareExe.stock
    echo "installed firmwareExe.stock (fallback UI)"
fi
sync

# ---- klipper configs -------------------------------------------------------
# Install only what is missing: never clobber a printer.cfg the user tuned.
# Anything that already exists lands as <name>.mod-new for manual merging.
if [ -d $MODDIR/config ]; then
    mkdir -p /usr/data/config
    for f in $MODDIR/config/*; do
        [ -f "$f" ] || continue
        b=`basename "$f"`
        if [ -f "/usr/data/config/$b" ]; then
            cp -f "$f" "/usr/data/config/$b.mod-new"
        else
            cp -f "$f" /usr/data/config/
        fi
    done
fi
sync

# Stale bytecode from the previous Klipper generation is a silent import-time
# landmine; the stock run.sh only clears four of the __pycache__ dirs.
find /usr/prog/klipper/klippy -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null
sync

# ---- ssh host keys, once at install time -----------------------------------
if [ -x $MODDIR/bin/dropbearkey ]; then
    mkdir -p $MODDIR/etc/dropbear
    for t in rsa ecdsa ed25519; do
        [ -f $MODDIR/etc/dropbear/dropbear_${t}_host_key ] || \
            $MODDIR/bin/dropbearkey -t $t -f $MODDIR/etc/dropbear/dropbear_${t}_host_key
    done
fi
sync

echo "mod installed `date 2>/dev/null`" > $MODDIR/VERSION
echo "=== mod install done ==="
sync
