#!/system/bin/sh
# =====================================================================
#  Zyrox - lib/cpucore.sh   (v1.0.33)
#  Matikan / hidupkan core CPU PER CORE lewat
#    /sys/devices/system/cpu/cpuN/online   (1 = aktif, 0 = offline)
#
#  - cpu0 (boot CPU) TIDAK PERNAH dimatikan (dilewati selalu).
#  - Topologi DINAMIS: daftar core dibaca dari cpu[0-9]*, jadi aman di
#    quad/hexa/octa-core dan 1+3+4 / 1+4+3. Core tanpa node `online`
#    (kernel tanpa hotplug) dilewati dan dilaporkan.
#  - Pilihan disimpan di conf: CC_OFF_LIST (nomor core offline, pisah koma)
#    dan CC_BOOT (1 = "Set on boot": terapkan ulang setelah reboot).
#    Kalau CC_BOOT=0 daftar dikosongkan saat boot (semua core online).
#  - Daemon (cc_watch) menegakkan lagi core yang dihidupkan PowerHAL/thermal.
#  - Sengaja TIDAK memakai safe_write/STACK: cleanup_all (tiap pindah mode
#    thermal) akan menghidupkan core lagi tanpa sepengetahuan user.
#  - Setelah core dihidupkan, policy cpufreq dibuat ulang kernel -> kunci
#    freq mode aktif diterapkan ulang (ml_watch).
# =====================================================================

CC_CPUDIR="$R/sys/devices/system/cpu"
CC_SPLIT=5            # a = core 1-5, b = core >=6 (shorthand CLI)

cc_setconf() { # cc_setconf KEY VAL
  if grep -q "^$1=" "$CONF" 2>/dev/null; then sed -i "s/^$1=[^ #]*/$1=$2/" "$CONF"
  else echo "$1=$2" >> "$CONF"; fi
  # salinan di LUAR folder data modul: tetap ada walau conf/data direset saat update (dipulihkan service.sh)
  case "$1" in CC_OFF_LIST|CC_BOOT)
    ccs_k=/data/adb/azenith-keep; mkdir -p "$ccs_k" 2>/dev/null
    { grep -v "^$1=" "$ccs_k/cpucore.conf" 2>/dev/null; echo "$1=$2"; } > "$ccs_k/cpucore.conf.t" 2>/dev/null && mv -f "$ccs_k/cpucore.conf.t" "$ccs_k/cpucore.conf" ;;
  esac
}

cc_ids() { # semua core yang ada (urut naik), termasuk yang offline
  for cci_d in "$CC_CPUDIR"/cpu[0-9]*; do
    [ -d "$cci_d" ] || continue
    cci_n=${cci_d##*/cpu}
    case "$cci_n" in ''|*[!0-9]*) continue ;; esac
    echo "$cci_n"
  done | sort -n
}

cc_ctrl_ids() { # core yang BISA dikontrol: bukan cpu0 & punya node online
  for ccc_n in $(cc_ids); do
    [ "$ccc_n" -eq 0 ] && continue
    [ -e "$CC_CPUDIR/cpu$ccc_n/online" ] && echo "$ccc_n"
  done
}

cc_get() { # 1 / 0 (tanpa node online dianggap 1)
  ccx_v=$(read1 "$CC_CPUDIR/cpu$1/online")
  case "$ccx_v" in 0) echo 0 ;; *) echo 1 ;; esac
}

cc_write() { # cc_write <n> <0|1> -> 0 kalau hasil baca-ulang sama
  ccw_p="$CC_CPUDIR/cpu$1/online"
  [ -e "$ccw_p" ] || return 1
  [ "$1" -eq 0 ] && return 1
  ccw_try=0
  while [ "$ccw_try" -lt 3 ]; do
    { chmod 644 "$ccw_p"; } 2>/dev/null
    { echo "$2" > "$ccw_p"; } 2>/dev/null
    [ "$(cc_get "$1")" = "$2" ] && return 0
    ccw_try=$((ccw_try + 1))
    sleep 0.2 2>/dev/null
  done
  return 1
}

# cc_expand <n | a | b | all> -> daftar core target (hanya yang bisa dikontrol)
cc_expand() {
  case "$1" in
    all) cc_ctrl_ids ;;
    a) for cce_n in $(cc_ctrl_ids); do [ "$cce_n" -le "$CC_SPLIT" ] && echo "$cce_n"; done ;;
    b) for cce_n in $(cc_ctrl_ids); do [ "$cce_n" -gt "$CC_SPLIT" ] && echo "$cce_n"; done ;;
    ''|*[!0-9]*) return 1 ;;
    *) for cce_n in $(cc_ctrl_ids); do [ "$cce_n" = "$1" ] && echo "$cce_n"; done ;;
  esac
}

cc_list_get() { echo "$CC_OFF_LIST" | tr ',' ' '; }
cc_list_save() { # cc_list_save <ids dipisah spasi>
  ccl_v=$(for ccl_n in $1; do echo "$ccl_n"; done | sort -un | tr '\n' ',' | sed 's/,$//')
  cc_setconf CC_OFF_LIST "$ccl_v"
  CC_OFF_LIST=$ccl_v
}

cc_reapply_freq() {
  sleep 1 2>/dev/null
  type ml_watch >/dev/null 2>&1 && ml_watch
}

# cc_set <n|a|b|all> <on|off>   (off = core dimatikan)
cc_set() {
  css_t=$1; css_a=$2
  case "$css_a" in on|off) ;; *) echo "aksi tidak dikenal: $css_a (on|off)"; return 2 ;; esac
  if [ "$css_t" = 0 ]; then echo "cpu0 (boot CPU) tidak boleh dimatikan."; return 1; fi
  case "$css_t" in all|a|b) ;; ''|*[!0-9]*) echo "target tidak dikenal: $css_t (nomor core|a|b|all)"; return 2 ;; esac
  css_ids=$(cc_expand "$css_t" | tr '\n' ' ' | sed 's/ $//')
  if [ -z "$css_ids" ]; then
    echo "Tidak ada core yang bisa dikontrol untuk target '$css_t' (tidak ada / kernel tanpa node online)."
    return 1
  fi
  if [ "$css_a" = off ]; then
    css_val=0; css_ord=$(for css_n in $css_ids; do echo "$css_n"; done | sort -rn)
  else
    css_val=1; css_ord=$css_ids
  fi
  css_ok=0; css_bad=0; css_done=""
  for css_n in $css_ord; do
    if cc_write "$css_n" "$css_val"; then css_ok=$((css_ok + 1)); css_done="$css_done $css_n"; else css_bad=$((css_bad + 1)); fi
  done
  css_cur=$(cc_list_get)
  if [ "$css_a" = off ]; then
    cc_list_save "$css_cur $css_done"
  else
    css_new=""
    for css_n in $css_cur; do
      case " $css_ids " in *" $css_n "*) ;; *) css_new="$css_new $css_n" ;; esac
    done
    cc_list_save "$css_new"
    cc_reapply_freq
  fi
  echo "cpu$(echo $css_ids | tr ' ' ',') -> $css_a  [$css_ok berhasil, $css_bad gagal]"
  [ "$css_bad" -eq 0 ]
}

cc_enforce() { # matikan lagi core di daftar yang ternyata online -> echo jumlah
  cef_n=0
  for cef_c in $(cc_list_get); do
    [ "$(cc_get "$cef_c")" = 1 ] && cc_write "$cef_c" 0 && cef_n=$((cef_n + 1))
  done
  echo "$cef_n"
}

cc_boot_set() { # cc_boot_set on|off
  case "$1" in on) cc_setconf CC_BOOT 1; CC_BOOT=1; echo "Set on boot: ON" ;;
               off) cc_setconf CC_BOOT 0; CC_BOOT=0; echo "Set on boot: OFF" ;;
               *) echo "boot on|off"; return 2 ;; esac
}

cc_boot_apply() {
  [ "$CC_BOOT" = 1 ] && [ -n "$CC_OFF_LIST" ] || return 0
  cba_n=$(cc_enforce)
  log_msg "CPUCORE: boot - core offline diterapkan ulang ($CC_OFF_LIST, diubah=$cba_n)"
  flog CPUCORE OK "boot: terapkan ulang core offline ($CC_OFF_LIST), diubah=$cba_n"
}

cc_watch() { # dipanggil daemon berkala
  [ -n "$CC_OFF_LIST" ] || return 0
  cw_n=$(cc_enforce)
  [ "$cw_n" -gt 0 ] 2>/dev/null && log_msg "CPUCORE: watch - $cw_n core dihidupkan pihak lain, dimatikan lagi"
}

cc_restore_all() { # semua core online + hapus daftar
  for crs_n in $(cc_ctrl_ids); do cc_write "$crs_n" 1; done
  cc_setconf CC_OFF_LIST "" 2>/dev/null; CC_OFF_LIST=""
}

cc_status() { # key=value (dibaca WebUI)
  cs_all=$(cc_ids | tr '\n' ' ')
  echo "cores=$(cc_ids | wc -l | tr -d ' ')"
  echo "ids=${cs_all% }"
  echo "ctrl=$(cc_ctrl_ids | tr '\n' ' ' | sed 's/ $//')"
  echo "online_kernel=$(read1 "$CC_CPUDIR/online")"
  echo "boot=${CC_BOOT:-0}"
  echo "off_list=$CC_OFF_LIST"
  for cs_n in $cs_all; do echo "cpu$cs_n=$(cc_get "$cs_n")"; done
}
