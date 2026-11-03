#!/system/bin/sh
# Tombol Action di Manager: buka aplikasi Zyrox.
MODDIR=${0%/*}
. "$MODDIR/lib/license.sh"
if ! lic_check; then
  echo "Lisensi terkunci untuk perangkat ini: $(lic_status 2>&1)"
  echo "Buka aplikasi Zyrox untuk memasukkan key, atau hubungi penjual."
  exit 0
fi
PKG="com.azenithtech.azenithai"
if ! pm path "$PKG" >/dev/null 2>&1; then
  echo "Aplikasi Zyrox belum terpasang. Pasang APK Zyrox lalu buka lagi."
  exit 0
fi
am start -n "$PKG/$PKG.MainActivity" >/dev/null 2>&1 \
  && echo "Aplikasi Zyrox dibuka." \
  || echo "Gagal membuka aplikasi Zyrox."
