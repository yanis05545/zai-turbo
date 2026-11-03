#!/system/bin/sh
# =====================================================================
#  Zyrox v2 - lib/daemon.sh
#  Daemon tunggal + siklus hidup game. Dirancang untuk stabil:
#   * single-instance (pidfile) + supervisor yang restart & membersihkan state
#   * deteksi game murah: pra-filter 'ps' (1 fork ringan) -> dumpsys hanya bila
#     ada proses game hidup; saat main, game dipantau lewat /proc/<pid> (tanpa
#     fork) dan foreground dicek tiap FG_CHECK_INGAME detik
#   * semua dumpsys dibungkus timeout; metode foreground auto-fallback
#   * boot counter (bukan marker) -> tidak ada self-disable palsu saat reboot cepat
# =====================================================================

GAMES_DEFAULT="com.mobile.legends com.tencent.ig com.pubg.imobile com.pubg.krmobile com.vng.pubgmobile com.rekoo.pubgm com.miHoYo.GenshinImpact com.miHoYo.hkrpg com.HoYoverse.hkrpgoversea com.HoYoverse.Nap com.activision.callofduty.shooter com.garena.game.codm com.dts.freefireth com.dts.freefiremax com.konami.efootball.pes.mobile com.winlator com.roblox.client com.mojang.minecraftpe com.kurogame.wutheringwaves.global com.levelinfinite.sgameGlobal com.supercell.brawlstars com.proximabeta.mf.uamo"

GAME_PKG=""; GAME_PID=""; COOL_UNTIL=0; PS_OK=0; DAEMON_QUIT=0
FG_PKG=""

games_build() {
  { for gb in $GAMES_DEFAULT; do echo "$gb"; done
    [ -n "$EXTRA_GAME_PACKAGES" ] && echo "$EXTRA_GAME_PACKAGES" | tr ',' '\n'
    [ -f "$DATADIR/games.user" ] && cat "$DATADIR/games.user"
  } | sed 's/[[:space:]]//g' | grep -E '^[A-Za-z0-9_.]+$' | sort -u > "$RUNDIR/games.list"
}

is_game_pkg() { grep -qxF "$1" "$RUNDIR/games.list" 2>/dev/null; }

running_games() { ps -A -o NAME 2>/dev/null | grep -F -x -f "$RUNDIR/games.list" 2>/dev/null; }

ps_selftest() { ps -A -o NAME 2>/dev/null | grep -qx 'system_server' && PS_OK=1 || PS_OK=0; }

system_alive() {
  [ -n "$(pidof surfaceflinger 2>/dev/null)" ] || return 1
  [ -n "$(pidof system_server 2>/dev/null)" ] || return 1
  return 0
}

# foreground app -> FG_PKG (tanpa subshell supaya FG_METHOD yang berhasil diingat)
fg_get() {
  FG_PKG=$(fg_try "${FG_METHOD:-1}")
  [ -n "$FG_PKG" ] && return 0
  for fgm in 1 2 3 4; do
    [ "$fgm" = "${FG_METHOD:-0}" ] && continue
    FG_PKG=$(fg_try "$fgm")
    [ -n "$FG_PKG" ] && { FG_METHOD=$fgm; log_msg "FG: metode foreground beralih ke $fgm"; return 0; }
  done
  return 1
}

game_pid() { set -- $(pidof "$1" 2>/dev/null); echo "$1"; }

# ---------------------------------------------------------------------
# Siklus hidup game
# ---------------------------------------------------------------------
start_game() {
  GAME_PKG=$1; GAME_PID=$2
  preset_params
  thermal_limits_init
  : > "$RUNDIR/writes"
  log_msg "GAME START $GAME_PKG pid=$GAME_PID | tier=$TIER soc=$SOC_VENDOR preset=$PRESET($PRESET_EFF) cap=$LV_CAP start=$LV_START"
  # gfx_apply_game (Graphics API per-game) DIHAPUS v2.0: Graphics API sekarang
  # toggle UNIVERSAL non-stop (lib/gfxapi.sh gu_on/gu_off), tidak lagi dipicu
  # per sesi game lewat start_game() - lihat gu_on() & blok boot di service.sh.
  for sg_fn in thermal_apply perf_sched_apply perf_fpsgo_apply log_reduce_apply perf_touch_apply \
               perf_io_apply refresh_apply network_apply ram_apply dnd_apply freeze_apply; do
    if ! system_alive; then
      log_msg "STAGE: system tidak responsif sebelum $sg_fn -> batalkan & cooldown"
      flog GAMEBOOST ERR "system tidak responsif sebelum $sg_fn -> boost dibatalkan, cooldown ${COOLDOWN_SEC}s"
      stop_game "system tidak responsif"; COOL_UNTIL=$(( $(uptime_s) + COOLDOWN_SEC )); return 1
    fi
    # Thermal Lock Daily (lib/thermaldaily.sh) sudah mengunci thermal lock/inject
    # lewat jalur TD_* sendiri, non-stop (daily + gaming) - thermal_apply sesi
    # game di sini jadi dobel kalau dipanggil juga, jadi dilewati saja.
    # nama fitur + flag Fitur untuk log per fitur (flog, lib/core.sh)
    case "$sg_fn" in
      thermal_apply)      sg_ft=THERMAL;   sg_fl=FEAT_THERMAL ;;
      perf_sched_apply)   sg_ft=SCHEDULER; sg_fl=FEAT_SCHED ;;
      perf_fpsgo_apply)   sg_ft=FPSGO;     sg_fl=FEAT_FPSGO_TUNE ;;
      log_reduce_apply)   sg_ft=LOGREDUCE; sg_fl=FEAT_LOG_REDUCE ;;
      perf_touch_apply)   sg_ft=TOUCHBOOST; sg_fl=FEAT_TOUCH ;;
      perf_io_apply)      sg_ft=IOTUNE;    sg_fl=FEAT_IO ;;
      refresh_apply)      sg_ft=REFRESH;   sg_fl=FEAT_REFRESH ;;
      network_apply)      sg_ft=NETWORK;   sg_fl=FEAT_NETWORK ;;
      ram_apply)          sg_ft=RAM;       sg_fl=FEAT_RAM ;;
      dnd_apply)          sg_ft=DND;       sg_fl=FEAT_DND_INGAME ;;
      freeze_apply)       sg_ft=FREEZE;    sg_fl=FEAT_FREEZE_INGAME ;;
      *)                  sg_ft=MISC;      sg_fl= ;;
    esac
    if [ "$sg_fn" = thermal_apply ] && [ "$THERMAL_DAILY" = 1 ]; then
      log_msg "STAGE: thermal_apply dilewati (Thermal Lock Daily sudah aktif)"
      flog "$sg_ft" INFO "dilewati saat game $GAME_PKG: Thermal Lock Daily sudah aktif (non-stop)"
    else
      sg_rj0=$(grep -c '^rej' "$RUNDIR/writes" 2>/dev/null); sg_rj0=${sg_rj0:-0}
      "$sg_fn"; sg_rc=$?
      sg_rj1=$(grep -c '^rej' "$RUNDIR/writes" 2>/dev/null); sg_rj1=${sg_rj1:-0}
      [ "$sg_rc" = 0 ] || log_msg "STAGE: $sg_fn rc=$sg_rc (fitur dilewati, lanjut)"
      sg_on=1; [ -n "$sg_fl" ] && eval "sg_on=\$$sg_fl"
      if [ "$sg_rc" != 0 ]; then
        flog "$sg_ft" ERR "$sg_fn gagal rc=$sg_rc saat game $GAME_PKG (fitur dilewati, game tetap lanjut)"
      elif [ "$sg_on" != 1 ]; then
        flog "$sg_ft" INFO "dilewati: fitur dimatikan di tab Fitur ($sg_fl=$sg_on)"
      elif [ "$sg_rj1" -gt "$sg_rj0" ] 2>/dev/null; then
        flog "$sg_ft" BUG "$sg_fn diterapkan untuk $GAME_PKG tapi $((sg_rj1 - sg_rj0)) tulisan ditolak kernel (dikunci vendor?)"
      else
        flog "$sg_ft" OK "$sg_fn berhasil diterapkan untuk $GAME_PKG"
      fi
    fi
    [ "$STAGE_STEP_DELAY" -gt 0 ] && sleep "$STAGE_STEP_DELAY"
  done
  perf_set_level "$LV_START"
  perf_priority_apply "$GAME_PID"
  fse_reset "$GAME_PKG"
  # Downscale per-game (lib/downscale.sh) - opt-in, cuma jalan kalau game
  # ini punya nilai tersimpan di downscale.conf (diam2 skip kalau tidak ada,
  # tidak ikut alur flog OK/ERR fitur universal supaya tidak salah kesan
  # "fitur diterapkan" untuk game yang memang belum diset downscale-nya).
  downscale_apply
  # Frame Rate (FPS) per game (lib/gamefps.sh) - sesudah downscale supaya rasio downscale ikut terkirim di perintah yang sama.
  gamefps_apply
  # Abaikan Keamanan Kernel (lib/killsec.sh) - diterapkan PALING TERAKHIR,
  # setelah perf_set_level, supaya kuncian min=max ke plafon tertinggi tidak
  # ditimpa balik oleh floor dinamis FSE/LV_CAP. Tidak melakukan apa pun
  # kalau toggle AKS_ON mati (no-op, lihat aks_apply).
  aks_apply
  # Cooling SoC (lib/cooling.sh) - siaga per game; plafon baru turun saat suhu SoC asli >= pemicu level slider.
  cool_start
  HOT_SINCE=0; THERM_STATE=0; NEXT_MON=0; NEXT_FG=$(( $(uptime_s) + FG_CHECK_INGAME ))
  sg_ok=$(grep -c '^ok' "$RUNDIR/writes" 2>/dev/null); sg_df=$(grep -c '^diff' "$RUNDIR/writes" 2>/dev/null); sg_rj=$(grep -c '^rej' "$RUNDIR/writes" 2>/dev/null)
  log_msg "GAME START selesai: tulis ok=$sg_ok dibulatkan-kernel=$sg_df ditolak=$sg_rj"
  if [ "${sg_rj:-0}" -gt 0 ] 2>/dev/null; then
    flog GAMEBOOST BUG "game $GAME_PKG: boost aktif tapi ditolak=$sg_rj (ok=$sg_ok dibulatkan-kernel=$sg_df) - cek log fitur terkait"
  else
    flog GAMEBOOST OK "game $GAME_PKG: boost aktif (tulis ok=$sg_ok dibulatkan-kernel=$sg_df ditolak=0)"
  fi
  echo "$GAME_PKG" > "$RUNDIR/game"
  notify "Gaming mode ON: $GAME_PKG (preset $PRESET_EFF, tier $TIER)"
}

stop_game() {
  log_msg "GAME STOP ${GAME_PKG:-?} ($1)"
  flog GAMEBOOST INFO "game ${GAME_PKG:-?} berhenti ($1), semua tweak direstore"
  # Cooling SoC dilepas DULUAN (backup-nya snapshot saat game aktif) - baru cleanup_all yang
  # mengembalikan ke nilai pabrik, jadi urutan restore tetap benar.
  cool_revert
  # Downscale (lib/downscale.sh): wm size/density itu override GLOBAL, bukan
  # per-app seperti GameManagerService dulu - WAJIB dikembalikan ke resolusi/
  # density asli di sini, tanpa syarat, begitu game berhenti (no-op kalau
  # memang tidak ada override aktif).
  downscale_revert
  # Frame Rate per game: lepas batas FPS / kunci Hz sesi ini SEBELUM cleanup_all (refresh_revert memulihkan nilai asli).
  gamefps_revert
  cleanup_all
  # AKS (lib/killsec.sh) pakai backup KHUSUS overclock.sh (OCSTACK/
  # OCBACKUPDIR), bukan $STACK - cleanup_all() DI ATAS tidak menyentuhnya
  # sama sekali, jadi harus dilepas eksplisit di sini supaya kuncian AKS
  # ikut berakhir begitu game berhenti (TIDAK permanen, sesuai desain).
  aks_revert
  # Touch Boost (lib/perf.sh): fpsgo_enable/ged_boost_enable/boost_gpu_enable/
  # gx_boost_enable WAJIB 0 begitu game berhenti - dipaksa eksplisit di sini,
  # bukan cuma ikut revert_stack biasa (lihat perf_touch_revert).
  perf_touch_revert
  # DND In-Game (lib/dnd.sh) & Freeze In-Game (lib/freeze.sh): Settings.Global
  # zen_mode dan app yang dibekukan BUKAN node sysfs, tidak ikut $STACK/
  # cleanup_all - dilepas eksplisit di sini, sama pola dengan perf_touch_revert
  # di atas. Aman dipanggil walau togglenya mati/tidak pernah aktif (no-op).
  dnd_revert
  freeze_revert
  GAME_PKG=""; GAME_PID=""
  rm -f "$RUNDIR/game"
  [ -n "$2" ] && notify "$2"
}

# ---------------------------------------------------------------------
# Tick
# ---------------------------------------------------------------------
NEXT_MON=0; NEXT_FG=0; NEXT_AKS=0

tick_ingame() {
  if [ ! -d "$R/proc/$GAME_PID" ]; then stop_game "proses game berakhir" "Gaming mode OFF, direstore"; return; fi
  if [ "$MODE" = off ]; then stop_game "mode off" "Gaming mode OFF (manual)"; return; fi
  now=$(uptime_s)
  # poin 5: mode hard dipantau lebih sering (HARD_MON_SEC) karena lebih banyak
  # proteksi vendor dimatikan -> suhu bisa naik lebih cepat di antara polling.
  ti_mon=4; [ "$THERMAL_MODE" = hard ] && ti_mon=$HARD_MON_SEC
  if [ "$FEAT_TEMP_MONITOR" = 1 ] && [ "$now" -ge "$NEXT_MON" ]; then
    NEXT_MON=$((now + ti_mon))
    temps_read probe
    thermal_eval
    echo "$T_SOC|$T_BATT|$T_SKIN|$THERM_STATE" > "$RUNDIR/temps"
    if [ "$THERM_STATE" -ge 2 ]; then
      ti_lim=$SAFE_HOT_SECONDS; [ "$THERMAL_MODE" = hard ] && ti_lim=$HARD_SAFE_HOT_SECONDS
      log_msg "SAFETY: $THERM_WHY (ambang ${ti_lim}s, mode $THERMAL_MODE) -> boost dimatikan, cooldown ${COOLDOWN_SEC}s"
      flog THERMAL BUG "safety trip: $THERM_WHY (ambang ${ti_lim}s, mode $THERMAL_MODE) -> boost dimatikan, cooldown ${COOLDOWN_SEC}s"
      stop_game "thermal" "Suhu tinggi ($THERM_WHY) - boost dimatikan otomatis"
      COOL_UNTIL=$(( $(uptime_s) + COOLDOWN_SEC ))
      # poin 5: setelah safety trip di mode hard, turunkan otomatis ke auto
      # untuk sisa sesi - mode hard harus dipilih ulang secara sadar, tidak
      # otomatis dicoba lagi dengan ambang yang sama persis setelah cooldown.
      if [ "$HARD_TRIPPED" = 1 ] && [ "$HARD_DEMOTE_AFTER_TRIP" = 1 ]; then
        if grep -q '^THERMAL_MODE=' "$CONF" 2>/dev/null; then
          sed -i 's/^THERMAL_MODE=.*/THERMAL_MODE=auto/' "$CONF" 2>/dev/null
        else
          echo "THERMAL_MODE=auto" >> "$CONF"
        fi
        THERMAL_MODE=auto; HARD_TRIPPED=0
        # kalau yang memaksa hard itu Bypass Thermal, lepas juga kuncinya supaya
        # Disable Thermal tidak ikut terkunci permanen gara-gara safety trip ini,
        # dan status di WebUI tidak bohong bilang bypass masih aktif.
        if [ "$BYPASS_THERMAL" = 1 ]; then
          by_setconf BYPASS_THERMAL 0; by_setconf BYPASS_PREV_MODE ""
          BYPASS_THERMAL=0
          log_msg "SAFETY: Bypass Thermal ikut dimatikan otomatis (safety trip)"
        fi
        log_msg "SAFETY: thermal hard -> diturunkan ke auto otomatis (safety trip). Pilih 'hard' lagi secara manual kalau tetap mau dipakai."
        notify "Zyrox: mode thermal 'hard' dimatikan otomatis karena overheat, diturunkan ke 'auto'"
      fi
      return
    fi
  fi
  if [ "$now" -ge "$NEXT_FG" ]; then
    NEXT_FG=$((now + FG_CHECK_INGAME))
    if fg_get && [ "$FG_PKG" != "$GAME_PKG" ]; then
      if [ "$MODE" = on ]; then
        # FIX: dulu blok foreground-recheck ini di-skip TOTAL selama MODE=on
        # ("Paksa ON"), jadi kalau tombol itu ditekan SEBELUM game dibuka
        # (mis. masih di launcher), boost nyangkut selamanya di app yang
        # kebetulan foreground saat tombol ditekan - begitu game sungguhan
        # dibuka, boost TIDAK PERNAH pindah ke situ karena blok ini dulu
        # tidak pernah dicek ulang. Ini akar masalah "gamelock/Paksa ON tidak
        # bisa diaktifkan sebelum main game".
        # Sekarang: tetap ikuti perpindahan foreground walau MODE=on, tapi
        # PINDAHKAN boost ke app baru (bukan dimatikan) - jadi "Paksa ON"
        # boleh ditekan kapan saja termasuk sebelum main, dan begitu game
        # sungguhan masuk foreground, boost otomatis mengikuti ke situ.
        ti_npid=$(game_pid "$FG_PKG")
        if [ -n "$ti_npid" ]; then
          log_msg "FORCE: foreground pindah $GAME_PKG -> $FG_PKG, pindahkan boost"
          cleanup_all
          start_game "$FG_PKG" "$ti_npid"
        fi
        return
      fi
      stop_game "game keluar dari foreground ($FG_PKG)" "Gaming mode OFF, direstore"
      return
    fi
  fi
  # AKS (lib/killsec.sh): dijaga ulang tiap ~5 dtk selama game berjalan,
  # sama pola dengan ml_watch/tk_watch - daemon perf/thermal vendor lain
  # bisa menulis ulang node yang sama, jadi kuncian perlu diterapkan ulang
  # berkala, bukan cuma sekali saat start_game. No-op kalau AKS_ON mati.
  if [ "$now" -ge "$NEXT_AKS" ]; then NEXT_AKS=$((now + 5)); aks_watch; fi
  fse_tick
  # Cooling SoC PALING AKHIR - plafon pendinginan harus menang atas FSE/AKS di tick yang sama.
  cool_tick
}

tick_idle() {
  [ "$MODE" = off ] && return 0
  now=$(uptime_s)
  [ "$now" -lt "$COOL_UNTIL" ] && return 0
  if [ "$MODE" != on ] && [ "$PS_OK" = 1 ]; then
    [ -n "$(running_games)" ] || return 0
  fi
  fg_get || return 0
  if [ "$MODE" = on ] || is_game_pkg "$FG_PKG"; then
    ti_pid=$(game_pid "$FG_PKG")
    [ -n "$ti_pid" ] || return 0
    # jangan mulai kalau device masih panas (setelah cooldown)
    temps_read
    if { [ -n "$T_SOC" ] && [ "$T_SOC" -ge $((SOC_LIM - 6)) ]; } || { [ -n "$T_BATT" ] && [ "$T_BATT" -ge $((BATT_LIM - 2)) ]; }; then
      log_msg "START ditunda: device masih panas (soc=${T_SOC:-?} batt=${T_BATT:-?})"
      COOL_UNTIL=$((now + 30)); return 0
    fi
    start_game "$FG_PKG" "$ti_pid"
  fi
}

# ---------------------------------------------------------------------
# Boot guard
# ---------------------------------------------------------------------
boot_commit_bg() {
  (
    bc_n=0
    while [ "$(getprop sys.boot_completed)" != 1 ] && [ "$bc_n" -lt 180 ]; do sleep 2; bc_n=$((bc_n + 2)); done
    sleep "$BOOT_OK_DELAY"
    if system_alive; then
      echo 0 > "$DATADIR/boot_count"
      log_msg "BOOT: sukses, boot_count direset"
      flog DAEMON OK "boot sukses, boot_count direset"
    else
      log_msg "BOOT: system tidak responsif setelah delay, boot_count TIDAK direset"
    fi
  ) &
}

# ---------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------
daemon_exit() { DAEMON_QUIT=1; }

daemon_main() {
  if [ -f "$RUNDIR/daemon.pid" ]; then
    dm_old=$(cat "$RUNDIR/daemon.pid" 2>/dev/null)
    if [ -n "$dm_old" ] && [ "$dm_old" != "$$" ] && kill -0 "$dm_old" 2>/dev/null; then
      log_msg "DAEMON: sudah berjalan (pid $dm_old), instance ini keluar"
      return 0
    fi
  fi
  echo $$ > "$RUNDIR/daemon.pid"
  trap 'daemon_exit' TERM INT HUP
  trap 'cleanup_all; rm -f "$RUNDIR/daemon.pid"' EXIT

  load_conf
  scan_if_needed
  thermal_limits_init; preset_params
  games_build
  ps_selftest
  log_msg "DAEMON v$TX_VER start pid=$$ | $SOC_VENDOR/$SOC_NAME tier=$TIER ram=${RAM_MB}MB cluster=$N_CLUSTERS gpu=$GPU_BACKEND fpsgo=$HAS_FPSGO ps=$PS_OK"

  dm_w=0
  while [ ! -f "$RUNDIR/safe_done" ] && [ "$dm_w" -lt 20 ]; do sleep 1; dm_w=$((dm_w + 1)); done
  dm_safe=$(cat "$DATADIR/safe_mode" 2>/dev/null)
  case "$dm_safe" in
    skip)
      log_msg "P.3: safe_mode=skip -> daemon idle total (hanya boot_count)"
      boot_commit_bg; return 0 ;;
    cool)
      log_msg "P.3: safe_mode=cool -> preset cool, thermal off"
      PRESET=cool; THERMAL_MODE=off ;;
  esac
  boot_commit_bg
  # Fitur Overclock sudah dihapus - tidak ada lagi override tersimpan yang
  # perlu diterapkan ulang saat boot (lihat lib/overclock.sh untuk alasan
  # file itu tetap ada: mesin tulis-verifikasi masih dipakai lib/modelock.sh
  # untuk mode-locking yang nyata, bukan untuk fitur overclock itu sendiri).

  dm_i=0
  while [ "$DAEMON_QUIT" = 0 ]; do
    echo "$(uptime_s)" > "$RUNDIR/heartbeat"
    [ -f "$MODDIR/disable" ] || [ -f "$MODDIR/remove" ] && { log_msg "DAEMON: module disabled/removed, berhenti"; break; }
    [ -f "$RUNDIR/stop" ] && { log_msg "DAEMON: stop diminta CLI"; break; }
    MODE=$(cat "$DATADIR/mode_state" 2>/dev/null); MODE=${MODE:-auto}
    dm_i=$((dm_i + 1)); [ $((dm_i % 200)) = 0 ] && log_rotate
    # v1.0.9: pastikan penjaga Disable Thermal hidup (tiap ~30 dtk saat idle) - kalau mati/ter-kill, dihidupkan lagi
    # v1.0.9-fix4: fallback dulu ":-1" (anggap AKTIF) kalau sed gagal/baris
    # belum ada di conf - padahal default modul (azenith-ai.conf.default)
    # adalah THERMAL_KILL=0 (opt-in). Kalau parsing ini kebetulan kosong
    # (race baca saat conf sedang ditulis ulang, atau baris belum sempat
    # disalin dari default), tk_watch bisa salah menyalakan penjaga
    # Disable Thermal yang agresif (stop/kill -9 service *thermal* tiap
    # beberapa detik) padahal user TIDAK PERNAH mengaktifkannya - ini
    # persis subsistem yang di changelog modul sendiri disebut sumber
    # crash + jaringan putus di chipset combo-HAL. Fallback dibetulkan ke
    # 0 supaya cuma benar-benar menyala kalau conf memang bilang begitu.
    [ -z "$GAME_PKG" ] && [ $((dm_i % 10)) = 0 ] && { THERMAL_KILL=$(sed -n 's/^THERMAL_KILL=\([^ #]*\).*/\1/p' "$DATADIR/azenith-ai.conf" 2>/dev/null | tail -n 1); THERMAL_KILL=${THERMAL_KILL:-0}; tk_watch; }
    # v1.0.9-fix23: watchdog Battery Saver (lib/powersave.sh) - jaga low_power
    # tetap sesuai mode thermal aktif (saver=ON, lainnya=OFF) SECARA REAL-TIME,
    # berjalan terus baik idle MAUPUN sedang in-game (tidak digerbang GAME_PKG
    # seperti tk_watch di atas), supaya tidak ada jeda rasa saat sesi gaming.
    [ $((dm_i % 3)) = 0 ] && ps_watch
    # Perf Lite (lib/perflite.sh): jaga kunci mode + swappiness/vfs, FSTrim saat layar mati lama.
    # Tiap ~10 tick (dumpsys power tidak murah), tidak digerbang game: ringan.
    [ $((dm_i % 10)) = 0 ] && pl_watch
    # Core CPU offline (lib/cpucore.sh): tegakkan lagi core yang dimatikan user kalau dihidupkan PowerHAL/thermal vendor.
    # Hanya membaca node bila ada grup yang dimatikan -> ringan; conf dibaca ulang tiap ~10 tick.
    if [ $((dm_i % 10)) = 5 ]; then CC_OFF_LIST=$(sed -n 's/^CC_OFF_LIST=\([^ #]*\).*/\1/p' "$DATADIR/azenith-ai.conf" 2>/dev/null | tail -n 1); cc_watch; fi
    # Fast Charger: pengaman suhu baterai (lib/charge.sh fc_watch), jalan juga saat in-game.
    [ $((dm_i % 10)) = 0 ] && fc_watch
    # v1.0.9-fix25: watchdog ceiling/floor CPU & GPU (lib/modelock.sh) - jaga
    # supaya tidak ditimpa balik oleh daemon perf/thermal vendor beberapa detik
    # setelah mode ditekan (lihat catatan panjang di ml_watch). HANYA saat idle
    # (tidak ada game terdeteksi) - saat game aktif, lib/perf.sh (LV_CAP) yang
    # pegang kendali floor dinamis, menimpanya dari sini akan tabrakan.
    [ -z "$GAME_PKG" ] && [ $((dm_i % 3)) = 0 ] && ml_watch
    # konfigurasi bisa diubah user kapan saja (WebUI/CLI): baca ulang tiap 30 tick, hanya saat idle
    if [ -z "$GAME_PKG" ] && [ $((dm_i % 30)) = 0 ]; then load_conf; thermal_limits_init; preset_params; games_build; fi
    if [ -n "$GAME_PKG" ]; then tick_ingame; sleep "$FPS_TICK"
    else tick_idle; sleep "$POLL_INTERVAL"; fi
  done
  [ -n "$GAME_PKG" ] && stop_game "daemon berhenti" "Gaming mode OFF, direstore"
  return 0
}
