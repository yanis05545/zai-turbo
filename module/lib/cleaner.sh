#!/system/bin/sh
# =====================================================================
#  Zyrox v2 - lib/cleaner.sh
#  Pembersih Sistem: cache aplikasi (internal + penyimpanan), cache
#  sistem/Dalvik/OAT, log crash (tombstones/ANR/dropbox), sisa OTA, file
#  sementara, dan folder sisa (sampah) app yang sudah di-uninstall.
#
#  SENGAJA TIDAK MENYENTUH /data/system/ secara keseluruhan (cuma
#  subfolder package_cache/ & dropbox/ yang memang resmi cache/log, aman
#  dibuang/regenerasi otomatis). /data/system/ berisi state sistem yang
#  AKTIF dipakai (packages.xml, akun, WiFi, device admin, battery stats,
#  dll) - bukan cache, dan menghapusnya bisa bikin bootloop / kehilangan
#  data, BUKAN mempercepat apa pun. Jangan pernah rm -rf seluruh folder itu.
#
#  Cache aplikasi dengan uid < 10000 (proses sistem inti, bukan
#  app biasa) dilewati secara default supaya tidak mengganggu service
#  yang sedang jalan.
#
#  DUA METODE:
#   - soft    : ringan, cuma cache app (internal+penyimpanan+package_cache)
#               & folder sampah app yang sudah di-uninstall - setara mode
#               cache+trash lama, risiko nyaris nol, aman dijalankan kapan
#               saja termasuk sambil device dipakai.
#   - agresif : soft DITAMBAH dalvik-cache/OAT, partisi /cache, log crash
#               (tombstones/ANR/dropbox), sisa OTA, file sementara - SEMUA
#               kategori kehapus total. Efek samping NORMAL (bukan bug):
#               app pertama dibuka lagi setelah agresif bisa sedikit lebih
#               lambat (dex2oat compile ulang), OTA yang sudah diunduh
#               harus diunduh ulang. Semua yang dihapus di sini memang
#               regenerasi otomatis oleh sistem, bukan data pribadi.
#
#  Fitur ini membersihkan SAMPAH & CACHE, bukan antivirus. Deteksi
#  malware/virus butuh signature/behaviour scanning yang di luar
#  jangkauan skrip shell - jangan diklaim bisa itu di sini.
# =====================================================================

CL_PKGLIST="$RUNDIR/cleaner_pkgs.txt"

# --- helper kecil, ikut pola "cmd || busybox cmd || toybox cmd" di lib lain ---
cl_du_kb() { # cl_du_kb <path> -> KB (0 kalau gagal/tidak ada)
  [ -e "$1" ] || { echo 0; return; }
  cl_d=$(du -sk "$1" 2>/dev/null) || cl_d=$(busybox du -sk "$1" 2>/dev/null) || cl_d=$(toybox du -sk "$1" 2>/dev/null)
  cl_d=${cl_d%%	*}; cl_d=${cl_d%% *}
  case "$cl_d" in ''|*[!0-9]*) echo 0 ;; *) echo "$cl_d" ;; esac
}

cl_uid_of() { # cl_uid_of <path> -> uid numerik (kosong kalau gagal)
  cl_u=$(stat -c %u "$1" 2>/dev/null) || cl_u=$(busybox stat -c %u "$1" 2>/dev/null) || cl_u=$(toybox stat -c %u "$1" 2>/dev/null)
  case "$cl_u" in ''|*[!0-9]*) echo "" ;; *) echo "$cl_u" ;; esac
}

cl_clear_dir() { # cl_clear_dir <path> - hapus ISI direktori, folder-nya sendiri (& izinnya) dibiarkan
  [ -d "$1" ] || return 0
  find "$1" -mindepth 1 -exec rm -rf {} + 2>/dev/null
}

cl_extroot() { # folder Android/data penyimpanan utama (multi-user 0), kosong kalau tak ada
  for cl_p in "$R/storage/emulated/0/Android/data" "$R/sdcard/Android/data" "${EXTERNAL_STORAGE:-}/Android/data"; do
    [ -n "$cl_p" ] && [ -d "$cl_p" ] && { echo "$cl_p"; return; }
  done
  echo ""
}

cl_obbroot() { # folder Android/obb yang sepasang dengan cl_extroot
  for cl_p in "$R/storage/emulated/0/Android/obb" "$R/sdcard/Android/obb" "${EXTERNAL_STORAGE:-}/Android/obb"; do
    [ -n "$cl_p" ] && [ -d "$cl_p" ] && { echo "$cl_p"; return; }
  done
  echo ""
}

# cl_wipe_path <path> -> cetak KB yang dibebaskan; kalau direktori, ISINYA
# saja yang dihapus (folder tetap ada), kalau file langsung dihapus filenya.
cl_wipe_path() {
  [ -e "$1" ] || { echo 0; return; }
  cw_kb=$(cl_du_kb "$1")
  if [ -d "$1" ]; then cl_clear_dir "$1"; else rm -f "$1" 2>/dev/null; fi
  echo "$cw_kb"
}

# cl_paths_kb <path...> -> total KB (hanya hitung, tidak hapus)
cl_paths_kb() {
  cpk_t=0
  for cpk_p in "$@"; do
    [ -e "$cpk_p" ] || continue
    cpk_t=$((cpk_t + $(cl_du_kb "$cpk_p")))
  done
  echo "$cpk_t"
}

# Dalvik-cache/OAT: /data/dalvik-cache (global, device lama) + /data/app/*/oat
# & /data/app/*/*/oat (AOT dex2ot per app terpasang, lokasi beda-beda
# tergantung versi Android) - SEMUA regenerasi otomatis oleh dex2oat saat
# app dibuka lagi, sama persis seperti package_cache di atas (bukan data,
# cuma cache kompilasi). /cache (partisi cache terpisah, bukan /data/cache)
# juga dihitung di sini - isinya staging OTA/recovery, aman dikosongkan.
cl_oat_dirs() { find "$R/data/app" -maxdepth 3 -type d -name oat 2>/dev/null; }

cl_dalvik_kb() {
  cdk_t=$(cl_paths_kb "$R/data/dalvik-cache" "$R/cache")
  for cdk_d in $(cl_oat_dirs); do cdk_t=$((cdk_t + $(cl_du_kb "$cdk_d"))); done
  echo "$cdk_t"
}
cl_dalvik_clean() {
  cdc_t=$(cl_wipe_path "$R/data/dalvik-cache")
  cdc_t=$((cdc_t + $(cl_wipe_path "$R/cache")))
  for cdc_d in $(cl_oat_dirs); do cdc_t=$((cdc_t + $(cl_wipe_path "$cdc_d"))); done
  echo "$cdc_t"
}

# Log error/crash - isinya dump crash, aman dihapus, TIDAK dipakai sistem
# yang sedang jalan (beda dengan file di /data/system/ lainnya).
cl_crash_kb()   { cl_paths_kb "$R/data/tombstones" "$R/data/anr" "$R/data/system/dropbox"; }
cl_crash_clean() {
  ccc_t=$(cl_wipe_path "$R/data/tombstones")
  ccc_t=$((ccc_t + $(cl_wipe_path "$R/data/anr")))
  ccc_t=$((ccc_t + $(cl_wipe_path "$R/data/system/dropbox")))
  echo "$ccc_t"
}

# Sisa update/OTA - paket update yang sudah diunduh/diterapkan, aman
# dihapus (kalau memang masih pending, device akan unduh ulang).
# "$R/sdcard/MIUI/rom" dicek sebagai contoh folder updater vendor (MIUI);
# device vendor lain dengan folder serupa bisa ditambahkan ke daftar ini.
cl_ota_dir() {
  for cod_p in "$R/sdcard/MIUI/rom"; do
    [ -d "$cod_p" ] && { echo "$cod_p"; return; }
  done
  echo ""
}
cl_ota_kb() {
  cok_t=$(cl_paths_kb "$R/data/ota" "$R/data/ota_package")
  cok_d=$(cl_ota_dir); [ -n "$cok_d" ] && cok_t=$((cok_t + $(cl_du_kb "$cok_d")))
  echo "$cok_t"
}
cl_ota_clean() {
  coc_t=$(cl_wipe_path "$R/data/ota")
  coc_t=$((coc_t + $(cl_wipe_path "$R/data/ota_package")))
  coc_d=$(cl_ota_dir); [ -n "$coc_d" ] && coc_t=$((coc_t + $(cl_wipe_path "$coc_d")))
  echo "$coc_t"
}

# File sementara - /data/local/tmp (shell/adb/root tools biasa numpuk di
# sini) & /sdcard/LOST.DIR (folder "lost+found" FAT, berkas yatim piatu
# hasil crash/unmount tidak bersih) - aman dihapus.
cl_tmp_kb()   { cl_paths_kb "$R/data/local/tmp" "$R/sdcard/LOST.DIR"; }
cl_tmp_clean() {
  ctc_t=$(cl_wipe_path "$R/data/local/tmp")
  ctc_t=$((ctc_t + $(cl_wipe_path "$R/sdcard/LOST.DIR")))
  echo "$ctc_t"
}

cl_refresh_pkglist() {
  { pm list packages 2>/dev/null || cmd package list packages 2>/dev/null; } | sed -n 's/^package://p' | sort -u > "$CL_PKGLIST.tmp" 2>/dev/null
  [ -s "$CL_PKGLIST.tmp" ] && mv -f "$CL_PKGLIST.tmp" "$CL_PKGLIST" || rm -f "$CL_PKGLIST.tmp"
}

cl_is_installed() { # cl_is_installed <pkg> -> exit 0 kalau masih terpasang
  [ -f "$CL_PKGLIST" ] || cl_refresh_pkglist
  grep -qx "$1" "$CL_PKGLIST" 2>/dev/null
}

# ---------------------------------------------------------------------
# Pindai - hanya MENGHITUNG ukuran, tidak menghapus apa pun
# ---------------------------------------------------------------------
cl_scan() {
  cl_refresh_pkglist
  cl_app_kb=0; cl_app_n=0
  for cl_d in "$R"/data/data/*/cache "$R"/data/data/*/code_cache; do
    [ -d "$cl_d" ] || continue
    cl_uid=$(cl_uid_of "$cl_d")
    [ -n "$cl_uid" ] || continue
    [ "$cl_uid" -ge 10000 ] 2>/dev/null || continue
    cl_kb=$(cl_du_kb "$cl_d")
    [ "$cl_kb" -gt 0 ] 2>/dev/null || continue
    cl_app_kb=$((cl_app_kb + cl_kb)); cl_app_n=$((cl_app_n + 1))
  done

  cl_ext_kb=0; cl_ext_n=0
  cl_er=$(cl_extroot)
  if [ -n "$cl_er" ]; then
    for cl_d in "$cl_er"/*/cache; do
      [ -d "$cl_d" ] || continue
      cl_kb=$(cl_du_kb "$cl_d")
      [ "$cl_kb" -gt 0 ] 2>/dev/null || continue
      cl_ext_kb=$((cl_ext_kb + cl_kb)); cl_ext_n=$((cl_ext_n + 1))
    done
  fi

  cl_sys_kb=0
  [ -d "$R/data/system/package_cache" ] && cl_sys_kb=$(cl_du_kb "$R/data/system/package_cache")

  cl_trash_kb=0; cl_trash_n=0
  cl_ob=$(cl_obbroot)
  if [ -n "$cl_er" ]; then
    for cl_d in "$cl_er"/*; do
      [ -d "$cl_d" ] || continue
      cl_p=$(basename "$cl_d")
      case "$cl_p" in .*) continue ;; esac
      cl_is_installed "$cl_p" && continue
      cl_kb=$(cl_du_kb "$cl_d")
      [ "$cl_kb" -gt 0 ] 2>/dev/null || continue
      cl_trash_kb=$((cl_trash_kb + cl_kb)); cl_trash_n=$((cl_trash_n + 1))
    done
  fi
  if [ -n "$cl_ob" ]; then
    for cl_d in "$cl_ob"/*; do
      [ -d "$cl_d" ] || continue
      cl_p=$(basename "$cl_d")
      case "$cl_p" in .*) continue ;; esac
      cl_is_installed "$cl_p" && continue
      cl_kb=$(cl_du_kb "$cl_d")
      [ "$cl_kb" -gt 0 ] 2>/dev/null || continue
      cl_trash_kb=$((cl_trash_kb + cl_kb)); cl_trash_n=$((cl_trash_n + 1))
    done
  fi

  cl_dalvik_kbv=$(cl_dalvik_kb)
  cl_crash_kbv=$(cl_crash_kb)
  cl_ota_kbv=$(cl_ota_kb)
  cl_tmp_kbv=$(cl_tmp_kb)
  cl_soft_kb=$((cl_app_kb + cl_ext_kb + cl_sys_kb + cl_trash_kb))

  echo "cache_app_kb=$cl_app_kb"
  echo "cache_app_count=$cl_app_n"
  echo "cache_ext_kb=$cl_ext_kb"
  echo "cache_ext_count=$cl_ext_n"
  echo "cache_syscache_kb=$cl_sys_kb"
  echo "cache_dalvik_kb=$cl_dalvik_kbv"
  echo "crash_log_kb=$cl_crash_kbv"
  echo "ota_kb=$cl_ota_kbv"
  echo "tmp_kb=$cl_tmp_kbv"
  echo "trash_kb=$cl_trash_kb"
  echo "trash_count=$cl_trash_n"
  echo "soft_total_kb=$cl_soft_kb"
  echo "total_kb=$((cl_soft_kb + cl_dalvik_kbv + cl_crash_kbv + cl_ota_kbv + cl_tmp_kbv))"
}

# ---------------------------------------------------------------------
# Bersihkan - mode: cache | trash | dalvik | crash | ota | tmp | soft | agresif
#   soft    = cache + trash (ringan, cuma cache app & sampah app terhapus)
#   agresif = soft + dalvik + crash + ota + tmp (SEMUA, dihapus total)
#   "all" tetap didukung sebagai alias lama dari "agresif".
# ---------------------------------------------------------------------
cl_clean() {
  cl_mode=${1:-soft}
  case "$cl_mode" in all) cl_mode=agresif ;; esac
  cl_freed=0

  if [ "$cl_mode" = cache ] || [ "$cl_mode" = soft ] || [ "$cl_mode" = agresif ]; then
    for cl_d in "$R"/data/data/*/cache "$R"/data/data/*/code_cache; do
      [ -d "$cl_d" ] || continue
      cl_uid=$(cl_uid_of "$cl_d")
      [ -n "$cl_uid" ] || continue
      [ "$cl_uid" -ge 10000 ] 2>/dev/null || continue
      cl_kb=$(cl_du_kb "$cl_d")
      cl_clear_dir "$cl_d"
      cl_freed=$((cl_freed + cl_kb))
    done
    cl_er=$(cl_extroot)
    if [ -n "$cl_er" ]; then
      for cl_d in "$cl_er"/*/cache; do
        [ -d "$cl_d" ] || continue
        cl_kb=$(cl_du_kb "$cl_d")
        cl_clear_dir "$cl_d"
        cl_freed=$((cl_freed + cl_kb))
      done
    fi
    if [ -d "$R/data/system/package_cache" ]; then
      cl_kb=$(cl_du_kb "$R/data/system/package_cache")
      cl_clear_dir "$R/data/system/package_cache"
      cl_freed=$((cl_freed + cl_kb))
    fi
  fi

  if [ "$cl_mode" = trash ] || [ "$cl_mode" = soft ] || [ "$cl_mode" = agresif ]; then
    cl_refresh_pkglist
    cl_er=$(cl_extroot); cl_ob=$(cl_obbroot)
    if [ -n "$cl_er" ]; then
      for cl_d in "$cl_er"/*; do
        [ -d "$cl_d" ] || continue
        cl_p=$(basename "$cl_d")
        case "$cl_p" in .*) continue ;; esac
        cl_is_installed "$cl_p" && continue
        cl_kb=$(cl_du_kb "$cl_d")
        rm -rf "$cl_d" 2>/dev/null
        cl_freed=$((cl_freed + cl_kb))
      done
    fi
    if [ -n "$cl_ob" ]; then
      for cl_d in "$cl_ob"/*; do
        [ -d "$cl_d" ] || continue
        cl_p=$(basename "$cl_d")
        case "$cl_p" in .*) continue ;; esac
        cl_is_installed "$cl_p" && continue
        cl_kb=$(cl_du_kb "$cl_d")
        rm -rf "$cl_d" 2>/dev/null
        cl_freed=$((cl_freed + cl_kb))
      done
    fi
  fi

  # Kategori di bawah ini HANYA jalan di mode agresif (atau mode
  # spesifiknya sendiri kalau dipanggil langsung) - tidak termasuk soft.
  if [ "$cl_mode" = dalvik ] || [ "$cl_mode" = agresif ]; then
    cl_freed=$((cl_freed + $(cl_dalvik_clean)))
  fi
  if [ "$cl_mode" = crash ] || [ "$cl_mode" = agresif ]; then
    cl_freed=$((cl_freed + $(cl_crash_clean)))
  fi
  if [ "$cl_mode" = ota ] || [ "$cl_mode" = agresif ]; then
    cl_freed=$((cl_freed + $(cl_ota_clean)))
  fi
  if [ "$cl_mode" = tmp ] || [ "$cl_mode" = agresif ]; then
    cl_freed=$((cl_freed + $(cl_tmp_clean)))
  fi

  cl_freed_mb=$((cl_freed / 1024))
  log_msg "Cleaner: mode=$cl_mode freed=${cl_freed_mb}MB"
  echo "freed_kb=$cl_freed"
  echo "freed_mb=$cl_freed_mb"
  echo "mode=$cl_mode"
}

# ---------------------------------------------------------------------
# cl_test - cl_scan (sebelum) -> cl_clean all (beneran menghapus) -> cl_scan
# lagi (sesudah), bandingkan total_kb NYATA - supaya ketahuan ruang yang
# "dibersihkan" itu beneran hilang dari disk, bukan cuma angka MB kosmetik
# di WebUI. PERINGATAN: ini beneran menghapus cache & folder sampah app
# yang sudah di-uninstall, sama seperti cl_clean all biasa - bukan dry-run.
# ---------------------------------------------------------------------
cl_test() {
  testlog_begin pembersih_sistem
  testlog "--- SCAN SEBELUM ---"
  cl_before=$(cl_scan)
  echo "$cl_before" | while IFS= read -r cl_ln; do testlog "$cl_ln"; done
  cl_before_kb=$(echo "$cl_before" | sed -n 's/^total_kb=//p')
  testlog ""
  testlog "--- MENJALANKAN cl_clean agresif (NYATA menghapus SEMUA kategori, bukan simulasi) ---"
  cl_res=$(cl_clean agresif)
  echo "$cl_res" | while IFS= read -r cl_ln; do testlog "$cl_ln"; done
  testlog ""
  testlog "--- SCAN SESUDAH ---"
  cl_after=$(cl_scan)
  echo "$cl_after" | while IFS= read -r cl_ln; do testlog "$cl_ln"; done
  cl_after_kb=$(echo "$cl_after" | sed -n 's/^total_kb=//p')
  testlog ""
  testlog "HASIL NYATA: total_kb sebelum=${cl_before_kb:-0} sesudah=${cl_after_kb:-0} (selisih = ruang yang BENAR-BENAR hilang dari disk, dicek ulang pakai du nyata - bukan sekadar klaim 'freed_kb' dari cl_clean)"
  testlog_end
}
