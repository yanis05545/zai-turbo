#!/system/bin/sh
# =====================================================================
#  Zyrox v2 - lib/bypass.sh : "Bypass Thermal"
#
#  Beda dengan "Disable Thermal" (lib/thermalkill.sh, tab Kontrol):
#   - thermalkill = agresif, benar2 MEMATIKAN service HAL thermal (stop +
#     bind-mount stub kalau perlu respawn-nya diblok). Bisa gagal di
#     sebagian device (lihat BLOCK GAGAL di thermalkill status).
#   - bypass = TIDAK membunuh service apa pun. Dia hanya memaksa
#     THERMAL_MODE=hard lewat jalur lib/thermal.sh yang SUDAH ADA, supaya
#     semua pengaman (baca suhu asli, safety trip, auto-downgrade di
#     lib/daemon.sh) tetap berlaku apa adanya, bukan jalur baru yang belum
#     teruji.
#
#  Saat bypass AKTIF, mode hard itu otomatis mencakup:
#   - "thermal yang boros baterai": service/prop thermal userspace yang
#     terus-menerus polling (SCANDIR/thermal_services + thermal_props) ->
#     dihentikan (lib/thermal.sh thermal_apply langkah 1-2, berlaku di
#     SEMUA mode termasuk hard, bukan cuma hard).
#   - "thermal performance": node vendor pembatas clock/perf + trip
#     passive/active dinaikkan (lib/thermal.sh thermal_apply langkah 4-5,
#     KHUSUS mode hard).
#
#  v2.7.2: Disable Thermal jadi fitur INTI PERMANEN (selalu THERMAL_KILL=1,
#  tidak ada lagi di WebUI tab Kontrol). Karena itu Bypass Thermal (by_on)
#  SELALU DITOLAK selama Disable Thermal aktif - tidak lagi mematikan
#  thermalkill secara otomatis seperti versi lama. Kalau tk_on() sendiri
#  menemukan BYPASS_THERMAL=1 (mis. sisa conf lama), itu yang dilepas
#  otomatis, bukan sebaliknya - Disable Thermal yang selalu menang.
# =====================================================================

by_setconf() { # by_setconf KEY VAL
  if grep -q "^$1=" "$CONF" 2>/dev/null; then sed -i "s/^$1=[^ #]*/$1=$2/" "$CONF"
  else echo "$1=$2" >> "$CONF"; fi
}

by_on() {
  load_conf
  if [ "$THERMAL_KILL" = 1 ]; then
    echo "DITOLAK: Disable Thermal adalah fitur inti permanen (selalu otomatis aktif) dan tidak boleh dimatikan oleh Bypass Thermal. Bypass Thermal tidak tersedia lagi selama Disable Thermal aktif."
    return 1
  fi
  # simpan mode sebelum bypass SEKALI saja; kalau sudah ada simpanan (mis.
  # bypass dinyalakan dua kali tanpa dimatikan), jangan ditimpa dengan "hard"
  if [ -z "$BYPASS_PREV_MODE" ] || [ "$BYPASS_THERMAL" != 1 ]; then
    by_setconf BYPASS_PREV_MODE "$THERMAL_MODE"
  fi
  by_setconf BYPASS_THERMAL 1
  by_setconf FEAT_THERMAL 1
  by_setconf THERMAL_MODE hard
  load_conf
  thermal_apply
  by_r=$?
  if [ "$by_r" = 0 ]; then
    echo "Bypass Thermal: AKTIF (mode dipaksa hard, Disable Thermal dikunci sampai bypass dimatikan)"
  else
    echo "Bypass Thermal: AKTIF tapi apply pertama ditolak (lihat log - biasanya sensor baterai tidak terbaca). Akan dicoba lagi otomatis oleh daemon."
  fi
  by_status
}

by_off() {
  load_conf
  thermal_revert
  by_prev=${BYPASS_PREV_MODE:-auto}
  by_setconf THERMAL_MODE "$by_prev"
  by_setconf BYPASS_THERMAL 0
  by_setconf BYPASS_PREV_MODE ""
  load_conf
  [ "$THERMAL_MODE" != off ] && thermal_apply
  echo "Bypass Thermal: MATI (mode dikembalikan ke $by_prev, Disable Thermal boleh dinyalakan lagi)"
  by_status
}

by_status() {
  load_conf
  echo "BYPASS_THERMAL=$BYPASS_THERMAL  thermal_mode=$THERMAL_MODE  mode_sebelum_bypass=${BYPASS_PREV_MODE:--}  thermalkill=$THERMAL_KILL"
}
