#!/system/bin/sh
# =====================================================================
#  Zyrox v2 - lib/thermal.sh
#  Thermal lock / inject / monitor berbasis HASIL SCAN (bukan tebakan path).
#
#  Strategi (urutan dari paling halus), dipilih sesuai THERMAL_MODE:
#   soft : freeze daemon thermal userspace + prop bergaya "disable" + override
#          status thermalservice (cmd thermalservice)
#   auto : soft + (emul_temp bila kernel mendukung, kalau tidak: mode=disabled
#          pada zona kelas SoC)  <- default
#   hard : auto + node vendor penonaktif throttle + naikkan trip passive
#   off  : tidak menyentuh thermal sama sekali
#
#  PENGAMAN:
#   * Zona yang di-freeze/di-inject TIDAK bisa dibaca apa adanya, jadi monitor
#     memakai "probe" (sementara kembalikan zona, baca suhu asli, bekukan lagi)
#     + sensor baterai/skin yang tidak pernah disentuh.
#   * Kalau suhu asli SoC tidak bisa dibaca sama sekali setelah apply,
#     perubahan zona langsung dibatalkan.
#   * Batas suhu tier-aware, bukan satu angka 50C untuk semua.
# =====================================================================

FROZEN_F="$RUNDIR/frozen_ids"
EMUL_F="$RUNDIR/emul_ids"
THERM_STATE=0; THERM_WHY=""; HOT_SINCE=0; HARD_TRIPPED=0
T_SOC=""; T_BATT=""; T_SKIN=""

thermal_limits_init() {
  case "$SAFE_SOC_C" in
    ''|*[!0-9]*)
      case "${TIER:-mid}" in
        flagship) SOC_LIM=92 ;; high) SOC_LIM=88 ;; mid) SOC_LIM=85 ;; *) SOC_LIM=80 ;;
      esac ;;
    *) SOC_LIM=$SAFE_SOC_C ;;
  esac
  BATT_LIM=$SAFE_BATT_C; SKIN_LIM=$SAFE_SKIN_C
}

zone_dir() { echo "$R/sys/class/thermal/thermal_zone$1"; }

zone_read_c() { # zdir -> suhu C
  { read -r zr_v < "$1/temp"; } 2>/dev/null || return 1
  norm_temp "$zr_v"
}

batt_read_c() {
  bt_v=$(read1 "$R/sys/class/power_supply/battery/temp")
  if [ -z "$bt_v" ]; then
    bt_v=$(dumpsys battery 2>/dev/null | sed -n 's/^ *temperature: *\([0-9][0-9]*\).*/\1/p' | head -n1)
  fi
  case "$bt_v" in ''|*[!0-9]*) return 1 ;; esac
  echo $((bt_v / 10))      # standar kernel & dumpsys: persepuluh derajat
}

# probe zona yang dibekukan/di-inject: ambil suhu ASLI sesaat
zone_probe_c() {
  zp_i=$1; zp_d=$(zone_dir "$zp_i")
  zp_f=$(cat "$FROZEN_F" 2>/dev/null); zp_e=$(cat "$EMUL_F" 2>/dev/null)
  case " $zp_e " in
    *" $zp_i "*)
      { echo 0 > "$zp_d/emul_temp"; } 2>/dev/null
      zp_t=$(zone_read_c "$zp_d")
      { echo $((INJECT_C * 1000)) > "$zp_d/emul_temp"; } 2>/dev/null
      echo "$zp_t"; return 0 ;;
  esac
  case " $zp_f " in
    *" $zp_i "*)
      { echo enabled > "$zp_d/mode"; } 2>/dev/null
      zp_t=$(zone_read_c "$zp_d")
      { echo disabled > "$zp_d/mode"; } 2>/dev/null
      echo "$zp_t"; return 0 ;;
  esac
  zone_read_c "$zp_d"
}

# temps_read [probe]  -> mengisi T_SOC T_BATT T_SKIN (integer C, kosong = tidak terbaca)
temps_read() {
  tr_probe=$1
  T_SOC=""; T_SKIN=""
  tr_hid=" $(cat "$FROZEN_F" 2>/dev/null) $(cat "$EMUL_F" 2>/dev/null) "
  while IFS='|' read -r tr_i tr_t tr_c tr_e tr_tp; do
    case "$tr_c" in soc|skin) ;; *) continue ;; esac
    case "$tr_hid" in
      *" $tr_i "*)
        [ "$tr_probe" = probe ] || continue
        tr_v=$(zone_probe_c "$tr_i") ;;
      *) tr_v=$(zone_read_c "$(zone_dir "$tr_i")") ;;
    esac
    [ -n "$tr_v" ] || continue
    if [ "$tr_c" = soc ]; then
      { [ -z "$T_SOC" ] || [ "$tr_v" -gt "$T_SOC" ]; } && T_SOC=$tr_v
    else
      { [ -z "$T_SKIN" ] || [ "$tr_v" -gt "$T_SKIN" ]; } && T_SKIN=$tr_v
    fi
  done < "$SCANDIR/zones"
  T_BATT=$(batt_read_c)
}

# evaluasi tekanan thermal: THERM_STATE 0=normal 1=hangat 2=panas (>= ambang waktu)
#
# poin 5 (proteksi panas mode hard): THERMAL_MODE=hard mematikan lebih banyak
# node throttle vendor, jadi pengaman software di sini TIDAK BOLEH memakai
# ambang yang sama dengan auto/soft. Dua lapis tambahan khusus hard:
#  a) ambang waktu lebih pendek (HARD_SAFE_HOT_SECONDS, default 8 dtk vs 20 dtk)
#  b) "emergency": suhu melewati limit tier + HARD_EMERGENCY_MARGIN_C -> trip
#     LANGSUNG (THERM_STATE=2) tanpa menunggu ambang waktu sama sekali, karena
#     tanpa throttle vendor suhu bisa naik sangat cepat.
thermal_eval() {
  now=$(uptime_s)
  te_hot=0; te_warm=0; te_emerg=0; THERM_WHY=""
  te_hard=0; [ "$THERMAL_MODE" = hard ] && te_hard=1
  if [ -n "$T_SOC" ]; then
    [ "$T_SOC" -ge "$SOC_LIM" ] && { te_hot=1; THERM_WHY="SoC ${T_SOC}C>=${SOC_LIM}C"; }
    [ "$te_hard" = 1 ] && [ "$T_SOC" -ge $((SOC_LIM + HARD_EMERGENCY_MARGIN_C)) ] && { te_emerg=1; THERM_WHY="EMERGENCY SoC ${T_SOC}C>=${SOC_LIM}+${HARD_EMERGENCY_MARGIN_C}C"; }
    [ "$T_SOC" -ge $((SOC_LIM - 5)) ] && te_warm=1
  fi
  if [ -n "$T_BATT" ]; then
    [ "$T_BATT" -ge "$BATT_LIM" ] && { te_hot=1; THERM_WHY="$THERM_WHY baterai ${T_BATT}C>=${BATT_LIM}C"; }
    [ "$te_hard" = 1 ] && [ "$T_BATT" -ge $((BATT_LIM + HARD_EMERGENCY_MARGIN_C)) ] && { te_emerg=1; THERM_WHY="$THERM_WHY EMERGENCY baterai ${T_BATT}C"; }
    [ "$T_BATT" -ge $((BATT_LIM - 2)) ] && te_warm=1
  fi
  if [ -n "$T_SKIN" ]; then
    [ "$T_SKIN" -ge "$SKIN_LIM" ] && { te_hot=1; THERM_WHY="$THERM_WHY skin ${T_SKIN}C>=${SKIN_LIM}C"; }
    [ "$te_hard" = 1 ] && [ "$T_SKIN" -ge $((SKIN_LIM + HARD_EMERGENCY_MARGIN_C)) ] && { te_emerg=1; THERM_WHY="$THERM_WHY EMERGENCY skin ${T_SKIN}C"; }
    [ "$T_SKIN" -ge $((SKIN_LIM - 2)) ] && te_warm=1
  fi
  if [ "$te_emerg" = 1 ]; then
    HOT_SINCE=$now; THERM_STATE=2; HARD_TRIPPED=1; return
  fi
  if [ "$te_hot" = 1 ]; then
    [ "$HOT_SINCE" = 0 ] && HOT_SINCE=$now
    te_lim=$SAFE_HOT_SECONDS; [ "$te_hard" = 1 ] && te_lim=$HARD_SAFE_HOT_SECONDS
    if [ $((now - HOT_SINCE)) -ge "$te_lim" ]; then
      [ "$te_hard" = 1 ] && HARD_TRIPPED=1
      THERM_STATE=2; return
    fi
    THERM_STATE=1; return
  fi
  HOT_SINCE=0
  THERM_STATE=$te_warm
}

# ---------------------------------------------------------------------
thermal_apply() {
  [ "$FEAT_THERMAL" = 1 ] || return 0
  [ "$THERMAL_MODE" = off ] && return 0
  thermal_limits_init
  temps_read
  if [ -z "$T_BATT" ]; then
    log_msg "A: sensor baterai tidak terbaca -> thermal tweak DIBATALKAN (tanpa pengaman minimum)"
    flog THERMAL ERR "sensor baterai tidak terbaca -> thermal tweak dibatalkan (tanpa pengaman minimum)"
    return 1
  fi
  : > "$FROZEN_F"; : > "$EMUL_F"
  th_n_svc=0; th_n_prop=0; th_n_emul=0; th_n_frz=0; th_n_vend=0; th_n_trip=0

  # 1) service daemon thermal userspace
  while IFS='|' read -r th_s th_st; do
    [ -n "$th_s" ] || continue
    svc_stop "$th_s" && th_n_svc=$((th_n_svc + 1))
  done < "$SCANDIR/thermal_services"

  # 2) prop bergaya disable-thermal
  while IFS='|' read -r th_k th_v; do
    [ -n "$th_k" ] || continue
    prop_set "$th_k" "$th_v" && th_n_prop=$((th_n_prop + 1))
  done < "$SCANDIR/thermal_props"

  # 3) override status thermalservice (framework: Android 11+)
  if [ "$(getp ro.build.version.sdk)" -ge 30 ] 2>/dev/null; then
    cmd thermalservice override-status 0 >/dev/null 2>&1 && : > "$RUNDIR/thermal_override"
  fi

  # 4) zona kelas SoC: emul_temp kalau ada, kalau tidak mode=disabled
  if [ "$THERMAL_MODE" = auto ] || [ "$THERMAL_MODE" = hard ]; then
    while IFS='|' read -r th_i th_t th_c th_e th_tp; do
      [ "$th_c" = soc ] || continue
      th_d=$(zone_dir "$th_i")
      if [ "$th_e" = 1 ] && { echo $((INJECT_C * 1000)) > "$th_d/emul_temp"; } 2>/dev/null; then
        th_chk=$(zone_read_c "$th_d")
        if [ "$th_chk" = "$INJECT_C" ]; then
          echo "$th_i" >> "$EMUL_F"; th_n_emul=$((th_n_emul + 1)); continue
        fi
        { echo 0 > "$th_d/emul_temp"; } 2>/dev/null    # tidak efektif -> batalkan
      fi
      if [ -e "$th_d/mode" ] && [ "$(read1 "$th_d/mode")" = enabled ]; then
        if safe_write "$th_d/mode" disabled; then
          echo "$th_i" >> "$FROZEN_F"; th_n_frz=$((th_n_frz + 1))
        fi
      fi
    done < "$SCANDIR/zones"
  fi

  # 5) hard: node vendor + trip passive
  if [ "$THERMAL_MODE" = hard ]; then
    while IFS='|' read -r th_p th_v; do
      [ -n "$th_p" ] || continue
      safe_write "$th_p" "$th_v" && th_n_vend=$((th_n_vend + 1))
    done < "$SCANDIR/thermal_vendor"
  fi
  if [ "$THERMAL_MODE" = hard ] && [ "$TRIP_RAISE_C" -gt 0 ]; then
    while IFS='|' read -r th_i th_t th_c th_e th_tp; do
      [ "$th_c" = soc ] && [ "$th_tp" = 1 ] || continue
      th_d=$(zone_dir "$th_i")
      for th_ty in "$th_d"/trip_point_*_type; do
        [ -e "$th_ty" ] || continue
        case "$(read1 "$th_ty")" in passive|active) ;; *) continue ;; esac
        th_tf=${th_ty%_type}_temp
        th_cur=$(read1 "$th_tf")
        case "$th_cur" in ''|*[!0-9]*) continue ;; esac
        th_new=$((th_cur + TRIP_RAISE_C * 1000))
        [ "$th_new" -le 100000 ] || continue
        safe_write "$th_tf" "$th_new" && th_n_trip=$((th_n_trip + 1))
      done
    done < "$SCANDIR/zones"
  fi

  # 6) pengaman: suhu asli SoC harus tetap bisa dibaca
  if [ -s "$FROZEN_F" ] || [ -s "$EMUL_F" ]; then
    temps_read probe
    if [ -z "$T_SOC" ]; then
      log_msg "A: suhu asli SoC TIDAK terbaca setelah apply -> batalkan perubahan zona"
      flog THERMAL BUG "suhu asli SoC tidak terbaca setelah apply -> perubahan zona dibatalkan"
      thermal_revert_zones
    fi
  fi
  flog THERMAL OK "mode=$THERMAL_MODE diterapkan (svc=$th_n_svc prop=$th_n_prop zona=$th_n_emul trip=$th_n_trip, soc=${T_SOC:-?}C batt=${T_BATT}C)"
  log_msg "A: thermal mode=$THERMAL_MODE svc=$th_n_svc prop=$th_n_prop emul=$th_n_emul freeze=$th_n_frz vendor=$th_n_vend trip=$th_n_trip (soc=${T_SOC:-?}C batt=${T_BATT}C)"
  return 0
}

thermal_revert_zones() {
  for te_i in $(cat "$EMUL_F" 2>/dev/null); do
    { echo 0 > "$(zone_dir "$te_i")/emul_temp"; } 2>/dev/null
  done
  : > "$EMUL_F"
  # mode zona dikembalikan oleh revert_stack (path ... /mode ada di STACK)
  for tf_i in $(cat "$FROZEN_F" 2>/dev/null); do
    tf_p="$(zone_dir "$tf_i")/mode"
    restore_path "$tf_p"
    stack_drop "$tf_p"
  done
  : > "$FROZEN_F"
}

thermal_revert() {
  thermal_revert_zones
  if [ -f "$RUNDIR/thermal_override" ]; then
    cmd thermalservice reset >/dev/null 2>&1
    rm -f "$RUNDIR/thermal_override"
  fi
  # service/props/vendor/trip dikembalikan oleh revert_services/revert_props/revert_stack
}
