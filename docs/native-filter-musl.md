# Using konica-native (pure-libc, musl-clean) instead of the vendor 245igdirf

`konica206-native` runs the vendor raster filter as a **child process** with the standard CUPS
filter calling convention (`argv: job user title copies options [file]`, raster on stdin, printer
stream on stdout, `PPD`/`CONTENT_TYPE`/... in the environment). `konica-native`
(https://github.com/vinod2807/konica-native-musl) is a drop-in for that child, so **no code change
is needed**: point `KONICA_VENDOR_FILTER` at it.

```
IPP -> PAPPL -> pdftoraster -> konica-native -> libusb, 8192-byte chunks -> bizhub 206
```

What you gain: no glibc, no private `libcups`/`libcupsimage` for the vendor stage, so the vendor
stage runs on Alpine/musl. What stays the same: the PAPPL app, the PPD, the USB transport, the
watchdog, duplex handling and copies (the app replays N streams itself; both filters ignore
`copies`).

Scope: *musl-clean* applies to the **vendor stage**. The app itself still needs `pappl`,
`libcups` (the raster API) and `libusb` on Alpine - see "Alpine" below.

## Configure

```sh
# build konica-native ON the target (musl on Alpine), then
install -m 0755 -o root -g root konica-native /usr/local/lib/konica/konica-native
# runtime data (vendor halftone screen + ICC profiles) at the default path -- see konica-native-musl docs
export KONICA_VENDOR_FILTER=/usr/local/lib/konica/konica-native
```

`KONICA_LIBDIR` can stay at its default; the filter does not use it.

### The runtime data must be at the default path

The app execs the filter with a **fixed environment** - `PPD`, `CONTENT_TYPE`,
`FINAL_CONTENT_TYPE`, `CUPS_SERVERBIN`, `CUPS_DATADIR`, `LD_LIBRARY_PATH`, `PRINTER`, `TMPDIR`,
`PATH`, `LANG`, `CUPS_SERVER` - and nothing else (see `src/konica_filter.c`). konica-native's own
`KONICA_HFT`, `KONICA_SRGB`, `KONICA_GRAY`, `KONICA_LUT` and `KONICA_FLAT_TONE` overrides are
therefore **not** inherited. The vendor data has to sit where konica-native looks for it:

```
/usr/local/lib/konica/KonicaMinolta/245igdi/Halftones/COPA.DEFAULT.600x600.hft
/usr/local/lib/konica/KonicaMinolta/245igdi/Profiles/sRGB.icm
/usr/local/lib/konica/KonicaMinolta/245igdi/Profiles/sGrayInv.icm
```

To keep the data somewhere else, point `KONICA_VENDOR_FILTER` at a wrapper - the app execs
`argv[0]` as whatever you name, so a shell script works. `test/filter-wrapper.sh` in this repo is a
ready-made one (it also records the child's argv, which is how the test below checks the calling
convention):

```sh
#!/bin/sh
# /usr/local/lib/konica/konica-native.sh
export KONICA_SRGB=/opt/konica/Profiles/sRGB.icm
exec /opt/konica/konica-native "$@"
```

### systemd

`dist/konica206-native-musl.conf` is a drop-in for the unit in `dist/konica206-native.service`:

```sh
install -D -m 644 dist/konica206-native-musl.conf \
  /etc/systemd/system/konica206-native.service.d/musl-native-filter.conf
systemctl daemon-reload
systemctl restart konica206-native
```

A drop-in is applied after the unit, so its `Environment=` replaces the unit's
`KONICA_VENDOR_FILTER` (the vendor path) with the musl one. The unit's other settings
(`KONICA_PDF_RENDERER`, `KONICA_PPD`, ...) are untouched.

### OpenRC

The repo ships no OpenRC init script (for Puppy, which has no systemd either, the documented
pattern is a `/root/Startup/*.sh` boot script - see `docs/install-ubuntu-debian-puppy.md`). If you
run an OpenRC service for this app, put the variable in its conf.d file;
`dist/konica206-native.conf` is a sample:

```sh
# /etc/conf.d/konica206-native
export KONICA_VENDOR_FILTER=/usr/local/lib/konica/konica-native
```

Pre-flight: with the halftone screen or profiles missing, `konica-native` exits 1 and writes
nothing, so the job is aborted with an error in the log and nothing is sent to the printer.

## Alpine

Alpine 3.24 ships no `pappl` package, so build PAPPL from source (1.3.1 works against Alpine's
CUPS 2.4.19); `cups-dev`, `libusb-dev`, `libpng-dev`, `libjpeg-turbo-dev`, `zlib-dev`,
`openssl-dev` and `avahi-dev` are what PAPPL needs. The app itself then builds with the usual
`make`.

Two PDF renderers exist, and they are **not** interchangeable:

| `KONICA_PDF_RENDERER` | path | notes |
|---|---|---|
| `builtin` (the unit's default) | `gs -sDEVICE=pgmraw` + the app's own raster writer | 600 dpi, 8-bit gray, geometry from the PPD; the duplex back-side rotation is done here |
| `system` | `KONICA_RASTER_FILTER` (`/usr/lib/cups/filter/pdftoraster`) | follows the PPD's resolution and bit depth; on Alpine the binary comes from **cups-filters** (1.28.17), not from poppler |

The old note "Alpine's Ghostscript 10.05.1 makes empty rasters" applies to cups-filters'
`gstoraster`, not to the `builtin` path (which calls `gs` directly); on Alpine 3.24.2 with
Ghostscript 10.08.0 the `builtin` path produced a correct 2-page stream. Still: check the paper
before switching a working queue over.

## Test

```sh
make check-native                                  # stand-in filter: no vendor data needed
NATIVE=/usr/local/lib/konica/konica-native make check-native   # the real filter
```

`test/test_native_filter.sh` runs the app against a `konicafile://` device (no printer, no USB, no
CUPS queue) and checks that

* the filter is invoked as a child with the CUPS filter calling convention - 5 arguments
  (`job user title copies options`), `copies` = 1 (the host replays the copies), and the option
  string carries `sides=` and `Duplex=`;
* the child's environment carries `PPD` and `CONTENT_TYPE=application/vnd.cups-raster`, and no
  `KONICA_*` variables (the host replaces it - see above);
* the filter's stdout becomes the printer stream, replayed once per copy.

By default it drives a stand-in filter (`test/standin-filter.sh`), so it runs anywhere; with
`NATIVE=` it drives the real konica-native and SKIPs (exit 0) when the runtime data is missing.

## Verified (Alpine 3.24.2, musl, 2026-10-21)

* The app builds and runs on musl (PAPPL 1.3.1 built from source; `make check` passes).
* `make check-native` with the stand-in filter: PASS.
* `NATIVE=<musl build of konica-native> make check-native` with the **real** vendor runtime data
  (halftone screen + ICC profiles): PASS - two collated copies, 240 kB stream, filter argv as
  expected.
* Raster path (PNG): the real filter produced a well-formed job (UEL, `@PJL SET COMPRESS=JBIG`,
  the JBIG bands, `@PJL EOJ`). With `sides=two-sided-long-edge` the stream carries
  `@PJL SET DUPLEX=ON` and `@PJL SET BINDING=SHORTEDGE` - konica-native reproduces the vendor's
  inversion of the edge names (`two-sided-long-edge` -> `SHORTEDGE`) faithfully, see
  konica-native-musl's `src/encode.c`.
* PDF path: `builtin` (Ghostscript 10.08.0) produced a 2-page, 600 dpi, 8-bit gray stream;
  `system` (cups-filters' `pdftoraster`) also ran, but with the minimal `test/ppd-fixture.ppd` it
  follows the PPD and degraded to 100 dpi, 1-bit - the real PPD is what pins 600 dpi.

## NOT verified -- please run

1. The real `konica-native` against the **vendor** filter on the same raster, byte for byte
   (`tools/compare-real.sh` in konica-native-musl). The test host has the vendor *runtime data*
   but not the `245igdirf` binary, so this could not be closed here.
2. Printing on the printer (use a test queue; one OS or queue on the USB device at a time; no
   banner pages).
3. The two PDF renderers against each other on the **real** PPD: the vendor's reference raster is
   pdftoraster's A4 page (4961x7016, 8-bit, `A4.Borderless`); confirm the app's raster reaches
   konica-native with the same geometry.
4. The committed binaries in this repo are glibc builds: rebuild on musl, do not copy them.
