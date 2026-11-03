#!/system/bin/sh
# =====================================================================
#  Zyrox - lib/dnd.sh : DND In-Game
#
#  Senyapkan SEMUA notifikasi (termasuk suaranya) dari LUAR game selama
#  sesi game aktif, lewat Do Not Disturb RESMI Android (Settings.Global
#  zen_mode + cmd notification set_zen_mode, dua jalur sama-sama ditulis
#  karena beberapa ROM vendor cuma dengarkan salah satunya - sama pola
#  dengan lib/powersave.sh ps_set yang juga tulis+verifikasi baca-balik).
#
#  zen_mode = 2 (ZEN_MODE_NO_INTERRUPTIONS) membungkam notifikasi & bunyi
#  ringtone/notifikasi SELURUH SISTEM. Audio game sendiri TIDAK ikut
#  kebungkam - DND Android cuma menahan stream notification/ring, bukan
#  stream musik/game (STREAM_MUSIC), jadi game tetap bersuara normal.
#
#  TIDAK PERMANEN: nilai zen_mode ASLI disimpan sebelum diubah (sekali,
#  tidak ditimpa kalau dipanggil berkali-kali dalam satu sesi) dan
#  dikembalikan begitu game berhenti ATAU toggle dimatikan - dipanggil
#  eksplisit dari stop_game (lib/daemon.sh), sama pola dengan
#  perf_touch_revert/aks_revert (bukan bagian dari $STACK umum/cleanup_all
#  karena ini Settings.Global, bukan node sysfs).
# =====================================================================

DND_BACKUP="$RUNDIR/dnd_zen_backup"

dnd_get_zen() { settings get global zen_mode 2>/dev/null | tr -d ' \t\r\n'; }

dnd_set_zen() { # dnd_set_zen <0-3>
  cmd notification set_zen_mode "$1" >/dev/null 2>&1
  settings put global zen_mode "$1" 2>/dev/null
}

# dnd_apply - dipanggil SEKALI dari start_game (lib/daemon.sh), lewat loop
# fitur generik (sg_fn) sama seperti refresh_apply/network_apply - no-op
# kalau togglenya mati, idempotent kalau dipanggil berkali-kali (backup
# cuma ditulis sekali per sesi).
dnd_apply() {
  [ "$FEAT_DND_INGAME" = 1 ] || return 0
  [ -f "$DND_BACKUP" ] && return 0   # sudah aktif sesi ini, jangan timpa backup asli
  dz_cur=$(dnd_get_zen)
  case "$dz_cur" in ''|*[!0-9]*) dz_cur=0 ;; esac
  echo "$dz_cur" > "$DND_BACKUP"
  dnd_set_zen 2
  dz_now=$(dnd_get_zen)
  if [ "$dz_now" = 2 ]; then
    log_msg "DND: DND In-Game AKTIF (zen_mode $dz_cur -> 2, notifikasi+suara dari luar game disenyapkan, audio game tidak disentuh)"
  else
    log_msg "DND: tulis zen_mode=2 tapi terbaca balik '$dz_now' - ROM ini mungkin tidak mendukung set_zen_mode lewat shell"
  fi
}

# dnd_revert - dipanggil eksplisit dari stop_game. Aman dipanggil walau
# DND tidak pernah aktif sesi ini (no-op, backup tidak ada).
dnd_revert() {
  [ -f "$DND_BACKUP" ] || return 0
  dz_old=$(cat "$DND_BACKUP" 2>/dev/null)
  case "$dz_old" in ''|*[!0-9]*) dz_old=0 ;; esac
  dnd_set_zen "$dz_old"
  rm -f "$DND_BACKUP"
  log_msg "DND: DND In-Game dilepas, zen_mode dikembalikan ke $dz_old"
}

dnd_status() {
  echo "FEAT_DND_INGAME=${FEAT_DND_INGAME:-0}  zen_mode_sekarang=$(dnd_get_zen)  aktif_sesi_ini=$([ -f "$DND_BACKUP" ] && echo ya || echo tidak)"
  [ -f "$DND_BACKUP" ] && echo "zen_mode_sebelum_aktif=$(cat "$DND_BACKUP" 2>/dev/null)"
}
