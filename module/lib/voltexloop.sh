#!/system/bin/sh
# Zyrox - voltexloop.sh : loop VoltEx (bagian Fast Charger). Tiap VX_TICK detik: pilih 6 A / 3 A
# sesuai suhu baterai & tulis ulang node arus. Berhenti sendiri kalau Fast Charger dimatikan.
MODDIR=${0%/*}; MODDIR=${MODDIR%/lib}
export MODDIR
. "$MODDIR/common.sh"
load_conf
vl_old=$(cat "$VX_PID" 2>/dev/null)
[ -n "$vl_old" ] && [ "$vl_old" != "$$" ] && kill -0 "$vl_old" 2>/dev/null && exit 0
echo $$ > "$VX_PID"
trap 'vx_failsafe; rm -f "$VX_PID"' EXIT
log_msg "VOLTEX: loop start pid=$$"
while :; do
  load_conf
  [ "$FAST_CHARGE" = 1 ] && [ -f "$VX_FLAG" ] || break
  [ -f "$MODDIR/disable" ] && break
  vx_tick >/dev/null 2>&1
  sleep "${VX_TICK:-10}"
done
log_msg "VOLTEX: loop selesai"
