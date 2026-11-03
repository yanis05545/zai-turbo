#!/system/bin/sh
# =====================================================================
#  Zyrox v2 - lib/perf.sh
#  CPU/GPU "boost level" (0..5), scheduler, prioritas, touch, I/O, FPSGO.
#
#  Beda dari v1: frekuensi TIDAK dikunci min=max selamanya. Yang diatur hanya
#  LANTAI (floor) frekuensi per-cluster/GPU dengan bobot per-cluster, naik
#  turun mengikuti hasil mesin FPS (lib/fps.sh) dan suhu. Semua path berasal
#  dari scan (policy*, devfreq, ged, kgpu), bukan tebakan.
# =====================================================================

LV_MAX=5
LV_CAP=3; LV_START=1; PRESET_EFF=balanced

preset_params() {
  pp=$PRESET
  if [ "$pp" = auto ]; then
    case "${TIER:-mid}" in
      flagship) LV_CAP=4; LV_START=2; PRESET_EFF=balanced ;;
      high)     LV_CAP=4; LV_START=1; PRESET_EFF=balanced ;;
      mid)      LV_CAP=3; LV_START=1; PRESET_EFF=balanced ;;
      *)        LV_CAP=3; LV_START=0; PRESET_EFF=balanced ;;
    esac
    return 0
  fi
  case "$pp" in
    cool)     LV_CAP=2; LV_START=0; PRESET_EFF=cool ;;
    extreme)  LV_CAP=5; LV_START=3; PRESET_EFF=extreme ;;
    *)        LV_CAP=3; LV_START=1; PRESET_EFF=balanced ;;
  esac
}

# ---------------------------------------------------------------------
# C. FREQUENCY FLOOR PER LEVEL
# ---------------------------------------------------------------------
perf_set_cpu_level() {
  pc_lv=$1
  [ -s "$SCANDIR/cpu_policies" ] || return 1
  pc_i=0
  while IFS='|' read -r pc_n pc_p pc_min pc_max pc_w pc_t; do
    pc_i=$((pc_i + 1))
    set -- $pc_t
    pc_cnt=$#
    [ "$pc_cnt" -ge 2 ] || continue
    if [ "$pc_lv" -le 0 ]; then restore_path "$pc_p/scaling_min_freq"; continue; fi
    pc_idx=$(( (pc_cnt - 1) * pc_lv * pc_w / (LV_MAX * 100) ))
    pc_f=$(nth_word $((pc_idx + 1)) $pc_t)
    [ -n "$pc_f" ] || continue
    pc_cur=$(read1 "$pc_p/scaling_max_freq")
    # Plafon OC aktif (lib/overclock.sh) untuk cluster ini, kalau user sedang
    # overclock. Bug lama: preset extreme menulis scaling_max_freq balik ke
    # pc_max (bawaan PABRIK) tiap kali level naik - diam-diam menghapus OC
    # persis saat sedang main game, jadi hanya "nyala" sesaat di WebUI lalu
    # kembali ke bawaan begitu dicek di DevCheck. Sekarang plafonnya ikut
    # OC yang tersimpan kalau itu lebih tinggi dari bawaan.
    pc_ceiling=$pc_max
    pc_ocv=$(oc_conf_get "CPU$pc_i" 2>/dev/null)
    [ -n "$pc_ocv" ] && [ "$pc_ocv" -gt "$pc_ceiling" ] 2>/dev/null && pc_ceiling=$pc_ocv
    if [ -n "$pc_cur" ] && [ "$pc_f" -gt "$pc_cur" ] 2>/dev/null; then
      if [ "$PRESET_EFF" = extreme ]; then safe_write "$pc_p/scaling_max_freq" "$pc_ceiling"
      else pc_f=$pc_cur; fi
    fi
    safe_write "$pc_p/scaling_min_freq" "$pc_f"
  done < "$SCANDIR/cpu_policies"
}

perf_set_gpu_level() {
  pg_lv=$1
  [ "$GPU_BACKEND" = none ] && return 0
  IFS='|' read -r pg_be pg_path pg_minn pg_maxn < "$SCANDIR/gpu"
  [ -n "$pg_path" ] || return 1
  if [ "$pg_lv" -le 0 ]; then restore_path "$pg_path/$pg_minn"; return 0; fi
  [ -s "$SCANDIR/gpu_tbl" ] || return 0        # tanpa tabel OPP: tidak ada skala level
  pg_t=$(cat "$SCANDIR/gpu_tbl"); set -- $pg_t; pg_cnt=$#
  [ "$pg_cnt" -ge 2 ] || return 0
  pg_idx=$(( (pg_cnt - 1) * pg_lv / LV_MAX ))
  pg_f=$(nth_word $((pg_idx + 1)) $pg_t)
  # sama seperti CPU di atas: plafon GPU ikut OC tersimpan kalau lebih tinggi
  # dari titik puncak tabel OPP bawaan, supaya preset extreme tidak diam-diam
  # menghapus overclock GPU di tengah game.
  pg_ceiling=${pg_t##* }
  pg_ocv=$(oc_conf_get GPU 2>/dev/null)
  if [ -n "$pg_ocv" ]; then
    # oc_conf_get GPU disimpan dalam Hz; tabel/node bisa kHz/MHz (lihat oc_gpu_mul)
    pg_mul=$(oc_gpu_mul "$pg_be" "$pg_ceiling" "")
    pg_ocv=$((pg_ocv / pg_mul))
    [ "$pg_ocv" -gt "$pg_ceiling" ] 2>/dev/null && pg_ceiling=$pg_ocv
  fi
  case "$pg_be" in
    devfreq)
      pg_cur=$(read1 "$pg_path/$pg_maxn")
      if [ -n "$pg_cur" ] && [ "$pg_f" -gt "$pg_cur" ] 2>/dev/null; then
        if [ "$PRESET_EFF" = extreme ]; then safe_write "$pg_path/$pg_maxn" "$pg_ceiling"
        else pg_f=$pg_cur; fi
      fi
      safe_write "$pg_path/$pg_minn" "$pg_f" ;;
    mtk_ged|exynos_kgpu)
      safe_write "$pg_path/$pg_minn" "$pg_f" ;;
  esac
}

perf_set_uclamp() {
  pu_lv=$1
  pu_f="$R/dev/cpuctl/top-app/cpu.uclamp.min"
  if [ -e "$pu_f" ]; then
    if [ "$pu_lv" -le 0 ]; then restore_path "$pu_f"; else safe_write "$pu_f" $((pu_lv * 8)); fi
  fi
  pu_s="$R/dev/stune/top-app/schedtune.boost"
  if [ -e "$pu_s" ]; then
    if [ "$pu_lv" -le 0 ]; then restore_path "$pu_s"; else safe_write "$pu_s" $((pu_lv * 5)); fi
  fi
}

perf_set_level() {
  [ "$FEAT_FREQ" = 1 ] || return 0
  pl_lv=$1
  [ "$pl_lv" -gt "$LV_MAX" ] && pl_lv=$LV_MAX
  [ "$pl_lv" -lt 0 ] && pl_lv=0
  perf_set_cpu_level "$pl_lv"
  perf_set_gpu_level "$pl_lv"
  perf_set_uclamp "$pl_lv"
  FSE_LEVEL=$pl_lv
  echo "$pl_lv" > "$RUNDIR/level"
}

# ---------------------------------------------------------------------
# perf_test - naik-turunkan level 0..LV_MAX satu-satu & baca BALIK NYATA
# scaling_min_freq/scaling_cur_freq dari CPU policy pertama (dan GPU kalau
# ada) setelah tiap level diterapkan - supaya ketahuan floor frekuensi
# benar2 bergerak di kernel (bukan cuma angka kosmetik di WebUI). Level
# dikembalikan ke 0 di akhir supaya tidak mengganggu device di luar sesi
# test ini.
# ---------------------------------------------------------------------
perf_test() {
  testlog_begin tweaks_performance
  testlog "PRESET=$PRESET  PRESET_EFF=$PRESET_EFF  LV_CAP=$LV_CAP  LV_START=$LV_START"
  testlog ""
  pt_lv=0
  while [ "$pt_lv" -le "$LV_MAX" ]; do
    perf_set_level "$pt_lv"
    pt_line=$(head -n1 "$SCANDIR/cpu_policies" 2>/dev/null)
    IFS='|' read -r pt_n pt_p pt_min pt_max pt_w pt_t <<EOF
$pt_line
EOF
    if [ -n "$pt_p" ]; then
      pt_realmin=$(read1 "$pt_p/scaling_min_freq")
      pt_realcur=$(read1 "$pt_p/scaling_cur_freq")
      testlog "level=$pt_lv -> CPU1 ($pt_n) scaling_min_freq NYATA=$pt_realmin  scaling_cur_freq NYATA=$pt_realcur"
    else
      testlog "level=$pt_lv -> tidak ada cpu_policies terbaca (scan gagal)"
    fi
    if [ "$GPU_BACKEND" != none ] && [ -s "$SCANDIR/gpu" ]; then
      IFS='|' read -r pt_gb pt_gp pt_gminn pt_gmaxn < "$SCANDIR/gpu" 2>/dev/null
      [ -n "$pt_gp" ] && testlog "            GPU ($pt_gb) ${pt_gminn} NYATA=$(read1 "$pt_gp/$pt_gminn")"
    fi
    pt_lv=$((pt_lv + 1))
  done
  perf_set_level 0
  testlog ""
  testlog "Selesai - level dikembalikan ke 0."
  testlog_end
}

# ---------------------------------------------------------------------
# D. SCHEDULER
# ---------------------------------------------------------------------
perf_sched_apply() {
  [ "$FEAT_SCHED" = 1 ] || return 0
  [ -s "$SCANDIR/cpu_policies" ] || return 0
  while IFS='|' read -r ps_n ps_p ps_rest; do
    for ps_f in "$ps_p/schedutil/up_rate_limit_us" "$ps_p/schedutil/rate_limit_us"; do
      [ -e "$ps_f" ] && safe_write "$ps_f" 500
    done
  done < "$SCANDIR/cpu_policies"
  if [ "$PRESET_EFF" = extreme ] && [ "$SOC_VENDOR" = qcom ]; then
    safe_write "$R/proc/sys/kernel/sched_boost" 1
  fi
  log_msg "D: scheduler tuning (preset=$PRESET_EFF)"
}

# ---------------------------------------------------------------------
# E. PRIORITAS PROSES GAME (nice/ionice; RT hanya kalau PRIO_RT=1)
# ---------------------------------------------------------------------
thr_nice() { sed 's/^.*) //' "$R/proc/$1/stat" 2>/dev/null | awk '{print $17}'; }

perf_priority_apply() {
  [ "$FEAT_PRIORITY" = 1 ] || return 0
  pr_pid=$1
  [ -d "$R/proc/$pr_pid" ] || return 1
  : > "$RUNDIR/prio_state"
  pr_o=$(thr_nice "$pr_pid"); pr_o=${pr_o:-0}
  echo "$pr_pid|$pr_o" >> "$RUNDIR/prio_state"
  renice -n "$PRIO_NICE" -p "$pr_pid" >/dev/null 2>&1
  ionice -c 2 -n 0 -p "$pr_pid" >/dev/null 2>&1
  pr_n=0
  for pr_t in "$R/proc/$pr_pid"/task/*; do
    pr_tid=${pr_t##*/}
    { read -r pr_c < "$pr_t/comm"; } 2>/dev/null || continue
    case "$pr_c" in
      UnityMain|UnityGfx*|RenderThread*|GameThread|RHIThread|UE4*|Main\ Thread)
        pr_o=$(thr_nice "$pr_tid"); pr_o=${pr_o:-0}
        echo "$pr_tid|$pr_o" >> "$RUNDIR/prio_state"
        renice -n $((PRIO_NICE - 2)) -p "$pr_tid" >/dev/null 2>&1
        [ "$PRIO_RT" = 1 ] && chrt -f -p 2 "$pr_tid" >/dev/null 2>&1
        pr_n=$((pr_n + 1)) ;;
    esac
  done
  log_msg "E: prioritas pid $pr_pid (nice $PRIO_NICE, thread kunci=$pr_n, rt=$PRIO_RT)"
}

perf_priority_revert() {
  [ -s "$RUNDIR/prio_state" ] || return 0
  while IFS='|' read -r pv_id pv_nice; do
    [ -d "$R/proc/$pv_id" ] || continue
    renice -n "${pv_nice:-0}" -p "$pv_id" >/dev/null 2>&1
    chrt -o -p 0 "$pv_id" >/dev/null 2>&1
  done < "$RUNDIR/prio_state"
  rm -f "$RUNDIR/prio_state"
  log_msg "E: prioritas direvert"
}

# ---------------------------------------------------------------------
# K. TOUCH (hanya node vendor yang benar-benar ada di device)
#    Input boost (input_boost_ms) pakai satu nilai tetap, bukan lagi diatur
#    lewat TOUCH_MODE/TOUCH_SENS (dihapus). Nilai NYATA ditulis ke kernel &
#    diverifikasi oleh safe_write (write-and-verify), bukan sekadar status
#    kosmetik di WebUI.
# ---------------------------------------------------------------------
# fix: TOUCH_MODE (low/balance/high) & TOUCH_SENS (slider sensitivitas)
# dihapus - Touch Boost sekarang cuma on/off dengan satu nilai tetap
# (angka "balance" lama), tidak ada lagi basis mode atau geser sensitivitas.
touch_boost_ms() {
  echo 150
}

#  Pembacaan sistem FPSGO/GED (lib/perf.sh touch_boost): tiga node utama di
#  bawah /sys/kernel/fpsgo/common wajib benar-benar mencerminkan status
#  toggle - fpsgo_enable=1 & stop_boost=0 & perfserv_ta=1 SAAT AKTIF,
#  fpsgo_enable=0 SAAT NONAKTIF (dipaksa lewat perf_touch_revert, bukan
#  cuma restore nilai lama, supaya status "mati" selalu benar-benar 0).
#  Kalau device ini tidak expose /sys/kernel/fpsgo/common sama sekali
#  (bukan MTK/FPSGO), fallback ke node GED generik (ged_boost_enable,
#  boost_gpu_enable, gx_boost_enable) dengan aturan sama: 1 saat aktif,
#  WAJIB 0 saat nonaktif.
TB_FP1="$R/sys/kernel/fpsgo/common/fpsgo_enable"
TB_FP2="$R/sys/kernel/fpsgo/common/stop_boost"
TB_FP3="$R/sys/kernel/fpsgo/common/perfserv_ta"
TB_GED1="$R/sys/module/ged/parameters/ged_boost_enable"
TB_GED2="$R/sys/module/ged/parameters/boost_gpu_enable"
TB_GED3="$R/sys/module/ged/parameters/gx_boost_enable"

perf_touch_apply() {
  [ "$FEAT_TOUCH" = 1 ] || return 0
  tc_n=0
  tc_ms=$(touch_boost_ms)
  safe_write "$R/sys/module/msm_performance/parameters/touchboost" 1 && tc_n=$((tc_n + 1))
  safe_write "$R/proc/touchpanel/game_switch_enable" 1 && tc_n=$((tc_n + 1))
  tc_f="$R/sys/module/cpu_boost/parameters/input_boost_ms"
  [ -e "$tc_f" ] && safe_write "$tc_f" "$tc_ms" && tc_n=$((tc_n + 1))
  # fix: dulu GED (ged_boost_enable/boost_gpu_enable/gx_boost_enable) CUMA
  # ditulis kalau device SAMA SEKALI tidak punya node fpsgo/common - jadi di
  # device yang punya fpsgo (fpsgo_enable/stop_boost/perfserv_ta), node GED
  # ini selalu nyangkut di 0 walau Touch Boost AKTIF. Sekarang kedua set node
  # SELALU dicoba ditulis (tidak lagi saling eksklusif) - safe_write sendiri
  # sudah aman kalau sebuah node tidak ada di device ini ([ -e "$sw_p" ] ||
  # return 1), jadi node yang memang tidak ada otomatis dilewati tanpa error.
  safe_write "$TB_FP1" 1 && tc_n=$((tc_n + 1))
  safe_write "$TB_FP2" 0 && tc_n=$((tc_n + 1))
  safe_write "$TB_FP3" 1 && tc_n=$((tc_n + 1))
  safe_write "$TB_GED1" 1 && tc_n=$((tc_n + 1))
  safe_write "$TB_GED2" 1 && tc_n=$((tc_n + 1))
  safe_write "$TB_GED3" 1 && tc_n=$((tc_n + 1))
  tc_fp=0
  for tc_p in "$TB_FP1" "$TB_FP2" "$TB_FP3"; do [ -e "$tc_p" ] && tc_fp=$((tc_fp + 1)); done
  log_msg "K: touch node vendor dipakai=$tc_n, input_boost_ms=$tc_ms fpsgo_common=$([ "$tc_fp" -gt 0 ] && echo ya || echo tidak-ada) (0 node = device tidak punya node touch boost, normal)"
}

# perf_touch_revert - WAJIB dipanggil setiap kali Touch Boost berhenti
# (game berhenti ATAU toggle dimatikan): fpsgo_enable & trio node GED
# dipaksa 0 secara eksplisit (bukan sekadar restore nilai lama device),
# supaya "pembacaan sistem" saat nonaktif selalu benar-benar 0. stop_boost
# & perfserv_ta, serta node touch lain, sudah dikembalikan otomatis lewat
# revert_stack/cleanup_all (ditulis dengan safe_write, punya backup).
perf_touch_revert() {
  for tc_rp in "$TB_FP1" "$TB_GED1" "$TB_GED2" "$TB_GED3"; do
    [ -w "$tc_rp" ] && { echo 0 > "$tc_rp"; } 2>/dev/null
  done
}

# ---------------------------------------------------------------------
# Toggle langsung (azenith-ai set FEAT_TOUCH 1|0 / touch on|off|status) -
# sama pola dengan aks_on/aks_off (lib/killsec.sh): toggle WebUI boleh
# dinyalakan kapan saja, efek nyata ke sysfs langsung ditulis KALAU ada
# game aktif sekarang; kalau tidak ada game, ditulis begitu game mulai
# (perf_touch_apply, stage K). MATI = langsung direvert (perf_touch_revert),
# tidak menunggu game berhenti.
# ---------------------------------------------------------------------
tb_setconf() { # tb_setconf KEY VAL
  if grep -q "^$1=" "$CONF" 2>/dev/null; then sed -i "s/^$1=[^ #]*/$1=$2/" "$CONF"
  else echo "$1=$2" >> "$CONF"; fi
}

tb_on() {
  load_conf
  tb_setconf FEAT_TOUCH 1
  FEAT_TOUCH=1
  # fix: dulu kalau belum ada game aktif, node kernel (fpsgo_enable/stop_boost/
  # perfserv_ta/ged_boost_enable dst) baru ditulis saat game mulai - jadi toggle
  # kelihatan "AKTIF" di WebUI tapi node masih 0 sampai game dibuka. Sekarang
  # perf_touch_apply() selalu dipanggil langsung begitu toggle dinyalakan, apa
  # pun status game saat ini, supaya node langsung jadi 1 tanpa menunggu.
  perf_touch_apply
  tb_g=$(aks_game_now)
  if [ -n "$tb_g" ]; then
    echo "Touch Boost: AKTIF (game $tb_g sedang jalan - fpsgo_enable/stop_boost/perfserv_ta (atau GED) ditulis langsung ke kernel)"
  else
    echo "Touch Boost: AKTIF (langsung ditulis ke kernel sekarang - fpsgo_enable/stop_boost/perfserv_ta (atau GED), tidak menunggu game dibuka)"
  fi
  tb_nn=0
  for tb_f in "$TB_FP1" "$TB_FP2" "$TB_FP3" "$TB_GED1" "$TB_GED2" "$TB_GED3"; do
    [ -n "$(dv_cat "$tb_f" 2>/dev/null)" ] && tb_nn=$((tb_nn + 1))
  done
  [ "$tb_nn" -gt 0 ] || echo "PERINGATAN: tidak ada satu pun node touch boost (fpsgo/GED) terbaca di device ini - fitur tidak berefek di sini"
  tb_status
}

tb_off() {
  load_conf
  tb_setconf FEAT_TOUCH 0
  FEAT_TOUCH=0
  perf_touch_revert
  echo "Touch Boost: MATI (fpsgo_enable/ged_boost_enable/boost_gpu_enable/gx_boost_enable dipaksa 0, node lain dikembalikan ke nilai asal)"
  tb_status
}

tb_status() {
  load_conf
  ts_g=$(aks_game_now)
  echo "FEAT_TOUCH=$FEAT_TOUCH  game_aktif=${ts_g:-tidak ada}  fpsgo_enable=$(dv_cat "$TB_FP1" 2>/dev/null)  stop_boost=$(dv_cat "$TB_FP2" 2>/dev/null)  perfserv_ta=$(dv_cat "$TB_FP3" 2>/dev/null)  ged_boost_enable=$(dv_cat "$TB_GED1" 2>/dev/null)  boost_gpu_enable=$(dv_cat "$TB_GED2" 2>/dev/null)  gx_boost_enable=$(dv_cat "$TB_GED3" 2>/dev/null)"
}

# ---------------------------------------------------------------------
# L. I/O (hanya storage flash nyata: sd*, mmcblk*, nvme*; bukan loop/zram/dm)
# ---------------------------------------------------------------------
perf_io_apply() {
  [ "$FEAT_IO" = 1 ] || return 0
  io_n=0
  for io_b in "$R"/sys/block/sd[a-z] "$R"/sys/block/mmcblk[0-9] "$R"/sys/block/nvme[0-9]n[0-9]; do
    [ -d "$io_b/queue" ] || continue
    safe_write "$io_b/queue/read_ahead_kb" 512
    safe_write "$io_b/queue/iostats" 0
    safe_write "$io_b/queue/add_random" 0
    if [ -r "$io_b/queue/scheduler" ]; then
      case " $(cat "$io_b/queue/scheduler" 2>/dev/null | tr -d '[]') " in
        *" none "*) safe_write "$io_b/queue/scheduler" none ;;
        *" noop "*) safe_write "$io_b/queue/scheduler" noop ;;
      esac
    fi
    io_n=$((io_n + 1))
  done
  # clock UFS dinaikkan ke maksimum selama game (loading lebih cepat)
  while read -r io_d; do
    [ -n "$io_d" ] || continue
    io_t=$({ tbl_sort < "$io_d/available_frequencies"; } 2>/dev/null)
    [ -n "$io_t" ] && safe_write "$io_d/min_freq" "${io_t##* }"
  done < "$SCANDIR/ufs_devfreq"
  log_msg "L: I/O dituning pada $io_n perangkat storage"
}

# F. FPSGO: lihat lib/fpsgo.sh (perf_fpsgo_apply)
