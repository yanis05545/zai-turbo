#!/system/bin/sh
# =====================================================================
#  Zyrox - lib/wifill.sh : "WiFi Low Latency"
#
#  Fitur TERSENDIRI (bukan bagian Network Booster). Tujuannya: waktu respons
#  (latensi/ping) Wi-Fi sekecil mungkin saat paket pulang-pergi device <-> server.
#  Ibarat jalan tol: bandwidth = lebar jalan, latensi = seberapa cepat mobilnya
#  sampai. Toggle ini tidak menambah "lebar jalan", tapi menghilangkan hambatan
#  yang bikin ping melonjak: radio Wi-Fi yang tidur, scan latar belakang, dll.
#
#  Yang dilakukan (semuanya dibackup & bisa dibalikkan wl_off):
#   1) cmd wifi force-low-latency-mode enabled   (API WifiManager low-latency,
#      Android 10+; dicek dulu lewat 'cmd wifi help' - kalau ROM tidak punya,
#      dilaporkan "tidak didukung", BUKAN pura-pura berhasil)
#   2) Settings.Global wifi_suspend_optimizations_enabled=0 (radio tidak
#      ditidurkan saat layar mati/idle) & wifi_scan_throttle_enabled=0
#   3) iw dev <wlan> set power_save off  (hanya kalau biner 'iw' ada di device;
#      dibaca-balik untuk verifikasi)
#
#  Tahan reboot lewat WIFILL=1 di conf (diterapkan ulang oleh service.sh).
# =====================================================================

WL_SETBK="$DATADIR/wifill_settings_backup"   # k|v settings global asli
WL_IWBK="$DATADIR/wifill_iw_backup"          # iface|power_save asli (on/off)

wl_setconf() { # wl_setconf KEY VAL
  if grep -q "^$1=" "$CONF" 2>/dev/null; then sed -i "s/^$1=[^ #]*/$1=$2/" "$CONF"
  else echo "$1=$2" >> "$CONF"; fi
}

# ROM mendukung perintah force-low-latency-mode?
wl_cmd_supported() { cmd wifi help 2>&1 | grep -q 'force-low-latency-mode'; }

# nama interface Wi-Fi (wlan0 umumnya)
wl_iface() {
  wi_p=$(getprop wifi.interface 2>/dev/null)
  [ -n "$wi_p" ] && [ -d "$R/sys/class/net/$wi_p" ] && { echo "$wi_p"; return 0; }
  for wi_i in wlan0 wlan1 wlan2; do
    [ -d "$R/sys/class/net/$wi_i" ] && { echo "$wi_i"; return 0; }
  done
  return 1
}

wl_iw_state() { # wl_iw_state <iface> -> on|off|"" (kosong = tidak terbaca)
  command -v iw >/dev/null 2>&1 || return 0
  iw dev "$1" get power_save 2>/dev/null | sed -n 's/.*[Pp]ower save: *\([a-z]*\).*/\1/p' | head -n 1
}

wl_on() {
  load_conf
  wl_ok=0; wl_fail=0
  # 1) force-low-latency-mode
  if wl_cmd_supported; then
    if cmd wifi force-low-latency-mode enabled >/dev/null 2>&1; then
      wl_ok=$((wl_ok + 1)); wl_cmd_r="aktif"
    else wl_fail=$((wl_fail + 1)); wl_cmd_r="GAGAL dijalankan"; fi
  else
    wl_cmd_r="tidak didukung ROM ini (cmd wifi tidak punya force-low-latency-mode)"
  fi
  # 2) settings global (backup nilai asli SEKALI - jangan timpa backup kalau sudah ada)
  [ -s "$WL_SETBK" ] || : > "$WL_SETBK"
  wl_set_r=""
  for wl_k in wifi_suspend_optimizations_enabled wifi_scan_throttle_enabled; do
    grep -q "^$wl_k|" "$WL_SETBK" 2>/dev/null || echo "$wl_k|$(settings get global "$wl_k" 2>/dev/null)" >> "$WL_SETBK"
    settings put global "$wl_k" 0 2>/dev/null
    wl_now=$(settings get global "$wl_k" 2>/dev/null | tr -d ' \r\n')
    if [ "$wl_now" = 0 ]; then wl_ok=$((wl_ok + 1)); wl_set_r="$wl_set_r $wl_k=0"
    else wl_fail=$((wl_fail + 1)); wl_set_r="$wl_set_r $wl_k=GAGAL($wl_now)"; fi
  done
  # 3) iw power_save off
  wl_iw_r="biner 'iw' tidak ada di device (dilewati)"
  wl_if=$(wl_iface)
  if [ -n "$wl_if" ] && command -v iw >/dev/null 2>&1; then
    wl_old=$(wl_iw_state "$wl_if")
    if [ -z "$wl_old" ]; then wl_iw_r="$wl_if: driver tidak melaporkan power_save (dilewati)"
    else
      [ -s "$WL_IWBK" ] || echo "$wl_if|$wl_old" > "$WL_IWBK"
      iw dev "$wl_if" set power_save off >/dev/null 2>&1
      if [ "$(wl_iw_state "$wl_if")" = off ]; then wl_ok=$((wl_ok + 1)); wl_iw_r="$wl_if: power_save off (terverifikasi)"
      else wl_fail=$((wl_fail + 1)); wl_iw_r="$wl_if: power_save TIDAK mau off (ditolak driver)"; fi
    fi
  fi
  if [ "$wl_ok" -gt 0 ]; then
    wl_setconf WIFILL 1
    log_msg "WIFILL: AKTIF (cmd=$wl_cmd_r;$wl_set_r; iw=$wl_iw_r)"
    echo "WiFi Low Latency: AKTIF ($wl_ok metode berhasil, $wl_fail gagal)"
  else
    wl_setconf WIFILL 0
    log_msg "WIFILL: GAGAL - tidak ada metode yang bisa diterapkan"
    echo "WiFi Low Latency: GAGAL - tidak ada satu pun metode yang berhasil diterapkan di device ini"
  fi
  echo "  force-low-latency-mode : $wl_cmd_r"
  echo " $wl_set_r" | sed 's/^ */  settings global        : /'
  echo "  iw power_save          : $wl_iw_r"
  wl_status
  [ "$wl_ok" -gt 0 ]
}

wl_off() {
  load_conf
  wl_cmd_supported && cmd wifi force-low-latency-mode disabled >/dev/null 2>&1
  if [ -s "$WL_SETBK" ]; then
    while IFS='|' read -r wo_k wo_v; do
      [ -n "$wo_k" ] || continue
      case "$wo_v" in ''|null) settings delete global "$wo_k" >/dev/null 2>&1 ;; *) settings put global "$wo_k" "$wo_v" 2>/dev/null ;; esac
    done < "$WL_SETBK"
    : > "$WL_SETBK"
  fi
  if [ -s "$WL_IWBK" ] && command -v iw >/dev/null 2>&1; then
    IFS='|' read -r wo_if wo_ps < "$WL_IWBK"
    [ -n "$wo_if" ] && [ -n "$wo_ps" ] && iw dev "$wo_if" set power_save "$wo_ps" >/dev/null 2>&1
    : > "$WL_IWBK"
  fi
  wl_setconf WIFILL 0
  log_msg "WIFILL: MATI (semua setting dikembalikan)"
  echo "WiFi Low Latency: MATI (semua setting dikembalikan ke nilai asal)"
  wl_status
}

wl_status() {
  load_conf
  wl_if=$(wl_iface)
  echo "WIFILL=$WIFILL  cmd_didukung=$(wl_cmd_supported && echo ya || echo tidak)  iface=${wl_if:--}  suspend_opt=$(settings get global wifi_suspend_optimizations_enabled 2>/dev/null)  scan_throttle=$(settings get global wifi_scan_throttle_enabled 2>/dev/null)  iw_power_save=$([ -n "$wl_if" ] && wl_iw_state "$wl_if" | grep . || echo n/a)"
}

# ---------------------------------------------------------------------
# Ping NYATA sekali jalan untuk indikator latensi WebUI (`azenith-ai ping`).
# Lewat ICMP dari shell root -> sama persis untuk WiFi maupun data seluler/paketan,
# tidak bergantung server echo pihak ketiga maupun fitur WebView.
# Output key=value: ms / jitter / loss / host  (gagal -> ms kosong + err=alasan)
# Selalu exit 0 supaya WebUI bisa membaca alasan gagalnya.
# ---------------------------------------------------------------------
net_ping_once() {
  if ! command -v ping >/dev/null 2>&1; then echo "ms="; echo "err=biner ping tidak ada di device"; return 0; fi
  np1_err="tidak ada balasan ICMP (diblokir operator/jaringan?)"
  for np1_h in ${NET_PING_HOST:-} 1.1.1.1 8.8.8.8 9.9.9.9; do
    [ -n "$np1_h" ] || continue
    np1_o=$(ping -c 3 -i 0.3 -W 2 -w 6 "$np1_h" 2>/dev/null)
    [ -n "$np1_o" ] || np1_o=$(ping -c 2 -W 2 "$np1_h" 2>/dev/null)   # ping versi lain tanpa -i/-w
    np1_v=$(echo "$np1_o" | sed -n 's#.*= *\([0-9.]*\)/\([0-9.]*\)/\([0-9.]*\)/\([0-9.]*\).*#\2 \4#p' | head -n 1)
    set -- $np1_v
    if [ -n "$1" ]; then
      np1_l=$(echo "$np1_o" | sed -n 's/.*[ ,]\([0-9][0-9]*\)% packet loss.*/\1/p' | head -n 1)
      echo "ms=$1"; echo "jitter=${2:-0}"; echo "loss=${np1_l:-0}"; echo "host=$np1_h"
      return 0
    fi
  done
  echo "ms="; echo "err=$np1_err"
  return 0
}
