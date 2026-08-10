# ⚡ SprayHub

An auto-paint script hub for the Roblox game **"Spray Paint!"** (placeId `5991163185`).

Instead of hand-forging remotes, SprayHub **rides the game's own paint pipeline** — it calls the exact same client modules the real spray-can UI uses (`makePaintFromPaintSettings` → `cachePaint` → `sendToServer`), fetching a fresh anticheat token pair from the game's obfuscated `WarnModule` on every flush. To the server it looks like a normal player painting — because mechanically it is.

> Private dev repo. This is the in-progress project of [@Sebiy](https://github.com/Sebiy) + collaborators. If you were added here to help: read **`CONTRIBUTING.md`** (the organized workflow) → **`docs/ISSUES.md`** (what's broken) → **`docs/SETUP-AGENT.md`** (recreate the agent loop on your machine). Note what you try in `LOG.md` using `docs/LOG-template.md`, and file tracked work as an Issue.

---

## What's in here

| File | What it is |
|---|---|
| `sprayhub.luau` | **The hub.** Paste/inject into an executor in-game. Builds a draggable in-game UI (RightCtrl / F4 to toggle) and drives paint through the game's own modules. |
| `img2grid.js` | **URL → wall-image decoder (Node).** Downloads a PNG, decodes it (inflate + unfilter, no deps), downscales, and emits a Luau pixel table the hub can paint. Run `node img2grid.js <url> [maxW] [maxH]`. |
| `CONTRIBUTING.md` | **The organized workflow** — branches, PRs, what to update when, do/don't. Read this before pushing anything. |
| `docs/SETUP-AGENT.md` | How a helper runs **their own agent + in-game bridge** to recreate this build loop (drive the client from an LLM). |
| `docs/PAINT-PIPELINE.md` | Full technical reference: the reversed paint pipeline, anticheat keys, server caps, paint-trim behavior. Read this before touching paint code. |
| `docs/ISSUES.md` | **What's not working** + every fix already tried + the fixes to try next. The single source of truth for open bugs. |
| `docs/LOG-template.md` | A template friends copy into `LOG.md` to record what they tried, or to file requests/ideas. |
| `LOG.md` | The running log of attempts + requests from everyone helping. |
| `CHANGELOG.md` | What changed, version to version. |
| `.github/ISSUE_TEMPLATE/*` | Structured forms for **bug/tried** and **idea/request** so tracked work stays tidy. |

---

## Current status (as of 2026-08-10)

**Working ✅**
- Brush: color swatches, size (capped to the normal max **1.2**), opacity, layer, Octagon/Square/Triangle.
- **Fill Region, Draw Pattern** (Heart / Smiley / Checker / Flag), **Rainbow Sweep**, **Spray Spam** — all paint & server-persist (visible to everyone).
- **Erase My Paint** (server-side), **Stop All**, **Enforce Brush** (keeps your manual-brush settings against the game's 1 s reset).
- URL image pipeline (decode + grid + cursor preview + paint) is **built** — see blockers below.

**Blocked / known issues ❌** (details + all attempts in `docs/ISSUES.md`)
- **Multi-color batches persist only ~1 blob.** Single-color batches persist perfectly; a mixed-color batch (image, rainbow) yields ~1. This is THE open bug for the image painter.
- Neon / Chrome / Rainbow / Brush sizes > **1.2** are **gamepass-locked** and **cannot** be faked client-side (proven — server validates real ownership).
- Game aggressively **trims old paint** — a big lifetime paint count means older blobs get recycled (looks like "deletion").

---

## Quick start

### 1. Load the hub
Run `sprayhub.luau` in your executor while in-game. A panel appears; press **RightCtrl** or **F4** to hide/show.

### 2. Use it
1. Stand **within ~40 studs** of a wall and **look at it**.
2. Pick a brush color/size, then click a Draw button.
3. Big jobs take a few seconds (the hub respects the game's 0.25 s flush cadence) — the status bar shows the blob count when done.

### 3. Paint a URL image (currently in-progress)
1. Run `node img2grid.js <image-url> 40 36 > imgdata.luau` (Node 18+; PNG only for now).
2. Inject `imgdata.luau` in-game (sets `getgenv().__imgdata`).
3. In the hub, toggle **Cursor Preview** → a square follows your mouse on the wall.
4. Click **🖼 Paint Image Here**.
   - ⚠️ Known blocker: multi-color batches only persist ~1 blob right now. See `docs/ISSUES.md`.

---

## Dev notes
- The non-destructive engine, wall-picking (`aimFrame` camera / `cursorHit` mouse), and anticheat-key fetch are all in `sprayhub.luau`. Read `docs/PAINT-PIPELINE.md` first — everything is sever-enforced within ~40 studs, and `PaintCount` is a *lifetime* counter, not live parts.
- Text-only verification tip: `PaintCount` and replication lag ~1–2 s; read actual non-`Client` paint `BasePart`s under `workspace.PaintFolder[LocalPlayer.Name]` to verify, not the attribute alone (it lags and caused repeated false "it didn't paint" reads).

## Credits
Built with extensive live reverse-engineering of the game's client modules (executed in-session via an in-game MCP bridge). Paint pipeline + constraints documented in `docs/PAINT-PIPELINE.md`.
