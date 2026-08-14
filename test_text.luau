local fs = require("@lune/fs")
local luau = require("@lune/luau")
local src = fs.readFile("C:/Users/Sebii/sprayhub_v1.luau")
local block = src:match("(%-%-// Text painter.-)\n%-%-// Image paint")
assert(block, "text painter block not found")
-- stub out game env: getgenv, and Image (the hub assigns the real one later)
block = block:gsub("local Image %-%- fwd%-decl[^\n]*", "local Image = { armed = false, previewOn = false }")
local harness = [==[
getgenv = function() return _G end
setStatus = function(s) _G.__status = s end
Brush = { color = { R = 1, G = 0, B = 0 } }
]==] .. block .. [==[
local data, skipped = textToImage("HI <3!", { R = 1, G = 0.5, B = 0 })
local grid = {}
for _, e in ipairs(data.px) do
	grid[e[2]] = grid[e[2]] or {}
	grid[e[2]][e[1]] = true
end
print(("w=%d h=%d n=%d skipped=%d"):format(data.w, data.h, data.n, skipped))
for y = 0, data.h - 1 do
	local row = ""
	for x = 0, data.w - 1 do
		row = row .. ((grid[y] and grid[y][x]) and "#" or ".")
	end
	print(row)
end
local d2, sk2 = textToImage("AB\nCD", { R = 0, G = 1, B = 0 })
print(("multiline: w=%d h=%d n=%d skipped=%d"):format(d2.w, d2.h, d2.n, sk2))
local px = d2.px[1]
print(("packed rgb sample: %d -> r=%d g=%d b=%d (expect 0,255,0)"):format(px[3], math.floor(px[3]/65536)%256, math.floor(px[3]/256)%256, px[3]%256))
local d3, sk3 = textToImage("\u{20AC}~", { R = 1, G = 1, B = 1 })
print(("unknown chars: n=%d skipped=%d (expect n=0 sk=4; 3 UTF-8 bytes + ~)"):format(d3.n, sk3))
assert(armText("OK", { R = 1, G = 1, B = 1 }) == true)
print("armText status: " .. tostring(_G.__status))
assert(armText("", { R = 1, G = 1, B = 1 }) == false)
print("armText empty status: " .. tostring(_G.__status))
local d4 = textToImage("abc", { R = 1, G = 1, B = 1 })
print(("lowercase abc: n=%d (expect >0)"):format(d4.n))
assert(d4.n > 0)
print("ALL TESTS PASSED")
]==]
local fn = luau.load(harness, { debugName = "texttest" })
fn()
