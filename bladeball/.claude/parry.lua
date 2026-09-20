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
	pingFactor = 0.75,
	maxLead = 0.42,
	minInterval = 0.055,
	sameBallRetry = 0.18,
	fallback = true,
}

local running = true
local lastClick = 0
local firedAt = {}
local renderConnection = nil
local inputConnection = nil

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
	if alive and character.Parent ~= alive then return nil end
	if safeAttribute(character, "Stunned") or safeAttribute(character, "PULSED") then
		return nil
	end

	return root
end

local function getBallPart(object)
	local ok, isPart = pcall(function()
		return object:IsA("BasePart")
	end)
	if ok and isPart then return object end

	local modelOk, isModel = pcall(function()
		return object:IsA("Model")
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
	return pcall(click)
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

			if distance > 0.001 and distance <= CONFIG.maxRange then
				local closing = ball.velocity:Dot(offset / distance)

				if closing > 0 then
					local closestTime = math.max(0, offset:Dot(ball.velocity) / (ball.speed * ball.speed))
					local closestPoint = ball.position + ball.velocity * closestTime
					local missDistance = (rootPosition - closestPoint).Magnitude
					local aimed = ball.target == player.Name
					local allowedMiss = aimed and CONFIG.targetedRadius or CONFIG.contactRadius
					local eligible = (ball.real == true and aimed)
						or (CONFIG.fallback and ball.real ~= false)

					if eligible and missDistance <= allowedMiss then
						local impactTime = math.max(0, (distance - CONFIG.contactRadius) / closing)
						if impactTime < bestTime then
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
	if not running or not CONFIG.enabled then return end

	local root = getRoot()
	if not root then return end

	local threat = chooseThreat(root.Position)
	if not threat then return end

	local lead = math.min(CONFIG.maxLead, CONFIG.baseLead + pingSeconds() * CONFIG.pingFactor)
	if threat.tti > lead then return end

	local now = os.clock()
	if now - lastClick < CONFIG.minInterval then return end

	local key = ballKey(threat.ball)
	local previous = firedAt[key]
	if previous and now - previous < CONFIG.sameBallRetry then return end

	if fireParry() then
		lastClick = now
		firedAt[key] = now
	end

	for oldKey, timestamp in pairs(firedAt) do
		if now - timestamp > 2 then
			firedAt[oldKey] = nil
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
		if ok and keyCode == Enum.KeyCode.T then
			CONFIG.enabled = not CONFIG.enabled
			print("Matcha auto-parry " .. (CONFIG.enabled and "enabled" or "disabled"))
		end
	end)
end

_G.BB_MATCHA_STOP = function()
	running = false
	if renderConnection then renderConnection:Disconnect() end
	if inputConnection then inputConnection:Disconnect() end
	firedAt = {}
	_G.BB_MATCHA_STOP = nil
end

print("Matcha local auto-parry loaded (T to toggle)")
