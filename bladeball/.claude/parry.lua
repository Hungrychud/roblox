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
	-- Parry any real ball on a collision course with you. The `target` tag is not
	-- reliable for the local player in every mode, so gating on target==you alone
	-- can miss your own ball; geometric detection (impactTime) is the safety net.
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
	minInterval = 0.05,
	clashEnabled = true,
	clashInterval = 0.016,
	clashRange = 14,          -- genuine point-blank only (was 22; fixed, not auto-expanded)
	clashMinSpeed = 110,      -- real fast exchange (was 70)
	clashRetry = 0.045,
	maxClashRetries = 2,
	fallback = true,

	-- ---- Combat additions ----
	targetPlayer = "None",          -- only parry balls aimed at this player (assist)
	parryMode = "Click",            -- "Click" (mouse1click) or "Remote" (ParryButtonPress)
	accuracy = 100,                 -- % chance a valid parry opportunity is taken
	randomizeAccuracy = false,      -- pick a random accuracy per attempt
	randomAccMin = 50,
	randomAccMax = 90,
	manualSpam = false, manualSpamKey = "E", manualSpamInterval = 0.03,
	autoSpam = false, autoSpamKey = "F2", autoSpamRange = 30, autoSpamInterval = 0.03,
	killPreClick = false, preClickRange = 30, preClickBallSpeed = 1,
	cooldownProtection = false, cooldownGap = 0.35,
	autoAbility = false, autoAbilityRange = 25, autoAbilityInterval = 0.6, autoAbilitySecondary = false,
	curveMode = "Off",              -- Off / Camera / Target
	triggerbot = false, triggerbotKey = "None",

	-- ---- Detections ----
	ignoreInfinity = false, ignoreDeathSlash = false, ignoreSlashesOfFury = false, ignoreTimeHole = false,
	antiPhantom = false, antiHellhook = false,

	-- ---- Visuals additions ----
	ballTrail = false, parryVisualizer = false, parryHits = false,
	ballIndicator = false, abilityEsp = false, noRender = false,
	customWinstreak = false, customWinstreakText = "Winstreak: %d",
	customWinMessage = false, customWinMessageText = "GG",

	-- ---- Player ----
	fovEnabled = false, fov = 70,
	gravityEnabled = false, gravity = 196.2,
	speedEnabled = false, speed = 16,
	jumpEnabled = false, jumpPower = 50,
	infiniteJump = false,

	-- ---- Blatant ----
	orbitBall = false, orbitKey = "H", orbitRadius = 8, orbitSpeed = 3,
	immortality = false,

	-- ---- Accuracy engine (outside-the-box) ----
	adaptiveLearning = false,  -- opt-in: self-tune lead from ServerParryCount outcomes
	velocityBlend = true,      -- never under-estimate ball speed (positional derivative)
	maxLearnBias = 0.06,       -- ceiling on how much earlier learning may fire (s)
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

-- ---- Live game remote references (Blade Ball, place 13772394625) ----
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = nil
pcall(function() UserInputService = game:GetService("UserInputService") end)
local Remotes = ReplicatedStorage:FindFirstChild("Remotes")
local function remote(name)
	return Remotes and Remotes:FindFirstChild(name) or nil
end

-- ---- Feature runtime state ----
local lastSpam = -math.huge          -- manual/auto spam throttle
local lastAbility = -math.huge       -- auto-ability throttle
local lastParryEnd = -math.huge      -- for cooldown protection
local lastEmote = -math.huge
local detectionFlags = {infinity = 0, deathSlash = 0, slashesOfFury = 0, timeHole = 0} -- os.clock() when last seen
local remoteConns = {}               -- detection remote connections
local parryBurst = {}                -- {x, y, t0} drawing pulses for Parry Hits/Visualizer
local heldKeys = {}                  -- keyboard state for hold-to-spam / orbit
local orbitAngle = 0
local baseGravity = nil              -- restore workspace gravity on unload
local playerNames = {"None"}         -- Target Player dropdown options

-- ---- Closed-loop learning state (ServerParryCount feedback) ----
local learnedBias = 0                -- extra lead learned from live outcomes (s)
local pendingFires = {}              -- {t} one entry per fresh committed parry
local lastParryCountSeen = nil       -- previous character ServerParryCount
local parryMissEma = 0               -- 0 = landing everything, higher = missing
local lastBiasAdjust = 0
local lastLandDistance = nil         -- ball distance when a parry last confirmed
local debugLog = {}                  -- [DIAGNOSTIC] recent close-ball frames + block reason

-- BEGIN PARRY MATH (pure functions, also exercised by the regression checks)
local function finite(n)
	return type(n) == "number" and n == n and math.abs(n) < math.huge
end

local function timingProfile(config, stats)
	local frame = math.clamp(math.max(stats.frame + stats.frameJitter * 2,
		stats.lastFrame or 0), 1 / 240, 0.080)
	local network = config.pingComp and stats.hasPing and stats.ping or 0
	local jitter = config.pingComp and stats.hasPing and stats.pingJitter or 0
	if config.autoTune then
		return {
			-- Preserve the working 120 ms baseline. Automatic tuning adds
			-- bounded margins; it must not silently shorten the parry window.
			lead = math.min(config.maxLead, 0.120 + network * config.pingFactor
				+ math.min(jitter, 0.025) + math.min(frame * 0.5, 0.030)),
			frame = frame,
			lookAhead = frame, -- cover travel before the next client observation
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
	return config.contactRadius + extra + math.max(0, closing)
		* (profile.lead + (profile.lookAhead or 0)) + accelerationMargin
end

local function sampleMotion(state, position, velocity, now, blend)
	-- Duplicate render/physics observations must not reset the sample clock.
	local dt = state.motionAt and now - state.motionAt or 0
	if not state.motionPos or dt > 0.15 or dt < 0 then
		state.motionPos, state.motionAt = position, now
		state.measuredVelocity, state.motionConfidence = nil, 0
	elseif dt >= 0.004 then
		local delta = position - state.motionPos
		if delta.Magnitude > 0.001 then
			local measured = delta / dt
			local old = state.measuredVelocity
			local consistent = old and old.Magnitude > 0.001
				and measured.Unit:Dot(old.Unit) > 0.95
				and measured.Magnitude >= old.Magnitude * 0.5
				and measured.Magnitude <= old.Magnitude * 2
			state.motionConfidence = consistent and (state.motionConfidence or 0) + 1 or 1
			state.measuredVelocity = measured
			state.motionPos, state.motionAt = position, now
		end
	end
	local measured = state.measuredVelocity
	local speed = velocity.Magnitude
	if blend and measured and now - state.motionAt <= 0.05 then
		local measuredSpeed = measured.Magnitude
		local aligned = speed < 0.001 or measured.Unit:Dot(velocity.Unit) > 0.95
		-- Two coherent displacements can recover severely stale engine speed.
		-- A single jump cannot override zero velocity or remove the speed bound.
		if aligned and measuredSpeed > speed and (state.motionConfidence or 0) >= 2 then
			return measured
		elseif aligned and speed > 0.001 and measuredSpeed > speed then
			return velocity.Unit * math.min(measuredSpeed, speed * 1.5)
		end
	end
	return velocity
end

local function betterThreat(candidate, best)
	if not best then return true end
	local ready = candidate.distance <= candidate.triggerDistance
	local bestReady = best.distance <= best.triggerDistance
	if ready ~= bestReady then return ready end
	return candidate.priority > best.priority
		or (candidate.priority == best.priority and candidate.tti < best.tti)
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
			metrics.lastFrame = dt
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
	-- Fold in the empirically-learned bias (fire earlier when live outcomes show
	-- we were late). Never drops below a 20 ms floor.
	if CONFIG.adaptiveLearning and learnedBias > 0 then
		effective.lead = math.clamp(effective.lead + learnedBias, 0.02, CONFIG.maxLead + CONFIG.maxLearnBias)
	end
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
for _, plr in ipairs(Players:GetPlayers()) do
	if plr ~= player then playerNames[#playerNames + 1] = plr.Name end
end

-- ======================= COMBAT =======================
local Main = Window:AddTab({Title = "Combat"})
Main:AddParagraph({
	Title = "Match controls",
	Content = "Drag the title bar to move. P minimizes/plays; T toggles auto parry.\nAuto parry, spam and triggerbot pause while this window is open.",
})
local Controls = Main:AddSection("Auto Parry")
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
	Callback = function(value) CONFIG.clashEnabled = value end,
})
Controls:AddToggle({
	Id = "Fallback", Title = "Fallback targeting", Default = CONFIG.fallback,
	Callback = function(value) CONFIG.fallback = value end,
})
Controls:AddToggle({
	Id = "Ping", Title = "Ping compensation", Default = CONFIG.pingComp,
	Callback = function(value) CONFIG.pingComp = value end,
})
Controls:AddDropdown({
	Title = "Parry mode", Options = {"Click", "Remote"}, Default = CONFIG.parryMode,
	Callback = function(value) CONFIG.parryMode = value end,
})
Controls:AddSlider({
	Title = "Accuracy (%)", Default = CONFIG.accuracy, Min = 0, Max = 100, Rounding = 0,
	Callback = function(value) CONFIG.accuracy = value end,
})
Controls:AddToggle({
	Title = "Randomize accuracy", Default = CONFIG.randomizeAccuracy,
	Callback = function(value) CONFIG.randomizeAccuracy = value end,
})
Controls:AddSlider({
	Title = "Random accuracy min", Default = CONFIG.randomAccMin, Min = 0, Max = 100, Rounding = 0,
	Callback = function(value) CONFIG.randomAccMin = value end,
})
Controls:AddSlider({
	Title = "Random accuracy max", Default = CONFIG.randomAccMax, Min = 0, Max = 100, Rounding = 0,
	Callback = function(value) CONFIG.randomAccMax = value end,
})

local Target = Main:AddSection("Target Player")
local targetDropdown = Target:AddDropdown({
	Title = "Focus parry on player", Options = playerNames, Default = "None", Searchable = true,
	Callback = function(value) CONFIG.targetPlayer = value end,
})
Target:AddButton({Title = "Refresh player list", Callback = function()
	local names = {"None"}
	for _, plr in ipairs(Players:GetPlayers()) do
		if plr ~= player then names[#names + 1] = plr.Name end
	end
	playerNames = names
	if targetDropdown and targetDropdown.SetValues then pcall(function() targetDropdown:SetValues(names) end) end
end})

local Spam = Main:AddSection("Spam")
Spam:AddKeybind({
	Title = "Manual spam", Default = CONFIG.manualSpamKey, Mode = "Toggle",
	Callback = function(on) CONFIG.manualSpam = on end,
})
Spam:AddSlider({Title = "Manual spam interval (ms)", Default = CONFIG.manualSpamInterval * 1000,
	Min = 10, Max = 200, Rounding = 0, Callback = function(v) CONFIG.manualSpamInterval = v / 1000 end})
Spam:AddKeybind({
	Title = "Auto spam (ball proximity)", Default = CONFIG.autoSpamKey, Mode = "Toggle",
	Callback = function(on) CONFIG.autoSpam = on end,
})
Spam:AddSlider({Title = "Auto spam range (studs)", Default = CONFIG.autoSpamRange,
	Min = 5, Max = 100, Rounding = 0, Callback = function(v) CONFIG.autoSpamRange = v end})

local PreClick = Main:AddSection("Pre Click")
PreClick:AddToggle({Title = "Kill pre click", Default = CONFIG.killPreClick,
	Callback = function(v) CONFIG.killPreClick = v end})
PreClick:AddSlider({Title = "Pre click range", Default = CONFIG.preClickRange,
	Min = 5, Max = 120, Rounding = 0, Callback = function(v) CONFIG.preClickRange = v end})
PreClick:AddSlider({Title = "Pre click ball speed", Default = CONFIG.preClickBallSpeed,
	Min = 1, Max = 400, Rounding = 0, Callback = function(v) CONFIG.preClickBallSpeed = v end})

local Abilities = Main:AddSection("Abilities & Extras")
Abilities:AddToggle({Title = "Cooldown protection", Default = CONFIG.cooldownProtection,
	Callback = function(v) CONFIG.cooldownProtection = v end})
Abilities:AddToggle({Title = "Auto ability", Default = CONFIG.autoAbility,
	Callback = function(v) CONFIG.autoAbility = v end})
Abilities:AddToggle({Title = "Auto ability uses secondary", Default = CONFIG.autoAbilitySecondary,
	Callback = function(v) CONFIG.autoAbilitySecondary = v end})
Abilities:AddSlider({Title = "Auto ability range (studs)", Default = CONFIG.autoAbilityRange,
	Min = 5, Max = 80, Rounding = 0, Callback = function(v) CONFIG.autoAbilityRange = v end})
Abilities:AddDropdown({Title = "Curve mode", Options = {"Off", "Camera", "Target"}, Default = CONFIG.curveMode,
	Callback = function(v) CONFIG.curveMode = v end})
Abilities:AddKeybind({Title = "Triggerbot (ball targets you)", Default = CONFIG.triggerbotKey, Mode = "Toggle",
	Callback = function(on) CONFIG.triggerbot = on end})

local Status = Main:AddParagraph({Title = "Live status", Content = "Waiting for ball"})

-- ======================= DETECTIONS =======================
local Detect = Window:AddTab({Title = "Detections"})
Detect:AddParagraph({Title = "Ability detection",
	Content = "Ignore toggles stop auto parry from reacting to these special ability balls\n(their timing differs). Anti toggles notify you when an enemy uses one on you."})
Detect:AddToggle({Title = "Infinity detection (ignore infinity ball)", Default = CONFIG.ignoreInfinity,
	Callback = function(v) CONFIG.ignoreInfinity = v end})
Detect:AddToggle({Title = "Death Slash detection (ignore)", Default = CONFIG.ignoreDeathSlash,
	Callback = function(v) CONFIG.ignoreDeathSlash = v end})
Detect:AddToggle({Title = "Slashes of Fury detection (ignore)", Default = CONFIG.ignoreSlashesOfFury,
	Callback = function(v) CONFIG.ignoreSlashesOfFury = v end})
Detect:AddToggle({Title = "Time Hole detection (ignore)", Default = CONFIG.ignoreTimeHole,
	Callback = function(v) CONFIG.ignoreTimeHole = v end})
Detect:AddToggle({Title = "Anti-Phantom (notify when targeted)", Default = CONFIG.antiPhantom,
	Callback = function(v) CONFIG.antiPhantom = v end})
Detect:AddToggle({Title = "Anti-Hellhook (notify when hooked)", Default = CONFIG.antiHellhook,
	Callback = function(v) CONFIG.antiHellhook = v end})

-- ======================= VISUALS =======================
local Visuals = Window:AddTab({Title = "Visuals"})
Visuals:AddToggle({Id = "Preview", Title = "Prediction preview", Default = CONFIG.predictionPreview,
	Callback = function(value) CONFIG.predictionPreview = value end})
Visuals:AddToggle({Id = "MatchHUD", Title = "Compact match HUD", Default = CONFIG.compactHud,
	Callback = function(value) CONFIG.compactHud = value end})
Visuals:AddToggle({Title = "Ball trail", Default = CONFIG.ballTrail,
	Callback = function(v) CONFIG.ballTrail = v end})
Visuals:AddToggle({Title = "Ball indicator (off-screen arrow)", Default = CONFIG.ballIndicator,
	Callback = function(v) CONFIG.ballIndicator = v end})
Visuals:AddToggle({Title = "Parry visualizer (ring on parry)", Default = CONFIG.parryVisualizer,
	Callback = function(v) CONFIG.parryVisualizer = v end})
Visuals:AddToggle({Title = "Parry hits (burst on parry)", Default = CONFIG.parryHits,
	Callback = function(v) CONFIG.parryHits = v end})
Visuals:AddToggle({Title = "Ability ESP", Default = CONFIG.abilityEsp,
	Callback = function(v) CONFIG.abilityEsp = v end})
Visuals:AddToggle({Title = "Custom winstreak HUD", Default = CONFIG.customWinstreak,
	Callback = function(v) CONFIG.customWinstreak = v end})
Visuals:AddInput({Title = "Winstreak text ( %d = count )", Default = CONFIG.customWinstreakText,
	Callback = function(v) CONFIG.customWinstreakText = v end})

-- ======================= PLAYER =======================
local PlayerTab = Window:AddTab({Title = "Player"})
PlayerTab:AddToggle({Title = "Field of view", Default = CONFIG.fovEnabled,
	Callback = function(v) CONFIG.fovEnabled = v end})
PlayerTab:AddSlider({Title = "FOV", Default = CONFIG.fov, Min = 30, Max = 120, Rounding = 0,
	Callback = function(v) CONFIG.fov = v end})
PlayerTab:AddToggle({Title = "Gravity", Default = CONFIG.gravityEnabled,
	Callback = function(v) CONFIG.gravityEnabled = v end})
PlayerTab:AddSlider({Title = "Gravity value", Default = CONFIG.gravity, Min = 0, Max = 400, Rounding = 0,
	Callback = function(v) CONFIG.gravity = v end})
PlayerTab:AddToggle({Title = "Speed", Default = CONFIG.speedEnabled,
	Callback = function(v) CONFIG.speedEnabled = v end})
PlayerTab:AddSlider({Title = "Walk speed", Default = CONFIG.speed, Min = 0, Max = 120, Rounding = 0,
	Callback = function(v) CONFIG.speed = v end})
PlayerTab:AddToggle({Title = "Jump power", Default = CONFIG.jumpEnabled,
	Callback = function(v) CONFIG.jumpEnabled = v end})
PlayerTab:AddSlider({Title = "Jump power value", Default = CONFIG.jumpPower, Min = 0, Max = 300, Rounding = 0,
	Callback = function(v) CONFIG.jumpPower = v end})
PlayerTab:AddKeybind({Title = "Infinite jump", Default = "None", Mode = "Toggle",
	Callback = function(on) CONFIG.infiniteJump = on end})

-- ======================= BLATANT =======================
local Blatant = Window:AddTab({Title = "Blatant"})
Blatant:AddKeybind({Title = "Orbit ball", Default = CONFIG.orbitKey, Mode = "Toggle",
	Callback = function(on) CONFIG.orbitBall = on end})
Blatant:AddSlider({Title = "Orbit radius", Default = CONFIG.orbitRadius, Min = 3, Max = 30, Rounding = 0,
	Callback = function(v) CONFIG.orbitRadius = v end})
Blatant:AddSlider({Title = "Orbit speed", Default = CONFIG.orbitSpeed, Min = 1, Max = 12, Rounding = 1,
	Callback = function(v) CONFIG.orbitSpeed = v end})

-- ======================= TIMING =======================
local Timing = Window:AddTab({Title = "Timing"})
Timing:AddToggle({
	Id = "AutoTune", Title = "Automatic tuning", Default = CONFIG.autoTune,
	Callback = function(value) CONFIG.autoTune = value end,
})
Timing:AddSection("Adaptive accuracy engine")
Timing:AddToggle({Id = "AdaptiveLearning", Title = "Adaptive learning (ServerParryCount)",
	Default = CONFIG.adaptiveLearning,
	Description = "Learns the exact lead from confirmed parries and fires earlier only when it detects late hits.",
	Callback = function(value)
		CONFIG.adaptiveLearning = value
		if not value then learnedBias, parryMissEma, pendingFires = 0, 0, {} end
	end})
Timing:AddToggle({Id = "VelocityBlend", Title = "Velocity blend (anti-late)",
	Default = CONFIG.velocityBlend,
	Description = "Uses measured ball displacement so an under-reported velocity never triggers late.",
	Callback = function(value) CONFIG.velocityBlend = value end})
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

-- ======================= GUI =======================
local Interface = Window:AddTab({Title = "GUI"})
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
		or (CONFIG.autoTune and "Based on speed and trigger distance" or tostring(CONFIG.maxRange) .. " studs")
	local learnText = CONFIG.adaptiveLearning
		and string.format("+%.0f ms (miss %.0f%%)", learnedBias * 1000, math.clamp(parryMissEma, 0, 1) * 100)
		or "off"
	TuningStatus:SetContent(string.format("%s | Lead: %.0f ms | Retry: %.0f ms\nRange: %s | Close range: %.0f studs\nPing jitter: %.0f ms | Frame budget: %.1f ms\nLearned bias: %s",
		CONFIG.autoTune and "Automatic" or "Manual", effective.lead * 1000, effective.retry * 1000,
		rangeText, effective.clashRange, metrics.pingJitter * 1000, effective.frame * 1000, learnText))
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
	if not finite(position.Magnitude) or not finite(speed) then return nil end

	local realBall = safeAttribute(object, "realBall")
	if realBall == nil and object ~= part then
		realBall = safeAttribute(part, "realBall")
	end
	if realBall == false then return nil end

	local target = safeAttribute(object, "target") or safeAttribute(object, "Target")
	if target == nil and object ~= part then
		target = safeAttribute(part, "target") or safeAttribute(part, "Target")
	end

	-- FakeoutRange is the game's own threat radius for a ball NOT tagged to you:
	-- BallReplicationHandler highlights it as dangerous only within this range.
	-- Mirroring it lets us parry a ball juking toward us while ignoring balls
	-- that merely pass nearby on their way to someone else.
	local fakeoutRange = safeAttribute(object, "FakeoutRange")
	if fakeoutRange == nil and object ~= part then
		fakeoutRange = safeAttribute(part, "FakeoutRange")
	end

	return {
		object = object,
		part = part,
		position = position,
		velocity = velocity,
		speed = speed,
		target = target,
		real = realBall,
		fakeoutRange = type(fakeoutRange) == "number" and fakeoutRange or nil,
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
	-- Matcha does not allow :Fire() on the game's BindableEvents, so both parry
	-- modes go through the real left-click path (the game turns MouseButton1 into
	-- ParryAttempt itself). The dropdown is kept for non-Matcha executors.
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

-- Accuracy gate: rolls the configured (or randomized) accuracy percentage.
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

-- ---- Ability helper ----
-- Matcha cannot :Fire() the AbilityButtonPress BindableEvent, so trigger the
-- equipped ability by simulating its keybind via keypress/keyrelease. The bound
-- key is read live from the Hotbar hotkey label (single letters map straight to
-- their virtual-key code: 'A'..'Z' == 0x41..0x5A). Falls back to E / X.
local function charToVk(ch)
	if type(ch) ~= "string" or #ch ~= 1 then return nil end
	local up = ch:upper()
	local b = string.byte(up)
	if (b >= 65 and b <= 90) or (b >= 48 and b <= 57) then return b end
	return nil
end
local function hotbarKeyVk(slot, fallback)
	local ok, vk = pcall(function()
		local hb = player.PlayerGui.Hotbar
		local frame = hb:FindFirstChild(slot)
		if not frame then return nil end
		-- The hotkey display is a short TextLabel (named "Q"/"X" historically).
		for _, d in ipairs(frame:GetDescendants()) do
			if d:IsA("TextLabel") and type(d.Text) == "string" and #d.Text == 1 then
				local v = charToVk(d.Text)
				if v then return v end
			end
		end
		return nil
	end)
	return (ok and vk) or fallback
end
local function useAbility(secondary)
	if type(keypress) ~= "function" then return end
	local vk = secondary and hotbarKeyVk("SecondAbility", 0x58) or hotbarKeyVk("Ability", 0x45)
	pcall(function()
		keypress(vk)
		task.delay(0.03, function() pcall(keyrelease, vk) end)
	end)
end

-- Nearest incoming real ball root-distance, used by proximity features.
local function nearestBallInfo(root)
	local folder = Workspace:FindFirstChild(CONFIG.ballsFolder)
	if not folder or not root then return nil end
	local best, bestDist = nil, math.huge
	for _, object in ipairs(folder:GetChildren()) do
		local ball = readBall(object)
		if ball and ball.real ~= false then
			local d = (root.Position - ball.position).Magnitude
			if d < bestDist then best, bestDist = ball, d end
		end
	end
	if best then return best, bestDist end
	return nil
end

-- =====================================================================
-- Closed-loop lead calibration.
-- The character's ServerParryCount rises once per server-confirmed parry.
-- Each committed parry pushes a pending marker; a count increment resolves the
-- oldest marker as a success, and a marker that ages out with no increment is a
-- miss. A rising miss rate nudges the learned lead earlier (bounded); a clean
-- streak lets it relax back. This tunes the timing to the live server + ping
-- with no manual sliders.
-- =====================================================================
local function currentParryCount()
	local ch = player.Character
	if not ch then return nil end
	local ok, v = pcall(function() return ch:GetAttribute("ServerParryCount") end)
	if ok and type(v) == "number" then return v end
	return nil
end

local function resolveLearning(now)
	if not CONFIG.adaptiveLearning then return end
	local count = currentParryCount()
	if count and lastParryCountSeen and count > lastParryCountSeen then
		for _ = 1, count - lastParryCountSeen do
			if #pendingFires > 0 then
				table.remove(pendingFires, 1)
				lastLandDistance = currentThreat and currentThreat.distance or lastLandDistance
			end
			parryMissEma = parryMissEma * 0.7          -- confirmed hit
		end
	end
	if count ~= nil then lastParryCountSeen = count end
	for i = #pendingFires, 1, -1 do
		if now - pendingFires[i].t > 0.5 then
			table.remove(pendingFires, i)
			parryMissEma = parryMissEma * 0.8 + 0.2    -- fire never confirmed = miss
		end
	end
	if now - lastBiasAdjust > 0.3 then
		lastBiasAdjust = now
		if parryMissEma > 0.15 then
			learnedBias = math.min(learnedBias + 0.004, CONFIG.maxLearnBias)
		elseif learnedBias > 0 then
			learnedBias = math.max(0, learnedBias - 0.002)
		end
	end
end

-- Helpers are assigned before the update connections are installed.
local applyPlayerMods, runFeatures, drawFeatureFx, spawnBurst, ballIgnored, curveBall

local function chooseThreat(root, now)
	local folder = Workspace:FindFirstChild(CONFIG.ballsFolder)
	if not folder then return nil end
	local rootPosition = root.Position
	local rootVelocity = Vector3.new(0, 0, 0)
	local velocityOk, value = pcall(function() return root.AssemblyLinearVelocity end)
	if velocityOk and value and finite(value.Magnitude) then rootVelocity = value end
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
				state.motionPos, state.motionAt, state.measuredVelocity = nil, nil, nil
				state.motionConfidence = 0
				state.target = ball.target
			end
			ball.velocity = sampleMotion(state, ball.position, ball.velocity, now, CONFIG.velocityBlend)
			ball.speed = ball.velocity.Magnitude
			local relativeVelocity = ball.velocity - rootVelocity
			local offset = rootPosition - ball.position
			local distance = offset.Magnitude
			local toRoot = distance > 0.001 and offset / distance or Vector3.new(0, 0, 0)
			local closing = relativeVelocity:Dot(toRoot)
			if advanceApproach(state, closing, distance) then
				firedAt[key], state.rearmedAt = nil, now
			end
			local dt = state.sampleAt and now - state.sampleAt or 0
			if not state.sampleAt or dt >= 0.004 then
				local stable = state.velocity and state.velocity.Magnitude > 0.001
					and relativeVelocity.Magnitude > 0.001
					and relativeVelocity.Unit:Dot(state.velocity.Unit) > 0.95
				if stable and state.closing and closing > 0 and dt <= 0.1 then
					local gain = math.clamp((closing - state.closing) / dt, 0, closing * 2)
					state.acceleration = (state.acceleration or 0) * 0.75 + gain * 0.25
				else state.acceleration = 0 end
				state.closing, state.sampleAt, state.velocity = closing, now, relativeVelocity
			end
			local focusName = (CONFIG.targetPlayer ~= "None" and CONFIG.targetPlayer) or player.Name
			local aimed = ball.target == focusName
			local unknown = ball.target == nil or ball.target == ""
			local fakeout = not aimed and ball.fakeoutRange ~= nil and distance <= ball.fakeoutRange
			local priority = aimed and 3 or (fakeout and 2 or (unknown and 1 or 0))
			local eligible = aimed or fakeout or CONFIG.anyIncoming or (unknown and CONFIG.fallback)
			local trigger = interceptionDistance(CONFIG, effective, closing, state.acceleration)
			local range = math.max(detectionRange(CONFIG, effective, ball.speed), trigger + 4)
			if eligible and ball.speed >= CONFIG.minSpeed and distance <= range
				and not (ballIgnored and ballIgnored(ball)) then
				local allowedMiss = priority >= 2 and CONFIG.targetedRadius or CONFIG.contactRadius
				local tti = impactTime(offset, relativeVelocity, CONFIG.contactRadius, allowedMiss)
				if tti then
					ball.key, ball.state = key, state
					local candidate = {ball = ball, distance = distance, tti = tti, aimed = aimed,
						priority = priority, range = range, triggerDistance = trigger, closing = closing}
					-- An out-of-window targeted ball must not hide an immediate collision.
					if betterThreat(candidate, best) then best = candidate end
				end
			end
		end
	end
	return best
end

local function attemptThreat(root, threat, now, doSample)
	-- Share the actual retry/rebound timing with the diagnostic reason.
	local clash = threat and CONFIG.clashEnabled and (threat.priority or 0) >= 2
		and threat.distance <= CONFIG.clashRange and threat.ball.speed >= CONFIG.clashMinSpeed
	local interval = clash and CONFIG.clashInterval or effective.interval
	local state = threat and threat.ball.state
	if state and not firedAt[threat.ball.key] and state.rearmedAt
		and now - state.rearmedAt <= effective.frame * 2 then
		-- A confirmed rebound is a fresh shot, even with retries disabled.
		interval = math.min(interval, CONFIG.clashInterval)
	end
	-- [DIAGNOSTIC] record what the engine sees for any close ball, and why it
	-- does or does not fire, so a death can be replayed from _G.BB_PARRY_LOG.
	if doSample ~= false and threat and threat.distance < math.max(70, threat.triggerDistance * 1.5) then
		local reason
		if not CONFIG.enabled then reason = "disabled"
		elseif menuOpen then reason = "MENU_OPEN"
		elseif ballIgnored and ballIgnored(threat.ball) then reason = "ignored"
		elseif type(isrbxactive) == "function" and not isrbxactive() then reason = "NOT_FOCUSED"
		elseif threat.distance > threat.triggerDistance then reason = "far>trig"
		elseif CONFIG.cooldownProtection and now - lastParryEnd < CONFIG.cooldownGap then reason = "cooldownProt"
		elseif now - lastClick < interval then reason = "interval"
		elseif not canAttempt(now, firedAt[threat.ball.key], threat.ball.state, clash, effective.retry, CONFIG.maxClashRetries) then reason = "LOCKED"
		else reason = "->FIRE" end
		local tgt = threat.ball.target
		tgt = (tgt == player.Name and "ME") or (tgt == nil and "nil") or (tgt == "" and "empty") or tostring(tgt):sub(1, 8)
		debugLog[#debugLog + 1] = string.format("t%.2f d=%.1f trg=%.1f spd=%.0f pri=%d tgt=%s %s",
			now % 100, threat.distance, threat.triggerDistance, threat.ball.speed, threat.priority or -9, tgt, reason)
		if #debugLog > 240 then table.remove(debugLog, 1) end
	end
	if not CONFIG.enabled or not threat or menuOpen then return end
	if type(isrbxactive) == "function" and not isrbxactive() then return end
	if ballIgnored and ballIgnored(threat.ball) then return end
	if threat.distance > threat.triggerDistance then
		-- Kill pre click: allow one early blind click on a fast, nearby ball.
		if CONFIG.killPreClick and threat.ball.speed >= CONFIG.preClickBallSpeed
			and threat.distance <= CONFIG.preClickRange and now - lastClick >= effective.interval then
			if passesAccuracy() and fireParry() then lastClick = now; spawnBurst(threat.ball.position) end
		end
		return
	end
	-- Cooldown protection: keep a minimum gap after the previous parry.
	if CONFIG.cooldownProtection and now - lastParryEnd < CONFIG.cooldownGap then return end

	if now - lastClick < interval then return end

	local key, state = threat.ball.key, threat.ball.state
	local previous = firedAt[key]
	if not canAttempt(now, previous, state, clash, effective.retry, CONFIG.maxClashRetries) then return end
	-- Accuracy: consume the shot on a miss roll so the percentage is meaningful.
	if not passesAccuracy() then
		lastClick, firedAt[key] = now, now
		state.locked, state.departed, state.departureStart, state.lastDistance = true, false, nil, threat.distance
		return
	end
	if fireParry() then
		-- One learning marker per fresh committed shot (not per close-range retry),
		-- so a single ServerParryCount increment maps to a single intended parry.
		if not previous and CONFIG.adaptiveLearning then
			pendingFires[#pendingFires + 1] = {t = now}
		end
		if previous then state.retries = (state.retries or 0) + 1 end
		state.locked = true
		state.departed, state.departureStart = false, nil
		state.lastDistance = threat.distance
		lastClick, firedAt[key], lastParryEnd = now, now, now
		parryCount = parryCount + 1
		lastFireDistance = threat.distance
		if curveBall then curveBall(threat.ball, root) end
		if spawnBurst then spawnBurst(threat.ball.position) end
	end
end

-- The critical path completes before any Drawing/UI or optional feature work.
local function update(doSample)
	if not running then return end
	local now = tick()
	if doSample ~= false then samplePerformance(now) end
	local root = getRoot()
	local rootId = root and (root.Address or root:GetFullName())
	if rootId ~= activeRoot then
		tracked, firedAt = {}, {}
		pendingFires, lastParryCountSeen = {}, nil
		activeRoot, lastClick = rootId, -math.huge
	end
	local threat = root and chooseThreat(root, now) or nil
	currentThreat = threat
	if root then attemptThreat(root, threat, now, doSample) end

	-- Heartbeat only does detection/input. Draw once per render callback.
	if doSample ~= false then
		resolveLearning(now)
		pcall(updateGui)
		updatePreview(root, threat)
		if root and drawFeatureFx then pcall(drawFeatureFx, root, threat) end
		if applyPlayerMods then pcall(applyPlayerMods) end
		if root and runFeatures then pcall(runFeatures, now, root, threat) end
		if now - lastCleanup >= 1 then
			lastCleanup = now
			for key, state in pairs(tracked) do
				if now - state.seen > 2 then tracked[key], firedAt[key] = nil, nil end
			end
		end
	end
end

-- =====================================================================
-- Extra feature overlays (Drawing pool; auto-removed on unload)
-- =====================================================================
local fx = {}
fx.indicator = overlayObject("Triangle", {Filled = true, Transparency = 1, Color = Color3.fromRGB(255, 90, 90), ZIndex = 9})
fx.winstreak = overlayObject("Text", {Size = 18, Font = 2, Outline = true, Center = true,
	Position = Vector2.new(0, 0), Color = Color3.fromRGB(255, 220, 120), Transparency = 1, ZIndex = 11})
local trailPoints = {}     -- recent ball screen positions
local trailLines = {}
for i = 1, 14 do
	trailLines[i] = overlayObject("Line", {Thickness = 2, Transparency = 1, Color = Color3.fromRGB(120, 200, 255), ZIndex = 8})
end
local burstCircles = {}
for i = 1, 6 do
	burstCircles[i] = overlayObject("Circle", {NumSides = 28, Filled = false, Thickness = 2, Transparency = 0, ZIndex = 11})
end
local espTexts = {}
for i = 1, 12 do
	espTexts[i] = overlayObject("Text", {Size = 13, Font = 2, Outline = true, Center = true, Transparency = 1,
		Color = Color3.fromRGB(255, 255, 255), ZIndex = 9})
end

function spawnBurst(worldPos)
	if not (CONFIG.parryHits or CONFIG.parryVisualizer) then return end
	parryBurst[#parryBurst + 1] = {pos = worldPos, t0 = os.clock()}
	if #parryBurst > 6 then table.remove(parryBurst, 1) end
end

-- =====================================================================
-- Detection listeners: notify on abilities used against the local player
-- =====================================================================
local function notify(title, text)
	pcall(function() Library:Notify({Title = title, Content = text, Duration = 3}) end)
end
local function bindDetection(name, cfgKey, title, text)
	local ev = remote(name)
	if not ev or not ev.OnClientEvent then return end
	local ok, conn = pcall(function()
		return ev.OnClientEvent:Connect(function()
			if CONFIG[cfgKey] then notify(title, text) end
		end)
	end)
	if ok and conn then remoteConns[#remoteConns + 1] = conn end
end
bindDetection("Phantom", "antiPhantom", "Anti-Phantom", "A Phantom ability was used.")
bindDetection("PlrHellHooked", "antiHellhook", "Anti-Hellhook", "You are being Hell Hooked!")

-- Ignore special ability balls by name/attribute keyword so their off-timing
-- does not bait a fatal auto-parry.
function ballIgnored(ball)
	local name = ""
	pcall(function() name = tostring(ball.object.Name):lower() end)
	if CONFIG.ignoreInfinity and name:find("infinit") then return true end
	if CONFIG.ignoreDeathSlash and (name:find("death") or name:find("slash")) then return true end
	if CONFIG.ignoreSlashesOfFury and name:find("fury") then return true end
	if CONFIG.ignoreTimeHole then
		if name:find("time") then return true end
		if safeAttribute(ball.part, "IsInTimeHoleAOE") or safeAttribute(ball.object, "IsInTimeHoleAOE") then return true end
	end
	return false
end

-- =====================================================================
-- Curve mode: point the parried ball at the camera aim or nearest enemy.
-- =====================================================================
local function setBallTarget(ball, name)
	pcall(function() ball.object:SetAttribute("target", name) end)
	pcall(function() ball.part:SetAttribute("target", name) end)
end
function curveBall(ball, root)
	if CONFIG.curveMode == "Off" then return end
	local cam = Workspace.CurrentCamera
	local bestName, bestScore = nil, -math.huge
	for _, plr in ipairs(Players:GetPlayers()) do
		if plr ~= player and plr.Character then
			local prt = plr.Character:FindFirstChild("HumanoidRootPart")
			if prt then
				local dir = prt.Position - ball.position
				local score
				if CONFIG.curveMode == "Camera" and cam then
					score = cam.CFrame.LookVector:Dot(dir.Unit)  -- most aligned with view
				else
					score = -dir.Magnitude                        -- nearest enemy
				end
				if score > bestScore then bestScore, bestName = score, plr.Name end
			end
		end
	end
	if bestName then setBallTarget(ball, bestName) end
end

-- =====================================================================
-- Player modifications (FOV / gravity / speed / jump / infinite jump)
-- =====================================================================
pcall(function() baseGravity = Workspace.Gravity end)
function applyPlayerMods()
	local cam = Workspace.CurrentCamera
	if CONFIG.fovEnabled and cam then pcall(function() cam.FieldOfView = CONFIG.fov end) end
	if CONFIG.gravityEnabled then pcall(function() Workspace.Gravity = CONFIG.gravity end)
	elseif baseGravity then pcall(function() Workspace.Gravity = baseGravity end) end
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		if CONFIG.speedEnabled then pcall(function() humanoid.WalkSpeed = CONFIG.speed end) end
		if CONFIG.jumpEnabled then
			pcall(function() humanoid.UseJumpPower = true end)
			pcall(function() humanoid.JumpPower = CONFIG.jumpPower end)
		end
		if CONFIG.infiniteJump then
			pcall(function()
				if humanoid:GetState() == Enum.HumanoidStateType.Freefall then
					humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
				end
			end)
		end
	end
end

-- =====================================================================
-- Orbit ball: sweep the character around the nearest ball each frame.
-- =====================================================================
local function orbitStep(now, root)
	if not CONFIG.orbitBall or not root then return end
	local ball = nearestBallInfo(root)
	if not ball then return end
	orbitAngle = orbitAngle + CONFIG.orbitSpeed * math.clamp(metrics.frame, 1/240, 0.05)
	local r = CONFIG.orbitRadius
	local target = ball.position + Vector3.new(math.cos(orbitAngle) * r, 0, math.sin(orbitAngle) * r)
	pcall(function() root.CFrame = CFrame.new(target, ball.position) end)
end

-- =====================================================================
-- Spam / triggerbot / auto-ability (run independently of the timed parry)
-- =====================================================================
function runFeatures(now, root, threat)
	if menuOpen then return end
	if type(isrbxactive) == "function" and not isrbxactive() then return end

	-- Manual spam: blind parry at the configured rate while toggled on.
	if CONFIG.manualSpam and now - lastSpam >= CONFIG.manualSpamInterval then
		if fireParry() then lastSpam = now end
	end
	-- Auto spam: parry rapidly while a real ball sits inside the proximity ring.
	if CONFIG.autoSpam and now - lastSpam >= CONFIG.autoSpamInterval then
		local ball, dist = nearestBallInfo(root)
		if ball and dist <= CONFIG.autoSpamRange then
			if fireParry() then lastSpam = now; spawnBurst(ball.position) end
		end
	end
	-- Triggerbot: instant parry the moment a real ball is aimed at you.
	if CONFIG.triggerbot and threat and threat.aimed and now - lastClick >= effective.interval then
		if fireParry() then lastClick = now; spawnBurst(threat.ball.position) end
	end
	-- Auto ability: fire the equipped ability when a ball closes in.
	if CONFIG.autoAbility and now - lastAbility >= CONFIG.autoAbilityInterval then
		local ball, dist = nearestBallInfo(root)
		if ball and dist <= CONFIG.autoAbilityRange then
			useAbility(CONFIG.autoAbilitySecondary)
			lastAbility = now
		end
	end
	orbitStep(now, root)
end

-- =====================================================================
-- Feature overlays drawn each frame (trail, indicator, bursts, ESP, HUD).
-- =====================================================================
function drawFeatureFx(root, threat)
	-- Ball trail
	for _, l in ipairs(trailLines) do l.Visible = false end
	if CONFIG.ballTrail and root and type(WorldToScreen) == "function" then
		local ball = nearestBallInfo(root)
		if ball then
			local pt, vis = WorldToScreen(ball.position)
			if vis then
				table.insert(trailPoints, 1, pt)
				while #trailPoints > #trailLines + 1 do table.remove(trailPoints) end
			end
		else trailPoints = {} end
		for i = 1, #trailPoints - 1 do
			local a, b, line = trailPoints[i], trailPoints[i + 1], trailLines[i]
			if line then line.From = a; line.To = b; line.Transparency = 1 - (i / #trailLines) * 0.8; line.Visible = true end
		end
	else trailPoints = {} end

	-- Off-screen / on-screen ball indicator arrow toward the nearest ball.
	if fx.indicator then fx.indicator.Visible = false end
	if CONFIG.ballIndicator and root and fx.indicator and type(WorldToScreen) == "function" then
		local ball = nearestBallInfo(root)
		local cam = Workspace.CurrentCamera
		if ball and cam then
			local vw, vh = 1920, 1080
			pcall(function() local vp = cam.ViewportSize; vw, vh = vp.X, vp.Y end)
			local cx, cy = vw / 2, vh / 2
			local pt, vis = WorldToScreen(ball.position)
			local dx, dy
			if vis then dx, dy = pt.X - cx, pt.Y - cy else
				local rel = cam.CFrame:PointToObjectSpace(ball.position)
				dx, dy = rel.X, rel.Y ~= 0 and -rel.Y or 1
			end
			local mag = math.sqrt(dx * dx + dy * dy)
			if mag > 1 then
				dx, dy = dx / mag, dy / mag
				local ex, ey = cx + dx * math.min(cx, cy) * 0.6, cy + dy * math.min(cx, cy) * 0.6
				local px, py = -dy, dx
				fx.indicator.PointA = Vector2.new(ex + dx * 18, ey + dy * 18)
				fx.indicator.PointB = Vector2.new(ex - dx * 6 + px * 10, ey - dy * 6 + py * 10)
				fx.indicator.PointC = Vector2.new(ex - dx * 6 - px * 10, ey - dy * 6 - py * 10)
				fx.indicator.Visible = true
			end
		end
	end

	-- Parry bursts (Parry Hits / Visualizer)
	local nowc = os.clock()
	for _, c in ipairs(burstCircles) do c.Visible = false end
	for i = #parryBurst, 1, -1 do
		local b = parryBurst[i]
		local age = nowc - b.t0
		if age > 0.35 then table.remove(parryBurst, i)
		elseif type(WorldToScreen) == "function" then
			local pt, vis = WorldToScreen(b.pos)
			local circle = burstCircles[i]
			if vis and circle then
				circle.Position = pt
				circle.Radius = 12 + age * 160
				circle.Transparency = 1 - age / 0.35
				circle.Color = CONFIG.parryVisualizer and Color3.fromRGB(120, 220, 255) or Color3.fromRGB(255, 240, 120)
				circle.Visible = true
			end
		end
	end

	-- Ability ESP: label the equipped (enabled) ability above each player.
	for _, t in ipairs(espTexts) do t.Visible = false end
	if CONFIG.abilityEsp and type(WorldToScreen) == "function" then
		local slot = 0
		for _, plr in ipairs(Players:GetPlayers()) do
			if plr ~= player and plr.Character and slot < #espTexts then
				local head = plr.Character:FindFirstChild("Head") or plr.Character:FindFirstChild("HumanoidRootPart")
				local abilities = plr.Character:FindFirstChild("Abilities")
				local abilityName
				if abilities then
					for _, a in ipairs(abilities:GetChildren()) do
						local enabled = true
						pcall(function() enabled = a.Enabled ~= false end)
						if enabled and a.Name ~= "inf" then abilityName = a.Name; break end
					end
					abilityName = abilityName or (abilities:GetChildren()[1] and abilities:GetChildren()[1].Name)
				end
				if head and abilityName then
					local pt, vis = WorldToScreen(head.Position)
					if vis then
						slot = slot + 1
						local t = espTexts[slot]
						t.Position = Vector2.new(pt.X, pt.Y - 40)
						t.Text = plr.Name .. " [" .. abilityName .. "]"
						t.Visible = true
					end
				end
			end
		end
	end

	-- Custom winstreak HUD
	if fx.winstreak then fx.winstreak.Visible = false end
	if CONFIG.customWinstreak and fx.winstreak then
		local streak = 0
		-- Source: the character's WinStreakDisplay billboard text (real value),
		-- with a player-attribute fallback.
		pcall(function()
			local ch = player.Character
			local disp = ch and ch:FindFirstChild("WinStreakDisplay")
			if disp then
				for _, d in ipairs(disp:GetDescendants()) do
					if d:IsA("TextLabel") then
						local n = tostring(d.Text):match("%d+")
						if n then streak = tonumber(n); break end
					end
				end
			end
			if streak == 0 then
				streak = tonumber(player:GetAttribute("Winstreak") or player:GetAttribute("WinStreak")) or 0
			end
		end)
		local txt = CONFIG.customWinstreakText
		local ok, formatted = pcall(string.format, txt, streak)
		fx.winstreak.Text = ok and formatted or txt
		fx.winstreak.Position = Vector2.new((Workspace.CurrentCamera and Workspace.CurrentCamera.ViewportSize.X or 1920) / 2, 90)
		fx.winstreak.Visible = true
	end
end

local renderSignal = RunService.RenderStepped or RunService.Heartbeat
assert(renderSignal, "Matcha exposes neither RenderStepped nor Heartbeat")
renderConnection = renderSignal:Connect(function() update(true) end)
-- Second, post-physics pass: Heartbeat runs after the ball's velocity/position
-- have been integrated, so a fast incoming ball is detected and parried a
-- fraction earlier than waiting for the next render frame. Perf sampling is
-- skipped here so the frame-time metric stays accurate.
local heartbeatConnection = nil
if RunService.Heartbeat and RunService.Heartbeat ~= renderSignal then
	heartbeatConnection = RunService.Heartbeat:Connect(function() update(false) end)
end

_G.BB_MATCHA_STOP = function()
	running = false
	if renderConnection then renderConnection:Disconnect() end
	if heartbeatConnection then heartbeatConnection:Disconnect() end
	for _, conn in ipairs(remoteConns) do pcall(function() conn:Disconnect() end) end
	if baseGravity then pcall(function() Workspace.Gravity = baseGravity end) end
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
		clashRange = CONFIG.clashRange, attempts = parryCount,
		lookAheadMs = (effective.lookAhead or 0) * 1000,
		impactMs = currentThreat and currentThreat.tti * 1000,
		lastFireDistance = lastFireDistance, triggerDistance = currentThreat and currentThreat.triggerDistance,
		extraDistance = CONFIG.earlyParry and CONFIG.extraDistance or 0,
		adaptiveLearning = CONFIG.adaptiveLearning, learnedBiasMs = learnedBias * 1000,
		missRate = parryMissEma, serverParryCount = lastParryCountSeen}
end

-- [DIAGNOSTIC] read recent close-ball frames after a death.
_G.BB_PARRY_LOG = function() return debugLog end

Library:OnUnload(function()
	if running and _G.BB_MATCHA_STOP then _G.BB_MATCHA_STOP() end
end)

if restoreMinimized then Library:Minimize() end
print("WabiSabi auto-parry restored (P minimize/play, T toggle)")
