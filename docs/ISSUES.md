# Issues: what's not working, what's been tried, what's next

This is the single source of truth for open bugs. If you work on one, log your attempt in `LOG.md` (copy the template in `docs/LOG-template.md`), then update this file.

Legend: 🟥 blocking · 🟨 annoying · 🟩 known-limitation (not fixable)

---

## ✅ #1 — Multi-color batches persist only `+1` — FIXED 2026-08-11

**Cause (confirmed live):** the server persists **ONE color per stroke** — a mixed-color batch in a single flush dedups to exactly one blob.

**Fix (shipped in v4):** `runPaintJob` now groups blobs **globally by color** (first-seen order — NOT contiguous runs, which would shard interleaved images into a stroke per pixel) and paints each color as its OWN stroke: `Stroke` bump + `LogUndoRedoEvent` + `cachePaint` those blobs only + fresh `WarnModule()` keys + `sendToServer`, waiting one `PaintUpdateRate` between color runs.

**Verification (2026-08-11, private server):** 4-color×4 test 16/16 ✓ · hub Checkerboard (18 white + 18 black interleaved) 36/36 ✓ · Roblox logo 40×36 image 1116/1116 px across 145 color runs ✓. Test script: `C:\Users\Sebii\sprayhub_colortest.luau` (flaky on first flush in round 1 — first color-run dropped once; watch for it).

<details><summary>Original report (kept for history)</summary>

**Symptom.** A batch of blobs with **mixed colors** yields exactly `+1` on the lifetime `PaintCount`, no matter the blob count, location, spacing, or offset — repeatedly reproduced via in-session execution. A **single-color** batch of the same size, same wall, same code path persists **fully**.

**Repro evidence.**
| batch | color | result |
|---|---|---|
| 8 blobs | all cyan | `+8` ✅ |
| 4 blobs | all cyan | `+4` ✅ |
| 3 blobs | all green | `+3` ✅ |
| ~228 fill | all red | `+228` ✅ |
| 16 grid (image) | R/G/B/W | `+1` ❌ |
| 4 grid 2×2 | R/G/B/W | `+1` ❌ |
| 16 grid, "fresh area" offset +8 | R/G/B/W | `+1` ❌ |
| 16 grid, centered on proven-good hit | R/G/B/W | `+1` ❌ |

**Ruled out (with evidence):** engine (simple blobs persist), session/throttle (single-color works *same session*), hub `runPaintJob` wrapper (inline direct pipeline also `+1`), surface placement (per-pixel raycast-snap = all 16 "snapped" valid), positioning/offsets (centered-on-good-spot still `+1`), occupancy/paint-over-paint (fresh-area offset still `+1`), up-vector inversion (fixed `frameFromHit`; outcome unchanged).

**Leading hypothesis.** The server's `MakePaint` accepts **one color per batch/stroke** (or dedups mixed-color blobs to one). Single-color = all persist; mixed-color = exactly one survives. **Not yet proven.**

**FIX TO TRY NEXT (top candidate, untested):** **Group pixels by color and flush each color as its OWN stroke.** i.e. quantize image colors, then for each color-group: bump `PaintSettings.Stroke`, `cachePaint` only that color's blobs, `sendToServer(WarnModule())`. ⚠️ A first attempt at this test crashed on a stray typo (`world + 1`) in the *test script* — fix that and rerun; the hub itself is fine.
- If it works → implement in `buildImage`/`runPaintJob` as a per-color multi-flush. Quantize image RGB (e.g. to nearest 16) to cap the number of flushes for photos.
- Also test whether **Rainbow Sweep** (also multi-color → its `+1` symptom matches LO's "rainbow deleted after 1s") is fixed by the same per-color flush.

**Other angles for #1:**
- Try the `Remotes.Paint.MakePaintNoCooldown` RemoteFunction (uninvestigated).
- Paint image on a **fresh/empty layer** (layer 2+) to test if a per-layer occupancy/cap contributes.
- Read `MakePaint:InvokeServer` return value / `sendToServer` return on a mixed batch for a server error string.

</details>

---

## 🟨 #2 — "Some of the fill/paint gets deleted"

**Status: mostly explained (engine + game trim), not fully a bug.**
- `PaintCount` = lifetime counter; the game **trims old paint** (2261 lifetime vs only ~27 live parts at one point). As you paint more, older blobs vanish → looks like partial deletion.
- Distinct simple blobs DO persist reliably right now (8/8, 4/4), so normal paint is healthy.
- **To-try:** confirm whether trimming is a global-per-player live cap, a per-layer cap, or region-based. If per-layer → distribute large fills across layers so fewer old ones get recycled at once.

---

## 🟨 #3 — Rainbow Sweep "deleted after ~1 second"

**Status: almost certainly the same root as #1** (rainbow sweep is many colors → multi-color batch → `+1`). Re-test after the group-by-color fix; likely self-resolves.

---

## 🟩 #4 — Neon / Chrome / Rainbow effects + Brush size > 1.2 (gamepass)

**Status: known limitation, server-enforced, NOT fixable client-side.**
- The hub/refusal gates them: `LocalPlayer.GamePasses.*` are all `false` for this account; server validates real ownership, so blobs with effect flags get rejected/stripped after the local preview flashes them (~1 s).
- **Proven no-fake:** setting `GamePasses` attrs `true` client-side then painting an effected/oversize blob → server still rejected both. The folder copy is cosmetic.
- Hub behavior: those toggles now **refuse with a status note** instead of silently reverting; size slider capped at the account max (**1.2**).

---

## 🟨 #5 — Hub wipes / stops working after re-inject or respawn

**Status: expected behavior, handled.**
- Re-injecting the executor connector or respawning clears `getgenv`, destroying the hub UI and its `getgenv().__SprayHub` state ("buttons do nothing").
- Dispel: re-run `sprayhub.luau` (it's re-exec safe — kills old UI/threads). Consider a tiny persistent loader that re-sources the script from a file/URL so a re-inject auto-reloads the hub.

---

## Verification cheatsheet (so we stop chasing ghosts)

- Read **non-`Client` `BasePart`s** under `workspace.PaintFolder[LocalPlayer.Name]` to count live paint.
- The `PaintCount` attribute **lags ~1–2 s** and is lifetime-cap inflated — a single early read after a job is a false negative. Wait, and read parts.
- Run multi-step tests on a genuinely **fresh, big, flat wall**, close (<40 studs), and note LO may move between runs (nearest-wall target shifts between runs — always print the hit position you used).
