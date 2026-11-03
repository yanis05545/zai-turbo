#!/system/bin/sh
# =====================================================================
#  Zyrox - lib/modelock.sh   (v1.0.9-fix24)
#  Penguncian frekuensi CPU & GPU LANGSUNG per mode (balance/saver/gaming/
#  extreme), dipanggil dari system/bin/azenith-thermal (ml_apply <mode>).
#
#  Kenapa ini perlu: lib/perf.sh (level 0-5 / LV_CAP) cuma menaikkan LANTAI
#  frekuensi saat sebuah game TERDETEKSI berjalan (lib/fps.sh) - artinya
#  menekan tombol mode di WebUI di luar sesi game tidak terasa apa-apa di
#  clock. Modul ini membaca tabel OPP hasil scan yang SAMA (lib/scan.sh,
#  cpu_policies & GPU - lihat lib/overclock.sh) lalu menulis
#  scaling_min_freq/scaling_max_freq (CPU) dan node GPU (ceiling/floor)
#  SECARA LANGSUNG begitu mode dipilih, lewat oc_raw_write/oc_restore_path
#  (backup KHUSUS overclock.sh, bukan backup sesi game) - supaya kuncian ini
#  PERSISTEN seperti OC manual, tidak lenyap begitu game ditutup.
#
#  CPU (ml_cpu_apply) sudah sejak awal brand-agnostic - pakai cpufreq sysfs
#  standar (scaling_min_freq/max_freq) yang sama di semua SoC Android
#  (Qualcomm/MediaTek/Exynos/Unisoc/dst).
#
#  v1.0.9-fix24: GPU (ml_gpu_apply) dulu HANYA jalan di MediaTek. Sekarang
#  dipecah ke dua backend otomatis (lihat komentar di ml_gpu_apply) supaya
#  saver/gaming/extreme mengunci clock GPU juga di Qualcomm Adreno/kgsl,
#  Mali/Panfrost devfreq generik, dan Samsung Exynos - bukan cuma Helio/MTK.
#
#  v1.0.9-fix25: ml_apply() di atas dulu CUMA ditulis SEKALI saat tombol mode
#  ditekan - kalau daemon perf/thermal bawaan vendor menulis ulang node yang
#  sama beberapa detik kemudian (umum di banyak ROM), ceiling saver yang
#  sudah diturunkan "lepas" lagi tanpa modul tahu, jadi kelihatan CPU/GPU
#  tidak pernah turun kalau dicek belakangan. Ditambahkan ml_watch() (lihat
#  di bawah) yang dipanggil berkala oleh daemon (lib/daemon.sh), sama seperti
#  ps_watch() sudah lebih dulu menjaga Battery Saver Android - sekarang
#  CPU/GPU ikut dijaga tetap konsisten dengan mode aktif.
#
#  v1.0.9-fix26: dulu mode saver CUMA menarik ceiling (scaling_max_freq) ke
#  60% tabel - governor CPU/GPU tidak ikut disentuh, jadi kalau dicek pakai
#  app lain (Kernel Adiutor/CPU-Z/dst) atau tab Governor di WebUI sendiri,
#  governor masih kebaca "schedutil"/bawaan vendor, bukan governor hemat
#  daya. Ditambahkan ml_cpu_gov_apply()/ml_gpu_gov_apply(): saver sekarang
#  juga memaksa governor ke mode hemat daya, dan balance/gaming/extreme
#  mengembalikannya ke bawaan (atau ke override manual user di tab
#  Overclock -> Governor kalau ada). Ikut dijaga ulang oleh ml_watch() yang
#  sama seperti ceiling freq.
#
#  v1.0.9-fix27: urutan pilihan governor saver DIBALIK - "conservative" jadi
#  prioritas pertama, "powersave" jadi fallback (lihat catatan panjang di
#  ml_gov_pick_saver). "powersave" literal mengunci CPU di titik TERENDAH
#  tabel OPP terus-menerus (freq beku, HP bisa lag) - cocok untuk hemat daya
#  maksimal tapi kurang nyaman dipakai aktif; "conservative" tetap hemat
#  daya tapi freq masih bergerak wajar mengikuti beban.
#
#  Catatan jujur: ini bekerja di ATAS infrastruktur overclock.sh yang sudah
#  ada (unlock PPM/GED/kgsl, snap ke titik tabel OPP nyata, hormati OC manual
#  user kalau sedang diset lebih tinggi dari stock). Kalau kernel device
#  menjepit sebuah titik ke titik lain, itu keputusan kernel - sama seperti
#  catatan "DIBATASI tabel OPP kernel" di overclock.sh. Device tanpa node GPU
#  freq yang kebuka sama sekali (GPU_BACKEND=none dari hasil scan) tetap
#  dilewati untuk bagian GPU saja - CPU tetap jalan normal.
#
#  v1.0.9-fix35: diganti total dari skema persentase tabel (ML_PCT_SAVER/
#  ML_PCT_GAMING lama) ke ANGKA FREKUENSI TETAP (kHz) per cluster untuk
#  balance/saver/gaming, PLUS governor literal per mode, sesuai spesifikasi
#  eksplisit yang diminta untuk tiap mode:
#    balance    -> governor schedutil, cluster 0-5 = 1400MHz, cluster 6-7 = 1200MHz   (fix37)
#    saver      -> governor powersave, cluster 0-5 = 1200MHz, cluster 6-7 = 1100MHz   (fix37)
#    gaming     -> governor performance, cluster 0-5 = 1600MHz, cluster 6-7 = 1800MHz (fix37)
#    extreme    -> governor performance, TANPA BATAS (lihat ML_EXTREME_RAW_KHZ
#                  di bawah) - zet turbo sengaja mengabaikan tabel OPP hasil
#                  scan kita sendiri (yang bisa basi/belum sinkron setelah
#                  kernel/DTBO di-patch - lihat [[mt6789-gpu-overclock]]) dan
#                  langsung minta angka jauh di atas kHz mana pun yang
#                  realistis, supaya hasil akhirnya murni ditentukan oleh
#                  batas ASLI hardware/kernel saat itu juga, bukan oleh nilai
#                  "mltop" yang kita hitung sendiri dari scan yang mungkin
#                  sudah basi.
#  balance/saver/gaming masing-masing dikunci floor=ceiling=angka tetap
#  (bukan floor dilepas seperti skema lama) supaya clock NYATA benar-benar
#  duduk di angka yang diminta, bukan cuma jadi plafon yang masih bisa
#  dilepas turun oleh governor dinamis - tetap dijepit turun ke
#  cpuinfo_max_freq LIVE device ini sendiri (mlkmax) kalau device punya
#  batas asli di bawah angka yang diminta, supaya tidak menulis nilai yang
#  pasti ditolak kernel begitu saja.
# =====================================================================

ML_BAL_LOW=1400000      # kHz - balance, cluster core pertama 0-5
ML_BAL_HIGH=1200000     # kHz - balance, cluster core pertama 6-7
ML_SAVER_LOW=1200000    # kHz - saver, cluster core pertama 0-5
ML_SAVER_HIGH=1100000   # kHz - saver, cluster core pertama 6-7 (memang lebih
                         # rendah dari cluster 0-5 - diminta begitu persis)
ML_GAMING_CAP_LOW=1600000    # kHz - gaming, cluster core pertama 0-5
ML_GAMING_CAP_HIGH=1800000   # kHz - gaming, cluster core pertama 6-7

# ZAI-Turbo (extreme): angka RAW yang sengaja jauh melebihi kHz nyata
# device mana pun ada di pasaran sekarang - bukan target yang diharapkan
# benar-benar "diterima apa adanya", tapi SINYAL ke kernel lewat
# scaling_min_freq/scaling_max_freq supaya ditarik ke titik SETINGGI yang
# kernel/hardware ini sendiri masih izinkan saat itu juga (lihat oc_raw_write
# - readback setelah tulis otomatis membaca balik nilai NYATA yang kernel
# clamp sendiri). Dengan ini extreme TIDAK PERNAH dijepit oleh tabel OPP
# hasil scan kita (mlkmax/mltop) yang kita tahu bisa ketinggalan begitu
# kernel/DTBO device di-patch untuk buka titik di atas tabel stock.
ML_EXTREME_RAW_KHZ=9999999

# ---------------------------------------------------------------------
# v1.0.32: GPU per mode (frekuensi TETAP dalam kHz, sama pola dengan CPU):
#   balance -> ceiling GPU 1100 MHz
#   saver   -> ceiling GPU 1000 MHz
#   extreme (ZAI-Turbo) -> TANPA BATAS: plafon dilepas total + floor dikunci ke
#                          titik tertinggi yang ada (puncak tabel OPP, atau titik
#                          overclock kalau GPU sudah di-OC / kernel di-patch).
# Angka dijepit ke titik tabel OPP NYATA terdekat yang <= target (tidak pernah
# di atas angka yang diminta), dan kalau puncak tabel device lebih rendah dari
# target maka plafon = puncak tabel (artinya tidak ada batas efektif).
# ML_GPU_PIN_FLOOR=0 -> HANYA ceiling yang dikunci, floor dilepas supaya GPU
# tetap boleh turun saat idle (hemat baterai). Ubah ke 1 kalau ingin floor =
# ceiling (GPU dikunci mati di angka itu terus-menerus, seperti CPU).
# ---------------------------------------------------------------------
ML_GPU_BAL_KHZ=1100000
ML_GPU_SAVER_KHZ=1000000
ML_GPU_PIN_FLOOR=0

# ml_gpu_target_khz <mode> -> kHz target ceiling (kosong = tidak ada angka tetap)
ml_gpu_target_khz() {
  case "$1" in
    balance) echo "$ML_GPU_BAL_KHZ" ;;
    saver)   echo "$ML_GPU_SAVER_KHZ" ;;
    *)       echo "" ;;
  esac
}

# ml_mtk_cap <khz | 0>  -> tulis plafon GED MediaTek (0 / >= puncak tabel = lepas).
# Satuan per node benar (module-param = kHz, debugfs/hal = INDEKS OPP, lihat
# catatan fix3 di oc_gpu_set_mtk). TIDAK menyentuh overclock.conf (GPU/GPUMIN):
# itu milik OC manual user, bukan milik mode.
ml_mtk_cap() {
  mmc_khz=$1
  mmc_t=$(oc_mtk_tbl_khz)
  [ -n "$mmc_t" ] || return 1
  set -- $mmc_t
  mmc_lo=$1; shift $(( $# - 1 )); mmc_top=$1
  if [ "$mmc_khz" = 0 ] || [ "$mmc_khz" -ge "$mmc_top" ] 2>/dev/null; then
    mmc_snap=$mmc_top; mmc_w=0
  else
    mmc_snap=$(oc_snap_tbl "$mmc_khz" $mmc_t)
    [ -n "$mmc_snap" ] || mmc_snap=$mmc_lo      # target di bawah titik terendah
    mmc_w=$mmc_snap
  fi
  mmc_idx=$(oc_khz_to_idx "$mmc_snap" $mmc_t)
  mmc_tgt=$(oc_ged_up_path) || return 1
  [ -n "$mmc_tgt" ] || return 1
  if [ "$mmc_tgt" = "$OC_GED_HAL_UP" ]; then mmc_wt=$mmc_idx; else mmc_wt=$mmc_w; fi
  oc_raw_write "$mmc_tgt" "$mmc_wt" >/dev/null 2>&1
  [ -e "$OC_GED_UP" ] && [ "$mmc_tgt" != "$OC_GED_UP" ] && oc_raw_write "$OC_GED_UP" "$mmc_w" >/dev/null 2>&1
  [ -e "$OC_GED_HAL_UP" ] && [ "$mmc_tgt" != "$OC_GED_HAL_UP" ] && oc_raw_write "$OC_GED_HAL_UP" "$mmc_idx" >/dev/null 2>&1
  echo "$mmc_snap" > "$RUNDIR/ml_gpu_cap" 2>/dev/null
  return 0
}

# ML_PCT_SAVER/ML_PCT_GAMING: skema persentase tabel LAMA - CPU (ml_cpu_apply
# di atas) sudah TIDAK memakainya lagi sejak fix35 (lihat atas), tapi masih
# dipakai apa adanya oleh sisi GPU (ml_gpu_apply_mtk/ml_gpu_apply_generic di
# bawah) karena permintaan fix35 cuma eksplisit menyebut "freq cpu" per mode
# - GPU saver/gaming sengaja TIDAK diubah, tetap ceiling/floor % dari tabel
# OPP GPU seperti sebelumnya.
ML_PCT_SAVER=60      # saver: ceiling GPU ditarik ke titik ini (% dari tabel)
ML_PCT_GAMING=72     # gaming: floor GPU dinaikkan ke titik ini (% dari tabel)

# ml_pick_pct <pct 0-100> <tabel...>  -> nilai tabel pada persentil ini
# (0% = titik terendah, 100% = titik tertinggi tabel) - dipakai GPU saja
# sekarang (lihat catatan ML_PCT_SAVER/ML_PCT_GAMING di atas)
ml_pick_pct() {
  mp_pct=$1; shift
  mp_n=$#
  [ "$mp_n" -ge 1 ] || { echo ""; return; }
  mp_idx=$(( (mp_n - 1) * mp_pct / 100 ))
  [ "$mp_idx" -ge "$mp_n" ] && mp_idx=$((mp_n - 1))
  [ "$mp_idx" -lt 0 ] && mp_idx=0
  nth_word $((mp_idx + 1)) "$@"
}

# ml_cluster_pick <core_pertama_cluster_ini> <nilai_cluster_0-5> <nilai_cluster_6-7>
# Dipakai untuk balance/saver/gaming - pembagian cluster sama persis seperti
# ML_GAMING_CAP_LOW/HIGH sejak awal (core pertama 0-5 vs 6-7, dibaca dari
# related_cpus policy ini).
ml_cluster_pick() {
  case "$1" in
    0|1|2|3|4|5) echo "$2" ;;
    *)           echo "$3" ;;
  esac
}

# ml_lock_cpu_freq <policy_path> <target_khz> <device_min_khz>
# Mengunci scaling_min_freq=scaling_max_freq=target_khz dengan URUTAN AMAN,
# terlepas dari arah transisi (naik dari mode sebelumnya yang lebih rendah,
# atau TURUN dari mode sebelumnya yang lebih tinggi - mis. dari
# gaming/extreme yang menguncinya tinggi, pindah ke saver yang lebih
# rendah). Banyak driver cpufreq menolak tulis scaling_max_freq kalau
# hasilnya < scaling_min_freq yang SEDANG berlaku saat itu (begitu juga
# sebaliknya) - kalau langsung menulis ceiling baru yang lebih rendah
# sementara floor lama masih lebih tinggi, tulisan itu bisa ditolak kernel.
# Jadi: lepas floor ke titik PALING RENDAH device dulu (supaya floor pasti
# <= ceiling apa pun yang mau ditulis setelah ini), baru set ceiling ke
# target, baru naikkan floor ke target yang sama persis (floor<=ceiling
# selalu terjaga di tiap langkah).
ml_lock_cpu_freq() { # ml_lock_cpu_freq <policy> <target_khz> <device_min_khz> [core_pertama] [nilai_yg_diharapkan]
  mlk_p=$1; mlk_tgt=$2; mlk_devmin=$3; mlk_first=$4; mlk_exp=${5:-$2}
  # fix37: DULU hanya 1x tulis tanpa cek hasil akhir, dan node debug DVFS MTK
  # (/proc/cpudvfs/cpufreq_debug) cuma ditulis ke target baru - kalau node itu
  # sedang mengunci ke angka mode SEBELUMNYA (min=max=angka lama), rentang
  # sempit itu menjepit tulisan sysfs baru, hasilnya freq "nyangkut" di mode
  # lama (kecuali ZAI-Turbo yang kebetulan membuka lebar dulu). Sekarang
  # SEMUA mode: (1) LEBARKAN node debug dulu (devmin..RAW), (2) tulis sysfs
  # floor->ceiling->floor, (3) kunci node debug ke target, (4) BACA ULANG
  # min & max; kalau belum sama dengan yang diharapkan, ulangi sampai 4x.
  mlk_try=0; mlk_dbg=0
  [ -n "$mlk_first" ] && oc_cpudvfs_debug_on && mlk_dbg=1
  while [ "$mlk_try" -lt 4 ]; do
    [ "$mlk_dbg" = 1 ] && { echo "$mlk_first $mlk_devmin $ML_EXTREME_RAW_KHZ" > "$OC_CPUDVFS_DEBUG"; } 2>/dev/null
    oc_raw_write "$mlk_p/scaling_min_freq" "$mlk_devmin" >/dev/null 2>&1
    oc_raw_write "$mlk_p/scaling_max_freq" "$mlk_tgt" >/dev/null 2>&1
    oc_raw_write "$mlk_p/scaling_min_freq" "$mlk_tgt" >/dev/null 2>&1
    [ "$mlk_dbg" = 1 ] && { echo "$mlk_first $mlk_tgt $mlk_tgt" > "$OC_CPUDVFS_DEBUG"; } 2>/dev/null
    mlk_gmax=$(read1 "$mlk_p/scaling_max_freq"); mlk_gmin=$(read1 "$mlk_p/scaling_min_freq")
    { [ "$mlk_gmax" = "$mlk_exp" ] || [ "$mlk_gmax" = "$mlk_tgt" ]; } && { [ "$mlk_gmin" = "$mlk_exp" ] || [ "$mlk_gmin" = "$mlk_tgt" ]; } && break
    mlk_try=$((mlk_try + 1))
    sleep 0.3 2>/dev/null
  done
  echo "$mlk_p|$mlk_exp" >> "$RUNDIR/ml_targets" 2>/dev/null
  [ "$mlk_gmax" = "$mlk_exp" ] || log_msg "MODELOCK: $mlk_p max diminta=$mlk_exp hasil=$mlk_gmax (setelah $((mlk_try)) percobaan)"
}

# ml_snap_opp <policy> <khz> -> titik OPP NYATA terdekat (seri: yang lebih rendah)
ml_snap_opp() {
  msp_t=$(read1 "$1/scaling_available_frequencies")
  [ -n "$msp_t" ] || { echo "$2"; return; }
  msp_b=""; msp_bd=2000000000
  for msp_f in $msp_t; do
    case "$msp_f" in ''|*[!0-9]*) continue ;; esac
    if [ "$msp_f" -ge "$2" ]; then msp_d=$((msp_f - $2)); else msp_d=$(($2 - msp_f)); fi
    if [ "$msp_d" -lt "$msp_bd" ] || { [ "$msp_d" -eq "$msp_bd" ] && [ "$msp_f" -lt "$msp_b" ]; }; then msp_b=$msp_f; msp_bd=$msp_d; fi
  done
  echo "${msp_b:-$2}"
}

# ---------------------------------------------------------------------
# CPU: per cluster, atur scaling_min_freq (floor) & scaling_max_freq (ceiling)
# ---------------------------------------------------------------------
ml_cpu_apply() { # ml_cpu_apply <mode>
  mlc_mode=$1
  mlc_n=$(oc_cpu_count)
  [ "$mlc_n" -ge 1 ] || return 0
  mlc_i=1
  while [ "$mlc_i" -le "$mlc_n" ]; do
    mlc_line=$(oc_cpu_line "$mlc_i")
    IFS='|' read -r mln mlp mlmin mlmax mlw mlt <<EOF
$mlc_line
EOF
    [ -n "$mlp" ] || { mlc_i=$((mlc_i + 1)); continue; }
    # cluster yang SEMUA core-nya dimatikan (lib/cpucore.sh) tidak punya policy
    # cpufreq aktif - dilewati, bukan ditulis berulang sampai gagal.
    [ -d "$mlp" ] || { mlc_i=$((mlc_i + 1)); continue; }
    mlkmax=$(read1 "$mlp/cpuinfo_max_freq"); mlkmax=${mlkmax:-$mlmax}
    mlkmin=$(read1 "$mlp/cpuinfo_min_freq"); mlkmin=${mlkmin:-$mlmin}
    # v1.0.9-fix35: keempat mode sekarang pakai angka TETAP (balance/saver/
    # gaming) atau RAW tanpa batas (extreme/ZAI-Turbo) - bukan lagi
    # "stock atau OC manual user" seperti skema lama, jadi oc_conf_get
    # "CPU$mlc_i" (override OC manual) sudah tidak dipakai di sini lagi.
    # core pertama cluster ini (related_cpus) - dipakai untuk pilih angka
    # tetap per cluster (balance/saver/gaming, lihat ml_cluster_pick di atas)
    mlc_cores=$(read1 "$mlp/related_cpus")
    set -- $mlc_cores
    mlc_first=${1:-0}
    # fix37: lepas batas vendor (PPM userlimit dll) di SEMUA mode - dulu cuma
    # ZAI-Turbo, jadi mode lain bisa terjepit sisa limit dari mode lain.
    oc_unlock_cpu "$mlc_i" "$mlp" >/dev/null 2>&1
    case "$mlc_mode" in
      balance) mlc_t=$(ml_cluster_pick "$mlc_first" "$ML_BAL_LOW" "$ML_BAL_HIGH") ;;
      saver)   mlc_t=$(ml_cluster_pick "$mlc_first" "$ML_SAVER_LOW" "$ML_SAVER_HIGH") ;;
      gaming)  mlc_t=$(ml_cluster_pick "$mlc_first" "$ML_GAMING_CAP_LOW" "$ML_GAMING_CAP_HIGH") ;;
      extreme)
        [ "$mlc_i" = 1 ] && { oc_unlock_dvfsrc >/dev/null 2>&1; oc_unlock_thermal_mtk >/dev/null 2>&1; }
        mlc_t=$ML_EXTREME_RAW_KHZ ;;
    esac
    if [ "$mlc_mode" = extreme ]; then
      # target RAW -> kernel menjepit ke batas nyata; yang diharapkan = cpuinfo_max LIVE
      ml_lock_cpu_freq "$mlp" "$mlc_t" "$mlkmin" "$mlc_first" "$mlkmax"
    else
      [ "$mlc_t" -gt "$mlkmax" ] 2>/dev/null && mlc_t=$mlkmax
      mlc_t=$(ml_snap_opp "$mlp" "$mlc_t")
      ml_lock_cpu_freq "$mlp" "$mlc_t" "$mlkmin" "$mlc_first"
    fi
    mlc_i=$((mlc_i + 1))
  done
  log_msg "MODELOCK: cpu mode=$mlc_mode diterapkan ke $mlc_n cluster"
}

# ---------------------------------------------------------------------
# GPU: ceiling (upbound) & floor (boost) per mode.
#
# v1.0.9-fix24: dulu HANYA jalan di MediaTek (GED/gpufreq) - device non-MTK
# (Qualcomm Adreno/kgsl, Mali/Panfrost devfreq generik, Samsung Exynos) sama
# sekali dilewati ("non-MTK dilewati di sini"), jadi saver/gaming/extreme
# TIDAK mengunci clock GPU sama sekali di luar MediaTek, walau CPU tetap
# jalan di semua merk. Sekarang DIPECAH jadi dua jalur, dipilih otomatis
# berdasar hasil scan device (sama seperti oc_gpu_set/oc_gpu_set_min di
# lib/overclock.sh yang sudah lebih dulu mendukung kedua jalur ini untuk OC
# manual):
#   - oc_mtk_on()=true  -> ml_gpu_apply_mtk  (GED/gpufreq, node devfreq kbase
#     di MTK cuma "bayangan" - lihat catatan panjang oc_mtk_on di overclock.sh)
#   - sisanya (GPU_BACKEND devfreq ATAU exynos_kgpu dari hasil scan) ->
#     ml_gpu_apply_generic, tulis LANGSUNG ke node min/max_freq hasil scan
#     (satuan node dikonversi ke Hz lewat oc_gpu_mul, sama seperti fungsi OC
#     manual, supaya perhitungan plafon OC user & persentase mode konsisten)
#   - GPU_BACKEND=none (device tanpa node GPU freq yang kebuka) -> dilewati,
#     sama seperti sebelumnya (tidak ada yang bisa ditulis)
# Backup/restore tetap lewat oc_raw_write/oc_restore_path (backup KHUSUS
# overclock.sh) di KEDUA jalur, supaya tetap PERSISTEN seperti OC manual dan
# tidak menimpa oc_conf_get GPU/GPUMIN (nilai OC manual tersimpan user).
# ---------------------------------------------------------------------
ml_gpu_apply() { # ml_gpu_apply <mode>
  if oc_mtk_on; then ml_gpu_apply_mtk "$1"; else ml_gpu_apply_generic "$1"; fi
}

ml_gpu_apply_mtk() { # ml_gpu_apply_mtk <mode>  (MediaTek GED/gpufreq)
  mlg_mode=$1
  mlgt=$(oc_mtk_tbl_khz)
  [ -n "$mlgt" ] || return 0
  set -- $mlgt
  mlglo=$1
  mlgn=$#
  shift $(( mlgn - 1 ))
  mlgtop=$1
  mlgov=$(oc_conf_get GPU 2>/dev/null)
  mlgovk=""
  case "$mlgov" in ''|*[!0-9]*) ;; *) mlgovk=$((mlgov / 1000)) ;; esac
  mlgceil=$mlgtop
  [ -n "$mlgovk" ] && [ "$mlgovk" -gt "$mlgceil" ] 2>/dev/null && mlgceil=$mlgovk
  oc_unlock_gpu >/dev/null 2>&1
  case "$mlg_mode" in
    balance|saver)
      mlgx=$(ml_gpu_target_khz "$mlg_mode")
      # floor dilepas dulu supaya floor lama (mis. dari ZAI-Turbo) tidak
      # menjepit plafon baru yang lebih rendah
      oc_gpu_set_mtk_floor 0 >/dev/null 2>&1
      ml_mtk_cap "$mlgx"
      if [ "$ML_GPU_PIN_FLOOR" = 1 ]; then
        mlgf=$(oc_snap_tbl "$mlgx" $mlgt); [ -n "$mlgf" ] || mlgf=$mlglo
        oc_gpu_set_mtk_floor $((mlgf * 1000)) >/dev/null 2>&1
      fi
      ;;
    gaming)
      mlgf=$(ml_pick_pct "$ML_PCT_GAMING" $mlgt)
      [ -n "$mlgf" ] || mlgf=$mlglo
      [ "$mlgf" -gt "$mlgceil" ] 2>/dev/null && mlgf=$mlgceil
      ml_mtk_cap 0
      oc_gpu_set_mtk_floor $((mlgf * 1000)) >/dev/null
      ;;
    extreme)
      # TANPA BATAS: plafon dilepas (0 = puncak tabel/OC), floor dikunci ke puncak
      ml_mtk_cap 0
      oc_gpu_set_mtk_floor $((mlgceil * 1000)) >/dev/null
      ;;
  esac
  mlgcap=$(oc_mtk_ceiling_khz $mlgt)
  log_msg "MODELOCK: gpu(mtk) mode=$mlg_mode diterapkan (puncak tabel ${mlgtop}kHz, plafon terbaca ${mlgcap:-?}kHz)"
}

# ml_gpu_apply_generic <mode>  (Qualcomm Adreno/kgsl, Mali/Panfrost devfreq
# generik, Samsung Exynos kgpu - backend devfreq/exynos_kgpu dari scan.sh)
# Tulis LANGSUNG ke node min_freq/max_freq (atau nama node hasil scan)
# dengan satuan node asli (sama seperti ml_gpu_apply_mtk pakai kHz langsung
# ke tabel GED), dikonversi ke/dari Hz hanya untuk membandingkan dengan
# oc_conf_get GPU (yang tersimpan dalam Hz) lewat oc_gpu_mul - fungsi yang
# sama dipakai oc_gpu_set/oc_gpu_set_min untuk OC manual di overclock.sh.
ml_gpu_apply_generic() { # ml_gpu_apply_generic <mode>
  mlg_mode=$1
  [ -s "$SCANDIR/gpu" ] || return 0
  IFS='|' read -r mlgb mlgp mlgminn mlgmaxn < "$SCANDIR/gpu" 2>/dev/null
  case "$mlgb" in devfreq|exynos_kgpu) ;; *) return 0 ;; esac
  [ -n "$mlgp" ] && [ -e "$mlgp/$mlgmaxn" ] || return 0
  mlgt=""
  [ -r "$mlgp/available_frequencies" ] && mlgt=$({ tbl_sort < "$mlgp/available_frequencies"; } 2>/dev/null)
  [ -n "$mlgt" ] || mlgt=$(cat "$SCANDIR/gpu_tbl" 2>/dev/null)
  [ -n "$mlgt" ] || return 0
  set -- $mlgt
  mlglo=$1
  mlgn=$#
  shift $(( mlgn - 1 ))
  mlgtop=$1
  mlgcur0=$(read1 "$mlgp/$mlgmaxn")
  mlgmul=$(oc_gpu_mul "$mlgb" "$mlgtop" "$mlgcur0")
  mlgceil=$mlgtop
  mlgovhz=$(oc_conf_get GPU 2>/dev/null)
  case "$mlgovhz" in
    ''|*[!0-9]*) ;;
    *) mlgovn=$((mlgovhz / mlgmul)); [ "$mlgovn" -gt "$mlgceil" ] 2>/dev/null && mlgceil=$mlgovn ;;
  esac
  # sama seperti oc_gpu_set() manual: lepas kunci power-level vendor (mis.
  # Qualcomm kgsl max_pwrlevel) dulu supaya tulisan max_freq/min_freq di
  # bawah benar-benar dihormati, bukan ditimpa balik oleh throttle vendor.
  oc_unlock_gpu >/dev/null 2>&1
  case "$mlg_mode" in
    balance|saver)
      # target tetap (Hz) -> satuan node -> titik tabel terdekat yang <= target
      mlgx=$(ml_gpu_target_khz "$mlg_mode")
      mlgxn=$(( mlgx * 1000 / mlgmul ))
      mlgf=$(oc_snap_tbl "$mlgxn" $mlgt)
      [ -n "$mlgf" ] || mlgf=$mlglo
      [ "$mlgf" -gt "$mlgtop" ] 2>/dev/null && mlgf=$mlgtop
      # floor dilepas ke bawaan dulu (floor lama tidak boleh > plafon baru)
      oc_restore_path "$mlgp/$mlgminn" >/dev/null 2>&1
      oc_raw_write "$mlgp/$mlgmaxn" "$mlgf" >/dev/null
      [ "$ML_GPU_PIN_FLOOR" = 1 ] && oc_raw_write "$mlgp/$mlgminn" "$mlgf" >/dev/null
      echo "$mlgf" > "$RUNDIR/ml_gpu_cap" 2>/dev/null
      ;;
    gaming)
      mlgf=$(ml_pick_pct "$ML_PCT_GAMING" $mlgt)
      [ -n "$mlgf" ] || mlgf=$mlglo
      [ "$mlgf" -gt "$mlgceil" ] 2>/dev/null && mlgf=$mlgceil
      oc_raw_write "$mlgp/$mlgmaxn" "$mlgceil" >/dev/null
      oc_raw_write "$mlgp/$mlgminn" "$mlgf" >/dev/null
      ;;
    extreme)
      # TANPA BATAS: plafon = titik tertinggi (puncak tabel, atau titik OC
      # manual user kalau GPU sudah di-overclock lebih tinggi), floor = plafon
      oc_raw_write "$mlgp/$mlgmaxn" "$mlgceil" >/dev/null
      oc_raw_write "$mlgp/$mlgminn" "$mlgceil" >/dev/null
      echo "$mlgceil" > "$RUNDIR/ml_gpu_cap" 2>/dev/null
      ;;
  esac
  log_msg "MODELOCK: gpu($mlgb) mode=$mlg_mode diterapkan (tabel puncak ${mlgtop}, ceiling efektif ${mlgceil}, satuan-node x${mlgmul})"
}

# ---------------------------------------------------------------------
# Governor CPU/GPU per mode (lihat juga catatan ml_watch di bawah - dipanggil
# ulang berkala jadi efeknya PERSISTEN, bukan cuma sesaat).
#
#  saver  -> governor power-saving ASLI kernel - BUKAN cuma ceiling freq
#            yang ditarik turun ke 60% tabel seperti sebelumnya: itu masih
#            bisa kebaca "schedutil" biasa di app lain (Kernel Adiutor/
#            CPU-Z/dst) kalau cuma plafonnya yang berubah. Governor-nya
#            sendiri sekarang ikut dipaksa ke mode hemat daya supaya saat
#            DICEK di mana pun (termasuk tab Governor di sini), hasilnya
#            konsisten dengan mode saver, bukan cuma ceiling yang turun.
#
#            v1.0.9-fix27: prioritas DIBALIK jadi "conservative" dulu, baru
#            fallback "powersave". Sebab: "powersave" literal mengunci CPU
#            TERUS di titik PALING RENDAH tabel OPP apa pun bebannya (freq
#            di Scene/app lain kelihatan beku di satu angka rendah, HP bisa
#            lag karena CPU tidak pernah naik walau dibutuhkan) - itu
#            perilaku resmi governor ini, bukan bug, tapi kurang nyaman
#            dipakai harian. "conservative" tetap governor hemat daya (naik
#            bertahap mengikuti beban, bukan langsung lompat seperti
#            schedutil/ondemand) jadi freq TETAP bergerak wajar sesuai
#            pemakaian - lebih nyaman tapi tetap lebih hemat dari governor
#            bawaan. "powersave" dipakai HANYA kalau "conservative" tidak
#            tersedia di device ini.
#  balance/gaming/extreme -> kembali ke governor bawaan kernel (restore dari
#            backup OC), KECUALI user sudah punya override governor MANUAL
#            tersimpan (GOVCPU<idx>/GOVGPU di tab Overclock -> Governor) -
#            itu tetap dihormati, persis seperti ceiling freq menghormati
#            override OC manual CPU<idx>/GPU di ml_cpu_apply/ml_gpu_apply.
#
#  v1.0.9-fix35: governor per mode sekarang EKSPLISIT diminta, jadi diganti
#  dari "restore ke bawaan kernel" jadi governor literal untuk balance &
#  saver juga (gaming/extreme tetap "performance" seperti sebelumnya):
#    balance -> "schedutil" (governor berbasis scheduler/CFS - diminta
#               sebagai "schedule"), baru fallback ke override manual user
#               lalu restore bawaan kalau device ini tidak punya schedutil
#    saver   -> "powersave" literal JADI PRIORITAS PERTAMA (dibalik dari
#               urutan fix27 lama yang mendahulukan "conservative" demi
#               kenyamanan harian) - diminta eksplisit "saver gov
#               powersaver", "conservative" sekarang cuma fallback kalau
#               device ini tidak punya governor "powersave" sama sekali
#
# Ditulis LANGSUNG ke node via oc_raw_write/oc_restore_path (backup KHUSUS
# OC yang sama dipakai ceiling freq) - BUKAN lewat oc_cpu_set_governor()/
# GOVCPU<idx> (itu konf override MANUAL permanen milik user, dengan tombol
# "Kembalikan bawaan" sendiri di tab Overclock) - supaya pilihan manual user
# di situ tidak diam-diam tertimpa/terhapus tiap kali mode WebUI ditekan;
# hanya DIBACA sebagai fallback kalau governor literal mode ini sendiri
# tidak tersedia di device.
# ---------------------------------------------------------------------
ml_gov_pick_saver() { # ml_gov_pick_saver <daftar governor tersedia...> -> governor terpilih (kosong kalau tidak ada yang cocok)
  for mgp_want in powersave conservative; do
    oc_gov_valid "$mgp_want" "$@" && { echo "$mgp_want"; return; }
  done
  echo ""
}

ml_gov_pick_balance() { # ml_gov_pick_balance <daftar governor tersedia...> -> governor terpilih (kosong kalau tidak ada yang cocok)
  for mgp_want in schedutil interactive ondemand; do
    oc_gov_valid "$mgp_want" "$@" && { echo "$mgp_want"; return; }
  done
  echo ""
}

ml_cpu_gov_apply() { # ml_cpu_gov_apply <mode>
  mgc_mode=$1
  mgc_n=$(oc_cpu_count)
  [ "$mgc_n" -ge 1 ] || return 0
  mgc_i=1
  while [ "$mgc_i" -le "$mgc_n" ]; do
    mgc_line=$(oc_cpu_line "$mgc_i")
    IFS='|' read -r mgcn mgcp _ _ _ _ <<EOF
$mgc_line
EOF
    [ -n "$mgcp" ] || { mgc_i=$((mgc_i + 1)); continue; }
    mgcgp="$mgcp/scaling_governor"
    [ -e "$mgcgp" ] || { mgc_i=$((mgc_i + 1)); continue; }
    mgcovr=$(oc_conf_get "GOVCPU$mgc_i" 2>/dev/null)
    case "$mgc_mode" in
      saver)
        mgcavail=$(read1 "$mgcp/scaling_available_governors")
        mgcpick=$(ml_gov_pick_saver $mgcavail)
        [ -n "$mgcpick" ] && oc_raw_write "$mgcgp" "$mgcpick" >/dev/null
        ;;
      gaming|extreme)
        # Gaming & ZAI-Turbo: paksa governor literal "performance" kalau
        # device ini punya governor itu. Governor ini sendiri yang mendorong
        # clock ke scaling_max_freq - konsisten dengan ceiling yang sudah
        # ditulis ml_cpu_apply di atas (cap tetap buat gaming, puncak tabel
        # buat extreme).
        mgcavail=$(read1 "$mgcp/scaling_available_governors")
        if oc_gov_valid performance $mgcavail; then
          oc_raw_write "$mgcgp" performance >/dev/null
        elif [ -n "$mgcovr" ]; then
          oc_raw_write "$mgcgp" "$mgcovr" >/dev/null
        else
          oc_restore_path "$mgcgp" >/dev/null 2>&1
        fi
        ;;
      balance)
        # "jadi schedule" - paksa governor literal "schedutil" (atau
        # interactive/ondemand di device lama tanpa schedutil) kalau
        # tersedia; fallback ke override manual user lalu restore bawaan
        # kalau sama sekali tidak ada yang cocok di device ini.
        mgcavail=$(read1 "$mgcp/scaling_available_governors")
        mgcpick=$(ml_gov_pick_balance $mgcavail)
        if [ -n "$mgcpick" ]; then
          oc_raw_write "$mgcgp" "$mgcpick" >/dev/null
        elif [ -n "$mgcovr" ]; then
          oc_raw_write "$mgcgp" "$mgcovr" >/dev/null
        else
          oc_restore_path "$mgcgp" >/dev/null 2>&1
        fi
        ;;
    esac
    mgc_i=$((mgc_i + 1))
  done
  log_msg "MODELOCK: governor cpu mode=$mgc_mode diterapkan ke $mgc_n cluster"
}

# GPU: hanya devfreq non-MTK yang punya node governor nyata (lihat
# oc_gpu_gov_eligible di lib/overclock.sh - di MediaTek node governor cuma
# "bayangan", tidak menggerakkan clock, jadi dilewati sama sekali di sana).
ml_gpu_gov_apply() { # ml_gpu_gov_apply <mode>
  oc_gpu_gov_eligible || return 0
  mgg_mode=$1
  IFS='|' read -r _ mggp _ _ < "$SCANDIR/gpu" 2>/dev/null
  [ -n "$mggp" ] && [ -e "$mggp/governor" ] || return 0
  mggovr=$(oc_conf_get GOVGPU 2>/dev/null)
  case "$mgg_mode" in
    saver)
      mggavail=$(read1 "$mggp/available_governors")
      mggpick=$(ml_gov_pick_saver $mggavail)
      [ -n "$mggpick" ] && oc_raw_write "$mggp/governor" "$mggpick" >/dev/null
      ;;
    gaming|extreme)
      mggavail=$(read1 "$mggp/available_governors")
      if oc_gov_valid performance $mggavail; then
        oc_raw_write "$mggp/governor" performance >/dev/null
      elif [ -n "$mggovr" ]; then
        oc_raw_write "$mggp/governor" "$mggovr" >/dev/null
      else
        oc_restore_path "$mggp/governor" >/dev/null 2>&1
      fi
      ;;
    balance)
      if [ -n "$mggovr" ]; then
        oc_raw_write "$mggp/governor" "$mggovr" >/dev/null
      else
        oc_restore_path "$mggp/governor" >/dev/null 2>&1
      fi
      ;;
  esac
}

# ---------------------------------------------------------------------
# Titik masuk tunggal dipanggil azenith-thermal. Memastikan scan sudah ada
# (device baru boot / belum pernah dibuka WebUI) sebelum membaca tabel.
# Governor diterapkan SETELAH ceiling/floor freq (ml_cpu_apply/ml_gpu_apply)
# supaya kalau governor power-saving langsung menjepit clock ke scaling_min
# yang baru, nilai min yang dipakai sudah hasil mode ini, bukan bawaan lama.
# ---------------------------------------------------------------------
ml_apply() { # ml_apply balance|saver|gaming|extreme
  case "$1" in balance|saver|gaming|extreme) ;; *) return 1 ;; esac
  : > "$RUNDIR/oc_writes"; : > "$RUNDIR/oc_rejected"; : > "$RUNDIR/ml_targets"
  scan_if_needed >/dev/null 2>&1
  # fix30: scan_if_needed cuma pakai cache KALAU ADA - device yang baru boot
  # pertama kali / cache scan kosong/korup bikin oc_cpu_count=0, seluruh loop
  # ml_cpu_apply/ml_gpu_apply tidak pernah jalan sama sekali (0 iterasi, tidak
  # error, cuma diam) - PERSIS gejala "pindah mode tidak ada yang berubah".
  # Dipaksa scan_all() SEKALI kalau tabel kosong, baru menyerah kalau tetap 0.
  if [ "$(oc_cpu_count)" -eq 0 ]; then
    log_msg "MODELOCK: cpu_policies kosong, paksa scan_all() ulang sebelum apply mode=$1"
    scan_all >/dev/null 2>&1
  fi
  if [ "$(oc_cpu_count)" -eq 0 ]; then
    echo "PERINGATAN: tidak ada node cpufreq terdeteksi di device ini (scan gagal) - CPU/GPU TIDAK bisa dikunci."
    echo "            Coba: su -c \"azenith-ai kernel scan\" lalu cek hasilnya, atau su -c \"azenith-ai doctor\"."
    log_msg "MODELOCK: GAGAL total mode=$1 - oc_cpu_count=0 bahkan setelah scan_all()"
    flog MODELOCK ERR "mode=$1 gagal total: tidak ada node cpufreq terdeteksi (scan gagal), CPU/GPU tidak bisa dikunci"
    return 1
  fi
  ml_cpu_apply "$1"
  ml_gpu_apply "$1"
  ml_cpu_gov_apply "$1"
  ml_gpu_gov_apply "$1"
  ml_report "$1"
  ml_ok=$(grep -c '^ok' "$RUNDIR/oc_writes" 2>/dev/null); ml_ok=${ml_ok:-0}
  ml_rj=$(grep -c '^rej' "$RUNDIR/oc_rejected" 2>/dev/null); ml_rj=${ml_rj:-0}
  if [ "$ml_rj" -gt 0 ] 2>/dev/null && [ "$ml_ok" -eq 0 ] 2>/dev/null; then
    flog MODELOCK ERR "mode=$1: SEMUA tulisan ditolak kernel (ditolak=$ml_rj, ok=0) - frekuensi tidak berubah"
  elif [ "$ml_rj" -gt 0 ] 2>/dev/null; then
    flog MODELOCK BUG "mode=$1 diterapkan sebagian: ok=$ml_ok ditolak=$ml_rj (node ditolak ada di $RUNDIR/oc_rejected)"
  else
    flog MODELOCK OK "mode=$1 diterapkan: ok=$ml_ok ditolak=0, semua nilai terverifikasi read-back"
  fi
}

# ml_report <mode> - ringkasan NYATA hasil apply (bukan cuma "sudah dicoba
# tulis"): baca ulang tiap node sesudah ml_cpu_apply/ml_gpu_apply/gov_apply
# selesai, bandingkan dengan oc_writes (berhasil terverifikasi readback)
# vs oc_rejected (ditolak kernel) yang dicatat oc_raw_write (lib/overclock.sh).
# mr_disp_freq <raw> <kmin> <kmax> -> nilai yang AMAN ditampilkan: raw dijepit
# ke batas hardware nyata (cpuinfo_min_freq/cpuinfo_max_freq) kalau raw itu
# sentinel internal (mis. ML_EXTREME_RAW_KHZ=9999999 milik mode extreme) yang
# jauh di luar kemampuan hardware - jadi yang tampil adalah frekuensi OC yang
# BENAR-BENAR berlaku, bukan angka sinyal mentah yang tidak berarti sebagai
# output. Dibaca-apa-adanya kalau raw masih di dalam batas wajar (balance/
# saver/gaming selalu begitu, extreme pun begitu di kernel yang mengkliping
# sendiri scaling_max_freq-nya saat ditulis).
mr_disp_freq() { # mr_disp_freq <raw> <kmin> <kmax>
  mrd_v=$1; mrd_mn=$2; mrd_mx=$3
  case "$mrd_v" in ''|*[!0-9]*) echo "$mrd_v"; return ;; esac
  [ -n "$mrd_mx" ] && case "$mrd_mx" in *[!0-9]*) ;; *) [ "$mrd_v" -gt "$mrd_mx" ] 2>/dev/null && mrd_v=$mrd_mx ;; esac
  [ -n "$mrd_mn" ] && case "$mrd_mn" in *[!0-9]*) ;; *) [ "$mrd_v" -lt "$mrd_mn" ] 2>/dev/null && mrd_v=$mrd_mn ;; esac
  echo "$mrd_v"
}

ml_report() {
  mr_mode=$1
  mr_ok=0; [ -s "$RUNDIR/oc_writes" ] && mr_ok=$(wc -l < "$RUNDIR/oc_writes")
  mr_rej=0; [ -s "$RUNDIR/oc_rejected" ] && mr_rej=$(wc -l < "$RUNDIR/oc_rejected")
  echo "--- Verifikasi mode '$mr_mode' ---"
  mr_i=$(oc_cpu_count); mr_c=1
  while [ "$mr_c" -le "$mr_i" ]; do
    mr_line=$(oc_cpu_line "$mr_c")
    IFS='|' read -r mr_n mr_p _ _ _ _ <<EOF
$mr_line
EOF
    if [ -n "$mr_p" ]; then
      mr_kmin=$(read1 "$mr_p/cpuinfo_min_freq")
      mr_kmax=$(read1 "$mr_p/cpuinfo_max_freq")
      mr_rawmin=$(read1 "$mr_p/scaling_min_freq")
      mr_rawmax=$(read1 "$mr_p/scaling_max_freq")
      mr_want=$(awk -F'|' -v p="$mr_p" '$1==p{t=$2} END{print t}' "$RUNDIR/ml_targets" 2>/dev/null)
      mr_st=""
      if [ -n "$mr_want" ]; then
        if [ "$mr_rawmax" = "$mr_want" ] && [ "$mr_rawmin" = "$mr_want" ]; then mr_st="  [OK diminta=$mr_want]"; else mr_st="  [BEDA diminta=$mr_want]"; fi
      fi
      echo "  CPU$mr_c ($mr_n): governor=$(read1 "$mr_p/scaling_governor") min=$(mr_disp_freq "$mr_rawmin" "$mr_kmin" "$mr_kmax") max=$(mr_disp_freq "$mr_rawmax" "$mr_kmin" "$mr_kmax") cur=$(read1 "$mr_p/scaling_cur_freq")$mr_st"
    fi
    mr_c=$((mr_c + 1))
  done
  if oc_mtk_on; then
    mr_mt=$(oc_mtk_tbl_khz)
    mr_mc=$(oc_mtk_ceiling_khz $mr_mt); mr_mf=$(oc_mtk_floor_khz $mr_mt); mr_mr=$(oc_mtk_real_khz)
    mr_gw=$(ml_gpu_target_khz "$mr_mode")
    echo "  GPU (MTK): plafon=${mr_mc:-?}kHz floor=${mr_mf:-lepas}kHz sekarang=${mr_mr:-?}kHz${mr_gw:+ diminta<=${mr_gw}kHz}"
  elif [ -s "$SCANDIR/gpu" ]; then
    IFS='|' read -r mr_gb mr_gp mr_gminn mr_gmaxn < "$SCANDIR/gpu" 2>/dev/null
    [ -n "$mr_gp" ] && echo "  GPU ($mr_gb): governor=$(read1 "$mr_gp/governor") min=$(read1 "$mr_gp/$mr_gminn") max=$(read1 "$mr_gp/$mr_gmaxn")"
  fi
  echo "  node ditulis & terverifikasi sama: $mr_ok   |   ditolak kernel (readback beda): $mr_rej"
  [ "$mr_rej" -gt 0 ] && echo "  (detail node yang ditolak: $RUNDIR/oc_rejected / su -c \"azenith-ai log\")"
}

# ---------------------------------------------------------------------
# ml_watch - dipanggil BERKALA dari daemon_main (lib/daemon.sh), HANYA saat
# idle/tidak ada game terdeteksi (sama seperti tk_watch), supaya ceiling/
# floor CPU & GPU, SERTA governor-nya (fix26), yang sudah dikunci oleh mode
# aktif (terutama "saver": ceiling 60% tabel + governor hemat daya) tidak
# "lepas" diam-diam kembali ke bawaan.
#
# Kenapa ini perlu (akar masalah "saver ditekan tapi CPU/GPU tidak turun
# saat dicek belakangan"): ml_apply() di atas cuma menulis sysfs SEKALI,
# tepat saat tombol mode ditekan di WebUI/CLI. Banyak ROM vendor punya
# daemon perf/thermal sendiri (perfd, mi-thermald, GED, dst) yang menulis
# ULANG scaling_max_freq/GPU upbound-nya sendiri beberapa detik kemudian -
# begitu itu terjadi, nilai ceiling saver yang sudah ditulis modelock
# hilang tanpa modul pernah tahu, dan clock kelihatan "tidak pernah turun"
# walau log saat tombol ditekan menunjukkan sudah diterapkan. Ini PERSIS
# alasan ps_watch() ada untuk Battery Saver Android (lib/powersave.sh) -
# sekarang pengamanan yang sama diterapkan juga ke CPU/GPU, dibaca dari
# $DATADIR/azenith_thermal_mode (mode aktif yang sama dipakai azenith-ai
# status / system/bin/azenith-thermal).
#
# Digerbang GAME_PKG (hanya jalan saat idle, bukan HANYA saat balance/saver -
# gaming/extreme ikut dijaga juga supaya floor tidak lepas di luar sesi
# game) karena saat game AKTIF, lib/perf.sh (LV_CAP) sudah punya logika
# dinamisnya sendiri yang menaik-turunkan floor berdasar FPS real-time -
# menimpanya ulang tiap tick dari sini hanya akan tabrakan dengan itu.
ml_watch() {
  mw_mode=$(cat "$DATADIR/azenith_thermal_mode" 2>/dev/null)
  case "$mw_mode" in balance|saver|gaming|extreme) ;; *) return 0 ;; esac
  # v1.0.9-fix37: jangan menimpa mode yang SEDANG dipindah (azenith-thermal
  # menulis $RUNDIR/mode_switching selama as_begin..selesai). Lock basi
  # (proses pemiliknya sudah mati) diabaikan.
  mw_lp=$(cat "$RUNDIR/mode_switching" 2>/dev/null)
  [ -n "$mw_lp" ] && kill -0 "$mw_lp" 2>/dev/null && return 0
  : > "$RUNDIR/ml_watch.running"
  ml_apply "$mw_mode" >/dev/null 2>&1
  rm -f "$RUNDIR/ml_watch.running"
}
