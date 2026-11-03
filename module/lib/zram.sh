#!/system/bin/sh
# =====================================================================
#  Zyrox - lib/zram.sh
#  zRAM manager (tab Battery, di bawah Pembersih Sistem). Mengatur
#  /sys/block/zram0/ (perangkat zRAM pertama):
#    comp_algorithm  algoritma kompresi (lzo, lz4, zstd, ...)
#    disksize        kapasitas zRAM (harus diisi SEBELUM swapon)
#    size/mm_stat    statistik pemakaian real-time (dibaca untuk status)
#    reset           kosongkan zRAM (hanya bisa kalau swap sudah dilepas)
#  Urutan apply (sama dengan alur yang umum dipakai):
#    swapoff -> reset -> comp_algorithm -> disksize -> mkswap -> swapon
#  Kalau salah satu langkah gagal, konfigurasi LAMA dipulihkan supaya
#  perangkat tidak tertinggal tanpa swap. Semua nilai dibaca balik dari
#  kernel (bukan sekadar "sudah ditulis").
# =====================================================================

ZR_CONF="$DATADIR/zram.conf"          # ZRAM_ALGO= ZRAM_MB= ZRAM_SWAPPINESS= ZRAM_BOOT=
ZR_SYS="$R/sys/block/zram0"
ZR_SWAPPINESS="$R/proc/sys/vm/swappiness"

zr_conf_get() { [ -f "$ZR_CONF" ] && sed -n "s/^$1=//p" "$ZR_CONF" | tail -n 1; }
zr_conf_set() { # zr_conf_set KEY VAL
  [ -f "$ZR_CONF" ] || : > "$ZR_CONF"
  grep -v "^$1=" "$ZR_CONF" > "$ZR_CONF.t" 2>/dev/null
  echo "$1=$2" >> "$ZR_CONF.t"
  mv -f "$ZR_CONF.t" "$ZR_CONF"
  # salinan di luar folder data modul (dipulihkan service.sh kalau data direset saat update)
  mkdir -p /data/adb/azenith-keep 2>/dev/null; cp -f "$ZR_CONF" /data/adb/azenith-keep/zram.conf 2>/dev/null
}

zr_dev() {
  for zd in "$R/dev/block/zram0" "$R/dev/zram0"; do [ -e "$zd" ] && { echo "$zd"; return; }; done
  echo "/dev/block/zram0"
}
zr_meminfo_kb() { sed -n "s/^$1: *\([0-9][0-9]*\) kB.*/\1/p" "$R/proc/meminfo" 2>/dev/null | head -n1; }
zr_exists() { [ -e "$ZR_SYS/disksize" ]; }
zr_active() { grep -q "zram0" "$R/proc/swaps" 2>/dev/null; }
zr_algos() { tr -d '[]' < "$ZR_SYS/comp_algorithm" 2>/dev/null; }
zr_algo_cur() { sed -n 's/.*\[\([^]]*\)\].*/\1/p' "$ZR_SYS/comp_algorithm" 2>/dev/null | head -n1; }
# disksize dalam byte bisa >2^31 (mis. 4096MB = 4294967296) - aritmetika shell 32-bit (toybox/mksh
# di beberapa ROM) membungkus nilainya jadi 0/negatif, sehingga zRAM dianggap "ditolak kernel"
# padahal sudah terpasang benar. Pembagian dilakukan di awk (double 64-bit) supaya aman.
zr_size_mb() { zs_b=$(read1 "$ZR_SYS/disksize"); case "$zs_b" in ''|*[!0-9]*) echo 0 ;; *) echo "$zs_b" | awk '{printf "%d", $1 / 1048576}' ;; esac; }
zr_max_mb() { # batas slider: 2x RAM, maks 16 GB
  zm_r=$(zr_meminfo_kb MemTotal); zm_r=${zm_r:-4000000}
  zm_m=$((zm_r * 2 / 1024)); [ "$zm_m" -gt 16384 ] && zm_m=16384
  echo "$zm_m"
}

zr_status() {
  load_conf
  if ! zr_exists; then
    echo "exists=0"
    echo "info=zram0 tidak ada (kernel tanpa zRAM atau modul belum dimuat - tombol Terapkan akan mencoba modprobe zram)"
  else
    echo "exists=1"
  fi
  zr_active && echo "active=1" || echo "active=0"
  echo "algo=$(zr_algo_cur)"
  echo "algos=$(zr_algos | tr '\n' ' ' | sed 's/ *$//')"
  echo "disksize_mb=$(zr_size_mb)"
  zr_mm=$(cat "$ZR_SYS/mm_stat" 2>/dev/null)
  echo "$zr_mm" | awk '{o=$1;c=$2;u=$3; printf "orig_mb=%.1f\ncompr_mb=%.1f\nused_mb=%.1f\nratio=%.2f\n", o/1048576, c/1048576, u/1048576, (c>0?o/c:0)}'
  echo "swappiness=$(read1 "$ZR_SWAPPINESS")"
  zr_rt=$(zr_meminfo_kb MemTotal); zr_st=$(zr_meminfo_kb SwapTotal); zr_sf=$(zr_meminfo_kb SwapFree)
  echo "ram_mb=$(( ${zr_rt:-0} / 1024 ))"
  echo "swap_total_mb=$(( ${zr_st:-0} / 1024 ))"
  echo "swap_used_mb=$(( (${zr_st:-0} - ${zr_sf:-0}) / 1024 ))"
  # --- sumber angka SAMA dengan DevCheck/Pengaturan: /proc/meminfo (SwapTotal/SwapFree) dalam KB,
  #     dan /proc/swaps khusus zram. Satuan & pembulatan dilakukan di WebUI (DevCheck pakai desimal:
  #     1 GB = 1.000.000.000 byte, bukan 1024^3), jadi di sini cukup kirim angka mentah.
  echo "swap_total_kb=${zr_st:-0}"
  echo "swap_used_kb=$(( ${zr_st:-0} - ${zr_sf:-0} ))"
  zr_sw=$(awk '$1 ~ /zram/ {t+=$3; u+=$4} END{printf "%.0f %.0f", t, u}' "$R/proc/swaps" 2>/dev/null)
  echo "zram_total_kb=${zr_sw% *}"
  echo "zram_used_kb=${zr_sw#* }"
  echo "disksize_b=$(read1 "$ZR_SYS/disksize")"
  echo "$zr_mm" | awk '{printf "orig_b=%.0f\ncompr_b=%.0f\nused_b=%.0f\n", $1, $2, $3}'
  echo "max_mb=$(zr_max_mb)"
  echo "saved_algo=$(zr_conf_get ZRAM_ALGO)"
  echo "saved_mb=$(zr_conf_get ZRAM_MB)"
  zs_boot=$(zr_conf_get ZRAM_BOOT); echo "boot=${zs_boot:-1}"   # default AKTIF: zRAM tahan reboot/flash update
}

# swapoff + reset; return 0 ok | 1 gagal (pesan di stdout)
zr_release() {
  zrr_dev=$(zr_dev)
  if zr_active; then
    zrr_used=$(( $(zr_meminfo_kb SwapTotal) - $(zr_meminfo_kb SwapFree) ))
    zrr_av=$(zr_meminfo_kb MemAvailable)
    # kernel lama tidak selalu punya MemAvailable - pakai MemFree sebagai fallback
    [ -z "$zrr_av" ] && zrr_av=$(zr_meminfo_kb MemFree)
    # swapoff memindahkan semua halaman swap kembali ke RAM: tolak kalau RAM bebas tidak cukup
    if [ -n "$zrr_av" ] && [ "$zrr_used" -gt $(( zrr_av - 307200 )) ] 2>/dev/null; then
      echo "ditolak: swap terpakai $((zrr_used / 1024))MB, RAM tersedia cuma $((zrr_av / 1024))MB - tutup beberapa aplikasi dulu supaya swapoff tidak bikin OOM"
      return 1
    fi
    swapoff "$zrr_dev" >/dev/null 2>&1 || swapoff /dev/zram0 >/dev/null 2>&1
    if zr_active; then echo "swapoff gagal (zram0 masih dipakai sistem)"; return 1; fi
  fi
  { echo 1 > "$ZR_SYS/reset"; } 2>/dev/null
  if [ "$(zr_size_mb)" != 0 ]; then echo "reset zram0 gagal (disksize masih $(zr_size_mb)MB, device sibuk)"; return 1; fi
  return 0
}

# set algo + ukuran + mkswap + swapon; return 0 ok
zr_build() { # zr_build <algo> <mb>
  zb_algo=$1; zb_mb=$2; zb_dev=$(zr_dev)
  if [ -n "$zb_algo" ]; then
    { echo "$zb_algo" > "$ZR_SYS/comp_algorithm"; } 2>/dev/null
    if [ "$(zr_algo_cur)" != "$zb_algo" ]; then echo "algoritma '$zb_algo' ditolak kernel (terbaca '$(zr_algo_cur)')"; return 1; fi
  fi
  { echo "${zb_mb}M" > "$ZR_SYS/disksize"; } 2>/dev/null
  if [ "$(zr_size_mb)" != "$zb_mb" ]; then
    # fallback: sebagian kernel tidak mengerti sufiks 'M' - tulis dalam byte (dihitung di awk)
    zb_bytes=$(echo "$zb_mb" | awk '{printf "%.0f", $1 * 1048576}')
    { echo "$zb_bytes" > "$ZR_SYS/disksize"; } 2>/dev/null
  fi
  if [ "$(zr_size_mb)" != "$zb_mb" ]; then echo "disksize ${zb_mb}MB ditolak kernel (terbaca $(zr_size_mb)MB)"; return 1; fi
  mkswap "$zb_dev" >/dev/null 2>&1 || { echo "mkswap $zb_dev gagal"; return 1; }
  swapon "$zb_dev" >/dev/null 2>&1 || swapon /dev/zram0 >/dev/null 2>&1
  zr_active || { echo "swapon $zb_dev gagal"; return 1; }
  return 0
}

zr_apply() { # zr_apply <algo> <mb> [swappiness]
  za_algo=$1; za_mb=$2; za_sw=$3
  case "$za_mb" in ''|*[!0-9]*) echo "ukuran harus angka (MB)"; return 1 ;; esac
  if [ "$za_mb" = 0 ]; then zr_off; return $?; fi
  za_max=$(zr_max_mb)
  [ "$za_mb" -lt 128 ] && { echo "ukuran minimal 128 MB"; return 1; }
  [ "$za_mb" -gt "$za_max" ] && { echo "ukuran maksimal $za_max MB (2x RAM, tertinggi 16 GB)"; return 1; }
  if ! zr_exists; then
    modprobe zram num_devices=1 >/dev/null 2>&1
    sleep 1
    zr_exists || { echo "GAGAL: /sys/block/zram0 tidak ada dan modprobe zram tidak berhasil - kernel ini tidak punya zRAM"; return 1; }
  fi
  if [ -n "$za_algo" ] && ! zr_algos | tr ' ' '\n' | grep -qx "$za_algo"; then
    echo "algoritma '$za_algo' tidak didukung kernel ini. Tersedia: $(zr_algos | tr '\n' ' ')"; return 1
  fi
  if [ -n "$za_sw" ]; then
    case "$za_sw" in ''|*[!0-9]*) echo "swappiness harus 0-200"; return 1 ;; esac
    [ "$za_sw" -gt 200 ] && { echo "swappiness harus 0-200"; return 1; }
  fi
  za_pa=$(zr_algo_cur); za_pm=$(zr_size_mb); za_pact=0; zr_active && za_pact=1
  za_msg=$(zr_release) || { echo "$za_msg"; flog ZRAM ERR "apply dibatalkan: $za_msg"; return 1; }
  za_msg=$(zr_build "$za_algo" "$za_mb")
  if [ $? -ne 0 ]; then
    echo "GAGAL: $za_msg"
    flog ZRAM ERR "apply gagal: $za_msg - memulihkan konfigurasi lama (${za_pa}, ${za_pm}MB)"
    # pulihkan konfigurasi sebelumnya supaya tidak tanpa swap
    zr_release >/dev/null 2>&1
    if [ "$za_pm" -gt 0 ] 2>/dev/null && [ "$za_pact" = 1 ]; then
      zr_build "$za_pa" "$za_pm" >/dev/null 2>&1 && echo "konfigurasi lama dipulihkan (${za_pa}, ${za_pm}MB)" || echo "PERINGATAN: gagal memulihkan konfigurasi lama, zRAM nonaktif"
    fi
    return 1
  fi
  if [ -n "$za_sw" ]; then
    { echo "$za_sw" > "$ZR_SWAPPINESS"; } 2>/dev/null
    [ "$(read1 "$ZR_SWAPPINESS")" = "$za_sw" ] || echo "peringatan: swappiness $za_sw ditolak kernel (terbaca $(read1 "$ZR_SWAPPINESS"))"
    zr_conf_set ZRAM_SWAPPINESS "$za_sw"
  fi
  [ -n "$za_algo" ] && zr_conf_set ZRAM_ALGO "$za_algo"
  zr_conf_set ZRAM_MB "$za_mb"
  [ -n "$(zr_conf_get ZRAM_BOOT)" ] || zr_conf_set ZRAM_BOOT 1
  echo "zRAM diterapkan: algoritma=$(zr_algo_cur) ukuran=$(zr_size_mb)MB swap-aktif=$(zr_active && echo ya || echo tidak) swappiness=$(read1 "$ZR_SWAPPINESS")"
  flog ZRAM OK "zRAM diterapkan: $(zr_algo_cur) $(zr_size_mb)MB swappiness=$(read1 "$ZR_SWAPPINESS")"
  return 0
}

zr_off() {
  zr_exists || { echo "zram0 tidak ada - tidak ada yang dimatikan"; return 0; }
  zo_msg=$(zr_release) || { echo "$zo_msg"; return 1; }
  zr_conf_set ZRAM_MB 0
  [ -n "$(zr_conf_get ZRAM_BOOT)" ] || zr_conf_set ZRAM_BOOT 1
  echo "zRAM dimatikan (swap dilepas, disksize=0). Tekan Terapkan untuk mengaktifkan lagi."
  flog ZRAM OK "zRAM dimatikan"
}

zr_boot_set() { # zr_boot_set on|off
  case "$1" in
    on)  zr_conf_set ZRAM_BOOT 1; echo "zRAM tahan reboot/flash update: AKTIF (memakai pengaturan terakhir yang berhasil diterapkan)" ;;
    off) zr_conf_set ZRAM_BOOT 0; echo "zRAM tahan reboot/flash update: MATI (zRAM mengikuti bawaan sistem setelah reboot)" ;;
    *)   echo "azenith-ai zram boot on|off"; return 1 ;;
  esac
}

# rekomendasi otomatis: pilih algoritma + ukuran dari RAM & jumlah core, lalu langsung terapkan
# - zstd kalau kernel mendukung & core >=6 (kompresi terbaik, cukup CPU buat nanggung overhead-nya)
# - lz4 kalau tersedia (keseimbangan kompresi/CPU paling umum dipakai)
# - fallback algoritma pertama yang didukung kernel (biasanya lzo, paling ringan di CPU)
# ukuran: persentase RAM makin besar untuk RAM kecil (butuh lebih banyak bantuan swap),
#         dibulatkan ke kelipatan 128MB, dibatasi zr_max_mb (2x RAM, maks 16GB)
zr_auto() {
  load_conf
  zr_exists || { modprobe zram num_devices=1 >/dev/null 2>&1; sleep 1; }
  zr_exists || { echo "GAGAL: /sys/block/zram0 tidak ada, kernel ini tidak punya zRAM"; return 1; }
  za_rt=$(zr_meminfo_kb MemTotal); za_rt=${za_rt:-4000000}
  za_ram_mb=$(( za_rt / 1024 ))
  za_cpu=$(grep -c '^processor' "$R/proc/cpuinfo" 2>/dev/null); za_cpu=${za_cpu:-4}
  # comp_algorithm satu baris dipisah spasi ("lzo lzo-rle lz4 zstd") - pecah per baris dulu,
  # kalau tidak grep -x tidak pernah cocok & head -n1 mengembalikan SELURUH daftar
  za_avail=$(zr_algos | tr ' ' '\n' | sed '/^$/d')
  if echo "$za_avail" | grep -qx zstd && [ "$za_cpu" -ge 6 ] 2>/dev/null; then
    za_algo=zstd
  elif echo "$za_avail" | grep -qx lz4; then
    za_algo=lz4
  else
    za_algo=$(echo "$za_avail" | head -n1)
  fi
  if [ "$za_ram_mb" -le 4096 ]; then za_pct=50
  elif [ "$za_ram_mb" -le 8192 ]; then za_pct=35
  else za_pct=25
  fi
  za_mb=$(( za_ram_mb * za_pct / 100 ))
  za_mb=$(( (za_mb / 128) * 128 ))
  [ "$za_mb" -lt 256 ] && za_mb=256
  za_max=$(zr_max_mb); [ "$za_mb" -gt "$za_max" ] && za_mb=$za_max
  echo "rekomendasi: algoritma=$za_algo ukuran=${za_mb}MB swappiness=100 (RAM ${za_ram_mb}MB, ${za_cpu} core)"
  flog ZRAM INFO "auto: RAM=${za_ram_mb}MB core=${za_cpu} -> algo=${za_algo} mb=${za_mb}"
  zr_apply "$za_algo" "$za_mb" 100
}

# ---- zRAM TAHAN REBOOT & FLASH UPDATE -------------------------------------------------------------
# Pengaturan terakhir (ZRAM_ALGO / ZRAM_MB / ZRAM_SWAPPINESS) disimpan di $DATADIR/zram.conf. Folder data
# TIDAK dihapus saat flash zip versi baru, jadi pengaturan yang sama dipakai lagi setelah update + reboot.
# Default AKTIF (ZRAM_BOOT kosong = 1); hanya ZRAM_BOOT=0 yang mematikan pemulihan.

# zr_keep_ok <algo> <mb>: 0 kalau kondisi zRAM sekarang SUDAH sama dengan yang tersimpan (tidak perlu disentuh)
zr_keep_ok() {
  zk_algo=$1; zk_mb=$2
  if [ "$zk_mb" = 0 ]; then
    zr_exists || return 0
    zr_active && return 1
    return 0
  fi
  zr_exists && zr_active || return 1
  [ "$(zr_size_mb)" = "$zk_mb" ] || return 1
  [ -z "$zk_algo" ] || [ "$(zr_algo_cur)" = "$zk_algo" ] || return 1
  return 0
}

# simpan kondisi zRAM yang sedang hidup kalau belum ada pengaturan tersimpan (dipakai saat pasang/update modul)
zr_snapshot() {
  zr_exists && zr_active || { echo "zRAM tidak aktif - tidak ada yang disimpan"; return 0; }
  zn_mb=$(zr_conf_get ZRAM_MB)
  case "$zn_mb" in ''|*[!0-9]*) ;; *) echo "pengaturan zRAM tersimpan dipertahankan (${zn_mb}MB)"; return 0 ;; esac
  zn_live=$(zr_size_mb); [ "$zn_live" -ge 128 ] 2>/dev/null || { echo "ukuran zRAM aktif tidak valid"; return 0; }
  zr_conf_set ZRAM_MB "$zn_live"
  [ -n "$(zr_algo_cur)" ] && zr_conf_set ZRAM_ALGO "$(zr_algo_cur)"
  zn_sw=$(read1 "$ZR_SWAPPINESS"); [ -n "$zn_sw" ] && zr_conf_set ZRAM_SWAPPINESS "$zn_sw"
  zr_conf_set ZRAM_BOOT 1
  echo "zRAM aktif disimpan: $(zr_algo_cur) ${zn_live}MB swappiness=${zn_sw}"
}

# dipanggil service.sh tiap boot. Cek 3x (langsung, +60 dtk, +120 dtk) karena sebagian ROM
# (init / memory-extension vendor) mengatur ulang zRAM beberapa saat SETELAH boot_completed.
zr_boot_apply() {
  [ "$(zr_conf_get ZRAM_BOOT)" = 0 ] && return 0
  zba_mb=$(zr_conf_get ZRAM_MB); zba_algo=$(zr_conf_get ZRAM_ALGO); zba_sw=$(zr_conf_get ZRAM_SWAPPINESS)
  case "$zba_mb" in ''|*[!0-9]*) return 0 ;; esac            # belum ada pengaturan tersimpan
  [ "$zba_mb" = 0 ] || [ "$zba_mb" -ge 128 ] || return 0
  for zba_d in 0 60 120; do
    [ "$zba_d" -gt 0 ] && sleep "$zba_d"
    if zr_keep_ok "$zba_algo" "$zba_mb"; then
      flog ZRAM INFO "boot: zRAM sudah sesuai (${zba_algo:-?} ${zba_mb}MB), tidak diubah"
    elif [ "$zba_mb" = 0 ]; then
      zr_off >/dev/null 2>&1
    else
      zr_apply "$zba_algo" "$zba_mb" "$zba_sw" >/dev/null 2>&1
    fi
    # swappiness sering ditimpa ROM/modul lain - pasang lagi walau zRAM tidak diapa-apakan
    if [ -n "$zba_sw" ] && [ "$(read1 "$ZR_SWAPPINESS")" != "$zba_sw" ]; then
      { echo "$zba_sw" > "$ZR_SWAPPINESS"; } 2>/dev/null
    fi
  done
  return 0
}
