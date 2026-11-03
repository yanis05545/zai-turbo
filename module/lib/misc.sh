#!/system/bin/sh
# =====================================================================
#  Zyrox v2 - lib/misc.sh
#  SurfaceFlinger(boot), log, refresh rate, network, RAM, cleanup_all.
# =====================================================================

# ---------------------------------------------------------------------
# I. SurfaceFlinger: prop debug.sf.* hanya dibaca Saat SF start, jadi diset
#    di post-fs-data (sebelum SF jalan). Memanggilnya saat game = tidak ada
#    efek (itu salah di v1). Non-persisten: hilang kalau module dimatikan.
# ---------------------------------------------------------------------
sf_boot_props() {
  [ "$FEAT_SURFACEFLINGER" = 1 ] && [ "$SF_BOOT_PROPS" = 1 ] || return 0
  [ -s "$PROFILE" ] || return 0           # belum pernah scan -> jangan tebak
  case "${TIER:-low}" in low) return 0 ;; esac
  for sb in "debug.sf.latch_unsignaled=1" "debug.sf.disable_backpressure=1"; do
    if command -v resetprop >/dev/null 2>&1; then resetprop "${sb%%=*}" "${sb#*=}" 2>/dev/null
    else setprop "${sb%%=*}" "${sb#*=}" 2>/dev/null; fi
  done
  log_msg "I: prop SurfaceFlinger boot diset (tier=$TIER)"
}

# ---------------------------------------------------------------------
# J. Kurangi overhead logging/tracing (logd TIDAK dimatikan)
# ---------------------------------------------------------------------
log_reduce_apply() {
  [ "$FEAT_LOG_REDUCE" = 1 ] || return 0
  safe_write "$R/proc/sys/kernel/printk" "0 0 0 0"
  safe_write "$R/proc/sys/kernel/sched_schedstats" 0
  safe_write "$R/sys/kernel/tracing/tracing_on" 0
  safe_write "$R/sys/kernel/debug/tracing/tracing_on" 0
  safe_write "$R/sys/module/lowmemorykiller/parameters/debug_level" 0
  prop_set debug.atrace.tags.enableflags 0
  log_msg "J: overhead logging/tracing dikurangi"
}

# ---------------------------------------------------------------------
# M. Refresh rate (backup nilai ASLI; "null" dipulihkan dengan settings delete)
# ---------------------------------------------------------------------
refresh_apply() {
  [ "$FEAT_REFRESH" = 1 ] || return 0
  [ "$HZ" = 1 ] && return 0   # fitur Refresh Rate (Hz) sudah mengunci tetap - jangan ditimpa saat game
  [ "$FRAMERATE" = 1 ] && return 0   # fitur Frame Rate (FPS) juga mengunci peak/min - jangan ditimpa saat game
  rf_hz=$(dumpsys display 2>/dev/null | grep -oE '(fps|refreshRate)=[0-9]+(\.[0-9]+)?' | sed 's/.*=//' | sort -n | tail -n1)
  rf_hz=${rf_hz%.*}
  case "$rf_hz" in ''|*[!0-9]*) return 0 ;; esac
  [ "$rf_hz" -ge 61 ] || { log_msg "M: layar hanya ${rf_hz}Hz, skip"; return 0; }
  for rf_k in peak_refresh_rate min_refresh_rate; do
    grep -q "^$rf_k|" "$RUNDIR/settings_backup" 2>/dev/null || \
      echo "$rf_k|$(settings get system "$rf_k" 2>/dev/null)" >> "$RUNDIR/settings_backup"
    settings put system "$rf_k" "$rf_hz" 2>/dev/null
  done
  log_msg "M: refresh rate dikunci ${rf_hz}Hz selama game"
}

refresh_revert() {
  [ -s "$RUNDIR/settings_backup" ] || return 0
  while IFS='|' read -r rr_k rr_v; do
    [ -n "$rr_k" ] || continue
    case "$rr_v" in
      ''|null) settings delete system "$rr_k" >/dev/null 2>&1 ;;
      *) settings put system "$rr_k" "$rr_v" 2>/dev/null ;;
    esac
  done < "$RUNDIR/settings_backup"
  rm -f "$RUNDIR/settings_backup"
  log_msg "M: refresh rate dipulihkan"
}

# ---------------------------------------------------------------------
# N. Network: TCP tuning + stop optimisasi daya WiFi yang bikin ping
#    melonjak saat layar nyala + doze-whitelist game + monitor kestabilan
#    ping NYATA (avg/jitter/loss dari ringkasan `ping`, bukan angka karangan).
# ---------------------------------------------------------------------
network_apply() {
  [ "$FEAT_NETWORK" = 1 ] || return 0
  safe_write "$R/proc/sys/net/ipv4/tcp_slow_start_after_idle" 0
  safe_write "$R/proc/sys/net/core/rmem_max" 6291456
  safe_write "$R/proc/sys/net/core/wmem_max" 4194304
  safe_write "$R/proc/sys/net/ipv4/tcp_fastopen" 3
  nw_c=$(read1 "$R/proc/sys/net/core/rmem_max")
  cmd wifi force-low-latency-mode enabled >/dev/null 2>&1 && : > "$RUNDIR/wifi_ll"
  # WiFi power-save/optimisasi daya & throttle scan background = sumber umum
  # ping tiba-tiba melonjak ("ping merah") saat main; dimatikan sementara,
  # nilai asli disimpan di settings_backup yang sama dipakai refresh_apply
  # (format generik k|v, direvert otomatis oleh refresh_revert -> dipanggil
  # juga dari network_revert di bawah).
  for nw_k in wifi_suspend_optimizations_enabled wifi_scan_throttle_enabled; do
    grep -q "^$nw_k|" "$RUNDIR/settings_backup" 2>/dev/null || \
      echo "$nw_k|$(settings get global "$nw_k" 2>/dev/null)" >> "$RUNDIR/settings_backup"
    settings put global "$nw_k" 0 2>/dev/null
  done
  # bebaskan game dari Doze/App Standby supaya koneksinya tidak ditahan
  # sistem di background (mis. saat layar sempat redup / alt-tab sebentar)
  if [ -n "$GAME_PKG" ]; then
    dumpsys deviceidle whitelist "+$GAME_PKG" >/dev/null 2>&1 && echo "$GAME_PKG" > "$RUNDIR/net_dozewl"
  fi
  net_ping_start
  log_msg "N: network tuning (wifi low-latency=$([ -f "$RUNDIR/wifi_ll" ] && echo ya || echo tidak-didukung), doze-whitelist=$([ -f "$RUNDIR/net_dozewl" ] && echo ya || echo tidak), ping-monitor=$NET_PING_LOG)"
}

network_revert() {
  [ -f "$RUNDIR/ping_pid" ] && { kill "$(cat "$RUNDIR/ping_pid")" 2>/dev/null; rm -f "$RUNDIR/ping_pid"; }
  # WiFi Low Latency (fitur tersendiri, lib/wifill.sh) kalau sedang AKTIF jangan dimatikan
  # ikut selesai sesi game - cuma tweak per-game ini yang dilepas.
  [ -f "$RUNDIR/wifi_ll" ] && { [ "$WIFILL" = 1 ] || cmd wifi force-low-latency-mode disabled >/dev/null 2>&1; rm -f "$RUNDIR/wifi_ll"; }
  if [ -f "$RUNDIR/net_dozewl" ]; then
    dumpsys deviceidle whitelist "-$(cat "$RUNDIR/net_dozewl")" >/dev/null 2>&1
    rm -f "$RUNDIR/net_dozewl"
  fi
  rm -f "$DATADIR/ping_stat"
}

# monitor ping NYATA: batch kecil tiap NET_PING_INTERVAL detik, baca ringkasan
# `ping` apa adanya (rtt min/avg/max/mdev + % packet loss) - tidak dihitung
# ulang/ditebak di shell supaya angkanya persis sama dengan yang `ping`
# sendiri laporkan.
net_ping_loop() {
  while :; do
    [ "$NET_PING_LOG" = 1 ] || break
    [ -f "$MODDIR/disable" ] && break
    np_out=$(ping -c 5 -i 1 -W 1 "${NET_PING_HOST:-8.8.8.8}" 2>/dev/null)
    [ -n "$np_out" ] || { sleep "${NET_PING_INTERVAL:-10}"; continue; }
    np_loss=$(echo "$np_out" | sed -n 's/.*, \([0-9][0-9]*\)% packet loss.*/\1/p')
    np_vals=$(echo "$np_out" | sed -n 's#.*= *\([0-9.]*\)/\([0-9.]*\)/\([0-9.]*\)/\([0-9.]*\).*#\1 \2 \3 \4#p')
    set -- $np_vals
    np_min=${1:-}; np_avg=${2:-}; np_max=${3:-}; np_jit=${4:-}
    np_ts=$(date '+%H:%M:%S')
    { echo "ts=$np_ts avg_ms=${np_avg:-?} min_ms=${np_min:-?} max_ms=${np_max:-?} jitter_ms=${np_jit:-?} loss_pct=${np_loss:-0} host=${NET_PING_HOST:-8.8.8.8}"; } > "$DATADIR/ping_stat"
    echo "$np_ts avg=${np_avg:-?}ms jitter=${np_jit:-?}ms loss=${np_loss:-0}%" >> "$DATADIR/ping.log"
    np_sz=$(wc -l < "$DATADIR/ping.log" 2>/dev/null); [ "${np_sz:-0}" -gt 300 ] && { tail -n 150 "$DATADIR/ping.log" > "$DATADIR/ping.log.t" && mv -f "$DATADIR/ping.log.t" "$DATADIR/ping.log"; }
    # packet loss parah -> coba re-assert wifi low-latency (bukan klaim "memperbaiki jaringan", cuma re-apply tweak yang sudah ada)
    case "$np_loss" in ''|*[!0-9]*) ;; *) [ "$np_loss" -ge 20 ] 2>/dev/null && { log_msg "N: packet loss tinggi (${np_loss}%) ke ${NET_PING_HOST:-8.8.8.8}"; cmd wifi force-low-latency-mode enabled >/dev/null 2>&1; } ;; esac
    sleep "${NET_PING_INTERVAL:-10}"
  done
}

net_ping_start() {
  [ "$NET_PING_LOG" = 1 ] || return 0
  [ -f "$RUNDIR/ping_pid" ] && kill -0 "$(cat "$RUNDIR/ping_pid")" 2>/dev/null && return 0
  : > "$DATADIR/ping_stat"
  ( net_ping_loop ) >/dev/null 2>&1 &
  echo $! > "$RUNDIR/ping_pid"
}

# ---------------------------------------------------------------------
# O. RAM (min_free_kbytes mengikuti ukuran RAM; drop_caches opsional)
# ---------------------------------------------------------------------
ram_apply() {
  [ "$FEAT_RAM" = 1 ] || return 0
  rm_mb=$((RAM_MB / 128)); [ "$rm_mb" -lt 16 ] && rm_mb=16; [ "$rm_mb" -gt 96 ] && rm_mb=96
  rm_t=$((rm_mb * 1024))
  rm_c=$(read1 "$R/proc/sys/vm/min_free_kbytes")
  if [ -n "$rm_c" ] && [ "$rm_c" -lt "$rm_t" ] 2>/dev/null; then
    safe_write "$R/proc/sys/vm/min_free_kbytes" "$rm_t"
  fi
  [ "$RAM_KILL_BG" = 1 ] && { am kill-all >/dev/null 2>&1; }
  if [ "$RAM_DROP_CACHES" = 1 ]; then sync; echo 1 > "$R/proc/sys/vm/drop_caches" 2>/dev/null; fi
  log_msg "O: RAM manager (min_free=${rm_mb}MB, kill-bg=$RAM_KILL_BG, drop_caches=$RAM_DROP_CACHES)"
}

# ---------------------------------------------------------------------
# cleanup_all - satu jalur pembersihan: game keluar, thermal panas, stop,
# disable, crash (supervisor), uninstall.
# ---------------------------------------------------------------------
cleanup_all() {
  log_msg "cleanup_all()"
  perf_priority_revert
  thermal_revert
  revert_stack
  revert_props
  revert_services
  refresh_revert
  network_revert
  # gfx_revert DIHAPUS v2.0: Graphics API Universal (lib/gfxapi.sh) sekarang
  # non-stop sampai dimatikan manual (gu_off), TIDAK lagi direvert tiap game
  # berhenti/keluar foreground/daemon idle - sama seperti Thermal Lock Daily/
  # Network Booster yang juga sengaja dilewatkan dari cleanup_all().
  rm -f "$RUNDIR/level" "$RUNDIR/fps_now"
  fpsa_reset_state
  verify_cleanup
}

verify_cleanup() {
  vc_left=0
  [ -s "$STACK" ] && vc_left=1
  [ -s "$PROPSTACK" ] && vc_left=1
  [ -s "$SVCSTACK" ] && vc_left=1
  [ -s "$RUNDIR/settings_backup" ] && vc_left=1
  if [ "$vc_left" = 1 ]; then
    log_msg "WARN: sisa state setelah cleanup, dibersihkan paksa"
    : > "$STACK"; : > "$PROPSTACK"; : > "$SVCSTACK"; rm -f "$RUNDIR/settings_backup"
  fi
  rm -f "$BACKUPDIR"/* 2>/dev/null
}
