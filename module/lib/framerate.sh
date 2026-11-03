#!/system/bin/sh
# =====================================================================
#  Zyrox - lib/framerate.sh : "Frame Rate" (60 / 90 / 120 / 144 FPS)
#
#  Mengunci refresh rate di SEMUA namespace Settings + melepas pembatas FPS
#  SurfaceFlinger/EGL supaya game bisa mencapai FPS tertinggi (batas atasnya
#  tetap panel: FPS tidak bisa melebihi Hz yang diekspos panel).
#
#   Settings (dengan backup nilai ASLI, "null" = dihapus saat OFF):
#     global : peak_refresh_rate, min_refresh_rate, low_power_refresh_rate=T.0,
#              adaptive_refresh_rate_enabled=0
#     system : peak_refresh_rate, min_refresh_rate=T.0, user_refresh_rate=T,
#              min_refresh_rate_battery_saver=T  (+ miui_refresh_rate kalau key itu ada)
#     secure : refresh_rate_mode=0, peak_refresh_rate=T.0
#   Properti (resetprop; yang ro.* / debug.sf.* dibaca SurfaceFlinger SAAT START
#   -> juga diset di post-fs-data lewat frm_boot_props; efek penuh setelah reboot):
#     debug.sf.set_idle_timer_ms=0  debug.sf.disable_backpressure=1
#     debug.sf.fusion.hrr=1  debug.egl.swapinterval=0
#     ro.surface_flinger.max_frame_buffer_acquired_buffers=3
#     debug.sf.hw=1  debug.egl.hw=1
#   + ro.surface_flinger.use_content_detection_for_refresh_rate=false (sama seperti fitur Refresh Rate)
#
#  TIDAK DILAKUKAN (sengaja): "sqlite3 ... settings_system.xml". Berkas itu BUKAN database
#  SQLite (XML, di Android 12+ berformat ABX biner); menulisnya langsung merusak Settings Provider
#  dan hilang saat provider menulis ulang. `settings put` di atas sudah menulis lewat jalur resmi.
#
#  ANTI-BENTROK dengan fitur lain di modul ini:
#   - Refresh Rate (Hz): memakai key system peak/min yang SAMA -> SALING MENGGANTIKAN. Mengaktifkan
#     salah satu otomatis mematikan yang lain (nilai asli dipulihkan dulu, baru ditimpa) sehingga
#     backup "nilai asli" tidak pernah tercemar nilai fitur lain. Prop content-detection dipakai
#     bersama (satu berkas backup, aman karena tidak pernah aktif bersamaan).
#   - Kunci Hz saat game (FEAT_REFRESH, misc.sh): dilewati selama Frame Rate aktif.
#   - Perf Lite: sudah memasang debug.sf.hw / debug.egl.hw. Prop yang SUDAH bernilai target atau
#     dimiliki fitur lain aktif TIDAK disentuh dan TIDAK ikut dipulihkan oleh Frame Rate.
#   - SF_BOOT_PROPS (misc.sh): memiliki debug.sf.disable_backpressure kalau aktif -> dilewati.
#   - Pemulihan prop hanya kalau nilainya masih nilai kita (tidak menimpa perubahan pihak lain).
#
#  Konfigurasi di conf:  FRAMERATE=0|1   FRAMERATE_TARGET=<angka>|0 (0 = Hz tertinggi panel)
# =====================================================================

FRM_BK="$DATADIR/framerate_backup"         # ns/key|nilai_asli
FRM_PBK="$DATADIR/framerate_prop_backup"   # prop|nilai_asli|nilai_kita  (HANYA prop yang benar-benar kita ubah)
FRM_PROPS="debug.sf.set_idle_timer_ms=0 debug.sf.disable_backpressure=1 debug.sf.fusion.hrr=1 debug.egl.swapinterval=0 ro.surface_flinger.max_frame_buffer_acquired_buffers=3 debug.sf.hw=1 debug.egl.hw=1"

# 0 kalau dua angka sama secara numerik (120 == 120.0)
frm_same() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a != "" && b != "" && a + 0 == b + 0) }'; }

# settings put dengan backup nilai asli (sekali) + baca-balik; hitung diterima/ditolak
frm_put() { # ns key val
  grep -q "^$1/$2|" "$FRM_BK" 2>/dev/null || echo "$1/$2|$(settings get "$1" "$2" 2>/dev/null | tr -d '\r')" >> "$FRM_BK"
  settings put "$1" "$2" "$3" 2>/dev/null
  if frm_same "$(settings get "$1" "$2" 2>/dev/null | tr -d '\r')" "$3"; then FM_OK=$((FM_OK + 1)); else FM_BAD="$FM_BAD $1/$2"; fi
}

frm_apply_settings() { # $1 = hz bulat
  fm_i=$1; fm_f="$1.0"
  frm_put global peak_refresh_rate "$fm_f"
  frm_put global min_refresh_rate "$fm_f"
  frm_put global low_power_refresh_rate "$fm_f"
  frm_put global adaptive_refresh_rate_enabled 0
  frm_put system peak_refresh_rate "$fm_f"
  frm_put system min_refresh_rate "$fm_f"
  frm_put system user_refresh_rate "$fm_i"
  frm_put system min_refresh_rate_battery_saver "$fm_i"
  fm_v=$(settings get system miui_refresh_rate 2>/dev/null | tr -d '\r')
  case "$fm_v" in ''|null) : ;; *) frm_put system miui_refresh_rate "$fm_i" ;; esac
  frm_put secure refresh_rate_mode 0
  frm_put secure peak_refresh_rate "$fm_f"
}

frm_restore_settings() {
  [ -s "$FRM_BK" ] || { rm -f "$FRM_BK"; return 0; }
  while IFS='|' read -r fm_k fm_v; do
    [ -n "$fm_k" ] || continue
    fm_ns=${fm_k%%/*}; fm_key=${fm_k#*/}
    case "$fm_v" in
      ''|null) settings delete "$fm_ns" "$fm_key" >/dev/null 2>&1 ;;
      *) settings put "$fm_ns" "$fm_key" "$fm_v" 2>/dev/null ;;
    esac
  done < "$FRM_BK"
  rm -f "$FRM_BK"
}

# 0 = prop ini sedang dimiliki fitur lain yang AKTIF (jangan disentuh / dipulihkan)
frm_prop_guarded() {
  case "$1" in
    debug.sf.hw|debug.egl.hw) [ "$PERFLITE" = 1 ] && return 0 ;;
    debug.sf.disable_backpressure) [ "$FEAT_SURFACEFLINGER" = 1 ] && [ "$SF_BOOT_PROPS" = 1 ] && return 0 ;;
  esac
  return 1
}

frm_resetprop() { # prop val
  if command -v resetprop >/dev/null 2>&1; then resetprop "$1" "$2" 2>/dev/null; else setprop "$1" "$2" 2>/dev/null; fi
}

frm_set_props() {
  FM_PSET=0; FM_PSKIP=""
  for fm_kv in $FRM_PROPS; do
    fm_pk=${fm_kv%%=*}; fm_pv=${fm_kv#*=}
    fm_cur=$(getprop "$fm_pk" 2>/dev/null)
    if ! grep -q "^$fm_pk|" "$FRM_PBK" 2>/dev/null; then
      # belum milik kita: lewati kalau fitur lain yang aktif memilikinya, atau nilainya sudah target
      if frm_prop_guarded "$fm_pk" || [ "$fm_cur" = "$fm_pv" ]; then FM_PSKIP="$FM_PSKIP $fm_pk"; continue; fi
      echo "$fm_pk|$fm_cur|$fm_pv" >> "$FRM_PBK"
    fi
    frm_resetprop "$fm_pk" "$fm_pv"
    FM_PSET=$((FM_PSET + 1))
  done
}

frm_restore_props() {
  if [ -s "$FRM_PBK" ]; then
    while IFS='|' read -r fm_pk fm_po fm_pv; do
      [ -n "$fm_pk" ] || continue
      frm_prop_guarded "$fm_pk" && continue
      [ "$(getprop "$fm_pk" 2>/dev/null)" = "$fm_pv" ] || continue
      if [ -n "$fm_po" ]; then frm_resetprop "$fm_pk" "$fm_po"
      else command -v resetprop >/dev/null 2>&1 && resetprop --delete "$fm_pk" 2>/dev/null; fi
    done < "$FRM_PBK"
  fi
  rm -f "$FRM_PBK"
}

frm_peak_ok() { frm_same "$(settings get system peak_refresh_rate 2>/dev/null | tr -d '\r')" "$1"; }

frm_rollback() {
  hz_guard_stop
  frm_restore_settings; frm_restore_props; hz_restore_prop; hz_pref_clear
  hz_setconf FRAMERATE 0
}

# frm_on [fps] - kosong = FRAMERATE_TARGET, 0/kosong = Hz tertinggi panel
frm_on() {
  load_conf
  fm_modes=$(hz_modes)
  fm_t=${1:-$FRAMERATE_TARGET}
  case "$fm_t" in ''|0) fm_t=$(hz_max) ;; esac
  case "$fm_t" in ''|*[!0-9]*) echo "Frame Rate: GAGAL - target harus angka (60 / 90 / 120 / 144)"; return 1 ;; esac
  fm_listed=1; hz_in_modes "$fm_t" "$fm_modes" || fm_listed=0
  # saling menggantikan dengan fitur Refresh Rate (key peak/min sama): pulihkan nilai asli DULU
  fm_hznote=0
  if [ "$HZ" = 1 ]; then hz_off >/dev/null 2>&1; fm_hznote=1; fi
  FM_OK=0; FM_BAD=""
  frm_apply_settings "$fm_t"
  frm_set_props
  hz_set_prop                       # content detection OFF (sama seperti fitur Refresh Rate)
  sleep 1
  frm_peak_ok "$fm_t" || { settings put system peak_refresh_rate "$fm_t.0" 2>/dev/null; sleep 1; }
  if ! frm_peak_ok "$fm_t"; then
    fm_seen=$(hz_get peak_refresh_rate)
    frm_rollback
    flog FRAMERATE ERR "system peak_refresh_rate tidak terbaca balik ${fm_t} (terbaca $fm_seen)"
    echo "Frame Rate: GAGAL - ROM menolak peak_refresh_rate (terbaca $fm_seen, diminta $fm_t); dikembalikan ke semula"
    return 1
  fi
  # min dikunci SESUDAH peak mapan (ROM sering mereset min ke 60 tepat setelah peak berubah)
  fm_minnote=""
  hz_lock_min "$fm_t" global || fm_minnote="system/min_refresh_rate ditimpa ROM di $(hz_get min_refresh_rate); penjaga latar akan memasangnya ulang"
  fm_pref=tidak; hz_pref_mode "$fm_t" && fm_pref=ya
  sleep 1
  fm_act=$(hz_active)
  if [ "$fm_listed" = 0 ] && [ -n "$fm_act" ] && [ "$fm_act" != "$fm_t" ]; then
    frm_rollback
    flog FRAMERATE ERR "${fm_t} tidak terdaftar ($fm_modes) & panel tetap ${fm_act}Hz"
    echo "Frame Rate: GAGAL - ${fm_t} tidak didukung panel/HAL (mode terbaca: ${fm_modes:-kosong}; layar tetap ${fm_act}Hz). FPS tidak bisa melebihi Hz panel."
    return 1
  fi
  hz_setconf FRAMERATE 1; hz_setconf FRAMERATE_TARGET "$fm_t"
  hz_guard_start
  flog FRAMERATE OK "AKTIF ${fm_t}FPS settings_ok=$FM_OK ditolak=[${FM_BAD# }] prop_diset=$FM_PSET aktif=${fm_act:-?}Hz"
  log_msg "FRAMERATE: AKTIF ${fm_t}"
  echo "Frame Rate: AKTIF ${fm_t} FPS (system peak_refresh_rate terverifikasi)"
  echo "settings diterima: $FM_OK  |  ditolak ROM:${FM_BAD:- tidak ada}"
  echo "prop diset: $FM_PSET  |  dilewati (sudah target / milik fitur lain):${FM_PSKIP:- tidak ada}"
  [ -n "$fm_minnote" ] && echo "catatan: $fm_minnote"
  [ "$fm_hznote" = 1 ] && echo "catatan: Refresh Rate (Hz) dimatikan - Frame Rate memakai key yang sama dan sudah mencakupnya"
  [ "$fm_listed" = 0 ] && echo "catatan: ${fm_t}Hz tidak ada di daftar mode terbaca, tetapi layar menjalankan ${fm_act:-?}Hz"
  [ -n "$fm_act" ] && [ "$fm_act" != "$fm_t" ] && echo "catatan: layar sekarang ${fm_act}Hz; Android memilih mode saat ada konten yang butuh refresh. Prop SurfaceFlinger (idle timer, content detection, ro.*) baru penuh setelah REBOOT"
  frm_status
  return 0
}

frm_off() {
  load_conf
  hz_guard_stop
  frm_restore_settings
  frm_restore_props
  hz_restore_prop
  hz_pref_clear
  hz_setconf FRAMERATE 0
  flog FRAMERATE OK "MATI nilai dikembalikan"
  log_msg "FRAMERATE: MATI"
  echo "Frame Rate: MATI (settings & prop dikembalikan ke nilai asal; prop SurfaceFlinger efektif setelah reboot)"
  frm_status
}

# frm_set <fps> : kalau AKTIF langsung diterapkan, kalau mati hanya disimpan sebagai target
frm_set() {
  load_conf
  case "$1" in ''|*[!0-9]*) echo "azenith-ai framerate set <angka FPS>"; return 1 ;; esac
  if [ "$FRAMERATE" = 1 ]; then frm_on "$1"; return $?; fi
  hz_setconf FRAMERATE_TARGET "$1"
  echo "Frame Rate: target disimpan ${1} FPS (fitur belum aktif - nyalakan untuk menerapkan)"
}

# service.sh, setelah boot selesai (2x): Settings kadang direset ROM saat boot/unlock pertama
frm_boot_apply() {
  load_conf
  [ "$FRAMERATE" = 1 ] || return 0
  fm_t=$FRAMERATE_TARGET
  case "$fm_t" in ''|0) fm_t=$(hz_max) ;; esac
  case "$fm_t" in ''|*[!0-9]*) return 1 ;; esac
  FM_OK=0; FM_BAD=""
  frm_apply_settings "$fm_t"
  frm_set_props
  hz_set_prop
  sleep 1
  hz_lock_min "$fm_t" global >/dev/null 2>&1
  hz_pref_mode "$fm_t" >/dev/null 2>&1
  hz_guard_start
  frm_peak_ok "$fm_t" && flog FRAMERATE OK "boot: terapkan ulang ${fm_t} (settings_ok=$FM_OK aktif=$(hz_active))" || flog FRAMERATE ERR "boot: peak tidak terbaca balik ${fm_t}"
}

# post-fs-data (SEBELUM SurfaceFlinger start): hanya prop; tanpa settings/dumpsys (belum siap)
frm_boot_props() {
  [ "$FRAMERATE" = 1 ] || return 0
  frm_set_props
  hz_set_prop
  log_msg "FRAMERATE: prop SurfaceFlinger/EGL diset (boot) diset=$FM_PSET"
}

frm_status() {
  load_conf
  echo "FRAMERATE=$FRAMERATE  target=${FRAMERATE_TARGET}  sys_peak=$(hz_get peak_refresh_rate)  sys_min=$(hz_get min_refresh_rate)  global_peak=$(settings get global peak_refresh_rate 2>/dev/null | tr -d '\r')  aktif=$(hz_active)"
}

frm_diag() {
  load_conf
  echo "== aktif (renderFrameRate): $(hz_active)  | mode terbaca: $(hz_modes)"
  for fd_k in global/peak_refresh_rate global/min_refresh_rate global/low_power_refresh_rate global/adaptive_refresh_rate_enabled \
              system/peak_refresh_rate system/min_refresh_rate system/user_refresh_rate system/min_refresh_rate_battery_saver \
              secure/refresh_rate_mode secure/peak_refresh_rate; do
    echo "$fd_k = $(settings get "${fd_k%%/*}" "${fd_k#*/}" 2>/dev/null | tr -d '\r')"
  done
  for fd_kv in $FRM_PROPS; do
    fd_o=""; frm_prop_guarded "${fd_kv%%=*}" && fd_o="  [milik fitur lain]"
    echo "${fd_kv%%=*} = $(getprop "${fd_kv%%=*}" 2>/dev/null)  (target ${fd_kv#*=})$fd_o"
  done
  echo "HZ=$HZ FRAMERATE=$FRAMERATE PERFLITE=$PERFLITE SF_BOOT_PROPS=$SF_BOOT_PROPS"
}
