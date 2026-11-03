#!/system/bin/sh
# =====================================================================
#  Zyrox v2.1 - lib/fpsgo.sh   (TUNING FPSGO + BUKTI EFEK KE FPS)
#
#  1. Katalog node (fpsgo_profile.conf) + node hasil temuan di device ("disc")
#     dikelompokkan jadi GRUP. Hanya node yang ADA, rw, dan bernilai satu angka.
#  2. Audisi A/B per game: tiap grup diterapkan, FPS game diukur dari sistem
#     (fpsgo_status difilter ke pid/tid game; atau SurfaceFlinger per-layer),
#     lalu grup DIBUANG kalau FPS turun / jank naik. Hasil disimpan per game
#     (learn/<paket>.fpsgo) sehingga sesi berikutnya langsung memakai yang terbukti.
#  3. Sumber FPS ditemukan dari isi direktori sistem + data game (pid/tid dari
#     /proc/<pid>/task), format kolom dideteksi dari file itu sendiri.
# =====================================================================

LEARNDIR="$DATADIR/learn"
EFFECT_LOG="$DATADIR/fpsgo_effect.log"
FPSA_ST=off; FPSA_Q=""; FPSA_CUR=""; FPSA_N=0; FPSA_BUF=""; FPSA_BASE=""; FPSA_HOLD=0
FPSA_GRPS=""; FSE_IDS=""; FSE_FPSFILE=""; FSE_ORDER=""
FPSG_G=""; FPSG_N=0; FPSG_SKIP_FMT=0; FPSG_SAME=0

fpsgo_catalog_file() {
  fc_f="$DATADIR/fpsgo_profile.conf"; [ -f "$fc_f" ] || fc_f="$MODDIR/fpsgo_profile.conf"
  echo "$fc_f"
}

fpsgo_fp() { echo "$(getp ro.build.fingerprint)|$(uname -r 2>/dev/null)" | cksum | awk '{print $1}'; }

# pid + semua tid game (data game dari /proc, bukan tebakan nama thread)
fpsgo_ids() {
  fi_s=" $1 "; fi_n=0
  for fi_t in "$R/proc/$1"/task/*; do
    [ -d "$fi_t" ] || continue
    fi_s="$fi_s${fi_t##*/} "
    fi_n=$((fi_n + 1)); [ "$fi_n" -ge 400 ] && break
  done
  echo "$fi_s"
}

# ---------------------------------------------------------------------
# Klasifikasi node temuan (dipanggil dari scan_fps) -> scan/fpsgo_candidates.txt
# ---------------------------------------------------------------------
fpsgo_disc_ok() { # nama nilai_sekarang
  case "$1" in
    *debug*|*trace*|*log*|*dump*|*thrm*|*therm*|*limit*|*ceil*|*force*|*disable*|*off*|*test*|*reset*|\
    *stop*|*kill*|*fake*|*simulat*|*fix*|*ignore*|*bypass*|*stress*|*mock*|*info*|*status*) return 1 ;;
  esac
  case "$1" in *rescue*|*boost*|*ultra*) ;; *) return 1 ;; esac
  [ "$2" = 0 ] || return 1
  return 0
}

fpsgo_classify() {
  [ -s "$SCANDIR/fpsgo_index" ] || { : > "$SCANDIR/fpsgo_candidates.txt"; return 0; }
  fk_cat=$(fpsgo_catalog_file)
  {
    echo "# jenis: bin(0/1) num(integer) multi/str(dilewati) | rw/ro | peran: cat:<grup> disc - "
    while IFS='|' read -r kn_name kn_path kn_rw kn_cur; do
      case "$kn_cur" in 0|1) kn_k=bin ;; ''|*[!0-9-]*) kn_k=str ;; *) kn_k=num ;; esac
      [ -n "$kn_cur" ] && case "$kn_cur" in *\ *) kn_k=multi ;; esac
      kn_role="-"
      kn_g=$(awk -F'|' -v n="$kn_name" '$1==n && $0 !~ /^#/ {g=$4} END{print g}' "$fk_cat" 2>/dev/null)
      if [ -n "$kn_g" ]; then kn_role="cat:$kn_g"
      elif [ "$kn_rw" = rw ] && [ "$kn_k" = bin ] && fpsgo_disc_ok "$kn_name" "$kn_cur"; then kn_role=disc; fi
      echo "$kn_k $kn_rw $kn_path = $kn_cur  [$kn_role]"
    done < "$SCANDIR/fpsgo_index"
  } > "$SCANDIR/fpsgo_candidates.txt"
}

# ---------------------------------------------------------------------
# Rencana node untuk game ini: grup|path|nilai
# ---------------------------------------------------------------------
fpsgo_plan_build() {
  fb_cat=$(fpsgo_catalog_file)
  [ -s "$SCANDIR/fpsgo_index" ] && [ -f "$fb_cat" ] || return 1
  fb_allow=" safe "
  if [ "$PRESET_EFF" = extreme ] || [ "$THERMAL_MODE" = hard ]; then fb_allow="$fb_allow aggr "; fi
  [ "$THERMAL_MODE" = hard ] && fb_allow="$fb_allow thermal "
  awk -F'|' -v allow="$fb_allow" '
    NR==FNR { if ($0 ~ /^#/ || $1 == "") next; v[$1]=$2; c[$1]=$3; g[$1]=($4 == "" ? "core" : $4); next }
    ($1 in v) && $3 == "rw" && index(allow, " " c[$1] " ") { print g[$1] "|" $2 "|" v[$1] }
  ' "$fb_cat" "$SCANDIR/fpsgo_index" > "$RUNDIR/fpsgo_plan"
  if [ "$FPSGO_DISCOVER" = 1 ]; then
    cut -d'|' -f1 "$fb_cat" | grep -v '^#' > "$RUNDIR/fpsgo_catnames"
    while IFS='|' read -r pd_name pd_path pd_rw pd_cur; do
      [ "$pd_rw" = rw ] || continue
      grep -qxF "$pd_name" "$RUNDIR/fpsgo_catnames" && continue
      fpsgo_disc_ok "$pd_name" "$pd_cur" && echo "disc|$pd_path|1" >> "$RUNDIR/fpsgo_plan"
    done < "$SCANDIR/fpsgo_index"
  fi
  [ -s "$RUNDIR/fpsgo_plan" ]
}

# tulis satu node dengan penjaga format; return 0 hanya bila nilai benar-benar berubah
fpsgo_try_write() {
  tw_p=$1; tw_v=$2
  [ -f "$tw_p" ] && [ -w "$tw_p" ] || return 1
  tw_c=$(norm_val "$tw_p") || return 1
  set -- $tw_c
  if [ $# -ne 1 ]; then FPSG_SKIP_FMT=$((FPSG_SKIP_FMT + 1)); return 1; fi
  case "$1" in -[0-9]*|[0-9]*) ;; *) FPSG_SKIP_FMT=$((FPSG_SKIP_FMT + 1)); return 1 ;; esac
  case "$tw_v" in ''|*[!0-9-]*) return 1 ;; esac
  if [ "$1" = "$tw_v" ]; then FPSG_SAME=$((FPSG_SAME + 1)); return 1; fi
  safe_write "$tw_p" "$tw_v" || return 1
  echo "$tw_p" >> "$RUNDIR/fpsg_$FPSG_G"
  return 0
}

fpsgo_group_apply() { # grup -> FPSG_N = jumlah node yang berubah
  FPSG_G=$1; FPSG_N=0; FPSG_SKIP_FMT=0; FPSG_SAME=0
  : > "$RUNDIR/fpsg_$1"
  while IFS='|' read -r ga_g ga_path ga_val; do
    [ "$ga_g" = "$1" ] || continue
    fpsgo_try_write "$R$ga_path" "$ga_val" && FPSG_N=$((FPSG_N + 1))
  done < "$RUNDIR/fpsgo_plan"
  return 0
}

fpsgo_group_revert() {
  [ -s "$RUNDIR/fpsg_$1" ] || return 0
  while read -r gr_p; do [ -n "$gr_p" ] && restore_path "$gr_p"; done < "$RUNDIR/fpsg_$1"
}

# ---------------------------------------------------------------------
# Hasil belajar per game
# ---------------------------------------------------------------------
learn_get() { # paket grup -> keep|drop (hanya bila masih segar & kernel sama)
  lg_f="$LEARNDIR/$1.fpsgo"; [ -f "$lg_f" ] || return 1
  awk -F'|' -v g="$2" -v now="$(date +%s)" -v mx="$((FPSGO_RELEARN_DAYS * 86400))" -v fp="$(fpsgo_fp)" '
    $1 == g { v = $2; t = $5; f = $6 }
    END { if (v != "" && now - t <= mx && f == fp) print v }' "$lg_f"
}

learn_put() { # paket grup verdict gain_x10 bad_pp
  mkdir -p "$LEARNDIR" 2>/dev/null
  lp_f="$LEARNDIR/$1.fpsgo"
  { grep -v "^$2|" "$lp_f" 2>/dev/null; echo "$2|$3|$4|$5|$(date +%s)|$(fpsgo_fp)"; } > "$lp_f.t" && mv -f "$lp_f.t" "$lp_f"
}

fpsa_state() { # grup status [nodes gain bad]
  { grep -v "^$1|" "$RUNDIR/fpsgo_state" 2>/dev/null; echo "$1|$2|${3:-0}|${4:-}|${5:-}"; } > "$RUNDIR/fpsgo_state.t" \
    && mv -f "$RUNDIR/fpsgo_state.t" "$RUNDIR/fpsgo_state"
}

fx() { # integer x10 -> teks 1 desimal
  fx_v=$1; fx_s=""; [ "$fx_v" -lt 0 ] && { fx_s="-"; fx_v=$((0 - fx_v)); }
  echo "$fx_s$((fx_v / 10)).$((fx_v % 10))"
}

effect_log() {
  printf '%s %s %s\n' "$(date '+%m-%d %H:%M')" "${GAME_PKG:-?}" "$*" >> "$EFFECT_LOG" 2>/dev/null
  log_msg "H: $*"
  [ "$(wc -l < "$EFFECT_LOG" 2>/dev/null)" -gt 300 ] 2>/dev/null && { tail -n 150 "$EFFECT_LOG" > "$EFFECT_LOG.t"; mv -f "$EFFECT_LOG.t" "$EFFECT_LOG"; }
}

# ---------------------------------------------------------------------
# Terapkan saat game mulai (stage F di daemon)
# ---------------------------------------------------------------------
fpsa_reset_state() {
  FPSA_ST=off; FPSA_Q=""; FPSA_CUR=""; FPSA_N=0; FPSA_BUF=""; FPSA_BASE=""; FPSA_HOLD=0
  rm -f "$RUNDIR"/fpsg_* "$RUNDIR/fpsgo_state" "$RUNDIR/fpsgo_plan"
}

perf_fpsgo_apply() {
  [ "$FEAT_FPSGO_TUNE" = 1 ] || return 0
  [ "$HAS_FPSGO" = 1 ] || { log_msg "F: skip (device tanpa FPSGO)"; return 0; }
  fpsa_reset_state
  fpsgo_plan_build || { log_msg "F: tidak ada node katalog/temuan yang cocok di device ini (lihat scan/fpsgo_candidates.txt)"; return 0; }
  FPSA_GRPS=$(awk -F'|' '!s[$1]++{printf "%s ", $1}' "$RUNDIR/fpsgo_plan")
  fa_pkg=${GAME_PKG:-_none}; fa_n=0; fa_known=0
  for fa_g in $FPSA_GRPS; do
    fa_v=$(learn_get "$fa_pkg" "$fa_g")
    case "$fa_v" in
      keep) fpsgo_group_apply "$fa_g"; fa_n=$((fa_n + FPSG_N)); fa_known=$((fa_known + 1))
            fpsa_state "$fa_g" "aktif(terbukti)" "$FPSG_N" ;;
      drop) fa_known=$((fa_known + 1)); fpsa_state "$fa_g" "dibuang(terbukti)" 0 ;;
      *)    if [ "$FPSGO_AUDITION" = 1 ]; then
              FPSA_Q="$FPSA_Q $fa_g"; fpsa_state "$fa_g" antri 0
            else
              fpsgo_group_apply "$fa_g"; fa_n=$((fa_n + FPSG_N)); fpsa_state "$fa_g" "aktif(belum-diuji)" "$FPSG_N"
            fi ;;
    esac
  done
  FPSA_Q=$(echo $FPSA_Q)
  log_msg "F: FPSGO grup=[$(echo $FPSA_GRPS)] node-berubah=$fa_n dipelajari=$fa_known antri-audisi=[$FPSA_Q]"
  return 0
}

# ---------------------------------------------------------------------
# Sumber FPS: temukan file yang memuat pid/tid GAME + data fps
# ---------------------------------------------------------------------
fpsgo_discover_src() { # ids -> FSE_FPSFILE (path relatif) atau kosong
  FSE_FPSFILE=""
  fd_ids=$1; fd_best=""; fd_score=0
  printf '%s\n' $fd_ids > "$RUNDIR/ids.list"
  : > "$RUNDIR/fps_src_cands"; : > "$RUNDIR/fd_list"
  [ -n "$FPSGO_STATUS_FILE" ] && echo "$FPSGO_STATUS_FILE" >> "$RUNDIR/fd_list"
  # seluruh direktori sistem hanya dibaca bila ada `timeout` (node tertentu bisa memblokir)
  [ -n "$HAVE_TIMEOUT" ] && [ -s "$SCANDIR/fpsgo_index" ] && cut -d'|' -f2 "$SCANDIR/fpsgo_index" >> "$RUNDIR/fd_list"
  awk '!s[$0]++' "$RUNDIR/fd_list" > "$RUNDIR/fd_list2"
  while read -r fd_rel; do
    [ -n "$fd_rel" ] && [ -r "$R$fd_rel" ] || continue
    tmo 2 head -c 16384 "$R$fd_rel" > "$RUNDIR/fd_tmp" 2>/dev/null
    grep -qi 'fps' "$RUNDIR/fd_tmp" || continue
    grep -qwF -f "$RUNDIR/ids.list" "$RUNDIR/fd_tmp" || continue
    fd_v=$(awk -v ids="$fd_ids" -v mode=val -f "$MODDIR/lib/fpsgo_parse.awk" "$RUNDIR/fd_tmp" 2>/dev/null)
    case "$fd_v" in ''|*[!0-9]*) continue ;; esac
    fd_d=$(awk -v ids="$fd_ids" -v mode=diag -f "$MODDIR/lib/fpsgo_parse.awk" "$RUNDIR/fd_tmp" 2>/dev/null)
    echo "$fd_rel|$((fd_v / 10))fps|$fd_d" >> "$RUNDIR/fps_src_cands"
    fd_sc=1; case "$fd_d" in fmt=table*) fd_sc=3 ;; fmt=kv*) fd_sc=2 ;; esac
    [ "$fd_rel" = "$FPSGO_STATUS_FILE" ] && fd_sc=$((fd_sc + 1))
    if [ "$fd_sc" -gt "$fd_score" ]; then fd_score=$fd_sc; fd_best=$fd_rel; fi
  done < "$RUNDIR/fd_list2"
  rm -f "$RUNDIR/fd_tmp" "$RUNDIR/fd_list" "$RUNDIR/fd_list2"
  FSE_FPSFILE=$fd_best
  if [ -n "$fd_best" ]; then
    fpsgo_diag > "$RUNDIR/fpsgo_diag"
    log_msg "H: sumber FPS dari direktori sistem: $fd_best ($(cat "$RUNDIR/fpsgo_diag"), kandidat=$(wc -l < "$RUNDIR/fps_src_cands"))"
  else
    echo "tidak ada file yang memuat pid/tid game + fps" > "$RUNDIR/fpsgo_diag"
    log_msg "H: tidak ada file FPSGO yang memuat pid/tid game (pakai sumber lain)"
  fi
}

fpsgo_diag() {
  [ -n "$FSE_FPSFILE" ] && [ -r "$R$FSE_FPSFILE" ] || return 0
  awk -v ids="$FSE_IDS" -v mode=diag -f "$MODDIR/lib/fpsgo_parse.awk" "$R$FSE_FPSFILE" 2>/dev/null
}

# ---------------------------------------------------------------------
# Audisi A/B
# ---------------------------------------------------------------------
fpsa_arm() {
  FPSA_ST=off; FPSA_HOLD=0
  [ -n "$FPSA_Q" ] || return 0
  if [ "$FSE_MODE" = static ]; then fpsa_abort "tidak ada sumber FPS"; return 0; fi
  FPSA_ST=warm; FPSA_N=0; FPSA_HOLD=1
  log_msg "H: audisi A/B dijadwalkan grup=[$FPSA_Q] warmup=$FPSGO_AB_WARMUP jendela=$FPSGO_AB_WINDOW settle=$FPSGO_AB_SETTLE"
}

fpsa_abort() {
  [ "$FPSA_ST" != off ] || [ -n "$FPSA_Q" ] || return 0
  ab_r=$1
  if [ "$FPSGO_APPLY_UNVERIFIED" = 1 ]; then
    for ab_g in $FPSA_Q; do fpsgo_group_apply "$ab_g"; fpsa_state "$ab_g" "aktif(belum-diuji)" "$FPSG_N"; done
    [ -n "$FPSA_CUR" ] && fpsa_state "$FPSA_CUR" "aktif(belum-diuji)"
  else
    [ -n "$FPSA_CUR" ] && { fpsgo_group_revert "$FPSA_CUR"; fpsa_state "$FPSA_CUR" "dilewati($ab_r)"; }
    for ab_g in $FPSA_Q; do fpsa_state "$ab_g" "dilewati($ab_r)"; done
  fi
  effect_log "audisi dibatalkan: $ab_r"
  FPSA_ST=off; FPSA_HOLD=0; FPSA_Q=""; FPSA_CUR=""
}

fpsa_next() {
  FPSA_CUR=""
  while :; do
    set -- $FPSA_Q
    if [ $# -eq 0 ]; then
      FPSA_ST=off; FPSA_HOLD=0
      effect_log "audisi selesai: $(tr '\n' ' ' < "$RUNDIR/fpsgo_state" 2>/dev/null)"
      return 0
    fi
    fn_g=$1; shift; FPSA_Q="$*"
    fpsgo_group_apply "$fn_g"
    if [ "$FPSG_N" -le 0 ]; then
      fpsa_state "$fn_g" "kosong(nilai sudah sama/format lain)" 0
      effect_log "grup $fn_g: tidak ada node yang berubah (sama=$FPSG_SAME format-lain=$FPSG_SKIP_FMT), dilewati"
      continue
    fi
    FPSA_CUR=$fn_g; FPSA_ST=settle; FPSA_N=0; FPSA_BUF=""
    fpsa_state "$fn_g" "diuji" "$FPSG_N"
    log_msg "H: uji grup $fn_g ($FPSG_N node)"
    return 0
  done
}

fpsa_metrics() { # buf_base buf_uji -> "mean_b jank_b mean_a jank_a"
  # jank = % sampel di bawah DROP_PCT dari plafon JENDELA ITU SENDIRI (bukan plafon gabungan),
  # supaya grup yang menaikkan FPS tidak membuat baseline tampak "jelek".
  awk -v B="$1" -v T="$2" -v pct="$FPS_DROP_PCT" 'BEGIN{
    nb=split(B,b," "); nt=split(T,t," ")
    if (nb==0||nt==0) { print "0 0 0 0"; exit }
    for(i=1;i<=nb;i++){sb+=b[i]; if(b[i]>cb)cb=b[i]}
    for(i=1;i<=nt;i++){st+=t[i]; if(t[i]>ct)ct=t[i]}
    for(i=1;i<=nb;i++) if(b[i]<cb*pct/100) xb++
    for(i=1;i<=nt;i++) if(t[i]<ct*pct/100) xt++
    printf "%d %d %d %d", sb/nb, xb*100/nb, st/nt, xt*100/nt }'
}

fpsa_eval() {
  set -- $(fpsa_metrics "$FPSA_BASE" "$FPSA_BUF")
  ev_mb=$1; ev_bb=$2; ev_ma=$3; ev_ba=$4
  ev_g=$FPSA_CUR
  [ "${ev_mb:-0}" -gt 0 ] || { fpsa_state "$ev_g" "belum-pasti" "$FPSG_N"; return 0; }
  ev_gain=$(( (ev_ma - ev_mb) * 1000 / ev_mb ))      # per mil -> 0.1%
  ev_dbad=$((ev_ba - ev_bb))
  ev_txt="grup $ev_g ($FPSG_N node): sebelum $(fx "$ev_mb")fps jank=${ev_bb}% | sesudah $(fx "$ev_ma")fps jank=${ev_ba}% | selisih $(fx "$ev_gain")%"
  if [ "$ev_bb" -ge 50 ]; then
    fpsa_state "$ev_g" "belum-pasti(baseline tak stabil)" "$FPSG_N" "$ev_gain" "$ev_dbad"
    effect_log "$ev_txt => BELUM PASTI (baseline tak stabil, grup dipakai sesi ini, diuji ulang sesi berikutnya)"
    FPSA_BASE=$FPSA_BUF
  elif [ "$ev_gain" -le $((0 - FPSGO_AB_REG_PCT * 10)) ] || [ "$ev_dbad" -ge 15 ]; then
    fpsgo_group_revert "$ev_g"
    learn_put "${GAME_PKG:-_none}" "$ev_g" drop "$ev_gain" "$ev_dbad"
    fpsa_state "$ev_g" "dibuang(FPS turun)" "$FPSG_N" "$ev_gain" "$ev_dbad"
    effect_log "$ev_txt => DIBUANG (kembali ke nilai awal)"
  else
    if [ "$ev_gain" -ge 20 ]; then ev_lbl="MEMBANTU"; else ev_lbl="NETRAL (tidak merugikan)"; fi
    learn_put "${GAME_PKG:-_none}" "$ev_g" keep "$ev_gain" "$ev_dbad"
    fpsa_state "$ev_g" "aktif(terbukti)" "$FPSG_N" "$ev_gain" "$ev_dbad"
    effect_log "$ev_txt => DIPERTAHANKAN: $ev_lbl"
    FPSA_BASE=$FPSA_BUF
  fi
}

fpsa_feed() { # fps x10 dari sampel valid
  case "$FPSA_ST" in
    off) FPSA_HOLD=0; return 0 ;;
    warm)   FPSA_N=$((FPSA_N + 1)); [ "$FPSA_N" -ge "$FPSGO_AB_WARMUP" ] && { FPSA_ST=base; FPSA_N=0; FPSA_BUF=""; } ;;
    base)   FPSA_BUF="$FPSA_BUF $1"; FPSA_N=$((FPSA_N + 1))
            if [ "$FPSA_N" -ge "$FPSGO_AB_WINDOW" ]; then FPSA_BASE=$FPSA_BUF; fpsa_next; fi ;;
    settle) FPSA_N=$((FPSA_N + 1)); [ "$FPSA_N" -ge "$FPSGO_AB_SETTLE" ] && { FPSA_ST=test; FPSA_N=0; FPSA_BUF=""; } ;;
    test)   FPSA_BUF="$FPSA_BUF $1"; FPSA_N=$((FPSA_N + 1))
            if [ "$FPSA_N" -ge "$FPSGO_AB_WINDOW" ]; then fpsa_eval; fpsa_next; fi ;;
  esac
  return 0
}
