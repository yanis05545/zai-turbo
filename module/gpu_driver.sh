#!/system/bin/sh
# =====================================================================
#  Zyrox - gpu_driver.sh  (v1.0.44)  "Driver 2": tambah/ganti driver grafis & sistem
#
#  Dua jalur (sesuai arsitektur Android):
#   A) PER-APP  - Graphics Driver Preferences (Android 10+). Tanpa menyentuh partisi:
#        settings global game_driver_* / angle_gl_driver_selection_*  + slot paket driver
#        ro.gfx.driver.0 (production) / ro.gfx.driver.1 (prerelease = "driver 2").
#   B) SYSTEM-WIDE - overlay Magic Mount: berkas .so ditaruh di $MODDIR/system/vendor/lib64/...
#        (Magisk/KernelSU/APatch me-mount di atas /vendor saat boot; partisi asli TIDAK diubah,
#        hapus overlay + reboot = kembali asli).
#
#  Pakai (root):
#   sh gpu_driver.sh info | validate <so> | install <so> [vulkan|egl|gles2|gles1] [nama] | remove
#   sh gpu_driver.sh app set <pkg> <driver|prerelease|native|angle> | app unset <pkg> | app list
#   sh gpu_driver.sh all <default|driver|prerelease>      (game_driver_all_apps)
#   sh gpu_driver.sh pkg <0|1> <paket-apk-driver|none>     (ro.gfx.driver.N, resetprop, tiap boot)
#   sh gpu_driver.sh status | boot
# =====================================================================
MODDIR=${MODDIR:-/data/adb/modules/zyrox-mod}
DATADIR="${TX_DATA:-/data/adb/azenith-ai}"
CONF="$DATADIR/azenith-ai.conf"
GD_MANIFEST="$DATADIR/gpudrv.manifest"      # path-overlay yang dipasang modul ini
GD_PKGS="$DATADIR/gpudrv.pkgs"              # slot|paket (diterapkan tiap boot)
export PATH="$PATH:/data/adb/magisk:/data/adb/ksu/bin:/data/adb/ap/bin:/system/bin"
mkdir -p "$DATADIR" 2>/dev/null

gd_say() { printf '%s\n' "$*"; }
gd_need_root() { [ "$(id -u 2>/dev/null)" = 0 ] && return 0; gd_say "GAGAL: butuh root"; return 1; }
gd_prop() { getprop "$1" 2>/dev/null | tr -d '\r'; }
gd_get() { settings get global "$1" 2>/dev/null | sed 's/^null$//'; }

# ---- validasi syarat teknis driver kustom ----
# 1) ELF64 little-endian  2) e_machine = AArch64 (0xB7)  3) ekspor simbol yang diminta loader
gd_hex() { od -An -tx1 -j"$2" -N"$3" "$1" 2>/dev/null | tr -d ' \n'; }
gd_validate() { # <file> <tipe>
  v_f=$1; v_t=${2:-vulkan}; v_bad=0
  [ -r "$v_f" ] || { gd_say "GAGAL: berkas tidak terbaca: $v_f"; return 1; }
  [ "$(gd_hex "$v_f" 0 4)" = "7f454c46" ] && gd_say "[OK ] magic ELF" || { gd_say "[GAGAL] bukan ELF"; v_bad=1; }
  [ "$(gd_hex "$v_f" 4 1)" = "02" ] && gd_say "[OK ] ELFCLASS64 (arm64-v8a)" || { gd_say "[GAGAL] bukan 64-bit - /vendor/lib64 butuh 64-bit"; v_bad=1; }
  [ "$(gd_hex "$v_f" 18 2)" = "b700" ] && gd_say "[OK ] e_machine = AArch64" || { gd_say "[GAGAL] arsitektur bukan AArch64 (ABI tidak cocok)"; v_bad=1; }
  case "$v_t" in
    vulkan)
      # hwvulkan HAL: loader mencari simbol HAL_MODULE_INFO_SYM (struct hw_module_t id "vulkan")
      if grep -q -a 'HAL_MODULE_INFO_SYM' "$v_f"; then gd_say "[OK ] ekspor HAL_MODULE_INFO_SYM (hwvulkan)"
      else gd_say "[PERINGATAN] HAL_MODULE_INFO_SYM tidak ada - ini bukan HAL vulkan.<x>.so (mungkin ICD Mesa/Turnip yang dimuat lewat paket driver, bukan overlay)"; fi
      grep -q -a 'vkGetInstanceProcAddr' "$v_f" && gd_say "[OK ] simbol vkGetInstanceProcAddr" || gd_say "[PERINGATAN] vkGetInstanceProcAddr tidak terlihat" ;;
    egl|gles2|gles1)
      grep -q -a 'eglGetProcAddress\|eglInitialize\|glGetString' "$v_f" && gd_say "[OK ] simbol EGL/GLES ditemukan" || { gd_say "[GAGAL] simbol EGL/GLES tidak ada"; v_bad=1; } ;;
  esac
  [ "$v_bad" -eq 0 ]
}

gd_target_path() { # <tipe> <nama>
  case "$1" in
    vulkan) printf '%s/system/vendor/lib64/hw/vulkan.%s.so' "$MODDIR" "$2" ;;
    egl)    printf '%s/system/vendor/lib64/egl/libEGL_%s.so' "$MODDIR" "$2" ;;
    gles2)  printf '%s/system/vendor/lib64/egl/libGLESv2_%s.so' "$MODDIR" "$2" ;;
    gles1)  printf '%s/system/vendor/lib64/egl/libGLESv1_CM_%s.so' "$MODDIR" "$2" ;;
  esac
}

gd_cmd_info() {
  gd_say "== Platform =="
  for k in ro.board.platform ro.hardware ro.hardware.vulkan ro.hardware.egl ro.opengles.version ro.gfx.driver.0 ro.gfx.driver.1 ro.product.cpu.abi persist.graphics.vulkan.disable; do gd_say "$k=$(gd_prop $k)"; done
  gd_say "== Berkas driver di vendor (lib64) =="
  ls -l /vendor/lib64/hw/vulkan.*.so /vendor/lib64/egl/*.so 2>/dev/null | awk '{print $1, $5, $NF}'
  gd_say "== Graphics Driver Preferences =="
  for k in game_driver_all_apps game_driver_opt_in_apps game_driver_opt_out_apps game_driver_prerelease_opt_in_apps angle_gl_driver_all_angle angle_gl_driver_selection_pkgs angle_gl_driver_selection_values; do gd_say "$k=$(gd_get $k)"; done
  gd_say "== Yang dibaca aplikasi (cmd gpu vkjson, ringkas) =="
  cmd gpu vkjson 2>/dev/null | tr ',' '\n' | grep -i -m6 'deviceName\|driverVersion\|apiVersion\|vendorID' 
  gd_say "== GLES renderer (SurfaceFlinger) =="
  dumpsys SurfaceFlinger 2>/dev/null | grep -i -m3 'GLES:\|GL_RENDERER\|GL_VERSION'
}

gd_cmd_install() { # <so> [tipe] [nama]
  gd_need_root || return 1
  i_f=$1; i_t=${2:-vulkan}; i_n=$3
  [ -n "$i_f" ] || { gd_say "pakai: install <berkas.so> [vulkan|egl|gles2|gles1] [nama]"; return 1; }
  [ -n "$i_n" ] || { [ "$i_t" = vulkan ] && i_n=$(gd_prop ro.hardware.vulkan) || i_n=$(gd_prop ro.hardware.egl); }
  [ -n "$i_n" ] || { gd_say "GAGAL: nama target kosong (ro.hardware.vulkan/egl tidak ada) - sebutkan nama manual"; return 1; }
  gd_validate "$i_f" "$i_t" || { gd_say "DITOLAK: berkas tidak lolos validasi, overlay TIDAK dipasang."; return 1; }
  i_d=$(gd_target_path "$i_t" "$i_n"); [ -n "$i_d" ] || { gd_say "GAGAL: tipe '$i_t' tidak dikenal"; return 1; }
  mkdir -p "${i_d%/*}" && cp -f "$i_f" "$i_d" || { gd_say "GAGAL menyalin"; return 1; }
  chmod 644 "$i_d"; chown 0:0 "$i_d" 2>/dev/null
  chcon u:object_r:same_process_hal_file:s0 "$i_d" 2>/dev/null || chcon u:object_r:vendor_file:s0 "$i_d" 2>/dev/null
  grep -qxF "$i_d" "$GD_MANIFEST" 2>/dev/null || echo "$i_d" >> "$GD_MANIFEST"
  gd_say "Overlay dipasang: ${i_d#$MODDIR}  -> akan menimpa /vendor/... lewat Magic Mount SETELAH REBOOT."
  gd_say "Partisi /vendor asli tidak diubah. Bootloop? hapus: sh gpu_driver.sh remove (atau flag 'disable' modul)."
}

gd_cmd_remove() {
  gd_need_root || return 1
  r_n=0
  [ -s "$GD_MANIFEST" ] && while read -r r_p; do [ -n "$r_p" ] && rm -f "$r_p" && r_n=$((r_n + 1)); done < "$GD_MANIFEST"
  : > "$GD_MANIFEST"
  gd_say "Overlay dihapus: $r_n berkas. REBOOT agar /vendor kembali murni."
}

# ---- daftar koma di settings global ----
gd_list_add() { # <key> <pkg>
  l_c=$(gd_get "$1"); case ",$l_c," in *",$2,"*) return 0 ;; esac
  settings put global "$1" "${l_c:+$l_c,}$2" 2>/dev/null
}
gd_list_del() { # <key> <pkg>
  l_c=$(gd_get "$1"); [ -n "$l_c" ] || return 0
  l_n=$(printf '%s' "$l_c" | tr ',' '\n' | grep -vxF "$2" | paste -sd, -)
  if [ -n "$l_n" ]; then settings put global "$1" "$l_n" 2>/dev/null; else settings delete global "$1" >/dev/null 2>&1; fi
}
gd_pkg_ok() { case "$1" in ''|*[!A-Za-z0-9._]*) return 1 ;; esac; pm path "$1" >/dev/null 2>&1; }

gd_cmd_app() { # set <pkg> <mode> | unset <pkg> | list
  gd_need_root || return 1
  case "$1" in
    set)
      gd_pkg_ok "$2" || { gd_say "GAGAL: paket '$2' tidak terpasang / nama tidak valid"; return 1; }
      gd_cmd_app_clear "$2"
      case "$3" in
        driver)     gd_list_add game_driver_opt_in_apps "$2"; gd_say "$2 -> Game Driver (production, ro.gfx.driver.0)" ;;
        prerelease) gd_list_add game_driver_prerelease_opt_in_apps "$2"; gd_say "$2 -> Prerelease driver (slot 'driver 2', ro.gfx.driver.1)" ;;
        native)     gd_list_add game_driver_opt_out_apps "$2"; gd_say "$2 -> driver sistem (native)" ;;
        angle)      gd_list_add angle_gl_driver_selection_pkgs "$2"; gd_list_add angle_gl_driver_selection_values angle; gd_say "$2 -> ANGLE (GLES di atas Vulkan)" ;;
        *) gd_say "mode: driver|prerelease|native|angle"; return 1 ;;
      esac
      am force-stop "$2" >/dev/null 2>&1; gd_say "Aplikasi di-force-stop; driver baru dipakai saat dibuka lagi." ;;
    unset) gd_pkg_ok "$2" || true; gd_cmd_app_clear "$2"; am force-stop "$2" >/dev/null 2>&1; gd_say "Preferensi driver $2 dihapus (kembali default)." ;;
    list|"") for k in game_driver_opt_in_apps game_driver_prerelease_opt_in_apps game_driver_opt_out_apps angle_gl_driver_selection_pkgs; do gd_say "$k=$(gd_get $k)"; done ;;
    *) gd_say "pakai: app set <pkg> <driver|prerelease|native|angle> | app unset <pkg> | app list" ;;
  esac
}
gd_cmd_app_clear() {
  CLR_PKG=$1
  for k in game_driver_opt_in_apps game_driver_prerelease_opt_in_apps game_driver_opt_out_apps; do gd_list_del "$k" "$1"; done
  # ANGLE: pkgs & values paralel -> hapus pasangan pada indeks yang sama
  a_p=$(gd_get angle_gl_driver_selection_pkgs); a_v=$(gd_get angle_gl_driver_selection_values)
  case ",$a_p," in *",$1,"*)
    a_np=""; a_nv=""; a_i=0
    OLDIFS=$IFS; IFS=','; set -- $a_p; IFS=$OLDIFS; a_pk="$*"
    OLDIFS=$IFS; IFS=','; set -- $a_v; IFS=$OLDIFS
    for a_x in $a_pk; do a_i=$((a_i + 1)); eval "a_val=\${$a_i:-default}"
      [ "$a_x" = "$CLR_PKG" ] && continue
      a_np="${a_np:+$a_np,}$a_x"; a_nv="${a_nv:+$a_nv,}$a_val"
    done
    if [ -n "$a_np" ]; then settings put global angle_gl_driver_selection_pkgs "$a_np"; settings put global angle_gl_driver_selection_values "$a_nv"
    else settings delete global angle_gl_driver_selection_pkgs >/dev/null 2>&1; settings delete global angle_gl_driver_selection_values >/dev/null 2>&1; fi ;;
  esac
}

gd_cmd_all() {
  gd_need_root || return 1
  case "$1" in default) a_v=0 ;; driver) a_v=1 ;; prerelease) a_v=2 ;; *) gd_say "pakai: all default|driver|prerelease"; return 1 ;; esac
  case "$1" in driver) [ -n "$(gd_prop ro.gfx.driver.0)" ] || gd_say "PERINGATAN: slot driver 1 (ro.gfx.driver.0) kosong - set dulu: gpudrv pkg 0 <paket-apk-driver>" ;;
    prerelease) [ -n "$(gd_prop ro.gfx.driver.1)" ] || gd_say "PERINGATAN: slot Driver 2 (ro.gfx.driver.1) kosong - set dulu: gpudrv pkg 1 <paket-apk-driver>" ;; esac
  settings put global game_driver_all_apps "$a_v" && gd_say "game_driver_all_apps=$a_v ($1) - berlaku untuk app yang dibuka berikutnya."
}

# slot paket driver (APK updatable): ro.gfx.driver.0 / .1 -> resetprop (in-memory) tiap boot
gd_cmd_pkg() { # <0|1> <paket|none>
  gd_need_root || return 1
  case "$1" in 0|1) ;; *) gd_say "pakai: pkg <0|1> <paket|none>"; return 1 ;; esac
  command -v resetprop >/dev/null 2>&1 || { gd_say "GAGAL: resetprop tidak ada"; return 1; }
  grep -v "^$1|" "$GD_PKGS" 2>/dev/null > "$GD_PKGS.t"; mv -f "$GD_PKGS.t" "$GD_PKGS" 2>/dev/null
  if [ "$2" = none ]; then resetprop --delete "ro.gfx.driver.$1" 2>/dev/null; gd_say "ro.gfx.driver.$1 dihapus."
  else
    gd_pkg_ok "$2" || { gd_say "GAGAL: APK driver '$2' belum terpasang"; return 1; }
    resetprop -n "ro.gfx.driver.$1" "$2" && echo "$1|$2" >> "$GD_PKGS" && gd_say "ro.gfx.driver.$1=$2 (diterapkan ulang tiap boot)"
  fi
}

# dipakai toggle WebUI: all_apps 0=default 1=Game Driver 2=Prerelease ("Driver 2")
gd_cmd_state() {
  s_v=$(gd_get game_driver_all_apps); case "$s_v" in 1|2) ;; *) s_v=0 ;; esac
  echo "gd_all=$s_v"
  echo "gd_pkg0=$(gd_prop ro.gfx.driver.0)"
  echo "gd_pkg1=$(gd_prop ro.gfx.driver.1)"
  echo "gd_overlay=$(grep -c . "$GD_MANIFEST" 2>/dev/null || echo 0)"
}
gd_cmd_status() {
  gd_say "overlay_dipasang=$(grep -c . "$GD_MANIFEST" 2>/dev/null || echo 0)"
  [ -s "$GD_MANIFEST" ] && sed "s|^$MODDIR||" "$GD_MANIFEST" | sed 's/^/  /'
  gd_say "slot_paket: $(tr '\n' ' ' < "$GD_PKGS" 2>/dev/null)"
  gd_say "ro.gfx.driver.0=$(gd_prop ro.gfx.driver.0) ro.gfx.driver.1=$(gd_prop ro.gfx.driver.1)"
  gd_say "game_driver_all_apps=$(gd_get game_driver_all_apps)"
}

gd_cmd_boot() { # dipanggil post-fs-data.sh (sebelum zygote)
  [ -s "$GD_PKGS" ] || return 0
  command -v resetprop >/dev/null 2>&1 || return 0
  while IFS='|' read -r b_s b_p; do [ -n "$b_s" ] && [ -n "$b_p" ] && resetprop -n "ro.gfx.driver.$b_s" "$b_p" 2>/dev/null; done < "$GD_PKGS"
}

c=$1; shift 2>/dev/null
case "$c" in
  info) gd_cmd_info ;;
  validate) gd_validate "$1" "$2" ;;
  install) gd_cmd_install "$@" ;;
  remove) gd_cmd_remove ;;
  app) gd_cmd_app "$@" ;;
  all) gd_cmd_all "$1" ;;
  pkg) gd_cmd_pkg "$1" "$2" ;;
  boot) gd_cmd_boot ;;
  state) gd_cmd_state ;;
  status|"") gd_cmd_status ;;
  *) gd_say "pakai: gpu_driver.sh info|validate|install|remove|app|all|pkg|status|boot" ; return 1 2>/dev/null || exit 1 ;;
esac
