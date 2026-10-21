#!/bin/sh
# End-to-end test of the vendor-filter stage: no printer, no USB, no CUPS queue.
#
# Runs konica206-native with a konicafile:// device and checks that
#   - the filter is invoked as a child process with the CUPS filter calling
#     convention (argv: job user title copies options [file]),
#   - the filter's stdout becomes the printer stream, and
#   - that stream is replayed once per copy (collated copies).
#
# Two modes:
#   default          stand-in filter (test/standin-filter.sh): the plumbing only,
#                    no vendor runtime data needed, always runnable.
#   NATIVE=<path>    the real konica-native: the same checks on the real stream.
#                    SKIPs (exit 0) when its runtime data is missing.
#
#   make check-native
#   NATIVE=/usr/local/lib/konica/konica-native ./test/test_native_filter.sh
#
# Never touches USB or a real CUPS queue.
set -u

HERE=$(cd "$(dirname "$0")/.." && pwd)
APP=${APP:-$HERE/konica206-native}
PORT=${PORT:-8697}
DATA=${KONICA_DATA:-/usr/local/lib/konica/KonicaMinolta/245igdi}
NATIVE=${NATIVE:-}
COPIES=${COPIES:-2}
SIDES=${SIDES:-two-sided-long-edge}
DUPLEX=${DUPLEX:-DuplexNoTumble}

skip() { echo "SKIP test_native_filter: $1"; exit 0; }
fail() { echo "FAIL test_native_filter: $1"; exit 1; }

# As root PAPPL keeps its state in /var/lib/konica206-native.state, the same file a
# real service uses; a test instance would overwrite it.  As a normal user the
# state goes under $HOME, which this script points at a temp directory.
[ "$(id -u)" -ne 0 ] || skip "run as a normal user (root would overwrite the real service's state file)"
[ -x "$APP" ] || skip "$APP not built"

if [ -n "$NATIVE" ]; then
  [ -x "$NATIVE" ] || skip "$NATIVE not found"
  # konica-native loads the halftone screen and builds its colour table from the
  # ICC profiles before it writes anything; without them it exits 1 and produces
  # no stream at all.
  for f in Halftones/COPA.DEFAULT.600x600.hft Profiles/sRGB.icm Profiles/sGrayInv.icm; do
    [ -r "$DATA/$f" ] || skip "vendor runtime data missing under $DATA ($f)"
  done
  FILTER_REAL=$NATIVE
  MODE=konica-native
else
  FILTER_REAL=$HERE/test/standin-filter.sh
  MODE=stand-in
fi

T=$(mktemp -d)
trap 'kill $SRV 2>/dev/null; rm -rf "$T"' EXIT
export HOME=$T XDG_RUNTIME_DIR=$T
mkdir "$T/out" "$T/spool"

# The filter wrapper records the child's argv and environment, then execs the real
# filter.  The host replaces the child's environment, so a wrapper is also the
# only way to hand extra variables to a filter that needs them.
cp "$HERE/test/filter-wrapper.sh" "$T/filter-wrapper.sh"
chmod +x "$T/filter-wrapper.sh"
{
  echo "FILTER_REAL=$FILTER_REAL"
  echo "FILTER_RECORD=$T/filter-argv.txt"
} > "$T/filter-wrapper.conf"

# A PNG job takes the raster path (PAPPL -> CUPS raster -> filter).
if python3 -c 'import PIL' 2>/dev/null; then
  python3 - "$T/p.png" <<'PY'
import sys
from PIL import Image
Image.new('L', (2480, 3508), 200).save(sys.argv[1])
PY
else
  # Minimal valid 1x1 PNG, for hosts without Pillow.
  printf '%s' 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==' |
    base64 -d > "$T/p.png" 2>/dev/null || skip "no PNG encoder (python3 Pillow or base64)"
fi

export KONICA_VENDOR_FILTER="$T/filter-wrapper.sh"
export KONICA_PPD="$HERE/test/ppd-fixture.ppd"
export KONICA_SPOOLDIR="$T/spool"
export KONICA_STUCK_SECS=0
# The PDF job below needs the builtin renderer (gs); the PNG job uses the raster path.
export KONICA_PDF_RENDERER=builtin

U=ipp://localhost:$PORT
"$APP" server -o server-port=$PORT -o log-file="$T/s.log" -o spool-directory="$T/spool" >"$T/srv.out" 2>&1 &
SRV=$!

i=0
while [ $i -lt 15 ]; do
  "$APP" status -u $U >/dev/null 2>&1 && break
  i=$((i + 1)); sleep 1
done

"$APP" add -d t -u $U -m konica-bizhub-206 -v "konicafile://$T/out" >/dev/null 2>&1 || fail "add printer"
"$APP" submit -u "$U/ipp/print/t" -o copies=$COPIES -o sides=$SIDES "$T/p.png" >/dev/null 2>&1 || fail "submit"

# The device creates the output file when the job starts, so wait for the job to
# finish instead.
i=0
while [ $i -lt 120 ] && ! grep -aq '\] Completed\|Aborted\|Canceled' "$T/s.log" 2>/dev/null; do
  i=$((i + 1)); sleep 1
done

f=$(ls "$T"/out/job-*.bin 2>/dev/null | head -1)
[ -n "$f" ] && [ -s "$f" ] || { echo "FAIL test_native_filter: no output (see log)"; tail -25 "$T/s.log"; exit 1; }

# One UEL/EOJ pair per copy: the job header and the trailer each appear twice.
uel=$(grep -ac "@PJL SET COMPRESS=JBIG" "$f")
eoj=$(grep -ac "@PJL EOJ" "$f")
[ "$uel" -eq "$COPIES" ] && [ "$eoj" -eq "$COPIES" ] ||
  { echo "FAIL test_native_filter: expected $COPIES streams, saw JBIG=$uel EOJ=$eoj"; exit 1; }

# The filter child's calling convention, as recorded by the wrapper.
rec=$T/filter-argv.txt
[ -s "$rec" ] || { echo "FAIL test_native_filter: the filter was never invoked"; exit 1; }
argc=$(sed -n 's/^argc=//p' "$rec")
[ "$argc" = "5" ] || fail "the filter got $argc arguments, expected 5 (job user title copies options)"
a1=$(sed -n 's/^argv1=//p' "$rec")
a4=$(sed -n 's/^argv4=//p' "$rec")
a5=$(sed -n 's/^argv5=//p' "$rec")
case "$a1" in
  '' | *[!0-9]*) fail "argv1 (job id) is not numeric: '$a1'" ;;
esac
[ "$a4" = "1" ] || fail "argv4 (copies) is '$a4', expected 1 (the host replays the copies)"
case "$a5" in
  *"sides=$SIDES"*) ;;
  *) fail "argv5 (options) has no sides=$SIDES: '$a5'" ;;
esac
case "$a5" in
  *"Duplex=$DUPLEX"*) ;;
  *) fail "argv5 (options) has no Duplex=$DUPLEX: '$a5'" ;;
esac
grep -q '^CONTENT_TYPE=application/vnd.cups-raster$' "$rec" || fail "wrong CONTENT_TYPE in the filter environment"
grep -q "^PPD=$HERE/test/ppd-fixture.ppd$" "$rec" || fail "no PPD in the filter environment"
# The host replaces the child's environment: a filter that needs KONICA_* variables
# has to get them from a wrapper (see test/filter-wrapper.sh).
if grep -q '^KONICA_' "$rec"; then fail "the filter environment carries KONICA_* variables"; fi

echo "PASS test_native_filter ($MODE): $COPIES collated streams ($(wc -c < "$f") B), filter argv ok"

# Job accounting: a two-page PDF must report two impressions (sides), not one.
# PAPPL adds a single impression itself after printfile_cb; the app adds the rest.
if command -v gs >/dev/null 2>&1; then
  gs -q -dNOPAUSE -dBATCH -sDEVICE=pdfwrite -sOutputFile="$T/two.pdf" -c \
     "/Helvetica findfont 24 scalefont setfont 72 700 moveto (page 1) show showpage 72 700 moveto (page 2) show showpage" \
     >/dev/null 2>&1 || fail "gs could not create the two-page PDF"
  "$APP" submit -u "$U/ipp/print/t" -o copies=1 -o sides=two-sided-long-edge "$T/two.pdf" >/dev/null 2>&1 ||
    fail "submit two-page PDF"
  i=0
  while [ $i -lt 120 ] && ! grep -aq 'job-impressions-completed=2' "$T/s.log" 2>/dev/null; do
    i=$((i + 1)); sleep 1
  done
  grep -aq 'job-impressions-completed=2' "$T/s.log" ||
    fail "two-page PDF did not report 2 impressions"
  echo "PASS test_native_filter: two-page PDF reports 2 impressions"
else
  echo "SKIP impressions check: gs not installed"
fi

exit 0
