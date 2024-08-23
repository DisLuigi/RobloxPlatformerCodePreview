-- Input Controller Module for my platformer demo thing

-- Services
local playerService = game:GetService("Players")
local userInputService = game:GetService("UserInputService")
local replicatedStorage = game:GetService("ReplicatedStorage")
local runService = game:GetService("RunService")

-- Modules
local customEnums = require(replicatedStorage.Types.Enums)
local signal = require(replicatedStorage.Shared.Modules.Utility.Signal)
local railModule = require(replicatedStorage.Shared.Modules.Gameplay.Rails)
local interactableReplicator = require(replicatedStorage.Client.Modules.Replication.InteractableReplication)
local mathModule = require(replicatedStorage.Shared.Modules.Utility.Math)

-- Variables
local workInteractables = workspace.Map.Interactables

local localPlayer = playerService.LocalPlayer
local debugGui = localPlayer.PlayerGui:WaitForChild("Debug")

-- Module
local inputController = {}
inputController.Sprinting = false
inputController.DoubleJumped = false
inputController.WallSliding = false
inputController.WallJumpDebounce = false
inputController.Diving = false
inputController.CanDive = true
inputController.GroundPounding = false
inputController.CanGroundPound = true
inputController.GrindingRail = false
inputController.RailDebounce = false
inputController.DiveDebounce = false
inputController.GroundPoundStarting = false
inputController.UsingSpeedPad = false

inputController.SprintToggled = signal.new()
inputController.OnDoubleJump = signal.new()
inputController.WallSlideToggled = signal.new()
inputController.DiveToggled = signal.new()
inputController.OnWallJump = signal.new()
inputController.GroundPoundToggled = signal.new()
inputController.RailGrindToggled = signal.new()
inputController.TimeWarped = signal.new()
inputController.JumpPadUsed = signal.new()
inputController.SpeedPadUsed = signal.new()
inputController.FOVChangeRequest = signal.new()

-- Variables and constants
local groundPoundCanceled = signal.new()

local disabled = false
local active = false

local sprintingKey = Enum.KeyCode.LeftShift
local jumpingKey = Enum.KeyCode.Space
local diveKey = Enum.KeyCode.E
local crouchKey = Enum.KeyCode.Q

local currentCharacter: typeof(replicatedStorage.Resources.Characters.DefaultPlayer)
local connections: {[string]: RBXScriptConnection}

local baseJumpPower = 50

local baseSpeed = 16
local sprintMult = 2
local sprintingOnJump = false

local diveForce = 64
local diveCoolDown = .1

local groundPoundCancelTime = .325
local groundPoundForce = 100

local defaultRailGrindVelocity = 75
local currentRailGrindVelocity = defaultRailGrindVelocity
local railAdjustmentSpeed = 2

local railGrindCoolDown = .25

local wallSlideObject: Part
local wallSlideNormal: Vector3
local wallJumpCoolDown = .1

local defaultRingVelocity = 125
local lastBoosterRing: Model

local defaultJumpPadVelocity = 75
local lastJumpPad: Model

local defaultSpeedPadVelocity = 100
local lastSpeedPad: Model

local alignPosition: AlignPosition
local currentRailSegment: railModule.Node

local primaryPart: Part
local humanoid: Humanoid

local modelSize: Vector3

-- Module
function inputController.Activate()
	if active then
		return
	end
	
	-- VARIABLES
	------------
	active = true
	
	currentCharacter = localPlayer.Character or localPlayer.CharacterAdded:Wait()
	connections = {}
	
	primaryPart = currentCharacter.PrimaryPart
	humanoid = currentCharacter.Humanoid
	
	humanoid.JumpPower = baseJumpPower
	humanoid.WalkSpeed = baseSpeed
	
	modelSize = currentCharacter:GetExtentsSize()
	
	-- STATE FUNCTIONS
	------------------
	
	-- ENDING A STATE
	--------
	
	local function endDiving()
		humanoid.HipHeight = 0
		inputController.Diving = false
		inputController.DiveToggled:Fire(false)
		--humanoid.WalkSpeed = if inputController.Sprinting then baseSpeed*sprintMult else baseSpeed
		
		inputController.DiveDebounce = true
		task.delay(diveCoolDown, function()
			inputController.DiveDebounce = false
		end)
	end
	
	local function endWallSliding()
		inputController.WallSlideToggled:Fire(false)
		wallSlideObject = nil
		inputController.WallSliding = false
		wallSlideNormal = nil
		alignPosition:Destroy()
		workspace.Gravity = workspace.Map.Configuration.Gravity.Value
	end
	
	local function endGroundPound(landed: boolean)
		groundPoundCanceled:Fire()
		inputController.GroundPoundToggled:Fire(false, landed)
		inputController.GroundPounding = false
		inputController.GroundPoundStarting = false
		-- Doesn't reset velocity
		humanoid.HipHeight = 0
	end
	
	local function endRailGrind()
		inputController.FOVChangeRequest:Fire(70, railAdjustmentSpeed)
		humanoid.EvaluateStateMachine = true
		inputController.RailDebounce = true
		sprintingOnJump = false -- Make sure that we don't go faster than our railGrind velocity
		
		local direction = (currentRailSegment.Node0.WorldPosition - currentRailSegment.Node1.WorldPosition).Unit
		local realSpeed = Vector3.new(direction.X, 0, direction.Z).Magnitude * currentRailGrindVelocity -- Remove Y axis from the intended movement speed
		
		currentRailSegment = nil
		baseSpeed = realSpeed
		
		task.delay(railGrindCoolDown, function()
			inputController.RailDebounce = false
		end)
		
		connections.RailGrinding:Disconnect()
		currentCharacter.Torso.CanCollide = true
		inputController.GrindingRail = false
		inputController.RailGrindToggled:Fire(false)
	end
	
	-- STARTING / TOGGLING A STATE THAT NEEDS TO BE CALLED FROM DIFFERENT POINTS
	-----------
	
	local function toggleSprinting(isSprinting: boolean)
		inputController.Sprinting = isSprinting
		inputController.SprintToggled:Fire(isSprinting)
	end
	
	local function startWallSliding(object: Part, normal: Vector3)
		-- Wallslide
		wallSlideObject = object
		wallSlideNormal = normal
		inputController.WallSliding = true
		-- Slow humanoid down
		primaryPart.AssemblyLinearVelocity = Vector3.new(0, primaryPart.AssemblyLinearVelocity.Y/3, 0)
		-- Limit movements
		alignPosition = Instance.new("AlignPosition", primaryPart)
		alignPosition.Mode = Enum.PositionAlignmentMode.OneAttachment
		alignPosition.Position = primaryPart.Position
		alignPosition.MaxVelocity = math.huge
		alignPosition.ForceLimitMode = Enum.ForceLimitMode.PerAxis
		alignPosition.MaxAxesForce = Vector3.new(math.huge, 0, math.huge)
		-- Fall slower
		workspace.Gravity = workspace.Map.Configuration.Gravity.Value / 4

		inputController.WallSlideToggled:Fire(true)
	end
	
	local function startRailGrinding(startPart: railModule.Node, railParts: {railModule.Node})
		if inputController.Diving then
			endDiving()
		end

		if inputController.GroundPounding then
			endGroundPound()
		end

		-- Rail Grinding resets the debounce on double jumping
		inputController.DoubleJumped = false
		inputController.GrindingRail = true
		inputController.RailGrindToggled:Fire(true)

		local sourceModel = railModule.ModelLibrary[startPart.Parent]
		local baseRailVelocity = sourceModel:GetAttribute("Velocity") or defaultRailGrindVelocity
		currentRailGrindVelocity = baseRailVelocity
		local loop: boolean = sourceModel:GetAttribute("Loop")

		-- Prevents the humanoid from doing any janky stuff (snapping positions and orientations for one)
		humanoid.EvaluateStateMachine = false
		currentCharacter.Torso.CanCollide = false

		currentRailSegment = startPart :: railModule.Node
		--local direction = if humanoid.MoveDirection:Dot(startPart.CFrame.LookVector) > 0 then 1 else -1
		-- Possible introduction of rail grinding input direction

		local lookCF = CFrame.new(currentRailSegment.Node0.WorldPosition, currentRailSegment.Node1.WorldPosition)
		primaryPart.CFrame = CFrame.new(currentRailSegment.Node0.WorldPosition + (lookCF.UpVector * 3)) * lookCF.Rotation

		local timePassed = 0

		local function getTravelTime()
			return currentRailSegment.Size.X / currentRailGrindVelocity
		end
		
		local lastSprintingState
		
		connections.RailGrinding = runService.RenderStepped:Connect(function(deltaTime)
			timePassed += deltaTime
			-- Gotta constantly reset the velocity because due to being unanchored, the character wants to fling everywhere
			primaryPart.AssemblyLinearVelocity = Vector3.zero
			primaryPart.AssemblyAngularVelocity = Vector3.zero
			
			if lastSprintingState ~= inputController.Sprinting then
				inputController.FOVChangeRequest:Fire(if inputController.Sprinting then 90 else 70, railAdjustmentSpeed)
			end
			
			lastSprintingState = inputController.Sprinting
			
			currentRailGrindVelocity = mathModule.Lerp(currentRailGrindVelocity, baseRailVelocity * (inputController.Sprinting and 1.5 or 1), deltaTime*railAdjustmentSpeed)
			
			while timePassed >= getTravelTime() do
				local oldSegment = currentRailSegment
				currentRailSegment = railParts[tonumber(currentRailSegment.Name)+1]
				
				if not currentRailSegment then
					if loop then
						currentRailSegment = railParts[1]
					else
						-- No more rail segments means it's at the end of the rail (we don't do directions)
						currentRailSegment = railParts[#railParts]
						local unit = (currentRailSegment.Node1.WorldPosition-currentRailSegment.Node0.WorldPosition).Unit
						primaryPart.AssemblyLinearVelocity = unit * currentRailGrindVelocity + Vector3.new(0,humanoid.JumpPower,0)
						primaryPart.AssemblyAngularVelocity = Vector3.zero
						humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
						endRailGrind()
						return
					end
				end

				timePassed -= getTravelTime()
			end

			local lookCF = CFrame.new(currentRailSegment.Node0.WorldPosition, currentRailSegment.Node1.WorldPosition)
			primaryPart.CFrame = CFrame.new(currentRailSegment.Node0.WorldPosition:Lerp(currentRailSegment.Node1.WorldPosition, timePassed/getTravelTime())) * lookCF.Rotation + (lookCF.UpVector*3)
		end)
	end
	
	local function startGroundPounding(customCancelTimeValue: number?)
		inputController.GroundPoundToggled:Fire(true) -- Sort of a lie but that's for animations
		inputController.GroundPoundStarting = true -- For the cancelation of groundPounding
		
		-- Actions that could override / cancel the ground pound
		local cancled, overriden
		local connection1 = inputController.DiveToggled:Connect(function(dive: boolean)
			if dive then
				cancled = true
			end
		end)

		local connection2 = groundPoundCanceled:Connect(function()
			cancled = true
			overriden = true
		end)

		local connection3 = inputController.TimeWarped:Connect(function()
			cancled = true
		end)

		task.delay(customCancelTimeValue or groundPoundCancelTime, function()
			connection1:Disconnect()
			connection2:Disconnect()
			connection3:Disconnect()
			
			if not overriden then
				inputController.CanGroundPound = true -- Reset debounce
			end

			if not cancled then -- Conflicts
				inputController.GroundPoundStarting = false
				inputController.GroundPounding = true -- Enable actual state
				primaryPart.AssemblyLinearVelocity = Vector3.new(0, -groundPoundForce, 0)
			end
		end)
	end
	
	-- CHECKING FOR INTERACTABLES
	--------
	
	-- Defined as its own function due to being called every Heartbeat,
	-- and when the humanoid lands, before it changes any key states (GroundPounding to be specific).
	
	local function jumpPadCheck()
		local params = OverlapParams.new()
		params.FilterType = Enum.RaycastFilterType.Include

		local descendnats = workInteractables.JumpPads:GetChildren()

		if lastJumpPad then
			table.remove(descendnats, table.find(descendnats, lastJumpPad))
		end

		params.FilterType = Enum.RaycastFilterType.Include
		params.FilterDescendantsInstances = descendnats

		local result = workspace:GetPartBoundsInBox(primaryPart.CFrame-Vector3.new(0,3,0), Vector3.new(0.5,2.5,0.5), params)
		local jumpPadModel: Model

		for _, part in pairs(result) do
			if part.Parent.Parent == workInteractables.JumpPads then
				jumpPadModel = part.Parent
				break
			end
		end

		if jumpPadModel then
			if inputController.Diving then
				endDiving()
			end

			local wasGroundPounding = inputController.GroundPounding
			if wasGroundPounding then
				endGroundPound()
			end

			local direction = jumpPadModel.PrimaryPart.CFrame.UpVector
			local velocity: number = (jumpPadModel:GetAttribute("Velocity") or defaultJumpPadVelocity) * (wasGroundPounding and 1.5 or 1)

			humanoid.JumpPower = velocity
			humanoid:ChangeState(Enum.HumanoidStateType.Jumping)	

			interactableReplicator.OnReplicated("JumpPads", jumpPadModel)
			inputController.JumpPadUsed:Fire()
			
			lastJumpPad = jumpPadModel

			task.spawn(function()
				runService.Heartbeat:Wait()
				humanoid.JumpPower = baseJumpPower
				
				if lastJumpPad == jumpPadModel then
					lastJumpPad = nil
				end
			end)
		end
	end
	
	-- CONNECTIONS
	--------------
	
	connections.InputStarted = userInputService.InputBegan:Connect(function(input, debounce)
		if debounce or disabled then
			return
		end
		
		if input.KeyCode == sprintingKey and humanoid.FloorMaterial ~= Enum.Material.Air then
			-- Enabling sprinting
			toggleSprinting(true)
		elseif input.KeyCode == jumpingKey and not inputController.Diving then
			-- Jumping actions
			if inputController.GrindingRail then
				
				-- Jumping off of a rail
				local oldRailSegment = currentRailSegment
				local oldRailVelocity = currentRailGrindVelocity
				
				endRailGrind()
				
				primaryPart.AssemblyLinearVelocity = 
					(oldRailSegment.Node1.WorldPosition-oldRailSegment.Node0.WorldPosition).Unit
					* oldRailVelocity
					+ Vector3.new(0,humanoid.JumpPower,0)
				humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
			elseif inputController.WallSliding then
				-- Wall Jumping
				local storedNormal = wallSlideNormal
				
				endWallSliding()
				
				inputController.WallJumpDebounce = true
				inputController.OnWallJump:Fire(storedNormal)
				
				sprintingOnJump = false
				primaryPart.AssemblyLinearVelocity = Vector3.new(storedNormal.X*humanoid.JumpPower*1.25, humanoid.JumpPower*1.5, storedNormal.Z*humanoid.JumpPower*1.25)
				task.wait(wallJumpCoolDown)
				baseSpeed = humanoid.JumpPower*1.25/1.5
				inputController.WallJumpDebounce = false
			elseif not inputController.DoubleJumped and humanoid.FloorMaterial == Enum.Material.Air then
				-- Double jumping
				inputController.DoubleJumped = true
				local originalVelocity = primaryPart.AssemblyLinearVelocity
				primaryPart.AssemblyLinearVelocity = Vector3.new(originalVelocity.X, humanoid.JumpPower, originalVelocity.Z)
				inputController.OnDoubleJump:Fire()
			else
				-- Regular Jumping
				sprintingOnJump = inputController.Sprinting
			end
		elseif input.KeyCode == diveKey then
			-- Diving
			local direction = humanoid.MoveDirection
			if direction.Magnitude == 0 or inputController.DiveDebounce or inputController.GroundPounding or inputController.GrindingRail or inputController.Diving or inputController.WallSliding then
				return
			end
			
			if inputController.GroundPoundStarting then
				inputController.GroundPoundStarting = false
				inputController.CanGroundPound = true
			end
			
			inputController.Diving = true
			baseSpeed = diveForce/1.5
			humanoid.HipHeight = -1
			primaryPart.AssemblyLinearVelocity = direction * diveForce + Vector3.new(0,diveForce/2,0)
			inputController.DiveToggled:Fire(true)
		elseif input.KeyCode == crouchKey then
			-- Corouching maybe but that's useless af
			if inputController.GroundPoundStarting then
				endGroundPound()
				-- Cancelling halves velocity
				primaryPart.AssemblyLinearVelocity /= 2
				task.wait(groundPoundCancelTime)
				inputController.CanGroundPound = true
			elseif humanoid.FloorMaterial == Enum.Material.Air and not inputController.Diving and not inputController.GrindingRail and not inputController.GroundPounding and inputController.CanGroundPound then
				-- Actually ground pound
				baseSpeed = 0
				humanoid.HipHeight = -1
				primaryPart.AssemblyLinearVelocity = Vector3.new(0, groundPoundForce/2, 0)
				inputController.CanGroundPound = false -- To avoid stacking of the action 
				startGroundPounding()
			end
		end
	end)
	
	connections.InputEnded = userInputService.InputEnded:Connect(function(input, debounce)
		if debounce or disabled then
			return
		end
		
		if input.KeyCode == sprintingKey and inputController.Sprinting then
			toggleSprinting(false)
		end
	end)
	
	-- State checking
	connections.HumanoidState = humanoid.StateChanged:Connect(function(oldState, newState)
		if newState == Enum.HumanoidStateType.Landed then
			-- Landing automatically sets back your speed
			sprintingOnJump = false
			baseSpeed = 16
			-- Enable double jumps
			inputController.DoubleJumped = false
			-- End wall sliding
			if inputController.WallSliding then
				endWallSliding()
			end
			-- End diving
			if inputController.Diving then
				endDiving()
			end
			
			-- Check for jump pads (ground pounding is a variable)
			if not inputController.GrindingRail then
				jumpPadCheck()
			end
			
			-- End ground pounding
			if inputController.GroundPounding then
				-- Ended
				endGroundPound(true)
				humanoid:ChangeState(Enum.HumanoidStateType.Jumping) -- Force jumping
			end
			-- Enable sprinting
			if userInputService:IsKeyDown(sprintingKey) and (not inputController.Sprinting or humanoid.WalkSpeed ~= baseSpeed*sprintMult) then
				toggleSprinting(true)
			end
		end
	end)
	
	-- Frame by frame checking of other actions / interactions
	connections.Update = runService.Heartbeat:Connect(function(deltaTime)
		-- Debug Gui Statuses
		debugGui.Main.RailGrinding.Text = "RailGrinding: "..tostring(inputController.GrindingRail)
		debugGui.Main.Diving.Text = "Diving: "..tostring(inputController.Diving)
		debugGui.Main.WallSliding.Text = "WallSliding: "..tostring(inputController.WallSliding)
		debugGui.Main.GroundPounding.Text = "GroundPounding: "..tostring(inputController.GroundPounding)
		debugGui.Main.GroundPoundDebounce.Text = "CanGroundPound: "..tostring(inputController.CanGroundPound)
		debugGui.Main.RailGrindDebounce.Text = "RailGrindDebounce: "..tostring(inputController.RailDebounce)
		debugGui.Main.WallJumpDebounce.Text = "WallJumpDebounce: "..tostring(inputController.WallJumpDebounce)
		debugGui.Main.DivingDebounce.Text = "DiveDebounce: "..tostring(inputController.DiveDebounce)
		debugGui.Main.Sprinting.Text = "Sprinting: "..tostring(inputController.Sprinting)
		debugGui.Main.RailNode.Visible = not not currentRailSegment
		
		if currentRailSegment then
			debugGui.Main.RailNode.Text = "CurrentRailNode: "..tostring(currentRailSegment.Name)
		end
		
		-- Gradually setting humanoid movement speed back to what it's meant to be
		
		if inputController.Diving then
			humanoid.WalkSpeed = baseSpeed
		else
			if humanoid.FloorMaterial == Enum.Material.Air then
				-- Adjust speed back to default
				local difference = 16 - baseSpeed
				local studsPerSecond = 50
				-- Adjusts speed at 50 studs / second
				if difference <= 0 then
					-- Base speed is bigger
					baseSpeed = math.max(16, baseSpeed-(deltaTime*studsPerSecond))
				else
					-- Base speed is smaller
					baseSpeed = math.min(16, baseSpeed+(deltaTime*studsPerSecond))
				end
				
				humanoid.WalkSpeed = baseSpeed * (sprintingOnJump and sprintMult or 1)
			else
				humanoid.WalkSpeed = baseSpeed * (inputController.Sprinting and sprintMult or 1)
			end
		end
		
		-- Rail grinding
		if not inputController.WallSliding and not inputController.GrindingRail and not inputController.RailDebounce then
			local params = OverlapParams.new()
			params.FilterType = Enum.RaycastFilterType.Include
			params.FilterDescendantsInstances = {workspace.Map.Rails.Visuals}
			
			-- Check if the player is colliding with a rail object
			local result = workspace:GetPartBoundsInBox(primaryPart.CFrame, modelSize*1.5, params)
			local railParts: {railModule.Node}
			local startPart: railModule.Node
			
			-- Find the rail information
			for _, part in pairs(result) do
				railParts = railModule.RailLibrary[part.Parent]
				if railParts then
					startPart = part
					break
				end
			end
			
			if railParts then
				startRailGrinding(startPart, railParts)
			end
		end
		
		-- Booster Rings
		if not inputController.WallSliding and not inputController.GrindingRail then
			local params = OverlapParams.new()
			
			local descendnats = workInteractables.BoosterRings:GetChildren()
			-- Use lastBoosterRing to prevent rings from being used multiple times
			if lastBoosterRing then
				table.remove(descendnats, table.find(descendnats, lastBoosterRing))
			end
			
			params.FilterType = Enum.RaycastFilterType.Include
			params.FilterDescendantsInstances = descendnats
			
			-- Find possible booster rings
			local result = workspace:GetPartBoundsInBox(primaryPart.CFrame, inputController.GetHitboxFromState(), params)
			local ringModel: Model
			
			for _, part in pairs(result) do
				if part.Parent.Parent == workInteractables.BoosterRings then
					ringModel = part.Parent
					break
				end
			end
			
			if ringModel then
				if inputController.GroundPounding then
					endGroundPound()
				end
				
				local characterDir = primaryPart.AssemblyLinearVelocity.Unit
				local lv = ringModel.PrimaryPart.CFrame.LookVector
				
				-- Velocity the player goes is dependant on if the player is GOING one way or the other (not facing)
				local fDot = lv:Dot(characterDir)
				local direction = if fDot >= 0 then lv else -lv
				
				local velocity: number = ringModel:GetAttribute("Velocity") or defaultRingVelocity
				
				primaryPart.AssemblyLinearVelocity = direction*velocity
				-- Update lastBoosterRing, prevents the same ring from being used multiple times
				lastBoosterRing = ringModel
				interactableReplicator.OnReplicated("BoosterRings", ringModel)
				sprintingOnJump = inputController.Sprinting
				baseSpeed = 16
				-- Reset the lastBoosterRing variable to nil
				task.delay(.1, function()
					if lastBoosterRing == ringModel then
						lastBoosterRing = nil
					end
				end)
			end
		end
		
		-- Jump Pads
		if not inputController.GrindingRail then
			jumpPadCheck()
		end
		
		-- Speed Pads
		if not inputController.GrindingRail and not inputController.UsingSpeedPad then
			local params = RaycastParams.new()
			params.FilterType = Enum.RaycastFilterType.Include
			params.FilterDescendantsInstances = workInteractables.SpeedPads:GetChildren()

			-- Find possible speed pads
			local result = workspace:Raycast(primaryPart.Position, Vector3.yAxis * -4, params)
			
			if result then
				if inputController.Diving then
					endDiving()
				end
				
				if inputController.GroundPounding then
					endGroundPound()
				end
				
				local part: BasePart = result.Instance
				local speedPadModel: Model = part.Parent
				local velocity = speedPadModel:GetAttribute("Velocity") or defaultSpeedPadVelocity
				local direction = part.CFrame.LookVector
				
				sprintingOnJump = false
				inputController.UsingSpeedPad = true
				inputController.SpeedPadUsed:Fire(customEnums.SpeedPadState.Started)
				
				-- Moves the player along the direction of the jump pad, and launches the player when it is no longer on it.
				connections.SpeedPad = runService.RenderStepped:Connect(function(deltaTime)
					primaryPart.CFrame += (direction * velocity) * deltaTime
					-- Make sure the player is still on the pad
					local result = workspace:Raycast(primaryPart.Position, Vector3.yAxis * -4, params)
					
					if not result or result.Instance.Parent ~= speedPadModel then
						-- Launch the player in whatever direction using the velocity and disconnect connection
						connections.SpeedPad:Disconnect()
						inputController.SpeedPadUsed:Fire(customEnums.SpeedPadState.Ended)
						primaryPart.CFrame = CFrame.new(primaryPart.CFrame.Position, primaryPart.CFrame.Position + direction)
						primaryPart.AssemblyLinearVelocity = direction * velocity
						inputController.UsingSpeedPad = false
						sprintingOnJump = false
						baseSpeed = velocity
					end
				end)
			end
		end
		
		-- Wall sliding
		local direction = humanoid.MoveDirection
		if direction.Magnitude ~= 0 and humanoid.FloorMaterial == Enum.Material.Air and not inputController.GroundPounding
			and not inputController.GrindingRail and not inputController.WallJumpDebounce then
			
			local params = RaycastParams.new()
			params.FilterType = Enum.RaycastFilterType.Include
			params.FilterDescendantsInstances = {workspace.Map.Visuals}

			-- Find the possble wall the humanoid is on
			local result = workspace:Raycast(primaryPart.Position, direction*2, params)
			
			if result then
				if result.Instance == wallSlideObject then
					return
				end

				-- You can't wallslide on a slope
				if math.abs(result.Normal.Y) > 0.1 then
					return
				end

				-- This action cancels out diving, allowing you to dive after wall jumping
				if inputController.Diving then
					endDiving()
				end

				startWallSliding(result.Instance, result.Normal)
			else
				if inputController.WallSliding then
					-- Player is moving elsewhere, cancel the wallslide
					endWallSliding()
				end
			end
		end
	end)
end

function inputController.Deactivate()
	if not active then
		return
	end
	
	active = false
	
	for _, connection in pairs(connections) do
		connection:Disconnect()
	end
end

-- Self Explanitory
function inputController.GetWallSlideNormal(): Vector3
	return wallSlideNormal
end

-- Self Explanitory
function inputController.GetRailSegment(): (railModule.Node)
	return currentRailSegment
end

-- Considers all active states and returns a string version
function inputController.GetCurrentAction(): string
	local newState: string
	-- Evaluated seperately to avoid conflicts
	if inputController.Sprinting then
		newState = "Sprinting" -- Kind of just a "nothing" state since the game doesn't actually care about this
	end
	
	if inputController.GrindingRail then
		newState = "GrindingRail"
	elseif inputController.Diving then
		newState = "Diving"
	elseif inputController.GroundPounding then
		newState = "GroundPounding"
	elseif not inputController.CanGroundPound then
		newState = "GroundPoundStart"
	elseif inputController.WallSliding then
		newState = "WallSliding"
	elseif humanoid.FloorMaterial == Enum.Material.Air then
		newState = "Jumping"
	else
		newState = "None"
	end
	
	return newState
end

-- Determines the hitbox size from the state
function inputController.GetHitboxFromState(): Vector3
	if inputController.GetCurrentAction() == "Diving" then
		return Vector3.new(4,1,6)
	else
		return Vector3.new(4,6,1)
	end
end

-- Disables the controller from accepting inputs without removing connections / Resetting variables from calling Deactivate()
function inputController.Disable()
	if disabled or not active then
		return
	end
	
	disabled = true
end

-- Re-enable input accepting
function inputController.Enable()
	if not disabled or not active then
		return
	end
	
	disabled = false
end

return inputController
