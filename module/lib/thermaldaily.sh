#!/system/bin/sh
# =====================================================================
#  Zyrox - lib/thermaldaily.sh : "Thermal Lock Daily"
#
#  Kenapa fitur ini ditambah (v1.0.7):
#   Fitur A "Thermal lock/inject" (lib/thermal.sh thermal_apply) SEBELUMNYA
#   cuma jalan di DALAM sesi game: dipanggil sekali di start_game() (lib/
#   daemon.sh) dan selalu DIREVERT oleh cleanup_all() begitu game berhenti/
#   keluar foreground/daemon idle. Di luar sesi game, thermal lock TIDAK
#   pernah aktif. "Bypass Thermal" (lib/bypass.sh) sebenarnya sudah bisa
#   memanggil thermal_apply() di luar sesi game, TAPI dia (a) selalu
#   memaksa THERMAL_MODE=hard, dan (b) SELALU DITOLAK selama THERMAL_KILL=1
#   - dan THERMAL_KILL itu dipaksa 1 PERMANEN tiap boot oleh service.sh,
#   jadi Bypass Thermal praktis tidak pernah bisa dipakai.
#
#  Thermal Lock Daily = toggle independen, TIDAK digerbang oleh THERMAL_KILL,
#  TIDAK memaksa mode (ikut THERMAL_MODE yang sedang dipilih user: soft/
#  auto/hard), dan begitu AKTIF dia terkunci "non-stop": berlaku di luar main
#  game (daily) MAUPUN selama main game (gaming) sampai dimatikan manual.
#
#  Kenapa TIDAK numpang ke thermal_apply()/thermal_revert() punya sesi game
#  (lib/thermal.sh) apa adanya: itu nulis lewat safe_write/prop_set/svc_stop
#  yang backup+stack-nya SAMA dengan punya sesi game (perf.sh dkk) - persis
#  bug lama yang sudah pernah ditemukan & diperbaiki di lib/overclock.sh
#  (lihat catatan OCSTACK/OCBACKUPDIR di sana). cleanup_all() (dipanggil tiap
#  game berhenti/keluar foreground/daemon idle/safety trip) memanggil
#  revert_stack/revert_props/revert_services yang akan ikut membongkar kunci
#  Daily kalau jalurnya dibagi. Makanya di sini dipakai jalur tulis+backup
#  SENDIRI (TD_*), supaya 100% tidak tersentuh cleanup_all() milik sesi game
#  - sama persis alasan OC punya OCSTACK/OCBACKUPDIR terpisah.
#
#  Pengaman: logika sama dengan thermal_apply() (verifikasi suhu asli SoC
#  masih terbaca setelah apply, batalkan kalau tidak), ditambah watchdog
#  lib/tdloop.sh yang auto-matikan (revert + THERMAL_DAILY=0) kalau baterai/
#  skin/SoC melewati ambang aman tier-aware - fitur ini menyamarkan suhu ASLI
#  dari OS/kernel SEPANJANG HARI (bukan cuma sebentar saat main game), jadi
#  auto-off di sini SENGAJA TIDAK dihapus (beda dari lib/thermalkill.sh yang
#  auto-off-nya dihapus atas permintaan user - fitur & risikonya beda).
# =====================================================================

TD_STACK="$DATADIR/td_applied_stack"
TD_BACKUPDIR="$DATADIR/td_backup"
TD_PROPSTACK="$DATADIR/td_props_stack"
TD_SVCSTACK="$DATADIR/td_svc_stack"
TD_FROZEN_F="$RUNDIR/td_frozen_ids"
TD_EMUL_F="$RUNDIR/td_emul_ids"
mkdir -p "$TD_BACKUPDIR" 2>/dev/null

td_setconf() { # td_setconf KEY VAL
  if grep -q "^$1=" "$CONF" 2>/dev/null; then sed -i "s/^$1=[^ #]*/$1=$2/" "$CONF"
  else echo "$1=$2" >> "$CONF"; fi
}

td_bfile() { echo "$TD_BACKUPDIR/$(echo "$1" | tr '/' '%')"; }

td_write() { # td_write <path> <val> - backup (sekali) + tulis, stack MILIK SENDIRI
  tw_p=$1; tw_v=$2
  [ -e "$tw_p" ] || return 1
  if ! grep -qxF "$tw_p" "$TD_STACK" 2>/dev/null; then
    tw_b=$(td_bfile "$tw_p"); tw_cur=$(read1 "$tw_p")
    [ -n "$tw_cur" ] || return 1
    { echo "$tw_cur" > "$tw_b.tmp"; } 2>/dev/null && mv -f "$tw_b.tmp" "$tw_b" 2>/dev/null
    echo "$tw_p" >> "$TD_STACK"
  fi
  { echo "$tw_v" > "$tw_p"; } 2>/dev/null
}
td_restore_path() {
  tb=$(td_bfile "$1")
  [ -f "$tb" ] || return 1
  tv=$(cat "$tb" 2>/dev/null)
  [ -n "$tv" ] || return 1
  { echo "$tv" > "$1"; } 2>/dev/null
  rm -f "$tb"
}
td_revert_stack() {
  [ -s "$TD_STACK" ] || { : > "$TD_STACK"; return 0; }
  awk '{a[NR]=$0} END{for(i=NR;i>0;i--) print a[i]}' "$TD_STACK" | while read -r td_r; do
    [ -n "$td_r" ] && td_restore_path "$td_r"
  done
  : > "$TD_STACK"
}

td_prop_set() {
  tp_k=$1; tp_v=$2
  case "$tp_k" in ro.*) return 1 ;; esac
  grep -q "^$tp_k|" "$TD_PROPSTACK" 2>/dev/null || echo "$tp_k|$(getp "$tp_k")" >> "$TD_PROPSTACK"
  if command -v resetprop >/dev/null 2>&1; then resetprop "$tp_k" "$tp_v" 2>/dev/null; else setprop "$tp_k" "$tp_v" 2>/dev/null; fi
}
td_revert_props() {
  [ -s "$TD_PROPSTACK" ] || { : > "$TD_PROPSTACK"; return 0; }
  while IFS='|' read -r tp_k tp_v; do
    [ -n "$tp_k" ] || continue
    if [ -n "$tp_v" ]; then
      if command -v resetprop >/dev/null 2>&1; then resetprop "$tp_k" "$tp_v" 2>/dev/null; else setprop "$tp_k" "$tp_v" 2>/dev/null; fi
    else resetprop --delete "$tp_k" 2>/dev/null || setprop "$tp_k" "" 2>/dev/null; fi
  done < "$TD_PROPSTACK"
  : > "$TD_PROPSTACK"
}

td_svc_stop() {
  [ "$(getp "init.svc.$1")" = running ] || return 1
  grep -qxF "$1" "$TD_SVCSTACK" 2>/dev/null || echo "$1" >> "$TD_SVCSTACK"
  stop "$1" 2>/dev/null
}
td_revert_services() {
  [ -s "$TD_SVCSTACK" ] || { : > "$TD_SVCSTACK"; return 0; }
  while read -r td_s; do [ -n "$td_s" ] && start "$td_s" 2>/dev/null; done < "$TD_SVCSTACK"
  : > "$TD_SVCSTACK"
}

td_revert_zones() {
  for td_i in $(cat "$TD_EMUL_F" 2>/dev/null); do { echo 0 > "$(zone_dir "$td_i")/emul_temp"; } 2>/dev/null; done
  : > "$TD_EMUL_F"
  for td_i in $(cat "$TD_FROZEN_F" 2>/dev/null); do td_restore_path "$(zone_dir "$td_i")/mode"; done
  : > "$TD_FROZEN_F"
}

# ---------------------------------------------------------------------
# td_apply(): replika thermal_apply() tapi semua tulisan lewat jalur TD_*
# sendiri, supaya tidak pernah ikut dibongkar cleanup_all() milik sesi game.
# ---------------------------------------------------------------------
td_apply() {
  [ "$THERMAL_MODE" = off ] && return 0
  thermal_limits_init
  temps_read
  if [ -z "$T_BATT" ]; then
    log_msg "THERMAL DAILY: sensor baterai tidak terbaca -> apply dibatalkan (tanpa pengaman minimum)"
    flog THERMAL_DAILY ERR "sensor baterai tidak terbaca -> apply dibatalkan (tanpa pengaman minimum)"
    return 1
  fi
  : > "$TD_FROZEN_F"; : > "$TD_EMUL_F"

  while IFS='|' read -r td_s td_st; do [ -n "$td_s" ] && td_svc_stop "$td_s"; done < "$SCANDIR/thermal_services"
  while IFS='|' read -r td_k td_v; do [ -n "$td_k" ] && td_prop_set "$td_k" "$td_v"; done < "$SCANDIR/thermal_props"
  if [ "$(getp ro.build.version.sdk)" -ge 30 ] 2>/dev/null; then
    cmd thermalservice override-status 0 >/dev/null 2>&1 && : > "$RUNDIR/td_thermal_override"
  fi

  if [ "$THERMAL_MODE" = auto ] || [ "$THERMAL_MODE" = hard ]; then
    while IFS='|' read -r td_i td_t td_c td_e td_tp; do
      [ "$td_c" = soc ] || continue
      td_d=$(zone_dir "$td_i")
      if [ "$td_e" = 1 ] && { echo $((INJECT_C * 1000)) > "$td_d/emul_temp"; } 2>/dev/null; then
        td_chk=$(zone_read_c "$td_d")
        if [ "$td_chk" = "$INJECT_C" ]; then echo "$td_i" >> "$TD_EMUL_F"; continue; fi
        { echo 0 > "$td_d/emul_temp"; } 2>/dev/null
      fi
      if [ -e "$td_d/mode" ] && [ "$(read1 "$td_d/mode")" = enabled ]; then
        td_write "$td_d/mode" disabled && echo "$td_i" >> "$TD_FROZEN_F"
      fi
    done < "$SCANDIR/zones"
  fi

  if [ "$THERMAL_MODE" = hard ]; then
    while IFS='|' read -r td_p td_v; do [ -n "$td_p" ] && td_write "$td_p" "$td_v"; done < "$SCANDIR/thermal_vendor"
    if [ "${TRIP_RAISE_C:-0}" -gt 0 ] 2>/dev/null; then
      while IFS='|' read -r td_i td_t td_c td_e td_tp; do
        [ "$td_c" = soc ] && [ "$td_tp" = 1 ] || continue
        td_d=$(zone_dir "$td_i")
        for td_ty in "$td_d"/trip_point_*_type; do
          [ -e "$td_ty" ] || continue
          case "$(read1 "$td_ty")" in passive|active) ;; *) continue ;; esac
          td_tf=${td_ty%_type}_temp
          td_cur=$(read1 "$td_tf")
          case "$td_cur" in ''|*[!0-9]*) continue ;; esac
          td_new=$((td_cur + TRIP_RAISE_C * 1000))
          [ "$td_new" -le 100000 ] || continue
          td_write "$td_tf" "$td_new"
        done
      done < "$SCANDIR/zones"
    fi
  fi

  if [ -s "$TD_FROZEN_F" ] || [ -s "$TD_EMUL_F" ]; then
    temps_read probe
    if [ -z "$T_SOC" ]; then
      log_msg "THERMAL DAILY: suhu asli SoC TIDAK terbaca setelah apply -> batalkan perubahan zona"
      flog THERMAL_DAILY BUG "suhu asli SoC tidak terbaca setelah apply -> perubahan zona dibatalkan"
      td_revert_zones
    fi
  fi
  flog THERMAL_DAILY OK "apply mode=$THERMAL_MODE berhasil (soc=${T_SOC:-?}C batt=${T_BATT}C)"
  log_msg "THERMAL DAILY: apply mode=$THERMAL_MODE (soc=${T_SOC:-?}C batt=${T_BATT}C)"
  return 0
}

td_revert() {
  td_revert_zones
  td_revert_stack
  td_revert_props
  td_revert_services
  if [ -f "$RUNDIR/td_thermal_override" ]; then
    cmd thermalservice reset >/dev/null 2>&1
    rm -f "$RUNDIR/td_thermal_override"
  fi
}

# ---------------------------------------------------------------------
# watchdog lifecycle (lib/tdloop.sh)
# ---------------------------------------------------------------------
td_loop_alive() {
  td_p=$(cat "$RUNDIR/td.pid" 2>/dev/null)
  [ -n "$td_p" ] && kill -0 "$td_p" 2>/dev/null
}
td_loop_start() {
  td_loop_alive && return 0
  nohup sh "$MODDIR/lib/tdloop.sh" >/dev/null 2>&1 &
}
td_loop_stop() {
  td_p=$(cat "$RUNDIR/td.pid" 2>/dev/null)
  [ -n "$td_p" ] && kill "$td_p" 2>/dev/null
  rm -f "$RUNDIR/td.pid"
}

td_on() {
  load_conf
  td_setconf THERMAL_DAILY 1
  td_setconf FEAT_THERMAL 1
  load_conf
  scan_if_needed >/dev/null 2>&1
  td_apply
  td_r=$?
  td_loop_start
  if [ "$td_r" = 0 ]; then
    echo "Thermal Lock Daily: AKTIF (mode $THERMAL_MODE, berlaku non-stop - daily & gaming, tidak lagi direvert otomatis saat game berhenti)"
  else
    echo "Thermal Lock Daily: AKTIF tapi apply pertama ditolak (lihat log - biasanya sensor baterai belum terbaca, atau THERMAL_MODE=off). Watchdog akan mencoba lagi."
  fi
  td_status
}

td_off() {
  load_conf
  td_revert
  td_setconf THERMAL_DAILY 0
  td_loop_stop
  echo "Thermal Lock Daily: MATI (dikembalikan ke bawaan). Thermal lock KHUSUS saat main game tetap jalan seperti biasa kalau fitur A di tab Fitur masih ON."
  td_status
}

td_status() {
  load_conf
  echo "THERMAL_DAILY=$THERMAL_DAILY  loop=$(td_loop_alive && echo jalan || echo mati)  thermal_mode=$THERMAL_MODE  feat_thermal=$FEAT_THERMAL  game_aktif=$(cat "$RUNDIR/game" 2>/dev/null || echo -)"
}
