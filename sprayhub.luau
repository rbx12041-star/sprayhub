--[[
  SprayHub v2 — auto paint hub for "Spray Paint!" (placeId 5991163185)
  Rides the game's OWN paint pipeline (no hand-forged remotes):
    set PaintSettings attrs (re-asserted per blob) -> makePaintFromPaintSettings
    -> cachePaint -> sendToServer( WarnModule() keys ) -> server persists.

  Hard facts measured live on this account (2026-08-10):
    * brush Size cap ~1.0 — requesting more makes the server REJECT the blob
      (LargerSizes gamepass not owned) -> cap slider at 1.0.
    * Neon/Chrome/Rainbow are gamepass-gated and get stripped -> refused with a note.
    * the game periodically RESETS PaintSettings to defaults -> re-assert attrs
      per blob for jobs, and an "enforce" loop keeps your manual-brush settings sticky.
    * MaxSprayDistance ~40 — blobs must land within ~40 studs of your character.
  Re-exec safe: kills the previous UI + threads.
--]]

--// Re-exec cleanup --------------------------------------------------------
if getgenv().__SprayHub then
	pcall(function() getgenv().__SprayHub.stopAll() end)
	pcall(function() getgenv().__SprayHub.gui:Destroy() end)
end

--// Services / env ----------------------------------------------------------
local RS       = game:GetService("ReplicatedStorage")
local Players  = game:GetService("Players")
local CS       = game:GetService("CollectionService")
local RunSvc   = game:GetService("RunService")
local UIS      = game:GetService("UserInputService")
local LP       = Players.LocalPlayer
local PlayerGui= LP:WaitForChild("PlayerGui")

local PaintPositioning = require(RS.Modules.Paint.PaintPositioning)
local ClientToServer   = require(RS.Modules.Paint.ClientToServer)
local MakePaint        = require(RS.Modules.Paint.MakePaint)
local WarnModule       = require(RS.Modules.Print.WarnModule)
local UndoRedo         = RS:FindFirstChild("UndoRedoServer") and RS.UndoRedoServer:FindFirstChild("LogUndoRedoEvent")
local MouseMod         = require(RS.Modules.Mouse.Mouse)

local MAX_DIST   = workspace:GetAttribute("MaxSprayDistance") or 40
local MIN_SPACING= workspace:GetAttribute("MinSpacing") or 0.075
local DIST_MULT  = workspace:GetAttribute("MinDistanceMultiplierBetweenPaint") or 0.35
local FLUSH_RATE = workspace:GetAttribute("PaintUpdateRate") or 0.25
local SIZE_CAP   = 1.2 -- LO's UI cap w/o LargerSizes pass; above this server drops blobs.

local PS = LP:WaitForChild("PaintSettings")

-- gamepass ownership for effects
local GP = LP:FindFirstChild("GamePasses")
local function owns(attr) return GP and GP:GetAttribute(attr) == true end

--// State -------------------------------------------------------------------
local Hub = { gui = nil, threads = {}, stopped = false, painted = 0, enforce = true }
getgenv().__SprayHub = Hub

function Hub.stopAll()
	Hub.stopped = true
	for _, co in ipairs(Hub.threads) do pcall(task.cancel, co) end
	Hub.threads = {}
	Hub.stopped = false
end

--// Brush config ------------------------------------------------------------
local Brush = {
	color = Color3.fromRGB(255, 0, 0),
	size = 0.6,
	shape = "Octagon",
	layer = 1,
	opacity = 1,
	neon = false, chrome = false, rainbow = false,
}
local function currentColor() return Brush.color end
local function applyBrush()
	Brush.size = math.clamp(Brush.size, 0.1, SIZE_CAP)
	PS:SetAttribute("Color", Brush.color)
	PS:SetAttribute("Size", Brush.size)
	PS:SetAttribute("BrushShape", Brush.shape)
	PS:SetAttribute("Layer", Brush.layer)
	PS:SetAttribute("Opacity", Brush.opacity)
	PS:SetAttribute("NeonEnabled", Brush.neon)
	PS:SetAttribute("ChromeEnabled", Brush.chrome)
	PS:SetAttribute("RainbowEnabled", Brush.rainbow)
	PS:SetAttribute("Rotation", "Fixed")
end

--// World helpers -----------------------------------------------------------
local function charPos()
	local c = LP.Character
	return c and c:GetPivot().Position or nil
end
local function faceCFrame(pos, normal)
	return CFrame.lookAt(pos, pos + normal) * CFrame.Angles(-math.pi / 2, 0, 0)
end

-- aim-centered frame on the wall the player is LOOKING at (fallback char fwd, then nearest)
local function aimFrame()
	local params = PaintPositioning.getRaycastParams()
	local root = charPos()
	local cam = workspace.CurrentCamera
	local candidates = {}
	if cam then table.insert(candidates, { cam.CFrame.Position, cam.CFrame.LookVector * MAX_DIST }) end
	if root and LP.Character then
		table.insert(candidates, { root, LP.Character:GetPivot().LookVector * MAX_DIST })
		table.insert(candidates, { root, Vector3.new(0, -1, 0) * MAX_DIST }) -- floor
	end
	-- nearest fallback
	local bestP, bestD
	if root then
		for _, p in ipairs(CS:GetTagged("PaintRaycast")) do
			if p:IsA("BasePart") then
				local d = (p.Position - root).Magnitude
				if not bestD or d < bestD then bestD, bestP = d, p end
			end
		end
	end

	local hits = {}
	for _, r in ipairs(candidates) do
		local hit = workspace:Raycast(r[1], r[2], params)
		if hit and hit.Instance:HasTag("PaintRaycast") then table.insert(hits, hit) end
	end
	if #hits == 0 and bestP and root then
		local hit = workspace:Raycast(root, (bestP.Position - root).Unit * MAX_DIST, params)
		if hit and hit.Instance:HasTag("PaintRaycast") then table.insert(hits, hit) end
	end
	local hit = hits[1]
	if not hit then return nil end
	local n = hit.Normal
	local up = Vector3.yAxis
	if math.abs(n:Dot(up)) > 0.999 then up = Vector3.xAxis end
	up = (up - n * up:Dot(n)).Unit
	local right = n:Cross(up).Unit
	return { origin = hit.Position, normal = n, right = right, up = up, dist = hit.Distance, part = hit.Instance }
end

local function blobCFrame(f, u, v)
	local root = charPos()
	local world = f.origin + f.right * u + f.up * v
	if root and (world - root).Magnitude > MAX_DIST * 0.97 then return nil end
	return faceCFrame(world, f.normal)
end

-- set EVERY attr right before the make (beats the game's periodic PaintSettings reset)
local function paintBlob(cf, color)
	PS:SetAttribute("Color", color)
	PS:SetAttribute("Size", math.clamp(Brush.size, 0.1, SIZE_CAP))
	PS:SetAttribute("BrushShape", Brush.shape)
	PS:SetAttribute("Layer", Brush.layer)
	PS:SetAttribute("Opacity", Brush.opacity)
	PS:SetAttribute("NeonEnabled", Brush.neon)
	PS:SetAttribute("ChromeEnabled", Brush.chrome)
	PS:SetAttribute("RainbowEnabled", Brush.rainbow)
	local inst, info = MakePaint.makePaintFromPaintSettings(PS, cf, true, nil, nil, nil)
	if inst then ClientToServer.cachePaint(inst, info) end
	return inst ~= nil
end
local function flush()
	local k1, k2 = WarnModule()
	ClientToServer.sendToServer(k1, k2)
end

local function runPaintJob(blobList, opts)
	opts = opts or {}
	local batch = opts.batch or 40
	local t = coroutine.create(function()
		PS:SetAttribute("Stroke", (PS:GetAttribute("Stroke") or 0) + 1)
		if UndoRedo then pcall(function() UndoRedo:InvokeServer({ Type = "Paint", Stroke = PS:GetAttribute("Stroke") }) end) end
		local made = 0
		for i, b in ipairs(blobList) do
			if Hub.stopped then break end
			if b.cf and paintBlob(b.cf, b.color or currentColor()) then made = made + 1 Hub.painted = Hub.painted + 1 end
			if made % batch == 0 then flush() task.wait(FLUSH_RATE) end
			task.wait()
		end
		flush()
		setStatus(("done: %d blobs (session %d)"):format(made, Hub.painted))
	end)
	table.insert(Hub.threads, t)
	coroutine.resume(t)
end

-- enforce manual-brush stickiness (game resets PaintSettings ~every 1s)
table.insert(Hub.threads, coroutine.create(function()
	while true do
		task.wait(0.25)
		if Hub.stopped then break end
		if Hub.enforce then pcall(applyBrush) end
	end
end))
coroutine.resume(Hub.threads[#Hub.threads])

--// Grid builders -----------------------------------------------------------
local function gridStep() return math.max(Brush.size * DIST_MULT, MIN_SPACING, 0.12) end
local function buildFill(halfW, halfH)
	local f = aimFrame(); if not f then setStatus("look at a wall first") return {} end
	halfW = halfW or 2; halfH = halfH or 2
	local step = gridStep()
	local list = {}
	local nx, ny = math.floor(halfW * 2 / step), math.floor(halfH * 2 / step)
	for ix = 0, nx do
		for iy = 0, ny do
			local cf = blobCFrame(f, -halfW + ix * step, -halfH + iy * step)
			if cf then table.insert(list, { cf = cf, color = Brush.color }) end
		end
	end
	return list
end
local function buildPattern(grid, charMap, cell)
	local f = aimFrame(); if not f then setStatus("look at a wall first") return {} end
	cell = cell or math.max(Brush.size * 0.9, 0.2)
	local rows = #grid
	local cols = 0
	for _, r in ipairs(grid) do cols = math.max(cols, #r) end
	local list = {}
	for iy = 1, rows do
		for ix = 1, #grid[iy] do
			local col = charMap[grid[iy]:sub(ix, ix)]
			if col then
				local cf = blobCFrame(f, (ix - cols / 2) * cell, -(iy - rows / 2) * cell)
				if cf then table.insert(list, { cf = cf, color = col }) end
			end
		end
	end
	return list
end
local function hsvRainbow(a) return Color3.fromHSV(a % 1, 0.9, 1) end
local function buildRainbow(maxW, maxH)
	local f = aimFrame(); if not f then setStatus("look at a wall first") return {} end
	maxW = maxW or 3; maxH = maxH or 3
	local step = gridStep()
	local list = {}
	local nx, ny = math.floor(maxW * 2 / step), math.floor(maxH * 2 / step)
	for ix = 0, nx do
		local col = hsvRainbow(ix / nx)
		for iy = 0, ny do
			local cf = blobCFrame(f, -maxW + ix * step, -maxH + iy * step)
			if cf then table.insert(list, { cf = cf, color = col }) end
		end
	end
	return list
end
local function buildSpraySpam(n, maxW, maxH)
	local f = aimFrame(); if not f then setStatus("look at a wall first") return {} end
	maxW = maxW or 2.5; maxH = maxH or 2.5
	local list = {}
	math.randomseed(os.time() + os.clock())
	for _ = 1, (n or 120) do
		local u = (math.random() * 2 - 1) * maxW
		local v = (math.random() * 2 - 1) * maxH
		local cf = blobCFrame(f, u, v)
		if cf then table.insert(list, { cf = cf, color = Brush.rainbow and hsvRainbow(math.random()) or Brush.color }) end
	end
	return list
end

--// Image paint: cursor-following preview + pixel-grid painting -------------
local Image = { enabled = false, previewOn = false, cell = 0.6, frame = nil, part = nil, urlBox = nil }

-- orthonormal wall frame from a ray hit (right/up on the surface)
local function frameFromHit(hit)
	local n = hit.Normal
	local up = Vector3.yAxis - n * n:Dot(Vector3.yAxis)
	if up.Magnitude < 0.01 then up = Vector3.xAxis end
	up = up.Unit
	local right = up:Cross(n).Unit
	return { center = hit.Position, normal = n, right = right, up = up }
end

-- raycast to the wall under the CURSOR (like the real game's aim)
local function cursorHit()
	local params = PaintPositioning.getRaycastParams()
	local mp = MouseMod.getMousePosition()
	local hit = MouseMod.raycastFromScreenPoint(params, mp, 1000)
	if hit and hit.Instance and hit.Instance:HasTag("PaintRaycast") then
		local root = charPos()
		if root and (hit.Position - root).Magnitude <= MAX_DIST then return hit end
	end
	return nil
end

local function updatePreview()
	local data = getgenv().__imgdata
	if not (Image.previewOn and data and data.w) then
		if Image.part then Image.part.Transparency = 1 end
		return
	end
	local hit = cursorHit()
	if hit then
		Image.frame = frameFromHit(hit)
		local fw, fh = data.w * Image.cell, data.h * Image.cell
		if not Image.part then
			local part = Instance.new("Part")
			part.Anchored = true
			part.CanCollide = false
			part.CanQuery = false
			part.CastShadow = false
			part.Material = Enum.Material.Neon
			part.Color = Color3.fromRGB(120, 90, 220)
			Image.part = part
		end
		Image.part.Size = Vector3.new(fw, fh, 0.2)
		Image.part.Transparency = 0.5
		local f = Image.frame
		Image.part.CFrame = CFrame.fromMatrix(f.center + f.normal * 0.15, f.right, f.up)
		if Image.part.Parent ~= workspace then Image.part.Parent = workspace end
	else
		if Image.part then Image.part.Transparency = 1 end
	end
end
RunSvc.RenderStepped:Connect(updatePreview)

-- build blob list from getgenv().__imgdata at a given wall frame
local function buildImage(f)
	local data = getgenv().__imgdata
	if not (data and data.px and data.w and data.h) then return nil, "no image loaded" end
	f = f or Image.frame or (function() local h = cursorHit() if h then return frameFromHit(h) end end)()
	if not f then return nil, "aim at a wall (hold preview)" end
	local cell = Image.cell
	local params = PaintPositioning.getRaycastParams()
	local root = charPos()
	local list = {}
	local colW, colH = data.w, data.h
	-- per-pixel ray to snap onto the real paintable surface (skips off-wall pixels)
	for _, e in ipairs(data.px) do
		local px, py, rgb = e[1], e[2], e[3]
		local r = math.floor(rgb / 65536) % 256
		local g = math.floor(rgb / 256) % 256
		local b = rgb % 256
		local target = f.center + f.right * ((px - colW / 2) * cell) + f.up * (-(py - colH / 2) * cell)
		local hit = workspace:Raycast(target + f.normal * 0.6, -f.normal * 1.6, params)
		if hit and hit.Instance:HasTag("PaintRaycast") then
			if not root or (hit.Position - root).Magnitude <= MAX_DIST * 0.97 then
				table.insert(list, { cf = faceCFrame(hit.Position, hit.Normal), color = Color3.fromRGB(r, g, b) })
			end
		end
	end
	return list
end

local function paintImage()
	local list, err = buildImage()
	if not list then setStatus(err) return end
	if #list == 0 then setStatus("nothing in range / too far") return end
	runPaintJob(list, { batch = 40 })
end

--// Pattern presets ---------------------------------------------------------
local W, K, R, B, Y =
	Color3.fromRGB(255,255,255), Color3.fromRGB(15,15,15), Color3.fromRGB(255,0,35),
	Color3.fromRGB(40,120,255), Color3.fromRGB(255,220,0)
local Presets = {
	Heart   = { grid = {".##.##.","#######","#######",".#####.","..###..","...#..."}, map = {["#"]=R} },
	Smiley  = { grid = {".####.","#K##K#","######","#K##K#","#.KK.#",".#KK#."}, map = {["K"]=Y} },
	Checker = { grid = {"WBWBWB","BWBWBW","WBWBWB","BWBWBW","WBWBWB","BWBWBW"}, map = {["W"]=W, ["B"]=K} },
	Flag    = { grid = {"RRR","WWW","BBB","RRR","WWW","BBB"}, map = {["R"]=R, ["W"]=W, ["B"]=B} },
}
local PresetOrder = { "Heart", "Smiley", "Checker", "Flag" }

--// UI ----------------------------------------------------------------------
local function new(class, props, parent)
	local o = Instance.new(class)
	for k, v in pairs(props) do o[k] = v end
	if parent then o.Parent = parent end
	return o
end
local function corner(p, r) new("UICorner", { CornerRadius = UDim.new(0, r or 6) }, p) end
local function pad(p, l, t, r, b) new("UIPadding", { PaddingLeft=UDim.new(0,l or 8), PaddingTop=UDim.new(0,t or 6), PaddingRight=UDim.new(0,r or 8), PaddingBottom=UDim.new(0,b or 6) }, p) end
local BG, BG2, ACC, TXT, DIM = Color3.fromRGB(22,23,27), Color3.fromRGB(32,34,40), Color3.fromRGB(120,90,220), Color3.fromRGB(235,236,240), Color3.fromRGB(150,152,160)

local sg = new("ScreenGui", { Name = "SprayHubV2", ResetOnSpawn = false, DisplayOrder = 999, IgnoreGuiInset = true }, PlayerGui)
Hub.gui = sg
local main = new("Frame", { Size = UDim2.new(0, 340, 0, 540), Position = UDim2.new(0.5, -170, 0.5, -270), BackgroundColor3 = BG, BorderSizePixel = 0, Active = true, Draggable = true }, sg)
corner(main, 10); new("UIStroke", { Color = ACC, Thickness = 1, Transparency = 0.4 }, main)
local title = new("TextLabel", { Size = UDim2.new(1, -60, 0, 34), BackgroundTransparency = 1, Text = "⚡ SprayHub v2", TextColor3 = ACC, Font = Enum.Font.GothamBold, TextSize = 15, TextXAlignment = Enum.TextXAlignment.Left }, main)
pad(title, 12, 0, 0, 0)
local statusLbl = new("TextLabel", { Size = UDim2.new(1, -16, 0, 18), Position = UDim2.new(0, 8, 1, -22), BackgroundTransparency = 1, Text = "ready", TextColor3 = DIM, Font = Enum.Font.Gotham, TextSize = 11, TextXAlignment = Enum.TextXAlignment.Left }, main)
function setStatus(sx) statusLbl.Text = tostring(sx) end
Hub.setStatus = setStatus
local closeB = new("TextButton", { Size = UDim2.new(0, 26, 0, 26), Position = UDim2.new(1, -30, 0, 4), BackgroundColor3 = BG2, BorderSizePixel = 0, Text = "✕", TextColor3 = TXT, Font = Enum.Font.GothamBold, TextSize = 12 }, main)
corner(closeB, 6); closeB.MouseButton1Click:Connect(function() Hub.stopAll() sg:Destroy() end)
local scroll = new("ScrollingFrame", { Size = UDim2.new(1, -12, 1, -66), Position = UDim2.new(0, 6, 0, 40), BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 4, CanvasSize = UDim2.new(0, 0, 0, 0), AutomaticCanvasSize = Enum.AutomaticSize.Y }, main)
new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, scroll)
pad(scroll, 6, 2, 6, 6)

local function section(name) new("TextLabel", { Size = UDim2.new(1,0,0,20), BackgroundTransparency = 1, Text = name:upper(), TextColor3 = ACC, Font = Enum.Font.GothamBold, TextSize = 11, TextXAlignment = Enum.TextXAlignment.Left }, scroll) end
local function btn(text, cb)
	local b = new("TextButton", { Size = UDim2.new(1,0,0,30), BackgroundColor3 = BG2, BorderSizePixel = 0, Text = text, TextColor3 = TXT, Font = Enum.Font.Gotham, TextSize = 12, AutoButtonColor = true }, scroll)
	corner(b, 6); b.MouseButton1Click:Connect(function() cb(b) end)
	return b
end
local function toggle(label, get, set)
	local b = new("TextButton", { Size = UDim2.new(1,0,0,28), BackgroundColor3 = BG2, BorderSizePixel = 0, Font = Enum.Font.Gotham, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Left }, scroll)
	corner(b, 6); pad(b, 10, 0, 10, 0)
	local function refresh()
		b.Text = ("%-22s %s"):format(label, get() and "● ON" or "○ off")
		b.TextColor3 = get() and Color3.fromRGB(120,255,150) or DIM
	end
	b.MouseButton1Click:Connect(function() set(not get()) refresh() applyBrush() end)
	refresh()
	return b
end
local function effectToggle(label, gpAttr, get, set)
	local b = new("TextButton", { Size = UDim2.new(1,0,0,28), BackgroundColor3 = BG2, BorderSizePixel = 0, Font = Enum.Font.Gotham, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Left }, scroll)
	corner(b, 6); pad(b, 10, 0, 10, 0)
	local function refresh() b.Text = ("%-22s %s"):format(label, get() and "● ON" or "○ off") b.TextColor3 = get() and Color3.fromRGB(120,255,150) or DIM end
	b.MouseButton1Click:Connect(function()
		if not get() and not owns(gpAttr) then setStatus(label .. " needs the gamepass (server strips it)") set(false) refresh() return end
		set(not get()) refresh() applyBrush()
	end)
	refresh()
	return b
end
local function slider(label, min, max, get, set, fmt)
	local frame = new("Frame", { Size = UDim2.new(1,0,0,40), BackgroundColor3 = BG2, BorderSizePixel = 0 }, scroll)
	corner(frame, 6); pad(frame, 10, 6, 10, 6)
	new("TextLabel", { Size = UDim2.new(0.55,0,0,14), BackgroundTransparency = 1, Text = label, TextColor3 = DIM, Font = Enum.Font.Gotham, TextSize = 11, TextXAlignment = Enum.TextXAlignment.Left }, frame)
	local val = new("TextLabel", { Size = UDim2.new(0.45,0,0,14), Position = UDim2.new(0.55,0,0,0), BackgroundTransparency = 1, Text = "", TextColor3 = TXT, Font = Enum.Font.GothamBold, TextSize = 11, TextXAlignment = Enum.TextXAlignment.Right }, frame)
	local bar = new("Frame", { Size = UDim2.new(1,0,0,10), Position = UDim2.new(0,0,0,20), BackgroundColor3 = Color3.fromRGB(15,16,19), BorderSizePixel = 0 }, frame)
	corner(bar, 5)
	local fill = new("Frame", { BackgroundColor3 = ACC, BorderSizePixel = 0 }, bar)
	corner(fill, 5)
	local function refresh() local v = get() local a = math.clamp((v-min)/(max-min),0,1) fill.Size = UDim2.new(a,0,1,0) val.Text = (fmt or "%.2f"):format(v) end
	bar.InputBegan:Connect(function(io) if io.UserInputType == Enum.UserInputType.MouseButton1 then local a = math.clamp((io.Position.X - bar.AbsolutePosition.X)/math.max(bar.AbsoluteSize.X,1),0,1) set(min + (max-min)*a) refresh() applyBrush() end end)
	refresh()
	return frame
end

-- color
section "Brush"
local swatch = new("Frame", { Size = UDim2.new(1,0,0,30), BackgroundTransparency = 1 }, scroll)
new("UIGridLayout", { CellSize = UDim2.new(0,30,0,30), CellPadding = UDim2.new(0,6,0,6), SortOrder = Enum.SortOrder.LayoutOrder }, swatch)
for _, c in ipairs({Color3.fromRGB(255,0,0),Color3.fromRGB(255,150,0),Color3.fromRGB(255,230,0),Color3.fromRGB(0,200,80),Color3.fromRGB(0,200,220),Color3.fromRGB(40,120,255),Color3.fromRGB(150,60,255),Color3.fromRGB(220,60,200),Color3.fromRGB(255,255,255),Color3.fromRGB(15,15,15),Color3.fromRGB(160,100,60),Color3.fromRGB(255,160,180)}) do
	local s = new("TextButton", { BackgroundColor3 = c, BorderSizePixel = 0, Text = "", AutoButtonColor = true }, swatch)
	corner(s, 6); new("UIStroke", { Color = TXT, Thickness = 1, Transparency = 0.7 }, s)
	s.MouseButton1Click:Connect(function() Brush.color = c applyBrush() setStatus("color set") end)
end
slider("Brush Size (cap 1.0)", 0.1, SIZE_CAP, function() return Brush.size end, function(v) Brush.size = v end, "%.2f")
slider("Opacity", 0.1, 1, function() return Brush.opacity end, function(v) Brush.opacity = v end, "%.2f")
slider("Layer", 1, 10, function() return Brush.layer end, function(v) Brush.layer = math.floor(v+0.5) end, "%d")
btn("Shape: Octagon", function(b)
	local order = { "Octagon", "Square", "Triangle" }
	for i, s in ipairs(order) do if s == Brush.shape then Brush.shape = order[i % #order + 1] break end end
	b.Text = "Shape: " .. Brush.shape; applyBrush()
end)
toggle("Enforce Brush (manual paint)", function() return Hub.enforce end, function(v) Hub.enforce = v end)
effectToggle("Neon", "NeonPaint", function() return Brush.neon end, function(v) Brush.neon = v end)
effectToggle("Chrome", "ChromePaint", function() return Brush.chrome end, function(v) Brush.chrome = v end)
effectToggle("Rainbow", "RainbowPaint", function() return Brush.rainbow end, function(v) Brush.rainbow = v end)

-- draw
section "Draw (aims at wall you're facing)"
btn("▦ Fill Region", function() runPaintJob(buildFill(2, 2)) end)
local patternIdx = 1
btn("Pattern: Heart", function(b) patternIdx = patternIdx % #PresetOrder + 1 b.Text = "Pattern: " .. PresetOrder[patternIdx] end)
btn("🖌 Draw Pattern", function() local p = Presets[PresetOrder[patternIdx]] if p then runPaintJob(buildPattern(p.grid, p.map, math.max(Brush.size, 0.3))) end end)
btn("🌈 Rainbow Sweep", function() runPaintJob(buildRainbow(3, 3)) end)
btn("◈ Spray Spam", function() runPaintJob(buildSpraySpam(150, 2.5, 2.5)) end)

-- image paint
section "Image Paint (URL -> wall)"
local urlBox = new("TextBox", { Size = UDim2.new(1,0,0,30), BackgroundColor3 = Color3.fromRGB(15,16,19), BorderSizePixel = 0, PlaceholderText = "paste image URL here, then tell ENI to paint it", Text = "", TextColor3 = TXT, PlaceholderColor3 = DIM, Font = Enum.Font.Gotham, TextSize = 11, ClearTextOnFocus = false, TextXAlignment = Enum.TextXAlignment.Left }, scroll)
corner(urlBox, 6); pad(urlBox, 10, 0, 10, 0)
Image.urlBox = urlBox
urlBox.FocusLost:Connect(function(enter)
	if enter and urlBox.Text:match("^https?://") then
		getgenv().__imgurl = urlBox.Text
		setStatus("URL saved — tell ENI to 'paint it'")
		print("[SPRAYHUB-URL] " .. urlBox.Text)
	end
end)
slider("px size (studs)", 0.2, 1.2, function() return Image.cell end, function(v) Image.cell = v end, "%.2f")
btn("👁 Toggle Cursor Preview", function(b)
	Image.previewOn = not Image.previewOn
	setStatus(Image.previewOn and "preview ON — move mouse on a wall" or "preview OFF")
end)
btn("🖼 Paint Image Here", function() paintImage() end)

-- tools
section "Tools"
btn("🧹 Erase My Paint", function()
	local pf = workspace:FindFirstChild("PaintFolder")
	local mine = pf and pf:FindFirstChild(LP.Name)
	if not mine then setStatus("no paint") return end
	local n = 0
	for _, inst in ipairs(mine:GetDescendants()) do
		if inst:IsA("BasePart") and not inst:HasTag("Client") then pcall(function() ClientToServer.cacheErase(inst) end) n = n + 1 end
	end
	pcall(function() ClientToServer.sendEraseToServer() end)
	setStatus(("erase sent for %d parts"):format(n))
end)
btn("■ STOP ALL (emergency)", function() Hub.stopAll() setStatus("stopped") end)

-- keybind toggle
UIS.InputBegan:Connect(function(io, gpe)
	if gpe then return end
	if io.KeyCode == Enum.KeyCode.RightControl or io.KeyCode == Enum.KeyCode.F4 then main.Visible = not main.Visible end
end)

--// init / exposed api
Hub.runJob = runPaintJob
Hub.build = { fill = buildFill, pattern = buildPattern, rainbow = buildRainbow, spray = buildSpraySpam, image = buildImage }
Hub.aimFrame = aimFrame
Hub.applyBrush = applyBrush
Hub.presets = Presets
Hub.presetOrder = PresetOrder
Hub.image = Image
Hub.paintImage = paintImage
Hub.setPreview = function(v) Image.previewOn = v end
applyBrush()
setStatus("v2 ready — size cap " .. SIZE_CAP .. ", effects need gamepass")
print("[SprayHub v2] loaded. MaxDist=" .. tostring(MAX_DIST) .. " SizeCap=" .. SIZE_CAP)
