local luau = require("@lune/luau")
T = {}
luau.load("T.x = 1 function setX(v) T.x = v end")()
print("direct read after load:", T.x) -- expect 1
setX(42)
print("after setX:", T.x) -- expect 42 if envs shared

-- now mimic: global Hub table + loaded chunk function writes a field, test reads it
Hub2 = { vimDown = false }
local f = luau.load([[
local function press(d) Hub2.vimDown = d end
return function()
	press(true)
	return Hub2.vimDown
end
]])()
print("chunk-internal read after press(true):", f()) -- expect true
print("test-side read:", Hub2.vimDown) -- expect true

-- and with a coroutine + task suspension in between
local taskx = require("@lune/task")
local g = luau.load([[
local function press(d) Hub2.vimDown = d end
return function()
	local co = coroutine.create(function()
		press(true)
		task.wait(0.01)
		print("in-coroutine read:", Hub2.vimDown)
	end)
	coroutine.resume(co)
	return co
end
]])()
taskx.wait(0.1)
print("test-side read after coroutine:", Hub2.vimDown)
