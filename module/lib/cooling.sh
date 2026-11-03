#!/system/bin/sh
# =====================================================================
#  Zyrox - lib/cooling.sh
#  COOLING SoC per-game ("Thermal Decay via Power Limiting").
#
#  Slider 0-4 per game (tab Game, di bawah slider downscale):
#     0 Mati | 1 Ringan | 2 Sedang | 3 Kuat | 4 Maksimal
#
#  Cara kerja (NYATA, semua tulisan dibaca-balik & dilaporkan, bukan kosmetik):
#   1. Selama game berjalan daemon memantau suhu SoC ASLI ($T_SOC dari
#      temps_read probe - bukan suhu palsu hasil inject Thermal Lock).
#   2. Begitu suhu >= pemicu level itu, plafon CPU (scaling_max_freq tiap
#      policy) diturunkan BERTAHAP: COOL_STEP_PCT (10%) tiap COOL_STEP_SEC
#      (60 dtk) sampai lantai level itu. Kalau suhu sudah turun lagi
#      (pemicu - COOL_HYST_C) plafon dinaikkan bertahap sampai 100% lalu
#      semuanya dilepas otomatis.
#   3. Pada saat yang sama (selama "aktif"):
#        - plafon GPU ikut turun (MTK GED upbound / devfreq max_freq)
#        - level 3 = governor "conservative", level 4 = "powersave"
#          (hanya kalau governor itu tersedia di kernel)
#        - /sys/class/thermal/cooling_device* (HANYA tipe cpu/gpu/cluster/
#          cpufreq/devfreq; shutdown/baterai/charger/backlight/modem dst
#          diblokir) dipaksa ke cur_state tinggi (level 2=1, 3=3, 4=4,
#          dijepit ke max_state)
#        - perangkat Intel/AMD: RAPL constraint_0_power_limit_uw ikut
#          diturunkan sesuai persen yang sama
#   4. Semua node punya backup SENDIRI ($COOLBK) -> dikembalikan persis
#      saat suhu sudah dingin / game berhenti / slider diset 0.
#
#  Catatan jujur: cur_state cooling_device bisa ditimpa balik oleh governor
#  thermal kernel (step_wise) di antara dua tick; makanya nilainya ditulis
#  ULANG tiap tick selama aktif. Level 4 (powersave) menurunkan FPS banyak -
#  itu memang harganya "dingin paksa".
# =====================================================================

COOL_CONF="$DATADIR/cooling.conf"
COOLBK="$DATADIR/cool_backup"
COOLSTACK="$DATADIR/cool_stack"
COOL_STATE_F="$RUNDIR/cooling_state"

COOL_LV=0; COOL_PCT=100; COOL_NEXT=0; COOL_ENGAGED=0; COOL_RELOAD=0
COOL_GPU_MTK=0; COOL_DEVS=""

# ---------------- konfigurasi per-game (pkg=level) ----------------
cool_get() { [ -f "$COOL_CONF" ] && sed -n "s/^$1=//p" "$COOL_CONF" | tail -n 1; }
cool_list() { [ -f "$COOL_CONF" ] && cat "$COOL_CONF"; }
cool_remove_conf() {
  [ -f "$COOL_CONF" ] || return 0
  grep -vx "^$1=.*" "$COOL_CONF" 2>/dev/null > "$COOL_CONF.t"
  mv -f "$COOL_CONF.t" "$COOL_CONF" 2>/dev/null
}
cool_set_conf() { # cool_set_conf <pkg> <0-4>
  [ -f "$COOL_CONF" ] || : > "$COOL_CONF"
  cool_remove_conf "$1"
  [ "$2" = 0 ] || echo "$1=$2" >> "$COOL_CONF"
}

cool_name() {
  case "$1" in 0) echo Mati ;; 1) echo Ringan ;; 2) echo Sedang ;; 3) echo Kuat ;; 4) echo Maksimal ;; *) echo "?" ;; esac
}
# suhu pemicu SoC (C) - makin tinggi level makin dini mulai mendinginkan
cool_trig()  { case "$1" in 1) echo 65 ;; 2) echo 58 ;; 3) echo 52 ;; 4) echo 46 ;; *) echo 999 ;; esac; }
# lantai plafon (% dari plafon asli) - batas terendah decay
cool_floor() { case "$1" in 1) echo 70 ;; 2) echo 55 ;; 3) echo 40 ;; 4) echo 30 ;; *) echo 100 ;; esac; }
# target cur_state cooling_device (dijepit ke max_state masing2 perangkat)
cool_state_for() { case "$1" in 2) echo 1 ;; 3) echo 3 ;; 4) echo 4 ;; *) echo 0 ;; esac; }

# ---------------- tulis + backup sendiri + verifikasi ----------------
cool_bfile() { echo "$COOLBK/$(echo "$1" | tr '/' '%')"; }

# return 0 = nilai terbaca sama persis | 1 = node tak ada/tak terbaca | 2 = ditolak kernel
cool_w() { # cool_w <path> <val>
  cw_p=$1; cw_v=$2
  [ -e "$cw_p" ] || return 1
  if ! grep -qxF "$cw_p" "$COOLSTACK" 2>/dev/null; then
    cw_cur=$(read1 "$cw_p")
    [ -n "$cw_cur" ] || return 1
    mkdir -p "$COOLBK" 2>/dev/null
    { echo "$cw_cur" > "$(cool_bfile "$cw_p")"; } 2>/dev/null || return 1
    echo "$cw_p" >> "$COOLSTACK"
  fi
  [ "$(read1 "$cw_p")" = "$cw_v" ] && return 0
  { echo "$cw_v" > "$cw_p"; } 2>/dev/null
  [ "$(read1 "$cw_p")" = "$cw_v" ] && return 0
  { chmod 644 "$cw_p"; } 2>/dev/null
  { echo "$cw_v" > "$cw_p"; } 2>/dev/null
  [ "$(read1 "$cw_p")" = "$cw_v" ] && return 0
  { chmod 666 "$cw_p"; } 2>/dev/null
  { echo "$cw_v" > "$cw_p"; } 2>/dev/null
  [ "$(read1 "$cw_p")" = "$cw_v" ] && return 0
  echo "rej $cw_p want=$cw_v got=$(read1 "$cw_p")" >> "$RUNDIR/cool_rejected" 2>/dev/null
  return 2
}

# kembalikan SEMUA node yang disentuh cooling (urutan terbalik: plafon naik dulu, baru lantai)
cool_restore_all() {
  [ -s "$COOLSTACK" ] || { : > "$COOLSTACK"; return 0; }
  awk '{a[NR]=$0} END{for(i=NR;i>0;i--) print a[i]}' "$COOLSTACK" | while read -r cr_p; do
    [ -n "$cr_p" ] || continue
    cr_b=$(cool_bfile "$cr_p")
    if [ -f "$cr_b" ]; then
      cr_o=$(cat "$cr_b" 2>/dev/null)
      [ -n "$cr_o" ] && { echo "$cr_o" > "$cr_p"; } 2>/dev/null
    fi
    rm -f "$cr_b"
  done
  : > "$COOLSTACK"
}

# frekuensi tabel terbesar yang <= target (kalau semua > target: yang terkecil)
cool_snap() { # cool_snap <target> <tabel...>
  cs_t=$1; shift
  cs_best=""; cs_lo=""
  for cs_f in "$@"; do
    case "$cs_f" in ''|*[!0-9]*) continue ;; esac
    { [ -z "$cs_lo" ] || [ "$cs_f" -lt "$cs_lo" ]; } && cs_lo=$cs_f
    if [ "$cs_f" -le "$cs_t" ]; then
      { [ -z "$cs_best" ] || [ "$cs_f" -gt "$cs_best" ]; } && cs_best=$cs_f
    fi
  done
  [ -n "$cs_best" ] && echo "$cs_best" || echo "$cs_lo"
}

# ---------------- CPU: plafon per policy ----------------
cool_cpu_apply() { # cool_cpu_apply <pct>
  cc_pct=$1; cc_i=0; cc_ok=0; cc_bad=0
  [ -s "$SCANDIR/cpu_policies" ] || return 1
  while IFS='|' read -r cc_n cc_p cc_min cc_max cc_w cc_t; do
    cc_i=$((cc_i + 1))
    [ -n "$cc_p" ] && [ -e "$cc_p/scaling_max_freq" ] || continue
    cc_base=$cc_max
    cc_ov=$(oc_conf_get "CPU$cc_i" 2>/dev/null)
    [ -n "$cc_ov" ] && [ "$cc_ov" -gt "$cc_base" ] 2>/dev/null && cc_base=$cc_ov
    [ -n "$cc_base" ] || continue
    cc_tgt=$((cc_base * cc_pct / 100))
    if [ -n "$cc_t" ]; then cc_f=$(cool_snap "$cc_tgt" $cc_t); else cc_f=$cc_tgt; fi
    [ -n "$cc_f" ] || continue
    [ -n "$cc_min" ] && [ "$cc_f" -lt "$cc_min" ] 2>/dev/null && cc_f=$cc_min
    # lantai (scaling_min_freq) tidak boleh di atas plafon baru
    cc_curmin=$(read1 "$cc_p/scaling_min_freq")
    if [ -n "$cc_curmin" ] && [ "$cc_curmin" -gt "$cc_f" ] 2>/dev/null; then
      cool_w "$cc_p/scaling_min_freq" "$cc_f" >/dev/null
    fi
    if cool_w "$cc_p/scaling_max_freq" "$cc_f"; then cc_ok=$((cc_ok + 1)); else cc_bad=$((cc_bad + 1)); fi
  done < "$SCANDIR/cpu_policies"
  COOL_CPU_OK=$cc_ok; COOL_CPU_BAD=$cc_bad
  [ "$cc_ok" -ge 1 ]
}

# ---------------- GPU ----------------
cool_gpu_apply() { # cool_gpu_apply <pct>
  cg_pct=$1
  [ "$cg_pct" -lt 40 ] && cg_pct=40            # GPU tidak dijepit di bawah 40%
  if oc_mtk_on; then
    cg_t=$(oc_mtk_tbl_khz)
    [ -n "$cg_t" ] || return 1
    set -- $cg_t; shift $(( $# - 1 )); cg_top=$1
    cg_f=$(cool_snap $((cg_top * cg_pct / 100)) $cg_t)
    [ -n "$cg_f" ] || return 1
    oc_gpu_set_mtk_floor 0 >/dev/null 2>&1      # lantai boost dilepas supaya tidak melawan plafon
    oc_gpu_set_mtk $((cg_f * 1000)) >/dev/null 2>&1 && COOL_GPU_MTK=1
    return 0
  fi
  [ -s "$SCANDIR/gpu" ] || return 1
  IFS='|' read -r cg_be cg_path cg_minn cg_maxn < "$SCANDIR/gpu"
  [ "$cg_be" = devfreq ] || return 1
  [ -e "$cg_path/$cg_maxn" ] || return 1
  cg_tbl=$(cat "$SCANDIR/gpu_tbl" 2>/dev/null)
  [ -n "$cg_tbl" ] || return 1
  set -- $cg_tbl; shift $(( $# - 1 )); cg_top=$1
  cg_f=$(cool_snap $((cg_top * cg_pct / 100)) $cg_tbl)
  [ -n "$cg_f" ] || return 1
  cg_curmin=$(read1 "$cg_path/$cg_minn")
  [ -n "$cg_curmin" ] && [ "$cg_curmin" -gt "$cg_f" ] 2>/dev/null && cool_w "$cg_path/$cg_minn" "$cg_f" >/dev/null
  cool_w "$cg_path/$cg_maxn" "$cg_f" >/dev/null
}

# MTK: kembalikan plafon/lantai GPU sesuai mode aktif (balance/saver/gaming/extreme)
cool_gpu_mtk_release() {
  [ "$COOL_GPU_MTK" = 1 ] || return 0
  COOL_GPU_MTK=0
  cgr_m=$(cat "$DATADIR/azenith_thermal_mode" 2>/dev/null)
  case "$cgr_m" in balance|saver|gaming|extreme) ;; *) cgr_m=balance ;; esac
  ml_gpu_apply "$cgr_m" >/dev/null 2>&1
}

# ---------------- governor / cooling_device / RAPL ----------------
cool_gov_apply() { # cool_gov_apply <level>
  [ "$1" -ge 3 ] 2>/dev/null || return 0
  [ -s "$SCANDIR/cpu_policies" ] || return 0
  if [ "$1" = 4 ]; then cgv_pref="powersave conservative"; else cgv_pref="conservative powersave"; fi
  while IFS='|' read -r cgv_n cgv_p _; do
    [ -n "$cgv_p" ] && [ -e "$cgv_p/scaling_governor" ] || continue
    cgv_av=$(read1 "$cgv_p/scaling_available_governors")
    cgv_pick=""
    for cgv_w in $cgv_pref; do
      oc_gov_valid "$cgv_w" $cgv_av && { cgv_pick=$cgv_w; break; }
    done
    [ -n "$cgv_pick" ] && cool_w "$cgv_p/scaling_governor" "$cgv_pick" >/dev/null
  done < "$SCANDIR/cpu_policies"
}

cool_devs_scan() { # isi COOL_DEVS = daftar direktori cooling_device yang AMAN
  COOL_DEVS=""
  for cds_d in "$R"/sys/class/thermal/cooling_device*; do
    [ -d "$cds_d" ] && [ -e "$cds_d/cur_state" ] || continue
    cds_t=$(lower "$(read1 "$cds_d/type")")
    case "$cds_t" in
      *shutdown*|*charg*|*batt*|*bcct*|*bcl*|*backlight*|*lcd*|*display*|*fan*|*modem*|*wifi*|*cam*|*usb*|*flash*|*torch*|*emerg*|*apu*|*vpu*|*mdla*) continue ;;
      *cpu*|*gpu*|*cluster*|*cpufreq*|*devfreq*|*mali*|*kgsl*|*g3d*) COOL_DEVS="$COOL_DEVS $cds_d" ;;
    esac
  done
}

cool_dev_apply() { # cool_dev_apply <level>
  cda_want=$(cool_state_for "$1")
  [ "$cda_want" -ge 1 ] 2>/dev/null || return 0
  for cda_d in $COOL_DEVS; do
    cda_max=$(read1 "$cda_d/max_state")
    case "$cda_max" in ''|*[!0-9]*) continue ;; esac
    cda_v=$cda_want
    [ "$cda_v" -gt "$cda_max" ] && cda_v=$cda_max
    cool_w "$cda_d/cur_state" "$cda_v" >/dev/null
  done
}

COOL_RAPL="$R/sys/class/powercap/intel-rapl/intel-rapl:0"
cool_rapl_apply() { # cool_rapl_apply <pct>
  [ -e "$COOL_RAPL/constraint_0_power_limit_uw" ] || return 0
  cra_max=$(read1 "$COOL_RAPL/constraint_0_max_power_uw")
  if [ -z "$cra_max" ] || [ "$cra_max" = 0 ]; then
    # tanpa constraint_0_max_power_uw: pakai nilai awal yang sudah dibackup / sedang berlaku
    cra_b=$(cool_bfile "$COOL_RAPL/constraint_0_power_limit_uw")
    cra_max=$(cat "$cra_b" 2>/dev/null); [ -n "$cra_max" ] || cra_max=$(read1 "$COOL_RAPL/constraint_0_power_limit_uw")
  fi
  case "$cra_max" in ''|*[!0-9]*) return 0 ;; esac
  cool_w "$COOL_RAPL/constraint_0_power_limit_uw" $((cra_max * $1 / 100)) >/dev/null
}

# ---------------- satu siklus tulis semua ----------------
COOL_GPU_PCT=""; COOL_GPU_NEXT=0
cool_apply_all() { # cool_apply_all <pct>
  cool_cpu_apply "$1"
  # tulis GPU (MTK: oc_gpu_set_mtk cukup berat) hanya kalau persen berubah / tiap 10 dtk
  caa_now=$(uptime_s)
  if [ "$1" != "$COOL_GPU_PCT" ] || [ "$caa_now" -ge "$COOL_GPU_NEXT" ]; then
    COOL_GPU_PCT=$1; COOL_GPU_NEXT=$((caa_now + 10))
    cool_gpu_apply "$1" 2>/dev/null
  fi
  cool_gov_apply "$COOL_LV"
  cool_dev_apply "$COOL_LV"
  cool_rapl_apply "$1"
}

cool_state_write() {
  echo "lv=$COOL_LV pct=$COOL_PCT engaged=$COOL_ENGAGED soc=${T_SOC:-?} trig=$(cool_trig "$COOL_LV") game=${GAME_PKG:-}" > "$COOL_STATE_F" 2>/dev/null
}

# ---------------- siklus hidup (dipanggil daemon) ----------------
cool_release() { # lepas SEMUA (suhu sudah dingin / slider 0 / game berhenti)
  cool_restore_all
  cool_gpu_mtk_release
  COOL_ENGAGED=0; COOL_PCT=100; COOL_DEVS=""; COOL_GPU_PCT=""
}

cool_start() { # dari start_game()
  load_conf
  # sisa backup dari sesi yang mati mendadak (daemon crash) -> pulihkan dulu
  [ -s "$COOLSTACK" ] && cool_restore_all
  COOL_ENGAGED=0; COOL_PCT=100; COOL_NEXT=0; COOL_RELOAD=0; COOL_GPU_MTK=0
  : > "$RUNDIR/cool_rejected" 2>/dev/null
  COOL_LV=0
  [ "$FEAT_COOLING" = 1 ] || return 0
  [ -n "$GAME_PKG" ] || return 0
  cs_lv=$(cool_get "$GAME_PKG"); [ -n "$cs_lv" ] || cs_lv=$(cool_get ALL); COOL_LV=${cs_lv:-0}   # ALL = pengaturan global (kartu Cooling SoC)
  case "$COOL_LV" in 1|2|3|4) ;; *) COOL_LV=0; return 0 ;; esac
  COOL_RELOAD=$(( $(uptime_s) + 10 ))
  flog COOLING INFO "game $GAME_PKG: Cooling SoC level $COOL_LV ($(cool_name "$COOL_LV")) siaga - mulai turun saat SoC >= $(cool_trig "$COOL_LV")C"
  log_msg "COOLING: $GAME_PKG level=$COOL_LV trig=$(cool_trig "$COOL_LV")C lantai=$(cool_floor "$COOL_LV")%"
  cool_state_write
}

cool_tick() { # dari tick_ingame() - PALING AKHIR supaya menang atas FSE/AKS
  [ "$FEAT_COOLING" = 1 ] || return 0
  [ -n "$GAME_PKG" ] || return 0
  ct_now=$(uptime_s)
  # baca ulang level tiap 10 dtk (slider bisa digeser saat game jalan)
  if [ "$ct_now" -ge "$COOL_RELOAD" ]; then
    COOL_RELOAD=$((ct_now + 10))
    ct_lv=$(cool_get "$GAME_PKG"); [ -n "$ct_lv" ] || ct_lv=$(cool_get ALL); ct_lv=${ct_lv:-0}
    if [ "$ct_lv" != "$COOL_LV" ]; then
      [ "$COOL_ENGAGED" = 1 ] && cool_release
      COOL_LV=$ct_lv
      case "$COOL_LV" in 1|2|3|4) ;; *) COOL_LV=0 ;; esac
      flog COOLING INFO "game $GAME_PKG: level diganti ke $COOL_LV ($(cool_name "$COOL_LV"))"
      if [ "$COOL_LV" = 0 ]; then rm -f "$COOL_STATE_F"; fi
    fi
  fi
  [ "$COOL_LV" -ge 1 ] 2>/dev/null || return 0
  [ -n "$T_SOC" ] || return 0                      # tanpa suhu asli: jangan menebak
  ct_trig=$(cool_trig "$COOL_LV"); ct_fl=$(cool_floor "$COOL_LV")
  [ -n "$COOL_STEP_SEC" ] || COOL_STEP_SEC=60
  [ -n "$COOL_STEP_PCT" ] || COOL_STEP_PCT=10
  [ -n "$COOL_HYST_C" ] || COOL_HYST_C=6
  if [ "$T_SOC" -ge "$ct_trig" ]; then
    if [ "$COOL_ENGAGED" = 0 ]; then
      COOL_ENGAGED=1; COOL_NEXT=0; cool_devs_scan
      flog COOLING INFO "game $GAME_PKG: SoC ${T_SOC}C >= ${ct_trig}C -> Cooling SoC AKTIF (level $COOL_LV)"
    fi
    if [ "$ct_now" -ge "$COOL_NEXT" ] && [ "$COOL_PCT" -gt "$ct_fl" ]; then
      COOL_PCT=$((COOL_PCT - COOL_STEP_PCT)); [ "$COOL_PCT" -lt "$ct_fl" ] && COOL_PCT=$ct_fl
      COOL_NEXT=$((ct_now + COOL_STEP_SEC))
      log_msg "COOLING: SoC ${T_SOC}C -> plafon turun ke ${COOL_PCT}% ($GAME_PKG)"
      flog COOLING INFO "SoC ${T_SOC}C: plafon CPU/GPU diturunkan ke ${COOL_PCT}% (lantai ${ct_fl}%)"
    fi
  elif [ "$COOL_ENGAGED" = 1 ] && [ "$T_SOC" -le $((ct_trig - COOL_HYST_C)) ]; then
    if [ "$ct_now" -ge "$COOL_NEXT" ]; then
      COOL_PCT=$((COOL_PCT + COOL_STEP_PCT))
      COOL_NEXT=$((ct_now + COOL_STEP_SEC))
      if [ "$COOL_PCT" -ge 100 ]; then
        cool_release
        flog COOLING OK "SoC ${T_SOC}C sudah dingin -> Cooling SoC dilepas, semua node dikembalikan"
        cool_state_write
        return 0
      fi
      log_msg "COOLING: SoC ${T_SOC}C dingin -> plafon naik ke ${COOL_PCT}% ($GAME_PKG)"
    fi
  fi
  if [ "$COOL_ENGAGED" = 1 ]; then
    cool_apply_all "$COOL_PCT"                      # ditulis ulang tiap tick (vendor/kernel bisa menimpa)
    if [ "${COOL_CPU_BAD:-0}" -gt 0 ] 2>/dev/null; then
      flog COOLING BUG "plafon CPU ditolak kernel di ${COOL_CPU_BAD} cluster (dikunci vendor? lihat $RUNDIR/cool_rejected)"
    fi
  fi
  cool_state_write
}

cool_revert() { # dari stop_game() - SEBELUM cleanup_all supaya urutan restore benar
  if [ "$COOL_ENGAGED" = 1 ] || [ -s "$COOLSTACK" ] || [ "$COOL_GPU_MTK" = 1 ]; then
    cool_release
    log_msg "COOLING: dilepas (game berhenti) - semua node dikembalikan"
  fi
  COOL_LV=0; COOL_ENGAGED=0; COOL_PCT=100
  rm -f "$COOL_STATE_F"
}

# ---------------- CLI ----------------
cool_set_cli() { # cool_set_cli <pkg> <0-4>
  case "$1" in ''|*[!A-Za-z0-9_.]*) echo "nama paket tidak valid"; return 1 ;; esac
  case "$2" in 0|1|2|3|4) ;; *) echo "level harus 0-4 (0=mati 1=ringan 2=sedang 3=kuat 4=maksimal)"; return 1 ;; esac
  cool_set_conf "$1" "$2"
  if [ "$2" = 0 ]; then
    echo "Cooling SoC dimatikan untuk $1 (node dipulihkan otomatis maks ~10 dtk kalau game sedang jalan)"
  else
    echo "Cooling SoC $1 -> level $2 ($(cool_name "$2")): mulai turun saat SoC >= $(cool_trig "$2")C, lantai $(cool_floor "$2")%, -${COOL_STEP_PCT:-10}% tiap ${COOL_STEP_SEC:-60} dtk. Aktif otomatis di sesi game (maks ~10 dtk kalau game sedang jalan)."
  fi
}

cool_status() {
  load_conf
  echo "FEAT_COOLING=$FEAT_COOLING  step=${COOL_STEP_PCT}%/${COOL_STEP_SEC}dtk  histeresis=${COOL_HYST_C}C"
  echo "state   : $(cat "$COOL_STATE_F" 2>/dev/null || echo '(tidak ada sesi aktif)')"
  echo "game    :"; cool_list | sed 's/^/  /'
  scan_if_needed >/dev/null 2>&1
  cool_devs_scan
  echo "cooling_device aman dipakai:"
  for st_d in $COOL_DEVS; do echo "  ${st_d##*/} type=$(read1 "$st_d/type") cur=$(read1 "$st_d/cur_state") max=$(read1 "$st_d/max_state")"; done
  [ -e "$COOL_RAPL/constraint_0_power_limit_uw" ] && echo "RAPL    : $(read1 "$COOL_RAPL/constraint_0_power_limit_uw") uW"
  echo "node disentuh sekarang: $(wc -l < "$COOLSTACK" 2>/dev/null || echo 0)"
  [ -s "$RUNDIR/cool_rejected" ] && { echo "ditolak kernel:"; sed 's/^/  /' "$RUNDIR/cool_rejected"; }
  return 0
}

# pulihkan paksa (kalau daemon mati mendadak waktu cooling aktif)
cool_reset() {
  cool_restore_all
  COOL_GPU_MTK=1; cool_gpu_mtk_release
  COOL_ENGAGED=0; COOL_PCT=100
  rm -f "$COOL_STATE_F"
  echo "Cooling SoC: semua node dikembalikan ke nilai sebelum cooling"
}
