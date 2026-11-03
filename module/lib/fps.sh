#!/system/bin/sh
# =====================================================================
#  Zyrox v2 - lib/fps.sh   (FPS SUSTAIN ENGINE, basis FPSGO)
#
#  Pengganti detect_true_fps() v1 (yang hanya MENGUKUR via SurfaceFlinger
#  --latency dan tidak berbuat apa-apa dengan hasilnya).
#
#  Cara kerja:
#   * Backend FPSGO (MediaTek): FPSGO dijaga aktif + dituning (lib/fpsgo.sh: grup node
#     diaudisi A/B). Sumber FPS dicari dari isi direktori sistem yang memuat pid/tid
#     GAME (lib/fpsgo_parse.awk mendeteksi kolom sendiri), bukan menebak format.
#   * Backend generic (non-MediaTek, FPSGO tidak ada): mesin yang sama jalan
#     dengan lantai cpufreq/devfreq + uclamp (perf_set_level).
#   * Sumber FPS dicoba berurutan & otomatis di-demote kalau gagal:
#     fpsgo -> sf_latency (per-layer game) -> sde (display) -> fbm.
#   * Umpan balik: FPS turun < FPS_DROP_PCT% dari plafon terbaru -> level naik
#     (cepat); stabil lama -> level turun pelan (hemat panas). Level yang
#     pernah terbukti perlu dipertahankan "dipelajari" (FSE_FLOOR).
#   * Plafon FPS = nilai tertinggi 20 sampel terakhir (bukan Hz layar), jadi
#     game yang di-cap 60fps di layar 120Hz tidak membuat level naik terus.
#   * Tekanan thermal (hangat) membatasi level maksimum.
# =====================================================================

FSE_LEVEL=0; FSE_HIST=""; FSE_BAD=0; FSE_GOOD=0; FSE_FLOOR=0; FSE_PROBE=0
FSE_BLIND=0; FSE_IDX=1; FSE_LAYER=""; FSE_FPS10=0; FSE_MODE=dynamic
FSE_STATIC_T=0; FSE_FLOOR_T=0; FSE_FAILCYC=0; FSE_PKG=""
# anti-sawtooth (poin 6): lacak arah tiap perubahan level + kapan terakhir
# gantian arah, supaya naik-turun berulang dalam waktu singkat (sawtooth)
# terdeteksi dan level dikunci sementara, bukan terus berosilasi.
FSE_LASTDIR=""; FSE_LASTCHG_T=0; FSE_FLAPN=0; FSE_SAW_UNTIL=0

fse_reset() {
  FSE_PKG=$1
  FSE_HIST=""; FSE_BAD=0; FSE_GOOD=0; FSE_FLOOR=0; FSE_PROBE=0
  FSE_BLIND=0; FSE_IDX=1; FSE_LAYER=""; FSE_FPS10=0; FSE_MODE=dynamic
  FSE_STATIC_T=0; FSE_FAILCYC=0; FSE_FLOOR_T=$(uptime_s)
  FSE_LASTDIR=""; FSE_LASTCHG_T=0; FSE_FLAPN=0; FSE_SAW_UNTIL=0
  FSE_IDS=""; FSE_FPSFILE=""; FSE_ORDER=$FPS_ORDER
  [ -n "$GAME_PID" ] && FSE_IDS=$(fpsgo_ids "$GAME_PID")
  if [ "$HAS_FPSGO" = 1 ] && [ "$FEAT_FPSGO_TUNE" = 1 ]; then
    fpsgo_discover_src "$FSE_IDS"
    if [ -n "$FSE_FPSFILE" ]; then
      case " $FSE_ORDER " in *" fpsgo "*) ;; *) FSE_ORDER="fpsgo $FSE_ORDER" ;; esac
    fi
  fi
  FSE_ORDER=$(echo $FSE_ORDER)
  set -- $FSE_ORDER
  FSE_NSRC=$#
  [ "$FSE_NSRC" -ge 1 ] || { FSE_MODE=static; FSE_STATIC_T=$(uptime_s); }
  fpsa_arm
}

sf_layer_resolve() {
  sl_all=$(tmo 4 dumpsys SurfaceFlinger --list 2>/dev/null | grep -F "$1")
  FSE_LAYER=$(echo "$sl_all" | grep -i 'SurfaceView' | grep -v -i -E 'Bounds|Background' | head -n1)
  [ -n "$FSE_LAYER" ] || FSE_LAYER=$(echo "$sl_all" | grep -v -i -E 'Bounds|Background|Splash|Letterbox|Dim' | head -n1)
}

# fps_sample_src <sumber> <pkg>  -> FPS x10 (integer) atau kosong
fps_sample_src() {
  case "$1" in
    fpsgo)
      fp_f="$R${FSE_FPSFILE:-$FPSGO_STATUS_FILE}"
      [ -r "$fp_f" ] && [ "$fp_f" != "$R" ] || return 1
      awk -v ids="$FSE_IDS" -v mode=val -f "$MODDIR/lib/fpsgo_parse.awk" "$fp_f" 2>/dev/null ;;
    sf_latency)
      [ -n "$FSE_LAYER" ] || sf_layer_resolve "$2"
      [ -n "$FSE_LAYER" ] || return 1
      tmo 4 dumpsys SurfaceFlinger --latency "$FSE_LAYER" 2>/dev/null | awk '
        NR==1{next}
        $2>0 && $2<9000000000000000000 { t[n++]=$2 }
        END{ if(n>=5){ d=t[n-1]-t[0]; if(d>0) printf "%d", (n-1)*10000000000/d + 0.5 } }' ;;
    sde)
      cat "$R/sys/class/drm/sde-crtc-0/measured_fps" 2>/dev/null | awk '
        { if (match($0,/[Ff][Pp][Ss][^0-9]*[0-9]+(\.[0-9]+)?/)) { s=substr($0,RSTART,RLENGTH); sub(/^[^0-9]*/,"",s); printf "%d", s*10+0.5; exit } }' ;;
    fbm)
      cat "$R/sys/class/graphics/fb0/measured_fps" 2>/dev/null | awk '
        { if (match($0,/[Ff][Pp][Ss][^0-9]*[0-9]+(\.[0-9]+)?/)) { s=substr($0,RSTART,RLENGTH); sub(/^[^0-9]*/,"",s); printf "%d", s*10+0.5; exit } }' ;;
  esac
}

fps_sample() {
  fs_src=$(nth_word "$FSE_IDX" $FSE_ORDER)
  [ -n "$fs_src" ] || return 1
  fs_v=$(fps_sample_src "$fs_src" "$FSE_PKG")
  case "$fs_v" in ''|*[!0-9]*) FSE_LAYER=""; return 1 ;; esac
  [ "$fs_v" -ge 10 ] && [ "$fs_v" -le 2500 ] || return 1
  echo "$fs_v"
}

fse_next_src() {
  FSE_LAYER=""
  FSE_IDX=$((FSE_IDX + 1))
  if [ "$FSE_IDX" -gt "$FSE_NSRC" ]; then
    FSE_IDX=1; FSE_FAILCYC=$((FSE_FAILCYC + 1))
    if [ "$FSE_FAILCYC" -ge 2 ]; then
      FSE_MODE=static; FSE_STATIC_T=$(uptime_s); FSE_FAILCYC=0
      log_msg "G: semua sumber FPS gagal -> mode statis (level tetap $FSE_LEVEL), coba lagi 60 dtk"
      fpsa_abort "semua sumber FPS gagal"
      return
    fi
  fi
  log_msg "G: sumber FPS dialihkan ke '$(nth_word "$FSE_IDX" $FSE_ORDER)'"
}

fse_set() {
  fse_old=$FSE_LEVEL
  perf_set_level "$1"
  log_msg "G: level $fse_old -> $FSE_LEVEL (fps=$((FSE_FPS10 / 10)) $2)"
}

# fse_flap_gate <up|down> -> 0 (boleh jalan) / 1 (diblok, sawtooth atau terkunci)
# Poin 6: mencegah level CPU/GPU naik-turun cepat berulang (pola gergaji).
# Dipanggil HANYA oleh logika adaptif naik/turun di fse_tick; clamp thermal
# (batas keamanan) tidak lewat sini dan selalu jalan apa pun kondisinya.
fse_flap_gate() {
  fg_now=$(uptime_s)
  if [ "$fg_now" -lt "$FSE_SAW_UNTIL" ]; then return 1; fi
  if [ -n "$FSE_LASTDIR" ] && [ "$FSE_LASTDIR" != "$1" ] && [ $((fg_now - FSE_LASTCHG_T)) -le "$SAWTOOTH_WINDOW_SEC" ]; then
    FSE_FLAPN=$((FSE_FLAPN + 1))
  else
    FSE_FLAPN=1
  fi
  FSE_LASTDIR=$1; FSE_LASTCHG_T=$fg_now
  if [ "$FSE_FLAPN" -ge "$SAWTOOTH_FLAPS" ]; then
    FSE_SAW_UNTIL=$((fg_now + SAWTOOTH_LOCK_SEC)); FSE_FLAPN=0; FSE_LASTDIR=""
    log_msg "G: sawtooth terdeteksi (level gantian arah ${SAWTOOTH_FLAPS}x dalam <=${SAWTOOTH_WINDOW_SEC}dtk) -> dikunci di level $FSE_LEVEL selama ${SAWTOOTH_LOCK_SEC}dtk"
    return 1
  fi
  return 0
}

fse_tick() {
  [ "$FEAT_FPS_ENGINE" = 1 ] || return 0
  [ "$FEAT_FREQ" = 1 ] || return 0
  ft_cap=$LV_CAP
  [ "$THERM_STATE" -ge 1 ] && [ "$ft_cap" -gt 2 ] && ft_cap=2
  [ "$FSE_LEVEL" -gt "$ft_cap" ] && fse_set "$ft_cap" "batas thermal"
  [ "$THERM_STATE" -ge 1 ] && [ "$FPSA_ST" != off ] && fpsa_abort "suhu hangat, hasil ukur tidak adil"

  if [ "$FSE_MODE" = static ]; then
    [ "$FPSA_ST" != off ] && fpsa_abort "tidak ada sumber FPS"
    if [ $(( $(uptime_s) - FSE_STATIC_T )) -ge 60 ]; then FSE_MODE=dynamic; FSE_IDX=1; FSE_FAILCYC=0; fi
    return 0
  fi
  ft_s=$(fps_sample)
  if [ -z "$ft_s" ]; then
    FSE_BLIND=$((FSE_BLIND + 1))
    if [ "$FSE_BLIND" = 2 ] && [ "$(nth_word "$FSE_IDX" $FSE_ORDER)" = fpsgo ]; then
      # thread render sering baru lahir setelah loading: segarkan pid/tid game & cari ulang file
      [ -n "$GAME_PID" ] && FSE_IDS=$(fpsgo_ids "$GAME_PID")
      fpsgo_discover_src "$FSE_IDS"
    fi
    [ "$FSE_BLIND" -ge 4 ] && { FSE_BLIND=0; fse_next_src; }
    return 0
  fi
  FSE_BLIND=0; FSE_FAILCYC=0; FSE_FPS10=$ft_s
  FSE_HIST="$FSE_HIST $ft_s"
  set -- $FSE_HIST
  while [ $# -gt 20 ]; do shift; done
  FSE_HIST="$*"; ft_n=$#
  ft_ceil=0
  for ft_v in "$@"; do [ "$ft_v" -gt "$ft_ceil" ] && ft_ceil=$ft_v; done
  echo "$((ft_s / 10)) $((ft_ceil / 10)) $FSE_LEVEL" > "$RUNDIR/fps_now"
  fpsa_feed "$ft_s"
  [ "$FPSA_HOLD" = 1 ] && return 0        # audisi A/B berjalan: level CPU/GPU dibekukan agar ukuran adil
  [ "$ft_n" -ge 5 ] || return 0

  ft_lim=$((ft_ceil * FPS_DROP_PCT / 100))
  if [ "$ft_s" -lt "$ft_lim" ]; then FSE_BAD=$((FSE_BAD + 1)); FSE_GOOD=0
  else FSE_GOOD=$((FSE_GOOD + 1)); FSE_BAD=0; fi

  # lantai yang "dipelajari" meluruh pelan (5 menit / 1 level)
  ft_now=$(uptime_s)
  if [ "$FSE_FLOOR" -gt 0 ] && [ $((ft_now - FSE_FLOOR_T)) -ge 300 ]; then
    FSE_FLOOR=$((FSE_FLOOR - 1)); FSE_FLOOR_T=$ft_now
  fi

  ft_want=""
  if [ "$FSE_BAD" -ge 2 ] && [ "$FSE_LEVEL" -lt "$ft_cap" ]; then ft_want=up
  elif [ "$FSE_GOOD" -ge "$FPS_STABLE_SAMPLES" ] && [ "$FSE_LEVEL" -gt "$FSE_FLOOR" ] && [ "$FSE_LEVEL" -gt 0 ]; then ft_want=down
  fi
  if [ "$ft_want" = up ]; then
    if fse_flap_gate up; then
      [ "$FSE_PROBE" -gt 0 ] && { FSE_FLOOR=$((FSE_LEVEL + 1)); FSE_FLOOR_T=$ft_now; }
      FSE_PROBE=0; FSE_BAD=0
      fse_set $((FSE_LEVEL + 1)) "fps drop ${ft_s}/${ft_ceil}"
    else
      FSE_BAD=0   # jangan langsung lompat lagi begitu kunci sawtooth lepas
    fi
  elif [ "$ft_want" = down ]; then
    if fse_flap_gate down; then
      FSE_GOOD=0; FSE_PROBE=4
      fse_set $((FSE_LEVEL - 1)) "stabil, hemat panas"
    else
      FSE_GOOD=0
    fi
  fi
  [ "$FSE_PROBE" -gt 0 ] && FSE_PROBE=$((FSE_PROBE - 1))
  return 0
}
