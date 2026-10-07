-- Bomberflash
--[[
	GunClient (client weapon manager)
	Keybind-driven equip system for the gun MODELS under
	ReplicatedStorage.Assets.Props.Guns (Models welded to the hand, NOT Roblox Tools).

	Controls:
		Left Alt  - equip the active slot; if already holding a gun, cycle primary <-> secondary
		B         - unequip / holster
		Mouse1    - fire while a gun is held (hold to keep firing; gated by FireCooldown)

	The gun model is welded into the Right Arm (R6). Draw / Holster / Idle animations
	play off the ids in GunConfig (0 = skip). Bullet simulation is delegated to
	GunController (one FastCast2 caster per gun id). Hits are reported to the server via
	WeaponFire, and the server is told which gun we hold via EquipWeapon.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer
local mouse = player:GetMouse()

local GunController = require(script.Parent.Parent:WaitForChild("LocalModules"):WaitForChild("GunController"))
local GunConfig = require(ReplicatedStorage.Shared.Config.GunConfig)
local Remotes = ReplicatedStorage.Shared:WaitForChild("Remotes")
local WeaponFire = Remotes:WaitForChild("WeaponFire")
local EquipWeapon = Remotes:WaitForChild("EquipWeapon")
local GunsFolder = ReplicatedStorage:WaitForChild("Assets"):WaitForChild("Props"):WaitForChild("Guns")
local BulletTemplate = ReplicatedStorage:WaitForChild("Assets"):WaitForChild("VFX"):WaitForChild("Bullets"):WaitForChild("Bullet")

local EQUIP_KEY = Enum.KeyCode.LeftAlt
local UNEQUIP_KEY = Enum.KeyCode.B
local RELOAD_KEY = Enum.KeyCode.R

-- ===== Per-life state =========================================================
-- Tracks the current character, equipped weapon, animations, ammo, and firing state.
local character = nil
local rightArm = nil
local animator = nil

local controllers = {}       -- gunId -> GunController (rebuilt each life)
local activeSlot = 1          -- 1 = primary, 2 = secondary
local equippedGunId = nil
local equippedModel = nil
local tracks = nil            -- { Draw, Holster, Idle } AnimationTracks
local lastFire = 0
local mouse1Down = false
local ammo = {}              -- gunId -> current rounds in the magazine
local reloading = false
local currentIdle = nil      -- which base idle track is playing (Idle vs IdleMove)

-- ===== Helpers ================================================================
-- Small reusable functions for loadouts, animations, gun models, and controllers.
-- Get the gun assigned to the selected loadout slot.
local function slotGunId(slot)
	-- Per-player loadout comes from the profile, published as attributes by DataInit
	-- (LoadoutPrimary / LoadoutSecondary). Fall back to the shared GunConfig default.
	local attr = slot == 1 and "LoadoutPrimary" or "LoadoutSecondary"
	local id = player:GetAttribute(attr)
	if type(id) == "string" and GunConfig.Get(id) then
		return id
	end
	local loadout = GunConfig.Loadout
	return loadout and loadout[slot]
end

-- Load an animation track from its asset ID.
local function loadTrack(id)
	if not id or id <= 0 or not animator then
		return nil
	end
	local anim = Instance.new("Animation")
	anim.AnimationId = "rbxassetid://" .. id
	local track = animator:LoadAnimation(anim)
	track.Priority = Enum.AnimationPriority.Action
	return track
end

-- Strip existing joints, make every part physics-friendly, then re-weld the whole
-- model rigidly to its PrimaryPart so a single grip weld can carry it around.
local function rigidize(model, primary)
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = false
			d.CanCollide = false
			d.Massless = true
			d.CanQuery = false
			d.CanTouch = false
		elseif d:IsA("Weld") or d:IsA("Motor6D") or d:IsA("WeldConstraint") or d:IsA("ManualWeld") then
			d:Destroy()
		end
	end
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") and d ~= primary then
			local wc = Instance.new("WeldConstraint")
			wc.Part0 = primary
			wc.Part1 = d
			wc.Parent = primary
		end
	end
end

-- Get the muzzle position and aim direction toward the mouse.
local function getMuzzle(model, primary)
	local muzzle = model:FindFirstChild("Muzzle", true)
	local origin = (muzzle and muzzle:IsA("Attachment") and muzzle.WorldPosition) or primary.Position
	local target = mouse.Hit.Position
	return origin, (target - origin).Unit
end

-- Create or reuse the bullet controller for this gun.
local function getController(gunId, stats)
	local existing = controllers[gunId]
	if existing then
		return existing
	end
	local controller = GunController.new({
		Stats = stats,
		BulletTemplate = BulletTemplate,
		Ignore = { character },
	})
	-- Client predicts the hit, then tells the server (which re-validates + applies damage).
	controller.OnHit = function(raycastResult, _velocity, _bullet)
		local hitPart = raycastResult.Instance
		local humanoid = hitPart and hitPart.Parent and hitPart.Parent:FindFirstChildOfClass("Humanoid") or hitPart and hitPart.Parent and hitPart.Parent.Parent and hitPart.Parent.Parent:FindFirstChildOfClass("Humanoid")
		if humanoid then
			WeaponFire:FireServer(hitPart, raycastResult.Position)
		end
	end
	controllers[gunId] = controller
	return controller
end

-- Tear down the currently held gun. Optionally play its Holster animation first,
-- and run `after` once the teardown (including holster delay) is done.
local function teardown(playHolster, after)
	local model = equippedModel
	local held = tracks
	equippedModel = nil
	tracks = nil
	equippedGunId = nil
	if character then character:SetAttribute("HoldingWeapon", false) end -- arms drop from view-model aim
	EquipWeapon:FireServer(nil) -- server disallows firing during the swap gap

	if held then
		for name, t in held do
			if t and name ~= "Holster" then t:Stop(0.15) end
		end
	end
	currentIdle = nil
	reloading = false

	local holsterTime = 0
	if playHolster and held and held.Holster then
		held.Holster.Looped = false
		held.Holster:Play(0.1)
		holsterTime = 0.35
	end

	task.delay(holsterTime, function()
		if model then model:Destroy() end
		if held then
			for _, t in held do
				if t then t:Destroy() end
			end
		end
		if after then after() end
	end)
end

-- Clone, prepare, animate, and equip the gun in the chosen slot.
local function equipSlot(slot)
	if not character or not rightArm or not animator then return end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then return end

	local gunId = slotGunId(slot)
	if not gunId then return end
	local stats = GunConfig.Get(gunId)
	if not stats then
		warn(`[GunClient] no GunConfig entry for slot {slot} (gunId '{tostring(gunId)}')`)
		return
	end

	local template = GunsFolder:FindFirstChild(stats.ModelName or "Gun")
	if not template or not template:IsA("Model") then
		warn(`[GunClient] gun model '{tostring(stats.ModelName)}' not found under Assets.Props.Guns`)
		return
	end

	activeSlot = slot

	local model = template:Clone()
	local primary = model.PrimaryPart or model:FindFirstChild("Main")
	if not primary then
		warn("[GunClient] gun model has no PrimaryPart / Main")
		model:Destroy()
		return
	end
	model.PrimaryPart = primary
	rigidize(model, primary)
	model.Parent = character

	-- Weld the gun's PrimaryPart into the Right Arm at the configured grip offset.
	local grip = Instance.new("Weld")
	grip.Name = "GunGrip"
	grip.Part0 = rightArm
	grip.Part1 = primary
	grip.C0 = stats.Grip or CFrame.new(0, -1, 0)
	grip.Parent = primary

	equippedModel = model
	equippedGunId = gunId

	local anims = stats.Animations
	tracks = {
		Draw = loadTrack(anims and anims.Draw),
		Holster = loadTrack(anims and anims.Holster),
		Idle = loadTrack(anims and anims.Idle),
		IdleMove = loadTrack(anims and anims.IdleMove),
		Shoot = loadTrack(anims and anims.Shoot),
		ShootMove = loadTrack(anims and anims.ShootMove),
		Reload = loadTrack(anims and anims.Reload),
	}
	if tracks.Shoot then
		tracks.Shoot.Looped = false
		tracks.Shoot.Priority = Enum.AnimationPriority.Action2 -- read over the Idle pose
	end
	if tracks.ShootMove then
		tracks.ShootMove.Looped = false
		tracks.ShootMove.Priority = Enum.AnimationPriority.Action2 -- read over the moving idle
	end
	if tracks.Reload then
		tracks.Reload.Looped = false
		tracks.Reload.Priority = Enum.AnimationPriority.Action2
	end
	if tracks.Idle then tracks.Idle.Looped = true end
	if tracks.IdleMove then tracks.IdleMove.Looped = true end
	currentIdle = nil -- updateIdle() (Heartbeat) starts the right base loop
	if tracks.Draw then
		tracks.Draw.Looped = false
		tracks.Draw:Play(0.1)
	end

	-- ammo: remember per-gun; fill the mag the first time this gun is equipped
	if ammo[gunId] == nil then
		ammo[gunId] = stats.MagSize or math.huge
	end
	reloading = false
	player:SetAttribute("Ammo", ammo[gunId])
	player:SetAttribute("MagSize", stats.MagSize or 0)

	character:SetAttribute("HoldingWeapon", true) -- WeaponArmsCamera makes the arms follow the camera
	getController(gunId, stats)     -- warm the caster
	EquipWeapon:FireServer(gunId)   -- server now allows this gun's damage
end

-- ===== Input ==================================================================
-- Connect player input to equip, holster, fire, and reload actions.
-- Equip a gun, or switch to the other loadout slot.
local function onEquipKey()
	if not equippedGunId then
		equipSlot(activeSlot)
	else
		-- already holding one -> cycle to the other slot
		local nextSlot = activeSlot == 1 and 2 or 1
		teardown(true, function()
			equipSlot(nextSlot)
		end)
	end
end

-- Holster the currently equipped gun.
local function onUnequipKey()
	if equippedGunId then
		teardown(true, nil)
	end
end

-- Validate firing conditions, shoot, spend ammo, and play the shot animation.
local function tryFire()
	if not equippedGunId or not equippedModel then return end
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then return end

	local stats = GunConfig.Get(equippedGunId)
	if not stats then return end

	if reloading then return end
	if (ammo[equippedGunId] or 0) <= 0 then return end -- empty mag; press R to reload

	local now = os.clock()
	-- fire rate is NOT time-scaled: you shoot at your normal cadence even in slowed
	-- time; only the bullet's travel speed slows (see GunController:Fire).
	if now - lastFire < stats.FireCooldown then return end
	lastFire = now

	local primary = equippedModel.PrimaryPart
	if not primary then return end

	local origin, direction = getMuzzle(equippedModel, primary)
	local controller = getController(equippedGunId, stats)
	if controller then
		controller:Fire(origin, direction)
	end

	-- spend a round
	ammo[equippedGunId] = (ammo[equippedGunId] or 1) - 1
	player:SetAttribute("Ammo", ammo[equippedGunId])

	-- retrigger the shoot animation from the start on every shot; use the moving
	-- variant when the character is moving (fall back to Shoot if it has no id)
	if tracks then
		local moving = humanoid.MoveDirection.Magnitude > 0
		local shot = (moving and tracks.ShootMove) or tracks.Shoot
		if shot then
			shot.TimePosition = 0
			shot:Play(0.05)
		end
	end
end

-- switch the base loop between standing idle and moving idle
-- Play the standing or moving idle animation as needed.
local function updateIdle()
	if not tracks then currentIdle = nil return end
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local moving = humanoid and humanoid.MoveDirection.Magnitude > 0
	local want = (moving and tracks.IdleMove) or tracks.Idle
	if want ~= currentIdle then
		if currentIdle then currentIdle:Stop(0.2) end
		if want then want:Play(0.2) end
		currentIdle = want
	end
end

-- Play the reload animation and refill the magazine after the reload time.
local function startReload()
	if reloading or not equippedGunId then return end
	local stats = GunConfig.Get(equippedGunId)
	if not stats then return end
	local mag = stats.MagSize or 0
	if mag <= 0 then return end
	if (ammo[equippedGunId] or 0) >= mag then return end -- already full

	reloading = true
	if tracks and tracks.Reload then
		tracks.Reload.TimePosition = 0
		tracks.Reload:Play(0.1)
	end

	local gunAtStart = equippedGunId
	task.delay(stats.ReloadTime or 1.5, function()
		if reloading and equippedGunId == gunAtStart then
			ammo[gunAtStart] = mag
			reloading = false
			player:SetAttribute("Ammo", ammo[gunAtStart])
		end
	end)
end

-- Handle weapon controls when a key or mouse button is pressed.
UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		mouse1Down = true
		tryFire() -- fire on the press (semi = just this shot; auto = first of many)
	elseif input.KeyCode == EQUIP_KEY then
		onEquipKey()
	elseif input.KeyCode == UNEQUIP_KEY then
		onUnequipKey()
	elseif input.KeyCode == RELOAD_KEY then
		startReload()
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		mouse1Down = false
	end
end)

-- Update idle animations and repeat fire for automatic weapons.
RunService.Heartbeat:Connect(function()
	updateIdle() -- keep the base loop matched to standing/moving

	-- only auto-repeat while held for guns flagged Automatic; semi guns fire once
	-- per click (handled in InputBegan above).
	if not mouse1Down or not equippedGunId then return end
	local stats = GunConfig.Get(equippedGunId)
	if stats and stats.Automatic then
		tryFire()
	end
end)

-- ===== Character lifecycle ====================================================
-- Clean up the old character and initialize the weapon system after respawning.
-- Reset weapon state and set up references for each new character life.
local function onCharacter(char)
	-- clear anything left from the previous life
	for id, c in controllers do
		c:Destroy()
		controllers[id] = nil
	end
	if equippedModel then equippedModel:Destroy() end
	equippedModel = nil
	equippedGunId = nil
	tracks = nil
	mouse1Down = false
	reloading = false
	currentIdle = nil
	table.clear(ammo)

	character = char
	char:SetAttribute("HoldingWeapon", false)
	rightArm = char:WaitForChild("Right Arm", 10)
	local humanoid = char:WaitForChild("Humanoid", 10)
	animator = humanoid and humanoid:WaitForChild("Animator", 10)

	-- On death, go limp: stop every playing track (our gun anims + Animate's
	-- walk/idle + movement anims) and stop Animate from replaying, so the ragdoll
	-- isn't holding a pose. The local client owns these tracks, so it must do this
	-- itself (RagdollService does the same server-side for dummies).
	if humanoid and humanoid:IsA("Humanoid") then
		humanoid.Died:Connect(function()
			-- resolve the animator from THIS life's humanoid, not the shared `animator`
			-- upvalue (which is reassigned on respawn) - a late Died must never touch
			-- the next character's tracks
			local myAnimator = humanoid:FindFirstChildOfClass("Animator")
			if myAnimator then
				for _, track in myAnimator:GetPlayingAnimationTracks() do
					track:Stop(0)
				end
			end
			local animate = char:FindFirstChild("Animate")
			if animate then animate.Disabled = true end
		end)
	end

	EquipWeapon:FireServer(nil)
end

player.CharacterAdded:Connect(onCharacter)
if player.Character then
	onCharacter(player.Character)
end