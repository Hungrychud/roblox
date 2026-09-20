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
	sameBallRetry = 0.18,
	fallback = true,
}

local running = true
local lastClick = 0
local firedAt = {}
local tracked = {}
local renderConnection = nil
local inputConnection = nil
local currentThreat = nil
local lastPing = 0
local parryCount = 0
local guiVisible = true
local drawings = {}
local buttons = {}

-------------------------------------------------------------------------
-- Matcha Drawing GUI
-------------------------------------------------------------------------
local GUI = {
	x = 20,
	y = 100,
	w = 270,
	row = 29,
	background = nil,
	title = nil,
	status = nil,
	ready = false,
}

local function setDrawing(object, properties)
	if not object then return end
	for key, value in pairs(properties) do
		pcall(function() object[key] = value end)
	end
end

local function newDrawing(kind, properties)
	if Drawing == nil or type(Drawing.new) ~= "function" then return nil end
	local ok, object = pcall(function() return Drawing.new(kind) end)
	if not ok or not object then return nil end
	drawings[#drawings + 1] = object
	setDrawing(object, properties)
	return object
end

local function addButton(y, xOffset, width, label, action)
	local button = {
		x = GUI.x + xOffset,
		y = y,
		w = width,
		h = 24,
		label = label,
		action = action,
	}
	button.box = newDrawing("Square", {
		Position = Vector2.new(button.x, button.y),
		Size = Vector2.new(button.w, button.h),
		Filled = true,
		Color = Color3.fromRGB(34, 39, 52),
		Transparency = 0.05,
		Thickness = 1,
		Visible = true,
	})
	button.text = newDrawing("Text", {
		Position = Vector2.new(button.x + 8, button.y + 5),
		Size = 14,
		Font = 2,
		Outline = true,
		Color = Color3.fromRGB(225, 230, 240),
		Visible = true,
	})
	buttons[#buttons + 1] = button
end

local function buildGui()
	GUI.background = newDrawing("Square", {
		Position = Vector2.new(GUI.x, GUI.y),
		Size = Vector2.new(GUI.w, 235),
		Filled = true,
		Color = Color3.fromRGB(15, 18, 27),
		Transparency = 0.06,
		Thickness = 1,
		Visible = true,
	})
	GUI.title = newDrawing("Text", {
		Position = Vector2.new(GUI.x + 10, GUI.y + 9),
		Text = "MATCHA AUTO PARRY",
		Size = 17,
		Font = 2,
		Outline = true,
		Color = Color3.fromRGB(100, 210, 255),
		Visible = true,
	})
	GUI.status = newDrawing("Text", {
		Position = Vector2.new(GUI.x + 10, GUI.y + 34),
		Size = 13,
		Font = 2,
		Outline = true,
		Color = Color3.fromRGB(180, 190, 205),
		Visible = true,
	})

	local y = GUI.y + 61
	addButton(y, 8, GUI.w - 16, function()
		return "Auto parry: " .. (CONFIG.enabled and "ON" or "OFF") .. "  [T]"
	end, function() CONFIG.enabled = not CONFIG.enabled end)
	y = y + GUI.row
	addButton(y, 8, GUI.w - 16, function()
		return "Fallback targeting: " .. (CONFIG.fallback and "ON" or "OFF")
	end, function() CONFIG.fallback = not CONFIG.fallback end)
	y = y + GUI.row
	addButton(y, 8, GUI.w - 16, function()
		return "Ping compensation: " .. (CONFIG.pingComp and "ON" or "OFF")
	end, function() CONFIG.pingComp = not CONFIG.pingComp end)
	y = y + GUI.row
	addButton(y, 8, 124, function()
		return "Lead -  (" .. math.floor(CONFIG.baseLead * 1000) .. "ms)"
	end, function() CONFIG.baseLead = math.max(0.02, CONFIG.baseLead - 0.01) end)
	addButton(y, 138, 124, function() return "Lead +" end,
		function() CONFIG.baseLead = math.min(CONFIG.maxLead, CONFIG.baseLead + 0.01) end)
	y = y + GUI.row
	addButton(y, 8, 124, function()
		return "Range -  (" .. math.floor(CONFIG.maxRange) .. ")"
	end, function() CONFIG.maxRange = math.max(30, CONFIG.maxRange - 10) end)
	addButton(y, 138, 124, function() return "Range +" end,
		function() CONFIG.maxRange = math.min(300, CONFIG.maxRange + 10) end)

	GUI.ready = GUI.background ~= nil and GUI.title ~= nil and GUI.status ~= nil
end

local function updateGui()
	if not GUI.ready then return end
	for _, object in ipairs(drawings) do
		pcall(function() object.Visible = guiVisible end)
	end
	if not guiVisible then return end

	local stateColor = CONFIG.enabled and Color3.fromRGB(100, 235, 145)
		or Color3.fromRGB(255, 105, 105)
	setDrawing(GUI.title, {Color = stateColor})

	local threatText = "no incoming ball"
	if currentThreat then
		threatText = string.format("ball %.2fs | %s", currentThreat.tti,
			currentThreat.aimed and "TARGETED" or "fallback")
	end
	setDrawing(GUI.status, {
		Text = string.format("%s\nping %dms | attempts %d", threatText,
			math.floor(lastPing * 1000), parryCount),
	})

	for _, button in ipairs(buttons) do
		local text = type(button.label) == "function" and button.label() or button.label
		setDrawing(button.text, {Text = text})
	end
end

buildGui()

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
				state.target = ball.target
			end
			if distance > 0.001 and ball.velocity:Dot(offset / distance) <= 0 then
				firedAt[key] = nil
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
	if not CONFIG.enabled or not threat then return end

	local pingLead = CONFIG.pingComp and lastPing * CONFIG.pingFactor or 0
	local lead = math.min(CONFIG.maxLead, CONFIG.baseLead + pingLead)
	if threat.tti > lead then return end

	local now = os.clock()
	if now - lastClick < CONFIG.minInterval then return end

	local key = ballKey(threat.ball)
	local previous = firedAt[key]
	-- One input per approach. Re-arm on a target change or outgoing motion.
	if previous then return end
	if type(isrbxactive) == "function" and not isrbxactive() then return end

	if fireParry() then
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

local UserInputService = game:GetService("UserInputService")
local inputOk, inputSignal = pcall(function()
	return UserInputService.InputBegan
end)
if inputOk and inputSignal then
	inputConnection = inputSignal:Connect(function(input)
		local ok, keyCode = pcall(function()
			return input.KeyCode
		end)
		if ok and (keyCode == Enum.KeyCode.T or keyCode == 84) then
			CONFIG.enabled = not CONFIG.enabled
			print("Matcha auto-parry " .. (CONFIG.enabled and "enabled" or "disabled"))
		elseif ok and (keyCode == Enum.KeyCode.P or keyCode == 80) then
			guiVisible = not guiVisible
			updateGui()
		end

		local mouseOk, inputType, position = pcall(function()
			return input.UserInputType, input.Position
		end)
		if mouseOk and inputType == Enum.UserInputType.MouseButton1 and guiVisible and position then
			for _, button in ipairs(buttons) do
				if position.X >= button.x and position.X <= button.x + button.w
					and position.Y >= button.y and position.Y <= button.y + button.h then
					button.action()
					updateGui()
					break
				end
			end
		end
	end)
end

_G.BB_MATCHA_STOP = function()
	running = false
	if renderConnection then renderConnection:Disconnect() end
	if inputConnection then inputConnection:Disconnect() end
	for _, object in ipairs(drawings) do
		pcall(function() object:Remove() end)
	end
	firedAt = {}
	_G.BB_MATCHA_STOP = nil
end

print("Matcha local auto-parry loaded (T toggle, P show/hide GUI)")
