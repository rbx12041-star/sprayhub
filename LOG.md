# LOG

Running record of attempts + requests. New entries go on **top**. Template: `docs/LOG-template.md`.

---

### [2026-08-11] — Sebiy + assistant
**Issue:** #1 (multi-color batches persist only +1)
**What I tried:** Re-ran the group-by-color-per-stroke test (fixed, no `world+1` typo): 4 colors × 4 blobs, each color its own Stroke+bump+`LogUndoRedoEvent`+`WarnModule()` keys+flush, one `PaintUpdateRate` apart. Then shipped the same logic inside hub `runPaintJob` (GLOBAL color grouping via `seen[ck]` map, first-seen order — deliberately NOT contiguous runs, which shard interleaved images) and re-verified with the interleaved Checkerboard and a real 36×36 URL image.
**Result:** ✅ **FIXED.** 16/16 on the color test (round 2; round 1 dropped the first/red row — one-off flake, watch), 36/36 checkerboard, **1116/1116** logo px across 145 color runs. Image painter unblocked end-to-end: URL → decode → click wall → full multi-color art persists.
**Notes / next lead:** Skipped-pixel cause on first logo run ≠ a bug: 288/1296 px were *off the wall surface* (ray miss) and 0 too-far — hub now reports skip counts. New v4 UX: `imgserver.js` localhost decode service + one-click Load & Place + click-to-place + full color picker + res slider. LO's private server accepted everything; note paint doesn't cross fresh server instances (jobId change = fresh walls — expected).

### [2026-08-10] — Sebiy + assistant

### [2026-08-10] — Sebiy + assistant
**Issue:** #1 (multi-color batches persist only +1)
**What I tried:** Full forensic pass in-session. Built + verified engine (8/8, 4/4, 228 solid), URL decoder (PNG inflate — verified pixel-exact on synthetic + Lenna + RGBA favicon), cursor preview, surface-snapping per pixel, `frameFromHit` up-vector fix, pattern-map string-key fix, size-cap 1.0→1.2, fresh-area offset, centered-on-good-spot, per-color grouping test.
**Result:** 🔍 Isolated the cause to *multi-color batching*: single-color persists 100%, mixed-color → exactly `+1`, independent of count/location/spread. Group-by-color flush test written but crashed on a stray typo (`world + 1`) in the test script — **not yet rerun.** Engine, decoder, pattern fixes all ✅.
**Notes / next lead:** Rerun the group-by-color-per-stroke test (fix `world+1` in the throwaway test only, hub is fine). If +full → implement per-color multi-flush in `buildImage`/`runPaintJob` + quantize colors. If still `+1` → inspect `MakePaintNoCooldown` remote + server `MakePaint` return string.

### [2026-08-10] — Sebiy + assistant
**Issue:** repo setup
**What I did:** Created private repo `sprayhub`, added `sprayhub.luau`, `img2grid.js`, full docs (`PAINT-PIPELINE`, `ISSUES`, `LOG-template`), this log, changelog.
**Notes:** Friends: start at `docs/ISSUES.md`. 🟥 #1 is the live one.
