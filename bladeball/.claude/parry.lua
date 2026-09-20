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
	autoTune = true,
	ballsFolder = "Balls",
	minSpeed = 5,
	maxRange = 140,
	contactRadius = 4.5,
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
local lastClick = -math.huge
local firedAt = {}
local tracked = {}
local renderConnection = nil
local currentThreat = nil
local lastPing = 0
local parryCount = 0
local menuOpen = true
local lastUiUpdate = 0
local lastFrameAt = nil
local lastCleanup = 0
local activeRoot = nil
local metrics = {frame = 1 / 60, frameJitter = 0, frames = 0,
	ping = 0, pingJitter = 0, hasPing = false, nextPing = 0, pingAt = -math.huge}

-- BEGIN PARRY MATH (pure functions, also exercised by the regression checks)
local function finite(n)
	return type(n) == "number" and n == n and math.abs(n) < math.huge
end

local function validVector(v)
	return v ~= nil and finite(v.X) and finite(v.Y) and finite(v.Z)
end

local function timingProfile(config, stats)
	local frame = math.clamp(stats.frame + stats.frameJitter * 2, 1 / 240, 0.080)
	local network = config.pingComp and stats.hasPing and stats.ping or 0
	local jitter = config.pingComp and stats.hasPing and stats.pingJitter or 0
	if config.autoTune then
		return {
			-- Assume measured ping is round-trip. Include one-way transport,
			-- a bounded jitter allowance, and the time until the next sample.
			lead = math.clamp(0.055 + network * 0.5 + math.min(jitter * 1.5, 0.035) + frame * 1.25, 0.060, 0.260),
			frame = frame,
			interval = math.clamp(frame, 0.012, 0.040),
			retry = math.clamp(math.max(frame * 2, network * 0.65 + jitter + 0.025), 0.035, 0.140),
			range = 0, -- determined from each ball's speed below
			clashRange = math.clamp(14 + frame * 180 + network * 35, 16, 34),
		}
	end
	return {lead = math.min(config.maxLead, config.baseLead + network * config.pingFactor),
		frame = frame, interval = config.minInterval, retry = config.clashRetry,
		range = config.maxRange, clashRange = config.clashRange}
end

local function detectionRange(config, profile, speed)
	if not config.autoTune then return profile.range end
	return math.clamp(config.contactRadius + speed * (profile.lead + profile.frame * 2) + 12, 40, 500)
end

local function impactTime(offset, relativeVelocity, radius)
	-- Solve |offset - relativeVelocity*t|^2 = radius^2. Radial distance /
	-- closing speed alone wrongly predicts collisions for passing balls.
	local speedSquared = relativeVelocity:Dot(relativeVelocity)
	if speedSquared < 0.001 then return nil end
	local approach = offset:Dot(relativeVelocity)
	if approach <= 0 then return nil end
	local c = offset:Dot(offset) - radius * radius
	if c <= 0 then return 0 end
	local discriminant = approach * approach - speedSquared * c
	if discriminant < 0 then return nil end
	-- Equivalent to the smaller quadratic root, with less cancellation.
	return c / (approach + math.sqrt(discriminant))
end

local function canAttempt(now, previous, state, isClash, retryDelay, limit)
	if previous == nil then return true end
	return isClash and now - previous >= retryDelay
		and (state.retries or 0) < limit
		and state.revision > (state.sentRevision or 0)
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
	["Automatic tuning"] = "Uses smoothed ping, network jitter, frame time and ball speed to choose timing, detection range and close-range retry delay. Turn it off to use the manual sliders. These are bounded estimates, not guaranteed optimal settings.",
	["Auto parry"] = "Automatically clicks when an incoming real ball reaches your parry timing window. T toggles it. Minimize with P to play.",
	["Close-range retries"] = "Allows up to two extra attempts during fast, nearby exchanges if a rebound was missed between updates.",
	["Fallback targeting"] = "Considers incoming real balls with an unknown target. Balls assigned to another player are still ignored.",
	["Ping compensation"] = "Accounts for measured network delay and its variation. Automatic tuning assumes the ping reading is round-trip. Turn off to use frame timing only.",
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
	local pingText = metrics.hasPing and string.format("%d ms", math.floor(lastPing * 1000 + 0.5)) or "unavailable"
	local fpsText = metrics.frames >= 10 and tostring(math.floor(1 / metrics.frame + 0.5)) or "measuring"
	Status:SetContent(string.format("%s | %s\nPing: %s | FPS estimate: %s | Attempts: %d", mode, threat, pingText, fpsText, parryCount))
	local rangeText = currentThreat and string.format("%.0f studs", currentThreat.range)
		or (CONFIG.autoTune and "40-500 studs, based on speed" or tostring(CONFIG.maxRange) .. " studs")
	TuningStatus:SetContent(string.format("%s | Lead: %.0f ms | Retry: %.0f ms\nRange: %s | Close range: %.0f studs\nPing jitter: %.0f ms | Frame budget: %.1f ms",
		CONFIG.autoTune and "Automatic" or "Manual", effective.lead * 1000, effective.retry * 1000,
		rangeText, effective.clashRange, metrics.pingJitter * 1000, effective.frame * 1000))
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

local function readBall(object, now)
	local part = getBallPart(object)
	if not part then return nil end
	local key = part.Address
	if not key then return nil end -- never key by Matcha's temporary wrappers
	local state = tracked[key]
	if not state then state = {revision = 0, retries = 0}; tracked[key] = state end
	state.seen = now

	local real = safeAttribute(object, "realBall")
	if real == nil then real = safeAttribute(part, "realBall") end
	if real ~= true then return nil end
	local target = safeAttribute(object, "target") or safeAttribute(object, "Target")
	if target == nil then target = safeAttribute(part, "target") or safeAttribute(part, "Target") end

	local position = part.Position
	if not validVector(position) then return nil end
	local dt = state.sampleAt and now - state.sampleAt or 0
	local displacement = state.position and position - state.position or nil
	local velocity = part.AssemblyLinearVelocity
	if not validVector(velocity) then velocity = part.Velocity end
	-- Script-driven motion can report zero assembly velocity. Only use a recent,
	-- plausible positional difference; don't extrapolate across a teleport.
	if (not validVector(velocity) or velocity.Magnitude < 0.01)
		and displacement and dt > 0.001 and dt < 0.15 then
		local measured = displacement / dt
		if measured.Magnitude < 6000 then velocity = measured end
	end
	if not validVector(velocity) then velocity = Vector3.new(0, 0, 0) end
	if velocity.Magnitude > 6000 then return nil end

	local changedTarget = target ~= state.target
	if changedTarget then
		firedAt[key], state.retries = nil, 0
		state.target = target
	end
	if changedTarget or not state.position or displacement.Magnitude > 0.02
		or not state.velocity or (velocity - state.velocity).Magnitude > 1 then
		state.revision = state.revision + 1
	end
	state.position, state.velocity, state.sampleAt = position, velocity, now
	local size = part.Size
	local ballRadius = validVector(size) and math.clamp(math.max(size.X, size.Y, size.Z) * 0.5, 0, 4) or 0
	return {key = key, position = position, velocity = velocity, speed = velocity.Magnitude,
		target = target, radius = CONFIG.contactRadius + ballRadius, state = state}
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
	local rootPosition = root.Position
	if not validVector(rootPosition) then return nil end
	local rootVelocity = root.AssemblyLinearVelocity
	if not validVector(rootVelocity) or rootVelocity.Magnitude > 200 then
		rootVelocity = Vector3.new(0, 0, 0)
	end
	local best = nil
	for _, object in ipairs(folder:GetChildren()) do
		local ball = readBall(object, now)
		if ball then
			local offset = rootPosition - ball.position
			local distance = offset.Magnitude
			local relativeVelocity = ball.velocity - rootVelocity
			local closingDot = offset:Dot(relativeVelocity)
			local state = ball.state
			-- Require meaningful outgoing motion to rearm; near-zero noise is
			-- not evidence of a new approach.
			if closingDot < -math.max(distance, 1) * 2 then
				firedAt[ball.key], state.retries = nil, 0
			end
			local aimed = ball.target == player.Name
			local unknown = ball.target == nil or ball.target == ""
			local allowed = aimed or (CONFIG.fallback and unknown)
			local range = detectionRange(CONFIG, effective, relativeVelocity.Magnitude)
			if allowed and ball.speed >= CONFIG.minSpeed and distance <= range then
				local tti = impactTime(offset, relativeVelocity, ball.radius)
				-- Curves are re-evaluated every frame. A large miss distance is
				-- never treated as a hit merely because target points at us.
				if tti and (not best or (aimed and not best.aimed)
					or (aimed == best.aimed and tti < best.tti)) then
					best = {ball = ball, distance = distance, tti = tti, aimed = aimed, range = range}
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
		return
	end

	local threat = chooseThreat(root, now)
	currentThreat = threat
	updateGui()
	if not CONFIG.enabled or not threat or menuOpen then return end
	if threat.tti > effective.lead then return end
	if type(isrbxactive) == "function" and not isrbxactive() then return end

	local clash = CONFIG.clashEnabled and threat.aimed and threat.distance <= effective.clashRange
		and threat.ball.speed >= CONFIG.clashMinSpeed
	local interval = effective.interval
	if not CONFIG.autoTune and clash then interval = CONFIG.clashInterval end
	if now - lastClick < interval then return end

	local key, state = threat.ball.key, threat.ball.state
	local previous = firedAt[key]
	if not canAttempt(now, previous, state, clash, effective.retry, CONFIG.maxClashRetries) then return end
	if fireParry() then
		if previous then state.retries = (state.retries or 0) + 1 end
		state.sentRevision = state.revision
		lastClick, firedAt[key] = now, now
		parryCount = parryCount + 1
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
	_G.BB_MATCHA_STATUS = nil
end

-- Read-only diagnostics for checking the active configuration in Matcha.
_G.BB_MATCHA_STATUS = function()
	return {automatic = CONFIG.autoTune, enabled = CONFIG.enabled, menuOpen = menuOpen,
		fps = 1 / metrics.frame, pingMs = metrics.hasPing and metrics.ping * 1000 or nil,
		leadMs = effective.lead * 1000, retryMs = effective.retry * 1000,
		clashRange = effective.clashRange, attempts = parryCount}
end

Library:OnUnload(function()
	if running and _G.BB_MATCHA_STOP then _G.BB_MATCHA_STOP() end
end)

print("WabiSabi auto-parry loaded (P minimize/play, T toggle)")
