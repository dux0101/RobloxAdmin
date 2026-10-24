--!nolint UnknownGlobal
--[[
	ADMIN HUB  -  single-script Luau client dashboard
	-------------------------------------------------------------------------

	WHAT IT CAN / CANNOT DO
	  * Everything here is CLIENT-SIDE. It changes your own character, camera,
	    lighting and local visuals. Your character's physics are client-owned, so
	    fly / noclip / speed / teleport on yourself replicate normally unless the
	    server (anti-cheat) reverts them.
	
]]

--==========================================================================
-- 0. CONFIG, SERVICES, GUARDS
--==========================================================================
local CONFIG = {
	RestrictToUserIds = {}, -- e.g. {123456789}. Empty = no gate. Convenience only, NOT security.
	SaveFileName = "AdminHub_Settings.json",
	WindowWidth = 800,
	WindowHeight = 520,
	TopBarHeight = 46,
	SidebarWidth = 150,
}

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local HttpService = game:GetService("HttpService")
local ContextActionService = game:GetService("ContextActionService")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
	warn("[AdminHub] This script must run as a LocalScript (client).")
	return
end
if #CONFIG.RestrictToUserIds > 0 and not table.find(CONFIG.RestrictToUserIds, LocalPlayer.UserId) then
	return
end

local genv
do
	local ok, env = pcall(function()
		return getgenv()
	end)
	genv = (ok and type(env) == "table") and env or _G
end

-- Prevent duplicated initialisation: tear down any previous instance first.
if type(genv.__AdminHubCleanup) == "function" then
	pcall(genv.__AdminHubCleanup)
end
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")
do
	local oldGui = PlayerGui:FindFirstChild("AdminHub_Main")
	if oldGui then oldGui:Destroy() end
	local oldFolder = Workspace:FindFirstChild("AdminHub_Visuals")
	if oldFolder then oldFolder:Destroy() end
end

--==========================================================================
-- 1. DEFAULTS, SETTINGS SPEC, STATE
--==========================================================================
local DEFAULTS = {
	menuKey = "RightShift",
	theme = "Dark",
	accent = Color3.fromRGB(90, 140, 255),
	transparency = 0,
	uiScale = 1,
	animSpeed = 1,
	notifDuration = 3.5,
	flySpeed = 70,
	walkSpeed = 32,
	jumpPower = 80,
	fov = 90,
	freeCamSpeed = 60,
	visualsMaster = true,
	espColor = Color3.fromRGB(255, 255, 255),
	espTextSize = 14,
	espMaxDistance = 1500,
	espShowNames = true,
	espShowDistance = true,
	chamsFill = Color3.fromRGB(255, 70, 70),
	chamsOutline = Color3.fromRGB(255, 255, 255),
	chamsFillTransparency = 0.5,
	keybinds = { fly = "F", noclip = "N", infjump = "J", esp = "K", fullbright = "B" },
}

-- Numeric ranges (used for sliders, typed input, command arguments and load-time validation)
local SPEC = {
	transparency = { label = "Transparency", min = 0, max = 0.6, step = 0.01, decimals = 2 },
	uiScale = { label = "UI scale", min = 0.6, max = 1.5, step = 0.05, decimals = 2, deferred = true },
	animSpeed = { label = "Animation speed", min = 0.25, max = 3, step = 0.05, decimals = 2 },
	notifDuration = { label = "Notification duration (s)", min = 1, max = 10, step = 0.5, decimals = 1 },
	flySpeed = { label = "Fly speed", min = 5, max = 400, step = 1, decimals = 0 },
	walkSpeed = { label = "WalkSpeed", min = 0, max = 300, step = 1, decimals = 0 },
	jumpPower = { label = "JumpPower", min = 0, max = 400, step = 1, decimals = 0 },
	fov = { label = "Field of view", min = 20, max = 120, step = 1, decimals = 0 },
	freeCamSpeed = { label = "Free camera speed", min = 5, max = 300, step = 1, decimals = 0 },
	espTextSize = { label = "ESP text size", min = 8, max = 28, step = 1, decimals = 0 },
	espMaxDistance = { label = "ESP max distance", min = 100, max = 5000, step = 50, decimals = 0 },
	chamsFillTransparency = { label = "Chams fill transparency", min = 0, max = 1, step = 0.05, decimals = 2 },
}

local settings = {}
local state = {
	fly = false, noclip = false, infjump = false, walkspeed = false, jumppower = false,
	esp = false, chams = false, fullbright = false, fov = false, freecam = false,
}
local alive = true
local selectedPlayer = nil
local onChange = {} -- settingKey -> function() called after the setting changes

--==========================================================================
-- 2. UTILITIES: Maid, Util, Store (persistence)
--==========================================================================
local Maid = {}
Maid.__index = Maid
function Maid.new()
	return setmetatable({ _tasks = {} }, Maid)
end
function Maid:Add(item)
	table.insert(self._tasks, item)
	return item
end
function Maid:Clean()
	local tasks = self._tasks
	self._tasks = {}
	for _, item in ipairs(tasks) do
		local ty = typeof(item)
		if ty == "RBXScriptConnection" then
			item:Disconnect()
		elseif ty == "Instance" then
			pcall(item.Destroy, item)
		elseif ty == "function" then
			pcall(item)
		end
	end
end

local Util = {}
function Util.deepCopy(v)
	if type(v) ~= "table" then return v end
	local c = {}
	for k, x in pairs(v) do c[k] = Util.deepCopy(x) end
	return c
end
function Util.round(v, step)
	local r = math.floor(v / step + 0.5) * step
	return tonumber(string.format("%.4f", r)) or r
end
function Util.fmt(v, decimals)
	return string.format("%." .. tostring(decimals or 0) .. "f", v)
end
function Util.validKey(name)
	local ok, kc = pcall(function()
		return Enum.KeyCode[name]
	end)
	return ok and kc ~= nil and kc ~= Enum.KeyCode.Unknown
end
function Util.tween(inst, props, duration, style, dir)
	local d = (duration or 0.2) / math.max(settings.animSpeed or 1, 0.1)
	local tw = TweenService:Create(inst, TweenInfo.new(d, style or Enum.EasingStyle.Quad, dir or Enum.EasingDirection.Out), props)
	tw:Play()
	return tw
end
function Util.new(class, props, children)
	local inst = Instance.new(class)
	local parent
	if props then
		for k, v in pairs(props) do
			if k == "Parent" then parent = v else inst[k] = v end
		end
	end
	if children then
		for _, c in ipairs(children) do c.Parent = inst end
	end
	if parent then inst.Parent = parent end
	return inst
end
local new = Util.new

-- Persistence ---------------------------------------------------------------
local Store = {
	hasFile = (type(writefile) == "function" and type(readfile) == "function"),
	queued = false,
	lastError = nil,
}

local function encodeValue(v)
	if typeof(v) == "Color3" then
		return { __color = { v.R, v.G, v.B } }
	elseif type(v) == "table" then
		local t = {}
		for k, x in pairs(v) do t[k] = encodeValue(x) end
		return t
	end
	return v
end

local function decodeValue(v)
	if type(v) == "table" then
		if type(v.__color) == "table" and #v.__color == 3 then
			local r, g, b = tonumber(v.__color[1]), tonumber(v.__color[2]), tonumber(v.__color[3])
			if r and g and b then
				return Color3.new(math.clamp(r, 0, 1), math.clamp(g, 0, 1), math.clamp(b, 0, 1))
			end
		end
		local t = {}
		for k, x in pairs(v) do t[k] = decodeValue(x) end
		return t
	end
	return v
end

-- Copies only valid, in-range values from `source` into `target`.
local function sanitizeInto(target, source)
	if type(source) ~= "table" then return end
	for key, default in pairs(DEFAULTS) do
		local v = source[key]
		if v ~= nil then
			if key == "keybinds" then
				if type(v) == "table" then
					local clean, seen = {}, {}
					local menu = (type(source.menuKey) == "string" and Util.validKey(source.menuKey)) and source.menuKey or DEFAULTS.menuKey
					for id, keyName in pairs(v) do
						if type(id) == "string" and type(keyName) == "string" and Util.validKey(keyName)
							and keyName ~= menu and not seen[keyName] then
							seen[keyName] = true
							clean[id] = keyName
						end
					end
					target.keybinds = clean
				end
			elseif key == "menuKey" then
				if type(v) == "string" and Util.validKey(v) then target.menuKey = v end
			elseif key == "theme" then
				if v == "Dark" or v == "Light" then target.theme = v end
			elseif typeof(v) == typeof(default) then
				if type(v) == "number" then
					if v == v then
						local spec = SPEC[key]
						target[key] = spec and math.clamp(v, spec.min, spec.max) or v
					end
				else
					target[key] = v
				end
			end
		end
	end
end

function Store.flush()
	local data = encodeValue(settings)
	if Store.hasFile then
		local ok, err = pcall(function()
			writefile(CONFIG.SaveFileName, HttpService:JSONEncode(data))
		end)
		Store.lastError = (not ok) and tostring(err) or nil
	else
		genv.__AdminHubSessionCache = data
	end
end

function Store.save()
	if Store.queued or not alive then return end
	Store.queued = true
	task.delay(0.6, function()
		Store.queued = false
		if alive then Store.flush() end
	end)
end

function Store.load()
	local saved
	if Store.hasFile then
		local ok, content = pcall(function()
			if type(isfile) == "function" and not isfile(CONFIG.SaveFileName) then return nil end
			return readfile(CONFIG.SaveFileName)
		end)
		if ok and type(content) == "string" and content ~= "" then
			local ok2, data = pcall(function()
				return HttpService:JSONDecode(content)
			end)
			if ok2 and type(data) == "table" then saved = decodeValue(data) end
		end
	elseif type(genv.__AdminHubSessionCache) == "table" then
		saved = decodeValue(genv.__AdminHubSessionCache)
	end
	sanitizeInto(settings, saved)
end

for k, v in pairs(Util.deepCopy(DEFAULTS)) do settings[k] = v end
Store.load()

local function setSetting(key, value)
	settings[key] = value
	local handler = onChange[key]
	if handler then
		local ok, err = pcall(handler)
		if not ok then warn("[AdminHub] setting handler error (" .. key .. "): " .. tostring(err)) end
	end
	Store.save()
end

local function validateSetting(key, raw)
	local spec = SPEC[key]
	local n = tonumber(raw)
	if not n or n ~= n or n == math.huge or n == -math.huge then
		return nil, ("'%s' is not a valid number."):format(tostring(raw))
	end
	if n < spec.min or n > spec.max then
		return nil, ("%s must be between %s and %s."):format(spec.label, Util.fmt(spec.min, spec.decimals), Util.fmt(spec.max, spec.decimals))
	end
	return n
end

--==========================================================================
-- 3. THEME, GUI ROOT, BASIC WIDGET HELPERS, NOTIFICATIONS
--==========================================================================
local UI = { refreshers = {}, pages = {}, navButtons = {}, cmdRows = {}, isOpen = false, minimized = false }

local THEMES = {
	Dark = {
		bg = Color3.fromRGB(21, 22, 30), sidebar = Color3.fromRGB(16, 17, 24),
		element = Color3.fromRGB(32, 34, 46), hover = Color3.fromRGB(43, 46, 62),
		text = Color3.fromRGB(236, 238, 247), subtext = Color3.fromRGB(148, 153, 175),
		stroke = Color3.fromRGB(54, 57, 76), track = Color3.fromRGB(58, 62, 84),
	},
	Light = {
		bg = Color3.fromRGB(244, 245, 250), sidebar = Color3.fromRGB(232, 234, 243),
		element = Color3.fromRGB(255, 255, 255), hover = Color3.fromRGB(238, 240, 248),
		text = Color3.fromRGB(26, 28, 38), subtext = Color3.fromRGB(108, 113, 135),
		stroke = Color3.fromRGB(214, 218, 230), track = Color3.fromRGB(205, 209, 224),
	},
}
local STATUS = { success = Color3.fromRGB(76, 196, 120), error = Color3.fromRGB(235, 87, 87) }
local WHITE = Color3.new(1, 1, 1)

local themedObjects = {} -- [instance] = { Property = themeKey }
local transparentTargets = {} -- [instance] = true (BackgroundTransparency follows settings.transparency)

local function color(key)
	if key == "accent" then return settings.accent end
	local t = THEMES[settings.theme] or THEMES.Dark
	return t[key]
end

local function bindTheme(inst, map)
	local entry = themedObjects[inst]
	if not entry then
		entry = {}
		themedObjects[inst] = entry
		inst.Destroying:Connect(function()
			themedObjects[inst] = nil
			transparentTargets[inst] = nil
		end)
	end
	for prop, key in pairs(map) do
		entry[prop] = key
		inst[prop] = color(key)
	end
	return inst
end

local function applyTheme()
	for inst, map in pairs(themedObjects) do
		if inst.Parent == nil then
			themedObjects[inst] = nil
		else
			for prop, key in pairs(map) do inst[prop] = color(key) end
		end
	end
	for inst in pairs(transparentTargets) do
		if inst.Parent then inst.BackgroundTransparency = settings.transparency end
	end
	UI.refreshAll(true)
end

local function corner(r)
	return new("UICorner", { CornerRadius = UDim.new(0, r or 8) })
end
local function stroke(key, thickness)
	local s = new("UIStroke", { Thickness = thickness or 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border })
	bindTheme(s, { Color = key or "stroke" })
	return s
end
local function padding(l, t, r, b)
	return new("UIPadding", {
		PaddingLeft = UDim.new(0, l or 0), PaddingTop = UDim.new(0, t or 0),
		PaddingRight = UDim.new(0, r or 0), PaddingBottom = UDim.new(0, b or 0),
	})
end
local function label(props, colorKey)
	props.BackgroundTransparency = 1
	props.Font = props.Font or Enum.Font.Gotham
	props.TextSize = props.TextSize or 14
	props.TextXAlignment = props.TextXAlignment or Enum.TextXAlignment.Left
	local l = new("TextLabel", props)
	bindTheme(l, { TextColor3 = colorKey or "text" })
	return l
end
local function nextOrder(parent)
	local n = (parent:GetAttribute("_n") or 0) + 1
	parent:SetAttribute("_n", n)
	return n
end

-- Root ScreenGui
local gui = new("ScreenGui", {
	Name = "AdminHub_Main", ResetOnSpawn = false, IgnoreGuiInset = true,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling, DisplayOrder = 1000, Parent = PlayerGui,
})

local function getCamera()
	return Workspace.CurrentCamera
end
local function screenSize()
	local s = gui.AbsoluteSize
	if s.X < 2 or s.Y < 2 then
		local cam = getCamera()
		s = cam and cam.ViewportSize or Vector2.new(1280, 720)
	end
	return s
end

-- Notifications ---------------------------------------------------------------
local toastRoot = new("Frame", {
	Name = "Toasts", AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -16, 1, -16),
	Size = UDim2.fromOffset(300, 420), BackgroundTransparency = 1, Parent = gui,
}, {
	new("UIListLayout", {
		SortOrder = Enum.SortOrder.LayoutOrder, VerticalAlignment = Enum.VerticalAlignment.Bottom,
		HorizontalAlignment = Enum.HorizontalAlignment.Right, Padding = UDim.new(0, 8),
	}),
})
local toastScale = new("UIScale", { Parent = toastRoot })
local toastCount = 0

local function notify(message, kind, title)
	if not alive then return end
	kind = kind or "info"
	toastCount += 1
	local accentColor = (kind == "success" and STATUS.success) or (kind == "error" and STATUS.error) or settings.accent
	title = title or (kind == "success" and "Success" or (kind == "error" and "Error" or "Info"))

	local frames = {}
	for _, c in ipairs(toastRoot:GetChildren()) do
		if c:IsA("Frame") then table.insert(frames, c) end
	end
	if #frames >= 5 then
		table.sort(frames, function(a, b) return a.LayoutOrder < b.LayoutOrder end)
		frames[1]:Destroy()
	end

	local holder = new("Frame", {
		Size = UDim2.fromOffset(300, 58), BackgroundTransparency = 1, LayoutOrder = toastCount, Parent = toastRoot,
	})
	local toast = new("Frame", {
		Size = UDim2.fromScale(1, 1), Position = UDim2.new(1.2, 0, 0, 0), BorderSizePixel = 0, Parent = holder,
	}, { corner(10), stroke("stroke") })
	bindTheme(toast, { BackgroundColor3 = "element" })
	new("Frame", {
		Size = UDim2.new(0, 4, 1, -16), Position = UDim2.fromOffset(8, 8), BackgroundColor3 = accentColor,
		BorderSizePixel = 0, Parent = toast,
	}, { corner(2) })
	label({ Text = title, Font = Enum.Font.GothamBold, TextSize = 13, Position = UDim2.fromOffset(22, 6), Size = UDim2.new(1, -32, 0, 16), Parent = toast })
	label({
		Text = tostring(message), TextSize = 12, Position = UDim2.fromOffset(22, 23), Size = UDim2.new(1, -32, 0, 30),
		TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top, TextTruncate = Enum.TextTruncate.AtEnd, Parent = toast,
	}, "subtext")

	Util.tween(toast, { Position = UDim2.new(0, 0, 0, 0) }, 0.3, Enum.EasingStyle.Back)
	task.delay(settings.notifDuration, function()
		if not alive or not holder.Parent then return end
		local tw = Util.tween(toast, { Position = UDim2.new(1.2, 0, 0, 0) }, 0.25)
		tw.Completed:Connect(function()
			if holder.Parent then holder:Destroy() end
		end)
	end)
end

--==========================================================================
-- 4. FEATURES (all real implementations; each owns its own connections)
--==========================================================================
local F = {}
local mainMaid = Maid.new()
local charMaid = Maid.new()

local function getChar() return LocalPlayer.Character end
local function getHumanoid()
	local c = LocalPlayer.Character
	return c and c:FindFirstChildOfClass("Humanoid")
end
local function getRoot()
	local c = LocalPlayer.Character
	return c and c:FindFirstChild("HumanoidRootPart")
end

local originalFov = (getCamera() and getCamera().FieldOfView) or 70

-- 4a. WalkSpeed / JumpPower --------------------------------------------------
local orig = { hum = nil }
local applied = { walk = false, jump = false }
local walkMaid, jumpMaid = Maid.new(), Maid.new()

local function captureOriginals(hum)
	if orig.hum ~= hum then
		orig = {
			hum = hum, walk = hum.WalkSpeed, jumpPower = hum.JumpPower,
			jumpHeight = hum.JumpHeight, useJumpPower = hum.UseJumpPower,
		}
		applied.walk, applied.jump = false, false
	end
end

function F.syncWalk()
	walkMaid:Clean()
	local hum = getHumanoid()
	if not hum then return true end
	captureOriginals(hum)
	if state.walkspeed then
		hum.WalkSpeed = settings.walkSpeed
		applied.walk = true
		walkMaid:Add(hum:GetPropertyChangedSignal("WalkSpeed"):Connect(function()
			if state.walkspeed and hum.WalkSpeed ~= settings.walkSpeed then
				hum.WalkSpeed = settings.walkSpeed
			end
		end))
	elseif applied.walk then
		hum.WalkSpeed = orig.walk
		applied.walk = false
	end
	return true
end

function F.syncJump()
	jumpMaid:Clean()
	local hum = getHumanoid()
	if not hum then return true end
	captureOriginals(hum)
	if state.jumppower then
		hum.UseJumpPower = true
		hum.JumpPower = settings.jumpPower
		applied.jump = true
		local function enforce()
			if not state.jumppower then return end
			if not hum.UseJumpPower then hum.UseJumpPower = true end
			if hum.JumpPower ~= settings.jumpPower then hum.JumpPower = settings.jumpPower end
		end
		jumpMaid:Add(hum:GetPropertyChangedSignal("JumpPower"):Connect(enforce))
		jumpMaid:Add(hum:GetPropertyChangedSignal("UseJumpPower"):Connect(enforce))
	elseif applied.jump then
		hum.JumpPower = orig.jumpPower
		hum.UseJumpPower = orig.useJumpPower
		applied.jump = false
	end
	return true
end

-- 4b. Fly ------------------------------------------------------------------------
local fly = { maid = Maid.new(), active = false }

function F.stopFly()
	local was = fly.active
	fly.active = false
	fly.maid:Clean()
	if was then
		local hum, root = getHumanoid(), getRoot()
		if hum and hum.Health > 0 then
			hum.PlatformStand = false
			hum:ChangeState(Enum.HumanoidStateType.GettingUp)
		end
		if root then root.AssemblyLinearVelocity = Vector3.zero end
	end
end

function F.startFly()
	F.stopFly()
	local hum, root = getHumanoid(), getRoot()
	if not hum or not root or hum.Health <= 0 then
		return false, "No living character to fly with."
	end
	local att = new("Attachment", { Name = "AdminHub_FlyAttachment", Parent = root })
	local lv = new("LinearVelocity", {
		Name = "AdminHub_FlyVelocity", Attachment0 = att, RelativeTo = Enum.ActuatorRelativeTo.World,
		MaxForce = math.huge, VectorVelocity = Vector3.zero, Parent = root,
	})
	local ao = new("AlignOrientation", {
		Name = "AdminHub_FlyOrientation", Mode = Enum.OrientationAlignmentMode.OneAttachment, Attachment0 = att,
		MaxTorque = math.huge, Responsiveness = 30, RigidityEnabled = false, CFrame = root.CFrame, Parent = root,
	})
	fly.maid:Add(att)
	fly.maid:Add(lv)
	fly.maid:Add(ao)
	hum.PlatformStand = true
	fly.active = true

	local velocity = Vector3.zero
	local lastFlat = Vector3.new(0, 0, -1)
	local function down(k) return UserInputService:IsKeyDown(k) end

	fly.maid:Add(RunService.Heartbeat:Connect(function(dt)
		local cam = getCamera()
		if not cam or not root.Parent then return end
		local cf = cam.CFrame
		local look = cf.LookVector
		local flat = Vector3.new(look.X, 0, look.Z)
		if flat.Magnitude > 0.001 then lastFlat = flat.Unit end
		local rv = cf.RightVector
		local flatRight = Vector3.new(rv.X, 0, rv.Z)
		flatRight = flatRight.Magnitude > 0.001 and flatRight.Unit or Vector3.xAxis

		local f, s, v = 0, 0, 0
		if UserInputService:GetFocusedTextBox() == nil then
			if down(Enum.KeyCode.W) then f += 1 end
			if down(Enum.KeyCode.S) then f -= 1 end
			if down(Enum.KeyCode.D) then s += 1 end
			if down(Enum.KeyCode.A) then s -= 1 end
			if down(Enum.KeyCode.Space) or down(Enum.KeyCode.E) then v += 1 end
			if down(Enum.KeyCode.LeftControl) or down(Enum.KeyCode.Q) then v -= 1 end
		end
		if f == 0 and s == 0 then -- gamepad / touch fallback through the default controls
			local md = hum.MoveDirection
			if md.Magnitude > 0.01 then
				f = md:Dot(lastFlat)
				s = md:Dot(flatRight)
			end
		end
		local dir = look * f + rv * s + Vector3.yAxis * v
		if dir.Magnitude > 1 then dir = dir.Unit end
		velocity = velocity:Lerp(dir * settings.flySpeed, math.clamp(dt * 10, 0, 1))
		lv.VectorVelocity = velocity
		ao.CFrame = CFrame.lookAt(root.Position, root.Position + lastFlat)
	end))
	return true
end

function F.syncFly()
	if state.fly then return F.startFly() end
	F.stopFly()
	return true
end

-- 4c. Noclip -----------------------------------------------------------------------
local noclip = { maid = Maid.new(), parts = {}, touched = {} }

function F.stopNoclip()
	noclip.maid:Clean()
	for part in pairs(noclip.touched) do
		if part.Parent then part.CanCollide = true end
	end
	noclip.touched = {}
	noclip.parts = {}
end

function F.startNoclip()
	F.stopNoclip()
	local char = getChar()
	if not char then return false, "No character." end
	local function add(d)
		if d:IsA("BasePart") then noclip.parts[d] = true end
	end
	for _, d in ipairs(char:GetDescendants()) do add(d) end
	noclip.maid:Add(char.DescendantAdded:Connect(add))
	noclip.maid:Add(char.DescendantRemoving:Connect(function(d)
		noclip.parts[d] = nil
		noclip.touched[d] = nil
	end))
	noclip.maid:Add(RunService.Stepped:Connect(function()
		for part in pairs(noclip.parts) do
			if part.CanCollide then
				noclip.touched[part] = true
				part.CanCollide = false
			end
		end
	end))
	return true
end

function F.syncNoclip()
	if state.noclip then return F.startNoclip() end
	F.stopNoclip()
	return true
end

-- 4d. Infinite jump ----------------------------------------------------------------
local infMaid = Maid.new()
function F.syncInfJump()
	infMaid:Clean()
	if state.infjump then
		infMaid:Add(UserInputService.JumpRequest:Connect(function()
			local hum = getHumanoid()
			if hum and hum.Health > 0 then hum:ChangeState(Enum.HumanoidStateType.Jumping) end
		end))
	end
	return true
end

-- 4e. Movement reset / teleport ------------------------------------------------------
function F.resetMovement()
	state.fly, state.noclip, state.infjump, state.walkspeed, state.jumppower = false, false, false, false, false
	F.syncFly()
	F.syncNoclip()
	F.syncInfJump()
	F.syncWalk()
	F.syncJump()
end

function F.teleport(pos)
	local root = getRoot()
	if not root then return false, "No character to teleport." end
	root.CFrame = CFrame.new(pos)
	root.AssemblyLinearVelocity = Vector3.zero
	return true, ("Teleported to %d, %d, %d"):format(math.floor(pos.X), math.floor(pos.Y), math.floor(pos.Z))
end

-- 4f. Visuals: ESP, Chams, Fullbright, FOV ----------------------------------------------
local vis = { esp = {}, chams = {}, loop = Maid.new() }
vis.folder = new("Folder", { Name = "AdminHub_Visuals", Parent = Workspace })

function F.destroyVisualsFor(plr)
	local e = vis.esp[plr]
	if e then e.gui:Destroy() vis.esp[plr] = nil end
	local c = vis.chams[plr]
	if c then c:Destroy() vis.chams[plr] = nil end
end

function F.updateEspText(plr)
	local e = vis.esp[plr]
	if not e then return end
	local lines = {}
	if settings.espShowNames then table.insert(lines, plr.DisplayName) end
	if settings.espShowDistance then
		local cam, ad = getCamera(), e.gui.Adornee
		if cam and ad then
			table.insert(lines, ("[%d studs]"):format(math.floor((cam.CFrame.Position - ad.Position).Magnitude)))
		end
	end
	e.label.Text = table.concat(lines, "\n")
end

function F.styleEsp(plr)
	local e = vis.esp[plr]
	if not e then return end
	e.label.TextColor3 = settings.espColor
	e.label.TextSize = settings.espTextSize
	e.gui.MaxDistance = settings.espMaxDistance
	e.gui.Size = UDim2.fromOffset(260, settings.espTextSize * 2 + 10)
	F.updateEspText(plr)
end

function F.styleChams(plr)
	local h = vis.chams[plr]
	if not h then return end
	h.FillColor = settings.chamsFill
	h.OutlineColor = settings.chamsOutline
	h.FillTransparency = settings.chamsFillTransparency
	h.OutlineTransparency = 0
end

function F.buildVisualsFor(plr)
	F.destroyVisualsFor(plr)
	if plr == LocalPlayer then return end
	local char = plr.Character
	if not char then return end
	local adornee = char:FindFirstChild("HumanoidRootPart") or char:FindFirstChild("Head") or char.PrimaryPart
	if state.esp and settings.visualsMaster and adornee then
		local g = new("BillboardGui", {
			Name = "ESP_" .. plr.UserId, Adornee = adornee, AlwaysOnTop = true,
			Size = UDim2.fromOffset(260, 40), StudsOffset = Vector3.new(0, 3.2, 0),
			MaxDistance = settings.espMaxDistance, Parent = vis.folder,
		})
		local l = new("TextLabel", {
			BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Font = Enum.Font.GothamBold,
			TextStrokeTransparency = 0.35, TextStrokeColor3 = Color3.new(0, 0, 0), Text = "", Parent = g,
		})
		vis.esp[plr] = { gui = g, label = l }
		F.styleEsp(plr)
	end
	if state.chams and settings.visualsMaster then
		vis.chams[plr] = new("Highlight", {
			Name = "Cham_" .. plr.UserId, Adornee = char, DepthMode = Enum.HighlightDepthMode.AlwaysOnTop, Parent = vis.folder,
		})
		F.styleChams(plr)
	end
end

function F.syncEspLoop()
	vis.loop:Clean()
	if state.esp and settings.visualsMaster and settings.espShowDistance then
		local acc = 0
		vis.loop:Add(RunService.Heartbeat:Connect(function(dt)
			acc += dt
			if acc < 0.1 then return end
			acc = 0
			for plr in pairs(vis.esp) do F.updateEspText(plr) end
		end))
	end
end

function F.restyleVisuals()
	for plr in pairs(vis.esp) do F.styleEsp(plr) end
	for plr in pairs(vis.chams) do F.styleChams(plr) end
	F.syncEspLoop()
end

-- Fullbright
local fb = { active = false, maid = Maid.new(), saved = {}, atmos = {} }
local FB_TARGET = {
	Brightness = 2, ClockTime = 14, FogEnd = 100000, GlobalShadows = false,
	Ambient = Color3.fromRGB(178, 178, 178), OutdoorAmbient = Color3.fromRGB(178, 178, 178),
}
function F.syncFullbright()
	local want = state.fullbright and settings.visualsMaster
	if want and not fb.active then
		fb.active, fb.saved, fb.atmos = true, {}, {}
		for prop in pairs(FB_TARGET) do fb.saved[prop] = Lighting[prop] end
		for _, a in ipairs(Lighting:GetChildren()) do
			if a:IsA("Atmosphere") then
				fb.atmos[a] = a.Density
				a.Density = 0
			end
		end
		for prop, val in pairs(FB_TARGET) do
			Lighting[prop] = val
			fb.maid:Add(Lighting:GetPropertyChangedSignal(prop):Connect(function()
				if fb.active and Lighting[prop] ~= val then Lighting[prop] = val end
			end))
		end
	elseif not want and fb.active then
		fb.active = false
		fb.maid:Clean()
		for prop, val in pairs(fb.saved) do Lighting[prop] = val end
		for a, d in pairs(fb.atmos) do
			if a.Parent then a.Density = d end
		end
		fb.saved, fb.atmos = {}, {}
	end
end

-- Field of view
local fovState = { maid = Maid.new(), applied = false }
function F.syncFov()
	fovState.maid:Clean()
	local cam = getCamera()
	if not cam then return end
	if state.fov and settings.visualsMaster then
		if not fovState.applied then originalFov = cam.FieldOfView end
		fovState.applied = true
		cam.FieldOfView = settings.fov
		fovState.maid:Add(cam:GetPropertyChangedSignal("FieldOfView"):Connect(function()
			if state.fov and settings.visualsMaster and cam.FieldOfView ~= settings.fov then
				cam.FieldOfView = settings.fov
			end
		end))
	elseif fovState.applied then
		cam.FieldOfView = originalFov
		fovState.applied = false
	end
end

function F.syncVisuals()
	for _, plr in ipairs(Players:GetPlayers()) do F.buildVisualsFor(plr) end
	F.syncEspLoop()
	F.syncFullbright()
	F.syncFov()
end

-- 4g. Players, spectate, free camera, camera reset -----------------------------------------
local spec = { target = nil, maid = Maid.new() }
local fc = { active = false, maid = Maid.new(), pos = Vector3.zero, yaw = 0, pitch = 0, rmb = false, locked = false, saved = nil }

function F.findPlayer(query)
	local q = query:lower()
	local plrs = Players:GetPlayers()
	for _, p in ipairs(plrs) do
		if p.Name:lower() == q then return p end
	end
	for _, p in ipairs(plrs) do
		if p.DisplayName:lower() == q then return p end
	end
	for _, p in ipairs(plrs) do
		if p.Name:lower():sub(1, #q) == q or p.DisplayName:lower():sub(1, #q) == q then return p end
	end
	return nil
end

function F.reapplySpectate()
	local plr = spec.target
	if not plr then return end
	local cam = getCamera()
	local hum = plr.Character and plr.Character:FindFirstChildOfClass("Humanoid")
	if cam and hum then
		if cam.CameraType ~= Enum.CameraType.Custom then cam.CameraType = Enum.CameraType.Custom end
		if cam.CameraSubject ~= hum then cam.CameraSubject = hum end
	end
end

function F.stopSpectate()
	if not spec.target then return false end
	spec.maid:Clean()
	spec.target = nil
	local cam = getCamera()
	if cam then
		cam.CameraType = Enum.CameraType.Custom
		local hum = getHumanoid()
		if hum then cam.CameraSubject = hum end
	end
	return true
end

function F.stopFreecam()
	if not fc.active then return end
	fc.active = false
	pcall(function() RunService:UnbindFromRenderStep("AdminHub_Freecam") end)
	pcall(function() ContextActionService:UnbindAction("AdminHub_FreecamSink") end)
	fc.maid:Clean()
	if fc.locked then
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		fc.locked = false
	end
	fc.rmb = false
	local cam = getCamera()
	if cam then
		local saved = fc.saved
		cam.CameraType = (saved and saved.type ~= Enum.CameraType.Scriptable) and saved.type or Enum.CameraType.Custom
		local hum = getHumanoid()
		if saved and saved.subject and saved.subject.Parent then
			cam.CameraSubject = saved.subject
		elseif hum then
			cam.CameraSubject = hum
		end
	end
end

function F.startSpectate(plr)
	if not plr or plr == LocalPlayer then return false, "Select another player to spectate." end
	if not plr.Parent then return false, "That player has left the game." end
	local hum = plr.Character and plr.Character:FindFirstChildOfClass("Humanoid")
	if not hum then return false, plr.DisplayName .. " has no character right now." end
	local cam = getCamera()
	if not cam then return false, "No camera available." end
	if fc.active then
		state.freecam = false
		F.stopFreecam()
	end
	spec.maid:Clean()
	spec.target = plr
	cam.CameraType = Enum.CameraType.Custom
	cam.CameraSubject = hum
	spec.maid:Add(cam:GetPropertyChangedSignal("CameraSubject"):Connect(function()
		if spec.target then F.reapplySpectate() end
	end))
	return true
end

function F.startFreecam()
	if fc.active then return true end
	local cam = getCamera()
	if not cam then return false, "No camera available." end
	if spec.target then F.stopSpectate() end
	fc.saved = { type = cam.CameraType, subject = cam.CameraSubject }
	local cf = cam.CFrame
	fc.pitch, fc.yaw = cf:ToOrientation()
	fc.pos = cf.Position
	fc.active = true
	cam.CameraType = Enum.CameraType.Scriptable

	-- Sink movement keys so the character does not walk while the camera flies.
	ContextActionService:BindActionAtPriority("AdminHub_FreecamSink", function()
		return Enum.ContextActionResult.Sink
	end, false, Enum.ContextActionPriority.High.Value,
		Enum.KeyCode.W, Enum.KeyCode.A, Enum.KeyCode.S, Enum.KeyCode.D,
		Enum.KeyCode.Space, Enum.KeyCode.Q, Enum.KeyCode.E)

	fc.maid:Add(UserInputService.InputBegan:Connect(function(input, gp)
		if input.UserInputType == Enum.UserInputType.MouseButton2 and not gp then
			fc.rmb = true
			fc.locked = true
			UserInputService.MouseBehavior = Enum.MouseBehavior.LockCurrentPosition
		end
	end))
	fc.maid:Add(UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton2 then
			fc.rmb = false
			if fc.locked then
				UserInputService.MouseBehavior = Enum.MouseBehavior.Default
				fc.locked = false
			end
		end
	end))
	fc.maid:Add(UserInputService.InputChanged:Connect(function(input)
		if fc.rmb and input.UserInputType == Enum.UserInputType.MouseMovement then
			fc.yaw -= input.Delta.X * 0.004
			fc.pitch = math.clamp(fc.pitch - input.Delta.Y * 0.004, -1.45, 1.45)
		end
	end))

	RunService:BindToRenderStep("AdminHub_Freecam", Enum.RenderPriority.Camera.Value + 1, function(dt)
		local c = getCamera()
		if not c then return end
		if c.CameraType ~= Enum.CameraType.Scriptable then c.CameraType = Enum.CameraType.Scriptable end
		local function down(k) return UserInputService:IsKeyDown(k) end
		local f, s, v = 0, 0, 0
		if UserInputService:GetFocusedTextBox() == nil then
			if down(Enum.KeyCode.W) then f += 1 end
			if down(Enum.KeyCode.S) then f -= 1 end
			if down(Enum.KeyCode.D) then s += 1 end
			if down(Enum.KeyCode.A) then s -= 1 end
			if down(Enum.KeyCode.E) or down(Enum.KeyCode.Space) then v += 1 end
			if down(Enum.KeyCode.Q) or down(Enum.KeyCode.LeftControl) then v -= 1 end
		end
		local rot = CFrame.fromOrientation(fc.pitch, fc.yaw, 0)
		local dir = rot.LookVector * f + rot.RightVector * s + Vector3.yAxis * v
		if dir.Magnitude > 0 then
			local speed = settings.freeCamSpeed * (down(Enum.KeyCode.LeftShift) and 3 or 1)
			fc.pos += dir.Unit * speed * dt
		end
		c.CFrame = CFrame.new(fc.pos) * rot
	end)
	return true
end

function F.syncFreecam()
	if state.freecam then return F.startFreecam() end
	F.stopFreecam()
	return true
end

function F.resetCamera()
	state.freecam = false
	F.stopFreecam()
	F.stopSpectate()
	state.fov = false
	F.syncFov()
	local cam = getCamera()
	if cam then
		cam.CameraType = Enum.CameraType.Custom
		local hum = getHumanoid()
		if hum then cam.CameraSubject = hum end
		cam.FieldOfView = originalFov
	end
end

function F.disableAll()
	F.resetMovement()
	state.esp, state.chams, state.fullbright, state.fov = false, false, false, false
	F.syncVisuals()
	state.freecam = false
	F.stopFreecam()
	F.stopSpectate()
end

--==========================================================================
-- 5. COMMAND REGISTRY (every UI control and keybind goes through this)
--==========================================================================
local Commands = { list = {}, byId = {}, byName = {} }

local function register(def)
	table.insert(Commands.list, def)
	Commands.byId[def.id] = def
	Commands.byName[def.id] = def
	for _, a in ipairs(def.aliases or {}) do Commands.byName[a] = def end
end

local function parseBool(arg, current)
	if arg == nil then return not current end
	arg = tostring(arg):lower()
	if arg == "on" or arg == "true" or arg == "1" or arg == "enable" then return true end
	if arg == "off" or arg == "false" or arg == "0" or arg == "disable" then return false end
	return nil
end

local function toggleCommand(def, o)
	def.kind = "toggle"
	def.get = function() return state[o.state] end
	def.exec = function(args)
		local a = args[1]
		if o.valueKey and a ~= nil and tonumber(a) then
			local v, err = validateSetting(o.valueKey, a)
			if not v then return false, err end
			setSetting(o.valueKey, v)
			state[o.state] = true
			local ok, msg = o.apply(true)
			if ok == false then
				state[o.state] = false
				return false, msg
			end
			return true, ("%s enabled (%s = %s)"):format(def.title, SPEC[o.valueKey].label, Util.fmt(v, SPEC[o.valueKey].decimals))
		end
		local on = parseBool(a, state[o.state])
		if on == nil then return false, "Usage: " .. def.usage end
		state[o.state] = on
		local ok, msg = o.apply(on)
		if ok == false then
			state[o.state] = not on
			return false, msg
		end
		return true, def.title .. (on and " enabled" or " disabled")
	end
	register(def)
end

local function actionCommand(def, exec)
	def.kind = "action"
	def.exec = exec
	register(def)
end

-- Movement
toggleCommand({ id = "fly", title = "Fly", category = "Movement", bindable = true, aliases = { "flight" },
	desc = "Free flight. WASD/stick move, Space or E up, Ctrl or Q down.", usage = "fly [on|off|speed]" },
	{ state = "fly", valueKey = "flySpeed", apply = function() return F.syncFly() end })
toggleCommand({ id = "walkspeed", title = "WalkSpeed", category = "Movement", bindable = true, aliases = { "ws", "speed" },
	desc = "Locks WalkSpeed to your chosen value while enabled.", usage = "walkspeed [on|off|value]" },
	{ state = "walkspeed", valueKey = "walkSpeed", apply = function() return F.syncWalk() end })
toggleCommand({ id = "jumppower", title = "JumpPower", category = "Movement", bindable = true, aliases = { "jp", "jump" },
	desc = "Locks JumpPower to your chosen value while enabled.", usage = "jumppower [on|off|value]" },
	{ state = "jumppower", valueKey = "jumpPower", apply = function() return F.syncJump() end })
toggleCommand({ id = "noclip", title = "Noclip", category = "Movement", bindable = true, aliases = { "nc" },
	desc = "Walk through walls (client collision only).", usage = "noclip [on|off]" },
	{ state = "noclip", apply = function() return F.syncNoclip() end })
toggleCommand({ id = "infjump", title = "Infinite Jump", category = "Movement", bindable = true, aliases = { "ij", "infinitejump" },
	desc = "Jump again while in the air.", usage = "infjump [on|off]" },
	{ state = "infjump", apply = function() return F.syncInfJump() end })
actionCommand({ id = "resetmovement", title = "Reset Movement", category = "Movement", bindable = true, aliases = { "resetmove", "rm" },
	desc = "Disable movement features and restore WalkSpeed/JumpPower.", usage = "resetmovement" },
	function()
		F.resetMovement()
		return true, "Movement reset"
	end)
actionCommand({ id = "tp", title = "Teleport", category = "Movement", aliases = { "teleport", "goto" },
	desc = "Teleport your character to world coordinates.", usage = "tp <x> <y> <z>" },
	function(args)
		if #args < 3 then return false, "Usage: tp <x> <y> <z>" end
		local x, y, z = tonumber(args[1]), tonumber(args[2]), tonumber(args[3])
		if not (x and y and z) or x ~= x or y ~= y or z ~= z then
			return false, "Coordinates must be numbers. Usage: tp <x> <y> <z>"
		end
		if math.abs(x) > 1e6 or math.abs(y) > 1e6 or math.abs(z) > 1e6 then
			return false, "Coordinates must be within +/-1,000,000 studs."
		end
		return F.teleport(Vector3.new(x, y, z))
	end)

-- Visuals
register({ id = "visuals", title = "Visuals Master", category = "Visuals", bindable = true, aliases = { "master" }, kind = "toggle",
	desc = "Master switch for ESP, Chams, Fullbright and FOV.", usage = "visuals [on|off]",
	get = function() return settings.visualsMaster end,
	exec = function(args)
		local on = parseBool(args[1], settings.visualsMaster)
		if on == nil then return false, "Usage: visuals [on|off]" end
		setSetting("visualsMaster", on)
		return true, "Visual features " .. (on and "enabled" or "disabled")
	end })
toggleCommand({ id = "esp", title = "ESP", category = "Visuals", bindable = true,
	desc = "Player names and distance labels through walls.", usage = "esp [on|off]" },
	{ state = "esp", apply = function() F.syncVisuals() end })
toggleCommand({ id = "chams", title = "Chams", category = "Visuals", bindable = true, aliases = { "highlight", "hl" },
	desc = "Highlight other players' characters.", usage = "chams [on|off]" },
	{ state = "chams", apply = function() F.syncVisuals() end })
toggleCommand({ id = "fullbright", title = "Fullbright", category = "Visuals", bindable = true, aliases = { "fb", "fullb" },
	desc = "Remove darkness and fog for map testing.", usage = "fullbright [on|off]" },
	{ state = "fullbright", apply = function() F.syncFullbright() end })
toggleCommand({ id = "fov", title = "Custom FOV", category = "Visuals", bindable = true,
	desc = "Override the camera field of view.", usage = "fov [on|off|degrees]" },
	{ state = "fov", valueKey = "fov", apply = function() F.syncFov() end })

-- Players
actionCommand({ id = "spectate", title = "Spectate", category = "Players", aliases = { "spec", "view" },
	desc = "Watch a player through their camera.", usage = "spectate [player]" },
	function(args)
		local plr
		if args[1] then
			plr = F.findPlayer(args[1])
			if not plr then return false, ("No player matches '%s'."):format(args[1]) end
		else
			plr = selectedPlayer
			if not plr then return false, "Select a player in the Players tab or use: spectate <player>" end
		end
		local ok, err = F.startSpectate(plr)
		if not ok then return false, err end
		state.freecam = false
		return true, "Spectating " .. plr.DisplayName
	end)
actionCommand({ id = "unspectate", title = "Stop Spectating", category = "Players", bindable = true, aliases = { "unspec", "unview" },
	desc = "Return the camera to your own character.", usage = "unspectate" },
	function()
		if not F.stopSpectate() then return false, "You are not spectating anyone." end
		return true, "Camera restored"
	end)
actionCommand({ id = "tpto", title = "Teleport To Player", category = "Players", aliases = { "bring", "tpplayer" },
	desc = "Teleport to another player's position.", usage = "tpto [player]" },
	function(args)
		local plr
		if args[1] then
			plr = F.findPlayer(args[1])
			if not plr then return false, ("No player matches '%s'."):format(args[1]) end
		else
			plr = selectedPlayer
			if not plr then return false, "Select a player in the Players tab or use: tpto <player>" end
		end
		if plr == LocalPlayer then return false, "You are already there." end
		local theirs = plr.Character and plr.Character:FindFirstChild("HumanoidRootPart")
		local mine = getRoot()
		if not theirs then return false, plr.DisplayName .. " has no character right now." end
		if not mine then return false, "You have no character." end
		mine.CFrame = theirs.CFrame * CFrame.new(0, 0, 4)
		mine.AssemblyLinearVelocity = Vector3.zero
		return true, "Teleported to " .. plr.DisplayName
	end)
actionCommand({ id = "refreshplayers", title = "Refresh Players", category = "Players", aliases = { "refresh" },
	desc = "Rebuild the player list.", usage = "refreshplayers" },
	function()
		UI.refreshPlayers()
		return true, "Player list refreshed"
	end)

-- Extra
toggleCommand({ id = "freecam", title = "Free Camera", category = "Extra", bindable = true, aliases = { "fc" },
	desc = "Detach the camera. RMB look, WASD move, E/Q up/down, Shift boost.", usage = "freecam [on|off|speed]" },
	{ state = "freecam", valueKey = "freeCamSpeed", apply = function() return F.syncFreecam() end })
actionCommand({ id = "resetcamera", title = "Reset Camera", category = "Extra", bindable = true, aliases = { "rc", "resetcam" },
	desc = "Stop spectate/free camera, restore subject, type and FOV.", usage = "resetcamera" },
	function()
		F.resetCamera()
		return true, "Camera reset"
	end)
actionCommand({ id = "disableall", title = "Disable All Features", category = "Extra", bindable = true, aliases = { "panic" },
	desc = "Turn every feature off and restore your character and camera.", usage = "disableall" },
	function()
		F.disableAll()
		return true, "All features disabled"
	end)
actionCommand({ id = "theme", title = "Theme", category = "Extra", aliases = {},
	desc = "Switch between the dark and light theme.", usage = "theme [dark|light]" },
	function(args)
		local a = args[1] and args[1]:lower()
		local target
		if a == "dark" then target = "Dark" elseif a == "light" then target = "Light"
		elseif a == nil then target = (settings.theme == "Dark") and "Light" or "Dark"
		else return false, "Usage: theme [dark|light]" end
		setSetting("theme", target)
		return true, target .. " theme applied"
	end)
actionCommand({ id = "resetsettings", title = "Reset Settings", category = "Extra", aliases = {},
	desc = "Restore every setting, keybind and theme option to defaults.", usage = "resetsettings" },
	function()
		Store.resetAll()
		return true, "All settings restored to defaults"
	end)

Commands.categories = { "Movement", "Visuals", "Players", "Extra" }

function Commands.run(cmd, args)
	local ok, success, msg = pcall(cmd.exec, args or {})
	if not ok then
		notify(("'%s' failed: %s"):format(cmd.title, tostring(success)), "error")
		UI.refreshAll()
		return false
	end
	if success then
		notify(msg or (cmd.title .. " executed"), "success", cmd.title)
	else
		notify(msg or "Command failed.", "error", cmd.title)
	end
	UI.refreshAll()
	UI.refreshPlayers()
	return success and true or false
end

function Commands.runText(text)
	text = (tostring(text or ""):gsub(",", " "))
	local parts = {}
	for w in text:gmatch("%S+") do table.insert(parts, w) end
	if #parts == 0 then
		notify("Type a command first, e.g. 'walkspeed 40'.", "error")
		return false
	end
	local name = table.remove(parts, 1):lower()
	local cmd = Commands.byName[name]
	if not cmd then
		notify(("Unknown command '%s'. Search the Commands tab for the full list."):format(name), "error")
		return false
	end
	return Commands.run(cmd, parts)
end

--==========================================================================
-- 6. KEYBINDS
--==========================================================================
local Keys = { listening = nil, map = {} }

function Keys.rebuild()
	Keys.map = {}
	for id, keyName in pairs(settings.keybinds) do Keys.map[keyName] = id end
end

function Keys.getKey(id)
	if id == "__menu" then return settings.menuKey end
	return settings.keybinds[id]
end

local function bindLabel(id)
	if id == "__menu" then return "the menu toggle" end
	local c = Commands.byId[id]
	return c and c.title or id
end

-- Returns ok, errorMessage. keyName == nil clears the binding.
function Keys.assign(id, keyName)
	if keyName == nil then
		if id == "__menu" then return false, "The menu key cannot be cleared. Pick another key instead." end
		settings.keybinds[id] = nil
	else
		if id ~= "__menu" and keyName == settings.menuKey then
			return false, ("%s is the menu toggle key. Pick a different key."):format(keyName)
		end
		for otherId, k in pairs(settings.keybinds) do
			if otherId ~= id and k == keyName then
				return false, ("%s is already bound to %s."):format(keyName, bindLabel(otherId))
			end
		end
		if id == "__menu" then settings.menuKey = keyName else settings.keybinds[id] = keyName end
	end
	Keys.rebuild()
	Store.save()
	return true
end

function Keys.listen(id)
	Keys.listening = id
	UI.refreshAll()
end
function Keys.cancel()
	Keys.listening = nil
	UI.refreshAll()
end
function Keys.restoreDefaults()
	settings.keybinds = Util.deepCopy(DEFAULTS.keybinds)
	settings.menuKey = DEFAULTS.menuKey
	Keys.rebuild()
	Store.save()
	UI.refreshAll()
end
Keys.rebuild()

--==========================================================================
-- 7. UI COMPONENT LIBRARY
--==========================================================================
function UI.refreshAll(force)
	for _, fn in ipairs(UI.refreshers) do pcall(fn, force) end
end

function UI.beginDrag(d)
	UI.drag = d
end

-- Rows ------------------------------------------------------------------------------
local function makeRow(parent, bare)
	local row = new("Frame", {
		Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = bare and 1 or 0, BorderSizePixel = 0, LayoutOrder = nextOrder(parent), Parent = parent,
	}, { new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder }) })
	if not bare then
		bindTheme(row, { BackgroundColor3 = "element" })
		corner(8).Parent = row
		stroke("stroke").Parent = row
	end
	return row
end

local function makeHeader(row, title, desc, controlWidth, order)
	local header = new("Frame", { Size = UDim2.new(1, 0, 0, desc and 50 or 40), BackgroundTransparency = 1, LayoutOrder = order or 1, Parent = row })
	local titleLabel = label({
		Text = title, Font = Enum.Font.GothamMedium, TextSize = 14,
		Position = UDim2.fromOffset(12, desc and 7 or 0), Size = UDim2.new(1, -(controlWidth + 28), 0, desc and 18 or 40),
		TextTruncate = Enum.TextTruncate.AtEnd, Parent = header,
	})
	if desc then
		label({
			Text = desc, TextSize = 12, Position = UDim2.fromOffset(12, 26), Size = UDim2.new(1, -(controlWidth + 28), 0, 16),
			TextTruncate = Enum.TextTruncate.AtEnd, Parent = header,
		}, "subtext")
	end
	local holder = new("Frame", {
		AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -12, 0.5, 0),
		Size = UDim2.fromOffset(controlWidth, 28), BackgroundTransparency = 1, Parent = header,
	})
	return header, holder, titleLabel
end

function UI.section(parent, text)
	local l = label({
		Text = string.upper(text), Font = Enum.Font.GothamBold, TextSize = 12, Size = UDim2.new(1, 0, 0, 24),
		LayoutOrder = nextOrder(parent), Parent = parent,
	}, "subtext")
	new("UIPadding", { PaddingTop = UDim.new(0, 6), Parent = l })
	return l
end

function UI.addNote(parent, text)
	return label({
		Text = text, TextSize = 12, TextWrapped = true, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = nextOrder(parent), Parent = parent,
	}, "subtext")
end

-- Buttons -------------------------------------------------------------------------------
function UI.makeButton(parent, text, w, h, style, onClick)
	local b = new("TextButton", {
		Text = text, Font = Enum.Font.GothamMedium, TextSize = 13, AutoButtonColor = false,
		Size = UDim2.fromOffset(w, h), BorderSizePixel = 0, Parent = parent,
	}, { corner(6) })
	local function base()
		if style == "accent" then return settings.accent end
		if style == "danger" then return STATUS.error end
		return color("hover")
	end
	local function hov()
		if style == "accent" then return settings.accent:Lerp(WHITE, 0.2) end
		if style == "danger" then return STATUS.error:Lerp(WHITE, 0.2) end
		return color("track")
	end
	if style == "accent" then
		bindTheme(b, { BackgroundColor3 = "accent" })
		b.TextColor3 = WHITE
	elseif style == "danger" then
		b.BackgroundColor3 = STATUS.error
		b.TextColor3 = WHITE
	else
		bindTheme(b, { BackgroundColor3 = "hover", TextColor3 = "text" })
	end
	b.MouseEnter:Connect(function() Util.tween(b, { BackgroundColor3 = hov() }, 0.12) end)
	b.MouseLeave:Connect(function() Util.tween(b, { BackgroundColor3 = base() }, 0.12) end)
	if onClick then b.Activated:Connect(function() onClick(b) end) end
	return b
end

function UI.addButton(parent, title, desc, buttonText, style, onClick)
	local row = makeRow(parent)
	local _, holder = makeHeader(row, title, desc, 120, 1)
	local b = UI.makeButton(holder, buttonText, 120, 28, style, onClick)
	return row, b
end

function UI.addButtonRow(parent, buttons)
	local row = new("Frame", { Size = UDim2.new(1, 0, 0, 32), BackgroundTransparency = 1, LayoutOrder = nextOrder(parent), Parent = parent }, {
		new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }),
	})
	for i, b in ipairs(buttons) do
		local btn = UI.makeButton(row, b.text, b.width or 120, 32, b.style or "neutral", b.onClick)
		btn.LayoutOrder = i
	end
	return row
end

-- Toggle -----------------------------------------------------------------------------------
function UI.makeSwitch(holder, get, set)
	local track = new("TextButton", {
		Text = "", AutoButtonColor = false, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.fromScale(1, 0.5),
		Size = UDim2.fromOffset(44, 24), BackgroundColor3 = color("track"), BorderSizePixel = 0, Parent = holder,
	}, { corner(12) })
	local knob = new("Frame", {
		Size = UDim2.fromOffset(18, 18), Position = UDim2.fromOffset(3, 3), BackgroundColor3 = WHITE, BorderSizePixel = 0, Parent = track,
	}, { corner(9) })
	local last
	local function refresh(force)
		local on = get() and true or false
		if on == last and not force then return end
		last = on
		Util.tween(track, { BackgroundColor3 = on and settings.accent or color("track") }, 0.16)
		Util.tween(knob, { Position = on and UDim2.fromOffset(23, 3) or UDim2.fromOffset(3, 3) }, 0.16)
	end
	track.Activated:Connect(function()
		set(not get())
		UI.refreshAll()
	end)
	table.insert(UI.refreshers, refresh)
	refresh(true)
	return refresh
end

function UI.addToggle(parent, title, desc, get, set)
	local row = makeRow(parent)
	local _, holder = makeHeader(row, title, desc, 48, 1)
	UI.makeSwitch(holder, get, set)
	return row
end

-- Slider (+ typed input) -----------------------------------------------------------------
function UI.addSlider(parent, cfg)
	local decimals = cfg.decimals or 0
	local row = makeRow(parent, cfg.bare)
	local _, holder = makeHeader(row, cfg.title, cfg.desc, 74, 1)
	local box = new("TextBox", {
		Size = UDim2.fromScale(1, 1), Text = "", Font = Enum.Font.GothamMedium, TextSize = 13,
		ClearTextOnFocus = false, BorderSizePixel = 0, Parent = holder,
	}, { corner(6) })
	bindTheme(box, { BackgroundColor3 = "hover", TextColor3 = "text" })

	local body = new("Frame", { Size = UDim2.new(1, 0, 0, 26), BackgroundTransparency = 1, LayoutOrder = 2, Parent = row })
	local track = new("Frame", { Size = UDim2.new(1, -24, 0, 6), Position = UDim2.new(0, 12, 0.5, -3), BorderSizePixel = 0, Parent = body }, { corner(3) })
	bindTheme(track, { BackgroundColor3 = "track" })
	local fill = new("Frame", { Size = UDim2.fromScale(0, 1), BorderSizePixel = 0, Parent = track }, { corner(3) })
	bindTheme(fill, { BackgroundColor3 = "accent" })
	local knob = new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(16, 16), Position = UDim2.fromScale(0, 0.5),
		BackgroundColor3 = WHITE, BorderSizePixel = 0, ZIndex = 2, Parent = track,
	}, { corner(8), stroke("stroke") })
	local hit = new("TextButton", { Text = "", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = body })

	local dragValue
	local function show(v)
		local rel = math.clamp((v - cfg.min) / (cfg.max - cfg.min), 0, 1)
		fill.Size = UDim2.fromScale(rel, 1)
		knob.Position = UDim2.fromScale(rel, 0.5)
		if not box:IsFocused() then box.Text = Util.fmt(v, decimals) end
	end
	local function refresh()
		show(dragValue or cfg.get())
	end
	local function valueFromX(x)
		local rel = math.clamp((x - track.AbsolutePosition.X) / math.max(track.AbsoluteSize.X, 1), 0, 1)
		local v = cfg.min + rel * (cfg.max - cfg.min)
		v = Util.round(v - cfg.min, cfg.step) + cfg.min
		return math.clamp(v, cfg.min, cfg.max)
	end
	local function onPointer(x)
		local v = valueFromX(x)
		if cfg.deferred then
			dragValue = v
			show(v)
		else
			cfg.set(v)
			show(v)
		end
	end
	hit.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			onPointer(input.Position.X)
			UI.beginDrag({
				update = function(pos) onPointer(pos.X) end,
				finish = function()
					if cfg.deferred and dragValue then
						local v = dragValue
						dragValue = nil
						cfg.set(v)
					end
					UI.refreshAll()
				end,
			})
		end
	end)
	box.FocusLost:Connect(function()
		local n = tonumber(box.Text)
		if not n or n ~= n then
			notify(("'%s' is not a number."):format(box.Text), "error", cfg.title)
		elseif n < cfg.min or n > cfg.max then
			notify(("%s must be between %s and %s."):format(cfg.title, Util.fmt(cfg.min, decimals), Util.fmt(cfg.max, decimals)), "error")
		else
			cfg.set(n)
		end
		UI.refreshAll()
	end)
	table.insert(UI.refreshers, refresh)
	refresh()
	return row
end

function UI.settingSlider(parent, key, title, desc)
	local spec = SPEC[key]
	return UI.addSlider(parent, {
		title = title or spec.label, desc = desc, min = spec.min, max = spec.max, step = spec.step,
		decimals = spec.decimals, deferred = spec.deferred,
		get = function() return settings[key] end,
		set = function(v) setSetting(key, v) end,
	})
end

-- Dropdown -------------------------------------------------------------------------------
function UI.addDropdown(parent, cfg)
	local row = makeRow(parent)
	local _, holder = makeHeader(row, cfg.title, cfg.desc, 120, 1)
	local body = new("Frame", {
		Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1,
		Visible = false, LayoutOrder = 2, Parent = row,
	}, { new("UIListLayout", { Padding = UDim.new(0, 4) }), padding(12, 0, 12, 10) })
	local btn = UI.makeButton(holder, "", 120, 28, "neutral", function()
		body.Visible = not body.Visible
	end)
	for _, opt in ipairs(cfg.options) do
		UI.makeButton(body, opt, 100, 28, "neutral", function()
			body.Visible = false
			cfg.set(opt)
			UI.refreshAll()
		end).Size = UDim2.new(1, 0, 0, 28)
	end
	table.insert(UI.refreshers, function() btn.Text = tostring(cfg.get()) end)
	btn.Text = tostring(cfg.get())
	return row
end

-- Color picker (HSV sliders + presets) ----------------------------------------------------------
local PRESET_COLORS = {
	Color3.fromRGB(255, 255, 255), Color3.fromRGB(235, 87, 87), Color3.fromRGB(255, 159, 67), Color3.fromRGB(254, 202, 87),
	Color3.fromRGB(76, 196, 120), Color3.fromRGB(46, 213, 215), Color3.fromRGB(90, 140, 255), Color3.fromRGB(155, 107, 255),
	Color3.fromRGB(255, 107, 190),
}

function UI.addColorPicker(parent, cfg)
	local row = makeRow(parent)
	local _, holder = makeHeader(row, cfg.title, cfg.desc, 52, 1)
	local swatch = new("TextButton", {
		Text = "", AutoButtonColor = false, Size = UDim2.fromOffset(52, 26), Position = UDim2.fromOffset(0, 1),
		BorderSizePixel = 0, Parent = holder,
	}, { corner(6), stroke("stroke") })
	local body = new("Frame", {
		Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, Visible = false,
		LayoutOrder = 2, Parent = row,
	}, { new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder }), padding(0, 0, 0, 8) })
	swatch.Activated:Connect(function() body.Visible = not body.Visible end)

	local hsv = { cfg.get():ToHSV() }
	local function sync()
		local c = cfg.get()
		local cur = Color3.fromHSV(hsv[1], hsv[2], hsv[3])
		if math.abs(c.R - cur.R) + math.abs(c.G - cur.G) + math.abs(c.B - cur.B) > 0.02 then
			hsv = { c:ToHSV() }
		end
		swatch.BackgroundColor3 = c
	end
	local function push()
		local c = Color3.fromHSV(hsv[1], hsv[2], hsv[3])
		cfg.set(c)
		swatch.BackgroundColor3 = c
	end
	for i, spec in ipairs({ { "Hue", 360 }, { "Saturation", 100 }, { "Brightness", 100 } }) do
		UI.addSlider(body, {
			title = spec[1], bare = true, min = 0, max = spec[2], step = 1, decimals = 0,
			get = function() sync() return hsv[i] * spec[2] end,
			set = function(v) hsv[i] = v / spec[2] push() end,
		})
	end
	local presets = new("Frame", {
		Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, LayoutOrder = 10, Parent = body,
	}, {
		new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Wraps = true, Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }),
		padding(12, 4, 12, 0),
	})
	for i, c in ipairs(PRESET_COLORS) do
		local p = new("TextButton", {
			Text = "", AutoButtonColor = false, Size = UDim2.fromOffset(22, 22), BackgroundColor3 = c, BorderSizePixel = 0,
			LayoutOrder = i, Parent = presets,
		}, { corner(11), stroke("stroke") })
		p.Activated:Connect(function()
			hsv = { c:ToHSV() }
			push()
			UI.refreshAll()
		end)
	end
	table.insert(UI.refreshers, sync)
	sync()
	return row
end

-- Text input with buttons ----------------------------------------------------------------------
function UI.addInput(parent, cfg)
	local row = makeRow(parent)
	makeHeader(row, cfg.title, cfg.desc, 0, 1)
	local total = 0
	for _, b in ipairs(cfg.buttons) do total += b.width + 8 end
	local body = new("Frame", { Size = UDim2.new(1, 0, 0, 40), BackgroundTransparency = 1, LayoutOrder = 2, Parent = row }, {
		new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }),
		padding(12, 0, 12, 10),
	})
	local box = new("TextBox", {
		Size = UDim2.new(1, -total, 1, 0), Text = "", PlaceholderText = cfg.placeholder or "", Font = Enum.Font.Gotham,
		TextSize = 13, ClearTextOnFocus = false, TextXAlignment = Enum.TextXAlignment.Left, BorderSizePixel = 0, LayoutOrder = 0, Parent = body,
	}, { corner(6), padding(8, 0, 8, 0) })
	bindTheme(box, { BackgroundColor3 = "hover", TextColor3 = "text", PlaceholderColor3 = "subtext" })
	for i, b in ipairs(cfg.buttons) do
		local btn = UI.makeButton(body, b.text, b.width, 30, b.style or "neutral", function() b.onClick(box) end)
		btn.LayoutOrder = i
		btn.Size = UDim2.fromOffset(b.width, 30)
	end
	box.FocusLost:Connect(function(enter)
		if enter and cfg.onEnter then cfg.onEnter(box) end
	end)
	return row, box
end

-- Keybind row -----------------------------------------------------------------------------------
function UI.addKeybind(parent, id, title, desc)
	local row = makeRow(parent)
	local _, holder = makeHeader(row, title, desc, 144, 1)
	local keyBtn = UI.makeButton(holder, "", 98, 28, "neutral", function()
		if Keys.listening == id then Keys.cancel() else Keys.listen(id) end
	end)
	local clearBtn = UI.makeButton(holder, "x", 40, 28, "neutral", function()
		if Keys.listening then
			Keys.cancel()
		else
			local ok, err = Keys.assign(id, nil)
			if not ok then notify(err, "error", "Keybind") else notify(title .. " keybind cleared.", "info", "Keybind") end
			UI.refreshAll()
		end
	end)
	clearBtn.Position = UDim2.fromOffset(104, 0)
	table.insert(UI.refreshers, function()
		local listening = (Keys.listening == id)
		keyBtn.Text = listening and "Press a key..." or (Keys.getKey(id) or "None")
		clearBtn.Text = listening and "Esc" or "x"
	end)
	return row
end

-- Command row (used by the Commands tab / search) ------------------------------------------------
function UI.addCommandRow(parent, cmd)
	local row = makeRow(parent)
	local header = new("Frame", { Size = UDim2.new(1, 0, 0, 64), BackgroundTransparency = 1, LayoutOrder = 1, Parent = row })
	local titleLabel = label({
		Text = cmd.title, Font = Enum.Font.GothamMedium, TextSize = 14, Position = UDim2.fromOffset(12, 6),
		Size = UDim2.new(1, -100, 0, 18), Parent = header,
	})
	label({
		Text = cmd.desc, TextSize = 12, Position = UDim2.fromOffset(12, 26), Size = UDim2.new(1, -100, 0, 16),
		TextTruncate = Enum.TextTruncate.AtEnd, Parent = header,
	}, "subtext")
	label({
		Text = "Usage: " .. cmd.usage, Font = Enum.Font.Code, TextSize = 11, Position = UDim2.fromOffset(12, 44),
		Size = UDim2.new(1, -100, 0, 14), TextTruncate = Enum.TextTruncate.AtEnd, Parent = header,
	}, "subtext")
	local holder = new("Frame", {
		AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -12, 0.5, 0), Size = UDim2.fromOffset(60, 28),
		BackgroundTransparency = 1, Parent = header,
	})
	if cmd.kind == "toggle" then
		UI.makeSwitch(holder, cmd.get, function(on) Commands.run(cmd, { on and "on" or "off" }) end)
	else
		UI.makeButton(holder, "Run", 60, 28, "accent", function() Commands.run(cmd, {}) end).Position = UDim2.fromOffset(0, 0)
	end
	table.insert(UI.refreshers, function()
		local k = Keys.getKey(cmd.id)
		titleLabel.Text = cmd.title .. (k and ("   [" .. k .. "]") or "")
	end)
	return row
end

-- Shared option groups (used on both feature pages and the Settings page) -------------------------
function UI.addEspOptions(parent)
	UI.addToggle(parent, "Show names", "Display player names on ESP labels",
		function() return settings.espShowNames end, function(v) setSetting("espShowNames", v) end)
	UI.addToggle(parent, "Show distance", "Display distance in studs on ESP labels",
		function() return settings.espShowDistance end, function(v) setSetting("espShowDistance", v) end)
	UI.settingSlider(parent, "espTextSize", "ESP text size")
	UI.settingSlider(parent, "espMaxDistance", "ESP max distance", "Labels farther than this are hidden")
	UI.addColorPicker(parent, { title = "ESP color", desc = "Label color",
		get = function() return settings.espColor end, set = function(c) setSetting("espColor", c) end })
end

function UI.addChamsOptions(parent)
	UI.addColorPicker(parent, { title = "Chams fill color", desc = "Fill color of highlighted characters",
		get = function() return settings.chamsFill end, set = function(c) setSetting("chamsFill", c) end })
	UI.addColorPicker(parent, { title = "Chams outline color", desc = "Outline color of highlighted characters",
		get = function() return settings.chamsOutline end, set = function(c) setSetting("chamsOutline", c) end })
	UI.settingSlider(parent, "chamsFillTransparency", "Chams fill transparency")
end

local function cmdToggle(parent, id)
	local cmd = Commands.byId[id]
	return UI.addToggle(parent, cmd.title, cmd.desc, cmd.get, function(on) Commands.run(cmd, { on and "on" or "off" }) end)
end

--==========================================================================
-- 8. MAIN WINDOW
--==========================================================================
local W, H, TOP, SIDE = CONFIG.WindowWidth, CONFIG.WindowHeight, CONFIG.TopBarHeight, CONFIG.SidebarWidth

local holder = new("Frame", {
	Name = "Holder", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromScale(0.5, 0.1),
	Size = UDim2.fromOffset(W, H), BackgroundTransparency = 1, Visible = false, Parent = gui,
})
local holderScale = new("UIScale", { Parent = holder })

local window = new("CanvasGroup", {
	Name = "Window", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.fromScale(1, 1), GroupTransparency = 1, BorderSizePixel = 0, Parent = holder,
}, { corner(14), stroke("stroke") })
local windowScale = new("UIScale", { Scale = 0.92, Parent = window })
bindTheme(window, { BackgroundColor3 = "bg" })
transparentTargets[window] = true

local topBar = new("Frame", { Name = "TopBar", Size = UDim2.new(1, 0, 0, TOP), BorderSizePixel = 0, Parent = window })
bindTheme(topBar, { BackgroundColor3 = "sidebar" })
transparentTargets[topBar] = true

local logo = new("Frame", { Size = UDim2.fromOffset(18, 18), Position = UDim2.fromOffset(14, 14), BorderSizePixel = 0, Parent = topBar }, { corner(5) })
bindTheme(logo, { BackgroundColor3 = "accent" })
label({ Text = "ADMIN HUB", Font = Enum.Font.GothamBold, TextSize = 15, Position = UDim2.fromOffset(40, 0), Size = UDim2.fromOffset(160, TOP), Parent = topBar })

local dragZone = new("Frame", { Size = UDim2.new(1, -520, 1, 0), Position = UDim2.fromOffset(190, 0), BackgroundTransparency = 1, Active = true, Parent = topBar })

local search = new("TextBox", {
	Size = UDim2.fromOffset(220, 28), AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -86, 0.5, 0),
	Text = "", PlaceholderText = "Search commands...", Font = Enum.Font.Gotham, TextSize = 13, ClearTextOnFocus = false,
	TextXAlignment = Enum.TextXAlignment.Left, BorderSizePixel = 0, Parent = topBar,
}, { corner(8), padding(10, 0, 10, 0), stroke("stroke") })
bindTheme(search, { BackgroundColor3 = "element", TextColor3 = "text", PlaceholderColor3 = "subtext" })

local minBtn = UI.makeButton(topBar, "-", 28, 28, "neutral", function() UI.setMinimized(not UI.minimized) end)
minBtn.AnchorPoint = Vector2.new(1, 0.5)
minBtn.Position = UDim2.new(1, -46, 0.5, 0)
local closeBtn = UI.makeButton(topBar, "x", 28, 28, "danger", function() UI.setOpen(false) end)
closeBtn.AnchorPoint = Vector2.new(1, 0.5)
closeBtn.Position = UDim2.new(1, -12, 0.5, 0)

local body = new("Frame", {
	Name = "Body", Position = UDim2.fromOffset(0, TOP), Size = UDim2.new(1, 0, 1, -TOP), BackgroundTransparency = 1, Parent = window,
})
local sidebar = new("Frame", { Size = UDim2.new(0, SIDE, 1, 0), BorderSizePixel = 0, Parent = body }, {
	new("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }),
	padding(10, 12, 10, 10),
})
bindTheme(sidebar, { BackgroundColor3 = "sidebar" })
transparentTargets[sidebar] = true

local content = new("Frame", {
	Position = UDim2.fromOffset(SIDE, 0), Size = UDim2.new(1, -SIDE, 1, 0), BackgroundTransparency = 1, ClipsDescendants = true, Parent = body,
})

-- Responsive scaling / positioning
function UI.updateScale()
	local s = screenSize()
	local maxScale = math.min(s.X / (W + 24), s.Y / (H + 24))
	local base = math.min(1, maxScale)
	local final = math.max(math.min(base * settings.uiScale, maxScale), 0.35)
	holderScale.Scale = final
	toastScale.Scale = math.clamp(base, 0.6, 1)
end
function UI.centerWindow()
	local s = screenSize()
	holder.Position = UDim2.fromScale(0.5, math.max(0.02, (s.Y - H * holderScale.Scale) / 2 / s.Y))
end

-- Open / close / minimise
local openToken = 0
function UI.setOpen(open)
	if UI.isOpen == open then return end
	UI.isOpen = open
	openToken += 1
	local token = openToken
	if open then
		holder.Visible = true
		Util.tween(window, { GroupTransparency = 0 }, 0.22)
		Util.tween(windowScale, { Scale = 1 }, 0.28, Enum.EasingStyle.Back)
	else
		if Keys.listening then Keys.cancel() end
		local tw = Util.tween(window, { GroupTransparency = 1 }, 0.18)
		Util.tween(windowScale, { Scale = 0.92 }, 0.18)
		tw.Completed:Connect(function()
			if openToken == token and not UI.isOpen then holder.Visible = false end
		end)
	end
end
function UI.toggleOpen() UI.setOpen(not UI.isOpen) end

local minToken = 0
function UI.setMinimized(min)
	UI.minimized = min
	minToken += 1
	local token = minToken
	if min then
		local tw = Util.tween(holder, { Size = UDim2.fromOffset(W, TOP) }, 0.22)
		tw.Completed:Connect(function()
			if minToken == token and UI.minimized then body.Visible = false end
		end)
	else
		body.Visible = true
		Util.tween(holder, { Size = UDim2.fromOffset(W, H) }, 0.25, Enum.EasingStyle.Back)
	end
end

-- Dragging the window (works with mouse and touch; position stored as screen fraction)
dragZone.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		local startPos = Vector2.new(input.Position.X, input.Position.Y)
		local startTop = Vector2.new(holder.AbsolutePosition.X + holder.AbsoluteSize.X / 2, holder.AbsolutePosition.Y)
		UI.beginDrag({
			update = function(pos)
				local s = screenSize()
				local c = startTop + (Vector2.new(pos.X, pos.Y) - startPos)
				c = Vector2.new(math.clamp(c.X, 60, s.X - 60), math.clamp(c.Y, 0, s.Y - 40))
				holder.Position = UDim2.fromScale(c.X / s.X, c.Y / s.Y)
			end,
		})
	end
end)

-- Pages & navigation
local PAGE_NAMES = { "Movement", "Visuals", "Players", "Extra", "Commands", "Settings" }

for i, name in ipairs(PAGE_NAMES) do
	local page = new("ScrollingFrame", {
		Name = name, Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 4,
		CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollingDirection = Enum.ScrollingDirection.Y,
		Visible = false, Parent = content,
	}, {
		new("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }),
		padding(12, 8, 16, 14),
	})
	bindTheme(page, { ScrollBarImageColor3 = "subtext" })
	UI.pages[name] = page

	local btn = new("TextButton", {
		Text = "", AutoButtonColor = false, Size = UDim2.new(1, 0, 0, 36), BackgroundTransparency = 1, BorderSizePixel = 0,
		LayoutOrder = i, Parent = sidebar,
	}, { corner(8) })
	local bar = new("Frame", { Size = UDim2.fromOffset(3, 18), Position = UDim2.new(0, 0, 0.5, -9), BackgroundTransparency = 1, BorderSizePixel = 0, Parent = btn }, { corner(2) })
	bindTheme(bar, { BackgroundColor3 = "accent" })
	local txt = label({ Text = name, Font = Enum.Font.GothamMedium, TextSize = 14, Position = UDim2.fromOffset(14, 0), Size = UDim2.new(1, -14, 1, 0), Parent = btn }, "subtext")
	UI.navButtons[name] = { btn = btn, bar = bar, txt = txt }
	btn.MouseEnter:Connect(function()
		if UI.currentPage ~= name then Util.tween(btn, { BackgroundTransparency = 0.6 }, 0.12) end
	end)
	btn.MouseLeave:Connect(function()
		if UI.currentPage ~= name then Util.tween(btn, { BackgroundTransparency = 1 }, 0.12) end
	end)
	btn.Activated:Connect(function() UI.navigate(name) end)
	bindTheme(btn, { BackgroundColor3 = "hover" })
end

local menuHint = label({
	Text = "", TextSize = 11, Size = UDim2.new(1, 0, 0, 30), LayoutOrder = 100, TextWrapped = true, Parent = sidebar,
}, "subtext")
table.insert(UI.refreshers, function() menuHint.Text = "Toggle menu: " .. settings.menuKey end)

function UI.switchPage(name)
	if UI.currentPage == name then return end
	UI.currentPage = name
	for pname, page in pairs(UI.pages) do
		local nav = UI.navButtons[pname]
		local active = (pname == name)
		page.Visible = active
		Util.tween(nav.btn, { BackgroundTransparency = active and 0 or 1 }, 0.15)
		Util.tween(nav.bar, { BackgroundTransparency = active and 0 or 1 }, 0.15)
		nav.txt.TextColor3 = active and color("text") or color("subtext")
		themedObjects[nav.txt].TextColor3 = active and "text" or "subtext"
		if active then
			page.Position = UDim2.fromOffset(0, 12)
			Util.tween(page, { Position = UDim2.fromOffset(0, 0) }, 0.22)
		end
	end
	UI.refreshAll()
end
function UI.navigate(name)
	UI.prevPage = nil
	UI.switchPage(name)
end

--==========================================================================
-- 9. PAGES
--==========================================================================
-- Movement ------------------------------------------------------------------------------------
do
	local pg = UI.pages.Movement
	UI.section(pg, "Flight")
	cmdToggle(pg, "fly")
	UI.settingSlider(pg, "flySpeed", "Fly speed", "Studs per second while flying")
	UI.section(pg, "Speed and jumping")
	cmdToggle(pg, "walkspeed")
	UI.settingSlider(pg, "walkSpeed", "WalkSpeed value", "Editable: drag or type a value")
	cmdToggle(pg, "jumppower")
	UI.settingSlider(pg, "jumpPower", "JumpPower value", "Editable: drag or type a value")
	UI.section(pg, "Collision and air control")
	cmdToggle(pg, "noclip")
	cmdToggle(pg, "infjump")
	UI.section(pg, "Utilities")
	UI.addButton(pg, "Reset movement", "Disable movement features and restore defaults", "Reset", "neutral", function()
		Commands.run(Commands.byId.resetmovement, {})
	end)
	UI.addInput(pg, {
		title = "Teleport to coordinates", desc = "Enter X Y Z in studs (spaces or commas)", placeholder = "0 50 0",
		onEnter = function(box) Commands.runText("tp " .. box.Text) end,
		buttons = {
			{ text = "Teleport", width = 86, style = "accent", onClick = function(box) Commands.runText("tp " .. box.Text) end },
			{ text = "My position", width = 100, style = "neutral", onClick = function(box)
				local r = getRoot()
				if r then
					local p = r.Position
					box.Text = ("%d %d %d"):format(math.floor(p.X), math.floor(p.Y), math.floor(p.Z))
				else
					notify("No character to read a position from.", "error")
				end
			end },
		},
	})
end

-- Visuals ----------------------------------------------------------------------------------------
do
	local pg = UI.pages.Visuals
	UI.section(pg, "Master")
	cmdToggle(pg, "visuals")
	UI.section(pg, "ESP")
	cmdToggle(pg, "esp")
	UI.addEspOptions(pg)
	UI.section(pg, "Chams")
	cmdToggle(pg, "chams")
	UI.addChamsOptions(pg)
	UI.section(pg, "World and camera")
	cmdToggle(pg, "fullbright")
	cmdToggle(pg, "fov")
	UI.settingSlider(pg, "fov", "Field of view value", "Degrees (applies while Custom FOV is on)")
end

-- Players ------------------------------------------------------------------------------------------
do
	local pg = UI.pages.Players
	UI.section(pg, "Players in this server")
	UI.playerList = new("Frame", {
		Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1,
		LayoutOrder = nextOrder(pg), Parent = pg,
	}, { new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }) })
	UI.section(pg, "Actions for the selected player")
	UI.addButtonRow(pg, {
		{ text = "Spectate", width = 110, style = "accent", onClick = function()
			Commands.run(Commands.byId.spectate, selectedPlayer and { selectedPlayer.Name } or {})
		end },
		{ text = "Stop", width = 80, style = "neutral", onClick = function() Commands.run(Commands.byId.unspectate, {}) end },
		{ text = "Teleport to", width = 110, style = "neutral", onClick = function()
			Commands.run(Commands.byId.tpto, selectedPlayer and { selectedPlayer.Name } or {})
		end },
		{ text = "Refresh", width = 90, style = "neutral", onClick = function() Commands.run(Commands.byId.refreshplayers, {}) end },
	})
	UI.addButton(pg, "Reset camera", "Stop spectating / free camera and restore the camera", "Reset", "neutral", function()
		Commands.run(Commands.byId.resetcamera, {})
	end)
	UI.addNote(pg, "The list updates automatically when players join or leave. Spectating follows a player through respawns and stops if they leave.")
end

function UI.refreshPlayers()
	local lf = UI.playerList
	if not lf then return end
	for _, c in ipairs(lf:GetChildren()) do
		if c:IsA("GuiObject") then c:Destroy() end
	end
	if selectedPlayer and not selectedPlayer.Parent then selectedPlayer = nil end
	local plrs = Players:GetPlayers()
	table.sort(plrs, function(a, b) return a.Name:lower() < b.Name:lower() end)
	for i, p in ipairs(plrs) do
		local selected = (selectedPlayer == p)
		local btn = new("TextButton", {
			Text = "", AutoButtonColor = false, Size = UDim2.new(1, 0, 0, 44), BorderSizePixel = 0, LayoutOrder = i, Parent = lf,
		}, { corner(8) })
		bindTheme(btn, { BackgroundColor3 = selected and "hover" or "element" })
		stroke(selected and "accent" or "stroke").Parent = btn
		local av = new("Frame", { Size = UDim2.fromOffset(28, 28), Position = UDim2.fromOffset(10, 8), BorderSizePixel = 0, Parent = btn }, { corner(14) })
		bindTheme(av, { BackgroundColor3 = "accent" })
		new("TextLabel", {
			BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Text = string.upper(p.DisplayName:sub(1, 1)),
			Font = Enum.Font.GothamBold, TextSize = 14, TextColor3 = WHITE, Parent = av,
		})
		label({
			Text = p.DisplayName .. (p == LocalPlayer and " (you)" or ""), Font = Enum.Font.GothamMedium, TextSize = 14,
			Position = UDim2.fromOffset(48, 5), Size = UDim2.new(1, -160, 0, 18), TextTruncate = Enum.TextTruncate.AtEnd, Parent = btn,
		})
		label({
			Text = "@" .. p.Name, TextSize = 12, Position = UDim2.fromOffset(48, 23), Size = UDim2.new(1, -160, 0, 16),
			TextTruncate = Enum.TextTruncate.AtEnd, Parent = btn,
		}, "subtext")
		if spec.target == p then
			label({
				Text = "SPECTATING", Font = Enum.Font.GothamBold, TextSize = 11, AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, -12, 0.5, 0), Size = UDim2.fromOffset(90, 16), TextXAlignment = Enum.TextXAlignment.Right, Parent = btn,
			}, "accent")
		end
		btn.Activated:Connect(function()
			selectedPlayer = p
			UI.refreshPlayers()
		end)
	end
end

-- Extra -------------------------------------------------------------------------------------------------
do
	local pg = UI.pages.Extra
	UI.section(pg, "Free camera")
	cmdToggle(pg, "freecam")
	UI.settingSlider(pg, "freeCamSpeed", "Free camera speed", "Hold Shift for a 3x boost")
	UI.addNote(pg, "Free camera controls: hold right mouse to look, WASD to move, E/Space up, Q/Ctrl down. Desktop only.")
	UI.addButton(pg, "Reset camera", "Restore camera subject, type and field of view", "Reset camera", "neutral", function()
		Commands.run(Commands.byId.resetcamera, {})
	end)
	UI.section(pg, "Safety")
	UI.addButton(pg, "Disable all features", "Turn everything off and restore your character", "Disable all", "danger", function()
		Commands.run(Commands.byId.disableall, {})
	end)
	UI.section(pg, "Command console")
	UI.addInput(pg, {
		title = "Run a command", desc = "Examples: walkspeed 40 | fly 100 | tp 0 50 0 | spectate Bob | theme light",
		placeholder = "Type a command and press Enter",
		onEnter = function(box)
			if box.Text ~= "" then Commands.runText(box.Text) box.Text = "" end
		end,
		buttons = { { text = "Run", width = 70, style = "accent", onClick = function(box)
			if box.Text ~= "" then Commands.runText(box.Text) box.Text = "" end
		end } },
	})
end

-- Commands (list + search) ---------------------------------------------------------------------------
do
	local pg = UI.pages.Commands
	UI.addNote(pg, "Every command, its description and usage. Use the search bar above to filter instantly. Bound keys are shown in brackets.")
	for _, cat in ipairs(Commands.categories) do
		local header = UI.section(pg, cat)
		local group = { header = header, rows = {} }
		for _, cmd in ipairs(Commands.list) do
			if cmd.category == cat then
				local row = UI.addCommandRow(pg, cmd)
				local hay = (cmd.id .. " " .. cmd.title .. " " .. cmd.desc .. " " .. cmd.category .. " " .. table.concat(cmd.aliases or {}, " ")):lower()
				table.insert(group.rows, { row = row, hay = hay })
			end
		end
		table.insert(UI.cmdRows, group)
	end
end

function UI.filterCommands(query)
	local q = query:lower():gsub("^%s+", ""):gsub("%s+$", "")
	for _, group in ipairs(UI.cmdRows) do
		local any = false
		for _, r in ipairs(group.rows) do
			local match = (q == "") or (r.hay:find(q, 1, true) ~= nil)
			r.row.Visible = match
			if match then any = true end
		end
		group.header.Visible = any
	end
end

search:GetPropertyChangedSignal("Text"):Connect(function()
	local q = search.Text
	if q ~= "" and UI.currentPage ~= "Commands" then
		UI.prevPage = UI.currentPage
		UI.switchPage("Commands")
	elseif q == "" and UI.prevPage then
		local p = UI.prevPage
		UI.prevPage = nil
		UI.switchPage(p)
	end
	UI.filterCommands(q)
end)

-- Settings -------------------------------------------------------------------------------------------------
do
	local pg = UI.pages.Settings

	UI.section(pg, "Appearance")
	UI.addDropdown(pg, { title = "Theme", desc = "Applies instantly", options = { "Dark", "Light" },
		get = function() return settings.theme end, set = function(v) setSetting("theme", v) end })
	UI.addColorPicker(pg, { title = "Accent color", desc = "Custom accent used across the interface",
		get = function() return settings.accent end, set = function(c) setSetting("accent", c) end })
	UI.settingSlider(pg, "transparency", "Window transparency", "Background transparency of the window")
	UI.settingSlider(pg, "uiScale", "UI scale", "Applied when you release the slider")
	UI.settingSlider(pg, "animSpeed", "Animation speed", "Higher is faster")
	UI.settingSlider(pg, "notifDuration", "Notification duration", "Seconds a notification stays on screen")

	UI.section(pg, "Feature settings")
	UI.settingSlider(pg, "flySpeed", "Fly speed")
	UI.settingSlider(pg, "walkSpeed", "WalkSpeed value")
	UI.settingSlider(pg, "jumpPower", "JumpPower value")
	UI.settingSlider(pg, "fov", "Field of view value")
	UI.settingSlider(pg, "freeCamSpeed", "Free camera speed")
	UI.addEspOptions(pg)
	UI.addChamsOptions(pg)

	UI.section(pg, "Keybinds")
	UI.addNote(pg, "Click a key button, then press a key. Esc cancels, Backspace clears. Conflicting keys are rejected with a message.")
	UI.addKeybind(pg, "__menu", "Menu toggle", "Opens and closes this window")
	for _, cmd in ipairs(Commands.list) do
		if cmd.bindable then UI.addKeybind(pg, cmd.id, cmd.title, cmd.kind == "toggle" and "Toggles this feature" or "Runs this command") end
	end
	UI.addButton(pg, "Restore default keybinds", "Resets the menu key and every command keybind", "Restore", "neutral", function()
		Keys.restoreDefaults()
		notify("Keybinds restored to defaults.", "success", "Keybinds")
	end)

	UI.section(pg, "Configuration")
	local status = UI.addNote(pg, "")
	table.insert(UI.refreshers, function()
		if Store.hasFile then
			status.Text = "Persistence: saving to file '" .. CONFIG.SaveFileName .. "'." .. (Store.lastError and (" Last error: " .. Store.lastError) or "")
		else
			status.Text = "Persistence: file storage is unavailable here, so settings are kept in memory for this session only."
		end
	end)
	UI.addButton(pg, "Save settings now", "Write the current settings immediately", "Save", "neutral", function()
		Store.flush()
		notify(Store.hasFile and "Settings saved." or "Settings stored for this session (no file access).", Store.lastError and "error" or "success", "Settings")
		UI.refreshAll()
	end)
	local resetArmed = false
	local _, resetBtn = UI.addButton(pg, "Reset to defaults", "Restore all settings, theme and keybinds (click twice)", "Reset all", "danger", function(b)
		if not resetArmed then
			resetArmed = true
			b.Text = "Confirm?"
			task.delay(3, function()
				if resetArmed and b.Parent then
					resetArmed = false
					b.Text = "Reset all"
				end
			end)
			return
		end
		resetArmed = false
		b.Text = "Reset all"
		Commands.run(Commands.byId.resetsettings, {})
	end)
	UI.addButton(pg, "Unload Admin Hub", "Disable all features, restore everything and remove the UI", "Unload", "danger", function()
		if genv.__AdminHubCleanup then genv.__AdminHubCleanup() end
	end)
end

--==========================================================================
-- 10. SETTING CHANGE HANDLERS + APPLY-ALL
--==========================================================================
onChange.theme = applyTheme
onChange.accent = applyTheme
onChange.transparency = applyTheme
onChange.uiScale = function() UI.updateScale() end
onChange.walkSpeed = function() if state.walkspeed then F.syncWalk() end end
onChange.jumpPower = function() if state.jumppower then F.syncJump() end end
onChange.fov = function() if state.fov then F.syncFov() end end
onChange.visualsMaster = function() F.syncVisuals() end
for _, key in ipairs({ "espColor", "espTextSize", "espMaxDistance", "espShowNames", "espShowDistance",
	"chamsFill", "chamsOutline", "chamsFillTransparency" }) do
	onChange[key] = function() F.restyleVisuals() end
end

function UI.applyAll()
	applyTheme()
	UI.updateScale()
	Keys.rebuild()
	F.syncWalk()
	F.syncJump()
	F.syncVisuals()
	UI.centerWindow()
	UI.refreshAll(true)
end

function Store.resetAll()
	for k in pairs(settings) do settings[k] = nil end
	for k, v in pairs(Util.deepCopy(DEFAULTS)) do settings[k] = v end
	UI.applyAll()
	Store.save()
end

--==========================================================================
-- 11. INPUT HANDLING (menu key, command keybinds, rebinding, drags)
--==========================================================================
mainMaid:Add(UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
	if Keys.listening then
		if UserInputService:GetFocusedTextBox() then return end
		local id = Keys.listening
		local kc = input.KeyCode
		if kc == Enum.KeyCode.Escape then
			Keys.cancel()
			notify("Rebind cancelled.", "info", "Keybind")
		elseif kc == Enum.KeyCode.Backspace or kc == Enum.KeyCode.Delete then
			local ok, err = Keys.assign(id, nil)
			Keys.listening = nil
			notify(ok and "Keybind cleared." or err, ok and "info" or "error", "Keybind")
			UI.refreshAll()
		elseif kc ~= Enum.KeyCode.Unknown then
			local ok, err = Keys.assign(id, kc.Name)
			Keys.listening = nil
			if ok then
				notify(("%s bound to %s."):format(bindLabel(id):gsub("^%l", string.upper), kc.Name), "success", "Keybind")
			else
				notify(err, "error", "Keybind conflict")
			end
			UI.refreshAll()
		end
		return
	end
	if gameProcessed then return end
	local name = input.KeyCode.Name
	if name == settings.menuKey then
		UI.toggleOpen()
		return
	end
	local id = Keys.map[name]
	local cmd = id and Commands.byId[id]
	if cmd then Commands.run(cmd, {}) end
end))

mainMaid:Add(UserInputService.InputChanged:Connect(function(input)
	local d = UI.drag
	if d and d.update and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
		d.update(input.Position)
	end
end))
mainMaid:Add(UserInputService.InputEnded:Connect(function(input)
	local d = UI.drag
	if d and (input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch) then
		UI.drag = nil
		if d.finish then d.finish() end
	end
end))

mainMaid:Add(gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function() UI.updateScale() end))

--==========================================================================
-- 12. PLAYER TRACKING, CHARACTER RESPAWN HANDLING
--==========================================================================
local playerMaids = {}

local function trackPlayer(plr)
	if plr == LocalPlayer or playerMaids[plr] then return end
	local m = Maid.new()
	playerMaids[plr] = m
	m:Add(plr.CharacterAdded:Connect(function(char)
		task.spawn(function()
			char:WaitForChild("HumanoidRootPart", 10)
			char:WaitForChild("Humanoid", 10)
			if not alive or plr.Character ~= char then return end
			F.buildVisualsFor(plr)
			if spec.target == plr then F.reapplySpectate() end
			UI.refreshPlayers()
		end)
	end))
	m:Add(plr.CharacterRemoving:Connect(function()
		F.destroyVisualsFor(plr)
	end))
	if plr.Character then F.buildVisualsFor(plr) end
end

local function untrackPlayer(plr)
	F.destroyVisualsFor(plr)
	local m = playerMaids[plr]
	if m then m:Clean() playerMaids[plr] = nil end
	if spec.target == plr then
		F.stopSpectate()
		notify(plr.DisplayName .. " left; camera restored.", "info", "Spectate")
	end
	if selectedPlayer == plr then selectedPlayer = nil end
end

mainMaid:Add(Players.PlayerAdded:Connect(function(plr)
	trackPlayer(plr)
	UI.refreshPlayers()
end))
mainMaid:Add(Players.PlayerRemoving:Connect(function(plr)
	untrackPlayer(plr)
	task.defer(UI.refreshPlayers)
end))
for _, plr in ipairs(Players:GetPlayers()) do trackPlayer(plr) end

local function onCharacterAdded(char)
	charMaid:Clean()
	task.spawn(function()
		local hum = char:WaitForChild("Humanoid", 10)
		local root = char:WaitForChild("HumanoidRootPart", 10)
		if not alive or not hum or not root or LocalPlayer.Character ~= char then return end
		F.syncWalk()
		F.syncJump()
		if state.fly then
			local ok, err = F.syncFly()
			if ok == false then notify(err, "error", "Fly") end
		end
		if state.noclip then F.syncNoclip() end
		if spec.target then F.reapplySpectate() end
		charMaid:Add(hum.Died:Connect(function()
			if fly.active then F.stopFly() end -- state stays on; fly resumes on respawn
		end))
	end)
end
mainMaid:Add(LocalPlayer.CharacterAdded:Connect(onCharacterAdded))
if LocalPlayer.Character then onCharacterAdded(LocalPlayer.Character) end

mainMaid:Add(Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
	F.syncFov()
	if spec.target then
		-- camera object was replaced; re-establish the spectate watcher on the new camera
		local plr = spec.target
		F.stopSpectate()
		F.startSpectate(plr)
	end
end))

--==========================================================================
-- 13. CLEANUP + INITIALISATION
--==========================================================================
local function cleanup()
	if not alive then return end
	pcall(Store.flush)
	pcall(F.disableAll) -- restores WalkSpeed/JumpPower, lighting, FOV, camera, collisions
	alive = false
	Keys.listening = nil
	UI.drag = nil
	mainMaid:Clean()
	charMaid:Clean()
	for plr, m in pairs(playerMaids) do m:Clean() playerMaids[plr] = nil end
	for _, m in ipairs({ walkMaid, jumpMaid, fly.maid, noclip.maid, infMaid, vis.loop, fb.maid, fovState.maid, spec.maid, fc.maid }) do
		m:Clean()
	end
	if vis.folder then vis.folder:Destroy() end
	if gui then gui:Destroy() end
	if genv.__AdminHubCleanup == cleanup then genv.__AdminHubCleanup = nil end
end
genv.__AdminHubCleanup = cleanup

-- Build the initial view
applyTheme()
UI.updateScale()
UI.centerWindow()
UI.filterCommands("")
UI.refreshPlayers()
UI.switchPage("Movement")
UI.refreshAll(true)
task.defer(function()
	if not alive then return end
	UI.updateScale()
	UI.centerWindow()
	UI.setOpen(true)
	notify("Loaded. Press " .. settings.menuKey .. " to show or hide the hub.", "success", "Admin Hub")
end)
