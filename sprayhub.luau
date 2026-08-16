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
local Hub = { gui = nil, threads = {}, stopped = false, painted = 0, enforce = true, human = false }
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
	h = 0, s = 1, v = 1, -- HSV mirror of color (drives the picker UI)
	size = 0.6,
	shape = "Octagon",
	layer = 1,
	opacity = 1,
	neon = false, chrome = false, rainbow = false,
}
local function currentColor() return Brush.color end
local function applyBrush()
	Brush.size = math.clamp(Brush.size, 0.05, SIZE_CAP)
	Brush.opacity = math.clamp(Brush.opacity, 0.05, 1)
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
local function paintBlob(cf, color, shape, size)
	PS:SetAttribute("Color", color)
	PS:SetAttribute("Size", math.clamp(size or Brush.size, 0.05, SIZE_CAP))
	PS:SetAttribute("BrushShape", shape or Brush.shape)
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

local function colorKey(c) return ("%d,%d,%d"):format(math.floor(c.R*255+0.5), math.floor(c.G*255+0.5), math.floor(c.B*255+0.5)) end
-- server persists ONE color per stroke (BUG#1: mixed-color batch dedups to 1 blob) ->
-- split into per-color runs; each run is its own Stroke + its own flush.
local function runPaintJob(blobList, opts)
	opts = opts or {}
	local batch = opts.batch or 40
	-- group ALL blobs globally by color (one stroke per color, first-seen order) —
	-- contiguous runs would shard interleaved images into a stroke per pixel.
	local runs, seen = {}, {}
	for _, b in ipairs(blobList) do
		local ck = colorKey(b.color or currentColor())
		local run = seen[ck]
		if not run then run = { ck = ck, blobs = {} } seen[ck] = run table.insert(runs, run) end
		table.insert(run.blobs, b)
	end
	local t = coroutine.create(function()
		-- warmup: the server's FIRST flush of a session is reliably dropped
		-- (observed 2026-08-11 + 2026-08-14: first batch vanishes, rest persist).
		-- Send an empty flush to wake it before any real paint.
		if Hub.painted == 0 and not opts.noWarmup then
			flush()
			task.wait(FLUSH_RATE)
		end
		-- human mode: smaller batches + jittered pacing (mitigates server spam-flagging)
		if Hub.human then batch = math.min(batch, 12) end
		local function blobWait()
			if Hub.human then task.wait(0.02 + math.random() * 0.05) else task.wait() end
		end
		local function flushWait()
			task.wait(Hub.human and FLUSH_RATE * (1.5 + math.random()) or FLUSH_RATE)
		end
		local made = 0
		for ri, run in ipairs(runs) do
			if Hub.stopped then break end
			PS:SetAttribute("Stroke", (PS:GetAttribute("Stroke") or 0) + 1)
			if UndoRedo then pcall(function() UndoRedo:InvokeServer({ Type = "Paint", Stroke = PS:GetAttribute("Stroke") }) end) end
			local n = 0
			for _, b in ipairs(run.blobs) do
				if Hub.stopped then break end
				if b.cf and paintBlob(b.cf, b.color or currentColor(), b.shape, b.size) then made = made + 1 n = n + 1 Hub.painted = Hub.painted + 1 end
				if n % batch == 0 then flush() flushWait() end
				blobWait()
			end
			flush()
			if ri < #runs then flushWait() end
		end
		setStatus(("done: %d blobs, %d color runs (session %d)"):format(made, #runs, Hub.painted))
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
local FILL_DIST_MULT = 1.0 -- blob centers one blob-width apart = edge-to-edge tiling
local function gridStep() return math.max(Brush.size * FILL_DIST_MULT, MIN_SPACING) end
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

--// Embedded pure-Luau PNG decoder (verified vs img2grid.js, 10/10 pixel-exact)
local PngDecode = (function()
--// pngdecode — pure-Luau PNG decoder (no deps).
-- Supports: 8-bit, color types 0 (gray), 2 (RGB), 3 (palette), 4 (gray+A), 6 (RGBA),
-- non-interlaced, any zlib-conformant IDAT (stored/fixed/dynamic DEFLATE blocks).
-- API:
--   PngDecode.decode(bytes: string) -> img, err
--     img = { w, h, rgba = { [i]=(byte) ... } }   -- RGBA bytes, 1..w*h*4
--   PngDecode.toGrid(img, maxW, maxH) -> { w, h, n, px = { {x,y,packedRGB,alpha}, ... } }
--     (downscale box-average + sparse alpha>31, matched to img2grid.js semantics)
local PngDecode = {}

--// zlib/DEFLATE -----------------------------------------------------------
local function inflate(data)
	local pos, bitBuf, bitCnt = 1, 0, 0
	local function readBits(n)
		while bitCnt < n do
			bitBuf = bitBuf + data:byte(pos) * 2 ^ bitCnt
			bitCnt = bitCnt + 8
			pos = pos + 1
		end
		local v = bitBuf % 2 ^ n
		bitBuf = (bitBuf - v) / 2 ^ n
		bitCnt = bitCnt - n
		return v
	end
	-- canonical Huffman: lengths -> fixed table of { [len] = {code->sym} }
	local function buildHuff(lengths)
		local blCount, maxLen = {}, 0
		for _, l in ipairs(lengths) do
			if l > 0 then blCount[l] = (blCount[l] or 0) + 1 maxLen = math.max(maxLen, l) end
		end
		local code = 0
		local nextCode = {}
		for bits = 1, maxLen do
			code = (code + (blCount[bits - 1] or 0)) * 2
			nextCode[bits] = code
		end
		local byLen = {}
		for sym, l in ipairs(lengths) do
			if l > 0 then
				byLen[l] = byLen[l] or {}
				byLen[l][nextCode[l]] = sym - 1
				nextCode[l] = nextCode[l] + 1
			end
		end
		return byLen, maxLen
	end
	local function decodeSym(byLen, maxLen)
		local code = 0
		for len = 1, maxLen do
			code = code * 2 + readBits(1)
			local t = byLen[len]
			if t then
				local s = t[code]
				if s then return s end
			end
		end
		error("bad huffman code", 0)
	end
	local LEN_BASE = {3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,163,195,227,258}
	local LEN_EXTRA = {0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0}
	local DIST_BASE = {1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,513,769,1025,1537,2049,3073,4097,6145,8193,12289,16385,24577}
	local DIST_EXTRA = {0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13}

	-- skip zlib wrapper (CMF/FLG); adler32 unchecked
	pos = 3
	local out = {}
	local outN = 0
	repeat
		local bfinal = readBits(1)
		local btype = readBits(2)
		if btype == 0 then -- stored
			bitBuf, bitCnt = 0, 0
			local len = data:byte(pos) + data:byte(pos + 1) * 256
			pos = pos + 4 -- len + nlen
			for _ = 1, len do
				outN += 1
				out[outN] = data:byte(pos)
				pos = pos + 1
			end
		else
			local litH, litMax, distH, distMax
			if btype == 1 then -- fixed
				local lengths = {}
				for i = 1, 288 do
					lengths[i] = i <= 144 and 8 or (i <= 256 and 9 or (i <= 280 and 7 or 8))
				end
				litH, litMax = buildHuff(lengths)
				local dl = {}
				for i = 1, 30 do dl[i] = 5 end
				distH, distMax = buildHuff(dl)
			elseif btype == 2 then -- dynamic
				local hlit = 257 + readBits(5)
				local hdist = 1 + readBits(5)
				local hclen = 4 + readBits(4)
				local ORDER = {16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15}
				local clLens = {}
				for i = 1, 19 do clLens[i] = 0 end
				for i = 1, hclen do clLens[ORDER[i] + 1] = readBits(3) end
				local clH, clMax = buildHuff(clLens)
				local lengths = {}
				local n = 1
				while n <= hlit + hdist do
					local s = decodeSym(clH, clMax)
					if s <= 15 then
						lengths[n] = s
						n = n + 1
					elseif s == 16 then
						local rep = 3 + readBits(2)
						local v = lengths[n - 1]
						for _ = 1, rep do lengths[n] = v n = n + 1 end
					elseif s == 17 then
						local rep = 3 + readBits(3)
						for _ = 1, rep do lengths[n] = 0 n = n + 1 end
					else -- 18
						local rep = 11 + readBits(7)
						for _ = 1, rep do lengths[n] = 0 n = n + 1 end
					end
				end
				local litL, distL = {}, {}
				for i = 1, hlit do litL[i] = lengths[i] or 0 end
				for i = 1, hdist do distL[i] = lengths[hlit + i] or 0 end
				litH, litMax = buildHuff(litL)
				distH, distMax = buildHuff(distL)
			else
				error("reserved DEFLATE block type", 0)
			end
			while true do
				local s = decodeSym(litH, litMax)
				if s < 256 then
					outN += 1
					out[outN] = s
				elseif s == 256 then
					break
				else
					local li = s - 256
					local len = LEN_BASE[li] + (LEN_EXTRA[li] > 0 and readBits(LEN_EXTRA[li]) or 0)
					local ds = decodeSym(distH, distMax) + 1
					local dist = DIST_BASE[ds] + (DIST_EXTRA[ds] > 0 and readBits(DIST_EXTRA[ds]) or 0)
					local src = outN - dist
					for _ = 1, len do
						src = src + 1
						outN += 1
						out[outN] = out[src]
					end
				end
			end
		end
		if bfinal == 1 then break end
	until false
	return out -- array of bytes, 1..outN
end

--// PNG ---------------------------------------------------------------------
local function u32be(s, i) return s:byte(i) * 16777216 + s:byte(i + 1) * 65536 + s:byte(i + 2) * 256 + s:byte(i + 3) end

function PngDecode.decode(bytes)
	if #bytes < 8 or bytes:sub(1, 8) ~= "\137PNG\r\n\026\n" then return nil, "not a PNG file" end
	local off = 9
	local ihdr, plte, trns = nil, nil, nil
	local idat = {}
	while off + 8 <= #bytes do
		local len = u32be(bytes, off)
		local ctype = bytes:sub(off + 4, off + 7)
		local data = bytes:sub(off + 8, off + 7 + len)
		off = off + 12 + len
		if ctype == "IHDR" then
			ihdr = { w = u32be(data, 1), h = u32be(data, 5), depth = data:byte(9), ct = data:byte(10), interlace = data:byte(13) }
		elseif ctype == "PLTE" then plte = data
		elseif ctype == "tRNS" then trns = data
		elseif ctype == "IDAT" then table.insert(idat, data)
		elseif ctype == "IEND" then break end
	end
	if not ihdr then return nil, "no IHDR chunk" end
	if ihdr.interlace ~= 0 then return nil, "interlaced PNG unsupported" end
	if ihdr.depth ~= 8 then return nil, ("bit depth %d unsupported (need 8)"):format(ihdr.depth) end
	local CH = ({ [0]=1, [2]=3, [3]=1, [4]=2, [6]=4 })[ihdr.ct]
	if not CH then return nil, ("color type %d unsupported"):format(ihdr.ct) end
	if ihdr.ct == 3 and not plte then return nil, "palette PNG missing PLTE" end

	local ok, rawOrErr = pcall(inflate, table.concat(idat))
	if not ok then return nil, "inflate failed: " .. tostring(rawOrErr) end
	local raw = rawOrErr
	local w, h, bpp = ihdr.w, ihdr.h, CH
	local rowLen = w * bpp
	if #raw < (rowLen + 1) * h then return nil, "truncated image data" end

	-- unfilter into RGBA
	local rgba = {}
	local prev = {}
	for x = 1, rowLen do prev[x] = 0 end
	for y = 0, h - 1 do
		local s = y * (rowLen + 1)
		local ft = raw[s + 1]
		local cur = {}
		for x = 1, rowLen do
			local a = x > bpp and cur[x - bpp] or 0
			local b = prev[x]
			local c = x > bpp and prev[x - bpp] or 0
			local v = raw[s + 1 + x]
			if ft == 1 then v = (v + a) % 256
			elseif ft == 2 then v = (v + b) % 256
			elseif ft == 3 then v = (v + (a + b) // 2) % 256
			elseif ft == 4 then
				local p = a + b - c
				local pa, pb, pc = math.abs(p - a), math.abs(p - b), math.abs(p - c)
				local pr = (pa <= pb and pa <= pc) and a or (pb <= pc and b or c)
				v = (v + pr) % 256
			end
			cur[x] = v
		end
		for x = 0, w - 1 do
			local i = x * bpp
			local o = (y * w + x) * 4
			if ihdr.ct == 0 then
				rgba[o+1], rgba[o+2], rgba[o+3], rgba[o+4] = cur[i+1], cur[i+1], cur[i+1], 255
			elseif ihdr.ct == 2 then
				rgba[o+1], rgba[o+2], rgba[o+3], rgba[o+4] = cur[i+1], cur[i+2], cur[i+3], 255
			elseif ihdr.ct == 3 then
				local idx = cur[i+1]
				rgba[o+1] = plte:byte(idx * 3 + 1)
				rgba[o+2] = plte:byte(idx * 3 + 2)
				rgba[o+3] = plte:byte(idx * 3 + 3)
				rgba[o+4] = (trns and idx + 1 <= #trns) and trns:byte(idx + 1) or 255
			elseif ihdr.ct == 4 then
				rgba[o+1], rgba[o+2], rgba[o+3], rgba[o+4] = cur[i+1], cur[i+1], cur[i+1], cur[i+2]
			else -- 6
				rgba[o+1], rgba[o+2], rgba[o+3], rgba[o+4] = cur[i+1], cur[i+2], cur[i+3], cur[i+4]
			end
		end
		prev = cur
	end
	return { w = w, h = h, rgba = rgba }
end

-- downscale box-average + sparse emit (img2grid-compatible)
function PngDecode.toGrid(img, maxW, maxH)
	local scale = math.min(maxW / img.w, maxH / img.h, 1)
	local nw = math.max(1, math.floor(img.w * scale + 0.5))
	local nh = math.max(1, math.floor(img.h * scale + 0.5))
	local px = {}
	for y = 0, nh - 1 do
		local y0 = math.floor(y * img.h / nh)
		local y1 = math.max(y0 + 1, math.floor((y + 1) * img.h / nh))
		for x = 0, nw - 1 do
			local x0 = math.floor(x * img.w / nw)
			local x1 = math.max(x0 + 1, math.floor((x + 1) * img.w / nw))
			local r, g, b, a, cnt = 0, 0, 0, 0, 0
			for yy = y0, y1 - 1 do
				for xx = x0, x1 - 1 do
					local o = (yy * img.w + xx) * 4
					r += img.rgba[o+1] g += img.rgba[o+2] b += img.rgba[o+3] a += img.rgba[o+4]
					cnt += 1
				end
			end
			local ar = math.floor(a / cnt + 0.5)
			if ar >= 32 then
				local rr, gg, bb = math.floor(r / cnt + 0.5), math.floor(g / cnt + 0.5), math.floor(b / cnt + 0.5)
				table.insert(px, { x + 1, y + 1, rr * 65536 + gg * 256 + bb, ar })
			end
		end
	end
	return { w = nw, h = nh, n = #px, px = px }
end

return PngDecode

end)()
--// Text painter: 5x7 bitmap font -> __imgdata (reuses the whole image pipeline)
-- Each glyph is 7 rows of "#"/"."; width is auto (max row len). Unknown chars skip.
local Image -- fwd-decl: defined in the image-paint section below
local FONT = {
	A = {".###.","#...#","#...#","#####","#...#","#...#","#...#"},
	B = {"####.","#...#","#...#","####.","#...#","#...#","####."},
	C = {".####","#....","#....","#....","#....","#....",".####"},
	D = {"####.","#...#","#...#","#...#","#...#","#...#","####."},
	E = {"#####","#....","#....","####.","#....","#....","#####"},
	F = {"#####","#....","#....","####.","#....","#....","#...."},
	G = {".####","#....","#....","#.###","#...#","#...#",".###."},
	H = {"#...#","#...#","#...#","#####","#...#","#...#","#...#"},
	I = {"###",".#.",".#.",".#.",".#.",".#.","###"},
	J = {"..###","...#.","...#.","...#.","...#.","#..#.",".##.."},
	K = {"#...#","#..#.","#.#..","##...","#.#..","#..#.","#...#"},
	L = {"#....","#....","#....","#....","#....","#....","#####"},
	M = {"#...#","##.##","#.#.#","#.#.#","#...#","#...#","#...#"},
	N = {"#...#","##..#","##..#","#.#.#","#..##","#..##","#...#"},
	O = {".###.","#...#","#...#","#...#","#...#","#...#",".###."},
	P = {"####.","#...#","#...#","####.","#....","#....","#...."},
	Q = {".###.","#...#","#...#","#...#","#.#.#","#..#.",".##.#"},
	R = {"####.","#...#","#...#","####.","#.#..","#..#.","#...#"},
	S = {".####","#....","#....",".###.","....#","....#","####."},
	T = {"#####","..#..","..#..","..#..","..#..","..#..","..#.."},
	U = {"#...#","#...#","#...#","#...#","#...#","#...#",".###."},
	V = {"#...#","#...#","#...#","#...#","#...#",".#.#.","..#.."},
	W = {"#...#","#...#","#...#","#.#.#","#.#.#","##.##","#...#"},
	X = {"#...#","#...#",".#.#.","..#..",".#.#.","#...#","#...#"},
	Y = {"#...#","#...#",".#.#.","..#..","..#..","..#..","..#.."},
	Z = {"#####","....#","...#.","..#..",".#...","#....","#####"},
	["0"] = {".###.","#..##","#.#.#","#.#.#","##..#","#...#",".###."},
	["1"] = {"..#..",".##..","..#..","..#..","..#..","..#..",".###."},
	["2"] = {".###.","#...#","....#","...#.","..#..",".#...","#####"},
	["3"] = {"####.","....#","....#",".###.","....#","....#","####."},
	["4"] = {"...#.","..##.",".#.#.","#..#.","#####","...#.","...#."},
	["5"] = {"#####","#....","####.","....#","....#","#...#",".###."},
	["6"] = {".###.","#....","#....","####.","#...#","#...#",".###."},
	["7"] = {"#####","....#","...#.","..#..",".#...",".#...",".#..."},
	["8"] = {".###.","#...#","#...#",".###.","#...#","#...#",".###."},
	["9"] = {".###.","#...#","#...#",".####","....#","....#",".###."},
	["!"] = {"..#..","..#..","..#..","..#..","..#..",".....","..#.."},
	["?"] = {".###.","#...#","....#","..##.","..#..",".....","..#.."},
	["."] = {".....",".....",".....",".....",".....","..##.","..##."},
	[","] = {".....",".....",".....",".....","..##.","..##.",".#..."},
	["'"] = {"..#..","..#..","..#..",".....",".....",".....","....."},
	['"'] = {".#.#.",".#.#.",".#.#.",".....",".....",".....","....."},
	[":"] = {".....","..##.","..##.",".....","..##.","..##.","....."},
	[";"] = {".....","..##.","..##.",".....","..##.","..##.",".#..."},
	["-"] = {".....",".....",".....","#####",".....",".....","....."},
	["_"] = {".....",".....",".....",".....",".....",".....","#####"},
	["+"] = {".....","..#..","..#..","#####","..#..","..#..","....."},
	["="] = {".....",".....","#####",".....","#####",".....","....."},
	["("] = {"...#.","..#..",".#...",".#...",".#...","..#..","...#."},
	[")"] = {".#...","..#..","...#.","...#.","...#.","..#..",".#..."},
	["/"] = {"....#","....#","...#.","..#..",".#...","#....","#...."},
	["*"] = {".....",".#.#.","..#..","#####","..#..",".#.#.","....."},
	["<"] = {"...#.","..#..",".#...","#....",".#...","..#..","...#."},
	[">"] = {".#...","..#..","...#.","....#","...#.","..#..",".#..."},
	["<3"] = {".#.#.","#####","#####","#####",".###.","..#..","....."}, -- heart, type <3
}
local GLYPH_H, LETTER_GAP, LINE_GAP, SPACE_W = 7, 1, 2, 3

-- text -> {w,h,n,px} in the imgserver/img2grid format (px = {x, y, packedRGB, alpha})
-- returns data, skippedCount (chars with no glyph)
local function textToImage(text, color)
	local r = math.floor(color.R * 255 + 0.5)
	local g = math.floor(color.G * 255 + 0.5)
	local b = math.floor(color.B * 255 + 0.5)
	local packed = r * 65536 + g * 256 + b
	local px, skipped = {}, 0
	local totalW, yOff = 0, 0
	local lineWidths = {}
	for line in (text .. "\n"):gmatch("(.-)\n") do
		local x, lineW = 0, 0
		local i = 1
		while i <= #line do
			-- multi-char glyph tokens first (<3)
			local tok = line:sub(i, i + 1)
			local glyph
			if FONT[tok] then glyph = FONT[tok] i = i + 2
			else
				local c = line:sub(i, i)
				i = i + 1
				if c == " " then x = x + SPACE_W + LETTER_GAP continue end
				glyph = FONT[c] or FONT[c:upper()]
				if not glyph then skipped = skipped + 1 continue end
			end
			local gw = 0
			for _, row in ipairs(glyph) do gw = math.max(gw, #row) end
			for ry, row in ipairs(glyph) do
				for rx = 1, #row do
					if row:sub(rx, rx) == "#" then
						table.insert(px, { x + rx - 1, yOff + ry - 1, packed, 255 })
					end
				end
			end
			x = x + gw + LETTER_GAP
			lineW = x
		end
		lineW = math.max(lineW - LETTER_GAP, 0) -- trailing gap doesn't count
		table.insert(lineWidths, lineW)
		totalW = math.max(totalW, lineW)
		yOff = yOff + GLYPH_H + LINE_GAP
	end
	local totalH = yOff - LINE_GAP
	return { w = math.max(totalW, 1), h = math.max(totalH, 1), n = #px, px = px, lineWidths = lineWidths }, skipped
end

-- turn text into __imgdata and arm click-to-place (same flow as URL images)
local function armText(text, color)
	if not text or text == "" then setStatus("type some text first") return false end
	local data, skipped = textToImage(text, color or Brush.color)
	if data.n == 0 then setStatus("no paintable glyphs in that text") return false end
	getgenv().__imgdata = data
	Image.armed = true
	Image.previewOn = false
	setStatus(("text armed: %d px (%dx%d)%s — click a wall"):format(
		data.n, data.w, data.h, skipped > 0 and (", skipped " .. skipped .. " chars") or ""))
	return true
end

--// Image paint: cursor-following preview + pixel-grid painting -------------
Image = { enabled = false, previewOn = false, armed = false, cell = 0.6, frame = nil, part = nil, urlBox = nil, culled = nil, maxW = 40, maxH = 36, overlap = 1.0 } -- size = cell*overlap; 1.0 = edge-to-edge tiles

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
	if not ((Image.previewOn or Image.armed) and data and data.w) then
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
			Image.part = part
		end
		Image.part.Size = Vector3.new(fw, fh, 0.2)
		Image.part.Transparency = 0.5
		Image.part.Color = Image.armed and Color3.fromRGB(255, 170, 40) or Color3.fromRGB(120, 90, 220)
		local f = Image.frame
		Image.part.CFrame = CFrame.fromMatrix(f.center + f.normal * 0.15, f.right, f.up)
		if Image.part.Parent ~= workspace then Image.part.Parent = workspace end
	else
		if Image.part then Image.part.Transparency = 1 end
	end
end
RunSvc.RenderStepped:Connect(updatePreview)

-- build blob list from getgenv().__imgdata at a given wall frame
-- returns list, err — on success also sets Image.culled = {tooFar, noRay}
local function buildImage(f)
	local data = getgenv().__imgdata
	if not (data and data.px and data.w and data.h) then return nil, "no image loaded" end
	f = f or Image.frame or (function() local h = cursorHit() if h then return frameFromHit(h) end end)()
	if not f then return nil, "aim at a wall (hold preview)" end
	local cell = Image.cell
	local params = PaintPositioning.getRaycastParams()
	local root = charPos()
	local list = {}
	local tooFar, noRay = 0, 0
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
				table.insert(list, { cf = faceCFrame(hit.Position, hit.Normal), color = Color3.fromRGB(r, g, b), shape = "Square", size = math.min(cell * Image.overlap, SIZE_CAP) })
			else
				tooFar += 1
			end
		else
			noRay += 1
		end
	end
	Image.culled = { tooFar = tooFar, noRay = noRay }
	return list
end

local function paintImage(f)
	local list, err = buildImage(f)
	if not list then setStatus(err) return end
	if #list == 0 then setStatus("nothing in range / off-wall") return end
	runPaintJob(list, { batch = 40 })
	local c = Image.culled
	if c and (c.tooFar > 0 or c.noRay > 0) then
		task.defer(function()
			task.wait(0.5)
			setStatus(("painting %d px (skipped %d off-wall, %d too far)"):format(#list, c.noRay, c.tooFar))
		end)
	end
end

-- mouse wheel: resize preview AND sink the event so the game camera doesn't zoom.
-- Resize runs INSIDE the sinking binding — a separate UIS.InputChanged handler
-- sees gpe=true for sunk input and never fires (that was the v4.4 resize bug).
-- Shift+wheel passes through so the camera can still zoom while armed.
local CAS = game:GetService("ContextActionService")
local function hubWheelResize(dz)
	if not (getgenv().__imgdata and getgenv().__imgdata.px) then return end
	Image.cell = math.clamp(Image.cell + dz * 0.05, 0.15, 1.2)
	local d = getgenv().__imgdata
	setStatus(("preview %d px (%.1fx%.1f studs) — wheel=size, shift+wheel=cam zoom, click=draw"):format(d.n, d.w * Image.cell, d.h * Image.cell))
end
local function setWheelSink(on)
	if on then
		CAS:BindActionAtPriority("SprayHubWheel", function(_, is, io)
			if io.UserInputType == Enum.UserInputType.MouseWheel and (Image.armed or Image.previewOn) then
				if UIS:IsKeyDown(Enum.KeyCode.LeftShift) then return Enum.ContextActionResult.Pass end
				hubWheelResize(io.Position.Z)
				return Enum.ContextActionResult.Sink
			end
			return Enum.ContextActionResult.Pass
		end, false, Enum.ContextActionPriority.High.Value + 1, Enum.UserInputType.MouseWheel)
	else
		pcall(function() CAS:UnbindAction("SprayHubWheel") end)
	end
end
setWheelSink(true)

-- one-click: load URL -> arm placement -> click wall -> auto-draw
-- fully self-contained: fetches the PNG directly and decodes with the embedded
-- pure-Luau decoder (no imgserver / localhost needed). PNG URLs only.
local function loadImageFromUrl(url, onDone)
	task.spawn(function()
		setStatus("downloading image…")
		local ok, body = pcall(function() return game:HttpGet(url) end)
		if not ok or type(body) ~= "string" or #body < 8 then setStatus("download failed") return end
		if body:sub(1, 8) ~= "\137PNG\r\n\026\n" then setStatus("not a PNG — convert the image to PNG first") return end
		setStatus("decoding…")
		local t0 = os.clock()
		local img, derr = PngDecode.decode(body)
		if not img then setStatus(derr) return end
		if img.w * img.h > 4000000 then setStatus(("image too large (%dx%d)"):format(img.w, img.h)) return end
		local d = PngDecode.toGrid(img, Image.maxW, Image.maxH)
		getgenv().__imgdata = d
		Image.armed = true
		Image.previewOn = false
		setStatus(("loaded %dx%d (%d px, %.1fs) — click a wall to place"):format(d.w, d.h, d.n, os.clock() - t0))
		if onDone then pcall(onDone) end
	end)
end

-- click-to-place: left click while armed -> paint HERE.
-- Bound via CAS at High+1 and SUNK so the game's own click-paint never sees it
-- (raw UIS.InputBegan can't stop the game from also painting one blob).
local function placeAtCursor()
	local f = Image.frame
	Image.armed = false
	if Image.part then Image.part.Transparency = 1 end
	if not f then setStatus("no wall under cursor") return end
	paintImage(f)
end
CAS:BindActionAtPriority("SprayHubPlace", function(_, is, io)
	if is == Enum.UserInputState.Begin and Image.armed then
		placeAtCursor()
		return Enum.ContextActionResult.Sink
	end
	return Enum.ContextActionResult.Pass
end, false, Enum.ContextActionPriority.High.Value + 1, Enum.UserInputType.MouseButton1)

-- (resize now lives in the SprayHubWheel CAS binding above)

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
	local dragging = false
	local function setFrom(io)
		local a = math.clamp((io.Position.X - bar.AbsolutePosition.X)/math.max(bar.AbsoluteSize.X,1),0,1)
		set(min + (max-min)*a) refresh() applyBrush()
	end
	bar.InputBegan:Connect(function(io)
		if io.UserInputType == Enum.UserInputType.MouseButton1 then dragging = true setFrom(io) end
	end)
	-- track mouse GLOBALLY while held — a ScrollingFrame can swallow the
	-- bar's own InputChanged once the cursor leaves the 10px bar area
	UIS.InputChanged:Connect(function(io)
		if dragging and io.UserInputType == Enum.UserInputType.MouseMovement then setFrom(io) end
	end)
	UIS.InputEnded:Connect(function(io)
		if io.UserInputType == Enum.UserInputType.MouseButton1 then dragging = false end
	end)
	refresh()
	return frame
end

-- color
section "Brush"
local setBrushColor -- fwd-decl: swatches hook into the picker once it's built
local swatch = new("Frame", { Size = UDim2.new(1,0,0,30), BackgroundTransparency = 1 }, scroll)
new("UIGridLayout", { CellSize = UDim2.new(0,30,0,30), CellPadding = UDim2.new(0,6,0,6), SortOrder = Enum.SortOrder.LayoutOrder }, swatch)
for _, c in ipairs({Color3.fromRGB(255,0,0),Color3.fromRGB(255,150,0),Color3.fromRGB(255,230,0),Color3.fromRGB(0,200,80),Color3.fromRGB(0,200,220),Color3.fromRGB(40,120,255),Color3.fromRGB(150,60,255),Color3.fromRGB(220,60,200),Color3.fromRGB(255,255,255),Color3.fromRGB(15,15,15),Color3.fromRGB(160,100,60),Color3.fromRGB(255,160,180)}) do
	local s = new("TextButton", { BackgroundColor3 = c, BorderSizePixel = 0, Text = "", AutoButtonColor = true }, swatch)
	corner(s, 6); new("UIStroke", { Color = TXT, Thickness = 1, Transparency = 0.7 }, s)
	s.MouseButton1Click:Connect(function() setBrushColor(c) setStatus("color set") end)
end
--// Color picker (hue bar + SV square + Hex/RGB/HSV) -----------------------
do
	local pk = new("Frame", { Size = UDim2.new(1,0,0,168), BackgroundColor3 = BG2, BorderSizePixel = 0 }, scroll)
	corner(pk, 6); pad(pk, 10, 8, 10, 8)

	-- SV square: hue base + white->clear horizontal + clear->black vertical
	local sv = new("Frame", { Size = UDim2.new(1,-84,0,88), BackgroundColor3 = Color3.fromHSV(Brush.h,1,1), BorderSizePixel = 0 }, pk)
	corner(sv, 6)
	local svWhite = new("Frame", { Size = UDim2.new(1,0,1,0), BackgroundColor3 = Color3.new(1,1,1), BorderSizePixel = 0 }, sv)
	corner(svWhite, 6)
	new("UIGradient", { Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0,0), NumberSequenceKeypoint.new(1,1)}) }, svWhite)
	local svBlack = new("Frame", { Size = UDim2.new(1,0,1,0), BackgroundColor3 = Color3.new(0,0,0), BorderSizePixel = 0 }, sv)
	corner(svBlack, 6)
	new("UIGradient", { Rotation = 90, Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0,1), NumberSequenceKeypoint.new(1,0)}) }, svBlack)
	local svDot = new("Frame", { Size = UDim2.new(0,10,0,10), AnchorPoint = Vector2.new(0.5,0.5), BackgroundColor3 = Brush.color, BorderSizePixel = 0 }, sv)
	corner(svDot, 5); new("UIStroke", { Color = Color3.new(1,1,1), Thickness = 2 }, svDot)

	-- hue bar: gradient of pure hues + marker
	local hueRow = new("Frame", { Size = UDim2.new(1,-84,0,16), Position = UDim2.new(0,0,0,96), BackgroundColor3 = Color3.new(1,1,1), BorderSizePixel = 0 }, pk)
	corner(hueRow, 6)
	local hKeys = {}
	for i = 0, 6 do hKeys[#hKeys+1] = ColorSequenceKeypoint.new(i/6, Color3.fromHSV(i/6,1,1)) end
	new("UIGradient", { Color = ColorSequence.new(hKeys) }, hueRow)
	local hueDot = new("Frame", { Size = UDim2.new(0,4,1,4), Position = UDim2.new(0.5,0,0.5,0), AnchorPoint = Vector2.new(0.5,0.5), BackgroundColor3 = Color3.new(1,1,1), BorderSizePixel = 0 }, hueRow)
	corner(hueDot, 2)

	-- preview swatch
	local pv = new("Frame", { Size = UDim2.new(0,64,0,88), Position = UDim2.new(1,-64,0,0), BackgroundColor3 = Brush.color, BorderSizePixel = 0 }, pk)
	corner(pv, 6); new("UIStroke", { Color = TXT, Thickness = 1, Transparency = 0.6 }, pv)

	-- numeric fields
	local function field(ph, pos)
		local t = new("TextBox", { Size = UDim2.new(0,64,0,20), Position = pos, BackgroundColor3 = Color3.fromRGB(15,16,19), BorderSizePixel = 0, Text = "", PlaceholderText = ph, TextColor3 = TXT, PlaceholderColor3 = DIM, Font = Enum.Font.Code, TextSize = 10, ClearTextOnFocus = false }, pk)
		corner(t, 5)
		return t
	end
	local hexF = field("#hex", UDim2.new(1,-64,0,96))
	local rgbF = field("r,g,b", UDim2.new(1,-64,0,120))
	local hsvF = field("h,s,v", UDim2.new(1,-64,0,144))

	local refresh
	local function setHSV(h, s, v, src)
		Brush.h, Brush.s, Brush.v = math.clamp(h,0,1), math.clamp(s,0,1), math.clamp(v,0,1)
		Brush.color = Color3.fromHSV(Brush.h, Brush.s, Brush.v)
		applyBrush()
		refresh(src)
	end
	setBrushColor = setHSV and function(c)
		local h, s, v = c:ToHSV()
		if s > 0.01 or v > 0.01 then setHSV(h, s, v, nil) else setHSV(Brush.h, s, v, nil) end
	end

	refresh = function(skip)
		sv.BackgroundColor3 = Color3.fromHSV(Brush.h, 1, 1)
		svDot.Position = UDim2.new(Brush.s, 0, 1 - Brush.v, 0)
		svDot.BackgroundColor3 = Brush.color
		hueDot.Position = UDim2.new(Brush.h, 0, 0.5, 0)
		pv.BackgroundColor3 = Brush.color
		local r, g, b = math.floor(Brush.color.R*255+0.5), math.floor(Brush.color.G*255+0.5), math.floor(Brush.color.B*255+0.5)
		if skip ~= hexF then hexF.Text = ("#%02x%02x%02x"):format(r,g,b) end
		if skip ~= rgbF then rgbF.Text = ("%d,%d,%d"):format(r,g,b) end
		if skip ~= hsvF then hsvF.Text = ("%.0f,%.0f,%.0f"):format(Brush.h*360, Brush.s*100, Brush.v*100) end
	end

	-- drag helpers
	local function dragOn(frame, cb)
		local dragging = false
		local function upd(io)
			local x = math.clamp((io.Position.X - frame.AbsolutePosition.X) / math.max(frame.AbsoluteSize.X, 1), 0, 1)
			local y = math.clamp((io.Position.Y - frame.AbsolutePosition.Y) / math.max(frame.AbsoluteSize.Y, 1), 0, 1)
			cb(x, y)
		end
		frame.InputBegan:Connect(function(io) if io.UserInputType == Enum.UserInputType.MouseButton1 then dragging = true upd(io) end end)
		frame.InputChanged:Connect(function(io) if dragging and io.UserInputType == Enum.UserInputType.MouseMovement then upd(io) end end)
		UIS.InputEnded:Connect(function(io) if io.UserInputType == Enum.UserInputType.MouseButton1 then dragging = false end end)
	end
	dragOn(sv, function(x, y) setHSV(Brush.h, x, 1 - y) end)
	dragOn(hueRow, function(x) setHSV(x, Brush.s, Brush.v) end)

	hexF.FocusLost:Connect(function(enter)
		if not enter then return end
		local t = hexF.Text:gsub("#",""):gsub("^%s+",""):gsub("%s+$","")
		if t:match("^%x%x%x%x%x%x$") then
			local c = Color3.fromRGB(tonumber(t:sub(1,2),16), tonumber(t:sub(3,4),16), tonumber(t:sub(5,6),16))
			setBrushColor(c)
		else refresh() end
	end)
	rgbF.FocusLost:Connect(function(enter)
		if not enter then return end
		local r, g, b = rgbF.Text:match("(%d+)%s*,%s*(%d+)%s*,%s*(%d+)")
		if r then setBrushColor(Color3.fromRGB(math.clamp(tonumber(r),0,255), math.clamp(tonumber(g),0,255), math.clamp(tonumber(b),0,255))) else refresh() end
	end)
	hsvF.FocusLost:Connect(function(enter)
		if not enter then return end
		local h, s, v = hsvF.Text:match("([%d%.]+)%s*,%s*([%d%.]+)%s*,%s*([%d%.]+)")
		if h then setHSV((tonumber(h)%360)/360, tonumber(s)/100, tonumber(v)/100) else refresh() end
	end)
	refresh()
end

slider("Brush Size (cap 1.2)", 0.05, SIZE_CAP, function() return Brush.size end, function(v) Brush.size = v end, "%.2f")
slider("Opacity", 0.05, 1, function() return Brush.opacity end, function(v) Brush.opacity = v end, "%.2f")
slider("Layer", 1, 10, function() return Brush.layer end, function(v) Brush.layer = math.floor(v+0.5) end, "%d")
btn("Shape: Octagon", function(b)
	local order = { "Octagon", "Square", "Triangle" }
	for i, s in ipairs(order) do if s == Brush.shape then Brush.shape = order[i % #order + 1] break end end
	b.Text = "Shape: " .. Brush.shape; applyBrush()
end)
toggle("Enforce Brush (manual paint)", function() return Hub.enforce end, function(v) Hub.enforce = v end)
toggle("Human Mode (safer, slower)", function() return Hub.human end, function(v) Hub.human = v end)
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
local urlBox = new("TextBox", { Size = UDim2.new(1,0,0,30), BackgroundColor3 = Color3.fromRGB(15,16,19), BorderSizePixel = 0, PlaceholderText = "paste PNG image URL here, press 🖼 to draw", Text = "", TextColor3 = TXT, PlaceholderColor3 = DIM, Font = Enum.Font.Gotham, TextSize = 11, ClearTextOnFocus = false, TextXAlignment = Enum.TextXAlignment.Left }, scroll)
corner(urlBox, 6); pad(urlBox, 10, 0, 10, 0)
Image.urlBox = urlBox
urlBox.FocusLost:Connect(function(enter)
	if enter and urlBox.Text:match("^https?://") then
		getgenv().__imgurl = urlBox.Text
		print("[SPRAYHUB-URL] " .. urlBox.Text)
	end
end)
slider("px size (studs)", 0.2, 1.2, function() return Image.cell end, function(v) Image.cell = v end, "%.2f")
slider("img resolution (px wide)", 16, 128, function() return Image.maxW end, function(v) Image.maxW = math.floor(v+0.5) Image.maxH = math.floor(v*0.9+0.5) end, "%d")
btn("🖼 Load URL & Place (click a wall)", function()
	local url = urlBox.Text:match("^https?://") and urlBox.Text or getgenv().__imgurl
	if not url then setStatus("paste an image URL first") return end
	getgenv().__imgurl = url
	loadImageFromUrl(url)
end)
btn("👁 Toggle Cursor Preview", function(b)
	Image.previewOn = not Image.previewOn
	Image.armed = false
	setStatus(Image.previewOn and "preview ON — move mouse on a wall" or "preview OFF")
end)
btn("🎯 Place Loaded Image Here", function()
	if not (getgenv().__imgdata and getgenv().__imgdata.px) then setStatus("no image loaded") return end
	Image.armed = true
	Image.previewOn = false
	setStatus("click a wall to place")
end)

-- text paint
section "Text Paint (bitmap font)"
local textBox = new("TextBox", { Size = UDim2.new(1,0,0,44), BackgroundColor3 = Color3.fromRGB(15,16,19), BorderSizePixel = 0, PlaceholderText = "type text here (A-Z 0-9, <3 = heart; Enter = new line)", Text = "", TextColor3 = TXT, PlaceholderColor3 = DIM, Font = Enum.Font.Gotham, TextSize = 11, ClearTextOnFocus = false, MultiLine = true, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top }, scroll)
corner(textBox, 6); pad(textBox, 10, 6, 10, 6)
btn("🔤 Arm Text — click a wall (uses brush color)", function()
	armText(textBox.Text, Brush.color)
end)

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
Hub.textToImage = textToImage
Hub.armText = armText
Hub.font = FONT
Hub.setPreview = function(v) Image.previewOn = v end
applyBrush()
setStatus("v2 ready — size cap " .. SIZE_CAP .. ", effects need gamepass")
print("[SprayHub v2] loaded. MaxDist=" .. tostring(MAX_DIST) .. " SizeCap=" .. SIZE_CAP)
