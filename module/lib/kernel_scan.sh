#!/system/bin/sh
# =====================================================================
#  Zyrox - lib/kernel_scan.sh   ("Scan Kernel")
#
#  Pengganti kartu "Cocokkan kernel" lama: dulu fitur itu MENGHARUSKAN upload
#  berkas kernel/driver (boot Image / vendor_dlkm.img / .ko) dulu baru bisa
#  lihat apa-apa. Fitur ini sebaliknya - scan LANGSUNG dari device yang
#  sedang berjalan (getprop + /proc + /sys, sumber yang sama dipakai
#  lib/devinfo.sh & lib/overclock.sh), tanpa perlu upload apa pun, dan
#  langsung menjawab 4 pertanyaan inti:
#    1) Kernel APA   - release, versi build, compiler, arsitektur
#    2) Basis APA    - GKI (Generic Kernel Image) vs vendor fork, + alasan
#    3) Lock BERAPA  - bootloader lock, verified boot, dm-verity, SELinux,
#                       root, serta status LOCK/UNLOCK tiap cluster CPU & GPU
#    4) Frequency CPU/GPU - min/cur/max per cluster CPU + GPU, dengan
#                       governor aktifnya
#
#  v1.0.16: ditambah bagian 7) KOMPATIBILITAS FITUR & BATAS KERNEL (ks_features):
#  tiap fitur Zyrox diuji nyata (tulis-balik nilai sama / cek dukungan cmd /
#  baca CONFIG kernel) dan dilabeli BISA / SEBAGIAN / TIDAK BISA beserta alasannya.
#  `azenith-ai kernel features` = keluaran mesin (STATUS|GRUP|NAMA|DETAIL) untuk WebUI.
#
#  Kalau user tetap upload berkas (opsional, lewat `kernel scan <berkas>`),
#  hasil klasifikasi string-match dari lib/kernel_match.sh (km_classify/
#  km_extract_tokens) ditambahkan sebagai lampiran "deteksi driver" di
#  bagian akhir laporan - bukan lagi syarat wajib untuk lihat info kernel.
# =====================================================================

KSCAN_REPORT="$SCANDIR/kernel_scan_report.txt"

# bilangan kHz -> teks manusiawi (GHz/MHz)
ks_khz_human() {
  awk -v k="${1:-0}" 'BEGIN{
    if (k=="" || k=="0") { print "-"; exit }
    if (k>=1000000) printf "%.2f GHz", k/1000000
    else             printf "%d MHz", k/1000
  }'
}

# ks_lockmark <min> <max> -> "LOCK (freq tetap)" / "unlock (bisa scaling)" / "?"
ks_lockmark() {
  kl_mn=$1; kl_mx=$2
  [ -n "$kl_mn" ] && [ -n "$kl_mx" ] || { echo "?"; return 0; }
  if [ "$kl_mn" = "$kl_mx" ]; then echo "LOCK (freq tetap di satu titik)"
  else echo "unlock (boleh scaling $(ks_khz_human "$kl_mn") - $(ks_khz_human "$kl_mx"))"
  fi
}

# --- deteksi basis kernel: GKI (Generic Kernel Image, Android 11+ Treble)
# vs vendor fork murni. Sinyal utama: banner "Linux version" GKI berpola
# "<ver>-android<N>-<K>-g<hash>[-ab<build>]" (lihat dok AOSP "GKI release
# builds") - kalau pola itu ketemu, nyaris pasti GKI/pengembangan darinya.
# Tanpa itu, fallback ke prop ro.kernel.version / ro.boot.hardware /
# tag vendor umum (mediatek/qcom/exynos/unisoc) dari nama release itu sendiri.
ks_detect_base() {
  kb_rel=$(uname -r 2>/dev/null)
  kb_ban=$(dv_cat "$R/proc/version")
  [ -n "$kb_ban" ] || kb_ban=$(uname -v 2>/dev/null)
  kb_dirty=""
  case "$kb_rel" in *-dirty) kb_dirty=" (ditandai 'dirty' - source tree kernel dimodifikasi dari upstream saat dikompail)" ;; esac

  case "$kb_rel" in
    *-android[0-9]*-[0-9]*-g????????*)
      kb_and=$(printf '%s' "$kb_rel" | sed -n 's/.*-\(android[0-9][0-9]*\)-.*/\1/p')
      kb_kmi=$(printf '%s' "$kb_rel" | sed -n 's/.*-android[0-9]*-\([0-9]*\)-g[0-9a-f]*.*/\1/p')
      echo "GKI|Kernel GKI (Generic Kernel Image) resmi Google - release '$kb_rel' cocok pola KMI GKI ($kb_and, sublevel $kb_kmi)$kb_dirty. Driver vendor (gpufreq/FPSGO/GED/GPU) pada kernel GKI modern BIASANYA dimuat terpisah sebagai modul .ko di vendor_dlkm.img, bukan dikompail langsung ke image ini."
      return 0 ;;
  esac

  kb_tag=""
  case "$(dv_lc "$kb_rel $kb_ban $(getprop ro.hardware 2>/dev/null) $(getprop ro.board.platform 2>/dev/null)")" in
    *mt[0-9][0-9][0-9][0-9]*|*mediatek*) kb_tag="MediaTek" ;;
    *qcom*|*msm*|*sm[0-9][0-9][0-9][0-9]*) kb_tag="Qualcomm" ;;
    *exynos*) kb_tag="Samsung Exynos" ;;
    *unisoc*|*sprd*|*ums[0-9]*) kb_tag="Unisoc" ;;
  esac
  if [ -n "$kb_tag" ]; then
    echo "VENDOR|Bukan pola GKI standar - release '$kb_rel'$kb_dirty. Terdeteksi sebagai kernel fork vendor $kb_tag (driver gpufreq/thermal/GPU kemungkinan dikompail LANGSUNG ke kernel ini, bukan modul .ko terpisah) - umum di kernel non-GKI/Android lama atau device yang belum pindah ke arsitektur GKI."
  else
    echo "UNKNOWN|Bukan pola GKI standar - release '$kb_rel'$kb_dirty. Tidak ada penanda vendor SoC yang jelas di banner/release, basis pastinya tidak bisa dipastikan dari sini saja."
  fi
}

# --- tabel CPU per-cluster: min/cur/max kHz + governor + status lock
# (dibaca langsung dari cpufreq, sumber sama dengan lib/overclock.sh - bukan
# duplikasi logic OC-nya, cuma pembacaan info apa adanya untuk laporan)
ks_cpu_table() {
  kc_i=0
  for kc_p in "$R"/sys/devices/system/cpu/cpufreq/policy*; do
    [ -d "$kc_p" ] || continue
    kc_i=$((kc_i + 1))
    kc_rel=$(dv_cat "$kc_p/related_cpus"); [ -n "$kc_rel" ] || kc_rel=$(dv_cat "$kc_p/affected_cpus")
    kc_n=$(printf '%s\n' $kc_rel | wc -l)
    kc_fc=${kc_rel%% *}
    kc_kmin=$(dv_cat "$kc_p/cpuinfo_min_freq")
    kc_kmax=$(dv_cat "$kc_p/cpuinfo_max_freq")
    kc_smin=$(dv_cat "$kc_p/scaling_min_freq")
    kc_smax=$(dv_cat "$kc_p/scaling_max_freq")
    kc_cur=$(dv_cat "$kc_p/scaling_cur_freq")
    kc_gov=$(dv_cat "$kc_p/scaling_governor")
    printf 'Cluster %-2s cpu%-3s (%s core) : min %-9s cur %-9s max %-9s | governor=%-10s | batas kernel %s-%s | %s\n' \
      "$kc_i" "$kc_fc" "$kc_n" \
      "$(ks_khz_human "$kc_smin")" "$(ks_khz_human "$kc_cur")" "$(ks_khz_human "$kc_smax")" \
      "${kc_gov:--}" \
      "$(ks_khz_human "$kc_kmin")" "$(ks_khz_human "$kc_kmax")" \
      "$(ks_lockmark "$kc_smin" "$kc_smax")"
  done
  [ "$kc_i" -gt 0 ] || echo "(tidak terbaca - sysfs cpufreq tidak ada/tidak bisa diakses)"
}

# --- GPU: min/cur/max + governor + status lock, node sama yang dipakai
# lib/devinfo.sh (dv_gpu_node, support Mali/Adreno/PowerVR)
ks_gpu_table() {
  dv_gpu_vendor
  dv_gpu_node
  if [ -z "$DV_GN" ]; then
    echo "(node devfreq GPU tidak ditemukan di device ini)"
    return 0
  fi
  kg_min=$(dv_cat "$DV_GN/min_freq"); [ -n "$kg_min" ] || kg_min=$(dv_cat "$DV_GN/min_gpuclk")
  kg_max=$(dv_cat "$DV_GN/max_freq"); [ -n "$kg_max" ] || kg_max=$(dv_gpu_hz max)
  kg_cur=$(dv_gpu_hz cur)
  kg_gov=$(dv_cat "$DV_GN/governor")
  echo "Vendor   : ${GV_VENDOR:-tidak diketahui}"
  echo "Nama     : ${GV_NAME:-tidak terbaca dari sysfs vendor}"
  echo "Node     : ${DV_GN##*/}"
  printf 'Frekuensi: min %s | cur %s | max %s\n' "$(ks_khz_human "$kg_min")" "$(ks_khz_human "$kg_cur")" "$(ks_khz_human "$kg_max")"
  echo "Governor : ${kg_gov:--}"
  echo "Status   : $(ks_lockmark "$kg_min" "$kg_max")"
}

# --- lock & keamanan: bootloader/verified boot/dm-verity/SELinux/root/ROM
ks_lock_security() {
  kl_fl=$(getprop ro.boot.flash.locked 2>/dev/null)
  case "$kl_fl" in
    1) echo "Bootloader     : LOCKED (ro.boot.flash.locked=1)" ;;
    0) echo "Bootloader     : UNLOCKED (ro.boot.flash.locked=0)" ;;
    *) echo "Bootloader     : tidak diketahui (prop ro.boot.flash.locked kosong/tidak ada di device ini)" ;;
  esac
  kl_vb=$(getprop ro.boot.verifiedbootstate 2>/dev/null)
  [ -n "$kl_vb" ] && echo "Verified Boot  : $kl_vb" || echo "Verified Boot  : tidak diketahui"
  kl_vm=$(getprop ro.boot.veritymode 2>/dev/null)
  [ -n "$kl_vm" ] && echo "dm-verity      : $kl_vm"
  kl_se=$(getenforce 2>/dev/null)
  echo "SELinux        : ${kl_se:-tidak diketahui}"
  kl_tags=$(getprop ro.build.tags 2>/dev/null); kl_btype=$(getprop ro.build.type 2>/dev/null)
  echo "Build tags/type: ${kl_tags:-?} / ${kl_btype:-?}"
  # dv_root mencetak "root=..."/"root_ver=..." via dv_p (stdout) - tangkap ke
  # berkas sementara lalu ambil nilainya, supaya tidak ikut tercampur ke laporan ini.
  kl_rtmp="$RUNDIR/kscan_root.tmp"
  dv_root > "$kl_rtmp" 2>/dev/null
  kl_rn=$(sed -n 's/^root=//p' "$kl_rtmp")
  kl_rv=$(sed -n 's/^root_ver=//p' "$kl_rtmp")
  rm -f "$kl_rtmp" 2>/dev/null
  echo "Root           : ${kl_rn:-tidak terdeteksi}${kl_rv:+ ($kl_rv)}"
  dv_rom
  echo "ROM            : ${rd_name:-tidak diketahui}${rd_ver:+ $rd_ver} (klasifikasi: $RD_TYPE, keyakinan $RD_CONF)"
  echo "  alasan       : $RD_WHY"
}

# =====================================================================
#  CEK KOMPATIBILITAS FITUR & KEMAMPUAN KERNEL  (v1.0.16)
#
#  Menjawab 2 hal: (1) fitur Zyrox mana yang BENAR-BENAR bisa jalan di
#  kernel/ROM ini, (2) apa yang TIDAK bisa dilakukan kernel ini - supaya user
#  tahu fitur mana yang tidak akan berguna dipakai.
#
#  Cara uji (TIDAK mengubah apa pun yang berefek):
#   - node sysfs/proc yang aman = TULIS-BALIK nilai yang SAMA lalu baca ulang
#     (kernel menolak -> ketahuan; nilai tidak berubah -> tidak ada efek samping)
#   - node berisiko (thermal zone, charger, GPU custom freq) = cek ada + izin
#     tulis saja, TIDAK ditulis
#   - perintah Android (cmd/settings/pm) = cek dukungan lewat 'help'
#   - CONFIG_* kernel dibaca dari /proc/config.gz kalau ada
#
#  Format baris: STATUS|GRUP|NAMA|DETAIL
#    STATUS = OK (bisa) | PART (sebagian) | NO (tidak bisa) | UNK (tidak diketahui)
# =====================================================================
KF_CFG="$RUNDIR/kfeat_kconfig.txt"

kf() { printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "$(printf '%s' "$4" | tr '|\r\n' '/  ')"; }

# tulis-balik nilai SAMA + baca ulang. 0 = kernel menerima tulisan.
kf_wtest() {
  kw_p=$1
  [ -e "$kw_p" ] && [ -w "$kw_p" ] || return 1
  kw_v=$(dv_cat "$kw_p")
  [ -n "$kw_v" ] || return 2
  { printf '%s' "$kw_v" > "$kw_p"; } 2>/dev/null || return 1
  [ "$(dv_cat "$kw_p")" = "$kw_v" ]
}

kf_cfg_load() {
  rm -f "$KF_CFG" 2>/dev/null
  [ -r "$R/proc/config.gz" ] || return 1
  { zcat "$R/proc/config.gz" 2>/dev/null || gzip -dc "$R/proc/config.gz" 2>/dev/null; } > "$KF_CFG"
  [ -s "$KF_CFG" ]
}
kf_cfg() { # kf_cfg NAMA -> y | m | n | ?   (? = /proc/config.gz tidak terbaca)
  [ -s "$KF_CFG" ] || { echo "?"; return 0; }
  kc_l=$(grep -m1 "^CONFIG_$1=" "$KF_CFG" 2>/dev/null)
  case "$kc_l" in "") echo n ;; *=y) echo y ;; *=m) echo m ;; *) echo "${kc_l#*=}" ;; esac
}

kf_gpu_opp_max_khz() {
  for kg_f in "$R/proc/gpufreq/gpufreq_opp_dump" "$R/proc/gpufreqv2/gpu_working_opp_table" "$R/proc/gpufreqv2/gpu_signed_opp_table"; do
    [ -r "$kg_f" ] || continue
    kg_m=$(grep -io 'freq[^0-9]*[0-9]\{5,\}' "$kg_f" 2>/dev/null | grep -o '[0-9]\{5,\}$' | sort -n | tail -n 1)
    [ -n "$kg_m" ] && { echo "$kg_m"; return 0; }
  done
  if [ -n "$DV_GN" ] && [ -r "$DV_GN/available_frequencies" ]; then
    kg_m=$(tr ' ' '\n' < "$DV_GN/available_frequencies" 2>/dev/null | grep -o '^[0-9][0-9]*' | sort -n | tail -n 1)
    [ -n "$kg_m" ] && { echo $((kg_m / 1000)); return 0; }
  fi
  return 0
}

kf_have_cmd() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------
ks_features() {
  G1="Fitur Zyrox"
  G2="Kernel / sistem"
  kf_cfg_load; kf_cfgok=$?
  kf_sdk=$(getprop ro.build.version.sdk 2>/dev/null); kf_sdk=${kf_sdk:-0}
  kf_kv=$(uname -r 2>/dev/null | sed -n 's/^\([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2/p'); kf_kmaj=${kf_kv% *}; kf_kmin=${kf_kv#* }
  kf_kmaj=${kf_kmaj:-0}; kf_kmin=${kf_kmin:-0}
  dv_gpu_vendor >/dev/null 2>&1; dv_gpu_node >/dev/null 2>&1

  # ---------- 1) Mode Thermal: kunci frekuensi & governor CPU ----------
  kf_n=0; kf_ok=0; kf_gv=""
  for kf_p in "$R"/sys/devices/system/cpu/cpufreq/policy*; do
    [ -d "$kf_p" ] || continue
    kf_n=$((kf_n + 1))
    if kf_wtest "$kf_p/scaling_max_freq" && kf_wtest "$kf_p/scaling_min_freq"; then kf_ok=$((kf_ok + 1)); fi
    [ -z "$kf_gv" ] && kf_gv=$(dv_cat "$kf_p/scaling_available_governors")
    kf_gv="$kf_gv $(dv_cat "$kf_p/scaling_available_governors")"
  done
  if   [ "$kf_n" -eq 0 ];       then kf NO "$G1" "Kunci frekuensi CPU (mode Balanced/Saver/Gaming/Turbo)" "sysfs cpufreq tidak ada - fitur ini TIDAK bisa jalan"
  elif [ "$kf_ok" -eq "$kf_n" ]; then kf OK "$G1" "Kunci frekuensi CPU (mode Balanced/Saver/Gaming/Turbo)" "$kf_n cluster: tulis min/max diterima kernel (diuji tulis-balik). Catatan: PPM/DVFS vendor tetap bisa menjepit efek nyatanya"
  elif [ "$kf_ok" -gt 0 ];       then kf PART "$G1" "Kunci frekuensi CPU (mode Balanced/Saver/Gaming/Turbo)" "hanya $kf_ok dari $kf_n cluster yang menerima tulisan min/max"
  else                              kf NO "$G1" "Kunci frekuensi CPU (mode Balanced/Saver/Gaming/Turbo)" "$kf_n cluster ada tapi kernel MENOLAK tulis scaling_min/max_freq"
  fi
  kf_miss=""
  for kf_g in schedutil powersave performance; do
    case " $kf_gv " in *" $kf_g "*) ;; *) kf_miss="$kf_miss $kf_g" ;; esac
  done
  if [ "$kf_n" -eq 0 ]; then :
  elif [ -z "$kf_miss" ]; then kf OK "$G1" "Governor CPU (schedutil/powersave/performance)" "ketiganya tersedia"
  else kf PART "$G1" "Governor CPU (schedutil/powersave/performance)" "TIDAK tersedia:$kf_miss - mode yang memakainya akan pakai governor lain"
  fi

  # ---------- 2) CPU di atas tabel OPP ----------
  kf_cmax=0
  for kf_p in "$R"/sys/devices/system/cpu/cpufreq/policy*; do
    [ -d "$kf_p" ] || continue
    kf_m=$(dv_cat "$kf_p/cpuinfo_max_freq"); [ "${kf_m:-0}" -gt "$kf_cmax" ] 2>/dev/null && kf_cmax=$kf_m
  done
  if [ -e "$R/proc/cpudvfs/cpufreq_debug" ]; then
    kf PART "$G1" "Overclock CPU melewati tabel OPP kernel" "puncak tabel OPP = $(ks_khz_human "$kf_cmax"). Frekuensi di atas tabel TIDAK bisa dibuat lewat sysfs; node debug /proc/cpudvfs hanya membantu menembus jepitan internal, bukan menambah OPP"
  else
    kf NO "$G1" "Overclock CPU melewati tabel OPP kernel" "puncak tabel OPP = $(ks_khz_human "$kf_cmax"). Kernel ini TIDAK bisa dipaksa lebih tinggi dari tabel OPP lewat runtime (butuh patch kernel/DTB)"
  fi

  # ---------- 3) GPU: kunci frekuensi ----------
  kf_gb=""
  if [ -n "$DV_GN" ] && kf_wtest "$DV_GN/max_freq" && kf_wtest "$DV_GN/min_freq"; then kf_gb="$kf_gb devfreq(${DV_GN##*/})"; fi
  [ -w "$R/sys/kernel/ged/hal/custom_upbound_gpu_freq" ] && kf_gb="$kf_gb GED(custom_upbound)"
  [ -w "$R/proc/gpufreq/gpufreq_opp_freq" ] && kf_gb="$kf_gb gpufreq(opp_freq)"
  [ -w "$R/proc/gpufreqv2/fix_target_opp_index" ] && kf_gb="$kf_gb gpufreqv2(fix_target_opp_index)"
  if [ -n "$kf_gb" ]; then kf OK "$G1" "Kunci frekuensi GPU (min/max)" "jalur yang bisa dipakai:$kf_gb"
  elif [ -n "$DV_GN" ]; then kf NO "$G1" "Kunci frekuensi GPU (min/max)" "node GPU ${DV_GN##*/} ada tapi MENOLAK tulis min/max, dan tidak ada jalur GED/gpufreq - GPU lock TIDAK bisa"
  else kf NO "$G1" "Kunci frekuensi GPU (min/max)" "tidak ada node GPU (devfreq/GED/gpufreq) yang bisa ditulis"
  fi

  # ---------- 4) GPU di atas tabel OPP ----------
  kf_gmax=$(kf_gpu_opp_max_khz)
  if [ -w "$R/proc/gpufreqv2/fix_custom_freq_volt" ] || [ -w "$R/proc/gpufreq/gpufreq_fixed_freq_volt" ]; then
    kf PART "$G1" "Overclock GPU melewati tabel OPP kernel" "puncak tabel OPP = $(ks_khz_human "${kf_gmax:-0}"). Ada node freq+volt kustom (fix_custom_freq_volt) - sebagian driver MTK menerima nilai di luar OPP, TIDAK diuji otomatis karena bisa hang"
  elif [ -n "$kf_gmax" ]; then
    kf NO "$G1" "Overclock GPU melewati tabel OPP kernel" "tabel OPP kernel berhenti di $(ks_khz_human "$kf_gmax"). GPU di atas itu TIDAK bisa dipaksa lewat runtime - perlu patch tabel OPP (.ko vendor_dlkm / kernel)"
  else
    kf UNK "$G1" "Overclock GPU melewati tabel OPP kernel" "tabel OPP GPU tidak terbaca, batas atasnya tidak diketahui"
  fi

  # ---------- 5) Thermal ----------
  kf_tsv=$(getprop 2>/dev/null | sed -n 's/^\[init\.svc\.\(.*[Tt][Hh][Ee][Rr][Mm][Aa][Ll].*\)\]: \[\(.*\)\]$/\1=\2/p' | tr '\n' ' ')
  kf_tz=$(ls -d "$R"/sys/class/thermal/thermal_zone* 2>/dev/null | wc -l | tr -d ' ')
  if [ -n "$kf_tsv" ]; then kf OK "$G1" "Disable Thermal / Thermal Lock Daily / Fast Charger" "service thermal userspace ditemukan: $kf_tsv - bisa dihentikan"
  elif [ "${kf_tz:-0}" -gt 0 ]; then kf PART "$G1" "Disable Thermal / Thermal Lock Daily / Fast Charger" "tidak ada service thermal userspace (throttle diatur kernel). $kf_tz thermal zone ada tapi mematikan service tidak berefek"
  else kf NO "$G1" "Disable Thermal / Thermal Lock Daily / Fast Charger" "tidak ada service maupun thermal zone yang bisa dimatikan"
  fi
  kf_em=$(ls "$R"/sys/class/thermal/thermal_zone*/emul_temp 2>/dev/null | wc -l | tr -d ' ')
  if [ "${kf_em:-0}" -gt 0 ]; then kf OK "$G1" "Inject/emulasi suhu (emul_temp)" "$kf_em zona mendukung emul_temp"
  else kf NO "$G1" "Inject/emulasi suhu (emul_temp)" "tidak ada emul_temp (CONFIG_THERMAL_EMULATION=$(kf_cfg THERMAL_EMULATION)) - suhu palsu TIDAK bisa diinjeksi, Thermal Lock hanya mengandalkan stop service/trip"
  fi
  kf_trip=0
  for kf_t in "$R"/sys/class/thermal/thermal_zone*/trip_point_*_temp; do [ -w "$kf_t" ] && kf_trip=$((kf_trip + 1)); done
  if [ "$kf_trip" -gt 0 ]; then kf OK "$G1" "Naikkan trip point thermal kernel" "$kf_trip trip point bisa ditulis"
  else kf NO "$G1" "Naikkan trip point thermal kernel" "tidak ada trip_point_*_temp yang bisa ditulis - mode THERMAL hard / TK_KERNEL TIDAK berefek"
  fi
  if [ -e "$R/proc/ppm/policy_status" ]; then kf OK "$G1" "Matikan PPM thermal (MediaTek)" "/proc/ppm/policy_status ada"
  else kf NO "$G1" "Matikan PPM thermal (MediaTek)" "tidak ada /proc/ppm (bukan MediaTek PPM / kernel tanpa PPM) - langkah ini dilewati"
  fi

  # ---------- 6) FPSGO / Touch Boost ----------
  kf_fp=0; kf_fl=""
  for kf_f in fpsgo_enable stop_boost perfserv_ta; do
    if [ -e "$R/sys/kernel/fpsgo/common/$kf_f" ]; then kf_fp=$((kf_fp + 1)); kf_wtest "$R/sys/kernel/fpsgo/common/$kf_f" || kf_fl="$kf_fl $kf_f"; fi
  done
  if [ "$kf_fp" -eq 3 ] && [ -z "$kf_fl" ]; then kf OK "$G1" "FPSGO & Touch Boost" "3 node /sys/kernel/fpsgo/common diterima kernel (diuji tulis-balik)"
  elif [ "$kf_fp" -gt 0 ]; then kf PART "$G1" "FPSGO & Touch Boost" "$kf_fp/3 node FPSGO ada${kf_fl:+, menolak tulis:$kf_fl}"
  elif [ -e "$R/sys/module/ged/parameters/ged_boost_enable" ]; then kf PART "$G1" "FPSGO & Touch Boost" "tidak ada FPSGO; hanya fallback GED (ged_boost_enable) - FPS engine berbasis FPSGO TIDAK jalan"
  else kf NO "$G1" "FPSGO & Touch Boost" "tidak ada FPSGO maupun GED - bukan SoC MediaTek / kernel tanpa FPSGO. Tuning FPSGO & Touch Boost TIDAK berguna"
  fi
  if [ -d "$R/sys/kernel/debug/fpsgo" ] || [ -d "$R/sys/kernel/fpsgo/fbt" ]; then kf OK "$G1" "Tuning node FPSGO lanjutan (fbt/fstb)" "direktori fpsgo lanjutan terbaca"
  else kf NO "$G1" "Tuning node FPSGO lanjutan (fbt/fstb)" "direktori fbt/fstb/debugfs fpsgo tidak terbaca - tuning FPSGO terbatas ke node dasar"
  fi

  # ---------- 7) Network Booster ----------
  kf_ccn="$R/proc/sys/net/ipv4/tcp_congestion_control"
  kf_cca=$(dv_cat "$R/proc/sys/net/ipv4/tcp_available_congestion_control")
  kf_bbrcfg=$(kf_cfg TCP_CONG_BBR)
  if ! kf_wtest "$kf_ccn"; then kf NO "$G1" "Network Booster - congestion control" "tcp_congestion_control tidak bisa ditulis"
  else
    case " $kf_cca " in
      *" bbr3 "*) kf OK "$G1" "Network Booster - congestion control" "bbr3 tersedia (daftar: $kf_cca)" ;;
      *" bbr "*)  kf PART "$G1" "Network Booster - congestion control" "bbr3 TIDAK ada, akan jatuh ke bbr (daftar: $kf_cca)" ;;
      *) if [ "$kf_bbrcfg" = m ]; then kf PART "$G1" "Network Booster - congestion control" "bbr/bbr3 belum terdaftar tapi CONFIG_TCP_CONG_BBR=m (dimuat saat dipakai) - daftar sekarang: $kf_cca"
         else kf NO "$G1" "Network Booster - congestion control" "bbr/bbr3 TIDAK ada di kernel ini (daftar: $kf_cca) - hanya bisa westwood/cubic/reno"; fi ;;
    esac
  fi
  kf_nok=0; kf_nn=0
  for kf_s in net/core/rmem_max net/core/wmem_max net/ipv4/tcp_rmem net/ipv4/tcp_wmem net/ipv4/tcp_fastopen net/ipv4/tcp_slow_start_after_idle net/ipv4/tcp_mtu_probing; do
    [ -e "$R/proc/sys/$kf_s" ] || continue
    kf_nn=$((kf_nn + 1)); kf_wtest "$R/proc/sys/$kf_s" && kf_nok=$((kf_nok + 1))
  done
  if [ "$kf_nn" -eq 0 ]; then kf NO "$G1" "Network Booster - buffer/window TCP" "sysctl net.* tidak terbaca"
  elif [ "$kf_nok" -eq "$kf_nn" ]; then kf OK "$G1" "Network Booster - buffer/window TCP" "$kf_nok/$kf_nn sysctl diterima kernel"
  else kf PART "$G1" "Network Booster - buffer/window TCP" "hanya $kf_nok dari $kf_nn sysctl yang diterima"
  fi
  if [ -e "$R/proc/sys/net/ipv4/tcp_low_latency" ]; then kf OK "$G1" "Network Booster - tcp_low_latency" "node ada"
  else kf PART "$G1" "Network Booster - tcp_low_latency" "node TIDAK ada di kernel $kf_kmaj.$kf_kmin (dihapus sejak 4.14) - bagian ini diabaikan, tidak berbahaya"
  fi

  # ---------- 8) WiFi Low Latency ----------
  if [ "$kf_sdk" -lt 29 ] 2>/dev/null; then
    kf NO "$G1" "WiFi Low Latency - force-low-latency-mode" "Android SDK $kf_sdk < 29, API low-latency Wi-Fi belum ada"
  elif wl_cmd_supported; then
    kf OK "$G1" "WiFi Low Latency - force-low-latency-mode" "ROM punya 'cmd wifi force-low-latency-mode'"
  else
    kf NO "$G1" "WiFi Low Latency - force-low-latency-mode" "ROM TIDAK punya perintah ini - metode utama tidak jalan, hanya metode settings/iw yang tersisa"
  fi
  kf_sv=$(settings get global wifi_suspend_optimizations_enabled 2>/dev/null | tr -d ' \r\n')
  if [ -z "$kf_sv" ]; then kf UNK "$G1" "WiFi Low Latency - matikan hemat daya radio (settings)" "perintah settings tidak merespon"
  elif [ "$kf_sv" = null ]; then kf PART "$G1" "WiFi Low Latency - matikan hemat daya radio (settings)" "key belum ada di ROM ini (nilai tetap ditulis, framework mungkin mengabaikannya)"
  else kf OK "$G1" "WiFi Low Latency - matikan hemat daya radio (settings)" "key ada, nilai sekarang $kf_sv"
  fi
  kf_wi=$(wl_iface)
  if [ -n "$kf_wi" ] && kf_have_cmd iw && [ -n "$(wl_iw_state "$kf_wi")" ]; then kf OK "$G1" "WiFi Low Latency - iw power_save" "iw ada, $kf_wi melaporkan power_save $(wl_iw_state "$kf_wi")"
  elif [ -z "$kf_wi" ]; then kf UNK "$G1" "WiFi Low Latency - iw power_save" "interface Wi-Fi tidak ditemukan (Wi-Fi sedang mati?) - nyalakan Wi-Fi lalu cek ulang"
  else kf PART "$G1" "WiFi Low Latency - iw power_save" "biner 'iw' tidak ada / driver tidak melaporkan power_save - dilewati"
  fi

  # ---------- 9) Graphics API Universal ----------
  kf_vk=$(ls "$R"/vendor/lib64/hw/vulkan.*.so "$R"/vendor/lib/hw/vulkan.*.so "$R"/system/lib64/hw/vulkan.*.so 2>/dev/null | head -n 1)
  [ -z "$kf_vk" ] && [ -n "$(getprop ro.hardware.vulkan 2>/dev/null)" ] && kf_vk="ro.hardware.vulkan=$(getprop ro.hardware.vulkan)"
  if [ -n "$kf_vk" ] && [ "$kf_sdk" -ge 29 ] 2>/dev/null; then kf OK "$G1" "Graphics API - Vulkan (skiavk)" "driver Vulkan ada (${kf_vk##*/}), SDK $kf_sdk"
  elif [ -n "$kf_vk" ]; then kf NO "$G1" "Graphics API - Vulkan (skiavk)" "driver Vulkan ada tapi SDK $kf_sdk < 29, renderer skiavk butuh Android 10+"
  else kf NO "$G1" "Graphics API - Vulkan (skiavk)" "driver Vulkan tidak ditemukan - pilihan vulkan/skiavk akan gagal diverifikasi"
  fi
  if [ "$kf_sdk" -ge 28 ] 2>/dev/null; then kf OK "$G1" "Graphics API - SkiaGL" "SDK $kf_sdk mendukung renderer skiagl (OpenGL ES $(getprop ro.opengles.version 2>/dev/null))"
  else kf NO "$G1" "Graphics API - SkiaGL" "SDK $kf_sdk < 28"
  fi

  # ---------- 10) zRAM ----------
  if [ -d "$R/sys/block/zram0" ]; then
    kf_za=$(tr -d '[]' < "$R/sys/block/zram0/comp_algorithm" 2>/dev/null)
    kf_zt=""; for kf_b in swapon mkswap swapoff; do kf_have_cmd "$kf_b" || kf_zt="$kf_zt $kf_b"; done
    if [ -n "$kf_zt" ]; then kf PART "$G1" "zRAM manager" "zram0 ada (algoritma: $kf_za) tapi biner TIDAK ada:$kf_zt - ubah ukuran/algoritma bisa gagal"
    elif [ -w "$R/sys/block/zram0/disksize" ]; then kf OK "$G1" "zRAM manager" "zram0 ada, algoritma: $kf_za"
    else kf PART "$G1" "zRAM manager" "zram0 ada tapi disksize tidak bisa ditulis"; fi
  else kf NO "$G1" "zRAM manager" "tidak ada /sys/block/zram0 (CONFIG_ZRAM=$(kf_cfg ZRAM)) - fitur zRAM TIDAK bisa dipakai"
  fi

  # ---------- 11) Bypass Charging ----------
  kf_cn=""
  for kf_d in "$R"/sys/class/power_supply/*; do
    for kf_n in charging_enabled input_suspend battery_charging_enabled chg_enable en_chg mmi_charging_enable charge_enable stop_charging constant_charge_current_max input_current_limit; do
      [ -w "$kf_d/$kf_n" ] && kf_cn="$kf_cn ${kf_d##*/}/$kf_n"
    done
  done
  for kf_n in proc/mtk_battery_cmd/current_cmd proc/mtk_battery_cmd/en_power_path; do [ -w "$R/$kf_n" ] && kf_cn="$kf_cn $kf_n"; done
  kf_cb=0; cmd battery help >/dev/null 2>&1 && cmd battery help 2>&1 | grep -qi 'status' && kf_cb=1
  if [ "$kf_cb" -eq 1 ]; then kf PART "$G1" "Bypass Charging" "modul memakai 'cmd battery set status 4' = HANYA mengubah status yang DILAPORKAN sistem, arus charger fisik TETAP masuk. Node pemutus hardware yang ada di device ini:${kf_cn:- tidak ada} (belum dipakai modul)"
  else kf NO "$G1" "Bypass Charging" "'cmd battery' tidak mendukung set status di ROM ini. Node hardware:${kf_cn:- tidak ada}"
  fi

  # ---------- 12) Fitur sistem Android ----------
  kf_lp=$(settings get global low_power 2>/dev/null | tr -d ' \r\n')
  case "$kf_lp" in 0|1|null) kf OK "$G1" "Battery Saver otomatis ikut mode (low_power)" "settings global low_power terbaca ($kf_lp)" ;; *) kf UNK "$G1" "Battery Saver otomatis ikut mode (low_power)" "settings tidak merespon" ;; esac
  kf_zn=$(settings get global zen_mode 2>/dev/null | tr -d ' \r\n')
  case "$kf_zn" in [0-9]|null) kf OK "$G1" "DND In-Game" "zen_mode terbaca ($kf_zn)" ;; *) kf UNK "$G1" "DND In-Game" "settings zen_mode tidak merespon" ;; esac
  if pm help 2>&1 | grep -q 'disable-user'; then kf OK "$G1" "Freeze In-Game" "pm disable-user didukung"
  else kf NO "$G1" "Freeze In-Game" "pm disable-user TIDAK didukung ROM ini"
  fi
  if [ -w "$R/proc/sys/vm/drop_caches" ] && pm help 2>&1 | grep -q 'trim-caches'; then kf OK "$G1" "Pembersih Sistem (cache)" "drop_caches bisa ditulis, pm trim-caches ada"
  elif [ -w "$R/proc/sys/vm/drop_caches" ] || pm help 2>&1 | grep -q 'trim-caches'; then kf PART "$G1" "Pembersih Sistem (cache)" "hanya sebagian jalur pembersih yang tersedia"
  else kf NO "$G1" "Pembersih Sistem (cache)" "drop_caches & pm trim-caches sama-sama tidak tersedia"
  fi
  kf_gm=$(cmd game help 2>&1 | head -n 3)
  case "$kf_gm" in
    *"find service"*|*"not found"*|"") kf PART "$G1" "Downscale resolusi per-game" "GameManagerService tidak ada - memakai fallback 'wm size+density' (mengubah resolusi seluruh layar, bukan per-game)" ;;
    *) kf OK "$G1" "Downscale resolusi per-game" "cmd game tersedia" ;;
  esac
  kf_cd=0; kf_cdw=0
  for kf_c in "$R"/sys/class/thermal/cooling_device*; do
    [ -d "$kf_c" ] || continue
    case "$(dv_lc "$(dv_cat "$kf_c/type")")" in *cpu*|*gpu*|*cluster*|*mali*|*kgsl*)
      kf_cd=$((kf_cd + 1)); kf_wtest "$kf_c/cur_state" && kf_cdw=$((kf_cdw + 1)) ;; esac
  done
  if [ "$kf_cd" -eq 0 ]; then kf NO "$G1" "Cooling SoC per-game" "tidak ada cooling_device bertipe cpu/gpu - penurunan plafon via cooling_device TIDAK bisa (hanya governor/plafon)"
  elif [ "$kf_cdw" -gt 0 ]; then kf OK "$G1" "Cooling SoC per-game" "$kf_cdw dari $kf_cd cooling_device cpu/gpu menerima tulisan"
  else kf PART "$G1" "Cooling SoC per-game" "$kf_cd cooling_device cpu/gpu ada tapi menolak tulis cur_state"
  fi
  kf_hz=$(dumpsys display 2>/dev/null | grep -o 'fps=[0-9.]*' | sed 's/fps=//; s/\.0*$//' | sort -un | tr '\n' ' ')
  kf_hzn=$(printf '%s\n' $kf_hz | grep -c .)
  if [ "${kf_hzn:-0}" -ge 2 ]; then kf OK "$G1" "Kunci refresh rate tertinggi saat game" "mode layar: ${kf_hz}Hz"
  elif [ "${kf_hzn:-0}" -eq 1 ]; then kf NO "$G1" "Kunci refresh rate tertinggi saat game" "layar hanya punya 1 mode (${kf_hz}Hz) - tidak ada yang bisa dinaikkan"
  else kf UNK "$G1" "Kunci refresh rate tertinggi saat game" "daftar mode layar tidak terbaca dari dumpsys display"
  fi
  kf_blk=""; for kf_b in sda mmcblk0 sdb sdc; do [ -e "$R/sys/block/$kf_b/queue/read_ahead_kb" ] && { kf_blk=$kf_b; break; }; done
  if [ -n "$kf_blk" ] && kf_wtest "$R/sys/block/$kf_blk/queue/read_ahead_kb"; then kf OK "$G1" "Tuning I/O (read-ahead)" "$kf_blk/queue/read_ahead_kb diterima kernel"
  elif [ -n "$kf_blk" ]; then kf NO "$G1" "Tuning I/O (read-ahead)" "$kf_blk ada tapi read_ahead_kb ditolak"
  else kf NO "$G1" "Tuning I/O (read-ahead)" "tidak ada block device utama dengan queue/read_ahead_kb"
  fi
  if [ -e "$R/proc/sys/kernel/sched_boost" ]; then kf OK "$G1" "Scheduler boost (sched_boost)" "node ada"
  else kf NO "$G1" "Scheduler boost (sched_boost)" "node sched_boost TIDAK ada (CONFIG_SCHED_WALT=$(kf_cfg SCHED_WALT)) - boost scheduler di mode Extreme dilewati"
  fi
  if [ -e "$R/dev/cpuctl/top-app/cpu.uclamp.min" ]; then kf OK "$G1" "uclamp top-app" "cpu.uclamp.min ada"
  else kf NO "$G1" "uclamp top-app" "cpu.uclamp.min tidak ada (CONFIG_UCLAMP_TASK=$(kf_cfg UCLAMP_TASK)) - prioritas CPU via uclamp TIDAK bisa"
  fi
  if [ -e "$R/proc/ppm/policy_status" ] || [ -e "$R/sys/module/msm_performance/parameters/cpu_max_freq" ]; then kf OK "$G1" "Abaikan Keamanan Kernel (lepas limiter PPM/msm_performance)" "limiter software terdeteksi & bisa dilepas"
  else kf NO "$G1" "Abaikan Keamanan Kernel (lepas limiter PPM/msm_performance)" "tidak ada PPM maupun msm_performance - tidak ada limiter software yang bisa dilepas"
  fi
  kf_dd=""
  [ -e "$R/proc/cpudvfs/cpufreq_debug" ] && kf_dd="$kf_dd cpudvfs"
  [ -n "$(ls -d "$R"/sys/devices/platform/*dvfsrc* "$R"/sys/kernel/helio-dvfsrc 2>/dev/null | head -n 1)" ] && kf_dd="$kf_dd dvfsrc"
  [ -e "$R/proc/gpufreq/gpufreq_power_limited" ] && kf_dd="$kf_dd gpufreq_power_limited"
  if [ -n "$kf_dd" ]; then kf OK "$G1" "ZAI-Turbo - unlock DVFS MediaTek" "node ada:$kf_dd"
  else kf NO "$G1" "ZAI-Turbo - unlock DVFS MediaTek" "tidak ada cpudvfs/dvfsrc/gpufreq_power_limited (bukan MediaTek?) - langkah unlock ini dilewati"
  fi

  # ---------- Kernel / sistem ----------
  if [ "$kf_cfgok" -eq 0 ]; then kf OK "$G2" "Baca CONFIG kernel (/proc/config.gz)" "terbaca - deteksi di bawah akurat"
  else kf NO "$G2" "Baca CONFIG kernel (/proc/config.gz)" "TIDAK tersedia - deteksi CONFIG di bawah jadi tanda tanya, sebagian pakai uji node langsung"
  fi
  kf_mod=$(kf_cfg MODULES); kf_md=$(dv_cat "$R/proc/sys/kernel/modules_disabled"); kf_se=$(dv_cat "$R/sys/module/module/parameters/sig_enforce")
  if [ "$kf_mod" = n ] || [ "$kf_md" = 1 ]; then kf NO "$G2" "Muat modul kernel (.ko / insmod)" "tidak bisa: CONFIG_MODULES=$kf_mod modules_disabled=${kf_md:--} - patch GPU/OC via .ko TIDAK bisa dimuat"
  elif [ "$kf_se" = Y ] || [ "$(kf_cfg MODULE_SIG_FORCE)" = y ]; then kf PART "$G2" "Muat modul kernel (.ko / insmod)" "hanya modul bertanda tangan kunci kernel (sig_enforce) - .ko hasil patch tanpa tanda tangan DITOLAK"
  elif kf_have_cmd insmod; then kf OK "$G2" "Muat modul kernel (.ko / insmod)" "insmod ada, tidak ada penguncian terdeteksi"
  else kf PART "$G2" "Muat modul kernel (.ko / insmod)" "kernel mengizinkan tapi biner insmod tidak ada"
  fi
  if [ -n "$(ls "$R/sys/kernel/debug" 2>/dev/null | head -n 1)" ]; then kf OK "$G2" "debugfs ter-mount" "/sys/kernel/debug terisi"
  else kf PART "$G2" "debugfs ter-mount" "/sys/kernel/debug kosong/tidak ter-mount - node debug (FPSGO/GED lanjutan) tidak terbaca"
  fi
  kf_sel=$(getenforce 2>/dev/null)
  case "$kf_sel" in
    Permissive) kf OK "$G2" "SELinux" "Permissive - tidak ada pemblokiran policy" ;;
    Enforcing) kf PART "$G2" "SELinux" "Enforcing - sebagian write sysfs vendor bisa ditolak walau root (tergantung policy root manager)" ;;
    *) kf UNK "$G2" "SELinux" "status tidak terbaca" ;;
  esac
  kf_cfgrow() { # kf_cfgrow NAMA "dipakai untuk" "jika tidak ada"
    kr_v=$(kf_cfg "$1")
    case "$kr_v" in
      y|m) kf OK "$G2" "CONFIG_$1" "=$kr_v - $2" ;;
      n) kf NO "$G2" "CONFIG_$1" "TIDAK aktif - $3" ;;
      *) kf UNK "$G2" "CONFIG_$1" "tidak diketahui (config.gz tidak terbaca) - $2" ;;
    esac
  }
  kf_cfgrow CPU_FREQ_GOV_SCHEDUTIL "governor schedutil (mode Balanced)" "mode Balanced tidak bisa pakai schedutil"
  kf_cfgrow CPU_FREQ_GOV_PERFORMANCE "governor performance (Gaming/Turbo)" "mode Gaming/Turbo tidak bisa mengunci governor performance"
  kf_cfgrow CPU_FREQ_GOV_POWERSAVE "governor powersave (Saver)" "mode Saver tidak bisa pakai powersave"
  kf_cfgrow TCP_CONG_BBR "BBR untuk Network Booster" "Network Booster tidak bisa pakai BBR"
  kf_cfgrow ZRAM "zRAM manager" "zRAM manager tidak berguna"
  kf_cfgrow UCLAMP_TASK "uclamp prioritas CPU" "tweak uclamp tidak berguna"
  kf_cfgrow THERMAL_EMULATION "emul_temp (inject suhu)" "inject suhu tidak bisa"
  kf_cfgrow SCHED_WALT "sched_boost / WALT" "sched_boost tidak ada"
  kf_cfgrow CGROUP_FREEZER "pembekuan proses cgroup" "pembekuan cgroup tidak ada (Freeze In-Game memakai pm disable-user, tidak terpengaruh)"
  kf_cfgrow PSI "pressure stall info (monitor tekanan memori/CPU)" "monitor PSI tidak tersedia"
  kf_cfgrow DEBUG_FS "debugfs" "node debug (FPSGO lanjutan) tidak ada"
}

# keluaran mesin (dipakai WebUI): STATUS|GRUP|NAMA|DETAIL
ks_features_run() {
  ks_features > "$KFEAT_OUT.tmp" 2>/dev/null
  mv "$KFEAT_OUT.tmp" "$KFEAT_OUT" 2>/dev/null
  cat "$KFEAT_OUT"
}
KFEAT_OUT="$RUNDIR/kfeat_rows.txt"

# versi teks untuk laporan scan
ks_features_text() {
  ks_features_run | awk -F'|' '
    { st=$1; g=$2; n=$3; d=$4
      tag = (st=="OK") ? "[BISA]       " : (st=="PART") ? "[SEBAGIAN]   " : (st=="NO") ? "[TIDAK BISA] " : "[?]          "
      c[st]++
      if (g!=lastg) { print ""; print "## " g; lastg=g }
      print tag n; print "              " d
      if (st=="NO" && g=="Fitur Zyrox") nolist = nolist "\n  - " n
      if (st=="PART" && g=="Fitur Zyrox") partlist = partlist "\n  - " n
    }
    END {
      print ""
      printf "RINGKASAN: %d bisa | %d sebagian | %d TIDAK bisa | %d tidak diketahui\n", c["OK"], c["PART"], c["NO"], c["UNK"]
      if (nolist != "")   print "Fitur yang TIDAK bisa dipakai di kernel ini:" nolist
      if (partlist != "") print "Fitur yang hanya SEBAGIAN jalan:" partlist
    }'
}

# kernel_scan_run [berkas-opsional]
# Laporan utama LIVE (selalu jalan, tanpa syarat upload). Kalau argumen
# berkas diberikan (hasil upload WebUI/CLI, sama seperti kernel_match_run),
# lampirkan deteksi driver dari string-match sebagai bagian tambahan di akhir.
kernel_scan_run() {
  ks_f=$1
  {
    echo "===================================================================="
    echo " Zyrox - Scan Kernel"
    echo " Waktu: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "===================================================================="
    echo
    echo "--- 1) KERNEL ---"
    echo "Release  : $(uname -r 2>/dev/null)"
    echo "Versi    : $(uname -v 2>/dev/null)"
    echo "Arsitektur: $(uname -m 2>/dev/null)"
    ks_cc=$(grep -Eo '(clang|gcc)[^)]*version[^)]*' "$R/proc/version" 2>/dev/null | head -n 1)
    echo "Compiler : ${ks_cc:-tidak terbaca}"
    echo
    echo "--- 2) BASIS KERNEL ---"
    ks_base=$(ks_detect_base)
    ks_kind=${ks_base%%|*}; ks_why=${ks_base#*|}
    echo "Klasifikasi: $ks_kind"
    echo "$ks_why"
    echo
    echo "--- 3) PERANGKAT / SoC ---"
    echo "Model    : $(dv_first ro.product.model ro.product.vendor.model) (${MARKETNAME:-$(dv_first ro.product.marketname ro.config.marketing_name)})"
    echo "Codename : $(dv_first ro.product.device ro.product.vendor.device)"
    echo "SoC      : $(dv_first ro.soc.manufacturer ro.vendor.soc.manufacturer) $(dv_first ro.soc.model ro.vendor.soc.model ro.hardware.chipname ro.mediatek.platform)"
    echo "Platform : $(getprop ro.board.platform 2>/dev/null)   Hardware: $(dv_first ro.hardware ro.boot.hardware)"
    echo "Android  : $(getprop ro.build.version.release 2>/dev/null) (SDK $(getprop ro.build.version.sdk 2>/dev/null)), patch keamanan $(getprop ro.build.version.security_patch 2>/dev/null)"
    echo
    echo "--- 4) LOCK & KEAMANAN ---"
    ks_lock_security
    echo
    echo "--- 5) FREKUENSI CPU (per cluster) ---"
    ks_cpu_table
    echo
    echo "--- 6) FREKUENSI GPU ---"
    ks_gpu_table
    echo
    echo "--- 7) KOMPATIBILITAS FITUR & BATAS KERNEL ---"
    echo "(diuji dengan tulis-balik nilai yang SAMA - tidak mengubah setelan Anda)"
    ks_features_text
    echo
    echo "Catatan: status LOCK/unlock CPU & GPU di atas dibaca dari scaling_min_freq"
    echo "vs scaling_max_freq SAAT INI (bisa berubah kalau menu Overclock dipakai)."
    echo "Kondisi stok/bawaan pabrik hanya terlihat sebelum ada perubahan di menu itu."

    if [ -n "$ks_f" ] && [ -f "$ks_f" ]; then
      echo
      echo "===================================================================="
      echo " LAMPIRAN: deteksi driver FPSGO dari berkas yang diupload"
      echo "===================================================================="
      ks_tok="$RUNDIR/kscan_tokens.txt"
      km_extract_tokens "$ks_f" > "$ks_tok"
      ks_ntok=$(wc -l < "$ks_tok" 2>/dev/null); ks_ntok=${ks_ntok:-0}
      ks_class=$(km_classify "$ks_f" "$ks_tok")
      ks_fkind=${ks_class%%|*}; ks_fwhy=${ks_class#*|}
      echo "Berkas     : $ks_f ($ks_ntok token unik diekstrak)"
      echo "Klasifikasi: $ks_fkind"
      echo "  $ks_fwhy"
      echo "(jalankan 'azenith-ai kernel match $ks_f' untuk hasil per-node lengkap + opsi terapkan)"
      rm -f "$ks_tok" 2>/dev/null
    fi
  } > "$KSCAN_REPORT"

  cat "$KSCAN_REPORT"
  log_msg "KSCAN: scan kernel live selesai -> $KSCAN_REPORT"
}
