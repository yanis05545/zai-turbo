#!/system/bin/sh
# =====================================================================
#  Zyrox v2 - lib/downscale.sh
#  Downscale resolusi render PER-GAME - 2 TINGKAT, dicoba berurutan:
#
#   TINGKAT 1 - GameManagerService (metode diambil & ditulis ulang dari
#   Comatoze/UltraPower gfx_scale_one(): `device_config put game_overlay
#   <pkg> mode=2` lalu `cmd game set --mode 2 --downscale <rasio> <pkg>`,
#   fallback `cmd game downscale <rasio> <pkg>`). NYATA per-app - hanya
#   render surface game itu yang mengecil, sisa sistem/launcher TIDAK
#   ikut terdampak. TAPI tergantung GameManagerService meng-implementasi
#   sub-command ini - sebagian ROM custom/vendor skin TIDAK (dispatcher-nya
#   balas "Unknown command: downscale", bukan "not supported" - artinya
#   sub-command itu memang tidak ada sama sekali di ROM itu, bukan ditolak
#   per-game, jadi TIDAK ADA kombinasi argumen apapun yang bisa menolong).
#
#   TINGKAT 2 - `wm size` + `wm density` (fallback UNIVERSAL, dipakai
#   OTOMATIS kalau Tingkat 1 kedeteksi "Unknown command"/tidak ada di ROM
#   ini). Bagian dari WindowManagerService inti, ada di hampir semua
#   Android - tapi GLOBAL (resolusi SELURUH LAYAR, bukan cuma 1 app)
#   selama game itu foreground, dikembalikan otomatis saat game berhenti.
#
#  Deteksi tingkat mana yang dipakai dilakukan OTOMATIS tiap ds_apply()
#  dipanggil (bukan dicoba sekali lalu diasumsikan selamanya) - supaya
#  tetap benar kalau user ganti ROM/update Android di tengah jalan.
# =====================================================================

DS_CONF="$DATADIR/downscale.conf"
DS_ACTIVE_F="$RUNDIR/ds_active"   # isi "tingkat:pkg" kalau override lagi aktif - dipakai downscale_revert tahu apa yang harus dibalikin

ds_ratio_valid() {
  case "$1" in 10|20|25|30|40|50|60|70|80|90|100) return 0 ;; *) return 1 ;; esac
}

ds_get() { [ -f "$DS_CONF" ] && sed -n "s/^$1=//p" "$DS_CONF" | tail -n 1; }

ds_list() { [ -f "$DS_CONF" ] && cat "$DS_CONF"; }

ds_set_conf() {
  [ -f "$DS_CONF" ] || : > "$DS_CONF"
  grep -vx "^$1=.*" "$DS_CONF" 2>/dev/null > "$DS_CONF.t"
  mv -f "$DS_CONF.t" "$DS_CONF" 2>/dev/null
  # 100% = resolusi asli -> tidak perlu disimpan/dipaksa ulang tiap sesi
  [ "$2" = 100 ] || echo "$1=$2" >> "$DS_CONF"
}

ds_remove_conf() {
  [ -f "$DS_CONF" ] || return 0
  grep -vx "^$1=.*" "$DS_CONF" 2>/dev/null > "$DS_CONF.t"
  mv -f "$DS_CONF.t" "$DS_CONF" 2>/dev/null
}

# ---------------------------------------------------------------------
# TINGKAT 1 - GameManagerService (Comatoze-style)
# ---------------------------------------------------------------------

# ds_gms_try <pkg> <rasio 0.xx> - echo = output mentah command, return
# 0 = framework MENERIMA (jangan dianggap "Unknown command"), 1 = ditolak.
ds_gms_try() {
  dg_pkg=$1; dg_ratio=$2
  cmd device_config put game_overlay "$dg_pkg" "mode=2" >/dev/null 2>&1
  dg_out=$(cmd game set --mode 2 --downscale "$dg_ratio" "$dg_pkg" 2>&1)
  dg_rc=$?
  case "$dg_out" in
    *"Unknown command"*|*"unknown command"*|*"not found"*|*"Invalid option"*) ;;
    *) [ "$dg_rc" = 0 ] && ! echo "$dg_out" | grep -qi "not supported" && { echo "$dg_out"; return 0; } ;;
  esac
  # fallback sub-command lama
  dg_out2=$(cmd game downscale "$dg_ratio" "$dg_pkg" 2>&1)
  dg_rc2=$?
  case "$dg_out2" in
    *"Unknown command"*|*"unknown command"*|*"not found"*|*Exception*|*"No such"*|*"Unknown sub command"*)
      echo "$dg_out2"; return 1 ;;
  esac
  if [ "$dg_rc2" = 0 ]; then echo "$dg_out2"; return 0; fi
  echo "$dg_out2"; return 1
}

ds_gms_reset() {
  dgr_pkg=$1
  cmd game reset --mode performance "$dgr_pkg" >/dev/null 2>&1
  cmd game reset --mode battery "$dgr_pkg" >/dev/null 2>&1
  cmd game reset "$dgr_pkg" >/dev/null 2>&1
  cmd game mode standard "$dgr_pkg" >/dev/null 2>&1
  cmd game downscale disable "$dgr_pkg" >/dev/null 2>&1
  device_config delete game_overlay "$dgr_pkg" >/dev/null 2>&1
}

# ---------------------------------------------------------------------
# TINGKAT 2 - wm size + wm density (fallback universal, global per sesi)
# ---------------------------------------------------------------------

ds_native_probe() {
  ds_np_sz=$(wm size 2>/dev/null | sed -n 's/^Physical size: *//p' | head -n 1)
  DS_NATIVE_W=${ds_np_sz%%x*}
  DS_NATIVE_H=${ds_np_sz#*x}
  DS_NATIVE_DPI=$(wm density 2>/dev/null | sed -n 's/^Physical density: *//p' | head -n 1)
  case "$DS_NATIVE_W" in ''|*[!0-9]*) DS_NATIVE_W="" ;; esac
  case "$DS_NATIVE_H" in ''|*[!0-9]*) DS_NATIVE_H="" ;; esac
  case "$DS_NATIVE_DPI" in ''|*[!0-9]*) DS_NATIVE_DPI="" ;; esac
  [ -n "$DS_NATIVE_W" ] && [ -n "$DS_NATIVE_H" ] && [ -n "$DS_NATIVE_DPI" ]
}

ds_wm_reset() { wm size reset >/dev/null 2>&1; wm density reset >/dev/null 2>&1; }

ds_wm_try() { # pct -> echo pesan, return 0/1, set DS_W/DS_H/DS_DPI kalau sukses
  dw_pct=$1
  ds_native_probe || { echo "gagal baca resolusi/density asli lewat 'wm size'/'wm density'"; return 1; }
  DS_W=$(( DS_NATIVE_W * dw_pct / 100 )); DS_W=$(( DS_W / 2 * 2 ))
  DS_H=$(( DS_NATIVE_H * dw_pct / 100 )); DS_H=$(( DS_H / 2 * 2 ))
  DS_DPI=$(( DS_NATIVE_DPI * dw_pct / 100 ))
  if [ "$DS_W" -lt 2 ] || [ "$DS_H" -lt 2 ] || [ "$DS_DPI" -lt 1 ]; then
    echo "hasil hitung resolusi/density tidak valid (asli=${DS_NATIVE_W}x${DS_NATIVE_H}@${DS_NATIVE_DPI}dpi)"
    return 1
  fi
  dw_sz_out=$(wm size "${DS_W}x${DS_H}" 2>&1); dw_sz_rc=$?
  dw_dp_out=$(wm density "$DS_DPI" 2>&1); dw_dp_rc=$?
  if [ "$dw_sz_rc" != 0 ] || [ "$dw_dp_rc" != 0 ]; then
    echo "wm size rc=$dw_sz_rc (${dw_sz_out:-tidak ada output}), wm density rc=$dw_dp_rc (${dw_dp_out:-tidak ada output})"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------
# ds_apply <pkg> <pct> - coba Tingkat 1 dulu, fallback Tingkat 2 kalau
# Tingkat 1 "Unknown command" (tidak ada di ROM ini). echo = pesan,
# return 0 = berhasil (tingkat manapun), 1 = dua-duanya gagal.
# ---------------------------------------------------------------------
ds_apply() {
  ds_a_pkg=$1; ds_a_pct=$2
  case "$ds_a_pkg" in ''|*[!A-Za-z0-9_.]*) echo "nama paket tidak valid"; return 1 ;; esac
  ds_ratio_valid "$ds_a_pct" || { echo "persen harus salah satu: 100/90/80/70/60/50/40/30/25/20/10"; return 1; }

  if [ "$ds_a_pct" = 100 ]; then
    ds_gms_reset "$ds_a_pkg"
    ds_wm_reset
    rm -f "$DS_ACTIVE_F"
    echo "downscale dimatikan untuk $ds_a_pkg (GameManagerService & wm size/density dikembalikan ke asli, restart game)"
    return 0
  fi

  ds_a_ratio=$(awk -v v="$ds_a_pct" 'BEGIN{printf "%.2f", v/100}')
  ds_a_g_out=$(ds_gms_try "$ds_a_pkg" "$ds_a_ratio")
  ds_a_g_rc=$?
  if [ "$ds_a_g_rc" = 0 ]; then
    echo "$ds_a_pkg:gms" > "$DS_ACTIVE_F"
    echo "diterapkan (GameManagerService, per-app): $ds_a_pkg -> ${ds_a_pct}% ($ds_a_g_out) - WAJIB restart game"
    return 0
  fi

  # Tingkat 1 tidak ada di ROM ini -> fallback Tingkat 2
  ds_a_w_out=$(ds_wm_try "$ds_a_pct")
  ds_a_w_rc=$?
  if [ "$ds_a_w_rc" = 0 ]; then
    echo "$ds_a_pkg:wm" > "$DS_ACTIVE_F"
    echo "diterapkan (wm size ${DS_W}x${DS_H}, wm density ${DS_DPI}; GameManagerService tidak tersedia di ROM ini - $ds_a_g_out): $ds_a_pkg -> ${ds_a_pct}%. WAJIB restart game. CATATAN: ini mengubah resolusi SELURUH LAYAR selama game ini foreground, dikembalikan otomatis saat game ditutup."
    return 0
  fi

  echo "GAGAL dua-duanya - GameManagerService: $ds_a_g_out | wm size/density: $ds_a_w_out"
  return 1
}

# downscale_apply - dipanggil dari start_game() (lib/daemon.sh) tiap sesi
# game baru. REAPPLY tiap sesi (bukan baca config sekali) - override di
# kedua tingkat non-persisten/bisa ditimpa balik, jadi dipaksa ulang tiap
# game yang di-set downscale-nya kedeteksi mulai.
downscale_apply() {
  [ "$FEAT_DOWNSCALE" = 1 ] || return 0
  [ -n "$GAME_PKG" ] || return 0
  ds_pct=$(ds_get "$GAME_PKG")
  [ -n "$ds_pct" ] || return 0
  ds_msg=$(ds_apply "$GAME_PKG" "$ds_pct")
  ds_rc=$?
  log_msg "P: downscale $GAME_PKG (${ds_pct}%) - $ds_msg"
  return $ds_rc
}

# downscale_revert - dipanggil dari stop_game() (lib/daemon.sh) & uninstall.sh.
# WAJIB TANPA SYARAT FEAT_DOWNSCALE: baca tingkat mana yang aktif dari
# marker, balikin cuma yang relevan. No-op kalau tidak ada override aktif.
downscale_revert() {
  [ -f "$DS_ACTIVE_F" ] || return 0
  dr_v=$(cat "$DS_ACTIVE_F" 2>/dev/null)
  dr_pkg=${dr_v%%:*}; dr_tier=${dr_v##*:}
  case "$dr_tier" in
    gms) ds_gms_reset "$dr_pkg" ;;
    wm)  ds_wm_reset ;;
    *)   ds_gms_reset "$dr_pkg"; ds_wm_reset ;;   # marker rusak/tidak dikenal -> reset dua-duanya, aman
  esac
  rm -f "$DS_ACTIVE_F"
  log_msg "P: downscale direvert ($dr_tier) untuk ${dr_pkg:-?}"
}
