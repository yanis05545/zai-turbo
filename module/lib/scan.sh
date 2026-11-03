#!/system/bin/sh
# =====================================================================
#  Zyrox v2 - lib/scan.sh   (SCANNER DEVICE DINAMIS)
#  Menggantikan path "tebakan generik" v1. Semua keputusan diambil dari
#  hasil membaca /sys, /proc dan getprop DEVICE ITU SENDIRI, lalu disimpan
#  ke $SCANDIR (profile.conf + file daftar). Node yang tidak ditemukan
#  = fitur terkait di-skip, bukan ditebak.
#
#  Output:
#    profile.conf       SOC_VENDOR SOC_NAME TIER RAM_MB ... (di-source)
#    cpu_policies       name|path|minkhz|maxkhz|bobot|tabel_freq
#    gpu / gpu_tbl      backend|path|... dan tabel frekuensi
#    zones              idx|type|kelas(soc/batt/skin/other)|emul|trip
#    thermal_services   service daemon thermal yang aman di-stop
#    thermal_props      prop bergaya "disable" yang nilainya masih 0
#    thermal_vendor     node vendor penonaktif throttle (mode hard)
#    fpsgo_nodes.txt    inventaris node FPSGO + nilai saat ini
#    fpsgo_index        nama|path|rw|nilai (dipakai tabel node)
#    fpsgo_candidates.txt  klasifikasi tiap node (bin/num/str, katalog/disc)
#    fps_sources        sumber FPS yang tersedia
#    scan_report.txt    laporan yang bisa dikirim untuk debug
# =====================================================================

tbl_sort() { tr -s ' \t\n' '\n' | grep -E '^[0-9]+$' | sort -n | tr '\n' ' ' | sed 's/ *$//'; }

# ------------------------------- SoC ---------------------------------
scan_soc() {
  sc_hw=$(getp ro.hardware); sc_plat=$(getp ro.board.platform)
  sc_mf=$(getp ro.soc.manufacturer); sc_md=$(getp ro.soc.model)
  sc_brd=$(getp ro.product.board); sc_chip=$(getp ro.hardware.chipname)
  sc_mtk=$(getp ro.mediatek.platform)
  sc_fam=$(read1 "$R/sys/devices/soc0/family")
  sc_mach=$(read1 "$R/sys/devices/soc0/machine")
  sc_cpuinfo=$({ grep -m1 -i '^Hardware' "$R/proc/cpuinfo"; } 2>/dev/null | sed 's/.*: *//')
  SOC_RAW=$(lower "$sc_hw $sc_plat $sc_mf $sc_md $sc_brd $sc_chip $sc_mtk $sc_fam $sc_mach $sc_cpuinfo")
  SOC_NAME=${sc_plat:-$sc_hw}; SOC_NAME=${SOC_NAME:-unknown}

  SOC_VENDOR=other
  case " $SOC_RAW " in
    *qcom*|*qualcomm*|*snapdragon*|*" sm"[0-9][0-9][0-9][0-9]*|*sdm[0-9]*|*msm[0-9]*|*" kona "*|*" lahaina "*|*" taro "*|*" kalama "*|*" pineapple "*|*" sun "*|*" canoe "*|*" lito "*|*" bengal "*|*" holi "*|*" trinket "*|*" atoll "*|*" parrot "*|*" crow "*|*" blair "*|*" monaco "*|*" cliffs "*|*" waipio "*|*" yupik "*|*" shima "*|*" ukee "*|*" sdm"*) SOC_VENDOR=qcom ;;
    *mt[0-9][0-9][0-9][0-9]*|*mediatek*|*mtk*|*helio*|*dimensity*) SOC_VENDOR=mtk ;;
    *exynos*|*s5e[0-9]*|*universal[0-9]*|*samsung*) SOC_VENDOR=exynos ;;
    *" gs101 "*|*" gs201 "*|*" zuma"*|*tensor*|*" laguna "*) SOC_VENDOR=tensor ;;
    *unisoc*|*spreadtrum*|*sprd*|*ums[0-9]*|*" sc"[0-9][0-9][0-9][0-9]*|*ud710*|*s9863*|*" t6"[0-9][0-9]*|*" t7"[0-9][0-9]*|*" t8"[0-9][0-9]*) SOC_VENDOR=unisoc ;;
    *kirin*|*" hi"[0-9][0-9][0-9][0-9]*) SOC_VENDOR=kirin ;;
  esac
  # tanda tangan sysfs mengalahkan tebakan nama (lebih dapat dipercaya)
  if [ -d "$R/sys/kernel/fpsgo" ] || [ -d "$R/proc/fpsgo" ] || [ -d "$R/sys/kernel/ged" ] || \
     [ -d "$R/proc/gpufreq" ] || [ -d "$R/proc/gpufreqv2" ] || [ -d "$R/proc/mtk_battery_cmd" ]; then
    SOC_VENDOR=mtk
  elif [ -d "$R/sys/class/kgsl/kgsl-3d0" ]; then
    SOC_VENDOR=qcom
  elif [ -d "$R/sys/kernel/gpu" ] && [ "$SOC_VENDOR" = other ]; then
    SOC_VENDOR=exynos
  fi
}

# ------------------------------- ROM ----------------------------------
# Deteksi "keluarga" ROM: stock (bawaan pabrik) | gsi (Treble generic system
# image) | custom (porting/ROM pihak ketiga) | unknown (tak ada sinyal
# cukup). TIDAK berdasar daftar nama ROM (lineage/pixelexperience/dst, yang
# akan selalu ketinggalan) - berdasar sinyal struktural Android sendiri:
#   * Treble GSI: partisi system mengaku brand/fingerprint berbeda dari
#     brand fisik device (ro.product.system.* vs ro.product.vendor.*/
#     manufacturer) - ini CARA RESMI Android membedakan image system dari
#     device, dipakai juga oleh Google VTS.
#   * signing keys: release-keys (pabrik, ditandatangani resmi) vs
#     test-keys/dev-keys (AOSP build lokal - hampir semua custom ROM & GSI
#     unofficial pakai ini).
#   * build type: user (pabrik) vs userdebug/eng (dev build - custom ROM
#     hampir selalu salah satu ini).
# Dipakai HANYA untuk pesan diagnostik (laporan/WebUI/kernel match) - tidak
# ada fitur apply yang digerbang olehnya, karena semua node tetap divalidasi
# langsung ke sysfs device ini (lihat README "Catatan jujur"); ROM custom
# atau porting kadang mengubah/menghapus node vendor, jadi deteksi ini
# membantu user paham KENAPA sebuah fitur skip, bukan menentukan boleh/tidak.
scan_rom() {
  rm_fp=$(getp ro.build.fingerprint)
  rm_tags=$(getp ro.build.tags)
  rm_type=$(getp ro.build.type)
  rm_treble=$(getp ro.treble.enabled)
  rm_mf=$(lower "$(getp ro.product.manufacturer)")
  rm_devbrand=$(lower "$(getp ro.product.vendor.brand)"); [ -n "$rm_devbrand" ] || rm_devbrand=$(lower "$(getp ro.product.brand)")
  rm_sysbrand=$(lower "$(getp ro.product.system.brand)")
  rm_sysname=$(lower "$(getp ro.product.system.name)")
  rm_sysfp=$(lower "$(getp ro.system.build.fingerprint)")

  # GSI (Treble generic system image) dideteksi SEMPIT, hanya dari nama
  # produk/fingerprint yang literally "generic"/"aosp_*"/"gsi_*" - itu konvensi
  # penamaan resmi Android untuk image GSI (baik GSI resmi Google maupun GSI
  # unofficial build), bukan dari "brand partisi system beda dari device",
  # karena hampir SEMUA custom ROM (termasuk porting penuh yang punya vendor
  # sendiri, bukan GSI) juga mengganti ro.product.system.brand ke nama ROM-nya
  # sendiri - kalau dipakai sebagai sinyal GSI, setiap custom ROM salah
  # terklasifikasi "gsi" padahal driver vendornya bisa saja lengkap.
  rm_gsi=0; rm_why=""
  case "$rm_fp" in generic/*|*/aosp_*|*/gsi_*) rm_gsi=1; rm_why="fingerprint sistem: '$rm_fp' (pola generic/aosp_/gsi_)" ;; esac
  case "$rm_sysfp" in generic/*|*/aosp_*|*/gsi_*) rm_gsi=1; rm_why="${rm_why:+$rm_why; }ro.system.build.fingerprint berpola GSI" ;; esac
  case "$rm_sysname" in generic|gsi_*|aosp_arm*|aosp_x86*) rm_gsi=1; rm_why="${rm_why:+$rm_why; }ro.product.system.name='$rm_sysname'" ;; esac

  rm_custom=0; rm_cwhy=""
  case "$rm_tags" in *test-keys*|*dev-keys*) rm_custom=1; rm_cwhy="ditandatangani $rm_tags (bukan release-keys pabrik)" ;; esac
  case "$rm_type" in userdebug|eng) rm_custom=1; rm_cwhy="${rm_cwhy:+$rm_cwhy; }build type=$rm_type (bukan user/pabrik)" ;; esac
  if [ -n "$rm_sysbrand" ] && [ "$rm_sysbrand" != "$rm_devbrand" ] && [ "$rm_sysbrand" != "$rm_mf" ]; then
    rm_custom=1; rm_cwhy="${rm_cwhy:+$rm_cwhy; }partisi system brand='$rm_sysbrand' != device brand/manufacturer='${rm_devbrand:-$rm_mf}' (ROM pihak ketiga, vendor partition biasanya tetap bawaan device)"
  fi
  rm_why="${rm_why:+$rm_why; }${rm_cwhy}"

  # Prioritas: sinyal GSI (partisi system generik/beda brand) menang atas sinyal
  # custom-keys/userdebug, karena keduanya SERING sama-sama benar di satu device
  # (image GSI resmi pun lazimnya userdebug/test-keys) tapi risikonya beda:
  # GSI = driver vendor (termasuk FPSGO) kemungkinan tidak ada sama sekali, itu
  # sinyal yang jauh lebih penting untuk kernel_match.sh daripada "bukan pabrik".
  if   [ "$rm_gsi" = 1 ]; then ROM_FAMILY=gsi
  elif [ "$rm_custom" = 1 ]; then ROM_FAMILY=custom
  elif [ -n "$rm_fp" ]; then ROM_FAMILY=stock
  else ROM_FAMILY=unknown; rm_why="fingerprint build kosong/tidak terbaca"
  fi
  ROM_TREBLE=$([ "$rm_treble" = true ] && echo 1 || echo 0)
  ROM_WHY=${rm_why:-"tanda tangan release-keys, build user, partisi system cocok dengan device - ciri ROM bawaan pabrik"}
  ROM_VENDOR_LIKELY_OK=1
  case "$ROM_FAMILY" in
    gsi) ROM_VENDOR_LIKELY_OK=0 ;;        # GSI sering tanpa driver vendor penuh (lihat kernel_match.sh)
    custom) ROM_VENDOR_LIKELY_OK=1 ;;     # porting/custom ROM biasanya tetap pakai kernel+vendor asli device
  esac
}

# ------------------------------- CPU ---------------------------------
scan_cpu() {
  : > "$SCANDIR/cpu_raw"
  for sp in "$R"/sys/devices/system/cpu/cpufreq/policy*; do
    [ -d "$sp" ] || continue
    sp_n=${sp##*/}
    sp_min=$(read1 "$sp/cpuinfo_min_freq"); sp_max=$(read1 "$sp/cpuinfo_max_freq")
    [ -n "$sp_max" ] || continue
    sp_t=$({ tbl_sort < "$sp/scaling_available_frequencies"; } 2>/dev/null)
    [ -z "$sp_t" ] && sp_t=$({ awk '{print $1}' "$sp/stats/time_in_state" | tbl_sort; } 2>/dev/null)
    [ -z "$sp_t" ] && sp_t="$sp_min $sp_max"
    echo "$sp_max|$sp_n|$sp|${sp_min:-0}|$sp_t" >> "$SCANDIR/cpu_raw"
  done
  if [ ! -s "$SCANDIR/cpu_raw" ]; then
    # kernel lama tanpa cpufreq/policy*: kelompokkan per related_cpus
    sp_seen=" "
    for sc in "$R"/sys/devices/system/cpu/cpu[0-9]*/cpufreq; do
      [ -d "$sc" ] || continue
      sp_rel=$(cat "$sc/related_cpus" 2>/dev/null | tr ' ' '_'); sp_rel=${sp_rel:-$sc}
      case "$sp_seen" in *" $sp_rel "*) continue ;; esac
      sp_seen="$sp_seen$sp_rel "
      sp_min=$(read1 "$sc/cpuinfo_min_freq"); sp_max=$(read1 "$sc/cpuinfo_max_freq")
      [ -n "$sp_max" ] || continue
      sp_t=$({ tbl_sort < "$sc/scaling_available_frequencies"; } 2>/dev/null)
      [ -z "$sp_t" ] && sp_t="$sp_min $sp_max"
      sp_c=${sc%/cpufreq}; sp_c=${sp_c##*/}
      echo "$sp_max|$sp_c|$sc|${sp_min:-0}|$sp_t" >> "$SCANDIR/cpu_raw"
    done
  fi
  : > "$SCANDIR/cpu_policies"
  N_CLUSTERS=0; CPU_MAXKHZ=0
  if [ -s "$SCANDIR/cpu_raw" ]; then
    sort -t'|' -k1,1nr "$SCANDIR/cpu_raw" > "$SCANDIR/cpu_sorted"
    N_CLUSTERS=$(wc -l < "$SCANDIR/cpu_sorted"); N_CLUSTERS=$((N_CLUSTERS + 0))
    sp_i=0
    while IFS='|' read -r sp_max sp_n sp_p sp_min sp_t; do
      sp_i=$((sp_i + 1))
      [ "$sp_i" = 1 ] && CPU_MAXKHZ=$sp_max
      if   [ "$N_CLUSTERS" -eq 1 ]; then sp_w=100
      elif [ "$N_CLUSTERS" -eq 2 ]; then [ "$sp_i" = 1 ] && sp_w=100 || sp_w=55
      else
        if   [ "$sp_i" = 1 ]; then sp_w=70
        elif [ "$sp_i" = "$N_CLUSTERS" ]; then sp_w=55
        else sp_w=100; fi
      fi
      echo "$sp_n|$sp_p|$sp_min|$sp_max|$sp_w|$sp_t" >> "$SCANDIR/cpu_policies"
    done < "$SCANDIR/cpu_sorted"
  fi
  NCPU=$(grep -c '^processor' "$R/proc/cpuinfo" 2>/dev/null); NCPU=${NCPU:-0}
}

# ------------------------------- GPU ---------------------------------
gpu_table_mtk() {
  for gt_f in "$R/proc/gpufreqv2/gpu_working_opp_table" "$R/proc/gpufreq/gpufreq_opp_dump" \
              "$R/proc/gpufreqv2/gpu_signed_opp_table"; do
    [ -r "$gt_f" ] || continue
    gt_t=$(sed -n 's/.*freq[ =:]*\([0-9][0-9]*\).*/\1/p' "$gt_f" 2>/dev/null | tbl_sort)
    [ -n "$gt_t" ] && { echo "$gt_t"; return 0; }
  done
  return 1
}

scan_gpu() {
  GPU_BACKEND=none; GPU_PATH=""; : > "$SCANDIR/gpu"; : > "$SCANDIR/gpu_tbl"
  gp_cands=""
  [ -d "$R/sys/class/kgsl/kgsl-3d0/devfreq" ] && gp_cands="$R/sys/class/kgsl/kgsl-3d0/devfreq"
  for gd in "$R"/sys/class/devfreq/*; do
    [ -d "$gd" ] || continue
    [ -e "$gd/min_freq" ] && [ -e "$gd/available_frequencies" ] || continue
    gp_n=${gd##*/}
    gp_s=$(lower "$gp_n $(readlink -f "$gd" 2>/dev/null)")
    case "$gp_s" in
      *busmon*|*bw*|*ddr*|*llcc*|*cache*|*cpu-lat*|*l3*|*snoc*|*cnoc*|*display*|*npu*|*ufs*|*mmc*|*venus*|*cam*|*dvfsrc*) continue ;;
      *kgsl-3d*|*mali*|*gpu*|*g3d*|*rgx*|*pvr*|*sgx*|*adreno*) gp_cands="$gp_cands $gd" ;;
    esac
  done
  gp_best=""; gp_bestmax=0
  for gd in $gp_cands; do
    gp_t=$({ tbl_sort < "$gd/available_frequencies"; } 2>/dev/null)
    [ -n "$gp_t" ] || continue
    gp_m=${gp_t##* }
    if [ "$gp_m" -gt "$gp_bestmax" ] 2>/dev/null; then gp_bestmax=$gp_m; gp_best=$gd; gp_bt=$gp_t; fi
  done
  if [ -n "$gp_best" ]; then
    GPU_BACKEND=devfreq; GPU_PATH=$gp_best
    echo "devfreq|$gp_best|min_freq|max_freq" > "$SCANDIR/gpu"
    echo "$gp_bt" > "$SCANDIR/gpu_tbl"
  elif [ -e "$R/sys/module/ged/parameters/gpu_cust_boost_freq" ]; then
    gp_t=$(gpu_table_mtk)
    GPU_BACKEND=mtk_ged; GPU_PATH="$R/sys/module/ged/parameters"
    echo "mtk_ged|$GPU_PATH|gpu_cust_boost_freq|gpu_cust_upbound_freq" > "$SCANDIR/gpu"
    [ -n "$gp_t" ] && echo "$gp_t" > "$SCANDIR/gpu_tbl"
  elif [ -e "$R/sys/kernel/gpu/gpu_min_clock" ]; then
    gp_t=$({ tbl_sort < "$R/sys/kernel/gpu/gpu_available_frequencies"; } 2>/dev/null)
    GPU_BACKEND=exynos_kgpu; GPU_PATH="$R/sys/kernel/gpu"
    echo "exynos_kgpu|$GPU_PATH|gpu_min_clock|gpu_max_clock" > "$SCANDIR/gpu"
    [ -n "$gp_t" ] && echo "$gp_t" > "$SCANDIR/gpu_tbl"
  fi
  # penanda tambahan untuk laporan
  GPU_MAXHZ=0
  [ -s "$SCANDIR/gpu_tbl" ] && { gp_t=$(cat "$SCANDIR/gpu_tbl"); GPU_MAXHZ=${gp_t##* }; }
  # UFS devfreq (dipakai fitur IO)
  : > "$SCANDIR/ufs_devfreq"
  for gd in "$R"/sys/class/devfreq/*ufs*; do
    [ -d "$gd" ] && [ -e "$gd/min_freq" ] && echo "$gd" >> "$SCANDIR/ufs_devfreq"
  done
}

# ------------------------------ Tier ---------------------------------
scan_tier() {
  RAM_KB=$(awk '/^MemTotal/{print $2}' "$R/proc/meminfo" 2>/dev/null); RAM_KB=${RAM_KB:-0}
  RAM_MB=$((RAM_KB / 1024))
  ti=0
  if   [ "$RAM_MB" -ge 10500 ]; then ti=$((ti+3))
  elif [ "$RAM_MB" -ge 7000 ];  then ti=$((ti+2))
  elif [ "$RAM_MB" -ge 5200 ];  then ti=$((ti+1))
  elif [ "$RAM_MB" -lt 3500 ];  then ti=$((ti-1)); fi
  if   [ "$CPU_MAXKHZ" -ge 3000000 ]; then ti=$((ti+2))
  elif [ "$CPU_MAXKHZ" -ge 2600000 ]; then ti=$((ti+1))
  elif [ "$CPU_MAXKHZ" -lt 2100000 ] && [ "$CPU_MAXKHZ" -gt 0 ]; then ti=$((ti-1)); fi
  [ "$N_CLUSTERS" -ge 3 ] && ti=$((ti+1))
  if   [ "$ti" -ge 5 ]; then TIER=flagship
  elif [ "$ti" -ge 3 ]; then TIER=high
  elif [ "$ti" -ge 1 ]; then TIER=mid
  else TIER=low; fi
  # peta SoC yang sudah dikenal (hanya menggeser tier bila skor menyesatkan)
  case " $SOC_RAW " in
    *" kona "*|*" lahaina "*|*" taro "*|*" kalama "*|*" pineapple "*|*" sun "*|*" canoe "*|*sm8[2-7][0-9][0-9]*|*mt6983*|*mt6985*|*mt6989*|*mt6991*|*s5e9925*|*s5e9945*|*s5e9840*)
      TIER=flagship ;;
    *" lito "*|*" cliffs "*|*mt6893*|*mt6895*|*mt6896*|*mt6897*|*" gs101 "*|*" gs201 "*|*" zuma"*|*sm7[3-7][0-9][0-9]*)
      [ "$TIER" = mid ] || [ "$TIER" = low ] && TIER=high ;;
    *ums512*|*sc9863*|*ums9230*|*ums312*|*sc7731*|*mt6761*|*mt6762*|*mt6765*|*mt6739*|*mt6580*|*" holi "*|*" bengal "*)
      [ "$TIER" = flagship ] || [ "$TIER" = high ] || TIER=low ;;
  esac
}

# --------------------------- Thermal scan ----------------------------
zone_class() {
  case "$1" in
    *batt*|*bms*|*charg*|*usb*|*wireless*|*fuelgauge*|*connector*) echo batt ;;
    *skin*|*quiet*|*xo-therm*|*xo_therm*|*sdr*|*bts*|*ambient*|*shell*|*case*|*board*|*msm-therm*|*back*|*front*|*flash*|*emmc*) echo skin ;;
    *modem*|*mdm*|*pa-therm*|*pa_therm*|*pmic*|*pm[0-9]*|*ddr*|*video*|*aoss*|*camera*|*cam*|*wlan*|*lcd*|*display*|*ufs*|*audio*|*qmi*|*sub1*) echo other ;;
    *cpu*|*gpu*|*g3d*|*big*|*mid*|*little*|*prime*|*gold*|*silver*|*soc*|*apc*|*cluster*|*tsens_tz_sensor*|*mtktsap*|*ap_therm*|*nsp*|*npu*|*mtktscpu*|*gpuss*|*cpuss*) echo soc ;;
    *) echo other ;;
  esac
}

scan_thermal() {
  : > "$SCANDIR/zones"
  for z in "$R"/sys/class/thermal/thermal_zone*; do
    [ -d "$z" ] || continue
    z_i=${z##*thermal_zone}
    z_t=$(lower "$(read1 "$z/type")")
    [ -n "$z_t" ] || z_t=zone$z_i
    z_c=$(zone_class "$z_t")
    z_v=$(read1 "$z/temp"); norm_temp "$z_v" >/dev/null || continue
    z_e=0; [ -e "$z/emul_temp" ] && z_e=1
    z_tp=0; [ -e "$z/trip_point_0_temp" ] && z_tp=1
    echo "$z_i|$z_t|$z_c|$z_e|$z_tp" >> "$SCANDIR/zones"
  done

  # service daemon thermal (allow-list; HAL/symlink sengaja tidak disentuh)
  : > "$SCANDIR/thermal_services"
  getprop 2>/dev/null | sed -n 's/^\[init\.svc\.\([^]]*thermal[^]]*\)\]: \[\(.*\)\]/\1|\2/p' | \
  while IFS='|' read -r ts_n ts_s; do
    case "$ts_n" in
      *thermal-engine*|*thermald*|*thermal_manager*|*thermalloadalgod*|*thermal_core*|*thermalcore*|*thermal-daemon*|*thermal-hal*|*thermal_space*|*thermalspace*)
        echo "$ts_n|$ts_s" >> "$SCANDIR/thermal_services" ;;
    esac
  done

  # prop bergaya "disable/bypass/ignore" yang saat ini bernilai 0
  : > "$SCANDIR/thermal_props"
  getprop 2>/dev/null | grep -i thermal | sed -n 's/^\[\([^]]*\)\]: \[\(.*\)\]/\1|\2/p' | \
  while IFS='|' read -r tp_k tp_v; do
    case "$tp_k" in ro.*) continue ;; esac
    case "$(lower "$tp_k")" in
      *disable*thermal*|*thermal*disable*|*bypass*thermal*|*thermal*bypass*|*ignore*thermal*|*thermal*ignore*)
        [ "$tp_v" = 0 ] && echo "$tp_k|1" >> "$SCANDIR/thermal_props" ;;
    esac
  done

  # node vendor penonaktif throttle (dipakai hanya di THERMAL_MODE=hard)
  : > "$SCANDIR/thermal_vendor"
  while IFS='|' read -r tv_p tv_v; do
    [ -e "$R$tv_p" ] && echo "$R$tv_p|$tv_v" >> "$SCANDIR/thermal_vendor"
  done <<'VEND'
/sys/class/kgsl/kgsl-3d0/throttling|0
/sys/class/kgsl/kgsl-3d0/thermal_pwrlevel|0
/sys/module/msm_thermal/parameters/enabled|N
/sys/module/msm_thermal/core_control/enabled|0
/sys/kernel/msm_thermal/enabled|0
/proc/gpufreq/gpufreq_limited_thermal_ignore|1
VEND
}

# ---------------------------- FPS / FPSGO ----------------------------
scan_fps() {
  HAS_FPSGO=0
  : > "$SCANDIR/fpsgo_nodes.txt"; : > "$SCANDIR/fpsgo_index"
  for fd in "$R/sys/kernel/fpsgo" "$R/proc/fpsgo" "$R/sys/module/mtk_fpsgo/parameters" "$R/proc/perfmgr"; do
    [ -d "$fd" ] || continue
    HAS_FPSGO=1
    echo "## $fd" >> "$SCANDIR/fpsgo_nodes.txt"
    for fn in "$fd"/* "$fd"/*/*; do
      [ -f "$fn" ] || continue
      fv=$({ head -c 80 "$fn" | head -n1; } 2>/dev/null)
      fm=ro; [ -w "$fn" ] && fm=rw
      echo "$fm ${fn#$R}  =  $fv" >> "$SCANDIR/fpsgo_nodes.txt"
      echo "${fn##*/}|${fn#$R}|$fm|$fv" >> "$SCANDIR/fpsgo_index"
    done
  done
  fpsgo_classify
  # urutan prioritas sumber FPS: fpsgo -> per-layer SurfaceFlinger -> display driver
  FPS_ORDER=""
  for ff in "$R/sys/kernel/fpsgo/fstb/fpsgo_status" "$R/proc/fpsgo/fstb/fpsgo_status" "$R/sys/kernel/fpsgo/fstb/fstb_status"; do
    [ -r "$ff" ] && { FPS_ORDER="fpsgo"; FPSGO_STATUS_FILE=${ff#$R}; break; }
  done
  command -v dumpsys >/dev/null 2>&1 && FPS_ORDER="$FPS_ORDER sf_latency"
  [ -r "$R/sys/class/drm/sde-crtc-0/measured_fps" ] && FPS_ORDER="$FPS_ORDER sde"
  [ -r "$R/sys/class/graphics/fb0/measured_fps" ] && FPS_ORDER="$FPS_ORDER fbm"
  FPS_ORDER=$(echo $FPS_ORDER)
  echo "$FPS_ORDER" > "$SCANDIR/fps_sources"
}

# ------------------------ Foreground app method ----------------------
fg_extract() { # stdin: satu baris dumpsys -> nama paket
  sed -n 's/.* u[0-9][0-9]* \([A-Za-z0-9_.][A-Za-z0-9_.]*\)\/.*/\1/p' | head -n1
}

fg_try() { # fg_try <metode> -> paket
  case "$1" in
    1) tmo 4 dumpsys activity activities 2>/dev/null | grep -m1 -E 'topResumedActivity' | fg_extract ;;
    2) tmo 4 dumpsys window 2>/dev/null | grep -m1 -E 'mCurrentFocus=' | fg_extract ;;
    3) tmo 4 dumpsys activity activities 2>/dev/null | grep -m1 -E 'mResumedActivity|ResumedActivity:' | fg_extract ;;
    4) tmo 4 dumpsys window windows 2>/dev/null | grep -m1 -E 'mCurrentFocus|mFocusedApp' | fg_extract ;;
  esac
}

scan_fg() {
  FG_METHOD=0
  for fm in 1 2 3 4; do
    fp=$(fg_try $fm)
    case "$fp" in *.*) FG_METHOD=$fm; return 0 ;; esac
  done
}

# ------------------------------ Orkestrasi ---------------------------
scan_fingerprint() { echo "$(getp ro.build.fingerprint)|$(uname -r 2>/dev/null)|$TX_VER"; }

scan_all() {
  log_msg "SCAN: mulai"
  rm -f "$SCANDIR"/*.tmp
  scan_soc; scan_rom; scan_cpu; scan_gpu; scan_tier; scan_thermal; scan_fps; scan_fg
  nz_soc=$(grep -c '|soc|' "$SCANDIR/zones" 2>/dev/null); nz_all=$(wc -l < "$SCANDIR/zones" 2>/dev/null)
  {
    echo "SCAN_FP='$(scan_fingerprint)'"
    echo "SCAN_TIME=$(date +%s)"
    echo "SOC_VENDOR=$SOC_VENDOR"
    echo "SOC_NAME='$SOC_NAME'"
    echo "ROM_FAMILY=$ROM_FAMILY"
    echo "ROM_TREBLE=$ROM_TREBLE"
    echo "ROM_WHY='$ROM_WHY'"
    echo "ROM_VENDOR_LIKELY_OK=$ROM_VENDOR_LIKELY_OK"
    echo "TIER=$TIER"
    echo "RAM_MB=$RAM_MB"
    echo "NCPU=$NCPU"
    echo "N_CLUSTERS=$N_CLUSTERS"
    echo "CPU_MAXKHZ=$CPU_MAXKHZ"
    echo "GPU_BACKEND=$GPU_BACKEND"
    echo "GPU_MAXHZ=$GPU_MAXHZ"
    echo "HAS_FPSGO=$HAS_FPSGO"
    echo "FPSGO_STATUS_FILE='${FPSGO_STATUS_FILE:-}'"
    echo "FPS_ORDER='$FPS_ORDER'"
    echo "FG_METHOD=$FG_METHOD"
    echo "N_ZONES=${nz_all:-0}"
    echo "N_ZONES_SOC=${nz_soc:-0}"
  } > "$PROFILE.tmp" && mv -f "$PROFILE.tmp" "$PROFILE"
  scan_report > "$SCANDIR/scan_report.txt"
  log_msg "SCAN: selesai vendor=$SOC_VENDOR rom=$ROM_FAMILY tier=$TIER cluster=$N_CLUSTERS gpu=$GPU_BACKEND zona=${nz_all:-0} fpsgo=$HAS_FPSGO fps=[$FPS_ORDER] fg=$FG_METHOD"
}

scan_if_needed() {
  if [ ! -s "$PROFILE" ]; then scan_all; load_conf; return; fi
  sin_old=$(sed -n "s/^SCAN_FP='\(.*\)'/\1/p" "$PROFILE")
  [ "$sin_old" = "$(scan_fingerprint)" ] || { log_msg "SCAN: fingerprint berubah, scan ulang"; scan_all; }
  load_conf
}

scan_report() {
  echo "Zyrox $TX_VER scan report - $(date)"
  echo "Model     : $(getp ro.product.manufacturer) $(getp ro.product.model)"
  echo "Android   : $(getp ro.build.version.release) (SDK $(getp ro.build.version.sdk))"
  echo "Kernel    : $(uname -r 2>/dev/null)"
  echo "SoC       : vendor=$SOC_VENDOR name=$SOC_NAME raw='$(echo $SOC_RAW)'"
  echo "ROM       : $ROM_FAMILY (treble=$ROM_TREBLE) - $ROM_WHY"
  echo "Tier      : $TIER   (RAM ${RAM_MB}MB, CPU max ${CPU_MAXKHZ}kHz, cluster $N_CLUSTERS)"
  echo "GPU       : backend=$GPU_BACKEND path=${GPU_PATH#$R} max=$GPU_MAXHZ"
  echo "FPSGO     : $HAS_FPSGO   sumber FPS: [$FPS_ORDER]   metode foreground: $FG_METHOD"
  echo; echo "--- CPU policy (nama|min|max|bobot) ---"
  awk -F'|' '{n=split($6,a," "); print $1"  min="$3"  max="$4"  bobot="$5"  jumlah_opp="n}' "$SCANDIR/cpu_policies"
  echo; echo "--- Zona thermal (idx|type|kelas|emul|trip) ---"
  cat "$SCANDIR/zones"
  echo; echo "--- Service thermal yang bisa di-stop ---"; cat "$SCANDIR/thermal_services"
  echo "--- Prop disable-thermal ---"; cat "$SCANDIR/thermal_props"
  echo "--- Node vendor penonaktif throttle ---"; cat "$SCANDIR/thermal_vendor"
  echo; echo "--- Inventaris FPSGO ---"; head -n 80 "$SCANDIR/fpsgo_nodes.txt"
}
