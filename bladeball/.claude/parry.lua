-------------------------------------------------------------------------
-- Blade Ball Auto Parry  --  rebuilt for accuracy
-- target selection now uses the ball's own realBall + target attributes
-- (deterministic) instead of guessing by geometry. INS-ui menu.
-------------------------------------------------------------------------

local Players     = game:GetService("Players")
local RunService  = game:GetService("RunService")
local UIS         = game:GetService("UserInputService")
local ws          = workspace
local lp          = Players.LocalPlayer

if _G.BBAP_stop then _G.BBAP_stop() end
_G.BBAP_installed = true

-------------------------------------------------------------------------
-- executor shims (work in matcha AND normal executors)
-------------------------------------------------------------------------
local function svc(n)
  local ok, s = pcall(function() return game:GetService(n) end)
  return ok and s or nil
end

local cam = ws.CurrentCamera

-- World -> screen. matcha exposes WorldToScreen(v3) -> Vector2, bool.
-- normal executors don't, so fall back to Camera:WorldToViewportPoint.
local _hasW2S = (type(WorldToScreen) == "function")
local function W2S(v)
  if _hasW2S then return WorldToScreen(v) end
  local p = cam:WorldToViewportPoint(v)
  return Vector2.new(p.X, p.Y), (p.Z > 0)
end

-- ping in ms. matcha: GetPingValue(). normal: Stats network item.
local Stats = svc("Stats")
local function getPing()
  if type(GetPingValue) == "function" then
    local ok, v = pcall(GetPingValue)
    if ok and type(v) == "number" then return v end
  end
  if Stats then
    local ok, v = pcall(function()
      return Stats.Network.ServerStatsItem["Data Ping"]:GetValue()
    end)
    if ok and type(v) == "number" then return v end
  end
  return 0
end

-- fire a parry click. matcha/most executors expose mouse1click/mouse2click.
local VIM = svc("VirtualInputManager")
local function click(rmb)
  local fn = rmb and mouse2click or mouse1click
  if type(fn) == "function" then
    local ok = pcall(fn)
    if ok then return true end
  end
  if rmb and type(mouse1click) == "function" then
    if pcall(mouse1click) then return true end
  end
  if VIM then
    local x, y = cam.ViewportSize.X / 2, cam.ViewportSize.Y / 2
    local btn = rmb and 1 or 0
    local ok = pcall(function()
      VIM:SendMouseButtonEvent(x, y, btn, true, game, 0)
      VIM:SendMouseButtonEvent(x, y, btn, false, game, 0)
    end)
    if ok then return true end
  end
  return false
end

-- stable per-instance key. matcha has .Address; elsewhere the instance
-- itself hashes fine, so use it directly.
local function idOf(inst)
  local ok, a = pcall(function() return inst.Address end)
  if ok and a ~= nil then return a end
  return inst
end

-------------------------------------------------------------------------
-- config
-------------------------------------------------------------------------
local CONFIG = {
  enabled     = true,
  rmb         = false,   -- use right click to parry instead of left
  -- timing: press when time-to-impact <= reaction + ping*pingFactor
  reaction    = 0.090,   -- seconds of lead before contact (90 ms)
  pingComp    = true,
  pingFactor  = 1.0,     -- how much measured ping to add to the lead
  minInterval = 0.060,   -- global min seconds between any two presses
  retry       = 0.150,   -- if same ball still incoming after this, press again
  contact     = 3.5,     -- studs: treat as "hit" when ball this close
  -- targeting
  fallback    = true,    -- also parry the nearest incoming real ball whose
                         -- target lags (rebound / curve / swaps)
  fallbackRange = 60,    -- studs, only for the fallback path
  onlyAlive   = true,
  -- visuals
  esp     = true,
  ring    = true,
  path    = true,
  retical = true,
  watermark = true,
}

-- stats
local attempts, hits = 0, 0
local lastParryCount = nil
local hitFlash = 0
local lastFire = 0
local firedBall = {}          -- id -> os.clock() of last press
local targets = {}            -- esp collector output
local curSel  = nil           -- current chosen ball snapshot (for HUD/visuals)
local pingMs  = 0

-------------------------------------------------------------------------
-- drawing pool
-------------------------------------------------------------------------
local D = {}
local function mkText(size, center)
  local t = Drawing.new("Text")
  t.Size = size or 13; t.Font = 4; t.Outline = true
  t.Center = center or false; t.Visible = false
  D[#D + 1] = t; return t
end
local function mkLine()
  local l = Drawing.new("Line"); l.Thickness = 1; l.Visible = false
  D[#D + 1] = l; return l
end
local function mkSquare()
  local s = Drawing.new("Square"); s.Visible = false
  D[#D + 1] = s; return s
end

local wm = mkText(13)
wm.Position = Vector2.new(14, 10)

local ret = mkSquare()
ret.Filled = false; ret.Thickness = 2; ret.Color = Color3.fromRGB(80, 220, 255); ret.ZIndex = 2
local retText = mkText(12, true); retText.ZIndex = 2

local flash = mkText(15)
flash.Position = Vector2.new(14, 28)

local ringPool = {}
for i = 1, 40 do ringPool[i] = mkLine() end
local pathPool = {}
for i = 1, 28 do pathPool[i] = mkLine() end
local espPool = {}
for i = 1, 32 do espPool[i] = mkText(12, true) end

local function drawRing(cx, cy, cz, r, color, transp)
  local n = #ringPool
  for i = 0, n - 1 do
    local a0 = (i / n) * 6.2831853
    local a1 = ((i + 1) / n) * 6.2831853
    local s0, v0 = W2S(Vector3.new(cx + math.cos(a0) * r, cy, cz + math.sin(a0) * r))
    local s1, v1 = W2S(Vector3.new(cx + math.cos(a1) * r, cy, cz + math.sin(a1) * r))
    local ln = ringPool[i + 1]
    if v0 and v1 then
      ln.From = s0; ln.To = s1; ln.Color = color; ln.Transparency = transp or 0; ln.Visible = true
    else
      ln.Visible = false
    end
  end
end
local function hideRing() for i = 1, #ringPool do ringPool[i].Visible = false end end
local function hidePath() for i = 1, #pathPool do pathPool[i].Visible = false end end

-------------------------------------------------------------------------
-- esp collector  (slow loop, does the expensive lookups)
-------------------------------------------------------------------------
task.spawn(function()
  while _G.BBAP_installed do
    local out = {}
    for _, p in ipairs(Players:GetPlayers()) do
      if p ~= lp then
        local char = p.Character
        local head = char and char:FindFirstChild("Head")
        local root = char and char:FindFirstChild("HumanoidRootPart")
        if head and root then
          out[#out + 1] = {
            name = p.Name, head = head, root = root,
            ability  = p:GetAttribute("CurrentlyEquippedAbility") or "",
            parrying = char:GetAttribute("Parrying") or false,
          }
        end
      end
    end
    targets = out

    -- parry-hit counter for accuracy readout
    local char = lp.Character
    local cnt = char and char:GetAttribute("ServerParryCount")
    if cnt then
      if lastParryCount and cnt > lastParryCount then
        hits = hits + (cnt - lastParryCount)
        hitFlash = os.clock()
      end
      lastParryCount = cnt
    end

    -- prune old fired entries
    local now = os.clock()
    for k, t in pairs(firedBall) do
      if now - t > 1.0 then firedBall[k] = nil end
    end
    task.wait(0.2)
  end
end)

-------------------------------------------------------------------------
-- ball selection  --  the accuracy core
-------------------------------------------------------------------------
local aliveFolder = ws:FindFirstChild("Alive")

local function selfState()
  local char = lp.Character
  if not char then return nil end
  local root = char:FindFirstChild("HumanoidRootPart")
  if not root then return nil end
  if CONFIG.onlyAlive then
    if aliveFolder and char.Parent ~= aliveFolder then return nil end
    if char:GetAttribute("Stunned") or char:GetAttribute("PULSED") then return nil end
  end
  return char, root
end

-- returns snapshot { ball, dist, speed, close, tti, aimed } or nil
local function pickBall(rootPos)
  local bf = ws:FindFirstChild("Balls")
  if not bf then return nil end
  local best, bestTTI = nil, math.huge          -- aimed at me (priority)
  local fb, fbTTI     = nil, math.huge           -- fallback: nearest incoming
  for _, b in ipairs(bf:GetChildren()) do
    local ok, vel = pcall(function() return b.AssemblyLinearVelocity end)
    if ok and vel then
      local speed = vel.Magnitude
      if speed > 5 then
        local toMe   = rootPos - b.Position
        local dist   = toMe.Magnitude
        local close  = (dist > 0.01) and vel:Dot(toMe / dist) or 0   -- closing speed
        if close > 0 then                                            -- moving toward me
          local tti  = (dist - CONFIG.contact) / close
          if tti < 0 then tti = 0 end
          local real = b:GetAttribute("realBall")
          local aimed = (b:GetAttribute("target") == lp.Name)
          if real == true and aimed then
            if tti < bestTTI then
              bestTTI = tti
              best = { ball = b, dist = dist, speed = speed, close = close, tti = tti, pos = b.Position, vel = vel, aimed = true }
            end
          elseif CONFIG.fallback and real ~= false and dist <= CONFIG.fallbackRange then
            if tti < fbTTI then
              fbTTI = tti
              fb = { ball = b, dist = dist, speed = speed, close = close, tti = tti, pos = b.Position, vel = vel, aimed = false }
            end
          end
        end
      end
    end
  end
  return best or fb
end

-------------------------------------------------------------------------
-- main loop
-------------------------------------------------------------------------
local hRender
hRender = RunService.RenderStepped:Connect(function()
  local now = os.clock()
  pingMs = pingMs == 0 and getPing() or (pingMs * 0.8 + getPing() * 0.2)

  local char, root = selfState()
  curSel = nil

  if root then
    local sel = pickBall(root.Position)
    curSel = sel
    if CONFIG.enabled and sel then
      local lead = CONFIG.reaction + (CONFIG.pingComp and (math.min(pingMs, 300) * CONFIG.pingFactor / 1000) or 0)
      if sel.tti <= lead and (now - lastFire) >= CONFIG.minInterval then
        local id = idOf(sel.ball)
        local last = firedBall[id]
        if (not last) or (now - last) >= CONFIG.retry then
          if click(CONFIG.rmb) then
            lastFire = now
            firedBall[id] = now
            attempts = attempts + 1
          end
        end
      end
    end
  end

  -------------------------------------------------------------- visuals
  -- watermark
  wm.Visible = CONFIG.watermark
  if CONFIG.watermark then
    local acc = attempts > 0 and math.floor(100 * hits / attempts) or 0
    wm.Text = string.format("AUTO PARRY  %s  ping %dms  swings %d  hits %d  acc %d%%",
      CONFIG.enabled and "ON" or "OFF", math.floor(pingMs), attempts, hits, acc)
    wm.Color = CONFIG.enabled and Color3.fromRGB(120, 240, 140) or Color3.fromRGB(255, 120, 120)
  end

  -- range ring + predicted path + retical
  if root and CONFIG.ring then
    local cy = root.Position.Y - 3
    drawRing(root.Position.X, cy, root.Position.Z, CONFIG.fallbackRange, Color3.fromRGB(90, 200, 255), 0.5)
  else
    hideRing()
  end

  hidePath()
  if curSel and CONFIG.path then
    local p, v = curSel.pos, curSel.vel
    local prevS, prevV = W2S(p)
    local n = 0
    local steps = math.min(28, math.max(4, math.floor(curSel.tti / 0.03)))
    for _ = 1, steps do
      p = p + v * 0.03
      local s, vis = W2S(p)
      if vis and prevV then
        n = n + 1
        local ln = pathPool[n]
        ln.From = prevS; ln.To = s; ln.Color = Color3.fromRGB(80, 220, 255); ln.Transparency = 0.2; ln.Visible = true
      end
      prevS, prevV = s, vis
    end
  end

  if curSel and CONFIG.retical then
    local sp, vis = W2S(curSel.pos)
    if vis then
      local col = curSel.aimed and Color3.fromRGB(255, 80, 80) or Color3.fromRGB(255, 200, 80)
      ret.Position = Vector2.new(sp.X - 15, sp.Y - 15); ret.Size = Vector2.new(30, 30)
      ret.Color = col; ret.Visible = true
      retText.Position = Vector2.new(sp.X, sp.Y - 24)
      retText.Text = string.format("%.2fs  %dspd", curSel.tti, math.floor(curSel.speed))
      retText.Color = col; retText.Visible = true
    else
      ret.Visible = false; retText.Visible = false
    end
  else
    ret.Visible = false; retText.Visible = false
  end

  -- esp
  local nEsp = 0
  if CONFIG.esp then
    for i = 1, #targets do
      if nEsp >= 32 then break end
      local tg = targets[i]
      local sp, vis = W2S(tg.head.Position + Vector3.new(0, 3.2, 0))
      if vis then
        nEsp = nEsp + 1
        local e = espPool[nEsp]
        e.Position = Vector2.new(sp.X, sp.Y)
        e.Text = tg.ability ~= "" and tg.ability or tg.name
        e.Color = tg.parrying and Color3.fromRGB(255, 90, 90) or Color3.fromRGB(150, 220, 255)
        e.Visible = true
      end
    end
  end
  for i = nEsp + 1, 32 do espPool[i].Visible = false end

  -- hit flash
  local flashing = (now - hitFlash) < 0.3
  flash.Visible = flashing
  if flashing then flash.Text = "PARRY!"; flash.Color = Color3.fromRGB(120, 255, 140) end
end)

-------------------------------------------------------------------------
-- keybinds  (always available, matcha-safe)
-------------------------------------------------------------------------
local hUIS
hUIS = UIS.InputBegan:Connect(function(inp)
  local kc = inp and inp.KeyCode
  local function is(k) return kc == k or kc == k.Value end
  if     is(Enum.KeyCode.T) then CONFIG.enabled = not CONFIG.enabled
  elseif is(Enum.KeyCode.H) then CONFIG.esp     = not CONFIG.esp
  elseif is(Enum.KeyCode.Y) then CONFIG.ring    = not CONFIG.ring
  elseif is(Enum.KeyCode.B) then CONFIG.path    = not CONFIG.path
  elseif is(Enum.KeyCode.N) then CONFIG.rmb     = not CONFIG.rmb
  elseif is(Enum.KeyCode.F) then CONFIG.fallback = not CONFIG.fallback
  elseif is(Enum.KeyCode.Z) then CONFIG.reaction = math.max(0, CONFIG.reaction - 0.01)
  elseif is(Enum.KeyCode.X) then CONFIG.reaction = math.min(0.4, CONFIG.reaction + 0.01)
  end
end)

-------------------------------------------------------------------------
-- INS-ui menu  (loads only where Instance.new exists; skipped in matcha)
-------------------------------------------------------------------------
local Lib
if Instance ~= nil then
  local okLib, lib = pcall(function()
    return loadstring(game:HttpGet("https://raw.githubusercontent.com/neaxusxgod-png/INS-ui/main/uilib.min.lua"))()
  end)
  if okLib and lib then
    Lib = lib
    pcall(function()
      local win = Lib:CreateWindow({
        title    = "AUTO PARRY",
        subtitle = "blade ball",
        size     = Vector2.new(620, 460),
        menuKey  = "p",
        opacity  = 98,
      })
      win:AddSettingsTab("gear")
      Lib:Notify("Auto Parry", "Press P for the menu", 4, "info")

      Lib:Category("PARRY")
      local main = win:Tab("Parry", "sword")

      local mn = main:Section("Auto Parry", "Left", "fires on the ball aimed at you")
      mn:Toggle("Enabled", CONFIG.enabled, function(v) CONFIG.enabled = v end):AddKeybind("t", "Toggle")
      mn:Toggle("Right click parry", CONFIG.rmb, function(v) CONFIG.rmb = v end,
        "use RMB instead of LMB to parry")
      mn:Toggle("Only while alive", CONFIG.onlyAlive, function(v) CONFIG.onlyAlive = v end)

      mn:Divider("Timing")
      mn:Slider("Reaction lead", math.floor(CONFIG.reaction * 1000), 5, 0, 400, "ms",
        function(v) CONFIG.reaction = v / 1000 end)
      mn:Toggle("Ping compensation", CONFIG.pingComp, function(v) CONFIG.pingComp = v end,
        "add your ping to the lead so fast balls still land")
      mn:Slider("Ping factor", CONFIG.pingFactor, 0.05, 0, 2, "x",
        function(v) CONFIG.pingFactor = v end)
      mn:Slider("Min interval", math.floor(CONFIG.minInterval * 1000), 5, 20, 300, "ms",
        function(v) CONFIG.minInterval = v / 1000 end)
      mn:Slider("Retry after", math.floor(CONFIG.retry * 1000), 5, 50, 500, "ms",
        function(v) CONFIG.retry = v / 1000 end)

      local tg = main:Section("Targeting", "Right", "which ball to parry")
      tg:Toggle("Fallback targeting", CONFIG.fallback, function(v) CONFIG.fallback = v end,
        "also parry the nearest incoming real ball when target lags (rebound / swap / curve)")
      tg:Slider("Fallback range", CONFIG.fallbackRange, 1, 10, 200, "studs",
        function(v) CONFIG.fallbackRange = v end)
      tg:Slider("Contact radius", CONFIG.contact, 0.5, 1, 12, "studs",
        function(v) CONFIG.contact = v end)
      tg:Divider("Live")
      tg:Label(function()
        if curSel then
          return string.format("%s  %.2fs  %d spd  %.0f st",
            curSel.aimed and "AIMED AT YOU" or "incoming",
            curSel.tti, math.floor(curSel.speed), curSel.dist)
        end
        return "no incoming ball"
      end)
      tg:Label(function()
        local acc = attempts > 0 and math.floor(100 * hits / attempts) or 0
        return string.format("ping %dms  swings %d  hits %d  acc %d%%",
          math.floor(pingMs), attempts, hits, acc)
      end)

      Lib:Category("VISUALS")
      local vis = win:Tab("Visuals", "eye")
      local vs = vis:Section("Overlay", "Left")
      vs:Toggle("Watermark", CONFIG.watermark, function(v) CONFIG.watermark = v end)
      vs:Toggle("Ball ESP", CONFIG.esp, function(v) CONFIG.esp = v end):AddKeybind("h", "Toggle")
      vs:Toggle("Range ring", CONFIG.ring, function(v) CONFIG.ring = v end):AddKeybind("y", "Toggle")
      vs:Toggle("Predicted path", CONFIG.path, function(v) CONFIG.path = v end):AddKeybind("b", "Toggle")
      vs:Toggle("Target retical", CONFIG.retical, function(v) CONFIG.retical = v end)

      local sys = vis:Section("Menu", "Right")
      sys:Button("Unload", function()
        Lib:Dialog({
          title = "Unload?", text = "Remove the auto parry and menu?",
          confirm = "Unload",
          onConfirm = function() if _G.BBAP_stop then _G.BBAP_stop() end end,
        })
      end):SetRisk()
    end)
  end
end

-------------------------------------------------------------------------
-- teardown
-------------------------------------------------------------------------
_G.BBAP_stop = function()
  _G.BBAP_installed = false
  if hUIS then hUIS:Disconnect() end
  if hRender then hRender:Disconnect() end
  for _, d in ipairs(D) do pcall(function() d:Remove() end) end
  if Lib then pcall(function() Lib:Destroy() end) end
  _G.BBAP_stop = nil
end

print("auto parry loaded  ("..(_hasW2S and "matcha" or "executor").." mode, INS-ui "..(Lib and "on" or "off")..")")
