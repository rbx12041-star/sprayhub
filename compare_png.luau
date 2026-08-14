-- compare_png.luau — verify pngdecode.luau against img2grid.js ground truth.
-- Usage: lune run compare_png.luau <file.png> <groundtruth.luau> [maxW] [maxH]
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local PngDecode = require("./pngdecode")

local file, truthFile = process.args[1], process.args[2]
local maxW = tonumber(process.args[3] or "1000")
local maxH = tonumber(process.args[4] or "1000")

-- ground truth from img2grid.js (a luau that sets getgenv().__imgdata)
local env = {}
local chunks = setmetatable({}, { __index = function() return function() end end })
getgenv = function() return env end
local fn = luau.load(fs.readFile(truthFile), { environment = setmetatable({ getgenv = getgenv }, { __index = getfenv(0) }) })
fn()
local truth = env.__imgdata
assert(truth and truth.px, "no ground truth imgdata")

-- ours
local img, err = PngDecode.decode(fs.readFile(file))
assert(img, "decode failed: " .. tostring(err))
local grid = PngDecode.toGrid(img, maxW, maxH)

local function key(e) return e[1] .. ":" .. e[2] end
local oursMap = {}
for _, e in ipairs(grid.px) do oursMap[key(e)] = e end
local truthMap = {}
for _, e in ipairs(truth.px) do truthMap[key(e)] = e end

local mismatches, missing, extra = 0, 0, 0
for k, e in pairs(truthMap) do
	local o = oursMap[k]
	if not o then
		missing += 1
		if missing <= 3 then print("missing px " .. k .. " truth=" .. e[3] .. "," .. e[4]) end
	elseif o[3] ~= e[3] or o[4] ~= e[4] then
		mismatches += 1
		if mismatches <= 3 then print("mismatch px " .. k .. " ours=" .. o[3] .. "," .. o[4] .. " truth=" .. e[3] .. "," .. e[4]) end
	end
end
for k in pairs(oursMap) do
	if not truthMap[k] then extra += 1 end
end

print(("%s: dims ours=%dx%d truth=%dx%d | ours n=%d truth n=%d | missing=%d mismatch=%d extra=%d"):format(
	file, grid.w, grid.h, truth.w, truth.h, grid.n, truth.n, missing, mismatches, extra))
if grid.w ~= truth.w or grid.h ~= truth.h or missing > 0 or mismatches > 0 or extra > 0 then
	print("RESULT: FAIL")
	process.exit(1)
end
print("RESULT: PASS")
