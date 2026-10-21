#!/bin/sh
# Filter wrapper: records the child's argv and environment, then execs the real
# filter.
#
# The host app execs the vendor filter with a *fixed* environment (PPD,
# CONTENT_TYPE, FINAL_CONTENT_TYPE, CUPS_SERVERBIN, CUPS_DATADIR, LD_LIBRARY_PATH,
# PRINTER, TMPDIR, PATH, LANG, CUPS_SERVER -- see src/konica_filter.c).  Any
# variable the filter itself needs (KONICA_HFT, KONICA_SRGB, KONICA_GRAY,
# KONICA_LUT, KONICA_FLAT_TONE) is therefore NOT inherited and has to be injected
# here.  This is the supported way to point konica-native at runtime data outside
# its compiled-in defaults.
#
# Configuration is read from "filter-wrapper.conf" next to this script:
#
#   FILTER_REAL=/usr/local/lib/konica/konica-native   # required
#   FILTER_RECORD=/tmp/filter-argv.txt                # optional: argv/env record
#   export KONICA_SRGB=/opt/konica/Profiles/sRGB.icm  # optional: filter's env
#
# Usage: filter-wrapper.sh job user title copies options [file]
set -u

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
conf=$here/filter-wrapper.conf

[ -r "$conf" ] || { echo "filter-wrapper: $conf missing" >&2; exit 126; }
. "$conf"

: "${FILTER_REAL:?filter-wrapper.conf must set FILTER_REAL}"

{
  printf 'argc=%s\n' "$#"
  n=1
  for a in "$@"; do
    printf 'argv%s=%s\n' "$n" "$a"
    n=$((n + 1))
  done
  printf 'PPD=%s\n' "${PPD-}"
  printf 'CONTENT_TYPE=%s\n' "${CONTENT_TYPE-}"
  printf 'FINAL_CONTENT_TYPE=%s\n' "${FINAL_CONTENT_TYPE-}"
  printf 'LD_LIBRARY_PATH=%s\n' "${LD_LIBRARY_PATH-}"
  printf 'PRINTER=%s\n' "${PRINTER-}"
  printf 'TMPDIR=%s\n' "${TMPDIR-}"
  printf 'CUPS_SERVER=%s\n' "${CUPS_SERVER-}"
} >> "${FILTER_RECORD:-/dev/null}"

exec "$FILTER_REAL" "$@"
