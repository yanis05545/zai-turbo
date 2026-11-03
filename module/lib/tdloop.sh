#!/system/bin/sh
# Zyrox - tdloop.sh : watchdog "Thermal Lock Daily"
#  - re-assert thermal_apply tiap ~30dtk selama THERMAL_DAILY=1 (jaga-jaga
#    kalau prop/service/zona kena reset proses lain)
#  - safety: auto revert + THERMAL_DAILY=0 kalau baterai/skin/SoC >= ambang
#    aman tier-aware (lihat catatan pengaman di lib/thermaldaily.sh)
MODDIR=${0%/*}; MODDIR=${MODDIR%/lib}
export MODDIR
. "$MODDIR/common.sh"
load_conf
TD_PID="$RUNDIR/td.pid"
td_p=$(cat "$TD_PID" 2>/dev/null)
[ -n "$td_p" ] && [ "$td_p" != "$$" ] && kill -0 "$td_p" 2>/dev/null && exit 0
echo $$ > "$TD_PID"
trap 'rm -f "$TD_PID"' EXIT
log_msg "THERMAL DAILY: loop start pid=$$"
flog THERMAL_DAILY INFO "watchdog Thermal Lock Daily mulai (pid=$$)"
scan_if_needed >/dev/null 2>&1
td_i=0
while :; do
  [ $((td_i % 6)) = 0 ] && load_conf
  [ "$THERMAL_DAILY" = 1 ] || break
  [ -f "$MODDIR/disable" ] && break
  if [ "$THERMAL_MODE" = off ]; then sleep 10; td_i=$((td_i + 1)); continue; fi
  thermal_limits_init; temps_read probe
  td_hot=""
  [ -n "$T_BATT" ] && [ -n "$BATT_LIM" ] && [ "$T_BATT" -ge "$BATT_LIM" ] && td_hot="baterai ${T_BATT}C"
  [ -n "$T_SKIN" ] && [ -n "$SKIN_LIM" ] && [ "$T_SKIN" -ge "$SKIN_LIM" ] && td_hot="$td_hot skin ${T_SKIN}C"
  [ -n "$T_SOC" ] && [ -n "$SOC_LIM" ] && [ "$T_SOC" -ge "$SOC_LIM" ] && td_hot="$td_hot SoC ${T_SOC}C"
  if [ -n "$td_hot" ]; then
    flog THERMAL_DAILY BUG "SAFETY panas ($td_hot) -> revert otomatis, Thermal Lock Daily dimatikan"
    log_msg "THERMAL DAILY: SAFETY panas ($td_hot) -> revert otomatis, Thermal Lock Daily dimatikan"
    td_revert
    if grep -q '^THERMAL_DAILY=' "$CONF" 2>/dev/null; then
      sed -i 's/^THERMAL_DAILY=.*/THERMAL_DAILY=0/' "$CONF"
    else
      echo 'THERMAL_DAILY=0' >> "$CONF"
    fi
    notify "Zyrox: Thermal Lock Daily dimatikan otomatis (suhu tinggi: $td_hot)"
    break
  fi
  # re-assert periodik (tiap ~30dtk = 6 x sleep 5dtk), bukan tiap tick, supaya ringan
  [ $((td_i % 6)) = 0 ] && td_apply >/dev/null 2>&1
  td_i=$((td_i + 1))
  sleep 5
done
log_msg "THERMAL DAILY: loop selesai"
