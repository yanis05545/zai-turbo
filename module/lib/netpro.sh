#!/system/bin/sh
# =====================================================================
#  Zyrox - lib/netpro.sh : "Network Pro" (fitur jaringan setara PingPimp)
#
#  Hanya fitur yang BELUM ada di Zyrox (Network Booster / WiFi Low Latency /
#  WiFi Tweak tetap dipakai apa adanya - tidak diduplikasi):
#    qdisc      : CAKE / fq_codel / fq (anti bufferbloat)         NP_QDISC
#    mtu        : MTU adaptif (probe ping DF lalu set MTU)        NP_MTU
#    dns        : Private DNS terpisah seluler / WiFi / per SSID  NP_DNS
#    adv        : IRQ affinity jaringan -> core tercepat + boost ksoftirqd   NP_ADV
#    nicoff     : offloading NIC off (butuh ethtool di ROM)       NP_NICOFF
#    conntrack  : tabel ConnTrack diperbesar                      NP_CONNTRACK
#    ipv6off    : matikan IPv6                                    NP_IPV6OFF
#    datasaver  : Data Saver sistem                               NP_DATASAVER
#    netstate   : matikan notifikasi/scan status jaringan         NP_NETSTATE
#    lteca      : force_lte_ca=true                               NP_LTECA
#    isolate    : blokir internet per aplikasi (iptables)         NP_ISOLATE
#    boost      : prioritas trafik DSCP 46 per aplikasi/game      NP_BOOST
#    auto       : Smart Auto - ganti preset sesuai aplikasi aktif NP_AUTO
#
#  Tiap fitur: toggle sendiri, nilai asli di-backup ($NP_BK) lalu dikembalikan
#  saat OFF, tahan reboot (np_boot dipanggil service.sh). Hasil selalu dibaca
#  ulang dari sistem; yang tidak didukung ROM/kernel dilaporkan apa adanya.
# =====================================================================

NP_BK="$DATADIR/netpro_backup"           # kunci|nilai_asli (sekali simpan)
NP_ISO_LIST="$DATADIR/np_isolate.list"
NP_BST_LIST="$DATADIR/np_boost.list"
NP_DNS_SSID="$DATADIR/np_dns_ssid.list"  # SSID|hostname
NP_CHAIN_ISO=ZYROX_ISO
NP_CHAIN_BST=ZYROX_BOOST
NP_CHAIN_BLK=ZYROX_BLKALL
NP_BLK_ALLOW="$DATADIR/np_blockall.allow"   # paket yang dikecualikan dari Block All
NP_SELF_PKG=com.azenithtech.azenithai       # Companion Zyrox selalu dikecualikan

np_setconf() { # np_setconf KEY VAL
  if grep -q "^$1=" "$CONF" 2>/dev/null; then sed -i "s|^$1=.*|$1=$2|" "$CONF"
  else echo "$1=$2" >> "$CONF"; fi
}

# ---------------- backup / tulis sysctl ----------------
np_bk_has() { grep -q "^$1|" "$NP_BK" 2>/dev/null; }
np_bk_get() { awk -v k="$1" 'index($0, k "|") == 1 { print substr($0, length(k) + 2); exit }' "$NP_BK" 2>/dev/null; }
np_bk_put() { np_bk_has "$1" || echo "$1|$2" >> "$NP_BK"; }
np_bk_del() { [ -f "$NP_BK" ] && { grep -v "^$1|" "$NP_BK" > "$NP_BK.t" 2>/dev/null; mv -f "$NP_BK.t" "$NP_BK"; }; }

np_write() { # np_write PATH VAL -> backup sekali, tulis, verifikasi baca-ulang
  nw_p=$1; nw_v=$2
  [ -w "$nw_p" ] || return 1
  np_bk_put "sys:$nw_p" "$(dv_cat "$nw_p")"
  { echo "$nw_v" > "$nw_p"; } 2>/dev/null
  [ "$(dv_cat "$nw_p")" = "$nw_v" ]
}

np_restore_prefix() { # np_restore_prefix sys: -> kembalikan semua sysctl terbackup berprefiks
  [ -s "$NP_BK" ] || return 0
  grep "^$1" "$NP_BK" | while IFS='|' read -r nr_k nr_v; do
    nr_p=${nr_k#*:}
    [ -n "$nr_v" ] && [ -w "$nr_p" ] && { echo "$nr_v" > "$nr_p"; } 2>/dev/null
  done
}

np_have() { command -v "$1" >/dev/null 2>&1; }

# ---------------- interface & jaringan aktif ----------------
np_ifaces() { # semua interface data (bukan lo/dummy/ifb/tun)
  for ni in "$R"/sys/class/net/*; do
    ni=${ni##*/}
    case "$ni" in wlan*|rmnet*|ccmni*|eth*|swlan*|v4-rmnet*|r_rmnet*) echo "$ni" ;; esac
  done
}
np_active_if() { # interface rute default sekarang
  ip route get 1.1.1.1 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -n 1
}
np_active_type() { # wifi|mobile|none
  na_i=$(np_active_if)
  case "$na_i" in '') echo none ;; wlan*|swlan*) echo wifi ;; *) echo mobile ;; esac
}
np_gw() { ip route get 1.1.1.1 2>/dev/null | sed -n 's/.* via \([^ ]*\).*/\1/p' | head -n 1; }
np_ssid() { # SSID WiFi aktif (kosong kalau tidak terhubung / tidak terbaca)
  cmd wifi status 2>/dev/null | sed -n 's/.*SSID: *"\([^"]*\)".*/\1/p' | head -n 1
}

# =====================================================================
#  qdisc  (CAKE / fq_codel / fq)
# =====================================================================
np_tc() { if np_have tc; then tc "$@"; else /system/bin/tc "$@"; fi; }

np_qdisc_apply_algo() { # np_qdisc_apply_algo ALGO -> cetak ok/total
  nq_a=$1; nq_ok=0; nq_t=0
  np_write "$R/proc/sys/net/core/default_qdisc" "$nq_a" >/dev/null 2>&1
  for nq_i in $(np_ifaces); do
    [ "$(dv_cat "$R/sys/class/net/$nq_i/operstate")" = down ] && continue
    nq_t=$((nq_t + 1))
    np_bk_put "qd:$nq_i" "$(np_tc qdisc show dev "$nq_i" 2>/dev/null | sed -n '1s/^qdisc \([^ ]*\).*/\1/p')"
    np_tc qdisc replace dev "$nq_i" root "$nq_a" >/dev/null 2>&1
    np_tc qdisc show dev "$nq_i" 2>/dev/null | grep -q "qdisc $nq_a" && nq_ok=$((nq_ok + 1))
  done
  echo "$nq_ok/$nq_t"
}

np_qdisc_on() {
  load_conf
  nq_algo=${1:-${NP_QDISC_ALGO:-cake}}
  case "$nq_algo" in cake|fq_codel|fq) ;; *) echo "algoritma qdisc harus cake|fq_codel|fq"; return 1 ;; esac
  np_have tc || [ -x /system/bin/tc ] || { np_setconf NP_QDISC 0; echo "Qdisc: GAGAL - binary 'tc' tidak ada di ROM ini"; return 1; }
  nq_r=$(np_qdisc_apply_algo "$nq_algo")
  case "$nq_r" in 0/*) 
    # CAKE tidak ada di kernel -> fallback fq_codel
    if [ "$nq_algo" = cake ]; then nq_algo=fq_codel; nq_r=$(np_qdisc_apply_algo fq_codel); fi ;;
  esac
  case "$nq_r" in 0/*) np_setconf NP_QDISC 0; echo "Qdisc: GAGAL - kernel menolak cake/fq_codel ($nq_r interface)"; return 1 ;; esac
  np_setconf NP_QDISC 1; np_setconf NP_QDISC_ALGO "$nq_algo"
  log_msg "NETPRO: qdisc=$nq_algo ($nq_r)"
  echo "Qdisc: AKTIF $nq_algo di $nq_r interface"
}

np_qdisc_off() {
  for nq_i in $(np_ifaces); do np_tc qdisc del dev "$nq_i" root >/dev/null 2>&1; done   # kembali ke qdisc bawaan kernel
  nq_def=$(np_bk_get "sys:$R/proc/sys/net/core/default_qdisc")
  [ -n "$nq_def" ] && [ -w "$R/proc/sys/net/core/default_qdisc" ] && { echo "$nq_def" > "$R/proc/sys/net/core/default_qdisc"; } 2>/dev/null
  np_bk_del "sys:$R/proc/sys/net/core/default_qdisc"
  grep '^qd:' "$NP_BK" 2>/dev/null | cut -d'|' -f1 | while read -r nq_k; do np_bk_del "$nq_k"; done
  np_setconf NP_QDISC 0
  echo "Qdisc: MATI (kembali ke bawaan kernel)"
}

# =====================================================================
#  MTU adaptif
# =====================================================================
np_ping_df() { ping -c 1 -W 1 -M do -s "$1" "${NET_PING_HOST:-8.8.8.8}" >/dev/null 2>&1; }

np_mtu_probe() { # cetak MTU terbaik (payload+28) atau kosong
  np_ping_df 56 || return 1                        # tanpa -M do / tanpa jaringan -> tidak bisa probe
  np_ping_df 1272 || { np_ping_df 1172 && { echo 1200; return 0; }; return 1; }
  nm_lo=1272; nm_hi=1472
  np_ping_df "$nm_hi" && { echo $((nm_hi + 28)); return 0; }
  while [ $((nm_hi - nm_lo)) -gt 1 ]; do
    nm_mid=$(( (nm_lo + nm_hi) / 2 ))
    if np_ping_df "$nm_mid"; then nm_lo=$nm_mid; else nm_hi=$nm_mid; fi
  done
  echo $((nm_lo + 28))
}

np_mtu_on() {
  load_conf
  nm_if=$(np_active_if)
  [ -n "$nm_if" ] || { np_setconf NP_MTU 0; echo "MTU: GAGAL - tidak ada jaringan aktif"; return 1; }
  nm_best=$(np_mtu_probe)
  [ -n "$nm_best" ] || { np_setconf NP_MTU 0; echo "MTU: GAGAL - probe ping DF tidak berhasil (ping tanpa -M do / jaringan memblokir ICMP)"; return 1; }
  np_bk_put "mtu:$nm_if" "$(dv_cat "$R/sys/class/net/$nm_if/mtu")"
  ip link set dev "$nm_if" mtu "$nm_best" >/dev/null 2>&1
  nm_now=$(dv_cat "$R/sys/class/net/$nm_if/mtu")
  if [ "$nm_now" = "$nm_best" ]; then
    np_setconf NP_MTU 1; log_msg "NETPRO: mtu $nm_if=$nm_best"
    echo "MTU: AKTIF $nm_if=$nm_best (probe ICMP DF)"
  else
    np_setconf NP_MTU 0; echo "MTU: GAGAL - kernel menolak MTU $nm_best di $nm_if (sekarang $nm_now)"; return 1
  fi
}

np_mtu_off() {
  grep '^mtu:' "$NP_BK" 2>/dev/null | while IFS='|' read -r nm_k nm_v; do
    nm_i=${nm_k#mtu:}
    [ -n "$nm_v" ] && ip link set dev "$nm_i" mtu "$nm_v" >/dev/null 2>&1
  done
  grep '^mtu:' "$NP_BK" 2>/dev/null | cut -d'|' -f1 | while read -r nm_k; do np_bk_del "$nm_k"; done
  np_setconf NP_MTU 0
  echo "MTU: MATI (dikembalikan ke nilai asal)"
}

# =====================================================================
#  Private DNS (seluler / WiFi / per SSID)
# =====================================================================
np_dns_name() { # alias -> hostname DoT
  case "$1" in
    google) echo dns.google ;; cloudflare) echo one.one.one.one ;; adguard) echo dns.adguard-dns.com ;;
    quad9) echo dns.quad9.net ;; cleanbrowsing) echo security-filter-dns.cleanbrowsing.org ;;
    *) echo "$1" ;;
  esac
}

np_dns_set() { # np_dns_set <off|auto|hostname|alias>
  nd_v=$(np_dns_name "$1")
  np_bk_put "dns:mode" "$(settings get global private_dns_mode 2>/dev/null)"
  np_bk_put "dns:spec" "$(settings get global private_dns_specifier 2>/dev/null)"
  case "$nd_v" in
    off)  settings put global private_dns_mode off ;;
    auto) settings put global private_dns_mode opportunistic ;;
    *)    settings put global private_dns_specifier "$nd_v"; settings put global private_dns_mode hostname ;;
  esac
}

np_dns_pick() { # cetak hostname untuk jaringan aktif sekarang
  np_dt=$(np_active_type)
  case "$np_dt" in
    wifi)
      np_ds=$(np_ssid)
      if [ -n "$np_ds" ] && [ -s "$NP_DNS_SSID" ]; then
        np_dh=$(awk -F'|' -v s="$np_ds" '$1==s {print $2; exit}' "$NP_DNS_SSID")
        [ -n "$np_dh" ] && { echo "$np_dh"; return; }
      fi
      echo "${NP_DNS_WIFI:-auto}" ;;
    mobile) echo "${NP_DNS_MOBILE:-auto}" ;;
    *) echo "" ;;
  esac
}

np_dns_apply() {
  load_conf
  [ "$NP_DNS" = 1 ] || return 0
  nd_h=$(np_dns_pick)
  [ -n "$nd_h" ] || { echo "DNS: tidak ada jaringan aktif"; return 0; }
  np_dns_set "$nd_h"
  nd_m=$(settings get global private_dns_mode 2>/dev/null)
  echo "DNS: $(np_active_type) -> $(np_dns_name "$nd_h") (mode=$nd_m)"
}

np_dns_on() { np_setconf NP_DNS 1; load_conf; np_dns_apply; np_watch_ensure; }
np_dns_off() {
  np_setconf NP_DNS 0
  nd_m=$(np_bk_get "dns:mode"); nd_s=$(np_bk_get "dns:spec")
  if [ -n "$nd_m" ] && [ "$nd_m" != null ]; then settings put global private_dns_mode "$nd_m" 2>/dev/null; else settings delete global private_dns_mode >/dev/null 2>&1; fi
  if [ -n "$nd_s" ] && [ "$nd_s" != null ]; then settings put global private_dns_specifier "$nd_s" 2>/dev/null; else settings delete global private_dns_specifier >/dev/null 2>&1; fi
  np_bk_del "dns:mode"; np_bk_del "dns:spec"
  echo "DNS: MATI (Private DNS dikembalikan ke nilai asal)"
}

np_dns_cmd() { # np_dns_cmd <sub> args...
  case "$1" in
    on) np_dns_on ;; off) np_dns_off ;; apply) np_dns_apply ;;
    set) case "$2" in
           mobile) np_setconf NP_DNS_MOBILE "$3"; echo "DNS seluler = $3" ;;
           wifi)   np_setconf NP_DNS_WIFI "$3"; echo "DNS WiFi = $3" ;;
           *) echo "pakai: net dns set mobile|wifi <off|auto|google|cloudflare|adguard|quad9|hostname>"; return 1 ;;
         esac
         load_conf; [ "$NP_DNS" = 1 ] && np_dns_apply ;;
    ssid) case "$2" in
            add) nd_h=$3; shift 3; nd_n="$*"
                 [ -n "$nd_h" ] && [ -n "$nd_n" ] || { echo "pakai: net dns ssid add <host> <nama SSID>"; return 1; }
                 [ -f "$NP_DNS_SSID" ] && grep -v "^$nd_n|" "$NP_DNS_SSID" > "$NP_DNS_SSID.t" && mv -f "$NP_DNS_SSID.t" "$NP_DNS_SSID"
                 echo "$nd_n|$nd_h" >> "$NP_DNS_SSID"; echo "DNS per-SSID: $nd_n -> $nd_h" ;;
            del) shift 2; nd_n="$*"
                 [ -f "$NP_DNS_SSID" ] && grep -v "^$nd_n|" "$NP_DNS_SSID" > "$NP_DNS_SSID.t" && mv -f "$NP_DNS_SSID.t" "$NP_DNS_SSID"
                 echo "DNS per-SSID dihapus: $nd_n" ;;
            list) [ -s "$NP_DNS_SSID" ] && cat "$NP_DNS_SSID" ;;
            *) echo "pakai: net dns ssid add|del|list" ;;
          esac ;;
    status|"") load_conf
          echo "NP_DNS=$NP_DNS mobile=$NP_DNS_MOBILE wifi=$NP_DNS_WIFI aktif=$(np_active_type) mode=$(settings get global private_dns_mode 2>/dev/null) host=$(settings get global private_dns_specifier 2>/dev/null)" ;;
    *) echo "net dns on|off|apply|set mobile|wifi <v>|ssid add|del|list|status" ;;
  esac
}

# =====================================================================
#  Advanced: IRQ affinity + ksoftirqd   |  NIC offload
# =====================================================================
np_fast_mask() { # bitmask hex core dengan cpuinfo_max_freq tertinggi
  nf_max=0; nf_list=""
  for nf_c in "$R"/sys/devices/system/cpu/cpu[0-9]*; do
    nf_n=${nf_c##*cpu}; nf_f=$(dv_cat "$nf_c/cpufreq/cpuinfo_max_freq"); nf_f=${nf_f:-0}
    case "$nf_f" in *[!0-9]*) nf_f=0 ;; esac
    nf_list="$nf_list $nf_n:$nf_f"
    [ "$nf_f" -gt "$nf_max" ] && nf_max=$nf_f
  done
  nf_m=0
  for nf_e in $nf_list; do
    [ "${nf_e#*:}" = "$nf_max" ] && nf_m=$((nf_m | (1 << ${nf_e%%:*})))
  done
  printf '%x' "$nf_m"
}

np_irq_nums() { grep -iE 'wlan|wifi|cnss|ipa|rmnet|ccmni|dhd|bcmsdh|wcnss|mtk_wmt' "$R/proc/interrupts" 2>/dev/null | sed -n 's/^ *\([0-9][0-9]*\):.*/\1/p'; }

np_adv_on() {
  nadv_mask=$(np_fast_mask)
  [ -n "$nadv_mask" ] && [ "$nadv_mask" != 0 ] || { np_setconf NP_ADV 0; echo "Advanced: GAGAL - core tercepat tidak terbaca"; return 1; }
  nadv_ok=0; nadv_t=0
  for nadv_i in $(np_irq_nums); do
    nadv_p="$R/proc/irq/$nadv_i/smp_affinity"
    [ -w "$nadv_p" ] || continue
    nadv_t=$((nadv_t + 1))
    np_bk_put "irq:$nadv_i" "$(dv_cat "$nadv_p")"
    { echo "$nadv_mask" > "$nadv_p"; } 2>/dev/null
    nadv_rb=$(dv_cat "$nadv_p" | sed 's/^0*//; s/,//g'); nadv_want=$(echo "$nadv_mask" | sed 's/^0*//')
    [ "$nadv_rb" = "$nadv_want" ] && nadv_ok=$((nadv_ok + 1))
  done
  nadv_k=0
  for nadv_pid in $(ps -A -o PID,NAME 2>/dev/null | awk '$2 ~ /^ksoftirqd\// {print $1}'); do
    np_bk_put "nice:$nadv_pid" "$(awk '{print $19}' "$R/proc/$nadv_pid/stat" 2>/dev/null)"
    renice -n -10 -p "$nadv_pid" >/dev/null 2>&1 && nadv_k=$((nadv_k + 1))
  done
  if [ "$nadv_ok" -gt 0 ] || [ "$nadv_k" -gt 0 ]; then
    np_setconf NP_ADV 1; log_msg "NETPRO: adv irq=$nadv_ok/$nadv_t ksoftirqd=$nadv_k mask=$nadv_mask"
    echo "Advanced: AKTIF IRQ affinity $nadv_ok/$nadv_t (mask $nadv_mask), ksoftirqd di-boost $nadv_k"
  else
    np_setconf NP_ADV 0; echo "Advanced: GAGAL - kernel menolak smp_affinity & renice ksoftirqd ($nadv_t IRQ jaringan ditemukan)"; return 1
  fi
}

np_adv_off() {
  grep '^irq:' "$NP_BK" 2>/dev/null | while IFS='|' read -r na_k na_v; do
    na_i=${na_k#irq:}
    [ -n "$na_v" ] && [ -w "$R/proc/irq/$na_i/smp_affinity" ] && { echo "$na_v" > "$R/proc/irq/$na_i/smp_affinity"; } 2>/dev/null
  done
  for na_pid in $(ps -A -o PID,NAME 2>/dev/null | awk '$2 ~ /^ksoftirqd\// {print $1}'); do renice -n 0 -p "$na_pid" >/dev/null 2>&1; done
  grep -E '^(irq|nice):' "$NP_BK" 2>/dev/null | cut -d'|' -f1 | while read -r na_k; do np_bk_del "$na_k"; done
  np_setconf NP_ADV 0
  echo "Advanced: MATI (IRQ affinity & prioritas ksoftirqd dikembalikan)"
}

np_nic_on() {
  np_have ethtool || { np_setconf NP_NICOFF 0; echo "NIC offload: TIDAK DIDUKUNG - binary 'ethtool' tidak ada di ROM ini"; return 1; }
  nn_ok=0
  for nn_i in $(np_ifaces); do
    ethtool -K "$nn_i" gro off gso off tso off lro off >/dev/null 2>&1 && nn_ok=$((nn_ok + 1))
  done
  [ "$nn_ok" -gt 0 ] || { np_setconf NP_NICOFF 0; echo "NIC offload: GAGAL - driver menolak ethtool -K"; return 1; }
  np_setconf NP_NICOFF 1; echo "NIC offload: AKTIF off (gro/gso/tso/lro) di $nn_ok interface"
}
np_nic_off() {
  np_have ethtool && for nn_i in $(np_ifaces); do ethtool -K "$nn_i" gro on gso on tso on >/dev/null 2>&1; done
  np_setconf NP_NICOFF 0; echo "NIC offload: MATI (dikembalikan ke aktif)"
}

# =====================================================================
#  Optimize Internet (toggle terpisah)
# =====================================================================
np_conntrack_on() {
  nc_ok=0
  for nc_e in "net/netfilter/nf_conntrack_max 262144" "net/netfilter/nf_conntrack_tcp_timeout_established 7200" "net/netfilter/nf_conntrack_tcp_timeout_time_wait 30" "net/nf_conntrack_max 262144"; do
    set -- $nc_e
    np_write "$R/proc/sys/$1" "$2" && nc_ok=$((nc_ok + 1))
  done
  [ "$nc_ok" -gt 0 ] || { np_setconf NP_CONNTRACK 0; echo "ConnTrack: TIDAK DIDUKUNG - kernel tanpa nf_conntrack yang bisa ditulis"; return 1; }
  np_setconf NP_CONNTRACK 1; echo "ConnTrack: AKTIF ($nc_ok parameter diperbesar/dipercepat)"
}
np_conntrack_off() {
  for nc_p in net/netfilter/nf_conntrack_max net/netfilter/nf_conntrack_tcp_timeout_established net/netfilter/nf_conntrack_tcp_timeout_time_wait net/nf_conntrack_max; do
    nc_v=$(np_bk_get "sys:$R/proc/sys/$nc_p"); [ -n "$nc_v" ] && { echo "$nc_v" > "$R/proc/sys/$nc_p"; } 2>/dev/null
    np_bk_del "sys:$R/proc/sys/$nc_p"
  done
  np_setconf NP_CONNTRACK 0; echo "ConnTrack: MATI (nilai asal dipulihkan)"
}

np_ipv6_apply() { # dipanggil lagi saat interface baru muncul
  ni_ok=0
  for ni_i in all default $(np_ifaces); do
    np_write "$R/proc/sys/net/ipv6/conf/$ni_i/disable_ipv6" 1 && ni_ok=$((ni_ok + 1))
  done
  echo "$ni_ok"
}
np_ipv6off_on() {
  ni_n=$(np_ipv6_apply)
  [ "$ni_n" -gt 0 ] || { np_setconf NP_IPV6OFF 0; echo "IPv6: GAGAL - sysctl disable_ipv6 tidak bisa ditulis"; return 1; }
  np_setconf NP_IPV6OFF 1; np_watch_ensure; echo "IPv6: DIMATIKAN di $ni_n interface"
}
np_ipv6off_off() {
  for ni_i in all default $(np_ifaces); do
    ni_p="$R/proc/sys/net/ipv6/conf/$ni_i/disable_ipv6"
    ni_v=$(np_bk_get "sys:$ni_p"); [ -n "$ni_v" ] && { echo "$ni_v" > "$ni_p"; } 2>/dev/null
    np_bk_del "sys:$ni_p"
  done
  np_setconf NP_IPV6OFF 0; echo "IPv6: MATI-fitur (IPv6 dikembalikan ke nilai asal)"
}

np_datasaver_on() {
  np_bk_put "ds:restrict" "$(cmd netpolicy get restrict-background 2>/dev/null | grep -io 'true\|false' | head -n 1)"
  cmd netpolicy set restrict-background true >/dev/null 2>&1
  if cmd netpolicy get restrict-background 2>/dev/null | grep -qi true; then
    np_setconf NP_DATASAVER 1; echo "Data Saver: AKTIF"
  else np_setconf NP_DATASAVER 0; echo "Data Saver: GAGAL - ROM menolak cmd netpolicy"; return 1; fi
}
np_datasaver_off() {
  nds_v=$(np_bk_get "ds:restrict"); [ "$nds_v" = true ] || nds_v=false
  cmd netpolicy set restrict-background "$nds_v" >/dev/null 2>&1; np_bk_del "ds:restrict"
  np_setconf NP_DATASAVER 0; echo "Data Saver: MATI"
}

NP_NETSTATE_KEYS="wifi_networks_available_notification_on network_recommendations_enabled wifi_scan_always_enabled ble_scan_always_enabled wifi_wakeup_enabled"
np_netstate_on() {
  for nn_k in $NP_NETSTATE_KEYS; do
    np_bk_put "set:$nn_k" "$(settings get global "$nn_k" 2>/dev/null)"
    settings put global "$nn_k" 0 2>/dev/null
  done
  np_setconf NP_NETSTATE 1; echo "Status jaringan & scan WiFi: DIMATIKAN ($(echo $NP_NETSTATE_KEYS | wc -w) setting)"
}
np_netstate_off() {
  for nn_k in $NP_NETSTATE_KEYS; do
    nn_v=$(np_bk_get "set:$nn_k")
    case "$nn_v" in ''|null) settings delete global "$nn_k" >/dev/null 2>&1 ;; *) settings put global "$nn_k" "$nn_v" 2>/dev/null ;; esac
    np_bk_del "set:$nn_k"
  done
  np_setconf NP_NETSTATE 0; echo "Status jaringan & scan WiFi: dikembalikan"
}

np_lteca_on() {
  np_bk_put "prop:force_lte_ca" "$(getprop force_lte_ca 2>/dev/null)"
  resetprop force_lte_ca true 2>/dev/null || setprop force_lte_ca true 2>/dev/null
  [ "$(getprop force_lte_ca 2>/dev/null)" = true ] && { np_setconf NP_LTECA 1; echo "LTE CA: force_lte_ca=true (efektif penuh setelah radio/ponsel restart)"; return 0; }
  np_setconf NP_LTECA 0; echo "LTE CA: GAGAL - resetprop tidak tersedia"; return 1
}
np_lteca_off() {
  nl_v=$(np_bk_get "prop:force_lte_ca")
  if [ -n "$nl_v" ]; then resetprop force_lte_ca "$nl_v" 2>/dev/null; else resetprop --delete force_lte_ca 2>/dev/null; fi
  np_bk_del "prop:force_lte_ca"; np_setconf NP_LTECA 0; echo "LTE CA: MATI"
}

# =====================================================================
#  iptables: Isolate Apps (blokir) & Boost Apps (DSCP 46)
# =====================================================================
NPW=""; iptables -w 5 -S >/dev/null 2>&1 && NPW="-w 5"
ipt()  { iptables $NPW "$@"; }
ipt6() { ip6tables $NPW "$@"; }

np_uid() { # np_uid <paket> -> uid
  nu_u=$(cmd package list packages -U "$1" 2>/dev/null | sed -n "s/^package:$1 uid:\([0-9]*\).*/\1/p" | head -n 1)
  [ -n "$nu_u" ] || nu_u=$(dumpsys package "$1" 2>/dev/null | sed -n 's/.*userId=\([0-9]*\).*/\1/p' | head -n 1)
  echo "$nu_u"
}

np_chain_reset() { # np_chain_reset <tabel> <chain> <hook>
  for nc_c in ipt ipt6; do
    $nc_c -t "$1" -D "$3" -j "$2" 2>/dev/null
    $nc_c -t "$1" -F "$2" 2>/dev/null; $nc_c -t "$1" -X "$2" 2>/dev/null
  done
}
np_chain_new() { # np_chain_new <tabel> <chain> <hook>
  for nc_c in ipt ipt6; do
    $nc_c -t "$1" -N "$2" 2>/dev/null
    $nc_c -t "$1" -C "$3" -j "$2" 2>/dev/null || $nc_c -t "$1" -I "$3" 1 -j "$2" 2>/dev/null
  done
}

np_list_pkgs() { # np_list_pkgs <berkas>
  [ -f "$1" ] && sed 's/[[:space:]]//g' "$1" | grep -E '^[A-Za-z0-9_.]+$' | sort -u
}

np_list_edit() { # np_list_edit <berkas> add|del <paket>
  case "$3" in ''|*[!A-Za-z0-9_.]*) echo "nama paket tidak valid"; return 1 ;; esac
  touch "$1"
  if [ "$2" = add ]; then grep -qxF "$3" "$1" || echo "$3" >> "$1"
  else grep -vxF "$3" "$1" > "$1.t"; mv -f "$1.t" "$1"; fi
}

np_isolate_apply() {
  np_chain_reset filter "$NP_CHAIN_ISO" OUTPUT
  np_chain_new filter "$NP_CHAIN_ISO" OUTPUT
  ni_ok=0; ni_miss=0
  for ni_p in $(np_list_pkgs "$NP_ISO_LIST"); do
    ni_u=$(np_uid "$ni_p")
    [ -n "$ni_u" ] || { ni_miss=$((ni_miss + 1)); continue; }
    ipt -A "$NP_CHAIN_ISO" -m owner --uid-owner "$ni_u" -j REJECT 2>/dev/null && ni_ok=$((ni_ok + 1))
    ipt6 -A "$NP_CHAIN_ISO" -m owner --uid-owner "$ni_u" -j REJECT 2>/dev/null
  done
  echo "$ni_ok $ni_miss"
}
np_isolate_on() {
  set -- $(np_isolate_apply)
  np_setconf NP_ISOLATE 1; np_watch_ensure
  [ -s "$NP_ISO_LIST" ] || { echo "Isolate Apps: AKTIF tapi daftar kosong (tambah: net isolate add <paket>)"; return 0; }
  [ "$1" -gt 0 ] || { echo "Isolate Apps: PERINGATAN - 0 aturan terpasang (iptables owner/REJECT tidak didukung kernel, atau paket tidak ditemukan)"; return 0; }
  echo "Isolate Apps: AKTIF, $1 aplikasi diblokir internetnya (tidak ditemukan: $2)"
}
np_isolate_off() {
  np_chain_reset filter "$NP_CHAIN_ISO" OUTPUT
  np_setconf NP_ISOLATE 0; echo "Isolate Apps: MATI (semua blokir dilepas)"
}

np_boost_pkgs() { { np_list_pkgs "$NP_BST_LIST"; [ "${NP_BOOST_GAMES:-1}" = 1 ] && { games_build >/dev/null 2>&1; cat "$RUNDIR/games.list" 2>/dev/null; }; } | sort -u; }
np_boost_apply() {
  np_chain_reset mangle "$NP_CHAIN_BST" OUTPUT
  np_chain_new mangle "$NP_CHAIN_BST" OUTPUT
  nb2_ok=0
  for nb2_p in $(np_boost_pkgs); do
    nb2_u=$(np_uid "$nb2_p"); [ -n "$nb2_u" ] || continue
    ipt -t mangle -A "$NP_CHAIN_BST" -m owner --uid-owner "$nb2_u" -j DSCP --set-dscp "${NP_DSCP:-46}" 2>/dev/null && nb2_ok=$((nb2_ok + 1))
    ipt6 -t mangle -A "$NP_CHAIN_BST" -m owner --uid-owner "$nb2_u" -j DSCP --set-dscp "${NP_DSCP:-46}" 2>/dev/null
  done
  echo "$nb2_ok"
}
np_boost_on() {
  load_conf
  nb2_n=$(np_boost_apply)
  np_setconf NP_BOOST 1; np_watch_ensure
  if [ "$nb2_n" -gt 0 ]; then echo "Boost Apps: AKTIF, $nb2_n aplikasi diberi DSCP ${NP_DSCP:-46}"
  else echo "Boost Apps: PERINGATAN - 0 aturan terpasang (kernel tanpa xt_DSCP/owner, atau tidak ada app terpilih terpasang)"; fi
}
np_boost_off() {
  np_chain_reset mangle "$NP_CHAIN_BST" OUTPUT
  np_setconf NP_BOOST 0; echo "Boost Apps: MATI (aturan DSCP dilepas)"
}


# =====================================================================
#  Tab Network (WebUI): Net Boost (TFO / Wi-Fi PS off / RPS) & Net Block (Block All + DSCP)
#  Backup memakai prefiks sendiri (tfo:/wps:/rps:) supaya np_preset_restore
#  (profil Off/Default) TIDAK ikut membatalkan toggle ini.
# =====================================================================
np_tfo_on() {
  nt_p="$R/proc/sys/net/ipv4/tcp_fastopen"
  [ -w "$nt_p" ] || { np_setconf NP_TFO 0; echo "TCP Fast Open: GAGAL - node tcp_fastopen tidak bisa ditulis"; return 1; }
  np_bk_put "tfo:$nt_p" "$(dv_cat "$nt_p")"
  { echo 3 > "$nt_p"; } 2>/dev/null
  if [ "$(dv_cat "$nt_p")" = 3 ]; then np_setconf NP_TFO 1; echo "TCP Fast Open: AKTIF (tcp_fastopen=3)"
  else np_setconf NP_TFO 0; echo "TCP Fast Open: GAGAL - kernel menolak nilai 3"; return 1; fi
}
np_tfo_off() {
  nt_p="$R/proc/sys/net/ipv4/tcp_fastopen"
  nt_v=$(np_bk_get "tfo:$nt_p"); [ -n "$nt_v" ] && { echo "$nt_v" > "$nt_p"; } 2>/dev/null
  np_bk_del "tfo:$nt_p"; np_setconf NP_TFO 0; echo "TCP Fast Open: MATI (nilai asli ${nt_v:-?} dikembalikan)"
}

np_wifips_ifaces() { for nw_i in "$R"/sys/class/net/wlan* "$R"/sys/class/net/swlan*; do [ -e "$nw_i" ] && echo "${nw_i##*/}"; done; }
np_wifips_on() {
  command -v iw >/dev/null 2>&1 || { np_setconf NP_WIFIPS 0; echo "Wi-Fi Power-Save: GAGAL - biner iw tidak ada di ROM ini (TIDAK DIDUKUNG)"; return 1; }
  nw_ok=0; nw_t=0
  for nw_i in $(np_wifips_ifaces); do
    nw_s=$(wl_iw_state "$nw_i"); [ -n "$nw_s" ] || continue
    nw_t=$((nw_t + 1))
    np_bk_put "wps:$nw_i" "$nw_s"
    iw dev "$nw_i" set power_save off >/dev/null 2>&1
    [ "$(wl_iw_state "$nw_i")" = off ] && nw_ok=$((nw_ok + 1))
  done
  if [ "$nw_ok" -gt 0 ]; then np_setconf NP_WIFIPS 1; echo "Wi-Fi Power-Save: AKTIF-off di $nw_ok/$nw_t interface"
  else np_setconf NP_WIFIPS 0; echo "Wi-Fi Power-Save: GAGAL - driver menolak power_save off ($nw_t interface terbaca)"; return 1; fi
}
np_wifips_off() {
  grep '^wps:' "$NP_BK" 2>/dev/null | while IFS='|' read -r nw_k nw_v; do
    nw_i=${nw_k#wps:}; [ -n "$nw_v" ] && iw dev "$nw_i" set power_save "$nw_v" >/dev/null 2>&1
  done
  grep '^wps:' "$NP_BK" 2>/dev/null | cut -d'|' -f1 | while read -r nw_k; do np_bk_del "$nw_k"; done
  np_setconf NP_WIFIPS 0; echo "Wi-Fi Power-Save: MATI-fitur (power_save dikembalikan)"
}

np_cpu_mask_all() { nm_n=0; for nm_c in "$R"/sys/devices/system/cpu/cpu[0-9]*; do [ -d "$nm_c" ] && nm_n=$((nm_n + 1)); done; [ "$nm_n" -gt 0 ] || nm_n=8; printf '%x' $(( (1 << nm_n) - 1 )); }
np_rps_apply() { # cetak "ok total"
  nr_mask=$(np_cpu_mask_all); nr_ok=0; nr_t=0
  for nr_if in $(np_ifaces); do
    for nr_q in "$R"/sys/class/net/$nr_if/queues/rx-*/rps_cpus; do
      [ -w "$nr_q" ] || continue
      nr_t=$((nr_t + 1))
      np_bk_put "rps:$nr_q" "$(dv_cat "$nr_q")"
      { echo "$nr_mask" > "$nr_q"; } 2>/dev/null
      nr_rb=$(dv_cat "$nr_q" | tr -d ',' | sed 's/^0*//')
      [ "$nr_rb" = "$nr_mask" ] && nr_ok=$((nr_ok + 1))
    done
  done
  echo "$nr_ok $nr_t"
}
np_rps_on() {
  set -- $(np_rps_apply)
  if [ "$1" -gt 0 ]; then np_setconf NP_RPS 1; np_watch_ensure; echo "RPS Boost: AKTIF di $1/$2 antrean RX (mask semua core)"
  else np_setconf NP_RPS 0; echo "RPS Boost: GAGAL - kernel tanpa rps_cpus yang bisa ditulis ($2 antrean ditemukan)"; return 1; fi
}
np_rps_off() {
  grep '^rps:' "$NP_BK" 2>/dev/null | while IFS='|' read -r nr_k nr_v; do
    nr_p=${nr_k#rps:}; [ -n "$nr_v" ] && [ -w "$nr_p" ] && { echo "$nr_v" > "$nr_p"; } 2>/dev/null
  done
  grep '^rps:' "$NP_BK" 2>/dev/null | cut -d'|' -f1 | while read -r nr_k; do np_bk_del "$nr_k"; done
  np_setconf NP_RPS 0; echo "RPS Boost: MATI (rps_cpus dikembalikan)"
}

# Block All: REJECT semua UID app (10000-19999) kecuali Companion Zyrox + daftar izin
np_blockall_apply() { # cetak "ok pengecualian"
  np_chain_reset filter "$NP_CHAIN_BLK" OUTPUT
  np_chain_new filter "$NP_CHAIN_BLK" OUTPUT
  nba_n=0; nba_ok=0
  for nba_p in "$NP_SELF_PKG" $(np_list_pkgs "$NP_BLK_ALLOW"); do
    nba_u=$(np_uid "$nba_p"); [ -n "$nba_u" ] || continue
    ipt -A "$NP_CHAIN_BLK" -m owner --uid-owner "$nba_u" -j RETURN 2>/dev/null && nba_n=$((nba_n + 1))
    ipt6 -A "$NP_CHAIN_BLK" -m owner --uid-owner "$nba_u" -j RETURN 2>/dev/null
  done
  ipt -A "$NP_CHAIN_BLK" -m owner --uid-owner 10000-19999 -j REJECT 2>/dev/null && nba_ok=1
  ipt6 -A "$NP_CHAIN_BLK" -m owner --uid-owner 10000-19999 -j REJECT 2>/dev/null
  echo "$nba_ok $nba_n"
}
np_blockall_on() {
  set -- $(np_blockall_apply)
  if [ "$1" = 1 ]; then np_setconf NP_BLOCKALL 1; np_watch_ensure; echo "Block All: AKTIF - semua app (UID 10000-19999) diblokir internetnya, $2 dikecualikan"
  else np_chain_reset filter "$NP_CHAIN_BLK" OUTPUT; np_setconf NP_BLOCKALL 0; echo "Block All: GAGAL - kernel tanpa iptables owner/REJECT (TIDAK DIDUKUNG)"; return 1; fi
}
np_blockall_off() { np_chain_reset filter "$NP_CHAIN_BLK" OUTPUT; np_setconf NP_BLOCKALL 0; echo "Block All: MATI (blokir semua dilepas)"; }

np_dscp_set() { # np_dscp_set <0-63>
  case "$1" in ''|*[!0-9]*) echo "DSCP harus angka 0-63"; return 1 ;; esac
  [ "$1" -le 63 ] || { echo "DSCP harus angka 0-63"; return 1; }
  np_setconf NP_DSCP "$1"; load_conf
  [ "$NP_BOOST" = 1 ] && np_boost_apply >/dev/null
  echo "DSCP Boost Apps = $1"
}

np_apps() { { pm list packages -3 2>/dev/null || cmd package list packages -3 2>/dev/null; } | sed -n 's/^package://p' | sort -u; }

# =====================================================================
#  Preset + Smart Auto
# =====================================================================
# preset|cc|qdisc|rbuf|lowlat|retries2|mtuprobe
np_preset_row() {
  case "$1" in
    balanced)  echo "bbr fq_codel 4194304 0 10 1" ;;
    game)      echo "bbr3 cake 2097152 1 8 1" ;;
    download)  echo "cubic fq_codel 16777216 0 15 1" ;;
    streaming) echo "bbr fq_codel 8388608 0 12 1" ;;
    social)    echo "cubic fq_codel 4194304 0 10 1" ;;
    browsing)  echo "cubic fq_codel 4194304 1 10 1" ;;
    outdoor)   echo "bbr fq_codel 4194304 1 15 2" ;;
    *) return 1 ;;
  esac
}

np_preset_apply() { # np_preset_apply <nama>
  np_p=$1
  [ "$np_p" = default ] && { np_preset_restore; echo "Preset: default (nilai asli dipulihkan)"; return 0; }
  np_row=$(np_preset_row "$np_p") || { echo "preset: default|balanced|game|download|streaming|social|browsing|outdoor"; return 1; }
  set -- $np_row
  np_cc=$1; np_qd=$2; np_rb=$3; np_ll=$4; np_r2=$5; np_mp=$6
  for np_try in "$np_cc" bbr bbr3 cubic; do
    np_write "$R/proc/sys/net/ipv4/tcp_congestion_control" "$np_try" && { np_cc=$np_try; break; }
  done
  np_write "$R/proc/sys/net/core/rmem_max" "$np_rb"
  np_write "$R/proc/sys/net/core/wmem_max" "$np_rb"
  np_write "$R/proc/sys/net/ipv4/tcp_rmem" "4096 1048576 $np_rb"
  np_write "$R/proc/sys/net/ipv4/tcp_wmem" "4096 1048576 $np_rb"
  np_write "$R/proc/sys/net/ipv4/tcp_low_latency" "$np_ll"
  np_write "$R/proc/sys/net/ipv4/tcp_retries2" "$np_r2"
  np_write "$R/proc/sys/net/ipv4/tcp_mtu_probing" "$np_mp"
  np_write "$R/proc/sys/net/ipv4/tcp_slow_start_after_idle" 0
  nq_msg=""
  if np_have tc || [ -x /system/bin/tc ]; then
    [ "$(cat "$RUNDIR/np_qdisc_cur" 2>/dev/null)" = "$np_qd" ] || { nq_msg=" qdisc=$np_qd($(np_qdisc_apply_algo "$np_qd"))"; echo "$np_qd" > "$RUNDIR/np_qdisc_cur"; }
  fi
  echo "$np_p" > "$RUNDIR/np_preset_cur"
  log_msg "NETPRO: preset=$np_p cc=$np_cc buf=$np_rb$nq_msg"
  echo "Preset: $np_p (cc=$np_cc buffer=$np_rb lowlat=$np_ll$nq_msg)"
}

np_preset_restore() { # kembalikan semua sysctl yang disentuh preset
  np_restore_prefix "sys:$R/proc/sys/net/ipv4/tcp"
  np_restore_prefix "sys:$R/proc/sys/net/core/rmem"
  np_restore_prefix "sys:$R/proc/sys/net/core/wmem"
  rm -f "$RUNDIR/np_preset_cur" "$RUNDIR/np_qdisc_cur"
}

np_classify() { # np_classify <paket> -> game|download|streaming|social|browsing|default
  grep -qxF "$1" "$RUNDIR/games.list" 2>/dev/null && { echo game; return; }
  case "$1" in
    com.android.providers.downloads*|com.dv.adm*|idm.internet.download.manager*|com.android.vending|com.google.android.apps.nbu.files|com.mixplorer*|org.torproject.*|com.utorrent*|com.bittorrent*|com.vuze*|com.xunlei*) echo download ;;
    com.google.android.youtube|com.netflix.*|com.spotify.*|com.disney.*|in.startv.hotstar*|com.mxtech.*|tv.twitch.*|com.vidio.*|com.google.android.apps.youtube.music|com.amazon.avod*|com.iqiyi.*|com.wetv*|com.zhiliaoapp.musically|com.ss.android.ugc.trill|com.sg.vidio*) echo streaming ;;
    com.whatsapp*|org.telegram*|org.thunderdog.challegram|com.instagram.*|com.facebook.*|com.twitter.android|com.x.android|com.discord|com.snapchat.*|jp.naver.line.*|com.linkedin.*|com.reddit.*|org.thoughtcrime.securesms|com.tinder) echo social ;;
    com.android.chrome|com.chrome.*|org.mozilla.*|com.opera.*|com.brave.*|com.microsoft.emmx|com.sec.android.app.sbrowser|com.vivaldi.*|com.duckduckgo.*|com.kiwibrowser.*|com.UCMobile*|com.mi.globalbrowser|com.android.browser) echo browsing ;;
    *) echo default ;;
  esac
}

np_auto_on() { np_setconf NP_AUTO 1; np_watch_ensure; echo "Smart Auto: AKTIF (preset otomatis mengikuti aplikasi yang dibuka)"; }
np_auto_off() { np_setconf NP_AUTO 0; np_preset_restore; echo "Smart Auto: MATI (sysctl preset dipulihkan)"; }

# =====================================================================
#  Watcher (Smart Auto + DNS per jaringan + jaga iptables/IPv6)
# =====================================================================
NP_WATCH_PID="$RUNDIR/netwatch.pid"
np_watch_alive() { nw_p=$(cat "$NP_WATCH_PID" 2>/dev/null); [ -n "$nw_p" ] && kill -0 "$nw_p" 2>/dev/null; }
np_watch_needed() { load_conf; [ "$NP_AUTO" = 1 ] || [ "$NP_DNS" = 1 ] || [ "$NP_IPV6OFF" = 1 ] || [ "$NP_ISOLATE" = 1 ] || [ "$NP_BOOST" = 1 ] || [ "$NP_BLOCKALL" = 1 ] || [ "$NP_RPS" = 1 ] || [ "$NP_MTU" = 1 ] || [ "$NP_QDISC" = 1 ]; }
np_watch_ensure() {
  np_watch_alive && return 0
  nohup sh "$MODDIR/lib/netwatch.sh" >/dev/null 2>&1 &
}

# =====================================================================
#  Boot (setara `PingPimp --boot`) & matikan semua
# =====================================================================
np_boot() {
  load_conf
  [ "$NP_QDISC" = 1 ]     && np_qdisc_on "$NP_QDISC_ALGO"
  [ "$NP_CONNTRACK" = 1 ] && np_conntrack_on
  [ "$NP_IPV6OFF" = 1 ]   && np_ipv6off_on
  [ "$NP_NETSTATE" = 1 ]  && np_netstate_on
  [ "$NP_DATASAVER" = 1 ] && np_datasaver_on
  [ "$NP_LTECA" = 1 ]     && np_lteca_on
  [ "$NP_NICOFF" = 1 ]    && np_nic_on
  [ "$NP_ADV" = 1 ]       && np_adv_on
  [ "$NP_ISOLATE" = 1 ]   && np_isolate_on
  [ "$NP_BOOST" = 1 ]     && np_boost_on
  [ "$NP_BLOCKALL" = 1 ]  && np_blockall_on
  [ "$NP_TFO" = 1 ]       && np_tfo_on
  [ "$NP_WIFIPS" = 1 ]    && np_wifips_on
  [ "$NP_RPS" = 1 ]       && np_rps_on
  [ "$NP_DNS" = 1 ]       && np_dns_apply
  [ "$NP_MTU" = 1 ]       && np_mtu_on
  np_watch_needed && np_watch_ensure
}

np_all_off() {
  np_auto_off; np_qdisc_off; np_mtu_off; np_dns_off; np_adv_off; np_nic_off
  np_conntrack_off; np_ipv6off_off; np_datasaver_off; np_netstate_off; np_lteca_off
  np_isolate_off; np_boost_off; np_blockall_off; np_tfo_off; np_wifips_off; np_rps_off
  nw_p=$(cat "$NP_WATCH_PID" 2>/dev/null); [ -n "$nw_p" ] && kill "$nw_p" 2>/dev/null; rm -f "$NP_WATCH_PID"
  : > "$NP_BK"
}

np_status() {
  load_conf
  echo "NP_AUTO=$NP_AUTO preset=$(cat "$RUNDIR/np_preset_cur" 2>/dev/null)"
  echo "NP_QDISC=$NP_QDISC algo=$NP_QDISC_ALGO NP_MTU=$NP_MTU NP_DNS=$NP_DNS NP_ADV=$NP_ADV NP_NICOFF=$NP_NICOFF"
  echo "NP_CONNTRACK=$NP_CONNTRACK NP_IPV6OFF=$NP_IPV6OFF NP_DATASAVER=$NP_DATASAVER NP_NETSTATE=$NP_NETSTATE NP_LTECA=$NP_LTECA"
  echo "NP_ISOLATE=$NP_ISOLATE ($(np_list_pkgs "$NP_ISO_LIST" | wc -l) app) NP_BOOST=$NP_BOOST ($(np_list_pkgs "$NP_BST_LIST" | wc -l) app + games=$NP_BOOST_GAMES)"
  echo "NP_TFO=$NP_TFO NP_WIFIPS=$NP_WIFIPS NP_RPS=$NP_RPS NP_BLOCKALL=$NP_BLOCKALL dscp=$NP_DSCP"
  echo "jaringan=$(np_active_type) if=$(np_active_if) congestion=$(dv_cat "$R/proc/sys/net/ipv4/tcp_congestion_control") qdisc_default=$(dv_cat "$R/proc/sys/net/core/default_qdisc") watcher=$(np_watch_alive && echo jalan || echo mati)"
}

# =====================================================================
#  Dispatcher: azenith-ai net ...
# =====================================================================
np_onoff() { # np_onoff <fitur> <on|off> -> panggil np_<fitur>_<on|off>
  case "$2" in on|off) "np_$1_$2" ;; *) echo "pakai: net $1 on|off"; return 1 ;; esac
}

np_main() {
  case "$1" in
    qdisc)  case "$2" in on) np_qdisc_on "$3" ;; off) np_qdisc_off ;; algo) np_setconf NP_QDISC_ALGO "$3"; load_conf; [ "$NP_QDISC" = 1 ] && np_qdisc_on "$3" ;; *) echo "net qdisc on [cake|fq_codel|fq]|off|algo <x>" ;; esac ;;
    mtu)    case "$2" in probe) np_mtu_probe ;; *) np_onoff mtu "$2" ;; esac ;;
    dns)    shift; np_dns_cmd "$@" ;;
    adv)    np_onoff adv "$2" ;;
    nicoff) np_onoff nic "$2" ;;
    conntrack) np_onoff conntrack "$2" ;;
    ipv6off) np_onoff ipv6off "$2" ;;
    datasaver) np_onoff datasaver "$2" ;;
    netstate) np_onoff netstate "$2" ;;
    lteca)  np_onoff lteca "$2" ;;
    isolate) case "$2" in
        on|off) np_onoff isolate "$2" ;;
        add|del) np_list_edit "$NP_ISO_LIST" "$2" "$3" && { load_conf; [ "$NP_ISOLATE" = 1 ] && np_isolate_apply >/dev/null; echo "Isolate: $2 $3"; } ;;
        list) np_list_pkgs "$NP_ISO_LIST" ;;
        *) echo "net isolate on|off|add <pkg>|del <pkg>|list" ;; esac ;;
    boost)  case "$2" in
        on|off) np_onoff boost "$2" ;;
        add|del) np_list_edit "$NP_BST_LIST" "$2" "$3" && { load_conf; [ "$NP_BOOST" = 1 ] && np_boost_apply >/dev/null; echo "Boost: $2 $3"; } ;;
        games) case "$3" in 1|0) np_setconf NP_BOOST_GAMES "$3"; load_conf; [ "$NP_BOOST" = 1 ] && np_boost_apply >/dev/null; echo "Boost game otomatis = $3" ;; esac ;;
        list) np_list_pkgs "$NP_BST_LIST" ;;
        *) echo "net boost on|off|add <pkg>|del <pkg>|games 1|0|list" ;; esac ;;
    auto)   case "$2" in on) np_auto_on ;; off) np_auto_off ;; preset) np_preset_apply "$3" ;; *) echo "net auto on|off|preset <default|game|download|streaming|social|browsing|outdoor>" ;; esac ;;
    cc)     case "$2" in auto|bbr|bbr3|cubic|westwood) np_setconf NET_CONGESTION "$2"; load_conf
                echo "Congestion control = $2"; [ "$NETBOOST" = 1 ] && nb_on ;;
              *) echo "net cc auto|bbr|bbr3|cubic|westwood" ;; esac ;;
    tfo)    np_onoff tfo "$2" ;;
    wifips) np_onoff wifips "$2" ;;
    rps)    np_onoff rps "$2" ;;
    blockall) np_onoff blockall "$2" ;;
    dscp)   np_dscp_set "$2" ;;
    apps)   np_apps ;;
    block)  case "$2" in
        all) case "$3" in on|off) np_onoff blockall "$3" ;; *) echo "net block all on|off" ;; esac ;;
        allow) case "$3" in
            add|del) np_list_edit "$NP_BLK_ALLOW" "$3" "$4" && { load_conf; [ "$NP_BLOCKALL" = 1 ] && np_blockall_apply >/dev/null; echo "Block All izin: $3 $4"; } ;;
            list) np_list_pkgs "$NP_BLK_ALLOW" ;;
            *) echo "net block allow add <pkg>|del <pkg>|list" ;; esac ;;
        app) shift 2; np_main isolate "$@" ;;
        *) echo "net block all on|off | allow add|del|list | app add|del|list|on|off" ;; esac ;;
    boot)   np_boot ;;
    alloff) np_all_off ;;
    status|"") np_status ;;
    *) echo "net qdisc|mtu|dns|adv|nicoff|conntrack|ipv6off|datasaver|netstate|lteca|isolate|boost|auto|cc|tfo|wifips|rps|blockall|block|dscp|apps|boot|alloff|status" ;;
  esac
}
