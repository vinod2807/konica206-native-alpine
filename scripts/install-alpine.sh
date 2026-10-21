#!/bin/sh
# Install konica206-native on Alpine (musl) as a PAPPL printer application with
# the musl-clean konica-native as the vendor stage, and create the queue.
#
#   sudo scripts/install-alpine.sh [queue-name]
#
# What it does:
#   1. build deps + PAPPL 1.3.1 (Alpine ships no pappl package) -> /usr/local
#   2. build and install the app -> /usr/local/bin
#   3. install the vendor runtime data (halftone screen + ICC profiles) and the
#      PPD, so that real output works out of the box
#   4. install the OpenRC service and its conf.d
#   5. start the service and add the queue for the printer found on USB
#
# The vendor files come from vendor/ in this repository; see vendor/NOTICE for
# what they are and what they are not.
set -eu

HERE=$(cd "$(dirname "$0")/.." && pwd)
QUEUE=${1:-konica206}
PORT=${KONICA206_PORT:-8001}
PAPPL_VER=${PAPPL_VER:-1.3.1}
PREFIX=${PREFIX:-/usr/local}
WORK=${WORK:-/tmp/konica206-install}

say() { echo "==> $*"; }
need_root() { [ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 1; }; }

need_root

say "build dependencies"
apk add --no-cache cups-dev libusb-dev libpng-dev libjpeg-turbo-dev zlib-dev \
  openssl-dev avahi-dev gcc make pkgconf curl

say "PAPPL $PAPPL_VER (Alpine has no pappl package)"
mkdir -p "$WORK"
if [ ! -d "$WORK/pappl" ]; then
  git clone -q --branch "v$PAPPL_VER" --depth 1 https://github.com/michaelrsweet/pappl.git "$WORK/pappl"
fi
cd "$WORK/pappl"
./configure --prefix="$PREFIX" >/dev/null
make -j"$(nproc)" >/dev/null
make install >/dev/null

say "konica206-native"
cd "$HERE"
make >/dev/null
make install >/dev/null

say "OpenRC service"
install -D -m 755 dist/konica206-native.initd /etc/init.d/konica206-native
install -D -m 644 dist/konica206-native.conf /etc/conf.d/konica206-native

say "vendor runtime data and PPD"
# The halftone screen and the two ICC profiles: konica-native loads them before
# it writes the first byte of a job and refuses to emit anything without them.
install -d -m 755 /usr/local/lib/konica/KonicaMinolta/245igdi
cp -a vendor/KonicaMinolta/245igdi/. /usr/local/lib/konica/KonicaMinolta/245igdi/
install -d -m 755 /usr/local/share/konica
install -m 644 vendor/KonicaMinolta/KonicaMinolta-206-native.ppd \
  /usr/local/share/konica/KonicaMinolta-206-native.ppd

say "preflight: does the filter have what it needs?"
# konica-native loads the halftone screen and the two ICC profiles before it
# writes the first byte of a job; without them it exits 1 and prints nothing.
missing=
for f in Halftones/COPA.DEFAULT.600x600.hft Profiles/sRGB.icm Profiles/sGrayInv.icm; do
  [ -r "/usr/local/lib/konica/KonicaMinolta/245igdi/$f" ] || missing="$missing $f"
done
if [ -n "$missing" ]; then
  echo "WARNING: missing vendor runtime data:$missing" >&2
  echo "         jobs will abort with 'vendor filter produced no output'." >&2
else
  echo "ok: halftone screen + ICC profiles present"
fi

say "start"
rc-service konica206-native restart || true
rc-update add konica206-native default 2>/dev/null || true

say "queue '$QUEUE' on port $PORT"
# The serial is the printer's USB iSerial; override with KONICA_SERIAL=...
SERIAL=${KONICA_SERIAL:-$(lsusb -d 132b:232b -v 2>/dev/null | sed -n 's/^[[:space:]]*iSerial[[:space:]]*[0-9]*[[:space:]]*\(.*\)$/\1/p' | head -1)}
[ -n "$SERIAL" ] || { echo "could not read the printer serial; set KONICA_SERIAL=" >&2; exit 1; }
echo "printer serial: $SERIAL"
"$PREFIX/bin/konica206-native" add -d "$QUEUE" -u "ipp://localhost:$PORT" \
  -m konica-bizhub-206 \
  -v "konica://KONICA%20MINOLTA/206?serial=$SERIAL"

say "done"
echo "queue URI: ipp://\$(hostname -i):$PORT/ipp/print/$QUEUE"
echo "defaults:  A4, one-sided (duplex long/short edge available)"
echo "log:       /var/log/konica206-native.log"
echo
echo "note: only one queue may own the USB device at a time"
