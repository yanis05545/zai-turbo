#!/system/bin/sh
# =====================================================================
#  Zyrox v2 - lib/core.sh
#  Fondasi: path, logging, konfigurasi, safe_write (backup+verifikasi+stack),
#  prop/service stack, helper kecil. Di-source oleh semua komponen lain.
#
#  Variabel TX_ROOT (default kosong) hanya untuk pengujian di sysfs tiruan;
#  di device asli selalu kosong sehingga path = /sys, /proc, /dev asli.
# =====================================================================

TX_VER=1.0.9
R="${TX_ROOT:-}"
MODDIR="${MODDIR:-/data/adb/modules/azenith-ai}"
DATADIR="${TX_DATA:-/data/adb/azenith-ai}"
BACKUPDIR="$DATADIR/backup"
SCANDIR="$DATADIR/scan"
RUNDIR="$DATADIR/run"
CONF="$DATADIR/azenith-ai.conf"
LOG="$DATADIR/log.txt"
STACK="$DATADIR/applied_stack"      # satu path sysfs per baris
PROPSTACK="$DATADIR/props_stack"    # key|nilai_lama (kosong = tidak ada)
SVCSTACK="$DATADIR/svc_stack"       # nama service yang kita stop
PROFILE="$SCANDIR/profile.conf"
TESTLOG_DIR="$DATADIR/test_logs"    # hasil azenith-ai test <fitur> (file teks per fitur)
FLOG_DIR="$DATADIR/feature_logs"    # log TERPUSAT per fitur: <FITUR>.log + ALL.log (level OK/ERR/BUG/INFO)

mkdir -p "$DATADIR" "$BACKUPDIR" "$SCANDIR" "$RUNDIR" "$TESTLOG_DIR" "$FLOG_DIR" 2>/dev/null

# ---------------------------------------------------------------------
# Logging (dengan rotasi supaya tidak memenuhi /data)
# ---------------------------------------------------------------------
log_msg() {
  printf '%s %s\n' "$(date '+%m-%d %H:%M:%S')" "$*" >> "$LOG" 2>/dev/null
}

# ---------------------------------------------------------------------
# Log hasil TEST per fitur (file teks terpisah dari log.txt biasa) - dipakai
# oleh *_test() di tiap lib (gfxapi/perf/cleaner/charge) supaya hasil "uji
# coba manual" bisa dibaca langsung dari file, bukan cuma lewat `azenith-ai
# log` yang isinya campur semua subsistem. Tiap panggilan test_begin()
# menimpa file lama (hasil terbaru saja), isinya nilai NYATA yang dibaca
# balik dari kernel/sistem (bukan "sudah dicoba tulis" doang) - supaya bisa
# dipakai membuktikan sebuah fitur benar2 bekerja atau cuma gimik kosmetik.
# (TESTLOG_DIR sendiri sudah dibuat di atas, bareng DATADIR/RUNDIR/dst,
# supaya foldernya langsung ada begitu module di-load - tidak perlu
# menunggu `azenith-ai test ...` dijalankan dulu baru foldernya muncul.)
# ---------------------------------------------------------------------
testlog_begin() { # testlog_begin <nama_fitur>
  mkdir -p "$TESTLOG_DIR" 2>/dev/null
  TESTLOG_FILE="$TESTLOG_DIR/$1.txt"
  { echo "=== TEST: $1 ==="; echo "waktu: $(date '+%Y-%m-%d %H:%M:%S')"; echo ""; } > "$TESTLOG_FILE" 2>/dev/null
}

testlog() { # testlog <baris...>  - tulis satu baris ke file test yang sedang aktif
  [ -n "$TESTLOG_FILE" ] && echo "$*" >> "$TESTLOG_FILE" 2>/dev/null
}

testlog_end() { # testlog_end - tutup & cetak isi file ke stdout (ikut muncul di CLI/WebUI)
  # ringkas hasil uji ke log per fitur (flog): marker NYATA-BEKERJA = OK, GAGAL/GIMIK/PERLU DICEK = BUG
  te_n=$(basename "$TESTLOG_FILE" .txt 2>/dev/null | tr 'a-z' 'A-Z' | tr -c 'A-Z0-9_\n' '_')
  te_ok=$(grep -c 'NYATA-BEKERJA' "$TESTLOG_FILE" 2>/dev/null); te_bg=$(grep -cE 'GAGAL/GIMIK|PERLU DICEK' "$TESTLOG_FILE" 2>/dev/null)
  if [ "${te_bg:-0}" -gt 0 ] 2>/dev/null; then flog "TEST_${te_n:-FITUR}" BUG "uji selesai: ${te_ok:-0} bekerja, $te_bg perlu dicek/gagal -> $TESTLOG_FILE"
  elif [ "${te_ok:-0}" -gt 0 ] 2>/dev/null; then flog "TEST_${te_n:-FITUR}" OK "uji selesai: $te_ok pemeriksaan nyata lulus -> $TESTLOG_FILE"
  else flog "TEST_${te_n:-FITUR}" INFO "uji selesai (tanpa marker hasil) -> $TESTLOG_FILE"; fi
  echo "" >> "$TESTLOG_FILE" 2>/dev/null
  echo "file log: $TESTLOG_FILE" >> "$TESTLOG_FILE" 2>/dev/null
  cat "$TESTLOG_FILE" 2>/dev/null
}

# ---------------------------------------------------------------------
# LOG PER FITUR (terpusat) - satu pintu untuk SEMUA fitur.
#
#   flog <FITUR> <LEVEL> <pesan...>
#
#   LEVEL:
#     OK   = BERHASIL  - fitur diterapkan & hasilnya terverifikasi
#     ERR  = ERROR     - fitur gagal / ditolak / perintah keluar dengan rc != 0
#     BUG  = BUG       - anomali: diterapkan tapi ada yang tidak sesuai
#                        (read-back beda, ditolak kernel sebagian, dipulihkan
#                        paksa, fallback dipakai, ditimpa pihak lain, dst)
#     INFO = catatan netral (mulai/selesai/dilewati)
#
#   Format baris : "MM-DD HH:MM:SS [FITUR] [LEVEL] pesan"
#   Tujuan tulis : $FLOG_DIR/<FITUR>.log  (per fitur)
#                  $FLOG_DIR/ALL.log      (semua fitur, urut waktu)
#                  $LOG (log.txt)         (supaya `azenith-ai log` tetap lengkap)
#   Rotasi       : tiap file > 64KB -> jadi .old (maks 1 generasi), aman untuk /data.
#
#   Cara baca    : azenith-ai flog [fitur|all] [ok|err|bug|info] [jumlah]
#                  azenith-ai flog list | summary | clear [fitur]
# ---------------------------------------------------------------------
flog() { # flog <FITUR> <OK|ERR|BUG|INFO> <pesan...>
  fl_f=$1; fl_l=$2; shift 2 2>/dev/null
  # nama fitur dipakai sebagai nama file -> hanya huruf/angka/_ (cegah path aneh)
  case "$fl_f" in ''|*[!A-Za-z0-9_]*) fl_f=MISC ;; esac
  case "$fl_l" in OK|ERR|BUG|INFO) ;; *) fl_l=INFO ;; esac
  fl_msg=$(printf '%s' "$*" | tr '\n\r' '  ' | cut -c1-400)
  fl_line="$(date '+%m-%d %H:%M:%S') [$fl_f] [$fl_l] $fl_msg"
  mkdir -p "$FLOG_DIR" 2>/dev/null
  for fl_t in "$FLOG_DIR/$fl_f.log" "$FLOG_DIR/ALL.log"; do
    printf '%s\n' "$fl_line" >> "$fl_t" 2>/dev/null
    fl_sz=$(wc -c < "$fl_t" 2>/dev/null); fl_sz=${fl_sz:-0}
    if [ "$fl_sz" -gt 65536 ] 2>/dev/null; then
      mv -f "$fl_t" "$fl_t.old" 2>/dev/null
      : > "$fl_t" 2>/dev/null
    fi
  done
  log_msg "[$fl_f] [$fl_l] $fl_msg"
  return 0
}

# flog_judge <FITUR> <aksi> <rc> <berkas_output>
# Menilai hasil sebuah perintah fitur lalu mencatatnya sebagai OK/ERR/BUG:
#   rc != 0                                  -> ERR
#   rc == 0 tapi output memuat kata gagal    -> BUG (jalan, tapi ada yang tidak beres)
#   selain itu                               -> OK
flog_judge() {
  fj_f=$1; fj_a=$2; fj_rc=$3; fj_o=$4
  fj_first=$(grep -v '^[[:space:]]*$' "$fj_o" 2>/dev/null | head -n 1 | cut -c1-220)
  if [ "$fj_rc" != 0 ]; then
    flog "$fj_f" ERR "$fj_a gagal rc=$fj_rc | ${fj_first:-tanpa output}"
    return 0
  fi
  # hitungan nol ("0 gagal", "0 error", "0 ditolak") BUKAN anomali -> dibuang dulu sebelum dicari kata gagalnya
  fj_bad=$(sed -E 's/(^|[^0-9])0 (gagal|GAGAL|error|ditolak)/\1/g' "$fj_o" 2>/dev/null | grep -iE 'peringatan|ditolak|gagal|tidak terbaca|melenceng|apply pertama|rejected|error' | head -n 1 | cut -c1-220)
  if [ -n "$fj_bad" ]; then
    flog "$fj_f" BUG "$fj_a jalan tapi ada anomali | $fj_bad"
  else
    flog "$fj_f" OK "$fj_a berhasil | ${fj_first:-selesai}"
  fi
  return 0
}

# flog_run <FITUR> <aksi> <perintah...>
# Jalankan perintah/fungsi apa adanya (output & rc TIDAK diubah, tetap tampil ke
# layar/WebUI) sambil mencatat hasilnya ke log fitur.
flog_run() {
  fr_f=$1; fr_a=$2; shift 2
  fr_t="$RUNDIR/flog_out.$$"
  flog "$fr_f" INFO "$fr_a dimulai"
  "$@" > "$fr_t" 2>&1
  fr_rc=$?
  cat "$fr_t" 2>/dev/null
  flog_judge "$fr_f" "$fr_a" "$fr_rc" "$fr_t"
  rm -f "$fr_t" 2>/dev/null
  return $fr_rc
}

log_rotate() {
  [ -f "$LOG" ] || return 0
  lr_sz=$(wc -c < "$LOG" 2>/dev/null); lr_sz=${lr_sz:-0}
  if [ "$lr_sz" -gt 262144 ] 2>/dev/null; then
    mv -f "$LOG" "$LOG.old" 2>/dev/null
    : > "$LOG"
  fi
}

uptime_s() {
  { read -r up_a up_b < "$R/proc/uptime"; } 2>/dev/null
  echo "${up_a%.*}"
}

# ---------------------------------------------------------------------
# Konfigurasi
# ---------------------------------------------------------------------
num_or() { # num_or VARNAME DEFAULT  -> pastikan variabel numerik
  eval "nv_cur=\$$1"
  case "$nv_cur" in
    ''|*[!0-9]*) eval "$1=$2" ;;
  esac
}

load_conf() {
  if [ ! -f "$CONF" ] && [ -f "$MODDIR/azenith-ai.conf.default" ]; then
    cp "$MODDIR/azenith-ai.conf.default" "$CONF" 2>/dev/null
  fi
  [ -f "$CONF" ] && . "$CONF"
  CONF_VERSION=${CONF_VERSION:-2}
  PRESET=${PRESET:-auto}                    # auto|cool|balanced|extreme
  THERMAL_MODE=${THERMAL_MODE:-auto}        # off|soft|auto|hard
  THERMAL_KILL=${THERMAL_KILL:-0}           # v1.0.41: HANYA 1 selama mode ZAI-Turbo (extreme) aktif; 0 di mode lain (lib/thermalkill.sh)
  BYPASS_THERMAL=${BYPASS_THERMAL:-0}       # 1 = mode hard dipaksa; tidak bisa aktif selama THERMAL_KILL=1 (lib/bypass.sh)
  BYPASS_PREV_MODE=${BYPASS_PREV_MODE:-}    # THERMAL_MODE sebelum bypass, dipakai untuk kembalikan saat bypass off
  THERMAL_DAILY=${THERMAL_DAILY:-0}         # 1 = thermal lock/inject (fitur A) berlaku NON-STOP (daily + gaming),
                                             # bukan cuma selama sesi game (lib/thermaldaily.sh) - independen dari
                                             # THERMAL_KILL (tidak ditolak seperti Bypass Thermal)
  AKS_ON=${AKS_ON:-0}                       # Abaikan Keamanan Kernel - 1 = kunci CPU ke plafon OC tertinggi
                                             # (min=max) HANYA selama game aktif, tidak permanen (lib/killsec.sh)
  TK_BATT_MAX=${TK_BATT_MAX:-45}; TK_SKIN_MAX=${TK_SKIN_MAX:-47}; TK_HOT_SEC=${TK_HOT_SEC:-10}; TK_TICK=${TK_TICK:-2}
  TK_BLOCK=${TK_BLOCK:-1}; TK_BLOCK_AFTER=${TK_BLOCK_AFTER:-2}; TK_KERNEL=${TK_KERNEL:-1}; TK_TRIP_C=${TK_TRIP_C:-90}
  TK_GUARD=${TK_GUARD:-1}                   # 1 = pengaman suhu aktif: panas >= TK_HOT_SEC dtk -> keluar dari ZAI-Turbo
  TK_FORCE_COMBO=${TK_FORCE_COMBO:-0}       # 1 = (ZAI-Turbo) HAL thermal combo-binary juga dimatikan (kill PID service itu saja)
  GAMEFPS_ALL=${GAMEFPS_ALL:-0}             # 1 = SEMUA game dipaksa GAMEFPS_ALL_FPS (default 120) bila tak punya data FPS sendiri
  GAMEFPS_ALL_FPS=${GAMEFPS_ALL_FPS:-120}
  FEAT_THERMAL=${FEAT_THERMAL:-1}
  FEAT_TEMP_MONITOR=${FEAT_TEMP_MONITOR:-1}
  FEAT_FREQ=${FEAT_FREQ:-1}
  FEAT_SCHED=${FEAT_SCHED:-1}
  FEAT_PRIORITY=${FEAT_PRIORITY:-1}
  FEAT_FPS_ENGINE=${FEAT_FPS_ENGINE:-1}
  FEAT_FPSGO_TUNE=${FEAT_FPSGO_TUNE:-1}
  FEAT_SURFACEFLINGER=${FEAT_SURFACEFLINGER:-1}
  FEAT_LOG_REDUCE=${FEAT_LOG_REDUCE:-1}
  FEAT_TOUCH=${FEAT_TOUCH:-1}                # K: Touch Boost on/off saja (TOUCH_MODE/TOUCH_SENS dihapus)
  FEAT_IO=${FEAT_IO:-1}
  FEAT_COOLING=${FEAT_COOLING:-1}           # Q: Cooling SoC per-game (lib/cooling.sh)
  COOL_STEP_SEC=${COOL_STEP_SEC:-60}; COOL_STEP_PCT=${COOL_STEP_PCT:-10}; COOL_HYST_C=${COOL_HYST_C:-6}
  num_or COOL_STEP_SEC 60; num_or COOL_STEP_PCT 10; num_or COOL_HYST_C 6
  [ "$COOL_STEP_SEC" -lt 10 ] && COOL_STEP_SEC=10
  [ "$COOL_STEP_PCT" -lt 5 ] && COOL_STEP_PCT=5
  [ "$COOL_STEP_PCT" -gt 50 ] && COOL_STEP_PCT=50
  FEAT_REFRESH=${FEAT_REFRESH:-1}
  FEAT_NETWORK=${FEAT_NETWORK:-1}
  FEAT_RAM=${FEAT_RAM:-1}
  SAFE_SOC_C=${SAFE_SOC_C:-auto}
  SAFE_BATT_C=${SAFE_BATT_C:-43}
  SAFE_SKIN_C=${SAFE_SKIN_C:-46}
  SAFE_HOT_SECONDS=${SAFE_HOT_SECONDS:-20}
  COOLDOWN_SEC=${COOLDOWN_SEC:-180}
  INJECT_C=${INJECT_C:-40}
  TRIP_RAISE_C=${TRIP_RAISE_C:-0}
  POLL_INTERVAL=${POLL_INTERVAL:-3}
  FPS_TICK=${FPS_TICK:-2}
  FG_CHECK_INGAME=${FG_CHECK_INGAME:-5}
  FPS_DROP_PCT=${FPS_DROP_PCT:-90}
  FPS_STABLE_SAMPLES=${FPS_STABLE_SAMPLES:-15}
  FPSGO_AUDITION=${FPSGO_AUDITION:-1}
  FPSGO_DISCOVER=${FPSGO_DISCOVER:-1}
  FPSGO_APPLY_UNVERIFIED=${FPSGO_APPLY_UNVERIFIED:-0}
  FPSGO_AB_WARMUP=${FPSGO_AB_WARMUP:-6}
  FPSGO_AB_WINDOW=${FPSGO_AB_WINDOW:-8}
  FPSGO_AB_SETTLE=${FPSGO_AB_SETTLE:-3}
  FPSGO_AB_REG_PCT=${FPSGO_AB_REG_PCT:-3}
  FPSGO_RELEARN_DAYS=${FPSGO_RELEARN_DAYS:-14}
  PRIO_NICE=${PRIO_NICE:--6}
  PRIO_RT=${PRIO_RT:-0}
  RAM_KILL_BG=${RAM_KILL_BG:-1}
  RAM_DROP_CACHES=${RAM_DROP_CACHES:-0}
  # NET_PING_* dipakai internal oleh network_apply/net_ping_loop (lib/misc.sh)
  # HANYA selama game aktif, untuk data monitor avg/jitter/loss - bukan
  # toggle berdiri sendiri (Ping Stabilizer sudah dihapus dari WebUI/CLI).
  NET_PING_LOG=${NET_PING_LOG:-0}
  NET_PING_HOST=${NET_PING_HOST:-8.8.8.8}
  NET_PING_INTERVAL=${NET_PING_INTERVAL:-10}
  # --- Bypass Charging (lib/charge.sh): matikan arus charging SUNGGUHAN lewat
  # node sysfs charger asli (diverifikasi dari status baterai, bukan toggle visual)
  CHARGE_BYPASS=${CHARGE_BYPASS:-0}
  CHARGE_MIN_PCT=${CHARGE_MIN_PCT:-20}   # baterai <= ini -> otomatis dimatikan (anti over-discharge)
  CHARGE_TICK=${CHARGE_TICK:-2}          # watchdog re-assert node (detik) - sengaja pendek (2dtk) supaya
                                          # node yang ditimpa balik oleh Power Manager/thermal daemon vendor
                                          # (banyak HAL mengembalikan nilainya sendiri tiap beberapa detik)
                                          # cepat ditulis ulang, bukan dibiarkan "kebobolan" charging lagi
  CHARGE_VERIFY_TRIES=${CHARGE_VERIFY_TRIES:-3}  # baca ulang status+arus berapa kali (x2dtk) sebelum nyerah
  CHARGE_CUSTOM_NODE=${CHARGE_CUSTOM_NODE:-}      # path node manual hasil 'charge diag' (opsional)
  CHARGE_CUSTOM_METHOD=${CHARGE_CUSTOM_METHOD:-enable}  # enable|suspend|current, dipasangkan dengan node di atas
  # --- Network Booster (lib/netboost.sh): NSS/optimasi TCP-IP + fix latency,
  # persisten (tahan reboot) terpisah dari network_apply/misc.sh yang hanya
  # jalan selagi game aktif. AKTIF -> congestion control bbr3 (fallback
  # NET_CONGESTION/bbr/westwood/cubic), MATI -> dipaksa cubic.
  NETBOOST=${NETBOOST:-0}
  # --- WiFi Low Latency (lib/wifill.sh): fitur TERSENDIRI, bukan bagian Network Booster
  WIFILL=${WIFILL:-0}
  # --- Spoof prosesor (cpu_spoof.sh): resetprop in-memory ro.soc.*, diterapkan tiap boot (menggantikan Spoof GPU)
  SPOOF_CPU=${SPOOF_CPU:-0}
  SPOOF_CPU_PROFILE=${SPOOF_CPU_PROFILE:-}
  # --- Spoof nama perangkat (dev_spoof.sh): resetprop in-memory, diterapkan tiap boot, build.prop asli tidak disentuh
  SPOOF_DEV=${SPOOF_DEV:-0}
  SPOOF_DEV_PROFILE=${SPOOF_DEV_PROFILE:-}
  # --- Perf Lite (lib/perflite.sh): profil ringan, bentrok dengan saver/extreme/Fast Charger
  PERFLITE=${PERFLITE:-0}
  # --- Core CPU online/offline PER CORE (lib/cpucore.sh): CC_OFF_LIST = nomor core offline (koma), CC_BOOT = terapkan ulang saat boot
  CC_OFF_LIST=${CC_OFF_LIST:-}
  CC_BOOT=${CC_BOOT:-0}
  # --- WiFi Tweak (lib/wifitweak.sh) & batas suhu baterai Fast Charger (lib/charge.sh fc_watch)
  WIFITWEAK=${WIFITWEAK:-0}
  # --- Network Pro (lib/netpro.sh): fitur jaringan setara PingPimp, tiap fitur toggle sendiri ---
  NP_AUTO=${NP_AUTO:-0}; NP_QDISC=${NP_QDISC:-0}; NP_QDISC_ALGO=${NP_QDISC_ALGO:-cake}
  NP_MTU=${NP_MTU:-0}; NP_DNS=${NP_DNS:-0}; NP_DNS_MOBILE=${NP_DNS_MOBILE:-auto}; NP_DNS_WIFI=${NP_DNS_WIFI:-auto}
  NP_ADV=${NP_ADV:-0}; NP_NICOFF=${NP_NICOFF:-0}; NP_CONNTRACK=${NP_CONNTRACK:-0}; NP_IPV6OFF=${NP_IPV6OFF:-0}
  NP_DATASAVER=${NP_DATASAVER:-0}; NP_NETSTATE=${NP_NETSTATE:-0}; NP_LTECA=${NP_LTECA:-0}
  NP_ISOLATE=${NP_ISOLATE:-0}; NP_BOOST=${NP_BOOST:-0}; NP_BOOST_GAMES=${NP_BOOST_GAMES:-1}; NP_WATCH_SEC=${NP_WATCH_SEC:-5}
  NP_TFO=${NP_TFO:-0}; NP_WIFIPS=${NP_WIFIPS:-0}; NP_RPS=${NP_RPS:-0}; NP_BLOCKALL=${NP_BLOCKALL:-0}; NP_DSCP=${NP_DSCP:-46}
  # --- Refresh Rate Hz (lib/hz.sh): peak/min_refresh_rate + prop SurfaceFlinger content detection=false
  HZ=${HZ:-0}
  HZ_TARGET=${HZ_TARGET:-0}                 # 0 = Hz tertinggi yang didukung panel
  # --- Frame Rate GLOBAL lama (lib/framerate.sh) DIPENSIUNKAN v1.0.30 - nilainya hanya dipulihkan (frm_off); FPS kini per game (lib/gamefps.sh)
  FEAT_GAMEFPS=${FEAT_GAMEFPS:-1}           # Frame Rate (FPS) PER GAME (lib/gamefps.sh; data di game_fps.list)
  FRAMERATE=${FRAMERATE:-0}
  FRAMERATE_TARGET=${FRAMERATE_TARGET:-0}   # 0 = Hz tertinggi yang didukung panel
  FC_BATT_MAX_C=${FC_BATT_MAX_C:-50}
  VX_CURRENT_UA=${VX_CURRENT_UA:-6000000}; VX_LOW_UA=${VX_LOW_UA:-3000000}; VX_TEMP_MAX=${VX_TEMP_MAX:-450}; VX_TEMP_RESUME=${VX_TEMP_RESUME:-420}; VX_TICK=${VX_TICK:-10}
  PL_SWAPPINESS=${PL_SWAPPINESS:-40}
  PL_VFS_PRESSURE=${PL_VFS_PRESSURE:-120}
  PL_READAHEAD_KB=${PL_READAHEAD_KB:-512}
  PL_UP_US=${PL_UP_US:-500}
  PL_DOWN_US=${PL_DOWN_US:-2000}
  PL_TOP_UCLAMP_MIN=${PL_TOP_UCLAMP_MIN:-10}
  PL_BG_UCLAMP_MAX=${PL_BG_UCLAMP_MAX:-50}
  NET_CONGESTION=${NET_CONGESTION:-bbr3}   # dipakai kalau tersedia di kernel (tcp_available_congestion_control), fallback bbr/westwood/cubic
  SF_BOOT_PROPS=${SF_BOOT_PROPS:-1}
  NOTIFY=${NOTIFY:-1}
  BOOT_FAIL_LIMIT=${BOOT_FAIL_LIMIT:-3}
  BOOT_OK_DELAY=${BOOT_OK_DELAY:-45}
  STAGE_STEP_DELAY=${STAGE_STEP_DELAY:-0}
  SAFE_WINDOW_SEC=${SAFE_WINDOW_SEC:-8}
  EXTRA_GAME_PACKAGES=${EXTRA_GAME_PACKAGES:-}
  # -- hard-mode thermal protection (poin 5): hard mode mematikan lebih banyak
  # proteksi vendor, jadi pengaman software harus LEBIH ketat, bukan sama dengan
  # mode lain. Lihat lib/thermal.sh thermal_eval().
  HARD_SAFE_HOT_SECONDS=${HARD_SAFE_HOT_SECONDS:-8}     # vs SAFE_HOT_SECONDS=20 default
  HARD_EMERGENCY_MARGIN_C=${HARD_EMERGENCY_MARGIN_C:-5} # lewat limit+margin = THERM_STATE=2 instan
  HARD_MON_SEC=${HARD_MON_SEC:-2}                       # vs 4 dtk default (tick_ingame)
  HARD_DEMOTE_AFTER_TRIP=${HARD_DEMOTE_AFTER_TRIP:-1}   # turunkan ke auto otomatis setelah safety trip
  # -- anti-sawtooth FPS level (poin 6): lihat lib/fps.sh fse_tick().
  SAWTOOTH_WINDOW_SEC=${SAWTOOTH_WINDOW_SEC:-45}  # jendela deteksi gantian arah
  SAWTOOTH_FLAPS=${SAWTOOTH_FLAPS:-3}             # berapa kali gantian arah = sawtooth
  SAWTOOTH_LOCK_SEC=${SAWTOOTH_LOCK_SEC:-60}      # kunci level selama ini kalau sawtooth
  for nv in SAFE_BATT_C SAFE_SKIN_C SAFE_HOT_SECONDS COOLDOWN_SEC INJECT_C TRIP_RAISE_C \
            POLL_INTERVAL FPS_TICK FG_CHECK_INGAME FPS_DROP_PCT FPS_STABLE_SAMPLES \
            BOOT_FAIL_LIMIT BOOT_OK_DELAY STAGE_STEP_DELAY SAFE_WINDOW_SEC \
            FPSGO_AB_WARMUP FPSGO_AB_WINDOW FPSGO_AB_SETTLE FPSGO_AB_REG_PCT FPSGO_RELEARN_DAYS \
            HARD_SAFE_HOT_SECONDS HARD_EMERGENCY_MARGIN_C HARD_MON_SEC \
            SAWTOOTH_WINDOW_SEC SAWTOOTH_FLAPS SAWTOOTH_LOCK_SEC \
            NET_PING_INTERVAL CHARGE_MIN_PCT CHARGE_TICK CHARGE_VERIFY_TRIES; do
    case "$nv" in
      SAFE_BATT_C) num_or $nv 43 ;;   SAFE_SKIN_C) num_or $nv 46 ;;
      SAFE_HOT_SECONDS) num_or $nv 20 ;; COOLDOWN_SEC) num_or $nv 180 ;;
      INJECT_C) num_or $nv 40 ;;      TRIP_RAISE_C) num_or $nv 0 ;;
      POLL_INTERVAL) num_or $nv 3 ;;  FPS_TICK) num_or $nv 2 ;;
      FG_CHECK_INGAME) num_or $nv 5 ;; FPS_DROP_PCT) num_or $nv 90 ;;
      FPS_STABLE_SAMPLES) num_or $nv 15 ;; BOOT_FAIL_LIMIT) num_or $nv 3 ;;
      BOOT_OK_DELAY) num_or $nv 45 ;; STAGE_STEP_DELAY) num_or $nv 0 ;;
      SAFE_WINDOW_SEC) num_or $nv 8 ;;
      FPSGO_AB_WARMUP) num_or $nv 6 ;; FPSGO_AB_WINDOW) num_or $nv 8 ;;
      FPSGO_AB_SETTLE) num_or $nv 3 ;;  FPSGO_AB_REG_PCT) num_or $nv 3 ;;
      FPSGO_RELEARN_DAYS) num_or $nv 14 ;;
      HARD_SAFE_HOT_SECONDS) num_or $nv 8 ;; HARD_EMERGENCY_MARGIN_C) num_or $nv 5 ;;
      HARD_MON_SEC) num_or $nv 2 ;;
      SAWTOOTH_WINDOW_SEC) num_or $nv 45 ;; SAWTOOTH_FLAPS) num_or $nv 3 ;;
      SAWTOOTH_LOCK_SEC) num_or $nv 60 ;;
      NET_PING_INTERVAL) num_or $nv 10 ;;
      CHARGE_MIN_PCT) num_or $nv 20 ;; CHARGE_TICK) num_or $nv 2 ;;
      CHARGE_VERIFY_TRIES) num_or $nv 3 ;;
    esac
  done
  [ "$POLL_INTERVAL" -lt 1 ] && POLL_INTERVAL=1
  [ "$FPS_TICK" -lt 1 ] && FPS_TICK=1
  [ "$FPSGO_AB_WINDOW" -lt 3 ] && FPSGO_AB_WINDOW=3
  [ "$HARD_MON_SEC" -lt 1 ] && HARD_MON_SEC=1
  [ "$CHARGE_VERIFY_TRIES" -lt 1 ] && CHARGE_VERIFY_TRIES=1
  # profile hasil scan (tier, vendor, dst) - dibuat oleh scan_all
  [ -f "$PROFILE" ] && . "$PROFILE"
  return 0
}

# ---------------------------------------------------------------------
# Wrapper perintah eksternal yang bisa tidak ada / menggantung
# ---------------------------------------------------------------------
HAVE_TIMEOUT=""
command -v timeout >/dev/null 2>&1 && HAVE_TIMEOUT=1
tmo() { # tmo <detik> perintah...
  tmo_s=$1; shift
  if [ -n "$HAVE_TIMEOUT" ]; then timeout "$tmo_s" "$@"; else "$@"; fi
}

getp() { getprop "$1" 2>/dev/null; }

lower() { echo "$*" | tr 'A-Z' 'a-z'; }

# baca satu angka dari file tanpa fork (builtin read). Kosong kalau gagal.
read1() { { read -r r1_v < "$1"; } 2>/dev/null && echo "$r1_v"; }

# ---------------------------------------------------------------------
# Normalisasi suhu -> derajat Celcius integer ("" kalau tidak valid)
# ---------------------------------------------------------------------
norm_temp() {
  nt=$1
  case "$nt" in ''|*[!0-9-]*) return 1 ;; esac
  [ "$nt" -lt 0 ] 2>/dev/null && return 1
  if [ "$nt" -ge 1000 ]; then nt=$((nt / 1000))
  elif [ "$nt" -ge 150 ]; then nt=$((nt / 10)); fi
  [ "$nt" -gt 150 ] && return 1
  echo "$nt"
}

# ---------------------------------------------------------------------
# safe_write <path> <nilai>
#   - tidak pernah menulis nilai yang tidak bisa dikembalikan (backup dulu)
#   - key backup = path (tidak ada tabrakan antar-policy / antar-zona)
#   - verifikasi read-back, hasil dicatat ke $RUNDIR/writes
#   return: 0 ok | 1 node tidak ada/tak terbaca | 2 ditolak kernel
# ---------------------------------------------------------------------
sw_bfile() { echo "$BACKUPDIR/$(echo "$1" | tr '/' '%')"; }

norm_val() { # nilai node dalam bentuk yang bisa ditulis balik
  nv_raw=$(cat "$1" 2>/dev/null) || return 1
  case "$nv_raw" in
    *\[*\]*) nv_raw=$(echo "$nv_raw" | sed -n 's/.*\[\([^]]*\)\].*/\1/p') ;;
  esac
  echo "$nv_raw"
}

stack_drop() { # buang satu path dari STACK + backup-nya
  grep -vxF "$1" "$STACK" > "$STACK.tmp" 2>/dev/null
  mv -f "$STACK.tmp" "$STACK" 2>/dev/null
  rm -f "$(sw_bfile "$1")"
}

safe_write() {
  sw_p=$1; sw_v=$2
  [ -e "$sw_p" ] || return 1
  sw_new=0
  if ! grep -qxF "$sw_p" "$STACK" 2>/dev/null; then
    sw_b=$(sw_bfile "$sw_p")
    if ! norm_val "$sw_p" > "$sw_b.tmp" 2>/dev/null; then rm -f "$sw_b.tmp"; return 1; fi
    [ -s "$sw_b.tmp" ] || { rm -f "$sw_b.tmp"; return 1; }
    mv -f "$sw_b.tmp" "$sw_b"
    echo "$sw_p" >> "$STACK"
    sw_new=1
  fi
  if { echo "$sw_v" > "$sw_p"; } 2>/dev/null; then
    sw_chk=$(norm_val "$sw_p")
    if [ "$(echo $sw_chk)" = "$(echo $sw_v)" ]; then
      echo "ok $sw_p" >> "$RUNDIR/writes"
    else
      echo "diff $sw_p want=$sw_v got=$sw_chk" >> "$RUNDIR/writes"
    fi
    return 0
  fi
  [ "$sw_new" = 1 ] && stack_drop "$sw_p"
  echo "rej $sw_p" >> "$RUNDIR/writes"
  return 2
}

# tulis nilai backup (kondisi awal) ke satu path tanpa menghapusnya dari stack
restore_path() {
  rp_b=$(sw_bfile "$1")
  [ -f "$rp_b" ] || return 1
  rp_o=$(cat "$rp_b" 2>/dev/null)
  [ -n "$rp_o" ] || return 1
  { echo "$rp_o" > "$1"; } 2>/dev/null
}

revert_stack() {
  [ -s "$STACK" ] || { : > "$STACK"; return 0; }
  awk '{a[NR]=$0} END{for(i=NR;i>0;i--) print a[i]}' "$STACK" | while read -r rs_p; do
    [ -n "$rs_p" ] || continue
    restore_path "$rs_p"
    rm -f "$(sw_bfile "$rs_p")"
  done
  : > "$STACK"
}

# ---------------------------------------------------------------------
# Property (non-persisten, dengan backup; nilai lama kosong = dihapus saat revert)
# ---------------------------------------------------------------------
prop_set() {
  ps_k=$1; ps_v=$2
  case "$ps_k" in ro.*) return 1 ;; esac
  if ! grep -q "^$ps_k|" "$PROPSTACK" 2>/dev/null; then
    echo "$ps_k|$(getp "$ps_k")" >> "$PROPSTACK"
  fi
  if command -v resetprop >/dev/null 2>&1; then resetprop "$ps_k" "$ps_v" 2>/dev/null
  else setprop "$ps_k" "$ps_v" 2>/dev/null; fi
}

revert_props() {
  [ -s "$PROPSTACK" ] || { : > "$PROPSTACK"; return 0; }
  while IFS='|' read -r rp_k rp_v; do
    [ -n "$rp_k" ] || continue
    if [ -n "$rp_v" ]; then
      if command -v resetprop >/dev/null 2>&1; then resetprop "$rp_k" "$rp_v" 2>/dev/null
      else setprop "$rp_k" "$rp_v" 2>/dev/null; fi
    else
      resetprop --delete "$rp_k" 2>/dev/null || setprop "$rp_k" "" 2>/dev/null
    fi
  done < "$PROPSTACK"
  : > "$PROPSTACK"
}

# ---------------------------------------------------------------------
# Service init (stop -> start ulang saat revert), hanya yang sedang running
# ---------------------------------------------------------------------
svc_stop() {
  [ "$(getp "init.svc.$1")" = "running" ] || return 1
  grep -qxF "$1" "$SVCSTACK" 2>/dev/null || echo "$1" >> "$SVCSTACK"
  stop "$1" 2>/dev/null
}

revert_services() {
  [ -s "$SVCSTACK" ] || { : > "$SVCSTACK"; return 0; }
  while read -r rv_s; do
    [ -n "$rv_s" ] && start "$rv_s" 2>/dev/null
  done < "$SVCSTACK"
  : > "$SVCSTACK"
}

notify() {
  [ "$NOTIFY" = "1" ] || return 0
  cmd notification post -t "Zyrox" azenith-ai "$1" >/dev/null 2>&1 &
}

nth_word() { # nth_word <n> <daftar...>  (1-based)
  nw_n=$1; shift
  nw_i=1
  for nw_w in "$@"; do
    [ "$nw_i" = "$nw_n" ] && { echo "$nw_w"; return 0; }
    nw_i=$((nw_i + 1))
  done
  return 1
}
