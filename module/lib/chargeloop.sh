#!/system/bin/sh
# Zyrox - chargeloop.sh : watchdog Bypass Charging (simpel)
# Tulis ulang "cmd battery set status 4" tiap CHARGE_TICK detik selama
# CHARGE_BYPASS=1, supaya override tidak tertimpa sistem.
MODDIR=${0%/*}; MODDIR=${MODDIR%/lib}
export MODDIR
. "$MODDIR/common.sh"
load_conf
cg_p=$(cat "$CHG_PID" 2>/dev/null)
[ -n "$cg_p" ] && [ "$cg_p" != "$$" ] && kill -0 "$cg_p" 2>/dev/null && exit 0
echo $$ > "$CHG_PID"
trap 'rm -f "$CHG_PID"' EXIT
log_msg "CHARGE: watchdog start pid=$$"
flog CHARGE INFO "watchdog Bypass Charging mulai (pid=$$, tahan reboot)"
cg_i=0
while :; do
  [ $((cg_i % 3)) = 0 ] && load_conf
  [ "$CHARGE_BYPASS" = 1 ] || break
  [ -f "$MODDIR/disable" ] && break
  chg_cmd_on
  cg_i=$((cg_i + 1))
  sleep "${CHARGE_TICK:-2}"
done
log_msg "CHARGE: watchdog selesai"
flog CHARGE INFO "watchdog Bypass Charging selesai"
