--// BUG#1 TEST: group-by-color per-stroke flush ---------------------------
-- Hypothesis: server accepts ONE color per batch/stroke, dedups mixed-color
-- batches to one blob. Test: paint each color as its own stroke + flush.
-- If all 16 blobs persist -> fix is a per-color multi-flush in runPaintJob.

local RS = game:GetService("ReplicatedStorage")
local LP = game:GetService("Players").LocalPlayer
local PaintPositioning = require(RS.Modules.Paint.PaintPositioning)
local ClientToServer   = require(RS.Modules.Paint.ClientToServer)
local MakePaint        = require(RS.Modules.Paint.MakePaint)
local WarnModule       = require(RS.Modules.Print.WarnModule)
local UndoRedo         = RS:FindFirstChild("UndoRedoServer") and RS.UndoRedoServer:FindFirstChild("LogUndoRedoEvent")
local Hub = getgenv().__SprayHub
local PS = LP:WaitForChild("PaintSettings")
local FLUSH_RATE = workspace:GetAttribute("PaintUpdateRate") or 0.25

local COLORS = {
	Color3.fromRGB(255, 0, 0),
	Color3.fromRGB(0, 200, 80),
	Color3.fromRGB(40, 120, 255),
	Color3.fromRGB(255, 230, 0),
}

local function faceCFrame(pos, normal)
	return CFrame.lookAt(pos, pos + normal) * CFrame.Angles(-math.pi / 2, 0, 0)
end

-- snapshot live parts on layer 1 (non-Client = server-replicated)
local function liveCount()
	local pf = workspace:FindFirstChild("PaintFolder")
	local mine = pf and pf:FindFirstChild(LP.Name)
	local l = mine and mine:FindFirstChild("1")
	if not l then return 0 end
	local n = 0
	for _, d in ipairs(l:GetDescendants()) do
		if d:IsA("BasePart") and not d:HasTag("Client") then n += 1 end
	end
	return n
end

local before = liveCount()
getgenv().__colortest = { phase = "start", before = before }

task.spawn(function()
	local f = Hub.aimFrame()
	if not f then getgenv().__colortest.phase = "no-aim" return end
	local oldEnforce = Hub.enforce
	Hub.enforce = false -- stop hub's 0.25s attr re-assert from stomping per-blob attrs

	local step = 0.35 -- spacing between blobs
	local made = 0
	for ci, col in ipairs(COLORS) do
		-- new stroke per color
		PS:SetAttribute("Stroke", (PS:GetAttribute("Stroke") or 0) + 1)
		if UndoRedo then pcall(function() UndoRedo:InvokeServer({ Type = "Paint", Stroke = PS:GetAttribute("Stroke") }) end) end

		for i = 0, 3 do
			-- 4 blobs per color in a horizontal row, one row per color
			local world = f.origin + f.right * ((i - 1.5) * step) + f.up * ((ci - 2.5) * step)
			local cf = faceCFrame(world, f.normal)
			-- re-assert ALL attrs right before the make
			PS:SetAttribute("Color", col)
			PS:SetAttribute("Size", 0.6)
			PS:SetAttribute("BrushShape", "Octagon")
			PS:SetAttribute("Layer", 1)
			PS:SetAttribute("Opacity", 1)
			PS:SetAttribute("NeonEnabled", false)
			PS:SetAttribute("ChromeEnabled", false)
			PS:SetAttribute("RainbowEnabled", false)
			local inst, info = MakePaint.makePaintFromPaintSettings(PS, cf, true, nil, nil, nil)
			if inst then ClientToServer.cachePaint(inst, info) made += 1 end
			task.wait()
		end
		local k1, k2 = WarnModule()
		ClientToServer.sendToServer(k1, k2)
		task.wait(FLUSH_RATE + 0.1)
	end

	Hub.enforce = oldEnforce
	getgenv().__colortest.phase = "flushed"
	getgenv().__colortest.made = made
	print(("[COLORTEST] flushed %d blobs (%d colors x 4), before=%d"):format(made, #COLORS, before))

	-- settle past replication lag, then count
	task.wait(5)
	local after = liveCount()
	getgenv().__colortest.after5s = after
	getgenv().__colortest.delta = after - before
	getgenv().__colortest.phase = "done"
	print(("[COLORTEST] live parts: before=%d after=%d delta=%d (expect +%d)"):format(before, after, after - before, made))
end)
