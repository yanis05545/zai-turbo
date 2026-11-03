#!/system/bin/sh
# =====================================================================
#  Zyrox - lib/thermalkill.sh : "Disable Thermal" mandiri (mode AGRESIF)
#
#  Kenapa versi lama masih menyisakan "running"?
#   Service HAL thermal (mis. vendor.thermal-hal-2-0.mtk) punya baris
#   'interface' di .rc. Begitu `stop` dijalankan, system_server / powerhal /
#   hwservicemanager meminta HAL itu lagi dan init MENYALAKAN ULANG lewat
#   ctl.interface_start. Loop 5 dtk + `stop` saja tidak pernah menang.
#
#  Strategi v2.6 (berlapis):
#   1. stop + ctl.stop + kill -9 PID (PID dari init.svc_debug_pid.*)  -> cepat
#   2. watchdog 2 dtk (bukan 5) untuk SEMUA service *thermal* yang
#      running/restarting, ditambah sapu proses *thermal* yatim
#   3. kalau service hidup lagi setelah dimatikan (ada yang menyalakan ulang)
#      -> BLOCK: binary HAL di-bind-mount dengan stub kosong (exit 0), jadi
#      respawn mati seketika dan tidak sempat menjalankan apa pun. Dilepas
#      otomatis saat fitur dimatikan.
#   4. prop disable-thermal + cmd thermalservice override-status 0 (diulang)
#   5. kernel: policy THERMAL pada MTK PPM dimatikan, trip passive/active zona
#      SoC dinaikkan ke TK_TRIP_C (hanya dinaikkan, nilai asli disimpan)
#
#  PENGAMAN (tetap): zona thermal kernel TIDAK dimatikan sehingga suhu asli
#  tetap terbaca. Kalau baterai >= TK_BATT_MAX, skin >= TK_SKIN_MAX atau SoC >=
#  batas tier selama TK_HOT_SEC detik -> SEMUA dikembalikan dan THERMAL_KILL=0.
# =====================================================================

TK_SVC="$DATADIR/tk_svc"; TK_PROP="$DATADIR/tk_props"; TK_PID="$RUNDIR/tk.pid"
TK_MNT="$DATADIR/tk_mounts"; TK_STUB="$DATADIR/tk_stub"; TK_KERN="$DATADIR/tk_kern"

tk_setconf() { # tk_setconf KEY VAL
  if grep -q "^$1=" "$CONF" 2>/dev/null; then sed -i "s/^$1=[^ #]*/$1=$2/" "$CONF"
  else echo "$1=$2" >> "$CONF"; fi
}
# v1.0.9: parsing getprop MURNI shell (tanpa regex sed) supaya sama di mksh/ash/toybox.
# Cetak "nama=status" untuk semua init.svc.*thermal* (status: running/stopped/restarting/...).
tk_props_svc() {
  getprop 2>/dev/null | while IFS= read -r tkl_l; do
    case "$tkl_l" in
      "[init.svc."*"]: ["*"]")
        tkl_n=${tkl_l#"[init.svc."}
        tkl_v=${tkl_n#*"]: ["}
        tkl_n=${tkl_n%%"]: ["*}
        tkl_v=${tkl_v%"]"}
        case "$tkl_n" in *thermal*) echo "$tkl_n=$tkl_v" ;; esac ;;
    esac
  done
}
# semua nama service *thermal* (apa pun statusnya)
tk_list_names() { tk_props_svc | while IFS='=' read -r tkn_a tkn_b; do echo "$tkn_a"; done; }
# yang masih hidup: running ATAU restarting (respawn)
tk_list_running() { tk_props_svc | while IFS='=' read -r tkn_a tkn_b; do case "$tkn_b" in running|restarting) echo "$tkn_a" ;; esac; done; }
tk_list_all() { tk_props_svc; }

# catat error perintah kontrol (stop/setprop/kill) - dulu dibuang ke /dev/null sehingga
# kalau SELinux/izin menolak, tidak ada jejak sama sekali. Terlihat di `thermalkill status`.
tk_err() { # tk_err "teks"
  [ -n "$1" ] || return 0
  tke_last=$(tail -n 1 "$DATADIR/tk_lasterr" 2>/dev/null)
  [ "$tke_last" = "$1" ] && return 0
  echo "$1" >> "$DATADIR/tk_lasterr"
  tail -n 6 "$DATADIR/tk_lasterr" > "$DATADIR/tk_lasterr.t" 2>/dev/null && mv -f "$DATADIR/tk_lasterr.t" "$DATADIR/tk_lasterr" 2>/dev/null
  log_msg "TKILL: ERR $1"
  flog THERMALKILL ERR "$1"
}

# cari path binary service dari file .rc init
tk_bin_of() {
  for tk_d in /vendor/etc/init /vendor/etc/init/hw /odm/etc/init /system/etc/init /system_ext/etc/init /product/etc/init; do
    [ -d "$tk_d" ] || continue
    tk_f=$(grep -lF "service $1 " "$tk_d"/*.rc 2>/dev/null | head -n 1)
    [ -n "$tk_f" ] || continue
    sed -n "s|^[[:space:]]*service $1 \([^ ]*\).*|\1|p" "$tk_f" | head -n 1
    return 0
  done
  return 0
}

# v1.0.15: bind-mount HARUS terlihat oleh init (yang meng-exec service). Dulu mount jalan di
# namespace pemanggil (shell WebUI/su) sehingga TK_MNT mencatat "sudah di-BLOCK" padahal init
# masih melihat binary asli -> service tetap hidup lagi dan penjaga menganggap urusan selesai.
tk_mnt() { # tk_mnt perintah... -> jalankan di namespace init kalau bisa
  if command -v nsenter >/dev/null 2>&1; then
    tkm_o=$(nsenter -t 1 -m -- "$@" 2>&1); tkm_r=$?
    case "$tkm_o" in *nsenter*) ;; *) [ -n "$tkm_o" ] && echo "$tkm_o"; return "$tkm_r" ;; esac
  fi
  "$@" 2>&1
}

# ---------------- BLOCK: stub di atas binary HAL ----------------
tk_block() { # tk_block nama [path_binary]
  tkb_n=$1; tkb_b=$2
  [ -n "$tkb_b" ] || tkb_b=$(tk_bin_of "$tkb_n")
  [ -n "$tkb_b" ] && [ -f "$tkb_b" ] || return 1
  grep -qxF "$tkb_b" "$TK_MNT" 2>/dev/null && return 0
  printf '#!/system/bin/sh\nexit 0\n' > "$TK_STUB" 2>/dev/null; chmod 755 "$TK_STUB" 2>/dev/null
  tkb_ctx=$(ls -Z "$tkb_b" 2>/dev/null | awk '{print $1}')
  [ -n "$tkb_ctx" ] && chcon "$tkb_ctx" "$TK_STUB" 2>/dev/null
  tkb_err=$(tk_mnt mount --bind "$TK_STUB" "$tkb_b")
  if [ $? -eq 0 ]; then
    echo "$tkb_b" >> "$TK_MNT"
    # oneshot: stub langsung exit -> service jadi "stopped" dan TIDAK masuk siklus restarting/running
    # tiap 5 dtk. Dicatat supaya dikembalikan (oneshot_off) saat Disable Thermal dimatikan.
    setprop ctl.oneshot_on "$tkb_n" 2>/dev/null
    grep -qxF "$tkb_n" "$DATADIR/tk_oneshot" 2>/dev/null || echo "$tkb_n" >> "$DATADIR/tk_oneshot"
    stop "$tkb_n" 2>/dev/null
    sed -i "\|^$tkb_n|d" "$DATADIR/tk_block_fail" 2>/dev/null
    log_msg "TKILL: BLOCK $tkb_n -> $tkb_b di-bind stub (respawn jadi mati seketika)"
    flog THERMALKILL OK "BLOCK $tkb_n -> $tkb_b di-bind stub (respawn jadi mati seketika)"
    return 0
  fi
  # simpan alasan gagal supaya kelihatan di `azenith-ai thermalkill status` (bukan cuma di log)
  echo "$tkb_n|$tkb_b|${tkb_err:-mount ditolak tanpa pesan (kemungkinan SELinux/izin)}" >> "$DATADIR/tk_block_fail"
  log_msg "TKILL: BLOCK $tkb_n gagal untuk $tkb_b -> $tkb_err"
  flog THERMALKILL ERR "BLOCK $tkb_n gagal untuk $tkb_b -> $tkb_err"
  return 1
}
tk_unblock() {
  [ -s "$TK_MNT" ] || { : > "$TK_MNT"; return 0; }
  while read -r tku_b; do [ -n "$tku_b" ] && { tk_mnt umount "$tku_b" >/dev/null 2>&1; umount "$tku_b" 2>/dev/null; }; done < "$TK_MNT"
  : > "$TK_MNT"
}

# ---------------- pengaman combo-HAL ----------------
# v1.0.9-fix: sebagian vendor binary (lazim di chipset MTK budget) mendaftarkan
# BEBERAPA service lewat satu binary yang sama - bukan cuma thermal. Kalau
# proses itu di-kill -9/di-BLOCK, interface lain yang nebeng (mis. data/
# connectivity/RIL glue) ikut putus -> jaringan "keblokir" + crash proses lain
# yang bergantung padanya. Deteksi: cari SEMUA baris "service NAMA path" di
# .rc yang path binary-nya SAMA dengan punya tks_n; kalau ada nama service lain
# yang TIDAK mengandung "thermal", anggap combo-binary -> jangan kill -9/BLOCK,
# cukup `stop` lunak saja.
tk_is_combo_bin() { # tk_is_combo_bin path_binary nama_service_asal
  tkc_b=$1; tkc_self=$2
  [ -n "$tkc_b" ] || return 1
  for tkc_d in /vendor/etc/init /vendor/etc/init/hw /odm/etc/init /system/etc/init /system_ext/etc/init /product/etc/init; do
    [ -d "$tkc_d" ] || continue
    for tkc_f in "$tkc_d"/*.rc; do
      [ -f "$tkc_f" ] || continue
      grep -qF " $tkc_b" "$tkc_f" 2>/dev/null || continue
      while read -r tkc_sn; do
        [ -n "$tkc_sn" ] || continue
        [ "$tkc_sn" = "$tkc_self" ] && continue
        case "$tkc_sn" in *thermal*) continue ;; esac
        return 0   # ada service non-thermal lain dibonceng di binary yang sama
      done <<EOF
$(sed -n "s|^[[:space:]]*service \([^ ]*\) $(printf '%s' "$tkc_b" | sed 's/[.[\*^$]/\\&/g').*|\1|p" "$tkc_f")
EOF
    done
  done
  return 1
}

# v1.0.44: matikan proses SATU service combo tanpa menyentuh service saudara di binary yang sama
tk_force_combo() { # nama bin pid
  fc_n=$1; fc_b=$2; fc_p=$3
  if [ -z "$fc_p" ] || [ ! -d "/proc/$fc_p" ]; then
    fc_all=$(pidof "${fc_b##*/}" 2>/dev/null)
    set -- $fc_all
    if [ "$#" -eq 1 ]; then fc_p=$1
    else
      [ -f "$RUNDIR/tkforce_amb.$fc_n" ] || { log_msg "TKILL: $fc_n combo: PID ambigu ($# proses) -> tidak di-kill agar service lain aman"; : > "$RUNDIR/tkforce_amb.$fc_n"; }
      return 0
    fi
  fi
  [ -n "$fc_p" ] && [ -d "/proc/$fc_p" ] || return 0
  kill -9 "$fc_p" 2>/dev/null && {
    log_msg "TKILL: FORCE $fc_n (pid $fc_p) dimatikan (combo-HAL, ZAI-Turbo)"
    flog THERMALKILL OK "FORCE $fc_n pid $fc_p dimatikan (ZAI-Turbo)"
  }
  setprop ctl.stop "$fc_n" 2>/dev/null
}

# ---------------- matikan satu service ----------------
tk_stop_one() { # tk_stop_one nama [force]
  tks_n=$1; tks_force=$2
  if grep -qxF "$tks_n" "$TK_SVC" 2>/dev/null; then tks_seen=1; else tks_seen=0; echo "$tks_n" >> "$TK_SVC"; fi
  tks_pid=$(getprop "init.svc_debug_pid.$tks_n" 2>/dev/null)
  case "$tks_pid" in ''|*[!0-9]*) tks_pid="" ;; esac
  tks_bin=""; [ -n "$tks_pid" ] && tks_bin=$(readlink "/proc/$tks_pid/exe" 2>/dev/null)
  # v1.0.15: init.svc_debug_pid.* biasanya TIDAK ada di build user -> dulu tks_bin kosong,
  # artinya pengaman combo-HAL dilewati dan kill/BLOCK tidak punya target. Cari binary dari
  # file .rc dan PID dari pidof sebagai cadangan.
  [ -n "$tks_bin" ] || tks_bin=$(tk_bin_of "$tks_n")
  if [ -z "$tks_pid" ] && [ -n "$tks_bin" ]; then
    tks_pid=$(pidof "${tks_bin##*/}" 2>/dev/null | while read -r tks_x tks_rest; do echo "$tks_x"; done)
    case "$tks_pid" in ''|*[!0-9]*) tks_pid="" ;; esac
  fi
  # PID beda dari yang kita matikan sebelumnya = ADA yang menyalakan ulang service ini
  tks_prev=$(cat "$RUNDIR/tkpid.$tks_n" 2>/dev/null)
  if [ -n "$tks_pid" ] && [ -n "$tks_prev" ] && [ "$tks_prev" != "$tks_pid" ]; then
    tks_rc=$(cat "$RUNDIR/tkrespawn.$tks_n" 2>/dev/null); tks_rc=$(( ${tks_rc:-0} + 1 )); echo "$tks_rc" > "$RUNDIR/tkrespawn.$tks_n"
    [ "$tks_rc" -le 20 ] && { log_msg "TKILL: $tks_n hidup lagi (pid $tks_prev -> $tks_pid), respawn ke-$tks_rc: ada yang menyalakan ulang"; flog THERMALKILL BUG "$tks_n hidup lagi (pid $tks_prev -> $tks_pid), respawn ke-$tks_rc: ada yang menyalakan ulang"; }
  fi
  [ -n "$tks_pid" ] && echo "$tks_pid" > "$RUNDIR/tkpid.$tks_n"
  tks_e=$(stop "$tks_n" 2>&1); [ -n "$tks_e" ] && tk_err "stop $tks_n: $tks_e"
  tks_e=$(setprop ctl.stop "$tks_n" 2>&1); [ -n "$tks_e" ] && tk_err "ctl.stop $tks_n: $tks_e"
  # v1.0.9-fix: binary gabungan (combo HAL, lihat tk_is_combo_bin) -> JANGAN
  # kill -9 / BLOCK, `stop` lunak di atas sudah cukup. Mencegah proses lain
  # (mis. data/connectivity) yang nebeng di binary sama ikut jatuh -> crash
  # + jaringan keblokir.
  if [ -n "$tks_bin" ] && tk_is_combo_bin "$tks_bin" "$tks_n"; then
    # v1.0.44 (ZAI-Turbo): TK_FORCE_COMBO=1 -> service thermal combo (mis. vendor.thermal-hal-2-0.mtk)
    # tetap dimatikan, tapi HANYA proses milik service ini (PID dari init.svc_debug_pid, atau
    # pidof bila tepat satu). BLOCK/stub tetap dilewati agar service non-thermal tak ikut jatuh.
    if [ "${TK_FORCE_COMBO:-0}" = 1 ]; then
      tk_force_combo "$tks_n" "$tks_bin" "$tks_pid"
      return 0
    fi
    [ -f "$RUNDIR/tkcombo.$tks_n" ] || { log_msg "TKILL: $tks_n ($tks_bin) adalah combo-binary (dipakai service non-thermal juga) -> skip kill-9/BLOCK, stop lunak saja"; : > "$RUNDIR/tkcombo.$tks_n"; }
    return 0
  fi
  # proses sering sudah hilang karena `stop` barusan - hanya catat error kalau PID masih ada
  if [ -n "$tks_pid" ] && [ -d "/proc/$tks_pid" ]; then tks_e=$(kill -9 "$tks_pid" 2>&1); [ -n "$tks_e" ] && tk_err "kill -9 $tks_pid ($tks_n): $tks_e"; fi
  # sudah pernah dimatikan tapi hidup lagi = ada yang menyalakan ulang -> BLOCK
  if [ "${TK_BLOCK:-1}" = 1 ]; then
    if [ "$tks_force" = force ]; then tk_block "$tks_n" "$tks_bin"
    elif [ "$tks_seen" = 1 ]; then
      tks_c=$(cat "$RUNDIR/tkrs.$tks_n" 2>/dev/null); tks_c=$(( ${tks_c:-0} + 1 )); echo "$tks_c" > "$RUNDIR/tkrs.$tks_n"
      [ "$tks_c" -ge "${TK_BLOCK_AFTER:-2}" ] && tk_block "$tks_n" "$tks_bin"
    fi
  fi
  return 0
}
tk_enforce() { # tk_enforce [force]  -> matikan semua service thermal yang hidup
  for tk_s in $(tk_list_running); do tk_stop_one "$tk_s" "$1"; done
}
# sapu proses *thermal* userspace yang tidak terdaftar sebagai service (atau sisa)
tk_kill_procs() {
  [ "${TK_KILL_PROCS:-0}" = 1 ] || return 0
  ps -A -o PID,NAME 2>/dev/null | while read -r tkp_p tkp_n; do
    case "$tkp_p" in ''|*[!0-9]*) continue ;; esac
    case "$tkp_n" in
      *azenith-ai*|*thermalservice*) continue ;;
      *thermal*) readlink "/proc/$tkp_p/exe" >/dev/null 2>&1 && kill -9 "$tkp_p" 2>/dev/null ;;
    esac
  done
}

tk_props_apply() {
  [ -s "$SCANDIR/thermal_props" ] || return 0
  while IFS='|' read -r tk_k tk_v; do
    [ -n "$tk_k" ] || continue
    grep -q "^$tk_k|" "$TK_PROP" 2>/dev/null || echo "$tk_k|$(getprop "$tk_k")" >> "$TK_PROP"
    if command -v resetprop >/dev/null 2>&1; then resetprop "$tk_k" "$tk_v" 2>/dev/null; else setprop "$tk_k" "$tk_v" 2>/dev/null; fi
  done < "$SCANDIR/thermal_props"
}
tk_props_revert() {
  [ -s "$TK_PROP" ] || { : > "$TK_PROP"; return 0; }
  while IFS='|' read -r tk_k tk_v; do
    [ -n "$tk_k" ] || continue
    if [ -n "$tk_v" ]; then
      if command -v resetprop >/dev/null 2>&1; then resetprop "$tk_k" "$tk_v" 2>/dev/null; else setprop "$tk_k" "$tk_v" 2>/dev/null; fi
    else resetprop --delete "$tk_k" 2>/dev/null || setprop "$tk_k" "" 2>/dev/null; fi
  done < "$TK_PROP"
  : > "$TK_PROP"
}
# v1.0.9: pakai timeout - `cmd` yang menggantung dulu bisa menahan penjaga SEBELUM sempat mematikan apa pun
tk_override() { [ "$(getprop ro.build.version.sdk)" -ge 30 ] 2>/dev/null && tmo 5 cmd thermalservice override-status 0 >/dev/null 2>&1; return 0; }

# ---------------- lapis kernel ----------------
tk_kernel_apply() {
  [ "${TK_KERNEL:-1}" = 1 ] || return 0
  # a) MTK PPM: matikan policy THERMAL
  if [ -r /proc/ppm/policy_status ]; then
    tkk_i=$(grep -i -m1 'policy_thermal' /proc/ppm/policy_status 2>/dev/null | sed -n 's/^[^0-9]*\([0-9][0-9]*\).*/\1/p')
    if [ -n "$tkk_i" ]; then
      grep -q '^ppm|' "$TK_KERN" 2>/dev/null || echo "ppm|$tkk_i" >> "$TK_KERN"
      { echo "$tkk_i 0" > /proc/ppm/policy_status; } 2>/dev/null
    fi
  fi
  # b) naikkan trip passive/active zona SoC (tidak pernah menurunkan, tidak menyentuh critical/hot)
  [ -s "$SCANDIR/zones" ] || return 0
  tkk_tgt=$(( ${TK_TRIP_C:-90} * 1000 ))
  while IFS='|' read -r tkk_z tkk_t tkk_c tkk_e tkk_tp; do
    [ "$tkk_c" = soc ] || continue
    tkk_d=$(zone_dir "$tkk_z")
    for tkk_ty in "$tkk_d"/trip_point_*_type; do
      [ -e "$tkk_ty" ] || continue
      case "$(read1 "$tkk_ty")" in passive|active) ;; *) continue ;; esac
      tkk_f=${tkk_ty%_type}_temp
      tkk_cur=$(read1 "$tkk_f")
      case "$tkk_cur" in ''|*[!0-9]*) continue ;; esac
      [ "$tkk_cur" -lt "$tkk_tgt" ] || continue
      grep -qxF "$tkk_f|$tkk_cur" "$TK_KERN" 2>/dev/null || grep -q "^$tkk_f|" "$TK_KERN" 2>/dev/null || echo "$tkk_f|$tkk_cur" >> "$TK_KERN"
      { echo "$tkk_tgt" > "$tkk_f"; } 2>/dev/null
    done
  done < "$SCANDIR/zones"
}
tk_kernel_revert() {
  [ -s "$TK_KERN" ] || { : > "$TK_KERN"; return 0; }
  while IFS='|' read -r tkr_k tkr_v; do
    [ -n "$tkr_k" ] || continue
    if [ "$tkr_k" = ppm ]; then { echo "$tkr_v 1" > /proc/ppm/policy_status; } 2>/dev/null
    else { echo "$tkr_v" > "$tkr_k"; } 2>/dev/null; fi
  done < "$TK_KERN"
  : > "$TK_KERN"
}

# ---------------- loop penjaga ----------------
# v1.0.9: cek PID benar-benar tkloop (PID lama yang dipakai ulang proses lain tidak lagi
# dianggap "penjaga masih hidup" -> dulu penjaga baru menolak start dan thermal tidak pernah dimatikan)
tk_loop_alive() {
  tk_p=$(cat "$TK_PID" 2>/dev/null)
  [ -n "$tk_p" ] || return 1
  kill -0 "$tk_p" 2>/dev/null || return 1
  case "$(tr '\0' ' ' < "/proc/$tk_p/cmdline" 2>/dev/null)" in *tkloop*) return 0 ;; esac
  return 1
}
tk_loop_start() { # tk_loop_start [verify]
  tk_loop_alive && return 0
  # jangan start dobel kalau baru saja dijalankan (penjaga butuh ~1 dtk untuk menulis PID)
  if [ "$1" != verify ]; then
    tkq_t=$(cat "$RUNDIR/tk_start_t" 2>/dev/null); tkq_n=$(uptime_s)
    case "$tkq_t" in ''|*[!0-9]*) ;; *) [ $((tkq_n - tkq_t)) -lt 6 ] && return 0 ;; esac
  fi
  uptime_s > "$RUNDIR/tk_start_t" 2>/dev/null
  # nsenter (mount namespace init) hanya perlu untuk BLOCK bind-mount; selain itu proses polos
  # lebih andal (nsenter yang gagal diam-diam = penjaga tidak pernah ada)
  if [ "${TK_BLOCK:-0}" = 1 ] && command -v nsenter >/dev/null 2>&1; then
    nohup nsenter -t 1 -m -- sh "$MODDIR/lib/tkloop.sh" >/dev/null 2>&1 &
  else
    nohup sh "$MODDIR/lib/tkloop.sh" >/dev/null 2>&1 &
  fi
  if [ "$1" = verify ]; then
    tkv_n=0
    while [ "$tkv_n" -lt 6 ]; do
      sleep 1; tk_loop_alive && return 0; tkv_n=$((tkv_n + 1))
    done
    log_msg "TKILL: penjaga tidak muncul setelah 6 dtk -> start ulang tanpa nsenter"
    nohup sh "$MODDIR/lib/tkloop.sh" >/dev/null 2>&1 &
    sleep 2
  fi
  return 0
}
# pastikan penjaga hidup selama THERMAL_KILL=1 (dipanggil daemon, `status`, dan WebUI)
tk_watch() {
  [ "$THERMAL_KILL" = 1 ] || return 0
  [ -f "$DATADIR/tk_off" ] && return 0
  [ -f "$MODDIR/disable" ] && return 0
  tk_loop_alive || { log_msg "TKILL: penjaga tidak jalan -> dijalankan"; tk_loop_start; }
  return 0
}
tk_loop_stop() {
  tk_p=$(cat "$TK_PID" 2>/dev/null)
  [ -n "$tk_p" ] && kill "$tk_p" 2>/dev/null
  rm -f "$TK_PID"
}

# pengaman suhu: v1.0.41 - dikembalikan, TAPI tetap tunduk pada aturan inti:
# "Disable Thermal hanya hidup saat ZAI-Turbo hidup, hanya mati saat ZAI-Turbo mati".
# Jadi pengaman TIDAK mematikan thermalkill sendirian - ia mengeluarkan modul dari
# ZAI-Turbo (azenith-thermal balance). as_reset_all lalu menjalankan tk_off, sehingga
# service thermal hidup lagi LEWAT jalur resmi mode-mati. Ambang: TK_BATT_MAX /
# TK_SKIN_MAX / batas SoC tier, bertahan >= TK_HOT_SEC detik. Matikan pengaman: TK_GUARD=0.
TK_HOT_T0=0
tk_safety() {
  [ "${TK_GUARD:-1}" = 1 ] || { TK_HOT_T0=0; return 0; }
  thermal_limits_init; temps_read
  tk_hot=""
  [ -n "$T_BATT" ] && [ "$T_BATT" -ge "${TK_BATT_MAX:-45}" ] && tk_hot="baterai ${T_BATT}C"
  [ -n "$T_SKIN" ] && [ "$T_SKIN" -ge "${TK_SKIN_MAX:-47}" ] && tk_hot="$tk_hot skin ${T_SKIN}C"
  [ -n "$T_SOC" ] && [ -n "$SOC_LIM" ] && [ "$T_SOC" -ge "$SOC_LIM" ] && tk_hot="$tk_hot SoC ${T_SOC}C"
  if [ -z "$tk_hot" ]; then TK_HOT_T0=0; return 0; fi
  tks_now=$(uptime_s)
  [ "${TK_HOT_T0:-0}" = 0 ] && TK_HOT_T0=$tks_now
  if [ $((tks_now - TK_HOT_T0)) -ge "${TK_HOT_SEC:-10}" ]; then
    log_msg "TKILL: PANAS ($tk_hot) >= ${TK_HOT_SEC:-10} dtk -> keluar dari ZAI-Turbo (balance), thermal hidup lagi lewat jalur mode-mati"
    flog THERMALKILL INFO "panas ($tk_hot) -> keluar dari ZAI-Turbo"
    TK_HOT_T0=0
    nohup sh "$MODDIR/system/bin/azenith-thermal" balance >/dev/null 2>&1 &
  fi
  return 0
}

tk_restore_all() {
  tk_unblock
  tk_kernel_revert
  if [ -s "$DATADIR/tk_oneshot" ]; then
    while read -r tk_s; do [ -n "$tk_s" ] && setprop ctl.oneshot_off "$tk_s" 2>/dev/null; done < "$DATADIR/tk_oneshot"
  fi
  : > "$DATADIR/tk_oneshot"
  if [ -s "$TK_SVC" ]; then
    while read -r tk_s; do [ -n "$tk_s" ] && start "$tk_s" 2>/dev/null; done < "$TK_SVC"
  fi
  : > "$TK_SVC"
  tk_props_revert
  rm -f "$RUNDIR"/tkrs.* 2>/dev/null
  [ "$(getprop ro.build.version.sdk)" -ge 30 ] 2>/dev/null && tmo 5 cmd thermalservice reset >/dev/null 2>&1
  return 0
}

tk_on() { # tk_on [quick]
  load_conf
  # pilihan user "ON" -> hapus penanda mati-permanen supaya tahan reboot lagi
  rm -f "$DATADIR/tk_off"
  # Disable Thermal fitur inti - selalu menang. Kalau Bypass Thermal entah bagaimana masih
  # aktif (conf lama/manual), lepas otomatis, jangan menolak.
  if [ "$BYPASS_THERMAL" = 1 ]; then
    log_msg "TKILL: Bypass Thermal aktif -> dilepas otomatis, Disable Thermal tidak pernah ditolak"
    tk_setconf BYPASS_THERMAL 0
    tk_setconf THERMAL_MODE "${BYPASS_PREV_MODE:-auto}"
    tk_setconf BYPASS_PREV_MODE ""
    load_conf
  fi
  tk_setconf THERMAL_KILL 1
  THERMAL_KILL=1
  : > "$DATADIR/tk_block_fail"
  : > "$DATADIR/tk_lasterr"
  # v1.0.9: MATIKAN DULU, urusan lain sesudahnya. Dulu scan + cek suhu + props jalan lebih
  # dulu dan fungsi bisa menolak/menggantung sebelum satu pun service sempat distop.
  tk_enforce
  tk_loop_start verify
  tk_props_apply; tk_override; tk_kernel_apply
  tk_enforce; tk_kill_procs
  if [ "$1" = quick ]; then
    echo "Disable Thermal: AKTIF (penjaga dijalankan, service thermal disapu)"
    return 0
  fi
  sleep 2; tk_enforce; tk_kill_procs
  sleep 2
  # masih ada yang hidup setelah 2 putaran -> langsung BLOCK (agresif, hanya bila TK_BLOCK=1)
  [ -n "$(tk_list_running)" ] && { tk_enforce force; sleep 2; tk_enforce; }
  tk_left=$(tk_list_running | wc -l)
  [ "${tk_left:-0}" -gt 0 ] 2>/dev/null && echo "PERINGATAN: $tk_left service thermal masih hidup setelah disapu (dijaga ulang oleh watchdog)"
  echo "Disable Thermal AGRESIF: AKTIF (watchdog ${TK_TICK_EFF:-2} dtk, tahan reboot)"
  tk_status
}
tk_off() {
  tk_setconf TK_FORCE_COMBO 0; TK_FORCE_COMBO=0
  tk_setconf THERMAL_KILL 0
  THERMAL_KILL=0
  # pilihan user "OFF" tahan reboot (service.sh tidak memaksa ON lagi selama penanda ini ada)
  touch "$DATADIR/tk_off" 2>/dev/null
  tk_loop_stop
  tk_restore_all
  echo "Disable Thermal: MATI (BLOCK dilepas, service thermal dihidupkan kembali)"
  sleep 2; tk_status
}
tk_now() { # paksa satu putaran penuh sekarang (tanpa menunggu loop)
  load_conf; tk_override; tk_kernel_apply; tk_enforce force; tk_kill_procs; sleep 2; tk_enforce force
  tk_status
}
tk_status() {
  echo "THERMAL_KILL=$THERMAL_KILL  loop=$(tk_loop_alive && echo jalan || echo mati)  block=$(grep -c . "$TK_MNT" 2>/dev/null || echo 0)  tk_off=$([ -f "$DATADIR/tk_off" ] && echo ada || echo tidak)  TK_BLOCK=${TK_BLOCK:-?}"
  echo "--- status service thermal (init.svc.*) ---"
  tk_list_all
  tk_n=$(tk_list_running | wc -l)
  echo "--- masih running/restarting: $tk_n ---"
  for tk_s in $(tk_list_running); do
    tk_pp=$(getprop "init.svc_debug_pid.$tk_s" 2>/dev/null)
    echo "  $tk_s pid=${tk_pp:-?} exe=$( [ -n "$tk_pp" ] && readlink "/proc/$tk_pp/exe" 2>/dev/null)"
  done
  for tk_rf in "$RUNDIR"/tkrespawn.*; do
    [ -f "$tk_rf" ] || continue
    echo "  respawn ${tk_rf##*/tkrespawn.}: $(cat "$tk_rf")x (ada yang menyalakan ulang service ini)"
  done
  [ -s "$DATADIR/tk_lasterr" ] && { echo "--- error perintah terakhir (stop/ctl.stop/kill ditolak?) ---"; cat "$DATADIR/tk_lasterr"; }
  [ -s "$TK_MNT" ] && { echo "--- BLOCK aktif ---"; cat "$TK_MNT"; }
  if [ -s "$DATADIR/tk_block_fail" ]; then
    echo "--- BLOCK GAGAL (service tetap hidup karena ini) ---"
    while IFS='|' read -r tbf_n tbf_b tbf_e; do
      [ -n "$tbf_n" ] && echo "  $tbf_n ($tbf_b): $tbf_e"
    done < "$DATADIR/tk_block_fail"
    echo "  -> cek juga: dmesg | grep -i denied | grep -i mount   (SELinux avc)"
  fi
  return 0
}
