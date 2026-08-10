# LOG

Running record of attempts + requests. New entries go on **top**. Template: `docs/LOG-template.md`.

---

### [2026-08-10] — Sebiy + assistant
**Issue:** #1 (multi-color batches persist only +1)
**What I tried:** Full forensic pass in-session. Built + verified engine (8/8, 4/4, 228 solid), URL decoder (PNG inflate — verified pixel-exact on synthetic + Lenna + RGBA favicon), cursor preview, surface-snapping per pixel, `frameFromHit` up-vector fix, pattern-map string-key fix, size-cap 1.0→1.2, fresh-area offset, centered-on-good-spot, per-color grouping test.
**Result:** 🔍 Isolated the cause to *multi-color batching*: single-color persists 100%, mixed-color → exactly `+1`, independent of count/location/spread. Group-by-color flush test written but crashed on a stray typo (`world + 1`) in the test script — **not yet rerun.** Engine, decoder, pattern fixes all ✅.
**Notes / next lead:** Rerun the group-by-color-per-stroke test (fix `world+1` in the throwaway test only, hub is fine). If +full → implement per-color multi-flush in `buildImage`/`runPaintJob` + quantize colors. If still `+1` → inspect `MakePaintNoCooldown` remote + server `MakePaint` return string.

### [2026-08-10] — Sebiy + assistant
**Issue:** repo setup
**What I did:** Created private repo `sprayhub`, added `sprayhub.luau`, `img2grid.js`, full docs (`PAINT-PIPELINE`, `ISSUES`, `LOG-template`), this log, changelog.
**Notes:** Friends: start at `docs/ISSUES.md`. 🟥 #1 is the live one.
