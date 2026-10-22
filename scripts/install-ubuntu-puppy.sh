#!/bin/sh
# Install the glibc/vendor-filter edition on Ubuntu, Debian, or Ubuntu-based
# Puppy systems.  This deliberately does not stop an existing printer app or
# create a CUPS queue; the native app uses its own IPP endpoint on port 8001.
set -eu

HERE=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
PREFIX=${PREFIX:-/usr/local}
PORT=${KONICA206_PORT:-8001}
QUEUE=${1:-konica206}

say() { printf '%s\n' "==> $*"; }
die() { printf '%s\n' "error: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root (for example: sudo $0)"

if command -v apt-get >/dev/null 2>&1; then
    missing=
    for tool in cc make pkgconf; do
        command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
    done
    if [ -n "$missing" ]; then
        say "installing build dependencies"
        if ! DEBIAN_FRONTEND=noninteractive apt-get install -y \
            build-essential pkgconf libpappl-dev libusb-1.0-0-dev \
            libcups2-dev cups-filters ghostscript cups-ipp-utils; then
            die "APT could not install the build dependencies; repair held/partial packages and rerun"
        fi
    fi
fi

command -v make >/dev/null 2>&1 || die "make is unavailable; install build-essential"
command -v cc >/dev/null 2>&1 || die "a C compiler is unavailable; install build-essential"

say "building"
cd "$HERE"
make
make check
make install PREFIX="$PREFIX"

# Existing vendor installations are the preferred glibc path.  Do not copy or
# overwrite their private libraries; only verify the required files exist.
VENDOR=${KONICA_VENDOR_FILTER:-/usr/local/lib/konica/KonicaMinolta/245igdi/Filters/245igdirf}
LIBDIR=${KONICA_LIBDIR:-/usr/local/lib/konica/lib}
PPD=${KONICA_PPD:-/var/lib/legacy-printer-app/ppd/KonicaMinolta-206-fullbleed.ppd}
RASTER=${KONICA_RASTER_FILTER:-/usr/lib/cups/filter/pdftoraster}
[ -x "$VENDOR" ] || die "vendor filter not found: $VENDOR"
[ -d "$LIBDIR" ] || die "private library directory not found: $LIBDIR"
[ -x "$RASTER" ] || die "PDF raster filter not found: $RASTER"
[ -r "$PPD" ] || die "PPD not found: $PPD"

if command -v systemctl >/dev/null 2>&1 && [ "$(cat /proc/1/comm 2>/dev/null || true)" = systemd ]; then
    say "installing systemd unit"
    install -D -m 644 "$HERE/dist/konica206-native.service" \
        /etc/systemd/system/konica206-native.service
    systemctl daemon-reload
    systemctl enable --now konica206-native
    RUNNING=1
else
    say "systemd is not PID 1; start the app from the Puppy startup mechanism"
    say "KONICA_VENDOR_FILTER=$VENDOR KONICA_LIBDIR=$LIBDIR KONICA_PPD=$PPD KONICA_RASTER_FILTER=$RASTER $PREFIX/bin/konica206-native server -o server-port=$PORT"
    RUNNING=0
fi

if [ "$RUNNING" -eq 0 ]; then
    say "build and installation complete; start the server, then add '$QUEUE' with the command below"
    say "$PREFIX/bin/konica206-native add -d $QUEUE -u ipp://localhost:$PORT -m konica-bizhub-206 -v 'konica://KONICA%20MINOLTA/206?serial=${KONICA_SERIAL:-A8A6041029423}'"
    exit 0
elif "$PREFIX/bin/konica206-native" printers -u "ipp://localhost:$PORT" 2>/dev/null | grep -qx "$QUEUE"; then
    say "IPP printer '$QUEUE' already exists"
else
    SERIAL=${KONICA_SERIAL:-$(lsusb -d 132b:232b -v 2>/dev/null | sed -n 's/^[[:space:]]*iSerial[[:space:]]*[0-9]*[[:space:]]*//p' | head -1)}
    [ -n "$SERIAL" ] || SERIAL=A8A6041029423
    "$PREFIX/bin/konica206-native" add -d "$QUEUE" -u "ipp://localhost:$PORT" \
        -m konica-bizhub-206 -v "konica://KONICA%20MINOLTA/206?serial=$SERIAL"
fi

say "ready: ipp://localhost:$PORT/ipp/print/$QUEUE"
