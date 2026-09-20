-- Execute with loadstring(thisFile)(parrySource) in a Luau runtime with Vector3.
-- No input is sent and no running UI is changed by these checks.
local source = ...
local first = assert(source:find("-- BEGIN PARRY MATH", 1, true))
local last = assert(source:find("-- END PARRY MATH", first, true))
local mathSource = source:sub(first, last - 1)
local core = assert(loadstring(mathSource .. [[
return {profile = timingProfile, range = detectionRange, impact = impactTime,
    attempt = canAttempt, finite = finite}
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
local slow = core.profile(config, stats(30, 0.019))
local delayed = core.profile(config, stats(160, 0.180))
local jittery = core.profile(config, stats(160, 0.019, 0.025))
check(slow.lead > fast.lead, "low FPS adds lead")
check(delayed.lead > fast.lead, "high ping adds lead")
check(jittery.lead > fast.lead, "jitter adds bounded lead")
check(core.profile(config, stats(5, 0.6, 1)).lead <= 0.260, "lead cap")
check(core.profile(config, stats(5, 0.6, 1)).retry <= 0.140, "retry cap")
check(core.range(config, fast, 1000) > core.range(config, fast, 30), "fast ball range grows")
check(core.range(config, fast, 6000) <= 500, "range cap")
config.pingComp = false
check(close(core.profile(config, stats(160, 0.6)).lead,
    core.profile(config, stats(160, 0)).lead), "ping toggle honored")
config.pingComp = true
config.autoTune = false
local manual = core.profile(config, stats(30, 0.1))
check(close(manual.lead, 0.195), "manual timing preserved")
check(core.range(config, manual, 5000) == 140, "manual range preserved")
config.autoTune = true

local v = Vector3.new
check(close(core.impact(v(100, 0, 0), v(100, 0, 0), 5), 0.95), "straight impact")
check(close(core.impact(v(10, 4, 0), v(10, 0, 0), 5), 0.7), "glancing impact exact root")
check(core.impact(v(10, 6, 0), v(10, 0, 0), 5) == nil, "near miss rejected")
check(core.impact(v(10, 0, 0), v(-100, 0, 0), 5) == nil, "outgoing rejected")
check(core.impact(v(10, 0, 0), v(0, 0, 0), 5) == nil, "stationary rejected")
check(core.impact(v(2, 0, 0), v(100, 0, 0), 5) == 0, "incoming inside radius")
check(core.impact(v(2, 0, 0), v(-100, 0, 0), 5) == nil, "outgoing inside radius")
check(close(core.impact(v(100, 0, 0), v(100, 0, 0) - v(20, 0, 0), 5), 95 / 80), "moving away extends time")
check(close(core.impact(v(100, 0, 0), v(100, 0, 0) - v(-20, 0, 0), 5), 95 / 120), "moving toward shortens time")
check(core.impact(v(100, 0, 0), v(100, 0, 0) - v(0, 30, 0), 5) == nil, "lateral player movement considered")
check(core.impact(v(100, 0, 0), v(100, 0, 0), 8) < core.impact(v(100, 0, 0), v(100, 0, 0), 5), "ball size considered")

local state = {retries = 0, revision = 2, sentRevision = 1}
check(core.attempt(1, nil, state, false, 0.04, 2), "first approach allowed")
check(not core.attempt(1, 0.5, state, false, 0.04, 2), "no distant duplicate")
check(not core.attempt(1, 0.99, state, true, 0.04, 2), "retry cooldown")
check(core.attempt(1, 0.9, state, true, 0.04, 2), "fresh close retry")
state.revision = 1
check(not core.attempt(1, 0.9, state, true, 0.04, 2), "stale snapshot retry blocked")
state.revision, state.retries = 3, 2
check(not core.attempt(1, 0.9, state, true, 0.04, 2), "retry limit")
check(not core.finite(0 / 0) and not core.finite(math.huge), "invalid numbers rejected")

-- Exercise the actual performance sampler with controlled timestamps/pings.
local sampleStart = assert(source:find("local function samplePerformance", 1, true))
local sampleEnd = assert(source:find("-- Load the user-selected", sampleStart, true))
local performance = assert(loadstring([[
local CONFIG, timingProfile = ...
local metrics = {frame = 1/60, frameJitter = 0, frames = 0, ping = 0,
    pingJitter = 0, hasPing = false, nextPing = 0, pingAt = -math.huge}
local lastFrameAt, lastPing, effective
local mockPing = 20
local function GetPingValue() return mockPing end
]] .. mathSource .. source:sub(sampleStart, sampleEnd - 1) .. [[
return {sample = samplePerformance, metrics = metrics,
    setPing = function(p) mockPing = p end}
]]))(config, core.profile)
performance.sample(0)
for i = 1, 600 do performance.sample(i / 120) end
check(math.abs(1 / performance.metrics.frame - 120) < 2, "FPS converges to 120")
local frameBefore = performance.metrics.frame
performance.sample(10) -- long pause is excluded, not reported as 0 FPS
check(close(performance.metrics.frame, frameBefore), "long frame pause ignored")
performance.setPing(0 / 0)
performance.sample(13)
check(not performance.metrics.hasPing, "stale invalid ping expires")
performance.setPing(60)
performance.sample(14)
check(performance.metrics.hasPing and close(performance.metrics.ping, 0.060), "ping recovers")
print("PASS: " .. count .. " parry prediction, timing and retry regression checks")
