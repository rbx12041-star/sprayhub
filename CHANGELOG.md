# Changelog

All notable changes, newest first. Format: version + date + what changed.

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
