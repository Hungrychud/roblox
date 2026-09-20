-------------------------------------------------------------------------
-- Blade Ball local auto-parry for Matcha
-- T toggles the script. Re-executing replaces the previous copy.
-------------------------------------------------------------------------

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
assert(player, "LocalPlayer is unavailable; run this as a client script")

if _G.BB_MATCHA_STOP then
	pcall(_G.BB_MATCHA_STOP)
end

local CONFIG = {
	enabled = true,
	ballsFolder = "Balls",
	minSpeed = 5,
	maxRange = 140,
	contactRadius = 4.5,
	targetedRadius = 18,
	baseLead = 0.12,
	pingComp = true,
	pingFactor = 0.75,
	maxLead = 0.42,
	minInterval = 0.055,
	clashEnabled = true,
	clashInterval = 0.018,
	clashRange = 22,
	clashMinSpeed = 70,
	clashRetry = 0.045,
	maxClashRetries = 2,
	fallback = true,
}

local running = true
local lastClick = 0
local firedAt = {}
local tracked = {}
local renderConnection = nil
local currentThreat = nil
local lastPing = 0
local parryCount = 0
local menuOpen = true
local lastUiUpdate = 0

-- Load the user-selected Matcha UI library.
local fetched, source = pcall(function()
	return game:HttpGet("https://scripts.wabisabi.mom/wabi-sabi-ui-lib.lua")
end)
assert(fetched and type(source) == "string", "Could not download WabiSabi UI")
local uiChunk, compileError = loadstring(source)
assert(uiChunk, "Could not compile WabiSabi: " .. tostring(compileError))
local loadedLibrary = uiChunk()
local Library = WabiSabi or loadedLibrary
assert(type(Library) == "table" and type(Library.CreateWindow) == "function", "Invalid WabiSabi UI")

local Window = Library:CreateWindow({
	Title = "Matcha",
	SubTitle = "Auto Parry",
	Size = Vector2.new(600, 520),
	Theme = "Ocean",
	MinimizeKey = "P",
})
local Main = Window:AddTab({Title = "Parry"})
Main:AddParagraph({
	Title = "Match controls",
	Content = "Drag the title bar to move. P minimizes the window; T toggles auto parry.\nAuto parry pauses while this window is open.",
})
local Controls = Main:AddSection("Features")
Controls:AddToggle({
	Id = "AutoParry", Title = "Auto parry", Default = CONFIG.enabled,
	Keybind = {Default = "T", Mode = "Toggle"},
	Callback = function(value) CONFIG.enabled = value end,
})
Controls:AddToggle({
	Id = "Clash", Title = "Close-range retries", Default = CONFIG.clashEnabled,
	Description = "Allow bounded retries during fast, close exchanges.",
	Callback = function(value) CONFIG.clashEnabled = value end,
})
Controls:AddToggle({
	Id = "Fallback", Title = "Fallback targeting", Default = CONFIG.fallback,
	Description = "Consider incoming real balls whose target is unknown.",
	Callback = function(value) CONFIG.fallback = value end,
})
Controls:AddToggle({
	Id = "Ping", Title = "Ping compensation", Default = CONFIG.pingComp,
	Callback = function(value) CONFIG.pingComp = value end,
})
local Status = Main:AddParagraph({Title = "Live status", Content = "Waiting for ball"})

local Timing = Window:AddTab({Title = "Timing"})
Timing:AddSlider({
	Id = "Lead", Title = "Reaction lead (ms)", Default = CONFIG.baseLead * 1000,
	Min = 20, Max = CONFIG.maxLead * 1000, Rounding = 0,
	Callback = function(value) CONFIG.baseLead = value / 1000 end,
})
Timing:AddSlider({
	Id = "Range", Title = "Detection range (studs)", Default = CONFIG.maxRange,
	Min = 30, Max = 300, Rounding = 0,
	Callback = function(value) CONFIG.maxRange = value end,
})
Timing:AddSlider({
	Id = "ClashRange", Title = "Close-range distance (studs)", Default = CONFIG.clashRange,
	Min = 8, Max = 40, Rounding = 0,
	Callback = function(value) CONFIG.clashRange = value end,
})

local Interface = Window:AddTab({Title = "Interface"})
Interface:AddDropdown({
	Title = "Theme", Options = {"Ocean", "Dark", "Aqua", "Amethyst", "Rose", "Darker"},
	Default = "Ocean", Callback = function(value) Library:SetTheme(value) end,
})
Interface:AddButton({
	Title = "Minimize and play", Callback = function() Library:Minimize() end,
})
Interface:AddButton({
	Title = "Unload script", Callback = function()
		if _G.BB_MATCHA_STOP then _G.BB_MATCHA_STOP() end
	end,
})
Library:OnMinimized(function(minimized) menuOpen = not minimized end)

local function updateGui()
	local now = os.clock()
	if now - lastUiUpdate < 0.15 then return end
	lastUiUpdate = now
	local mode = not CONFIG.enabled and "Disabled" or (menuOpen and "Paused while menu is open" or "Active")
	local threat = currentThreat and string.format("Incoming: %.2fs", currentThreat.tti) or "Waiting for ball"
	Status:SetContent(string.format("%s | %s\nPing: %d ms | Attempts: %d", mode, threat, math.floor(lastPing * 1000), parryCount))
end

local function safeAttribute(instance, name)
	local ok, value = pcall(function()
		return instance:GetAttribute(name)
	end)
	if ok then return value end
	return nil
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
	if safeAttribute(character, "Stunned") or safeAttribute(character, "PULSED") then
		return nil
	end

	return root
end

local function getBallPart(object)
	local ok, isPart = pcall(function()
		return object.ClassName == "Part" or object.ClassName == "MeshPart" or object.ClassName == "UnionOperation"
	end)
	if ok and isPart then return object end

	local modelOk, isModel = pcall(function()
		return object.ClassName == "Model"
	end)
	if modelOk and isModel then
		local primaryOk, primary = pcall(function()
			return object.PrimaryPart
		end)
		if primaryOk and primary then return primary end

		local findOk, part = pcall(function()
			return object:FindFirstChildWhichIsA("BasePart", true)
		end)
		if findOk then return part end
	end

	return nil
end

local function readBall(object)
	local part = getBallPart(object)
	if not part then return nil end

	local positionOk, position = pcall(function()
		return part.Position
	end)
	local velocityOk, velocity = pcall(function()
		return part.AssemblyLinearVelocity
	end)
	if not velocityOk or not velocity then
		velocityOk, velocity = pcall(function()
			return part.Velocity
		end)
	end
	if not positionOk or not velocityOk or not position or not velocity then
		return nil
	end

	local speed = velocity.Magnitude
	if speed < CONFIG.minSpeed then return nil end

	local realBall = safeAttribute(object, "realBall")
	if realBall == nil and object ~= part then
		realBall = safeAttribute(part, "realBall")
	end
	if realBall == false then return nil end

	local target = safeAttribute(object, "target") or safeAttribute(object, "Target")
	if target == nil and object ~= part then
		target = safeAttribute(part, "target") or safeAttribute(part, "Target")
	end

	return {
		object = object,
		part = part,
		position = position,
		velocity = velocity,
		speed = speed,
		target = target,
		real = realBall,
	}
end

local function ballKey(ball)
	local ok, address = pcall(function()
		return ball.object.Address
	end)
	if ok and address ~= nil then return address end
	return ball.object
end

local function pingSeconds()
	if type(GetPingValue) ~= "function" then return 0 end
	local ok, value = pcall(GetPingValue)
	if not ok or type(value) ~= "number" then return 0 end
	return math.clamp(value, 0, 400) / 1000
end

local function fireParry()
	local click = mouse1click
	if type(click) ~= "function" then
		click = mouse2click
	end
	if type(click) ~= "function" then
		warn("Matcha does not expose mouse1click or mouse2click")
		return false
	end
	local ok, result = pcall(click)
	return ok and result ~= false
end

local function chooseThreat(rootPosition)
	local folder = Workspace:FindFirstChild(CONFIG.ballsFolder)
	if not folder then return nil end

	local best = nil
	local bestTime = math.huge

	for _, object in ipairs(folder:GetChildren()) do
		local ball = readBall(object)
		if ball then
			local offset = rootPosition - ball.position
			local distance = offset.Magnitude
			local key = ballKey(ball)
			local state = tracked[key]
			if not state then state = {}; tracked[key] = state end
			state.seen = os.clock()
			if state.target ~= ball.target then
				firedAt[key] = nil
				state.retries = 0
				state.target = ball.target
			end
			if distance > 0.001 and ball.velocity:Dot(offset / distance) <= 0 then
				firedAt[key] = nil
				state.retries = 0
			end

			if distance > 0.001 and distance <= CONFIG.maxRange then
				local closing = ball.velocity:Dot(offset / distance)

				if closing > 0 then
					local closestTime = math.max(0, offset:Dot(ball.velocity) / (ball.speed * ball.speed))
					local closestPoint = ball.position + ball.velocity * closestTime
					local missDistance = (rootPosition - closestPoint).Magnitude
					local aimed = ball.target == player.Name
					local allowedMiss = aimed and CONFIG.targetedRadius or CONFIG.contactRadius
					local unknownTarget = ball.target == nil or ball.target == ""
					local eligible = ball.real == true and (aimed or (CONFIG.fallback and unknownTarget))

					if eligible and missDistance <= allowedMiss then
						local impactTime = math.max(0, (distance - CONFIG.contactRadius) / closing)
						if not best or (aimed and not best.aimed) or (aimed == best.aimed and impactTime < bestTime) then
							bestTime = impactTime
							best = {
								ball = ball,
								distance = distance,
								tti = impactTime,
								aimed = aimed,
							}
						end
					end
				end
			end
		end
	end

	return best
end

local function update()
	if not running then return end

	local root = getRoot()
	if not root then
		tracked = {}
		firedAt = {}
		currentThreat = nil
		updateGui()
		return
	end

	local threat = chooseThreat(root.Position)
	currentThreat = threat
	lastPing = pingSeconds()
	updateGui()
	if not CONFIG.enabled or not threat or menuOpen then return end

	local pingLead = CONFIG.pingComp and lastPing * CONFIG.pingFactor or 0
	local lead = math.min(CONFIG.maxLead, CONFIG.baseLead + pingLead)
	if threat.tti > lead then return end

	local now = os.clock()
	local clash = CONFIG.clashEnabled and threat.aimed and threat.distance <= CONFIG.clashRange
		and threat.ball.speed >= CONFIG.clashMinSpeed
	local interval = clash and CONFIG.clashInterval or CONFIG.minInterval
	if now - lastClick < interval then return end

	local key = ballKey(threat.ball)
	local previous = firedAt[key]
	local state = tracked[key]
	-- A complete close rebound can occur between replicated samples. Permit
	-- bounded retries only for a fast, nearby ball still targeting this player.
	if previous then
		if not clash or now - previous < CONFIG.clashRetry
			or (state.retries or 0) >= CONFIG.maxClashRetries then return end
	end
	if type(isrbxactive) == "function" and not isrbxactive() then return end

	if fireParry() then
		if previous then state.retries = (state.retries or 0) + 1 end
		lastClick = now
		firedAt[key] = now
		parryCount = parryCount + 1
	end

	for oldKey, state in pairs(tracked) do
		if now - state.seen > 2 then
			firedAt[oldKey] = nil
			tracked[oldKey] = nil
		end
	end
end

local renderSignal = RunService.RenderStepped or RunService.Heartbeat
assert(renderSignal, "Matcha exposes neither RenderStepped nor Heartbeat")
renderConnection = renderSignal:Connect(update)

_G.BB_MATCHA_STOP = function()
	running = false
	if renderConnection then renderConnection:Disconnect() end
	Library:Stop()
	firedAt = {}
	_G.BB_MATCHA_STOP = nil
end

Library:OnUnload(function()
	if running and _G.BB_MATCHA_STOP then _G.BB_MATCHA_STOP() end
end)

print("WabiSabi auto-parry loaded (P minimize/play, T toggle)")
