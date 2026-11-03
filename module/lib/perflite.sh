#!/system/bin/sh
# =====================================================================
#  Zyrox - lib/perflite.sh : "Perf Lite"
#
#  Profil performa RINGAN & hemat daya (bukan "kunci clock maksimum").
#  Toggle TERSENDIRI di tab Kontrol, di bawah Mode Thermal.
#
#  ATURAN BENTROK (dijaga di sini, azenith-thermal, charge.sh, WebUI):
#   - Perf Lite BOLEH dikombinasikan dengan mode Balanced.
#   - Perf Lite TIDAK BOLEH bersama ZAI-Turbo (extreme) dan PowerSaver (saver):
#     selama Perf Lite AKTIF, kedua mode itu ditolak (PL_MODE_LOCK).
#   - Saat Perf Lite dinyalakan: Fast Charger otomatis dimatikan, dan kalau
#     mode aktif saat itu saver/extreme, otomatis dipindah ke Balanced dulu.
#   - Selama Perf Lite AKTIF, Fast Charger juga ditolak dinyalakan.
#
#  5 grup tweak. SEMUA ditulis dengan backup sendiri ($PL_BK, bukan $STACK
#  milik safe_write) supaya reset total mode Balanced (cleanup_all) tidak
#  diam-diam ikut membatalkan Perf Lite. Semua dibaca-balik untuk verifikasi
#  dan dikembalikan persis ke nilai asal oleh pl_off.
#
#   1) VM & RAM   : swappiness, vfs_cache_pressure, Low Memory Killer
#                   (LMK kernel lama: minfree dinaikkan ~25%; lmkd modern
#                   memakai ro.lmk.* yang read-only -> dilaporkan, dilewati)
#   2) CPU & GPU  : schedutil up/down_rate_limit_us (interactive: timer),
#                   uclamp top-app naik tipis & background dibatasi,
#                   input boost vendor (kalau node ada), Adreno adrenoboost=0
#   3) Grafis/UI  : debug.sf.hw, debug.egl.hw, persist.sys.ui.hw,
#                   debug.composition.type=gpu (HWC), renderer skiagl
#                   (renderer TIDAK disentuh kalau Graphics API Universal aktif)
#   4) Storage    : read_ahead_kb (512 KB), FSTrim /data /system /cache tiap
#                   boot + saat layar mati lama (dijaga daemon: pl_watch)
#   5) Log/Trace  : kurangi logcat/dumpsys overhead, matikan analitik & trace
#                   vendor yang aman dimatikan (Settings + prop non-ro)
#
#  CATATAN JUJUR: touch boost murni bergantung pada kernel/vendor. Perf Lite
#  hanya menyalakan input boost kalau nodenya ada (mis. cpu_boost Qualcomm);
#  untuk MediaTek/lainnya pakai toggle Touch Boost yang sudah ada.
#  Prop di grup 3/5 bersifat runtime (setprop/resetprop), diterapkan ulang
#  tiap boot oleh service.sh; sebagian baru berlaku untuk proses yang dimulai
#  SETELAH diterapkan (app dibuka ulang).
# =====================================================================

PL_BK="$DATADIR/perflite_backup"            # tipe|kunci|nilai_asli
PL_MODE_LOCK="$RUNDIR/pl_mode_lock"         # ada = Perf Lite AKTIF (saver/extreme ditolak)
PL_TRIM_STAMP="$DATADIR/perflite_trim_last" # epoch trim terakhir
PL_PREV_MODE="$DATADIR/perflite_prev_mode"  # mode sebelum Perf Lite (info saja)

pl_setconf() { # pl_setconf KEY VAL
  if grep -q "^$1=" "$CONF" 2>/dev/null; then sed -i "s/^$1=[^ #]*/$1=$2/" "$CONF"
  else echo "$1=$2" >> "$CONF"; fi
}

# ---------- backup & tulis ----------
pl_bk_has() { grep -qF "$1|$2|" "$PL_BK" 2>/dev/null; }
pl_bk_add() { # pl_bk_add <sys|prop|set> <kunci> <nilai_asli>
  pl_bk_has "$1" "$2" && return 0
  printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$PL_BK"
}

pl_norm() { # nilai node tanpa [] (format governor/scheduler) dan tanpa spasi ganda
  pn_r=$(cat "$1" 2>/dev/null) || return 1
  case "$pn_r" in *\[*\]*) pn_r=$(echo "$pn_r" | sed -n 's/.*\[\([^]]*\)\].*/\1/p') ;; esac
  echo $pn_r
}

# pl_wr <path> <nilai>   return 0 ok | 1 node tidak ada | 2 ditolak kernel
pl_wr() {
  pw_p=$1; pw_v=$2
  [ -e "$pw_p" ] || return 1
  pw_old=$(pl_norm "$pw_p") || return 1
  [ -n "$pw_old" ] || return 1
  pl_bk_add sys "$pw_p" "$pw_old"
  { echo "$pw_v" > "$pw_p"; } 2>/dev/null || { chmod 644 "$pw_p" 2>/dev/null; { echo "$pw_v" > "$pw_p"; } 2>/dev/null; } || return 2
  [ "$(pl_norm "$pw_p")" = "$(echo $pw_v)" ] && return 0
  return 2
}

# pl_wr_log <label> <path> <nilai> -> tulis + tambah hitungan + catat satu baris
pl_wr_log() {
  pl_wr "$2" "$3"; pg_rc=$?
  case "$pg_rc" in
    0) PL_OK=$((PL_OK + 1)); PL_REP="$PL_REP
    [ok]    $1=$3" ;;
    2) PL_FAIL=$((PL_FAIL + 1)); PL_REP="$PL_REP
    [DITOLAK] $1 (kernel menolak $3)" ;;
    *) PL_SKIP=$((PL_SKIP + 1)) ;;   # node tidak ada di device ini: bukan error
  esac
}

# pl_prop <nama> <nilai> : prop runtime dengan backup (ro.* ditolak)
pl_prop() {
  pp_k=$1; pp_v=$2
  case "$pp_k" in ro.*) return 1 ;; esac
  pl_bk_add prop "$pp_k" "$(getprop "$pp_k" 2>/dev/null)"
  if command -v resetprop >/dev/null 2>&1; then resetprop "$pp_k" "$pp_v" 2>/dev/null
  else setprop "$pp_k" "$pp_v" 2>/dev/null; fi
  [ "$(getprop "$pp_k" 2>/dev/null)" = "$pp_v" ]
}
pl_prop_log() {
  if pl_prop "$1" "$2"; then PL_OK=$((PL_OK + 1)); PL_REP="$PL_REP
    [ok]    prop $1=$2"
  else PL_FAIL=$((PL_FAIL + 1)); PL_REP="$PL_REP
    [DITOLAK] prop $1 (tidak bisa diubah ROM ini)"; fi
}

# pl_set <ns> <key> <val> : Settings dengan backup (nilai asal 'null' = dihapus saat off)
pl_set() {
  ps_n=$1; ps_k=$2; ps_v=$3
  pl_bk_add set "$ps_n/$ps_k" "$(settings get "$ps_n" "$ps_k" 2>/dev/null | tr -d '\r')"
  settings put "$ps_n" "$ps_k" "$ps_v" 2>/dev/null
  [ "$(settings get "$ps_n" "$ps_k" 2>/dev/null | tr -d ' \r\n')" = "$ps_v" ]
}
pl_set_log() {
  if pl_set "$1" "$2" "$3"; then PL_OK=$((PL_OK + 1)); PL_REP="$PL_REP
    [ok]    settings $1 $2=$3"
  else PL_SKIP=$((PL_SKIP + 1)); fi
}

# ---------- 1) VM & RAM ----------
pl_apply_vm() {
  PL_REP="$PL_REP
  [1] VM & RAM"
  pl_wr_log swappiness "$R/proc/sys/vm/swappiness" "${PL_SWAPPINESS:-40}"
  pl_wr_log vfs_cache_pressure "$R/proc/sys/vm/vfs_cache_pressure" "${PL_VFS_PRESSURE:-120}"
  # LMK kernel lama (lowmemorykiller.ko / built-in): minfree dalam satuan page.
  pl_lm="$R/sys/module/lowmemorykiller/parameters/minfree"
  if [ -w "$pl_lm" ]; then
    pl_cur=$(cat "$pl_lm" 2>/dev/null)
    pl_new=$(echo "$pl_cur" | awk -F, '{for(i=1;i<=NF;i++){v=int($i*1.25); printf "%s%d", (i>1?",":""), v}}')
    [ -n "$pl_new" ] && pl_wr_log "LMK minfree" "$pl_lm" "$pl_new"
  else
    PL_REP="$PL_REP
    [lewati] LMK: kernel memakai lmkd (ro.lmk.* read-only) - tidak bisa diubah runtime"
    PL_SKIP=$((PL_SKIP + 1))
  fi
}

# ---------- 2) CPU & GPU ----------
pl_apply_cpu() {
  PL_REP="$PL_REP
  [2] CPU & GPU"
  pl_gn=0
  for pl_pol in "$R"/sys/devices/system/cpu/cpufreq/policy[0-9]*; do
    [ -d "$pl_pol" ] || continue
    pl_gov=$(pl_norm "$pl_pol/scaling_governor")
    case "$pl_gov" in
      schedutil|sugov_ext|walt)
        # naik cepat tapi tidak liar (up), turun relatif cepat saat statis (down) -> hemat daya
        pl_wr_log "$(basename "$pl_pol") up_rate_limit_us"   "$pl_pol/$pl_gov/up_rate_limit_us"   "${PL_UP_US:-500}"
        pl_wr_log "$(basename "$pl_pol") down_rate_limit_us" "$pl_pol/$pl_gov/down_rate_limit_us" "${PL_DOWN_US:-2000}"
        pl_gn=$((pl_gn + 1)) ;;
      interactive)
        pl_wr_log "$(basename "$pl_pol") timer_rate" "$pl_pol/interactive/timer_rate" 20000
        pl_wr_log "$(basename "$pl_pol") min_sample_time" "$pl_pol/interactive/min_sample_time" 40000
        pl_gn=$((pl_gn + 1)) ;;
    esac
  done
  # schedutil global (kernel lama: satu set untuk semua policy)
  if [ -d "$R/sys/devices/system/cpu/cpufreq/schedutil" ]; then
    pl_wr_log "schedutil up_rate_limit_us"   "$R/sys/devices/system/cpu/cpufreq/schedutil/up_rate_limit_us"   "${PL_UP_US:-500}"
    pl_wr_log "schedutil down_rate_limit_us" "$R/sys/devices/system/cpu/cpufreq/schedutil/down_rate_limit_us" "${PL_DOWN_US:-2000}"
    pl_gn=$((pl_gn + 1))
  fi
  [ "$pl_gn" = 0 ] && PL_REP="$PL_REP
    [lewati] governor aktif bukan schedutil/interactive - rate limit tidak diubah"
  # boost margin top-app + clamp background (uclamp cgroup v2/cpuctl, atau stune lama)
  for pl_cg in "$R/dev/cpuctl" "$R/sys/fs/cgroup/cpuctl" "$R/dev/cpuctl/system"; do
    [ -d "$pl_cg/top-app" ] || continue
    pl_wr_log "top-app uclamp.min" "$pl_cg/top-app/cpu.uclamp.min" "${PL_TOP_UCLAMP_MIN:-10}"
    pl_wr_log "background uclamp.max" "$pl_cg/background/cpu.uclamp.max" "${PL_BG_UCLAMP_MAX:-50}"
    pl_wr_log "system-background uclamp.max" "$pl_cg/system-background/cpu.uclamp.max" "${PL_BG_UCLAMP_MAX:-50}"
    break
  done
  pl_wr_log "stune top-app boost" "$R/dev/stune/top-app/schedtune.boost" 5
  # input/touch boost vendor: hanya kalau node ada (Qualcomm cpu_boost)
  pl_wr_log "input_boost_ms" "$R/sys/module/cpu_boost/parameters/input_boost_ms" 64
  # GPU Adreno: matikan penahan clock/boost supaya GPU ikut pacing
  pl_kg="$R/sys/class/kgsl/kgsl-3d0"
  pl_wr_log "adrenoboost" "$pl_kg/devfreq/adrenoboost" 0
  pl_wr_log "force_clk_on" "$pl_kg/force_clk_on" 0
  pl_wr_log "force_bus_on" "$pl_kg/force_bus_on" 0
  pl_wr_log "force_rail_on" "$pl_kg/force_rail_on" 0
}

# ---------- 3) Grafis & UI ----------
pl_apply_gfx() {
  PL_REP="$PL_REP
  [3] Grafis & UI"
  pl_prop_log debug.sf.hw 1
  pl_prop_log debug.egl.hw 1
  pl_prop_log persist.sys.ui.hw true
  pl_prop_log debug.composition.type gpu          # komposisi layar via GPU/HWC
  if [ "$GFX_UNIVERSAL" = 1 ]; then
    PL_REP="$PL_REP
    [lewati] debug.hwui.renderer: Graphics API Universal sedang AKTIF, renderer tidak disentuh"
  else
    pl_prop_log debug.hwui.renderer skiagl        # driver render paling stabil
  fi
}

# ---------- 4) Storage ----------
pl_apply_io() {
  PL_REP="$PL_REP
  [4] Storage"
  pl_ion=0
  for pl_b in "$R"/sys/block/sd[a-z] "$R"/sys/block/mmcblk[0-9] "$R"/sys/block/nvme[0-9]n[0-9]; do
    [ -d "$pl_b/queue" ] || continue
    pl_wr_log "$(basename "$pl_b") read_ahead_kb" "$pl_b/queue/read_ahead_kb" "${PL_READAHEAD_KB:-512}"
    pl_ion=$((pl_ion + 1))
  done
  [ "$pl_ion" = 0 ] && PL_REP="$PL_REP
    [lewati] tidak ada blok flash (sd*/mmcblk*/nvme*) yang terbaca"
  PL_REP="$PL_REP
    [info]  FSTrim otomatis: tiap boot + saat layar mati lama (dijaga daemon)"
}

# FSTrim: /data /system /cache (yang ada & writable-mount saja). return 0 kalau ada yang jalan.
pl_fstrim() {
  pf_n=0
  for pf_m in /data /system /cache; do
    if command -v fstrim >/dev/null 2>&1; then
      fstrim "$pf_m" >/dev/null 2>&1 && pf_n=$((pf_n + 1))
    fi
  done
  # fallback Android: idle maintenance StorageManager (men-trim semua volume)
  if [ "$pf_n" = 0 ] && command -v sm >/dev/null 2>&1; then
    sm fstrim >/dev/null 2>&1 && pf_n=1
  fi
  [ "$pf_n" -gt 0 ] && { uptime_s > "$PL_TRIM_STAMP"; log_msg "PERFLITE: FSTrim dijalankan ($pf_n target)"; return 0; }
  log_msg "PERFLITE: FSTrim tidak tersedia (tidak ada biner fstrim / sm fstrim)"
  return 1
}

# ---------- 5) Log & trace ----------
pl_apply_log() {
  PL_REP="$PL_REP
  [5] Log & Trace"
  pl_prop_log log.tag.stats_log ASSERT
  pl_prop_log debug.atrace.tags.enableflags 0
  pl_prop_log persist.traced.enable 0
  # analitik/laporan performa berkala ke vendor/ROM (hanya yang aman: Settings, bisa dikembalikan)
  pl_set_log global send_action_app_error 0
  pl_set_log secure send_action_app_error 0
  pl_set_log global activity_starts_logging_enabled 0
  pl_set_log global anomaly_detection_enabled 0
  pl_set_log global network_recommendations_enabled 0
  # buang buffer logcat yang menumpuk (aman, hanya isi buffer, bukan file)
  logcat -c >/dev/null 2>&1
  PL_REP="$PL_REP
    [ok]    logcat buffer dibersihkan"
}

# ---------- on / off / status ----------
pl_load_tunables() { PL_SWAPPINESS=${PL_SWAPPINESS:-40}; PL_VFS_PRESSURE=${PL_VFS_PRESSURE:-120}; PL_READAHEAD_KB=${PL_READAHEAD_KB:-512}; }

pl_on() {
  load_conf
  pl_load_tunables
  PL_OK=0; PL_FAIL=0; PL_SKIP=0; PL_REP=""
  mkdir -p "$RUNDIR" 2>/dev/null
  pl_pre=""

  # 1) v1.0.38: Fast Charger AKTIF -> Perf Lite yang TIDAK direspon (ditolak),
  #    Fast Charger & mode balance tetap normal.
  if [ "$FAST_CHARGE" = 1 ] || [ -f "$FC_MODE_LOCK" ]; then
    echo "Perf Lite DITOLAK: Fast Charger sedang AKTIF (Perf Lite tidak direspon selama Fast Charger aktif)."
    echo "Matikan Fast Charger dulu (azenith-ai fastcharge off / toggle WebUI) baru Perf Lite bisa dinyalakan."
    flog PERFLITE INFO "Perf Lite ditolak - Fast Charger aktif"
    return 1
  fi
  # 2) mode saver/extreme tidak boleh bersama Perf Lite -> pindah ke Balanced
  pl_cur=$(cat "$DATADIR/azenith_thermal_mode" 2>/dev/null)
  case "$pl_cur" in
    saver|extreme)
      echo "$pl_cur" > "$PL_PREV_MODE"
      rm -f "$PL_MODE_LOCK"   # pastikan balance tidak ditolak oleh kunci sendiri
      sh "$MODDIR/system/bin/azenith-thermal" balance >/dev/null 2>&1
      flog PERFLITE INFO "mode '$pl_cur' -> balance otomatis (tidak bisa bersama Perf Lite)"
      pl_pre="$pl_pre
  - Mode thermal: $pl_cur -> balance otomatis" ;;
  esac

  pl_apply_vm
  pl_apply_cpu
  pl_apply_gfx
  pl_apply_io
  pl_apply_log

  if [ "$PL_OK" -gt 0 ]; then
    pl_setconf PERFLITE 1
    : > "$PL_MODE_LOCK"
    # FSTrim sekali sekarang (background, tidak menahan toggle)
    ( pl_fstrim >/dev/null 2>&1 ) &
    log_msg "PERFLITE: AKTIF ok=$PL_OK gagal=$PL_FAIL dilewati=$PL_SKIP"
    echo "Perf Lite: AKTIF ($PL_OK tweak berhasil, $PL_FAIL ditolak kernel, $PL_SKIP tidak ada di device ini)"
    echo "Aturan: PowerSaver & ZAI-Turbo dikunci, Fast Charger dikunci - hanya Balanced yang bisa dipakai bersama Perf Lite"
    [ -n "$pl_pre" ] && echo "Otomatis:$pl_pre"
    echo "$PL_REP" | sed '/^$/d'
    pl_status
    return 0
  fi
  pl_setconf PERFLITE 0
  rm -f "$PL_MODE_LOCK"
  log_msg "PERFLITE: GAGAL - tidak ada tweak yang bisa diterapkan"
  echo "Perf Lite: GAGAL - tidak ada satu pun tweak yang berhasil diterapkan di device ini"
  echo "$PL_REP" | sed '/^$/d'
  return 1
}

pl_off() {
  load_conf
  rm -f "$PL_MODE_LOCK"
  pl_restored=0
  if [ -s "$PL_BK" ]; then
    # urutan terbalik supaya kunci yang sama dipulihkan ke nilai tertua
    awk '{a[NR]=$0} END{for(i=NR;i>0;i--) print a[i]}' "$PL_BK" | while IFS='|' read -r po_t po_k po_v; do
      [ -n "$po_k" ] || continue
      case "$po_t" in
        sys) [ -e "$po_k" ] && { echo "$po_v" > "$po_k"; } 2>/dev/null ;;
        prop)
          if [ -n "$po_v" ]; then
            if command -v resetprop >/dev/null 2>&1; then resetprop "$po_k" "$po_v" 2>/dev/null; else setprop "$po_k" "$po_v" 2>/dev/null; fi
          else
            resetprop --delete "$po_k" 2>/dev/null || setprop "$po_k" "" 2>/dev/null
          fi ;;
        set)
          po_ns=${po_k%%/*}; po_kk=${po_k#*/}
          case "$po_v" in ''|null) settings delete "$po_ns" "$po_kk" >/dev/null 2>&1 ;; *) settings put "$po_ns" "$po_kk" "$po_v" 2>/dev/null ;; esac ;;
      esac
    done
    pl_restored=$(grep -c . "$PL_BK" 2>/dev/null)
    : > "$PL_BK"
  fi
  rm -f "$PL_PREV_MODE"
  pl_setconf PERFLITE 0
  log_msg "PERFLITE: MATI ($pl_restored nilai dikembalikan)"
  echo "Perf Lite: MATI ($pl_restored nilai dikembalikan ke asal; PowerSaver & ZAI-Turbo bisa dipakai lagi)"
  pl_status
}

pl_status() {
  load_conf
  echo "PERFLITE=$PERFLITE  kunci_mode=$([ -f "$PL_MODE_LOCK" ] && echo ya || echo tidak)  backup=$(grep -c . "$PL_BK" 2>/dev/null || echo 0)"
  echo "swappiness=$(read1 "$R/proc/sys/vm/swappiness")  vfs_cache_pressure=$(read1 "$R/proc/sys/vm/vfs_cache_pressure")  composition=$(getprop debug.composition.type)  renderer=$(getprop debug.hwui.renderer)"
  pl_ra=""
  for pl_b in "$R"/sys/block/sd[a-z] "$R"/sys/block/mmcblk[0-9]; do [ -d "$pl_b/queue" ] && { pl_ra="$(read1 "$pl_b/queue/read_ahead_kb")"; break; }; done
  echo "read_ahead_kb=${pl_ra:--}  fstrim_terakhir=$(cat "$PL_TRIM_STAMP" 2>/dev/null || echo belum)(uptime_s)  fastcharge=$FAST_CHARGE"
}

# ---------- dipanggil boot (service.sh) ----------
# Diterapkan ulang setelah reboot. Fast Charger / mode extreme-saver yang
# dipulihkan azenith-thermal restore dibereskan lagi oleh pl_on.
pl_boot_apply() {
  rm -f "$PL_BK"      # backup lama berisi nilai SEBELUM reboot (sudah tidak berlaku)
  pl_on
  pl_fstrim
}

# ---------- watchdog ringan, dipanggil daemon (lib/daemon.sh) ----------
# 1) jaga kunci tetap konsisten; 2) FSTrim saat layar mati lama (>= 30 menit
# sejak trim terakhir, layar mati); 3) re-assert swappiness/vfs (zram.sh &
# ROM vendor sering menulis ulang).
PL_SCREEN_OFF_SINCE=0
pl_watch() {
  [ "$PERFLITE" = 1 ] || return 0
  [ -f "$PL_MODE_LOCK" ] || : > "$PL_MODE_LOCK"
  pw_s=$(read1 "$R/proc/sys/vm/swappiness")
  [ -n "$pw_s" ] && [ "$pw_s" != "${PL_SWAPPINESS:-40}" ] && { echo "${PL_SWAPPINESS:-40}" > "$R/proc/sys/vm/swappiness"; } 2>/dev/null
  pw_v=$(read1 "$R/proc/sys/vm/vfs_cache_pressure")
  [ -n "$pw_v" ] && [ "$pw_v" != "${PL_VFS_PRESSURE:-120}" ] && { echo "${PL_VFS_PRESSURE:-120}" > "$R/proc/sys/vm/vfs_cache_pressure"; } 2>/dev/null
  # layar mati?
  if dumpsys power 2>/dev/null | grep -q 'mWakefulness=Asleep'; then
    pw_now=$(uptime_s)
    [ "$PL_SCREEN_OFF_SINCE" = 0 ] && PL_SCREEN_OFF_SINCE=$pw_now
    pw_last=$(cat "$PL_TRIM_STAMP" 2>/dev/null); pw_last=${pw_last:-0}
    if [ $((pw_now - PL_SCREEN_OFF_SINCE)) -ge 1800 ] && [ $((pw_now - pw_last)) -ge 21600 ]; then
      pl_fstrim >/dev/null 2>&1
      flog PERFLITE INFO "FSTrim otomatis (layar mati lama)"
    fi
  else
    PL_SCREEN_OFF_SINCE=0
  fi
}

# dipanggil uninstall.sh
pl_restore_node() { pl_off >/dev/null 2>&1; rm -f "$PL_MODE_LOCK"; }
