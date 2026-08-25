# Runs at the TOP of the stock run.sh, before it copies anything into
# /usr/prog. This ordering matters: back up the files while they are still
# the STOCK ones. Backing up after the copy would capture our own modified
# files and make the uninstall package a no-op.
MODDIR=/usr/data/anvil
case "$MODDIR" in
    /usr/data/?*) ;;
    *) echo "refusing to run: MODDIR='$MODDIR' is not under /usr/data"; exit 0 ;;
esac
STAMP=`date +%Y%m%d-%H%M%S 2>/dev/null || echo manual`
BACKUP=$MODDIR/backup/$STAMP
mkdir -p "$MODDIR" "$BACKUP"
{
  echo "=== mod install $STAMP ==="
  # app_startup.sh is deliberately NOT in this list: the mod replaces
  # firmwareExe instead, so the stock boot scripts are never modified.
  for file in /usr/prog/klipper/start.sh /usr/prog/etc/passwd \
              /usr/prog/etc/shadow; do
      if [ -e "$file" ]; then
          dest="$BACKUP`dirname $file`"
          mkdir -p "$dest" && cp -a "$file" "$dest/" && echo "backed up $file"
      fi
  done
  # NOTE: we deliberately do NOT try to back up the previous firmwareExe here.
  # The stock outer installer runs
  #     cd /usr/prog/PROGRAM/software && ls | grep -v temp | xargs rm -rf
  # BEFORE it executes this run.sh, so the old binary is already gone by the
  # time we get control. That is also why uninstalling means flashing the
  # STOCK package again: it is the only thing that still carries the genuine
  # binary. See docs/hardware-testing.md and `make test-recovery`.

  # Record which backup is the pristine one: only the first install sees
  # genuinely stock files, so never let a later re-flash overwrite it.
  if [ ! -d "$MODDIR/backup/stock" ]; then
      cp -a "$BACKUP" "$MODDIR/backup/stock" && echo "kept pristine copy at backup/stock"
  fi

  # The root password the printer has RIGHT NOW -- random from a first
  # install, or set by hand with `passwd` -- lives only in this shadow, and
  # the stock installer is about to replace the file. Record the hash so the
  # post-block can put it back: that is what keeps the password stable
  # across updates.
  rm -f "$MODDIR/.prev-root-hash"
  if [ -f /usr/prog/etc/shadow ]; then
      awk 'BEGIN{FS=":"} $1=="root"{print $2}' /usr/prog/etc/shadow \
          > "$MODDIR/.prev-root-hash" 2>/dev/null &&
          chmod 600 "$MODDIR/.prev-root-hash" &&
          echo "recorded current root password hash"
  fi
} >> /usr/data/anvil-install.log 2>&1
sync
