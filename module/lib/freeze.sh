#!/system/bin/sh
# =====================================================================
#  Zyrox - lib/freeze.sh : Freeze In-Game
#
#  Bekukan (pm disable-user) app pihak ketiga yang tidak dipakai SELAMA
#  game aktif, supaya tidak ikut makan CPU/RAM/baterai di background -
#  TIDAK PERMANEN: semua app yang dibekukan sesi ini dicatat ke
#  FREEZE_LIST dan dikembalikan (pm enable) begitu game berhenti ATAU
#  toggle dimatikan, dipanggil eksplisit dari stop_game (lib/daemon.sh),
#  sama pola dengan aks_revert/perf_touch_revert/dnd_revert.
#
#  DUA KATEGORI (FEAT_FREEZE_INGAME = sakelar utama):
#   - Pihak ketiga (-3 -e dari `pm list packages`): dibekukan OTOMATIS,
#     KECUALI yang ada di FREEZE_GUARD (daftar wajib-aman, lihat bawah)
#     atau FREEZE_KEEP (daftar "jangan bekukan" milik user sendiri, mis.
#     WhatsApp/Discord yang masih dipakai chat/voice sambil main).
#   - Sistem (FREEZE_INCLUDE_SYSTEM=1, OPT-IN, default MATI): HANYA paket
#     yang sudah ditambahkan SATU-PER-SATU secara sadar oleh user ke
#     whitelist $DATADIR/freeze_system.user ('azenith-ai freeze addsys
#     <paket>') - SENGAJA BUKAN "bekukan semua app sistem". App sistem
#     banyak yang jadi tulang punggung Android (SystemUI, Phone, Settings,
#     Package Installer, dll) - membekukannya bisa bikin UI hilang, tidak
#     bisa terima telepon, sampai butuh factory reset/flash ulang untuk
#     pulih. FREEZE_GUARD di bawah jadi jaring pengaman TERAKHIR: paket
#     di daftar itu DITOLAK dipanggil, baik saat 'freeze addsys' MAUPUN
#     saat freeze_apply() jalan - walau entah bagaimana lolos masuk file
#     whitelist (mis. diedit manual).
#
#  Caranya 'pm disable-user --user 0 <paket>' (reversibel, beda dengan
#  uninstall/force-stop) - 'pm enable <paket>' buat mengembalikan.
# =====================================================================

FREEZE_LIST="$RUNDIR/freeze_frozen.txt"          # paket yang BENAR dibekukan sesi ini (buat revert)
FREEZE_KEEP_F="$DATADIR/freeze_keep.user"         # user: paket pihak ketiga yang JANGAN dibekukan
FREEZE_SYS_F="$DATADIR/freeze_system.user"        # user: whitelist paket SISTEM yang BOLEH dibekukan

# Jaring pengaman TERAKHIR - tidak pernah dibekukan apa pun alasannya,
# walau entah bagaimana masuk ke freeze_system.user. Generik (bukan cuma
# nama paket vendor tertentu) + beberapa nama manager root umum supaya
# modul ini sendiri tidak ikut membekukan akses baliknya sendiri.
FREEZE_GUARD="
android
com.android.systemui
com.android.settings
com.android.phone
com.android.server.telecom
com.android.providers.settings
com.android.providers.media
com.android.providers.downloads
com.android.providers.telephony
com.android.externalstorage
com.android.packageinstaller
com.google.android.packageinstaller
com.android.permissioncontroller
com.google.android.permissioncontroller
com.android.vending
com.google.android.gms
com.google.android.gsf
com.android.webview
com.google.android.webview
com.google.android.trichromelibrary
com.android.bluetooth
com.android.nfc
com.android.shell
com.android.inputmethod.latin
com.azenithtech.azenithai
com.topjohnwu.magisk
me.weishu.kernelsu
me.bmax.apatch
io.github.a13e300.ksuwebui
"

# freeze_dyn_guard - tambahan guard yang sifatnya DINAMIS per device: launcher
# default & input method default yang SEDANG dipakai sekarang (membekukannya
# bisa bikin layar home/keyboard hilang di tengah sesi). Dicoba best-effort,
# gagal baca = dilewati (bukan dianggap "aman dibekukan").
freeze_dyn_guard() {
  fg_launcher=$(cmd package resolve-activity --brief -c android.intent.category.HOME 2>/dev/null | tail -n1)
  fg_launcher=${fg_launcher%%/*}
  fg_ime=$(settings get secure default_input_method 2>/dev/null)
  fg_ime=${fg_ime%%/*}
  echo "$fg_launcher $fg_ime"
}

freeze_guard_list() { # echo semua paket yang TIDAK BOLEH dibekukan (guard + dinamis + keep-list user + game aktif + diri sendiri)
  { for fgz in $FREEZE_GUARD; do echo "$fgz"; done
    freeze_dyn_guard | tr ' ' '\n'
    [ -s "$FREEZE_KEEP_F" ] && cat "$FREEZE_KEEP_F"
    [ -n "$GAME_PKG" ] && echo "$GAME_PKG"
  } | grep -E '^[A-Za-z0-9_.]+$'
}

freeze_is_guarded() { # freeze_is_guarded <paket> <daftar_guard multi-baris>
  case "
$2
" in
    *"
$1
"*) return 0 ;;
    *) return 1 ;;
  esac
}

freeze_thirdparty_candidates() { pm list packages -3 -e 2>/dev/null | sed -n 's/^package://p'; }

# freeze_apply - dipanggil SEKALI dari start_game lewat loop fitur generik,
# no-op kalau togglenya mati. fz_n dihitung buat log, tidak mempengaruhi rc.
freeze_apply() {
  [ "$FEAT_FREEZE_INGAME" = 1 ] || return 0
  : > "$FREEZE_LIST"
  fz_guard=$(freeze_guard_list)
  fz_n=0
  for fz_p in $(freeze_thirdparty_candidates); do
    freeze_is_guarded "$fz_p" "$fz_guard" && continue
    if pm disable-user --user 0 "$fz_p" >/dev/null 2>&1; then
      echo "$fz_p" >> "$FREEZE_LIST"
      fz_n=$((fz_n + 1))
    fi
  done
  fz_sysn=0
  if [ "$FREEZE_INCLUDE_SYSTEM" = 1 ] && [ -s "$FREEZE_SYS_F" ]; then
    while IFS= read -r fz_s; do
      [ -n "$fz_s" ] || continue
      freeze_is_guarded "$fz_s" "$fz_guard" && continue
      if pm disable-user --user 0 "$fz_s" >/dev/null 2>&1; then
        echo "$fz_s" >> "$FREEZE_LIST"
        fz_sysn=$((fz_sysn + 1))
      fi
    done < "$FREEZE_SYS_F"
  fi
  log_msg "FREEZE: $fz_n app pihak-ketiga + $fz_sysn app sistem(whitelist) dibekukan sementara untuk sesi game ini"
}

# freeze_revert - dipanggil eksplisit dari stop_game. Aman dipanggil walau
# Freeze tidak pernah aktif sesi ini (no-op, FREEZE_LIST kosong/tidak ada).
freeze_revert() {
  [ -s "$FREEZE_LIST" ] || { rm -f "$FREEZE_LIST"; return 0; }
  fz_n=0
  while IFS= read -r fz_p; do
    [ -n "$fz_p" ] || continue
    pm enable "$fz_p" >/dev/null 2>&1 && fz_n=$((fz_n + 1))
  done < "$FREEZE_LIST"
  rm -f "$FREEZE_LIST"
  log_msg "FREEZE: $fz_n app dikembalikan aktif (unfreeze, game berhenti/fitur dimatikan)"
}

freeze_status() {
  echo "FEAT_FREEZE_INGAME=${FEAT_FREEZE_INGAME:-0}  FREEZE_INCLUDE_SYSTEM=${FREEZE_INCLUDE_SYSTEM:-0}"
  echo "dibekukan_sekarang=$([ -s "$FREEZE_LIST" ] && wc -l < "$FREEZE_LIST" | tr -d ' ' || echo 0)"
  echo "whitelist_sistem=$([ -s "$FREEZE_SYS_F" ] && wc -l < "$FREEZE_SYS_F" | tr -d ' ' || echo 0)"
  echo "keep_list_user=$([ -s "$FREEZE_KEEP_F" ] && wc -l < "$FREEZE_KEEP_F" | tr -d ' ' || echo 0)"
  [ -s "$FREEZE_LIST" ] && { echo "--- sedang dibekukan ---"; cat "$FREEZE_LIST"; }
}
