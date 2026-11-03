#!/system/bin/sh
# =====================================================================
#  Zyrox - lib/wifitweak.sh : "WiFi Tweak"
#
#  Toggle TERSENDIRI (satu kartu di tab Kontrol, pola sama seperti Network
#  Booster). Menjalankan 15 perintah `cmd wifi` untuk Wi-Fi yang lebih
#  responsif & tidak dihambat fitur latar belakang:
#
#   clear-user-disabled-networks     (sekali jalan, TIDAK bisa di-undo)
#   enable-scanning enabled
#   force-hi-perf-mode enabled
#   force-low-latency-mode enabled
#   set-emergency-call-state / -callback-mode / -scan-request disabled
#   set-ipreach-disconnect disabled
#   set-passpoint-enabled disabled
#   set-pno-scan disabled
#   set-restricted-network-debug disabled
#   set-scan-always-available disabled
#   set-scan-throttling-enabled disabled
#   set-verbose-logging disabled
#   set-wifi-watchdog disabled
#
#  Tidak semua ROM punya semua subcommand. Tiap subcommand dicek dulu lewat
#  `cmd wifi help`; yang tidak ada dilaporkan "tidak didukung", BUKAN pura-pura
#  berhasil. Hasil tiap perintah dicek dari exit-code + isi output.
#
#  wt_off mengembalikan ke default AOSP (hi-perf/low-latency disabled, pno/
#  passpoint/ipreach/watchdog/throttling enabled). set-scan-always-available
#  dikembalikan ke nilai SEBELUM aktif (dibackup dari Settings.Global).
#  Dua item milik fitur WiFi Low Latency (force-low-latency-mode &
#  scan-throttling) TIDAK dikembalikan kalau WIFILL=1, supaya tidak saling
#  membatalkan. enable-scanning, 3 emergency & restricted-network-debug
#  default-nya sudah 'normal', tidak perlu dikembalikan.
#
#  Tahan reboot lewat WIFITWEAK=1 di conf (diterapkan ulang oleh service.sh).
# =====================================================================

WT_BK="$DATADIR/wifitweak_backup"   # key|nilai_asli (Settings.Global)

wt_setconf() { # wt_setconf KEY VAL
  if grep -q "^$1=" "$CONF" 2>/dev/null; then sed -i "s/^$1=[^ #]*/$1=$2/" "$CONF"
  else echo "$1=$2" >> "$CONF"; fi
}

# subcommand|nilai_on  (nilai kosong = perintah tanpa argumen)
wt_table() {
cat <<'EOF'
clear-user-disabled-networks|
enable-scanning|enabled
force-hi-perf-mode|enabled
force-low-latency-mode|enabled
set-emergency-call-state|disabled
set-emergency-callback-mode|disabled
set-emergency-scan-request|disabled
set-ipreach-disconnect|disabled
set-passpoint-enabled|disabled
set-pno-scan|disabled
set-restricted-network-debug|disabled
set-scan-always-available|disabled
set-scan-throttling-enabled|disabled
set-verbose-logging|disabled
set-wifi-watchdog|disabled
EOF
}

wt_help_cache=""
wt_has() { # subcommand ada di `cmd wifi help`?
  [ -n "$wt_help_cache" ] || wt_help_cache=$(cmd wifi help 2>&1)
  echo "$wt_help_cache" | grep -q -- "$1"
}

# wt_exec <sub> [nilai] -> 0 kalau exit-code 0 DAN output tidak memuat error
wt_exec() {
  we_o=$(cmd wifi "$@" 2>&1); we_rc=$?
  [ "$we_rc" = 0 ] || return 1
  echo "$we_o" | grep -qiE 'exception|unknown command|error|not supported|permission denied' && return 1
  return 0
}

wt_on() {
  load_conf
  wt_help_cache=""
  wt_ok=0; wt_fail=0; wt_unsup=0; wt_rep=""
  # backup nilai asli SEKALI (re-apply saat boot tidak boleh menimpa dengan nilai yang sudah kita ubah)
  [ -s "$WT_BK" ] || echo "wifi_scan_always_enabled|$(settings get global wifi_scan_always_enabled 2>/dev/null | tr -d '\r')" > "$WT_BK"
  while IFS='|' read -r wt_s wt_v; do
    [ -n "$wt_s" ] || continue
    if ! wt_has "$wt_s"; then
      wt_unsup=$((wt_unsup + 1)); wt_rep="$wt_rep
    [tidak didukung] $wt_s"; continue
    fi
    if wt_exec "$wt_s" $wt_v; then
      wt_ok=$((wt_ok + 1)); wt_rep="$wt_rep
    [ok]     $wt_s $wt_v"
    else
      wt_fail=$((wt_fail + 1)); wt_rep="$wt_rep
    [GAGAL]  $wt_s $wt_v (ditolak ROM)"
    fi
  done <<EOF
$(wt_table)
EOF
  if [ "$wt_ok" -gt 0 ]; then
    wt_setconf WIFITWEAK 1
    log_msg "WIFITWEAK: AKTIF ok=$wt_ok gagal=$wt_fail tidak_didukung=$wt_unsup"
    echo "WiFi Tweak: AKTIF ($wt_ok perintah berhasil, $wt_fail gagal, $wt_unsup tidak didukung ROM ini)"
    echo "$wt_rep" | sed '/^$/d'
    echo "catatan: clear-user-disabled-networks hanya berjalan sekali & tidak bisa dibatalkan; pno-scan OFF bisa membuat Wi-Fi lebih lambat tersambung ulang saat layar mati"
    wt_status
    return 0
  fi
  wt_setconf WIFITWEAK 0
  log_msg "WIFITWEAK: GAGAL - tidak ada perintah yang berhasil"
  echo "WiFi Tweak: GAGAL - tidak ada satu pun perintah cmd wifi yang berhasil di device ini"
  echo "$wt_rep" | sed '/^$/d'
  return 1
}

wt_off() {
  load_conf
  wt_help_cache=""
  wt_n=0
  wt_rev() { # wt_rev <sub> <nilai>
    wt_has "$1" || return 0
    wt_exec "$1" "$2" && wt_n=$((wt_n + 1))
  }
  wt_rev force-hi-perf-mode disabled
  [ "$WIFILL" = 1 ] || wt_rev force-low-latency-mode disabled
  [ "$WIFILL" = 1 ] || wt_rev set-scan-throttling-enabled enabled
  wt_rev set-pno-scan enabled
  wt_rev set-passpoint-enabled enabled
  wt_rev set-ipreach-disconnect enabled
  wt_rev set-wifi-watchdog enabled
  wt_old=$(sed -n 's/^wifi_scan_always_enabled|//p' "$WT_BK" 2>/dev/null | head -n 1)
  if [ -s "$WT_BK" ]; then
    case "$wt_old" in 1) wt_rev set-scan-always-available enabled ;; *) wt_rev set-scan-always-available disabled ;; esac
  fi
  : > "$WT_BK"
  wt_setconf WIFITWEAK 0
  log_msg "WIFITWEAK: MATI ($wt_n perintah dikembalikan ke default)"
  echo "WiFi Tweak: MATI ($wt_n perintah dikembalikan ke default/nilai asal)"
  [ "$WIFILL" = 1 ] && echo "force-low-latency-mode & scan-throttling dibiarkan karena WiFi Low Latency masih AKTIF"
  wt_status
}

wt_status() {
  load_conf
  wt_help_cache=""
  wt_sup=0; wt_tot=0
  while IFS='|' read -r wt_s wt_v; do
    [ -n "$wt_s" ] || continue
    wt_tot=$((wt_tot + 1)); wt_has "$wt_s" && wt_sup=$((wt_sup + 1))
  done <<EOF
$(wt_table)
EOF
  echo "WIFITWEAK=$WIFITWEAK  didukung_ROM=$wt_sup/$wt_tot  wifill=$WIFILL  scan_always_asli=$(sed -n 's/^wifi_scan_always_enabled|//p' "$WT_BK" 2>/dev/null | head -n 1)"
}
