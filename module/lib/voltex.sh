#!/system/bin/sh
# =====================================================================
#  Zyrox - lib/voltex.sh : "VoltEx" - bagian arus charge dari Fast Charger
#  (porting konsep VoltEx Charg E.O.L oleh @vennec)
#
#  HANYA hidup bersama Fast Charger: fc_on -> vx_on, fc_off -> vx_off
#  (tidak ada toggle sendiri). Yang dilakukan:
#   1) buka batas bawaan pabrik: step_charging_enabled / thermal_limit_current /
#      restrict_chg / batt_slate_mode = 0, usb_fastcharge_en = 1 (kalau ada)
#   2) override prop thermal baterai (resetprop, in-memory, systemless)
#   3) loop tiap VX_TICK detik (10): tulis target 6 A ke constant_charge_current_max,
#      input_current_max, usb/current_max dengan write_lock (666 -> tulis -> 444)
#   4) pengaman suhu: > 45.0C -> arus 3 A, kembali 6 A setelah <= 42.0C.
#      Suhu tidak terbaca -> juga 3 A (gagal-aman).
#
#  SENGAJA TIDAK DILAKUKAN: menaikkan ambang temp_cool/temp_warm/temp_hot
#  ke 90-95C. Itu pemutus suhu tingkat hardware/PMIC - kalau loop ini mati,
#  satu-satunya penjaga hilang. Batas arus 6 A (VX_MAX_UA) juga tidak bisa dilewati.
#
#  Semua node di-backup (nilai + mode file) dan dikembalikan persis saat OFF.
# =====================================================================

VX_BK="$DATADIR/voltex_backup"      # node|nilai_asli|mode_asli
VX_PBK="$DATADIR/voltex_props"      # prop|nilai_asli
VX_FLAG="$DATADIR/voltex_on"        # ada = VoltEx sedang aktif (tahan reboot)
VX_PID="$RUNDIR/voltex.pid"
VX_STATE="$RUNDIR/voltex_state"     # full | cool
VX_MAX_UA=6000000
# v1.0.44: direktori dicari DINAMIS (semua power_supply + lokasi vendor MTK/Qualcomm/Xiaomi), bukan 5 path tetap.
vx_dirs() {
  for vd_d in "$R"/sys/class/power_supply/* "$R"/sys/class/qcom-battery "$R"/sys/devices/platform/charger \
              "$R"/sys/devices/platform/mt-battery "$R"/sys/devices/platform/battery "$R"/sys/class/power_supply/mtk-master-charger; do
    [ -d "$vd_d" ] || continue
    case "${vd_d##*/}" in *wireless*|*dc-wireless*) ;; esac
    echo "$vd_d"
  done
}

vx_find() { for vf_d in $(vx_dirs); do [ -e "$vf_d/$1" ] && echo "$vf_d/$1"; done; }
vx_cur_nodes() {
  vx_find constant_charge_current_max
  vx_find constant_charge_current
  vx_find input_current_max
  vx_find input_current_limit
  vx_find charging_current_limit
  [ -e "$R/sys/class/power_supply/usb/current_max" ] && echo "$R/sys/class/power_supply/usb/current_max"
  [ -e "$R/sys/class/power_supply/ac/current_max" ] && echo "$R/sys/class/power_supply/ac/current_max"
}

vx_node_backup() { # sekali saja per node
  grep -q "^$1|" "$VX_BK" 2>/dev/null && return 0
  vb_m=$(stat -c %a "$1" 2>/dev/null)
  echo "$1|$(dv_cat "$1")|${vb_m:-644}" >> "$VX_BK"
}
vx_bk_mode() { awk -F'|' -v k="$1" '$1 == k { print $3; exit }' "$VX_BK" 2>/dev/null; }

vx_write_node() { # vx_write_node PATH VAL LOCK(0|1)
  [ -e "$1" ] || return 1
  vx_node_backup "$1"
  chmod 666 "$1" 2>/dev/null
  { echo "$2" > "$1"; } 2>/dev/null; vw_r=$?
  if [ "$3" = 1 ]; then chmod 444 "$1" 2>/dev/null; else chmod "$(vx_bk_mode "$1")" "$1" 2>/dev/null; fi
  return $vw_r
}

vx_cap() { # batasi 500000..6000000
  vc_v=$1; case "$vc_v" in ''|*[!0-9]*) vc_v=$VX_MAX_UA ;; esac
  [ "$vc_v" -gt "$VX_MAX_UA" ] && vc_v=$VX_MAX_UA
  [ "$vc_v" -lt 500000 ] && vc_v=500000
  echo "$vc_v"
}

vx_set_current() { # vx_set_current <uA> -> "ok total"
  vs_ok=0; vs_t=0
  for vs_p in $(vx_cur_nodes); do
    vs_t=$((vs_t + 1))
    vx_write_node "$vs_p" "$1" 1 && vs_ok=$((vs_ok + 1))
  done
  echo "$vs_ok $vs_t"
}

vx_unlock() { # -> "ok total"
  vu_ok=0; vu_t=0
  for vu_n in step_charging_enabled thermal_limit_current restrict_chg batt_slate_mode; do
    for vu_p in $(vx_find "$vu_n"); do
      vu_t=$((vu_t + 1)); vx_write_node "$vu_p" 0 0 && vu_ok=$((vu_ok + 1))
    done
  done
  for vu_p in $(vx_find usb_fastcharge_en); do
    vu_t=$((vu_t + 1)); vx_write_node "$vu_p" 1 0 && vu_ok=$((vu_ok + 1))
  done
  echo "$vu_ok $vu_t"
}

vx_props_on() { # cetak jumlah prop berhasil
  vp_n=0
  command -v resetprop >/dev/null 2>&1 || { echo 0; return; }
  for vp_e in persist.sys.miui.battery.thermal_limit=false persist.vendor.battery.thermal_control=0 ro.vendor.battery.disable_thermal_throttling=true; do
    vp_k=${vp_e%%=*}; vp_v=${vp_e#*=}
    grep -q "^$vp_k|" "$VX_PBK" 2>/dev/null || echo "$vp_k|$(getprop "$vp_k" 2>/dev/null)" >> "$VX_PBK"
    resetprop "$vp_k" "$vp_v" 2>/dev/null && vp_n=$((vp_n + 1))
  done
  echo "$vp_n"
}
vx_props_off() {
  [ -s "$VX_PBK" ] || { : > "$VX_PBK"; return 0; }
  while IFS='|' read -r vq_k vq_v; do
    [ -n "$vq_k" ] || continue
    if [ -n "$vq_v" ]; then resetprop "$vq_k" "$vq_v" 2>/dev/null || setprop "$vq_k" "$vq_v" 2>/dev/null
    else resetprop --delete "$vq_k" 2>/dev/null; fi
  done < "$VX_PBK"
  : > "$VX_PBK"
}

# suhu baterai dalam 0.1C (450 = 45.0C); gagal -> return 1
vx_temp10() {
  vt_d=$(chg_bat_dir) 2>/dev/null || return 1
  vt_r=$(dv_cat "$vt_d/temp"); case "$vt_r" in ''|*[!0-9]*) return 1 ;; esac
  if [ "$vt_r" -ge 1000 ]; then vt_r=$((vt_r / 100)); elif [ "$vt_r" -lt 150 ]; then vt_r=$((vt_r * 10)); fi
  echo "$vt_r"
}

vx_tmax() { # batas suhu 0.1C, dipaksa <= 450
  vm_v=${VX_TEMP_MAX:-450}; case "$vm_v" in ""|*[!0-9]*) vm_v=450 ;; esac
  [ "$vm_v" -gt 450 ] && vm_v=450
  echo "$vm_v"
}

# satu putaran: pilih 6 A / 3 A sesuai suhu, tulis, tahan batas. Cetak "state ua ok total"
vx_tick() {
  vk_max=$(vx_tmax)
  vk_res=${VX_TEMP_RESUME:-420}; case "$vk_res" in ''|*[!0-9]*) vk_res=420 ;; esac; [ "$vk_res" -ge "$vk_max" ] && vk_res=$((vk_max - 30))
  vk_t=$(vx_temp10); vk_old=$(cat "$VX_STATE" 2>/dev/null)
  if [ -z "$vk_t" ]; then vk_want=cool
  elif [ "$vk_t" -gt "$vk_max" ]; then vk_want=cool
  elif [ "$vk_old" = cool ] && [ "$vk_t" -gt "$vk_res" ]; then vk_want=cool
  else vk_want=full; fi
  if [ "$vk_want" = full ]; then vk_ua=$(vx_cap "${VX_CURRENT_UA:-6000000}"); else vk_ua=$(vx_cap "${VX_LOW_UA:-3000000}"); fi
  vx_unlock >/dev/null
  set -- $(vx_set_current "$vk_ua")
  echo "$vk_want" > "$VX_STATE"
  [ "$vk_want" != "$vk_old" ] && log_msg "VOLTEX: $vk_old -> $vk_want (suhu=${vk_t:-?}/10 C, arus=${vk_ua}uA)"
  echo "$vk_want $vk_ua $1 $2"
}

vx_failsafe() { [ -f "$VX_FLAG" ] && vx_set_current "$(vx_cap "${VX_LOW_UA:-3000000}")" >/dev/null 2>&1; }

vx_loop_alive() { vl_p=$(cat "$VX_PID" 2>/dev/null); [ -n "$vl_p" ] && kill -0 "$vl_p" 2>/dev/null; }
vx_loop_start() { vx_loop_alive && return 0; nohup sh "$MODDIR/lib/voltexloop.sh" >/dev/null 2>&1 & }
vx_loop_stop() { vl_p=$(cat "$VX_PID" 2>/dev/null); [ -n "$vl_p" ] && kill "$vl_p" 2>/dev/null; rm -f "$VX_PID"; }

vx_on() {
  load_conf
  if [ "$CHARGE_BYPASS" = 1 ]; then
    echo "VoltEx: DILEWATI - Bypass Charging sedang AKTIF (matikan dulu supaya arus bisa dipaksa). Fast Charger tetap jalan (thermal saja)."
    return 1
  fi
  [ -f "$VX_BK" ] || : > "$VX_BK"; [ -f "$VX_PBK" ] || : > "$VX_PBK"
  set -- $(vx_unlock); vo_ul=$1; vo_ut=$2
  vo_pn=$(vx_props_on)
  : > "$VX_FLAG"; rm -f "$VX_STATE"
  set -- $(vx_tick); vo_st=$1; vo_ua=$2; vo_ok=$3; vo_t=$4
  vx_loop_start
  log_msg "VOLTEX: AKTIF state=$vo_st arus=${vo_ua}uA node_arus=$vo_ok/$vo_t limit=$vo_ul/$vo_ut prop=$vo_pn/3"
  flog FASTCHARGE INFO "VoltEx ON state=$vo_st arus=${vo_ua}uA node_arus=$vo_ok/$vo_t"
  echo "VoltEx: AKTIF - target $((vo_ua / 1000000)) A ($vo_st), node arus $vo_ok/$vo_t, batas pabrik dibuka $vo_ul/$vo_ut, prop thermal baterai $vo_pn/3"
  echo "Pengaman VoltEx: suhu baterai > 45.0C -> arus 3 A, kembali 6 A setelah <= 42.0C (tidak bisa dimatikan)"
  if [ "${vo_t:-0}" -eq 0 ] 2>/dev/null; then
    echo "PERINGATAN: node arus charge tidak ditemukan di perangkat ini - VoltEx tidak berpengaruh (Fast Charger tetap mematikan thermal)"
  elif [ "${vo_ok:-0}" -eq 0 ] 2>/dev/null; then
    echo "PERINGATAN: kernel menolak semua penulisan node arus ($vo_t node) - arus tidak berubah"
  fi
}

vx_off() {
  [ -f "$VX_FLAG" ] || [ -s "$VX_BK" ] || [ -s "$VX_PBK" ] || return 0
  rm -f "$VX_FLAG" "$VX_STATE"
  vx_loop_stop
  vf_n=0
  if [ -s "$VX_BK" ]; then
    while IFS='|' read -r vf_p vf_v vf_m; do
      [ -n "$vf_p" ] && [ -e "$vf_p" ] || continue
      chmod 666 "$vf_p" 2>/dev/null
      [ -n "$vf_v" ] && { echo "$vf_v" > "$vf_p"; } 2>/dev/null
      chmod "${vf_m:-644}" "$vf_p" 2>/dev/null
      vf_n=$((vf_n + 1))
    done < "$VX_BK"
  fi
  : > "$VX_BK"
  vx_props_off
  log_msg "VOLTEX: MATI ($vf_n node dikembalikan)"
  echo "VoltEx: MATI ($vf_n node arus/batas dikembalikan ke nilai & mode asli, prop thermal dipulihkan)"
}

vx_status() {
  load_conf
  echo "VoltEx: $([ -f "$VX_FLAG" ] && echo AKTIF || echo mati)  loop=$(vx_loop_alive && echo jalan || echo mati)  state=$(cat "$VX_STATE" 2>/dev/null)  suhu=$(vx_temp10 2>/dev/null)/10C  batas_suhu=$(vx_tmax)/10C"
}

# pembacaan live untuk panel Fast Charger di WebUI (read-only, nilai mentah dari sysfs)
vx_power() {
  vw_d=$(chg_bat_dir) 2>/dev/null
  echo "cur_raw=$(dv_cat "$vw_d/current_now")"
  echo "volt_raw=$(dv_cat "$vw_d/voltage_now")"
  echo "t10=$(vx_temp10 2>/dev/null)"
  echo "cap=$(chg_cur_level)"
  echo "status=$(chg_real_status)"
  echo "status_raw=$(chg_cur_status)"
  echo "plugged=$(chg_plugged && echo 1 || echo 0)"
  echo "chg_type=$(chg_type)"
  echo "vx=$([ -f "$VX_FLAG" ] && echo 1 || echo 0)"
  echo "vx_state=$(cat "$VX_STATE" 2>/dev/null)"
}

# v1.0.44: daftar node arus charge yang ditemukan di perangkat ini (diagnosa "node tidak ditemukan")
vx_scan() {
  echo "== power_supply =="
  for sc_d in "$R"/sys/class/power_supply/*; do
    [ -d "$sc_d" ] || continue
    echo "${sc_d##*/}: type=$(cat "$sc_d/type" 2>/dev/null) online=$(cat "$sc_d/online" 2>/dev/null) status=$(cat "$sc_d/status" 2>/dev/null) current_now=$(cat "$sc_d/current_now" 2>/dev/null)"
  done
  echo "== node arus yang akan ditulis VoltEx =="
  sc_n=0
  for sc_p in $(vx_cur_nodes); do sc_n=$((sc_n + 1)); echo "$sc_p = $(dv_cat "$sc_p") (mode $(stat -c %a "$sc_p" 2>/dev/null))"; done
  [ "$sc_n" -eq 0 ] && echo "(tidak ada) - kernel/ROM ini tidak mengekspos node arus standar; kirim output ini untuk ditambahkan"
  echo "== node vendor lain (hanya info) =="
  ls "$R"/proc/mtk_battery_cmd "$R"/sys/devices/platform/charger "$R"/sys/class/qcom-battery 2>/dev/null | head -n 40
  echo "status_nyata=$(chg_real_status) raw=$(chg_cur_status) charger=$(chg_type)"
}
