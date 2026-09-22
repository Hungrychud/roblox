-- Standard Luau runner: loadstring(thisFile)(parrySource).
-- Matcha's loadstring does not pass arguments/return values; its live tool runs
-- the extracted math functions and checks in one chunk instead.
local source = ...
local first = assert(source:find("-- BEGIN PARRY MATH", 1, true))
local last = assert(source:find("-- END PARRY MATH", first, true))
local mathSource = source:sub(first, last - 1)
local core = assert(loadstring(mathSource .. [[
return {advance = advanceApproach, eligible = eligibleBall, intercept = interceptionDistance, profile = timingProfile, range = detectionRange, impact = impactTime,
    attempt = canAttempt, finite = finite, motion = sampleMotion, better = betterThreat}
]]))()
local count = 0
local function check(value, label)
    assert(value, label)
    count = count + 1
end
local function close(a, b) return a ~= nil and math.abs(a - b) < 0.00001 end
local config = {autoTune = true, pingComp = true, contactRadius = 4.5,
    baseLead = 0.12, maxLead = 0.42, pingFactor = 0.75, minInterval = 0.055,
    clashRetry = 0.045, maxRange = 140, clashRange = 22}
local function stats(fps, ping, jitter)
    return {frame = 1 / fps, frameJitter = 0, ping = ping,
        pingJitter = jitter or 0, hasPing = true}
end
local fast = core.profile(config, stats(160, 0.019))
check(fast.lead >= 0.12 + 0.019 * 0.75, "automatic mode never shortens working baseline")
check(core.profile(config, stats(30, 0.019)).lead > fast.lead, "low FPS adds margin")
check(core.profile(config, stats(160, 0.18)).lead > fast.lead, "ping adds margin")
check(core.profile(config, stats(160, 0.019, 0.025)).lead > fast.lead, "jitter adds margin")
check(core.profile(config, stats(5, 0.6, 1)).lead <= config.maxLead, "lead cap")
check(core.profile(config, stats(5, 0.6, 1)).retry <= 0.065, "close retry remains fast")
check(core.range(config, fast, 30) >= 140, "detection range baseline preserved")
check(core.range(config, fast, 6000) <= 500, "range capped")
config.pingComp = false
check(close(core.profile(config, stats(160, 0.6)).lead, core.profile(config, stats(160, 0)).lead), "ping toggle")
config.pingComp = true
config.autoTune = false
local manual = core.profile(config, stats(30, 0.1))
check(close(manual.lead, 0.195), "manual timing preserved")
check(core.range(config, manual, 5000) == 140, "manual range preserved")

local v = Vector3.new
check(close(core.impact(v(100, 0, 0), v(100, 0, 0), 4.5, 18), 0.955), "straight approach")
-- Regression: homing ball targets us, but its current straight line misses the
-- small physical sphere. This must still reach the timing gate.
check(core.impact(v(10, 8, 0), v(100, 0, 0), 4.5, 18) < fast.lead, "targeted curve triggers")
check(core.impact(v(10, 8, 0), v(100, 0, 0), 4.5, 4.5) == nil, "unknown target remains strict")
check(core.impact(v(10, 19, 0), v(100, 0, 0), 4.5, 18) == nil, "wide targeted miss rejected")
check(core.impact(v(10, 0, 0), v(-100, 0, 0), 4.5, 18) == nil, "outgoing ignored")
check(core.impact(v(10, 0, 0), v(0, 0, 0), 4.5, 18) == nil, "stationary ignored")
check(core.impact(v(2, 0, 0), v(100, 0, 0), 4.5, 18) == 0, "close incoming triggers")

local state = {retries = 0}
check(core.attempt(1, nil, state, false, 0.045, 2), "first attempt")
check(not core.attempt(1, 0.5, state, false, 0.045, 2), "distant duplicate blocked")
check(not core.attempt(1, 0.99, state, true, 0.045, 2), "retry cooldown")
check(core.attempt(1, 0.9, state, true, 0.045, 2), "close retry does not require missed replication event")
state.retries = 2
check(not core.attempt(1, 0.9, state, true, 0.045, 2), "retry cap")
check(not core.finite(0 / 0) and not core.finite(math.huge), "invalid numbers")
config.earlyParry, config.extraDistance, config.accelerationPrediction = true, 4, true
local profile = {lead = 0.15}
local base = core.intercept(config, profile, 100, 0)
check(close(base, 23.5), "100 stud/s ball triggers at 23.5 studs")
check(core.intercept(config, profile, 200, 0) > base, "faster approach triggers farther out")
check(core.intercept(config, {lead = 0.20}, 100, 0) > base, "higher lead triggers farther out")
check(core.intercept(config, profile, 100, 10000) <= base + 3, "acceleration allowance capped")
check(core.intercept(config, profile, 100, -100) == base, "deceleration does not delay trigger")
config.accelerationPrediction = false
check(core.intercept(config, profile, 100, 10000) == base, "acceleration toggle honored")
config.earlyParry = false
check(close(core.intercept(config, profile, 100, 0), 19.5), "extra distance toggle restores baseline")
config.earlyParry, config.extraDistance = true, 0
check(close(core.intercept(config, profile, 100, 0), 19.5), "zero buffer restores baseline")
config.anyIncoming = true
check(core.eligible(config, true, false, false), "other target considered in any-ball mode")
check(core.eligible(config, nil, false, true), "untagged launcher ball considered")
check(not core.eligible(config, false, true, false), "visual duplicate excluded")
config.anyIncoming, config.fallback = false, false
check(not core.eligible(config, true, false, false), "target restriction can be restored")
check(core.eligible(config, true, true, false), "own targeted ball retained")
config.fallback = true
check(core.eligible(config, true, false, true), "unknown-target fallback retained")
-- Post-parry target updates and velocity flicker must not clear the shot lock.
local shot = {locked = true, lastDistance = 12, retries = 0, target = "self"}
shot.target = "other"
check(not core.advance(shot, 100, 11), "target change with old incoming velocity stays locked")
check(not core.attempt(1, 0.5, shot, false, 0.045, 2), "retries OFF blocks duplicate after target change")
check(not core.advance(shot, -100, 11.1), "single outgoing velocity sample insufficient")
check(not core.advance(shot, 100, 11), "velocity flicker does not rearm")
check(not core.advance(shot, 0, 11), "zero velocity does not rearm")
check(not core.advance(shot, -100, 11.2), "small outward movement keeps lock")
check(not core.advance(shot, -100, 11.7) and shot.departed, "confirmed departure still keeps lock")
check(not core.attempt(1, 0.5, shot, true, 0.045, 2), "confirmed outgoing ball cannot retry even with retries ON")
check(core.advance(shot, 100, 11.4), "fresh inward approach after departure rearms")
check(not shot.locked and shot.retries == 0, "new approach resets retry budget")
check(not core.advance(shot, 100, 10), "same new approach cannot rearm twice")
-- Duplicate callback samples must preserve the displacement observation clock.
local motion = {}
core.motion(motion, v(0, 0, 0), v(100, 0, 0), 0, true)
core.motion(motion, v(0, 0, 0), v(100, 0, 0), 0.009, true)
check(motion.motionAt == 0, "duplicate sample keeps original timestamp")
local recovered = core.motion(motion, v(10, 0, 0), v(100, 0, 0), 0.01, true)
check(close(recovered.Magnitude, 150), "single jump is bounded")
core.motion(motion, v(10, 0, 0), v(100, 0, 0), 0.019, true)
recovered = core.motion(motion, v(20, 0, 0), v(100, 0, 0), 0.02, true)
check(close(recovered.Magnitude, 1000), "coherent motion recovers understated speed")
check(close(core.motion(motion, v(20, 0, 0), v(-100, 0, 0), 0.021, true).X, -100),
    "old measured velocity cannot override a rebound")
check(close(core.motion(motion, v(20, 0, 0), v(100, 0, 0), 0.03, false).X, 100),
    "velocity blend toggle")
check(close(core.motion(motion, v(20, 0, 0), v(100, 0, 0), 0.08, true).X, 100),
    "stale measured velocity expires")
core.motion(motion, v(200, 0, 0), v(100, 0, 0), 1, true)
check(motion.motionConfidence == 0, "long observation gap resets confidence")

local stopped = {}
core.motion(stopped, v(0, 0, 0), v(0, 0, 0), 0, true)
check(core.motion(stopped, v(10, 0, 0), v(0, 0, 0), 0.01, true).Magnitude == 0,
    "one position jump with zero engine speed is not trusted")
check(close(core.motion(stopped, v(20, 0, 0), v(0, 0, 0), 0.02, true).X, 1000),
    "two coherent movements recover zero engine velocity")

local delayed = stats(144, 0)
delayed.lastFrame = 0.06
config.autoTune, config.extraDistance = true, 4
local stalled = core.profile(config, delayed)
check(stalled.lookAhead >= 0.06, "recent frame stall increases next-check budget immediately")
check(core.intercept(config, stalled, 5000, 0) >= 4.5 + 4 + 5000 * (stalled.lead + 0.06),
    "fast-ball trigger covers full next-check travel")
check(core.impact(v(100, 0, 0), v(100, 0, 0) - v(50, 0, 0), 4.5, 18) > 0.955,
    "player moving away increases relative impact time")
check(core.impact(v(100, 0, 0), v(100, 0, 0) - v(-50, 0, 0), 4.5, 18) < 0.955,
    "player moving toward ball decreases relative impact time")
local urgent = {distance = 20, triggerDistance = 25, priority = 0, tti = 0.1}
local distant = {distance = 100, triggerDistance = 25, priority = 3, tti = 1}
check(core.better(urgent, distant), "immediate collision beats out-of-window tagged ball")
distant.distance = 22
check(not core.better(urgent, distant), "target priority preserved when both are in-window")

-- Sampled straight-flight sweeps: detect on the current observation if the
-- next one would enter the original lead window, even at very high speeds.
for _, fps in ipairs({12, 30, 60, 144, 240}) do
    for _, speed in ipairs({30, 500, 3000, 10000, 25000}) do
        local timing = core.profile(config, stats(fps, 0.05))
        local fired = false
        for frame = 0, fps * 2 do
            local distance = 4.5 + speed * (1 - frame / fps)
            local tti = core.impact(v(distance, 0, 0), v(speed, 0, 0), 4.5, 18)
            if tti and distance <= core.intercept(config, timing, speed, 0) then
                check(tti > 0, "sampled flight fires before contact")
                check(tti + 1 / fps >= timing.lead, "sampled flight preserves reaction lead")
                fired = true
                break
            end
        end
        check(fired, "sampled high-speed flight detected")
    end
end
print("PASS: " .. count .. " parry regression checks")
