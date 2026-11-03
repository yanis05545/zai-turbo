#!/system/bin/sh
# Zyrox v2 - support.sh : laporan troubleshooting.  su -c "sh /data/adb/modules/azenith-ai/support.sh"
MODDIR=/data/adb/modules/azenith-ai
. "$MODDIR/common.sh"; load_conf
echo "=== Zyrox $TX_VER troubleshooting ==="
echo "Tanggal : $(date)"; echo "Device  : $(getp ro.product.model) / Android $(getp ro.build.version.release)"
echo "Status  : $([ -f "$MODDIR/disable" ] && echo 'DISABLED (self-disable/manual) -> jalankan: azenith-ai enable' || echo aktif)  boot_count=$(cat "$DATADIR/boot_count" 2>/dev/null)"
echo "--- Jika bootloop ---"
echo "1. Tahan Volume UP saat logo boot (8 detik pertama) = safe mode, daemon idle."
echo "2. Boot ke recovery / adb: rm -rf /data/adb/modules/azenith-ai"
echo "3. Sesudah normal: su -c 'azenith-ai doctor' lalu su -c 'azenith-ai selftest'"
echo "--- 50 baris log ---"; tail -n 50 "$LOG" 2>/dev/null
echo "--- riwayat self-disable ---"; cat "$DATADIR/bootloop_history.log" 2>/dev/null || echo "(tidak ada)"
echo "--- scan ---"; cat "$SCANDIR/scan_report.txt" 2>/dev/null | head -n 60
