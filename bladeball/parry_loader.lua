local SOURCE_URL = "https://raw.githubusercontent.com/Hungrychud/roblox/master/bladeball/.claude/parry.lua"

local ok, source = pcall(function()
	-- Matcha/executor HTTP API.
	return game:HttpGet(SOURCE_URL, true)
end)

assert(ok, "Could not download parry.lua: " .. tostring(source))

local chunk, compileError = loadstring(source)
assert(chunk, "Could not compile parry.lua: " .. tostring(compileError))

return chunk()
