# Duplex binding investigation: builtin vs system renderer

Date: 2026-10-06. App: `konica206-native` (native PAPPL, bizhub 206 GDI).
Question: why do `builtin`-rendered duplex jobs bind short-edge while
`system`-rendered ones bind long-edge?

## Method

Same document (`ACCE03…-II_PUC.pdf`, 3 pages A4 portrait, scanned), same
queue (`konica206-native`), same options (`PageSize=A4 InputSlot=Tray1
Duplex=DuplexNoTumble sides=two-sided-long-edge 600dpi`), pages 1–2
(one duplex sheet). Power-cycle before every trial. Vendor input raster
and output stream captured per trial (`KONICA_CAPTURE_DIR`).

Golden control: 2-page duplex of CUPS `standard.pdf`, same options.

## Results

| Test | Renderer | Power-cycle | Binding |
|---|---|---|---|
| builtin void | builtin | no | short |
| system T2 | system | yes | **long** |
| builtin T3 | builtin | yes | short |
| system T4 | system | yes | **long** |
| golden std2, builtin | builtin | yes | short |

Deterministic across power-cycles: renderer-correlated, not flakiness.

## Measurements (all equivalent except pixels)

- Raster headers, every field, both pages: `4961x7016, Duplex=1,
  Tumble=0, MP=3, PS=595x842, BBox=0,0,595,842, NCopy=1` — identical.
- PJL control strings: identical except `IMAGELEN` byte counts
  (compressed-size bookkeeping).
- Stream tails (`PAGESTATUS=END`, `EOJ`, `UEL`): identical.
- Decoded final bitmaps: 99.4% identical bits both pages.
- Pixel diffs live in one band only (text antialiasing); no shift,
  rotation, flip, or placement difference found (tested explicitly).

Per-page diff on the failing document: p1 ~9%, p2 ~39% (watermark/
annotation rendering differences between Ghostscript and poppler,
including ~2.4% fully-inverted pixels) — but orientation-independent.

## Fixes applied along the way (kept)

1. `MediaPosition` was 0 on builtin vs 3 on system → vendor emitted
   `MEDIASOURCE=AUTO` instead of `TRAY1`. Fixed: header now mapped from
   PPD `InputSlot` (`commit: Builtin: set raster MediaPosition`).
2. `ImagingBoundingBox` was `0,0,0,0` and borderless scale `0.0` on
   builtin vs `0,0,595,842` / `1.0` on system. Fixed to mirror.
3. Neither fix changed the binding outcome.

## 2026-10-07 conclusion — superseded, see the next section

Root cause found with external review: `pdftoraster` rotates duplex
back-side pages 180° when the PPD says `*cupsBackSide: Rotated` (ours
does) and `Tumble` is off. The printer's `SHORTEDGE` mechanics turn that
upside-down back page into long-edge output. The builtin path skipped the
rotation, so backs came out flipped. Headers, PJL and placement are now
mirrored including the rotation rule table (Rotated/ManualTumble/
Flipped); offline comparison shows 0.569% bit difference on both pages
(pure antialiasing), and the golden 2-page duplex prints long-edge on
paper. The earlier "no control-byte cause" assessment is superseded:
the cause was a missing *transformation*, invisible to header/PJL diffs.
Live default stays `system` until the soak period passes.

## 2026-11-13: the pre-rotation is wrong for the current encoder stage

The conclusion above was measured while the vendor `245igdirf` was the encoder
stage. On 2026-10-21 the app switched to `konica-native`, which derives
`DUPLEX`/`BINDING` from the raster header and the job options alone. It never
sees the PPD's back-side setting, which the vendor filter did receive on its
command line (`back-side-orientation=Rotated`). The pre-rotation therefore kept
compensating for a hint that no longer exists.

Straight A/B on an A4 orientation marker sheet (2 pages, duplex long edge,
flip about the left long edge), same queue and printer, one sheet each:

| job | `*cupsBackSide` the app read | back page on paper |
|---|---|---|
| 323 | `Rotated` (app pre-rotated page 2) | upside down |
| 325 | `Normal` (no pre-rotation) | upright, both sides top-to-bottom |

Offline, with the Normal PPD the duplex raster's page 2 is pixel-identical to
the simplex render of the same page (previously it matched only after a 180°
rotation), while the encoder still emits `DUPLEX=ON` + `BINDING=SHORTEDGE` for
a portrait long-edge job. So the 206's duplexer does the long-edge binding
itself and the application must not pre-rotate.

Changes: `BACKSIDE_DEFAULT` is now "no rotation", and the install scripts
derive a `*cupsBackSide: Normal` copy for the app
(`/usr/local/share/konica/KonicaMinolta-206-native-normal.ppd`) instead of
using the vendor PPD. The vendor PPD and the PPDs used by the CUPS/legacy
queues keep `Rotated`, which is still required there (deleting it makes the
legacy chain print at the wrong edge; see `ubuntu-printing/konica206uri.md`).

Caveat worth keeping in mind: job 324 (old PPD, printed immediately after the
failing 323) came out upright, which matches the duplex-clutch carry-over
hypothesis in `konica-retrofit/konica206-duplex-discrepancy.md`. If a back page
ever comes out inverted again, repeat the same job before changing any
configuration.
