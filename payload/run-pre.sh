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
  for f in /usr/prog/klipper/start.sh /usr/prog/etc/passwd /usr/prog/etc/shadow; do
      if [ -e "$f" ]; then
          d="$BACKUP`dirname $f`"
          mkdir -p "$d" && cp -a "$f" "$d/" && echo "backed up $f"
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
} >> /usr/data/anvil-install.log 2>&1
sync
