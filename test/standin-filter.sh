#!/bin/sh
# Stand-in for the vendor raster filter (konica-native).
#
# It follows the same calling convention as the real filter -- argv: job user title
# copies options [file], raster on stdin, printer stream on stdout -- but it does
# not encode anything.  It emits a minimal PJL envelope so the host side can be
# tested (filter invocation, stream capture, copies replay) without the vendor
# runtime data (halftone screen, ICC profiles).
#
# The stream it writes is NOT a valid printer job: it only carries the markers the
# test looks for.
#
# Usage: standin-filter.sh job user title copies options [file]
#
# The raster arrives on stdin, or in the file named by argv[6] when present (the
# real filter reads argv[6] in that case).
if [ $# -ge 6 ] && [ -f "$6" ]; then
  cat "$6" > /dev/null 2>&1 || true
else
  cat > /dev/null 2>&1 || true
fi

printf '\033%%-12345X@PJL\r\n'
printf '@PJL SET COMPRESS=JBIG\r\n'
printf '@PJL SET PAPER=A4\r\n'
printf '@PJL SET PAGESTATUS=END\r\n'
printf '@PJL EOJ\r\n'

exit 0
