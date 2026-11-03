#!/system/bin/sh
# =====================================================================
#  Zyrox - lib/gamefps.sh : "Frame Rate (FPS) PER GAME"
#
#  PEMBEDAAN (v1.0.30):
#   - Refresh Rate (lib/hz.sh)  = LAYAR: Hz panel, sentuhan, sensitivitas & respons. Global.
#   - Frame Rate  (file ini)    = FPS yang dipakai DI DALAM GAME. Per game, data disimpan sendiri.
#   Fitur Frame Rate global lama (lib/framerate.sh, mengunci Hz di semua namespace Settings)
#   DIPENSIUNKAN: berkas itu kini hanya dipakai untuk memulihkan nilai asli (frm_off) saat
#   migrasi/uninstall. Tidak ada lagi tombol "kunci FPS semua game".
#
#  Data game (satu baris per paket) di $DATADIR/game_fps.list :
#      paket|profil|fps|nama_data
#    profil : hemat | standar | performa   -> Game Mode Android (3 battery / 1 standard / 2 performance)
#    fps    : angka bulat 20..240 (UI menawarkan 30/45/60/90/120/144)
#    nama   : label bebas (maks ~40 karakter, tanpa '|')
#
#  Penerapan - dicoba berurutan tiap sesi game (dipanggil gamefps_apply dari start_game):
#   TINGKAT 1  GameManagerService (per-app, NYATA):
#       cmd game set --mode <1|2|3> [--downscale R] --fps <FPS> <paket>   lalu  cmd game mode <nama> <paket>
#       Hanya game ini yang dibatasi; sistem/launcher tidak ikut. Butuh Android 13+ (opsi --fps).
#       Kalau game ini juga punya downscale (downscale.conf), rasionya ikut dikirim di perintah yang
#       SAMA supaya tidak saling menimpa, dan mode dipaksa 2 (sama dengan downscale.sh).
#   TINGKAT 2  Kunci Hz selama game (fallback bila ROM tidak punya --fps):
#       peak/min_refresh_rate = mode panel terkecil yang >= FPS (utamakan kelipatan bulat FPS).
#       Ini pembatas KASAR (game tetap boleh lebih rendah); nilai awal dipulihkan saat game berhenti.
#       Dilewati kalau Refresh Rate (Hz) sedang dikunci manual (HZ=1).
#
#  gamefps_revert (stop_game / uninstall) mengembalikan tingkat yang tercatat di marker $GF_ACTIVE_F.
#  CATATAN: belum diuji di perangkat nyata - efek tergantung ROM (lihat log fitur GAMEFPS: azenith-ai flog GAMEFPS).
# =====================================================================

GF_DB="$DATADIR/game_fps.list"
GF_ACTIVE_F="$RUNDIR/gf_active"     # "tingkat:paket" selama override aktif (gms | hz)
GF_HZBK="$RUNDIR/gf_hz_backup"      # key|nilai (Settings.System) sebelum tingkat 2 menimpa

gf_setconf() { # gf_setconf KEY VAL
  if grep -q "^$1=" "$CONF" 2>/dev/null; then sed -i "s/^$1=[^ #]*/$1=$2/" "$CONF"; else echo "$1=$2" >> "$CONF"; fi
}
gf_pkg_ok()  { case "$1" in ''|*[!A-Za-z0-9_.]*) return 1 ;; esac; return 0; }
gf_fps_ok()  { case "$1" in ''|*[!0-9]*) return 1 ;; esac; [ "$1" -ge 20 ] && [ "$1" -le 240 ]; }
gf_prof_ok() { case "$1" in hemat|standar|performa) return 0 ;; esac; return 1; }

# profil -> Game Mode Android: 1 standard, 2 performance, 3 battery
gf_mode_of()  { case "$1" in hemat) echo 3 ;; performa) echo 2 ;; *) echo 1 ;; esac; }
gf_mode_nm()  { case "$1" in 3) echo battery ;; 2) echo performance ;; *) echo standard ;; esac; }

# buang karakter yang merusak format berkas ('|', kontrol), potong panjang
gf_clean_name() { printf '%s' "$*" | tr -d '|\r\n\t' | cut -c1-120; }

# ---------------- penyimpanan ----------------
gf_get()  { [ -f "$GF_DB" ] && awk -F'|' -v p="$1" '$1 == p { print; exit }' "$GF_DB"; }
gf_list() { [ -f "$GF_DB" ] && cat "$GF_DB"; }

# gf_put <paket> <fps> <profil> <nama>   (satu baris per paket: menimpa yang lama)
gf_put() {
  [ -f "$GF_DB" ] || : > "$GF_DB"
  awk -F'|' -v p="$1" '$1 != p' "$GF_DB" > "$GF_DB.t" 2>/dev/null
  printf '%s|%s|%s|%s\n' "$1" "$3" "$2" "$4" >> "$GF_DB.t"
  mv -f "$GF_DB.t" "$GF_DB"
}
gf_del() {
  [ -f "$GF_DB" ] || return 0
  awk -F'|' -v p="$1" '$1 != p' "$GF_DB" > "$GF_DB.t" 2>/dev/null
  mv -f "$GF_DB.t" "$GF_DB"
}

# ---------------- TINGKAT 1: GameManagerService ----------------
# gf_gms_try <paket> <mode 1|2|3> <fps> - echo output mentah, return 0 kalau DITERIMA
gf_gms_try() {
  gg_pkg=$1; gg_mode=$2; gg_fps=$3
  gg_ds=""
  gg_pct=$(ds_get "$gg_pkg")
  if [ -n "$gg_pct" ]; then
    gg_ds="--downscale $(awk -v v="$gg_pct" 'BEGIN{printf "%.2f", v/100}')"
  fi
  cmd device_config put game_overlay "$gg_pkg" "mode=$gg_mode" >/dev/null 2>&1
  # $gg_ds sengaja tanpa kutip: kosong = tidak ada argumen, atau dua kata "--downscale 0.70"
  gg_out=$(cmd game set --mode "$gg_mode" $gg_ds --fps "$gg_fps" "$gg_pkg" 2>&1)
  gg_rc=$?
  case "$gg_out" in
    *"Unknown command"*|*"unknown command"*|*"nvalid option"*|*"nknown option"*|*"not found"*|*Exception*|*"No such"*|*"not supported"*)
      echo "$gg_out"; return 1 ;;
  esac
  [ "$gg_rc" = 0 ] || { echo "$gg_out"; return 1; }
  cmd game mode "$(gf_mode_nm "$gg_mode")" "$gg_pkg" >/dev/null 2>&1
  echo "$gg_out"; return 0
}

# ---------------- TINGKAT 2: kunci Hz selama game ----------------
gf_same() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a != "" && b != "" && a + 0 == b + 0) }'; }

# gf_hz_pick <fps> -> Hz mode panel terkecil >= fps (utamakan kelipatan bulat), kosong kalau tidak ada
gf_hz_pick() {
  gh_fall=""; gh_best=""
  for gh_m in $(hz_modes); do
    [ "$gh_m" -ge "$1" ] 2>/dev/null || continue
    if [ $((gh_m % $1)) -eq 0 ]; then gh_best=$gh_m; break; fi
    [ -n "$gh_fall" ] || gh_fall=$gh_m
  done
  echo "${gh_best:-$gh_fall}"
}

gf_hz_lock() { # <hz>
  [ "$HZ" = 1 ] && return 2        # Refresh Rate (Hz) dikunci manual - jangan ditimpa
  : > "$GF_HZBK"
  for gl_k in peak_refresh_rate min_refresh_rate; do
    echo "$gl_k|$(settings get system "$gl_k" 2>/dev/null | tr -d '\r')" >> "$GF_HZBK"
    settings put system "$gl_k" "$1.0" 2>/dev/null
  done
  gf_same "$(settings get system peak_refresh_rate 2>/dev/null | tr -d '\r')" "$1"
}

gf_hz_unlock() {
  [ -s "$GF_HZBK" ] || { rm -f "$GF_HZBK"; return 0; }
  while IFS='|' read -r gu_k gu_v; do
    [ -n "$gu_k" ] || continue
    case "$gu_v" in
      ''|null) settings delete system "$gu_k" >/dev/null 2>&1 ;;
      *) settings put system "$gu_k" "$gu_v" 2>/dev/null ;;
    esac
  done < "$GF_HZBK"
  rm -f "$GF_HZBK"
}

# ---------------- penerapan ----------------
# gf_apply <paket> <profil> <fps> - echo hasil (baris pertama = ringkasan), return 0/1
gf_apply() {
  ga_pkg=$1; ga_prof=$2; ga_fps=$3
  gf_pkg_ok "$ga_pkg"   || { echo "GAGAL - nama paket tidak valid"; return 1; }
  gf_prof_ok "$ga_prof" || { echo "GAGAL - profil harus hemat|standar|performa"; return 1; }
  gf_fps_ok "$ga_fps"   || { echo "GAGAL - FPS harus angka 20-240"; return 1; }
  ga_mode=$(gf_mode_of "$ga_prof"); ga_note=""
  if [ -n "$(ds_get "$ga_pkg")" ] && [ "$ga_mode" != 2 ]; then
    ga_mode=2; ga_note=" (mode Performa dipakai karena game ini juga di-downscale)"
  fi
  ga_hznote=""
  if [ "$HZ" = 1 ] && [ "${HZ_TARGET:-0}" -gt 0 ] 2>/dev/null && [ "$HZ_TARGET" -lt "$ga_fps" ]; then
    ga_hznote=" Perhatian: Refresh Rate dikunci ${HZ_TARGET} Hz, FPS di atas itu tidak akan tercapai."
  fi

  ga_out=$(gf_gms_try "$ga_pkg" "$ga_mode" "$ga_fps")
  if [ $? = 0 ]; then
    echo "gms:$ga_pkg" > "$GF_ACTIVE_F"
    echo "FPS ${ga_fps} aktif untuk $ga_pkg (profil $ga_prof, per-app via GameManager)${ga_note}.${ga_hznote} Mulai ulang game bila belum terasa."
    return 0
  fi

  ga_hz=$(gf_hz_pick "$ga_fps")
  if [ -z "$ga_hz" ]; then
    echo "GAGAL - ROM tidak mendukung batas FPS per-app (${ga_out:-tanpa output}) dan tidak ada mode layar >= ${ga_fps} Hz"
    return 1
  fi
  gf_hz_lock "$ga_hz"; ga_rc=$?
  case "$ga_rc" in
    0) echo "hz:$ga_pkg" > "$GF_ACTIVE_F"
       echo "FPS ${ga_fps} untuk $ga_pkg dipasang lewat kunci layar ${ga_hz} Hz selama game (ROM tanpa batas FPS per-app; pembatas kasar, bukan batas pasti).${ga_hznote}"
       return 0 ;;
    2) echo "GAGAL - ROM tanpa batas FPS per-app dan Refresh Rate (Hz) sedang dikunci manual; matikan kunci Hz atau pakai Hz yang sama dengan FPS target"
       return 1 ;;
    *) gf_hz_unlock
       echo "GAGAL - GameManager: ${ga_out:-ditolak}; kunci ${ga_hz} Hz juga ditolak ROM"
       return 1 ;;
  esac
}

# gf_release <paket> - lepas override yang tercatat marker (aman dipanggil berulang)
gf_release() {
  [ -f "$GF_ACTIVE_F" ] || return 0
  gr_v=$(cat "$GF_ACTIVE_F" 2>/dev/null)
  gr_pkg=${gr_v#*:}; gr_tier=${gr_v%%:*}
  case "$gr_tier" in
    gms) ds_gms_reset "$gr_pkg" ;;
    hz)  gf_hz_unlock ;;
    *)   ds_gms_reset "$gr_pkg"; gf_hz_unlock ;;   # marker rusak -> lepas dua-duanya
  esac
  rm -f "$GF_ACTIVE_F"
  log_msg "GAMEFPS: override direvert ($gr_tier) untuk ${gr_pkg:-?}"
}

# dipanggil start_game() (lib/daemon.sh) - diam kalau game ini tidak punya data FPS
gamefps_apply() {
  [ "$FEAT_GAMEFPS" = 1 ] || return 0
  [ -n "$GAME_PKG" ] || return 0
  gfa_l=$(gf_get "$GAME_PKG")
  if [ -n "$gfa_l" ]; then
    gfa_prof=$(echo "$gfa_l" | cut -d'|' -f2)
    gfa_fps=$(echo "$gfa_l" | cut -d'|' -f3)
  elif [ "$(getprop sys.azenith.thermal.state 2>/dev/null)" = extreme ]; then
    # v1.0.44: selama mode ZAI-Turbo aktif, SEMUA game tanpa data FPS sendiri dipaksa 120 FPS (profil performa)
    gfa_prof=performa; gfa_fps=120
  else
    return 0
  fi
  gfa_msg=$(gf_apply "$GAME_PKG" "$gfa_prof" "$gfa_fps"); gfa_rc=$?
  log_msg "GAMEFPS: $GAME_PKG (${gfa_fps} FPS, $gfa_prof) - $gfa_msg"
  if [ "$gfa_rc" = 0 ]; then flog GAMEFPS OK "$gfa_msg"; else flog GAMEFPS ERR "$gfa_msg"; fi
  return $gfa_rc
}

# dipanggil azenith-thermal saat mode berubah: game yang SEDANG jalan langsung ikut (ZAI-Turbo -> 120, keluar -> lepas)
gamefps_mode_changed() {
  gm_pkg=$(cat "$RUNDIR/game" 2>/dev/null); [ -n "$gm_pkg" ] || return 0
  [ -n "$(gf_get "$gm_pkg")" ] && return 0     # game ini punya data FPS sendiri: tidak diubah
  GAME_PKG=$gm_pkg
  gf_release
  gamefps_apply >/dev/null 2>&1
  return 0
}

# dipanggil stop_game() & uninstall.sh - TANPA syarat FEAT_GAMEFPS (no-op bila tak ada override)
gamefps_revert() { gf_release; }

# ---------------- CLI: azenith-ai game fps ... ----------------
gf_cli() {
  case "$1" in
    set) # set <paket> <fps> [profil] [nama...]
      gc_pkg=$2; gc_fps=$3; gc_prof=${4:-standar}; gc_name=""
      gf_pkg_ok "$gc_pkg" || { echo "GAGAL - nama paket tidak valid"; return 1; }
      gf_fps_ok "$gc_fps" || { echo "GAGAL - FPS harus angka 20-240"; return 1; }
      gf_prof_ok "$gc_prof" || { echo "GAGAL - profil harus hemat|standar|performa"; return 1; }
      if [ $# -ge 5 ]; then shift 4; gc_name=$(gf_clean_name "$*"); fi
      [ -n "$gc_name" ] || gc_name=$gc_pkg
      gf_put "$gc_pkg" "$gc_fps" "$gc_prof" "$gc_name"
      # game sedang main sekarang? terapkan langsung (kalau tidak, berlaku di sesi game berikutnya)
      if [ "$(cat "$RUNDIR/game" 2>/dev/null)" = "$gc_pkg" ]; then
        gf_release
        gf_apply "$gc_pkg" "$gc_prof" "$gc_fps"; return $?
      fi
      echo "Data FPS disimpan: $gc_name - ${gc_fps} FPS (profil $gc_prof). Berlaku saat game ini dibuka." ;;
    del)
      gf_pkg_ok "$2" || { echo "GAGAL - nama paket tidak valid"; return 1; }
      gf_del "$2"
      [ "$(cat "$RUNDIR/game" 2>/dev/null)" = "$2" ] && gf_release
      echo "Data FPS dihapus: $2" ;;
    get)  gf_get "$2" ;;
    all) # all on [fps] | off | status   (v1.0.44: FPS global untuk SEMUA game tanpa data sendiri)
      load_conf
      case "$2" in
        on)  ga_f=${3:-${GAMEFPS_ALL_FPS:-120}}
             gf_fps_ok "$ga_f" || { echo "GAGAL - FPS harus angka 20-240"; return 1; }
             gf_setconf GAMEFPS_ALL_FPS "$ga_f"; gf_setconf GAMEFPS_ALL 1; gf_setconf FEAT_GAMEFPS 1
             echo "FPS semua game: AKTIF ${ga_f} FPS (game dengan data FPS sendiri tetap memakai datanya). Berlaku saat game dibuka." ;;
        off) gf_setconf GAMEFPS_ALL 0
             [ -n "$GAME_PKG" ] && [ -z "$(gf_get "$GAME_PKG")" ] && gf_release
             echo "FPS semua game: MATI" ;;
        *)   echo "gamefps_all=$GAMEFPS_ALL"; echo "gamefps_all_fps=$GAMEFPS_ALL_FPS" ;;
      esac ;;
    list|"") gf_list ;;
    *) echo "game fps all on [fps]|off|status | set <paket> <fps 20-240> [hemat|standar|performa] [nama...] | del <paket> | get <paket> | list" ;;
  esac
}
