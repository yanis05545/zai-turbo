#!/system/bin/sh
# Zyrox v2 - customize.sh (di-source oleh installer Magisk / KernelSU / APatch)
SKIPUNZIP=0
TXVER=$(sed -n 's/^version=//p' "$MODPATH/module.prop" 2>/dev/null)
ui_print "*********************************************"
ui_print "  Zyrox Gaming Booster ${TXVER:-v2.6.1}"
ui_print "  scan dinamis + FPS sustain (FPSGO) + App"
ui_print "*********************************************"

[ -n "$API" ] && [ "$API" -lt 28 ] && abort "! Butuh Android 9 (API 28) atau lebih baru."

if   [ -n "$KSU" ];    then ui_print "- Root manager: KernelSU"
elif [ -n "$APATCH" ]; then ui_print "- Root manager: APatch"
else                        ui_print "- Root manager: Magisk ${MAGISK_VER:-}"; fi

ui_print "- Mengatur permission"
set_perm_recursive "$MODPATH" 0 0 0755 0644
for f in post-fs-data.sh service.sh uninstall.sh safe_trigger.sh support.sh common.sh action.sh cpu_spoof.sh dev_spoof.sh gpu_driver.sh \
         lib/core.sh lib/profile.sh lib/scan.sh lib/thermal.sh lib/perf.sh lib/fps.sh lib/fpsgo.sh lib/misc.sh lib/daemon.sh \
         lib/supervisor.sh lib/daemon_run.sh lib/kernel_match.sh lib/kernel_scan.sh lib/devinfo.sh lib/thermalkill.sh lib/tkloop.sh lib/bypass.sh lib/overclock.sh system/bin/azenith-ai system/bin/azenith-thermal; do
  [ -f "$MODPATH/$f" ] && set_perm "$MODPATH/$f" 0 0 0755
done

DATA=/data/adb/azenith-ai
mkdir -p "$DATA"
# konfigurasi v1 (kunci berbeda) disimpan sebagai cadangan, config baru dibuat saat boot
if [ -f "$DATA/azenith-ai.conf" ] && ! grep -q '^CONF_VERSION=2' "$DATA/azenith-ai.conf"; then
  mv -f "$DATA/azenith-ai.conf" "$DATA/azenith-ai.conf.v1.bak"
  ui_print "- Config lama dicadangkan: azenith-ai.conf.v1.bak (format berubah di v2)"
fi
rm -f "$DATA/boot_count" "$DATA/safe_mode"
# v1.0.9: penanda tk_off (sisa "safe on"/toggle lama) membuat Disable Thermal TIDAK dijalankan saat boot
# walau toggle tampil ON -> dihapus saat pasang supaya default permanen ON benar-benar berlaku.
rm -f "$DATA/tk_off"
rm -f "$DATA/scan/profile.conf"   # paksa scan ulang

# v1.0.9-fix: Disable Thermal TIDAK lagi dipaksa permanen - paksa-ON tiap
# boot/instal inilah yang kill -9 service *thermal* tiap 2 dtk tanpa henti
# dan di sebagian chipset MTK combo-HAL ikut menjatuhkan proses non-thermal
# yang nebeng binary sama (crash + jaringan blokir). Sekarang murni opt-in:
# conf lama yang sudah THERMAL_KILL=1 dibiarkan apa adanya (pilihan user),
# yang belum ada/masih 0 TIDAK diubah jadi 1 di sini lagi.
if [ -f "$DATA/azenith-ai.conf" ]; then
  # v1.0.3: nilai aman (penyebab app crash/freeze): matikan prop SF, BLOCK bind-mount, kill proses, kill-bg
  for kv in SF_BOOT_PROPS=0 TK_BLOCK=0 TK_KERNEL=0 TK_KILL_PROCS=0 RAM_KILL_BG=0; do
    k=${kv%%=*}
    if grep -q "^$k=" "$DATA/azenith-ai.conf"; then sed -i "s/^$k=.*/$kv/" "$DATA/azenith-ai.conf"; else echo "$kv" >> "$DATA/azenith-ai.conf"; fi
  done
  ui_print "- v1.0.3: fitur penyebab crash/freeze dimatikan secara default"
  ui_print "- v1.0.9-fix: Disable Thermal sekarang opt-in (azenith-ai thermalkill on), tidak dipaksa tiap boot"
fi

# --- zRAM tahan flash update + reboot -------------------------------------------------------
# zram.conf (algoritma/ukuran/swappiness terakhir yang dipakai) ada di $DATA dan TIDAK dihapus saat update.
# Kalau belum ada pengaturan tersimpan tapi zRAM sedang aktif, simpan kondisi yang SEDANG dipakai sekarang
# supaya setelah reboot tetap sama. Pemulihan tiap boot dijaga service.sh (default AKTIF).
ZC="$DATA/zram.conf"
[ -f "$ZC" ] || : > "$ZC"
zc_set() { grep -v "^$1=" "$ZC" > "$ZC.t" 2>/dev/null; echo "$1=$2" >> "$ZC.t"; mv -f "$ZC.t" "$ZC"; }
zc_has_mb=$(sed -n 's/^ZRAM_MB=//p' "$ZC" | tail -n 1)
case "$zc_has_mb" in
  ''|*[!0-9]*)
    if [ -e /sys/block/zram0/disksize ] && grep -q zram0 /proc/swaps 2>/dev/null; then
      zc_mb=$(awk '{printf "%d", $1 / 1048576}' /sys/block/zram0/disksize 2>/dev/null)
      zc_algo=$(sed -n 's/.*\[\([^]]*\)\].*/\1/p' /sys/block/zram0/comp_algorithm 2>/dev/null | head -n 1)
      zc_sw=$(cat /proc/sys/vm/swappiness 2>/dev/null)
      if [ "${zc_mb:-0}" -ge 128 ] 2>/dev/null; then
        zc_set ZRAM_MB "$zc_mb"
        [ -n "$zc_algo" ] && zc_set ZRAM_ALGO "$zc_algo"
        [ -n "$zc_sw" ] && zc_set ZRAM_SWAPPINESS "$zc_sw"
        ui_print "- zRAM aktif sekarang disimpan: ${zc_algo:-?} ${zc_mb}MB (dipulihkan tiap reboot)"
      fi
    fi ;;
  *) ui_print "- zRAM: pengaturan sebelumnya dipertahankan (${zc_has_mb}MB), tidak direset" ;;
esac
zc_set ZRAM_BOOT 1
ui_print "- zRAM tahan reboot/flash update: AKTIF"

ui_print "- UI: aplikasi Zyrox (APK). Modul ini tidak lagi menyediakan WebUI Manager."
ui_print "  (aplikasi butuh izin root dari Manager saat pertama dibuka)"
ui_print "- Spoof prosesor (v1.0.36, ganti Spoof GPU): WebUI tab Spoofing atau  su -c azenith-ai cpuspoof profiles"
ui_print "  (resetprop in-memory tiap boot; tidak ada driver/partisi yang diubah)"
# Spoof GPU DIHAPUS: bersihkan sisa overlay driver + backup + state lama (overlay di folder modul lama ikut tergantikan saat update)
rm -rf "$DATA/gpu_backup" "$DATA/gpu_spoof.state" "$DATA/gpu_spoof.stale" "$DATA/gpu_props.bk" "$MODPATH/system/vendor" 2>/dev/null
[ -f "$DATA/azenith-ai.conf" ] && sed -i '/^SPOOF_GPU=/d;/^SPOOF_GPU_MODEL=/d' "$DATA/azenith-ai.conf" 2>/dev/null
ui_print "- Spoof nama perangkat (v1.0.21): WebUI tab Spoofing atau  su -c azenith-ai devspoof profiles"
ui_print "  (resetprop in-memory tiap boot; build.prop asli tidak disentuh)"
# Spoof per-aplikasi (Zygisk) DIHAPUS di v1.0.23: sisa .so lama tidak dipakai lagi.
rm -rf "$MODPATH/zygisk" 2>/dev/null
ui_print "- Selesai. Reboot, lalu cek:  su -c azenith-ai status"
ui_print "  Tahan Volume UP saat boot = safe mode (skip)."
