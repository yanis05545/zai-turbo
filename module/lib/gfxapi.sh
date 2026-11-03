#!/system/bin/sh
# =====================================================================
#  Zyrox v2 - lib/gfxapi.sh
#  Graphics API UNIVERSAL (v2.0): dulu per-game (game_gfxapi.conf, dipicu di
#  start_game()/direvert di cleanup_all() tiap game berhenti), SEKARANG satu
#  toggle SELURUH SISTEM - begitu diaktifkan langsung berlaku untuk semua
#  app (bukan cuma game di daftar), non-stop (TIDAK direvert otomatis saat
#  game berhenti - sama seperti Thermal Lock Daily/Network Booster), dan
#  otomatis kedeteksi aplikasi info sistem seperti DevCheck karena yang
#  ditulis adalah node/property SISTEM yang sama yang dibaca aplikasi itu:
#    - debug.hwui.renderer         -> "Renderer" (Skia/GL atau Skia/Vulkan)
#    - angle_gl_driver_all_angle   -> status ANGLE (Settings.Global, SAMA
#      dengan toggle Developer Options "Angle for all") berlaku utk SEMUA
#      paket, bukan cuma pkg tertentu lewat angle_gl_driver_selection_*
#    - debug.angle.backend         -> backend ANGLE (opengles/vulkan)
#
#  Backend yang dipilih user (vulkan/skiavk/skiagl - v1.0.11: angle & native
#  dihapus dari pilihan) dicoba lalu diverifikasi BALIK dari node asli; kalau
#  gagal, langsung dilaporkan GAGAL apa adanya - TIDAK ada fallback diam-diam
#  ke backend lain lagi, supaya jelas backend mana yang benar-benar tidak
#  didukung device ini.
#
#  Non-persisten per-boot (debug.* prop & Settings.Global di atas hilang
#  tiap reboot) - diterapkan ulang otomatis oleh service.sh kalau
#  GFX_UNIVERSAL=1 di config (lihat blok "Graphics API Universal" di
#  service.sh), sama seperti Network Booster/Thermal Lock Daily.
# =====================================================================

GU_PROP_BK="$DATADIR/gfx_universal_props"      # k|nilai_asli untuk debug.hwui.renderer & debug.angle.backend
GU_SET_BK="$DATADIR/gfx_universal_settings"    # k|nilai_asli untuk Settings.Global (angle_gl_driver_all_angle)

GFX_APIS="vulkan skiavk skiagl"

gfx_valid_api() {
  case "$1" in
    vulkan|skiavk|skiagl) return 0 ;;
    *) return 1 ;;
  esac
}

gu_setconf() { # gu_setconf KEY VAL
  if grep -q "^$1=" "$CONF" 2>/dev/null; then sed -i "s/^$1=[^ #]*/$1=$2/" "$CONF"
  else echo "$1=$2" >> "$CONF"; fi
}

# ---------------------------------------------------------------------
# gfx_driver_info() - TAMBAHAN MURNI, tidak mengubah gu_try/gu_on/gu_off.
# Panggil dv_gpu_driver_files() (lib/devinfo.sh) untuk cetak file driver
# grafis apa saja yang BENAR-BENAR ada di device ini (/system/lib64/
# libhwui.so, libEGL.so, libGLESv2.so, libvulkan.so, dan driver vendor di
# /vendor/lib64/egl|hw seperti libGLES_adreno/mali.so, vulkan.adreno/
# mali.so). Murni informasi untuk WebUI/testlog - tidak dipakai untuk
# memblokir/mengubah alur gu_try yang sudah ada.
# ---------------------------------------------------------------------
gfx_driver_info() {
  command -v dv_gpu_driver_files >/dev/null 2>&1 || return 0
  dv_gpu_driver_files
  echo "libhwui.so         : ${GV_HWUI:-tidak ditemukan}"
  echo "libEGL.so           : ${GV_EGL:-tidak ditemukan}"
  echo "libGLESv2.so        : ${GV_GLESV2:-tidak ditemukan}"
  echo "libvulkan.so (base) : ${GV_VULKAN_BASE:-tidak ditemukan}"
  echo "driver GLES vendor   : ${GV_VENDOR_GLES:-tidak ditemukan}"
  echo "driver Vulkan vendor : ${GV_VENDOR_VULKAN:-tidak ditemukan}"
}

# ---------------------------------------------------------------------
# Jalur tulis+backup MILIK SENDIRI (GU_PROP_BK/GU_SET_BK, bukan PROPSTACK
# session punya perf.sh dkk) - supaya TIDAK ikut dibongkar cleanup_all()
# tiap game berhenti/keluar foreground/daemon idle (sama persis alasan
# Thermal Lock Daily punya TD_* sendiri, lihat catatan di lib/thermaldaily.sh)
# ---------------------------------------------------------------------
gu_prop_write() { # gu_prop_write <prop> <nilai>  - tulis nilai baru
  gw_k=$1; gw_v=$2
  grep -q "^$gw_k|" "$GU_PROP_BK" 2>/dev/null || echo "$gw_k|$(getp "$gw_k")" >> "$GU_PROP_BK"
  if command -v resetprop >/dev/null 2>&1; then resetprop "$gw_k" "$gw_v" 2>/dev/null
  else setprop "$gw_k" "$gw_v" 2>/dev/null; fi
}
gu_prop_clear() { # gu_prop_clear <prop> - hapus override (kembali ke tidak-diset)
  gc_k=$1
  grep -q "^$gc_k|" "$GU_PROP_BK" 2>/dev/null || echo "$gc_k|$(getp "$gc_k")" >> "$GU_PROP_BK"
  if command -v resetprop >/dev/null 2>&1; then resetprop --delete "$gc_k" 2>/dev/null || resetprop "$gc_k" "" 2>/dev/null
  else setprop "$gc_k" "" 2>/dev/null; fi
}
gu_prop_restore() {
  [ -s "$GU_PROP_BK" ] || { : > "$GU_PROP_BK"; return 0; }
  while IFS='|' read -r gr_k gr_v; do
    [ -n "$gr_k" ] || continue
    if [ -n "$gr_v" ]; then
      if command -v resetprop >/dev/null 2>&1; then resetprop "$gr_k" "$gr_v" 2>/dev/null
      else setprop "$gr_k" "$gr_v" 2>/dev/null; fi
    else
      if command -v resetprop >/dev/null 2>&1; then resetprop --delete "$gr_k" 2>/dev/null
      else setprop "$gr_k" "" 2>/dev/null; fi
    fi
  done < "$GU_PROP_BK"
  : > "$GU_PROP_BK"
}

gu_angle_all() { # gu_angle_all <0|1> - Settings.Global angle_gl_driver_all_angle (SEMUA paket)
  grep -q "^angle_gl_driver_all_angle|" "$GU_SET_BK" 2>/dev/null || \
    echo "angle_gl_driver_all_angle|$(settings get global angle_gl_driver_all_angle 2>/dev/null)" >> "$GU_SET_BK"
  settings put global angle_gl_driver_all_angle "$1" 2>/dev/null
}
gu_settings_restore() {
  [ -s "$GU_SET_BK" ] || { : > "$GU_SET_BK"; return 0; }
  while IFS='|' read -r gs_k gs_v; do
    [ -n "$gs_k" ] || continue
    case "$gs_v" in
      ''|null) settings delete global "$gs_k" >/dev/null 2>&1 ;;
      *) settings put global "$gs_k" "$gs_v" 2>/dev/null ;;
    esac
  done < "$GU_SET_BK"
  : > "$GU_SET_BK"
}

# gu_try <api> -> 0 kalau berhasil diterapkan SELURUH SISTEM & lolos
# verifikasi (baca BALIK dari node asli, bukan cuma "perintah tulis sukses")
gu_try() {
  gt_api=$1
  case "$gt_api" in
    skiagl|skiavk)
      gu_prop_write debug.hwui.renderer "$gt_api"
      gu_prop_clear debug.angle.backend
      gu_angle_all 0
      [ "$(getp debug.hwui.renderer)" = "$gt_api" ]
      ;;
    vulkan)
      # Vulkan: renderer HWUI = Skia/Vulkan SELURUH SISTEM + paksa ANGLE utk
      # SEMUA app (translasi GLES -> Vulkan) - dua jalur sekaligus, best-effort.
      gu_prop_write debug.hwui.renderer skiavk
      gu_prop_write debug.angle.backend vulkan
      gu_angle_all 1
      [ "$(getp debug.hwui.renderer)" = skiavk ] && \
        [ "$(settings get global angle_gl_driver_all_angle 2>/dev/null)" = 1 ]
      ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------
# gu_on <api> - AKTIFKAN Graphics API Universal (berlaku SELURUH SISTEM,
# non-stop sampai dimatikan manual lewat gu_off, tahan reboot lewat
# service.sh). TIDAK ADA fallback diam-diam ke backend lain (angle/native
# sudah dihapus dari daftar pilihan v1.0.11) - kalau <api> yang diminta
# gagal diverifikasi, langsung dilaporkan GAGAL apa adanya supaya kelihatan
# jelas backend mana yang benar-benar tidak didukung device ini, bukan
# diam-diam diganti ke backend lain tanpa sepengetahuan user.
# ---------------------------------------------------------------------
gu_on() {
  gon_api=$1
  gfx_valid_api "$gon_api" || { echo "API tidak dikenal (vulkan|skiavk|skiagl)"; return 1; }
  load_conf
  : > "$GU_PROP_BK" 2>/dev/null
  : > "$GU_SET_BK" 2>/dev/null

  if ! gu_try "$gon_api"; then
    gu_prop_restore; gu_settings_restore
    log_msg "GFX UNIVERSAL: '$gon_api' gagal diterapkan/diverifikasi di device ini"
    echo "Graphics API Universal: GAGAL menerapkan '$gon_api' - device/ROM ini kemungkinan tidak mendukung override backend tersebut. Tidak dialihkan otomatis ke backend lain."
    gu_status
    return 1
  fi

  gu_setconf GFX_UNIVERSAL 1
  gu_setconf GFX_UNIVERSAL_API "$gon_api"
  log_msg "GFX UNIVERSAL: AKTIF seluruh sistem -> $gon_api"
  echo "Graphics API Universal: AKTIF -> $gon_api (berlaku SELURUH SISTEM, bukan per-game, langsung tanpa reboot)"
  echo "Tahan reboot: diterapkan ulang otomatis oleh service.sh. Otomatis kedeteksi di aplikasi info sistem (DevCheck dkk) lewat debug.hwui.renderer/ANGLE."
  echo "CATATAN: debug.hwui.renderer baru BENAR-BENAR dipakai app setelah app itu di-restart (force-stop lalu buka lagi, atau reboot) - mengubah prop ini tidak langsung memaksa app yang SUDAH berjalan pindah renderer."
  gu_status
}

# gu_off - MATIKAN, kembalikan ke default sistem (dibaca balik lewat backup
# GU_PROP_BK/GU_SET_BK, bukan diasumsikan "kosong")
gu_off() {
  load_conf
  gu_prop_restore
  gu_settings_restore
  gu_setconf GFX_UNIVERSAL 0
  log_msg "GFX UNIVERSAL: MATI (dikembalikan ke default sistem)"
  echo "Graphics API Universal: MATI (debug.hwui.renderer & ANGLE dikembalikan ke default sistem)"
  gu_status
}

gu_status() {
  load_conf
  echo "GFX_UNIVERSAL=$GFX_UNIVERSAL  api=$GFX_UNIVERSAL_API  debug.hwui.renderer=$(getp debug.hwui.renderer)  debug.angle.backend=$(getp debug.angle.backend)  angle_gl_driver_all_angle=$(settings get global angle_gl_driver_all_angle 2>/dev/null)"
}

# ---------------------------------------------------------------------
# gfx_test - coba SEMUA Graphics API satu-satu SELURUH SISTEM & baca BALIK
# nilai NYATA dari prop/Settings.Global (bukan cuma "perintah tulis
# sukses") - supaya ketahuan tiap backend beneran diterapkan device ini
# atau cuma gimik yang gagal diverifikasi. Di akhir, state dikembalikan:
# kalau Graphics API Universal sedang AKTIF, dikembalikan ke pilihan aktif
# user (bukan dimatikan); kalau tidak aktif, direvert ke default sistem.
# ---------------------------------------------------------------------
gfx_test() {
  load_conf
  testlog_begin gfxapi
  testlog "Mode uji: Graphics API Universal (berlaku SELURUH SISTEM, bukan per-game)"
  testlog "Urutan backend yang dicoba: $GFX_APIS"
  testlog ""
  testlog "--- Deteksi file driver grafis (tambahan, info saja) ---"
  while IFS= read -r gt2_dline; do testlog "$gt2_dline"; done <<EOF
$(gfx_driver_info)
EOF
  testlog ""
  gt2_was_on=$GFX_UNIVERSAL; gt2_was_api=$GFX_UNIVERSAL_API
  : > "$GU_PROP_BK" 2>/dev/null
  : > "$GU_SET_BK" 2>/dev/null
  for gt2_api in $GFX_APIS; do
    if gu_try "$gt2_api"; then
      case "$gt2_api" in
        skiagl|skiavk) gt2_real="debug.hwui.renderer=$(getp debug.hwui.renderer)" ;;
        vulkan)        gt2_real="debug.hwui.renderer=$(getp debug.hwui.renderer) debug.angle.backend=$(getp debug.angle.backend) angle_all=$(settings get global angle_gl_driver_all_angle 2>/dev/null)" ;;
      esac
      testlog "[NYATA-BEKERJA] $gt2_api -> readback cocok, node sistem benar2 berubah ($gt2_real)"
    else
      testlog "[GAGAL/GIMIK] $gt2_api -> ditulis tapi readback TIDAK cocok (device/ROM ini kemungkinan tidak dukung backend ini, atau butuh restart app/reboot)"
    fi
  done
  gu_prop_restore
  gu_settings_restore
  if [ "$gt2_was_on" = 1 ] && [ -n "$gt2_was_api" ]; then
    gu_try "$gt2_was_api" >/dev/null 2>&1
    testlog ""
    testlog "Selesai - dikembalikan ke pengaturan aktif sebelumnya ($gt2_was_api)."
  else
    testlog ""
    testlog "Selesai - direvert ke default sistem (tidak permanen, Graphics API Universal memang sedang mati)."
  fi
  testlog_end
}
