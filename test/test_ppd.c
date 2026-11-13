/* Regression test for the PPD helpers in src/konica_filter.c.
 * The live PPD uses the translated keyword form ("*PaperDimension A4/A4: ..."),
 * which ppd_paper_points() used to miss (every size silently fell back to
 * hardcoded A4 geometry). Run from the repo root:  make check-ppd
 * No printer, no USB, no paper. */
#include <stdio.h>
#include <string.h>

#include "../src/konica_filter.c"

static int fails = 0;

#define CHECK(cond, ...) \
  do { \
    if (!(cond)) { printf("FAIL %d: ", __LINE__); printf(__VA_ARGS__); printf("\n"); fails++; } \
  } while (0)

int
main(int argc, char *argv[])
{
  const char *ppd = argc > 1 ? argv[1] : "test/ppd-fixture.ppd";
  double w = 0, h = 0;

  /* translated form: the case that used to miss */
  CHECK(ppd_paper_points(ppd, "A4", &w, &h) == 0 && w == 595 && h == 842,
        "A4 -> %g %g", w, h);
  CHECK(ppd_paper_points(ppd, "Letter", &w, &h) == 0 && w == 612 && h == 792,
        "Letter -> %g %g", w, h);
  CHECK(ppd_paper_points(ppd, "A3", &w, &h) == 0 && w == 842 && h == 1191,
        "A3 -> %g %g", w, h);
  CHECK(ppd_paper_points(ppd, "B5", &w, &h) == 0 && w == 516 && h == 729,
        "B5 -> %g %g", w, h);
  /* untranslated form keeps working */
  CHECK(ppd_paper_points(ppd, "Plain", &w, &h) == 0 && w == 100 && h == 200,
        "Plain -> %g %g", w, h);
  /* unknown size and partial-name prefix must miss, not match a sibling */
  CHECK(ppd_paper_points(ppd, "Statement", &w, &h) != 0, "Statement should miss");
  CHECK(ppd_paper_points(ppd, "A", &w, &h) != 0, "'A' must not match A3/A4");
  CHECK(ppd_paper_points("/nonexistent.ppd", "A4", &w, &h) != 0, "missing file");
  CHECK(ppd_paper_points(ppd, NULL, &w, &h) != 0, "NULL name");

  /* neighbours use prefix matching already; pin their behaviour too */
  CHECK(ppd_has_option(ppd, "PageSize", "A4") == 1, "has PageSize A4");
  CHECK(ppd_has_option(ppd, "PageSize", "Nope") == 0, "no PageSize Nope");
  CHECK(ppd_has_option(ppd, "Resolution", "600x600dpi") == 1, "has 600dpi");
  CHECK(ppd_media_position(ppd, "Tray1") == 3, "Tray1 -> %d", ppd_media_position(ppd, "Tray1"));
  CHECK(ppd_media_position(ppd, "Bypass") == 2, "Bypass -> %d", ppd_media_position(ppd, "Bypass"));
  CHECK(ppd_media_position(ppd, "Auto") == 1, "Auto -> %d", ppd_media_position(ppd, "Auto"));
  CHECK(ppd_media_position(ppd, "Tray9") == 0, "unknown slot -> 0");
  CHECK(ppd_backside(ppd) == 'R', "backside -> '%c'", ppd_backside(ppd));

  /* The PPD is optional (CUPS 3.0 drops PPD support): with no PPD the built-in
   * tables provide the geometry, the tray map and the back-side rule.  A
   * readable PPD stays authoritative. */
  {
    konica_cfg_t cfg;
    double pw = 0, ph = 0;

    memset(&cfg, 0, sizeof(cfg));

    /* PPD present: the PPD wins, even where it differs from the built-in table */
    snprintf(cfg.ppd, sizeof(cfg.ppd), "%s", ppd);
    CHECK(paper_points(&cfg, "A4", &pw, &ph) == 0 && pw == 595 && ph == 842,
          "with PPD: A4 -> %g %g", pw, ph);
    CHECK(paper_points(&cfg, "Plain", &pw, &ph) == 0 && pw == 100 && ph == 200,
          "with PPD: Plain -> %g %g", pw, ph);
    CHECK(media_position(&cfg, "Tray1") == 3, "with PPD: Tray1 -> %d", media_position(&cfg, "Tray1"));
    CHECK(backside_rule(&cfg) == 'R', "with PPD: backside -> '%c'", backside_rule(&cfg));
    CHECK(konica_has_option(&cfg, "PageSize", "A4") == 1, "with PPD: has PageSize A4");
    CHECK(konica_has_option(&cfg, "PageSize", "Nope") == 0, "with PPD: no PageSize Nope");

    /* No PPD: the built-in tables take over */
    snprintf(cfg.ppd, sizeof(cfg.ppd), "%s", "/nonexistent.ppd");
    CHECK(paper_points(&cfg, "A4", &pw, &ph) == 0 && pw == 595 && ph == 842,
          "no PPD: A4 -> %g %g", pw, ph);
    CHECK(paper_points(&cfg, "Letter", &pw, &ph) == 0 && pw == 612 && ph == 792,
          "no PPD: Letter -> %g %g", pw, ph);
    CHECK(paper_points(&cfg, "A3", &pw, &ph) == 0 && pw == 842 && ph == 1191,
          "no PPD: A3 -> %g %g", pw, ph);
    CHECK(paper_points(&cfg, "Legal", &pw, &ph) == 0 && pw == 612 && ph == 1008,
          "no PPD: Legal -> %g %g", pw, ph);
    CHECK(paper_points(&cfg, "Statement", &pw, &ph) == 0 && pw == 396 && ph == 612,
          "no PPD: Statement -> %g %g", pw, ph);
    CHECK(paper_points(&cfg, "Nope", &pw, &ph) != 0, "no PPD: unknown size misses");
    CHECK(media_position(&cfg, "Auto") == 1, "no PPD: Auto -> %d", media_position(&cfg, "Auto"));
    CHECK(media_position(&cfg, "Tray1") == 3, "no PPD: Tray1 -> %d", media_position(&cfg, "Tray1"));
    CHECK(media_position(&cfg, "Bypass") == 2, "no PPD: Bypass -> %d", media_position(&cfg, "Bypass"));
    CHECK(media_position(&cfg, "Tray9") == 0, "no PPD: unknown slot -> 0");
    /* The back-side rule must not silently disappear: without it duplex back
     * pages come out upside down. */
    CHECK(backside_rule(&cfg) == 'R', "no PPD: backside -> '%c'", backside_rule(&cfg));
    CHECK(konica_has_option(&cfg, "PageSize", "A4") == 1, "no PPD: has PageSize A4");
    CHECK(konica_has_option(&cfg, "PageSize", "Nope") == 0, "no PPD: no PageSize Nope");
    CHECK(konica_has_option(&cfg, "InputSlot", "Tray1") == 1, "no PPD: has InputSlot Tray1");
    CHECK(konica_has_option(&cfg, "InputSlot", "Nope") == 0, "no PPD: no InputSlot Nope");
  }

  if (fails == 0)
    printf("ALL PPD TESTS PASSED (%s)\n", ppd);
  else
    printf("%d FAILURES (%s)\n", fails, ppd);
  return fails != 0;
}
