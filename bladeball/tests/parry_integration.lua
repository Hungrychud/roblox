-- Run with loadstring(thisFile)(parrySource) in a standard Luau host.
-- All game objects, input and UI are local mocks; no clicks reach the game.
local source = ...
local function section(first, last)
    local a = assert(source:find(first, 1, true))
    local b = assert(source:find(last, a, true))
    return source:sub(a, b - 1)
end
local prelude = [====[
local v = Vector3.new
local clock, clicks, draws, uiCalls = 0, 0, 0, 0
local order, balls = {}, {}
local root = {Address = 123, Position = v(0, 0, 0), AssemblyLinearVelocity = v(0, 0, 0)}
local player = {Name = "self"}
local running, menuOpen, focused = true, false, true
local tracked, firedAt, pendingFires, debugLog = {}, {}, {}, {}
local lastClick, lastParryEnd = -math.huge, -math.huge
local activeRoot, currentThreat, lastParryCountSeen, lastFireDistance
local parryCount, lastCleanup = 0, 0
local effective = timingProfile(CONFIG, {frame = 1/60, frameJitter = 0, hasPing = false})
local Workspace = {}
function Workspace:FindFirstChild()
    return {GetChildren = function() return balls end}
end
local function tick() return clock end
local function isrbxactive() return focused end
local function getRoot() return root end
local function safeAttribute(object, name) return object.attributes[name] end
local function samplePerformance() end
local function resolveLearning() end
local function passesAccuracy() return true end
local function fireParry()
    clicks = clicks + 1
    order[#order + 1] = "click"
    return true
end
local function updateGui()
    uiCalls = uiCalls + 1
    order[#order + 1] = "ui"
    error("simulated optional UI failure")
end
local function updatePreview() draws = draws + 1 end
]====]
local checks = [====[
local count = 0
local function check(value, label)
    assert(value, label)
    count = count + 1
end
local function ball(id, x, speed, target)
    return {Address = id, ClassName = "Part", Position = v(x, 0, 0),
        AssemblyLinearVelocity = v(speed, 0, 0),
        attributes = {realBall = true, target = target or "self"}}
end
local function reset()
    balls, tracked, firedAt, pendingFires, debugLog, order = {}, {}, {}, {}, {}, {}
    clock, clicks, draws, uiCalls, parryCount = 0, 0, 0, 0, 0
    lastClick, lastParryEnd, activeRoot = -math.huge, -math.huge, nil
    menuOpen, focused, CONFIG.enabled, CONFIG.anyIncoming, CONFIG.fallback = false, true, true, true, true
    CONFIG.clashEnabled = true
    root = {Address = 123, Position = v(0, 0, 0), AssemblyLinearVelocity = v(0, 0, 0)}
end
reset()
balls = {ball(1, -100, 1000)}
update(true)
check(clicks == 1, "render path detects and fires")
check(order[1] == "click" and order[2] == "ui", "input precedes optional UI")
check(draws == 1, "UI failure cannot stop preview or input")
clock = 0.001
update(false)
check(clicks == 1 and draws == 1 and uiCalls == 1, "physics pass avoids duplicate shot and all drawing")
clock = 0.06
update(false)
check(clicks == 1, "same approach stays locked beyond ordinary interval")

-- Genuine rebound within the old 50 ms throttle.
reset()
CONFIG.clashEnabled = false
balls = {ball(1, -100, 1000)}
update(false)
clock = 0.01
balls[1].Position, balls[1].AssemblyLinearVelocity = v(-110, 0, 0), v(-1000, 0, 0)
update(false)
check(clicks == 1, "outgoing phase never fires")
clock = 0.02
balls[1].Position, balls[1].AssemblyLinearVelocity = v(-100, 0, 0), v(1000, 0, 0)
update(false)
check(clicks == 2, "new confirmed rebound fires within 50ms even with retries disabled")

reset()
balls = {ball(1, -100, 1000)}
menuOpen = true
update(false)
check(clicks == 0, "menu pause preserved")
menuOpen, focused = false, false
update(false)
check(clicks == 0, "focus guard preserved")
focused, CONFIG.enabled = true, false
update(false)
check(clicks == 0, "disabled toggle preserved")

reset()
balls = {ball(1, -100, 1000)}
balls[1].attributes.realBall = false
update(false)
check(clicks == 0, "visual duplicates excluded by actual reader")
reset()
balls = {ball(1, -100, -1000)}
update(false)
check(clicks == 0, "outgoing ball excluded by actual selector")
reset()
balls = {ball(1, -100, 0)}
update(false)
check(clicks == 0, "stationary ball cannot trigger")
reset()
CONFIG.anyIncoming, CONFIG.fallback = false, false
balls = {ball(1, -100, 1000)}
balls[1].attributes.target = nil
update(false)
check(clicks == 0, "fallback-off is respected in actual selector")

reset()
balls = {ball(1, -1000, 1000), ball(2, -100, 1000, "other")}
update(false)
check(clicks == 1 and currentThreat.ball.key == 2, "immediate incoming threat is not hidden by distant tagged ball")
reset()
balls = {ball(1, -100, 1000), ball(2, -50, 1000, "other")}
update(false)
check(currentThreat.ball.key == 1, "tagged priority retained when both are ready")

-- Recover a moving ball with zero engine velocity through the real reader.
reset()
balls = {ball(1, -120, 0)}
update(false)
clock, balls[1].Position = 0.01, v(-110, 0, 0)
update(false)
check(clicks == 0, "one teleport-like sample cannot fire")
clock, balls[1].Position = 0.02, v(-100, 0, 0)
update(false)
check(clicks == 1, "coherent position samples recover zero engine velocity in actual loop")

reset()
balls = {ball(1, -100, 1000)}
root = nil
update(false)
check(clicks == 0, "missing character is safe")
print("PASS: " .. count .. " parry integration checks")
]====]
local code = section("-- BEGIN PARRY MATH", "-- END PARRY MATH")
    .. section("local CONFIG = {", "if type(restoreClash)")
    .. prelude
    .. section("local function getBallPart", "local function fireParry")
    .. section("-- Helpers are assigned before", "-- =====================================================================\n-- Extra feature overlays")
    .. checks
assert(loadstring(code))()
