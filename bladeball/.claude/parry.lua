-------------------------------------------------------------------------
-- Blade Ball local auto-parry for Matcha -- TARGET-SPAM build.
-- No geometry, no timing, no tuning. Live-confirmed: the real ball's
-- `target` attribute == your name the whole time the ball is yours and
-- flips away only when it bounces off you. So: while a realBall targets
-- you, spam the parry. The game's own cooldown ignores early clicks.
-- T toggles. P menu. Re-executing replaces the previous copy.
-------------------------------------------------------------------------

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
assert(player, "LocalPlayer is unavailable; run this as a client script")

if _G.BB_MATCHA_STOP then pcall(_G.BB_MATCHA_STOP) end

local CONFIG = {
	enabled = true,
	ballsFolder = "Balls",
	spamInterval = 0.05,          -- ms between parry clicks while the ball targets you
	spamRange = 60,               -- outer zone: throttled spam when the targeting ball is this near
	contactRange = 25,            -- inner zone: click EVERY frame (ignore interval) so a press always
	                              -- lands on the contact frame no matter how fast/curvy the ball is
	parryMode = "Remote",         -- "Remote" (net parry RemoteEvent:FireServer(true) -- focus-independent,
	                              -- no sword swing), "Click" (mouse1click), "Touch" (firetouchinterest, experimental)
	accuracy = 100,               -- % of parry clicks actually taken
	randomizeAccuracy = false, randomAccMin = 50, randomAccMax = 90,
	-- Interactions (executor fns)
	autoPrompt = false, autoPromptRange = 20,
	autoClick = false, autoClickRange = 20, interactInterval = 0.4,
}

local running = true
local lastSpamParry = -math.huge
local lastInteract = -math.huge
local parryCount = 0
local menuOpen = false
local targeting = false        -- a real ball currently targets you (for HUD)

-- ---- Ball / character reads ----
local function finite(n)
	return type(n) == "number" and n == n and math.abs(n) < math.huge
end

local function safeAttribute(instance, name)
	local ok, value = pcall(function() return instance:GetAttribute(name) end)
	if ok then return value end
	return nil
end

local function getBallPart(object)
	local ok, cls = pcall(function() return object.ClassName end)
	if ok and (cls == "Part" or cls == "MeshPart" or cls == "UnionOperation") then return object end
	local findOk, part = pcall(function() return object:FindFirstChildWhichIsA("BasePart", true) end)
	if findOk then return part end
	return nil
end

local function readBall(object)
	local part = getBallPart(object)
	if not part then return nil end
	local posOk, position = pcall(function() return part.Position end)
	if not posOk or not position or not finite(position.Magnitude) then return nil end
	local real = safeAttribute(object, "realBall")
	if real == nil and object ~= part then real = safeAttribute(part, "realBall") end
	if real == false then return nil end
	local target = safeAttribute(object, "target") or safeAttribute(object, "Target")
	if target == nil and object ~= part then
		target = safeAttribute(part, "target") or safeAttribute(part, "Target")
	end
	return {object = object, part = part, position = position, real = real, target = target}
end

local function getRoot()
	local character = player.Character
	if not character then return nil end
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root then return nil end
	local alive = Workspace:FindFirstChild("Alive")
	local parent = character.Parent
	if alive and (not parent or parent.Address ~= alive.Address) then return nil end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.Health <= 0 then return nil end
	if safeAttribute(character, "Stunned") or safeAttribute(character, "PULSED") then return nil end
	return root
end

-- ---- Parry input ----
-- Blade Ball parry RemoteEvent (from Remote Spy): a sleitnick-net RE fired with a
-- single boolean. Resolved once; the obfuscated name can change on game updates,
-- so a nil result falls back to mouse1click.
local parryRemote
pcall(function()
	local pkgs = ReplicatedStorage:FindFirstChild("Packages")
	local idx = pkgs and pkgs:FindFirstChild("_Index")
	local sl = idx and idx:FindFirstChild("sleitnick_net@0.1.0")
	local net = sl and sl:FindFirstChild("net")
	parryRemote = net and net:FindFirstChild(
		"RE/a7e95fad55babeade0506d1ab663c0f121a12316263d5acd614d34ac2e76e945")
end)

local function fireParry(ball, root)
	if CONFIG.parryMode == "Remote" and parryRemote then
		return (pcall(function() parryRemote:FireServer(true) end))
	end
	if CONFIG.parryMode == "Touch" and type(firetouchinterest) == "function"
		and ball and ball.part and root then
		-- EXPERIMENTAL: a touch registers the ball as HITTING you, not a parry.
		return (pcall(function()
			firetouchinterest(root, ball.part, 0)
			firetouchinterest(root, ball.part, 1)
		end))
	end
	local click = mouse1click or mouse2click
	if type(click) ~= "function" then
		warn("Matcha does not expose mouse1click or mouse2click")
		return false
	end
	local ok, result = pcall(click)
	return ok and result ~= false
end

local function passesAccuracy()
	local acc = CONFIG.accuracy
	if CONFIG.randomizeAccuracy then
		local lo, hi = CONFIG.randomAccMin, CONFIG.randomAccMax
		if lo > hi then lo, hi = hi, lo end
		acc = math.random(math.floor(lo), math.floor(hi))
	end
	if acc >= 100 then return true end
	if acc <= 0 then return false end
	return math.random(1, 100) <= acc
end

-- ---- Core: spam while the real ball targets you ----
local function targetSpamParry(root, now)
	if not CONFIG.enabled or menuOpen then targeting = false; return end
	if type(isrbxactive) == "function" and not isrbxactive() then return end
	local folder = Workspace:FindFirstChild(CONFIG.ballsFolder)
	if not folder then targeting = false; return end
	local me = player.Name
	local rootPos = root.Position
	-- Nearest real ball that targets you.
	local mine, mineDist = nil, math.huge
	for _, obj in ipairs(folder:GetChildren()) do
		local ball = readBall(obj)
		if ball and ball.real ~= false and ball.target == me then
			local d = (rootPos - ball.position).Magnitude
			if d < mineDist then mine, mineDist = ball, d end
		end
	end
	targeting = mine ~= nil and mineDist <= CONFIG.spamRange
	if not targeting then return end
	-- Inner zone: react to the real position every frame (curve/speed-proof, no
	-- prediction). Outer zone: throttle so it doesn't swing nonstop while closing.
	if mineDist > CONFIG.contactRange and now - lastSpamParry < CONFIG.spamInterval then return end
	if not passesAccuracy() then lastSpamParry = now; return end
	if fireParry(mine, root) then
		lastSpamParry = now
		parryCount = parryCount + 1
	end
end

-- ---- Interactions (executor fns fireproximityprompt / fireclickdetector) ----
local function instanceWorldPos(inst)
	local node = inst.Parent
	for _ = 1, 4 do
		if not node then return nil end
		local okC, cls = pcall(function() return node.ClassName end)
		if okC and (cls == "Part" or cls == "MeshPart" or cls == "UnionOperation"
			or cls == "Seat" or cls == "VehicleSeat") then
			local ok, pos = pcall(function() return node.Position end)
			if ok and pos then return pos end
		end
		local okA, isAtt = pcall(function() return node.ClassName == "Attachment" end)
		if okA and isAtt then
			local ok, pos = pcall(function() return node.WorldPosition end)
			if ok and pos then return pos end
		end
		node = node.Parent
	end
	return nil
end

local function runInteractions(root, now)
	if not root or (not CONFIG.autoPrompt and not CONFIG.autoClick) then return end
	if now - lastInteract < CONFIG.interactInterval then return end
	lastInteract = now
	local rootPos = root.Position
	-- shortcut: full Workspace scan each interval; fine while gated off by default.
	local ok, descendants = pcall(function() return Workspace:GetDescendants() end)
	if not ok or not descendants then return end
	for _, d in ipairs(descendants) do
		local cls = d.ClassName
		if cls == "ProximityPrompt" and CONFIG.autoPrompt and type(fireproximityprompt) == "function" then
			local pos = instanceWorldPos(d)
			if pos and (rootPos - pos).Magnitude <= CONFIG.autoPromptRange then pcall(fireproximityprompt, d) end
		elseif cls == "ClickDetector" and CONFIG.autoClick and type(fireclickdetector) == "function" then
			local pos = instanceWorldPos(d)
			if pos and (rootPos - pos).Magnitude <= CONFIG.autoClickRange then pcall(fireclickdetector, d, 0, "MouseClick") end
		end
	end
end

-- ======================= UI (INS-ui Drawing lib) =======================
local fetched, chunkOrErr = pcall(function()
	return game:HttpGet("https://raw.githubusercontent.com/neaxusxgod-png/INS-ui/main/uilib.min.lua")
end)
assert(fetched and type(chunkOrErr) == "string", "Could not download INS-ui")
local uiChunk, compileError = loadstring(chunkOrErr)
assert(uiChunk, "Could not compile INS-ui: " .. tostring(compileError))
local Lib = uiChunk() or (type(INSUI) ~= "nil" and INSUI) or _G["INSUI"]
assert(type(Lib) == "table" and type(Lib.CreateWindow) == "function", "Invalid INS-ui library")

local statusText = "Waiting for ball"

local Window = Lib:CreateWindow({title = "Matcha", subtitle = "Target-Spam Parry",
	size = Vector2.new(560, 440), menuKey = "p"})

local Main = Window:Tab("Auto Parry", "sword")
local Controls = Main:Section("Auto Parry", "Left",
	"Spams the parry while the real ball's target is you. T toggles.")
Controls:Toggle("Auto parry", CONFIG.enabled, function(v) CONFIG.enabled = v end,
	"Spam parry while a real ball targets you."):AddKeybind("t", "Toggle")
Controls:Slider("Spam interval", CONFIG.spamInterval * 1000, 1, 20, 150, " ms",
	function(v) CONFIG.spamInterval = v / 1000 end)
Controls:Slider("Spam range", CONFIG.spamRange, 1, 10, 140, " st", function(v) CONFIG.spamRange = v end)
Controls:Slider("Contact range (every-frame)", CONFIG.contactRange, 1, 5, 80, " st", function(v) CONFIG.contactRange = v end)
Controls:Slider("Accuracy", CONFIG.accuracy, 1, 0, 100, "%", function(v) CONFIG.accuracy = v end)
Controls:Toggle("Parry via remote (recommended)", CONFIG.parryMode == "Remote",
	function(v) CONFIG.parryMode = v and "Remote" or "Click" end,
	"Fire the game's parry RemoteEvent directly. Focus-independent, no sword swing. Off = mouse1click. Falls back to mouse1click if the remote isn't found.")
Controls:Toggle("Parry via touch (experimental)", CONFIG.parryMode == "Touch",
	function(v) CONFIG.parryMode = v and "Touch" or "Click" end,
	"Fire the ball's TouchInterest instead of mouse1click. In Blade Ball a touch registers as a HIT, not a parry -- leave OFF for real play.")

local StatusSec = Main:Section("Live status", "Right")
StatusSec:Label(function() return statusText end)
StatusSec:Button("Unload script", function() if _G.BB_MATCHA_STOP then _G.BB_MATCHA_STOP() end end)

local Interact = Window:Tab("Interactions", "wrench")
local InteractSec = Interact:Section("Auto interact", "Left",
	"Fire nearby ProximityPrompts and ClickDetectors.")
InteractSec:Toggle("Auto proximity prompts", CONFIG.autoPrompt, function(v) CONFIG.autoPrompt = v end,
	"fireproximityprompt on prompts within range.")
InteractSec:Slider("Prompt range", CONFIG.autoPromptRange, 1, 5, 80, " st", function(v) CONFIG.autoPromptRange = v end)
InteractSec:Toggle("Auto click detectors", CONFIG.autoClick, function(v) CONFIG.autoClick = v end,
	"fireclickdetector on ClickDetectors within range.")
InteractSec:Slider("Click range", CONFIG.autoClickRange, 1, 5, 80, " st", function(v) CONFIG.autoClickRange = v end)

-- ======================= Update loop =======================
local function update()
	if not running then return end
	local now = tick()
	local root = getRoot()
	if root then targetSpamParry(root, now) else targeting = false end
	if root then pcall(runInteractions, root, now) end
	statusText = string.format("%s | %s | Attempts: %d",
		CONFIG.enabled and "Active" or "Disabled",
		targeting and "Ball targeting YOU" or "No incoming ball", parryCount)
end

local renderSignal = RunService.RenderStepped or RunService.Heartbeat
assert(renderSignal, "Matcha exposes neither RenderStepped nor Heartbeat")
local renderConnection = renderSignal:Connect(update)
-- Post-physics pass: ball target replicates here too; catches a flip a frame sooner.
local heartbeatConnection = nil
if RunService.Heartbeat and RunService.Heartbeat ~= renderSignal then
	heartbeatConnection = RunService.Heartbeat:Connect(update)
end
-- Pre-physics pass: ball position updates here too. Three passes/frame shrink the
-- gap between samples so a 240+ speed ball can't cross the contact zone unseen.
local preSimConnection = nil
if RunService.PreSimulation and RunService.PreSimulation ~= renderSignal
	and RunService.PreSimulation ~= RunService.Heartbeat then
	preSimConnection = RunService.PreSimulation:Connect(update)
end

_G.BB_MATCHA_STOP = function()
	running = false
	if renderConnection then renderConnection:Disconnect() end
	if heartbeatConnection then heartbeatConnection:Disconnect() end
	if preSimConnection then preSimConnection:Disconnect() end
	pcall(function() Lib:Destroy() end)
	_G.BB_MATCHA_STOP = nil
	_G.BB_MATCHA_STATUS = nil
end

_G.BB_MATCHA_STATUS = function()
	return {enabled = CONFIG.enabled, menuOpen = menuOpen, targeting = targeting,
		attempts = parryCount, spamIntervalMs = CONFIG.spamInterval * 1000,
		parryMode = CONFIG.parryMode, parryRemoteFound = parryRemote ~= nil}
end

print("Target-spam auto-parry loaded (P menu, T toggle)")
