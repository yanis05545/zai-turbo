#!/system/bin/sh
# =====================================================================
#  Zyrox - cpu_spoof.sh   (v1.0.44)   -- MENGGANTI Spoof GPU
#  Spoof NAMA PROSESOR (SoC) SYSTEMLESS lewat resetprop.
#
#  TIDAK menulis /system /vendor /product /odm (tidak ada driver yang dipatch,
#  tidak ada overlay). Nilai hanya ditimpa di memori (property service) dan
#  diterapkan ulang tiap boot di post-fs-data (sebelum zygote).
#
#  Properti yang diubah:
#    ro.soc.model / ro.soc.manufacturer           (Build.SOC_MODEL / SOC_MANUFACTURER, Android 12+)
#    ro.vendor.soc.model / ro.vendor.soc.manufacturer
#    ro.hardware.chipname                          (hanya kalau sudah ada di perangkat)
#  SENGAJA TIDAK diubah: ro.hardware, ro.board.platform, ro.product.board (dipakai init/HAL vendor
#  untuk memilih driver - menimpanya bisa bootloop).
#  v1.0.43 (fix DevCheck tidak tembus): selain properti, baris 'Hardware' di /proc/cpuinfo kini ikut
#  diganti lewat bind-mount berkas salinan (bukan menulis kernel/sistem; umount = kembali asli) dan
#  /sys/devices/soc0/machine (kalau ada). Prop soc tambahan (ro.vendor.qti.soc_name, ro.mediatek.platform,
#  ro.hardware.chipname dst.) ditimpa HANYA kalau sudah ada di perangkat. Bind-mount dipasang di
#  post-fs-data (sebelum zygote) supaya terlihat oleh semua aplikasi. Failsafe boot dinaikkan ke 3.
#
#  Pengaman: nilai asli dicadangkan sebelum ditimpa (off = kembalikan; prop yang sebelumnya tidak ada
#  dihapus lagi), input divalidasi, boot-failsafe (boot_count >= 2 -> spoof dimatikan otomatis).
#  Build.SOC_MODEL dibaca zygote sekali -> aplikasi baru melihat nama baru setelah 'restart' / REBOOT.
#
#  Pakai (root):
#   sh cpu_spoof.sh detect | profiles | status | on <id> | set <id> | off | verify | restart | boot <n>
#   (tambah --restart di akhir on/set/off untuk langsung restart framework)
# =====================================================================
MODDIR=${MODDIR:-/data/adb/modules/azenith-ai}
DATADIR="${TX_DATA:-/data/adb/azenith-ai}"
R="${TX_ROOT:-}"
CONF="$DATADIR/azenith-ai.conf"
CP_PROPS="$DATADIR/cpu_spoof.props"     # name|nilai -> diterapkan tiap boot
CP_ORIG="$DATADIR/cpu_orig.props"       # name|nilai asli (nilai kosong = prop memang tidak ada)
CP_META="$DATADIR/cpu_spoof.meta"
CP_STALE="$DATADIR/cpu_spoof.fwstale"
CP_FAKE_CPUINFO="$DATADIR/cpuinfo.fake"   # salinan /proc/cpuinfo dgn baris Hardware diganti (bind-mount)
CP_FAKE_MACHINE="$DATADIR/soc0_machine.fake"
CP_SOC0="/sys/devices/soc0/machine"
export PATH="$PATH:/data/adb/magisk:/data/adb/ksu/bin:/data/adb/ap/bin:/system/bin"
mkdir -p "$DATADIR" 2>/dev/null

cp_say() { printf '%s\n' "$*"; }
cp_kv()  { printf '%s=%s\n' "$1" "$2"; }
cp_log() { printf '%s [CPUSPOOF] %s\n' "$(date '+%m-%d %H:%M:%S')" "$*" >> "$DATADIR/log.txt" 2>/dev/null; }
cp_prop() { getprop "$1" 2>/dev/null | tr -d '\r'; }
cp_conf_get() { cp_cv=$(sed -n "s/^$1=\([^ #]*\).*/\1/p" "$CONF" 2>/dev/null | tail -n 1); printf '%s' "${cp_cv:-$2}"; }
cp_conf_set() {
  [ -f "$CONF" ] || : > "$CONF"
  if grep -q "^$1=" "$CONF" 2>/dev/null; then sed -i "s|^$1=[^ #]*|$1=$2|" "$CONF"; else printf '%s=%s\n' "$1" "$2" >> "$CONF"; fi
}
cp_need_root() { [ -n "$R" ] && return 0; [ "$(id -u 2>/dev/null)" = 0 ] && return 0; cp_say "GAGAL: butuh root (jalankan lewat su)"; return 1; }
cp_need_resetprop() { command -v resetprop >/dev/null 2>&1 && return 0; cp_say "GAGAL: resetprop tidak ada (butuh Magisk/KernelSU/APatch)"; return 1; }

# id|famili|pabrikan|nama soc (ro.soc.model)|chipname|label
cp_catalog() {
  cat <<'EOT'
sd8elite5|qcom|Qualcomm|Snapdragon 8 Elite Gen 5|SM8850|Snapdragon 8 Elite Gen 5
sd888p|qcom|Qualcomm|Snapdragon 888+|SM8350-AC|Snapdragon 888+
sd650|qcom|Qualcomm|Snapdragon 650|MSM8956|Snapdragon 650
sd8g2|qcom|Qualcomm|Snapdragon 8 Gen 2|SM8550|Snapdragon 8 Gen 2
d9500|mtk|MediaTek|Dimensity 9500|MT6993|Dimensity 9500
d9500s|mtk|MediaTek|Dimensity 9500s|Dimensity 9500s|Dimensity 9500s
d9500m|mtk|MediaTek|Dimensity 9500m|Dimensity 9500m|Dimensity 9500m
d9400|mtk|MediaTek|Dimensity 9400|MT6991|Dimensity 9400
d9400p|mtk|MediaTek|Dimensity 9400+|MT6991|Dimensity 9400+
d9000|mtk|MediaTek|Dimensity 9000|MT6983|Dimensity 9000
d9000p|mtk|MediaTek|Dimensity 9000+|MT6983|Dimensity 9000+
d8300u|mtk|MediaTek|Dimensity 8300 Ultra|MT6897|Dimensity 8300 Ultra
d8500u|mtk|MediaTek|Dimensity 8500 Ultra|Dimensity 8500 Ultra|Dimensity 8500 Ultra
d8400|mtk|MediaTek|Dimensity 8400|Dimensity 8400|Dimensity 8400
EOT
}

# daftar prop target: soc.* selalu dibuat; chipname & prop vendor lain hanya kalau sudah ada di perangkat
cp_build_list() { # <pabrikan> <nama soc> <chipname> [famili]
  printf 'ro.soc.manufacturer|%s\n' "$1"
  printf 'ro.soc.model|%s\n' "$2"
  printf 'ro.vendor.soc.manufacturer|%s\n' "$1"
  printf 'ro.vendor.soc.model|%s\n' "$2"
  # v1.0.44: chipname dibuat SELALU (DevCheck/CPU-Z membacanya; prop baru tidak membahayakan HAL)
  printf 'ro.hardware.chipname|%s\n' "$3"
  case "$4" in
    qcom) printf 'ro.vendor.qti.soc_name|%s\nro.vendor.qti.soc_model|%s\n' "$3" "$3" ;;
  esac
  # prop lain: hanya kalau sudah ada di perangkat (jangan membuat prop yang dipakai HAL secara tak terduga)
  for cb_k in ro.vendor.qti.soc_name ro.vendor.qti.soc_model ro.soc_name ro.board.chipname ro.chipname ro.mediatek.platform ro.vendor.mediatek.platform; do
    [ -n "$(cp_prop "$cb_k")" ] && ! { [ "$4" = qcom ] && case "$cb_k" in ro.vendor.qti.soc_*) true ;; *) false ;; esac; } && printf '%s|%s\n' "$cb_k" "$3"
  done
}

cp_save_orig() { # cadangkan nilai asli sekali; backup dari OTA lama dibuang
  cs_cur=$(cp_prop ro.build.version.incremental)
  if [ ! -f "$CP_ORIG" ] || [ "$(sed -n 's/^#incr|//p' "$CP_ORIG" | head -n 1)" != "$cs_cur" ]; then printf '#incr|%s\n' "$cs_cur" > "$CP_ORIG"; fi
  while IFS='|' read -r so_k so_v; do
    [ -n "$so_k" ] || continue
    grep -q "^$so_k|" "$CP_ORIG" 2>/dev/null || printf '%s|%s\n' "$so_k" "$(cp_prop "$so_k")" >> "$CP_ORIG"
  done < "$1"
}
cp_apply_file() { # resetprop -n ; CP_APPLIED = jumlah ok ; return jumlah gagal
  af_bad=0; af_ok=0
  while IFS='|' read -r af_k af_v; do
    [ -n "$af_k" ] || continue
    case "$af_k" in '#'*) continue ;; esac
    if resetprop -n "$af_k" "$af_v" 2>/dev/null; then af_ok=$((af_ok + 1)); else af_bad=$((af_bad + 1)); fi
  done < "$1"
  CP_APPLIED=$af_ok
  return "$af_bad"
}
cp_restore_orig() { # kembalikan nilai asli; nilai kosong = prop dulu tidak ada -> hapus
  CP_RESTORED=0
  [ -s "$CP_ORIG" ] || return 0
  [ "$(sed -n 's/^#incr|//p' "$CP_ORIG" | head -n 1)" = "$(cp_prop ro.build.version.incremental)" ] || return 0
  while IFS='|' read -r ro_k ro_v; do
    [ -n "$ro_k" ] || continue
    case "$ro_k" in '#'*) continue ;; esac
    if [ -n "$ro_v" ]; then resetprop -n "$ro_k" "$ro_v" 2>/dev/null; else resetprop --delete "$ro_k" 2>/dev/null; fi
    CP_RESTORED=$((CP_RESTORED + 1))
  done < "$CP_ORIG"
}
cp_real() { cr_v=$(awk -F'|' -v k="$1" '$1==k{print substr($0,length(k)+2); exit}' "$CP_ORIG" 2>/dev/null); [ -n "$cr_v" ] && printf '%s' "$cr_v" || cp_prop "$1"; }

# ---- v1.0.43: bind-mount /proc/cpuinfo (+ soc0/machine) supaya DevCheck ikut melihat nama palsu ----
cp_ns() { # jalankan perintah di mount-namespace init (global) kalau nsenter ada
  if command -v nsenter >/dev/null 2>&1; then nsenter -t 1 -m -- "$@" 2>/dev/null || "$@"; else "$@"; fi
}
cp_is_mounted() { grep -q " $1 " /proc/self/mountinfo 2>/dev/null; }
cp_umount_one() { # lepas SEMUA bind-mount milik kita di path itu (bisa bertumpuk)
  um_n=0
  while cp_is_mounted "$1" && [ "$um_n" -lt 6 ]; do
    cp_ns umount "$1" >/dev/null 2>&1 || cp_ns umount -l "$1" >/dev/null 2>&1 || break
    um_n=$((um_n + 1))
  done
}
cp_umount_all() { cp_umount_one /proc/cpuinfo; cp_umount_one "$CP_SOC0"; }
cp_label() { # beri label SELinux yang boleh dibaca aplikasi
  lb_ctx=$(ls -Z "$2" 2>/dev/null | awk '{print $1}' | grep '^u:object_r:' | head -n 1)
  [ -n "$lb_ctx" ] || lb_ctx="$3"
  chcon "$lb_ctx" "$1" >/dev/null 2>&1 || chcon u:object_r:system_file:s0 "$1" >/dev/null 2>&1
  chmod 444 "$1" 2>/dev/null
}
cp_hw_string() { # <pabrikan> <chipname>
  case "$1" in Qualcomm*) printf 'Qualcomm Technologies, Inc %s' "$2" ;; *) printf '%s' "$2" ;; esac
}
cp_ns_pid() { # <pid> perintah... : jalankan di mount-namespace proses lain
  np_pid=$1; shift
  command -v nsenter >/dev/null 2>&1 || return 1
  nsenter -t "$np_pid" -m -- "$@" >/dev/null 2>&1
}
cp_ns_target_pids() { # zygote (supaya app BARU mewarisi) + app info perangkat yang sedang jalan
  for tp_n in zygote zygote64 flar2.devcheck com.cpuid.cpu_z com.finalwire.aida64 com.antutu.ABenchMark; do
    for tp_p in $(pidof "$tp_n" 2>/dev/null); do printf '%s\n' "$tp_p"; done
  done
}
# v1.0.44: bind-mount hanya di namespace init sering TIDAK terlihat oleh app (namespace app = salinan
# milik zygote). Maka mount juga di namespace tiap zygote & app info yang sedang berjalan.
cp_mount_into_ns() { # <src> <dst>
  mn_c=0
  for mn_p in $(cp_ns_target_pids); do
    [ -r "/proc/$mn_p/ns/mnt" ] || continue
    # sudah ter-mount di namespace itu? lewati
    nsenter -t "$mn_p" -m -- grep -q " $2 " /proc/self/mountinfo 2>/dev/null && continue
    cp_ns_pid "$mn_p" mount --bind "$1" "$2" && mn_c=$((mn_c + 1))
  done
  printf '%s' "$mn_c"
}
cp_mount_files() { # <pabrikan> <chipname> ; hasil: CP_MNT_CPU (1/0), CP_MNT_SOC0 (1/0), CP_MNT_NS (jumlah ns)
  CP_MNT_CPU=0; CP_MNT_SOC0=0; CP_MNT_NS=0
  cp_umount_all   # baca cpuinfo ASLI dulu (bukan hasil mount sebelumnya)
  mf_hw=$(cp_hw_string "$1" "$2")
  if [ -r /proc/cpuinfo ]; then
    awk -v hw="$mf_hw" 'BEGIN{d=0} /^Hardware[ \t]*:/{ if(!d){ print "Hardware\t: " hw; d=1 } next } { print } END{ if(!d) print "Hardware\t: " hw }' /proc/cpuinfo > "$CP_FAKE_CPUINFO" 2>/dev/null
    if [ -s "$CP_FAKE_CPUINFO" ]; then
      cp_label "$CP_FAKE_CPUINFO" /proc/cpuinfo u:object_r:proc_cpuinfo:s0
      cp_ns mount --bind "$CP_FAKE_CPUINFO" /proc/cpuinfo >/dev/null 2>&1
      [ "$(grep -m1 '^Hardware' /proc/cpuinfo 2>/dev/null | sed 's/^[^:]*: *//')" = "$mf_hw" ] && CP_MNT_CPU=1
      CP_MNT_NS=$(cp_mount_into_ns "$CP_FAKE_CPUINFO" /proc/cpuinfo)
    fi
  fi
  if [ -e "$CP_SOC0" ]; then
    printf '%s\n' "$2" > "$CP_FAKE_MACHINE" 2>/dev/null
    cp_label "$CP_FAKE_MACHINE" "$CP_SOC0" u:object_r:sysfs:s0
    cp_ns mount --bind "$CP_FAKE_MACHINE" "$CP_SOC0" >/dev/null 2>&1
    [ "$(cat "$CP_SOC0" 2>/dev/null | tr -d '\r\n')" = "$2" ] && CP_MNT_SOC0=1
    cp_mount_into_ns "$CP_FAKE_MACHINE" "$CP_SOC0" >/dev/null
  fi
  cp_log "mount cpuinfo=$CP_MNT_CPU soc0_machine=$CP_MNT_SOC0 ns_tambahan=$CP_MNT_NS (hardware='$mf_hw')"
}
# v1.0.44: pasang ulang kalau mount/prop hilang (dipanggil service.sh setelah boot_completed & tombol Restart)
cp_cmd_remount() {
  [ "$(cp_conf_get SPOOF_CPU 0)" = 1 ] || { cp_say "Spoof prosesor tidak aktif."; return 0; }
  [ -s "$CP_PROPS" ] || return 0
  command -v resetprop >/dev/null 2>&1 && cp_apply_file "$CP_PROPS"
  rm_m=$(cp_meta_get manuf); rm_c=$(cp_meta_get chip)
  [ -n "$rm_m" ] && [ -n "$rm_c" ] && cp_mount_files "$rm_m" "$rm_c"
  cp_log "remount: prop=$CP_APPLIED cpuinfo=$CP_MNT_CPU ns=$CP_MNT_NS"
  cp_say "Remount selesai: prop=$CP_APPLIED cpuinfo=$CP_MNT_CPU namespace_tambahan=$CP_MNT_NS"
}
cp_meta_get() { sed -n "s/^$1=//p" "$CP_META" 2>/dev/null | head -n 1; }

cp_cmd_detect() {
  cp_kv real.soc_model "$(cp_real ro.soc.model)"
  cp_kv real.soc_manufacturer "$(cp_real ro.soc.manufacturer)"
  cp_kv real.chipname "$(cp_real ro.hardware.chipname)"
  cp_kv real.platform "$(cp_prop ro.board.platform)"
  cp_kv real.hardware "$(cp_prop ro.hardware)"
  cp_kv now.soc_model "$(cp_prop ro.soc.model)"
  cp_kv now.soc_manufacturer "$(cp_prop ro.soc.manufacturer)"
  cp_kv sdk "$(cp_prop ro.build.version.sdk)"
  cp_kv resetprop "$(command -v resetprop >/dev/null 2>&1 && echo ada || echo TIDAK-ADA)"
}

cp_verify_quiet() {
  CP_VOK=0; CP_VBAD=0
  [ -s "$CP_PROPS" ] || return 0
  while IFS='|' read -r vq_k vq_v; do
    [ -n "$vq_k" ] || continue
    if [ "$(cp_prop "$vq_k")" = "$vq_v" ]; then CP_VOK=$((CP_VOK + 1)); else CP_VBAD=$((CP_VBAD + 1)); fi
  done < "$CP_PROPS"
}

cp_cmd_status() {
  cp_kv cpuspoof "$(cp_conf_get SPOOF_CPU 0)"
  cp_kv profile "$(sed -n 's/^profile=//p' "$CP_META" 2>/dev/null | head -n 1)"
  cp_kv label "$(sed -n 's/^label=//p' "$CP_META" 2>/dev/null | head -n 1)"
  cp_kv props "$(grep -c '|' "$CP_PROPS" 2>/dev/null || echo 0)"
  cp_kv now.soc_model "$(cp_prop ro.soc.model)"
  cp_kv now.soc_manufacturer "$(cp_prop ro.soc.manufacturer)"
  cp_kv real.soc_model "$(cp_real ro.soc.model)"
  cp_kv real.platform "$(cp_prop ro.board.platform)"
  cp_kv cpuinfo.hardware "$(grep -m1 '^Hardware' /proc/cpuinfo 2>/dev/null | sed 's/^[^:]*: *//')"
  cp_kv cpuinfo.mounted "$(cp_is_mounted /proc/cpuinfo && echo 1 || echo 0)"
  cp_verify_quiet
  cp_kv mismatch "$CP_VBAD"
  cp_kv stale "$([ -f "$DATADIR/cpu_spoof.stale" ] && cat "$DATADIR/cpu_spoof.stale" || echo 0)"
  cp_kv fwstale "$([ -f "$CP_STALE" ] && echo 1 || echo 0)"
}

cp_cmd_on() {
  cp_id=$1; [ -n "$cp_id" ] || cp_id=$(cp_conf_get SPOOF_CPU_PROFILE "")
  [ -n "$cp_id" ] || { cp_say "GAGAL: sebutkan profil (lihat 'profiles')"; return 1; }
  cp_need_root || return 1; cp_need_resetprop || return 1
  cp_row=$(cp_catalog | while IFS='|' read -r a b c d e f; do [ "$a" = "$cp_id" ] && { printf '%s|%s|%s|%s|%s|%s' "$a" "$b" "$c" "$d" "$e" "$f"; break; }; done)
  [ -n "$cp_row" ] || { cp_say "GAGAL: profil '$cp_id' tidak dikenal (lihat: cpu_spoof.sh profiles)"; return 1; }
  OLDIFS=$IFS; IFS='|'; set -- $cp_row; IFS=$OLDIFS
  cp_t="$DATADIR/.cplist.$$"
  cp_build_list "$3" "$4" "$5" "$2" > "$cp_t"
  cp_save_orig "$cp_t"
  # prop milik profil lama yang tidak dipakai profil baru -> kembalikan ke asli
  if [ -s "$CP_PROPS" ]; then
    while IFS='|' read -r dd_k dd_v; do
      [ -n "$dd_k" ] || continue
      grep -q "^$dd_k|" "$cp_t" 2>/dev/null && continue
      dd_o=$(awk -F'|' -v k="$dd_k" '$1==k{print substr($0,length(k)+2); exit}' "$CP_ORIG" 2>/dev/null)
      if [ -n "$dd_o" ]; then resetprop -n "$dd_k" "$dd_o" 2>/dev/null; else resetprop --delete "$dd_k" 2>/dev/null; fi
    done < "$CP_PROPS"
  fi
  mv -f "$cp_t" "$CP_PROPS"
  { echo "profile=$1"; echo "label=$6"; echo "manuf=$3"; echo "chip=$5"; echo "epoch=$(date +%s)"; } > "$CP_META"
  cp_apply_file "$CP_PROPS"; cp_rc=$?
  cp_conf_set SPOOF_CPU 1; cp_conf_set SPOOF_CPU_PROFILE "$1"
  rm -f "$DATADIR/cpu_spoof.stale"; echo 1 > "$CP_STALE"
  cp_log "on $1: $CP_APPLIED prop ditimpa, $cp_rc gagal"
  cp_mount_files "$3" "$5"
  cp_verify_quiet
  cp_say "Spoof prosesor AKTIF: $6 (ro.soc.model='$4', pabrikan='$3') - $CP_APPLIED properti ditimpa (in-memory, tidak ada berkas sistem yang diubah)."
  [ "$cp_rc" -gt 0 ] && cp_say "CATATAN: $cp_rc properti ditolak resetprop."
  [ "$CP_MNT_CPU" = 1 ] && cp_say "/proc/cpuinfo: baris Hardware sudah diganti (DevCheck membaca ini)." || cp_say "CATATAN: bind-mount /proc/cpuinfo gagal (SELinux/kernel menolak) - hanya properti yang berubah."
  [ "$CP_MNT_SOC0" = 1 ] && cp_say "/sys/devices/soc0/machine ikut diganti."
  for fs_a in flar2.devcheck com.cpuid.cpu_z; do am force-stop "$fs_a" >/dev/null 2>&1; done
  cp_say "getprop sudah berubah ($CP_VOK cocok, $CP_VBAD beda). Aplikasi baru membaca Build.SOC_MODEL setelah framework di-restart: jalankan 'restart' atau REBOOT."
  return 0
}

cp_cmd_off() {
  cp_need_root || return 1
  cp_restore_orig
  cp_umount_all
  rm -f "$CP_FAKE_CPUINFO" "$CP_FAKE_MACHINE"
  rm -f "$CP_PROPS" "$CP_META" "$DATADIR/cpu_spoof.stale"
  echo 1 > "$CP_STALE"
  cp_conf_set SPOOF_CPU 0
  cp_log "off: $CP_RESTORED properti dikembalikan"
  cp_say "Spoof prosesor MATI: $CP_RESTORED properti dikembalikan ke nilai asli. REBOOT agar sistem sepenuhnya bersih."
}

cp_cmd_verify() {
  [ -s "$CP_PROPS" ] || { cp_say "Tidak ada spoof aktif."; return 1; }
  vf_ok=0; vf_bad=0
  while IFS='|' read -r vf_k vf_v; do
    [ -n "$vf_k" ] || continue
    if [ "$(cp_prop "$vf_k")" = "$vf_v" ]; then vf_ok=$((vf_ok + 1)); else vf_bad=$((vf_bad + 1)); cp_say "[BEDA ] $vf_k = '$(cp_prop "$vf_k")' (target '$vf_v')"; fi
  done < "$CP_PROPS"
  cp_say "Cocok: $vf_ok  Tidak cocok: $vf_bad"
  cp_say "/proc/cpuinfo Hardware = '$(grep -m1 '^Hardware' /proc/cpuinfo 2>/dev/null | sed 's/^[^:]*: *//')' (mount: $(cp_is_mounted /proc/cpuinfo && echo aktif || echo TIDAK-AKTIF))"
  cp_is_mounted /proc/cpuinfo || cp_say "PERINGATAN: cpuinfo belum di-mount - tekan Restart framework atau reboot, lalu Verifikasi lagi."
  [ "$vf_bad" -eq 0 ] && cp_say "HASIL: COCOK - spoof prosesor bekerja." || cp_say "HASIL: ada properti yang tidak cocok (mungkin ditimpa ulang modul lain)."
  [ "$vf_bad" -eq 0 ]
}

cp_cmd_restart() {
  cp_need_root || return 1
  cp_say "Restart framework dimulai (~15 dtk, layar sempat berkedip). Aplikasi ditutup; setelah itu nama prosesor baru terbaca."
  cp_log "restart framework (zygote)"
  rm -f "$CP_STALE"
  ( sleep 2
    setprop ctl.restart zygote_secondary >/dev/null 2>&1
    setprop ctl.restart zygote >/dev/null 2>&1 || { stop >/dev/null 2>&1; start >/dev/null 2>&1; }
  ) >/dev/null 2>&1 &
  return 0
}

# dipanggil post-fs-data.sh (SEBELUM zygote)
cp_cmd_boot() {
  rm -f "$CP_STALE"
  [ "$(cp_conf_get SPOOF_CPU 0)" = 1 ] || return 0
  [ -s "$CP_PROPS" ] || return 0
  case "$1" in ''|*[!0-9]*) bn=0 ;; *) bn=$1 ;; esac
  if [ "$bn" -ge 3 ]; then
    cp_conf_set SPOOF_CPU 0
    echo "boot sebelumnya tidak sehat" > "$DATADIR/cpu_spoof.stale"
    cp_log "BOOT failsafe: spoof prosesor dimatikan (boot_count=$bn)"
    return 0
  fi
  command -v resetprop >/dev/null 2>&1 || return 0
  cp_apply_file "$CP_PROPS"
  cp_log "BOOT: $CP_APPLIED properti prosesor diterapkan"
  bo_m=$(cp_meta_get manuf); bo_c=$(cp_meta_get chip)
  if [ -n "$bo_m" ] && [ -n "$bo_c" ]; then cp_mount_files "$bo_m" "$bo_c"; fi
  return 0
}

cp_main() {
  CP_RESTART=0
  cp_n=$#; cp_i=0
  while [ "$cp_i" -lt "$cp_n" ]; do
    cp_x=$1; shift; cp_i=$((cp_i + 1))
    if [ "$cp_x" = "--restart" ]; then CP_RESTART=1; else set -- "$@" "$cp_x"; fi
  done
  cp_c=$1; shift 2>/dev/null
  case "$cp_c" in
    detect) cp_cmd_detect ;;
    profiles|models) cp_catalog ;;
    status|"") cp_cmd_status ;;
    on|set) cp_cmd_on "$1" ;;
    off|restore) cp_cmd_off ;;
    verify) cp_cmd_verify ;;
    boot) cp_cmd_boot "$1" ;;
    restart) cp_cmd_restart ;;
    remount) cp_cmd_remount ;;
    *) cp_say "pakai: cpu_spoof.sh detect|profiles|status|on <id>|off|verify|restart|remount|boot <n> [--restart]"; return 1 ;;
  esac
}
cp_run() { cp_main "$@"; cp_rc2=$?; case "$1" in on|set|off) [ "$CP_RESTART" = 1 ] && [ "$cp_rc2" = 0 ] && cp_cmd_restart ;; esac; return "$cp_rc2"; }
cp_run "$@"
