# Changelog

All notable changes, newest first. Format: version + date + what changed.

## v4.5 — 2026-08-15
- **Slider dragging fixed.** Sliders only set on mouse-press; added global mouse tracking while held (ScrollingFrame was swallowing the bar's own InputChanged).
- **Wheel resize fixed.** Wheel was sunk for the camera but resize lived in a `gpe`-gated UIS handler that never fired for sunk input; resize now runs inside the sink binding. **Shift+wheel** passes through to zoom the camera while armed.
- **Turbo mode added.** Toggle: 500-blob batches per flush, no per-blob delay, exact `PaintUpdateRate` cadence. Human Mode still wins if both are on. Untested against the server's per-invoke blob cap — watch for dropped blobs on first use.

## v4.4 — 2026-08-14
- **Self-contained:** embedded pure-Luau PNG decoder (verified 10/10 pixel-exact vs img2grid.js); URL image painting no longer needs localhost imgserver. PNG URLs only, 8-bit, non-interlaced.
- **Human mode, click-sink.** Also known 2026-08-14: warmup flush for fresh servers (v4.3.1), text painter (v4.3).

## v4 — 2026-08-11
- **BUG #1 FIXED (multi-color batches).** Server persists one color per stroke → `runPaintJob` now groups blobs globally by color (first-seen order) and flushes each color as its own stroke with its own `WarnModule()` keys. Verified: 16/16 color test, 36/36 checkerboard, 1116/1116 logo image (145 color runs).
- **One-click URL painting.** New `imgserver.js` (localhost:17393) decodes PNG URLs (incl. Wikimedia file pages) → hub "🖼 Load URL & Place" button fetches, arms placement, shows preview; **left-click a wall** to auto-draw. No more manual node commands.
- **Image resolution slider** (default 40 px wide, up to 80) + skipped-pixel reporting (off-wall / too-far counts).
- **Full color picker:** hue bar + saturation/value square + preview swatch + Hex / RGB / HSV text fields; swatches feed into it. Size slider min 0.1→0.05, opacity min 0.1→0.05.

## v3 — 2026-08-10

## v3 — 2026-08-10
- **URL image painter (built, blocked by issue #1).** `buildImage` + cursor-following preview square + URL box + px-size slider + Paint button. Per-pixel surface-snapping.
- Added `img2grid.js` (Node PNG decoder → Luau pixel grid). Verified decode pixel-exact (synthetic, Lenna, RGBA favicon).
- Fixed: `frameFromHit` up-vector inversion (was painting image off the wall bottom).
- Fixed: pattern maps for Checker/Flag (were Color3 keys → drew nothing).
- Added "Enforce Brush" loop so manual painting keeps your settings vs the game's ~1 s `PaintSettings` reset.
- Size cap set to the account max **1.2**; Neon/Chrome/Rainbow toggles now gated with an explanatory note (gamepass-locked).

## v2 — 2026-08-10
- Aim-centered facing-wall targeting (`aimFrame` camera ray) — features paint where you look, not the nearest wall.
- Per-blob attribute re-assert (defeats `PaintSettings` periodic reset).
- Effects toggles gated by gamepass ownership (refuse with status instead of silently reverting).

## v1 — 2026-08-10
- Initial hub: verified paint pipeline (make/cache/sendToServer + WarnModule keys), UI panel, fill/pattern preset/rainbow/spray-spam/erase/stop, brush settings.
