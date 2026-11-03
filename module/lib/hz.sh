#!/system/bin/sh
# =====================================================================
#  Zyrox - lib/hz.sh : "Refresh Rate (Hz)"
#
#  Toggle TERSENDIRI di tab Fitur. Supaya angka Hz yang dibaca aplikasi seperti
#  DevCheck benar-benar berubah, tiga lapis dikerjakan sekaligus:
#
#   1. API Android (SurfaceFlinger/DisplayManager) - DevCheck TIDAK membaca sysfs
#      kernel mentah, tapi bertanya ke framework. Maka nilai target disuntikkan ke
#      System Settings:  peak_refresh_rate  &  min_refresh_rate
#      (+ user_refresh_rate / miui_refresh_rate HANYA kalau key itu sudah ada di ROM).
#      Dipasang ulang tiap boot oleh service.sh (hz_boot_apply).
#
#   2. Validasi mode yang DIDUKUNG panel (level HAL). Target WAJIB ada di daftar
#      mode `dumpsys display` (DisplayModeRecord / supportedModes). Kalau tidak ada,
#      fitur GAGAL APA ADANYA - tidak pura-pura berhasil. Mode yang tidak diekspos
#      driver panel / DTBO / kernel TIDAK akan pernah terdeteksi DevCheck.
#
#   3. Matikan Content Detection Refresh Rate (SurfaceFlinger):
#        ro.surface_flinger.use_content_detection_for_refresh_rate=false
#      Prop ro.* dibaca SurfaceFlinger SAAT START, jadi diset lewat resetprop di
#      post-fs-data (hz_boot_props) - hanya kalau HZ=1, supaya bisa dimatikan lagi
#      (system.prop statis tidak bisa dibatalkan dari toggle). Efeknya penuh setelah reboot.
#
#  hz_off mengembalikan Settings ke nilai ASLI (dibackup sekali) dan prop ke nilai awal
#  (prop baru efektif di SurfaceFlinger setelah reboot).
#
#  4. (v1.0.23+) Mode tampilan pilihan pengguna: `cmd display set-user-preferred-display-mode W H HZ`
#     (Android 11+, diterima framework & tahan reboot) - best-effort, dilepas lagi saat OFF.
#
#  Keberhasilan = peak_refresh_rate terbaca balik = target (itu yang menentukan batas atas Hz).
#  min_refresh_rate ditulis juga, tapi sebagian ROM menimpanya balik ke 60 -> TIDAK dianggap gagal,
#  hanya dilaporkan.
#
#  Konfigurasi di conf:  HZ=0|1   HZ_TARGET=<angka Hz>|0 (0 = Hz tertinggi yang didukung)
# =====================================================================

HZ_BK="$DATADIR/hz_backup"            # key|nilai_asli (Settings.System), "null" = tadinya tidak ada
HZ_PROP_BK="$DATADIR/hz_prop_backup"  # nilai asli prop SurfaceFlinger (boleh kosong)
HZ_SF_PROP="ro.surface_flinger.use_content_detection_for_refresh_rate"

hz_setconf() { # hz_setconf KEY VAL
  if grep -q "^$1=" "$CONF" 2>/dev/null; then sed -i "s/^$1=[^ #]*/$1=$2/" "$CONF"
  else echo "$1=$2" >> "$CONF"; fi
}

# Daftar Hz yang diekspos panel/HAL ke framework, bulat, urut naik, dipisah spasi.
# Gabungan dua sumber (satu sumber saja sering tidak lengkap di ROM tertentu, mis. 90Hz hilang dari daftar):
#   dumpsys display (supportedModes / DisplayModeRecord / renderFrameRate aktif) + dumpsys SurfaceFlinger (baris mode HWC).
hz_modes() {
  hm_a=$(dumpsys display 2>/dev/null | grep -iE 'DisplayMode\{|DisplayModeRecord|supportedModes' \
         | grep -oE '(fps|refreshRate)=[0-9]+(\.[0-9]+)?' | sed 's/.*=//')
  hm_b=$(dumpsys SurfaceFlinger 2>/dev/null | grep -iE 'DisplayMode|hwcId|supportedModes' \
         | grep -oE '(fps|refreshRate|vsyncRate)=[0-9]+(\.[0-9]+)?' | sed 's/.*=//')
  hm_c=$(hz_active)
  printf '%s\n%s\n%s\n' "$hm_a" "$hm_b" "$hm_c" | awk 'NF { v = int($1 + 0.5); if (v >= 30 && v <= 480) print v }' | sort -n | uniq | tr '\n' ' ' | sed 's/ *$//'
}

# Hz yang SEDANG dijalankan layar (renderFrameRate di DisplayDeviceInfo) - kosong kalau tidak terbaca
hz_active() {
  dumpsys display 2>/dev/null | grep -oE 'renderFrameRate[ =][0-9]+(\.[0-9]+)?' | head -n 1 | sed 's/.*[ =]//' | awk 'NF { printf "%d", $1 + 0.5 }'
}

hz_diag() {
  echo "== aktif (renderFrameRate): $(hz_active)"
  echo "== mode terbaca: $(hz_modes)"
  echo "== baris mode dumpsys display:"
  dumpsys display 2>/dev/null | grep -iE 'DisplayMode\{|DisplayModeRecord|supportedModes' | cut -c1-220 | head -n 8
  echo "== baris mode SurfaceFlinger:"
  dumpsys SurfaceFlinger 2>/dev/null | grep -iE 'DisplayMode|hwcId|supportedModes' | cut -c1-220 | head -n 8
  echo "== settings: peak=$(hz_get peak_refresh_rate) min=$(hz_get min_refresh_rate)  prop=$(getprop "$HZ_SF_PROP" 2>/dev/null)"
}

hz_max() { hz_modes | tr ' ' '\n' | tail -n 1; }

hz_in_modes() { # hz_in_modes <hz> <daftar> -> 0 kalau ada
  for hi_m in $2; do [ "$hi_m" = "$1" ] && return 0; done
  return 1
}

hz_get() { # hz_get <key> -> nilai bulat Hz atau "null"/kosong
  hg_v=$(settings get system "$1" 2>/dev/null | tr -d '\r')
  case "$hg_v" in ''|null) echo null; return ;; esac
  echo "$hg_v" | awk '{ printf "%d", $1 + 0.5 }'
}

# tulis nilai ke Settings; backup nilai asli SEKALI (boot ulang tidak boleh menimpa backup)
hz_write_settings() { # $1 = hz
  hw_keys="peak_refresh_rate min_refresh_rate"
  # key vendor: HANYA disentuh kalau sudah ada di ROM ini (tidak membuat key baru yang artinya tidak jelas)
  for hw_vk in user_refresh_rate miui_refresh_rate; do
    hw_cur=$(settings get system "$hw_vk" 2>/dev/null | tr -d '\r')
    case "$hw_cur" in ''|null) : ;; *) hw_keys="$hw_keys $hw_vk" ;; esac
  done
  for hw_k in $hw_keys; do
    grep -q "^$hw_k|" "$HZ_BK" 2>/dev/null || echo "$hw_k|$(settings get system "$hw_k" 2>/dev/null | tr -d '\r')" >> "$HZ_BK"
    settings put system "$hw_k" "$1" 2>/dev/null
  done
}

hz_set_prop() { # resetprop in-memory; backup nilai awal sekali
  [ -e "$HZ_PROP_BK" ] || getprop "$HZ_SF_PROP" 2>/dev/null > "$HZ_PROP_BK"
  if command -v resetprop >/dev/null 2>&1; then resetprop "$HZ_SF_PROP" false 2>/dev/null
  else setprop "$HZ_SF_PROP" false 2>/dev/null; fi
}

hz_verify() { # hz_verify <hz> -> 0 kalau PEAK terbaca balik = hz (penentu keberhasilan)
  [ "$(hz_get peak_refresh_rate)" = "$1" ]
}
hz_verify_min() { [ "$(hz_get min_refresh_rate)" = "$1" ]; }

# min_refresh_rate: banyak ROM menimpanya balik ke 60 sesaat SETELAH peak berubah. Maka min ditulis SESUDAH peak
# mapan, dibaca balik, dan diulang (maks 4x, jeda 1 dtk). $2 = "global" -> min global ikut ditulis.
hz_lock_min() { # $1 = hz bulat ; 0 kalau system min terbaca = hz
  hl_i=0
  while [ "$hl_i" -lt 4 ]; do
    settings put system min_refresh_rate "$1.0" 2>/dev/null
    [ "$2" = global ] && settings put global min_refresh_rate "$1.0" 2>/dev/null
    sleep 1
    hz_verify_min "$1" && return 0
    hl_i=$((hl_i + 1))
  done
  return 1
}

# Penjaga latar: kalau ROM menimpa peak/min saat HP dipakai (ganti app, layar mati-nyala), dipasang ulang.
# Polling 8 dtk (2x `settings get` = panggilan binder ringan). Berhenti sendiri kalau Hz & Frame Rate sama-sama
# mati, atau kalau ROM terus-menerus menimpa (>=20 koreksi / 5 menit) supaya tidak berperang dengan sistem.
HZ_GUARD_PID="$DATADIR/hz_guard.pid"
hz_guard_loop() {
  hg_fix=0; hg_w=$(date +%s)
  while :; do
    sleep 8
    load_conf
    hg_g=""
    if [ "$FRAMERATE" = 1 ]; then hg_t=$FRAMERATE_TARGET; hg_g=global
    elif [ "$HZ" = 1 ]; then hg_t=$HZ_TARGET
    else break; fi
    case "$hg_t" in ''|0) hg_t=$(hz_max) ;; esac
    case "$hg_t" in ''|*[!0-9]*) continue ;; esac
    if ! hz_verify "$hg_t" || ! hz_verify_min "$hg_t"; then
      # tulis HANYA yang salah; min selalu sesudah peak mapan (lihat hz_lock_min)
      if ! hz_verify "$hg_t"; then
        settings put system peak_refresh_rate "$hg_t.0" 2>/dev/null
        [ "$hg_g" = global ] && settings put global peak_refresh_rate "$hg_t.0" 2>/dev/null
        sleep 2
      fi
      hz_lock_min "$hg_t" $hg_g
      hg_fix=$((hg_fix + 1))
      log_msg "HZ guard: peak/min ditimpa ROM, dipasang ulang ke ${hg_t} (koreksi $hg_fix)"
    fi
    hg_n=$(date +%s)
    [ $((hg_n - hg_w)) -ge 300 ] && { hg_w=$hg_n; hg_fix=0; }
    if [ "$hg_fix" -ge 20 ]; then log_msg "HZ guard: ROM terus menimpa peak/min - guard berhenti"; break; fi
  done
  rm -f "$HZ_GUARD_PID"
}
hz_guard_start() {
  [ -f "$HZ_GUARD_PID" ] && kill -0 "$(cat "$HZ_GUARD_PID" 2>/dev/null)" 2>/dev/null && return 0
  ( hz_guard_loop ) >/dev/null 2>&1 </dev/null &
  echo $! > "$HZ_GUARD_PID"
}
hz_guard_stop() {
  [ -f "$HZ_GUARD_PID" ] && kill "$(cat "$HZ_GUARD_PID" 2>/dev/null)" 2>/dev/null
  rm -f "$HZ_GUARD_PID"
}

HZ_PREF_MARK="$DATADIR/hz_pref_set"
# Mode pilihan pengguna lewat DisplayManager (resolusi fisik + Hz target). Best-effort.
hz_pref_mode() { # $1 = hz
  command -v cmd >/dev/null 2>&1 || return 1
  hp_sz=$(wm size 2>/dev/null | sed -n 's/.*Physical size: *//p' | head -n 1)
  hp_w=${hp_sz%x*}; hp_h=${hp_sz#*x}
  hp_wh=$(dumpsys display 2>/dev/null | grep -iE 'DisplayMode\{|DisplayModeRecord' | awk -v hz="$1" -v w="$hp_w" -v h="$hp_h" '
    { W=""; H=""; F=""
      if (match($0, /width=[0-9]+/))  W = substr($0, RSTART + 6, RLENGTH - 6)
      if (match($0, /height=[0-9]+/)) H = substr($0, RSTART + 7, RLENGTH - 7)
      if (match($0, /fps=[0-9.]+/))   F = substr($0, RSTART + 4, RLENGTH - 4)
      if (W == "" || H == "" || F == "") next
      if (int(F + 0.5) != hz + 0) next
      if (W == w && H == h) { print W " " H; found = 1; exit }
      if (fb == "") fb = W " " H
    }
    END { if (!found && fb != "") print fb }' | head -n 1)
  [ -n "$hp_wh" ] || return 1
  if cmd display set-user-preferred-display-mode ${hp_wh% *} ${hp_wh#* } "$1" >/dev/null 2>&1; then
    : > "$HZ_PREF_MARK"; return 0
  fi
  return 1
}
hz_pref_clear() {
  [ -e "$HZ_PREF_MARK" ] || return 0
  cmd display clear-user-preferred-display-mode >/dev/null 2>&1
  rm -f "$HZ_PREF_MARK"
}

hz_restore_settings() {
  [ -s "$HZ_BK" ] || return 0
  while IFS='|' read -r hr_k hr_v; do
    [ -n "$hr_k" ] || continue
    case "$hr_v" in
      ''|null) settings delete system "$hr_k" >/dev/null 2>&1 ;;
      *) settings put system "$hr_k" "$hr_v" 2>/dev/null ;;
    esac
  done < "$HZ_BK"
  : > "$HZ_BK"
}

hz_restore_prop() {
  [ -e "$HZ_PROP_BK" ] || return 0
  hp_old=$(cat "$HZ_PROP_BK" 2>/dev/null)
  if [ -n "$hp_old" ]; then
    if command -v resetprop >/dev/null 2>&1; then resetprop "$HZ_SF_PROP" "$hp_old" 2>/dev/null; else setprop "$HZ_SF_PROP" "$hp_old" 2>/dev/null; fi
  else
    command -v resetprop >/dev/null 2>&1 && resetprop --delete "$HZ_SF_PROP" 2>/dev/null
  fi
  rm -f "$HZ_PROP_BK"
}

# hz_on [hz]  - hz kosong = pakai HZ_TARGET, kalau 0/kosong = Hz tertinggi yang didukung
hz_on() {
  load_conf
  # saling menggantikan dengan fitur Frame Rate (key peak/min sama): pulihkan nilai asli DULU supaya backup tidak tercemar
  ho_frnote=0
  if [ "$FRAMERATE" = 1 ]; then frm_off >/dev/null 2>&1; ho_frnote=1; fi
  ho_modes=$(hz_modes)
  ho_t=${1:-$HZ_TARGET}
  case "$ho_t" in ''|0) ho_t=$(hz_max) ;; esac
  case "$ho_t" in ''|*[!0-9]*) echo "Refresh Rate: GAGAL - target harus angka Hz (contoh 90 / 120)"; return 1 ;; esac
  # Langkah 2: mode yang terdaftar di panel/HAL. TIDAK lagi memblokir buta: daftar dumpsys bisa tidak lengkap,
  # jadi kalau target tidak terdaftar tetap dicoba lalu DIBUKTIKAN lewat Hz yang benar-benar berjalan.
  ho_listed=1; hz_in_modes "$ho_t" "$ho_modes" || ho_listed=0
  # Langkah 1: suntik ke System Settings (API yang dibaca DevCheck)
  hz_write_settings "$ho_t"
  # Langkah 3: matikan content detection (prop dibaca SurfaceFlinger saat start)
  hz_set_prop
  # ROM kadang menimpa balik nilai yang baru ditulis -> beri jeda, baca balik, tulis ulang sekali
  sleep 1
  if ! hz_verify "$ho_t"; then settings put system peak_refresh_rate "$ho_t" 2>/dev/null; sleep 1; fi
  if ! hz_verify "$ho_t"; then
    ho_seen=$(hz_get peak_refresh_rate)
    hz_guard_stop; hz_restore_settings; hz_restore_prop; hz_pref_clear; hz_setconf HZ 0
    flog HZ ERR "peak_refresh_rate tidak terbaca balik = ${ho_t}Hz (terbaca $ho_seen)"
    echo "Refresh Rate: GAGAL - ROM menolak peak_refresh_rate (terbaca $ho_seen, diminta $ho_t); dikembalikan ke semula"
    return 1
  fi
  # min dikunci SESUDAH peak mapan (ROM sering mereset min ke 60 tepat setelah peak berubah)
  ho_minnote=""
  hz_lock_min "$ho_t" || ho_minnote="min_refresh_rate ditimpa ROM di $(hz_get min_refresh_rate); penjaga latar akan memasangnya ulang"
  # Mode pilihan pengguna di DisplayManager SESUDAH peak/min konsisten (framework menerima sebagai satu paket)
  ho_pref=tidak; hz_pref_mode "$ho_t" && ho_pref=ya
  sleep 1
  ho_act=$(hz_active)
  # target tidak terdaftar DAN panel terbukti menjalankan Hz lain -> memang tidak didukung: kembalikan
  if [ "$ho_listed" = 0 ] && [ -n "$ho_act" ] && [ "$ho_act" != "$ho_t" ]; then
    hz_guard_stop; hz_restore_settings; hz_restore_prop; hz_pref_clear; hz_setconf HZ 0
    flog HZ ERR "${ho_t}Hz tidak terdaftar ($ho_modes) & panel tetap ${ho_act}Hz"
    echo "Refresh Rate: GAGAL - ${ho_t}Hz tidak didukung panel/HAL (tidak ada di mode: ${ho_modes:-kosong}; layar tetap ${ho_act}Hz)"
    echo "catatan: mode yang dikunci pabrik harus diekspos dulu oleh driver panel / DTBO / kernel"
    return 1
  fi
  hz_setconf HZ 1; hz_setconf HZ_TARGET "$ho_t"
  hz_guard_start
  flog HZ OK "AKTIF ${ho_t}Hz peak terverifikasi aktif=${ho_act:-?} min=$(hz_get min_refresh_rate) pref_mode=$ho_pref terdaftar=$ho_listed"
  log_msg "HZ: AKTIF ${ho_t}Hz"
  echo "Refresh Rate: AKTIF ${ho_t}Hz (peak_refresh_rate terverifikasi)"
  [ "$ho_listed" = 0 ] && echo "catatan: ${ho_t}Hz tidak ada di daftar mode yang terbaca, tapi ${ho_act:+layar menjalankan ${ho_act}Hz}${ho_act:-tidak bisa diverifikasi (Hz aktif tidak terbaca)}"
  [ -n "$ho_act" ] && [ "$ho_act" != "$ho_t" ] && echo "catatan: layar sekarang ${ho_act}Hz; Android memilih mode saat ada konten yang butuh refresh (gesek layar / buka game) - content detection baru benar-benar off setelah reboot"
  [ -n "$ho_minnote" ] && echo "catatan: $ho_minnote"
  [ "$ho_frnote" = 1 ] && echo "catatan: Frame Rate (FPS) dimatikan - Refresh Rate dan Frame Rate saling menggantikan (key peak/min sama)"
  echo "mode pilihan DisplayManager: $ho_pref  |  mode terbaca: ${ho_modes:-kosong}"
  echo "catatan: prop SurfaceFlinger ($HZ_SF_PROP=false) baru dibaca SF setelah reboot; setting Hz sudah langsung berlaku"
  hz_status
  return 0
}

hz_off() {
  load_conf
  hz_guard_stop
  hz_restore_settings
  hz_restore_prop
  hz_pref_clear
  hz_setconf HZ 0
  flog HZ OK "MATI settings dikembalikan"
  log_msg "HZ: MATI"
  echo "Refresh Rate: MATI (settings dikembalikan ke nilai asal; prop SurfaceFlinger efektif setelah reboot)"
  hz_status
}

# hz_set <hz> : kalau fitur AKTIF langsung diterapkan, kalau mati hanya disimpan sebagai target
hz_set() {
  load_conf
  case "$1" in ''|*[!0-9]*) echo "azenith-ai hz set <angka Hz>"; return 1 ;; esac
  if [ "$HZ" = 1 ]; then hz_on "$1"; return $?; fi
  hz_setconf HZ_TARGET "$1"
  echo "Refresh Rate: target disimpan ${1}Hz (fitur belum aktif - nyalakan toggle untuk menerapkan)"
}

# dipanggil service.sh setelah boot selesai (Settings & ROM kadang mereset saat boot) - 2 kali
hz_boot_apply() {
  load_conf
  [ "$HZ" = 1 ] || return 0
  hb_t=$HZ_TARGET
  case "$hb_t" in ''|0) hb_t=$(hz_max) ;; esac
  case "$hb_t" in ''|*[!0-9]*) return 1 ;; esac
  hz_write_settings "$hb_t"
  hz_set_prop
  sleep 1
  hz_lock_min "$hb_t" >/dev/null 2>&1
  hz_pref_mode "$hb_t" >/dev/null 2>&1
  hz_guard_start
  hz_verify "$hb_t" && flog HZ OK "boot: terapkan ulang ${hb_t}Hz (aktif=$(hz_active))" || flog HZ ERR "boot: peak tidak terbaca balik ${hb_t}Hz"
}

# dipanggil post-fs-data (SEBELUM SurfaceFlinger start): hanya prop, tanpa dumpsys/settings (belum siap)
hz_boot_props() {
  rm -f "$HZ_GUARD_PID"   # pid lama tidak valid setelah reboot
  # keadaan rusak (HZ & FRAMERATE sama-sama 1, mis. conf diedit manual): Frame Rate menang - ia mencakup Hz
  if [ "$HZ" = 1 ] && [ "$FRAMERATE" = 1 ]; then hz_setconf HZ 0; HZ=0; log_msg "HZ: HZ & FRAMERATE sama-sama 1 -> HZ dimatikan (saling menggantikan)"; fi
  [ "$HZ" = 1 ] || return 0
  hz_set_prop
  log_msg "HZ: prop $HZ_SF_PROP=false diset (boot)"
}

hz_status() {
  load_conf
  echo "HZ=$HZ  target=${HZ_TARGET}  peak=$(hz_get peak_refresh_rate)  min=$(hz_get min_refresh_rate)  aktif=$(hz_active)  sf_content_detection=$(getprop "$HZ_SF_PROP" 2>/dev/null)  mode_terbaca=$(hz_modes)"
}
