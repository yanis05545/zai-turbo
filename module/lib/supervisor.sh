#!/system/bin/sh
# Zyrox v2 - supervisor: jalankan daemon, restart kalau crash (maks 5x/10 menit),
# dan SELALU bersihkan state kalau daemon mati tanpa sempat cleanup (mis. SIGKILL).
MODDIR=${0%/*}; MODDIR=${MODDIR%/lib}
export MODDIR
. "$MODDIR/common.sh"
load_conf
log_msg "SUPERVISOR: start pid=$$"
echo $$ > "$RUNDIR/supervisor.pid"
sv_crash=0; sv_t0=$(uptime_s)
while :; do
  sh "$MODDIR/lib/daemon_run.sh"
  sv_rc=$?
  [ -f "$RUNDIR/stop" ] && break
  [ -f "$MODDIR/disable" ] || [ -f "$MODDIR/remove" ] && break
  [ "$sv_rc" = 0 ] && break
  log_msg "SUPERVISOR: daemon mati tak normal (rc=$sv_rc) -> cleanup + restart"
  flog DAEMON BUG "daemon mati tak normal (rc=$sv_rc) -> cleanup + restart otomatis"
  load_conf; cleanup_all
  sv_now=$(uptime_s)
  [ $((sv_now - sv_t0)) -gt 600 ] && { sv_crash=0; sv_t0=$sv_now; }
  sv_crash=$((sv_crash + 1))
  if [ "$sv_crash" -gt 5 ]; then
    log_msg "SUPERVISOR: crash >5x/10 menit, menyerah (jalankan 'azenith-ai doctor')"
    flog DAEMON ERR "daemon crash >5x dalam 10 menit, supervisor menyerah (jalankan 'azenith-ai doctor')"
    echo gave_up > "$RUNDIR/supervisor_state"
    break
  fi
  sleep 5
done
rm -f "$RUNDIR/supervisor.pid"
log_msg "SUPERVISOR: selesai"
