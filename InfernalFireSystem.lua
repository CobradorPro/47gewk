--[[
    ================================================================================
    SISTEMA AVANÇADO DE HABILIDADES DE FOGO — DELTA EXECUTOR MOBILE
    Arquitetura: Local / Procedural / Object Pooling / Central Render Loop
    Compatibilidade: R15 & R6 | Interface Touch Responsiva (Android/iOS)
    ================================================================================
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer
local Camera = Workspace.CurrentCamera

-- ============================================================================
-- 1. LIMPEZA DE EXECUÇÕES ANTERIORES (SINGLETON GUARD)
-- ============================================================================
if _G.InfernalFireSystemCleanup then
    pcall(_G.InfernalFireSystemCleanup)
end

local SystemActive = true
local Connections = {}

local function AddConnection(conn)
    table.insert(Connections, conn)
    return conn
end

-- ============================================================================
-- 2. PALETA DE CORES E CONSTANTES VISUAIS (ESTILO ANIME CEL-SHADED FIRE)
-- ============================================================================
local Palette = {
    CoreWhite     = Color3.fromRGB(255, 255, 240),
    BrightYellow  = Color3.fromRGB(255, 230, 85),
    GoldenOrange  = Color3.fromRGB(255, 165, 30),
    DeepOrange    = Color3.fromRGB(245, 95, 15),
    CrimsonRed    = Color3.fromRGB(195, 25, 15),
    DarkMagma     = Color3.fromRGB(90, 12, 10),
    CharcoalSmoke = Color3.fromRGB(28, 22, 22),
    UiBackground  = Color3.fromRGB(18, 16, 20),
    UiAccent      = Color3.fromRGB(255, 115, 25),
    UiBorder      = Color3.fromRGB(255, 180, 70)
}

local FlameColorSequence = ColorSequence.new({
    ColorSequenceKeypoint.new(0.00, Palette.CoreWhite),
    ColorSequenceKeypoint.new(0.22, Palette.BrightYellow),
    ColorSequenceKeypoint.new(0.55, Palette.GoldenOrange),
    ColorSequenceKeypoint.new(0.82, Palette.CrimsonRed),
    ColorSequenceKeypoint.new(1.00, Palette.CharcoalSmoke)
})

local MagmaColorSequence = ColorSequence.new({
    ColorSequenceKeypoint.new(0.00, Palette.BrightYellow),
    ColorSequenceKeypoint.new(0.45, Palette.DeepOrange),
    ColorSequenceKeypoint.new(0.85, Palette.CrimsonRed),
    ColorSequenceKeypoint.new(1.00, Palette.DarkMagma)
})

local RaycastParamsEnv = RaycastParams.new()
RaycastParamsEnv.FilterType = Enum.RaycastFilterType.Exclude
RaycastParamsEnv.IgnoreWater = true

-- Pasta dedicada no Workspace para organização e filtro de Raycast
local EffectsFolder = Workspace:FindFirstChild("DeltaInfernalVFX")
if EffectsFolder then
    EffectsFolder:Destroy()
end
EffectsFolder = Instance.new("Folder")
EffectsFolder.Name = "DeltaInfernalVFX"
EffectsFolder.Parent = Workspace

local function UpdateRaycastFilter()
    local ignoreList = {EffectsFolder}
    if LocalPlayer.Character then
        table.insert(ignoreList, LocalPlayer.Character)
    end
    RaycastParamsEnv.FilterDescendantsInstances = ignoreList
end
UpdateRaycastFilter()

-- ============================================================================
-- 3. UTILITÁRIOS MATEMÁTICOS E FÍSICOS
-- ============================================================================
local Math = {}

function Math.Lerp(a, b, t)
    return a + (b - a) * t
end

function Math.Clamp01(val)
    if val < 0 then return 0 end
    if val > 1 then return 1 end
    return val
end

function Math.EaseOutCubic(t)
    return 1 - ((1 - t) ^ 3)
end

function Math.EaseInCubic(t)
    return t * t * t
end

function Math.EaseInOutQuad(t)
    return t < 0.5 and 2 * t * t or 1 - ((-2 * t + 2) ^ 2) / 2
end

function Math.SampleFlameColor(alpha)
    alpha = Math.Clamp01(alpha)
    if alpha < 0.25 then
        return Palette.CoreWhite:Lerp(Palette.BrightYellow, alpha / 0.25)
    elseif alpha < 0.55 then
        return Palette.BrightYellow:Lerp(Palette.GoldenOrange, (alpha - 0.25) / 0.30)
    elseif alpha < 0.80 then
        return Palette.GoldenOrange:Lerp(Palette.CrimsonRed, (alpha - 0.55) / 0.25)
    else
        return Palette.CrimsonRed:Lerp(Palette.CharcoalSmoke, (alpha - 0.80) / 0.20)
    end
end

function Math.RandomVector(minMag, maxMag)
    local theta = math.random() * math.pi * 2
    local phi = math.acos(2 * math.random() - 1)
    local mag = minMag + math.random() * (maxMag - minMag)
    return Vector3.new(
        mag * math.sin(phi) * math.cos(theta),
        mag * math.cos(phi),
        mag * math.sin(phi) * math.sin(theta)
    )
end

function Math.GetGroundPosition(originPos, maxDrop)
    maxDrop = maxDrop or 60
    local result = Workspace:Raycast(originPos + Vector3.new(0, 6, 0), Vector3.new(0, -maxDrop, 0), RaycastParamsEnv)
    if result then
        return result.Position, result.Normal
    end
    return originPos - Vector3.new(0, 3, 0), Vector3.new(0, 1, 0)
end

-- ============================================================================
-- 4. POOL DE OBJETOS E GERENCIADOR CENTRAL DE EFEITOS (PERFORMANCE ENGINE)
-- ============================================================================
local PartPool = {
    Available = {
        Block = {},
        Ball = {},
        Cylinder = {},
        Wedge = {}
    },
    ActiveCount = 0,
    MaxActive = 550
}

local HiddenCFrame = CFrame.new(0, -5000, 0)

local function CreateBasePart(shapeType)
    local part
    if shapeType == "Wedge" then
        part = Instance.new("WedgePart")
    else
        part = Instance.new("Part")
        if shapeType == "Ball" then
            part.Shape = Enum.PartType.Ball
        elseif shapeType == "Cylinder" then
            part.Shape = Enum.PartType.Cylinder
        else
            part.Shape = Enum.PartType.Block
        end
    end

    part.Anchored = true
    part.CanCollide = false
    part.CanQuery = false
    part.CanTouch = false
    part.CastShadow = false
    part.Material = Enum.Material.Neon
    part.TopSurface = Enum.SurfaceType.Smooth
    part.BottomSurface = Enum.SurfaceType.Smooth
    part.Size = Vector3.new(1, 1, 1)
    part.CFrame = HiddenCFrame
    part.Parent = EffectsFolder

    local light = Instance.new("PointLight")
    light.Name = "FXLight"
    light.Enabled = false
    light.Shadows = false
    light.Parent = part

    return part
end

function PartPool:Acquire(shapeType, material, color, size, cf, transparency, lightRange, lightBrightness)
    shapeType = shapeType or "Block"
    local bucket = self.Available[shapeType] or self.Available.Block
    local part = table.remove(bucket)

    if not part or not part.Parent then
        part = CreateBasePart(shapeType)
    end

    part.Material = material or Enum.Material.Neon
    part.Color = color or Palette.GoldenOrange
    part.Size = size or Vector3.new(1, 1, 1)
    part.CFrame = cf or CFrame.identity
    part.Transparency = transparency or 0

    local light = part:FindFirstChild("FXLight")
    if light then
        if lightRange and lightRange > 0 then
            light.Color = color or Palette.GoldenOrange
            light.Range = lightRange
            light.Brightness = lightBrightness or 2
            light.Enabled = true
        else
            light.Enabled = false
        end
    end

    self.ActiveCount = self.ActiveCount + 1
    return part, shapeType
end

function PartPool:Release(part, shapeType)
    if not part then return end
    shapeType = shapeType or "Block"

    local light = part:FindFirstChild("FXLight")
    if light then
        light.Enabled = false
    end

    part.Transparency = 1
    part.CFrame = HiddenCFrame

    local bucket = self.Available[shapeType] or self.Available.Block
    if #bucket < 250 then
        table.insert(bucket, part)
    else
        part:Destroy()
    end

    self.ActiveCount = math.max(0, self.ActiveCount - 1)
end

-- Pré-alocação leve para evitar engasgos no primeiro uso
for i = 1, 45 do
    table.insert(PartPool.Available.Ball, CreateBasePart("Ball"))
    table.insert(PartPool.Available.Block, CreateBasePart("Block"))
    table.insert(PartPool.Available.Cylinder, CreateBasePart("Cylinder"))
end

-- Listas centrais processadas em um único RenderStepped
local ActiveParticles = {}
local ActiveUpdaters = {}
local ActiveShakes = {}

local function SpawnParticle(config)
    if PartPool.ActiveCount >= PartPool.MaxActive and not config.Force then
        return nil
    end

    local part, shapeType = PartPool:Acquire(
        config.Shape or "Ball",
        config.Material or Enum.Material.Neon,
        config.StartColor or Palette.BrightYellow,
        config.StartSize or Vector3.new(1, 1, 1),
        config.CFrame or CFrame.new(config.Position or Vector3.zero),
        config.StartTransparency or 0,
        config.LightRange,
        config.LightBrightness
    )

    local pData = {
        Part = part,
        Shape = shapeType,
        Age = 0,
        Lifetime = config.Lifetime or 0.6,
        Position = config.Position or (config.CFrame and config.CFrame.Position) or Vector3.zero,
        Velocity = config.Velocity or Vector3.zero,
        Acceleration = config.Acceleration or Vector3.zero,
        Drag = config.Drag or 0,
        Rotation = config.Rotation or Vector3.new(math.random() * 6, math.random() * 6, math.random() * 6),
        RotSpeed = config.RotSpeed or Vector3.zero,
        OrientToVelocity = config.OrientToVelocity or false,
        StartSize = config.StartSize or Vector3.new(1, 1, 1),
        MidSize = config.MidSize,
        EndSize = config.EndSize or Vector3.new(0.1, 0.1, 0.1),
        StartColor = config.StartColor or Palette.BrightYellow,
        MidColor = config.MidColor,
        EndColor = config.EndColor or Palette.CrimsonRed,
        UseFlameGradient = config.UseFlameGradient or false,
        SwitchToDarkCore = config.SwitchToDarkCore or false,
        StartTransparency = config.StartTransparency or 0,
        EndTransparency = config.EndTransparency or 1,
        CollideGround = config.CollideGround or false,
        Bounce = config.Bounce or 0.35,
        OnGroundHit = config.OnGroundHit,
        HasHitGround = false,
        CustomStep = config.CustomStep
    }

    table.insert(ActiveParticles, pData)
    return pData
end

local function AddUpdater(duration, stepCallback, finishCallback)
    local entry = {
        Elapsed = 0,
        Duration = duration,
        Step = stepCallback,
        Finish = finishCallback,
        Cancelled = false
    }
    table.insert(ActiveUpdaters, entry)
    return entry
end

local function TriggerCameraShake(originPos, maxDist, intensity, duration)
    table.insert(ActiveShakes, {
        Origin = originPos,
        MaxDist = maxDist or 120,
        Intensity = intensity or 1.2,
        Duration = duration or 0.45,
        Elapsed = 0
    })
end

-- ============================================================================
-- 5. BIBLIOTECA DE EFEITOS COMPOSTOS (ONDAS, NUVENS, LAVA, FAÍSCAS)
-- ============================================================================
local VFX = {}

-- Cria uma esfera com núcleo escuro e borda de fogo (inspirado no canto superior direito da imagem)
function VFX.CreateShadowCoreBurst(centerPos, radius, duration)
    -- Anel/esfera externa de fogo intenso
    SpawnParticle({
        Shape = "Ball",
        Material = Enum.Material.Neon,
        Position = centerPos,
        StartSize = Vector3.new(radius * 0.25, radius * 0.25, radius * 0.25),
        MidSize = Vector3.new(radius * 2.1, radius * 2.1, radius * 2.1),
        EndSize = Vector3.new(radius * 2.5, radius * 2.5, radius * 2.5),
        StartColor = Palette.CoreWhite,
        MidColor = Palette.GoldenOrange,
        EndColor = Palette.CrimsonRed,
        StartTransparency = 0.05,
        EndTransparency = 1,
        Lifetime = duration,
        LightRange = radius * 2.2,
        LightBrightness = 3.5,
        Force = true
    })

    -- Núcleo negro/sombrio interno de alta pressão
    SpawnParticle({
        Shape = "Ball",
        Material = Enum.Material.SmoothPlastic,
        Position = centerPos + Vector3.new(0, radius * 0.04, 0),
        StartSize = Vector3.new(radius * 0.15, radius * 0.15, radius * 0.15),
        MidSize = Vector3.new(radius * 1.75, radius * 1.55, radius * 1.75),
        EndSize = Vector3.new(radius * 0.2, radius * 0.2, radius * 0.2),
        StartColor = Color3.fromRGB(15, 10, 12),
        EndColor = Color3.fromRGB(5, 5, 5),
        StartTransparency = 0,
        EndTransparency = 1,
        Lifetime = duration * 0.88,
        Force = true
    })

    -- Coroa de lâminas de fogo rasgando a borda da esfera
    local crownCount = 14
    for i = 1, crownCount do
        local angle = (i / crownCount) * math.pi * 2
        local dir = Vector3.new(math.cos(angle), (math.random() - 0.3) * 0.8, math.sin(angle)).Unit
        SpawnParticle({
            Shape = "Block",
            Material = Enum.Material.Neon,
            Position = centerPos + dir * (radius * 0.5),
            Velocity = dir * (radius * 1.8) + Vector3.new(0, radius * 0.9, 0),
            Drag = 3.5,
            OrientToVelocity = true,
            StartSize = Vector3.new(radius * 0.25, radius * 0.25, radius * 0.9),
            EndSize = Vector3.new(0.1, 0.1, radius * 1.5),
            UseFlameGradient = true,
            StartTransparency = 0,
            EndTransparency = 1,
            Lifetime = duration * (0.7 + math.random() * 0.4)
        })
    end
end

-- Cria nuvem de explosão volumétrica multicamadas (centro e base direita da referência)
function VFX.CreateVolumetricFireCloud(centerPos, scale, puffCount)
    puffCount = puffCount or 14
    for i = 1, puffCount do
        local angle = (i / puffCount) * math.pi * 2 + (math.random() - 0.5) * 0.4
        local dist = (0.2 + math.random() * 0.8) * scale
        local offset = Vector3.new(math.cos(angle) * dist, math.random() * scale * 0.55, math.sin(angle) * dist)
        local puffSize = scale * (0.45 + math.random() * 0.45)

        SpawnParticle({
            Shape = "Ball",
            Material = Enum.Material.Neon,
            Position = centerPos + offset * 0.3,
            Velocity = offset * 1.8 + Vector3.new(0, scale * (0.5 + math.random() * 0.6), 0),
            Drag = 2.8,
            StartSize = Vector3.new(puffSize * 0.4, puffSize * 0.4, puffSize * 0.4),
            MidSize = Vector3.new(puffSize * 1.35, puffSize * 1.15, puffSize * 1.35),
            EndSize = Vector3.new(puffSize * 1.6, puffSize * 1.4, puffSize * 1.6),
            UseFlameGradient = true,
            SwitchToDarkCore = true,
            StartTransparency = 0.05,
            EndTransparency = 1,
            Lifetime = 0.55 + math.random() * 0.45
        })
    end
end

-- Cria anel de onda de choque achatado
function VFX.CreateShockwaveRing(centerPos, normal, startRadius, endRadius, thickness, duration, colorStart, colorEnd)
    normal = normal or Vector3.new(0, 1, 0)
    local baseCF = CFrame.lookAt(centerPos, centerPos + normal) * CFrame.Angles(0, math.rad(90), 0)

    -- No Roblox, Cylinder tem o eixo de altura no eixo X local
    SpawnParticle({
        Shape = "Cylinder",
        Material = Enum.Material.Neon,
        CFrame = baseCF,
        Position = centerPos,
        StartSize = Vector3.new(thickness, startRadius * 2, startRadius * 2),
        EndSize = Vector3.new(thickness * 0.15, endRadius * 2, endRadius * 2),
        StartColor = colorStart or Palette.CoreWhite,
        MidColor = Palette.GoldenOrange,
        EndColor = colorEnd or Palette.CrimsonRed,
        StartTransparency = 0.1,
        EndTransparency = 1,
        Lifetime = duration or 0.5,
        CustomStep = function(p, dt, alpha)
            p.Part.CFrame = baseCF
        end
    })
end

-- Cria efeito de magma/lava viscosa escorrendo (canto inferior esquerdo da referência)
function VFX.CreateDrippingLavaPool(groundPos, radius, duration)
    local poolCF = CFrame.new(groundPos + Vector3.new(0, 0.08, 0)) * CFrame.Angles(0, 0, math.rad(90))
    SpawnParticle({
        Shape = "Cylinder",
        Material = Enum.Material.Neon,
        CFrame = poolCF,
        Position = groundPos + Vector3.new(0, 0.08, 0),
        StartSize = Vector3.new(0.18, radius * 0.3, radius * 0.3),
        MidSize = Vector3.new(0.22, radius * 2.0, radius * 2.0),
        EndSize = Vector3.new(0.05, radius * 2.1, radius * 2.1),
        StartColor = Palette.BrightYellow,
        MidColor = Palette.DeepOrange,
        EndColor = Palette.DarkMagma,
        StartTransparency = 0.05,
        EndTransparency = 1,
        Lifetime = duration,
        CustomStep = function(p)
            p.Part.CFrame = poolCF
        end
    })

    -- Filamentos de magma subindo e escorrendo como cortina de lava
    local dripCount = math.clamp(math.floor(radius * 1.4), 6, 16)
    for i = 1, dripCount do
        local ang = (i / dripCount) * math.pi * 2 + math.random() * 0.3
        local r = math.random() * (radius * 0.85)
        local dropOrigin = groundPos + Vector3.new(math.cos(ang) * r, 0.2 + math.random() * 2.8, math.sin(ang) * r)
        local dripHeight = 1.6 + math.random() * 2.6

        SpawnParticle({
            Shape = "Block",
            Material = Enum.Material.Neon,
            Position = dropOrigin,
            Velocity = Vector3.new(0, -1.8 - math.random() * 1.5, 0),
            StartSize = Vector3.new(0.32, dripHeight, 0.32),
            EndSize = Vector3.new(0.08, dripHeight * 1.5, 0.08),
            StartColor = Palette.BrightYellow,
            MidColor = Palette.CrimsonRed,
            EndColor = Palette.DarkMagma,
            StartTransparency = 0.05,
            EndTransparency = 1,
            Lifetime = duration * (0.55 + math.random() * 0.35),
            CustomStep = function(p, dt)
                p.Part.CFrame = CFrame.new(p.Position)
            end
        })
    end
end

-- Cria arco cortante de fogo (meio-esquerdo da referência)
function VFX.CreateFireSlashArc(originCF, radius, arcAngleDeg, duration, tiltDeg)
    local segments = 12
    local tiltCF = originCF * CFrame.Angles(0, 0, math.rad(tiltDeg or 0))

    for i = 1, segments do
        local frac = (i - 0.5) / segments
        local angle = math.rad((frac - 0.5) * arcAngleDeg)
        local thickness = math.sin(frac * math.pi) * (radius * 0.28) + 0.25
        local segLen = (math.rad(arcAngleDeg) * radius) / segments * 1.35

        local localPos = Vector3.new(math.sin(angle) * radius, 0, -math.cos(angle) * radius)
        local worldPos = tiltCF:PointToWorldSpace(localPos)
        local tangent = tiltCF:VectorToWorldSpace(Vector3.new(math.cos(angle), 0, math.sin(angle)))

        SpawnParticle({
            Shape = "Block",
            Material = Enum.Material.Neon,
            Position = worldPos,
            Velocity = (worldPos - tiltCF.Position).Unit * (radius * 1.6),
            Drag = 3.0,
            OrientToVelocity = false,
            StartSize = Vector3.new(thickness, thickness * 0.45, segLen),
            EndSize = Vector3.new(0.05, 0.05, segLen * 1.4),
            UseFlameGradient = true,
            StartTransparency = 0.02,
            EndTransparency = 1,
            Lifetime = duration * (0.75 + math.sin(frac * math.pi) * 0.35),
            CustomStep = function(p, dt, alpha)
                local forwardPos = p.Position + tangent * (dt * 18)
                p.Position = forwardPos
                p.Part.CFrame = CFrame.lookAt(p.Position, p.Position + tangent)
            end
        })
    end
end

-- Emite faíscas rápidas orientadas pela velocidade
function VFX.EmitSparks(originPos, count, minSpeed, maxSpeed, upwardBias)
    upwardBias = upwardBias or 12
    for i = 1, count do
        local vel = Math.RandomVector(minSpeed, maxSpeed) + Vector3.new(0, upwardBias, 0)
        SpawnParticle({
            Shape = "Block",
            Material = Enum.Material.Neon,
            Position = originPos + Math.RandomVector(0, 1.2),
            Velocity = vel,
            Acceleration = Vector3.new(0, -38, 0),
            Drag = 1.2,
            OrientToVelocity = true,
            StartSize = Vector3.new(0.18, 0.18, 1.4 + math.random() * 1.6),
            EndSize = Vector3.new(0.04, 0.04, 0.3),
            StartColor = Palette.CoreWhite,
            MidColor = Palette.BrightYellow,
            EndColor = Palette.DeepOrange,
            StartTransparency = 0,
            EndTransparency = 1,
            CollideGround = true,
            Bounce = 0.45,
            Lifetime = 0.4 + math.random() * 0.45
        })
    end
end

-- ============================================================================
-- 6. RIG PROCEDURAL & ANIMAÇÕES CORPORAIS (COMPATÍVEL COM R15 E R6)
-- ============================================================================
local RigAnimator = {
    Joints = {},
    OriginalC0 = {},
    TargetOffsets = {},
    CurrentOffsets = {},
    Character = nil,
    Humanoid = nil,
    RootPart = nil,
    IsR15 = true
}

function RigAnimator:BindCharacter(char)
    if not char then return false end
    local hum = char:FindFirstChildOfClass("Humanoid")
    local hrp = char:FindFirstChild("HumanoidRootPart")
    if not hum or not hrp then return false end

    if self.Character == char and next(self.Joints) ~= nil then
        return true
    end

    self.Character = char
    self.Humanoid = hum
    self.RootPart = hrp
    self.Joints = {}
    self.OriginalC0 = {}
    self.TargetOffsets = {}
    self.CurrentOffsets = {}
    self.IsR15 = (hum.RigType == Enum.HumanoidRigType.R15)

    UpdateRaycastFilter()

    local function RegisterMotor(alias, motor)
        if motor and motor:IsA("Motor6D") then
            self.Joints[alias] = motor
            self.OriginalC0[alias] = motor.C0
            self.TargetOffsets[alias] = CFrame.identity
            self.CurrentOffsets[alias] = CFrame.identity
        end
    end

    if self.IsR15 then
        local lowerTorso = char:FindFirstChild("LowerTorso")
        local upperTorso = char:FindFirstChild("UpperTorso")
        local head = char:FindFirstChild("Head")
        local rUpperArm = char:FindFirstChild("RightUpperArm")
        local rLowerArm = char:FindFirstChild("RightLowerArm")
        local lUpperArm = char:FindFirstChild("LeftUpperArm")
        local lLowerArm = char:FindFirstChild("LeftLowerArm")

        if lowerTorso then RegisterMotor("Root", lowerTorso:FindFirstChild("Root")) end
        if upperTorso then RegisterMotor("Waist", upperTorso:FindFirstChild("Waist")) end
        if head then RegisterMotor("Neck", head:FindFirstChild("Neck")) end
        if rUpperArm then RegisterMotor("RightShoulder", rUpperArm:FindFirstChild("RightShoulder")) end
        if rLowerArm then RegisterMotor("RightElbow", rLowerArm:FindFirstChild("RightElbow")) end
        if lUpperArm then RegisterMotor("LeftShoulder", lUpperArm:FindFirstChild("LeftShoulder")) end
        if lLowerArm then RegisterMotor("LeftElbow", lLowerArm:FindFirstChild("LeftElbow")) end
    else
        local torso = char:FindFirstChild("Torso")
        if torso then
            RegisterMotor("Root", hrp:FindFirstChild("RootJoint"))
            RegisterMotor("Neck", torso:FindFirstChild("Neck"))
            RegisterMotor("RightShoulder", torso:FindFirstChild("Right Shoulder"))
            RegisterMotor("LeftShoulder", torso:FindFirstChild("Left Shoulder"))
        end
    end

    return true
end

function RigAnimator:SetPose(poseTable)
    for alias, _ in pairs(self.Joints) do
        self.TargetOffsets[alias] = poseTable[alias] or CFrame.identity
    end
end

function RigAnimator:ResetPose()
    for alias, _ in pairs(self.Joints) do
        self.TargetOffsets[alias] = CFrame.identity
    end
end

function RigAnimator:RestoreDefaultsImmediate()
    for alias, motor in pairs(self.Joints) do
        if motor and motor.Parent and self.OriginalC0[alias] then
            motor.C0 = self.OriginalC0[alias]
        end
    end
end

function RigAnimator:Step(dt)
    local char = LocalPlayer.Character
    if not char then return end
    if char ~= self.Character then
        self:BindCharacter(char)
    end

    local alpha = math.clamp(dt * 14, 0, 1)
    for alias, motor in pairs(self.Joints) do
        if motor and motor.Parent and self.OriginalC0[alias] then
            local target = self.TargetOffsets[alias] or CFrame.identity
            local current = (self.CurrentOffsets[alias] or CFrame.identity):Lerp(target, alpha)
            self.CurrentOffsets[alias] = current

            -- Para R6, os eixos dos ombros são rotacionados lateralmente; convertemos suavemente
            if not self.IsR15 and (alias == "RightShoulder" or alias == "LeftShoulder") then
                local rx, ry, rz = current:ToEulerAnglesXYZ()
                local sign = (alias == "RightShoulder") and 1 or -1
                local adapted = CFrame.new(current.Position) * CFrame.Angles(rz * sign, ry, rx * sign)
                motor.C0 = self.OriginalC0[alias] * adapted
            else
                motor.C0 = self.OriginalC0[alias] * current
            end
        end
    end
end

function RigAnimator:GetHandPosition(side)
    local char = self.Character
    if not char then return Vector3.zero end
    if side == "Right" then
        local part = char:FindFirstChild("RightHand") or char:FindFirstChild("Right Arm")
        if part then return part.Position end
    elseif side == "Left" then
        local part = char:FindFirstChild("LeftHand") or char:FindFirstChild("Left Arm")
        if part then return part.Position end
    end
    return self.RootPart and self.RootPart.Position or Vector3.zero
end

-- ============================================================================
-- 7. IMPLEMENTAÇÃO DAS 6 HABILIDADES COMPLEXAS EM MÚLTIPLAS ETAPAS
-- ============================================================================
local Skills = {}
local Cooldowns = {}
local GlobalCastLock = false

local SkillMetadata = {
    {
        Id = "InfernalBurst",
        Name = "Infernal Burst",
        Subtitle = "Concentração & Fragmentação",
        Cooldown = 5.5,
        Accent = Color3.fromRGB(255, 130, 30),
        IconType = "Burst"
    },
    {
        Id = "FlameDragon",
        Name = "Flame Dragon",
        Subtitle = "Dragão Articulado Serpentino",
        Cooldown = 8.0,
        Accent = Color3.fromRGB(255, 85, 25),
        IconType = "Dragon"
    },
    {
        Id = "FireTornado",
        Name = "Fire Tornado",
        Subtitle = "Vórtice Espiral Multicamadas",
        Cooldown = 9.0,
        Accent = Color3.fromRGB(255, 185, 40),
        IconType = "Tornado"
    },
    {
        Id = "MeteorStrike",
        Name = "Meteor Strike",
        Subtitle = "Queda Orbital & Cratera",
        Cooldown = 11.0,
        Accent = Color3.fromRGB(235, 55, 20),
        IconType = "Meteor"
    },
    {
        Id = "FlameDash",
        Name = "Flame Dash",
        Subtitle = "Arrancada Ígnea & Corte",
        Cooldown = 4.0,
        Accent = Color3.fromRGB(255, 210, 65),
        IconType = "Dash"
    },
    {
        Id = "InfernoDomain",
        Name = "Inferno Domain",
        Subtitle = "Santuário de Pilares & Magma",
        Cooldown = 14.0,
        Accent = Color3.fromRGB(215, 35, 25),
        IconType = "Domain"
    }
}

for _, meta in ipairs(SkillMetadata) do
    Cooldowns[meta.Id] = 0
end

-- ----------------------------------------------------------------------------
-- HABILIDADE 1: INFERNAL BURST
-- Etapas: Preparação -> Antecipação -> Execução -> Impacto -> Fragmentação -> Dissipação -> Recuperação
-- ----------------------------------------------------------------------------
function Skills.InfernalBurst()
    local root = RigAnimator.RootPart
    if not root then return end

    GlobalCastLock = true

    -- Fase 1 & 2: Preparação e Antecipação (0.0s -> 0.55s)
    -- Jogador recua o tronco e concentra uma esfera comprimida nas duas mãos
    RigAnimator:SetPose({
        Root = CFrame.new(0, -0.25, 0) * CFrame.Angles(math.rad(-12), math.rad(-28), 0),
        Waist = CFrame.Angles(math.rad(-10), math.rad(-20), 0),
        RightShoulder = CFrame.Angles(math.rad(75), math.rad(-35), math.rad(-25)),
        RightElbow = CFrame.Angles(math.rad(45), 0, 0),
        LeftShoulder = CFrame.Angles(math.rad(75), math.rad(35), math.rad(25)),
        LeftElbow = CFrame.Angles(math.rad(45), 0, 0),
        Neck = CFrame.Angles(math.rad(8), math.rad(25), 0)
    })

    local chargeCore, chargeShape = PartPool:Acquire(
        "Ball", Enum.Material.Neon, Palette.CoreWhite,
        Vector3.new(0.4, 0.4, 0.4), root.CFrame, 0.05, 16, 2.8
    )
    local chargeShell, shellShape = PartPool:Acquire(
        "Ball", Enum.Material.Neon, Palette.GoldenOrange,
        Vector3.new(0.8, 0.8, 0.8), root.CFrame, 0.35, 0, 0
    )

    AddUpdater(0.55, function(dt, elapsed, alpha)
        if not RigAnimator.RootPart then return end
        local rHand = RigAnimator:GetHandPosition("Right")
        local lHand = RigAnimator:GetHandPosition("Left")
        local midHands = (rHand + lHand) * 0.5 + RigAnimator.RootPart.CFrame.LookVector * 0.8

        local pulse = 1 + math.sin(elapsed * 35) * 0.18
        local cSize = Math.Lerp(0.4, 2.4, Math.EaseOutCubic(alpha)) * pulse
        chargeCore.Size = Vector3.new(cSize, cSize, cSize)
        chargeCore.CFrame = CFrame.new(midHands)
        chargeCore.Color = Palette.CoreWhite:Lerp(Palette.BrightYellow, alpha * 0.6)

        chargeShell.Size = Vector3.new(cSize * 1.45, cSize * 1.45, cSize * 1.45)
        chargeShell.CFrame = CFrame.new(midHands)

        -- Partículas convergindo para o núcleo durante a antecipação
        if math.random() < 0.85 then
            local offset = Math.RandomVector(3.5, 6.5)
            SpawnParticle({
                Shape = "Block",
                Material = Enum.Material.Neon,
                Position = midHands + offset,
                Velocity = -offset * 3.8,
                OrientToVelocity = true,
                StartSize = Vector3.new(0.22, 0.22, 1.2),
                EndSize = Vector3.new(0.05, 0.05, 0.2),
                UseFlameGradient = true,
                StartTransparency = 0.1,
                EndTransparency = 0.9,
                Lifetime = 0.24
            })
        end

        if alpha > 0.72 then
            -- Estágio final da antecipação: compressão súbita antes do disparo
            RigAnimator:SetPose({
                Root = CFrame.new(0, -0.35, 0.2) * CFrame.Angles(math.rad(-18), math.rad(-40), 0),
                RightShoulder = CFrame.Angles(math.rad(95), math.rad(-45), math.rad(-15)),
                LeftShoulder = CFrame.Angles(math.rad(95), math.rad(45), math.rad(15))
            })
        end
    end, function()
        PartPool:Release(chargeCore, chargeShape)
        PartPool:Release(chargeShell, shellShape)

        local launchRoot = RigAnimator.RootPart
        if not launchRoot then
            GlobalCastLock = false
            RigAnimator:ResetPose()
            return
        end

        -- Fase 3: Execução / Disparo (0.55s -> 1.35s)
        local launchCF = launchRoot.CFrame
        local startPos = launchCF.Position + launchCF.LookVector * 3.2 + Vector3.new(0, 0.8, 0)
        local dir = Camera and Camera.CFrame.LookVector or launchCF.LookVector
        if dir.Y < -0.45 then
            dir = Vector3.new(dir.X, -0.45, dir.Z).Unit
        end

        RigAnimator:SetPose({
            Root = CFrame.new(0, -0.1, -0.35) * CFrame.Angles(math.rad(18), math.rad(15), 0),
            Waist = CFrame.Angles(math.rad(14), math.rad(10), 0),
            RightShoulder = CFrame.Angles(math.rad(95), 0, math.rad(12)),
            RightElbow = CFrame.Angles(math.rad(5), 0, 0),
            LeftShoulder = CFrame.Angles(math.rad(88), 0, math.rad(-12)),
            LeftElbow = CFrame.Angles(math.rad(5), 0, 0),
            Neck = CFrame.Angles(math.rad(-12), math.rad(-10), 0)
        })

        -- Onda de choque de recuo no disparo + arco cortante
        VFX.CreateShockwaveRing(startPos, dir, 1.2, 7.5, 0.45, 0.35, Palette.CoreWhite, Palette.GoldenOrange)
        VFX.CreateFireSlashArc(CFrame.lookAt(startPos, startPos + dir), 4.2, 130, 0.32, 25)
        TriggerCameraShake(startPos, 80, 0.7, 0.25)

        -- Projétil composto (Núcleo + Manto Turbulento)
        local projCore, projCoreShape = PartPool:Acquire(
            "Ball", Enum.Material.Neon, Palette.CoreWhite,
            Vector3.new(2.6, 2.6, 2.6), CFrame.new(startPos), 0, 24, 3.5
        )
        local projMantle, projMantleShape = PartPool:Acquire(
            "Ball", Enum.Material.Neon, Palette.GoldenOrange,
            Vector3.new(3.8, 3.8, 3.8), CFrame.new(startPos), 0.32, 0, 0
        )

        local currentPos = startPos
        local speed = 92
        local exploded = false

        local function DetonateBurst(hitPos, hitNormal)
            if exploded then return end
            exploded = true

            PartPool:Release(projCore, projCoreShape)
            PartPool:Release(projMantle, projMantleShape)

            -- Fase 4: Impacto Principal (Esfera de Sombra e Fogo + Ondas de Choque)
            TriggerCameraShake(hitPos, 130, 1.85, 0.55)
            VFX.CreateShadowCoreBurst(hitPos, 9.5, 0.65)
            VFX.CreateVolumetricFireCloud(hitPos, 7.5, 18)
            VFX.CreateShockwaveRing(hitPos, hitNormal, 2.0, 22.0, 0.9, 0.55, Palette.CoreWhite, Palette.CrimsonRed)
            VFX.CreateShockwaveRing(hitPos, Vector3.new(0, 1, 0), 1.5, 16.0, 0.6, 0.75, Palette.BrightYellow, Palette.DarkMagma)
            VFX.EmitSparks(hitPos, 28, 22, 58, 18)

            local groundHit = Math.GetGroundPosition(hitPos, 25)
            VFX.CreateDrippingLavaPool(groundHit, 8.5, 2.6)

            -- Fase 5 & 6: Efeitos Secundários (Fragmentação em Bombas de Cluster) e Dissipação
            local clusterCount = 7
            for i = 1, clusterCount do
                local ang = (i / clusterCount) * math.pi * 2 + (math.random() - 0.5) * 0.4
                local horizSpeed = 16 + math.random() * 18
                local initVel = Vector3.new(math.cos(ang) * horizSpeed, 24 + math.random() * 14, math.sin(ang) * horizSpeed)

                SpawnParticle({
                    Shape = "Ball",
                    Material = Enum.Material.Neon,
                    Position = hitPos + Vector3.new(0, 1.5, 0),
                    Velocity = initVel,
                    Acceleration = Vector3.new(0, -58, 0),
                    StartSize = Vector3.new(1.5, 1.5, 1.5),
                    EndSize = Vector3.new(0.8, 0.8, 0.8),
                    StartColor = Palette.BrightYellow,
                    EndColor = Palette.CrimsonRed,
                    StartTransparency = 0,
                    EndTransparency = 0.2,
                    CollideGround = true,
                    Bounce = 0.25,
                    Lifetime = 1.15,
                    OnGroundHit = function(frag, gPos, gNormal)
                        VFX.CreateVolumetricFireCloud(gPos, 3.2, 6)
                        VFX.CreateShockwaveRing(gPos, gNormal, 0.8, 6.5, 0.35, 0.38, Palette.BrightYellow, Palette.CrimsonRed)
                        VFX.CreateDrippingLavaPool(gPos, 3.2, 1.6)
                        VFX.EmitSparks(gPos, 8, 10, 26, 10)
                        frag.Age = frag.Lifetime -- encerra o fragmento após detonar
                    end,
                    CustomStep = function(frag)
                        if math.random() < 0.55 then
                            SpawnParticle({
                                Shape = "Ball",
                                Material = Enum.Material.Neon,
                                Position = frag.Position,
                                StartSize = Vector3.new(0.9, 0.9, 0.9),
                                EndSize = Vector3.new(0.1, 0.1, 0.1),
                                UseFlameGradient = true,
                                StartTransparency = 0.2,
                                EndTransparency = 1,
                                Lifetime = 0.25
                            })
                        end
                    end
                })
            end
        end

        AddUpdater(0.85, function(dt, elapsed)
            if exploded then return end
            local stepVec = dir * (speed * dt)
            local rayHit = Workspace:Raycast(currentPos, stepVec, RaycastParamsEnv)

            if rayHit then
                currentPos = rayHit.Position
                DetonateBurst(rayHit.Position, rayHit.Normal)
                return
            end

            currentPos = currentPos + stepVec
            projCore.CFrame = CFrame.new(currentPos)
            projMantle.CFrame = CFrame.new(currentPos) * CFrame.Angles(elapsed * 8, elapsed * 6, 0)

            -- Rastro espiral em torno da esfera (como na imagem superior esquerda)
            for s = 1, 2 do
                local spiralAng = elapsed * 22 + s * math.pi
                local right = dir:Cross(Vector3.new(0, 1, 0))
                if right.Magnitude < 0.05 then right = Vector3.new(1, 0, 0) else right = right.Unit end
                local up = right:Cross(dir).Unit
                local spiralOffset = (right * math.cos(spiralAng) + up * math.sin(spiralAng)) * 1.65

                SpawnParticle({
                    Shape = "Block",
                    Material = Enum.Material.Neon,
                    Position = currentPos + spiralOffset,
                    Velocity = -dir * 14 + spiralOffset * 2.5,
                    OrientToVelocity = true,
                    StartSize = Vector3.new(0.65, 0.65, 2.4),
                    EndSize = Vector3.new(0.1, 0.1, 0.4),
                    UseFlameGradient = true,
                    StartTransparency = 0.05,
                    EndTransparency = 1,
                    Lifetime = 0.32
                })
            end
        end, function()
            if not exploded then
                DetonateBurst(currentPos, Vector3.new(0, 1, 0))
            end
        end)

        -- Fase 7: Recuperação Corporal Suave
        AddUpdater(0.35, function() end, function()
            RigAnimator:ResetPose()
            GlobalCastLock = false
        end)
    end)
end

-- ----------------------------------------------------------------------------
-- HABILIDADE 2: FLAME DRAGON
-- Dragão de fogo articulado com mandíbula animada, chifres, bigodes e locomoção senoidal
-- ----------------------------------------------------------------------------
function Skills.FlameDragon()
    local root = RigAnimator.RootPart
    if not root then return end

    GlobalCastLock = true

    -- Fase 1 & 2: Preparação Ritualística e Antecipação (0.0s -> 0.5s)
    RigAnimator:SetPose({
        Root = CFrame.new(0, -0.3, 0) * CFrame.Angles(math.rad(-10), 0, 0),
        Waist = CFrame.Angles(math.rad(-15), 0, 0),
        RightShoulder = CFrame.Angles(math.rad(135), math.rad(-20), math.rad(-30)),
        LeftShoulder = CFrame.Angles(math.rad(135), math.rad(20), math.rad(30)),
        Neck = CFrame.Angles(math.rad(18), 0, 0)
    })

    local groundOrigin = Math.GetGroundPosition(root.Position, 20)
    VFX.CreateShockwaveRing(groundOrigin, Vector3.new(0, 1, 0), 1.5, 11.0, 0.35, 0.5, Palette.BrightYellow, Palette.CrimsonRed)

    AddUpdater(0.45, function(dt)
        if not RigAnimator.RootPart then return end
        if math.random() < 0.75 then
            local pPos = RigAnimator.RootPart.Position + Vector3.new((math.random() - 0.5) * 7, -2.5, (math.random() - 0.5) * 7)
            SpawnParticle({
                Shape = "Block",
                Material = Enum.Material.Neon,
                Position = pPos,
                Velocity = Vector3.new(0, 18 + math.random() * 12, 0),
                OrientToVelocity = true,
                StartSize = Vector3.new(0.35, 0.35, 1.8),
                EndSize = Vector3.new(0.05, 0.05, 0.4),
                UseFlameGradient = true,
                StartTransparency = 0.1,
                EndTransparency = 1,
                Lifetime = 0.35
            })
        end
    end, function()
        local castRoot = RigAnimator.RootPart
        if not castRoot then
            GlobalCastLock = false
            RigAnimator:ResetPose()
            return
        end

        -- Fase 3: Execução — Invocação e Voo Serpentino do Dragão Articulado
        RigAnimator:SetPose({
            Root = CFrame.new(0, 0.1, -0.25) * CFrame.Angles(math.rad(14), 0, 0),
            RightShoulder = CFrame.Angles(math.rad(90), math.rad(15), math.rad(25)),
            LeftShoulder = CFrame.Angles(math.rad(90), math.rad(-15), math.rad(-25)),
            Neck = CFrame.Angles(math.rad(-8), 0, 0)
        })

        local originCF = castRoot.CFrame
        local forward = (Camera and Camera.CFrame.LookVector or originCF.LookVector)
        forward = Vector3.new(forward.X, math.clamp(forward.Y, -0.25, 0.35), forward.Z).Unit
        local right = forward:Cross(Vector3.new(0, 1, 0)).Unit
        local up = right:Cross(forward).Unit

        local startPos = castRoot.Position + forward * 3.5 + Vector3.new(0, 2.2, 0)
        TriggerCameraShake(startPos, 95, 1.1, 0.45)

        -- Construção Anatômica do Dragão no Pool
        local numSegments = 18
        local dragonParts = {}

        local function AcquirePart(shape, color, size, lightR)
            local p, s = PartPool:Acquire(shape, Enum.Material.Neon, color, size, CFrame.new(startPos), 0.04, lightR, 3.0)
            table.insert(dragonParts, {Part = p, Shape = s})
            return p
        end

        -- Cabeça Articulada
        local upperSnout = AcquirePart("Wedge", Palette.BrightYellow, Vector3.new(3.2, 1.8, 4.6), 28)
        local lowerJaw   = AcquirePart("Wedge", Palette.DeepOrange, Vector3.new(2.7, 1.0, 3.8), 0)
        local leftEye    = AcquirePart("Ball", Palette.CoreWhite, Vector3.new(0.85, 0.85, 1.2), 0)
        local rightEye   = AcquirePart("Ball", Palette.CoreWhite, Vector3.new(0.85, 0.85, 1.2), 0)
        local leftHorn   = AcquirePart("Wedge", Palette.CrimsonRed, Vector3.new(0.65, 1.1, 4.4), 0)
        local rightHorn  = AcquirePart("Wedge", Palette.CrimsonRed, Vector3.new(0.65, 1.1, 4.4), 0)
        local leftWhisker = AcquirePart("Block", Palette.CoreWhite, Vector3.new(0.28, 0.28, 4.2), 0)
        local rightWhisker = AcquirePart("Block", Palette.CoreWhite, Vector3.new(0.28, 0.28, 4.2), 0)

        -- Vértebras e Cristas Dorsais
        local bodyNodes = {}
        for i = 1, numSegments do
            local frac = i / numSegments
            local radius = (1 - frac * 0.72) * 3.1 * (i == 1 and 0.9 or 1.0)
            local segColor = Math.SampleFlameColor(frac * 0.78)
            local coreSeg = AcquirePart("Ball", segColor, Vector3.new(radius, radius * 0.92, radius * 1.25), (i % 5 == 0) and 16 or 0)
            local dorsalFin = AcquirePart("Wedge", Palette.CrimsonRed, Vector3.new(0.45, radius * 0.85, radius * 1.1), 0)
            table.insert(bodyNodes, {Core = coreSeg, Fin = dorsalFin, Radius = radius})
        end

        -- Histórico de trilha para que o corpo siga perfeitamente a cabeça
        local pathHistory = {}
        for i = 1, 90 do
            pathHistory[i] = CFrame.lookAt(startPos, startPos + forward)
        end

        local headPos = startPos
        local dragonSpeed = 62
        local flightDuration = 1.65

        AddUpdater(flightDuration, function(dt, elapsed, alpha)
            -- Trajetória Senoidal Complexa 3D
            local waveH = math.cos(elapsed * 9.5) * 18.0
            local waveV = math.sin(elapsed * 6.5) * 9.5
            local currentVel = (forward * dragonSpeed) + (right * waveH) + (up * waveV)
            local nextPos = headPos + currentVel * dt

            local headCF = CFrame.lookAt(nextPos, nextPos + currentVel.Unit)
            headPos = nextPos

            table.insert(pathHistory, 1, headCF)
            if #pathHistory > 95 then
                table.remove(pathHistory)
            end

            -- Animação de Mandíbula (abre e fecha + cospe brasas)
            local jawAngle = math.rad(16 + math.abs(math.sin(elapsed * 14)) * 28)
            upperSnout.CFrame = headCF * CFrame.new(0, 0.65, -0.4)
            lowerJaw.CFrame = headCF * CFrame.new(0, -0.35, -0.1) * CFrame.Angles(-jawAngle, 0, math.rad(180))
            leftEye.CFrame = headCF * CFrame.new(-1.25, 1.05, -0.8)
            rightEye.CFrame = headCF * CFrame.new(1.25, 1.05, -0.8)
            leftHorn.CFrame = headCF * CFrame.new(-1.1, 1.6, 1.8) * CFrame.Angles(math.rad(28), math.rad(-22), 0)
            rightHorn.CFrame = headCF * CFrame.new(1.1, 1.6, 1.8) * CFrame.Angles(math.rad(28), math.rad(22), 0)

            local whiskerSwing = math.sin(elapsed * 18) * math.rad(25)
            leftWhisker.CFrame = headCF * CFrame.new(-1.8, 0.1, -1.6) * CFrame.Angles(0, math.rad(42) + whiskerSwing, 0)
            rightWhisker.CFrame = headCF * CFrame.new(1.8, 0.1, -1.6) * CFrame.Angles(0, math.rad(-42) - whiskerSwing, 0)

            -- Sopro de chamas da boca do dragão
            if math.random() < 0.75 then
                local mouthPos = (headCF * CFrame.new(0, 0.1, -2.5)).Position
                SpawnParticle({
                    Shape = "Ball",
                    Material = Enum.Material.Neon,
                    Position = mouthPos,
                    Velocity = currentVel.Unit * 25 + Math.RandomVector(4, 14),
                    StartSize = Vector3.new(1.4, 1.4, 1.4),
                    EndSize = Vector3.new(0.2, 0.2, 0.2),
                    UseFlameGradient = true,
                    StartTransparency = 0.1,
                    EndTransparency = 1,
                    Lifetime = 0.35
                })
            end

            -- Atualização Articulada de Cada Segmento Corporal
            for i = 1, numSegments do
                local histIndex = math.clamp(i * 3, 1, #pathHistory)
                local segCF = pathHistory[histIndex]
                local node = bodyNodes[i]
                node.Core.CFrame = segCF
                node.Fin.CFrame = segCF * CFrame.new(0, node.Radius * 0.72, 0) * CFrame.Angles(math.rad(18), 0, 0)

                if i % 3 == 0 and math.random() < 0.45 then
                    SpawnParticle({
                        Shape = "Block",
                        Material = Enum.Material.Neon,
                        Position = segCF.Position + Math.RandomVector(0.5, node.Radius),
                        Velocity = -segCF.LookVector * 10 + Vector3.new(0, 8, 0),
                        OrientToVelocity = true,
                        StartSize = Vector3.new(0.45, 0.45, 1.8),
                        EndSize = Vector3.new(0.08, 0.08, 0.3),
                        UseFlameGradient = true,
                        StartTransparency = 0.15,
                        EndTransparency = 1,
                        Lifetime = 0.38
                    })
                end
            end
        end, function()
            -- Fase 4, 5 & 6: Impacto Final do Dragão, Efeitos Secundários e Dissipação
            for _, item in ipairs(dragonParts) do
                PartPool:Release(item.Part, item.Shape)
            end

            local impactGround = Math.GetGroundPosition(headPos, 45)
            TriggerCameraShake(headPos, 150, 2.1, 0.65)
            VFX.CreateShadowCoreBurst(headPos, 11.5, 0.75)
            VFX.CreateVolumetricFireCloud(headPos, 9.5, 22)
            VFX.CreateShockwaveRing(headPos, Vector3.new(0, 1, 0), 2.5, 28.0, 1.1, 0.65, Palette.CoreWhite, Palette.CrimsonRed)
            VFX.CreateDrippingLavaPool(impactGround, 11.0, 3.0)
            VFX.EmitSparks(headPos, 36, 25, 65, 22)

            RigAnimator:ResetPose()
            GlobalCastLock = false
        end)
    end)
end

-- ----------------------------------------------------------------------------
-- HABILIDADE 3: FIRE TORNADO
-- Tornado cônico rotativo em múltiplas camadas, fitas espirais e fragmentos em órbita
-- ----------------------------------------------------------------------------
function Skills.FireTornado()
    local root = RigAnimator.RootPart
    if not root then return end

    GlobalCastLock = true

    -- Fase 1 & 2: Preparação e Antecipação (Giro de braços gerando redemoinho basal)
    RigAnimator:SetPose({
        Root = CFrame.new(0, -0.35, 0) * CFrame.Angles(math.rad(8), math.rad(-45), 0),
        RightShoulder = CFrame.Angles(math.rad(35), 0, math.rad(75)),
        LeftShoulder = CFrame.Angles(math.rad(35), 0, math.rad(-75)),
        Neck = CFrame.Angles(math.rad(-10), math.rad(35), 0)
    })

    local castForward = root.CFrame.LookVector
    local spawnCenter = Math.GetGroundPosition(root.Position + castForward * 10, 30)

    VFX.CreateShockwaveRing(spawnCenter, Vector3.new(0, 1, 0), 1.0, 12.0, 0.4, 0.45, Palette.BrightYellow, Palette.CrimsonRed)

    AddUpdater(0.42, function(dt, elapsed)
        for i = 1, 2 do
            local ang = elapsed * 16 + i * math.pi
            local r = 5.5 * (1 - elapsed)
            local pPos = spawnCenter + Vector3.new(math.cos(ang) * r, 0.5, math.sin(ang) * r)
            SpawnParticle({
                Shape = "Block",
                Material = Enum.Material.Neon,
                Position = pPos,
                Velocity = Vector3.new(-math.sin(ang) * 18, 14, math.cos(ang) * 18),
                OrientToVelocity = true,
                StartSize = Vector3.new(0.4, 0.4, 2.0),
                EndSize = Vector3.new(0.1, 0.1, 0.4),
                UseFlameGradient = true,
                StartTransparency = 0.05,
                EndTransparency = 1,
                Lifetime = 0.3
            })
        end
    end, function()
        -- Fase 3 & 4: Execução do Vórtice Multicamadas (como no topo central da imagem)
        RigAnimator:SetPose({
            Root = CFrame.new(0, 0.15, 0) * CFrame.Angles(math.rad(-12), math.rad(25), 0),
            RightShoulder = CFrame.Angles(math.rad(155), 0, math.rad(35)),
            LeftShoulder = CFrame.Angles(math.rad(155), 0, math.rad(-35)),
            Neck = CFrame.Angles(math.rad(15), math.rad(-20), 0)
        })

        TriggerCameraShake(spawnCenter, 120, 1.35, 0.6)
        VFX.CreateDrippingLavaPool(spawnCenter, 10.5, 4.2)

        local numRings = 16
        local numRibbons = 22
        local numDebris = 12
        local tornadoPool = {}

        local function GetPart(shape, mat, col, sz, lightR)
            local p, s = PartPool:Acquire(shape, mat, col, sz, CFrame.new(spawnCenter), 0.1, lightR, 2.6)
            table.insert(tornadoPool, {Part = p, Shape = s})
            return p
        end

        -- Camada 1: Anéis internos do funil
        local rings = {}
        for i = 1, numRings do
            local hFrac = (i - 1) / (numRings - 1)
            local col = Math.SampleFlameColor(hFrac * 0.75)
            local p = GetPart("Cylinder", Enum.Material.Neon, col, Vector3.new(1.6, 2, 2), (i % 4 == 0) and 22 or 0)
            table.insert(rings, {Part = p, HFrac = hFrac})
        end

        -- Camada 2: Fitas espirais ascendentes externas (vento incandescente)
        local ribbons = {}
        for i = 1, numRibbons do
            local p = GetPart("Block", Enum.Material.Neon, Palette.CoreWhite, Vector3.new(0.55, 3.2, 1.2), 0)
            table.insert(ribbons, {
                Part = p,
                BaseAngle = (i / numRibbons) * math.pi * 2,
                BaseHeight = (i / numRibbons),
                SpeedMult = 0.85 + (i % 3) * 0.2
            })
        end

        -- Camada 3: Fragmentos de rocha vulcânica em órbita
        local debris = {}
        for i = 1, numDebris do
            local p = GetPart("Block", Enum.Material.Slate, Palette.DarkMagma, Vector3.new(1.3, 1.1, 1.5), 0)
            table.insert(debris, {
                Part = p,
                Angle = (i / numDebris) * math.pi * 2,
                HFrac = math.random(),
                RadiusMult = 1.25 + math.random() * 0.45
            })
        end

        local tornadoCenter = spawnCenter
        local driftVel = castForward * 8.5
        local totalDuration = 3.8

        -- Libera o personagem após o início da canalização
        AddUpdater(0.55, function() end, function()
            RigAnimator:ResetPose()
            GlobalCastLock = false
        end)

        AddUpdater(totalDuration, function(dt, elapsed, alpha)
            tornadoCenter = Math.GetGroundPosition(tornadoCenter + driftVel * dt, 35)

            -- Envelope de crescimento (Início -> Clímax -> Dissipação)
            local scaleEnv = 1.0
            if alpha < 0.15 then
                scaleEnv = Math.EaseOutCubic(alpha / 0.15)
            elseif alpha > 0.82 then
                scaleEnv = 1.0 - Math.EaseInCubic((alpha - 0.82) / 0.18)
            end

            local maxHeight = 32.0 * scaleEnv
            local baseRadius = 3.2 * scaleEnv
            local topRadius = 11.8 * scaleEnv

            -- Atualização dos anéis cônicos com oscilação orgânica (Sway)
            for i, rData in ipairs(rings) do
                local h = rData.HFrac
                local y = h * maxHeight
                local rad = (baseRadius + (topRadius - baseRadius) * (h ^ 1.35)) * (1 + math.sin(elapsed * 12 + i) * 0.08)
                local swayX = math.sin(elapsed * 5.5 + h * 4.2) * (1.8 * h)
                local swayZ = math.cos(elapsed * 4.8 + h * 3.8) * (1.8 * h)

                local ringPos = tornadoCenter + Vector3.new(swayX, y + 0.8, swayZ)
                local tiltX = math.cos(elapsed * 7 + i) * math.rad(12)
                local tiltZ = math.sin(elapsed * 7 + i) * math.rad(12)

                rData.Part.Size = Vector3.new(2.2 * scaleEnv, rad * 2, rad * 2)
                rData.Part.CFrame = CFrame.new(ringPos)
                    * CFrame.Angles(tiltX, elapsed * 10 + i * 0.5, tiltZ)
                    * CFrame.Angles(0, 0, math.rad(90))
                rData.Part.Transparency = Math.Lerp(0.12, 0.95, 1 - scaleEnv)
            end

            -- Atualização das fitas espirais externas
            for i, rib in ipairs(ribbons) do
                local h = (rib.BaseHeight + elapsed * 0.75 * rib.SpeedMult) % 1.0
                local y = h * maxHeight
                local rad = (baseRadius + (topRadius - baseRadius) * (h ^ 1.35)) * 1.14
                local ang = rib.BaseAngle + elapsed * 13.5 + h * 7.5

                local pos = tornadoCenter + Vector3.new(math.cos(ang) * rad, y + 1.0, math.sin(ang) * rad)
                local tangent = Vector3.new(-math.sin(ang) * rad, maxHeight * 0.35, math.cos(ang) * rad).Unit

                rib.Part.Size = Vector3.new(0.48 * scaleEnv, 0.48 * scaleEnv, 4.5 * scaleEnv)
                rib.Part.CFrame = CFrame.lookAt(pos, pos + tangent)
                rib.Part.Color = Math.SampleFlameColor(h * 0.65)
                rib.Part.Transparency = 1 - (math.sin(h * math.pi) * scaleEnv * 0.92)
            end

            -- Atualização dos escombros orbitais
            for i, deb in ipairs(debris) do
                local h = (deb.HFrac + elapsed * 0.38) % 1.0
                local y = h * maxHeight
                local rad = (baseRadius + (topRadius - baseRadius) * h) * deb.RadiusMult
                local ang = deb.Angle + elapsed * 8.0

                local pos = tornadoCenter + Vector3.new(math.cos(ang) * rad, y + 1.2, math.sin(ang) * rad)
                deb.Part.CFrame = CFrame.new(pos) * CFrame.Angles(elapsed * 5 + i, elapsed * 7, 0)
                deb.Part.Transparency = 1 - scaleEnv
            end

            -- Emissão periódica de ondas na base e faíscas centrífugas
            if math.random() < 0.35 then
                VFX.EmitSparks(tornadoCenter + Vector3.new(0, 2, 0), 2, 18, 38, 22)
            end
        end, function()
            -- Fase 5 & 6: Explosão de Dissipação do Vórtice
            for _, item in ipairs(tornadoPool) do
                PartPool:Release(item.Part, item.Shape)
            end
            VFX.CreateShockwaveRing(tornadoCenter, Vector3.new(0, 1, 0), 3.0, 20.0, 0.8, 0.5, Palette.BrightYellow, Palette.CrimsonRed)
            VFX.CreateVolumetricFireCloud(tornadoCenter + Vector3.new(0, 4, 0), 6.5, 12)
            VFX.EmitSparks(tornadoCenter + Vector3.new(0, 5, 0), 22, 20, 50, 20)
        end)
    end)
end

-- ----------------------------------------------------------------------------
-- HABILIDADE 4: METEOR STRIKE
-- Meteorito colossal com núcleo de magma, cone de entrada atmosférica, rastro e impacto cataclísmico
-- ----------------------------------------------------------------------------
function Skills.MeteorStrike()
    local root = RigAnimator.RootPart
    if not root then return end

    GlobalCastLock = true

    local forward = (Camera and Camera.CFrame.LookVector or root.CFrame.LookVector)
    local flatForward = Vector3.new(forward.X, 0, forward.Z)
    if flatForward.Magnitude < 0.05 then flatForward = Vector3.new(0, 0, -1) else flatForward = flatForward.Unit end

    local targetGround = Math.GetGroundPosition(root.Position + flatForward * 26, 60)
    local skySpawn = targetGround + (-flatForward * 42) + Vector3.new(0, 95, 0)

    -- Fase 1 & 2: Preparação e Antecipação (Jogador ergue o braço invocando o selo de mira solar)
    RigAnimator:SetPose({
        Root = CFrame.new(0, -0.15, 0) * CFrame.Angles(math.rad(-8), math.rad(20), 0),
        RightShoulder = CFrame.Angles(math.rad(168), 0, math.rad(15)),
        RightElbow = CFrame.Angles(math.rad(10), 0, 0),
        LeftShoulder = CFrame.Angles(math.rad(45), 0, math.rad(-25)),
        Neck = CFrame.Angles(math.rad(22), math.rad(-15), 0)
    })

    -- Indicador de impacto no solo + portal de entrada nas nuvens
    VFX.CreateShockwaveRing(targetGround, Vector3.new(0, 1, 0), 14.0, 2.0, 0.4, 0.55, Palette.GoldenOrange, Palette.CoreWhite)
    VFX.CreateShockwaveRing(skySpawn, (targetGround - skySpawn).Unit, 2.0, 18.0, 0.8, 0.65, Palette.CoreWhite, Palette.CrimsonRed)

    AddUpdater(0.45, function() end, function()
        -- Puxão do braço para baixo comandando a queda do meteoro
        RigAnimator:SetPose({
            Root = CFrame.new(0, -0.3, 0) * CFrame.Angles(math.rad(16), math.rad(-15), 0),
            RightShoulder = CFrame.Angles(math.rad(45), math.rad(-20), math.rad(-10)),
            Neck = CFrame.Angles(math.rad(-10), 0, 0)
        })

        -- Fase 3: Execução — Queda Diagonal com Cone supersônico (como na parte inferior direita da imagem)
        local meteorPool = {}
        local function AcquireMeteorPart(shape, mat, col, sz, trans, lightR)
            local p, s = PartPool:Acquire(shape, mat, col, sz, CFrame.new(skySpawn), trans, lightR, 4.0)
            table.insert(meteorPool, {Part = p, Shape = s})
            return p
        end

        local magmaCore   = AcquireMeteorPart("Ball", Enum.Material.Neon, Palette.BrightYellow, Vector3.new(8.5, 8.5, 8.5), 0, 42)
        local outerPlasma = AcquireMeteorPart("Ball", Enum.Material.Neon, Palette.DeepOrange, Vector3.new(10.8, 10.8, 10.8), 0.35, 0)
        local shockCone   = AcquireMeteorPart("Cylinder", Enum.Material.Neon, Palette.CoreWhite, Vector3.new(18.0, 9.2, 9.2), 0.45, 0)

        -- Crostas de rocha vulcânica na superfície do meteoro
        local crusts = {}
        for i = 1, 8 do
            local cPart = AcquireMeteorPart("Block", Enum.Material.Slate, Palette.DarkMagma, Vector3.new(4.8, 4.2, 5.2), 0, 0)
            table.insert(crusts, {
                Part = cPart,
                Offset = Math.RandomVector(2.8, 3.6),
                Angles = CFrame.Angles(math.random() * 6, math.random() * 6, math.random() * 6)
            })
        end

        local fallDir = (targetGround - skySpawn).Unit
        local totalDist = (targetGround - skySpawn).Magnitude
        local fallDuration = 0.72

        AddUpdater(fallDuration, function(dt, elapsed, alpha)
            local easedAlpha = Math.EaseInCubic(alpha) * 0.4 + alpha * 0.6
            local currentPos = skySpawn:Lerp(targetGround, easedAlpha)
            local spinCF = CFrame.new(currentPos) * CFrame.Angles(elapsed * 7, elapsed * 9, elapsed * 5)

            magmaCore.CFrame = spinCF
            outerPlasma.CFrame = CFrame.lookAt(currentPos, currentPos + fallDir) * CFrame.new(0, 0, 1.8)

            -- Cone de reentrada atmosférica alinhado ao vetor de queda
            local coneCenter = currentPos - fallDir * 8.5
            shockCone.CFrame = CFrame.lookAt(coneCenter, coneCenter + fallDir) * CFrame.Angles(0, math.rad(90), 0)

            for _, c in ipairs(crusts) do
                c.Part.CFrame = spinCF * CFrame.new(c.Offset) * c.Angles
            end

            -- Linhas de velocidade e nuvens do rastro diagonal
            for s = 1, 3 do
                local trailOffset = Math.RandomVector(3.5, 6.5)
                SpawnParticle({
                    Shape = "Block",
                    Material = Enum.Material.Neon,
                    Position = currentPos + trailOffset,
                    Velocity = -fallDir * 45,
                    OrientToVelocity = true,
                    StartSize = Vector3.new(0.45, 0.45, 7.5),
                    EndSize = Vector3.new(0.08, 0.08, 1.5),
                    StartColor = Palette.CoreWhite,
                    EndColor = Palette.GoldenOrange,
                    StartTransparency = 0.1,
                    EndTransparency = 1,
                    Lifetime = 0.28
                })
            end

            SpawnParticle({
                Shape = "Ball",
                Material = Enum.Material.Neon,
                Position = currentPos - fallDir * 3.0 + Math.RandomVector(0, 2.5),
                Velocity = -fallDir * 12 + Math.RandomVector(2, 8),
                StartSize = Vector3.new(5.5, 5.5, 5.5),
                EndSize = Vector3.new(9.5, 9.5, 9.5),
                UseFlameGradient = true,
                SwitchToDarkCore = true,
                StartTransparency = 0.15,
                EndTransparency = 1,
                Lifetime = 0.55
            })
        end, function()
            -- Fase 4, 5 & 6: Impacto Cataclísmico, Feixe Ascendente, Cratera e Lava
            for _, item in ipairs(meteorPool) do
                PartPool:Release(item.Part, item.Shape)
            end

            TriggerCameraShake(targetGround, 180, 2.8, 0.85)
            VFX.CreateShadowCoreBurst(targetGround + Vector3.new(0, 2.5, 0), 16.5, 0.9)
            VFX.CreateVolumetricFireCloud(targetGround, 13.5, 26)
            VFX.CreateShockwaveRing(targetGround, Vector3.new(0, 1, 0), 3.0, 38.0, 1.4, 0.75, Palette.CoreWhite, Palette.CrimsonRed)
            VFX.CreateShockwaveRing(targetGround, Vector3.new(0, 1, 0), 2.0, 26.0, 0.8, 1.05, Palette.BrightYellow, Palette.DarkMagma)
            VFX.CreateDrippingLavaPool(targetGround, 15.0, 4.0)
            VFX.EmitSparks(targetGround + Vector3.new(0, 2, 0), 45, 30, 75, 28)

            -- Feixe de energia residual apontando na direção da trajetória de queda (como na base direita da imagem)
            local beamLength = 42
            local beamCenter = targetGround - fallDir * (beamLength * 0.5)
            local beamCF = CFrame.lookAt(beamCenter, beamCenter + fallDir) * CFrame.Angles(0, math.rad(90), 0)
            SpawnParticle({
                Shape = "Cylinder",
                Material = Enum.Material.Neon,
                CFrame = beamCF,
                Position = beamCenter,
                StartSize = Vector3.new(beamLength, 6.5, 6.5),
                EndSize = Vector3.new(beamLength, 0.2, 0.2),
                StartColor = Palette.CoreWhite,
                MidColor = Palette.BrightYellow,
                EndColor = Palette.DeepOrange,
                StartTransparency = 0.1,
                EndTransparency = 1,
                Lifetime = 0.65,
                CustomStep = function(p)
                    p.Part.CFrame = beamCF
                end
            })

            -- Anel de Rochas da Cratera + Ejeção Balística de Fragmentos Incandescentes
            local rockCount = 14
            for i = 1, rockCount do
                local ang = (i / rockCount) * math.pi * 2
                local rPos = targetGround + Vector3.new(math.cos(ang) * 11.5, 0.6, math.sin(ang) * 11.5)
                local rCF = CFrame.lookAt(rPos, targetGround) * CFrame.Angles(math.rad(-28), 0, 0)

                SpawnParticle({
                    Shape = "Block",
                    Material = Enum.Material.Slate,
                    CFrame = rCF,
                    Position = rPos,
                    StartSize = Vector3.new(4.2, 3.2, 5.0),
                    EndSize = Vector3.new(4.2, 0.2, 5.0),
                    StartColor = Palette.DarkMagma,
                    EndColor = Palette.CharcoalSmoke,
                    StartTransparency = 0,
                    EndTransparency = 1,
                    Lifetime = 2.8,
                    CustomStep = function(p)
                        p.Part.CFrame = rCF
                    end
                })
            end

            RigAnimator:ResetPose()
            GlobalCastLock = false
        end)
    end)
end

-- ----------------------------------------------------------------------------
-- HABILIDADE 5: FLAME DASH
-- Arrancada veloz com postura aerodinâmica, explosão de partida, rastro de pegadas e corte giratório na chegada
-- ----------------------------------------------------------------------------
function Skills.FlameDash()
    local root = RigAnimator.RootPart
    if not root then return end

    GlobalCastLock = true

    -- Fase 1 & 2: Agachamento de Ignição (0.0s -> 0.16s)
    RigAnimator:SetPose({
        Root = CFrame.new(0, -0.55, 0) * CFrame.Angles(math.rad(-32), 0, 0),
        Waist = CFrame.Angles(math.rad(-15), 0, 0),
        RightShoulder = CFrame.Angles(math.rad(-55), 0, math.rad(15)),
        LeftShoulder = CFrame.Angles(math.rad(-55), 0, math.rad(-15)),
        Neck = CFrame.Angles(math.rad(28), 0, 0)
    })

    local startOrigin = root.Position
    VFX.EmitSparks(startOrigin - Vector3.new(0, 2, 0), 12, 12, 28, 8)

    AddUpdater(0.16, function() end, function()
        local dashRoot = RigAnimator.RootPart
        if not dashRoot then
            GlobalCastLock = false
            RigAnimator:ResetPose()
            return
        end

        -- Fase 3: Execução da Arrancada + Efeito de Partida
        local startPos = dashRoot.Position
        local lookDir = dashRoot.CFrame.LookVector
        if Camera then
            local camFlat = Vector3.new(Camera.CFrame.LookVector.X, 0, Camera.CFrame.LookVector.Z)
            if camFlat.Magnitude > 0.1 then
                lookDir = camFlat.Unit
            end
        end

        local maxDashDist = 40
        local wallCheck = Workspace:Raycast(startPos, lookDir * maxDashDist, RaycastParamsEnv)
        local endPos = startPos + lookDir * maxDashDist
        if wallCheck then
            endPos = wallCheck.Position - lookDir * 3.0
        end

        -- Explosão de partida
        TriggerCameraShake(startPos, 70, 0.85, 0.25)
        VFX.CreateShockwaveRing(startPos, lookDir, 1.0, 9.5, 0.5, 0.35, Palette.CoreWhite, Palette.CrimsonRed)
        VFX.CreateVolumetricFireCloud(startPos, 4.2, 8)

        -- Manto de plasma em volta do corpo durante o Dash
        local auraCone, auraShape = PartPool:Acquire(
            "Cylinder", Enum.Material.Neon, Palette.BrightYellow,
            Vector3.new(8.5, 4.8, 4.8), dashRoot.CFrame, 0.35, 22, 3.0
        )

        local dashDuration = 0.26
        local stepCounter = 0

        AddUpdater(dashDuration, function(dt, elapsed, alpha)
            if not RigAnimator.RootPart then return end
            local eased = Math.EaseOutCubic(alpha)
            local newPos = startPos:Lerp(endPos, eased)

            RigAnimator.RootPart.CFrame = CFrame.lookAt(newPos, newPos + lookDir)
            RigAnimator.RootPart.AssemblyLinearVelocity = Vector3.zero

            auraCone.CFrame = CFrame.lookAt(newPos, newPos + lookDir) * CFrame.Angles(0, math.rad(90), 0)
            auraCone.Color = Math.SampleFlameColor(alpha * 0.5)

            -- Rastro contínuo de fitas de fogo e pegadas incandescentes
            stepCounter = stepCounter + 1
            local groundStep = Math.GetGroundPosition(newPos, 15)

            if stepCounter % 2 == 0 then
                VFX.CreateDrippingLavaPool(groundStep, 2.4, 1.1)
            end

            for s = -1, 1, 2 do
                local sideVec = lookDir:Cross(Vector3.new(0, 1, 0)) * (s * 1.8)
                SpawnParticle({
                    Shape = "Block",
                    Material = Enum.Material.Neon,
                    Position = newPos + sideVec + Vector3.new(0, (math.random() - 0.5) * 2, 0),
                    Velocity = -lookDir * 22 + sideVec * 3 + Vector3.new(0, 6, 0),
                    OrientToVelocity = true,
                    StartSize = Vector3.new(0.55, 0.55, 4.5),
                    EndSize = Vector3.new(0.08, 0.08, 0.8),
                    UseFlameGradient = true,
                    StartTransparency = 0.08,
                    EndTransparency = 1,
                    Lifetime = 0.35
                })
            end
        end, function()
            PartPool:Release(auraCone, auraShape)

            -- Fase 4, 5, 6 & 7: Chegada com Corte Giratório Duplo e Recuperação
            local arrivePos = RigAnimator.RootPart and RigAnimator.RootPart.Position or endPos
            local arriveCF = CFrame.lookAt(arrivePos, arrivePos + lookDir)

            RigAnimator:SetPose({
                Root = CFrame.new(0, -0.2, 0) * CFrame.Angles(math.rad(12), math.rad(38), 0),
                RightShoulder = CFrame.Angles(math.rad(90), math.rad(20), math.rad(85)),
                LeftShoulder = CFrame.Angles(math.rad(70), 0, math.rad(-55)),
                Neck = CFrame.Angles(0, math.rad(-35), 0)
            })

            TriggerCameraShake(arrivePos, 85, 1.1, 0.35)
            VFX.CreateFireSlashArc(arriveCF, 8.5, 210, 0.42, 15)
            VFX.CreateFireSlashArc(arriveCF, 7.2, 180, 0.38, -25)
            VFX.CreateShockwaveRing(arrivePos, Vector3.new(0, 1, 0), 1.5, 14.0, 0.55, 0.42, Palette.BrightYellow, Palette.CrimsonRed)
            VFX.EmitSparks(arrivePos, 24, 18, 45, 14)

            AddUpdater(0.28, function() end, function()
                RigAnimator:ResetPose()
                GlobalCastLock = false
            end)
        end)
    end)
end

-- ----------------------------------------------------------------------------
-- HABILIDADE 6: INFERNO DOMAIN
-- Santuário circular expansivo com runas rotativas, núcleo suspenso e 8 pilares de erupção
-- ----------------------------------------------------------------------------
function Skills.InfernoDomain()
    local root = RigAnimator.RootPart
    if not root then return end

    GlobalCastLock = true

    -- Fase 1 & 2: Preparação Solene (Jogador levita levemente e depois golpeia o solo)
    RigAnimator:SetPose({
        Root = CFrame.new(0, 1.2, 0) * CFrame.Angles(math.rad(-14), 0, 0),
        RightShoulder = CFrame.Angles(math.rad(145), 0, math.rad(45)),
        LeftShoulder = CFrame.Angles(math.rad(145), 0, math.rad(-45)),
        Neck = CFrame.Angles(math.rad(20), 0, 0)
    })

    local centerGround = Math.GetGroundPosition(root.Position, 35)

    AddUpdater(0.5, function(dt, elapsed, alpha)
        if not RigAnimator.RootPart then return end
        if alpha > 0.68 then
            -- Golpe descendente no chão
            RigAnimator:SetPose({
                Root = CFrame.new(0, -1.1, 0) * CFrame.Angles(math.rad(35), 0, 0),
                RightShoulder = CFrame.Angles(math.rad(55), math.rad(-25), math.rad(-10)),
                LeftShoulder = CFrame.Angles(math.rad(55), math.rad(25), math.rad(10)),
                Neck = CFrame.Angles(math.rad(-20), 0, 0)
            })
        end
    end, function()
        -- Fase 3 & 4: Expansão do Domínio Circular, Núcleo Solar e Pilares Individuais
        local domainRadius = 26.0
        local pillarCount = 8
        local domainPool = {}

        local function AcquireDomainPart(shape, mat, col, sz, trans, lightR)
            local p, s = PartPool:Acquire(shape, mat, col, sz, CFrame.new(centerGround), trans, lightR, 3.2)
            table.insert(domainPool, {Part = p, Shape = s})
            return p
        end

        TriggerCameraShake(centerGround, 160, 1.9, 0.7)
        VFX.CreateShockwaveRing(centerGround, Vector3.new(0, 1, 0), 2.0, domainRadius * 1.25, 0.9, 0.65, Palette.CoreWhite, Palette.CrimsonRed)

        -- Selo do Domínio no Chão + Raios Radiais
        local floorSeal = AcquireDomainPart("Cylinder", Enum.Material.Neon, Palette.CrimsonRed, Vector3.new(0.2, 1, 1), 0.25, 38)
        local innerSeal = AcquireDomainPart("Cylinder", Enum.Material.Neon, Palette.BrightYellow, Vector3.new(0.28, 1, 1), 0.15, 0)

        local runes = {}
        for i = 1, 12 do
            local rBlock = AcquireDomainPart("Block", Enum.Material.Neon, Palette.CoreWhite, Vector3.new(1.2, 0.32, 3.8), 0.1, 0)
            table.insert(runes, {Part = rBlock, Index = i})
        end

        -- Núcleo Central Suspenso (Esfera de Sombra rodeada por Anéis Giroscópicos)
        local coreDark  = AcquireDomainPart("Ball", Enum.Material.SmoothPlastic, Color3.fromRGB(12, 8, 10), Vector3.new(5.2, 5.2, 5.2), 0, 0)
        local coreShell = AcquireDomainPart("Ball", Enum.Material.Neon, Palette.GoldenOrange, Vector3.new(6.4, 6.4, 6.4), 0.35, 30)
        local gyroRing1 = AcquireDomainPart("Cylinder", Enum.Material.Neon, Palette.CoreWhite, Vector3.new(0.45, 9.5, 9.5), 0.15, 0)
        local gyroRing2 = AcquireDomainPart("Cylinder", Enum.Material.Neon, Palette.BrightYellow, Vector3.new(0.45, 11.2, 11.2), 0.2, 0)

        -- 8 Pilares de Fogo Perimetrais com Anéis Espirais Individuais
        local pillars = {}
        for i = 1, pillarCount do
            local pAngle = (i / pillarCount) * math.pi * 2
            local pPos = centerGround + Vector3.new(math.cos(pAngle) * (domainRadius * 0.82), 0, math.sin(pAngle) * (domainRadius * 0.82))
            local pCol = AcquireDomainPart("Cylinder", Enum.Material.Neon, Palette.GoldenOrange, Vector3.new(0.5, 4.2, 4.2), 0.12, 18)
            local pCore = AcquireDomainPart("Cylinder", Enum.Material.Neon, Palette.CoreWhite, Vector3.new(0.5, 2.2, 2.2), 0.05, 0)
            local pSpiral = AcquireDomainPart("Block", Enum.Material.Neon, Palette.CrimsonRed, Vector3.new(0.8, 2.5, 5.2), 0.15, 0)

            table.insert(pillars, {
                Pos = pPos,
                Angle = pAngle,
                Delay = (i - 1) * 0.07,
                Triggered = false,
                Outer = pCol,
                Inner = pCore,
                Spiral = pSpiral
            })
        end

        -- Libera a postura do jogador após o impacto de abertura
        AddUpdater(0.45, function() end, function()
            RigAnimator:ResetPose()
            GlobalCastLock = false
        end)

        local domainDuration = 4.8

        AddUpdater(domainDuration, function(dt, elapsed, alpha)
            local env = 1.0
            if alpha < 0.12 then
                env = Math.EaseOutCubic(alpha / 0.12)
            elseif alpha > 0.84 then
                env = 1.0 - Math.EaseInCubic((alpha - 0.84) / 0.16)
            end

            local curRadius = domainRadius * env
            floorSeal.Size = Vector3.new(0.22, curRadius * 2, curRadius * 2)
            floorSeal.CFrame = CFrame.new(centerGround + Vector3.new(0, 0.1, 0)) * CFrame.Angles(0, 0, math.rad(90))
            floorSeal.Transparency = Math.Lerp(0.25, 1.0, 1 - env)

            innerSeal.Size = Vector3.new(0.3, curRadius * 1.15, curRadius * 1.15)
            innerSeal.CFrame = CFrame.new(centerGround + Vector3.new(0, 0.16, 0)) * CFrame.Angles(0, 0, math.rad(90))
            innerSeal.Transparency = Math.Lerp(0.15, 1.0, 1 - env)

            -- Runas perimetrais girando em órbita
            for _, r in ipairs(runes) do
                local rAng = (r.Index / #runes) * math.pi * 2 + elapsed * 1.6
                local rPos = centerGround + Vector3.new(math.cos(rAng) * (curRadius * 0.92), 0.25, math.sin(rAng) * (curRadius * 0.92))
                r.Part.CFrame = CFrame.lookAt(rPos, centerGround + Vector3.new(0, 0.25, 0))
                r.Part.Size = Vector3.new(1.2 * env, 0.3 * env, 3.8 * env)
                r.Part.Transparency = 1 - env * 0.9
            end

            -- Animação do Núcleo Solar Suspenso
            local coreCenter = centerGround + Vector3.new(0, (8.5 + math.sin(elapsed * 4) * 1.2) * env, 0)
            local coreScale = (1 + math.sin(elapsed * 14) * 0.08) * env
            coreDark.Size = Vector3.new(5.2, 5.2, 5.2) * coreScale
            coreDark.CFrame = CFrame.new(coreCenter)
            coreDark.Transparency = 1 - env

            coreShell.Size = Vector3.new(6.5, 6.5, 6.5) * coreScale
            coreShell.CFrame = CFrame.new(coreCenter)
            coreShell.Transparency = Math.Lerp(0.32, 1.0, 1 - env)

            gyroRing1.Size = Vector3.new(0.45 * env, 9.8 * env, 9.8 * env)
            gyroRing1.CFrame = CFrame.new(coreCenter) * CFrame.Angles(elapsed * 5, elapsed * 3.5, 0)
            gyroRing1.Transparency = 1 - env * 0.85

            gyroRing2.Size = Vector3.new(0.45 * env, 11.4 * env, 11.4 * env)
            gyroRing2.CFrame = CFrame.new(coreCenter) * CFrame.Angles(-elapsed * 4, elapsed * 6, math.rad(45))
            gyroRing2.Transparency = 1 - env * 0.8

            -- Animação Individual de Cada Pilar
            for idx, pil in ipairs(pillars) do
                local localTime = elapsed - pil.Delay
                if localTime > 0 then
                    if not pil.Triggered then
                        pil.Triggered = true
                        VFX.CreateShockwaveRing(pil.Pos, Vector3.new(0, 1, 0), 1.0, 7.5, 0.4, 0.35, Palette.CoreWhite, Palette.GoldenOrange)
                        VFX.CreateDrippingLavaPool(pil.Pos, 4.2, 3.5)
                    end

                    local pAlpha = math.clamp(localTime / 0.35, 0, 1)
                    local pHeight = 28.0 * Math.EaseOutCubic(pAlpha) * env
                    local pulseW = (1 + math.sin(elapsed * 16 + idx) * 0.14) * env

                    local pCenter = pil.Pos + Vector3.new(0, pHeight * 0.5, 0)
                    local cylCF = CFrame.new(pCenter) * CFrame.Angles(0, 0, math.rad(90))

                    pil.Outer.Size = Vector3.new(pHeight, 4.4 * pulseW, 4.4 * pulseW)
                    pil.Outer.CFrame = cylCF
                    pil.Outer.Color = Math.SampleFlameColor(0.35 + math.sin(elapsed * 8 + idx) * 0.2)
                    pil.Outer.Transparency = Math.Lerp(0.15, 1.0, 1 - env)

                    pil.Inner.Size = Vector3.new(pHeight * 1.02, 2.3 * pulseW, 2.3 * pulseW)
                    pil.Inner.CFrame = cylCF
                    pil.Inner.Transparency = Math.Lerp(0.05, 1.0, 1 - env)

                    -- Espiral subindo ao redor do pilar
                    local sHeight = ((elapsed * 14 + idx * 3) % math.max(1, pHeight))
                    local sPos = pil.Pos + Vector3.new(0, sHeight, 0)
                    pil.Spiral.Size = Vector3.new(1.2 * env, 2.2 * env, 5.6 * env)
                    pil.Spiral.CFrame = CFrame.new(sPos) * CFrame.Angles(math.rad(25), elapsed * 12 + idx, 0)
                    pil.Spiral.Transparency = Math.Lerp(0.15, 1.0, 1 - env)
                else
                    pil.Outer.Transparency = 1
                    pil.Inner.Transparency = 1
                    pil.Spiral.Transparency = 1
                end
            end

            -- Arcos de plasma disparados do núcleo para os pilares + gêiseres aleatórios
            if math.random() < 0.35 then
                local chosen = pillars[math.random(1, #pillars)]
                if chosen.Triggered then
                    local targetTop = chosen.Pos + Vector3.new(0, 12 + math.random() * 10, 0)
                    local midPoint = (coreCenter + targetTop) * 0.5 + Vector3.new(0, 4, 0)
                    local dist = (targetTop - coreCenter).Magnitude
                    SpawnParticle({
                        Shape = "Block",
                        Material = Enum.Material.Neon,
                        CFrame = CFrame.lookAt(midPoint, targetTop),
                        Position = midPoint,
                        StartSize = Vector3.new(0.45, 0.45, dist),
                        EndSize = Vector3.new(0.05, 0.05, dist),
                        StartColor = Palette.CoreWhite,
                        EndColor = Palette.GoldenOrange,
                        StartTransparency = 0.05,
                        EndTransparency = 1,
                        Lifetime = 0.18,
                        CustomStep = function(p)
                            p.Part.CFrame = CFrame.lookAt(midPoint, targetTop)
                        end
                    })
                end
            end
        end, function()
            -- Fase 5 & 6: Colapso e Dissipação Final do Santuário
            for _, item in ipairs(domainPool) do
                PartPool:Release(item.Part, item.Shape)
            end

            TriggerCameraShake(centerGround, 170, 2.2, 0.65)
            VFX.CreateShadowCoreBurst(centerGround + Vector3.new(0, 6, 0), 14.0, 0.8)
            VFX.CreateVolumetricFireCloud(centerGround, 11.0, 20)
            VFX.CreateShockwaveRing(centerGround, Vector3.new(0, 1, 0), 4.0, domainRadius * 1.4, 1.1, 0.65, Palette.CoreWhite, Palette.CrimsonRed)
            VFX.EmitSparks(centerGround + Vector3.new(0, 5, 0), 40, 25, 65, 25)
        end)
    end)
end

-- Executor seguro de habilidades com validação de Cooldown
local function ActivateSkill(skillId)
    if not SystemActive then return end
    if GlobalCastLock then return end

    local now = os.clock()
    if Cooldowns[skillId] and now < Cooldowns[skillId] then
        return
    end

    if not RigAnimator:BindCharacter(LocalPlayer.Character) then
        return
    end

    local meta
    for _, m in ipairs(SkillMetadata) do
        if m.Id == skillId then
            meta = m
            break
        end
    end
    if not meta then return end

    Cooldowns[skillId] = now + meta.Cooldown
    if Skills[skillId] then
        Skills[skillId]()
    end
end

-- ============================================================================
-- 8. INTERFACE MOBILE TOUCH PERSONALIZADA (DRAGGABLE, MINIMIZÁVEL, ÍCONES)
-- ============================================================================
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")
local OldGui = PlayerGui:FindFirstChild("DeltaInfernalTouchUI")
if OldGui then
    OldGui:Destroy()
end

local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "DeltaInfernalTouchUI"
ScreenGui.ResetOnSpawn = false
ScreenGui.IgnoreGuiInset = true
ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
ScreenGui.Parent = PlayerGui

-- Container Principal posicionado de forma ergonômica no lado direito sem bloquear o joystick ou o botão de pulo
local MainContainer = Instance.new("Frame")
MainContainer.Name = "MainContainer"
MainContainer.AnchorPoint = Vector2.new(1, 0.5)
MainContainer.Position = UDim2.new(0.985, 0, 0.46, 0)
MainContainer.Size = UDim2.fromOffset(236, 208)
MainContainer.BackgroundColor3 = Palette.UiBackground
MainContainer.BackgroundTransparency = 0.14
MainContainer.BorderSizePixel = 0
MainContainer.Parent = ScreenGui

local UIScaleNode = Instance.new("UIScale")
UIScaleNode.Parent = MainContainer

local function UpdateResponsiveScale()
    local vp = Camera and Camera.ViewportSize or Vector2.new(1280, 720)
    local minDim = math.min(vp.X, vp.Y)
    UIScaleNode.Scale = math.clamp(minDim / 520, 0.78, 1.18)
end
UpdateResponsiveScale()
AddConnection(Camera:GetPropertyChangedSignal("ViewportSize"):Connect(UpdateResponsiveScale))

local MainCorner = Instance.new("UICorner")
MainCorner.CornerRadius = UDim.new(0, 14)
MainCorner.Parent = MainContainer

local MainStroke = Instance.new("UIStroke")
MainStroke.Color = Palette.UiBorder
MainStroke.Thickness = 1.6
MainStroke.Transparency = 0.25
MainStroke.Parent = MainContainer

-- Barra de Título (Arrastável no Touch + Botão Minimizar/Restaurar)
local HeaderBar = Instance.new("Frame")
HeaderBar.Name = "HeaderBar"
HeaderBar.Size = UDim2.new(1, 0, 0, 34)
HeaderBar.BackgroundColor3 = Color3.fromRGB(28, 22, 26)
HeaderBar.BackgroundTransparency = 0.1
HeaderBar.BorderSizePixel = 0
HeaderBar.Active = true
HeaderBar.Parent = MainContainer

local HeaderCorner = Instance.new("UICorner")
HeaderCorner.CornerRadius = UDim.new(0, 14)
HeaderCorner.Parent = HeaderBar

-- Indicador luminoso de fogo no título
local HeaderBadge = Instance.new("Frame")
HeaderBadge.Size = UDim2.fromOffset(10, 10)
HeaderBadge.Position = UDim2.new(0, 12, 0.5, -5)
HeaderBadge.BackgroundColor3 = Palette.UiAccent
HeaderBadge.BorderSizePixel = 0
HeaderBadge.Parent = HeaderBar

local BadgeCorner = Instance.new("UICorner")
BadgeCorner.CornerRadius = UDim.new(1, 0)
BadgeCorner.Parent = HeaderBadge

local TitleLabel = Instance.new("TextLabel")
TitleLabel.Size = UDim2.new(1, -68, 1, 0)
TitleLabel.Position = UDim2.fromOffset(28, 0)
TitleLabel.BackgroundTransparency = 1
TitleLabel.Font = Enum.Font.GothamBold
TitleLabel.Text = "INFERNAL ARTS"
TitleLabel.TextColor3 = Color3.fromRGB(255, 235, 210)
TitleLabel.TextSize = 13
TitleLabel.TextXAlignment = Enum.TextXAlignment.Left
TitleLabel.Parent = HeaderBar

local MinimizeBtn = Instance.new("TextButton")
MinimizeBtn.Name = "MinimizeBtn"
MinimizeBtn.Size = UDim2.fromOffset(26, 24)
MinimizeBtn.Position = UDim2.new(1, -32, 0.5, -12)
MinimizeBtn.BackgroundColor3 = Color3.fromRGB(45, 32, 36)
MinimizeBtn.BorderSizePixel = 0
MinimizeBtn.Font = Enum.Font.GothamBold
MinimizeBtn.Text = "–"
MinimizeBtn.TextColor3 = Palette.BrightYellow
MinimizeBtn.TextSize = 16
MinimizeBtn.Parent = HeaderBar

local MinCorner = Instance.new("UICorner")
MinCorner.CornerRadius = UDim.new(0, 7)
MinCorner.Parent = MinimizeBtn

-- Grade de Botões Touch (3 Colunas x 2 Linhas)
local SkillsHolder = Instance.new("Frame")
SkillsHolder.Name = "SkillsHolder"
SkillsHolder.Size = UDim2.new(1, -16, 1, -44)
SkillsHolder.Position = UDim2.fromOffset(8, 38)
SkillsHolder.BackgroundTransparency = 1
SkillsHolder.Parent = MainContainer

local GridLayout = Instance.new("UIGridLayout")
GridLayout.CellSize = UDim2.fromOffset(68, 76)
GridLayout.CellPadding = UDim2.fromOffset(8, 8)
GridLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
GridLayout.VerticalAlignment = Enum.VerticalAlignment.Center
GridLayout.SortOrder = Enum.SortOrder.LayoutOrder
GridLayout.Parent = SkillsHolder

-- Desenhador de Ícones Vetoriais Procedurais para cada Habilidade
local function BuildProceduralSkillIcon(parent, iconType, accentColor)
    local iconFrame = Instance.new("Frame")
    iconFrame.Name = "IconCanvas"
    iconFrame.Size = UDim2.fromOffset(32, 32)
    iconFrame.Position = UDim2.new(0.5, -16, 0, 7)
    iconFrame.BackgroundTransparency = 1
    iconFrame.Parent = parent

    local function AddShape(w, h, x, y, rot, col, radius)
        local f = Instance.new("Frame")
        f.Size = UDim2.fromOffset(w, h)
        f.AnchorPoint = Vector2.new(0.5, 0.5)
        f.Position = UDim2.fromOffset(x, y)
        f.Rotation = rot or 0
        f.BackgroundColor3 = col
        f.BorderSizePixel = 0
        f.Parent = iconFrame
        if radius then
            local c = Instance.new("UICorner")
            c.CornerRadius = radius
            c.Parent = f
        end
        return f
    end

    if iconType == "Burst" then
        AddShape(22, 22, 16, 16, 45, accentColor, UDim.new(0, 4))
        AddShape(22, 22, 16, 16, 0, Palette.BrightYellow, UDim.new(0, 4))
        AddShape(12, 12, 16, 16, 0, Palette.CoreWhite, UDim.new(1, 0))
    elseif iconType == "Dragon" then
        AddShape(10, 8, 9, 10, -25, Palette.CoreWhite, UDim.new(1, 0))
        AddShape(8, 8, 17, 14, 15, Palette.BrightYellow, UDim.new(1, 0))
        AddShape(7, 7, 23, 21, -20, accentColor, UDim.new(1, 0))
        AddShape(5, 5, 16, 26, 10, Palette.CrimsonRed, UDim.new(1, 0))
        AddShape(9, 3, 7, 6, -40, Palette.CrimsonRed, UDim.new(0, 2))
    elseif iconType == "Tornado" then
        AddShape(26, 5, 16, 7, -6, Palette.CoreWhite, UDim.new(1, 0))
        AddShape(20, 5, 16, 14, 6, Palette.BrightYellow, UDim.new(1, 0))
        AddShape(14, 5, 16, 21, -6, accentColor, UDim.new(1, 0))
        AddShape(8, 4, 16, 27, 4, Palette.CrimsonRed, UDim.new(1, 0))
    elseif iconType == "Meteor" then
        AddShape(18, 4, 11, 11, 45, Palette.GoldenOrange, UDim.new(1, 0))
        AddShape(14, 3, 9, 15, 45, Palette.BrightYellow, UDim.new(1, 0))
        AddShape(14, 14, 21, 21, 0, accentColor, UDim.new(1, 0))
        AddShape(8, 8, 22, 22, 0, Palette.CoreWhite, UDim.new(1, 0))
    elseif iconType == "Dash" then
        AddShape(16, 4, 18, 11, 35, Palette.CoreWhite, UDim.new(0, 2))
        AddShape(16, 4, 18, 19, -35, Palette.CoreWhite, UDim.new(0, 2))
        AddShape(12, 3, 10, 12, 35, accentColor, UDim.new(0, 2))
        AddShape(12, 3, 10, 18, -35, accentColor, UDim.new(0, 2))
    elseif iconType == "Domain" then
        local ring = AddShape(26, 26, 16, 16, 0, Color3.fromRGB(0, 0, 0), UDim.new(1, 0))
        ring.BackgroundTransparency = 1
        local st = Instance.new("UIStroke")
        st.Color = Palette.BrightYellow
        st.Thickness = 2.2
        st.Parent = ring
        AddShape(4, 16, 8, 15, 0, accentColor, UDim.new(0, 2))
        AddShape(4, 20, 16, 13, 0, Palette.CoreWhite, UDim.new(0, 2))
        AddShape(4, 16, 24, 15, 0, accentColor, UDim.new(0, 2))
    end
end

local ButtonRegistry = {}

for idx, meta in ipairs(SkillMetadata) do
    local btn = Instance.new("TextButton")
    btn.Name = meta.Id .. "_Button"
    btn.LayoutOrder = idx
    btn.BackgroundColor3 = Color3.fromRGB(30, 24, 28)
    btn.BorderSizePixel = 0
    btn.AutoButtonColor = false
    btn.Text = ""
    btn.Parent = SkillsHolder

    local btnCorner = Instance.new("UICorner")
    btnCorner.CornerRadius = UDim.new(0, 10)
    btnCorner.Parent = btn

    local btnStroke = Instance.new("UIStroke")
    btnStroke.Color = meta.Accent
    btnStroke.Thickness = 1.4
    btnStroke.Transparency = 0.35
    btnStroke.Parent = btn

    BuildProceduralSkillIcon(btn, meta.IconType, meta.Accent)

    local nameLbl = Instance.new("TextLabel")
    nameLbl.Size = UDim2.new(1, -6, 0, 26)
    nameLbl.Position = UDim2.new(0, 3, 1, -28)
    nameLbl.BackgroundTransparency = 1
    nameLbl.Font = Enum.Font.GothamBold
    nameLbl.Text = meta.Name
    nameLbl.TextColor3 = Color3.fromRGB(245, 235, 225)
    nameLbl.TextSize = 10
    nameLbl.TextWrapped = true
    nameLbl.Parent = btn

    -- Máscara de Cooldown
    local cdOverlay = Instance.new("Frame")
    cdOverlay.Name = "CooldownOverlay"
    cdOverlay.AnchorPoint = Vector2.new(0, 1)
    cdOverlay.Position = UDim2.new(0, 0, 1, 0)
    cdOverlay.Size = UDim2.new(1, 0, 0, 0)
    cdOverlay.BackgroundColor3 = Color3.fromRGB(10, 8, 10)
    cdOverlay.BackgroundTransparency = 0.22
    cdOverlay.BorderSizePixel = 0
    cdOverlay.Visible = false
    cdOverlay.Parent = btn

    local cdCorner = Instance.new("UICorner")
    cdCorner.CornerRadius = UDim.new(0, 10)
    cdCorner.Parent = cdOverlay

    local cdText = Instance.new("TextLabel")
    cdText.Size = UDim2.new(1, 0, 1, 0)
    cdText.BackgroundTransparency = 1
    cdText.Font = Enum.Font.GothamBlack
    cdText.Text = ""
    cdText.TextColor3 = Palette.BrightYellow
    cdText.TextSize = 15
    cdText.Visible = false
    cdText.Parent = btn

    btn.Activated:Connect(function()
        -- Feedback tátil visual no toque
        TweenService:Create(btn, TweenInfo.new(0.08), {BackgroundColor3 = meta.Accent}):Play()
        task.delay(0.12, function()
            if btn and btn.Parent then
                TweenService:Create(btn, TweenInfo.new(0.18), {BackgroundColor3 = Color3.fromRGB(30, 24, 28)}):Play()
            end
        end)
        ActivateSkill(meta.Id)
    end)

    ButtonRegistry[meta.Id] = {
        Button = btn,
        Overlay = cdOverlay,
        Text = cdText,
        Stroke = btnStroke,
        MaxCooldown = meta.Cooldown
    }
end

-- Sistema de Arrastar (Touch & Mouse) restrito ao HeaderBar para não interferir no joystick do Roblox
local isDragging = false
local dragInput = nil
local dragStart = Vector2.zero
local startPos = MainContainer.Position

HeaderBar.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
        isDragging = true
        dragStart = input.Position
        startPos = MainContainer.Position

        input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then
                isDragging = false
            end
        end)
    end
end)

HeaderBar.InputChanged:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseMovement then
        dragInput = input
    end
end)

AddConnection(UserInputService.InputChanged:Connect(function(input)
    if input == dragInput and isDragging then
        local delta = (input.Position - dragStart) / math.max(0.5, UIScaleNode.Scale)
        MainContainer.Position = UDim2.new(
            startPos.X.Scale,
            startPos.X.Offset + delta.X,
            startPos.Y.Scale,
            startPos.Y.Offset + delta.Y
        )
    end
end))

-- Botão Minimizar / Restaurar
local isMinimized = false
MinimizeBtn.Activated:Connect(function()
    isMinimized = not isMinimized
    if isMinimized then
        MinimizeBtn.Text = "+"
        SkillsHolder.Visible = false
        TweenService:Create(MainContainer, TweenInfo.new(0.22, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), {
            Size = UDim2.fromOffset(180, 34)
        }):Play()
    else
        MinimizeBtn.Text = "–"
        TweenService:Create(MainContainer, TweenInfo.new(0.25, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), {
            Size = UDim2.fromOffset(236, 208)
        }):Play()
        task.delay(0.12, function()
            if not isMinimized then
                SkillsHolder.Visible = true
            end
        end)
    end
end)

-- ============================================================================
-- 9. CONTROLADOR CENTRAL DE ATUALIZAÇÃO (SINGLE RENDER LOOP)
-- ============================================================================
RigAnimator:BindCharacter(LocalPlayer.Character)
AddConnection(LocalPlayer.CharacterAdded:Connect(function(newChar)
    task.wait(0.2)
    RigAnimator:BindCharacter(newChar)
end))

AddConnection(RunService.RenderStepped:Connect(function(dt)
    if not SystemActive then return end
    dt = math.min(dt, 0.05)

    -- 1. Atualiza as animações corporais procedurais
    RigAnimator:Step(dt)

    -- 2. Processa Updaters de Habilidades em múltiplas etapas (Iteração Reversa Segura)
    for i = #ActiveUpdaters, 1, -1 do
        local upd = ActiveUpdaters[i]
        if upd.Cancelled then
            table.remove(ActiveUpdaters, i)
        else
            upd.Elapsed = upd.Elapsed + dt
            local alpha = math.clamp(upd.Elapsed / math.max(0.001, upd.Duration), 0, 1)
            if upd.Step then
                upd.Step(dt, upd.Elapsed, alpha)
            end
            if upd.Elapsed >= upd.Duration then
                table.remove(ActiveUpdaters, i)
                if upd.Finish then
                    upd.Finish()
                end
            end
        end
    end

    -- 3. Processa todas as Partículas Ativas e devolve ao Pool ao expirar
    for i = #ActiveParticles, 1, -1 do
        local p = ActiveParticles[i]
        p.Age = p.Age + dt

        if p.Age >= p.Lifetime or not p.Part or not p.Part.Parent then
            PartPool:Release(p.Part, p.Shape)
            table.remove(ActiveParticles, i)
        else
            local alpha = p.Age / p.Lifetime

            -- Integração Cinemática (Velocidade + Aceleração + Arrasto Aerodinâmico)
            p.Velocity = p.Velocity + p.Acceleration * dt
            if p.Drag > 0 then
                p.Velocity = p.Velocity * math.max(0, 1 - p.Drag * dt)
            end

            local nextPos = p.Position + p.Velocity * dt

            -- Colisão com o solo quando habilitada
            if p.CollideGround and p.Velocity.Y < 0 then
                local hit = Workspace:Raycast(p.Position, nextPos - p.Position, RaycastParamsEnv)
                if hit then
                    nextPos = hit.Position + hit.Normal * 0.2
                    p.Velocity = Vector3.new(p.Velocity.X * 0.65, math.abs(p.Velocity.Y) * p.Bounce, p.Velocity.Z * 0.65)
                    if not p.HasHitGround then
                        p.HasHitGround = true
                        if p.OnGroundHit then
                            p.OnGroundHit(p, hit.Position, hit.Normal)
                        end
                    end
                end
            end

            p.Position = nextPos

            -- Interpolação de Tamanho (Suporta curva de 3 pontos: Start -> Mid -> End)
            if p.MidSize then
                if alpha < 0.45 then
                    p.Part.Size = p.StartSize:Lerp(p.MidSize, alpha / 0.45)
                else
                    p.Part.Size = p.MidSize:Lerp(p.EndSize, (alpha - 0.45) / 0.55)
                end
            else
                p.Part.Size = p.StartSize:Lerp(p.EndSize, alpha)
            end

            -- Interpolação de Cor e Material (Transição de Chama para Fumaça Densa)
            if p.UseFlameGradient then
                p.Part.Color = Math.SampleFlameColor(alpha)
                if p.SwitchToDarkCore and alpha > 0.72 then
                    p.Part.Material = Enum.Material.SmoothPlastic
                end
            elseif p.MidColor then
                if alpha < 0.5 then
                    p.Part.Color = p.StartColor:Lerp(p.MidColor, alpha * 2)
                else
                    p.Part.Color = p.MidColor:Lerp(p.EndColor, (alpha - 0.5) * 2)
                end
            else
                p.Part.Color = p.StartColor:Lerp(p.EndColor, alpha)
            end

            -- Transparência
            p.Part.Transparency = Math.Lerp(p.StartTransparency, p.EndTransparency, alpha ^ 1.35)

            -- Orientação Espacial ou CustomStep
            if p.CustomStep then
                p.CustomStep(p, dt, alpha)
            elseif p.OrientToVelocity and p.Velocity.Magnitude > 0.5 then
                p.Part.CFrame = CFrame.lookAt(p.Position, p.Position + p.Velocity.Unit)
            else
                p.Rotation = p.Rotation + p.RotSpeed * dt
                p.Part.CFrame = CFrame.new(p.Position) * CFrame.Angles(p.Rotation.X, p.Rotation.Y, p.Rotation.Z)
            end
        end
    end

    -- 4. Processa Tremor de Câmera (Camera Shake com decaimento por distância)
    if #ActiveShakes > 0 and Camera then
        local totalOffset = Vector3.zero
        local camPos = Camera.CFrame.Position

        for i = #ActiveShakes, 1, -1 do
            local sh = ActiveShakes[i]
            sh.Elapsed = sh.Elapsed + dt
            if sh.Elapsed >= sh.Duration then
                table.remove(ActiveShakes, i)
            else
                local fade = 1 - (sh.Elapsed / sh.Duration)
                local dist = (camPos - sh.Origin).Magnitude
                local distAtten = math.clamp(1 - (dist / sh.MaxDist), 0, 1)
                local mag = sh.Intensity * fade * distAtten
                totalOffset = totalOffset + Vector3.new(
                    (math.random() - 0.5) * 2 * mag,
                    (math.random() - 0.5) * 2 * mag,
                    (math.random() - 0.5) * 2 * mag
                )
            end
        end

        if totalOffset.Magnitude > 0.001 then
            Camera.CFrame = Camera.CFrame * CFrame.new(totalOffset)
        end
    end

    -- 5. Atualiza Indicadores Visuais de Cooldown na Interface Mobile
    local now = os.clock()
    for skillId, uiData in pairs(ButtonRegistry) do
        local endTime = Cooldowns[skillId] or 0
        local remaining = endTime - now
        if remaining > 0 then
            local frac = math.clamp(remaining / uiData.MaxCooldown, 0, 1)
            uiData.Overlay.Visible = true
            uiData.Overlay.Size = UDim2.new(1, 0, frac, 0)
            uiData.Text.Visible = true
            uiData.Text.Text = string.format("%.1fs", remaining)
        else
            uiData.Overlay.Visible = false
            uiData.Text.Visible = false
        end
    end
end))

-- ============================================================================
-- 10. FUNÇÃO GLOBAL DE LIMPEZA (GARANTIA CONTRA VAZAMENTO DE MEMÓRIA)
-- ============================================================================
_G.InfernalFireSystemCleanup = function()
    SystemActive = false
    GlobalCastLock = false

    for _, conn in ipairs(Connections) do
        if conn.Connected then
            conn:Disconnect()
        end
    end
    table.clear(Connections)
    table.clear(ActiveUpdaters)
    table.clear(ActiveParticles)
    table.clear(ActiveShakes)

    RigAnimator:RestoreDefaultsImmediate()

    if ScreenGui and ScreenGui.Parent then
        ScreenGui:Destroy()
    end
    if EffectsFolder and EffectsFolder.Parent then
        EffectsFolder:Destroy()
    end
end
