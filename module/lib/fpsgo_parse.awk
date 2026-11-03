# Zyrox v2.1 - lib/fpsgo_parse.awk
# Membaca FPS dari file status FPSGO/FSTB/perfmgr dengan format YANG TIDAK DIKETAHUI
# di awal: kolom/kunci dideteksi dari isi file itu sendiri, lalu baris difilter ke
# pid/tid GAME (bukan nilai maksimum semua proses).
#   -v ids=" pid tid tid ... "   kosong = tanpa filter
#   -v mode=val                  cetak FPS x10 (integer) atau kosong
#   -v mode=diag                 cetak diagnosis format (untuk log/CLI)
# Dua bentuk yang dikenali:
#   1) tabel : baris header berisi nama kolom ber-"fps" (currentFPS, cur_fps, fps, ...)
#   2) kv    : "tid=123 ... fps=57" / "tid: 123 cur_fps: 57"
function isnum(s) { return (s ~ /^[0-9]+(\.[0-9]+)?$/) }
function inids(s) { return (ids != "" && index(ids, " " s " ") > 0) }
function clean(t) { t = tolower(t); gsub(/[^a-z0-9_]/, "", t); return t }
function fpsname(t) {
  if (t ~ /(target|tgt|max|min|limit|range|fix|lower|upper|margin|cap|diff|ratio|pct|count|num)/) return 0
  return (t ~ /^(cur|current|curr|real|queue|queued|avg|measured)?_?fps$/)
}
{
  nn = 0
  for (i = 1; i <= NF; i++) if (isnum($i)) nn++
  low = tolower($0)
  if (nn == 0 && NF >= 2 && low ~ /fps/ && low !~ /[=:][ \t]*[0-9]/) {   # header tabel (bukan baris kv)
    hdr = 1; fc = 0; tc = 0; pc = 0
    for (i = 1; i <= NF; i++) {
      t = clean($i)
      if (!fc && fpsname(t)) fc = i
      if (t == "tid" || t ~ /^render_?tid$/ || t ~ /_tid$/) { if (!tc) tc = i }
      else if (t == "pid" || t ~ /^render_?pid$/ || t ~ /^process_?id$/ || t ~ /_pid$/) { if (!pc) pc = i }
    }
    next
  }
  if (hdr && fc > 0) {                                  # baris data tabel
    if (nn == 0) next
    rows++
    ok = 1
    if (ids != "" && (tc || pc)) { ok = 0; if (tc && inids($tc)) ok = 1; if (pc && inids($pc)) ok = 1 }
    if (ok && isnum($fc)) {
      v = $fc + 0
      if (v >= 1 && v <= 250) { match_n++; if (v > best) { best = v; fmt = "table" } }
    }
    next
  }
  if (low !~ /fps/) next                                # mode kv
  line = $0; gsub(/[ \t]*[=:][ \t]*/, "=", line)
  n = split(line, a, /[ \t,;|]+/)
  for (x in k) delete k[x]
  for (j = 1; j <= n; j++) {
    if (a[j] ~ /^[A-Za-z_][A-Za-z0-9_]*=[0-9.]+$/) {
      p = index(a[j], "="); k[clean(substr(a[j], 1, p - 1))] = substr(a[j], p + 1)
    }
  }
  idk = 0; idok = 0
  split("tid pid render_tid render_pid rendertid renderpid process_id", idn, " ")
  for (j = 1; j <= 7; j++) if (idn[j] in k) { idk = 1; if (inids(k[idn[j]])) idok = 1 }
  if (ids != "" && idk && !idok) { kvrows++; next }
  for (x in k) if (fpsname(x) && isnum(k[x])) {
    v = k[x] + 0
    if (v >= 1 && v <= 250) { match_n++; if (v > best) { best = v; fmt = "kv" } }
  }
  kvrows++
}
END {
  if (mode == "diag")
    printf "fmt=%s rows=%d kvrows=%d match=%d col_fps=%d col_tid=%d col_pid=%d best=%s",
      (fmt == "" ? (hdr ? "table" : "?") : fmt), rows, kvrows, match_n, fc, tc, pc, (best > 0 ? best : "-")
  else if (best > 0) printf "%d", best * 10 + 0.5
}
