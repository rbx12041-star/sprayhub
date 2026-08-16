-- Functional test for the VIM input mode in sprayhub.luau.
-- Extracts the colorKey + VIM block out of the hub, runs it against stubs,
-- and asserts the synthetic input stream looks like human strokes:
--   auto-equip, calibrate, press-move-release per color run, pen lifts on gaps.
--
-- GOTCHA (found 2026-08-16): lune's luau.load sandboxes chunk globals with
-- stale reads (write escapes, reads inside the chunk see load-time copies).
-- So deps must be passed as explicit locals (function args), not via globals.
local fs = require("@lune/fs")

local src = fs.readFile("sprayhub.luau")

-- extract: colorKey 1-liner through the end of vimPaintJob (up to runPaintJob)
local block = src:match([==[(local function colorKey.-local function vimPaintJob.-coroutine%.resume%(t%)
end)
]==])
assert(block, "could not extract VIM block from sprayhub.luau")

-- ---- stubs -----------------------------------------------------------------
local vec2mt, vec3mt = {}, {}
local function Vec2(x, y)
	local v = setmetatable({ X = x, Y = y }, vec2mt)
	v.Magnitude = math.sqrt(x * x + y * y)
	return v
end
local function Vec3(x, y, z)
	local v = setmetatable({ X = x, Y = y, Z = z }, vec3mt)
	v.Magnitude = math.sqrt(x * x + y * y + z * z)
	return v
end
vec2mt.__sub = function(a, b) return Vec2(a.X - b.X, a.Y - b.Y) end
vec3mt.__sub = function(a, b) return Vec3(a.X - b.X, a.Y - b.Y, a.Z - b.Z) end
vec2mt.__index = vec2mt

local vimEvents = {} -- {{"move",x,y}, {"press",x,y,down}, ...}
local lastStatus = ""
local equipped = false

-- world->screen: pin world x/y to screen with scale 50 px/stud
local deps = {
	Vector2 = { new = Vec2 },
	Vector3 = { new = Vec3 },
	Color3 = { fromRGB = function(r, g, b) return { R = r / 255, G = g / 255, B = b / 255 } end },
	VIM = {
		SendMouseMoveEvent = function(_, x, y) table.insert(vimEvents, { "move", x, y }) end,
		SendMouseButtonEvent = function(_, x, y, btn, down) table.insert(vimEvents, { "press", x, y, down }) end,
	},
	UIS = { GetMouseLocation = function() return Vec2(420, 320) end }, -- calib sends (420,320): offset 0
	RunSvc = { RenderStepped = { Wait = function() end } },
	workspace = {
		CurrentCamera = {
			ViewportSize = Vec2(1280, 720),
			WorldToViewportPoint = function(_, pos) return Vec3(640 + pos.X * 50, 360 + pos.Y * 50, 10) end,
		},
	},
	MIN_SPACING = 0.075,
	Hub = { vimDown = false, enforce = false, human = false, painted = 0, threads = {} },
	Brush = { color = { R = 1, G = 0, B = 0 }, size = 0.6, shape = "Octagon", opacity = 1 },
	setStatus = function(s) print("STATUS:", s) lastStatus = s end,
	applyBrush = function() end,
	currentColor = function() return { R = 1, G = 0, B = 0 } end,
	task = require("@lune/task"),
}
-- LP: holding no tool; Backpack has "SprayPaint" -> expect EquipTool call
local tool = { Name = "SprayPaint", IsA = function(_, c) return c == "Tool" end }
local backpack = { GetChildren = function() return { tool } end }
deps.LP = {
	Character = {
		GetChildren = function() return {} end, -- holding no tool
		FindFirstChildOfClass = function() return { EquipTool = function() equipped = true end } end,
	},
	FindFirstChild = function(_, name) return name == "Backpack" and backpack or nil end,
}

-- ---- run: wrap block so deps arrive as locals (lune global sandbox is stale) --
local wrapped = ([==[return function(deps)
	local Vector2, Color3, VIM, UIS, RunSvc, workspace = deps.Vector2, deps.Color3, deps.VIM, deps.UIS, deps.RunSvc, deps.workspace
	local MIN_SPACING, Hub, Brush, setStatus, applyBrush, currentColor = deps.MIN_SPACING, deps.Hub, deps.Brush, deps.setStatus, deps.applyBrush, deps.currentColor
	local LP, task, game = deps.LP, deps.task, deps.game
]==]) .. block .. [==[
	return vimPaintJob
end
]==]
local vimPaintJob = require("@lune/luau").load(wrapped)()(deps)

-- fake job: 2 colors x 4 blobs; color A clustered (no lift), color B has a
-- 2-stud world gap between #2/#3 (well above 0.6*2.2 = 1.32 -> lift expected)
local blobs = {}
for i = 0, 3 do table.insert(blobs, { cf = { Position = Vec3(i * 0.7, 0, 0) }, color = { R = 1, G = 0, B = 0 } }) end
for i = 0, 3 do table.insert(blobs, { cf = { Position = Vec3(i * 0.7 + (i >= 2 and 2 or 0), 3, 0) }, color = { R = 0, G = 0, B = 1 } }) end

vimPaintJob(blobs)
-- lune schedules yielded coroutines async: drain until the job reports done
local t0 = os.clock()
while lastStatus:sub(1, 8) ~= "VIM done" and os.clock() - t0 < 10 do deps.task.wait(0.1) end

-- ---- assertions ------------------------------------------------------------
local moves, downCount, upCount = 0, 0, 0
for _, e in ipairs(vimEvents) do
	if e[1] == "press" then if e[4] then downCount += 1 else upCount += 1 end
	else moves += 1 end
end

-- expect: calibrate move + paints; 2 runs x press+release + 1 lift pair = down 3, up 3
assert(equipped, "spray tool was not auto-equipped")
assert(downCount == 3 and upCount == 3, ("expected 3 press-down + 3 release, got %d/%d"):format(downCount, upCount))
assert(moves >= 1 + 8, "expected at least calibrate + one move per painted point")
assert(deps.Hub.vimDown == false, "mouse left held down at job end")
assert(deps.Hub.enforce == false, "enforce flag not restored")
assert(deps.Brush.color.R == 1 and deps.Brush.color.G == 0, "brush color not restored")
print(("OK: %d press-downs, %d releases, %d moves, tool equipped"):format(downCount, upCount, moves))
