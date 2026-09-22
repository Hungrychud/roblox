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
	-- Only parry balls that are actually a threat to YOU: tagged at you (aimed) or
	-- juking toward you within their FakeoutRange. anyIncoming/fallback are OFF so
	-- the parry is spent on your own ball -- clean clashes, no cooldown burnt on
	-- balls passing to someone else.
	anyIncoming = false,
	autoTune = true,
	earlyParry = false,             -- reactive model: no extra-distance creep
	extraDistance = 4,
	accelerationPrediction = true,  -- fire earlier when the ball is genuinely speeding up (capped +3 studs, never delays)
	predictionPreview = false,      -- overlay removed from GUI; keep off
	compactHud = true,
	ballsFolder = "Balls",
	minSpeed = 5,
	maxRange = 140,
	contactRadius = 4.5,
	targetedRadius = 18,
	-- ---- Reactive parry geometry ----
	standoff = 12,                  -- hard min buffer: never let the ball get closer than this at press
	maxParryRange = 80,             -- furthest a parry still registers (auto-calibrated from live hits)
	calibrateRange = true,          -- learn maxParryRange from confirmed ServerParryCount outcomes
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
	clashProximity = 32,      -- when an alive opponent is within this many studs, force fast
	                          -- clash timing on the threat so rapid volleys never slip past
	fallback = false,

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
	adaptiveLearning = true,   -- self-tune lead earlier from live ServerParryCount misses (bounded)
	velocityBlend = true,      -- never under-estimate ball speed (positional derivative)
	maxLearnBias = 0.06,       -- ceiling on how much earlier learning may fire (s)
	instantPredict = false,    -- (prediction) fire at exact sub-frame instant — off: reactive model
	instantAcquire = true,     -- trust measured ball speed on the first frame a threat is seen
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
local lastLearnAt = 0      -- throttle ServerParryCount polling / learning off the hot path
local lastModsAt = 0       -- throttle player-modification writes
local fxHidden = false     -- feature-overlay pool currently hidden (skip per-frame resets)
local frameId = 0          -- increments each update; keys the nearest-ball cache
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

-- ---- Live parry-range calibration (independent of adaptive lead learning) ----
local rangeFires = {}                -- {t, dist} one per fresh committed parry
local calibCountSeen = nil           -- ServerParryCount tracked for range learning
local calibDistMax = 0               -- largest confirmed-parry distance observed

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
	-- Reactive trigger: press when the ball, at its CURRENT closing speed, is about
	-- to enter the standoff buffer within one reaction window (lead = reaction+ping,
	-- lookAhead = one frame so it cannot slip through between observations). No
	-- acceleration extrapolation, no early-distance creep -- purely how fast it is
	-- coming and how close it is right now.
	local reach = config.standoff + math.max(0, closing) * (profile.lead + (profile.lookAhead or 0))
	-- Optional extra buffer, and never reach past where a parry actually registers.
	if config.earlyParry then reach = reach + config.extraDistance end
	if config.accelerationPrediction then
		reach = reach + math.min(3, math.max(0, closing) * 0.025,
			0.5 * math.max(0, acceleration) * profile.lead * profile.lead)
	end
	return math.min(config.maxParryRange, reach)
end

local function sampleMotion(state, position, velocity, now, blend, instant)
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
			-- Instant acquire: a single coherent displacement can override a stale
			-- engine speed sooner (cap 2.5x vs the cautious 1.5x) so a fresh fast
			-- ball is timed from its true speed one frame earlier.
			local cap = instant and 2.5 or 1.5
			return velocity.Unit * math.min(measuredSpeed, speed * cap)
		elseif instant and aligned and speed <= 0.001 and measuredSpeed > 0.001
			and (state.motionConfidence or 0) >= 1 then
			-- Engine reported no velocity at all but the ball plainly moved; use the
			-- measured vector directly so a dead-read never delays detection.
			return measured
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

-- Load the INS-ui Drawing UI library (github.com/neaxusxgod-png/INS-ui).
-- It renders with the Drawing API (Square/Text/Image). Matcha only confirms
-- Text/Circle/Line/Triangle, so the menu may not draw under Matcha; parrying
-- still runs headless (it fires mouse1click, independent of the menu). The
-- compact Drawing HUD below is the reliable fallback readout.
local fetched, chunkOrErr = pcall(function()
	return game:HttpGet("https://raw.githubusercontent.com/neaxusxgod-png/INS-ui/main/uilib.min.lua")
end)
assert(fetched and type(chunkOrErr) == "string", "Could not download INS-ui")
local uiChunk, compileError = loadstring(chunkOrErr)
assert(uiChunk, "Could not compile INS-ui: " .. tostring(compileError))
local Lib = uiChunk() or (type(INSUI) ~= "nil" and INSUI) or _G["INSUI"]
assert(type(Lib) == "table" and type(Lib.CreateWindow) == "function", "Invalid INS-ui library")

for _, plr in ipairs(Players:GetPlayers()) do
	if plr ~= player then playerNames[#playerNames + 1] = plr.Name end
end

-- Dynamic status strings. updateGui refreshes them; the Labels below read them
-- so INS-ui re-renders the live values each frame.
local statusText = "Waiting for ball"
local tuningText = "Measuring ping and frame time..."

local Window = Lib:CreateWindow({
	title = "Matcha",
	subtitle = "Auto Parry",
	size = Vector2.new(620, 520),
	menuKey = "p",
})

-- ======================= AUTO PARRY =======================
local Main = Window:Tab("Auto Parry", "sword")
local Controls = Main:Section("Auto Parry", "Left", "T toggles auto parry. Parry runs even while the menu is open.")
Controls:Toggle("Auto parry", CONFIG.enabled, function(v) CONFIG.enabled = v end,
	"Clicks when an incoming real ball reaches your parry timing window. Only parries balls that threaten you."):AddKeybind("t", "Toggle")
Controls:Toggle("Ping compensation", CONFIG.pingComp, function(v) CONFIG.pingComp = v end,
	"Add measured network delay and jitter to the timing lead.")
Controls:Slider("Clash proximity", CONFIG.clashProximity, 1, 0, 80, " st", function(v) CONFIG.clashProximity = v end)
Controls:Slider("Accuracy", CONFIG.accuracy, 1, 0, 100, "%", function(v) CONFIG.accuracy = v end)

local Tuning = Main:Section("Tuning", "Right", "Timing and accuracy engine.")
Tuning:Toggle("Automatic tuning", CONFIG.autoTune, function(v) CONFIG.autoTune = v end,
	"Choose timing and range from ping, jitter, frame time and ball speed.")
Tuning:Toggle("Velocity blend (anti-late)", CONFIG.velocityBlend, function(v) CONFIG.velocityBlend = v end,
	"Never under-estimate ball speed; uses the positional derivative.")
Tuning:Toggle("Instant acquire", CONFIG.instantAcquire, function(v) CONFIG.instantAcquire = v end,
	"Trust measured speed on the first frame a threat is seen.")
Tuning:Toggle("Acceleration prediction", CONFIG.accelerationPrediction, function(v) CONFIG.accelerationPrediction = v end,
	"Fire a touch earlier when the ball is genuinely speeding up (capped +3 studs, never delays).")
Tuning:Toggle("Adaptive learning", CONFIG.adaptiveLearning, function(v) CONFIG.adaptiveLearning = v end,
	"Self-tune the lead earlier from live ServerParryCount misses (bounded).")
Tuning:Toggle("Auto-calibrate parry range", CONFIG.calibrateRange, function(v) CONFIG.calibrateRange = v end,
	"Learn the real max parry range from confirmed hits.")
Tuning:Slider("Standoff buffer", CONFIG.standoff, 1, 4, 30, " st", function(v) CONFIG.standoff = v end)
Tuning:Slider("Max parry range", CONFIG.maxParryRange, 1, 40, 120, " st", function(v) CONFIG.maxParryRange = v end)
Tuning:Slider("Reaction lead (manual)", CONFIG.baseLead * 1000, 1, 20, math.floor(CONFIG.maxLead * 1000 + 0.5), " ms",
	function(v) CONFIG.baseLead = v / 1000 end)

local StatusSec = Main:Section("Live status", "Left")
StatusSec:Label(function() return statusText end)
StatusSec:Label(function() return tuningText end)
StatusSec:Button("Unload script", function()
	if _G.BB_MATCHA_STOP then _G.BB_MATCHA_STOP() end
end)

-- No menu-open pause: parry stays active while the menu is visible. Firing
-- mouse1click is independent of the Drawing menu, so this only adds coverage.
menuOpen = false

local function updateGui()
	local now = os.clock()
	if now - lastUiUpdate < 0.15 then return end
	lastUiUpdate = now
	local mode = not CONFIG.enabled and "Disabled" or "Active"
	local threat = currentThreat and string.format("Ball: %.1f studs | Trigger: %.1f studs", currentThreat.distance, currentThreat.triggerDistance) or "Waiting for ball"
	local pingText = metrics.hasPing and string.format("%d ms", math.floor(lastPing * 1000 + 0.5)) or "unavailable"
	local fpsText = metrics.frames >= 10 and tostring(math.floor(1 / metrics.frame + 0.5)) or "measuring"
	statusText = string.format("%s | %s\nPing: %s | FPS estimate: %s | Attempts: %d", mode, threat, pingText, fpsText, parryCount)
	local rangeText = currentThreat and string.format("%.0f studs", currentThreat.range)
		or (CONFIG.autoTune and "Based on speed and trigger distance" or tostring(CONFIG.maxRange) .. " studs")
	local learnText = CONFIG.adaptiveLearning
		and string.format("+%.0f ms (miss %.0f%%)", learnedBias * 1000, math.clamp(parryMissEma, 0, 1) * 100)
		or "off"
	local calibText = CONFIG.calibrateRange
		and string.format(" (learned, max hit %.0fst)", calibDistMax) or ""
	tuningText = string.format("%s | Lead: %.0f ms | Retry: %.0f ms\nScan: %s | Standoff: %.0f st | Parry range: %.0f st%s\nPing jitter: %.0f ms | Frame budget: %.1f ms\nLearned bias: %s",
		CONFIG.autoTune and "Automatic" or "Manual", effective.lead * 1000, effective.retry * 1000,
		rangeText, CONFIG.standoff, CONFIG.maxParryRange, calibText,
		metrics.pingJitter * 1000, effective.frame * 1000, learnText)
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
local previewObjects = {overlay.hud, overlay.ball, overlay.future, overlay.path, overlay.label}
local previewHidden = false
local function drawPreview(root, threat)
	-- Only ever touch the 5 preview objects (not the whole Drawing pool), and skip
	-- entirely when there is nothing to show or the menu is open / game unfocused.
	local active = (CONFIG.compactHud or CONFIG.predictionPreview) and not menuOpen
		and not (type(isrbxactive) == "function" and not isrbxactive())
	if not active then
		if not previewHidden then
			for _, o in ipairs(previewObjects) do if o then o.Visible = false end end
			previewHidden = true
		end
		return
	end
	previewHidden = false
	for _, o in ipairs(previewObjects) do if o then o.Visible = false end end
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

-- Per-frame cache: trail, indicator, auto-spam, auto-ability and orbit all want
-- the nearest ball. Scan the Balls folder once per frame, not once per feature.
local nearestFrame, nearestBall, nearestDist = -1, nil, nil
local function cachedNearest(root)
	if frameId ~= nearestFrame then
		nearestFrame = frameId
		nearestBall, nearestDist = nearestBallInfo(root)
	end
	return nearestBall, nearestDist
end

-- Distance to the closest ALIVE opponent, cached per frame. Used to force fast
-- clash timing when you close in on someone so the rapid volley never slips past.
local oppFrame, oppDist = -1, nil
local function cachedOpponentDist(root)
	if frameId ~= oppFrame then
		oppFrame, oppDist = frameId, nil
		local alive = Workspace:FindFirstChild("Alive")
		if alive and root then
			local best = math.huge
			for _, model in ipairs(alive:GetChildren()) do
				if model.Name ~= player.Name then
					local ok, hrp = pcall(function() return model:FindFirstChild("HumanoidRootPart") end)
					if ok and hrp then
						local posOk, pos = pcall(function() return hrp.Position end)
						if posOk and pos then
							local d = (root.Position - pos).Magnitude
							if d < best then best = d end
						end
					end
				end
			end
			if best < math.huge then oppDist = best end
		end
	end
	return oppDist
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

-- =====================================================================
-- Live parry-range calibration. "How far can I actually parry?" is server
-- authoritative, so learn it: every fresh committed parry records the ball
-- distance at press time; a ServerParryCount increment confirms that distance
-- was in range (grow maxParryRange toward it), while a long-distance shot that
-- never confirms means we fired past the real range (shrink it). This runs
-- regardless of the adaptive-lead engine.
-- =====================================================================
local function updateRangeCalibration(now)
	if not CONFIG.calibrateRange then return end
	local count = currentParryCount()
	if count and calibCountSeen and count > calibCountSeen then
		for _ = 1, count - calibCountSeen do
			local f = table.remove(rangeFires, 1)
			if f then
				calibDistMax = math.max(calibDistMax, f.dist)
				-- Sit a few studs beyond the furthest confirmed parry so a genuine
				-- in-range ball is never rejected, but stay bounded.
				CONFIG.maxParryRange = math.clamp(math.max(CONFIG.maxParryRange, f.dist + 6), 40, 120)
			end
		end
	end
	if count ~= nil then calibCountSeen = count end
	for i = #rangeFires, 1, -1 do
		if now - rangeFires[i].t > 0.6 then
			local f = table.remove(rangeFires, i)
			-- Fired near the current cap yet nothing confirmed: the cap is too far.
			if f.dist > math.max(calibDistMax, CONFIG.maxParryRange - 8) then
				CONFIG.maxParryRange = math.clamp(CONFIG.maxParryRange - 2, 40, 120)
			end
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
			ball.velocity = sampleMotion(state, ball.position, ball.velocity, now, CONFIG.velocityBlend, CONFIG.instantAcquire)
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
	-- Proximity clash: when an alive opponent is within clashProximity, you are in
	-- a close exchange -- force the fast clash timing on your threat regardless of
	-- ball speed so a rapid volley cannot slip past between frames.
	local nearOpp = cachedOpponentDist(root)
	local proximityClash = (CONFIG.clashProximity or 0) > 0 and nearOpp ~= nil
		and nearOpp <= CONFIG.clashProximity
	local clash = threat and CONFIG.clashEnabled and (proximityClash
		or ((threat.priority or 0) >= 2 and threat.distance <= CONFIG.clashRange
			and threat.ball.speed >= CONFIG.clashMinSpeed))
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
			if passesAccuracy() and fireParry() then lastClick = now end
		end
		return
	end
	-- Cooldown protection: keep a minimum gap after the previous parry.
	if CONFIG.cooldownProtection and now - lastParryEnd < CONFIG.cooldownGap then return end

	if now - lastClick < interval then return end

	local key, state = threat.ball.key, threat.ball.state
	local previous = firedAt[key]
	if not canAttempt(now, previous, state, clash, effective.retry, CONFIG.maxClashRetries) then return end

	-- Precise sub-frame timing. The distance gate above means the ball crosses the
	-- parry line within this frame; instead of clicking now (up to a frame early),
	-- schedule the click at the exact predicted impact instant. Only for a fresh
	-- shot (retries/point-blank commit immediately below).
	local fireIn = threat.tti - effective.lead
	if CONFIG.instantPredict and not previous and finite(fireIn)
		and fireIn > 0.003 and fireIn <= effective.frame * 1.5
		and type(task) == "table" and type(task.delay) == "function" then
		-- Reserve the shot so following frames neither re-arm nor spam it.
		lastClick, firedAt[key] = now, now
		state.locked, state.departed, state.departureStart = true, false, nil
		state.lastDistance = threat.distance
		local token = (state.fireToken or 0) + 1
		state.fireToken = token
		task.delay(fireIn, function()
			-- Fire only if this exact prediction is still the live one.
			if not running or state.fireToken ~= token then return end
			if not CONFIG.enabled or menuOpen then return end
			if type(isrbxactive) == "function" and not isrbxactive() then return end
			if not passesAccuracy() then return end
			if fireParry() then
				if CONFIG.adaptiveLearning then pendingFires[#pendingFires + 1] = {t = tick()} end
				rangeFires[#rangeFires + 1] = {t = tick(), dist = threat.distance}
				lastParryEnd = tick()
				parryCount = parryCount + 1
				lastFireDistance = threat.distance
				if curveBall then curveBall(threat.ball, root) end
				if spawnBurst then spawnBurst(threat.ball.position) end
			end
		end)
		return
	end

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
		if not previous then rangeFires[#rangeFires + 1] = {t = now, dist = threat.distance} end
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
	frameId = frameId + 1
	if doSample ~= false then samplePerformance(now) end
	local root = getRoot()
	local rootId = root and (root.Address or root:GetFullName())
	if rootId ~= activeRoot then
		tracked, firedAt = {}, {}
		pendingFires, lastParryCountSeen = {}, nil
		rangeFires, calibCountSeen = {}, nil
		activeRoot, lastClick = rootId, -math.huge
	end
	local threat = root and chooseThreat(root, now) or nil
	currentThreat = threat
	if root then attemptThreat(root, threat, now, doSample) end

	-- Heartbeat only does detection/input. Draw once per render callback.
	if doSample ~= false then
		-- Learning/calibration poll attributes; they do not need every frame.
		if now - lastLearnAt >= 0.05 then
			lastLearnAt = now
			resolveLearning(now)
			updateRangeCalibration(now)
		end
		pcall(updateGui)
		updatePreview(root, threat)
		if now - lastCleanup >= 1 then
			lastCleanup = now
			for key, state in pairs(tracked) do
				if now - state.seen > 2 then tracked[key], firedAt[key] = nil, nil end
			end
		end
	end
end

-- Extra features (spam, triggerbot, abilities, ESP, trail, player mods,
-- detections, curve, orbit) were removed: this build is auto-parry only.
-- The forward-declared feature hooks stay nil, so update() skips them.

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
-- Third, pre-physics pass: PreSimulation fires before the engine integrates the
-- step, so together with the render + post-physics passes the gap between ball
-- observations shrinks -- a fast ball is far less likely to slip across the
-- trigger band unseen between frames (a common "too late" cause on frame hitches).
local preSimConnection = nil
if RunService.PreSimulation and RunService.PreSimulation ~= renderSignal
	and RunService.PreSimulation ~= RunService.Heartbeat then
	preSimConnection = RunService.PreSimulation:Connect(function() update(false) end)
end

_G.BB_MATCHA_STOP = function()
	running = false
	if renderConnection then renderConnection:Disconnect() end
	if heartbeatConnection then heartbeatConnection:Disconnect() end
	if preSimConnection then preSimConnection:Disconnect() end
	for _, conn in ipairs(remoteConns) do pcall(function() conn:Disconnect() end) end
	if baseGravity then pcall(function() Workspace.Gravity = baseGravity end) end
	pcall(function() Lib:Destroy() end)
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

-- One-call copyable report: status snapshot + calibration + the last close-ball
-- frames with fire/block reasons. Run `print(_G.BB_REPORT())`, copy the whole
-- block, and paste it back. `_G.BB_REPORT(60)` includes the last 60 log lines.
_G.BB_REPORT = function(lines)
	lines = tonumber(lines) or 30
	local out = {}
	out[#out + 1] = "===== BB PARRY REPORT ====="
	local s = _G.BB_MATCHA_STATUS and _G.BB_MATCHA_STATUS() or {}
	out[#out + 1] = string.format(
		"enabled=%s fps=%.0f ping=%s lead=%.0fms retry=%.0fms",
		tostring(s.enabled), s.fps or 0,
		s.pingMs and string.format("%.0fms", s.pingMs) or "n/a",
		s.leadMs or 0, s.retryMs or 0)
	out[#out + 1] = string.format(
		"attempts=%d serverParryCount=%s missRate=%.2f learnedBias=%.0fms",
		s.attempts or 0, tostring(s.serverParryCount), s.missRate or 0, s.learnedBiasMs or 0)
	out[#out + 1] = string.format(
		"maxParryRange=%.0fst maxHitDist=%.0fst standoff=%.0fst clashProx=%.0fst clashInt=%.0fms",
		CONFIG.maxParryRange, calibDistMax, CONFIG.standoff, CONFIG.clashProximity or 0,
		CONFIG.clashInterval * 1000)
	out[#out + 1] = string.format(
		"anyIncoming=%s fallback=%s accelPred=%s adaptive=%s calibRange=%s",
		tostring(CONFIG.anyIncoming), tostring(CONFIG.fallback),
		tostring(CONFIG.accelerationPrediction), tostring(CONFIG.adaptiveLearning),
		tostring(CONFIG.calibrateRange))
	out[#out + 1] = string.format("--- last %d close-ball frames (oldest first) ---", lines)
	local start = math.max(1, #debugLog - lines + 1)
	for i = start, #debugLog do out[#out + 1] = debugLog[i] end
	if #debugLog == 0 then out[#out + 1] = "(no close-ball frames logged yet -- play a round)" end
	out[#out + 1] = "===== END ====="
	return table.concat(out, "\n")
end

-- INS-ui exposes no OnUnload hook; guard in case a future build adds one.
if type(Lib.OnUnload) == "function" then
	pcall(function()
		Lib:OnUnload(function()
			if running and _G.BB_MATCHA_STOP then _G.BB_MATCHA_STOP() end
		end)
	end)
end

print("INS-ui auto-parry loaded (P menu, T toggle parry)")
