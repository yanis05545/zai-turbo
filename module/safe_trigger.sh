#!/system/bin/sh
# =====================================================================
#  Zyrox v2 - safe_trigger.sh   (SAFE BOOT VIA TOMBOL VOLUME)
#  v1 membaca SEMUA input device dengan 'getevent -c 2' (2 event pertama dari
#  perangkat apa pun, mudah terambil event lain). v2:
#   1. Cari input device yang MEMANG punya KEY_VOLUMEUP/KEY_VOLUMEDOWN lewat
#      'getevent -pl' (nomor eventN berbeda tiap device; tidak ada hardcode).
#   2. Baca hanya device itu selama SAFE_WINDOW_SEC detik (default 8).
#   3. Fallback: kalau tidak ada yang cocok, baca semua device.
#  Hasil -> $DATADIR/safe_mode : skip (Vol UP) | cool (Vol DOWN) | kosong
#  Catatan: Vol DOWN saat boot juga memicu Magisk Safe Mode di sebagian device.
# =====================================================================
MODDIR=${MODDIR:-${0%/*}}
export MODDIR
. "$MODDIR/common.sh"
load_conf

: > "$DATADIR/safe_mode"
rm -f "$RUNDIR/safe_done"
mkdir -p "$RUNDIR"

devs=$(getevent -pl 2>/dev/null | awk '
  /^add device/ { if (dev != "" && keys) print dev; dev=$NF; keys=0; next }
  /KEY_VOLUME(UP|DOWN)/ { keys=1 }
  END { if (dev != "" && keys) print dev }')
log_msg "P.3: device tombol volume: ${devs:-<tidak ditemukan, fallback semua device>}"

result=""
if command -v getevent >/dev/null 2>&1; then
  tmo "$SAFE_WINDOW_SEC" getevent -lq $devs 2>/dev/null | while read -r line; do
    case "$line" in
      *KEY_VOLUMEUP*DOWN*|*KEY_VOLUMEUP*REPEAT*)     echo skip > "$DATADIR/safe_mode"; break ;;
      *KEY_VOLUMEDOWN*DOWN*|*KEY_VOLUMEDOWN*REPEAT*) echo cool > "$DATADIR/safe_mode"; break ;;
    esac
  done
fi
result=$(cat "$DATADIR/safe_mode" 2>/dev/null)

vib() { for v in /sys/class/timed_output/vibrator/enable /sys/class/leds/vibrator/activate; do
          [ -w "$v" ] && { echo "$1" > "$v"; return; }; done; }
case "$result" in
  skip) log_msg "P.3: Volume UP -> SAFE MODE: daemon idle total"; vib 150; sleep 1; vib 150 ;;
  cool) log_msg "P.3: Volume DOWN -> preset cool, thermal off"; vib 150 ;;
  *)    log_msg "P.3: tidak ada tombol volume ditekan, mode normal" ;;
esac
touch "$RUNDIR/safe_done"
exit 0
