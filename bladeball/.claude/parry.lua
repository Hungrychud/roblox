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
local keysHeld = {}
local currentThreat = nil
local lastPing = 0
local parryCount = 0
local guiVisible = true
local drawings = {}
local buttons = {}
local mouse = player:GetMouse()
local mouseWasDown = false
local pointerOverGui = false

-------------------------------------------------------------------------
-- Matcha Drawing GUI
-------------------------------------------------------------------------
local GUI = {x = 30, y = 100, w = 320, h = 374, ready = false}
local layout = {}
local dragging = false
local dragX, dragY = 0, 0
local accent = Color3.fromRGB(104, 220, 190)
local muted = Color3.fromRGB(143, 156, 175)

local function setDrawing(object, properties)
	if not object then return end
	for key, value in pairs(properties) do pcall(function() object[key] = value end) end
end

local function draw(kind, x, y, properties)
	if Drawing == nil then return nil end
	local ok, object = pcall(function() return Drawing.new(kind) end)
	if not ok or not object then return nil end
	drawings[#drawings + 1] = object
	layout[#layout + 1] = {object = object, x = x, y = y}
	properties.Position = Vector2.new(GUI.x + x, GUI.y + y)
	properties.Visible = true
	properties.Transparency = properties.Transparency or 0
	setDrawing(object, properties)
	return object
end

local function rect(x, y, w, h, color, z)
	return draw("Square", x, y, {Size = Vector2.new(w, h), Filled = true,
		Color = color, Rounding = 8, ZIndex = z or 2})
end

local function label(x, y, text, size, color)
	return draw("Text", x, y, {Text = text, Size = size or 14, Font = 2,
		Color = color or Color3.fromRGB(229, 236, 244), ZIndex = 5})
end

local function moveGui(x, y)
	local camera = Workspace.CurrentCamera
	local viewport = camera and camera.ViewportSize
	if viewport then
		x = math.clamp(x, 0, math.max(0, viewport.X - GUI.w))
		y = math.clamp(y, 0, math.max(0, viewport.Y - GUI.h))
	end
	GUI.x, GUI.y = x, y
	for _, item in ipairs(layout) do
		setDrawing(item.object, {Position = Vector2.new(x + item.x, y + item.y)})
	end
end

local function toggle(y, title, key)
	local b = {x = 12, y = y, w = 296, h = 36, key = key}
	b.box = rect(b.x, b.y, b.w, b.h, Color3.fromRGB(27, 35, 48))
	label(24, y + 10, title)
	b.track = rect(252, y + 8, 44, 20, muted, 3)
	b.knob = rect(255, y + 11, 14, 14, Color3.fromRGB(241, 248, 250), 4)
	b.knobLayout = layout[#layout]
	b.action = function() CONFIG[key] = not CONFIG[key] end
	buttons[#buttons + 1] = b
end

local function stepper(y, title, key, step, low, high, scale, suffix)
	local value = label(24, y + 10, "", 14)
	for _, direction in ipairs({-1, 1}) do
		local x = direction == -1 and 238 or 274
		local b = {x = x, y = y, w = 30, h = 30}
		b.box = rect(x, y, 30, 30, Color3.fromRGB(35, 47, 62))
		label(x + 10, y + 6, direction == -1 and "-" or "+", 17, accent)
		b.action = function() CONFIG[key] = math.clamp(CONFIG[key] + direction * step, low, high) end
		buttons[#buttons + 1] = b
	end
	return function()
		setDrawing(value, {Text = title .. "   " .. math.floor(CONFIG[key] * scale + 0.5) .. suffix})
	end
end

rect(4, 5, GUI.w, GUI.h, Color3.fromRGB(7, 10, 16), 0)
GUI.background = rect(0, 0, GUI.w, GUI.h, Color3.fromRGB(17, 23, 33), 1)
rect(0, 0, GUI.w, 3, accent, 3)
GUI.title = label(18, 14, "MATCHA  /  PARRY", 18, accent)
label(18, 39, "Drag header to move", 12, muted)
GUI.badge = label(250, 17, "ACTIVE", 12, accent)
rect(12, 62, 296, 48, Color3.fromRGB(23, 31, 43))
GUI.status = label(24, 69, "Waiting for ball", 13, muted)
toggle(120, "Auto parry  [T]", "enabled")
toggle(160, "Close-range retries", "clashEnabled")
toggle(200, "Fallback targeting", "fallback")
toggle(240, "Ping compensation", "pingComp")
local refreshLead = stepper(284, "Reaction", "baseLead", 0.01, 0.02, CONFIG.maxLead, 1000, " ms")
local refreshRange = stepper(320, "Range", "maxRange", 10, 30, 300, 1, " studs")
label(18, 356, "P  show / hide     T  auto parry", 11, muted)
GUI.ready = GUI.background ~= nil

local function updateGui()
	if not GUI.ready then return end
	for _, object in ipairs(drawings) do setDrawing(object, {Visible = guiVisible}) end
	if not guiVisible then return end
	setDrawing(GUI.badge, {Text = CONFIG.enabled and "ACTIVE" or "PAUSED",
		Color = CONFIG.enabled and accent or muted})
	local status = currentThreat and string.format("Incoming %.2fs", currentThreat.tti) or "Waiting for ball"
	setDrawing(GUI.status, {Text = string.format("%s\n%d ms ping   /   %d attempts", status, math.floor(lastPing * 1000), parryCount)})
	for _, b in ipairs(buttons) do
		if b.key then
			local enabled = CONFIG[b.key]
			setDrawing(b.track, {Color = enabled and accent or Color3.fromRGB(65, 76, 93)})
			b.knobLayout.x = enabled and 279 or 255
			setDrawing(b.knob, {Position = Vector2.new(GUI.x + b.knobLayout.x, GUI.y + b.knobLayout.y)})
		end
	end
	refreshLead()
	refreshRange()
end

-- Matcha's native key polling uses Windows virtual-key numbers.
local function updateKeys()
	if type(iskeypressed) ~= "function" then return end
	local active = type(isrbxactive) ~= "function" or isrbxactive()
	for _, key in ipairs({80, 84}) do
		local down = iskeypressed(key)
		if active and down and not keysHeld[key] then
			if key == 80 then guiVisible = not guiVisible
			else
				CONFIG.enabled = not CONFIG.enabled
				print("Matcha auto-parry " .. (CONFIG.enabled and "enabled" or "disabled"))
			end
		end
		keysHeld[key] = down
	end
end

-- Matcha InputBegan only supplies KeyCode. Poll its mouse API for clicks.
local function updatePointer()
	local x, y = mouse.X, mouse.Y
	local active = type(isrbxactive) ~= "function" or isrbxactive()
	local down = type(ismouse1pressed) == "function" and ismouse1pressed() or false
	local valid = type(x) == "number" and type(y) == "number"
	if not down or not active or not guiVisible then dragging = false end
	pointerOverGui = active and guiVisible and GUI.ready and valid
		and x >= GUI.x and x <= GUI.x + GUI.w and y >= GUI.y and y <= GUI.y + GUI.h
	if pointerOverGui and down and not mouseWasDown and y < GUI.y + 58 then
		dragging = true
		dragX, dragY = x - GUI.x, y - GUI.y
	end
	if dragging and valid then
		moveGui(x - dragX, y - dragY)
		pointerOverGui = true
	end
	for _, b in ipairs(buttons) do
		local hover = pointerOverGui and not dragging and x >= GUI.x + b.x and x <= GUI.x + b.x + b.w
			and y >= GUI.y + b.y and y <= GUI.y + b.y + b.h
		setDrawing(b.box, {Color = hover and Color3.fromRGB(40, 56, 71) or Color3.fromRGB(27, 35, 48)})
		if hover and down and not mouseWasDown then b.action() end
	end
	mouseWasDown = down
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
	updateKeys()
	updatePointer()

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
	if not CONFIG.enabled or not threat or pointerOverGui then return end

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
	for _, object in ipairs(drawings) do
		pcall(function() object:Remove() end)
	end
	firedAt = {}
	_G.BB_MATCHA_STOP = nil
end

print("Matcha local auto-parry loaded (T toggle, P show/hide GUI)")
