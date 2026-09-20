-- Run from the server (for example, the Studio server command bar).
-- Requires Game Settings > Security > Allow HTTP Requests and
-- ServerScriptService.LoadStringEnabled to be enabled.

local HttpService = game:GetService("HttpService")
local SOURCE_URL = "https://raw.githubusercontent.com/Hungrychud/roblox/master/bladeball/.claude/parry.lua"

local ok, source = pcall(function()
	return HttpService:GetAsync(SOURCE_URL, true)
end)

assert(ok, "Could not download parry.lua: " .. tostring(source))

local chunk, compileError = loadstring(source)
assert(chunk, "Could not compile parry.lua: " .. tostring(compileError))

return chunk()
