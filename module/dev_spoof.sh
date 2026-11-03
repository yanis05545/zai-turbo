#!/system/bin/sh
# =====================================================================
#  Zyrox - dev_spoof.sh   (v1.0.21)
#  Spoof NAMA PERANGKAT (model/merek/pabrikan/codename) SYSTEMLESS lewat resetprop.
#
#  TIDAK PERNAH menulis /system|/vendor|/product|/system_ext|/odm build.prop.
#  Nilai hanya ditimpa di memori (property service) dan diterapkan ulang tiap
#  boot di tahap post-fs-data (sebelum zygote), jadi tidak ada berkas yang
#  bisa rusak -> tidak ada risiko bootloop dari menimpa build.prop asli.
#
#  Properti yang diubah (HANYA yang memang ada di perangkat ini):
#    ro.product.{model,brand,manufacturer,device,name,marketname}
#    + varian per-partisi: ro.product.{system,vendor,odm,product,system_ext,bootimage}.*
#    ro.build.product
#    ro.build.fingerprint (+ varian per-partisi) HANYA kalau diminta eksplisit (--fp)
#
#  Pengaman:
#   - Nilai asli dicadangkan SEBELUM ditimpa (gpu: $DATADIR/dev_orig.props); off = kembalikan.
#   - Input divalidasi (karakter aman, panjang dibatasi) - tidak ada eksekusi shell dari input.
#   - boot-failsafe: kalau boot sebelumnya tidak sehat (boot_count >= 2) spoof dimatikan otomatis.
#   - Fingerprint TIDAK ikut profil bawaan: fingerprint palsu yang tidak valid bisa memicu
#     deteksi integritas / merusak OTA. Pakai --fp hanya kalau Anda punya fingerprint VALID.
#   - Perubahan dibaca aplikasi saat proses aplikasi baru dimulai; layanan sistem baru
#     konsisten setelah REBOOT.
#
#  Pakai (root):
#   sh dev_spoof.sh detect                 nilai asli vs sekarang + isi build.prop (hanya baca)
#   sh dev_spoof.sh profiles               daftar profil (id|brand|manufacturer|model|device|name|marketname|label)
#   sh dev_spoof.sh status                 status + verifikasi nilai live
#   sh dev_spoof.sh on <id>                terapkan profil (juga langsung ke proses baru)
#   sh dev_spoof.sh set custom <brand> <manufacturer> <model> <device> [--name <n>] [--fp <fingerprint>]
#   sh dev_spoof.sh off                    kembalikan nilai asli
#   sh dev_spoof.sh verify                 cocokkan getprop dengan target
#   sh dev_spoof.sh restart                restart framework (zygote) agar Build.MODEL dst. terbaca ulang TANPA reboot penuh
#   sh dev_spoof.sh boot <boot_count>      dipanggil post-fs-data.sh
#   Tambahkan --restart di akhir on/set/off untuk langsung restart framework setelah diterapkan.
#
#  KENAPA GANTI PROFIL DULU "TIDAK MAU BERUBAH": getprop langsung berubah, tapi android.os.Build.MODEL/BRAND/...
#  dibaca SEKALI oleh zygote saat start lalu diwariskan ke semua aplikasi. Jadi ganti profil saat runtime tidak
#  mengubah apa yang dilihat aplikasi (DevCheck, Settings) sampai zygote start ulang. Sekarang: (1) tanda
#  "fwstale" ditampilkan sampai framework di-restart/reboot, (2) --restart / `restart` me-restart zygote,
#  (3) properti milik profil LAMA yang tidak dipakai profil baru (mis. fingerprint dari profil kustom)
#  dikembalikan ke nilai asli, bukan tertinggal.
# =====================================================================
MODDIR=${MODDIR:-/data/adb/modules/azenith-ai}
DATADIR="${TX_DATA:-/data/adb/azenith-ai}"
R="${TX_ROOT:-}"
CONF="$DATADIR/azenith-ai.conf"
DV_PROPS="$DATADIR/dev_spoof.props"      # name|nilai  -> diterapkan tiap boot
DV_ORIG="$DATADIR/dev_orig.props"        # name|nilai asli (+ baris #incr|<build incremental>)
DV_META="$DATADIR/dev_spoof.meta"
DV_STALE="$DATADIR/dev_spoof.fwstale"   # ada = zygote belum membaca ulang props terbaru
export PATH="$PATH:/data/adb/magisk:/data/adb/ksu/bin:/data/adb/ap/bin:/system/bin"
mkdir -p "$DATADIR" 2>/dev/null

dv_say() { printf '%s\n' "$*"; }
dv_kv()  { printf '%s=%s\n' "$1" "$2"; }
dv_log() { printf '%s [DEVSPOOF] %s\n' "$(date '+%m-%d %H:%M:%S')" "$*" >> "$DATADIR/log.txt" 2>/dev/null; }
dv_prop() { getprop "$1" 2>/dev/null | tr -d '\r'; }
dv_conf_get() { dv_cv=$(sed -n "s/^$1=\([^ #]*\).*/\1/p" "$CONF" 2>/dev/null | tail -n 1); printf '%s' "${dv_cv:-$2}"; }
dv_conf_set() {
  [ -f "$CONF" ] || : > "$CONF"
  if grep -q "^$1=" "$CONF" 2>/dev/null; then sed -i "s|^$1=[^ #]*|$1=$2|" "$CONF"; else printf '%s=%s\n' "$1" "$2" >> "$CONF"; fi
}
dv_need_root() { [ -n "$R" ] && return 0; [ "$(id -u 2>/dev/null)" = 0 ] && return 0; dv_say "GAGAL: butuh root (jalankan lewat su)"; return 1; }
dv_need_resetprop() { command -v resetprop >/dev/null 2>&1 && return 0; dv_say "GAGAL: resetprop tidak ada (butuh Magisk/KernelSU/APatch)"; return 1; }

# nilai aman: huruf/angka/spasi dan . _ - : / + ( )  ; tanpa | agar format berkas aman
dv_clean() { # dv_clean <maks> <teks>
  printf '%s' "$2" | tr -cd 'A-Za-z0-9 ._:/+()-' | cut -c1-"$1" | sed 's/^ *//;s/ *$//'
}

dv_catalog() { # id|brand|manufacturer|model|device|name|marketname|label
  cat <<'EOT'
pixel9proxl|google|Google|Pixel 9 Pro XL|komodo|komodo|Pixel 9 Pro XL|Google Pixel 9 Pro XL
pixel9pro|google|Google|Pixel 9 Pro|caiman|caiman|Pixel 9 Pro|Google Pixel 9 Pro
s22ultra|samsung|samsung|SM-S908B|b0s|b0sxxx|Galaxy S22 Ultra|Samsung Galaxy S22 Ultra
s24ultra|samsung|samsung|SM-S928B|e3q|e3qxxx|Galaxy S24 Ultra|Samsung Galaxy S24 Ultra
rog9pro|asus|asus|ASUS_AI2501|AI2501|WW_AI2501|ROG Phone 9 Pro|ASUS ROG Phone 9 Pro
redmagic11pro|nubia|nubia|NX809J|NX809J|NX809J|REDMAGIC 11 Pro|RedMagic 11 Pro
blackshark4pro|blackshark|BLACKSHARK|SHARK KSR-H0|kaiser|KSR-H0|Black Shark 4 Pro|Black Shark 4 Pro
iqoo15r|vivo|vivo|I2508|I2508|I2508|iQOO 15R|iQOO 15R
EOT
}

# ---- bangun daftar properti (hanya yang ada di perangkat) ------------
dv_emit() { # dv_emit <prop> <nilai>
  [ -n "$2" ] || return 0
  [ -n "$(dv_prop "$1")" ] || return 0
  printf '%s|%s\n' "$1" "$2"
}
dv_build_list() { # brand manufacturer model device name marketname fingerprint
  for dv_p in "" system vendor odm product system_ext bootimage; do
    dv_pre="ro.product.${dv_p:+$dv_p.}"
    dv_emit "${dv_pre}model" "$3"
    dv_emit "${dv_pre}brand" "$1"
    dv_emit "${dv_pre}manufacturer" "$2"
    dv_emit "${dv_pre}device" "$4"
    dv_emit "${dv_pre}name" "$5"
    dv_emit "${dv_pre}marketname" "$6"
  done
  dv_emit ro.build.product "$4"
  if [ -n "$7" ]; then
    for dv_p in "" system vendor odm product system_ext bootimage; do
      dv_emit "ro.${dv_p:+$dv_p.}build.fingerprint" "$7"
    done
  fi
}

dv_save_orig() { # cadangkan nilai asli tiap prop di daftar (sekali, jangan timpa backup lama)
  [ -f "$DV_ORIG" ] || printf '#incr|%s\n' "$(dv_prop ro.build.version.incremental)" > "$DV_ORIG"
  # backup dari OTA lama tidak valid
  if [ "$(sed -n 's/^#incr|//p' "$DV_ORIG" | head -n 1)" != "$(dv_prop ro.build.version.incremental)" ]; then
    printf '#incr|%s\n' "$(dv_prop ro.build.version.incremental)" > "$DV_ORIG"
  fi
  while IFS='|' read -r so_k so_v; do
    [ -n "$so_k" ] || continue
    grep -q "^$so_k|" "$DV_ORIG" 2>/dev/null || printf '%s|%s\n' "$so_k" "$(dv_prop "$so_k")" >> "$DV_ORIG"
  done < "$1"
}
dv_apply_file() { # name|nilai per baris -> resetprop -n ; return jumlah gagal
  af_bad=0; af_ok=0
  while IFS='|' read -r af_k af_v; do
    [ -n "$af_k" ] || continue
    case "$af_k" in '#'*) continue ;; esac
    if resetprop -n "$af_k" "$af_v" 2>/dev/null; then af_ok=$((af_ok + 1)); else af_bad=$((af_bad + 1)); fi
  done < "$1"
  DV_APPLIED=$af_ok
  return "$af_bad"
}

# kembalikan prop milik profil LAMA yang TIDAK ada di profil baru ke nilai asli (jangan tertinggal)
dv_drop_stale() { # dv_drop_stale <berkas_baru>
  [ -s "$DV_PROPS" ] && [ -s "$DV_ORIG" ] || return 0
  while IFS='|' read -r dd_k dd_v; do
    [ -n "$dd_k" ] || continue
    grep -q "^$dd_k|" "$1" 2>/dev/null && continue
    dd_o=$(awk -F'|' -v k="$dd_k" '$1==k{print substr($0,length(k)+2); exit}' "$DV_ORIG" 2>/dev/null)
    if [ -n "$dd_o" ]; then resetprop -n "$dd_k" "$dd_o" 2>/dev/null; else resetprop --delete "$dd_k" 2>/dev/null; fi
  done < "$DV_PROPS"
}

dv_real() { # nilai asli (backup) atau nilai sekarang kalau belum pernah di-spoof
  rl_v=$(awk -F'|' -v k="$1" '$1==k{print substr($0,length(k)+2); exit}' "$DV_ORIG" 2>/dev/null)
  [ -n "$rl_v" ] && printf '%s' "$rl_v" || dv_prop "$1"
}

# ---- perintah ----------------------------------------------------------
dv_cmd_detect() {
  dv_kv real.model "$(dv_real ro.product.model)"
  dv_kv real.brand "$(dv_real ro.product.brand)"
  dv_kv real.manufacturer "$(dv_real ro.product.manufacturer)"
  dv_kv real.device "$(dv_real ro.product.device)"
  dv_kv real.fingerprint "$(dv_real ro.build.fingerprint)"
  dv_kv now.model "$(dv_prop ro.product.model)"
  dv_kv now.brand "$(dv_prop ro.product.brand)"
  dv_kv now.manufacturer "$(dv_prop ro.product.manufacturer)"
  dv_kv now.device "$(dv_prop ro.product.device)"
  dv_kv now.fingerprint "$(dv_prop ro.build.fingerprint)"
  # build.prop asli (HANYA dibaca, tidak pernah ditulis)
  for dd_f in system vendor product system_ext odm; do
    case "$dd_f" in system) dd_p="$R/system/build.prop" ;; *) dd_p="$R/$dd_f/build.prop" ;; esac
    [ -f "$dd_p" ] || continue
    dd_m=$(grep -m1 -E '^ro\.product(\.[a-z_]+)?\.model=' "$dd_p" 2>/dev/null | cut -d= -f2-)
    dv_kv "buildprop.$dd_f" "${dd_p#$R} (model=${dd_m:-?})"
  done
  dv_kv resetprop "$(command -v resetprop >/dev/null 2>&1 && echo ada || echo TIDAK-ADA)"
}

dv_cmd_status() {
  ds_on=$(dv_conf_get SPOOF_DEV 0)
  dv_kv devspoof "$ds_on"
  dv_kv profile "$(sed -n 's/^profile=//p' "$DV_META" 2>/dev/null | head -n 1)"
  dv_kv label "$(sed -n 's/^label=//p' "$DV_META" 2>/dev/null | head -n 1)"
  dv_kv props "$(grep -c '|' "$DV_PROPS" 2>/dev/null || echo 0)"
  dv_kv has_fp "$(grep -c '^ro\.[a-z_.]*build\.fingerprint|' "$DV_PROPS" 2>/dev/null || echo 0)"
  dv_kv now.model "$(dv_prop ro.product.model)"
  dv_kv now.brand "$(dv_prop ro.product.brand)"
  dv_kv now.manufacturer "$(dv_prop ro.product.manufacturer)"
  dv_kv now.device "$(dv_prop ro.product.device)"
  dv_kv real.model "$(dv_real ro.product.model)"
  dv_kv real.device "$(dv_real ro.product.device)"
  ds_bad=0
  if [ -s "$DV_PROPS" ]; then
    while IFS='|' read -r ds_k ds_v; do [ -n "$ds_k" ] && [ "$(dv_prop "$ds_k")" != "$ds_v" ] && ds_bad=$((ds_bad + 1)); done < "$DV_PROPS"
  fi
  dv_kv mismatch "$ds_bad"
  dv_kv stale "$([ -f "$DATADIR/dev_spoof.stale" ] && cat "$DATADIR/dev_spoof.stale" || echo 0)"
  dv_kv fwstale "$([ -f "$DV_STALE" ] && echo 1 || echo 0)"
}

dv_do_set() { # dv_do_set <profile_id> <brand> <manufacturer> <model> <device> <name> <market> <label> <fp>
  dv_need_root || return 1; dv_need_resetprop || return 1
  ds_t="$DATADIR/.dvlist.$$"
  dv_build_list "$2" "$3" "$4" "$5" "$6" "$7" "$9" > "$ds_t"
  if [ ! -s "$ds_t" ]; then rm -f "$ds_t"; dv_say "GAGAL: tidak ada properti ro.product.* yang bisa ditimpa di perangkat ini"; return 1; fi
  dv_save_orig "$ds_t"
  dv_drop_stale "$ds_t"
  mv -f "$ds_t" "$DV_PROPS"
  { echo "profile=$1"; echo "label=$8"; echo "epoch=$(date +%s)"; } > "$DV_META"
  dv_apply_file "$DV_PROPS"; ds_rc=$?
  dv_conf_set SPOOF_DEV 1; dv_conf_set SPOOF_DEV_PROFILE "$1"
  rm -f "$DATADIR/dev_spoof.stale"
  echo 1 > "$DV_STALE"
  dv_log "on $1: $DV_APPLIED prop ditimpa, $ds_rc gagal"
  dv_say "Spoof nama perangkat AKTIF: $8 (model='$4' brand='$2' manufacturer='$3' device='$5') - $DV_APPLIED properti ditimpa (in-memory, build.prop asli tidak disentuh)."
  [ -n "$9" ] && dv_say "PERINGATAN: fingerprint ikut ditimpa. Fingerprint yang tidak valid dapat memicu deteksi integritas / mengganggu OTA."
  [ "$ds_rc" -gt 0 ] && dv_say "CATATAN: $ds_rc properti ditolak resetprop."
  dv_verify_quiet
  dv_say "getprop sudah berubah ($DV_VOK cocok, $DV_VBAD beda). Tapi Build.MODEL yang dibaca aplikasi baru ikut berubah SETELAH framework di-restart: jalankan 'restart' (tanpa reboot penuh) atau REBOOT."
  return 0
}

dv_verify_quiet() { # isi DV_VOK / DV_VBAD dari getprop vs target
  DV_VOK=0; DV_VBAD=0
  [ -s "$DV_PROPS" ] || return 0
  while IFS='|' read -r vq_k vq_v; do
    [ -n "$vq_k" ] || continue
    if [ "$(dv_prop "$vq_k")" = "$vq_v" ]; then DV_VOK=$((DV_VOK + 1)); else DV_VBAD=$((DV_VBAD + 1)); fi
  done < "$DV_PROPS"
}

# restart zygote (soft reboot): semua aplikasi ditutup ~10-20 dtk, lalu Build.* dibaca ulang dari properti terbaru.
# Dijalankan di latar + jeda supaya respons (WebUI) sempat kembali sebelum prosesnya ikut mati.
dv_cmd_restart() {
  dv_need_root || return 1
  dv_say "Restart framework dimulai (~15 dtk, layar sempat berkedip). Aplikasi ditutup; setelah itu nama baru terbaca."
  dv_log "restart framework (zygote)"
  rm -f "$DV_STALE"
  ( sleep 2
    setprop ctl.restart zygote_secondary >/dev/null 2>&1
    setprop ctl.restart zygote >/dev/null 2>&1 || { stop >/dev/null 2>&1; start >/dev/null 2>&1; }
  ) >/dev/null 2>&1 &
  return 0
}

dv_cmd_on() {
  dv_id=$1; [ -n "$dv_id" ] || dv_id=$(dv_conf_get SPOOF_DEV_PROFILE "")
  [ -n "$dv_id" ] || { dv_say "GAGAL: sebutkan profil (lihat 'profiles') atau 'set custom ...'"; return 1; }
  if [ "$dv_id" = custom ]; then dv_say "GAGAL: gunakan 'set custom <brand> <manufacturer> <model> <device>'"; return 1; fi
  dv_row=$(dv_catalog | while IFS='|' read -r a b c d e f g h; do [ "$a" = "$dv_id" ] && { printf '%s|%s|%s|%s|%s|%s|%s|%s' "$a" "$b" "$c" "$d" "$e" "$f" "$g" "$h"; break; }; done)
  [ -n "$dv_row" ] || { dv_say "GAGAL: profil '$dv_id' tidak dikenal (lihat: dev_spoof.sh profiles)"; return 1; }
  OLDIFS=$IFS; IFS='|'; set -- $dv_row; IFS=$OLDIFS
  dv_do_set "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" ""
}

dv_cmd_custom() { # custom <brand> <manufacturer> <model> <device> [--name n] [--fp f]
  cu_b=$(dv_clean 32 "$1"); cu_m=$(dv_clean 32 "$2"); cu_mo=$(dv_clean 48 "$3"); cu_d=$(dv_clean 32 "$4"); shift 4 2>/dev/null
  cu_n=""; cu_fp=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --name) cu_n=$(dv_clean 32 "$2"); shift 2 ;;
      --fp)   cu_fp=$(dv_clean 160 "$2"); shift 2 ;;
      *) shift ;;
    esac
  done
  if [ -z "$cu_b" ] || [ -z "$cu_m" ] || [ -z "$cu_mo" ] || [ -z "$cu_d" ]; then
    dv_say "GAGAL: brand, manufacturer, model, dan device wajib diisi (huruf/angka/spasi . _ : / + ( ) -)"; return 1
  fi
  case "$cu_d" in *" "*) dv_say "GAGAL: device (codename) tidak boleh mengandung spasi"; return 1 ;; esac
  if [ -n "$cu_fp" ]; then
    # format fingerprint Android: brand/product/device:release/id/incremental:type/tags
    case "$cu_fp" in */*/*:*/*/*:*/*) ;; *) dv_say "GAGAL: format fingerprint tidak valid (brand/product/device:release/build-id/incremental:type/tags)"; return 1 ;; esac
  fi
  dv_do_set custom "$cu_b" "$cu_m" "$cu_mo" "$cu_d" "$cu_n" "" "Kustom: $cu_mo" "$cu_fp"
}

dv_cmd_off() {
  dv_need_root || return 1
  of_n=0
  if [ -s "$DV_ORIG" ] && command -v resetprop >/dev/null 2>&1 \
     && [ "$(sed -n 's/^#incr|//p' "$DV_ORIG" | head -n 1)" = "$(dv_prop ro.build.version.incremental)" ]; then
    dv_apply_file "$DV_ORIG"; of_n=$DV_APPLIED
  fi
  rm -f "$DV_PROPS" "$DV_META" "$DATADIR/dev_spoof.stale"
  echo 1 > "$DV_STALE"
  dv_conf_set SPOOF_DEV 0
  dv_log "off: $of_n properti dikembalikan"
  dv_say "Spoof nama perangkat MATI: $of_n properti dikembalikan ke nilai asli (build.prop asli tidak pernah diubah). REBOOT agar sistem sepenuhnya bersih."
}

dv_cmd_verify() {
  [ -s "$DV_PROPS" ] || { dv_say "Tidak ada spoof aktif."; return 1; }
  vf_ok=0; vf_bad=0
  while IFS='|' read -r vf_k vf_v; do
    [ -n "$vf_k" ] || continue
    if [ "$(dv_prop "$vf_k")" = "$vf_v" ]; then vf_ok=$((vf_ok + 1)); else vf_bad=$((vf_bad + 1)); dv_say "[BEDA ] $vf_k = '$(dv_prop "$vf_k")' (target '$vf_v')"; fi
  done < "$DV_PROPS"
  dv_say "Cocok: $vf_ok  Tidak cocok: $vf_bad"
  [ "$vf_bad" -eq 0 ] && dv_say "HASIL: COCOK - spoof nama perangkat bekerja." || dv_say "HASIL: ada properti yang tidak cocok (mungkin ditimpa ulang oleh sistem/modul lain)."
  [ "$vf_bad" -eq 0 ]
}

# dipanggil post-fs-data.sh (SEBELUM zygote). Cepat: hanya resetprop dari berkas daftar jadi.
dv_cmd_boot() {
  rm -f "$DV_STALE"   # post-fs-data jalan SEBELUM zygote start: Build.* akan membaca props ini
  [ "$(dv_conf_get SPOOF_DEV 0)" = 1 ] || return 0
  [ -s "$DV_PROPS" ] || return 0
  case "$1" in ''|*[!0-9]*) bn=0 ;; *) bn=$1 ;; esac
  if [ "$bn" -ge 3 ]; then
    dv_conf_set SPOOF_DEV 0
    echo "boot sebelumnya tidak sehat" > "$DATADIR/dev_spoof.stale"
    dv_log "BOOT failsafe: spoof nama perangkat dimatikan (boot_count=$bn)"
    return 0
  fi
  command -v resetprop >/dev/null 2>&1 || return 0
  dv_apply_file "$DV_PROPS"
  dv_log "BOOT: $DV_APPLIED properti nama perangkat diterapkan"
  return 0
}

dv_main() {
  # ambil flag --restart dari argumen (posisi mana pun)
  DV_RESTART=0; dv_args=""
  dv_n=$#; dv_i=0
  while [ "$dv_i" -lt "$dv_n" ]; do
    dv_x=$1; shift; dv_i=$((dv_i + 1))
    if [ "$dv_x" = "--restart" ]; then DV_RESTART=1; else set -- "$@" "$dv_x"; fi
  done
  dv_c=$1; shift 2>/dev/null
  case "$dv_c" in
    detect) dv_cmd_detect ;;
    profiles) dv_catalog ;;
    status|"") dv_cmd_status ;;
    on) dv_cmd_on "$1" ;;
    set) if [ "$1" = custom ]; then shift; dv_cmd_custom "$@"; else dv_cmd_on "$1"; fi ;;
    off) dv_cmd_off ;;
    verify) dv_cmd_verify ;;
    boot) dv_cmd_boot "$1" ;;
    restart) dv_cmd_restart ;;
    *) dv_say "pakai: dev_spoof.sh detect|profiles|status|on <id>|set custom <brand> <manufacturer> <model> <device> [--name n] [--fp f]|off|verify|restart|boot <n> [--restart]"; return 1 ;;
  esac
}
dv_run() { dv_main "$@"; dv_rc=$?; case "$1" in on|set|off) [ "$DV_RESTART" = 1 ] && [ "$dv_rc" = 0 ] && dv_cmd_restart ;; esac; return "$dv_rc"; }
dv_run "$@"
