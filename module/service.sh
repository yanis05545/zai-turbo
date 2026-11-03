#!/system/bin/sh
# Zyrox v2 - service.sh (late_start): hanya meluncurkan supervisor.
MODDIR=${0%/*}
[ -f "$MODDIR/disable" ] && exit 0
# --- Gerbang lisensi: HP tidak terdaftar = semua fitur service tetap mati. ---
. "$MODDIR/lib/license.sh"
if ! lic_check; then
  lic_log "BOOT: service.sh dihentikan - $(lic_status 2>&1)"
  mkdir -p /data/adb/azenith-ai && touch /data/adb/azenith-ai/license.lock
  exit 0
fi
rm -f /data/adb/azenith-ai/license.lock
# -----------------------------------------------------------------------------
# --- Pulihkan pengaturan yang harus tahan flash/update (salinan di /data/adb/azenith-keep) ---
# Core CPU (Set on boot + daftar core offline) dan zRAM. Salinan selalu sinkron dengan conf tiap diubah,
# jadi aman dipakai menimpa nilai conf yang ter-reset oleh update/instal ulang.
KEEP=/data/adb/azenith-keep
if [ -d "$KEEP" ]; then
  [ -f /data/adb/azenith-ai/zram.conf ] || { [ -f "$KEEP/zram.conf" ] && cp -f "$KEEP/zram.conf" /data/adb/azenith-ai/zram.conf; }
  KC=/data/adb/azenith-ai/azenith-ai.conf
  if [ -f "$KEEP/cpucore.conf" ] && [ -f "$KC" ]; then
    while IFS='=' read -r kk kv; do
      case "$kk" in CC_OFF_LIST|CC_BOOT) ;; *) continue ;; esac
      if grep -q "^$kk=" "$KC"; then sed -i "s/^$kk=.*/$kk=$kv/" "$KC"; else echo "$kk=$kv" >> "$KC"; fi
    done < "$KEEP/cpucore.conf"
  fi
fi
# tunggu boot selesai supaya dumpsys/ps stabil
n=0
while [ "$(getprop sys.boot_completed)" != 1 ] && [ "$n" -lt 180 ]; do sleep 2; n=$((n + 2)); done
sleep 5
# Downscale (lib/downscale.sh) safety-net: wm size/density adalah override
# GLOBAL yang Android simpan ke settings - bisa BERTAHAN setelah reboot kalau
# sesi game sebelumnya terputus paksa (reboot manual/crash) sebelum
# stop_game() sempat jalan. TANPA SYARAT conf apapun: reset dulu sebelum
# fitur lain mulai, supaya device tidak pernah nyangkut di resolusi kecil
# permanen gara-gara sesi yang tidak sempat dibersihkan.
wm size reset >/dev/null 2>&1
wm density reset >/dev/null 2>&1
mkdir -p /data/adb/azenith-ai/run
rm -f /data/adb/azenith-ai/run/stop
sh "$MODDIR/lib/supervisor.sh" >/dev/null 2>&1 &
# Disable Thermal: SEKARANG opt-in, mengikuti pilihan user di conf/WebUI.
# v1.0.9-fix: TIDAK lagi memaksa THERMAL_KILL=1 kalau user belum pernah
# mengaktifkannya sendiri - sebelumnya ini aktif otomatis dari boot pertama
# dan membunuh service *thermal* tiap 2 dtk tanpa henti, yang di sebagian
# chipset MTK combo-HAL (satu binary melayani beberapa interface sekaligus)
# ikut menjatuhkan proses non-thermal yang nebeng di binder yang sama ->
# crash & koneksi jaringan putus-nyambung. Hanya jalankan penjaga kalau
# user memang sudah set THERMAL_KILL=1 secara eksplisit DAN belum tk_off.
TK_CONF=/data/adb/azenith-ai/azenith-ai.conf
# v1.0.41: aturan inti - thermalkill hanya hidup bersama mode ZAI-Turbo (extreme).
# Kalau conf masih THERMAL_KILL=1 tapi mode terakhir BUKAN extreme (sisa crash/reboot
# mendadak) dan Fast Charger juga tidak aktif, flag basi itu dibersihkan, penjaga TIDAK jalan.
TK_LASTMODE=$(cat /data/adb/azenith-ai/azenith_thermal_mode 2>/dev/null)
if [ -f "$TK_CONF" ] && grep -q '^THERMAL_KILL=1' "$TK_CONF" \
   && [ "$TK_LASTMODE" != extreme ] && ! grep -q '^FAST_CHARGE=1' "$TK_CONF"; then
  sed -i 's/^THERMAL_KILL=1/THERMAL_KILL=0/' "$TK_CONF" 2>/dev/null
fi
if [ ! -f /data/adb/azenith-ai/tk_off ] && [ -f "$TK_CONF" ] \
   && grep -q '^THERMAL_KILL=1' "$TK_CONF"; then
  sed -i 's/^BYPASS_THERMAL=1/BYPASS_THERMAL=0/' "$TK_CONF" 2>/dev/null
  nohup sh "$MODDIR/lib/tkloop.sh" >/dev/null 2>&1 &
fi
# Thermal Lock Daily tahan reboot: kalau THERMAL_DAILY=1 di conf, terapkan ulang
# (fitur A non-stop, daily + gaming - node emul/freeze non-persisten, hilang tiap
# reboot) lalu jalankan watchdog-nya lagi.
if grep -q '^THERMAL_DAILY=1' /data/adb/azenith-ai/azenith-ai.conf 2>/dev/null; then
  ( . "$MODDIR/common.sh"; load_conf; scan_if_needed >/dev/null 2>&1; [ "$THERMAL_MODE" != off ] && td_apply >/dev/null 2>&1 || flog THERMAL_DAILY ERR "boot: terapkan ulang gagal" ) >/dev/null 2>&1 &
  nohup sh "$MODDIR/lib/tdloop.sh" >/dev/null 2>&1 &
fi
# Bypass Charging tahan reboot: kalau CHARGE_BYPASS=1 di conf, jalankan watchdog-nya lagi
# (node charger non-persisten, hilang tiap reboot - harus ditulis ulang + diverifikasi lagi)
if grep -q '^CHARGE_BYPASS=1' /data/adb/azenith-ai/azenith-ai.conf 2>/dev/null; then
  nohup sh "$MODDIR/lib/chargeloop.sh" >/dev/null 2>&1 &
fi
# Fast Charger (v1.0.15) = Disable Thermal saja: tahan reboot lewat THERMAL_KILL=1 di atas
# (tkloop.sh), tidak ada watchdog arus lagi. Kunci mode balance/saver tidak ikut reboot -
# pasang lagi kalau FAST_CHARGE masih 1.
if grep -q '^FAST_CHARGE=1' /data/adb/azenith-ai/azenith-ai.conf 2>/dev/null; then
  : > /data/adb/azenith-ai/run/fc_mode_lock 2>/dev/null
  # kunci suhu zona thermal (chmod) hilang tiap reboot -> pasang lagi setelah boot selesai
  ( . "$MODDIR/common.sh"; load_conf
    fb_n=0; while [ "$(getprop sys.boot_completed)" != 1 ] && [ "$fb_n" -lt 180 ]; do sleep 2; fb_n=$((fb_n + 2)); done
    sleep 15
    [ "$FAST_CHARGE" = 1 ] && { : > "$FC_TEMP_BK"; fc_temp_lock >/dev/null 2>&1; vx_on >/dev/null 2>&1; }
  ) >/dev/null 2>&1 &
fi
# Network Booster DIHAPUS dari UI (v1.0.43). Kalau masih aktif dari versi lama, pulihkan sekali
# (sysctl/setting dikembalikan ke nilai asal) lalu NETBOOST=0 - tidak diterapkan ulang lagi.
NB_CONF=/data/adb/azenith-ai/azenith-ai.conf
if grep -q '^NETBOOST=1' "$NB_CONF" 2>/dev/null; then
  ( . "$MODDIR/common.sh"; load_conf
    [ "$NETBOOST" = 1 ] && flog_run NETBOOST "boot: Network Booster dihapus, pulihkan nilai asli" nb_off >/dev/null 2>&1
  ) >/dev/null 2>&1 &
fi
# WiFi Low Latency tahan reboot: force-low-latency-mode & settings Wi-Fi hilang tiap
# reboot - terapkan ulang setelah boot selesai (service Wi-Fi harus sudah hidup).
if grep -q '^WIFILL=1' /data/adb/azenith-ai/azenith-ai.conf 2>/dev/null; then
  ( . "$MODDIR/common.sh"; load_conf
    wl_n=0; while [ "$(getprop sys.boot_completed)" != 1 ] && [ "$wl_n" -lt 180 ]; do sleep 2; wl_n=$((wl_n + 2)); done
    sleep 8
    [ "$WIFILL" = 1 ] && flog_run WIFILL "boot: terapkan ulang" wl_on >/dev/null 2>&1
  ) >/dev/null 2>&1 &
fi
# WiFi Tweak tahan reboot: pengaturan `cmd wifi` hilang/direset tiap reboot - terapkan ulang
# setelah service Wi-Fi hidup (sama pola dengan WiFi Low Latency).
if grep -q '^WIFITWEAK=1' /data/adb/azenith-ai/azenith-ai.conf 2>/dev/null; then
  ( . "$MODDIR/common.sh"; load_conf
    wt_n=0; while [ "$(getprop sys.boot_completed)" != 1 ] && [ "$wt_n" -lt 180 ]; do sleep 2; wt_n=$((wt_n + 2)); done
    sleep 12
    [ "$WIFITWEAK" = 1 ] && flog_run WIFITWEAK "boot: terapkan ulang" wt_on >/dev/null 2>&1
  ) >/dev/null 2>&1 &
fi
# Network Pro (lib/netpro.sh) tahan reboot - setara `PingPimp --boot`: qdisc, DNS, IPv6, iptables, IRQ, dll
# diterapkan ulang setelah boot selesai + jaringan siap, lalu watcher (Smart Auto/DNS per jaringan) dihidupkan.
if grep -Eq '^NP_[A-Z0-9_]+=1' /data/adb/azenith-ai/azenith-ai.conf 2>/dev/null; then
  ( . "$MODDIR/common.sh"; load_conf
    np_n=0; while [ "$(getprop sys.boot_completed)" != 1 ] && [ "$np_n" -lt 180 ]; do sleep 2; np_n=$((np_n + 2)); done
    sleep 18
    flog_run NETPRO "boot: terapkan ulang" np_boot >/dev/null 2>&1
  ) >/dev/null 2>&1 &
fi
# Refresh Rate (Hz) tahan reboot: peak_refresh_rate/min_refresh_rate (Settings.System) dipasang ulang
# setelah boot selesai, DUA kali (ROM kadang mereset nilai ini saat boot/unlock pertama).
if grep -q '^HZ=1' /data/adb/azenith-ai/azenith-ai.conf 2>/dev/null; then
  ( . "$MODDIR/common.sh"; load_conf
    hz_n=0; while [ "$(getprop sys.boot_completed)" != 1 ] && [ "$hz_n" -lt 180 ]; do sleep 2; hz_n=$((hz_n + 2)); done
    sleep 10
    [ "$HZ" = 1 ] && flog_run HZ "boot: terapkan ulang" hz_boot_apply >/dev/null 2>&1
    sleep 30
    [ "$HZ" = 1 ] && hz_boot_apply >/dev/null 2>&1
  ) >/dev/null 2>&1 &
fi
# Frame Rate (FPS) PER GAME (lib/gamefps.sh), v1.0.30:
#  - override sesi game yang tertinggal (reboot/crash saat game) dilepas dulu: batas FPS GameManager & kunci Hz sementara.
#  - Frame Rate GLOBAL lama dipensiunkan: kalau conf lama masih FRAMERATE=1, nilai asli Settings/prop dipulihkan SEKALI
#    (frm_off) supaya tidak ada kunci Hz yang tertinggal tanpa tombol untuk mematikannya.
( . "$MODDIR/common.sh"; load_conf
  fm_n=0; while [ "$(getprop sys.boot_completed)" != 1 ] && [ "$fm_n" -lt 180 ]; do sleep 2; fm_n=$((fm_n + 2)); done
  sleep 8
  gamefps_revert >/dev/null 2>&1
  if [ "$FRAMERATE" = 1 ]; then
    flog_run FRAMERATE "boot: Frame Rate global dipensiunkan, pulihkan nilai lama" frm_off >/dev/null 2>&1
  fi
) >/dev/null 2>&1 &
# Kunci mode Perf Lite basi (PERFLITE bukan 1 di conf) dibuang saat boot supaya saver/ZAI-Turbo tidak ditolak.
grep -q '^PERFLITE=1' /data/adb/azenith-ai/azenith-ai.conf 2>/dev/null || rm -f /data/adb/azenith-ai/run/pl_mode_lock 2>/dev/null
# Perf Lite tahan reboot: tweak sysctl/sysfs/prop non-persisten hilang tiap reboot - terapkan
# ulang setelah boot selesai (+ FSTrim sekali). pl_boot_apply juga memastikan Fast Charger mati
# dan mode saver/extreme tidak ikut dipulihkan bersama Perf Lite (aturan bentrok).
if grep -q '^PERFLITE=1' /data/adb/azenith-ai/azenith-ai.conf 2>/dev/null; then
  ( . "$MODDIR/common.sh"; load_conf
    pl_n=0; while [ "$(getprop sys.boot_completed)" != 1 ] && [ "$pl_n" -lt 180 ]; do sleep 2; pl_n=$((pl_n + 2)); done
    sleep 25
    [ "$PERFLITE" = 1 ] && flog_run PERFLITE "boot: terapkan ulang" pl_boot_apply >/dev/null 2>&1
  ) >/dev/null 2>&1 &
fi
# Core CPU offline (lib/cpucore.sh): node cpuN/online hilang tiap reboot. "Set on boot" (CC_BOOT=1) ->
# matikan lagi core pilihan user setelah boot selesai; kalau OFF, daftar dikosongkan supaya daemon
# tidak mematikan core tanpa diminta.
if grep -q '^CC_OFF_LIST=[0-9]' /data/adb/azenith-ai/azenith-ai.conf 2>/dev/null; then
  if grep -q '^CC_BOOT=1' /data/adb/azenith-ai/azenith-ai.conf 2>/dev/null; then
    ( . "$MODDIR/common.sh"; load_conf
      cb_n=0; while [ "$(getprop sys.boot_completed)" != 1 ] && [ "$cb_n" -lt 180 ]; do sleep 2; cb_n=$((cb_n + 2)); done
      sleep 20
      cc_boot_apply >/dev/null 2>&1
      sleep 30
      cc_boot_apply >/dev/null 2>&1
    ) >/dev/null 2>&1 &
  else
    sed -i 's/^CC_OFF_LIST=.*/CC_OFF_LIST=/' /data/adb/azenith-ai/azenith-ai.conf 2>/dev/null
  fi
fi
# Graphics API Universal tahan reboot: kalau GFX_UNIVERSAL=1 di conf,
# terapkan ulang (debug.hwui.renderer & Settings.Global angle_gl_driver_all_angle
# non-persisten, hilang tiap reboot) - berlaku SELURUH SISTEM, bukan per-game.
GU_CONF=/data/adb/azenith-ai/azenith-ai.conf
if grep -q '^GFX_UNIVERSAL=1' "$GU_CONF" 2>/dev/null; then
  ( . "$MODDIR/common.sh"; load_conf
    [ "$GFX_UNIVERSAL" = 1 ] && flog_run GFXAPI "boot: terapkan ulang" gu_on "$GFX_UNIVERSAL_API" >/dev/null 2>&1
  ) >/dev/null 2>&1 &
fi
# zRAM tahan reboot & flash update (DEFAULT AKTIF): pengaturan terakhir di zram.conf diterapkan ulang
# setelah boot selesai (menunggu init selesai mengatur swap bawaan dulu). Hanya ZRAM_BOOT=0 yang menonaktifkan.
if [ -f /data/adb/azenith-ai/zram.conf ] && ! grep -q '^ZRAM_BOOT=0' /data/adb/azenith-ai/zram.conf 2>/dev/null; then
  ( . "$MODDIR/common.sh"; load_conf
    zb_n=0; while [ "$(getprop sys.boot_completed)" != 1 ] && [ "$zb_n" -lt 180 ]; do sleep 2; zb_n=$((zb_n + 2)); done
    sleep 20
    flog_run ZRAM "boot: terapkan ulang" zr_boot_apply >/dev/null 2>&1
  ) >/dev/null 2>&1 &
fi
# Spoof prosesor: pasang ulang prop + mount cpuinfo (termasuk ke namespace zygote) setelah boot selesai,
# supaya DevCheck/app info yang start belakangan tetap melihat nama palsu.
if grep -q '^SPOOF_CPU=1' /data/adb/azenith-ai/azenith-ai.conf 2>/dev/null && [ -f "$MODDIR/cpu_spoof.sh" ]; then
  ( sleep 5; MODDIR="$MODDIR" sh "$MODDIR/cpu_spoof.sh" remount >/dev/null 2>&1 ) &
fi
# azenith-thermal: properti sys.azenith.thermal.state non-persisten (hilang
# tiap reboot) - pulihkan mode terakhir (balance/saver/gaming/extreme) kalau
# user pernah memilih salah satunya.
[ -f /data/adb/azenith-ai/azenith_thermal_mode ] && PATH="$MODDIR/system/bin:$PATH" nohup sh "$MODDIR/system/bin/azenith-thermal" restore >/dev/null 2>&1 &
exit 0
