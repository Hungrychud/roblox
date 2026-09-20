---------------------------------

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local CONFIG = {
	NpcTag = "ImpossibleParryNPC",
	NpcAttribute = "ImpossibleParry",
	BallsFolder = "Balls",
	lookAhead = 1.5,
	contact = 9,
	targetedContact = 18,
	minSpeed = 1,
	retry = 0.04,
	parryStateTime = 0.12,
	fallback = true,
	fallbackRange = 500,
	returnSpeedMultiplier = 1.10,
	minimumReturnSpeed = 90,
	aimLead = 0.10,
}

type BallState = {
	container: Instance,
	part: BasePart,
	pos: Vector3,
	vel: Vector3,
	speed: number,
	target: string?,
}

local npcs: {[Model]: boolean} = {}
local firedBall: {[Model]: {[Instance]: number}} = setmetatable({}, { __mode = "k" }) :: any
local parrySerial: {[Model]: number} = setmetatable({}, { __mode = "k" }) :: any
local watchedNpcs: {[Model]: boolean} = setmetatable({}, { __mode = "k" }) :: any

local function getRoot(model: Model): BasePart?
	local root = model:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then return root end
	return model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true)
end

local function isAliveNpc(model: Model): boolean
	if Players:GetPlayerFromCharacter(model) then return false end
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.Health > 0 and getRoot(model) ~= nil
end

local function registerNpc(instance: Instance)
	-- Keep marked models in the registry even if their Humanoid/root has not
	-- replicated yet. Heartbeat checks readiness before trying to parry.
	if instance:IsA("Model") then npcs[instance] = true end
end

local function unregisterNpc(instance: Instance)
	if instance:IsA("Model") then
		npcs[instance] = nil
		firedBall[instance] = nil
	end
end

local function watchNpc(instance: Instance)
	if not instance:IsA("Model") then return end
	if watchedNpcs[instance] then return end
	watchedNpcs[instance] = true
	if instance:GetAttribute(CONFIG.NpcAttribute) == true then registerNpc(instance) end
	-- Matcha does not implement GetAttributeChangedSignal. The initial value is
	-- still honored there; full Roblox servers also receive later changes.
	local hasSignal, attributeSignal = pcall(function()
		return instance:GetAttributeChangedSignal(CONFIG.NpcAttribute)
	end)
	if not hasSignal or not attributeSignal then return end
	attributeSignal:Connect(function()
		if instance:GetAttribute(CONFIG.NpcAttribute) == true then
			registerNpc(instance)
		elseif not CollectionService:HasTag(instance, CONFIG.NpcTag) then
			unregisterNpc(instance)
		end
	end)
end

for _, instance in Workspace:GetDescendants() do watchNpc(instance) end
for _, instance in CollectionService:GetTagged(CONFIG.NpcTag) do
	watchNpc(instance)
	registerNpc(instance)
end
local addedOk, tagAddedSignal = pcall(function()
	return CollectionService:GetInstanceAddedSignal(CONFIG.NpcTag)
end)
if addedOk and tagAddedSignal then
	tagAddedSignal:Connect(function(instance)
		watchNpc(instance)
		registerNpc(instance)
	end)
end

local removedOk, tagRemovedSignal = pcall(function()
	return CollectionService:GetInstanceRemovedSignal(CONFIG.NpcTag)
end)
if removedOk and tagRemovedSignal then
	tagRemovedSignal:Connect(function(instance)
		if instance:GetAttribute(CONFIG.NpcAttribute) ~= true then unregisterNpc(instance) end
	end)
end
Workspace.DescendantAdded:Connect(function(instance)
	watchNpc(instance)
	-- A marked Model can be inserted before its Humanoid/root. Registering the
	-- model itself above and retaining it in `npcs` makes that order harmless.
end)
Workspace.DescendantRemoving:Connect(unregisterNpc)

local function getBallState(container: Instance): BallState?
	if container:GetAttribute("realBall") == false then return nil end
	local part: BasePart?
	if container:IsA("BasePart") then
		part = container
	elseif container:IsA("Model") then
		part = container.PrimaryPart or container:FindFirstChildWhichIsA("BasePart", true)
	end
	if not part then return nil end
	local velocity = part.AssemblyLinearVelocity
	local speed = velocity.Magnitude
	if speed < CONFIG.minSpeed then return nil end
	local target = container:GetAttribute("target") or container:GetAttribute("Target")
	if target == nil and container ~= part then
		target = part:GetAttribute("target") or part:GetAttribute("Target")
	end
	return {
		container = container,
		part = part,
		pos = part.Position,
		vel = velocity,
		speed = speed,
		target = if type(target) == "string" then target else nil,
	}
end

-- Keeps the original realBall/target priority and incoming-ball fallback, but
-- uses closest-point prediction so high-speed balls cannot tunnel past an NPC.
local function getThreat(ball: BallState, npc: Model, root: BasePart): number?
	local toNpc = root.Position - ball.pos
	local distance = toNpc.Magnitude
	if distance < 0.001 then return 0 end
	if ball.vel:Dot(toNpc / distance) <= 0 then return nil end
	local tti = math.clamp(toNpc:Dot(ball.vel) / (ball.speed * ball.speed), 0, CONFIG.lookAhead)
	local miss = (root.Position - (ball.pos + ball.vel * tti)).Magnitude
	if ball.target == npc.Name and miss <= CONFIG.targetedContact then return tti end
	if CONFIG.fallback and distance <= CONFIG.fallbackRange and miss <= CONFIG.contact then return tti end
	return nil
end

local function findReturnTarget(npc: Model, origin: Vector3): (BasePart?, string?)
	local bestRoot: BasePart? = nil
	local bestName: string? = nil
	local bestDistance = math.huge
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local root = character and getRoot(character)
		if humanoid and humanoid.Health > 0 and root then
			local distance = (root.Position - origin).Magnitude
			if distance < bestDistance then
				bestRoot, bestName, bestDistance = root, player.Name, distance
			end
		end
	end
	for otherNpc in npcs do
		if otherNpc ~= npc and isAliveNpc(otherNpc) then
			local root = getRoot(otherNpc)
			if root then
				local distance = (root.Position - origin).Magnitude
				if distance < bestDistance then
					bestRoot, bestName, bestDistance = root, otherNpc.Name, distance
				end
			end
		end
	end
	return bestRoot, bestName
end

local function setBallTarget(ball: BallState, name: string)
	ball.container:SetAttribute("target", name)
	if ball.container:GetAttribute("Target") ~= nil then ball.container:SetAttribute("Target", name) end
	if ball.container ~= ball.part then
		if ball.part:GetAttribute("target") ~= nil then ball.part:SetAttribute("target", name) end
		if ball.part:GetAttribute("Target") ~= nil then ball.part:SetAttribute("Target", name) end
	end
end

local function parry(npc: Model, root: BasePart, ball: BallState)
	local now = os.clock()
	local history = firedBall[npc]
	if not history then
		history = setmetatable({}, { __mode = "k" }) :: any
		firedBall[npc] = history
	end
	if now - (history[ball.container] or -math.huge) < CONFIG.retry then return end
	history[ball.container] = now

	local returnRoot, returnName = findReturnTarget(npc, ball.pos)
	local direction: Vector3
	if returnRoot and returnName then
		direction = returnRoot.Position + returnRoot.AssemblyLinearVelocity * CONFIG.aimLead - ball.pos
		setBallTarget(ball, returnName)
	else
		local normal = ball.pos - root.Position
		if normal.Magnitude < 0.001 then
			direction = -ball.vel
		else
			normal = normal.Unit
			direction = ball.vel - 2 * ball.vel:Dot(normal) * normal
		end
	end
	if direction.Magnitude < 0.001 then direction = -ball.vel end

	-- Server ownership makes the hardest NPC independent of client ping.
	pcall(function() ball.part:SetNetworkOwner(nil) end)
	local speed = math.max(ball.speed * CONFIG.returnSpeedMultiplier, CONFIG.minimumReturnSpeed)
	ball.part.AssemblyLinearVelocity = direction.Unit * speed
	ball.container:SetAttribute("Parried", true)
	ball.container:SetAttribute("LastParriedBy", npc.Name)
	npc:SetAttribute("Parrying", true)

	-- Existing server VFX/animation/counter code can listen to this event.
	local event = npc:FindFirstChild("ImpossibleParry")
	if event and not event:IsA("BindableEvent") then
		warn(("%s.ImpossibleParry must be a BindableEvent"):format(npc:GetFullName()))
		event = nil
	elseif not event then
		event = Instance.new("BindableEvent")
		event.Name = "ImpossibleParry"
		event.Parent = npc
	end
	if event then (event :: BindableEvent):Fire(ball.container) end

	local serial = (parrySerial[npc] or 0) + 1
	parrySerial[npc] = serial
	task.delay(CONFIG.parryStateTime, function()
		if npc.Parent and parrySerial[npc] == serial then npc:SetAttribute("Parrying", false) end
	end)
end

RunService.Heartbeat:Connect(function()
	local folder = Workspace:FindFirstChild(CONFIG.BallsFolder)
	if not folder then return end
	for _, child in folder:GetChildren() do
		local ball = getBallState(child)
		if not ball then continue end
		local bestNpc: Model? = nil
		local bestRoot: BasePart? = nil
		local bestTti = math.huge
		for npc in npcs do
			if not npc:IsDescendantOf(Workspace) then
				unregisterNpc(npc)
				continue
			end
			if not isAliveNpc(npc) then continue end
			local root = getRoot(npc)
			if root then
				local tti = getThreat(ball, npc, root)
				if tti ~= nil and tti < bestTti then
					bestNpc, bestRoot, bestTti = npc, root, tti
				end
			end
		end
		if bestNpc and bestRoot then parry(bestNpc, bestRoot, ball) end
	end
end)
