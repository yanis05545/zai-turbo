#!/system/bin/sh
# =====================================================================
#  Zyrox v2.2 - lib/kernel_match.sh   ("Cocokkan kernel")
#
#  Katalog fpsgo_profile.conf + node "disc" (lib/fpsgo.sh) berasal dari
#  ingatan nama simbol driver MTK FPSGO v1-v3, BELUM tentu cocok dengan
#  kernel/driver device nyata (lihat README "Catatan jujur"). Fitur ini
#  mengecek nama node tsb terhadap sebuah berkas kernel/driver yang
#  diupload (boot Image, vendor_dlkm.img, atau .ko tunggal) via WebUI
#  atau CLI, dengan mencari nama simbol itu sebagai STRING di dalam
#  berkas biner tsb (tanpa perlu toolchain disasm).
#
#  BATASAN JUJUR (lihat juga hasil di laporan):
#   * Nama simbol ada di binary TIDAK menjamin semantik nilainya sama -
#     audisi A/B (lib/fpsgo.sh) tetap satu-satunya pengaman sesungguhnya.
#   * Boot Image GKI modern (Android 11+) umumnya TIDAK berisi driver
#     vendor (gpufreq/FPSGO/GED) sama sekali - itu ada terpisah sebagai
#     modul .ko di vendor_dlkm.img, dimuat saat boot. Kalau file yang
#     diupload ternyata boot Image generik begini, hasil match tidak
#     berarti apa-apa dan laporan akan bilang begitu secara eksplisit
#     alih-alih pura-pura mencocokkan.
# =====================================================================

KMATCH_DIR="$DATADIR/incoming"
KMATCH_REPORT="$SCANDIR/kernel_match_report.txt"
KMATCH_PROFILE="$SCANDIR/fpsgo_profile.matched.conf"
KMATCH_KIND="$SCANDIR/kernel_match_kind.txt"   # klasifikasi hasil match terakhir (dipakai kernel_match_apply)
KMATCH_MAXSZ=314572800   # 300MB, pengaman storage /data

mkdir -p "$KMATCH_DIR" 2>/dev/null

# ekstrak token identifier (>=4 char alnum/_) dari berkas biner, unik+terurut
km_extract_tokens() {
  if command -v strings >/dev/null 2>&1; then
    strings -a "$1" 2>/dev/null | tr -c 'A-Za-z0-9_' '\n' | awk 'length($0)>=4' | sort -u
  else
    tr -c 'A-Za-z0-9_' '\n' < "$1" 2>/dev/null | awk 'length($0)>=4' | sort -u
  fi
}

# klasifikasi berkas: VENDOR_LIKELY | GKI_BOOT | UNKNOWN  + alasan
#
# PENTING: "mediatek,..." / "mt6NNN-timer" dkk adalah string compatible
# device-tree generik yang ikut ada di HAMPIR SEMUA boot Image ARM64 (tabel
# IP timer umum), BUKAN bukti driver FPSGO/gpufreq spesifik device. Jadi itu
# cuma sinyal lemah (dicatat, tidak dipakai menentukan vendor_likely). Sinyal
# kuat = token yang benar-benar menyebut fpsgo/gpufreq/ged, yang hanya ada
# kalau driver itu memang dikompail ke berkas ini.
km_classify() {
  kc_f=$1; kc_tok=$2
  kc_strong=$(grep -ciE 'fpsgo|gpufreq|^ged_|mtk_ged' "$kc_tok" 2>/dev/null); kc_strong=${kc_strong:-0}
  kc_weak=$(grep -ciE '^(mtk|mediatek)$|^mt6[0-9][0-9][0-9]' "$kc_tok" 2>/dev/null); kc_weak=${kc_weak:-0}
  kc_banner=$(command -v strings >/dev/null 2>&1 && strings -a "$kc_f" 2>/dev/null | grep -m1 -E 'Linux version [0-9]')
  kc_isboot=0
  case "$kc_banner" in *Linux\ version*) kc_isboot=1 ;; esac
  if [ "$kc_strong" -ge 1 ]; then
    echo "VENDOR_LIKELY|ditemukan $kc_strong penanda spesifik fpsgo/gpufreq/ged (+$kc_weak penanda MediaTek umum) - berkas ini kemungkinan berisi driver vendor yang relevan untuk dicocokkan."
  elif [ "$kc_isboot" = 1 ]; then
    echo "GKI_BOOT|ini boot Image kernel generik ($kc_banner). Nol penanda spesifik fpsgo/gpufreq/ged ($kc_weak penanda MediaTek umum ditemukan, tapi itu cuma string device-tree generik yang ada di hampir semua boot Image, bukan bukti driver). Driver vendor biasanya TERPISAH di vendor_dlkm.img (modul .ko), bukan di boot Image ini. Upload vendor_dlkm.img atau .ko modulnya langsung untuk hasil yang berarti."
  else
    echo "UNKNOWN|nol penanda spesifik fpsgo/gpufreq/ged di berkas ini ($kc_weak penanda MediaTek umum) - kemungkinan bukan driver vendor yang relevan, atau berkas terkompresi/terenkripsi (coba ekstrak dulu, mis. unpack vendor_dlkm.img ke .ko individual)."
  fi
}

# kernel_match_run <path berkas>
kernel_match_run() {
  km_f=$1
  [ -n "$km_f" ] && [ -f "$km_f" ] || { echo "berkas tidak ditemukan: $km_f"; return 1; }
  km_sz=$(wc -c < "$km_f" 2>/dev/null); km_sz=${km_sz:-0}
  [ "$km_sz" -gt 0 ] || { echo "berkas kosong"; return 1; }
  if [ "$km_sz" -gt "$KMATCH_MAXSZ" ]; then
    echo "berkas $((km_sz / 1048576))MB melebihi batas $((KMATCH_MAXSZ / 1048576))MB, dibatalkan (hemat storage /data)"
    return 1
  fi

  km_tok="$RUNDIR/kmatch_tokens.txt"
  km_extract_tokens "$km_f" > "$km_tok"
  km_ntok=$(wc -l < "$km_tok" 2>/dev/null); km_ntok=${km_ntok:-0}

  km_class=$(km_classify "$km_f" "$km_tok")
  km_kind=${km_class%%|*}; km_why=${km_class#*|}

  km_cat=$(fpsgo_catalog_file)
  km_nodes="$RUNDIR/kmatch_nodes.txt"
  : > "$km_nodes"
  [ -f "$km_cat" ] && awk -F'|' '!/^#/ && NF>=1 && $1!="" {print $1"|katalog:"$4}' "$km_cat" >> "$km_nodes"
  if [ -s "$SCANDIR/fpsgo_candidates.txt" ]; then
    awk '{
      n = split($0, a, "/"); if (n < 2) next
      last = a[n]; sub(/ .*/, "", last)
      if (last == "") next
      print last "|disc"
    }' "$SCANDIR/fpsgo_candidates.txt" | sort -u >> "$km_nodes"
  fi
  sort -u -t'|' -k1,1 "$km_nodes" -o "$km_nodes" 2>/dev/null

  km_match=0; km_total=0
  {
    echo "=== Zyrox kernel match report ==="
    echo "Tanggal    : $(date)"
    echo "Berkas     : $km_f ($((km_sz / 1024))KB, $km_ntok token unik diekstrak)"
    echo "Klasifikasi: $km_kind"
    echo "  $km_why"
    [ "${ROM_FAMILY:-}" = gsi ] && echo "  Catatan ROM: device ini terdeteksi GSI/Treble generic system image ($ROM_WHY) - GSI umumnya TIDAK menyertakan driver vendor FPSGO/gpufreq penuh, jadi hasil match di bawah kemungkinan besar nol/tidak berarti meski kernelnya asli."
    echo
    echo "PENTING: nama simbol cocok TIDAK berarti semantik nilainya sama persis"
    echo "di device ini - ini hanya menyaring node yang jelas tidak relevan."
    echo "Audisi A/B per game ('azenith-ai fpsgo') tetap satu-satunya pengaman nyata."
    echo
    echo "--- hasil per node (katalog=dari fpsgo_profile.conf, disc=ditemukan live di device) ---"
    while IFS='|' read -r kn_name kn_src; do
      [ -n "$kn_name" ] || continue
      km_total=$((km_total + 1))
      if grep -qxF "$kn_name" "$km_tok" 2>/dev/null; then
        km_match=$((km_match + 1))
        echo "COCOK      $kn_name  ($kn_src)"
      else
        echo "tidak ada  $kn_name  ($kn_src)"
      fi
    done < "$km_nodes"
    echo
    echo "Ringkasan  : $km_match / $km_total node ditemukan namanya di berkas ini."
    [ "$km_kind" != VENDOR_LIKELY ] && echo "Catatan    : klasifikasi di atas BUKAN vendor_likely, jadi jumlah cocok di atas kemungkinan kebetulan/tidak berarti - jangan dipakai sebagai dasar 'apply'."
    echo
    echo "Profil tersaring (hanya node katalog yang cocok): $KMATCH_PROFILE"
    echo "Terapkan sebagai profil aktif: azenith-ai kernel apply"
  } > "$KMATCH_REPORT"

  if [ -f "$km_cat" ]; then
    {
      echo "# dihasilkan otomatis oleh 'azenith-ai kernel match' $(date '+%F %T')"
      echo "# sumber: $km_f ($km_kind)"
      echo "# HANYA baris katalog yang namanya ditemukan di berkas kernel/driver yang diupload."
      echo "# Audisi A/B tetap jalan seperti biasa untuk node yang lolos di sini."
      awk -F'|' '!/^#/ && NF>=1 && $1!=""' "$km_cat" | while IFS='|' read -r kc_n kc_v kc_c kc_g; do
        grep -qxF "$kc_n" "$km_tok" 2>/dev/null && echo "$kc_n|$kc_v|$kc_c|$kc_g"
      done
    } > "$KMATCH_PROFILE"
  else
    : > "$KMATCH_PROFILE"
  fi

  echo "$km_kind" > "$KMATCH_KIND"
  cat "$KMATCH_REPORT"
  log_msg "KMATCH: $km_f kind=$km_kind match=$km_match/$km_total -> $KMATCH_REPORT"

  # berkas upload (di DATADIR/incoming) dihapus otomatis setelah diproses;
  # berkas yang ditunjuk langsung oleh user di luar situ TIDAK disentuh.
  case "$km_f" in "$KMATCH_DIR"/*) rm -f "$km_f" ;; esac
  return 0
}

# terapkan hasil saringan terakhir sebagai fpsgo_profile.conf aktif (dengan backup)
# kernel_match_apply [force] - tanpa "force", ditolak kalau berkas yang diupload
# terakhir BUKAN diklasifikasi VENDOR_LIKELY (lihat km_classify) - mencocokkan nama
# simbol ke boot Image generik/berkas tak relevan tidak membuktikan apa-apa (lihat
# README "Catatan jujur"), jadi menerapkannya sebagai default justru bisa menulis
# node yang namanya kebetulan sama tapi fungsinya beda. Audisi A/B tetap jalan
# setelah apply baik dipaksa atau tidak - ini hanya mengurangi node yang masuk
# antrian audisi dari awal, bukan pengganti audisi.
kernel_match_apply() {
  ka_force=$1
  [ -s "$KMATCH_PROFILE" ] || { echo "belum ada hasil match (jalankan dulu: azenith-ai kernel match <berkas>)"; return 1; }
  km_n=$(grep -vc '^#' "$KMATCH_PROFILE" 2>/dev/null); km_n=${km_n:-0}
  [ "$km_n" -gt 0 ] || { echo "hasil match terakhir 0 node cocok - tidak diterapkan (profil lama dibiarkan)"; return 1; }
  km_kind_saved=$(cat "$KMATCH_KIND" 2>/dev/null)
  if [ "$km_kind_saved" != VENDOR_LIKELY ] && [ "$ka_force" != force ]; then
    echo "DITOLAK: hasil match terakhir diklasifikasi '$km_kind_saved' (bukan VENDOR_LIKELY)."
    echo "Nama simbol yang cocok di berkas ini kemungkinan kebetulan/tidak berarti - lihat $KMATCH_REPORT."
    echo "Upload vendor_dlkm.img atau .ko driver yang benar, atau paksa dengan: azenith-ai kernel apply force"
    echo "(audisi A/B tetap akan menguji efek nyata tiap grup ke FPS - ini hanya memilih node mana yang masuk antrian)"
    return 1
  fi
  [ "$ka_force" = force ] && [ "$km_kind_saved" != VENDOR_LIKELY ] && \
    echo "PERINGATAN: dipaksa menerapkan match '$km_kind_saved' (bukan VENDOR_LIKELY) - audisi A/B akan membuang node yang tidak terbukti membantu."
  km_active="$DATADIR/fpsgo_profile.conf"
  [ -f "$km_active" ] && cp -f "$km_active" "$DATADIR/fpsgo_profile.conf.bak" 2>/dev/null
  if cp -f "$KMATCH_PROFILE" "$km_active"; then
    echo "diterapkan: $km_active ($km_n node) - backup profil lama: $DATADIR/fpsgo_profile.conf.bak"
    log_msg "KMATCH: profil tersaring diterapkan ($km_n node)"
  else
    echo "gagal menyalin profil"; return 1
  fi
}

kernel_match_revert() {
  [ -f "$DATADIR/fpsgo_profile.conf.bak" ] || { echo "tidak ada backup"; return 1; }
  mv -f "$DATADIR/fpsgo_profile.conf.bak" "$DATADIR/fpsgo_profile.conf" && echo "profil fpsgo dikembalikan ke sebelum 'kernel apply'"
}
