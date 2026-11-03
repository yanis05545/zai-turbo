#!/system/bin/sh
# =====================================================================
#  Zyrox - lib/license.sh
#  Sistem lisensi offline berbasis serial number perangkat.
#
#  CARA KERJA (ringkas):
#   - Key lisensi = hash berparameter rahasia (LIC_SECRET1/2) dari
#     SERIAL NUMBER perangkat. Tidak butuh internet, tidak butuh server.
#   - Verifikasi hanya butuh `sha256sum` (ada di Termux & di toybox/
#     busybox Android), jadi bisa dijalankan dari Termux ATAU dari
#     shell module ini sendiri saat boot.
#   - Key yang valid di HP A otomatis TIDAK valid kalau folder module
#     ini disalin ke HP B, karena serial number HP B beda -> hash
#     yang diharapkan ikut beda -> module mengunci diri (fitur mati).
#
#  PENTING - batas keamanan (baca sampai habis, jangan di-skip):
#   Ini skema SIMETRIS: untuk *memverifikasi* key, script ini juga
#   harus tahu cara *menghitung* key yang benar. Karena script ini ikut
#   didistribusikan ke pembeli (supaya bisa jalan offline di HP
#   mereka), org yang cukup paham shell script SECARA TEKNIS BISA
#   mengambil LIC_SECRET1/2 dari file ini dan membuat key sendiri untuk
#   serial berapapun. Tidak ada skema offline tanpa server yang kebal
#   dari ini (ini batasan matematis, bukan bug). Yang skema ini
#   benar-benar cegah secara efektif: orang awam yang cuma terima
#   folder module/zip dari teman lalu pasang di HP sendiri - itu akan
#   gagal total & otomatis tanpa mereka ngerti kenapa. Fungsi `keygen`
#   SENGAJA tidak diekspos lewat CLI di sini (lihat paling bawah) -
#   simpan terpisah di tools/azenith_keygen.sh milikmu sendiri dan
#   JANGAN ikut dimasukkan ke zip yang kamu jual.
#
#  WAJIB sebelum dijual: ganti LIC_SECRET1 & LIC_SECRET2 di bawah ini
#  dengan string acakmu sendiri (panjang, unik per rilis/produk).
# =====================================================================

LIC_DATA="${TX_DATA:-/data/adb/azenith-ai}"
LIC_KEYFILE="$LIC_DATA/license.key"
LIC_LOCKFILE="$LIC_DATA/license.lock"
LIC_LOGFILE="$LIC_DATA/license.log"

# --------------------------------------------------------------------
# GANTI DUA NILAI INI sebelum build zip yang akan dijual. Jangan pernah
# dipakai ulang antar produk/season berbeda. Simpan juga salinannya di
# tempat aman di luar project (dibutuhkan lagi tiap generate key baru).
LIC_SECRET1="AzNth-7q2K9pLsT4-S1-GANTI-INI"
LIC_SECRET2="AzNth-v8Rc1Mn6Wd-S2-GANTI-INI"
# --------------------------------------------------------------------

lic_log() {
  mkdir -p "$LIC_DATA" 2>/dev/null
  echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LIC_LOGFILE" 2>/dev/null
}

# sha256 hex dari sebuah string, lewat stdin (tanpa file sementara)
lic_hash() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    printf '%s' "$1" | openssl dgst -sha256 | awk '{print $NF}'
  else
    lic_log "ERROR: tidak ada sha256sum/shasum/openssl di perangkat ini"
    printf ''
  fi
}

# Serial number perangkat, dengan beberapa fallback prop. Dijalankan
# sebagai root (service.sh/post-fs-data.sh sudah root; dari Termux
# pakai `su -c`). Dinormalisasi: tanpa spasi, huruf besar semua, supaya
# hasil hash selalu konsisten antara sisi penjual & pembeli.
lic_serial() {
  s=$(getprop ro.serialno 2>/dev/null)
  if [ -z "$s" ] || [ "$s" = "unknown" ]; then s=$(getprop ro.boot.serialno 2>/dev/null); fi
  if [ -z "$s" ] || [ "$s" = "unknown" ]; then s=$(getprop ro.boot.serial 2>/dev/null); fi
  if [ -z "$s" ] || [ "$s" = "unknown" ]; then s=$(getprop gsm.serial 2>/dev/null); fi
  printf '%s' "$s" | tr -d '\r\n \t' | tr 'a-z' 'A-Z'
}

# Key yang diharapkan untuk sebuah serial (dipakai utk verifikasi DAN
# utk generate - makanya fungsi ini tidak diekspos sebagai subcommand
# publik di akhir file, cuma lewat "keygen" yang sengaja dicomment).
lic_expected_key() {
  SER="$1"
  [ -z "$SER" ] && { printf ''; return 1; }
  H1=$(lic_hash "${SER}#${LIC_SECRET1}")
  [ -z "$H1" ] && { printf ''; return 1; }
  H2=$(lic_hash "${H1}#${SER}#${LIC_SECRET2}")
  [ -z "$H2" ] && { printf ''; return 1; }
  RAW=$(printf '%s' "$H2" | cut -c1-20 | tr 'a-z' 'A-Z')
  printf 'AZN-%s-%s-%s-%s-%s' \
    "$(printf '%s' "$RAW" | cut -c1-4)"   "$(printf '%s' "$RAW" | cut -c5-8)" \
    "$(printf '%s' "$RAW" | cut -c9-12)"  "$(printf '%s' "$RAW" | cut -c13-16)" \
    "$(printf '%s' "$RAW" | cut -c17-20)"
}

# "Kode perangkat" yg dikirim pembeli ke penjual (serial mentah - boleh
# diganti jadi hash-terpotong kalau tidak mau serial asli terlihat).
lic_code() {
  SER=$(lic_serial)
  if [ -z "$SER" ]; then echo "ERROR: serial number tidak terbaca di perangkat ini (coba jalankan via su)"; return 1; fi
  echo "$SER"
}

# Cek status, tulis pesan ke stdout, return 0 = valid / 1 = terkunci.
lic_status() {
  if [ "$LIC_SECRET1" = "AzNth-7q2K9pLsT4-S1-GANTI-INI" ]; then
    lic_log "PERINGATAN: LIC_SECRET belum diganti dari default - TIDAK AMAN untuk dijual!"
  fi
  SER=$(lic_serial)
  if [ -z "$SER" ]; then echo "LOCKED: serial number tidak terbaca"; return 1; fi
  if [ ! -f "$LIC_KEYFILE" ]; then echo "LOCKED: belum ada key terpasang"; return 1; fi
  SAVED=$(tr -d '\r\n \t' < "$LIC_KEYFILE" 2>/dev/null | tr 'a-z' 'A-Z')
  EXP=$(lic_expected_key "$SER")
  if [ -n "$EXP" ] && [ "$SAVED" = "$EXP" ]; then
    echo "OK: lisensi valid untuk perangkat ini ($SER)"
    return 0
  fi
  echo "LOCKED: key tidak cocok dengan perangkat ini ($SER)"
  return 1
}

# Dipakai script lain (post-fs-data.sh/service.sh/action.sh) - diam,
# cuma exit code. 0 = boleh jalan, 1 = harus mengunci diri.
lic_check() { lic_status >/dev/null 2>&1; }

# Pasang key baru (dipanggil dari WebUI / Termux / adb shell).
lic_activate() {
  KEY=$(printf '%s' "$1" | tr -d '\r\n \t' | tr 'a-z' 'A-Z')
  if [ -z "$KEY" ]; then echo "ERROR: key kosong"; return 1; fi
  mkdir -p "$LIC_DATA"
  printf '%s' "$KEY" > "$LIC_KEYFILE"
  if lic_check; then
    rm -f "$LIC_LOCKFILE"
    lic_log "ACTIVATE OK serial=$(lic_serial)"
    echo "OK: key berhasil dipasang & valid untuk perangkat ini"
    return 0
  fi
  touch "$LIC_LOCKFILE"
  lic_log "ACTIVATE GAGAL serial=$(lic_serial) key_dicoba=$KEY"
  echo "GAGAL: key ini tidak cocok dengan perangkat ini"
  return 1
}

# ----------------------- CLI (dipanggil langsung) ---------------------
# sh lib/license.sh code              -> cetak serial utk dikirim ke penjual
# sh lib/license.sh status            -> cek status lisensi
# sh lib/license.sh activate <KEY>    -> pasang key
#
# "keygen" SENGAJA dimatikan di bawah ini pada copy yang kamu DISTRIBUSIKAN.
# Buka komentar baris keygen ini HANYA di copy pribadi (tools/azenith_keygen.sh),
# jangan pernah di file yang ikut masuk ke zip buat dijual.
case "$1" in
  code)     lic_code ;;
  status)   lic_status ;;
  activate) shift; lic_activate "$1" ;;
  # keygen) shift; lic_expected_key "$(printf '%s' "$1" | tr -d '\r\n \t' | tr 'a-z' 'A-Z')" ;;
esac
