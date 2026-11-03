#!/system/bin/sh
# =====================================================================
#  Zyrox v2 - lib/profile.sh
#  Jembatan nama mode "default/saver/gaming/azetturbo" (dipakai skrip/alias
#  lama cpu_gpu_profile.sh) ke mesin mode ASLI modul (system/bin/azenith-thermal
#  balance/saver/gaming/extreme).
#
#  Ini BUKAN implementasi baru yang menulis sysfs sendiri - sengaja.
#  azenith-thermal + lib/modelock.sh + lib/core.sh safe_write SUDAH:
#    - menulis NODE sysfs dan membaca-baliknya untuk verifikasi (bukan
#      cuma assume berhasil kalau echo tidak error),
#    - mengunci floor/ceiling dari tabel OPP asli device (bukan tebakan),
#    - dijaga ulang terus-menerus oleh daemon (lib/daemon.sh) + dipulihkan
#      lagi setelah reboot (azenith-thermal restore, service.sh).
#  Dulu cpu_gpu_profile.sh berdiri sendiri dan menulis sysfs mentah TANPA
#  satupun dari tiga hal di atas - makanya cuma "visual". Fungsi di bawah
#  ini sengaja TIDAK duplikasi logika itu, cuma memanggilnya, supaya hasil
#  "profile" selalu sama nyatanya dengan menekan mode di WebUI/CLI resmi.
# =====================================================================

# profile_apply <default|saver|azetturbo>
#   return: 0 = berhasil diterapkan, 1 = argumen tidak dikenal, >1 = azenith-thermal gagal
profile_apply() {
  pa_mode=$1
  case "$pa_mode" in
    default)                         pa_target=balance ;;
    saver)                           pa_target=saver ;;
    azetturbo|turbo|zetturbo|zetai|zai|zaiturbo)  pa_target=extreme ;;   # nama tampilan mode ini: "ZAI-Turbo"
    *)
      echo "Mode tidak dikenal: '$pa_mode' (pilihan: default|saver|azetturbo [ZAI-Turbo])"
      flog PROFILE ERR "mode tidak dikenal: '$pa_mode'"
      return 1
      ;;
  esac

  pa_engine="$MODDIR/system/bin/azenith-thermal"
  if command -v azenith-thermal >/dev/null 2>&1; then
    pa_engine=azenith-thermal
  elif [ ! -x "$pa_engine" ]; then
    echo "Error: engine azenith-thermal tidak ditemukan di $pa_engine"
    flog PROFILE ERR "engine azenith-thermal tidak ditemukan di $pa_engine"
    return 2
  fi

  echo "[profile] '$pa_mode' -> azenith-thermal '$pa_target' ..."
  sh "$pa_engine" "$pa_target"
  pa_rc=$?
  if [ "$pa_rc" -eq 0 ]; then
    log_msg "PROFILE: '$pa_mode' diterapkan lewat azenith-thermal '$pa_target' (rc=0)"
  else
    log_msg "PROFILE: '$pa_mode' GAGAL lewat azenith-thermal '$pa_target' (rc=$pa_rc)"
  fi
  return $pa_rc
}
