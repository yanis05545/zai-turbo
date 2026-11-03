#!/system/bin/sh
# =====================================================================
#  Zyrox v2 - lib/overclock.sh
#
#  FITUR "OVERCLOCK" (slider manual CPU/GPU di atas batas kernel, badge
#  OVERCLOCK/NON-OVERCLOCK, "baca OC dari .ko") SUDAH DIHAPUS SELURUHNYA
#  dari produk ini - tidak ada lagi jalur di WebUI atau CLI (`azenith-ai
#  overclock ...`) yang bisa memanggilnya. oc_headroom() dikunci permanen
#  ke 0, jadi oc_cpu_ceil/oc_gpu_ceil di bawah tidak akan pernah lagi
#  menghitung plafon di atas titik tertinggi tabel OPP/kernel bawaan.
#
#  File ini TETAP ADA (tidak dihapus total) karena isinya bukan cuma OC:
#  oc_raw_write/oc_restore_path adalah MESIN TULIS-DAN-VERIFIKASI (tulis ke
#  node sysfs, baca balik, retry chmod 666, catat ke oc_rejected kalau
#  kernel menolak) yang dipakai lib/modelock.sh (ml_apply) untuk benar-benar
#  mengunci frekuensi CPU/GPU tiap mode (balance/saver/gaming/ZAI-Turbo) -
#  itu bagian yang membuat mode BENAR-BENAR menembus sistem (sysfs nyata),
#  bukan cuma tombol kosmetik di layar. Menghapus file ini akan mematikan
#  mode-locking juga, jadi yang dihapus adalah FITUR-nya (akses user untuk
#  memaksa clock di atas spesifikasi pabrik), bukan mesin tulisnya.
# =====================================================================

OCCONF="$DATADIR/overclock.conf"
# OCSTACK/OCBACKUPDIR: TERPISAH dari $STACK/$BACKUPDIR milik safe_write.
# Alasan (bug lama): oc_raw_write dulu numpang ke $STACK/$BACKUPDIR yang sama
# dipakai sesi game (lib/perf.sh). cleanup_all() -> revert_stack dipanggil
# TIAP game berhenti / thermal trip / daemon stop-disable-uninstall, dan
# menulis BALIK semua path di $STACK ke nilai bawaan - termasuk scaling_max_freq
# yang sudah di-overclock - lalu verify_cleanup() menghapus seluruh isi
# $BACKUPDIR. Hasilnya: OC kelihatan ke-apply sesaat di WebUI (karena status
# dibaca ulang tepat setelah menulis), tapi begitu game berhenti/daemon idle
# lagi, nilai sysfs ASLI (yang dibaca DevCheck/app lain) sudah balik ke
# bawaan - overclock jadi "visual doang". OC adalah override PERSISTEN milik
# user, bukan state sementara sesi game, jadi backup+stack-nya WAJIB berbeda
# jalur dan TIDAK PERNAH disentuh oleh revert_stack/verify_cleanup.
OCSTACK="$DATADIR/oc_applied_stack"
OCBACKUPDIR="$DATADIR/oc_backup"
mkdir -p "$OCBACKUPDIR" 2>/dev/null

oc_cpu_count() { [ -s "$SCANDIR/cpu_policies" ] && wc -l < "$SCANDIR/cpu_policies" || echo 0; }

oc_cpu_line() { # oc_cpu_line <idx 1-based> -> name|path|minkhz|maxkhz|bobot|tabel
  sed -n "${1}p" "$SCANDIR/cpu_policies" 2>/dev/null
}

# Rentang nomor core asli cluster ini, misal "CPU0-5" atau "CPU6-7" (bukan
# cuma "Cluster N" generik) - dibaca langsung dari related_cpus kernel supaya
# namanya selalu cocok dengan device sebenarnya, sama seperti yang ditampilkan
# app lain (mis. Scene) yang mengidentifikasi cluster lewat nomor core.
oc_core_range() { # oc_core_range "0 1 2 3 4 5"
  set -- $1
  [ "$#" -ge 1 ] || { echo ""; return; }
  oc_first=$1; oc_last=$1
  for oc_c in "$@"; do
    case "$oc_c" in *[!0-9]*) continue ;; esac
    [ "$oc_c" -lt "$oc_first" ] 2>/dev/null && oc_first=$oc_c
    [ "$oc_c" -gt "$oc_last" ] 2>/dev/null && oc_last=$oc_c
  done
  if [ "$#" -eq $((oc_last - oc_first + 1)) ]; then
    [ "$oc_first" = "$oc_last" ] && echo "CPU$oc_first" || echo "CPU$oc_first-$oc_last"
  else
    echo "CPU$(echo "$1" | tr -s ' ' ',')"
  fi
}

# Kelas cluster berdasar URUTAN clock (cpu_policies sudah diurutkan dari
# tercepat -> terlambat oleh scan_cpu di lib/scan.sh) - benar untuk 2, 3,
# maupun 4 cluster (little/mid/big/prime), bukan cuma menebak index 1 = atas,
# index terakhir = bawah secara kasar seperti UI lama.
oc_cluster_class() { # oc_cluster_class <idx 1-based> <total>
  oc_ci=$1; oc_cn=$2
  if   [ "$oc_cn" -le 1 ]; then echo "Tunggal"
  elif [ "$oc_cn" -eq 2 ]; then
    if [ "$oc_ci" = 1 ]; then echo "Performa"; else echo "Efisiensi"; fi
  else
    if   [ "$oc_ci" = 1 ]; then echo "Prime"
    elif [ "$oc_ci" = "$oc_cn" ]; then echo "Efisiensi"
    else echo "Performa"
    fi
  fi
}

oc_conf_get() { # oc_conf_get KEY
  [ -f "$OCCONF" ] && sed -n "s/^$1=//p" "$OCCONF" | tail -n 1
}
oc_conf_set() { # oc_conf_set KEY VAL
  : > "$OCCONF.tmp" 2>/dev/null || return 1
  [ -f "$OCCONF" ] && grep -v "^$1=" "$OCCONF" > "$OCCONF.tmp"
  [ -n "$2" ] && echo "$1=$2" >> "$OCCONF.tmp"
  mv -f "$OCCONF.tmp" "$OCCONF"
}

# ---------------------------------------------------------------------
# Kunci Frekuensi: saat aktif, plafon (MAX) maupun lantai (MIN) CPU/GPU
# TIDAK BISA DIUBAH SAMA SEKALI (naik ataupun turun) dari nilai yang sedang
# berlaku, sampai kunci ini dinonaktifkan lagi manual. Dicek di oc_cpu_set /
# oc_cpu_set_min / oc_gpu_set / oc_gpu_set_min, dan reset (oc_cpu_reset /
# oc_gpu_reset) ditolak total selama terkunci.
#
# FIX "kunci tidak berfungsi" (riwayat lama): oc_lock_blocked dulu
# membandingkan nilai baru dengan CPU<idx>/CPUMIN<idx>/GPU/GPUMIN yang
# TERSIMPAN di overclock.conf - tapi kalau user belum PERNAH menggeser
# slider manual sebelum menekan "Aktifkan kunci", conf itu masih kosong,
# jadi perbandingan selalu meloloskan. oc_lock_snapshot() dipanggil TEPAT
# saat kunci diaktifkan: menyalin nilai plafon & lantai yang SEDANG berlaku
# di sysfs jadi baseline overclock.conf kalau belum ada override tersimpan -
# dipakai buat pesan info "dikunci ke: ..." di bawah.
#
# FIX "lantai naik ga karuan saat kunci aktif": versi lama cuma MENOLAK
# PENURUNAN (boleh dinaikkan) - niatnya supaya masih bisa overclock lebih
# jauh selagi terkunci, tapi kenaikan lewat jalur ini ikut kena masalah
# urutan/ketidakkonsistenan slider (lihat fix20) dan membuat kunci terasa
# tidak bisa diandalkan: user menekan "kunci" mengira semua freq BEKU, tapi
# ternyata lantai masih bisa berubah. Sekarang Kunci Frekuensi = freeze
# total: oc_lock_blocked menolak SEMUA percobaan ubah (apa pun arahnya)
# selama kunci aktif, apa pun nilainya - satu-satunya cara mengubah plafon
# atau lantai CPU/GPU adalah nonaktifkan kunci dulu di tab Overclock.
# ---------------------------------------------------------------------
oc_lock_get() { oc_conf_get LOCK; }

oc_lock_snapshot() {
  scan_if_needed >/dev/null 2>&1
  oln_n=$(oc_cpu_count); oln_i=1
  while [ "$oln_i" -le "$oln_n" ]; do
    IFS='|' read -r oln_name oln_path _ _ _ _ <<EOF
$(oc_cpu_line "$oln_i")
EOF
    if [ -n "$oln_path" ]; then
      if [ -z "$(oc_conf_get "CPU$oln_i")" ]; then
        oln_cur=$(read1 "$oln_path/scaling_max_freq")
        [ -n "$oln_cur" ] && oc_conf_set "CPU$oln_i" "$oln_cur"
      fi
      if [ -z "$(oc_conf_get "CPUMIN$oln_i")" ]; then
        oln_curmn=$(read1 "$oln_path/scaling_min_freq")
        [ -n "$oln_curmn" ] && oc_conf_set "CPUMIN$oln_i" "$oln_curmn"
      fi
    fi
    oln_i=$((oln_i + 1))
  done
  if [ -z "$(oc_conf_get GPU)" ] || [ -z "$(oc_conf_get GPUMIN)" ]; then
    oln_st=$(oc_status 2>/dev/null)
    oln_geff=$(printf '%s\n' "$oln_st" | sed -n 's/^gpu_hz_eff=//p' | tail -n 1)
    oln_gmin=$(printf '%s\n' "$oln_st" | sed -n 's/^gpu_hz_min_cur=//p' | tail -n 1)
    [ -z "$(oc_conf_get GPU)" ]    && [ -n "$oln_geff" ] && oc_conf_set GPU "$oln_geff"
    [ -z "$(oc_conf_get GPUMIN)" ] && [ -n "$oln_gmin" ] && oc_conf_set GPUMIN "$oln_gmin"
  fi
}

oc_lock_set() { # oc_lock_set on|off
  case "$1" in
    on)
      oc_conf_set LOCK 1
      oc_lock_snapshot
      echo "Kunci frekuensi AKTIF - plafon & lantai CPU/GPU dibekukan di kondisi sekarang, tidak bisa diubah (naik ataupun turun) sampai dinonaktifkan lagi"
      ;;
    off) oc_conf_set LOCK ""; echo "Kunci frekuensi dinonaktifkan - plafon & lantai bisa diubah lagi" ;;
    *) echo "azenith-ai overclock lock on|off|status"; return 1 ;;
  esac
}
oc_lock_status() { [ "$(oc_lock_get)" = 1 ] && echo "lock_freq=1" || echo "lock_freq=0"; }
# oc_lock_blocked [nilai_tersimpan_sebelumnya] [nilai_baru] -> 0 (true) kalau DITOLAK.
# Argumen lama (baseline/nilai baru) dipertahankan di pemanggil cuma untuk pesan
# info, TIDAK dipakai lagi buat memutuskan blokir - saat kunci aktif, blokir
# total apa pun arah/nilainya (lihat catatan panjang di atas).
oc_lock_blocked() {
  [ "$(oc_lock_get)" = 1 ]
}

# ---------------------------------------------------------------------
# Database spesifikasi pabrik (perkiraan terbaik dari lembar spek publik;
# core terkencang = CPU prime/performance cluster, GPU = clock puncak yang
# dipublikasikan vendor). SoC tak terdaftar -> TIDAK_DIKETAHUI (bukan dipaksa
# "stock"), supaya tidak salah tuduh/salah puji.
#   format DB: "cpu_khz gpu_mhz"
# ---------------------------------------------------------------------
# SOC_RAW tidak ikut tersimpan di profile.conf -> kosong di proses baru, itu
# penyebab status "TIDAK DIKETAHUI". Bangun ulang dari getprop bila kosong.
oc_soc_fix() {
  if [ -z "$SOC_RAW" ]; then
    SOC_RAW=$(lower "$(getp ro.hardware) $(getp ro.board.platform) $(getp ro.soc.manufacturer) $(getp ro.soc.model) $(getp ro.product.board) $(getp ro.hardware.chipname) $(getp ro.mediatek.platform) $SOC_NAME")
  fi
  case " $SOC_RAW " in *" $SOC_NAME "*) ;; *) SOC_RAW="$SOC_RAW $(lower "$SOC_NAME")" ;; esac
}

oc_db_lookup() {
  OC_DB_CPU=""; OC_DB_GPU=""
  oc_soc_fix
  od_r=" $SOC_RAW "
  case "$od_r" in
    *mt6789*|*helio\ g99*) OC_DB_CPU=2200000; OC_DB_GPU=1100 ;;
    *mt6785*|*helio\ g95*) OC_DB_CPU=2050000; OC_DB_GPU=820 ;;
    *mt6769*|*helio\ g85*) OC_DB_CPU=2000000; OC_DB_GPU=950 ;;
    *mt6768*|*helio\ g80*|*helio\ g70*) OC_DB_CPU=2000000; OC_DB_GPU=950 ;;
    *mt6765*|*helio\ g35*|*helio\ g25*) OC_DB_CPU=2300000; OC_DB_GPU=680 ;;
    *mt6781*|*helio\ g96*|*helio\ g88*) OC_DB_CPU=2050000; OC_DB_GPU=1000 ;;
    *mt6833*|*dimensity\ 700*) OC_DB_CPU=2200000; OC_DB_GPU=950 ;;
    *mt6853*|*dimensity\ 720*|*dimensity\ 800u*) OC_DB_CPU=2000000; OC_DB_GPU=950 ;;
    *mt6877*|*dimensity\ 900*) OC_DB_CPU=2400000; OC_DB_GPU=950 ;;
    *mt6885*|*dimensity\ 1000*) OC_DB_CPU=2600000; OC_DB_GPU=1000 ;;
    *mt6893*|*dimensity\ 1200*|*dimensity\ 1100*) OC_DB_CPU=3000000; OC_DB_GPU=950 ;;
    *mt6895*|*dimensity\ 8100*) OC_DB_CPU=2850000; OC_DB_GPU=950 ;;
    *mt6983*|*dimensity\ 9000*) OC_DB_CPU=3050000; OC_DB_GPU=1000 ;;
    *mt6985*|*dimensity\ 9200*) OC_DB_CPU=3050000; OC_DB_GPU=1040 ;;
    *dimensity\ 9300*) OC_DB_CPU=3250000; OC_DB_GPU=1300 ;;
    *sm8750*|*" 8 elite"*|*"snapdragon 8 elite"*) OC_DB_CPU=4320000; OC_DB_GPU=1200 ;;
    *sm8650*|*"8 gen 3"*) OC_DB_CPU=3300000; OC_DB_GPU=903 ;;
    *sm8550*|*"8 gen 2"*) OC_DB_CPU=3200000; OC_DB_GPU=680 ;;
    *sm8450*|*"8 gen 1"*) OC_DB_CPU=3000000; OC_DB_GPU=818 ;;
    *sm8350*|*snapdragon\ 888*) OC_DB_CPU=2840000; OC_DB_GPU=840 ;;
    *sm8250*|*snapdragon\ 865*) OC_DB_CPU=2840000; OC_DB_GPU=587 ;;
    *sm7675*|*"7+ gen 3"*) OC_DB_CPU=2910000; OC_DB_GPU=887 ;;
    *sm7550*|*"7 gen 3"*) OC_DB_CPU=2630000; OC_DB_GPU=801 ;;
    *sm7475*|*"7+ gen 2"*) OC_DB_CPU=2910000; OC_DB_GPU=887 ;;
    *sm7435*|*snapdragon\ 778g*) OC_DB_CPU=2400000; OC_DB_GPU=695 ;;
    *sm7325*|*snapdragon\ 732g*) OC_DB_CPU=2300000; OC_DB_GPU=840 ;;
    *sm6375*|*snapdragon\ 695*) OC_DB_CPU=2200000; OC_DB_GPU=840 ;;
    *sm6225*|*snapdragon\ 680*) OC_DB_CPU=2400000; OC_DB_GPU=950 ;;
    *sm4375*|*snapdragon\ 695*) OC_DB_CPU=2200000; OC_DB_GPU=840 ;;
    *s5e9945*|*exynos\ 2400*) OC_DB_CPU=3210000; OC_DB_GPU=1200 ;;
    *s5e9925*|*exynos\ 2200*) OC_DB_CPU=2800000; OC_DB_GPU=1300 ;;
    *s5e8535*|*exynos\ 1380*) OC_DB_CPU=2400000; OC_DB_GPU=950 ;;
    *s5e8825*|*exynos\ 1280*) OC_DB_CPU=2400000; OC_DB_GPU=950 ;;
    *s5e8535*|*exynos\ 850*) OC_DB_CPU=2000000; OC_DB_GPU=950 ;;
    *gs201*|*tensor\ g2*) OC_DB_CPU=2850000; OC_DB_GPU=890 ;;
    *zuma*|*tensor\ g3*) OC_DB_CPU=2910000; OC_DB_GPU=890 ;;
    *ums9230*|*unisoc\ t606*) OC_DB_CPU=1600000; OC_DB_GPU=750 ;;
    *ums9230*|*unisoc\ t612*) OC_DB_CPU=1800000; OC_DB_GPU=750 ;;
    *ums9620*|*unisoc\ t760*) OC_DB_CPU=2000000; OC_DB_GPU=850 ;;
  esac
}

# ---------------------------------------------------------------------
# Bacaan tambahan khusus vendor (dipakai hanya untuk INFORMASI/diagnosa di
# status, bukan jalur tulis utama -> jalur tulis tetap lewat $SCANDIR/gpu
# generik yang sudah diuji perf.sh, supaya tidak ada dua cara berbeda yang
# bisa saling tabrakan).
# ---------------------------------------------------------------------
oc_gpu_extra_read() {
  OC_GX_CUR=""; OC_GX_MAX=""; OC_GX_SRC=""
  if [ -e "$R/sys/class/kgsl/kgsl-3d0/gpuclk" ]; then
    OC_GX_CUR=$(read1 "$R/sys/class/kgsl/kgsl-3d0/gpuclk")
    og_mmhz=$(read1 "$R/sys/class/kgsl/kgsl-3d0/max_clock_mhz")
    [ -n "$og_mmhz" ] && OC_GX_MAX=$((og_mmhz * 1000000))
    OC_GX_SRC="kgsl"
  elif [ -r "$R/proc/gpufreq/gpufreq_var_dump" ]; then
    OC_GX_SRC="mtk_gpufreqv1"
    OC_GX_MAX=$(grep -i 'freq' "$R/proc/gpufreq/gpufreq_var_dump" 2>/dev/null | grep -i max | grep -oE '[0-9]{5,}' | sort -n | tail -n1)
  elif [ -r "$R/sys/module/mali_kbase/parameters/mali_gpu_clock" ]; then
    OC_GX_CUR=$(read1 "$R/sys/module/mali_kbase/parameters/mali_gpu_clock")
    OC_GX_SRC="mali_kbase_param"
  fi
}

# ---------------------------------------------------------------------
# Fitur Overclock (headroom di atas batas kernel) SUDAH DIHAPUS. Fungsi ini
# sengaja dipertahankan sebagai titik tunggal (bukan dihapus & diganti satu-
# satu di tiap pemanggil) supaya oc_cpu_ceil/oc_gpu_ceil di bawah selalu
# berhenti PERSIS di batas tabel OPP/kernel bawaan - tidak pernah lagi
# menambah persentase ekstra. Nilai HARUS tetap 0.
# ---------------------------------------------------------------------
oc_headroom() { echo 0; }
oc_cpu_ceil() { # oc_cpu_ceil <kernel_max_khz> -> kHz, kelipatan 50 MHz
  oc_k=$1; oc_p=$(oc_headroom)
  echo $(( (oc_k / 100 * (100 + oc_p)) / 50000 * 50000 ))
}
oc_gpu_ceil() { # oc_gpu_ceil <table_top_hz> -> Hz, kelipatan 5 MHz
  oc_k=$1; oc_p=$(oc_headroom)
  echo $(( (oc_k / 100 * (100 + oc_p)) / 5000000 * 5000000 ))
}


# FIX v1.0.8: node/tabel GPU TIDAK selalu dalam Hz. devfreq (kgsl/mali) = Hz,
# MediaTek GED (gpu_cust_upbound_freq + tabel gpufreq_opp_dump) = kHz, Exynos
# kgpu = MHz. Dulu semua dianggap Hz -> plafon dihitung ~0 (bulat ke 5 MHz dari
# angka kHz) dan nilai yang ditulis ke node salah satuan, jadi OC GPU tidak
# pernah berubah. oc_gpu_mul = pengali satuan-node -> Hz (1 / 1000 / 1000000),
# ditebak dari besaran tabel/nilai sekarang, fallback per-backend.
oc_gpu_mul() { # oc_gpu_mul <backend> <top_native> <cur_native>
  gm_ref=$2
  case "$gm_ref" in ''|0|*[!0-9]*) gm_ref=$3 ;; esac
  case "$gm_ref" in
    ''|0|*[!0-9]*)
      case "$1" in mtk_ged) echo 1000 ;; exynos_kgpu) echo 1000000 ;; *) echo 1 ;; esac
      return ;;
  esac
  if   [ "$gm_ref" -ge 100000000 ]; then echo 1
  elif [ "$gm_ref" -ge 100000 ];    then echo 1000
  else echo 1000000
  fi
}
# pilih titik tabel (satuan node) tertinggi yang <= target; kosong bila target di atas puncak
oc_snap_tbl() { # oc_snap_tbl <target_native> <tabel...>
  sn_t=$1; shift; sn_b=""
  for sn_f in "$@"; do
    [ "$sn_f" -le "$sn_t" ] 2>/dev/null && sn_b=$sn_f
  done
  echo "$sn_b"
}

# path backup KHUSUS OC (lihat catatan OCSTACK/OCBACKUPDIR di atas)
oc_bfile() { echo "$OCBACKUPDIR/$(echo "$1" | tr '/' '%')"; }

# tulis ke node sysfs: catat nilai awal (supaya "Bawaan" bisa restore) ke
# backup OC SENDIRI, lalu tulis DAN BACA ULANG untuk verifikasi (fix30 -
# dulu "TANPA verifikasi ketat", tanggung jawab dilempar ke pemanggil yang
# ternyata TIDAK ADA satupun yang benar-benar mengecek - itu akar masalah
# "governor/freq tidak pernah naik-turun walau mode sudah ditekan": node
# ditolak diam-diam oleh kernel/vendor driver dan modul tidak pernah tahu.
# Sekarang: kalau nilai yang terbaca-balik beda dari yang diminta, dicoba
# SEKALI LAGI (chmod 666 sebagai fallback - sebagian kernel mengekspor node
# writable-by-group/other tapi file mode di sysfs memang 644 default), lalu
# kalau masih beda juga dicatat ke log DAN ke $RUNDIR/oc_rejected supaya
# kelihatan jelas di `azenith-ai log` / `azenith-ai status` - bukan cuma
# "sudah coba tulis" yang terlihat sukses padahal percuma.
# return: 0 = terverifikasi sama persis | 1 = node tidak ada | 2 = ditolak kernel (readback beda)
oc_raw_write() { # oc_raw_write <path> <val>
  orw_p=$1; orw_v=$2
  [ -e "$orw_p" ] || return 1
  if ! grep -qxF "$orw_p" "$OCSTACK" 2>/dev/null; then
    ow_b=$(oc_bfile "$orw_p")
    ow_cur=$(read1 "$orw_p")
    if [ -n "$ow_cur" ]; then
      { echo "$ow_cur" > "$ow_b.tmp"; } 2>/dev/null && mv -f "$ow_b.tmp" "$ow_b" 2>/dev/null
      echo "$orw_p" >> "$OCSTACK"
    fi
  fi
  { chmod 644 "$orw_p"; } 2>/dev/null
  { echo "$orw_v" > "$orw_p"; } 2>/dev/null
  orw_got=$(read1 "$orw_p")
  if [ "$(echo $orw_got)" = "$(echo $orw_v)" ]; then
    echo "ok $orw_p -> $orw_v" >> "$RUNDIR/oc_writes" 2>/dev/null
    return 0
  fi
  # fallback: sebagian node sysfs vendor butuh mode lebih longgar dari 644
  # (atau tertimpa balik oleh daemon lain persis di antara tulis & baca -
  # dicoba sekali lagi langsung setelah chmod 666, race-nya kecil)
  { chmod 666 "$orw_p"; } 2>/dev/null
  { echo "$orw_v" > "$orw_p"; } 2>/dev/null
  orw_got2=$(read1 "$orw_p")
  if [ "$(echo $orw_got2)" = "$(echo $orw_v)" ]; then
    echo "ok(retry) $orw_p -> $orw_v" >> "$RUNDIR/oc_writes" 2>/dev/null
    return 0
  fi
  log_msg "OVERCLOCK: DITOLAK kernel - $orw_p minta='$orw_v' hasil_baca='$orw_got2' (kemungkinan dikunci vendor/kernel, bukan bug skrip)"
  echo "rej $orw_p want=$orw_v got=$orw_got2" >> "$RUNDIR/oc_rejected" 2>/dev/null
  flog OVERCLOCK BUG "ditolak kernel: $orw_p minta='$orw_v' terbaca='$orw_got2' (kemungkinan dikunci vendor/kernel)"
  return 2
}

# ---------------------------------------------------------------------
# METODE RaiRin-AI (diambil & diadaptasi): write-verify-RETRY berkali-kali
# dengan jeda singkat, bukan cuma satu kali ulang seperti oc_raw_write biasa.
# RaiRin mengunci scaling_max_freq/scaling_min_freq dengan loop sampai 5x
# percobaan @0.2 detik (menulis NILAI YANG SAMA berulang) sebelum menyerah -
# ini menang melawan race dengan daemon vendor lain yang diam-diam menimpa
# balik node sepersekian detik setelah kita menulis (kasus yang oc_raw_write
# versi sekali-coba bisa kalah). Dipakai HANYA untuk target yang paling
# "adversarial" (mis. raw-khz ZAI-Turbo yang sengaja di atas tabel OPP
# kernel) - bukan pengganti oc_raw_write di jalur normal, supaya backup/
# verifikasi/oc_rejected milik oc_raw_write tetap jadi satu-satunya mesin
# tulis (tidak ada dua cara berbeda yang bisa saling tabrakan).
# return: 0 = akhirnya terverifikasi sama | 2 = tetap ditolak sampai percobaan habis
oc_raw_write_retry() { # oc_raw_write_retry <path> <val> [tries=3]
  orwr_p=$1; orwr_v=$2; orwr_n=${3:-3}; orwr_t=0
  while [ "$orwr_t" -lt "$orwr_n" ]; do
    oc_raw_write "$orwr_p" "$orwr_v" && return 0
    orwr_t=$((orwr_t + 1))
    sleep 0.2 2>/dev/null
  done
  return 2
}

# ---------------------------------------------------------------------
# METODE RaiRin-AI: node debug DVFS MediaTek /proc/cpudvfs/cpufreq_debug -
# jalur TERPISAH & LEBIH RENDAH dari cpufreq sysfs biasa (scaling_max_freq/
# scaling_min_freq) untuk memaksa plafon/lantai tabel DVFS per cluster. Pada
# sebagian build Helio G99/MT6789, scaling_max_freq sendiri masih bisa
# dijepit internal oleh tabel DVFS ini walau write ke sysfs "sukses" - node
# debug inilah yang RaiRin pakai untuk benar-benar menembusnya. Format tulis:
# "<cpu_id_representatif_cluster> <min_khz> <max_khz>". Dilewati diam-diam
# (return 1) kalau node tidak ada di device ini (non-MTK atau kernel tanpa
# debug node ini) - aman dipanggil tanpa syarat.
OC_CPUDVFS_DEBUG="$R/proc/cpudvfs/cpufreq_debug"
oc_cpudvfs_debug_on() { [ -e "$OC_CPUDVFS_DEBUG" ]; }
oc_cpudvfs_debug_write() { # oc_cpudvfs_debug_write <cpu_id> <min_khz> <max_khz>
  oc_cpudvfs_debug_on || return 1
  oc_raw_write "$OC_CPUDVFS_DEBUG" "$1 $2 $3" >/dev/null 2>&1
}

# ---------------------------------------------------------------------
# METODE RaiRin-AI: lepas DVFSRC (DRAM/Vcore DVFS request) MediaTek - jalur
# throttle TERPISAH dari CPU/GPU clock itu sendiri. Di SoC MTK, permintaan
# frekuensi DDR/Vcore (dvfsrc) bisa jadi bottleneck tersembunyi di bawah
# beban berat walau plafon CPU/GPU sudah dilepas semua - dvfsrc_req_ddr_opp
# = -1 artinya "tanpa paksaan OPP tertentu" (biarkan naik ke yang dibutuhkan
# tanpa plafon buatan), dan governor devfreq kelas dvfsrc (kalau ada) ikut
# diarahkan ke simple_ondemand + rentang penuh tabelnya. Azenith sebelumnya
# tidak pernah menyentuh subsistem ini sama sekali (lib/scan.sh bahkan
# sengaja MENGECUALIKAN node *dvfsrc* dari scan GPU generik supaya tidak
# dikira node GPU) - best-effort, aman dipanggil di device non-MTK (semua
# node tidak ada -> tidak melakukan apa-apa).
oc_unlock_dvfsrc() {
  oud_dh=$(find "$R/sys/devices/platform" -name "dvfsrc_req_ddr_opp" 2>/dev/null | head -n 1 | xargs -r dirname)
  if [ -n "$oud_dh" ]; then
    oc_vwrite "$oud_dh/dvfsrc_req_ddr_opp" "-1"
    [ -e "$oud_dh/dvfsrc_force_vcore_dvfs_opp" ] && oc_vwrite "$oud_dh/dvfsrc_force_vcore_dvfs_opp" "-1"
  fi
  [ -e "$R/sys/kernel/helio-dvfsrc/dvfsrc_force_vcore_dvfs_opp" ] && oc_vwrite "$R/sys/kernel/helio-dvfsrc/dvfsrc_force_vcore_dvfs_opp" "-1"
  for oud_d in "$R"/sys/class/devfreq/*dvfsrc*; do
    [ -d "$oud_d" ] || continue
    if grep -q simple_ondemand "$oud_d/available_governors" 2>/dev/null; then
      oc_vwrite "$oud_d/governor" "simple_ondemand"
    fi
    oud_mf=$(tr ' ' '\n' < "$oud_d/available_frequencies" 2>/dev/null | sort -rn | head -n 1)
    oud_nf=$(tr ' ' '\n' < "$oud_d/available_frequencies" 2>/dev/null | sort -n | head -n 1)
    if [ -n "$oud_mf" ]; then
      oc_vwrite "$oud_d/min_freq" "$oud_nf"
      oc_vwrite "$oud_d/max_freq" "$oud_mf"
    fi
    break
  done
}

# ---------------------------------------------------------------------
# METODE RaiRin-AI: lepas flag pembatas daya/termal vendor MediaTek yang bisa
# diam-diam menjepit clock GPU/CPU DI BAWAH plafon yang baru saja ditulis -
# subsistem BERBEDA dari yang sudah ditangani oc_unlock_cpu/oc_unlock_gpu
# (PPM userlimit & GED upbound). gpufreq_power_limited punya beberapa flag
# independen (baterai over-current, persentase baterai rendah, battery-low,
# proteksi termal, PBM) - tiap flag ditulis terpisah "<nama> 0" (nonaktif).
# battery_oc_protect_stop & thermal_message/cpu_limits adalah node sejenis
# di subsistem lain. Semua best-effort/aman di device tanpa node ini.
oc_unlock_thermal_mtk() {
  if [ -e "$R/proc/gpufreq/gpufreq_power_limited" ]; then
    for out_s in ignore_batt_oc ignore_batt_percent ignore_low_batt ignore_thermal_protect ignore_pbm_limited; do
      oc_vwrite "$R/proc/gpufreq/gpufreq_power_limited" "$out_s 0"
    done
  fi
  [ -e "$R/proc/mtk_batoc_throttling/battery_oc_protect_stop" ] && oc_vwrite "$R/proc/mtk_batoc_throttling/battery_oc_protect_stop" "stop 0"
  [ -e "$R/sys/devices/virtual/thermal/thermal_message/cpu_limits" ] && oc_vwrite "$R/sys/devices/virtual/thermal/thermal_message/cpu_limits" "0"
}

# kembalikan satu node OC ke nilai bawaan tersimpan (backup khusus OC), dan
# lepaskan node itu dari OCSTACK supaya oc_raw_write berikutnya mem-backup
# ulang dari nilai yang sedang berlaku saat itu.
oc_restore_path() { # oc_restore_path <path>
  ob=$(oc_bfile "$1")
  [ -f "$ob" ] || return 1
  ov=$(cat "$ob" 2>/dev/null)
  [ -n "$ov" ] || return 1
  { echo "$ov" > "$1"; } 2>/dev/null
  grep -vxF "$1" "$OCSTACK" > "$OCSTACK.tmp" 2>/dev/null; mv -f "$OCSTACK.tmp" "$OCSTACK" 2>/dev/null
  rm -f "$ob"
  return 0
}
# tulis ke node vendor (format bebas, tanpa backup) - best effort
oc_vwrite() { # oc_vwrite <path> <isi>
  [ -w "$1" ] || { [ -e "$1" ] && chmod 644 "$1" 2>/dev/null; }
  [ -e "$1" ] || return 1
  { echo "$2" > "$1"; } 2>/dev/null && log_msg "OVERCLOCK unlock: $1 <- $2"
}

# ---------------------------------------------------------------------
# Lepas batas software CPU untuk satu cluster
# ---------------------------------------------------------------------
oc_unlock_cpu() { # oc_unlock_cpu <idx 1-based> <policy path>
  ou_n=$(oc_cpu_count); ou_ppm=$(( ou_n - $1 ))
  # MediaTek PPM: -1 = tanpa batas userlimit (idx PPM menaik: 0 = cluster kecil)
  oc_vwrite "$R/proc/ppm/policy/userlimit_max_cpu_freq" "$ou_ppm -1"
  oc_vwrite "$R/proc/ppm/policy/hard_userlimit_max_cpu_freq" "$ou_ppm -1"
  # Qualcomm msm_performance: lepas plafon per-CPU
  if [ -e "$R/sys/module/msm_performance/parameters/cpu_max_freq" ]; then
    for ou_c in $(cat "$2/related_cpus" 2>/dev/null); do
      oc_vwrite "$R/sys/module/msm_performance/parameters/cpu_max_freq" "$ou_c:4294967295"
    done
  fi
  # METODE RaiRin-AI: reset flag scaling_boost_freq/scaling_boost_frequencies
  # ke 0 - sebagian kernel menggerbang akses boost-freq di belakang flag ini,
  # jadi dilepas supaya tidak ikut membatasi ceiling yang baru ditulis.
  [ -f "$2/scaling_boost_freq" ] && oc_vwrite "$2/scaling_boost_freq" "0"
  [ -f "$2/scaling_boost_frequencies" ] && oc_vwrite "$2/scaling_boost_frequencies" "0"
}

# ---------------------------------------------------------------------
# Lepas batas software GPU
# ---------------------------------------------------------------------
oc_unlock_gpu() {
  # MediaTek GED: 0 = upbound di OPP tertinggi
  oc_vwrite "$R/sys/kernel/ged/hal/custom_upbound_gpu_freq" "0"
  # Qualcomm kgsl: power level 0 = tertinggi
  oc_vwrite "$R/sys/class/kgsl/kgsl-3d0/max_pwrlevel" "0"
}

# ---------------------------------------------------------------------
# v1.0.9 - MediaTek: kontrol GPU ASLI (GED + tabel gpufreq), bukan node devfreq kbase.
#
# Akar masalah "OC GPU tidak berubah, naik ataupun turun": di MediaTek (mis. Helio G99 /
# MT6789) ada node /sys/class/devfreq/*.mali, jadi scan memilih backend "devfreq" dan semua
# tulisan masuk ke max_freq node itu. Tapi clock GPU MTK sebenarnya diatur GED + driver
# gpufreq (mtk_gpufreq_*.ko), bukan devfreq kbase - node itu hanya "bayangan", ditulis/dibaca
# ulang terlihat berubah di sysfs tapi clock asli tidak pernah ikut. Tabel OPP-nya pun beda:
# devfreq memakai tabel DT, gpufreq memakai tabel di dalam .ko (yang ditambal untuk OC).
# Sekarang kalau node GED ada: tabel diambil dari gpufreq (/proc/gpufreq/gpufreq_opp_dump),
# plafon ditulis ke gpu_cust_upbound_freq (kHz; 0 = tanpa plafon = puncak tabel), dan nilai
# yang dibaca-ulang itulah "efektif". Node devfreq tetap ikut ditulis (best-effort).
# ---------------------------------------------------------------------
OC_GED_UP="$R/sys/module/ged/parameters/gpu_cust_upbound_freq"
OC_GED_HAL_UP="$R/sys/kernel/ged/hal/custom_upbound_gpu_freq"
OC_GED_BOOST="$R/sys/module/ged/parameters/gpu_cust_boost_freq"
OC_GED_HAL_BOOST="$R/sys/kernel/ged/hal/custom_boost_gpu_freq"
# v1.0.9-fix2: BUG UTAMA "OC GPU tidak pernah berubah naik/turun" ada DI SINI.
# oc_mtk_on() versi lama cuma mengecek node module-parameter (OC_GED_UP =
# /sys/module/ged/parameters/gpu_cust_upbound_freq). Banyak kernel vendor MTK
# (termasuk sebagian build Helio G99/MT6789) TIDAK mengekspor node itu sama
# sekali - yang ada cuma varian debugfs/HAL-nya (OC_GED_HAL_UP =
# /sys/kernel/ged/hal/custom_upbound_gpu_freq, sudah dipakai oc_gpu_extra_read
# & oc_mtk_ceiling_khz di berkas ini untuk MEMBACA, tapi oc_mtk_on() yang
# memutuskan "boleh pakai jalur GED asli atau tidak" tidak pernah
# memeriksanya). Akibatnya oc_mtk_on() selalu FALSE di device begini, seluruh
# jalur kontrol GED/gpufreq (yang BENAR-BENAR menggerakkan clock) dilewati,
# dan oc_gpu_set() jatuh ke jalur devfreq generik - yang menurut catatan
# panjang di bagian atas berkas ini sendiri cuma "bayangan": sysfs-nya
# kelihatan berubah ditulis/dibaca ulang, tapi clock GPU asli (gpuclk nyata)
# tidak pernah ikut. Sekarang oc_mtk_on() TRUE kalau SALAH SATU dari dua node
# upbound itu ada, dan oc_gpu_set_mtk() di bawah menulis ke node mana pun yang
# benar2 ada (keduanya kalau device punya dua-duanya).
oc_mtk_on() { [ -e "$OC_GED_UP" ] || [ -e "$OC_GED_HAL_UP" ]; }
oc_ged_up_path() { # path upbound GED yang BENAR ADA di device ini (kosong = tidak ada)
  [ -e "$OC_GED_UP" ] && { echo "$OC_GED_UP"; return 0; }
  [ -e "$OC_GED_HAL_UP" ] && { echo "$OC_GED_HAL_UP"; return 0; }
  return 1
}
oc_ged_boost_path() { # path floor/boost GED (dipakai mode gaming/extreme lib/modelock.sh)
  [ -e "$OC_GED_BOOST" ] && { echo "$OC_GED_BOOST"; return 0; }
  [ -e "$OC_GED_HAL_BOOST" ] && { echo "$OC_GED_HAL_BOOST"; return 0; }
  return 1
}

oc_num() { # angka pertama di dalam teks (kosong kalau tidak ada)
  case "$1" in
    ''|*[!0-9]*) echo "$1" | sed -n 's/^[^0-9]*\([0-9][0-9]*\).*/\1/p' ;;
    *) echo "$1" ;;
  esac
}

# tabel OPP GPU MediaTek dalam kHz, naik. gpufreq (live) dulu, lalu devfreq/cache scan.
oc_mtk_tbl_khz() {
  omt_t=$(gpu_table_mtk 2>/dev/null)
  if [ -z "$omt_t" ]; then
    omt_b=""; omt_p=""
    IFS='|' read -r omt_b omt_p omt_x omt_y < "$SCANDIR/gpu" 2>/dev/null
    omt_s=""
    [ "$omt_b" = devfreq ] && [ -r "$omt_p/available_frequencies" ] && omt_s=$({ tbl_sort < "$omt_p/available_frequencies"; } 2>/dev/null)
    [ -n "$omt_s" ] || omt_s=$(cat "$SCANDIR/gpu_tbl" 2>/dev/null)
    for omt_f in $omt_s; do
      if [ "$omt_f" -ge 100000000 ] 2>/dev/null; then omt_t="$omt_t $((omt_f / 1000))"; else omt_t="$omt_t $omt_f"; fi
    done
    omt_t=${omt_t# }
  fi
  echo "$omt_t"
}

# indeks OPP (0 = tertinggi) -> kHz, dari tabel naik
oc_idx_to_khz() { # oc_idx_to_khz <idx> <tabel...>
  oix_i=$1; shift
  oix_p=$(( $# - oix_i )); [ "$oix_p" -lt 1 ] && oix_p=1
  oix_k=1
  for oix_f in "$@"; do
    [ "$oix_k" = "$oix_p" ] && { echo "$oix_f"; return 0; }
    oix_k=$((oix_k + 1))
  done
}
# kebalikan oc_idx_to_khz: titik tabel (kHz, HARUS persis salah satu nilai
# tabel - pakai hasil oc_snap_tbl dulu) -> indeks OPP (0 = tertinggi), tabel naik.
# v1.0.9-fix3: dipakai karena node debugfs/hal GED (custom_upbound_gpu_freq /
# custom_boost_gpu_freq) menyimpan INDEKS OPP, BUKAN kHz seperti kembarannya
# module-param (gpu_cust_upbound_freq / gpu_cust_boost_freq). Lihat catatan di
# oc_gpu_set_mtk dan oc_gpu_set_mtk_floor.
oc_khz_to_idx() { # oc_khz_to_idx <khz_tepat_di_tabel> <tabel...>
  oki_v=$1; shift
  oki_n=$#; oki_p=0
  for oki_f in "$@"; do
    oki_p=$((oki_p + 1))
    [ "$oki_f" = "$oki_v" ] && { echo $((oki_n - oki_p)); return 0; }
  done
  echo 0
}

# plafon GPU yang sedang berlaku di GED (kHz). Param 0/kosong = tanpa plafon = puncak tabel.
oc_mtk_ceiling_khz() { # oc_mtk_ceiling_khz <tabel...>
  omc_top=""; for omc_f in "$@"; do omc_top=$omc_f; done
  omc_c=$omc_top
  omc_p=$(oc_num "$(read1 "$OC_GED_UP")")
  case "$omc_p" in ''|0) ;; *)
    if [ -z "$omc_c" ] || [ "$omc_p" -lt "$omc_c" ]; then omc_c=$omc_p; fi ;;
  esac
  omc_h=$(oc_num "$(read1 "$OC_GED_HAL_UP")")
  case "$omc_h" in ''|0) ;; *)
    if [ "$omc_h" -ge 100000 ]; then omc_hf=$omc_h; else omc_hf=$(oc_idx_to_khz "$omc_h" "$@"); fi
    if [ -n "$omc_hf" ] && { [ -z "$omc_c" ] || [ "$omc_hf" -lt "$omc_c" ]; }; then omc_c=$omc_hf; fi ;;
  esac
  echo "$omc_c"
}

# lantai (floor/boost GED) MTK yang sedang berlaku (kHz) - kosong/0 = tidak ada floor
oc_mtk_floor_khz() { # oc_mtk_floor_khz <tabel...>
  omf_c=""
  omf_p=$(oc_num "$(read1 "$OC_GED_BOOST")")
  case "$omf_p" in ''|0) ;; *) omf_c=$omf_p ;; esac
  omf_h=$(oc_num "$(read1 "$OC_GED_HAL_BOOST")")
  case "$omf_h" in ''|0) ;; *)
    if [ "$omf_h" -ge 100000 ]; then omf_hf=$omf_h; else omf_hf=$(oc_idx_to_khz "$omf_h" "$@"); fi
    [ -n "$omf_hf" ] && omf_c=$omf_hf ;;
  esac
  echo "$omf_c"
}

# clock GPU NYATA saat ini (kHz) - hanya informasi
oc_mtk_real_khz() {
  for orf in "$R/sys/kernel/ged/hal/current_freqency" "$R/sys/kernel/debug/ged/hal/current_freqency"; do
    [ -r "$orf" ] || continue
    orv=$(oc_num "$(read1 "$orf")")
    [ -n "$orv" ] && [ "$orv" -ge 10000 ] 2>/dev/null && { echo "$orv"; return 0; }
  done
  if [ -r "$R/proc/gpufreq/gpufreq_var_dump" ]; then
    orv=$(grep -i 'cur.*freq' "$R/proc/gpufreq/gpufreq_var_dump" 2>/dev/null | head -n 1 | sed -n 's/.*[Ff]req[^0-9]*\([0-9][0-9]*\).*/\1/p')
    [ -n "$orv" ] && [ "$orv" -ge 10000 ] 2>/dev/null && { echo "$orv"; return 0; }
  fi
  for orf in "$R"/sys/class/devfreq/*mali*/cur_freq; do
    [ -r "$orf" ] || continue
    orv=$(oc_num "$(read1 "$orf")")
    [ -n "$orv" ] && { echo $((orv / 1000)); return 0; }
  done
  return 1
}

# ---------------------------------------------------------------------
# Status (dikonsumsi WebUI tab Overclock)
# ---------------------------------------------------------------------
oc_status() {
  scan_if_needed >/dev/null 2>&1
  oc_db_lookup
  echo "soc_name=$SOC_NAME"
  echo "soc_vendor=$SOC_VENDOR"
  echo "db_known=$([ -n "$OC_DB_CPU" ] && echo 1 || echo 0)"
  echo "db_cpu_khz=$OC_DB_CPU"
  echo "db_gpu_mhz=$OC_DB_GPU"
  echo "headroom_pct=$(oc_headroom)"
  oc_lock_status

  oc_n=$(oc_cpu_count)
  echo "cpu_count=$oc_n"
  oc_any=0
  oc_i=1
  while [ "$oc_i" -le "$oc_n" ]; do
    IFS='|' read -r oc_name oc_path oc_min oc_max oc_w oc_t <<EOF
$(oc_cpu_line "$oc_i")
EOF
    oc_kmax=$(read1 "$oc_path/cpuinfo_max_freq"); oc_kmax=${oc_kmax:-$oc_max}
    oc_kmin=$(read1 "$oc_path/cpuinfo_min_freq"); oc_kmin=${oc_kmin:-$oc_min}
    oc_cur=$(read1 "$oc_path/scaling_max_freq"); oc_cur=${oc_cur:-$oc_kmax}
    oc_ovr=$(oc_conf_get "CPU$oc_i")
    # referensi pabrik: batas kernel, atau spek resmi DB (cluster tercepat)
    oc_ref=$oc_kmax
    if [ "$oc_i" = 1 ] && [ -n "$OC_DB_CPU" ] && [ "$OC_DB_CPU" -lt "$oc_kmax" ] 2>/dev/null; then oc_ref=$OC_DB_CPU; fi
    # "efektif" = nilai scaling_max_freq APA ADANYA (sama persis yang dibaca
    # DevCheck/app lain dari node sysfs ini) - TIDAK dijepit ke oc_kmax lagi.
    # Clamp lama bikin UI bisa menampilkan angka lebih rendah dari kenyataan
    # kalau kernel device ini ternyata menerima target di atas cpuinfo_max_freq.
    oc_eff=$oc_cur
    oc_st=NON_OVERCLOCK
    if [ "$oc_eff" -gt "$oc_ref" ] 2>/dev/null; then oc_st=OVERCLOCK; oc_any=1; fi
    oc_clamp=0
    [ -n "$oc_ovr" ] && [ "$oc_ovr" -gt "$oc_kmax" ] 2>/dev/null && oc_clamp=1
    oc_cores=$(read1 "$oc_path/related_cpus")
    oc_cores_r=$(oc_core_range "$oc_cores")
    oc_class=$(oc_cluster_class "$oc_i" "$oc_n")
    # tabel OPP nyata (kHz) -> slider WebUI memakai titik ini, bukan langkah buatan
    oc_tt=$oc_t
    [ -n "$oc_tt" ] || oc_tt=$({ tbl_sort < "$oc_path/scaling_available_frequencies"; } 2>/dev/null)
    echo "cpu${oc_i}_table=$(echo $oc_tt | tr ' ' ',')"
    echo "cpu${oc_i}_name=$oc_name"
    echo "cpu${oc_i}_cores=${oc_cores_r:-$oc_name}"
    echo "cpu${oc_i}_class=$oc_class"
    echo "cpu${oc_i}_khz_min=$oc_kmin"
    echo "cpu${oc_i}_khz_max=$oc_kmax"
    echo "cpu${oc_i}_khz_ref=$oc_ref"
    echo "cpu${oc_i}_khz_ceil=$(oc_cpu_ceil "$oc_kmax")"
    echo "cpu${oc_i}_khz_cur=$oc_cur"
    echo "cpu${oc_i}_khz_eff=$oc_eff"
    echo "cpu${oc_i}_khz_override=$oc_ovr"
    echo "cpu${oc_i}_clamped=$oc_clamp"
    echo "cpu${oc_i}_status=$oc_st"
    oc_minkhz_cur=$(read1 "$oc_path/scaling_min_freq"); oc_minkhz_cur=${oc_minkhz_cur:-$oc_kmin}
    oc_minovr=$(oc_conf_get "CPUMIN$oc_i")
    echo "cpu${oc_i}_khz_min_cur=$oc_minkhz_cur"
    echo "cpu${oc_i}_khz_min_override=$oc_minovr"
    oc_gcur=$(read1 "$oc_path/scaling_governor")
    oc_gavail=$(read1 "$oc_path/scaling_available_governors")
    oc_govr=$(oc_conf_get "GOVCPU$oc_i")
    echo "cpu${oc_i}_governor_cur=$oc_gcur"
    echo "cpu${oc_i}_governor_avail=$(echo $oc_gavail | tr ' ' ',')"
    echo "cpu${oc_i}_governor_override=$oc_govr"
    echo "cpu${oc_i}_governor_locked=$([ -n "$oc_govr" ] && [ "$oc_govr" = "$oc_gcur" ] && echo 1 || echo 0)"
    oc_i=$((oc_i + 1))
  done
  if [ "$oc_any" = 1 ]; then echo "cpu_status=OVERCLOCK"; else echo "cpu_status=NON_OVERCLOCK"; fi

  IFS='|' read -r og_be og_path og_minn og_maxn < "$SCANDIR/gpu" 2>/dev/null
  echo "gpu_backend=${og_be:-none}"
  og_hi=""; og_lo=""; og_cur=""; og_tbl=""; og_mul=1; og_mtk=0
  if oc_mtk_on; then
    # MediaTek: tabel & plafon dari GED/gpufreq (kontrol asli), satuan kHz
    og_mtk=1
    og_tbl=$(oc_mtk_tbl_khz)
    set -- $og_tbl; og_lo=$1
    [ "$#" -ge 1 ] && { shift $(( $# - 1 )); og_hi=$1; }
    og_cur=$(oc_mtk_ceiling_khz $og_tbl)
    og_mul=1000
    echo "gpu_control=mtk_ged"
    og_real=$(oc_mtk_real_khz); echo "gpu_real_cur_hz=$([ -n "$og_real" ] && echo $((og_real * 1000)))"
    og_floor=$(oc_mtk_floor_khz $og_tbl)
    og_floor_hz=""
    if [ -n "$og_floor" ]; then og_floor_hz=$((og_floor * 1000)); elif [ -n "$og_lo" ]; then og_floor_hz=$((og_lo * 1000)); fi
    echo "gpu_hz_min_cur=$og_floor_hz"
  elif [ -n "$og_path" ]; then
    og_cur=$(read1 "$og_path/$og_maxn")
    # FIX v1.0.7: tabel OPP GPU dibaca LIVE dari sysfs (bukan cache scan lama); cache = fallback.
    og_tbl=""
    [ -r "$og_path/available_frequencies" ] && og_tbl=$({ tbl_sort < "$og_path/available_frequencies"; } 2>/dev/null)
    [ -n "$og_tbl" ] || og_tbl=$(cat "$SCANDIR/gpu_tbl" 2>/dev/null)
    set -- $og_tbl; og_lo=$1
    [ "$#" -ge 1 ] && { shift $(( $# - 1 )); og_hi=$1; }
    [ -n "$og_minn" ] && og_mincur_raw=$(read1 "$og_path/$og_minn")
  fi
  [ -n "$og_hi" ] || og_hi=$GPU_MAXHZ
  case "$og_hi" in 0|*[!0-9]*) og_hi="" ;; esac
  # satuan node -> Hz (lihat oc_gpu_mul); MTK real sudah kHz
  if [ "$og_mtk" != 1 ]; then
    og_mul=1
    [ -n "$og_path" ] && og_mul=$(oc_gpu_mul "$og_be" "$og_hi" "$og_cur")
  fi
  [ -n "$og_hi" ]  && og_hi=$((og_hi * og_mul))
  [ -n "$og_lo" ]  && og_lo=$((og_lo * og_mul))
  case "$og_cur" in ''|*[!0-9]*) ;; *) og_cur=$((og_cur * og_mul)) ;; esac
  oc_gpu_extra_read
  if [ "$og_mtk" = 1 ]; then
    og_upp=$(oc_ged_up_path)
    OC_GX_SRC="mtk_ged+gpufreq (GED upbound[$og_upp]=$(read1 "$og_upp"))"
    OC_GX_MAX=$og_hi
    [ -n "$og_real" ] && OC_GX_CUR=$((og_real * 1000))
  fi
  [ -n "$og_hi" ] || og_hi=$OC_GX_MAX
  og_tblhz=""
  for og_f in $og_tbl; do og_tblhz="$og_tblhz,$((og_f * og_mul))"; done
  echo "gpu_table=${og_tblhz#,}"
  echo "gpu_hz_cur=$og_cur"
  echo "gpu_hz_table_top=$og_hi"
  echo "gpu_hz_table_min=$og_lo"
  echo "gpu_hz_override=$(oc_conf_get GPU)"
  if [ "$og_mtk" != 1 ]; then
    og_mincur_hz=""
    case "$og_mincur_raw" in ''|*[!0-9]*) og_mincur_hz=$og_lo ;; *) og_mincur_hz=$((og_mincur_raw * og_mul)) ;; esac
    echo "gpu_hz_min_cur=$og_mincur_hz"
  fi
  echo "gpu_hz_min_override=$(oc_conf_get GPUMIN)"
  echo "gpu_unit_mul=$og_mul"
  echo "gpu_extra_src=$OC_GX_SRC"
  echo "gpu_extra_cur_hz=$OC_GX_CUR"
  echo "gpu_extra_max_hz=$OC_GX_MAX"
  og_mhz=""; [ -n "$og_hi" ] && og_mhz=$((og_hi / 1000000))
  echo "gpu_mhz_detected=$og_mhz"
  if [ -n "$og_hi" ]; then
    og_ref=$og_hi
    [ -n "$OC_DB_GPU" ] && [ $((OC_DB_GPU * 1000000)) -lt "$og_hi" ] 2>/dev/null && og_ref=$((OC_DB_GPU * 1000000))
    # sama seperti CPU: "efektif" GPU = nilai node sysfs apa adanya, tidak
    # dijepit ke og_hi, supaya konsisten dengan yang dibaca DevCheck.
    og_eff=${og_cur:-$og_hi}
    # GED upbound 0 = tanpa plafon -> efektifnya puncak tabel
    [ "$og_eff" = 0 ] && og_eff=$og_hi
    echo "gpu_hz_ref=$og_ref"
    echo "gpu_hz_ceil=$(oc_gpu_ceil "$og_hi")"
    echo "gpu_hz_eff=$og_eff"
    og_ov=$(oc_conf_get GPU); og_cl=0
    [ -n "$og_ov" ] && [ "$og_ov" -gt "$og_hi" ] 2>/dev/null && og_cl=1
    echo "gpu_clamped=$og_cl"
    if [ "$og_eff" -gt "$og_ref" ] 2>/dev/null; then echo "gpu_status=OVERCLOCK"; else echo "gpu_status=NON_OVERCLOCK"; fi
  else
    echo "gpu_status=NON_OVERCLOCK"
  fi
  if oc_gpu_gov_eligible; then
    og_gcur=$(oc_gov_cur_gpu); og_gavail=$(oc_gov_avail_gpu); og_govr=$(oc_conf_get GOVGPU)
    echo "gpu_governor_eligible=1"
    echo "gpu_governor_cur=$og_gcur"
    echo "gpu_governor_avail=$(echo $og_gavail | tr ' ' ',')"
    echo "gpu_governor_override=$og_govr"
    echo "gpu_governor_locked=$([ -n "$og_govr" ] && [ "$og_govr" = "$og_gcur" ] && echo 1 || echo 0)"
  else
    echo "gpu_governor_eligible=0"
    echo "gpu_governor_cur="
    echo "gpu_governor_avail="
    echo "gpu_governor_override="
    echo "gpu_governor_locked=0"
  fi
}

# ---------------------------------------------------------------------
# Tulis: CPU
# ---------------------------------------------------------------------
oc_cpu_set() { # oc_cpu_set <idx 1-based> <khz>
  oi=$1; ok=$2
  case "$oi" in ''|*[!0-9]*) echo "indeks cluster tidak valid"; return 1 ;; esac
  case "$ok" in ''|*[!0-9]*) echo "nilai kHz tidak valid"; return 1 ;; esac
  line=$(oc_cpu_line "$oi")
  [ -n "$line" ] || { echo "cluster $oi tidak ada"; return 1; }
  IFS='|' read -r ocn ocp ocmin ocmax ocw oct <<EOF
$line
EOF
  ochi=$(read1 "$ocp/cpuinfo_max_freq"); [ -n "$ochi" ] || ochi=$ocmax
  ocmn=$(read1 "$ocp/cpuinfo_min_freq"); [ -n "$ocmn" ] || ocmn=$ocmin
  occeil=$(oc_cpu_ceil "$ochi")
  [ "$ok" -gt "$occeil" ] 2>/dev/null && ok=$occeil
  [ -n "$ocmn" ] && [ "$ok" -lt "$ocmn" ] 2>/dev/null && ok=$ocmn
  # FIX v1.0.9-fix22: "overclock selalu turun beberapa tiap diterapkan" - saat
  # target ($ok) MASIH DI DALAM tabel OPP kernel asli (bukan headroom di atas
  # cpuinfo_max_freq), nilai itu dulu ditulis APA ADANYA ke scaling_max_freq
  # walau bukan salah satu titik tabel yang valid. Kernel/governor lalu
  # menjepitnya sendiri ke titik OPP VALID TERDEKAT DI BAWAHNYA begitu
  # scaling_cur_freq dipilih - hasilnya "efektif" yang terbaca balik konsisten
  # beberapa MHz lebih rendah dari target, padahal target itu sendiri
  # sebenarnya di bawah batas kernel (bukan kasus "DIBATASI tabel"). Sekarang:
  # kalau target masih <= titik tertinggi tabel OPP nyata ($oct), tarik dulu
  # ke titik tabel VALID TERDEKAT (<=target) SEBELUM ditulis - pola yang sama
  # persis sudah dipakai jalur GPU (oc_snap_tbl). Target DI ATAS tabel
  # (overclock sungguhan, > titik tertinggi) TETAP ditulis apa adanya - kernel
  # sendiri yang memutuskan menerima/menjepit, sama seperti sebelumnya.
  if [ -n "$oct" ]; then
    oct_top=""; for oct_f in $oct; do oct_top=$oct_f; done
    if [ -n "$oct_top" ] && [ "$ok" -le "$oct_top" ] 2>/dev/null; then
      oct_sn=$(oc_snap_tbl "$ok" $oct); [ -n "$oct_sn" ] && ok=$oct_sn
    fi
  fi
  oc_prevmax=$(oc_conf_get "CPU$oi")
  if oc_lock_blocked "$oc_prevmax" "$ok"; then
    echo "cluster $oi ($ocn): kunci frekuensi aktif - plafon dibekukan di ${oc_prevmax}kHz, tidak bisa diubah. Nonaktifkan kunci di tab Overclock dulu."; return 1
  fi
  # Selalu lepas limiter software dulu (PPM/msm_performance), TERMASUK saat
  # OC_BOOT=1. Bug lama: unlock di-skip khusus saat auto-apply boot, padahal
  # limiter itu ikut RESET tiap reboot - akibatnya tulisan OC bisa dijepit
  # ulang oleh limiter tanpa modul sadar (OC "ke-set" di conf tapi tidak
  # benar-benar nyala di sysfs setelah reboot).
  oc_unlock_cpu "$oi" "$ocp"
  # FIX v1.0.6: dulu di sini nilai yang BENERAN ditulis ke kernel (okw) dipotong
  # balik ke $ochi (batas stock cpuinfo_max_freq) SEBELUM sempat dicoba - jadi
  # berapa pun target yang digeser di slider, GHz yang sampai ke sysfs (dan
  # yang dibaca DevCheck/app lain) tidak pernah lebih tinggi dari bawaan.
  # Status "DIBATASI kernel" pun selalu muncul walau kernel sendiri belum tentu
  # menolak - itu cuma hasil modul yang mencegat duluan, bukan kernel.
  # Sekarang nilai TARGET ($ok, sudah dijepit ke occeil=stock+headroom di atas)
  # ditulis apa adanya; kernel sendiri yang memutuskan menerima atau menjepit,
  # dan hasil baca ulang (got) di bawah inilah yang menentukan status
  # sebenarnya - sesuai desain yang sudah dijelaskan di komentar atas berkas ini.
  if oc_raw_write "$ocp/scaling_max_freq" "$ok"; then
    got=$(read1 "$ocp/scaling_max_freq")
    oc_conf_set "CPU$oi" "$ok"
    log_msg "OVERCLOCK: cluster $oi ($ocn) target ${ok}kHz, terbaca ${got:-?}kHz, batas OPP kernel ${ochi}kHz"
    # "DIBATASI" dinilai dari hasil BACA ULANG asli (got) vs target, bukan dari
    # heuristik ochi - kalau kernel ternyata menerima lebih tinggi dari ochi,
    # itu harus ikut ditampilkan apa adanya (match dengan DevCheck), bukan
    # dipaksa dipotong ke ochi di layar.
    if [ -n "$got" ] && [ "$got" -lt "$ok" ] 2>/dev/null; then
      echo "cluster $oi ($ocn): target ${ok}kHz, efektif ${got}kHz - DIBATASI tabel OPP kernel (${ochi}kHz)"
    else
      echo "cluster $oi ($ocn) diset ke ${ok}kHz (terbaca ${got:-?}kHz)"
    fi
    # v1.0.9-fix22: lantai (MIN) ikut dinaikkan OTOMATIS ke plafon yang BARU
    # SAJA benar2 tercapai (got, bukan target mentah $ok) setiap kali plafon
    # ini diterapkan - baik dari tab Overclock maupun reapply boot
    # (oc_apply_all), dan begitu juga untuk overclock berikutnya. Sebelumnya
    # lantai dibiarkan di nilai lama sampai user buka slider Lantai secara
    # terpisah, jadi clock nyata masih bisa jatuh-bangun di bawah plafon OC
    # yang baru diset. oc_cpu_set_min sendiri sudah menjepit ke occeilnow
    # (=scaling_max_freq yang baru saja ditulis ini), jadi aman dipanggil
    # langsung dengan nilai got.
    [ -n "$got" ] && oc_cpu_set_min "$oi" "$got" >/dev/null
  else
    echo "gagal menulis ke $ocp/scaling_max_freq"; return 1
  fi
}

# ---------------------------------------------------------------------
# Tulis: CPU lantai (MIN) - mirror oc_cpu_set, tapi untuk scaling_min_freq.
# Lantai tidak boleh melebihi plafon yang sedang aktif (override tersimpan,
# atau scaling_max_freq sekarang bila belum ada override).
# ---------------------------------------------------------------------
oc_cpu_set_min() { # oc_cpu_set_min <idx 1-based> <khz>
  oi=$1; ok=$2
  case "$oi" in ''|*[!0-9]*) echo "indeks cluster tidak valid"; return 1 ;; esac
  case "$ok" in ''|*[!0-9]*) echo "nilai kHz tidak valid"; return 1 ;; esac
  line=$(oc_cpu_line "$oi")
  [ -n "$line" ] || { echo "cluster $oi tidak ada"; return 1; }
  IFS='|' read -r ocn ocp ocmin ocmax ocw oct <<EOF
$line
EOF
  ochi=$(read1 "$ocp/cpuinfo_max_freq"); [ -n "$ochi" ] || ochi=$ocmax
  ocmn=$(read1 "$ocp/cpuinfo_min_freq"); [ -n "$ocmn" ] || ocmn=$ocmin
  [ -n "$ocmn" ] && [ "$ok" -lt "$ocmn" ] 2>/dev/null && ok=$ocmn
  # FIX "lantai naik acak ke batas maksimal": occeilnow DULU diambil dari
  # oc_conf_get "CPU$oi" - nilai TARGET plafon mentah yang disimpan, yang bisa
  # jauh di atas apa yang kernel benar-benar terima (mis. target 2875MHz tapi
  # tabel OPP kernel mentok di 2450MHz -> status "DIBATASI kernel"). Akibatnya
  # lantai boleh digeser/ditulis sampai ke target yang TIDAK PERNAH benar2
  # aktif itu, lalu dibaca-ulang beda dari yang diminta - kelihatan "acak".
  # Sekarang occeilnow = scaling_max_freq SEKARANG (nilai plafon yang BENAR2
  # berlaku di kernel saat ini, sama seperti yang dibaca DevCheck), bukan
  # target mentah - lantai tidak pernah bisa melewati plafon yang nyata aktif.
  occeilnow=$(read1 "$ocp/scaling_max_freq"); [ -n "$occeilnow" ] || occeilnow=$ochi
  [ "$ok" -gt "$occeilnow" ] 2>/dev/null && ok=$occeilnow
  # FIX v1.0.9-fix22: sama seperti oc_cpu_set() - snap ke titik tabel OPP
  # nyata ($oct) kalau target masih di dalam tabel, supaya nilai yang ditulis
  # sudah pasti didukung kernel dan tidak "turun beberapa" tak terduga saat
  # dibaca ulang (berlaku juga saat dipanggil otomatis dari oc_cpu_set di atas).
  if [ -n "$oct" ]; then
    oct_top=""; for oct_f in $oct; do oct_top=$oct_f; done
    if [ -n "$oct_top" ] && [ "$ok" -le "$oct_top" ] 2>/dev/null; then
      oct_sn=$(oc_snap_tbl "$ok" $oct); [ -n "$oct_sn" ] && ok=$oct_sn
    fi
  fi
  oc_prevmin=$(oc_conf_get "CPUMIN$oi")
  if oc_lock_blocked "$oc_prevmin" "$ok"; then
    echo "cluster $oi ($ocn): kunci frekuensi aktif - lantai dibekukan di ${oc_prevmin}kHz, tidak bisa diubah. Nonaktifkan kunci di tab Overclock dulu."; return 1
  fi
  oc_unlock_cpu "$oi" "$ocp"
  if oc_raw_write "$ocp/scaling_min_freq" "$ok"; then
    got=$(read1 "$ocp/scaling_min_freq")
    oc_conf_set "CPUMIN$oi" "$ok"
    log_msg "OVERCLOCK: cluster $oi ($ocn) lantai target ${ok}kHz, terbaca ${got:-?}kHz"
    echo "cluster $oi ($ocn) lantai diset ke ${ok}kHz (terbaca ${got:-?}kHz)"
  else
    echo "gagal menulis ke $ocp/scaling_min_freq"; return 1
  fi
}

oc_cpu_reset() { # oc_cpu_reset [idx]   (kosong = semua)
  if [ "$(oc_lock_get)" = 1 ]; then
    echo "kunci frekuensi aktif - nonaktifkan dulu di tab Overclock sebelum reset"; return 1
  fi
  if [ -n "$1" ]; then
    line=$(oc_cpu_line "$1"); [ -n "$line" ] || { echo "cluster $1 tidak ada"; return 1; }
    IFS='|' read -r ocn ocp _ _ _ _ <<EOF
$line
EOF
    oc_restore_path "$ocp/scaling_max_freq"
    oc_restore_path "$ocp/scaling_min_freq"
    oc_conf_set "CPU$1" ""
    oc_conf_set "CPUMIN$1" ""
    echo "cluster $1 ($ocn) dikembalikan ke bawaan (plafon & lantai)"
  else
    oc_n=$(oc_cpu_count); oc_i=1
    while [ "$oc_i" -le "$oc_n" ]; do oc_cpu_reset "$oc_i" >/dev/null; oc_i=$((oc_i + 1)); done
    echo "semua cluster CPU dikembalikan ke bawaan (plafon & lantai)"
  fi
}

# ---------------------------------------------------------------------
# Tulis: GPU
# ---------------------------------------------------------------------
# v1.0.9: set plafon GPU lewat kontrol ASLI MediaTek (GED upbound, tabel gpufreq)
oc_gpu_set_mtk() { # oc_gpu_set_mtk <hz>
  ov=$1
  oc_prevmax=$(oc_conf_get GPU)
  if oc_lock_blocked "$oc_prevmax" "$ov"; then
    echo "GPU: kunci frekuensi aktif - plafon dibekukan di $((oc_prevmax / 1000000))MHz, tidak bisa diubah. Nonaktifkan kunci di tab Overclock dulu."; return 1
  fi
  omt=$(oc_mtk_tbl_khz)
  omtop=""; omlo=""
  if [ -n "$omt" ]; then set -- $omt; omlo=$1; shift $(( $# - 1 )); omtop=$1; fi
  # jepit ke plafon slider (puncak tabel + headroom) dan lantai tabel
  if [ -n "$omtop" ]; then
    omceil=$(oc_gpu_ceil $((omtop * 1000)))
    [ "$ov" -gt "$omceil" ] 2>/dev/null && ov=$omceil
  fi
  ovk=$((ov / 1000))
  [ -n "$omlo" ] && [ "$ovk" -lt "$omlo" ] && ovk=$omlo
  omover=0; omsnap=$ovk
  if [ -n "$omtop" ]; then
    if [ "$ovk" -gt "$omtop" ]; then omover=1; omsnap=$omtop
    else
      omsn=$(oc_snap_tbl "$ovk" $omt); [ -n "$omsn" ] && omsnap=$omsn
    fi
  fi
  # puncak tabel / di atasnya = lepas plafon (0 = default GED = puncak tabel)
  omw=$omsnap
  if [ -n "$omtop" ] && [ "$omsnap" -ge "$omtop" ]; then omw=0; fi
  oc_unlock_gpu
  omtgt=$(oc_ged_up_path)
  if [ -z "$omtgt" ]; then
    echo "gagal: tidak ada node GED upbound (module-param maupun hal) di device ini"; return 1
  fi
  # v1.0.9-fix3: BUG UTAMA "OC GPU dipatok turun ke titik terendah (mis.
  # ~390MHz) berapa pun target yang diminta" ada DI SINI. Node debugfs/hal
  # ($OC_GED_HAL_UP = /sys/kernel/ged/hal/custom_upbound_gpu_freq) menyimpan
  # INDEKS OPP (0 = tertinggi, makin besar makin rendah), BUKAN kHz seperti
  # kembarannya module-param ($OC_GED_UP). Banyak build Helio G99/MT6789
  # (termasuk device ini kemungkinan besar) cuma mengekspor varian hal, jadi
  # oc_ged_up_path() mengarah ke sana. Sebelumnya kode ini menulis "omw"
  # (nilai kHz mentah, ratusan ribu) langsung ke node itu - kernel membacanya
  # sebagai indeks JAUH di luar tabel lalu menjepitnya ke indeks VALID
  # TERAKHIR = OPP PALING LEMAH di tabel. Itu sebabnya hasilnya selalu
  # nyangkut di titik terendah tabel, tidak peduli target di atas 1000MHz
  # sekalipun. Sekarang tiap node ditulis dalam satuannya sendiri: kHz untuk
  # module-param, indeks (oc_khz_to_idx) untuk debugfs/hal.
  omidx=$(oc_khz_to_idx "$omsnap" $omt)
  if [ "$omtgt" = "$OC_GED_HAL_UP" ]; then omwtgt=$omidx; else omwtgt=$omw; fi
  if ! oc_raw_write "$omtgt" "$omwtgt"; then
    echo "gagal menulis ke $omtgt"; return 1
  fi
  # device yang punya DUA node (module-param & hal) - tulis juga pasangannya
  # best-effort, SATUAN BEDA tiap node (lihat catatan di atas) - supaya
  # konsisten tidak peduli mana yang dibaca balik oleh powerhal/vendor lain
  [ -e "$OC_GED_UP" ] && [ "$omtgt" != "$OC_GED_UP" ] && oc_raw_write "$OC_GED_UP" "$omw"
  [ -e "$OC_GED_HAL_UP" ] && [ "$omtgt" != "$OC_GED_HAL_UP" ] && oc_raw_write "$OC_GED_HAL_UP" "$omidx"
  # bayangan devfreq kbase (best-effort, tidak menentukan hasil)
  IFS='|' read -r omb omp omminn ommaxn < "$SCANDIR/gpu" 2>/dev/null
  if [ "$omb" = devfreq ] && [ -n "$omp" ] && [ -e "$omp/$ommaxn" ]; then
    oc_raw_write "$omp/$ommaxn" $((ovk * 1000)) || true
  fi
  omgot=$(oc_mtk_ceiling_khz $omt)
  omreal=$(oc_mtk_real_khz)
  oc_conf_set GPU $((omsnap * 1000))
  # v1.0.9-fix22: GPU lantai ikut dinaikkan OTOMATIS ke plafon yang baru saja
  # diterapkan (sama pola dengan CPU di atas) - lewat jalur floor/boost GED
  # yang sudah ada (oc_gpu_set_mtk_floor), dipanggil dengan nilai plafon yang
  # BENAR2 tercapai (omsnap), bukan target mentah $ov. Berlaku untuk overclock
  # berikutnya juga, karena ini jalan tiap kali oc_gpu_set_mtk() dipanggil -
  # termasuk dari oc_apply_all() saat boot.
  oc_gpu_set_mtk_floor $((omsnap * 1000)) >/dev/null 2>&1 && oc_conf_set GPUMIN $((omsnap * 1000))
  log_msg "OVERCLOCK: gpu MTK target ${ovk}kHz snap ${omsnap}kHz tulis $omtgt=${omwtgt} (idx=${omidx}, khz=${omw}) -> plafon terbaca ${omgot:-?}kHz, clock nyata ${omreal:-?}kHz, puncak tabel gpufreq ${omtop:-?}kHz"
  if [ "$omover" = 1 ]; then
    echo "GPU: target $((ovk / 1000))MHz di atas tabel gpufreq kernel (maks $((omtop / 1000))MHz) - plafon dilepas ke $((omtop / 1000))MHz. Untuk lebih tinggi butuh mtk_gpufreq_*.ko yang sudah di-patch (tabel OPP-nya ditambah)."
  elif [ -n "$omgot" ] && [ "$omgot" -ne "$omsnap" ] 2>/dev/null; then
    echo "GPU: target $((omsnap / 1000))MHz, tapi GED melaporkan plafon $((omgot / 1000))MHz - ada yang menimpa (app lain/PowerHAL). Cek: azenith-ai overclock gpudiag"
  else
    echo "GPU plafon diset ke $((omsnap / 1000))MHz (terbaca $(( ${omgot:-$omsnap} / 1000 ))MHz${omreal:+, clock sekarang $((omreal / 1000))MHz})"
  fi
  return 0
}

oc_gpu_set() { # oc_gpu_set <hz>
  ov=$1
  case "$ov" in ''|*[!0-9]*) echo "nilai Hz tidak valid"; return 1 ;; esac
  # MediaTek dengan GED: pakai kontrol asli (devfreq kbase cuma bayangan)
  if oc_mtk_on; then oc_gpu_set_mtk "$ov"; return $?; fi
  oc_prevmax=$(oc_conf_get GPU)
  if oc_lock_blocked "$oc_prevmax" "$ov"; then
    echo "GPU: kunci frekuensi aktif - plafon dibekukan di $((oc_prevmax / 1000000))MHz, tidak bisa diubah. Nonaktifkan kunci di tab Overclock dulu."; return 1
  fi
  IFS='|' read -r ogb ogp ogminn ogmaxn < "$SCANDIR/gpu" 2>/dev/null
  [ -n "$ogp" ] || { echo "GPU tidak punya node yang bisa ditulis di device ini"; return 1; }
  # tabel OPP live (fallback cache scan) - dalam SATUAN NODE
  ogtbl=""
  [ -r "$ogp/available_frequencies" ] && ogtbl=$({ tbl_sort < "$ogp/available_frequencies"; } 2>/dev/null)
  [ -n "$ogtbl" ] || ogtbl=$(cat "$SCANDIR/gpu_tbl" 2>/dev/null)
  set -- $ogtbl; oghi=""; oglo=$1
  [ "$#" -ge 1 ] && { shift $(( $# - 1 )); oghi=$1; }
  [ -n "$oghi" ] || oghi=$GPU_MAXHZ
  case "$oghi" in 0|*[!0-9]*) oghi="" ;; esac
  ogcur0=$(read1 "$ogp/$ogmaxn")
  ogmul=$(oc_gpu_mul "$ogb" "$oghi" "$ogcur0")
  # semua perhitungan jepit dalam Hz, baru dikonversi ke satuan node saat menulis
  oghi_hz=""; oglo_hz=""
  [ -n "$oghi" ] && oghi_hz=$((oghi * ogmul))
  case "$oglo" in ''|*[!0-9]*) ;; *) oglo_hz=$((oglo * ogmul)) ;; esac
  if [ -n "$oghi_hz" ]; then
    ogceil=$(oc_gpu_ceil "$oghi_hz")
    [ "$ov" -gt "$ogceil" ] 2>/dev/null && ov=$ogceil
  fi
  [ -n "$oglo_hz" ] && [ "$ov" -lt "$oglo_hz" ] 2>/dev/null && ov=$oglo_hz
  ovn=$((ov / ogmul))
  # MTK GED / Exynos hanya menerima titik OPP nyata: tarik ke titik tabel terdekat
  # (<= target). Di atas puncak tabel (overclock) ditulis apa adanya.
  case "$ogb" in
    mtk_ged|exynos_kgpu)
      if [ -n "$ogtbl" ] && [ -n "$oghi" ] && [ "$ovn" -le "$oghi" ] 2>/dev/null; then
        ogsn=$(oc_snap_tbl "$ovn" $ogtbl)
        [ -n "$ogsn" ] && ovn=$ogsn
      fi ;;
  esac
  ov=$((ovn * ogmul))
  oc_unlock_gpu
  if oc_raw_write "$ogp/$ogmaxn" "$ovn"; then
    got=$(read1 "$ogp/$ogmaxn")
    case "$got" in ''|*[!0-9]*) got_hz="" ;; *) got_hz=$((got * ogmul)) ;; esac
    oc_conf_set GPU "$ov"
    log_msg "OVERCLOCK: gpu $ogb $ogp/$ogmaxn target ${ov}Hz (node=${ovn}, x${ogmul}), terbaca ${got:-?} (${got_hz:-?}Hz), puncak tabel ${oghi_hz:-?}Hz"
    if [ -n "$got_hz" ] && [ "$got_hz" -lt "$ov" ] 2>/dev/null; then
      if [ "$got_hz" = 0 ]; then
        echo "GPU diset ke $((ov / 1000000))MHz (node melaporkan 0 = tanpa plafon)"
      else
        echo "GPU: target $((ov / 1000000))MHz, efektif $((got_hz / 1000000))MHz - DIBATASI tabel OPP kernel"
      fi
    else
      echo "GPU diset ke $((ov / 1000000))MHz (terbaca $(( ${got_hz:-$ov} / 1000000 ))MHz)"
    fi
    # v1.0.9-fix22: lantai GPU ikut plafon baru juga (sama seperti CPU/MTK di
    # atas) - pakai nilai efektif yang benar2 terbaca (got_hz) kalau ada,
    # fallback ke target $ov. Berlaku tiap kali oc_gpu_set() dipanggil,
    # termasuk reapply boot lewat oc_apply_all().
    oc_gpu_set_min "${got_hz:-$ov}" >/dev/null 2>&1
  else
    echo "gagal menulis ke $ogp/$ogmaxn"; return 1
  fi
}

# ---------------------------------------------------------------------
# Tulis: GPU lantai (MIN). MediaTek pakai jalur floor/boost GED yang sudah
# ada (oc_gpu_set_mtk_floor); non-MTK devfreq tulis langsung ke node min
# (ogminn, hasil scan di $SCANDIR/gpu), dijepit tabel & tidak melebihi
# plafon yang sedang aktif.
# ---------------------------------------------------------------------
oc_gpu_set_min() { # oc_gpu_set_min <hz>
  ov=$1
  case "$ov" in ''|*[!0-9]*) echo "nilai Hz tidak valid"; return 1 ;; esac
  oc_prevmin=$(oc_conf_get GPUMIN)
  if oc_lock_blocked "$oc_prevmin" "$ov"; then
    echo "GPU: kunci frekuensi aktif - lantai dibekukan di $((oc_prevmin / 1000000))MHz, tidak bisa diubah. Nonaktifkan kunci di tab Overclock dulu."; return 1
  fi
  if oc_mtk_on; then
    if oc_gpu_set_mtk_floor "$ov"; then
      oc_conf_set GPUMIN "$ov"
      echo "GPU lantai diset ke $((ov / 1000000))MHz"
      return 0
    else
      return 1
    fi
  fi
  IFS='|' read -r ogb ogp ogminn ogmaxn < "$SCANDIR/gpu" 2>/dev/null
  [ -n "$ogp" ] && [ -n "$ogminn" ] || { echo "GPU tidak punya node lantai (min_freq) yang bisa ditulis di device ini"; return 1; }
  ogtbl=""
  [ -r "$ogp/available_frequencies" ] && ogtbl=$({ tbl_sort < "$ogp/available_frequencies"; } 2>/dev/null)
  [ -n "$ogtbl" ] || ogtbl=$(cat "$SCANDIR/gpu_tbl" 2>/dev/null)
  set -- $ogtbl; oglo=$1; oghi=""
  [ "$#" -ge 1 ] && { shift $(( $# - 1 )); oghi=$1; }
  ogcur0=$(read1 "$ogp/$ogmaxn")
  ogmul=$(oc_gpu_mul "$ogb" "$oghi" "$ogcur0")
  oglo_hz=""; case "$oglo" in ''|*[!0-9]*) ;; *) oglo_hz=$((oglo * ogmul)) ;; esac
  oghi_hz=""; [ -n "$oghi" ] && oghi_hz=$((oghi * ogmul))
  [ -n "$oglo_hz" ] && [ "$ov" -lt "$oglo_hz" ] 2>/dev/null && ov=$oglo_hz
  # FIX sama seperti CPU: occeilnow pakai nilai plafon NYATA yang sedang
  # ditulis di node ($ogmaxn) SEKARANG, bukan target mentah oc_conf_get GPU -
  # target itu bisa lebih tinggi dari yang kernel benar2 terima.
  occeilnow=""; case "$ogcur0" in ''|*[!0-9]*) ;; *) occeilnow=$((ogcur0 * ogmul)) ;; esac
  [ -n "$occeilnow" ] || occeilnow=$oghi_hz
  [ -n "$occeilnow" ] && [ "$ov" -gt "$occeilnow" ] 2>/dev/null && ov=$occeilnow
  ovn=$((ov / ogmul))
  case "$ogb" in
    mtk_ged|exynos_kgpu)
      if [ -n "$ogtbl" ]; then ogsn=$(oc_snap_tbl "$ovn" $ogtbl); [ -n "$ogsn" ] && ovn=$ogsn; fi ;;
  esac
  ov=$((ovn * ogmul))
  oc_unlock_gpu
  if oc_raw_write "$ogp/$ogminn" "$ovn"; then
    got=$(read1 "$ogp/$ogminn")
    gotHz=""; case "$got" in ''|*[!0-9]*) ;; *) gotHz=$((got * ogmul)) ;; esac
    oc_conf_set GPUMIN "$ov"
    log_msg "OVERCLOCK: gpu $ogb $ogp/$ogminn lantai target ${ov}Hz (node=${ovn}), terbaca ${got:-?} (${gotHz:-?}Hz)"
    echo "GPU lantai diset ke $((ov / 1000000))MHz (terbaca $(( ${gotHz:-$ov} / 1000000 ))MHz)"
  else
    echo "gagal menulis ke $ogp/$ogminn"; return 1
  fi
}

oc_gpu_reset() {
  if [ "$(oc_lock_get)" = 1 ]; then
    echo "kunci frekuensi aktif - nonaktifkan dulu di tab Overclock sebelum reset"; return 1
  fi
  IFS='|' read -r ogb ogp ogminn ogmaxn < "$SCANDIR/gpu" 2>/dev/null
  [ -n "$ogp" ] && oc_restore_path "$ogp/$ogmaxn"
  [ -n "$ogp" ] && [ -n "$ogminn" ] && oc_restore_path "$ogp/$ogminn"
  # MediaTek: kembalikan plafon & floor GED ke nilai sebelum modul menulis
  # (0 = tanpa plafon/boost) - kedua node (module-param & hal) dicoba, mana
  # pun yang device ini punya.
  oc_restore_path "$OC_GED_UP" || true
  oc_restore_path "$OC_GED_HAL_UP" || true
  oc_restore_path "$OC_GED_BOOST" || true
  oc_restore_path "$OC_GED_HAL_BOOST" || true
  oc_conf_set GPU ""
  oc_conf_set GPUMIN ""
  echo "GPU dikembalikan ke bawaan (plafon & lantai)"
}

# ---------------------------------------------------------------------
# v1.0.9-fix2: floor/boost GPU MediaTek (dipakai lib/modelock.sh untuk mode
# gaming - floor terangkat supaya clock tidak jatuh-bangun - dan extreme -
# floor dikunci sama dengan ceiling). Node GED boost (gpu_cust_boost_freq /
# custom_boost_gpu_freq) sama persis dengan node upbound (satuan kHz di
# module-param, dan di-snap ke titik tabel gpufreq terdekat), hanya beda
# fungsi: upbound = plafon ATAS, boost = lantai BAWAH yang dipaksa GED.
# ---------------------------------------------------------------------
oc_gpu_set_mtk_floor() { # oc_gpu_set_mtk_floor <hz atau 0/kosong = lepas>
  ofv=$1
  oftgt=$(oc_ged_boost_path)
  if [ -z "$oftgt" ]; then
    echo "device ini tidak punya node GED boost (floor GPU tidak tersedia)"; return 1
  fi
  if [ -z "$ofv" ] || [ "$ofv" = 0 ]; then
    oc_restore_path "$oftgt" || { echo 0 > "$oftgt"; } 2>/dev/null
    [ -e "$OC_GED_BOOST" ] && [ "$oftgt" != "$OC_GED_BOOST" ] && { oc_restore_path "$OC_GED_BOOST" || { echo 0 > "$OC_GED_BOOST"; } 2>/dev/null; }
    [ -e "$OC_GED_HAL_BOOST" ] && [ "$oftgt" != "$OC_GED_HAL_BOOST" ] && { oc_restore_path "$OC_GED_HAL_BOOST" || { echo 0 > "$OC_GED_HAL_BOOST"; } 2>/dev/null; }
    log_msg "OVERCLOCK: gpu floor (boost) dilepas"
    return 0
  fi
  omt=$(oc_mtk_tbl_khz)
  ofk=$((ofv / 1000))
  # FIX: dulu lantai MTK tidak pernah dijepit ke plafon yang sedang aktif sama
  # sekali (beda dari jalur CPU/GPU-non-MTK yang sudah menjepit ke occeilnow) -
  # floor boleh ditulis lebih tinggi dari ceiling GED yang nyata berlaku
  # sekarang, device lalu menolak/menjepit sendiri dengan caranya -> kelihatan
  # "acak". oc_mtk_ceiling_khz = plafon NYATA GED saat ini (bukan target
  # mentah), dipakai sebagai batas atas lantai, sama logikanya dengan fix CPU.
  if [ -n "$omt" ]; then
    ofceil=$(oc_mtk_ceiling_khz $omt)
    [ -n "$ofceil" ] && [ "$ofk" -gt "$ofceil" ] 2>/dev/null && ofk=$ofceil
    ofsn=$(oc_snap_tbl "$ofk" $omt); [ -n "$ofsn" ] && ofk=$ofsn
  fi
  # v1.0.9-fix3: sama seperti ceiling di oc_gpu_set_mtk() - node debugfs/hal
  # ($OC_GED_HAL_BOOST) itu INDEKS OPP, module-param ($OC_GED_BOOST) itu kHz.
  # Tulis satuan yang benar ke masing-masing node, atau floor "gaming"/"extreme"
  # dari lib/modelock.sh ikut kena bug yang sama (nyangkut ke OPP terendah).
  ofidx=0
  [ -n "$omt" ] && ofidx=$(oc_khz_to_idx "$ofk" $omt)
  if [ "$oftgt" = "$OC_GED_HAL_BOOST" ]; then oftwrite=$ofidx; else oftwrite=$ofk; fi
  oc_raw_write "$oftgt" "$oftwrite"
  [ -e "$OC_GED_BOOST" ] && [ "$oftgt" != "$OC_GED_BOOST" ] && oc_raw_write "$OC_GED_BOOST" "$ofk"
  [ -e "$OC_GED_HAL_BOOST" ] && [ "$oftgt" != "$OC_GED_HAL_BOOST" ] && oc_raw_write "$OC_GED_HAL_BOOST" "$ofidx"
  ofgot=$(oc_num "$(read1 "$oftgt")")
  log_msg "OVERCLOCK: gpu floor target ${ofk}kHz (idx ${ofidx}) tulis $oftgt=${oftwrite}, terbaca ${ofgot:-?}"
  return 0
}

# =======================================================================
# v1.0.9-fix9: GOVERNOR (CPU scaling_governor per cluster + GPU devfreq
# governor), bukan cuma plafon scaling_max_freq.
#
# Kenapa ini perlu: menaikkan scaling_max_freq TIDAK memaksa clock jalan di
# situ - governor (schedutil/interactive/ondemand) tetap boleh menurunkan
# scaling_cur_freq kapan saja sesuai beban. Kalau yang dicek cuma "apakah
# nilai max sudah ketulis" maka terlihat OC, tapi app lain (DevCheck/game)
# yang membaca scaling_cur_freq atau benchmark singkat tetap melihat clock
# turun-naik seperti biasa - OC jadi serasa "visual doang" padahal node
# sudah benar ditulis. Mengunci governor ke "performance" (CPU) / performance
# devfreq governor (GPU non-MTK) membuat clock NYATA menempel ke plafon yang
# baru diset, itu yang disebut "diterapkan" di sini: bukan cuma file target
# ketulis, tapi cur_freq ikut sama persis saat dibaca ulang.
#
# Sama seperti plafon freq: override governor disimpan PERSISTEN di
# $OCCONF (kunci GOVCPU<idx> / GOVGPU), dipakai lagi oleh oc_apply_all()
# tiap boot (dipanggil dari lib/daemon.sh setelah scan selesai), dan ditulis
# lewat oc_raw_write supaya backup-nya ikut jalur OCSTACK/OCBACKUPDIR yang
# TIDAK pernah disentuh revert_stack sesi game (lihat catatan di awal berkas).
#
# GPU: hanya efektif pada backend "devfreq" ASLI (kgsl/mali/exynos devfreq -
# ini yang punya file governor/available_governors). Pada MediaTek dengan GED
# (oc_mtk_on=true) clock GPU diatur GED+gpufreq, node devfreq-nya cuma
# "bayangan" (lihat catatan panjang di oc_gpu_set_mtk di atas) - MENULIS
# governor devfreq di situ TIDAK mengubah clock nyata, jadi fungsi di bawah
# menolak dan bilang jelas kenapa, alih-alih diam-diam menulis sesuatu yang
# tidak ada efeknya (itu sendiri contoh "visual doang" yang mau dihindari).
# =======================================================================
oc_gov_path() { # oc_gov_path <cpu policy path> -> .../scaling_governor
  echo "$1/scaling_governor"
}
oc_gov_avail_cpu() { # oc_gov_avail_cpu <idx 1-based> -> daftar governor dipisah spasi
  line=$(oc_cpu_line "$1"); [ -n "$line" ] || return 1
  IFS='|' read -r _ ocp _ _ _ _ <<EOF
$line
EOF
  read1 "$ocp/scaling_available_governors"
}
oc_gov_cur_cpu() { # oc_gov_cur_cpu <idx 1-based>
  line=$(oc_cpu_line "$1"); [ -n "$line" ] || return 1
  IFS='|' read -r _ ocp _ _ _ _ <<EOF
$line
EOF
  read1 "$ocp/scaling_governor"
}
oc_gov_valid() { # oc_gov_valid <governor> <daftar...> -> 0 kalau ada di daftar
  ogv_want=$1; shift
  for ogv_g in "$@"; do [ "$ogv_g" = "$ogv_want" ] && return 0; done
  return 1
}
# tulis governor ke SEMUA cpu di related_cpus cluster ini (kernel butuh governor
# sama rata per-cluster; menulis cuma ke policy pertama kadang tidak diikuti
# cpu lain di cluster yang sama pada sebagian kernel vendor) - tapi node
# policy itu sendiri sudah mewakili seluruh cluster di hampir semua kernel
# modern, jadi satu tulisan ke scaling_governor policy cukup; tetap dicoba ke
# tiap cpuN/cpufreq/scaling_governor sebagai best-effort untuk kernel lama.
oc_cpu_set_governor() { # oc_cpu_set_governor <idx 1-based> <governor>
  oi=$1; og=$2
  case "$oi" in ''|*[!0-9]*) echo "indeks cluster tidak valid"; return 1 ;; esac
  [ -n "$og" ] || { echo "nama governor kosong"; return 1; }
  line=$(oc_cpu_line "$oi"); [ -n "$line" ] || { echo "cluster $oi tidak ada"; return 1; }
  IFS='|' read -r ocn ocp _ _ _ _ <<EOF
$line
EOF
  avail=$(read1 "$ocp/scaling_available_governors")
  if [ -n "$avail" ] && ! oc_gov_valid "$og" $avail; then
    echo "governor '$og' tidak tersedia di cluster $oi ($ocn). Pilihan: $avail"; return 1
  fi
  gp=$(oc_gov_path "$ocp")
  if oc_raw_write "$gp" "$og"; then
    got=$(read1 "$gp")
    if [ "$got" = "$og" ]; then
      oc_conf_set "GOVCPU$oi" "$og"
      log_msg "OVERCLOCK: governor cluster $oi ($ocn) diset ke $og"
      # best-effort: tulis juga ke tiap cpuN/cpufreq/scaling_governor di cluster
      # ini (kernel lama yang tidak mewarisi dari node policy bersama)
      for ocg_c in $(cat "$ocp/related_cpus" 2>/dev/null); do
        ocg_f="$R/sys/devices/system/cpu/cpu$ocg_c/cpufreq/scaling_governor"
        [ "$ocg_f" = "$gp" ] || { [ -e "$ocg_f" ] && oc_raw_write "$ocg_f" "$og" >/dev/null; }
      done
      echo "cluster $oi ($ocn): governor diset ke $og (terbaca $got)"
    else
      echo "cluster $oi ($ocn): governor ditulis $og tapi kernel membaca balik '$got' - tidak diterima"; return 1
    fi
  else
    echo "gagal menulis governor ke $gp"; return 1
  fi
}
oc_cpu_governor_reset() { # oc_cpu_governor_reset [idx]   (kosong = semua)
  if [ -n "$1" ]; then
    line=$(oc_cpu_line "$1"); [ -n "$line" ] || { echo "cluster $1 tidak ada"; return 1; }
    IFS='|' read -r ocn ocp _ _ _ _ <<EOF
$line
EOF
    oc_restore_path "$(oc_gov_path "$ocp")"
    oc_conf_set "GOVCPU$1" ""
    echo "cluster $1 ($ocn): governor dikembalikan ke bawaan"
  else
    oc_n=$(oc_cpu_count); oc_i=1
    while [ "$oc_i" -le "$oc_n" ]; do oc_cpu_governor_reset "$oc_i" >/dev/null; oc_i=$((oc_i + 1)); done
    echo "semua governor CPU dikembalikan ke bawaan"
  fi
}

oc_gpu_gov_eligible() { # 0 = ada node devfreq governor yang BENAR-BENAR mengatur clock (bukan bayangan MTK)
  oc_mtk_on && return 1
  IFS='|' read -r ogb ogp _ _ < "$SCANDIR/gpu" 2>/dev/null
  [ "$ogb" = devfreq ] && [ -n "$ogp" ] && [ -e "$ogp/governor" ]
}
oc_gov_avail_gpu() {
  oc_gpu_gov_eligible || return 1
  IFS='|' read -r _ ogp _ _ < "$SCANDIR/gpu" 2>/dev/null
  read1 "$ogp/available_governors"
}
oc_gov_cur_gpu() {
  oc_gpu_gov_eligible || return 1
  IFS='|' read -r _ ogp _ _ < "$SCANDIR/gpu" 2>/dev/null
  read1 "$ogp/governor"
}
oc_gpu_set_governor() { # oc_gpu_set_governor <governor>
  og=$1
  [ -n "$og" ] || { echo "nama governor kosong"; return 1; }
  if oc_mtk_on; then
    echo "device ini pakai kontrol GPU MediaTek (GED/gpufreq) - node devfreq governor cuma bayangan dan tidak menggerakkan clock nyata di sini, jadi tidak ditulis. Pakai slider Plafon GPU (sudah lewat jalur GED yang benar)."
    return 1
  fi
  IFS='|' read -r ogb ogp _ _ < "$SCANDIR/gpu" 2>/dev/null
  if [ "$ogb" != devfreq ] || [ -z "$ogp" ] || [ ! -e "$ogp/governor" ]; then
    echo "device ini tidak punya node devfreq governor yang bisa ditulis"; return 1
  fi
  avail=$(read1 "$ogp/available_governors")
  if [ -n "$avail" ] && ! oc_gov_valid "$og" $avail; then
    echo "governor '$og' tidak tersedia di GPU. Pilihan: $avail"; return 1
  fi
  if oc_raw_write "$ogp/governor" "$og"; then
    got=$(read1 "$ogp/governor")
    if [ "$got" = "$og" ]; then
      oc_conf_set "GOVGPU" "$og"
      log_msg "OVERCLOCK: governor GPU diset ke $og"
      echo "GPU: governor diset ke $og (terbaca $got)"
    else
      echo "GPU: governor ditulis $og tapi kernel membaca balik '$got' - tidak diterima"; return 1
    fi
  else
    echo "gagal menulis governor ke $ogp/governor"; return 1
  fi
}
oc_gpu_governor_reset() {
  if ! oc_gpu_gov_eligible; then
    oc_conf_set "GOVGPU" ""
    echo "GPU: tidak ada override governor aktif di device ini"
    return 0
  fi
  IFS='|' read -r _ ogp _ _ < "$SCANDIR/gpu" 2>/dev/null
  oc_restore_path "$ogp/governor"
  oc_conf_set "GOVGPU" ""
  echo "GPU: governor dikembalikan ke bawaan"
}

# ---------------------------------------------------------------------
# Terapkan ulang semua override tersimpan (boot, setelah scan selesai -
# lib/daemon.sh). Bisa juga manual: azenith-ai overclock apply
# ---------------------------------------------------------------------
oc_apply_all() {
  [ -f "$OCCONF" ] || return 0
  oc_n=$(oc_cpu_count); oc_i=1
  while [ "$oc_i" -le "$oc_n" ]; do
    ov=$(oc_conf_get "CPU$oc_i")
    [ -n "$ov" ] && oc_cpu_set "$oc_i" "$ov" >/dev/null
    oc_i=$((oc_i + 1))
  done
  ogv=$(oc_conf_get GPU)
  [ -n "$ogv" ] && oc_gpu_set "$ogv" >/dev/null
  # lantai (MIN) diterapkan SETELAH plafon (MAX), supaya penjepitan "lantai
  # tidak melebihi plafon aktif" di oc_cpu_set_min/oc_gpu_set_min memakai
  # plafon yang sudah baru, bukan bawaan lama.
  oc_n=$(oc_cpu_count); oc_i=1
  while [ "$oc_i" -le "$oc_n" ]; do
    ovm=$(oc_conf_get "CPUMIN$oc_i")
    [ -n "$ovm" ] && oc_cpu_set_min "$oc_i" "$ovm" >/dev/null
    oc_i=$((oc_i + 1))
  done
  ogvm=$(oc_conf_get GPUMIN)
  [ -n "$ogvm" ] && oc_gpu_set_min "$ogvm" >/dev/null
  # governor override diterapkan SETELAH plafon freq, supaya kalau governor
  # "performance" langsung mendorong clock ke scaling_max_freq, nilai max
  # yang dibaca sudah yang baru, bukan bawaan.
  oc_n=$(oc_cpu_count); oc_i=1
  while [ "$oc_i" -le "$oc_n" ]; do
    ogov=$(oc_conf_get "GOVCPU$oc_i")
    [ -n "$ogov" ] && oc_cpu_set_governor "$oc_i" "$ogov" >/dev/null
    oc_i=$((oc_i + 1))
  done
  oggv=$(oc_conf_get GOVGPU)
  [ -n "$oggv" ] && oc_gpu_set_governor "$oggv" >/dev/null
  return 0
}

# ---------------------------------------------------------------------
# Diagnosa: ada tidak OPP lebih tinggi yang tersembunyi di kernel ini?
# ---------------------------------------------------------------------
oc_diag() {
  echo "== CPU =="
  for d in "$R"/sys/devices/system/cpu/cpufreq/policy*; do
    [ -d "$d" ] || continue
    echo "${d##*/}: cpus=$(cat $d/related_cpus 2>/dev/null) min=$(read1 $d/cpuinfo_min_freq) max=$(read1 $d/cpuinfo_max_freq) scaling_max=$(read1 $d/scaling_max_freq)"
    echo "  tabel: $(cat $d/scaling_available_frequencies 2>/dev/null)"
  done
  echo "== PPM =="
  for f in policy_status policy/userlimit_max_cpu_freq policy/hard_userlimit_max_cpu_freq; do
    [ -r "$R/proc/ppm/$f" ] && { echo "-- ppm/$f"; head -n 12 "$R/proc/ppm/$f"; }
  done
  echo "== CPUFREQ MTK =="
  for f in "$R"/proc/cpufreq/MT_CPU_DVFS_*/cpufreq_oppidx; do [ -r "$f" ] && { echo "-- $f"; head -n 20 "$f"; }; done
  echo "== GPU =="
  for d in "$R"/sys/class/devfreq/*; do
    [ -d "$d" ] || continue
    echo "${d##*/}: cur=$(read1 $d/cur_freq) min=$(read1 $d/min_freq) max=$(read1 $d/max_freq)"
    echo "  tabel: $(cat $d/available_frequencies 2>/dev/null)"
  done
  for f in gpufreq/gpufreq_opp_dump gpufreq/gpufreq_limit_table gpufreqv2/gpu_working_opp_table gpufreqv2/gpu_signed_opp_table; do
    [ -r "$R/proc/$f" ] && { echo "-- proc/$f"; head -n 40 "$R/proc/$f"; }
  done
  [ -r "$R/sys/kernel/ged/hal/custom_upbound_gpu_freq" ] && echo "ged upbound idx: $(read1 $R/sys/kernel/ged/hal/custom_upbound_gpu_freq)"
}

# ---------------------------------------------------------------------
# v1.0.9: diagnosa GPU - tampilkan SEMUA node kandidat + nilainya, supaya jelas
# jalur mana yang benar-benar mengatur clock GPU di device ini.
#   azenith-ai overclock gpudiag
# ---------------------------------------------------------------------
oc_gpu_diag() {
  scan_if_needed >/dev/null 2>&1
  dv_gpu_vendor
  echo "== GPU vendor =="
  echo "vendor: ${GV_VENDOR:-tidak teridentifikasi (bukan Mali/Adreno/PowerVR yang terdeteksi lewat sysfs/debugfs resmi vendor)}  model: ${GV_NAME:-?}"
  echo "== GPU scan =="; cat "$SCANDIR/gpu" 2>/dev/null
  echo "kontrol MTK (GED): $(oc_mtk_on && echo ADA || echo tidak-ada)"
  echo "== GED =="
  for f in "$R"/sys/module/ged/parameters/gpu_cust_upbound_freq "$R"/sys/module/ged/parameters/gpu_cust_boost_freq \
           "$R"/sys/kernel/ged/hal/custom_upbound_gpu_freq "$R"/sys/kernel/ged/hal/custom_boost_gpu_freq \
           "$R"/sys/kernel/ged/hal/current_freqency "$R"/sys/kernel/debug/ged/hal/current_freqency; do
    [ -e "$f" ] && echo "${f#$R}: $(read1 "$f")  ($([ -w "$f" ] && echo rw || echo ro))"
  done
  echo "== gpufreq =="
  for f in gpufreq/gpufreq_opp_dump gpufreq/gpufreq_var_dump gpufreq/gpufreq_opp_freq gpufreqv2/gpu_working_opp_table; do
    [ -r "$R/proc/$f" ] && { echo "-- proc/$f"; head -n 40 "$R/proc/$f"; }
  done
  echo "== devfreq (kbase) =="
  for d in "$R"/sys/class/devfreq/*; do
    [ -d "$d" ] || continue
    case "${d##*/}" in *mali*|*gpu*|*g3d*|*kgsl*|*adreno*|*rogue*|*rgx*|*pvr*|*sgx*|*imgtec*) echo "${d##*/}: cur=$(read1 $d/cur_freq) min=$(read1 $d/min_freq) max=$(read1 $d/max_freq) governor=$(read1 $d/governor)"; echo "  tabel: $(cat $d/available_frequencies 2>/dev/null)" ;; esac
  done
  tb=$(oc_mtk_tbl_khz)
  echo "== hasil baca modul =="
  echo "tabel (kHz): $tb"
  echo "plafon efektif (kHz): $(oc_mtk_ceiling_khz $tb)"
  echo "clock nyata (kHz): $(oc_mtk_real_khz)"
  echo "override tersimpan (Hz): $(oc_conf_get GPU)"
  echo "== 15 baris log OVERCLOCK terakhir =="; grep OVERCLOCK "$LOG" 2>/dev/null | tail -n 15
}
