--!nocheck
--[[
    Knife VS Gun Duels — Cheat Suite (Delta / Fluxus / Codex)
    Single-file, no external require.

    Требования к экзекутору:
      MUST:  hookmetamethod, getrawmetatable, checkcaller, getnamecallmethod, gethui|CoreGui
      GOOD:  Drawing, mouse1click, mouse1press/mouse1release, identifyexecutor, setclipboard
      SOFT:  Drawing отсутствует -> скелет-ESP отключится, остальное работает.
             hookmetamethod отсутствует -> Silent Aim отключится, Rage переключится на CFrame.

    Known limitations (не враньё):
      - Silent Aim меняет аргументы ЛЮБОГО remote'а, у которого Vector3/CFrame-аргумент.
        В играх, где тот же remote тащит позицию движения — будет ломать. Юзай "Dump Remotes"
        и RemoteFilter, чтобы ограничить по имени.
      - Anti-Aim — это Motor6D (Neck) + AutoRotate=false. Полноценный серверный desync
        в Roblox невозможен. Голова/шея крутится у всех, кто видит твой персонаж, но
        hitbox по ногам/торсу не сдвигается.
      - Bhop WalkSpeed/JumpPower — сервер может срезать. В KVSG обычно не валидируется,
        но если срезает — не баг скрипта.
      - Ambience восстанавливается на Unload по сохранённым оригиналам, не по хардкоду.

    Юзать на свой страх. Unload — кнопка в UI или вызови _G.KVSG_Unload().
]]

local Players        = game:GetService("Players")
local RunService     = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService   = game:GetService("TweenService")
local Lighting       = game:GetService("Lighting")
local VirtualInputManager = game:GetService("VirtualInputManager")

local LP = Players.LocalPlayer
if not LP then return end

-- ==== EXECUTOR DETECT ====
local function getExecName()
    local ok, n = pcall(function()
        if identifyexecutor then return identifyexecutor() end
        if getexecutorname then return getexecutorname() end
        if syn and syn.getexecutorname then return syn.getexecutorname() end
        return "Unknown"
    end)
    return ok and tostring(n) or "Unknown"
end
local EXEC = getExecName()

local hasHookMM      = type(hookmetamethod) == "function" and type(getrawmetatable) == "function"
local hasCheckCaller = type(checkcaller) == "function"
local hasDrawing     = pcall(function() local d = Drawing.new("Line"); d:Remove() end)
local hasMouseClick  = type(mouse1click) == "function"
local hasMousePress  = type(mouse1press) == "function" and type(mouse1release) == "function"

-- ==== GAME CHECK ====
local function isTargetGame()
    local n = tostring(game.Name):lower()
    return n:find("knife") ~= nil and n:find("gun") ~= nil
end
if not isTargetGame() then
    warn(("[KVSG] Not Knife VS Gun Duels (game.Name=%q). Aborting."):format(game.Name))
    return
end
warn(("[KVSG] Loaded | exec=%s | hookMM=%s | drawing=%s"):format(EXEC, tostring(hasHookMM), tostring(hasDrawing)))

-- ==== CONFIG ====
local Config = {
    Rage = {
        Enabled = false, Mode = "CFrame", TargetMode = "FOV",
        FOV = 200, Smoothing = 0.35, Prediction = 60,
        WallCheck = false, TeamCheck = true,
        AutoFire = false, AutoFireDelay = 0.08,
        RemoteFilter = "",
    },
    AntiAim = {
        Enabled = false, Mode = "Jitter", Speed = 90, StaticAngle = 180,
    },
    Bhop = {
        Enabled = false, WalkSpeed = 16, JumpPower = 50,
        AirStrafe = false, AntiFall = false,
    },
    ESP = {
        Enabled = false, Highlight = true, Name = true,
        Health = true, Skeleton = false, MaxDistance = 500,
        FillTransparency = 0.5,
    },
    Ambience = {
        Enabled = false, Brightness = 2, ClockTime = 14,
        FogStart = 0, FogEnd = 10000, Exposure = 0,
        Bloom = false, ColorCorrection = false, Saturation = 0, Contrast = 0,
        Sky = "Default", FOV = 70,
    },
}

-- ==== STATE ====
local State = {
    conns      = {},
    esp        = {},        -- [Player] = {highlight, billboard, lines, headRef}
    aaOrig     = {c0=nil, c1=nil, humAuto=true},
    ambOrig    = nil,
    hooks      = {},
    ui         = nil,
    unloaded   = false,
    lastClick  = 0,
    lastAA     = 0,
    lastAARand = 0,
    aaRandAng  = 0,
    drawingLines = {},      -- черновик для скелета (глобальные Drawing.Line)
}

local function track(conn) table.insert(State.conns, conn); return conn end
local function safe(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then warn("[KVSG] " .. tostring(err)) end
    return ok, err
end

-- ==== TARGET SELECTION ====
local function hasLineOfSight(targetPart)
    local cam = workspace.CurrentCamera
    if not cam or not targetPart then return false end
    local origin = cam.CFrame.Position
    local dir    = targetPart.Position - origin
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    local ignore = {}
    for _, p in ipairs(Players:GetPlayers()) do
        if p.Character then table.insert(ignore, p.Character) end
    end
    params.FilterDescendantsInstances = ignore
    local hit = workspace:Raycast(origin, dir, params)
    return hit == nil
end

local function getRageTarget()
    local cam = workspace.CurrentCamera
    if not cam or not LP.Character then return nil end
    local vpSize = cam.ViewportSize
    local center = Vector2.new(vpSize.X / 2, vpSize.Y / 2)
    local best, bestScore = nil, math.huge

    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LP and p.Character then
            local char = p.Character
            local hum  = char:FindFirstChildOfClass("Humanoid")
            local hrp  = char:FindFirstChild("HumanoidRootPart")
            local head = char:FindFirstChild("Head")
            local skip = false
            if not hum or hum.Health <= 0 or not hrp or not head then skip = true end
            if not skip and Config.Rage.TeamCheck and LP.Team and p.Team and LP.Team == p.Team then skip = true end
            if not skip then
                local sp, onScreen = cam:WorldToViewportPoint(head.Position)
                if onScreen then
                    local dist = (Vector2.new(sp.X, sp.Y) - center).Magnitude
                    if dist <= Config.Rage.FOV then
                        local los = (not Config.Rage.WallCheck) or hasLineOfSight(head)
                        if los then
                            local score
                            if Config.Rage.TargetMode == "FOV" then
                                score = dist
                            elseif Config.Rage.TargetMode == "Health" then
                                score = hum.Health
                            else
                                local lph = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
                                score = lph and (hrp.Position - lph.Position).Magnitude or dist
                            end
                            if score < bestScore then
                                bestScore, best = score, p
                            end
                        end
                    end
                end
            end
        end
    end
    return best
end

local function getAimPart(player)
    if not player or not player.Character then return nil end
    return player.Character:FindFirstChild("Head") or player.Character:FindFirstChild("HumanoidRootPart")
end

-- ==== ESP ====
local espGui = nil
local function ensureEspGui()
    if espGui and espGui.Parent then return espGui end
    espGui = Instance.new("ScreenGui")
    espGui.Name = "KVSG_ESP"
    espGui.ResetOnSpawn = false
    espGui.IgnoreGuiInset = true
    espGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    local parent = (gethui and gethui()) or (pcall(function() return game:GetService("CoreGui") end) and game:GetService("CoreGui")) or LP:WaitForChild("PlayerGui")
    espGui.Parent = parent
    return espGui
end

local function createHighlight(char, color)
    local h = Instance.new("Highlight")
    h.Name = "KVSG_HL"
    h.FillColor = color
    h.FillTransparency = Config.ESP.FillTransparency
    h.OutlineColor = Color3.fromRGB(255, 255, 255)
    h.OutlineTransparency = 0
    h.Adornee = char
    h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    h.Parent = ensureEspGui()
    return h
end

local function createBillboard(head)
    local bb = Instance.new("BillboardGui")
    bb.Name = "KVSG_BB"
    bb.Adornee = head
    bb.Size = UDim2.fromOffset(200, 40)
    bb.StudsOffset = Vector3.new(0, 2.5, 0)
    bb.AlwaysOnTop = true
    bb.Parent = ensureEspGui()

    local nameLbl = Instance.new("TextLabel")
    nameLbl.Name = "NameLbl"
    nameLbl.BackgroundTransparency = 1
    nameLbl.Size = UDim2.new(1, 0, 0, 16)
    nameLbl.TextColor3 = Color3.fromRGB(255, 255, 255)
    nameLbl.TextStrokeTransparency = 0.3
    nameLbl.Font = Enum.Font.GothamBold
    nameLbl.TextSize = 13
    nameLbl.Parent = bb

    local hpBack = Instance.new("Frame")
    hpBack.Name = "HpBack"
    hpBack.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
    hpBack.BorderSizePixel = 0
    hpBack.Size = UDim2.fromOffset(120, 4)
    hpBack.Position = UDim2.new(0.5, -60, 1, -6)
    hpBack.Parent = bb

    local hpFill = Instance.new("Frame")
    hpFill.Name = "HpFill"
    hpFill.BackgroundColor3 = Color3.fromRGB(90, 220, 90)
    hpFill.BorderSizePixel = 0
    hpFill.Size = UDim2.fromScale(1, 1)
    hpFill.Parent = hpBack

    return bb
end

local R15_BONES = {
    {"Head","UpperTorso"},{"UpperTorso","LowerTorso"},
    {"UpperTorso","LeftUpperArm"},{"LeftUpperArm","LeftLowerArm"},{"LeftLowerArm","LeftHand"},
    {"UpperTorso","RightUpperArm"},{"RightUpperArm","RightLowerArm"},{"RightLowerArm","RightHand"},
    {"LowerTorso","LeftUpperLeg"},{"LeftUpperLeg","LeftLowerLeg"},{"LeftLowerLeg","LeftFoot"},
    {"LowerTorso","RightUpperLeg"},{"RightUpperLeg","RightLowerLeg"},{"RightLowerLeg","RightFoot"},
}
local R6_BONES = {
    {"Head","Torso"},{"Torso","Left Arm"},{"Torso","Right Arm"},
    {"Torso","Left Leg"},{"Torso","Right Leg"},
}

local function ensureSkeleton(player, data)
    if not hasDrawing or not Config.ESP.Skeleton then return end
    if data.lines then return end
    local char = player.Character
    if not char then return end
    local isR15 = char:FindFirstChild("UpperTorso") ~= nil
    local bones = isR15 and R15_BONES or R6_BONES
    data.lines = {}
    for i = 1, #bones do
        local line = Drawing.new("Line")
        line.Thickness = 1
        line.Color = Color3.fromRGB(255, 90, 90)
        line.Transparency = 0.7
        line.Visible = false
        data.lines[i] = line
    end
    data.bones = bones
end

local function ensureESP(player)
    if player == LP then return end
    local data = State.esp[player]
    local char = player.Character
    if not char then return end
    local head = char:FindFirstChild("Head")
    if not head then return end
    if not data then
        data = {}
        State.esp[player] = data
    end
    if Config.ESP.Highlight and (not data.highlight or not data.highlight.Parent) then
        data.highlight = createHighlight(char, Color3.fromRGB(255, 70, 70))
    end
    if (Config.ESP.Name or Config.ESP.Health) and (not data.billboard or not data.billboard.Parent) then
        data.billboard = createBillboard(head)
    end
    ensureSkeleton(player, data)
    data.char = char
    data.head = head
end

local function removeESP(player)
    local data = State.esp[player]
    if not data then return end
    if data.highlight then data.highlight:Destroy() end
    if data.billboard  then data.billboard:Destroy() end
    if data.lines then
        for _, l in ipairs(data.lines) do pcall(function() l:Remove() end) end
    end
    State.esp[player] = nil
end

local function updateESP()
    if not Config.ESP.Enabled then
        for p in pairs(State.esp) do removeESP(p) end
        return
    end
    local cam = workspace.CurrentCamera
    local lph = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
    for player, data in pairs(State.esp) do
        local char = player.Character
        if not char or not data.head or not data.head.Parent then
            removeESP(player)
        else
            local hrp = char:FindFirstChild("HumanoidRootPart")
            local hum = char:FindFirstChildOfClass("Humanoid")
            local dist = (lph and hrp) and (hrp.Position - lph.Position).Magnitude or 0
            local inRange = dist <= Config.ESP.MaxDistance
            -- highlight
            if data.highlight then
                data.highlight.Enabled = inRange and Config.ESP.Highlight
                data.highlight.FillTransparency = Config.ESP.FillTransparency
            end
            -- billboard
            if data.billboard then
                data.billboard.Enabled = inRange and (Config.ESP.Name or Config.ESP.Health)
                local nameLbl = data.billboard:FindFirstChild("NameLbl")
                local hpBack  = data.billboard:FindFirstChild("HpBack")
                local hpFill  = hpBack and hpBack:FindFirstChild("HpFill")
                if nameLbl then
                    nameLbl.Visible = Config.ESP.Name
                    nameLbl.Text = player.Name .. (" [%d]"):format(math.floor(dist))
                end
                if hpBack and hpFill then
                    hpBack.Visible = Config.ESP.Health
                    if hum and hum.MaxHealth > 0 then
                        local frac = math.clamp(hum.Health / hum.MaxHealth, 0, 1)
                        hpFill.Size = UDim2.fromScale(frac, 1)
                        hpFill.BackgroundColor3 = Color3.fromRGB(
                            255 * (1 - frac) + 90 * frac,
                            90 + 130 * frac,
                            90 * (1 - frac) + 90 * frac
                        )
                    end
                end
            end
            -- skeleton
            if data.lines and cam then
                local visible = Config.ESP.Skeleton and inRange
                if not visible then
                    for _, l in ipairs(data.lines) do l.Visible = false end
                else
                    for i, bonePair in ipairs(data.bones) do
                        local a = char:FindFirstChild(bonePair[1])
                        local b = char:FindFirstChild(bonePair[2])
                        local line = data.lines[i]
                        if not line then break end
                        if a and b then
                            local sa, oa = cam:WorldToViewportPoint(a.Position)
                            local sb, ob = cam:WorldToViewportPoint(b.Position)
                            if oa and ob then
                                line.From = Vector2.new(sa.X, sa.Y)
                                line.To   = Vector2.new(sb.X, sb.Y)
                                line.Visible = true
                            else
                                line.Visible = false
                            end
                        else
                            line.Visible = false
                        end
                    end
                end
            end
        end
    end
end

-- ==== SILENT AIM HOOK ====
local function remoteMatches(name)
    local f = Config.Rage.RemoteFilter
    if f == nil or f == "" then return true end
    return tostring(name):lower():find(tostring(f):lower(), 1, true) ~= nil
end

local function installSilentAim()
    if not hasHookMM or not hasCheckCaller then
        warn("[KVSG] Silent Aim unavailable: no hookmetamethod/checkcaller. Forcing CFrame mode.")
        Config.Rage.Mode = "CFrame"
        return
    end
    local old
    old = hookmetamethod(game, "__namecall", function(self, ...)
        local method = getnamecallmethod()
        if method == "FireServer" or method == "InvokeServer" then
            if not checkcaller()
               and Config.Rage.Enabled and Config.Rage.Mode == "Silent"
               and (self:IsA("RemoteEvent") or self:IsA("RemoteFunction")
                    or self.ClassName == "UnreliableRemoteEvent")
               and remoteMatches(self.Name) then
                local target = getRageTarget()
                local aimPart = getAimPart(target)
                if aimPart then
                    local args = table.pack(...)
                    local modified = false
                    for i = 1, args.n do
                        local a = args[i]
                        local t = typeof(a)
                        if t == "Vector3" then
                            args[i] = aimPart.Position; modified = true
                        elseif t == "CFrame" then
                            args[i] = CFrame.new(aimPart.Position); modified = true
                        end
                    end
                    if modified then
                        return old(self, table.unpack(args, 1, args.n))
                    end
                end
            end
        end
        return old(self, ...)
    end)
    State.hooks.namecall = old
end

-- ==== CFrame AIM + AUTOFIRE ====
local function doClick()
    if hasMouseClick then mouse1click()
    elseif hasMousePress then mouse1press(); task.wait(0.02); mouse1release()
    else
        local mp = UserInputService:GetMouseLocation()
        pcall(function()
            VirtualInputManager:SendMouseButtonEvent(mp.X, mp.Y, 0, true, game, 0)
        end)
        task.wait(0.02)
        pcall(function()
            VirtualInputManager:SendMouseButtonEvent(mp.X, mp.Y, 0, false, game, 0)
        end)
    end
end

local function rageFrame()
    if not Config.Rage.Enabled then return end
    if Config.Rage.Mode ~= "CFrame" then return end
    local target = getRageTarget()
    if not target then return end
    local aimPart = getAimPart(target)
    if not aimPart then return end
    local cam = workspace.CurrentCamera
    if not cam then return end

    local aimPos = aimPart.Position
    if Config.Rage.Prediction > 0 and target.Character then
        local hrp = target.Character:FindFirstChild("HumanoidRootPart")
        if hrp then
            aimPos = aimPos + hrp.AssemblyLinearVelocity * (Config.Rage.Prediction / 1000)
        end
    end
    local desired = CFrame.new(cam.CFrame.Position, aimPos)
    local sm = math.clamp(Config.Rage.Smoothing, 0, 0.99)
    cam.CFrame = cam.CFrame:Lerp(desired, 1 - sm)

    if Config.Rage.AutoFire and (tick() - State.lastClick) >= Config.Rage.AutoFireDelay then
        State.lastClick = tick()
        doClick()
    end
end

-- ==== ANTI-AIM ====
local function getNeck(char)
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if not hum then return nil end
    local torso = char:FindFirstChild("UpperTorso") or char:FindFirstChild("Torso")
    if not torso then return nil end
    return torso:FindFirstChild("Neck")
end

local function antiAimFrame()
    local char = LP.Character
    if not char then return end
    local hum = char:FindFirstChildOfClass("Humanoid")
    local neck = getNeck(char)
    if not hum or not neck then return end

    if not State.aaOrig.c0 then
        State.aaOrig.c0 = neck.C0
        State.aaOrig.c1 = neck.C1
        State.aaOrig.humAuto = hum.AutoRotate
    end

    if not Config.AntiAim.Enabled then
        hum.AutoRotate = State.aaOrig.humAuto
        neck.C0 = State.aaOrig.c0
        neck.C1 = State.aaOrig.c1
        return
    end

    hum.AutoRotate = false

    local angle = 0
    local mode = Config.AntiAim.Mode
    if mode == "Spin" then
        angle = (tick() * Config.AntiAim.Speed) % 360
    elseif mode == "Jitter" then
        angle = (math.sin(tick() * 12) > 0) and 90 or -90
    elseif mode == "Random" then
        if (tick() - State.lastAARand) > 0.15 then
            State.lastAARand = tick()
            State.aaRandAng = math.random(-180, 180)
        end
        angle = State.aaRandAng
    elseif mode == "Static" then
        angle = Config.AntiAim.StaticAngle
    end

    neck.C0 = State.aaOrig.c0 * CFrame.Angles(0, math.rad(angle), 0)
end

-- ==== BHOP ====
local function bhopFrame()
    local char = LP.Character
    if not char then return end
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not hum then return end
    if not Config.Bhop.Enabled then return end

    hum.WalkSpeed = Config.Bhop.WalkSpeed
    if hum.UseJumpPower then
        hum.JumpPower = Config.Bhop.JumpPower
    else
        hum.JumpHeight = Config.Bhop.JumpPower
    end

    local st = hum:GetState()
    if st == Enum.HumanoidStateType.Landed or st == Enum.HumanoidStateType.Running then
        hum.Jump = true
    end

    if Config.Bhop.AntiFall and st == Enum.HumanoidStateType.Freefall then
        local hrp = char:FindFirstChild("HumanoidRootPart")
        if hrp then
            hrp.AssemblyLinearVelocity = Vector3.new(hrp.AssemblyLinearVelocity.X, 0, hrp.AssemblyLinearVelocity.Z)
        end
    end

    if Config.Bhop.AirStrafe and st == Enum.HumanoidStateType.Freefall then
        local hrp = char:FindFirstChild("HumanoidRootPart")
        if hrp then
            local dir = hum.MoveDirection
            if dir.Magnitude > 0.01 then
                local v = hrp.AssemblyLinearVelocity
                local add = dir * 3
                local newV = Vector3.new(v.X + add.X, v.Y, v.Z + add.Z)
                if newV.Magnitude < 60 then
                    hrp.AssemblyLinearVelocity = newV
                end
            end
        end
    end
end

-- ==== AMBIENCE ====
local function saveAmbienceOrig()
    if State.ambOrig then return end
    State.ambOrig = {
        Brightness = Lighting.Brightness,
        ClockTime = Lighting.ClockTime,
        FogStart = Lighting.FogStart,
        FogEnd = Lighting.FogEnd,
        FogColor = Lighting.FogColor,
        Ambient = Lighting.Ambient,
        OutdoorAmbient = Lighting.OutdoorAmbient,
        ExposureCompensation = Lighting.ExposureCompensation,
        GlobalShadows = Lighting.GlobalShadows,
    }
    local atm = Lighting:FindFirstChildOfClass("Atmosphere")
    if atm then
        State.ambOrig.Atmo = {
            Density = atm.Density, Haze = atm.Haze,
            Glare = atm.Glare, Color = atm.Color,
        }
        State.ambOrig.AtmoRef = atm
    end
    local sky = Lighting:FindFirstChildOfClass("Sky")
    if sky then
        State.ambOrig.Sky = {
            Bk = sky.SkyboxBk, Dn = sky.SkyboxDn, Ft = sky.SkyboxFt,
            Lf = sky.SkyboxLf, Rt = sky.SkyboxRt, Up = sky.SkyboxUp,
            StarCount = sky.StarCount, SunAngularSize = sky.SunAngularSize,
        }
        State.ambOrig.SkyRef = sky
    end
end

local function getOrMake(class, parent)
    local inst = parent:FindFirstChildOfClass(class)
    if not inst then
        inst = Instance.new(class)
        inst.Parent = parent
    end
    return inst
end

local SKY_PRESETS = {
    Default = {Bk="rbxasset://sky/sky_bk_basic.png"},
    Night   = {Bk="rbxasset://sky/sky_bk_night.png"},
}

local function applyAmbience()
    if not Config.Ambience.Enabled then
        if State.ambOrig then
            local o = State.ambOrig
            Lighting.Brightness = o.Brightness
            Lighting.ClockTime = o.ClockTime
            Lighting.FogStart = o.FogStart
            Lighting.FogEnd = o.FogEnd
            Lighting.FogColor = o.FogColor
            Lighting.Ambient = o.Ambient
            Lighting.OutdoorAmbient = o.OutdoorAmbient
            Lighting.ExposureCompensation = o.ExposureCompensation
            Lighting.GlobalShadows = o.GlobalShadows
            if o.Atmo and o.AtmoRef then
                o.AtmoRef.Density = o.Atmo.Density
                o.AtmoRef.Haze = o.Atmo.Haze
                o.AtmoRef.Glare = o.Atmo.Glare
                o.AtmoRef.Color = o.Atmo.Color
            end
            if o.Sky and o.SkyRef then
                for k, v in pairs({Bk=o.Sky.Bk,Dn=o.Sky.Dn,Ft=o.Sky.Ft,Lf=o.Sky.Lf,Rt=o.Sky.Rt,Up=o.Sky.Up}) do
                    pcall(function() o.SkyRef["Skybox"..k] = v end)
                end
                o.SkyRef.StarCount = o.Sky.StarCount
                o.SkyRef.SunAngularSize = o.Sky.SunAngularSize
            end
        end
        return
    end
    saveAmbienceOrig()
    local o = State.ambOrig

    Lighting.Brightness = Config.Ambience.Brightness
    Lighting.ClockTime = Config.Ambience.ClockTime
    Lighting.FogStart = Config.Ambience.FogStart
    Lighting.FogEnd = Config.Ambience.FogEnd
    Lighting.ExposureCompensation = Config.Ambience.Exposure

    -- post fx
    if Config.Ambience.Bloom then
        local b = getOrMake("BloomEffect", Lighting)
        b.Intensity = 0.7; b.Size = 24; b.Threshold = 1.2
    else
        for _, e in ipairs(Lighting:GetChildren()) do
            if e:IsA("BloomEffect") then e:Destroy() end
        end
    end
    if Config.Ambience.ColorCorrection then
        local cc = getOrMake("ColorCorrectionEffect", Lighting)
        cc.Saturation = Config.Ambience.Saturation
        cc.Contrast = Config.Ambience.Contrast
    else
        for _, e in ipairs(Lighting:GetChildren()) do
            if e:IsA("ColorCorrectionEffect") then e:Destroy() end
        end
    end
    -- fov
    local cam = workspace.CurrentCamera
    if cam then cam.FieldOfView = Config.Ambience.FOV end
end

-- ==== UI ====
local function resolveParent()
    local ok, hui = pcall(function() return gethui and gethui() end)
    if ok and hui then return hui end
    local ok2, cg = pcall(function() return game:GetService("CoreGui") end)
    if ok2 and cg then return cg end
    return LP:WaitForChild("PlayerGui")
end

local function addToggle(parent, label, cfg, key, order)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, 0, 0, 30)
    row.BackgroundColor3 = Color3.fromRGB(32, 32, 40)
    row.BorderSizePixel = 0
    row.LayoutOrder = order or 0
    row.Parent = parent
    Instance.new("UICorner", row).CornerRadius = UDim.new(0, 6)

    local lbl = Instance.new("TextLabel")
    lbl.Text = label
    lbl.Size = UDim2.new(1, -56, 1, 0)
    lbl.Position = UDim2.fromOffset(10, 0)
    lbl.BackgroundTransparency = 1
    lbl.TextColor3 = Color3.fromRGB(220, 220, 230)
    lbl.Font = Enum.Font.Gotham
    lbl.TextSize = 13
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.Parent = row

    local btn = Instance.new("TextButton")
    btn.Size = UDim2.fromOffset(36, 18)
    btn.Position = UDim2.new(1, -46, 0.5, -9)
    btn.BackgroundColor3 = cfg[key] and Color3.fromRGB(80, 160, 100) or Color3.fromRGB(50, 50, 65)
    btn.BorderSizePixel = 0
    btn.Text = ""
    btn.AutoButtonColor = false
    btn.Parent = row
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 9)

    local knob = Instance.new("Frame")
    knob.Size = UDim2.fromOffset(14, 14)
    knob.Position = cfg[key] and UDim2.fromOffset(20, 2) or UDim2.fromOffset(2, 2)
    knob.BackgroundColor3 = Color3.fromRGB(230, 230, 240)
    knob.BorderSizePixel = 0
    knob.Parent = btn
    Instance.new("UICorner", knob).CornerRadius = UDim.new(0, 7)

    btn.MouseButton1Click:Connect(function()
        cfg[key] = not cfg[key]
        btn.BackgroundColor3 = cfg[key] and Color3.fromRGB(80, 160, 100) or Color3.fromRGB(50, 50, 65)
        knob:TweenPosition(cfg[key] and UDim2.fromOffset(20, 2) or UDim2.fromOffset(2, 2), Enum.EasingDirection.Out, Enum.EasingStyle.Quad, 0.12, true)
    end)
end

local function addSlider(parent, label, cfg, key, minV, maxV, isFloat, order)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, 0, 0, 44)
    row.BackgroundColor3 = Color3.fromRGB(32, 32, 40)
    row.BorderSizePixel = 0
    row.LayoutOrder = order or 0
    row.Parent = parent
    Instance.new("UICorner", row).CornerRadius = UDim.new(0, 6)

    local lbl = Instance.new("TextLabel")
    lbl.Text = label
    lbl.Size = UDim2.new(1, -70, 0, 18)
    lbl.Position = UDim2.fromOffset(10, 4)
    lbl.BackgroundTransparency = 1
    lbl.TextColor3 = Color3.fromRGB(220, 220, 230)
    lbl.Font = Enum.Font.Gotham
    lbl.TextSize = 13
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.Parent = row

    local valLbl = Instance.new("TextLabel")
    valLbl.Size = UDim2.fromOffset(60, 18)
    valLbl.Position = UDim2.new(1, -70, 0, 4)
    valLbl.BackgroundTransparency = 1
    valLbl.TextColor3 = Color3.fromRGB(160, 160, 180)
    valLbl.Font = Enum.Font.Gotham
    valLbl.TextSize = 12
    valLbl.TextXAlignment = Enum.TextXAlignment.Right
    valLbl.Text = isFloat and string.format("%.2f", cfg[key]) or tostring(cfg[key])
    valLbl.Parent = row

    local track = Instance.new("Frame")
    track.Size = UDim2.new(1, -20, 0, 6)
    track.Position = UDim2.fromOffset(10, 26)
    track.BackgroundColor3 = Color3.fromRGB(50, 50, 65)
    track.BorderSizePixel = 0
    track.Parent = row
    Instance.new("UICorner", track).CornerRadius = UDim.new(0, 3)

    local fill = Instance.new("Frame")
    fill.BackgroundColor3 = Color3.fromRGB(100, 160, 240)
    fill.BorderSizePixel = 0
    fill.Size = UDim2.fromScale(math.clamp((cfg[key] - minV) / (maxV - minV), 0, 1), 1)
    fill.Parent = track
    Instance.new("UICorner", fill).CornerRadius = UDim.new(0, 3)

    local dragging = false
    local function applyFromX(absX)
        local rel = math.clamp((absX - track.AbsolutePosition.X) / math.max(track.AbsoluteSize.X, 1), 0, 1)
        local val = minV + (maxV - minV) * rel
        if not isFloat then val = math.floor(val + 0.5) end
        cfg[key] = val
        fill.Size = UDim2.fromScale(rel, 1)
        valLbl.Text = isFloat and string.format("%.2f", val) or tostring(val)
    end

    track.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            applyFromX(input.Position.X)
        end
    end)
    track( UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            applyFromX(input.Position.X)
        end
    end))
    track( UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end))
end

local function addDropdown(parent, label, cfg, key, options, order)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, 0, 0, 52)
    row.BackgroundColor3 = Color3.fromRGB(32, 32, 40)
    row.BorderSizePixel = 0
    row.LayoutOrder = order or 0
    row.Parent = parent
    Instance.new("UICorner", row).CornerRadius = UDim.new(0, 6)

    local lbl = Instance.new("TextLabel")
    lbl.Text = label
    lbl.Size = UDim2.new(0.6, 0, 0, 18)
    lbl.Position = UDim2.fromOffset(10, 4)
    lbl.BackgroundTransparency = 1
    lbl.TextColor3 = Color3.fromRGB(220, 220, 230)
    lbl.Font = Enum.Font.Gotham
    lbl.TextSize = 13
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.Parent = row

    local currentBtn = Instance.new("TextButton")
    currentBtn.Size = UDim2.new(1, -20, 0, 22)
    currentBtn.Position = UDim2.fromOffset(10, 24)
    currentBtn.BackgroundColor3 = Color3.fromRGB(50, 50, 65)
    currentBtn.BorderSizePixel = 0
    currentBtn.TextColor3 = Color3.fromRGB(220, 220, 230)
    currentBtn.Font = Enum.Font.Gotham
    currentBtn.TextSize = 12
    currentBtn.Text = tostring(cfg[key])
    currentBtn.Parent = row
    Instance.new("UICorner", currentBtn).CornerRadius = UDim.new(0, 4)

    local expanded = false
    local list = Instance.new("Frame")
    list.Size = UDim2.new(1, -20, 0, #options * 22)
    list.Position = UDim2.fromOffset(10, 48)
    list.BackgroundColor3 = Color3.fromRGB(28, 28, 36)
    list.BorderSizePixel = 0
    list.Visible = false
    list.ZIndex = 5
    list.Parent = row
    Instance.new("UICorner", list).CornerRadius = UDim.new(0, 4)

    local ll = Instance.new("UIListLayout", list)
    ll.Padding = UDim.new(0, 0)

    for i, opt in ipairs(options) do
        local optBtn = Instance.new("TextButton")
        optBtn.Size = UDim2.new(1, 0, 0, 22)
        optBtn.BackgroundColor3 = Color3.fromRGB(28, 28, 36)
        optBtn.BorderSizePixel = 0
        optBtn.Text = tostring(opt)
        optBtn.TextColor3 = Color3.fromRGB(200, 200, 210)
        optBtn.Font = Enum.Font.Gotham
        optBtn.TextSize = 12
        optBtn.LayoutOrder = i
        optBtn.ZIndex = 6
        optBtn.Parent = list
        optBtn.MouseButton1Click:Connect(function()
            cfg[key] = opt
            currentBtn.Text = tostring(opt)
            expanded = false
            list.Visible = false
            row.Size = UDim2.new(1, 0, 0, 52)
        end)
    end

    currentBtn.MouseButton1Click:Connect(function()
        expanded = not expanded
        list.Visible = expanded
        row.Size = expanded and UDim2.new(1, 0, 0, 52 + #options * 22) or UDim2.new(1, 0, 0, 52)
    end)
end

local function addTextBox(parent, label, cfg, key, order)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, 0, 0, 44)
    row.BackgroundColor3 = Color3.fromRGB(32, 32, 40)
    row.BorderSizePixel = 0
    row.LayoutOrder = order or 0
    row.Parent = parent
    Instance.new("UICorner", row).CornerRadius = UDim.new(0, 6)

    local lbl = Instance.new("TextLabel")
    lbl.Text = label
    lbl.Size = UDim2.new(1, -20, 0, 16)
    lbl.Position = UDim2.fromOffset(10, 3)
    lbl.BackgroundTransparency = 1
    lbl.TextColor3 = Color3.fromRGB(220, 220, 230)
    lbl.Font = Enum.Font.Gotham
    lbl.TextSize = 12
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.Parent = row

    local tb = Instance.new("TextBox")
    tb.Size = UDim2.new(1, -20, 0, 20)
    tb.Position = UDim2.fromOffset(10, 20)
    tb.BackgroundColor3 = Color3.fromRGB(50, 50, 65)
    tb.BorderSizePixel = 0
    tb.Text = tostring(cfg[key] or "")
    tb.TextColor3 = Color3.fromRGB(220, 220, 230)
    tb.PlaceholderText = "..."
    tb.PlaceholderColor3 = Color3.fromRGB(120, 120, 140)
    tb.Font = Enum.Font.Gotham
    tb.TextSize = 12
    tb.ClearTextOnFocus = false
    tb.Parent = row
    Instance.new("UICorner", tb).CornerRadius = UDim.new(0, 4)

    tb.FocusLost:Connect(function()
        cfg[key] = tb.Text
    end)
end

local function addButton(parent, label, callback, order)
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(1, 0, 0, 30)
    btn.BackgroundColor3 = Color3.fromRGB(80, 120, 200)
    btn.BorderSizePixel = 0
    btn.TextColor3 = Color3.fromRGB(240, 240, 255)
    btn.Font = Enum.Font.GothamBold
    btn.TextSize = 13
    btn.Text = label
    btn.LayoutOrder = order or 0
    btn.Parent = parent
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 6)
    btn.MouseButton1Click:Connect(callback)
    return btn
end

local function buildUI()
    local parent = resolveParent()
    local gui = Instance.new("ScreenGui")
    gui.Name = "KVSG_UI"
    gui.ResetOnSpawn = false
    gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    gui.DisplayOrder = 100
    pcall(function() if syn and syn.protect_gui then syn.protect_gui(gui) end end)
    pcall(function() if protectgui then protectgui(gui) end end)
    gui.Parent = parent
    State.ui = gui

    local main = Instance.new("Frame")
    main.Size = UDim2.fromOffset(430, 540)
    main.Position = UDim2.fromOffset(80, 80)
    main.BackgroundColor3 = Color3.fromRGB(20, 20, 26)
    main.BorderSizePixel = 0
    main.Active = true
    main.Draggable = true
    main.Parent = gui
    Instance.new("UICorner", main).CornerRadius = UDim.new(0, 8)

    local header = Instance.new("Frame")
    header.Size = UDim2.new(1, 0, 0, 36)
    header.BackgroundColor3 = Color3.fromRGB(30, 30, 38)
    header.BorderSizePixel = 0
    header.Parent = main
    Instance.new("UICorner", header).CornerRadius = UDim.new(0, 8)

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, -100, 1, 0)
    title.Position = UDim2.fromOffset(12, 0)
    title.BackgroundTransparency = 1
    title.TextColor3 = Color3.fromRGB(230, 230, 240)
    title.Font = Enum.Font.GothamBold
    title.TextSize = 14
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Text = "KVSG Suite  •  " .. EXEC
    title.Parent = header

    local closeBtn = Instance.new("TextButton")
    closeBtn.Size = UDim2.fromOffset(28, 26)
    closeBtn.Position = UDim2.new(1, -34, 0, 5)
    closeBtn.BackgroundColor3 = Color3.fromRGB(200, 60, 70)
    closeBtn.BorderSizePixel = 0
    closeBtn.Text = "✕"
    closeBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    closeBtn.Font = Enum.Font.GothamBold
    closeBtn.TextSize = 13
    closeBtn.Parent = header
    Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 6)

    local minBtn = Instance.new("TextButton")
    minBtn.Size = UDim2.fromOffset(28, 26)
    minBtn.Position = UDim2.new(1, -66, 0, 5)
    minBtn.BackgroundColor3 = Color3.fromRGB(60, 60, 78)
    minBtn.BorderSizePixel = 0
    minBtn.Text = "—"
    minBtn.TextColor3 = Color3.fromRGB(230, 230, 240)
    minBtn.Font = Enum.Font.GothamBold
    minBtn.TextSize = 13
    minBtn.Parent = header
    Instance.new("UICorner", minBtn).CornerRadius = UDim.new(0, 6)

    local tabBar = Instance.new("Frame")
    tabBar.Size = UDim2.new(1, 0, 0, 32)
    tabBar.Position = UDim2.fromOffset(0, 36)
    tabBar.BackgroundColor3 = Color3.fromRGB(26, 26, 32)
    tabBar.BorderSizePixel = 0
    tabBar.Parent = main

    local content = Instance.new("Frame")
    content.Size = UDim2.new(1, -16, 1, -84)
    content.Position = UDim2.fromOffset(8, 76)
    content.BackgroundTransparency = 1
    content.Parent = main

    local tabs = {}
    local currentTab
    local function createTab(name, order)
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.fromOffset(72, 32)
        btn.BackgroundColor3 = Color3.fromRGB(26, 26, 32)
        btn.BorderSizePixel = 0
        btn.Text = name
        btn.TextColor3 = Color3.fromRGB(160, 160, 180)
        btn.Font = Enum.Font.GothamSemibold
        btn.TextSize = 12
        btn.LayoutOrder = order
        btn.Parent = tabBar

        local frame = Instance.new("ScrollingFrame")
        frame.Size = UDim2.fromScale(1, 1)
        frame.BackgroundTransparency = 1
        frame.BorderSizePixel = 0
        frame.ScrollBarThickness = 4
        frame.CanvasSize = UDim2.new()
        frame.AutomaticCanvasSize = Enum.AutomaticSize.Y
        frame.Visible = false
        frame.Parent = content
        local ll = Instance.new("UIListLayout", frame)
        ll.Padding = UDim.new(0, 6)
        ll.SortOrder = Enum.SortOrder.LayoutOrder

        tabs[name] = {btn = btn, frame = frame}
        btn.MouseButton1Click:Connect(function()
            for n, t in pairs(tabs) do
                t.frame.Visible = (n == name)
                t.btn.BackgroundColor3 = (n == name) and Color3.fromRGB(40, 40, 52) or Color3.fromRGB(26, 26, 32)
                t.btn.TextColor3 = (n == name) and Color3.fromRGB(255,255,255) or Color3.fromRGB(160,160,180)
            end
            currentTab = name
        end)
        return frame
    end
    createTab("Rage", 1); createTab("Anti-Aim", 2); createTab("Bhop", 3)
    createTab("ESP", 4); createTab("Ambience", 5); createTab("Config", 6)

    -- RAGE TAB
    local rage = tabs["Rage"].frame
    addToggle(rage, "Enabled", Config.Rage, "Enabled", 1)
    local modes = {"CFrame", "Silent"}
    if not hasHookMM or not hasCheckCaller then modes = {"CFrame"} end
    addDropdown(rage, "Aim Mode", Config.Rage, "Mode", modes, 2)
    addDropdown(rage, "Target", Config.Rage, "TargetMode", {"FOV","Health","Distance"}, 3)
    addSlider(rage, "FOV (px)", Config.Rage, "FOV", 40, 800, false, 4)
    addSlider(rage, "Smoothing", Config.Rage, "Smoothing", 0, 0.95, true, 5)
    addSlider(rage, "Prediction (ms)", Config.Rage, "Prediction", 0, 250, false, 6)
    addToggle(rage, "Wall Check", Config.Rage, "WallCheck", 7)
    addToggle(rage, "Team Check", Config.Rage, "TeamCheck", 8)
    addToggle(rage, "Auto Fire", Config.Rage, "AutoFire", 9)
    addSlider(rage, "Auto Fire Delay", Config.Rage, "AutoFireDelay", 0.02, 0.5, true, 10)
    addTextBox(rage, "Remote Filter (Silent only, пусто = все)", Config.Rage, "RemoteFilter", 11)

    -- ANTI-AIM
    local aa = tabs["Anti-Aim"].frame
    addToggle(aa, "Enabled", Config.AntiAim, "Enabled", 1)
    addDropdown(aa, "Mode", Config.AntiAim, "Mode", {"Jitter","Spin","Random","Static"}, 2)
    addSlider(aa, "Spin Speed", Config.AntiAim, "Speed", 30, 720, false, 3)
    addSlider(aa, "Static Angle", Config.AntiAim, "StaticAngle", 0, 180, false, 4)

    -- BHOP
    local bh = tabs["Bhop"].frame
    addToggle(bh, "Enabled", Config.Bhop, "Enabled", 1)
    addSlider(bh, "WalkSpeed", Config.Bhop, "WalkSpeed", 16, 120, false, 2)
    addSlider(bh, "JumpPower", Config.Bhop, "JumpPower", 50, 200, false, 3)
    addToggle(bh, "Air Strafe", Config.Bhop, "AirStrafe", 4)
    addToggle(bh, "Anti Fall", Config.Bhop, "AntiFall", 5)

    -- ESP
    local esp = tabs["ESP"].frame
    addToggle(esp, "Enabled", Config.ESP, "Enabled", 1)
    addToggle(esp, "Highlight", Config.ESP, "Highlight", 2)
    addToggle(esp, "Name + Distance", Config.ESP, "Name", 3)
    addToggle(esp, "Health Bar", Config.ESP, "Health", 4)
    addToggle(esp, "Skeleton", Config.ESP, "Skeleton", 5)
    addSlider(esp, "Max Distance", Config.ESP, "MaxDistance", 50, 3000, false, 6)
    addSlider(esp, "Fill Transparency", Config.ESP, "FillTransparency", 0, 1, true, 7)

    -- AMBIENCE
    local am = tabs["Ambience"].frame
    addToggle(am, "Enabled", Config.Ambience, "Enabled", 1)
    addSlider(am, "Brightness", Config.Ambience, "Brightness", 0, 5, true, 2)
    addSlider(am, "Clock Time", Config.Ambience, "ClockTime", 0, 24, true, 3)
    addSlider(am, "Fog Start", Config.Ambience, "FogStart", 0, 2000, false, 4)
    addSlider(am, "Fog End", Config.Ambience, "FogEnd", 100, 20000, false, 5)
    addSlider(am, "Exposure", Config.Ambience, "Exposure", -3, 3, true, 6)
    addSlider(am, "FOV", Config.Ambience, "FOV", 30, 120, false, 7)
    addToggle(am, "Bloom", Config.Ambience, "Bloom", 8)
    addToggle(am, "Color Correction", Config.Ambience, "ColorCorrection", 9)
    addSlider(am, "Saturation", Config.Ambience, "Saturation", -1, 1, true, 10)
    addSlider(am, "Contrast", Config.Ambience, "Contrast", -1, 1, true, 11)

    -- CONFIG
    local cfg = tabs["Config"].frame
    addButton(cfg, "Dump Remotes (в консоль)", function()
        print("=== KVSG Remote Dump ===")
        local rs = game:GetService("ReplicatedStorage")
        for _, obj in ipairs(rs:GetDescendants()) do
            if obj:IsA("RemoteEvent") or obj:IsA("RemoteFunction") or obj.ClassName == "UnreliableRemoteEvent" then
                print(("[%s] %s"):format(obj.ClassName, obj:GetFullName()))
            end
        end
        for _, obj in ipairs(workspace:GetDescendants()) do
            if obj:IsA("RemoteEvent") or obj:IsA("RemoteFunction") or obj.ClassName == "UnreliableRemoteEvent" then
                print(("[%s] %s"):format(obj.ClassName, obj:GetFullName()))
            end
        end
        print("=== End ===")
        pcall(function() if setclipboard then setclipboard("Remote dump открыт в Developer Console (F9)") end end)
    end, 1)
    addButton(cfg, "Unload", function()
        _G.KVSG_Unload()
    end, 2)

    closeBtn.MouseButton1Click:Connect(function()
        _G.KVSG_Unload()
    end)
    minBtn.MouseButton1Click:Connect(function()
        main.Visible = not main.Visible
    end)
    -- показываем первую вкладку
    for _, t in pairs(tabs) do break end
    tabs["Rage"].btn:GetPropertyChangedSignal("BackgroundColor3"):Connect(function() end)
    -- принудительно активируем Rage
    tabs["Rage"].frame.Visible = true
    tabs["Rage"].btn.BackgroundColor3 = Color3.fromRGB(40, 40, 52)
    tabs["Rage"].btn.TextColor3 = Color3.fromRGB(255,255,255)
end

-- ==== PLAYER HOOKS ====
local function onPlayerAdded(p)
    if p == LP then return end
    if Config.ESP.Enabled then ensureESP(p) end
    track(p.CharacterAdded:Connect(function()
        task.wait(0.5)
        if Config.ESP.Enabled then ensureESP(p) end
    end))
end
for _, p in ipairs(Players:GetPlayers()) do onPlayerAdded(p) end
track(Players.PlayerAdded:Connect(onPlayerAdded))
track(Players.PlayerRemoving:Connect(removeESP))
track(LP.CharacterAdded:Connect(function()
    -- сбрасываем anti-aim оригиналы на новый персонаж
    State.aaOrig.c0 = nil
    State.aaOrig.c1 = nil
end))

-- ==== UNLOAD ====
_G.KVSG_Unload = function()
    if State.unloaded then return end
    State.unloaded = true
    for _, c in ipairs(State.conns) do pcall(function() c:Disconnect() end) end
    for _, h in pairs(State.hooks) do
        if type(h) == "function" and hasHookMM then
            pcall(function() hookmetamethod(game, "__namecall", h) end)
        end
    end
    -- restore ambience
    Config.Ambience.Enabled = false
    applyAmbience()
    for _, e in ipairs(Lighting:GetChildren()) do
        if e:IsA("BloomEffect") or e:IsA("ColorCorrectionEffect") then
            pcall(function() e:Destroy() end)
        end
    end
    -- restore AA
    local char = LP.Character
    if char then
        local neck = getNeck(char)
        if neck and State.aaOrig.c0 then
            pcall(function() neck.C0 = State.aaOrig.c0; neck.C1 = State.aaOrig.c1 end)
        end
        local hum = char:FindFirstChildOfClass("Humanoid")
        if hum then pcall(function() hum.AutoRotate = State.aaOrig.humAuto end) end
    end
    -- ESP cleanup
    for p in pairs(State.esp) do removeESP(p) end
    if espGui then pcall(function() espGui:Destroy() end) end
    -- UI cleanup
    if State.ui then pcall(function() State.ui:Destroy() end) end
    warn("[KVSG] Unloaded.")
end

-- ==== BOOT ====
task.spawn(function()
    pcall(buildUI)
    pcall(installSilentAim)

    track(RunService.RenderStepped:Connect(function()
        pcall(rageFrame)
        pcall(antiAimFrame)
        pcall(updateESP)
    end))
    track(RunService.Heartbeat:Connect(function()
        pcall(bhopFrame)
    end))
    -- периодически применяем ambience (не в RenderStepped, чтобы не дёргать Lighting каждый кадр)
    track(task.spawn(function()
        while not State.unloaded do
            task.wait(0.5)
            pcall(applyAmbience)
        end
    end))
    -- автоуборка ESP для несуществующих персонажей
    track(task.spawn(function()
        while not State.unloaded do
            task.wait(2)
            for p in pairs(State.esp) do
                if not p.Parent then removeESP(p) end
            end
        end
    end))
end)
