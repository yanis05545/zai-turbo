#!/system/bin/sh
# =====================================================================
#  Zyrox v2 - lib/killsec.sh : "Abaikan Keamanan Kernel" (AKS)
#
#  Toggle ON/OFF TERPISAH dari pemilihan mode (balance/saver/gaming/
#  extreme di lib/modelock.sh). BUKAN mode baru, BUKAN tombol kosmetik -
#  node sysfs kernel ditulis LANGSUNG lewat mesin tulis-dan-verifikasi
#  yang sama dipakai seluruh overclock.sh (oc_raw_write, baca-ulang untuk
#  konfirmasi kernel benar menerima), persis seperti catatan di
#  lib/overclock.sh tentang mode-locking vs "visual doang".
#
#  KAPAN AKTIF: hanya SELAMA ada game terdeteksi berjalan (GAME_PKG,
#  lib/daemon.sh). Toggle di WebUI boleh dinyalakan kapan saja, tapi efek
#  di sysfs baru benar2 ditulis begitu sebuah game mulai (start_game) dan
#  dijaga ulang tiap tick selama game berjalan (tick_ingame). TIDAK
#  PERMANEN: begitu game berhenti (stop_game) ATAU toggle dimatikan, semua
#  node yang disentuh dikembalikan ke nilai sebelum AKS aktif.
#
#  YANG DILAKUKAN ke SEMUA cluster CPU (cluster core 0-5 maupun 6-7, atau
#  berapa pun jumlah cluster di device ini - generik lewat oc_cpu_count,
#  bukan di-hardcode cuma dua cluster):
#   1. Lepas limiter software kernel/vendor yang menahan clock di bawah
#      titik tertinggi (oc_unlock_cpu - PPM userlimit/hard userlimit
#      MediaTek, msm_performance Qualcomm; jalur sama dipakai OC manual).
#   2. Kunci scaling_max_freq = scaling_min_freq = plafon OC tertinggi
#      cluster ini (oc_cpu_ceil dari cpuinfo_max_freq, ATAU override OC
#      manual tersimpan kalau lebih tinggi - logika sama persis dengan
#      "mltop" mode extreme di lib/modelock.sh) - freq dipaksa mentok
#      ATAS terus-menerus, tidak boleh turun walau beban rendah.
#
#  Backup/restore lewat oc_raw_write/oc_restore_path - backup KHUSUS milik
#  overclock.sh (OCSTACK/OCBACKUPDIR), BUKAN backup sesi game ($STACK) -
#  supaya TIDAK ikut kehapus oleh revert_stack/cleanup_all yang jalan tiap
#  kali game berhenti karena sebab lain (thermal trip dst), dan supaya
#  nilai sebelum AKS aktif yang tersimpan selalu dipakai utuh untuk
#  restore kapan pun dibutuhkan.
# =====================================================================

aks_setconf() { # aks_setconf KEY VAL - tulis ke $CONF utama (sama pola tk_setconf/by_setconf)
  if grep -q "^$1=" "$CONF" 2>/dev/null; then sed -i "s/^$1=[^ #]*/$1=$2/" "$CONF"
  else echo "$1=$2" >> "$CONF"; fi
}
aks_get() { echo "${AKS_ON:-0}"; }

# Nama paket game aktif. Dipanggil dari CLI (azenith-ai killsec on|off|
# status) berjalan di PROSES TERPISAH dari daemon - variabel $GAME_PKG
# daemon tidak ikut terbawa ke sana, jadi baca penanda $RUNDIR/game yang
# ditulis start_game/dihapus stop_game (lib/daemon.sh). Dalam daemon
# sendiri (aks_watch dipanggil dari tick_ingame), $GAME_PKG sudah pasti
# terisi lewat shell yang sama - dicoba dulu supaya tidak perlu baca file.
aks_game_now() {
  [ -n "$GAME_PKG" ] && { echo "$GAME_PKG"; return 0; }
  cat "$RUNDIR/game" 2>/dev/null
}

# plafon tertinggi yang berhak dipakai cluster ini (batas kernel ATAU OC
# manual kalau lebih tinggi) - AKS tidak pernah menolak OC manual user,
# cuma memaksa cluster dikunci SELALU di titik itu selama game + toggle
# aktif, bukan cuma lantai/plafon biasa yang masih boleh naik-turun.
aks_ceiling() { # aks_ceiling <idx 1-based> <cpuinfo_max_khz>
  ac_i=$1; ac_kmax=$2
  ac_ov=$(oc_conf_get "CPU$ac_i" 2>/dev/null)
  ac_top=$(oc_cpu_ceil "$ac_kmax")
  [ -n "$ac_ov" ] && [ "$ac_ov" -gt "$ac_top" ] 2>/dev/null && ac_top=$ac_ov
  echo "$ac_top"
}

# aks_apply - idempotent, aman dipanggil berkali-kali (watchdog tiap tick).
# Tidak melakukan apa pun kalau toggle mati.
aks_apply() {
  [ "$(aks_get)" = 1 ] || return 0
  ak_n=$(oc_cpu_count)
  [ "$ak_n" -ge 1 ] || return 1
  ak_i=1
  while [ "$ak_i" -le "$ak_n" ]; do
    ak_line=$(oc_cpu_line "$ak_i")
    IFS='|' read -r ak_name ak_p _ _ _ _ <<EOF
$ak_line
EOF
    if [ -n "$ak_p" ]; then
      ak_kmax=$(read1 "$ak_p/cpuinfo_max_freq")
      if [ -n "$ak_kmax" ]; then
        ak_top=$(aks_ceiling "$ak_i" "$ak_kmax")
        oc_unlock_cpu "$ak_i" "$ak_p"
        oc_raw_write "$ak_p/scaling_max_freq" "$ak_top" >/dev/null
        oc_raw_write "$ak_p/scaling_min_freq" "$ak_top" >/dev/null
      fi
    fi
    ak_i=$((ak_i + 1))
  done
  log_msg "AKS: abaikan keamanan kernel diterapkan ke $ak_n cluster (limiter software dilepas, min=max dikunci ke plafon tertinggi)"
  return 0
}

# aks_revert - kembalikan SEMUA cluster yang disentuh AKS ke nilai sebelum
# AKS aktif. Aman dipanggil walau AKS tidak pernah apply (oc_restore_path
# diam-diam no-op kalau tidak ada backup tersimpan untuk path itu).
aks_revert() {
  ak_n=$(oc_cpu_count)
  [ "$ak_n" -ge 1 ] || return 0
  ak_i=1
  while [ "$ak_i" -le "$ak_n" ]; do
    ak_line=$(oc_cpu_line "$ak_i")
    IFS='|' read -r _ ak_p _ _ _ _ <<EOF
$ak_line
EOF
    if [ -n "$ak_p" ]; then
      oc_restore_path "$ak_p/scaling_max_freq" >/dev/null 2>&1
      oc_restore_path "$ak_p/scaling_min_freq" >/dev/null 2>&1
    fi
    ak_i=$((ak_i + 1))
  done
  log_msg "AKS: dilepas - cluster dikembalikan ke nilai sebelum AKS aktif (atau mode aktif yang berlaku sekarang)"
}

# aks_watch - dipanggil berkala oleh daemon SELAMA game berjalan (lihat
# tick_ingame di lib/daemon.sh), sama pola dengan ml_watch/tk_watch: ROM
# vendor lain (perfd/GED/dst) bisa menulis ulang node yang sama beberapa
# detik kemudian, jadi kuncian AKS perlu dijaga ulang, bukan cuma ditulis
# sekali saat game baru mulai.
aks_watch() {
  [ -n "$GAME_PKG" ] || return 0
  # Cooling SoC sedang menurunkan plafon -> AKS (min=max=puncak) jangan melawan pendinginan.
  [ "${COOL_ENGAGED:-0}" = 1 ] && return 0
  aks_apply
}

aks_on() {
  load_conf
  aks_setconf AKS_ON 1
  AKS_ON=1
  ak_g=$(aks_game_now)
  if [ -n "$ak_g" ]; then
    scan_if_needed >/dev/null 2>&1
    aks_apply
    echo "Abaikan Keamanan Kernel: AKTIF (game $ak_g sedang jalan - CPU langsung dikunci ke plafon OC tertinggi, min=max)"
  else
    echo "Abaikan Keamanan Kernel: AKTIF (menunggu game dibuka - belum ada efek di sysfs karena belum ada game jalan)"
  fi
  aks_status
}

aks_off() {
  load_conf
  aks_setconf AKS_ON 0
  AKS_ON=0
  scan_if_needed >/dev/null 2>&1
  aks_revert
  echo "Abaikan Keamanan Kernel: MATI (cluster dikembalikan ke bawaan/mode aktif, tidak permanen)"
  aks_status
}

aks_status() {
  ast_g=$(aks_game_now)
  echo "AKS_ON=$(aks_get)  game_aktif=${ast_g:-tidak ada}"
}
