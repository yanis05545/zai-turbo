#!/system/bin/sh
# Zyrox - lib/netwatch.sh : watcher Network Pro (Smart Auto, DNS per jaringan, jaga IPv6/iptables/MTU/qdisc)
MODDIR=${0%/*}; MODDIR=${MODDIR%/lib}
export MODDIR
. "$MODDIR/common.sh"
load_conf
[ -f "$MODDIR/disable" ] && exit 0
np_watch_alive && [ "$(cat "$NP_WATCH_PID" 2>/dev/null)" != "$$" ] && exit 0
echo $$ > "$NP_WATCH_PID"
log_msg "NETWATCH: start pid=$$"
scan_if_needed >/dev/null 2>&1
games_build >/dev/null 2>&1
nwl_sig=""; nwl_cat=""; nwl_pend=""; nwl_n=0
while :; do
  [ -f "$MODDIR/disable" ] || [ -f "$RUNDIR/stop" ] && break
  nwl_n=$((nwl_n + 1))
  [ $((nwl_n % 6)) = 1 ] && { load_conf; np_watch_needed || break; }
  # --- perubahan jaringan (interface + gateway) ---
  nwl_s="$(np_active_if)|$(np_gw)"
  if [ "$nwl_s" != "$nwl_sig" ]; then
    nwl_sig=$nwl_s
    sleep 2
    [ "$NP_DNS" = 1 ] && np_dns_apply >/dev/null 2>&1
    [ "$NP_IPV6OFF" = 1 ] && np_ipv6_apply >/dev/null 2>&1
    [ "$NP_QDISC" = 1 ] && np_qdisc_apply_algo "$NP_QDISC_ALGO" >/dev/null 2>&1
    [ "$NP_MTU" = 1 ] && np_mtu_on >/dev/null 2>&1
    [ "$NP_ISOLATE" = 1 ] && np_isolate_apply >/dev/null 2>&1
    [ "$NP_BOOST" = 1 ] && np_boost_apply >/dev/null 2>&1
    [ "$NP_BLOCKALL" = 1 ] && np_blockall_apply >/dev/null 2>&1
    [ "$NP_RPS" = 1 ] && np_rps_apply >/dev/null 2>&1
    rm -f "$RUNDIR/np_qdisc_cur"
    log_msg "NETWATCH: jaringan berubah ($nwl_s)"
  fi
  # --- jaga jump iptables (netd kadang membangun ulang) ---
  if [ $((nwl_n % 12)) = 0 ]; then
    [ "$NP_ISOLATE" = 1 ] && ! ipt -C OUTPUT -j "$NP_CHAIN_ISO" 2>/dev/null && np_isolate_apply >/dev/null 2>&1
    [ "$NP_BLOCKALL" = 1 ] && ! ipt -C OUTPUT -j "$NP_CHAIN_BLK" 2>/dev/null && np_blockall_apply >/dev/null 2>&1
    [ "$NP_BOOST" = 1 ] && ! ipt -t mangle -C OUTPUT -j "$NP_CHAIN_BST" 2>/dev/null && np_boost_apply >/dev/null 2>&1
  fi
  # --- Smart Auto: preset mengikuti aplikasi aktif (debounce 2 bacaan) ---
  if [ "$NP_AUTO" = 1 ]; then
    FG_PKG=""; fg_get
    if [ -n "$FG_PKG" ]; then
      nwl_c=$(np_classify "$FG_PKG")
      if [ "$nwl_c" = "$nwl_pend" ]; then
        [ "$nwl_c" != "$nwl_cat" ] && { np_preset_apply "$nwl_c" >/dev/null 2>&1; nwl_cat=$nwl_c; log_msg "NETWATCH: $FG_PKG -> preset $nwl_c"; }
      fi
      nwl_pend=$nwl_c
    fi
  fi
  sleep "${NP_WATCH_SEC:-5}"
done
rm -f "$NP_WATCH_PID"
log_msg "NETWATCH: selesai"
