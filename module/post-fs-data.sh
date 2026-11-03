#!/system/bin/sh
# =====================================================================
#  Zyrox v2 - post-fs-data.sh   (paling awal; TIDAK ada tweak berat)
#   1. Boot counter: +1 tiap boot. Direset ke 0 oleh daemon setelah boot terbukti
#      sehat (boot_completed + BOOT_OK_DELAY detik). >= BOOT_FAIL_LIMIT berarti
#      beberapa boot berturut-turut tidak sempat sehat -> module self-disable.
#      (v1 memakai marker yang hilang kalau user reboot < 2 menit -> disable palsu)
#   2. Bersihkan state kadaluarsa (backup lama berbahaya setelah reboot).
#   3. Prop SurfaceFlinger (harus sebelum SF start).
#   4. Jalankan safe_trigger.sh (baca tombol volume) di background.
# =====================================================================
MODDIR=${0%/*}
export MODDIR
DATADIR=${TX_DATA:-/data/adb/azenith-ai}
mkdir -p "$DATADIR/backup" "$DATADIR/run" "$DATADIR/scan" "$DATADIR/test_logs"

# state run-time dari boot sebelumnya sudah tidak valid
rm -rf "$DATADIR/run" "$DATADIR/backup"
mkdir -p "$DATADIR/run" "$DATADIR/backup"
: > "$DATADIR/applied_stack"; : > "$DATADIR/props_stack"; : > "$DATADIR/svc_stack"

# --- Gerbang lisensi: WAJIB lolos sebelum fitur apapun diterapkan. ---
. "$MODDIR/lib/license.sh"
if ! lic_check; then
  lic_log "BOOT: post-fs-data dihentikan - $(lic_status 2>&1)"
  touch "$DATADIR/license.lock"
  exit 0
fi
rm -f "$DATADIR/license.lock"
# ----------------------------------------------------------------------

. "$MODDIR/common.sh"
load_conf
log_rotate

n=$(cat "$DATADIR/boot_count" 2>/dev/null); n=${n:-0}
case "$n" in *[!0-9]*) n=0 ;; esac
n=$((n + 1)); echo "$n" > "$DATADIR/boot_count"
log_msg "BOOT: post-fs-data, boot_count=$n (batas $BOOT_FAIL_LIMIT)"

if [ "$n" -ge "$BOOT_FAIL_LIMIT" ]; then
  touch "$MODDIR/disable"
  echo "$(date '+%Y-%m-%d %H:%M:%S') SELF-DISABLED: $n boot berturut-turut tanpa boot sehat" >> "$DATADIR/bootloop_history.log"
  log_msg "BOOT: SELF-DISABLE (boot_count=$n). Jalankan 'azenith-ai enable' setelah boot normal."
  flog DAEMON ERR "SELF-DISABLE: boot gagal berulang (boot_count=$n). Jalankan 'azenith-ai enable' setelah boot normal."
  echo 0 > "$DATADIR/boot_count"
  exit 0
fi

sf_boot_props
# Refresh Rate (Hz): prop SurfaceFlinger content-detection=false (ro.*, harus sebelum SF start; hanya kalau HZ=1)
hz_boot_props
# Frame Rate (FPS): prop SurfaceFlinger/EGL (debug.sf.*, ro.surface_flinger.*) harus sebelum SF start; hanya kalau FRAMERATE=1
frm_boot_props
# Spoof nama perangkat (resetprop in-memory; HARUS sebelum zygote). $n = boot_count setelah +1; >=2 -> failsafe matikan.
[ -f "$MODDIR/dev_spoof.sh" ] && MODDIR="$MODDIR" sh "$MODDIR/dev_spoof.sh" boot "$n" >/dev/null 2>&1
# Spoof prosesor (resetprop in-memory, menggantikan Spoof GPU). HARUS sebelum zygote; boot_count >= 2 -> failsafe matikan.
[ -f "$MODDIR/cpu_spoof.sh" ] && MODDIR="$MODDIR" sh "$MODDIR/cpu_spoof.sh" boot "$n" >/dev/null 2>&1
# Driver GPU (slot ro.gfx.driver.0/1) - resetprop in-memory sebelum zygote
[ -f "$MODDIR/gpu_driver.sh" ] && MODDIR="$MODDIR" sh "$MODDIR/gpu_driver.sh" boot >/dev/null 2>&1
sh "$MODDIR/safe_trigger.sh" >> "$LOG" 2>&1 &
exit 0
