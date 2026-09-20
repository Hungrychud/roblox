-------------------------------------------------------------------------
-- Blade Ball local auto-parry for Matcha
-- T toggles the script. Re-executing replaces the previous copy.
-------------------------------------------------------------------------

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
assert(player, "LocalPlayer is unavailable; run this as a client script")

local restoreMinimized = false
local restoreClash = nil
if type(WabiSabi) == "table" and WabiSabi.Options and WabiSabi.Options.Clash then
	restoreClash = WabiSabi.Options.Clash.Value
end
if _G.BB_MATCHA_STATUS then
	local previousStatus = _G.BB_MATCHA_STATUS()
	restoreMinimized = previousStatus and previousStatus.menuOpen == false
end

if _G.BB_MATCHA_STOP then
	pcall(_G.BB_MATCHA_STOP)
end

local CONFIG = {
	enabled = true,
	anyIncoming = true,
	autoTune = true,
	earlyParry = true,
	extraDistance = 4,
	accelerationPrediction = true,
	predictionPreview = true,
	compactHud = true,
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
if type(restoreClash) == "boolean" then CONFIG.clashEnabled = restoreClash end

local running = true
local lastClick = -math.huge
local firedAt = {}
local tracked = {}
local renderConnection = nil
local currentThreat = nil
local lastPing = 0
local parryCount = 0
local menuOpen = true
local lastUiUpdate = 0
local lastFireDistance = nil
local lastFrameAt = nil
local lastCleanup = 0
local activeRoot = nil
local metrics = {frame = 1 / 60, frameJitter = 0, frames = 0,
	ping = 0, pingJitter = 0, hasPing = false, nextPing = 0, pingAt = -math.huge}

-- BEGIN PARRY MATH (pure functions, also exercised by the regression checks)
local function finite(n)
	return type(n) == "number" and n == n and math.abs(n) < math.huge
end

local function timingProfile(config, stats)
	local frame = math.clamp(stats.frame + stats.frameJitter * 2, 1 / 240, 0.080)
	local network = config.pingComp and stats.hasPing and stats.ping or 0
	local jitter = config.pingComp and stats.hasPing and stats.pingJitter or 0
	if config.autoTune then
		return {
			-- Preserve the working 120 ms baseline. Automatic tuning adds
			-- bounded margins; it must not silently shorten the parry window.
			lead = math.min(config.maxLead, 0.120 + network * config.pingFactor
				+ math.min(jitter, 0.025) + math.min(frame * 0.5, 0.030)),
			frame = frame,
			interval = config.minInterval,
			retry = math.clamp(math.max(config.clashRetry, frame), config.clashRetry, 0.065),
			range = 0, -- determined from each ball's speed below
			clashRange = math.clamp(14 + frame * 180 + network * 35, 22, 34),
		}
	end
	return {lead = math.min(config.maxLead, config.baseLead + network * config.pingFactor),
		frame = frame, interval = config.minInterval, retry = config.clashRetry,
		range = config.maxRange, clashRange = config.clashRange}
end

local function detectionRange(config, profile, speed)
	if not config.autoTune then return profile.range end
	return math.clamp(config.contactRadius + speed * (profile.lead + profile.frame * 2) + 12, 140, 500)
end

local function impactTime(offset, velocity, radius, allowedMiss)
	-- Restore the working targeting model. Homing balls can curve toward the
	-- target after this sample, so an exact straight-line sphere test is too strict.
	local distance, speed = offset.Magnitude, velocity.Magnitude
	if distance < 0.001 or speed < 0.001 then return nil end
	local closing = velocity:Dot(offset / distance)
	if closing <= 0 then return nil end
	local closestTime = math.max(0, offset:Dot(velocity) / (speed * speed))
	if (offset - velocity * closestTime).Magnitude > allowedMiss then return nil end
	return math.max(0, (distance - radius) / closing)
end

local function canAttempt(now, previous, state, isClash, retryDelay, limit)
	if previous == nil then return true end
	return not state.departed and isClash and now - previous >= retryDelay
		and (state.retries or 0) < limit
end

local function advanceApproach(state, closing, distance)
	-- A target change is not a rebound: target and velocity can replicate on
	-- different frames. Keep the shot lock until actual outward travel, then
	-- a fresh inward phase. Require displacement to reject velocity flicker.
	local rearmed = false
	if state.locked then
		if closing < -2 then
			state.departureStart = state.departureStart or state.lastDistance or distance
			if distance - state.departureStart >= 0.5 then state.departed = true end
		elseif closing > 2 then
			if state.departed then
				state.locked, state.departed, state.departureStart = false, false, nil
				state.retries = 0
				rearmed = true
			else
				state.departureStart = nil
			end
		end
	end
	state.lastDistance = distance
	return rearmed
end

local function interceptionDistance(config, profile, closing, acceleration)
	local extra = config.earlyParry and config.extraDistance or 0
	local accelerationMargin = 0
	if config.accelerationPrediction then
		-- Never move the trigger later. Bound extra prediction to three studs
		-- and 25 ms of travel so a noisy velocity update cannot fire far away.
		accelerationMargin = math.min(3, math.max(0, closing) * 0.025,
			0.5 * math.max(0, acceleration) * profile.lead * profile.lead)
	end
	return config.contactRadius + extra + math.max(0, closing) * profile.lead + accelerationMargin
end

local function eligibleBall(config, real, aimed, unknownTarget)
	-- Known visual duplicates never drive input. Source player/NPC is irrelevant.
	return real ~= false and (config.anyIncoming or (real == true and (aimed or (config.fallback and unknownTarget))))
end
-- END PARRY MATH

local effective = timingProfile(CONFIG, metrics)

local function samplePerformance(now)
	if lastFrameAt then
		local dt = now - lastFrameAt
		if finite(dt) and dt > 0 and dt < 0.25 then
			local alpha = 1 - math.exp(-dt / 0.75)
			local deviation = math.abs(dt - metrics.frame)
			metrics.frame = metrics.frame + alpha * (dt - metrics.frame)
			metrics.frameJitter = metrics.frameJitter + alpha * (deviation - metrics.frameJitter)
			metrics.frames = metrics.frames + 1
		end
	end
	lastFrameAt = now
	if now >= metrics.nextPing then
		metrics.nextPing = now + 0.25
		local ok, value = pcall(function() return GetPingValue() end)
		if ok and finite(value) and value >= 0 and value <= 2000 then
			local seconds = math.min(value, 600) / 1000
			if metrics.hasPing then
				metrics.pingJitter = metrics.pingJitter * 0.8 + math.abs(seconds - metrics.ping) * 0.2
				metrics.ping = metrics.ping * 0.75 + seconds * 0.25
			else metrics.ping, metrics.pingJitter = seconds, 0 end
			metrics.hasPing, metrics.pingAt = true, now
		elseif now - metrics.pingAt > 2 then metrics.hasPing = false end
	end
	lastPing = metrics.ping
	effective = timingProfile(CONFIG, metrics)
end

-- Load the user-selected Matcha UI library.
local fetched, source = pcall(function()
	return game:HttpGet("https://scripts.wabisabi.mom/wabi-sabi-ui-lib.lua")
end)
assert(fetched and type(source) == "string", "Could not download WabiSabi UI")
-- Extend WabiSabi's own renderer so help follows dragging, scrolling and tabs.
-- Plain, checked anchors avoid silently patching an incompatible library release.
local function extendUi(anchor, replacement)
	local first, last = source:find(anchor, 1, true)
	assert(first and not source:find(anchor, last + 1, true), "WabiSabi help integration needs updating")
	source = source:sub(1, first - 1) .. replacement .. source:sub(last + 1)
end
local titleAnchor = '    text(idp .. ".t", el.title, titleX, titleY, 13, Theme.Text, z + 2)'
extendUi(titleAnchor, [=[
    local help = UI.HelpText and UI.HelpText[el.title]
    if help then
        local hx, hy = titleX + 6, titleY + 7
        local helpHover = inBounds(hx - 9, hy - 9, 18, 18)
            and not State.Overlay and not State.Dialog and not State.Drag
        circle(idp .. ".help.bg", hx, hy, 7, helpHover and Theme.Accent or Theme.Control, 1, z + 3)
        text(idp .. ".help.q", "?", hx, titleY, 12, Theme.Text, z + 4, true)
        titleX = titleX + 22
        if helpHover then
            UI._hoverHelp = help
            hovered = false
        end
    end
]=] .. titleAnchor)
extendUi('    if State.Minimized then renderBubble(dt) else renderWindow(dt) end',
	'    UI._hoverHelp = nil\n    if State.Minimized then renderBubble(dt) else renderWindow(dt) end')
extendUi('    renderNotifs(dt)\n    cleanup()', [=[
    renderNotifs(dt)
    if UI._hoverHelp and not State.Minimized then
        local vw, vh = getViewport()
        local width = math.min(280, vw - 16)
        local lines = wrapText(UI._hoverHelp, 12, width - 24)
        local height = #lines * 16 + 20
        local tx = clamp(Input.mx + 16, 8, math.max(8, vw - width - 8))
        local ty = Input.my + 22
        if ty + height > vh - 8 then ty = Input.my - height - 12 end
        ty = math.max(8, ty)
        rect("help.tooltip.bg", tx, ty, width, height, Theme.OverlayBg, 1, 300, 6)
        outline("help.tooltip.border", tx, ty, width, height, Theme.Accent, 0.8, 301, 6)
        for i, ln in ipairs(lines) do
            text("help.tooltip.line" .. i, ln, tx + 12, ty + 10 + (i - 1) * 16, 12, Theme.Text, 302)
        end
    end
    cleanup()
]=])
local uiChunk, compileError = loadstring(source)
assert(uiChunk, "Could not compile WabiSabi: " .. tostring(compileError))
local loadedLibrary = uiChunk()
local Library = WabiSabi or loadedLibrary
assert(type(Library) == "table" and type(Library.CreateWindow) == "function", "Invalid WabiSabi UI")
Library.HelpText = {
	["Any incoming ball"] = "Considers moving balls in Workspace.Balls regardless of who sent them or their target tag: players, bots, and launchers. Non-targeted balls must be on a close incoming path. Known visual duplicates are excluded.",
	["Earlier parry"] = "Adds the extra-distance buffer to the existing speed and ping prediction. This presses parry sooner; it cannot increase the server's actual parry range.",
	["Extra distance (studs)"] = "Additional distance before the normal trigger. Default: 4 studs. Lower this if inputs happen too early. Works in both automatic and manual modes.",
	["Acceleration prediction"] = "Uses recent stable incoming velocity changes to allow a small earlier trigger when the ball accelerates. The extra allowance is capped at 3 studs and never delays a parry.",
	["Prediction preview"] = "Marks the incoming ball and shows its estimated position after the timing lead. Green means it has entered the planned trigger distance. This is an estimate, not a guaranteed path.",
	["Compact match HUD"] = "Shows current ball distance, planned trigger distance, and the distance of your last attempt while the menu is minimized. Attempts are not confirmed hits.",
	["Automatic tuning"] = "Uses smoothed ping, network jitter, frame time and ball speed to choose timing, detection range and close-range retry delay. Turn it off to use the manual sliders. These are bounded estimates, not guaranteed optimal settings.",
	["Auto parry"] = "Automatically clicks when an incoming real ball reaches your parry timing window. T toggles it. Minimize with P to play.",
	["Close-range retries"] = "Allows up to two extra attempts during fast, nearby exchanges if a rebound was missed between updates.",
	["Fallback targeting"] = "When Any incoming ball is OFF, also consider incoming real balls with an unknown target. Any incoming ball overrides this target restriction.",
	["Ping compensation"] = "Accounts for measured network delay and its variation. Automatic tuning preserves the working base timing. Turn off to omit the network margin.",
	["Reaction lead (ms)"] = "Manual setting, used only when automatic tuning is off. Higher values click earlier; too high can waste the parry window.",
	["Detection range (studs)"] = "Manual setting, used only when automatic tuning is off. Automatic mode expands detection with ball speed; it does not change the game's actual parry range.",
	["Close-range distance (studs)"] = "Manual setting, used only when automatic tuning is off. Controls where fast incoming balls may use bounded retries. Requires close-range retries enabled.",
	["Theme"] = "Changes the window colors. It does not change auto-parry behavior.",
	["Minimize and play"] = "Collapses the menu into a small bubble and lets auto-parry run when enabled. Press P or click the bubble to restore it.",
	["Unload script"] = "Stops auto-parry and removes this UI. Run the loader again to restart.",
}

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
	Id = "AnyIncoming", Title = "Any incoming ball", Default = CONFIG.anyIncoming,
	Callback = function(value) CONFIG.anyIncoming = value end,
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
Timing:AddToggle({
	Id = "AutoTune", Title = "Automatic tuning", Default = CONFIG.autoTune,
	Callback = function(value) CONFIG.autoTune = value end,
})
local TuningStatus = Timing:AddParagraph({Title = "Effective settings", Content = "Measuring ping and frame time..."})
Timing:AddSection("Predictive distance (all modes)")
Timing:AddToggle({Id = "EarlyParry", Title = "Earlier parry", Default = CONFIG.earlyParry,
	Callback = function(value) CONFIG.earlyParry = value end})
Timing:AddSlider({Id = "ExtraDistance", Title = "Extra distance (studs)", Default = CONFIG.extraDistance,
	Min = 0, Max = 10, Rounding = 1, Callback = function(value) CONFIG.extraDistance = value end})
Timing:AddToggle({Id = "Acceleration", Title = "Acceleration prediction", Default = CONFIG.accelerationPrediction,
	Callback = function(value) CONFIG.accelerationPrediction = value end})
Timing:AddSection("Manual settings (automatic tuning OFF)")
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

local Visuals = Window:AddTab({Title = "Visuals"})
Visuals:AddToggle({Id = "Preview", Title = "Prediction preview", Default = CONFIG.predictionPreview,
	Callback = function(value) CONFIG.predictionPreview = value end})
Visuals:AddToggle({Id = "MatchHUD", Title = "Compact match HUD", Default = CONFIG.compactHud,
	Callback = function(value) CONFIG.compactHud = value end})

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
	local threat = currentThreat and string.format("Ball: %.1f studs | Trigger: %.1f studs", currentThreat.distance, currentThreat.triggerDistance) or "Waiting for ball"
	local pingText = metrics.hasPing and string.format("%d ms", math.floor(lastPing * 1000 + 0.5)) or "unavailable"
	local fpsText = metrics.frames >= 10 and tostring(math.floor(1 / metrics.frame + 0.5)) or "measuring"
	Status:SetContent(string.format("%s | %s\nPing: %s | FPS estimate: %s | Attempts: %d", mode, threat, pingText, fpsText, parryCount))
	local rangeText = currentThreat and string.format("%.0f studs", currentThreat.range)
		or (CONFIG.autoTune and "140-500 studs, based on speed" or tostring(CONFIG.maxRange) .. " studs")
	TuningStatus:SetContent(string.format("%s | Lead: %.0f ms | Retry: %.0f ms\nRange: %s | Close range: %.0f studs\nPing jitter: %.0f ms | Frame budget: %.1f ms",
		CONFIG.autoTune and "Automatic" or "Manual", effective.lead * 1000, effective.retry * 1000,
		rangeText, effective.clashRange, metrics.pingJitter * 1000, effective.frame * 1000))
end

-- Fixed Drawing pool. Failure in the optional preview must not stop parrying.
local overlay = {}
local overlayObjects = {}
local function overlayObject(kind, properties)
	local ok, object = pcall(function()
		local item = Drawing.new(kind)
		overlayObjects[#overlayObjects + 1] = item
		for key, value in pairs(properties) do item[key] = value end
		item.Visible = false
		return item
	end)
	if ok then return object end
	return nil
end
overlay.hud = overlayObject("Text", {Size = 14, Font = 2, Outline = true, Position = Vector2.new(20, 58), Color = Color3.fromRGB(210, 235, 245), Transparency = 0, ZIndex = 10})
overlay.ball = overlayObject("Circle", {Radius = 12, NumSides = 24, Filled = false, Thickness = 2, Transparency = 0, ZIndex = 10})
overlay.future = overlayObject("Circle", {Radius = 5, NumSides = 16, Filled = false, Thickness = 1, Transparency = 0, ZIndex = 10})
overlay.path = overlayObject("Line", {Thickness = 1, Transparency = 0, ZIndex = 10})
overlay.label = overlayObject("Text", {Size = 13, Font = 2, Outline = true, Center = true, Transparency = 0, ZIndex = 10})
local previewFailed = false
local function drawPreview(root, threat)
	for _, object in ipairs(overlayObjects) do object.Visible = false end
	if menuOpen or (type(isrbxactive) == "function" and not isrbxactive()) then return end
	if CONFIG.compactHud and overlay.hud then
		local status = not CONFIG.enabled and "OFF" or (not root and "Waiting for round" or "Tracking")
		local info = threat and string.format("ball %.1fst / trigger %.1fst", threat.distance, threat.triggerDistance) or "no incoming ball"
		local last = lastFireDistance and string.format("%.1fst", lastFireDistance) or "none"
		overlay.hud.Text = string.format("PARRY %s | %s\nLast attempt: %s | T toggle | P menu", status, info, last)
		overlay.hud.Visible = true
	end
	if not CONFIG.predictionPreview or not threat or type(WorldToScreen) ~= "function" then return end
	local color = threat.distance <= threat.triggerDistance and Color3.fromRGB(110, 240, 150) or Color3.fromRGB(110, 200, 255)
	local point, visible = WorldToScreen(threat.ball.position)
	local future, futureVisible = WorldToScreen(threat.ball.position + threat.ball.velocity * math.min(effective.lead, threat.tti))
	if visible then
		if overlay.ball then overlay.ball.Position = point; overlay.ball.Color = color; overlay.ball.Visible = true end
		if overlay.label then
			overlay.label.Position = Vector2.new(point.X, point.Y - 30)
			overlay.label.Text = string.format("%.1fst | fire at %.1fst", threat.distance, threat.triggerDistance)
			overlay.label.Color = color; overlay.label.Visible = true
		end
	end
	if visible and futureVisible then
		if overlay.path then overlay.path.From = point; overlay.path.To = future; overlay.path.Color = color; overlay.path.Visible = true end
		if overlay.future then overlay.future.Position = future; overlay.future.Color = color; overlay.future.Visible = true end
	end
end

local function updatePreview(root, threat)
	if previewFailed then return end
	local ok, err = pcall(function() drawPreview(root, threat) end)
	if not ok then
		previewFailed = true
		for _, object in ipairs(overlayObjects) do pcall(function() object.Visible = false end) end
		warn("Prediction preview disabled: " .. tostring(err))
	end
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
	-- Matcha creates new wrapper objects on reads; never hash the wrapper.
	return ball.object:GetFullName()
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

local function chooseThreat(root, now)
	local folder = Workspace:FindFirstChild(CONFIG.ballsFolder)
	if not folder then return nil end
	local best = nil
	for _, object in ipairs(folder:GetChildren()) do
		local ball = readBall(object)
		if ball then
			local key = ballKey(ball)
			local state = tracked[key]
			if not state then state = {retries = 0}; tracked[key] = state end
			state.seen = now
			if state.target ~= ball.target then
				state.acceleration, state.closing, state.sampleAt, state.velocity = 0, nil, nil, nil
				state.target = ball.target
			end
			local offset = root.Position - ball.position
			local distance = offset.Magnitude
			local closing = distance > 0.001 and ball.velocity:Dot(offset / distance) or 0
			if advanceApproach(state, closing, distance) then firedAt[key] = nil end
			local dt = state.sampleAt and now - state.sampleAt or 0
			local stable = state.velocity and state.velocity.Magnitude > 0
				and ball.velocity.Unit:Dot(state.velocity.Unit) > 0.95
			if stable and state.closing and closing > 0 and dt >= 0.004 and dt <= 0.1 then
				local gain = math.clamp((closing - state.closing) / dt, 0, closing * 2)
				state.acceleration = (state.acceleration or 0) * 0.75 + gain * 0.25
			else state.acceleration = 0 end
			state.closing, state.sampleAt, state.velocity = closing, now, ball.velocity
			local aimed = ball.target == player.Name
			local unknown = ball.target == nil or ball.target == ""
			local eligible = eligibleBall(CONFIG, ball.real, aimed, unknown)
			local trigger = interceptionDistance(CONFIG, effective, closing, state.acceleration)
			local range = math.max(detectionRange(CONFIG, effective, ball.speed), trigger + 4)
			if eligible and distance <= range then
				local allowedMiss = aimed and CONFIG.targetedRadius or CONFIG.contactRadius
				local tti = impactTime(offset, ball.velocity, CONFIG.contactRadius, allowedMiss)
				local better = tti and (not best or (CONFIG.anyIncoming and tti < best.tti)
					or (not CONFIG.anyIncoming and ((aimed and not best.aimed) or (aimed == best.aimed and tti < best.tti))))
				if better then
					ball.key, ball.state = key, state
					best = {ball = ball, distance = distance, tti = tti, aimed = aimed, range = range, triggerDistance = trigger}
				end
			end
		end
	end
	return best
end

local function update()
	if not running then return end
	local now = tick()
	samplePerformance(now)
	-- Cleanup also runs while idle, so removed balls don't accumulate.
	if now - lastCleanup >= 1 then
		lastCleanup = now
		for key, state in pairs(tracked) do
			if now - state.seen > 2 then tracked[key], firedAt[key] = nil, nil end
		end
	end

	local root = getRoot()
	local rootId = root and root.Address
	if rootId ~= activeRoot then
		tracked, firedAt = {}, {}
		activeRoot = rootId
		lastClick = -math.huge
	end
	if not root then
		currentThreat = nil
		updateGui()
		updatePreview(nil, nil)
		return
	end

	local threat = chooseThreat(root, now)
	currentThreat = threat
	updateGui()
	updatePreview(root, threat)
	if not CONFIG.enabled or not threat or menuOpen then return end
	if threat.distance > threat.triggerDistance then return end
	if type(isrbxactive) == "function" and not isrbxactive() then return end

	local clash = CONFIG.clashEnabled and (threat.aimed or CONFIG.anyIncoming) and threat.distance <= effective.clashRange
		and threat.ball.speed >= CONFIG.clashMinSpeed
	local interval = effective.interval
	if clash then interval = CONFIG.clashInterval end
	if now - lastClick < interval then return end

	local key, state = threat.ball.key, threat.ball.state
	local previous = firedAt[key]
	if not canAttempt(now, previous, state, clash, effective.retry, CONFIG.maxClashRetries) then return end
	if fireParry() then
		if previous then state.retries = (state.retries or 0) + 1 end
		state.locked = true
		state.departed, state.departureStart = false, nil
		state.lastDistance = threat.distance
		lastClick, firedAt[key] = now, now
		parryCount = parryCount + 1
		lastFireDistance = threat.distance
	end
end

local renderSignal = RunService.RenderStepped or RunService.Heartbeat
assert(renderSignal, "Matcha exposes neither RenderStepped nor Heartbeat")
renderConnection = renderSignal:Connect(update)

_G.BB_MATCHA_STOP = function()
	running = false
	if renderConnection then renderConnection:Disconnect() end
	Library:Stop()
	for _, object in ipairs(overlayObjects) do pcall(function() object:Remove() end) end
	firedAt = {}
	_G.BB_MATCHA_STOP = nil
	_G.BB_MATCHA_STATUS = nil
end

-- Read-only diagnostics for checking the active configuration in Matcha.
_G.BB_MATCHA_STATUS = function()
	return {automatic = CONFIG.autoTune, enabled = CONFIG.enabled, menuOpen = menuOpen,
		closeRangeRetries = CONFIG.clashEnabled,
		fps = 1 / metrics.frame, pingMs = metrics.hasPing and metrics.ping * 1000 or nil,
		leadMs = effective.lead * 1000, retryMs = effective.retry * 1000,
		clashRange = effective.clashRange, attempts = parryCount,
		lastFireDistance = lastFireDistance, triggerDistance = currentThreat and currentThreat.triggerDistance,
		extraDistance = CONFIG.earlyParry and CONFIG.extraDistance or 0}
end

Library:OnUnload(function()
	if running and _G.BB_MATCHA_STOP then _G.BB_MATCHA_STOP() end
end)

if restoreMinimized then Library:Minimize() end
print("WabiSabi auto-parry restored (P minimize/play, T toggle)")
