#!/system/bin/sh
# Zyrox - tkloop.sh : watchdog agresif; menjaga service thermal tetap mati selama THERMAL_KILL=1
# v1.0.9: (1) MATIKAN DULU baru urusan lambat (scan/cmd/props) - dulu satu panggilan yang
#         menggantung di awal menahan penjaga selamanya; (2) tidak lagi KELUAR saat conf
#         sempat THERMAL_KILL=0 - cukup menunggu, lalu aktif lagi begitu kembali 1 (toggle
#         OFF->ON di WebUI dulu mematikan penjaga permanen karena cuma mengubah conf).
MODDIR=${0%/*}; MODDIR=${MODDIR%/lib}
export MODDIR
. "$MODDIR/common.sh"
load_conf
tk_loop_alive && [ "$(cat "$TK_PID" 2>/dev/null)" != "$$" ] && exit 0
echo $$ > "$TK_PID"
trap 'rm -f "$TK_PID"' EXIT
flog THERMALKILL INFO "penjaga Disable Thermal mulai (pid=$$)"
log_msg "TKILL: loop agresif start pid=$$ (THERMAL_KILL=$THERMAL_KILL TK_BLOCK=${TK_BLOCK:-?})"
tk_i=0; tk_init=0
while :; do
  # v1.0.9-fix: tick efektif minimum 5 dtk (dulu dipatok 2 dtk fix). kill -9
  # tiap 2 dtk tanpa henti pada binary HAL combo (lazim di MTK budget) memicu
  # badai binder-died ke proses lain yang nebeng di binary sama -> crash +
  # jaringan putus. 5 dtk masih responsif tapi jauh lebih ramah ke binder.
  TK_TICK_EFF=${TK_TICK:-5}; case "$TK_TICK_EFF" in ''|*[!0-9]*|0) TK_TICK_EFF=5 ;; esac
  [ "$TK_TICK_EFF" -lt 5 ] && TK_TICK_EFF=5
  [ $((tk_i % 5)) = 0 ] && load_conf
  [ -f "$MODDIR/disable" ] && break
  if [ "$THERMAL_KILL" = 1 ] && [ ! -f "$DATADIR/tk_off" ]; then
    # v1.0.15: putaran pertama + TK_BLOCK=1 -> BLOCK langsung (di namespace init), jangan
    # menunggu service hidup lagi 2x dulu. Harus SEBELUM tk_enforce biasa, karena yang
    # sudah di-stop tidak lagi terdaftar "running" sehingga tidak akan di-BLOCK.
    [ "$tk_init" = 0 ] && [ "${TK_BLOCK:-0}" = 1 ] && tk_enforce force
    tk_enforce
    if [ "$tk_init" = 0 ]; then
      tk_init=1
      scan_if_needed >/dev/null 2>&1; load_conf
      tk_props_apply; tk_override; tk_kernel_apply
      tk_enforce
    fi
    [ $((tk_i % 3)) = 0 ] && { tk_kill_procs; tk_safety || true; }
    [ $((tk_i % 10)) = 0 ] && { tk_override; tk_kernel_apply; }
  else
    tk_init=0
  fi
  tk_i=$((tk_i + 1))
  sleep "$TK_TICK_EFF"
done
log_msg "TKILL: loop selesai"
