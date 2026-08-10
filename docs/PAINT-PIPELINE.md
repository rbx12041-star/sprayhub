# Paint pipeline (reverse-engineered)

How "Spray Paint!" actually paints, from the decompiled client modules. Everything the hub does hangs off this.

## The real paint primitive
- The **wall paint** RemoteFunction is `ReplicatedStorage.Remotes.Paint.MakePaint`.
- It is invoked by the game's `Modules.Paint.ClientToServer.sendToServer(key1, key2)` as:
  ```lua
  MakePaint:InvokeServer(paintInfoArray --[[sorted by CreationTime]], key1, key2)
  ```
- `SprayServer` is **not** wall paint — it's only the spray-can particle/sound tool (`FireServer(bool, color)`).

## Each paint blob = an info table
Built by `Modules.Paint.MakePaint.getPaintInfoFromPaintSettings(paintSettings, cframe)`:
```lua
{
  PlayerName = LocalPlayer.Name,
  BrushShape = "Octagon" | "Square" | "Triangle",
  Size, Opacity, Layer, CFrame, Color,
  ChromeEnabled, NeonEnabled, RainbowEnabled,
  Stroke,
  CreationTime  -- set client-side = workspace:GetServerTimeNow()
}
```

## CFrame on the wall
`PaintPositioning.getCFrame(raycastResult)`:
```lua
CFrame.lookAt(hitPos, hitPos + hitNormal) * CFrame.Angles(-math.pi / 2, 0, 0)
```
Walls are tagged `PaintRaycast` and live under `workspace.Map.RaycastInstances` (raycast with `FilterType.Include`).

## Anticheat keys (required on every flush)
- `require(ReplicatedStorage.Modules.Print.WarnModule)` returns a callable → `local k1, k2 = WarnModule()`.
- `k1` is a timestamp float, `k2` a ~15-char token. The server validates them on `MakePaint`.
- `WarnModule` is a 530 KB control-flow-flattened VM — **do not hand-reverse; just `require` and call it** (works in current executor's require cache; the keys are valid server-side).

## The correct client flow (what the hub mirrors)
```lua
local PP  = require(RS.Modules.Paint.PaintPositioning)
local C2S = require(RS.Modules.Paint.ClientToServer)
local MP  = require(RS.Modules.Paint.MakePaint)
local WM  = require(RS.Modules.Print.WarnModule)
-- set PaintSettings (Layer, Size, Color, ...) then per blob:
local inst, info = MP.makePaintFromPaintSettings(PS, wallCFrame, true, nil, nil, nil)
if inst then C2S.cachePaint(inst, info) end
local k1, k2 = WM()
C2S.sendToServer(k1, k2)
```
Per stroke: bump `PaintSettings.Stroke += 1` and (optionally) `ReplicatedStorage.UndoRedoServer.LogUndoRedoEvent:InvokeServer({ Type = "Paint", Stroke = n })`.

## `PaintSettings`
An attribute folder on `LocalPlayer` (created by the PaintGui on join). Attributes: `BrushShape, Size, Opacity, Layer, Color, Stroke, Tool, Rotation, NeonEnabled, ChromeEnabled, RainbowEnabled, ClassicRainbow, EraseSize, ShapeToolSelection`.
⚠️ **The game periodically RESETS these to defaults (~every 1 s).** The hub re-asserts them per blob and runs an "enforce" loop so manual painting keeps your chosen size/color.

## Server-enforced caps (measured live; can't be bypassed client-side)
- `workspace` attributes:
  - `MaxSprayDistance = 40` (blobs must land within ~40 studs of your character)
  - `MaxNormalBrushSize = 1.2`, `MaxGamepassBrushSize = 2.2`
  - `MaxNormalLayers = 10`, `MaxGamepassLayers = 20`, `MaxTopArtistLayers = 30`
  - `MinSpacing = 0.075`, `MinDistanceMultiplierBetweenPaint = 0.35` → native blob spacing `max(size*0.35, 0.075)`
  - `PaintUpdateRate = 0.25` (flush cadence), `MaxPaintFPS = 160`
- **Brush Size > ~1.0–1.1 (up to the 1.2 UI cap):** requesting above the normal max makes the server **reject the blob** (vanish, not clamp). Cap your size UI at the account's real max.
- **Neon / Chrome / Rainbow effects:** gamepass-gated. Server checks real ownership (`LocalPlayer.GamePasses` attributes — **client-side flips do NOT fool the server**, proven empirically). There is a `Misc.GiveAllGamePasses` remote; it's almost certainly server-validated/mod-gated — **do not use it**.

## Tutorial/anticheat notes
- `LocalPlayer` attrs include `TimesBanned`, `AllTimePaint`, `SecondsPlayed`, `LastAutoModCheck`, `RankInGroup`. `TimesBanned > 0` may raise scrutiny — keep cadence sane, don't spam.
- `ReplicatedStorage.Remotes.Paint.MakePaintNoCooldown` exists (uninvestigated — possibly a no-rate-limit variant).

## CRITICAL: `PaintCount` is a LIFETIME counter, not live parts
- `workspace.PaintFolder[PlayerName][Layer]:GetAttribute("PaintCount")` is a cumulative "ever placed" number.
- The number of **live** paint parts is much smaller — the game **trims old paint** aggressively (observed: lifetime ~2261 but only ~27 live parts). So **aiming/painting enough makes older blobs vanish** ("deletion" reports were this, not a hub bug).
- **Verify with actual parts**, not the attribute: read non-`Client` `BasePart`s under the player folder (the attribute also lags ~1–2 s and caused many false "it didn't paint" reads).
