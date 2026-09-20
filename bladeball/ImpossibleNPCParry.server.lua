

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local CONFIG = {
	NpcTag = "ImpossibleParryNPC",
	NpcAttribute = "ImpossibleParry",
	BallsFolderName = "Balls",

	-- A swept trajectory check prevents fast balls from tunnelling past the NPC.
	LookAheadSeconds = 1.25,
	ParryRadius = 9,
	TargetedParryRadius = 18,
	MinimumBallSpeed = 1,
	PerBallCooldown = 0.05,
	ParryStateSeconds = 0.12,

	-- A small speed gain keeps the hardest NPC from losing fast exchanges.
	ReturnSpeedMultiplier = 1.08,
	MinimumReturnSpeed = 85,
	AimLeadSeconds = 0.10,
}

type BallSnapshot = {
	container: Instance,
	part: BasePart,
	position: Vector3,
	velocity: Vector3,
	speed: number,
}

local npcSet: {[Model]: boolean} = {}
local lastParry: {[Model]: {[Instance]: number}} = setmetatable({}, { __mode = "k" }) :: any
local parrySerial: {[Model]: number} = setmetatable({}, { __mode = "k" }) :: any

local function getRoot(model: Model): BasePart?
	local root = model:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	if model.PrimaryPart then
		return model.PrimaryPart
	end
	return model:FindFirstChildWhichIsA("BasePart", true)
end

local function isLivingNpc(model: Model): boolean
	if Players:GetPlayerFromCharacter(model) then
		return false
	end
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.Health > 0 and getRoot(model) ~= nil
end

local function registerNpc(instance: Instance)
	if instance:IsA("Model") and isLivingNpc(instance) then
		npcSet[instance] = true
	end
end

local function unregisterNpc(instance: Instance)
	if instance:IsA("Model") then
		npcSet[instance] = nil
		lastParry[instance] = nil
	end
end

local function watchNpcAttribute(instance: Instance)
	if not instance:IsA("Model") then
		return
	end
	if instance:GetAttribute(CONFIG.NpcAttribute) == true then
		registerNpc(instance)
	end
	instance:GetAttributeChangedSignal(CONFIG.NpcAttribute):Connect(function()
		if instance:GetAttribute(CONFIG.NpcAttribute) == true then
			registerNpc(instance)
		elseif not CollectionService:HasTag(instance, CONFIG.NpcTag) then
			unregisterNpc(instance)
		end
	end)
end

for _, tagged in CollectionService:GetTagged(CONFIG.NpcTag) do
	registerNpc(tagged)
end

-- Attribute support makes setup possible without CollectionService tags.
for _, descendant in Workspace:GetDescendants() do
	watchNpcAttribute(descendant)
end

CollectionService:GetInstanceAddedSignal(CONFIG.NpcTag):Connect(registerNpc)
CollectionService:GetInstanceRemovedSignal(CONFIG.NpcTag):Connect(unregisterNpc)

Workspace.DescendantAdded:Connect(function(instance)
	watchNpcAttribute(instance)
end)

Workspace.DescendantRemoving:Connect(unregisterNpc)

local function getBallSnapshot(container: Instance): BallSnapshot?
	if container:GetAttribute("realBall") == false then
		return nil
	end

	local part: BasePart?
	if container:IsA("BasePart") then
		part = container
	elseif container:IsA("Model") then
		part = container.PrimaryPart or container:FindFirstChildWhichIsA("BasePart", true)
	end
	if not part then
		return nil
	end

	local velocity = part.AssemblyLinearVelocity
	local speed = velocity.Magnitude
	if speed < CONFIG.MinimumBallSpeed then
		return nil
	end

	return {
		container = container,
		part = part,
		position = part.Position,
		velocity = velocity,
		speed = speed,
	}
end

local function targetName(ball: BallSnapshot): string?
	local value = ball.container:GetAttribute("target")
	if value == nil and ball.container ~= ball.part then
		value = ball.part:GetAttribute("target")
	end
	if typeof(value) == "Instance" then
		return (value :: Instance).Name
	end
	return if type(value) == "string" then value else nil
end

local function willHitNpc(ball: BallSnapshot, npc: Model, root: BasePart): boolean
	local offset = root.Position - ball.position
	if ball.velocity:Dot(offset) <= 0 then
		return false
	end

	local timeToClosest = math.clamp(
		offset:Dot(ball.velocity) / (ball.speed * ball.speed),
		0,
		CONFIG.LookAheadSeconds
	)
	local closestPoint = ball.position + ball.velocity * timeToClosest
	local explicitlyTargeted = targetName(ball) == npc.Name
	local radius = if explicitlyTargeted then CONFIG.TargetedParryRadius else CONFIG.ParryRadius

	return (root.Position - closestPoint).Magnitude <= radius
end

local function getReturnTarget(npc: Model, fromPosition: Vector3): BasePart?
	local best: BasePart? = nil
	local bestDistance = math.huge

	for _, player in Players:GetPlayers() do
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local root = character and getRoot(character)
		if humanoid and humanoid.Health > 0 and root then
			local distance = (root.Position - fromPosition).Magnitude
			if distance < bestDistance then
				best, bestDistance = root, distance
			end
		end
	end

	for otherNpc in npcSet do
		if otherNpc ~= npc and isLivingNpc(otherNpc) then
			local root = getRoot(otherNpc)
			if root then
				local distance = (root.Position - fromPosition).Magnitude
				if distance < bestDistance then
					best, bestDistance = root, distance
				end
			end
		end
	end

	return best
end

local function setTargetAttribute(ball: BallSnapshot, value: string)
	ball.container:SetAttribute("target", value)
	if ball.container ~= ball.part and ball.part:GetAttribute("target") ~= nil then
		ball.part:SetAttribute("target", value)
	end
end

local function parry(npc: Model, root: BasePart, ball: BallSnapshot)
	local now = os.clock()
	local npcCooldowns = lastParry[npc]
	if not npcCooldowns then
		npcCooldowns = setmetatable({}, { __mode = "k" }) :: any
		lastParry[npc] = npcCooldowns
	end
	if now - (npcCooldowns[ball.container] or -math.huge) < CONFIG.PerBallCooldown then
		return
	end
	npcCooldowns[ball.container] = now

	local returnTarget = getReturnTarget(npc, ball.position)
	local direction: Vector3
	if returnTarget then
		local predictedPosition = returnTarget.Position
			+ returnTarget.AssemblyLinearVelocity * CONFIG.AimLeadSeconds
		direction = predictedPosition - ball.position
		setTargetAttribute(ball, returnTarget.Parent and returnTarget.Parent.Name or returnTarget.Name)
	else
		-- With no opponent, reflect the ball away from the NPC.
		local normal = ball.position - root.Position
		if normal.Magnitude < 0.001 then
			normal = -ball.velocity.Unit
		else
			normal = normal.Unit
		end
		direction = ball.velocity - 2 * ball.velocity:Dot(normal) * normal
	end

	if direction.Magnitude < 0.001 then
		direction = -ball.velocity
	end

	local returnSpeed = math.max(ball.speed * CONFIG.ReturnSpeedMultiplier, CONFIG.MinimumReturnSpeed)
	pcall(function()
		ball.part:SetNetworkOwner(nil)
	end)
	ball.part.AssemblyLinearVelocity = direction.Unit * returnSpeed
	ball.container:SetAttribute("LastParriedBy", npc.Name)
	ball.container:SetAttribute("Parried", true)

	local event = npc:FindFirstChild("ImpossibleParry")
	if not event then
		event = Instance.new("BindableEvent")
		event.Name = "ImpossibleParry"
		event.Parent = npc
	end
	(event :: BindableEvent):Fire(ball.container)

	npc:SetAttribute("Parrying", true)
	local serial = (parrySerial[npc] or 0) + 1
	parrySerial[npc] = serial
	task.delay(CONFIG.ParryStateSeconds, function()
		if npc.Parent and parrySerial[npc] == serial then
			npc:SetAttribute("Parrying", false)
		end
	end)
end

RunService.Heartbeat:Connect(function()
	local ballsFolder = Workspace:FindFirstChild(CONFIG.BallsFolderName)
	if not ballsFolder then
		return
	end

	local balls: {BallSnapshot} = {}
	for _, child in ballsFolder:GetChildren() do
		local snapshot = getBallSnapshot(child)
		if snapshot then
			table.insert(balls, snapshot)
		end
	end

	for npc in npcSet do
		if not npc:IsDescendantOf(Workspace) or not isLivingNpc(npc) then
			unregisterNpc(npc)
			continue
		end

		local root = getRoot(npc)
		if root then
			for _, ball in balls do
				if willHitNpc(ball, npc, root) then
					parry(npc, root, ball)
				end
			end
		end
	end
end)
