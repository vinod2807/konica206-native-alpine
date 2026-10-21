# konica206-native on Alpine (musl)

The PAPPL printer application running on Alpine Linux with the musl-clean
`konica-native` as the vendor stage. Verified on Alpine 3.24.2 (musl 1.2.6),
PAPPL 1.3.1, CUPS 2.4.19.

## What is installed where

| Piece | Path | Notes |
|---|---|---|
| the app | `/usr/local/bin/konica206-native` | musl build; the repo's committed binaries are glibc builds and do **not** run here - rebuild |
| PAPPL 1.3.1 | `/usr/local/lib/libpappl.so.1` | Alpine ships no `pappl` package, so it is built from source |
| vendor stage | `/usr/local/lib/konica/konica-native` | pure C11/libc, from https://github.com/vinod2807/konica-native-musl |
| vendor runtime data | `/usr/local/lib/konica/KonicaMinolta/245igdi/` | halftone screen + ICC profiles; **not** in this repo (vendor files) |
| OpenRC service | `/etc/init.d/konica206-native` | `dist/konica206-native.initd` |
| environment | `/etc/conf.d/konica206-native` | `dist/konica206-native.conf` |
| PAPPL state | `/var/lib/konica206-native.state` | as root; under `$HOME` for a normal user |
| log | `/var/log/konica206-native.log` | PAPPL logs to stderr; there is no journald here |

## Install

```sh
sudo scripts/install-alpine.sh [queue-name]     # default queue name: konica206
```

It builds PAPPL, builds and installs the app, installs the OpenRC service,
starts it and adds the queue for the printer found on USB.

The vendor runtime data and the PPD are **not** installed by the script: both are
vendor files and stay out of this repository. The runtime data is required for
real output (konica-native exits 1 and writes nothing without the halftone
screen and the two ICC profiles). The PPD is optional - see below.

## The queue

```
ipp://<host>:8001/ipp/print/konica206
```

Defaults, as published by the driver:

| Attribute | Value |
|---|---|
| `media-default` | `iso_a4_210x297mm` (A4) |
| `sides-default` | `one-sided` |
| `sides-supported` | `one-sided`, `two-sided-long-edge`, `two-sided-short-edge` |
| `print-color-mode-default` | `monochrome` |
| `printer-resolution-default` | `600dpi` |

`KONICA_LISTEN=localhost` (the default) restricts IPP to the loopback; set it to
`any` for LAN clients. The PAPPL web interface follows the same setting.

Check it:

```sh
konica206-native printers -u ipp://localhost:8001
konica206-native status   -u ipp://localhost:8001
ipptool -t ipp://localhost:8001/ipp/print/konica206 get-printer-attributes.test
```

## One queue per USB device

The USB interface is claimed by whichever queue prints first, and the legacy
CUPS queue (`KONICA206_ALPINE`, PPD + `*cupsFilter`) claims the same interface.
Only one of them may print at a time. Under CUPS 3.0, which drops PPD support,
the CUPS-side queue has to become a driverless IPP proxy to this app:

```sh
lpadmin -p konica206 -v ipp://127.0.0.1:8001/ipp/print/konica206 -m everywhere
```

## The PPD is optional

CUPS 3.0 drops PPD support, so the app does not depend on one: the page
geometry, the tray-to-`MediaPosition` map and the duplex back-side rule
(`cupsBackSide: Rotated`) are compiled in, and a readable `KONICA_PPD` overrides
all three. The same job renders to a byte-identical raster and printer stream
with and without the PPD (verified; `test/test_ppd.c` pins both paths).

If you keep one, put it outside CUPS's tree so a CUPS upgrade cannot change the
app's behaviour:

```sh
install -D -m 644 KonicaMinolta-206-native.ppd /usr/local/share/konica/
export KONICA_PPD=/usr/local/share/konica/KonicaMinolta-206-native.ppd
```

## Verifying without paper

```sh
make check           # chunking + PPD regression
make check-native    # the vendor-filter stage end to end (no printer, no USB)
```

`check-native` drives a stand-in filter by default, so it runs anywhere; with
`NATIVE=<path>` it drives the real konica-native and skips when the runtime
data is missing.

## What was verified (Alpine 3.24.2, musl, 2026-10-21)

* The app builds and runs on musl against PAPPL 1.3.1 built from source.
* `make check` passes; `make check-native` passes with the stand-in filter and
  with a musl build of konica-native plus the real vendor runtime data (two
  collated copies, 240 kB stream).
* PDF path: `builtin` (Ghostscript 10.08.0) produced a 2-page, 600 dpi, 8-bit
  gray stream; `system` (cups-filters' `pdftoraster`, which on Alpine comes
  from the cups-filters package, not from poppler) follows the PPD.
* Two real jobs printed through the queue (A4, one-sided and A4 duplex), both
  completed with one impression.

## NOT verified

1. The byte comparison against the **vendor** filter (the test host has the
   runtime data but not the `245igdirf` binary).
2. The two PDF renderers against each other on the real PPD: the vendor's
   reference raster is pdftoraster's A4 page (4961x7016, 8-bit, `A4.Borderless`).
3. The seven trays of the PPD: the driver advertises `auto`, `tray-1` and
   `by-pass-tray` only.
