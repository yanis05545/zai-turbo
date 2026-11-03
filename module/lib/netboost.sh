#!/system/bin/sh
# =====================================================================
#  Zyrox v2 - lib/netboost.sh : "Network Booster"
#
#  "Network Booster" = tuning NYATA sysctl TCP/IP (congestion control,
#  buffer, fastopen, low latency) - bukan sekadar toggle visual.
#
#  v1.0.16: bagian WiFi low-latency DIPISAH jadi fitur tersendiri
#  (lib/wifill.sh, `azenith-ai wifill on|off`) supaya tiap fitur punya toggle
#  sendiri dan tidak saling menimpa. Network Booster sekarang murni TCP/IP.
#
#  congestion control: AKTIF -> bbr3 (fallback bbr/westwood/cubic kalau
#  bbr3 tidak tersedia di kernel ini), MATI -> dipaksa cubic secara
#  eksplisit (bukan sekadar restore nilai sebelum aktif).
#
#  Semua tweak lain di nb_on() lewat safe_write/prop_set/settings yang SAMA
#  dipakai modul lain (nilai asli di-backup, bisa direvert nb_off()),
#  JADI BUKAN toggle satu-arah yang meninggalkan sisa kalau dimatikan.
# =====================================================================

NB_BK="$DATADIR/netboost_backup"   # path|nilai_asli sysctl (format sama seperti CHG_BK)
NB_SETBK="$DATADIR/netboost_settings_backup"  # k|v (settings global, format sama refresh_apply)

nb_setconf() { # nb_setconf KEY VAL
  if grep -q "^$1=" "$CONF" 2>/dev/null; then sed -i "s/^$1=[^ #]*/$1=$2/" "$CONF"
  else echo "$1=$2" >> "$CONF"; fi
}

nb_write() { # nb_write PATH VAL  -> backup nilai asli sekali, lalu tulis
  nw_p=$1; nw_v=$2
  [ -w "$nw_p" ] || return 1
  grep -q "^$nw_p|" "$NB_BK" 2>/dev/null || echo "$nw_p|$(dv_cat "$nw_p")" >> "$NB_BK"
  { echo "$nw_v" > "$nw_p"; } 2>/dev/null
}

nb_restore() {
  [ -s "$NB_BK" ] || { : > "$NB_BK"; return 0; }
  while IFS='|' read -r nr_p nr_v; do
    [ -n "$nr_p" ] && [ -e "$nr_p" ] && [ -n "$nr_v" ] && { echo "$nr_v" > "$nr_p"; } 2>/dev/null
  done < "$NB_BK"
  : > "$NB_BK"
}

# -------------------- NSS / optimasi TCP-IP + fix latency --------------------
# Congestion control: NYATA ditulis ke /proc/sys/net/ipv4/tcp_congestion_control
# DAN diverifikasi dibaca-ulang dari file yang SAMA - bukan cuma dicek dari
# daftar tcp_available_congestion_control (sebagian kernel baru memuat modul
# algoritma-nya ON-DEMAND begitu ditulis, jadi belum tentu nongol di daftar
# "available" SEBELUM dicoba tulis). AKTIF -> coba bbr3 dulu, baru fallback
# NET_CONGESTION (override user) -> bbr -> westwood -> cubic, berhenti di
# kandidat PERTAMA yang terbukti benar-benar masuk (read-back cocok).
NB_CC_PATH="$R/proc/sys/net/ipv4/tcp_congestion_control"

nb_congestion_try() { # nb_congestion_try VALUE -> 0 kalau NYATA masuk ke file (read-back cocok)
  nb_write "$NB_CC_PATH" "$1" || return 1
  [ "$(dv_cat "$NB_CC_PATH" 2>/dev/null)" = "$1" ]
}

nb_congestion_apply() { # tulis+verifikasi, cetak nama algoritma yang BERHASIL masuk (kosong kalau semua gagal)
  for nc_try in "${NET_CONGESTION:-bbr3}" bbr3 bbr westwood cubic; do
    [ -n "$nc_try" ] && [ "$nc_try" != auto ] || continue
    if nb_congestion_try "$nc_try"; then echo "$nc_try"; return 0; fi
  done
  echo ""
  return 1
}

nb_on() {
  load_conf
  : > "$NB_BK"
  nb_cc=$(nb_congestion_apply)
  # NSS - buffer & window TCP/IP lebih besar supaya tidak jadi bottleneck di
  # koneksi cepat, tetap aman untuk RAM kecil (nilai moderat, bukan ekstrem)
  nb_write "$R/proc/sys/net/core/rmem_max" 8388608
  nb_write "$R/proc/sys/net/core/wmem_max" 8388608
  nb_write "$R/proc/sys/net/core/rmem_default" 1048576
  nb_write "$R/proc/sys/net/core/wmem_default" 1048576
  nb_write "$R/proc/sys/net/core/netdev_max_backlog" 2500
  nb_write "$R/proc/sys/net/core/somaxconn" 1024
  nb_write "$R/proc/sys/net/ipv4/tcp_rmem" "4096 1048576 8388608"
  nb_write "$R/proc/sys/net/ipv4/tcp_wmem" "4096 1048576 8388608"
  nb_write "$R/proc/sys/net/ipv4/tcp_moderate_rcvbuf" 1
  nb_write "$R/proc/sys/net/ipv4/tcp_window_scaling" 1
  nb_write "$R/proc/sys/net/ipv4/tcp_sack" 1
  nb_write "$R/proc/sys/net/ipv4/tcp_mtu_probing" 1
  nb_write "$R/proc/sys/net/ipv4/tcp_fastopen" 3
  nb_write "$R/proc/sys/net/ipv4/tcp_slow_start_after_idle" 0
  # Latency Fix - matikan Nagle-delay jalur low-latency kernel (kalau ada) +
  # percepat deteksi koneksi mati supaya tidak nahan reconnect lama-lama
  nb_write "$R/proc/sys/net/ipv4/tcp_low_latency" 1
  nb_write "$R/proc/sys/net/ipv4/tcp_fin_timeout" 15
  nb_write "$R/proc/sys/net/ipv4/tcp_keepalive_time" 60
  nb_write "$R/proc/sys/net/ipv4/tcp_keepalive_intvl" 10
  nb_write "$R/proc/sys/net/ipv4/tcp_keepalive_probes" 3
  nb_write "$R/proc/sys/net/ipv4/tcp_retries2" 8
  nb_setconf NETBOOST 1
  log_msg "NETBOOST: AKTIF (congestion=${nb_cc:-tidak-tersedia})"
  echo "Network Booster: AKTIF (NSS/optimasi TCP-IP + fix latency). congestion_control=${nb_cc:-default-kernel (bbr3/bbr/cubic tidak tersedia)}"
  [ -n "$nb_cc" ] || echo "PERINGATAN: congestion control (bbr3/bbr/cubic) tidak ada yang bisa ditulis ke kernel ini - memakai default kernel"
  nb_status
}

nb_off() {
  load_conf
  nb_restore
  # sisa versi lama (<1.0.16) yang masih nyangkut di backup: kembalikan, TAPI jangan
  # sentuh kalau fitur WiFi Low Latency yang baru sedang aktif (WIFILL=1)
  if [ -s "$NB_SETBK" ] && [ "$WIFILL" != 1 ]; then
    while IFS='|' read -r nr_k nr_v; do
      [ -n "$nr_k" ] || continue
      case "$nr_v" in ''|null) settings delete global "$nr_k" >/dev/null 2>&1 ;; *) settings put global "$nr_k" "$nr_v" 2>/dev/null ;; esac
    done < "$NB_SETBK"
    : > "$NB_SETBK"
  fi
  [ -f "$RUNDIR/nb_wifi_ll" ] && { [ "$WIFILL" = 1 ] || cmd wifi force-low-latency-mode disabled >/dev/null 2>&1; rm -f "$RUNDIR/nb_wifi_ll"; }
  # MATI -> congestion control DIPAKSA cubic, NYATA ditulis langsung ke
  # /proc/sys/net/ipv4/tcp_congestion_control dan diverifikasi read-back -
  # bukan cuma restore nilai sebelum aktif (nb_restore di atas sudah
  # mengembalikan sysctl lain, tapi utk congestion control nilai akhirnya
  # SELALU cubic, ditimpa eksplisit di sini).
  [ -w "$NB_CC_PATH" ] && { echo cubic > "$NB_CC_PATH"; } 2>/dev/null
  nb_cc_off="$(dv_cat "$NB_CC_PATH" 2>/dev/null)"
  nb_setconf NETBOOST 0
  echo "Network Booster: MATI (semua sysctl & setting dikembalikan ke nilai asal, congestion_control=$nb_cc_off)"
  nb_status
}

nb_status() {
  load_conf
  echo "NETBOOST=$NETBOOST  congestion_control=$(dv_cat "$NB_CC_PATH" 2>/dev/null)"
}

