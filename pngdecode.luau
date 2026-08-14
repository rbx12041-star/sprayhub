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
