#!/system/bin/sh
# =====================================================================
#  Zyrox - lib/powersave.sh   (v1.0.9-fix23, BARU)
#  Battery Saver Android (Settings.Global low_power) REAL-TIME menempel
#  ke mode thermal (balance/saver/gaming/extreme), dipanggil dari
#  system/bin/azenith-thermal (ps_apply_mode <mode>) dan dijaga ulang
#  tiap tick oleh daemon (lib/daemon.sh -> ps_watch) supaya statusnya
#  tidak "lepas" kalau ada pihak lain yang mengubahnya di luar modul.
#
#  Mekanisme: `settings put global low_power 0|1` - kunci Settings.Global
#  resmi AOSP yang didengarkan langsung oleh PowerManagerService lewat
#  ContentObserver (dasar semua toggle "Battery Saver" root/Tasker/Quick
#  Settings tanpa perlu jadi app sistem, sama seperti pola settings put
#  global/system yang sudah dipakai lib/misc.sh & lib/netboost.sh).
#
#  Catatan jujur: beberapa ROM vendor (MIUI/ColorOS/OriginOS/dll) punya
#  power-manager tambahan di atas AOSP yang kadang menimpa balik nilai
#  ini sendiri (mis. auto-matikan battery saver saat layar nyala). Itu
#  sebabnya ps_watch() di bawah dipanggil BERKALA oleh daemon (bukan
#  cuma sekali saat tombol mode ditekan) - supaya efeknya tetap "nyata
#  secara real time" walau ada yang menimpa dari luar.
#
#  Aturan per mode (sesuai permintaan: saver = hemat daya ON otomatis;
#  gaming/extreme = hemat daya OFF otomatis karena keduanya butuh
#  floor/ceiling frekuensi penuh dari lib/modelock.sh, Battery Saver
#  Android sendiri bisa ikut membatasi CPU/background kalau dibiarkan
#  nyala; balance = OFF juga, kembali ke perilaku vendor standar):
#    saver   -> low_power = 1
#    balance -> low_power = 0
#    gaming  -> low_power = 0
#    extreme -> low_power = 0
# =====================================================================

PS_EXPECT_FILE="$DATADIR/powersave_expect"   # 0|1 yang SEHARUSNYA aktif sekarang

# ps_get -> isi Settings.Global low_power saat ini (0/1/kosong kalau gagal baca)
ps_get() {
  settings get global low_power 2>/dev/null | tr -d ' \t\r\n'
}

# ps_set <0|1> -> tulis + verifikasi baca balik
ps_set() {
  psv=$1
  case "$psv" in 0|1) ;; *) return 1 ;; esac
  settings put global low_power "$psv" 2>/dev/null
  echo "$psv" > "$PS_EXPECT_FILE"
  psc=$(ps_get)
  [ "$psc" = "$psv" ] && return 0
  flog POWERSAVE BUG "tulis low_power=$psv tapi terbaca balik '$psc' (ditimpa power-manager vendor?)"
  log_msg "POWERSAVE: tulis low_power=$psv tapi terbaca balik '$psc' (kemungkinan ditimpa power-manager vendor) - akan dicoba ulang oleh watchdog"
  return 1
}

# ps_target_for_mode <mode> -> echo 0|1 (kosong kalau mode tidak dikenal)
ps_target_for_mode() {
  case "$1" in
    saver) echo 1 ;;
    balance|gaming|extreme) echo 0 ;;
    *) ;;
  esac
}

# ps_apply_mode <mode> - dipanggil LANGSUNG dari system/bin/azenith-thermal
# tiap kali mode ditekan di WebUI/CLI, supaya efeknya terasa SEKARANG JUGA:
#   saver            -> Battery Saver Android diaktifkan real-time
#   balance/gaming/extreme -> Battery Saver dipastikan mati real-time
ps_apply_mode() {
  pam_t=$(ps_target_for_mode "$1")
  [ -n "$pam_t" ] || return 1
  pam_cur=$(ps_get)
  if [ -z "$pam_cur" ]; then
    # device tanpa binder `settings`/low_power siap (sangat jarang) - jangan
    # paksa, cukup catat target supaya tidak dianggap "aktif" secara keliru
    echo "$pam_t" > "$PS_EXPECT_FILE"
    return 1
  fi
  if [ "$pam_cur" != "$pam_t" ]; then
    ps_set "$pam_t"
    log_msg "POWERSAVE: mode=$1 -> low_power $pam_cur -> $pam_t"
  else
    echo "$pam_t" > "$PS_EXPECT_FILE"
  fi
}

# ps_watch - dipanggil berkala dari daemon_main (lib/daemon.sh), berjalan
# TERUS baik idle maupun sedang in-game, supaya status Battery Saver selalu
# konsisten dengan mode thermal yang sedang aktif - termasuk kalau diubah
# paksa dari luar modul (app lain, Quick Settings user, atau Android sendiri
# saat baterai kritis mengaktifkan battery saver sendirian di tengah mode
# gaming/extreme).
ps_watch() {
  pw_exp=$(cat "$PS_EXPECT_FILE" 2>/dev/null)
  [ -n "$pw_exp" ] || return 0
  pw_cur=$(ps_get)
  [ -z "$pw_cur" ] && return 0
  if [ "$pw_cur" != "$pw_exp" ]; then
    log_msg "POWERSAVE WATCHDOG: low_power melenceng ($pw_cur, seharusnya $pw_exp) -> dipulihkan"
    flog POWERSAVE BUG "watchdog: low_power melenceng ($pw_cur, seharusnya $pw_exp) -> dipulihkan paksa"
    ps_set "$pw_exp"
  fi
}
