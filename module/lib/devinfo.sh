#!/system/bin/sh
# =====================================================================
#  Zyrox - lib/devinfo.sh
#  Info perangkat untuk kartu "Status Perangkat" di WebUI (format key=value).
#    devinfo_all   : semua (statis + live)         -> azenith-ai devinfo
#    devinfo_live  : hanya yang berubah-ubah (cepat, tanpa getprop/dumpsys)
#  Semua nilai dibaca langsung dari device (getprop, /proc, /sys, df) - tidak
#  ada tabel perangkat bawaan. Klasifikasi ROM (stock/aosp/port/gsi) adalah
#  HEURISTIK dari sinyal struktural Android, bukan jaminan 100%; alasan dan
#  tingkat keyakinannya ikut ditampilkan (rom_why / rom_conf).
# =====================================================================

dv_p() { printf '%s=%s\n' "$1" "$(printf '%s' "$2" | tr -d '\r\n')"; }
dv_first() { # nilai prop pertama yang tidak kosong
  for dv_k in "$@"; do dv_v=$(getprop "$dv_k" 2>/dev/null); [ -n "$dv_v" ] && { printf '%s' "$dv_v"; return 0; }; done
  return 0
}
dv_cat() { [ -r "$1" ] || return 0; read -r dv_l < "$1" 2>/dev/null; printf '%s' "$dv_l"; }
dv_lc() { printf '%s' "$*" | tr 'A-Z' 'a-z'; }

# ------------------------------ GPU -----------------------------------
# Catatan vendor: dulu node devfreq GPU dicari dengan pola yang condong ke
# Mali/MediaTek (*mali*|*gpu*|*g3d*|*kgsl*|*gpufreq*). Sekarang pola diperluas
# supaya node devfreq GPU dari Adreno (Qualcomm, biasanya di bawah
# kgsl-3d0/devfreq) dan PowerVR/IMG (Imagination, biasanya "rogue"/"rgx"/"pvr"/
# "sgx" di nama node) juga ketemu, bukan cuma Mali.
dv_gpu_node() { # set DV_GN ke direktori devfreq/kgsl GPU (kosong kalau tidak ada)
  DV_GN=""
  # kgsl (Adreno) dicek duluan - devfreq-nya bukan langsung di sys/class/devfreq,
  # tapi di sys/class/kgsl/kgsl-3d0/devfreq, jadi pola generik di bawah tidak nemu dia.
  if [ -d "$R/sys/class/kgsl/kgsl-3d0/devfreq" ]; then
    DV_GN="$R/sys/class/kgsl/kgsl-3d0/devfreq"; return 0
  fi
  for dv_d in "$R"/sys/class/devfreq/*; do
    [ -d "$dv_d" ] || continue
    case "${dv_d##*/}" in
      *mali*|*gpu*|*g3d*|*kgsl*|*gpufreq*|*adreno*|*rogue*|*rgx*|*pvr*|*sgx*|*imgtec*)
        DV_GN=$dv_d; return 0 ;;
    esac
  done
  [ -d "$R/sys/class/kgsl/kgsl-3d0" ] && DV_GN="$R/sys/class/kgsl/kgsl-3d0"
  return 0
}

# Deteksi vendor GPU (Mali/ARM, Adreno/Qualcomm, PowerVR/Imagination) + nama
# model kalau kernel membocorkannya lewat sysfs/debugfs/proc resmi vendor itu
# (bukan tebakan dari nama node semata). Hasil: GV_VENDOR, GV_NAME.
dv_gpu_vendor() {
  GV_VENDOR=""; GV_NAME=""
  dv_gpu_node
  dv_dn_low=$(dv_lc "${DV_GN##*/} $(readlink -f "$DV_GN" 2>/dev/null)")

  # 1) Adreno (Qualcomm) - node resmi kgsl, gpu_model berisi nama chip asli
  #    (mis. "Adreno650v2") kalau devfreq GPU memang kgsl-3d0.
  if [ -d "$R/sys/class/kgsl/kgsl-3d0" ]; then
    gv_m=$(dv_cat "$R/sys/class/kgsl/kgsl-3d0/gpu_model")
    if [ -n "$gv_m" ]; then GV_VENDOR="Adreno (Qualcomm)"; GV_NAME=$gv_m; return 0; fi
    case "$dv_dn_low" in *kgsl*|*adreno*) GV_VENDOR="Adreno (Qualcomm)"; return 0 ;; esac
  fi

  # 2) PowerVR (Imagination) - driver rogue/pvrsrvkm expose versi di debugfs/proc.
  for gv_f in "$R/sys/kernel/debug/pvr/version" "$R/proc/pvr/version" \
              "$R/sys/kernel/debug/pvr/driver_info"; do
    [ -r "$gv_f" ] || continue
    gv_m=$(dv_cat "$gv_f")
    GV_VENDOR="PowerVR (Imagination)"; GV_NAME=$gv_m; return 0
  done
  if [ -d "$R/sys/module/pvrsrvkm" ] || [ -d "$R/sys/module/rogue" ] || [ -d "$R/sys/module/img_rogue" ]; then
    GV_VENDOR="PowerVR (Imagination)"; return 0
  fi
  case "$dv_dn_low" in *rogue*|*rgx*|*pvr*|*sgx*|*imgtec*|*imagination*) GV_VENDOR="PowerVR (Imagination)"; return 0 ;; esac

  # 3) Mali (ARM) - kbase/midgard/bifrost/valhall expose "gpuinfo" (nama model
  #    + revisi) di debugfs atau di bawah /sys/devices/platform/.../gpuinfo.
  if [ -d "$R/sys/module/mali_kbase" ] || [ -d "$R/sys/module/midgard" ] || [ -d "$R/sys/module/mali" ]; then
    for gv_f in "$R/sys/kernel/debug/mali0/gpuinfo" "$R/sys/class/misc/mali0/device/gpuinfo" \
                "$R"/sys/devices/platform/*/gpuinfo "$R"/sys/devices/platform/*/*/gpuinfo; do
      [ -r "$gv_f" ] || continue
      gv_m=$(dv_cat "$gv_f")
      [ -n "$gv_m" ] || continue
      GV_VENDOR="Mali (ARM)"; GV_NAME=$gv_m; return 0
    done
    GV_VENDOR="Mali (ARM)"; return 0
  fi
  case "$dv_dn_low" in *mali*|*kbase*|*midgard*|*bifrost*|*valhall*) GV_VENDOR="Mali (ARM)"; return 0 ;; esac

  return 0
}
# ------------------------------------------------------------------
# dv_gpu_driver_files() - TAMBAHAN MURNI, tidak mengubah dv_gpu_vendor
# ataupun fungsi lain di atas. Cek keberadaan file library userspace
# driver grafis (bukan baca isi/exec, cuma cek ada/tidak) supaya bisa
# dikonfirmasi node mana yang BENAR-BENAR punya backend-nya di device
# ini sebelum gfxapi.sh mencoba switch ke vulkan/skiavk/skiagl.
#   Hasil: GV_HWUI, GV_EGL, GV_GLESV2, GV_VULKAN_BASE,
#          GV_VENDOR_GLES, GV_VENDOR_VULKAN
# ------------------------------------------------------------------
dv_gpu_driver_files() {
  GV_HWUI="";GV_EGL="";GV_GLESV2="";GV_VULKAN_BASE=""
  GV_VENDOR_GLES="";GV_VENDOR_VULKAN=""

  [ -f "$R/system/lib64/libhwui.so" ]   && GV_HWUI="$R/system/lib64/libhwui.so"
  [ -f "$R/system/lib64/libEGL.so" ]    && GV_EGL="$R/system/lib64/libEGL.so"
  [ -f "$R/system/lib64/libGLESv2.so" ] && GV_GLESV2="$R/system/lib64/libGLESv2.so"
  [ -f "$R/system/lib64/libvulkan.so" ] && GV_VULKAN_BASE="$R/system/lib64/libvulkan.so"

  for dv_dir in "$R/vendor/lib64/egl" "$R/vendor/lib64/hw"; do
    [ -d "$dv_dir" ] || continue
    for dv_f in "$dv_dir"/libGLES_adreno.so "$dv_dir"/libGLES_mali.so \
                "$dv_dir"/*GLES*adreno*.so "$dv_dir"/*GLES*mali*.so; do
      [ -f "$dv_f" ] || continue
      GV_VENDOR_GLES="$GV_VENDOR_GLES${GV_VENDOR_GLES:+ }$dv_f"
    done
    for dv_f in "$dv_dir"/vulkan.adreno.so "$dv_dir"/vulkan.mali.so \
                "$dv_dir"/vulkan.*.so; do
      [ -f "$dv_f" ] || continue
      GV_VENDOR_VULKAN="$GV_VENDOR_VULKAN${GV_VENDOR_VULKAN:+ }$dv_f"
    done
  done
  return 0
}

dv_gpu_hz() { # dv_gpu_hz cur|max
  # v1.0.9-fix15: pada device MediaTek dengan kontrol GED/gpufreq (oc_mtk_on),
  # node devfreq (DV_GN/max_freq dkk di bawah) cuma "bayangan" - tidak ikut
  # bergerak waktu plafon GPU di-overclock lewat jalur GED asli (lihat catatan
  # panjang di lib/overclock.sh dekat OC_GED_UP). Akibatnya "maks" yang
  # ditampilkan di kartu Info Perangkat/Monitor jadi beda dari "Batas tabel
  # kernel" di tab Overclock (yang sudah benar, baca GED/gpufreq live) -
  # salah satunya OC, satunya tidak. Di sini "max" dibuat baca sumber yang
  # sama (puncak tabel gpufreq live) kalau GED aktif, supaya konsisten dan
  # ikut keadaan OC/non-OC yang sebenarnya; "cur" tidak diubah.
  if [ "$1" = max ] && command -v oc_mtk_on >/dev/null 2>&1 && oc_mtk_on; then
    dv_gmt=$(oc_mtk_tbl_khz 2>/dev/null)
    if [ -n "$dv_gmt" ]; then
      dv_gtop=""; for dv_gf in $dv_gmt; do dv_gtop=$dv_gf; done
      case "$dv_gtop" in ''|*[!0-9]*) ;; *) printf '%s' $((dv_gtop * 1000)); return 0 ;; esac
    fi
  fi
  dv_gpu_node
  [ -n "$DV_GN" ] || return 0
  if [ "$1" = cur ]; then
    dv_x=$(dv_cat "$DV_GN/cur_freq"); [ -n "$dv_x" ] || dv_x=$(dv_cat "$DV_GN/gpuclk")
  else
    dv_x=$(dv_cat "$DV_GN/max_freq"); [ -n "$dv_x" ] || dv_x=$(dv_cat "$DV_GN/max_gpuclk")
    [ -n "$dv_x" ] || dv_x=$(tr ' ' '\n' < "$DV_GN/available_frequencies" 2>/dev/null | grep '^[0-9]' | sort -n | tail -n 1)
  fi
  printf '%s' "$dv_x"
}

# ------------------------------ ROM -----------------------------------
dv_skin() { # dv_skin Nama "regex_brand" prop...  (set rd_* bila prop ada)
  [ -n "$rd_name" ] && return 0
  ds_n=$1; ds_b=$2; shift 2
  ds_v=$(dv_first "$@")
  [ -n "$ds_v" ] || return 0
  rd_name=$ds_n; rd_ver=$ds_v; rd_kind=skin; rd_skinbrand=$ds_b
}
dv_fpdev() { printf '%s' "$1" | cut -d/ -f3 | cut -d: -f1; }

dv_rom() {
  rd_name=""; rd_ver=""; rd_kind=""; rd_skinbrand=""
  rb=$(dv_lc "$(getprop ro.product.brand 2>/dev/null)")
  [ -n "$rb" ] || rb=$(dv_lc "$(getprop ro.product.manufacturer 2>/dev/null)")
  tags=$(getprop ro.build.tags 2>/dev/null); btype=$(getprop ro.build.type 2>/dev/null)
  fp=$(getprop ro.build.fingerprint 2>/dev/null)

  # 1) custom ROM berbasis AOSP: dikenali dari prop versi khasnya
  for e in lineage:LineageOS crdroid:crDroid pixelexperience:PixelExperience evolution:EvolutionX \
           aospa:ParanoidAndroid rice:RiceDroid derp:DerpFest havoc:Havoc arrow:ArrowOS superior:SuperiorOS \
           pixelos:PixelOS voltage:VoltageOS yaap:YAAP matrixx:MatrixxOS cherish:CherishOS bliss:BlissROM \
           corvus:CorvusOS spark:SparkOS ancient:AncientOS nusantara:Nusantara potato:PotatoOS \
           infinity:InfinityX lunaris:LunarisAOSP; do
    k=${e%%:*}; n=${e#*:}; v=$(getprop "ro.$k.version" 2>/dev/null)
    [ -n "$v" ] && { rd_name=$n; rd_ver=$v; rd_kind=custom; break; }
  done
  # ro.modversion = paling umum (LineageOS lama & banyak custom ROM lain).
  # ro.rom.version / ro.custom.version = dipakai beberapa custom ROM lain yang
  # tidak punya prop ro.<nama>.version sendiri di daftar di atas.
  [ -n "$rd_name" ] || { v=$(dv_first ro.modversion ro.rom.version ro.custom.version); [ -n "$v" ] && { rd_name="Custom ROM"; rd_ver=$v; rd_kind=custom; }; }

  # 2) skin/ROM bawaan vendor (dicocokkan dengan brand fisik device)
  dv_skin HyperOS "xiaomi|redmi|poco|blackshark" ro.mi.os.version.name
  dv_skin MIUI "xiaomi|redmi|poco|blackshark" ro.miui.ui.version.name
  dv_skin ColorOS "oppo|realme|oneplus" ro.build.version.oplusrom ro.build.version.opporom
  dv_skin "realme UI" "realme|oppo" ro.build.version.realmeui
  # ro.build.version.oneui = nama resmi sekarang; ro.build.version.sep = prop lama
  # "Samsung Experience" dari sebelum rebrand One UI, masih ada di sebagian build.
  dv_skin "One UI" "samsung" ro.build.version.oneui ro.build.version.sep
  dv_skin "Funtouch/OriginOS" "vivo|iqoo" ro.vivo.os.version
  dv_skin "HiOS/XOS/itel OS" "tecno|infinix|itel|transsion" ro.tranos.version ro.transsion.os.version ro.tranos.type
  dv_skin MagicOS "honor" ro.build.version.magic
  dv_skin EMUI "huawei|honor" ro.build.version.emui

  # 3) sinyal lain
  sysdev=$(dv_lc "$(dv_first ro.product.system.device ro.product.system_ext.device)")
  vdev=$(dv_lc "$(dv_first ro.product.vendor.device ro.product.odm.device ro.product.device)")
  sfp=$(getprop ro.system.build.fingerprint 2>/dev/null); vfp=$(getprop ro.vendor.build.fingerprint 2>/dev/null)
  sfd=$(dv_lc "$(dv_fpdev "$sfp")"); vfd=$(dv_lc "$(dv_fpdev "$vfp")")
  # ro.product.bootimage.device: device yang DIKLAIM boot.img (bagian dari image
  # system/port yang dipasang). ro.boot.device: dibaca bootloader dari DTB/cmdline
  # saat itu juga, jadi ini sinyal HARDWARE ASLI, beda sumber dari sysdev/vdev di
  # atas (yang sama-sama dari prop .device build, bisa dua2nya ikut diubah porter).
  bidev=$(dv_lc "$(getprop ro.product.bootimage.device 2>/dev/null)")
  hwdev=$(dv_lc "$(dv_first ro.boot.device ro.boot.hardware)")
  devmis=0; devwhy=""
  if [ -n "$sysdev" ] && [ -n "$vdev" ] && [ "$sysdev" != "$vdev" ] && [ "$sysdev" != generic ]; then
    devmis=1; devwhy="kode device partisi system ('$sysdev') beda dari vendor ('$vdev')"
  elif [ -n "$sfd" ] && [ -n "$vfd" ] && [ "$sfd" != "$vfd" ] && [ "$sfd" != generic ]; then
    devmis=1; devwhy="fingerprint system ('$sfd') beda device dari fingerprint vendor ('$vfd')"
  elif [ -n "$bidev" ] && [ -n "$hwdev" ] && [ "$bidev" != "$hwdev" ] && [ "$bidev" != generic ]; then
    devmis=1; devwhy="device di boot image ('$bidev') beda dari hardware asli yang dilaporkan bootloader ('$hwdev')"
  fi
  skinmis=0
  if [ "$rd_kind" = skin ] && ! printf '%s' "$rb" | grep -Eq "^($rd_skinbrand)"; then skinmis=1; fi
  looks_stock=0
  case "$tags" in *release-keys*) [ "$btype" = user ] && looks_stock=1 ;; esac
  gsi=0
  case "$fp" in generic/*|*/aosp_*|*/gsi_*) gsi=1 ;; esac
  case "$sfp" in generic/*|*/aosp_*|*/gsi_*) gsi=1 ;; esac
  case "$(dv_lc "$(getprop ro.product.system.name 2>/dev/null)")" in generic|gsi_*|aosp_arm*|aosp_x86*) gsi=1 ;; esac

  rt=unknown; rc=rendah; rw="fingerprint build tidak terbaca"
  if [ "$gsi" = 1 ]; then
    rt=gsi; rc=tinggi; rw="nama produk/fingerprint berpola generic/aosp_/gsi_ (Treble GSI)"
    [ -n "$rd_name" ] || { rd_name="AOSP GSI"; rd_ver=""; }
  elif [ "$looks_stock" = 1 ] && [ "$skinmis" = 0 ] && { [ -z "$rd_kind" ] || [ "$rd_kind" = skin ]; }; then
    rt=stock; rc=tinggi; rw="release-keys + build user, tanpa tanda ROM pihak ketiga"
    [ "$devmis" = 1 ] && { rc=sedang; rw="$rw (catatan: $devwhy; bisa varian region)"; }
    [ -n "$rd_name" ] || { rd_name=$(getprop ro.build.display.id 2>/dev/null); }
  elif [ "$skinmis" = 1 ]; then
    rt=port; rc=tinggi; rw="ada prop $rd_name tapi brand device '$rb' bukan brand asli ROM itu"
  elif [ "$devmis" = 1 ]; then
    rt=port; rc=sedang; rw="$devwhy, dan build bukan release-keys/user pabrik"
  elif [ "$rd_kind" = custom ]; then
    rt=aosp; rc=tinggi; rw="prop versi khas $rd_name terdeteksi (custom ROM berbasis AOSP)"
  elif [ "$rd_kind" = skin ]; then
    rt=stock-mod; rc=sedang; rw="skin $rd_name cocok dengan brand tapi build bukan release-keys/user (ROM bawaan yang dimodifikasi)"
  elif [ -n "$fp" ]; then
    rt=aosp; rc=sedang; rw="build ${tags:-?}/${btype:-?} tanpa skin vendor - kemungkinan AOSP/custom build"
    bu=$(dv_lc "$(getprop ro.build.user 2>/dev/null)")
    case "$bu" in *jenkins*|*android-build*|*buildkite*|*ci*) rw="$rw (ro.build.user='$bu', pola builder CI - memperkuat dugaan bukan build pabrik)" ;; esac
    [ -n "$rd_name" ] || rd_name="AOSP/Custom"
  fi
  RD_TYPE=$rt; RD_CONF=$rc; RD_WHY=$rw
}

# ------------------------------ Root ----------------------------------
dv_root() {
  rt_n=""; rt_v=""
  if [ -d "$R/data/adb/ap" ] || [ -e "$R/data/adb/apd" ]; then
    rt_n=APatch; rt_v=$(dv_cat "$R/data/adb/ap/version")
  elif [ -d "$R/data/adb/ksu" ] || [ -e "$R/data/adb/ksud" ]; then
    rt_n=KernelSU; rt_v=$("$R/data/adb/ksud" -V 2>/dev/null | head -n 1)
    [ -n "$rt_v" ] || rt_v=$(ksud -V 2>/dev/null | head -n 1)
  elif command -v magisk >/dev/null 2>&1; then
    rt_n=Magisk; rt_v=$(magisk -v 2>/dev/null | head -n 1)
  elif [ -d "$R/data/adb/magisk" ]; then
    rt_n=Magisk
  fi
  dv_p root "$rt_n"; dv_p root_ver "$rt_v"
}

# --------------------------- Bagian LIVE ------------------------------
devinfo_live() {
  if [ -r "$R/proc/meminfo" ]; then
    while read -r dk dval _; do
      case "$dk" in
        MemTotal:) dv_p mem_total_kb "$dval" ;;
        MemFree:) dv_p mem_free_kb "$dval" ;;
        MemAvailable:) dv_p mem_avail_kb "$dval" ;;
        Buffers:) dv_p mem_buf_kb "$dval" ;;
        Cached:) dv_p mem_cache_kb "$dval" ;;
        Shmem:) dv_p mem_shmem_kb "$dval" ;;
        SReclaimable:) dv_p mem_srec_kb "$dval" ;;
        KReclaimable:) dv_p mem_krec_kb "$dval" ;;
        Mapped:) dv_p mem_mapped_kb "$dval" ;;
        SwapTotal:) dv_p swap_total_kb "$dval" ;;
        SwapFree:) dv_p swap_free_kb "$dval" ;;
      esac
    done < "$R/proc/meminfo"
  fi
  # RAM dari binary bawaan Android `free` (toybox/busybox), kolom dibaca lewat NAMA header
  fr=$(free -k 2>/dev/null) || fr=$(busybox free -k 2>/dev/null) || fr=$(toybox free -k 2>/dev/null)
  if [ -n "$fr" ]; then
    set -- $(printf '%s\n' "$fr" | awk '
      NR==1 { for (i = 1; i <= NF; i++) h[tolower($i)] = i }
      /^[Mm]em:/ {
        if (!("total" in h) || !("free" in h)) exit
        t = $(h["total"] + 1); f = $(h["free"] + 1); a = 0; c = 0
        if ("available" in h) a = $(h["available"] + 1)
        if ("buff/cache" in h) c = $(h["buff/cache"] + 1)
        else { if ("buffers" in h) c += $(h["buffers"] + 1); if ("cached" in h) c += $(h["cached"] + 1) }
        print t, f, a, c; exit
      }')
    if [ "$#" -ge 4 ]; then
      dv_p free_total_kb "$1"; dv_p free_free_kb "$2"; dv_p free_avail_kb "$3"; dv_p free_bc_kb "$4"
    fi
  fi
  # ambil 5 kolom TERAKHIR (blok, terpakai, tersedia) supaya tahan nama device panjang / df yang membungkus baris
  set -- $(df -k "$R/data" 2>/dev/null | awk 'END{ if (NF >= 5) print $(NF-4), $(NF-3), $(NF-2) }')
  [ "$#" -ge 3 ] && { dv_p data_total_kb "$1"; dv_p data_used_kb "$2"; dv_p data_avail_kb "$3"; }

  bp="$R/sys/class/power_supply/battery"
  [ -d "$bp" ] || bp="$R/sys/class/power_supply/Battery"
  dv_p bat_level "$(dv_cat "$bp/capacity")"
  dv_p bat_status "$(dv_cat "$bp/status")"
  dv_p bat_health "$(dv_cat "$bp/health")"
  dv_p bat_temp "$(dv_cat "$bp/temp")"
  dv_p bat_volt "$(dv_cat "$bp/voltage_now")"
  dv_p bat_cycle "$(dv_cat "$bp/cycle_count")"

  cf=""
  for p in "$R"/sys/devices/system/cpu/cpufreq/policy*; do
    [ -d "$p" ] || continue
    cf="$cf${cf:+,}$(dv_cat "$p/scaling_cur_freq")"
  done
  dv_p cpu_cur_khz "$cf"
  dv_p gpu_cur_hz "$(dv_gpu_hz cur)"
  dv_p uptime_s "$(uptime_s)"
  dv_net_radio

  # kestabilan ping NYATA (ditulis net_ping_loop di lib/misc.sh dari ringkasan
  # `ping` apa adanya - avg/jitter/loss) - hanya ada isinya kalau NET_PING_LOG=1
  if [ -r "$DATADIR/ping_stat" ]; then
    read -r dv_pl < "$DATADIR/ping_stat" 2>/dev/null
    for dv_kv in $dv_pl; do
      dv_nk=${dv_kv%%=*}; dv_nv=${dv_kv#*=}
      dv_p "net_$dv_nk" "$dv_nv"
    done
  fi
}

# --------------------------- Bagian MONITOR (tab "Monitor", ala DevCheck) ----
#  CPU per-cluster (freq nyata + load% nyata), GPU (freq nyata), RAM, suhu
#  SoC/baterai/skin (PROBE - tetap akurat walau sedang di-freeze lib/thermal.sh,
#  lihat zone_probe_c), dan kecepatan jaringan NYATA (KB/s dari delta byte
#  /proc/net/dev, bukan tebakan). TIDAK ADA `sleep` di sini supaya aman
#  dipanggil berulang tiap 1-2 dtk dari WebUI tanpa nge-blok CLI: load% CPU
#  & KB/s jaringan dihitung dari DELTA ke snapshot panggilan SEBELUMNYA
#  (disimpan di $RUNDIR/mon_*) - baru akurat mulai panggilan KEDUA, panggilan
#  pertama wajar 0 (belum ada pembanding).
# ---------------------------------------------------------------------
MON_CPU_PREV="$RUNDIR/mon_cpu_prev"
MON_NET_PREV="$RUNDIR/mon_net_prev2"

# uptime dalam sentidetik (1/100 dtk) dari /proc/uptime - dipakai hitung KB/s supaya
# polling cepat (<1 dtk) tetap akurat. uptime_s (detik bulat) bikin delta waktu 0 pada
# panggilan beruntun sehingga angka jaringan hilang/0 dan grafik terlihat patah-patah.
dv_uptime_cs() {
  dv_ua=""; { read -r dv_ua dv_ub < "$R/proc/uptime"; } 2>/dev/null
  case "$dv_ua" in
    *.*) dv_ui=${dv_ua%%.*}; dv_uf=${dv_ua#*.}00; dv_uf=${dv_uf%"${dv_uf#??}"} ;;
    *) dv_ui=$dv_ua; dv_uf=00 ;;
  esac
  case "$dv_ui$dv_uf" in ''|*[!0-9]*) echo 0; return ;; esac
  echo $(( dv_ui * 100 + ${dv_uf#0} ))
}

# load% per cluster dari delta jiffies /proc/stat (awk, tanpa floating/bc -
# toybox/busybox awk cukup). baris "cpu" = rata-rata semua core -> cpu_load_all;
# "cpuN" -> cpu_load_N.
dv_cpu_load() {
  [ -r "$R/proc/stat" ] || return 0
  awk -v prevf="$MON_CPU_PREV" '
    BEGIN {
      while ((getline l < prevf) > 0) { split(l, a, " "); prev[a[1]] = l }
      close(prevf)
    }
    /^cpu[0-9]* / {
      name = $1
      total = $2 + $3 + $4 + $5 + $6 + $7 + $8 + $9
      idle  = $5 + $6
      print > prevf
      if (name in prev) {
        split(prev[name], p, " ")
        ptotal = p[2] + p[3] + p[4] + p[5] + p[6] + p[7] + p[8] + p[9]
        pidle  = p[5] + p[6]
        dtotal = total - ptotal; didle = idle - pidle
        if (dtotal > 0) {
          pct = int((dtotal - didle) * 100 / dtotal)
          if (pct < 0) pct = 0; if (pct > 100) pct = 100
          out = name; sub(/^cpu/, "", out)
          print "cpu_load_" (out == "" ? "all" : out) "=" pct
        }
      }
    }
  ' "$R/proc/stat"
}

# kecepatan jaringan NYATA dalam KB/s: jumlah rx/tx semua interface (kecuali
# lo) dari /proc/net/dev, dibagi detik yang BENAR-BENAR lewat sejak panggilan
# sebelumnya (bukan diasumsikan tetap 2 dtk - polling WebUI tidak selalu persis).
dv_net_speed() {
  [ -r "$R/proc/net/dev" ] || return 0
  nw_now=$(dv_uptime_cs); nw_rx=0; nw_tx=0
  while IFS=: read -r nw_if nw_rest; do
    nw_if=$(printf '%s' "$nw_if" | tr -d ' ')
    [ "$nw_if" = lo ] && continue
    set -- $nw_rest
    [ -n "$1" ] && [ -n "$9" ] || continue
    case "$1$9" in *[!0-9]*) continue ;; esac
    nw_rx=$((nw_rx + $1)); nw_tx=$((nw_tx + $9))
  done < "$R/proc/net/dev"
  if [ -f "$MON_NET_PREV" ]; then
    IFS='|' read -r nw_prx nw_ptx nw_pt < "$MON_NET_PREV"
    case "$nw_prx$nw_ptx$nw_pt" in *[!0-9]*) nw_prx="" ;; esac
    if [ -n "$nw_prx" ]; then
      nw_dt=$((nw_now - nw_pt))
      if [ "$nw_dt" -gt 0 ] && [ "$nw_rx" -ge "$nw_prx" ] && [ "$nw_tx" -ge "$nw_ptx" ]; then
        dv_p net_rx_kBps $(( (nw_rx - nw_prx) * 100 / (1024 * nw_dt) ))
        dv_p net_tx_kBps $(( (nw_tx - nw_ptx) * 100 / (1024 * nw_dt) ))
      fi
    fi
  fi
  echo "$nw_rx|$nw_tx|$nw_now" > "$MON_NET_PREV"
}

# ------------------------ Jaringan (WiFi / Data Seluler) ---------------
#  dv_net_speed() di atas cuma hitung KB/s mentah dari /proc/net/dev (tidak
#  peduli itu WiFi atau data seluler). Bagian ini BEDA: mendeteksi jaringan
#  mana yang sedang dipakai dan "berapa" sinyal/kecepatan LINK-nya -
#  SSID+RSSI(dBm)+link speed(Mbps) untuk WiFi, operator+jenis jaringan
#  (2G/3G/4G/5G)+sinyal(dBm) untuk data seluler. Dibaca dari dumpsys/getprop
#  bawaan Android (apa adanya, bukan dihitung ulang) supaya kerja di semua
#  vendor GPU/chipset - ini murni soal radio, tidak tergantung Mali/Adreno/
#  PowerVR sama sekali.
dv_rat_gen() { # dv_rat_gen NAMA_RAT -> label generasi (2G/3G/4G/5G/?)
  case "$(dv_lc "$1")" in
    nr|nrsa|nrnsa|5g) echo 5G ;;
    lte*|iwlan|ehrpd) echo 4G ;;
    umts|hsdpa|hsupa|hspa|hspap|hsupah|td_scdma|evdo_0|evdo_a|evdo_b|1xrtt) echo 3G ;;
    gprs|edge|cdma|gsm) echo 2G ;;
    *) printf '%s' "$1" ;;
  esac
}

dv_net_wifi() { # isi NV_SSID NV_RSSI NV_LSPD NV_FREQ kalau WiFi sedang connect (return 1 kalau tidak)
  NV_SSID=""; NV_RSSI=""; NV_LSPD=""; NV_FREQ=""
  command -v dumpsys >/dev/null 2>&1 || return 1
  if command -v timeout >/dev/null 2>&1; then nw_wd=$(timeout 3 dumpsys wifi 2>/dev/null)
  else nw_wd=$(dumpsys wifi 2>/dev/null); fi
  [ -n "$nw_wd" ] || return 1
  # baris "mWifiInfo" (lama) atau "Current Wifi Info" (baru) isinya satu baris
  # panjang: SSID: "Nama", BSSID: .., RSSI: -55, Link speed: 433Mbps, Frequency: 5180MHz, ...
  nw_l=$(printf '%s\n' "$nw_wd" | grep -m1 -E 'SSID:.*RSSI:')
  [ -n "$nw_l" ] || return 1
  case "$nw_l" in *'<unknown ssid>'*|*none* ) ;; esac
  NV_SSID=$(printf '%s' "$nw_l" | sed -n 's/.*SSID: *"\{0,1\}\([^,"]*\)"\{0,1\},.*/\1/p')
  NV_RSSI=$(printf '%s' "$nw_l" | grep -oE 'RSSI: *-?[0-9]+' | grep -oE -- '-?[0-9]+' | head -n 1)
  NV_LSPD=$(printf '%s' "$nw_l" | grep -oE 'Link speed: *[0-9]+' | grep -oE '[0-9]+' | head -n 1)
  NV_FREQ=$(printf '%s' "$nw_l" | grep -oE 'Frequency: *[0-9]+' | grep -oE '[0-9]+' | head -n 1)
  [ -n "$NV_SSID" ] || [ -n "$NV_RSSI" ]
}

dv_net_mobile() { # isi NV_OP NV_RAT NV_DBM dari data seluler (return 1 kalau tidak ada info sama sekali)
  NV_OP=""; NV_RAT=""; NV_DBM=""
  NV_OP=$(dv_first gsm.sim.operator.alpha gsm.operator.alpha)
  command -v dumpsys >/dev/null 2>&1 || { [ -n "$NV_OP" ]; return $?; }
  if command -v timeout >/dev/null 2>&1; then nw_td=$(timeout 3 dumpsys telephony.registry 2>/dev/null)
  else nw_td=$(dumpsys telephony.registry 2>/dev/null); fi
  [ -n "$nw_td" ] || { [ -n "$NV_OP" ]; return $?; }
  NV_RAT=$(printf '%s\n' "$nw_td" | grep -m1 -oE 'mDataNetworkType ?= ?[A-Za-z0-9_]+' | sed 's/.*=//')
  [ -n "$NV_RAT" ] || NV_RAT=$(printf '%s\n' "$nw_td" | grep -m1 -oE 'mVoiceNetworkType ?= ?[A-Za-z0-9_]+' | sed 's/.*=//')
  # format signal strength beda-beda antar versi Android: cari "dbm=" dulu
  # (modern, SignalStrength.toString()), fallback pola lama "gsmSignalStrength".
  NV_DBM=$(printf '%s\n' "$nw_td" | grep -m1 -oE 'dbm=-?[0-9]+' | grep -oE -- '-?[0-9]+')
  if [ -z "$NV_DBM" ]; then
    nw_asu=$(printf '%s\n' "$nw_td" | grep -m1 -oE 'gsmSignalStrength=[0-9]+' | grep -oE '[0-9]+')
    # ASU GSM -> dBm perkiraan standar: dBm = -113 + 2*ASU (99 = tidak diketahui)
    [ -n "$nw_asu" ] && [ "$nw_asu" -ne 99 ] 2>/dev/null && NV_DBM=$((nw_asu * 2 - 113))
  fi
  [ -n "$NV_OP" ] || [ -n "$NV_RAT" ] || [ -n "$NV_DBM" ]
}

# panggil dari devinfo_live/monitor: isi net_conn, dan detail WiFi atau data
# seluler tergantung mana yang aktif. Cukup "berat" (dumpsys), tapi devinfo_live
# sudah dipakai di tab yang sama dengan polling 2dtk jadi aman.
dv_net_radio() {
  if dv_net_wifi; then
    dv_p net_conn wifi
    dv_p net_wifi_ssid "$NV_SSID"
    dv_p net_wifi_rssi_dbm "$NV_RSSI"
    dv_p net_wifi_linkspeed_mbps "$NV_LSPD"
    dv_p net_wifi_freq_mhz "$NV_FREQ"
  elif dv_net_mobile; then
    dv_p net_conn mobile
    dv_p net_mobile_operator "$NV_OP"
    dv_p net_mobile_rat "$NV_RAT"
    dv_p net_mobile_gen "$(dv_rat_gen "$NV_RAT")"
    dv_p net_mobile_dbm "$NV_DBM"
  else
    dv_p net_conn none
  fi
}

# beban (utilisasi) GPU NYATA dalam persen, dibaca dari node kernel yang ADA di
# device ini (tanpa deteksi merk): Qualcomm kgsl, MediaTek GED, devfreq Mali/lainnya.
# Kalau tidak ada satu pun yang terbaca, tidak ada output (WebUI menampilkan
# grafik clock saja, tidak mengarang angka beban).
dv_gpu_load() {
  dv_gl=""
  for dv_gf in "$R/sys/class/kgsl/kgsl-3d0/gpu_busy_percentage" \
               "$R/sys/kernel/ged/hal/gpu_utilization" \
               "$R/sys/module/ged/parameters/gpu_loading" \
               "$R/sys/kernel/gpu/gpu_busy"; do
    [ -r "$dv_gf" ] || continue
    dv_gx=$(dv_cat "$dv_gf" | tr -dc '0-9 ' | awk '{print $1}')
    case "$dv_gx" in ''|*[!0-9]*) continue ;; esac
    [ "$dv_gx" -le 100 ] 2>/dev/null && { dv_gl=$dv_gx; break; }
  done
  if [ -z "$dv_gl" ] && [ -r "$R/sys/class/kgsl/kgsl-3d0/gpubusy" ]; then
    dv_gb=$(dv_cat "$R/sys/class/kgsl/kgsl-3d0/gpubusy")
    set -- $dv_gb
    case "$1$2" in ''|*[!0-9]*) ;; *) [ "$2" -gt 0 ] 2>/dev/null && dv_gl=$(( $1 * 100 / $2 )) ;; esac
  fi
  if [ -z "$dv_gl" ]; then
    dv_gpu_node
    for dv_gf in "$DV_GN/load" "$DV_GN/gpu_load" "$DV_GN/device/load"; do
      [ -r "$dv_gf" ] || continue
      dv_gx=$(dv_cat "$dv_gf" | sed 's/@.*//' | tr -dc '0-9')
      case "$dv_gx" in ''|*[!0-9]*) continue ;; esac
      [ "$dv_gx" -le 100 ] 2>/dev/null && { dv_gl=$dv_gx; break; }
    done
  fi
  [ -n "$dv_gl" ] && dv_p gpu_load_pct "$dv_gl"
}

devinfo_monitor() {
  # "fast" (dipakai WebUI tiap ~0,4 dtk): lewati scan_if_needed yang menghitung
  # fingerprint (banyak getprop) kalau profil sudah ada, dan lewati dv_net_radio
  # (dumpsys wifi/telephony, bisa sampai 3 dtk) - WebUI tidak memakainya di grafik.
  if [ "$1" = fast ]; then [ -s "$PROFILE" ] || scan_if_needed >/dev/null 2>&1
  else scan_if_needed >/dev/null 2>&1; fi
  dv_cpu_load
  cf=""; mf=""
  for p in "$R"/sys/devices/system/cpu/cpufreq/policy*; do
    [ -d "$p" ] || continue
    cf="$cf${cf:+,}$(dv_cat "$p/scaling_cur_freq")"
    # v1.0.9-fix15: sama seperti GPU di atas - "max" yang ditampilkan harus
    # ikut plafon yang BENAR-BENAR berlaku sekarang. oc_cpu_set() (lib/
    # overclock.sh) menulis plafon OC ke scaling_max_freq, bukan ke
    # cpuinfo_max_freq (itu batas HW statis, tidak berubah waktu OC). Baca
    # cpuinfo_max_freq saja bikin kartu Monitor tetap menunjukkan plafon
    # bawaan walau OC sudah aktif; scaling_max_freq dulu (fallback ke
    # cpuinfo_max_freq kalau tidak kebaca) supaya akurat di kedua keadaan.
    dv_cmax=$(dv_cat "$p/scaling_max_freq")
    [ -n "$dv_cmax" ] || dv_cmax=$(dv_cat "$p/cpuinfo_max_freq")
    mf="$mf${mf:+,}$dv_cmax"
  done
  dv_p cpu_cur_khz "$cf"; dv_p cpu_max_khz "$mf"
  dv_p gpu_cur_hz "$(dv_gpu_hz cur)"; dv_p gpu_max_hz "$(dv_gpu_hz max)"
  dv_gpu_load
  if [ -r "$R/proc/meminfo" ]; then
    mm_t=0; mm_a=0
    while read -r mm_k mm_v _; do
      case "$mm_k" in MemTotal:) mm_t=$mm_v ;; MemAvailable:) mm_a=$mm_v ;; esac
    done < "$R/proc/meminfo"
    dv_p ram_total_kb "$mm_t"; dv_p ram_avail_kb "$mm_a"
    [ "${mm_t:-0}" -gt 0 ] 2>/dev/null && dv_p ram_used_pct $(( (mm_t - mm_a) * 100 / mm_t ))
  fi
  bp="$R/sys/class/power_supply/battery"
  [ -d "$bp" ] || bp="$R/sys/class/power_supply/Battery"
  dv_p bat_level "$(dv_cat "$bp/capacity")"
  dv_p bat_current_ua "$(dv_cat "$bp/current_now")"
  dv_net_speed
  [ "$1" = fast ] || dv_net_radio
  thermal_limits_init; temps_read probe
  dv_p t_soc "$T_SOC"; dv_p t_batt "$T_BATT"; dv_p t_skin "$T_SKIN"
  dv_p uptime_s "$(uptime_s)"
}

# --------------------------- Bagian STATIS ----------------------------
devinfo_static() {
  # --- identitas perangkat
  dv_p brand "$(getprop ro.product.brand 2>/dev/null)"
  dv_p manufacturer "$(getprop ro.product.manufacturer 2>/dev/null)"
  dv_p model "$(dv_first ro.product.model ro.product.vendor.model)"
  dv_p marketname "$(dv_first ro.product.marketname ro.product.vendor.marketname ro.product.odm.marketname ro.config.marketing_name ro.vendor.oplus.market.name)"
  dv_p codename "$(dv_first ro.product.device ro.product.vendor.device)"
  dv_p board "$(dv_first ro.product.board ro.board.platform)"

  # --- SoC / CPU
  dv_p soc_mfr "$(dv_first ro.soc.manufacturer ro.vendor.soc.manufacturer)"
  dv_p soc_model "$(dv_first ro.soc.model ro.vendor.soc.model ro.hardware.chipname ro.mediatek.platform)"
  dv_p platform "$(getprop ro.board.platform 2>/dev/null)"
  dv_p hardware "$(dv_first ro.hardware ro.boot.hardware)"
  dv_p abi "$(getprop ro.product.cpu.abi 2>/dev/null)"
  dv_p cores "$(grep -c '^processor' "$R/proc/cpuinfo" 2>/dev/null)"
  dv_p cpu_impl "$(sed -n 's/^CPU implementer[[:space:]]*:[[:space:]]*0x//p' "$R/proc/cpuinfo" 2>/dev/null | head -n 1)"
  dv_p cpu_parts "$(sed -n 's/^CPU part[[:space:]]*:[[:space:]]*0x//p' "$R/proc/cpuinfo" 2>/dev/null | tr '\n' ',')"
  pl=""
  for p in "$R"/sys/devices/system/cpu/cpufreq/policy*; do
    [ -d "$p" ] || continue
    rcpu=$(dv_cat "$p/related_cpus"); [ -n "$rcpu" ] || rcpu=$(dv_cat "$p/affected_cpus")
    fc=${rcpu%% *}; nn=$(printf '%s\n' $rcpu | wc -l)
    pl="$pl${pl:+|}$fc:$nn:$(dv_cat "$p/cpuinfo_max_freq")"
  done
  dv_p cpu_policies "$pl"

  # --- GPU (Mali/Adreno/PowerVR - lihat dv_gpu_vendor di atas, bukan cuma kgsl/Mali lagi)
  dv_gpu_vendor
  gname="$GV_NAME"
  glraw=""
  if command -v dumpsys >/dev/null 2>&1; then
    if command -v timeout >/dev/null 2>&1; then glraw=$(timeout 4 dumpsys SurfaceFlinger 2>/dev/null | grep -m1 'GLES:')
    else glraw=$(dumpsys SurfaceFlinger 2>/dev/null | grep -m1 'GLES:'); fi
  fi
  glraw=$(printf '%s' "$glraw" | sed 's/^[^:]*:[[:space:]]*//')
  # kalau nama model resmi vendor tidak kebaca (vendor tidak expose node-nya),
  # pakai GL_RENDERER dari driver OpenGL ES sebagai fallback - ini jalan di
  # SEMUA vendor (Mali/Adreno/PowerVR) karena datang dari EGL, bukan sysfs vendor.
  [ -n "$gname" ] || gname=$(printf '%s' "$glraw" | cut -d, -f2 | sed 's/^[[:space:]]*//')
  dv_p gpu_vendor "$GV_VENDOR"
  dv_p gpu_name "$gname"
  dv_p gl_renderer "$(printf '%s' "$glraw" | cut -d, -f2 | sed 's/^[[:space:]]*//')"
  dv_p gl_vendor "$(printf '%s' "$glraw" | cut -d, -f1)"
  dv_p gl_version "$(printf '%s' "$glraw" | cut -d, -f3- | sed 's/^[[:space:]]*//')"
  dv_p gpu_node "${DV_GN##*/}"
  dv_p gpu_max_hz "$(dv_gpu_hz max)"
  # --- TAMBAHAN: file driver userspace (EGL/Vulkan/vendor) - murni info,
  # tidak menggantikan baris gpu_vendor/gpu_name di atas
  dv_gpu_driver_files
  dv_p gpu_lib_hwui "${GV_HWUI:-tidak ada}"
  dv_p gpu_lib_vulkan_base "${GV_VULKAN_BASE:-tidak ada}"
  dv_p gpu_lib_vendor_gles "${GV_VENDOR_GLES:-tidak ada}"
  dv_p gpu_lib_vendor_vulkan "${GV_VENDOR_VULKAN:-tidak ada}"

  # --- ROM penyimpanan (kapasitas blok terbesar = partisi user, bukan hanya /data)
  dv_p disk_sectors "$(cat "$R"/sys/block/sd[a-z]/size "$R"/sys/block/mmcblk[0-9]/size "$R"/sys/block/nvme[0-9]n[0-9]/size 2>/dev/null | sort -n | tail -n 1)"
  bd=$(dv_lc "$(getprop ro.boot.bootdevice 2>/dev/null)")
  case "$bd" in
    *ufs*) st=UFS ;;
    *mmc*|*sdhci*|*sdcc*) st=eMMC ;;
    *) if [ -e "$R/sys/block/sda" ]; then st=UFS; elif [ -e "$R/sys/block/mmcblk0" ]; then st=eMMC; else st=""; fi ;;
  esac
  dv_p storage_type "$st"

  # --- layar
  dv_p wm_size "$(wm size 2>/dev/null | sed -n 's/^Physical size:[[:space:]]*//p' | head -n 1)"
  dv_p wm_density "$(wm density 2>/dev/null | sed -n 's/^Physical density:[[:space:]]*//p' | head -n 1)"
  bp="$R/sys/class/power_supply/battery"; [ -d "$bp" ] || bp="$R/sys/class/power_supply/Battery"
  dv_p bat_design_uah "$(dv_cat "$bp/charge_full_design")"
  dv_p bat_tech "$(dv_cat "$bp/technology")"

  # --- Android / ROM
  dv_p android "$(getprop ro.build.version.release 2>/dev/null)"
  dv_p sdk "$(getprop ro.build.version.sdk 2>/dev/null)"
  dv_p patch "$(getprop ro.build.version.security_patch 2>/dev/null)"
  dv_p display_id "$(getprop ro.build.display.id 2>/dev/null)"
  dv_p incremental "$(getprop ro.build.version.incremental 2>/dev/null)"
  dv_p fingerprint "$(getprop ro.build.fingerprint 2>/dev/null)"
  dv_p build_tags "$(getprop ro.build.tags 2>/dev/null)"
  dv_p build_type "$(getprop ro.build.type 2>/dev/null)"
  dv_p build_utc "$(getprop ro.build.date.utc 2>/dev/null)"
  dv_rom
  dv_p rom_type "$RD_TYPE"; dv_p rom_name "$rd_name"; dv_p rom_ver "$rd_ver"
  dv_p rom_conf "$RD_CONF"; dv_p rom_why "$RD_WHY"
  dv_p treble "$(getprop ro.treble.enabled 2>/dev/null)"
  dv_p dynparts "$(getprop ro.boot.dynamic_partitions 2>/dev/null)"
  dv_p slot "$(getprop ro.boot.slot_suffix 2>/dev/null)"
  dv_p vboot "$(getprop ro.boot.verifiedbootstate 2>/dev/null)"
  dv_p bl_locked "$(getprop ro.boot.flash.locked 2>/dev/null)"
  dv_p selinux "$(getenforce 2>/dev/null)"
  dv_root

  # --- kernel
  dv_p kernel_rel "$(uname -r 2>/dev/null)"
  dv_p kernel_ver "$(uname -v 2>/dev/null)"
  dv_p kernel_arch "$(uname -m 2>/dev/null)"
  dv_p kernel_cc "$(grep -Eo '(clang|gcc)[^)]*version[^)]*' "$R/proc/version" 2>/dev/null | head -n 1)"
}

devinfo_all() { devinfo_static; devinfo_live; }
