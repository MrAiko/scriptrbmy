-- Save the executor require locally and restore getgenv().require for game client scripts
local require = require
pcall(function()
    if getgenv and getgenv().require then
        getgenv().require = nil
    end
end)

-- Grow a Garden 2 Stock Scraper Script (Extreme-Optimized)
-- Run this script in a Roblox Executor (e.g. Wave, Synapse, Electron, Solara, etc.)

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local LocalPlayer = Players.LocalPlayer

-- ================= CONFIGURATION =================
local API_URL = "https://grow-a-garden-2-tracker.onrender.com/api/update-stock"
local API_PASSWORD = "mySuperSecretToken123"
local UPDATE_INTERVAL = 30       -- Fallback interval in seconds to update API
local POLL_INTERVAL = 0.5        -- Fast state poll interval; fruit data comes from FruitStock snapshot
local FRUIT_REQUEST_INTERVAL = 10 -- Fallback remote refresh interval if Snapshot event is missed
local DEBUG = false             -- Set to true only to diagnose scraper issues
local MOBILE_SAFE_MODE = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
local DESTROY_WORLD_ASSETS = false -- Never destroy Workspace parts; game controllers need plant.Base etc.
-- =================================================

local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")
local SharedModules = ReplicatedStorage:WaitForChild("SharedModules", 10)

function safeTaskSpawn(fn)
    if type(task) == "table" and type(task.spawn) == "function" then
        return task.spawn(fn)
    end
    if type(spawn) == "function" then
        return spawn(fn)
    end
    local thread = coroutine.create(fn)
    return coroutine.resume(thread)
end

function safeTaskDelay(seconds, fn)
    if type(task) == "table" and type(task.delay) == "function" then
        return task.delay(seconds, fn)
    end
    if type(delay) == "function" then
        return delay(seconds, fn)
    end
    return safeTaskSpawn(function()
        if type(task) == "table" and type(task.wait) == "function" then
            task.wait(seconds)
        elseif type(wait) == "function" then
            wait(seconds)
        end
        fn()
    end)
end

function safeTaskDefer(fn)
    if type(task) == "table" and type(task.defer) == "function" then
        return task.defer(fn)
    end
    return safeTaskDelay(0, fn)
end

function safeTaskWait(seconds)
    if type(task) == "table" and type(task.wait) == "function" then
        return task.wait(seconds)
    end
    if type(wait) == "function" then
        return wait(seconds)
    end
    return nil
end

-- ================== CLIENT OPTIMIZATION ==================
-- Aggressively reduce client CPU/GPU/RAM usage so the scraper runs with near-zero
-- overhead. All steps are wrapped in pcall so a failure never breaks scraping.
function optimizeClient()
    local RunService = game:GetService("RunService")

    -- 1. Stop 3D world rendering entirely.
    -- Some mobile executors (Delta/Android) become unstable when 3D rendering
    -- is disabled or the whole Workspace is locally destroyed, so phones use a
    -- lighter optimization profile.
    if not MOBILE_SAFE_MODE then
        pcall(function() RunService:Set3dRenderingEnabled(false) end)
    end

    -- 2. Minimize lighting/shadow cost.
    pcall(function()
        local lighting = game:GetService("Lighting")
        lighting.GlobalShadows = false
        lighting.OutdoorAmbient = Color3.fromRGB(128, 128, 128)
    end)

    -- 3. Force lowest graphics quality.
    pcall(function()
        settings().Rendering.QualityLevel = Enum.QualityLevel.Level01
        settings().Rendering.MeshPartDetailLevel = Enum.MeshPartDetailLevel.Level01
    end)

    -- 4. Move the camera far away so almost everything is frustum-culled.
    if not MOBILE_SAFE_MODE then
        pcall(function()
            local cam = workspace.CurrentCamera
            if cam then
                cam.CameraType = Enum.CameraType.Scriptable
                cam.CFrame = CFrame.new(0, 500000, 0)
            end
        end)
    end

    -- 5. Hide all CoreGui (chat, backpack, playerlist, ...).
    pcall(function()
        game:GetService("StarterGui"):SetCoreGuiEnabled(Enum.CoreGuiType.All, false)
    end)

    -- 6. Mute all sounds.
    pcall(function()
        game:GetService("SoundService").AmbientReverb = Enum.ReverbType.NoReverb
        for _, sound in ipairs(game:GetDescendants()) do
            if sound:IsA("Sound") then
                sound:Stop()
                sound.Volume = 0
            end
        end
        game.DescendantAdded:Connect(function(desc)
            if desc:IsA("Sound") then
                desc:Stop()
                desc.Volume = 0
            end
        end)
    end)

    -- 6.5. FPS capping & Physics throttling (PC optimizations)
    pcall(function()
        if setfpscap then
            setfpscap(5)
        end
    end)
    pcall(function()
        settings().Physics.PhysicsEnvironmentalThrottle = Enum.EnviromentalPhysicsThrottle.HeavyThrottle
        settings().Physics.AllowSleep = true
    end)
    -- Periodic Garbage Collection
    safeTaskSpawn(function()
        while true do
            safeTaskWait(30)
            pcall(function()
                collectgarbage("collect")
            end)
        end
    end)


    -- 7. Optional destructive cleanup. Keep disabled by default: several game
    --    controllers still read Workspace.Gardens.*.Plants.*.Base on the client.
    local function cleanInstance(instance)
        if not instance then return end
        if instance:IsA("Camera") or instance:IsA("Terrain") then return end
        if LocalPlayer and LocalPlayer.Character and (instance == LocalPlayer.Character or instance:IsDescendantOf(LocalPlayer.Character)) then
            return
        end
        -- Destroy other players' characters locally.
        local player = Players:GetPlayerFromCharacter(instance)
        if player and player ~= LocalPlayer then
            safeTaskDefer(function() pcall(function() instance:Destroy() end) end)
            return
        end
        -- Walk up the parent chain; if any ancestor is a moon/eclipse asset, keep it.
        local current = instance
        while current and current ~= workspace do
            local nameLower = string.lower(current.Name)
            if string.find(nameLower, "moon") or string.find(nameLower, "blood")
               or string.find(nameLower, "gold") or string.find(nameLower, "eclipse") then
                return
            end
            current = current.Parent
        end
        if instance:IsA("BasePart") or instance:IsA("Decal") or instance:IsA("Texture")
           or instance:IsA("SpecialMesh") or instance:IsA("ParticleEmitter")
           or instance:IsA("Beam") or instance:IsA("Trail") or instance:IsA("PostEffect") then
            safeTaskDefer(function() pcall(function() instance:Destroy() end) end)
        end
    end

    if DESTROY_WORLD_ASSETS and not MOBILE_SAFE_MODE then
        pcall(function()
            workspace.Terrain:Clear()
            for _, desc in ipairs(workspace:GetDescendants()) do cleanInstance(desc) end
        end)
        workspace.DescendantAdded:Connect(cleanInstance)
    end

    -- 8. Black overlay indicating optimization mode (no brand text).
    safeTaskSpawn(function()
        pcall(function()
            local pGui = LocalPlayer:WaitForChild("PlayerGui", 15)
            if not pGui then return end
            local existing = pGui:FindFirstChild("OptimizerOverlay")
            if existing then existing:Destroy() end

            local sg = Instance.new("ScreenGui")
            sg.Name = "OptimizerOverlay"
            sg.IgnoreGuiInset = true
            sg.DisplayOrder = 999999
            sg.ResetOnSpawn = false

            local frame = Instance.new("Frame")
            frame.Size = UDim2.new(1, 0, 1, 0)
            frame.BackgroundColor3 = Color3.fromRGB(10, 10, 10)
            frame.BorderSizePixel = 0
            frame.Parent = sg

            local content = Instance.new("Frame")
            content.Size = UDim2.new(0, 420, 0, 170)
            content.Position = UDim2.new(0.5, -210, 0.5, -85)
            content.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
            content.BorderSizePixel = 0
            content.Parent = frame

            local corner = Instance.new("UICorner")
            corner.CornerRadius = UDim.new(0, 8)
            corner.Parent = content

            local stroke = Instance.new("UIStroke")
            stroke.Color = Color3.fromRGB(0, 170, 255)
            stroke.Thickness = 1.5
            stroke.Parent = content

            local status = Instance.new("TextLabel")
            status.Size = UDim2.new(1, -20, 1, -20)
            status.Position = UDim2.new(0, 10, 0, 10)
            status.BackgroundTransparency = 1
            status.TextColor3 = Color3.fromRGB(220, 220, 220)
            status.Font = Enum.Font.SourceSans
            status.TextSize = 16
            status.TextWrapped = true
            status.TextYAlignment = Enum.TextYAlignment.Top
            status.Text = "Optimization: EXTREME (Void Mode)\n\n" ..
                          "Monitoring stock, weather, moon phases and fruit multipliers in the background...\n\n" ..
                          "Active & Connected"
            status.Parent = content

            sg.Parent = pGui
        end)
    end)
end

-- ================== NAME HELPERS ==================
function formatCamelCase(str)
    if not str then return nil end
    return (str:gsub("(%l)(%u)", "%1 %2"))
end

function cleanPhaseName(name)
    local formatted = formatCamelCase(name)
    local key = string.lower(tostring(formatted or name or "")):gsub("[^%w]", "")
    if key == "night" then return "Moon" end
    if key == "blood" or key == "bloodmoon" then return "Blood Moon" end
    if key == "gold" or key == "goldmoon" then return "Gold Moon" end
    if key == "chained" or key == "chainedmoon" then return "Chained Moon" end
    if key == "pizza" or key == "pizzamoon" then return "Pizza Moon" end
    if key == "rainbowmoon" then return "Rainbow Moon" end
    if key == "solar" or key == "solareclipse" then return "Solar Eclipse" end
    if key == "mega" or key == "megamoon" then return "Mega Moon" end
    return formatted
end

function normalizeName(name)
    return string.lower(tostring(name or "")):gsub("[^%w]", "")
end

function isTechnicalPhaseName(name)
    local key = normalizeName(name)
    return key == "" or string.find(key, "websocket") or string.find(key, "remote")
        or string.find(key, "controller") or string.find(key, "module")
        or string.find(key, "request") or string.find(key, "response")
        or string.find(key, "snapshot") or string.find(key, "event")
end

local PHASE_FALLBACK_IMAGES = {
    day = "100486757307207",
    sunset = "86217612022586",
    moon = "91446334780160",
    bloodmoon = "140465339393451",
    goldmoon = "84902063004871",
    rainbowmoon = "93602895495056",
    megamoon = "107925838920918",
}

function getPhaseKey(name)
    if not name or name == "" or isTechnicalPhaseName(name) then return nil end
    local key = normalizeName(name)
    if key == "night" then return "moon" end
    if key == "day" or key == "sunset" or key == "moon" then return key end
    if key == "blood" or key == "bloodmoon" then return "bloodmoon" end
    if key == "gold" or key == "goldmoon" then return "goldmoon" end
    if key == "chained" or key == "chainedmoon" then return "chainedmoon" end
    if key == "pizza" or key == "pizzamoon" then return "pizzamoon" end
    if key == "rainbowmoon" then return "rainbowmoon" end
    if key == "solar" or key == "solareclipse" then return "solareclipse" end
    if key == "mega" or key == "megamoon" then return "megamoon" end
    if string.sub(key, -4) == "moon" or string.find(key, "eclipse") then return key end
    return nil
end

function getPhaseFallbackImage(name)
    local phaseKey = getPhaseKey(name)
    return phaseKey and PHASE_FALLBACK_IMAGES[phaseKey] or nil
end

local isDecorativeWeatherCatalogName

local weatherDataCache = nil
local weatherDataByKeyCache = nil
local weatherDataCacheAt = -999
local WEATHER_DATA_REFRESH_INTERVAL = 5

function getWeatherValues()
    return ReplicatedStorage:FindFirstChild("WeatherValues")
end

function normalizeWeatherImageRef(value)
    if value == nil then return nil end
    local str = tostring(value)
    if str == "" or str == "0" or str == "112886786873408" then return nil end
    if string.sub(str, 1, 4) == "http" or string.sub(str, 1, 1) == "/" then return str end
    local id = string.match(str, "[iI][dD]=(%d+)") or string.match(str, "rbxassetid://(%d+)") or string.match(str, "%d+")
    if id and id ~= "0" and id ~= "112886786873408" then return id end
    return str
end

local RAINBOW_MOON_IMAGE_IDS = {
    ["93602895495056"] = true
}

function weatherImageRefContainsId(image, assetId)
    if not image or not assetId then return false end
    return string.find(tostring(image), tostring(assetId), 1, true) ~= nil
end

function isWeatherImageValidForName(name, image)
    if not image then return false end
    local key = normalizeName(name)
    if key == "rainbow" then
        local imageKey = normalizeName(image)
        if string.find(imageKey, "rainbowmoon") then
            return false
        end
        for assetId in pairs(RAINBOW_MOON_IMAGE_IDS) do
            if weatherImageRefContainsId(image, assetId) then
                return false
            end
        end
    end
    return true
end

function stripWeatherWrapperTokens(key)
    local stripped = key
    for _, token in ipairs({ "weather", "event", "active", "state", "card", "frame", "ui", "button", "container", "holder" }) do
        stripped = string.gsub(stripped, token, "")
    end
    return stripped
end

local WEATHER_CANONICAL_NAME_OVERRIDES = {
    lightning = "Thunderstorm"
}

function canonicalWeatherDisplayName(rawName)
    local key = normalizeName(rawName)
    return WEATHER_CANONICAL_NAME_OVERRIDES[key] or formatCamelCase(rawName) or rawName
end

function addWeatherDataEntry(entries, byKey, rawName, image)
    if type(rawName) ~= "string" or rawName == "" then return end
    if isTechnicalPhaseName(rawName) or isDecorativeWeatherCatalogName(rawName) then return end

    local displayName = canonicalWeatherDisplayName(rawName)
    local key = normalizeName(rawName)
    local displayKey = normalizeName(displayName)
    if key == "" or byKey[key] or byKey[displayKey] then return end

    local entry = {
        name = displayName,
        rawName = rawName,
        key = key,
        image = normalizeWeatherImageRef(image)
    }
    table.insert(entries, entry)
    byKey[key] = entry
    byKey[displayKey] = entry
    byKey[stripWeatherWrapperTokens(key)] = entry
end

function getWeatherDataEntries()
    local now = os.clock()
    if weatherDataCache and (now - weatherDataCacheAt) < WEATHER_DATA_REFRESH_INTERVAL then
        return weatherDataCache, weatherDataByKeyCache
    end

    local entries, byKey = {}, {}
    local shared = SharedModules or ReplicatedStorage:FindFirstChild("SharedModules")
    local weatherDataModule = shared and shared:FindFirstChild("WeatherData")
    if weatherDataModule then
        local weatherData = safeRequireModule(weatherDataModule)
        local rawData = type(weatherData) == "table" and weatherData.Data or nil
        if type(rawData) == "table" then
            for rawKey, item in pairs(rawData) do
                local rawName = nil
                local image = nil
                if type(item) == "table" then
                    rawName = item.Name or item.name or item.DisplayName or item.displayName or item.Id or item.ID
                        or (type(rawKey) == "string" and rawKey or nil)
                    image = item.IMG or item.img or item.Image or item.Icon or item.IconImage or item.ImageId or item.ImageID
                        or item.Asset or item.AssetId or item.AssetID or item.Texture or item.TextureId
                elseif type(item) == "string" then
                    rawName = item
                elseif type(rawKey) == "string" then
                    rawName = rawKey
                end
                addWeatherDataEntry(entries, byKey, rawName, image)
            end
        end
    end

    local weatherValues = getWeatherValues()
    if weatherValues then
        local okAttrs, attrs = pcall(function() return weatherValues:GetAttributes() end)
        if okAttrs and type(attrs) == "table" then
            for attrName, _ in pairs(attrs) do
                if type(attrName) == "string" then
                    local rawName = string.match(attrName, "(.+)_Playing$") or string.match(attrName, "(.+)_EndTime$")
                    addWeatherDataEntry(entries, byKey, rawName, nil)
                end
            end
        end
    end

    weatherDataCache = entries
    weatherDataByKeyCache = byKey
    weatherDataCacheAt = now
    return entries, byKey
end

function findWeatherDataEntryByName(name)
    local key = normalizeName(name)
    if key == "" then return nil end
    local _, byKey = getWeatherDataEntries()
    if byKey[key] then return byKey[key] end

    local stripped = stripWeatherWrapperTokens(key)
    if byKey[stripped] then return byKey[stripped] end

    local allowedSuffixes = {
        icon = true, image = true, vector = true, card = true, frame = true,
        ui = true, button = true, container = true, holder = true
    }
    for entryKey, entry in pairs(byKey) do
        if entryKey ~= "" and string.sub(key, 1, #entryKey) == entryKey and allowedSuffixes[string.sub(key, #entryKey + 1)] then
            return entry
        end
    end
    return nil
end

function cleanWeatherStateName(name)
    local entry = findWeatherDataEntryByName(name)
    return entry and entry.name or nil
end

function isKnownWeatherStateName(name)
    return cleanWeatherStateName(name) ~= nil
end

local DECORATIVE_WEATHER_NAMES = {
    background = true, bg = true, frame = true, shadow = true, glow = true,
    border = true, gradient = true, uigradient = true, uistroke = true,
    uicorner = true, overlay = true, shine = true, bevel = true,
    beveleffect = true, image = true, icon = true,
    vector = true, thumbnail = true, timer = true, time = true, clock = true,
    label = true, text = true, textlabel = true, title = true, container = true,
    content = true, main = true, mainframe = true
}

isDecorativeWeatherCatalogName = function(name)
    local key = normalizeName(name)
    if DECORATIVE_WEATHER_NAMES[key] then return true end
    return string.find(key, "background")
        or string.find(key, "gradient") or string.find(key, "shadow")
        or string.find(key, "bevel") or string.find(key, "overlay")
end

function findChildByNormalizedName(parent, names)
    if not parent then return nil end
    for _, targetName in ipairs(names) do
        local exact = parent:FindFirstChild(targetName)
        if exact then return exact end
    end
    local targets = {}
    for _, targetName in ipairs(names) do
        targets[normalizeName(targetName)] = true
    end
    for _, child in ipairs(parent:GetChildren()) do
        if targets[normalizeName(child.Name)] then
            return child
        end
    end
    return nil
end

local FALLBACK_PHASE_NAMES = {
    "Bloodmoon", "Goldmoon", "Chainedmoon", "Chained Moon", "Pizza Moon",
    "Rainbow Moon", "Solar Eclipse", "Mega Moon", "MegaMoon", "Megamoon", "Moon", "Night", "Sunset", "Day"
}

function findTimeCycleController()
    -- Never touch PlayerScripts.Controllers.TimeCycleController from executor
    -- context. Its phase modules are RobloxScript-only and can break the
    -- game's own controller when required outside a LocalScript.
    return nil
end

function getPhasesFolder()
    -- Do not scan/require TimeCycleController.Phases.* modules from an executor:
    -- some phase modules are RobloxScript-context only and throw in public executors.
    return nil
end

function getKnownPhaseNames()
    local names, seen = {}, {}
    local function add(name)
        if not name or name == "" then return end
        if isTechnicalPhaseName(name) then return end
        if isDecorativeWeatherCatalogName(name) then return end
        local key = normalizeName(name)
        if key ~= "" and not seen[key] then
            seen[key] = true
            table.insert(names, name)
        end
    end
    local phases = getPhasesFolder()
    if phases then
        for _, child in ipairs(phases:GetChildren()) do
            add(child.Name)
            add(formatCamelCase(child.Name))
        end
    end
    for _, name in ipairs(FALLBACK_PHASE_NAMES) do add(name) end
    return names
end

function isDefaultPhaseName(name)
    local key = normalizeName(name)
    return key == "day" or key == "sunset" or key == "moon" or key == "night"
end

local DECORATION_SUFFIXES = {
    "beams", "beam", "particles", "particle", "particlesemitter",
    "effect", "effects", "light", "lights", "glow", "glows",
    "aura", "auras", "fx", "visual", "visuals", "emitter", "emitters",
    "vfx", "ray", "rays", "mesh", "meshes", "model", "models",
    "trail", "trails", "sparkles", "sparkle", "smoke", "fire",
    "attachment", "attachments", "decal", "decals", "billboard", "billboardgui",
}

function isDecorationAsset(instanceKey, phaseKey)
    if #instanceKey <= #phaseKey then return false end
    if string.sub(instanceKey, 1, #phaseKey) ~= phaseKey then return false end
    local rest = string.sub(instanceKey, #phaseKey + 1)
    for _, suffix in ipairs(DECORATION_SUFFIXES) do
        if rest == suffix then return true end
    end
    return false
end

function findActivePhaseAsset(container, specialOnly)
    if not container then return nil end
    local instances = {}
    for _, child in ipairs(container:GetChildren()) do
        table.insert(instances, child)
        if (child:IsA("Folder") or child:IsA("Model")) and child.Name ~= "Terrain" then
            if not (game.Players and game.Players:GetPlayerFromCharacter(child)) then
                for _, subChild in ipairs(child:GetChildren()) do
                    table.insert(instances, subChild)
                end
            end
        end
    end
    local phaseNames = getKnownPhaseNames()
    for _, phaseName in ipairs(phaseNames) do
        if not specialOnly or not isDefaultPhaseName(phaseName) then
            local phaseKey = normalizeName(phaseName)
            local cleanKey = normalizeName(cleanPhaseName(phaseName))
            for _, instance in ipairs(instances) do
                local instanceKey = normalizeName(instance.Name)
                if not (isDecorationAsset(instanceKey, phaseKey) or isDecorationAsset(instanceKey, cleanKey)) then
                    if instanceKey == phaseKey or instanceKey == cleanKey
                       or instanceKey == "active" .. phaseKey or instanceKey == "active" .. cleanKey then
                        return cleanPhaseName(phaseName)
                    end
                end
            end
        end
    end
    return nil
end

-- ================== HTTP ==================
function addHttpCandidate(list, fn)
    if type(fn) == "function" then
        for _, existing in ipairs(list) do
            if existing == fn then return end
        end
        table.insert(list, fn)
    end
end

function getExecutorHttpCandidates()
    local list = {}
    addHttpCandidate(list, request)
    addHttpCandidate(list, http_request)
    addHttpCandidate(list, syn and syn.request)
    addHttpCandidate(list, http and http.request)
    addHttpCandidate(list, fluxus and fluxus.request)
    addHttpCandidate(list, krnl and krnl.request)
    addHttpCandidate(list, delta and delta.request)
    addHttpCandidate(list, Delta and Delta.request)

    local ok, env = pcall(function()
        return getgenv and getgenv() or nil
    end)
    if ok and type(env) == "table" then
        addHttpCandidate(list, env.request)
        addHttpCandidate(list, env.http_request)
        addHttpCandidate(list, env.syn and env.syn.request)
        addHttpCandidate(list, env.http and env.http.request)
        addHttpCandidate(list, env.fluxus and env.fluxus.request)
        addHttpCandidate(list, env.krnl and env.krnl.request)
        addHttpCandidate(list, env.delta and env.delta.request)
        addHttpCandidate(list, env.Delta and env.Delta.request)
    end

    return list
end

function normalizeHttpResult(response)
    if type(response) == "table" then
        local status = response.StatusCode or response.Status or response.status or response.status_code or response.code
        local body = response.Body or response.body or response.Response or response.response or response.Data or response.data or ""
        status = tonumber(status)
        if not status or (status >= 200 and status < 300) then
            return true, body
        end
        return false, "HTTP " .. tostring(status) .. ": " .. tostring(body)
    end
    if type(response) == "string" then
        return true, response
    end
    if response == true then
        return true, ""
    end
    return false, "no response"
end

function makeHttpRequest(url, method, headers, body)
    local lastErr = nil
    for _, requestFunc in ipairs(getExecutorHttpCandidates()) do
        local payloads = {
            { Url = url, Method = method, Headers = headers, Body = body },
            { url = url, method = method, headers = headers, body = body },
        }
        for _, payload in ipairs(payloads) do
            local ok, response = pcall(function()
                return requestFunc(payload)
            end)
            if ok then
                local success, result = normalizeHttpResult(response)
                if success then
                    return true, result
                end
                lastErr = result
            else
                lastErr = response
            end
        end
    end

    local requestAsyncOk, requestAsyncResult = pcall(function()
        return HttpService:RequestAsync({
            Url = url,
            Method = method,
            Headers = headers,
            Body = body
        })
    end)
    if requestAsyncOk then
        local success, result = normalizeHttpResult(requestAsyncResult)
        if success then
            return true, result
        end
        lastErr = result
    else
        lastErr = requestAsyncResult
    end

    local success, res = pcall(function()
        return HttpService:PostAsync(url, body, Enum.HttpContentType.ApplicationJson, false, headers)
    end)
    if success then
        return true, res
    end
    lastErr = res

    local gamePostOk, gamePostResult = pcall(function()
        return game:HttpPost(url, body, Enum.HttpContentType.ApplicationJson, false, headers)
    end)
    if gamePostOk then
        return true, gamePostResult
    end
    lastErr = gamePostResult

    return false, tostring(lastErr or "no supported HTTP request function")
end

-- ================== WEBSOCKET CLIENT ==================
local wsConnection = nil
local isWsConnecting = false

function getWebSocketClient()
    if wsConnection then return wsConnection end
    if isWsConnecting then return nil end
    
    local wsConnectFunc = WebSocket and WebSocket.connect or (syn and syn.websocket and syn.websocket.connect)
    if not wsConnectFunc then
        return nil
    end
    
    isWsConnecting = true
    safeTaskSpawn(function()
        local wsUrl = API_URL:gsub("https://", "wss://"):gsub("http://", "ws://")
        if wsUrl:sub(-10) == "/api/stock" then
            wsUrl = wsUrl:sub(1, -11)
        elseif wsUrl:sub(-11) == "/api/stock/" then
            wsUrl = wsUrl:sub(1, -12)
        end
        
        if DEBUG then
            print("[Grow a Garden 2 Stocker] Connecting WebSocket to: " .. wsUrl)
        end
        
        local success, ws = pcall(function()
            return wsConnectFunc(wsUrl)
        end)
        
        isWsConnecting = false
        if success and ws then
            if DEBUG then
                print("[Grow a Garden 2 Stocker] WebSocket connected successfully!")
            end
            wsConnection = ws
            
            local onMessage = ws.OnMessage or ws.on_message
            local onClose = ws.OnClose or ws.on_close
            
            if onClose then
                onClose:Connect(function()
                    if DEBUG then
                        print("[Grow a Garden 2 Stocker] WebSocket closed.")
                    end
                    wsConnection = nil
                end)
            end
            
            if onMessage then
                onMessage:Connect(function(msg)
                    if DEBUG then
                        print("[Grow a Garden 2 Stocker] WebSocket msg: " .. tostring(msg))
                    end
                end)
            end
        else
            warn("[Grow a Garden 2 Stocker] WebSocket connection failed: " .. tostring(ws))
        end
    end)
    
    return wsConnection
end


-- ================== RESTOCK TIMES ==================
function getRestockTimes()
    local times = {
        CrateShop = { last = 0, next = 0 },
        GearShop = { last = 0, next = 0 },
        SeedShop = { last = 0, next = 0 }
    }
    local StockValues = ReplicatedStorage:FindFirstChild("StockValues")
    if StockValues then
        for _, shopFolder in ipairs(StockValues:GetChildren()) do
            if times[shopFolder.Name] then
                local lastVal, nextVal = shopFolder:FindFirstChild("UnixLastRestock"), shopFolder:FindFirstChild("UnixNextRestock")
                if lastVal then
                    local ok, ret = pcall(function() return lastVal.Value end)
                    if ok and type(ret) == "number" then times[shopFolder.Name].last = ret end
                end
                if nextVal then
                    local ok, ret = pcall(function() return nextVal.Value end)
                    if ok and type(ret) == "number" then times[shopFolder.Name].next = ret end
                end
            end
        end
    end
    return times
end

-- ================== ITEM PARSING ==================
local RARITY_NAMES = {
    common = "Common", uncommon = "Uncommon", rare = "Rare", epic = "Epic",
    legendary = "Legendary", secret = "Secret", exotic = "Exotic", super = "Super",
    mythic = "Mythic", divine = "Divine", prismatic = "Prismatic", transendent = "Transendent"
}

local GENERIC_ITEM_NAMES = {
    frame = true, main_frame = true, template = true, itemtemplate = true,
    itemframe = true, generateitems = true, item_size = true, new_frame = true,
    uilistlayout = true, uigridlayout = true, uipadding = true, uistroke = true,
    uigradient = true, uicorner = true, viewportframe = true, imagedisplay = true,
    rarity = true, rarity_text = true, cost_text = true, stock_text = true,
    seed_text = true, name = true, textlabel = true, textbutton = true,
    shadow = true, beveleffect = true, sunburst = true, vector = true,
    inlettexture = true, buttons = true, fruitcard = true, scrollingframe = true,
    fruitstockprice = true, normalshop = true, normal = true, header = true,
    fruits = true, fruit = true, seeds = true, seed = true, crops = true, crop = true,
    items = true, item = true, assets = true, asset = true, textures = true, texture = true,
    images = true, image = true, icons = true, icon = true, models = true, model = true,
    products = true, product = true, plants = true, plant = true, vegetables = true, vegetable = true,
    flowers = true, flower = true, deals = true, deal = true, shop = true, inventory = true,
    backpack = true, character = true
}

function isTechnicalItem(name)
    local ln = string.lower(name)
    return ln == "itemtemplate" or ln == "template" or ln == "padding" or ln == "uipadting"
        or ln == "uipadding" or ln == "robux_shelf" or ln == "sheckles_shelf" or ln == "shackles_shelf"
        or ln == "buttons" or string.find(ln, "padding") or string.find(ln, "template")
        or string.find(ln, "shelf") or string.find(ln, "layout")
end

function isGenericItemName(name)
    if not name or name == "" then return true end
    local ln = string.lower(name)
    if GENERIC_ITEM_NAMES[ln] then return true end
    if ln:match("^itemframe_") or ln:match("^activedeal_") or ln:match("^item_%d+") then return true end
    return isTechnicalItem(name)
end

function detectRarity(itemRoot)
    local rarityFrame = itemRoot:FindFirstChild("Rarity", true)
    if rarityFrame then
        for _, c in ipairs(rarityFrame:GetChildren()) do
            local r = RARITY_NAMES[string.lower(c.Name)]
            if r then return r end
        end
    end
    local rarityText = itemRoot:FindFirstChild("Rarity_Text", true)
    if rarityText and rarityText:IsA("TextLabel") then
        local t = string.lower(rarityText.Text or "")
        for kw, val in pairs(RARITY_NAMES) do
            if string.find(t, kw) then return val end
        end
    end
    return "Common"
end

-- Image element names that represent the ACTUAL item icon, in priority order.
local ITEM_ICON_NAMES = { "imagedisplay", "vector", "icon", "thumbnail", "itemimage", "fruitvector" }
-- Image element names that are decorative chrome (background, bevel, glow, shadow)
-- and must NEVER be picked as the item image. They share one asset id across all
-- cards, which is why every item previously got the same wrong picture.
local DECORATIVE_IMAGE_NAMES = {
    beveleffect = true, sunburst = true, shadow = true, frame = true,
    background = true, bg = true, border = true, gradient = true,
    uigradient = true, uistroke = true, uicorner = true, glow = true,
    shine = true, overlay = true, rarity = true, main_frame = true,
}

function detectImage(itemRoot)
    -- Pass 1: prefer ImageLabels/ImageButtons whose Name marks them as the item icon.
    -- This is the correct icon (ImageDisplay / Vector in the new card layout).
    for _, desc in ipairs(itemRoot:GetDescendants()) do
        if desc:IsA("ImageLabel") or desc:IsA("ImageButton") then
            local dn = string.lower(desc.Name)
            local isIcon = false
            for _, icon in ipairs(ITEM_ICON_NAMES) do
                if dn == icon then isIcon = true; break end
            end
            if isIcon then
                local img = desc.Image or ""
                local assetId = string.match(img, "%d+")
                if assetId and assetId ~= "112886786873408" then
                    return assetId
                end
            end
        end
    end

    -- Pass 2: fall back to any ImageLabel that is NOT a known decorative element.
    -- This avoids returning the shared card-chrome image for every item.
    for _, desc in ipairs(itemRoot:GetDescendants()) do
        if desc:IsA("ImageLabel") or desc:IsA("ImageButton") then
            local dn = string.lower(desc.Name)
            if not DECORATIVE_IMAGE_NAMES[dn] then
                local img = desc.Image or ""
                local assetId = string.match(img, "%d+")
                if assetId and assetId ~= "112886786873408" then
                    return assetId
                end
            end
        end
    end
    return nil
end

function getNestedText(itemRoot, containerName)
    local container = itemRoot:FindFirstChild(containerName, true)
    if not container then return nil end
    if container:IsA("TextLabel") and container.Text and container.Text ~= "" then
        return container.Text
    end
    for _, desc in ipairs(container:GetDescendants()) do
        if desc:IsA("TextLabel") and desc.Text and desc.Text ~= "" then
            return desc.Text
        end
    end
    return nil
end

function scrapeShop(container)
    local items = {}
    if not container or not container.Parent then return items end
    local ok, descendants = pcall(function() return container:GetDescendants() end)
    if not ok or not descendants then return items end
    for _, desc in ipairs(descendants) do
        pcall(function()
            if desc and desc.Parent and desc:IsA("GuiObject") and not isGenericItemName(desc.Name) then
                local mainFrame = desc:FindFirstChild("Main_Frame")
                local contentRoot = mainFrame or desc
                local hasFields = contentRoot:FindFirstChild("Cost_Text", true)
                    or contentRoot:FindFirstChild("Stock_Text", true)
                    or contentRoot:FindFirstChild("Seed_Text", true)
                    or contentRoot:FindFirstChild("Rarity", true)
                if mainFrame or hasFields then
                    local stockVal = 0
                    local priceVal = getNestedText(contentRoot, "Cost_Text") or "Unknown"
                    local stockText = getNestedText(contentRoot, "Stock_Text") or getNestedText(contentRoot, "Seed_Text")
                    if stockText then
                        local lt = string.lower(stockText)
                        if string.find(lt, "no stock") or stockText == "" then
                            stockVal = 0
                        else
                            local parsed = string.match(stockText, "(%d+)")
                            if parsed then stockVal = tonumber(parsed) end
                        end
                    end
                    local noStock = contentRoot:FindFirstChild("NoStock", true)
                    if noStock and noStock:IsA("GuiObject") and noStock.Visible == true then
                        stockVal = 0
                    end
                    table.insert(items, {
                        name = desc.Name,
                        stock = stockVal,
                        price = priceVal,
                        rarity = detectRarity(contentRoot),
                        image = detectImage(contentRoot)
                    })
                end
            end
        end)
    end
    return items
end

function scrapeShopSafe(container)
    local success, items = pcall(function() return scrapeShop(container) end)
    return success and items or {}
end

-- ================== WEATHER / PHASE ==================
function getDefaultPhase()
    local clock = game.Lighting.ClockTime
    if clock >= 17 and clock < 19.5 then return "Sunset"
    elseif clock >= 6 and clock < 17 then return "Day"
    else return "Moon" end
end

function isNightPhase(phaseName)
    local lower = string.lower(phaseName)
    return lower ~= "day" and lower ~= "sunset"
end

function isInstanceVisible(instance)
    local p = instance
    while p and p ~= PlayerGui do
        if p:IsA("GuiObject") and p.Visible == false then return false end
        p = p.Parent
    end
    return true
end

function hasTruthyAttribute(instance, names)
    if not instance then return false end
    for _, attrName in ipairs(names) do
        local ok, value = pcall(function() return instance:GetAttribute(attrName) end)
        if ok then
            if value == true then return true end
            if type(value) == "string" and string.lower(value) == "true" then return true end
            if type(value) == "number" and value > 0 then return true end
        end
    end
    return false
end

function valueLooksTruthy(value)
    if value == true then return true end
    if type(value) == "number" then return value > 0 end
    if type(value) == "string" then
        local lower = string.lower(value)
        return lower == "true" or lower == "active" or lower == "playing"
            or lower == "enabled" or lower == "on" or lower == "yes"
            or string.find(lower, "%d+:%d+") ~= nil
            or string.find(lower, "%d+m") ~= nil
            or string.find(lower, "%d+s") ~= nil
    end
    return false
end

function hasTruthyStateSignal(instance, names)
    if not instance then return false end
    if hasTruthyAttribute(instance, names) then return true end

    local instanceKey = normalizeName(instance.Name)
    local nameMatches = false
    for _, stateName in ipairs(names) do
        local stateKey = normalizeName(stateName)
        if instanceKey == stateKey or string.find(instanceKey, stateKey, 1, true) then
            nameMatches = true
            break
        end
    end
    if not nameMatches then return false end

    if instance:IsA("BoolValue") or instance:IsA("StringValue")
       or instance:IsA("IntValue") or instance:IsA("NumberValue") then
        local ok, value = pcall(function() return instance.Value end)
        return ok and valueLooksTruthy(value)
    end
    return false
end

function textLooksActive(text)
    local lower = string.lower(tostring(text or ""))
    if lower == "" then return false end
    if string.find(lower, "starts") or string.find(lower, "start in")
       or string.find(lower, "???") or string.find(lower, "?????") then
        return false
    end
    return string.find(lower, "%d+:%d+") ~= nil
        or string.find(lower, "%d+m") ~= nil
        or string.find(lower, "%d+s") ~= nil
        or string.find(lower, "active") ~= nil
        or string.find(lower, "playing") ~= nil
        or string.find(lower, "ends") ~= nil
        or string.find(lower, "remaining") ~= nil
        or string.find(lower, "left") ~= nil
        or string.find(lower, "?????") ~= nil
        or string.find(lower, "??") ~= nil
end

function isWeatherCardActive(card)
    if not card or not card:IsA("GuiObject") then return false end
    if not isInstanceVisible(card) then return false end
    local stateNames = { "Playing", "Active", "IsActive", "Enabled", "Running", "Started", "playing", "active", "enabled", "running" }
    if hasTruthyStateSignal(card, stateNames) then
        return true
    end
    for _, desc in ipairs(card:GetDescendants()) do
        if hasTruthyStateSignal(desc, stateNames) then
            return true
        end
        if desc:IsA("TextLabel") and isInstanceVisible(desc) then
            local text = string.lower(tostring(desc.Text or ""))
            if textLooksActive(text) then
                return true
            end
        end
    end
    return false
end

function parseTimeToSeconds(timeStr)
    if not timeStr or timeStr == "" then return 0 end
    local cleanStr = string.match(timeStr, "(%d+:%d+)") or timeStr
    local m, s = string.match(cleanStr, "(%d+):(%d+)")
    if m and s then return tonumber(m) * 60 + tonumber(s) end
    local minutes = string.match(cleanStr, "(%d+)m")
    local seconds = string.match(cleanStr, "(%d+)s")
    local total = 0
    if minutes then total = total + tonumber(minutes) * 60 end
    if seconds then total = total + tonumber(seconds) end
    if total == 0 and tonumber(cleanStr) then total = tonumber(cleanStr) end
    return total
end

function findWeatherUI()
    local exact = PlayerGui:FindFirstChild("WeatherUI")
    if exact then return exact end
    exact = PlayerGui:FindFirstChild("Weather")
    if exact then return exact end
    exact = PlayerGui:FindFirstChild("EnvironmentUI")
    if exact then return exact end

    for _, child in ipairs(PlayerGui:GetChildren()) do
        local key = normalizeName(child.Name)
        if string.find(key, "weather", 1, true) or string.find(key, "environment", 1, true) then
            return child
        end
    end
    return nil
end

function getActiveTimerText()
    local weatherUI = findWeatherUI()
    if not weatherUI then return nil end
    local frame = weatherUI:FindFirstChild("Frame") or weatherUI
    if frame then
        for _, child in ipairs(frame:GetChildren()) do
            if child:IsA("GuiObject") and isWeatherCardActive(child) then
                for _, sub in ipairs(child:GetDescendants()) do
                    if sub:IsA("TextLabel") and isInstanceVisible(sub) and sub.Text ~= "" then
                        local sn = string.lower(sub.Name)
                        if string.find(sn, "time") or string.find(sn, "timer") or string.find(sn, "clock") then
                            return sub.Text
                        end
                    end
                end
                for _, sub in ipairs(child:GetDescendants()) do
                    if sub:IsA("TextLabel") and isInstanceVisible(sub) and sub.Text ~= "" then
                        local tc = string.match(sub.Text, "^%s*(.-)%s*$")
                        if string.match(tc, "%d+:%d+") or string.match(tc, "%d+m %d+s")
                           or string.match(tc, "%d+m") or string.match(tc, "%d+s") then
                            return tc
                        end
                    end
                end
            end
        end
    end
    for _, desc in ipairs(weatherUI:GetDescendants()) do
        if desc:IsA("TextLabel") and isInstanceVisible(desc) and desc.Text ~= "" then
            local tc = string.match(desc.Text, "^%s*(.-)%s*$")
            if string.match(tc, "%d+:%d+") or string.match(tc, "%d+m %d+s")
               or string.match(tc, "%d+m") or string.match(tc, "%d+s") then
                return tc
            end
        end
    end
    return nil
end

function findImageId(instance, expectedName)
    if not instance then return nil end
    local expectedKey = normalizeName(expectedName or instance.Name or "")
    local expectedPhaseKey = getPhaseKey(expectedName or instance.Name or "")
    local phaseFallback = expectedPhaseKey and PHASE_FALLBACK_IMAGES[expectedPhaseKey] or nil
    if phaseFallback then
        return phaseFallback
    end
    local function isExpectedImage(id)
        return isWeatherImageValidForName(expectedName or instance.Name, id)
    end

    local function extractId(str)
        if not str or str == "" then return nil end
        str = tostring(str)
        if string.sub(str, 1, 4) == "http" then return str end
        if string.sub(str, 1, 1) == "/" then return str end
        -- Match id= digits first (e.g. for rbxthumb URL)
        local id = string.match(str, "[iI][dD]=(%d+)")
        if id and id ~= "0" and id ~= "112886786873408" then return id end
        id = string.match(str, "rbxassetid://(%d+)")
        if id and id ~= "0" and id ~= "112886786873408" then return id end
        -- Match raw digits
        id = string.match(str, "%d+")
        if id and id ~= "0" and id ~= "112886786873408" then return id end
        return nil
    end

    local imageAttributes = {
        "Image", "ImageId", "ImageID", "Icon", "IconId", "IconID",
        "Texture", "TextureId", "TextureID", "Asset", "AssetId", "AssetID"
    }

    local decorativeNames = {
        background = true, bg = true, frame = true, shadow = true, glow = true,
        border = true, gradient = true, uigradient = true, uistroke = true,
        uicorner = true, overlay = true, shine = true, bevel = true,
        beveleffect = true
    }

    local preferredNames = {
        icon = true, image = true, imageicon = true, imagedisplay = true,
        vector = true, weathericon = true, phaseicon = true, thumbnail = true,
        logo = true, sprite = true
    }

    local function hasMoonInLineage(inst, stopAt)
        local cur, depth = inst, 0
        while cur and depth < 8 do
            local key = normalizeName(cur.Name)
            if string.find(key, "moon") then
                return true
            end
            if cur == stopAt then break end
            cur = cur.Parent
            depth = depth + 1
        end
        return false
    end

    local function matchesExpectedIconName(name)
        if expectedKey == "" then return false end
        local key = normalizeName(name)
        if expectedKey == "rainbow" and string.find(key, "moon") then
            return false
        end
        if expectedPhaseKey then
            return key == expectedPhaseKey
                or key == expectedPhaseKey .. "icon"
                or key == expectedPhaseKey .. "image"
                or key == expectedPhaseKey .. "vector"
        end
        if expectedKey == "rain" then
            return key == "rain" or key == "raining" or key == "rainy"
                or key == "rainicon" or key == "rainimage" or key == "rainvector"
                or string.find(key, "raindrop") ~= nil
        end
        return key == expectedKey
            or key == expectedKey .. "icon"
            or key == expectedKey .. "image"
            or key == expectedKey .. "vector"
            or ((string.find(key, expectedKey) ~= nil) and (string.find(key, "icon") ~= nil or string.find(key, "image") ~= nil or string.find(key, "vector") ~= nil))
    end

    local function ancestorMatchesExpected(inst)
        if expectedKey == "" then return false end
        local cur, depth = inst, 0
        while cur and depth < 6 do
            if matchesExpectedIconName(cur.Name) then
                return true
            end
            cur = cur.Parent
            depth = depth + 1
        end
        return false
    end

    local function imageFrom(inst)
        if not inst then return nil end
        for _, attrName in ipairs(imageAttributes) do
            local ok, attrValue = pcall(function() return inst:GetAttribute(attrName) end)
            if ok then
                local attrId = extractId(attrValue)
                if attrId then return attrId end
            end
        end
        if inst:IsA("StringValue") or inst:IsA("ObjectValue") then
            local valueId = extractId(inst.Value)
            if valueId then return valueId end
        elseif inst:IsA("IntValue") or inst:IsA("NumberValue") then
            local valueId = extractId(inst.Value)
            if valueId then return valueId end
        end
        if (inst:IsA("ImageLabel") or inst:IsA("ImageButton")) and inst.Image ~= "" then
            return extractId(inst.Image)
        end
        if inst:IsA("Decal") or inst:IsA("Texture") then
            return extractId(inst.Texture)
        end
        if inst:IsA("MeshPart") and inst.TextureID ~= "" then
            return extractId(inst.TextureID)
        end
        if (inst:IsA("SpecialMesh") or inst:IsA("FileMesh")) and inst.TextureId ~= "" then
            return extractId(inst.TextureId)
        end
        return nil
    end

    -- Weather UI cards store the real icon at Frame.<WeatherName>.Vector.
    -- Read it before scanning descendants, so Rain/Snowfall don't pick effects.
    local vector = findChildByNormalizedName(instance, { "Vector" })
    local vectorId = imageFrom(vector)
    if expectedKey == "rainbow" and vector and hasMoonInLineage(vector, instance) then
        vectorId = nil
    end
    if vectorId and isExpectedImage(vectorId) then return vectorId end

    local direct = imageFrom(instance)
    local rootName = normalizeName(instance.Name)
    if direct and isExpectedImage(direct) and (expectedKey == "" or preferredNames[rootName] or matchesExpectedIconName(instance.Name)) then
        return direct
    end

    local fallback = nil
    for _, desc in ipairs(instance:GetDescendants()) do
        local id = imageFrom(desc)
        if id and isExpectedImage(id) then
            local dn = normalizeName(desc.Name)
            if expectedKey == "rainbow" and hasMoonInLineage(desc, instance) then
                id = nil
            end
        end
        if id and isExpectedImage(id) then
            local dn = normalizeName(desc.Name)
            if matchesExpectedIconName(desc.Name) and not decorativeNames[dn] then
                return id
            end
            if preferredNames[dn] and (expectedKey == "" or ancestorMatchesExpected(desc)) then
                return id
            end
            if expectedKey == "" and not fallback and not decorativeNames[dn] then
                fallback = id
            end
        end
    end

    if fallback then return fallback end
    if expectedKey == "" and direct then return direct end
    return nil
end

function isWeatherPhaseName(name)
    if isTechnicalPhaseName(name) then return false end
    return getPhaseKey(name) ~= nil
end

function resolveWeatherCardName(instance)
    if not instance then return nil, false end
    local rawName = instance.Name
    if isTechnicalPhaseName(rawName) or isDecorativeWeatherCatalogName(rawName) then
        return nil, false
    end

    if isWeatherPhaseName(rawName) then
        return cleanPhaseName(rawName), true
    end

    local weatherName = cleanWeatherStateName(rawName)
    if weatherName then
        return weatherName, false
    end

    local okAttrs, attrs = pcall(function() return instance:GetAttributes() end)
    if okAttrs and type(attrs) == "table" then
        for _, value in pairs(attrs) do
            if type(value) == "string" then
                if isWeatherPhaseName(value) then
                    return cleanPhaseName(value), true
                end
                weatherName = cleanWeatherStateName(value)
                if weatherName then
                    return weatherName, false
                end
            end
        end
    end

    for _, desc in ipairs(instance:GetDescendants()) do
        if desc:IsA("TextLabel") and isInstanceVisible(desc) then
            local text = tostring(desc.Text or "")
            if isWeatherPhaseName(text) then
                return cleanPhaseName(text), true
            end
            weatherName = cleanWeatherStateName(text)
            if weatherName then
                return weatherName, false
            end
        elseif desc:IsA("StringValue") then
            local text = tostring(desc.Value or "")
            if isWeatherPhaseName(text) then
                return cleanPhaseName(text), true
            end
            weatherName = cleanWeatherStateName(text)
            if weatherName then
                return weatherName, false
            end
        end
    end

    return nil, false
end

function getWeatherFrameCards(frame)
    local cards, seen = {}, {}
    local function add(inst)
        if not inst or seen[inst] or not inst:IsA("GuiObject") then return end
        local name = resolveWeatherCardName(inst)
        if not name then return end
        seen[inst] = true
        table.insert(cards, inst)
    end

    if not frame then return cards end
    for _, child in ipairs(frame:GetChildren()) do
        add(child)
    end
    for _, desc in ipairs(frame:GetDescendants()) do
        add(desc)
    end
    return cards
end

function findWeatherFrameCard(frame, name)
    if not frame or not name then return nil end
    local wantedEntry = findWeatherDataEntryByName(name)
    local wantedKey = wantedEntry and wantedEntry.key or normalizeName(name)
    if wantedKey == "" then return nil end

    for _, card in ipairs(getWeatherFrameCards(frame)) do
        local cardName = resolveWeatherCardName(card) or card.Name
        local cardEntry = findWeatherDataEntryByName(card.Name) or findWeatherDataEntryByName(cardName)
        local cardKey = cardEntry and cardEntry.key or normalizeName(cardName)
        if cardKey == wantedKey then
            return card
        end
    end
    return nil
end

function getWeatherStateScanRoots()
    local roots, seen = {}, {}
    local function add(root)
        if root and not seen[root] then
            seen[root] = true
            table.insert(roots, root)
        end
    end

    add(findWeatherUI())
    add(ReplicatedStorage:FindFirstChild("Weather"))
    add(ReplicatedStorage:FindFirstChild("WeatherState"))
    add(ReplicatedStorage:FindFirstChild("Environment"))
    add(ReplicatedStorage:FindFirstChild("ActiveWeather"))

    return roots
end

function readWeatherNameFromValue(value)
    if type(value) ~= "string" then return nil, false end
    if isWeatherPhaseName(value) then
        return cleanPhaseName(value), true
    end
    local weatherName = cleanWeatherStateName(value)
    if weatherName then
        return weatherName, false
    end
    return nil, false
end

function getActiveWeatherFromWeatherValues(endTime, frame)
    local weathers = {}
    local weatherValues = getWeatherValues()
    if not weatherValues then
        return weathers, endTime or 0
    end

    local function readAttr(rawName, suffix)
        if not rawName then return nil end
        local ok, value = pcall(function() return weatherValues:GetAttribute(rawName .. "_" .. suffix) end)
        return ok and value or nil
    end

    local maxEndTime = endTime or 0
    local entries = getWeatherDataEntries()
    for _, entry in ipairs(entries) do
        local playing = readAttr(entry.rawName, "Playing")
        if playing == nil and entry.name ~= entry.rawName then
            playing = readAttr(entry.name, "Playing")
        end

        if valueLooksTruthy(playing) then
            local rawEndTime = readAttr(entry.rawName, "EndTime")
            if rawEndTime == nil and entry.name ~= entry.rawName then
                rawEndTime = readAttr(entry.name, "EndTime")
            end

            local eventEndTime = tonumber(rawEndTime) or maxEndTime
            if eventEndTime > maxEndTime then
                maxEndTime = eventEndTime
            end

            local card = findWeatherFrameCard(frame, entry.rawName) or findWeatherFrameCard(frame, entry.name)
            local image = entry.image or (card and findImageId(card, entry.name) or nil)
            if image and not isWeatherImageValidForName(entry.name, image) then
                image = nil
            end
            weathers[entry.name] = {
                playing = true,
                endTime = eventEndTime,
                image = image
            }
        end
    end

    return weathers, maxEndTime
end

function getActiveWeatherFromStateRoots(endTime)
    local weathers = {}
    local phase = nil
    local visited = 0
    local stateNames = { "Active", "Playing", "Enabled", "Running", "Current", "CurrentWeather", "ActiveWeather", "Weather" }

    local function addWeather(name, imageRoot)
        if not name then return end
        weathers[name] = {
            playing = true,
            endTime = endTime or 0,
            image = imageRoot and findImageId(imageRoot, name) or nil
        }
    end

    local function scanInstance(inst)
        pcall(function()
            if not inst or not inst.Parent or isTechnicalPhaseName(inst.Name) then return end

            local attrName = nil
            local okAttrs, attrs = pcall(function() return inst:GetAttributes() end)
            if okAttrs and type(attrs) == "table" then
                for attrKey, attrValue in pairs(attrs) do
                    local attrKeyNorm = normalizeName(attrKey)
                    if attrKeyNorm == "weather" or attrKeyNorm == "currentweather" or attrKeyNorm == "activeweather"
                       or attrKeyNorm == "phase" or attrKeyNorm == "currentphase" then
                        local name, isPhase = readWeatherNameFromValue(attrValue)
                        if name then
                            if isPhase then phase = name else attrName = name end
                        end
                    end
                end
            end

            local nameFromValue, valueIsPhase = nil, false
            if inst:IsA("StringValue") then
                nameFromValue, valueIsPhase = readWeatherNameFromValue(inst.Value)
            end

            local nameFromInstance, instanceIsPhase = nil, false
            if isWeatherPhaseName(inst.Name) then
                nameFromInstance, instanceIsPhase = cleanPhaseName(inst.Name), true
            else
                nameFromInstance = cleanWeatherStateName(inst.Name)
            end
            local activeByState = hasTruthyStateSignal(inst, stateNames)

            if attrName then
                addWeather(attrName, inst)
            elseif nameFromValue then
                if valueIsPhase then
                    phase = nameFromValue
                elseif activeByState or normalizeName(inst.Name) == "weather"
                    or normalizeName(inst.Name) == "currentweather" or normalizeName(inst.Name) == "activeweather" then
                    addWeather(nameFromValue, inst)
                end
            elseif nameFromInstance and not instanceIsPhase and activeByState then
                addWeather(nameFromInstance, inst)
            elseif nameFromInstance and instanceIsPhase and activeByState then
                phase = nameFromInstance
            end
        end)
    end

    for _, root in ipairs(getWeatherStateScanRoots()) do
        scanInstance(root)
        local ok, descendants = pcall(function() return root:GetDescendants() end)
        if ok then
            for _, desc in ipairs(descendants) do
                visited = visited + 1
                if visited > 3500 then break end
                scanInstance(desc)
            end
        end
    end

    return weathers, phase
end

local weatherCatalogCache = {}
local WEATHER_CATALOG_RESCAN_INTERVAL = 120
local WEATHER_CATALOG_SCAN_LIMIT = 5000
local weatherCatalogCacheAt = -WEATHER_CATALOG_RESCAN_INTERVAL

function getWeatherCatalogScanRoots()
    local roots, seen = {}, {}
    local function add(root)
        if root and not seen[root] then
            seen[root] = true
            table.insert(roots, root)
        end
    end

    local function addHintedDescendantRoots(base)
        if not base then return end
        local ok, descendants = pcall(function() return base:GetDescendants() end)
        if not ok then return end
        local scanned = 0
        for _, desc in ipairs(descendants) do
            scanned = scanned + 1
            if scanned > 1500 then break end
            local key = normalizeName(desc.Name)
            if string.find(key, "weather") or string.find(key, "environment") or key == "icons" or key == "images" or key == "weathericons" or key == "weatherimages" then
                add(desc)
            end
        end
    end

    local weatherUI = findWeatherUI()
    add(weatherUI)

    add(ReplicatedStorage:FindFirstChild("Weather"))
    add(ReplicatedStorage:FindFirstChild("WeatherIcons"))
    add(ReplicatedStorage:FindFirstChild("WeatherImages"))
    add(ReplicatedStorage:FindFirstChild("Environment"))

    if SharedModules then
        add(findChildByNormalizedName(SharedModules, { "Weather", "WeatherData", "WeatherImages", "WeatherIcons", "Environment", "EnvironmentData" }))
        addHintedDescendantRoots(SharedModules)
    end
    addHintedDescendantRoots(ReplicatedStorage)

    return roots
end

function rebuildWeatherCatalogCache()
    local catalog, visited = {}, 0

    local function add(rawName, root, allowUnknown)
        if not rawName or rawName == "" or not root then return end
        if isTechnicalPhaseName(rawName) or isDecorativeWeatherCatalogName(rawName) then return end
        local displayName = cleanWeatherStateName(rawName)
        if not displayName then
            if isWeatherPhaseName(rawName) then
                displayName = cleanPhaseName(rawName)
            elseif allowUnknown then
                displayName = formatCamelCase(rawName)
            else
                return
            end
        end
        if catalog[displayName] then return end
        local image = findImageId(root, displayName or rawName)
        if image and isWeatherImageValidForName(displayName or rawName, image) then
            catalog[displayName] = { name = displayName, image = image }
        end
    end

    local function addFromAncestor(inst)
        local p, depth = inst, 0
        while p and depth < 4 do
            add(p.Name, p)
            p = p.Parent
            depth = depth + 1
        end
    end

    local weatherUI = findWeatherUI()
    local frame = weatherUI and (weatherUI:FindFirstChild("Frame") or weatherUI)
    if frame then
        for _, child in ipairs(getWeatherFrameCards(frame)) do
            local displayName = resolveWeatherCardName(child)
            add(displayName or child.Name, child, true)
        end
    end
    for _, entry in ipairs(getWeatherDataEntries()) do
        if not catalog[entry.name] then
            local card = frame and (findWeatherFrameCard(frame, entry.rawName) or findWeatherFrameCard(frame, entry.name)) or nil
            local image = entry.image or (card and findImageId(card, entry.name) or nil)
            if image and not isWeatherImageValidForName(entry.name, image) then image = nil end
            catalog[entry.name] = { name = entry.name, image = image }
        end
    end

    for _, root in ipairs(getWeatherCatalogScanRoots()) do
        if visited >= WEATHER_CATALOG_SCAN_LIMIT then break end
        add(root.Name, root)
        local ok, descendants = pcall(function() return root:GetDescendants() end)
        if ok then
            for _, desc in ipairs(descendants) do
                visited = visited + 1
                if visited > WEATHER_CATALOG_SCAN_LIMIT then break end
                add(desc.Name, desc)
                if desc:IsA("ImageLabel") or desc:IsA("ImageButton") or desc:IsA("StringValue") or desc:IsA("IntValue") or desc:IsA("NumberValue") then
                    addFromAncestor(desc)
                end
            end
        end
    end

    weatherCatalogCache = catalog
    weatherCatalogCacheAt = os.clock()
end

function getWeatherCatalog()
    local catalog = {}
    local function add(rawName, root, allowUnknown)
        if not rawName or rawName == "" or not root then return end
        if isTechnicalPhaseName(rawName) or isDecorativeWeatherCatalogName(rawName) then return end
        local image = findImageId(root, rawName)
        if not image then return end
        local displayName = cleanWeatherStateName(rawName) or (isWeatherPhaseName(rawName) and cleanPhaseName(rawName) or (allowUnknown and formatCamelCase(rawName) or nil))
        if not displayName or displayName == "" then displayName = rawName end
        if not isWeatherImageValidForName(displayName, image) then return end
        catalog[displayName] = {
            name = displayName,
            image = image
        }
    end

    local weatherUI = findWeatherUI()
    local frame = weatherUI and (weatherUI:FindFirstChild("Frame") or weatherUI)
    if frame then
        for _, child in ipairs(getWeatherFrameCards(frame)) do
            local displayName = resolveWeatherCardName(child)
            add(displayName or child.Name, child, true)
        end
    end
    for _, entry in ipairs(getWeatherDataEntries()) do
        if not catalog[entry.name] then
            local card = frame and (findWeatherFrameCard(frame, entry.rawName) or findWeatherFrameCard(frame, entry.name)) or nil
            local image = entry.image or (card and findImageId(card, entry.name) or nil)
            if image and not isWeatherImageValidForName(entry.name, image) then image = nil end
            catalog[entry.name] = { name = entry.name, image = image }
        end
    end

    local phases = getPhasesFolder()
    if phases then
        for _, child in ipairs(phases:GetChildren()) do
            add(child.Name, child)
        end
    end

    if (os.clock() - weatherCatalogCacheAt) > WEATHER_CATALOG_RESCAN_INTERVAL then
        pcall(rebuildWeatherCatalogCache)
    end
    for name, item in pairs(weatherCatalogCache) do
        if not catalog[name] then
            catalog[name] = item
        end
    end

    return catalog
end

function getActiveWeatherAndPhase()
    local activePhase = getDefaultPhase()
    local workspacePhase = findActivePhaseAsset(workspace, true)
    if workspacePhase and not isTechnicalPhaseName(workspacePhase) then activePhase = workspacePhase end

    local activeWeathers = {}
    local weatherUI = findWeatherUI()
    local frame = weatherUI and (weatherUI:FindFirstChild("Frame") or weatherUI)
    local timerText = getActiveTimerText()
    local parsedSec = parseTimeToSeconds(timerText)
    local endTime = parsedSec > 0 and (os.time() + parsedSec) or 0

    local activePhaseImage = nil
    local uiPhase = nil
    local valuesWeathers, valuesEndTime = getActiveWeatherFromWeatherValues(endTime, frame)
    if valuesEndTime and valuesEndTime > endTime then
        endTime = valuesEndTime
    end
    for weatherName, info in pairs(valuesWeathers or {}) do
        activeWeathers[weatherName] = info
    end

    if frame then
        for _, child in ipairs(getWeatherFrameCards(frame)) do
            if child:IsA("GuiObject") and isWeatherCardActive(child) then
                local weatherName, isPhase = resolveWeatherCardName(child)
                local name = weatherName or child.Name
                if not isPhase then
                    weatherName = cleanWeatherStateName(name) or weatherName or formatCamelCase(name)
                    local existing = activeWeathers[weatherName] or {}
                    local image = existing.image or findImageId(child, weatherName)
                    if image and not isWeatherImageValidForName(weatherName, image) then
                        image = nil
                    end
                    activeWeathers[weatherName] = {
                        playing = true,
                        endTime = existing.endTime or endTime,
                        image = image
                    }
                else
                    activePhaseImage = findImageId(child, name)
                    uiPhase = cleanPhaseName(name)
                end
            end
        end
    end
    local stateWeathers, statePhase = getActiveWeatherFromStateRoots(endTime)
    for weatherName, info in pairs(stateWeathers or {}) do
        if not activeWeathers[weatherName] then
            activeWeathers[weatherName] = info
        end
    end
    if statePhase and not isTechnicalPhaseName(statePhase) then
        uiPhase = uiPhase or statePhase
    end
    if uiPhase and not isTechnicalPhaseName(uiPhase) then activePhase = uiPhase end
    activePhaseImage = getPhaseFallbackImage(activePhase) or activePhaseImage
    return activePhase, activePhaseImage, activeWeathers, endTime
end

function getWeathersHash(weathers)
    local parts = {}
    for name, info in pairs(weathers) do
        if info.playing then table.insert(parts, name .. ":true") end
    end
    table.sort(parts)
    return table.concat(parts, "|")
end

function getWeatherCatalogHash(catalog)
    local parts = {}
    for name, info in pairs(catalog or {}) do
        table.insert(parts, tostring(name) .. ":" .. tostring(info and info.image or ""))
    end
    table.sort(parts)
    return table.concat(parts, "|")
end

function getAuctionHash(auction)
    if type(auction) ~= "table" or type(auction.lots) ~= "table" then return "" end
    local parts = {}
    for _, lot in ipairs(auction.lots) do
        table.insert(parts, table.concat({
            tostring(lot.lotId or ""),
            tostring(lot.stockQuantity or lot.stock or ""),
            tostring(lot.currentPrice or ""),
            tostring(lot.soldOut == true),
            tostring(lot.expired == true),
            tostring(lot.priceUnknown == true),
            tostring(lot.stockUnknown == true)
        }, ":"))
    end
    table.sort(parts)
    return table.concat(parts, "|")
end

function getCatalogImageByName(catalog, name)
    if not catalog or not name then return nil end
    local wantedKey = getPhaseKey(name) or normalizeName(name)
    if wantedKey == "" then return nil end
    for catalogName, item in pairs(catalog) do
        if type(item) == "table" then
            local itemName = item.name or catalogName
            local catalogKey = getPhaseKey(catalogName) or normalizeName(catalogName)
            local itemKey = getPhaseKey(itemName) or normalizeName(itemName)
            if catalogKey == wantedKey or itemKey == wantedKey then
                if isWeatherImageValidForName(name, item.image) then
                    return item.image
                end
            end
        end
    end
    return nil
end

-- Legacy GUI parser retained only as dead fallback/reference; active code below uses
-- FruitImages + FruitStock snapshots and never calls these legacy* functions.
function legacyGetFruitRefreshTimer()
    return nil
end

function legacyGetFruitMultipliers()
    if true then return {} end
    local multipliers = {}
    local success, err = pcall(function()
        local fruitStockPrice = PlayerGui:FindFirstChild("FruitStockPrice")
        if not fruitStockPrice then
            for _, child in ipairs(PlayerGui:GetChildren()) do
                if child:IsA("ScreenGui") then
                    local nl = string.lower(child.Name)
                    if string.find(nl, "fruit") and (string.find(nl, "stock") or string.find(nl, "price") or string.find(nl, "multiplier")) then
                        fruitStockPrice = child
                        break
                    end
                end
            end
        end
        if not fruitStockPrice then return end

        local scrollingFrame = fruitStockPrice:FindFirstChildOfClass("ScrollingFrame")
            or fruitStockPrice:FindFirstChild("ScrollingFrame", true)
        if not scrollingFrame then
            for _, desc in ipairs(fruitStockPrice:GetDescendants()) do
                if desc:IsA("Frame") and desc.Name ~= "Frame" then
                    for _, c in ipairs(desc:GetChildren()) do
                        local cl = string.lower(c.Name)
                        if string.find(cl, "card") or string.find(cl, "fruit") then
                            scrollingFrame = desc
                            break
                        end
                    end
                    if scrollingFrame then break end
                end
            end
        end
        if not scrollingFrame then return end

        local seen = {}
        for _, card in ipairs(scrollingFrame:GetChildren()) do
            if card:IsA("GuiObject") and isInstanceVisible(card) then
                local nameLower = string.lower(card.Name)
                local isLayoutOrTemplate = string.find(nameLower, "layout") or string.find(nameLower, "padding")
                    or string.find(nameLower, "constraint") or nameLower == "template" or nameLower == "itemtemplate"
                if not isLayoutOrTemplate then
                    local frameInner = card:FindFirstChild("Frame") or card:FindFirstChildOfClass("Frame")

                    -- Multiplier value
                    local multText, multiplierLabel = nil, nil
                    if frameInner then
                        multiplierLabel = findChildByNormalizedName(frameInner, { "Multiplier" })
                        if multiplierLabel and multiplierLabel:IsA("TextLabel") then
                            multText = multiplierLabel.Text or ""
                        end
                    end
                    if not multText or multText == "" then
                        local searchRoot = frameInner or card
                        for _, desc in ipairs(searchRoot:GetDescendants()) do
                            if desc:IsA("TextLabel") and desc.Text and desc.Text ~= "" then
                                local cleanText = desc.Text:gsub(",", ".")
                                local num = string.match(cleanText, "([%d%.]+)")
                                if num then
                                    local lowerText = string.lower(desc.Text)
                                    if string.find(lowerText, "x") or string.find(lowerText, "РЎвЂ¦") or string.find(lowerText, "%*") 
                                       or string.match(cleanText, "^%s*[%d%.]+%s*$") then
                                        multText = num
                                        multiplierLabel = desc
                                        break
                                    end
                                end
                            end
                        end
                    end
                    if not multText then multText = "1" end
                    local valNum = tonumber(string.match(multText:gsub(",", "."), "([%d%.]+)")) or 1.0

                    -- Image
                    local imageAssetId = nil
                    if frameInner then
                        local fruitVector = findChildByNormalizedName(frameInner, { "FruitVector" })
                        if fruitVector and (fruitVector:IsA("ImageLabel") or fruitVector:IsA("ImageButton")) then
                            imageAssetId = string.match(fruitVector.Image or "", "%d+")
                        end
                    end
                    if not imageAssetId then
                        local searchRoot = frameInner or card
                        for _, desc in ipairs(searchRoot:GetDescendants()) do
                            if (desc:IsA("ImageLabel") or desc:IsA("ImageButton")) then
                                local dn = string.lower(desc.Name)
                                if dn ~= "beveleffect" and dn ~= "sunburst" and dn ~= "shadow" then
                                    local aid = string.match(desc.Image or "", "%d+")
                                    if aid and aid ~= "112886786873408" then
                                        imageAssetId = aid
                                        break
                                    end
                                end
                            end
                        end
                    end

                    -- Name: attribute > StringValue > label > asset map
                    local fruitName = nil
                    local toolTipAttr = card:GetAttribute("SeedToolTip") or (frameInner and frameInner:GetAttribute("SeedToolTip"))
                    if toolTipAttr and type(toolTipAttr) == "string" and toolTipAttr ~= "" then
                        fruitName = cleanScrapedName(toolTipAttr)
                    end
                    if not fruitName then
                        local toolTipVal = card:FindFirstChild("SeedToolTip", true)
                        if toolTipVal and (toolTipVal:IsA("StringValue") or toolTipVal:IsA("TextLabel")) then
                            local text = toolTipVal:IsA("StringValue") and toolTipVal.Value or toolTipVal.Text
                            if text and text ~= "" then fruitName = cleanScrapedName(text) end
                        end
                    end
                    if not fruitName and frameInner then
                        for _, child in ipairs(frameInner:GetChildren()) do
                            if child:IsA("TextLabel") and child ~= multiplierLabel then
                                local cn = string.lower(child.Name)
                                if cn == "big" or cn == "mega" or cn == "title" or cn == "fruitname" or cn == "name" then
                                    local text = child.Text or ""
                                    if text ~= "" and not string.find(text, "[%d]") and not string.find(string.lower(text), "^x") then
                                        local cleanText = text:gsub("^%s*(.-)%s*$", "%1")
                                        if cleanText ~= "" then fruitName = cleanText; break end
                                    end
                                end
                            end
                        end
                        if not fruitName then
                            for _, child in ipairs(frameInner:GetChildren()) do
                                if child:IsA("TextLabel") and child ~= multiplierLabel then
                                    local cn = string.lower(child.Name)
                                    if cn ~= "multiplier" and cn ~= "cost_text" and cn ~= "stock_text" and cn ~= "rarity_text" then
                                        local text = child.Text or ""
                                        if text ~= "" and not string.find(text, "[%d]") and not string.find(string.lower(text), "^x") then
                                            local cleanText = text:gsub("^%s*(.-)%s*$", "%1")
                                            if cleanText ~= "" then fruitName = cleanText; break end
                                        end
                                    end
                                end
                            end
                        end
                    end
                    if not fruitName and imageAssetId and assetToItemNameMap[imageAssetId] then
                        fruitName = assetToItemNameMap[imageAssetId]
                    end
                    if not fruitName then
                        local searchRoot = frameInner or card
                        for _, desc in ipairs(searchRoot:GetDescendants()) do
                            if desc:IsA("TextLabel") and desc ~= multiplierLabel
                               and not (multiplierLabel and desc:IsDescendantOf(multiplierLabel)) then
                                local dn = string.lower(desc.Name)
                                if dn ~= "multiplier" and dn ~= "cost_text" and dn ~= "stock_text" and dn ~= "rarity_text" then
                                    local text = desc.Text or ""
                                    if text ~= "" and not string.find(text, "[%d]") and not string.find(string.lower(text), "^x") then
                                        local cleanText = text:gsub("^%s*(.-)%s*$", "%1")
                                        if cleanText ~= "" then fruitName = cleanText; break end
                                    end
                                end
                            end
                        end
                    end

                    local key
                    if fruitName then key = fruitName
                    elseif imageAssetId then key = "Asset_" .. imageAssetId
                    else key = "Unknown_" .. tostring(#multipliers + 1) end

                    if seen[key] then
                        if valNum > (multipliers[seen[key]].multiplier or 0) then
                            multipliers[seen[key]].multiplier = valNum
                        end
                    else
                        seen[key] = (#multipliers + 1)
                        table.insert(multipliers, {
                            name = fruitName,
                            image = imageAssetId,
                            key = key,
                            multiplier = valNum
                        })
                    end
                end
            end
        end
    end)
    if not success and DEBUG then
        warn("[Grow a Garden 2 Stocker] Error getting fruit multipliers: " .. tostring(err))
    end
    return multipliers
end

-- Active fruit multiplier source:
-- FruitImages gives fruit name -> image id, FruitStock snapshot gives fruit name -> multiplier/tier.
function cleanScrapedName(name)
    if not name then return nil end
    local str = tostring(name)
    if string.find(string.lower(str), "^photo_") then return string.sub(str, 7) end
    return str
end

local function writeDebugLog(msg)
    if DEBUG then
        print("[" .. os.date("%H:%M:%S") .. "] [Grow a Garden 2 Stocker] " .. tostring(msg))
    end
end

function getInstanceFullName(instance)
    local ok, fullName = pcall(function()
        return instance and instance:GetFullName() or nil
    end)
    return ok and fullName or tostring(instance)
end

function isUnsafeModuleRequire(moduleScript)
    if not moduleScript then return true, "missing module" end
    local ok, reason = pcall(function()
        if typeof(moduleScript) ~= "Instance" then
            return "not an Instance"
        end
        if not moduleScript:IsA("ModuleScript") then
            return "not a ModuleScript"
        end
        if Players and moduleScript:IsDescendantOf(Players) then
            return "Players/PlayerScripts module"
        end

        local fullName = moduleScript:GetFullName()
        if string.find(fullName, ".PlayerScripts.", 1, true)
            or string.find(fullName, ".PlayerGui.", 1, true)
            or string.find(fullName, "CoreGui", 1, true)
            or string.find(fullName, "CorePackages", 1, true)
            or string.find(fullName, "TimeCycleController", 1, true) then
            return "client-only RobloxScript module"
        end

        return nil
    end)
    if not ok then
        return true, "module check failed"
    end
    return reason ~= nil, reason
end

function safeRequireModule(moduleScript)
    if not moduleScript then return nil end
    local unsafe, reason = isUnsafeModuleRequire(moduleScript)
    if unsafe then
        writeDebugLog("Skipped unsafe require (" .. tostring(reason) .. "): " .. getInstanceFullName(moduleScript))
        return nil
    end
    local ok, result = pcall(function()
        return require(moduleScript)
    end)
    if ok then return result end
    if DEBUG then
        warn("[Grow a Garden 2 Stocker] Failed to require " .. tostring(moduleScript.Name) .. ": " .. tostring(result))
    end
    return nil
end

function getSharedModule(moduleName)
    local root = SharedModules or ReplicatedStorage:FindFirstChild("SharedModules")
    return root and root:FindFirstChild(moduleName) or nil
end

local cachedNetworking = nil

function getNetworkingModule()
    if not cachedNetworking then
        cachedNetworking = safeRequireModule(getSharedModule("Networking"))
    end
    return cachedNetworking
end

function normalizeAssetRef(value)
    if value == nil then return nil end
    local str = tostring(value)
    if str == "" then return nil end
    if string.sub(str, 1, 4) == "http" or string.sub(str, 1, 1) == "/" then
        return str
    end
    return string.match(str, "[iI][dD]=(%d+)") or string.match(str, "%d+") or str
end

-- ================== AUCTIONEER SNAPSHOT SOURCE ==================
local AUCTION_DEFAULT_ICON_ID = "81520753924742"
local cachedAuctioneer = nil
local cachedMailboxItemCatalog = false
local latestAuctionSnapshot = nil
local latestAuctionStock = {}
local latestAuctionSoldOutPrices = {}
local latestAuctionAt = 0
local latestAuctionSnapshotAt = 0
local latestAuctionStockAt = 0
local auctionSnapshotConnected = false
local auctionStockConnected = false
local auctionRequestPending = false
local lastAuctionRequestAt = -10
local auctionGuiPrimedAt = 0
local auctionGuiAutoHidden = false
local AUCTION_REQUEST_INTERVAL = 3
local AUCTION_STARTUP_RETRY_INTERVAL = 0.75
local AUCTION_STARTUP_RETRY_COUNT = 24

function getAuctioneerModule()
    if not cachedAuctioneer then
        cachedAuctioneer = safeRequireModule(getSharedModule("Auctioneer"))
    end
    return cachedAuctioneer
end

function getMailboxItemCatalog()
    -- Avoid requiring PlayerScripts modules from executor context. Auction cards
    -- already expose the final image/name/rarity in PlayerGui.Auction.
    return nil
end

local function wrapRawRemote(remote)
    if not remote then return nil end
    local wrapper = {}
    if remote:IsA("RemoteEvent") then
        wrapper.Fire = function(self, ...)
            return remote:FireServer(...)
        end
        wrapper.OnClientEvent = remote.OnClientEvent
        wrapper.Connect = function(self, callback)
            return remote.OnClientEvent:Connect(callback)
        end
    elseif remote:IsA("RemoteFunction") then
        wrapper.Invoke = function(self, ...)
            return remote:InvokeServer(...)
        end
        wrapper.InvokeServer = function(self, ...)
            return remote:InvokeServer(...)
        end
    end
    return wrapper
end

local cachedFallbackNetworking = {}

local function getFallbackNetworking(serviceName)
    if cachedFallbackNetworking[serviceName] ~= nil then
        if cachedFallbackNetworking[serviceName] == false then
            return nil
        else
            return cachedFallbackNetworking[serviceName]
        end
    end

    writeDebugLog("getFallbackNetworking called for: " .. tostring(serviceName))
    local remotes = {}
    local ok, err = pcall(function()
        local lowerService = string.lower(serviceName)
        for _, desc in ipairs(ReplicatedStorage:GetDescendants()) do
            if desc:IsA("RemoteEvent") or desc:IsA("RemoteFunction") then
                local rawFullName = desc:GetFullName()
                local fullName = string.lower(rawFullName)
                if string.find(fullName, lowerService) then
                    local lname = string.lower(desc.Name)
                    local key = nil
                    if lowerService == "auction" then
                        if string.find(lname, "request") then
                            key = "RequestSnapshot"
                        elseif string.find(lname, "stockupdate") or string.find(lname, "stock") then
                            key = "StockUpdate"
                        elseif string.find(lname, "snapshot") then
                            key = "Snapshot"
                        end
                    elseif lowerService == "fruitstock" then
                        if string.find(lname, "request") then
                            key = "Request"
                        elseif string.find(lname, "snapshot") then
                            key = "Snapshot"
                        end
                    end
                    
                    if key then
                        writeDebugLog("Found fallback remote: " .. rawFullName .. " -> mapped as: " .. key)
                        remotes[key] = wrapRawRemote(desc)
                    end
                end
            end
        end
    end)
    if not ok then
        writeDebugLog("Error in getFallbackNetworking: " .. tostring(err))
    end
    if next(remotes) ~= nil then
        cachedFallbackNetworking[serviceName] = remotes
        return remotes
    end
    writeDebugLog("No fallback remotes found for: " .. tostring(serviceName))
    cachedFallbackNetworking[serviceName] = false
    return nil
end


function getAuctionNetworking()
    local networking = getNetworkingModule()
    local auction = networking and networking.Auctioneer or nil
    if auction then
        writeDebugLog("Auction networking obtained via Sharing Module")
    else
        writeDebugLog("Auction networking sharing module failed, trying fallback")
        auction = getFallbackNetworking("Auction")
    end
    return auction
end

local function callNetworkEndpoint(endpoint, ...)
    if not endpoint then return false, nil end
    if type(endpoint) == "function" then
        return pcall(endpoint, ...)
    end

    local methods = { "Fire", "Invoke", "InvokeServer", "FireServer", "Call", "Request", "Send" }
    local lastError = nil
    local firedWithoutResult = false
    for _, method in ipairs(methods) do
        local okMethod, fn = pcall(function()
            return endpoint[method]
        end)
        if okMethod and type(fn) == "function" then
            local ok, result = pcall(function(...)
                return fn(endpoint, ...)
            end, ...)
            if ok and result ~= nil then
                return true, result
            elseif ok then
                firedWithoutResult = true
            end
            lastError = result

            ok, result = pcall(function(...)
                return fn(...)
            end, ...)
            if ok and result ~= nil then
                return true, result
            elseif ok then
                firedWithoutResult = true
            end
            lastError = result
        end
    end

    local okInstance, isRemoteFunction = pcall(function()
        return endpoint:IsA("RemoteFunction")
    end)
    if okInstance and isRemoteFunction then
        return pcall(function(...)
            return endpoint:InvokeServer(...)
        end, ...)
    end

    if firedWithoutResult then
        return true, nil
    end
    return false, lastError
end

local function connectNetworkSignal(signal, callback)
    if not signal or type(callback) ~= "function" then return false end

    local okEvent, event = pcall(function()
        return signal.OnClientEvent
    end)
    if okEvent and event and event.Connect then
        local ok = pcall(function()
            event:Connect(callback)
        end)
        if ok then return true end
    end

    local okBindable, bindableEvent = pcall(function()
        return signal.Event
    end)
    if okBindable and bindableEvent and bindableEvent.Connect then
        local ok = pcall(function()
            bindableEvent:Connect(callback)
        end)
        if ok then return true end
    end

    local okConnect, connectFn = pcall(function()
        return signal.Connect
    end)
    if okConnect and type(connectFn) == "function" then
        local ok = pcall(function()
            connectFn(signal, callback)
        end)
        if ok then return true end
    end

    local okOn, onFn = pcall(function()
        return signal.On
    end)
    if okOn and type(onFn) == "function" then
        local ok = pcall(function()
            onFn(signal, callback)
        end)
        if ok then return true end
    end

    return false
end

function getServerNow()
    local ok, result = pcall(function()
        return workspace:GetServerTimeNow()
    end)
    if ok and type(result) == "number" then
        return result
    end
    return os.time()
end

function getLotDisplayName(lot)
    if type(lot) ~= "table" then return "" end
    local auctioneer = getAuctioneerModule()
    if auctioneer and auctioneer.DisplayName then
        local ok, result = pcall(function()
            return auctioneer.DisplayName(lot)
        end)
        if ok and type(result) == "string" and result ~= "" then
            return result
        end
    end
    return tostring(lot.displayName or lot.name or lot.item or lot.FruitName or lot.lotId or "")
end

function getLotCurrentPrice(lot)
    if type(lot) ~= "table" then return tonumber(lot) or 0 end
    local auctioneer = getAuctioneerModule()
    if auctioneer and auctioneer.CurrentPrice then
        local ok, result = pcall(function()
            return auctioneer.CurrentPrice(lot, getServerNow())
        end)
        if ok and type(result) == "number" then
            return math.max(0, math.floor(result))
        end
    end
    local startPrice = tonumber(lot.startPrice)
    local minPrice = tonumber(lot.minPrice) or 0
    local decrementIntervalSeconds = tonumber(lot.decrementIntervalSeconds) or 0
    local decrementPercent = tonumber(lot.decrementPercent) or 0
    local rolledAt = tonumber(lot.rolledAt) or 0
    if startPrice and startPrice >= 0 then
        if decrementIntervalSeconds <= 0 then
            return math.max(0, math.floor(startPrice))
        end
        local elapsed = getServerNow() - rolledAt
        if elapsed < 0 then elapsed = 0 end
        local ticks = math.floor(elapsed / decrementIntervalSeconds)
        local step = math.floor(startPrice * decrementPercent / 100 + 0.5)
        local price = startPrice - step * ticks
        if price < minPrice then price = minPrice end
        return math.max(0, math.floor(price))
    end
    return math.max(0, math.floor(tonumber(lot.currentPrice or lot.price or lot.startPrice or lot.cost) or 0))
end

function hasReliableAuctionPrice(lot)
    if type(lot) ~= "table" then return false end
    if tonumber(lot.currentPrice or lot.price or lot.cost) then return true end
    if tonumber(lot.startPrice) then return true end
    return false
end

function getAuctionLotFallbackStock(lot)
    if type(lot) ~= "table" then return nil end
    return normalizeAuctionStockValue(lot.stockQuantity or lot.stock or lot.quantity or lot.count)
end

function getAuctionLotExpiry(lot)
    if type(lot) ~= "table" then return 0 end
    local expiresAt = tonumber(lot.expiresAt or lot.expireAt or lot.endTime or lot.endsAt)
    if expiresAt and expiresAt > 0 then return expiresAt end
    local rolledAt = tonumber(lot.rolledAt or lot.startedAt)
    local duration = tonumber(lot.durationSeconds or lot.duration or lot.lifetime or lot.last)
    if rolledAt and rolledAt > 0 and duration and duration > 0 then
        return rolledAt + duration
    end
    return 0
end

function hasAuctionPriceFormula(lot)
    if type(lot) ~= "table" then return false end
    if tonumber(lot.currentPrice or lot.price or lot.cost) then return true end
    if not tonumber(lot.startPrice) then return false end
    local decrementIntervalSeconds = tonumber(lot.decrementIntervalSeconds)
    if decrementIntervalSeconds and decrementIntervalSeconds > 0 then
        return tonumber(lot.rolledAt) ~= nil and tonumber(lot.decrementPercent) ~= nil
    end
    return true
end

function normalizeAuctionStockValue(stock)
    if type(stock) == "table" then
        stock = stock.stock
            or stock.value
            or stock.Stock
            or stock.quantity
            or stock.Quantity
            or stock.stockQuantity
            or stock.StockQuantity
            or stock.remainingStock
            or stock.StockRemaining
            or stock.count
            or stock.Count
            or stock.remaining
            or stock.Remaining
            or stock.available
            or stock.Available
            or stock.left
            or stock.Left
            or stock.quantityLeft
            or stock.QuantityLeft
            or stock.Amount
            or stock.Value
    end
    local value = tonumber(stock)
    if value == nil then return nil end
    return math.max(0, math.floor(value))
end

function setAuctionStockMapValue(out, key, value)
    if key == nil then return end
    local rawKey = tostring(key)
    if rawKey == "" then return end
    local normalizedKey = normalizeAuctionLotId(rawKey)
    out[rawKey] = value
    out[normalizedKey] = value
    local index = getAuctionLotIndex(normalizedKey)
    if index ~= nil then
        out[index] = value
        out[tostring(index)] = value
    end
end

function normalizeAuctionLotId(lotId)
    local text = tostring(lotId or "")
    if text == "" then return "" end
    return (text:gsub("^Lot_", ""))
end

function getAuctionLotIndex(lotId)
    local indexText = tostring(lotId or ""):match(":(%d+)$")
    return indexText and tonumber(indexText) or nil
end

function normalizeAuctionStockMap(stock)
    local out = {}
    if type(stock) ~= "table" then return out end
    for key, value in pairs(stock) do
        setAuctionStockMapValue(out, key, value)
    end
    return out
end

function extractAuctionStockPayload(update, maybeStock)
    if maybeStock ~= nil and type(update) ~= "table" then
        return { [update] = maybeStock }, false
    end
    if type(update) ~= "table" then return nil, false end

    local stock = update.stock or update.Stock or update.stocks or update.Stocks
    if type(stock) == "table" then
        return stock, true
    end

    for _, key in ipairs({ "data", "Data", "payload", "Payload", "result", "Result", "snapshot", "Snapshot" }) do
        local nested = update[key]
        if type(nested) == "table" then
            local nestedStock, nestedReplaceAll = extractAuctionStockPayload(nested)
            if type(nestedStock) == "table" then
                return nestedStock, nestedReplaceAll
            end
        end
    end

    local lotId = update.lotId or update.LotId or update.lotID or update.id or update.Id
    local singleValue = normalizeAuctionStockValue(update)
    if lotId ~= nil and singleValue ~= nil then
        return { [lotId] = singleValue }, false
    end

    local looksLikeMap = false
    for key, value in pairs(update) do
        if key ~= "manifest" and key ~= "lots" and key ~= "items" and normalizeAuctionStockValue(value) ~= nil then
            looksLikeMap = true
            break
        end
    end
    if looksLikeMap then
        return update, true
    end

    return nil, false
end

function getAuctionStockMapValue(stockMap, lot, lotId, lotIndex, position, rawIndex)
    if type(stockMap) ~= "table" then return nil end
    local candidates = {}
    local function addCandidate(value)
        if value ~= nil then
            table.insert(candidates, value)
        end
    end

    addCandidate(lotId)
    if type(lot) == "table" then
        addCandidate(lot.lotId)
        addCandidate(lot.id)
        addCandidate(lot.key)
    end
    if lotId and lotId ~= "" then
        addCandidate("Lot_" .. tostring(lotId))
    end
    addCandidate(lotIndex)
    addCandidate(lotIndex and tostring(lotIndex) or nil)
    addCandidate(position)
    addCandidate(position and tostring(position) or nil)
    addCandidate(position and position - 1 or nil)
    addCandidate(position and tostring(position - 1) or nil)
    addCandidate(rawIndex)
    addCandidate(rawIndex and tostring(rawIndex) or nil)

    for _, key in ipairs(candidates) do
        if stockMap[key] ~= nil then
            return stockMap[key]
        end
        local normalizedKey = normalizeAuctionLotId(key)
        if stockMap[normalizedKey] ~= nil then
            return stockMap[normalizedKey]
        end
    end

    return nil
end

function getAuctionRawLots(snapshot)
    if type(snapshot) ~= "table" then return nil end
    if type(snapshot.manifest) == "table" and type(snapshot.manifest.lots) == "table" then
        return snapshot.manifest.lots
    end
    if type(snapshot.lots) == "table" then
        return snapshot.lots
    end
    if type(snapshot.items) == "table" then
        return snapshot.items
    end
    if type(snapshot.manifest) == "table" then
        local hasIndexedLots = false
        for _, lot in pairs(snapshot.manifest) do
            if type(lot) == "table" and lot.lotId then
                hasIndexedLots = true
                break
            end
        end
        if hasIndexedLots then
            return snapshot.manifest
        end
    end
    return nil
end

function getAuctionSnapshotLotKey(snapshot)
    local lots = getAuctionRawLots(snapshot)
    if type(lots) ~= "table" then return "" end
    local keys = {}
    for _, lot in pairs(lots) do
        if type(lot) == "table" and lot.lotId then
            table.insert(keys, normalizeAuctionLotId(lot.lotId))
        end
    end
    table.sort(keys)
    return table.concat(keys, "|")
end

local AUCTION_CATEGORY_ALIASES = {
    seed = "Seeds",
    seeds = "Seeds",
    normal_seeds = "Seeds",
    normalseeds = "Seeds",
    gear = "Gears",
    gears = "Gears",
    sprinkler = "Sprinklers",
    sprinklers = "Sprinklers",
    crate = "Crates",
    crates = "Crates",
    egg = "Eggs",
    eggs = "Eggs",
    seedpack = "Seedpacks",
    seedpacks = "Seedpacks",
    seed_pack = "Seedpacks",
    seed_packs = "Seedpacks",
    harvestedfruit = "HarvestedFruits",
    harvestedfruits = "HarvestedFruits",
    harvested_fruit = "HarvestedFruits",
    harvested_fruits = "HarvestedFruits",
    fruit = "HarvestedFruits",
    fruits = "HarvestedFruits"
}

local AUCTION_CATEGORY_CANDIDATES = {
    Seeds = { "Seeds", "Seed", "NormalSeeds", "Normal Seeds" },
    Gears = { "Gears", "Gear" },
    Sprinklers = { "Sprinklers", "Sprinkler", "Gears" },
    Crates = { "Crates", "Crate" },
    Eggs = { "Eggs", "Egg" },
    Seedpacks = { "Seedpacks", "SeedPacks", "Seed Packs", "SeedPack", "Seed Pack" },
    HarvestedFruits = { "HarvestedFruits", "Harvested Fruits", "Fruits", "Fruit" }
}

function normalizeAuctionCategory(category)
    if category == nil then return nil end
    local text = tostring(category)
    if text == "" then return nil end
    local key = normalizeName(text)
    return AUCTION_CATEGORY_ALIASES[key] or text
end

function isDefaultAuctionIcon(ref)
    local normalized = normalizeAssetRef(ref)
    return normalized == AUCTION_DEFAULT_ICON_ID
end

function addUnique(list, seen, value)
    if value == nil then return end
    local text = tostring(value)
    if text == "" then return end
    local key = string.lower(text)
    if seen[key] then return end
    seen[key] = true
    table.insert(list, text)
end

function getAuctionCategoryCandidates(category)
    local normalized = normalizeAuctionCategory(category)
    local result = {}
    local seen = {}
    addUnique(result, seen, normalized)
    addUnique(result, seen, category)
    local aliases = normalized and AUCTION_CATEGORY_CANDIDATES[normalized]
    if aliases then
        for _, value in ipairs(aliases) do
            addUnique(result, seen, value)
        end
    elseif not normalized or normalizeName(normalized) == "auction" then
        for _, values in pairs(AUCTION_CATEGORY_CANDIDATES) do
            for _, value in ipairs(values) do
                addUnique(result, seen, value)
            end
        end
    end
    return result
end

function getAuctionItemCandidates(lot)
    local result = {}
    local seen = {}
    if type(lot) == "table" then
        addUnique(result, seen, lot.item)
        addUnique(result, seen, lot.name)
        addUnique(result, seen, lot.displayName)
        addUnique(result, seen, lot.FruitName)
    end
    return result
end

function resolveAuctionCatalogImage(lot)
    if type(lot) ~= "table" then return nil end
    local catalog = getMailboxItemCatalog()
    if not (catalog and catalog.Resolve) then return nil end

    local categories = getAuctionCategoryCandidates(lot.category)
    local items = getAuctionItemCandidates(lot)
    local defaultResult = nil

    for _, category in ipairs(categories) do
        for _, item in ipairs(items) do
            local ok, result = pcall(function()
                return catalog.Resolve(category, item, {
                    Name = item,
                    FruitName = item,
                    Mutation = lot.mutation,
                    Size = lot.size,
                    Type = lot.type
                })
            end)
            local image = ok and normalizeAssetRef(result) or nil
            if image then
                if not isDefaultAuctionIcon(image) then
                    return image
                end
                defaultResult = defaultResult or image
            end
        end
    end

    return defaultResult
end

function getLotImage(lot)
    if type(lot) ~= "table" then return nil end
    local direct = normalizeAssetRef(lot.image or lot.icon or lot.displayImage or lot.thumbnail or lot.assetId)
    if direct and not isDefaultAuctionIcon(direct) then return direct end

    local catalogImage = resolveAuctionCatalogImage(lot)
    if catalogImage then return catalogImage end

    return direct
end

function getLotRarity(lot)
    if type(lot) ~= "table" then return "" end
    if type(lot.rarity) == "string" and lot.rarity ~= "" then
        return lot.rarity
    end
    local catalog = getMailboxItemCatalog()
    if catalog and catalog.ResolveRarity then
        local ok, result = pcall(function()
            return catalog.ResolveRarity(lot.category, lot.item)
        end)
        if ok and type(result) == "string" and result ~= "" then
            return result
        end
    end
    return ""
end

function unwrapAuctionSnapshotPayload(payload, depth)
    if type(payload) ~= "table" then return nil end
    depth = depth or 0
    if depth > 4 then return payload end
    if type(getAuctionRawLots(payload)) == "table" or type(payload.stock) == "table" then
        return payload
    end
    local nestedKeys = {
        "snapshot", "Snapshot",
        "data", "Data",
        "payload", "Payload",
        "result", "Result",
        "auction", "Auction"
    }
    for _, key in ipairs(nestedKeys) do
        local nested = payload[key]
        if type(nested) == "table" then
            local unwrapped = unwrapAuctionSnapshotPayload(nested, depth + 1)
            if unwrapped then return unwrapped end
        end
    end
    return payload
end

function applyAuctionSnapshot(snapshot)
    snapshot = unwrapAuctionSnapshotPayload(snapshot)
    if type(snapshot) ~= "table" then return false end
    local incomingHasLots = type(getAuctionRawLots(snapshot)) == "table"
    if not incomingHasLots and type(snapshot.stock) ~= "table" and not latestAuctionSnapshot then
        return false
    end
    if not incomingHasLots and latestAuctionSnapshot then
        local merged = {}
        for key, value in pairs(latestAuctionSnapshot) do
            merged[key] = value
        end
        for key, value in pairs(snapshot) do
            merged[key] = value
        end
        snapshot = merged
    end
    local previousLotKey = getAuctionSnapshotLotKey(latestAuctionSnapshot)
    local nextLotKey = getAuctionSnapshotLotKey(snapshot)
    local lotsChanged = previousLotKey ~= "" and nextLotKey ~= "" and previousLotKey ~= nextLotKey
    latestAuctionSnapshot = snapshot
    if lotsChanged then
        latestAuctionSoldOutPrices = {}
    end
    if type(snapshot.stock) == "table" then
        latestAuctionStock = normalizeAuctionStockMap(snapshot.stock)
        latestAuctionSnapshot.stock = latestAuctionStock
    elseif lotsChanged then
        latestAuctionStock = {}
        latestAuctionSnapshot.stock = latestAuctionStock
    else
        latestAuctionSnapshot.stock = latestAuctionStock
    end
    latestAuctionAt = os.clock()
    if incomingHasLots then
        latestAuctionSnapshotAt = latestAuctionAt
    end
    return true
end

function applyAuctionStockUpdate(update, maybeStock)
    local stockPayload, replaceAll = extractAuctionStockPayload(update, maybeStock)
    if type(stockPayload) ~= "table" then return false end
    local normalizedStock = normalizeAuctionStockMap(stockPayload)
    if next(normalizedStock) == nil then return false end

    if replaceAll or type(latestAuctionStock) ~= "table" then
        latestAuctionStock = normalizedStock
    else
        for key, value in pairs(normalizedStock) do
            latestAuctionStock[key] = value
        end
    end
    if latestAuctionSnapshot then
        latestAuctionSnapshot.stock = latestAuctionStock
    end
    latestAuctionStockAt = os.clock()
    latestAuctionAt = latestAuctionStockAt
    writeDebugLog("Auction stock update applied")
    return true
end

function requestAuctionSnapshot(force)
    local now = os.clock()
    if auctionRequestPending then return false end
    if not force and (now - lastAuctionRequestAt) < AUCTION_REQUEST_INTERVAL then
        return false
    end

    local auction = getAuctionNetworking()
    local requestRemote = auction and auction.RequestSnapshot
    if not requestRemote then return false end

    auctionRequestPending = true
    lastAuctionRequestAt = now
    local ok, result = callNetworkEndpoint(requestRemote)
    auctionRequestPending = false

    if ok and type(result) == "table" then
        writeDebugLog("Auction snapshot received from RequestSnapshot")
        return applyAuctionSnapshot(result)
    end
    if ok then
        writeDebugLog("Auction RequestSnapshot fired; waiting for Snapshot event")
    end
    if DEBUG and not ok then
        warn("[Grow a Garden 2 Stocker] Auctioneer.RequestSnapshot failed: " .. tostring(result))
    end
    return false
end

function connectAuctionSnapshot(onSnapshot)
    if auctionSnapshotConnected and auctionStockConnected then return end
    local auction = getAuctionNetworking()
    if not auction then return end

    local snapshotConnectedNow = false
    local stockConnectedNow = false
    local ok, err = pcall(function()
        local snapshotEvent = not auctionSnapshotConnected and auction.Snapshot or nil
        if snapshotEvent then
            if connectNetworkSignal(snapshotEvent, function(snapshot)
                if applyAuctionSnapshot(snapshot) and onSnapshot then onSnapshot() end
            end) then
                snapshotConnectedNow = true
            end
        end

        local stockEvent = not auctionStockConnected and auction.StockUpdate or nil
        if stockEvent then
            if connectNetworkSignal(stockEvent, function(...)
                if applyAuctionStockUpdate(...) and onSnapshot then onSnapshot() end
            end) then
                stockConnectedNow = true
            end
        end
    end)

    if ok then
        auctionSnapshotConnected = auctionSnapshotConnected or snapshotConnectedNow
        auctionStockConnected = auctionStockConnected or stockConnectedNow
    end
    if snapshotConnectedNow or stockConnectedNow then
        writeDebugLog("Auction events connected: Snapshot=" .. tostring(auctionSnapshotConnected) .. ", StockUpdate=" .. tostring(auctionStockConnected))
    end
    if DEBUG and not ok then
        warn("[Grow a Garden 2 Stocker] Failed to connect Auctioneer events: " .. tostring(err))
    end
end

function getFirstTextByNames(root, names)
    if not root then return nil end
    local targets = {}
    for _, name in ipairs(names) do
        targets[normalizeName(name)] = true
    end
    for _, desc in ipairs(root:GetDescendants()) do
        if (desc:IsA("TextLabel") or desc:IsA("TextButton")) and targets[normalizeName(desc.Name)] and isInstanceVisible(desc) then
            local text = desc.Text or ""
            if text ~= "" then return text end
        end
    end
    return nil
end

function getFirstTextMatching(root, matcher)
    if not root then return nil end
    for _, desc in ipairs(root:GetDescendants()) do
        if desc:IsA("TextLabel") or desc:IsA("TextButton") then
            local text = desc.Text or ""
            if text ~= "" and isInstanceVisible(desc) and matcher(text, desc) then
                return text
            end
        end
    end
    return nil
end

function getVisibleTextFrom(root)
    if not root then return nil end
    if (root:IsA("TextLabel") or root:IsA("TextButton")) and isInstanceVisible(root) then
        local text = root.Text or ""
        if text ~= "" then return text end
    end
    for _, desc in ipairs(root:GetDescendants()) do
        if (desc:IsA("TextLabel") or desc:IsA("TextButton")) and isInstanceVisible(desc) then
            local text = desc.Text or ""
            if text ~= "" then return text end
        end
    end
    return nil
end

function getVisibleTextAtPath(root, path)
    local node = root
    for _, name in ipairs(path) do
        node = node and node:FindFirstChild(name)
        if not node then return nil end
    end
    return getVisibleTextFrom(node)
end

function getVisibleTextByNames(root, names)
    if not root then return nil end
    local targets = {}
    for _, name in ipairs(names) do
        targets[normalizeName(name)] = true
    end
    if (root:IsA("TextLabel") or root:IsA("TextButton")) and targets[normalizeName(root.Name)] and isInstanceVisible(root) then
        local text = root.Text or ""
        if text ~= "" then return text end
    end
    for _, desc in ipairs(root:GetDescendants()) do
        if (desc:IsA("TextLabel") or desc:IsA("TextButton")) and targets[normalizeName(desc.Name)] and isInstanceVisible(desc) then
            local text = desc.Text or ""
            if text ~= "" then return text end
        end
    end
    return nil
end

function getAuctionTextFrom(root)
    if not root then return nil end
    if root:IsA("TextLabel") or root:IsA("TextButton") then
        local text = root.Text or ""
        if text ~= "" then return text end
    end
    for _, desc in ipairs(root:GetDescendants()) do
        if desc:IsA("TextLabel") or desc:IsA("TextButton") then
            local text = desc.Text or ""
            if text ~= "" then return text end
        end
    end
    return nil
end

function getAuctionTextAtPath(root, path)
    local node = root
    for _, name in ipairs(path) do
        node = node and node:FindFirstChild(name)
        if not node then return nil end
    end
    return getAuctionTextFrom(node)
end

function getAuctionTextByNames(root, names)
    if not root then return nil end
    local targets = {}
    for _, name in ipairs(names) do
        targets[normalizeName(name)] = true
    end
    if (root:IsA("TextLabel") or root:IsA("TextButton")) and targets[normalizeName(root.Name)] then
        local text = root.Text or ""
        if text ~= "" then return text end
    end
    for _, desc in ipairs(root:GetDescendants()) do
        if (desc:IsA("TextLabel") or desc:IsA("TextButton")) and targets[normalizeName(desc.Name)] then
            local text = desc.Text or ""
            if text ~= "" then return text end
        end
    end
    return nil
end

function getAuctionTextMatching(root, matcher)
    if not root then return nil end
    for _, desc in ipairs(root:GetDescendants()) do
        if desc:IsA("TextLabel") or desc:IsA("TextButton") then
            local text = desc.Text or ""
            if text ~= "" and matcher(text, desc) then
                return text
            end
        end
    end
    return nil
end

function hasAncestorNamed(instance, names, stopAt)
    if not instance then return false end
    local targets = {}
    for _, name in ipairs(names) do
        targets[normalizeName(name)] = true
    end
    local node = instance
    while node and node ~= stopAt do
        if targets[normalizeName(node.Name)] then return true end
        node = node.Parent
    end
    return false
end

function getFirstAttributeByNames(root, names)
    if not root then return nil end
    local targets = {}
    for _, name in ipairs(names) do
        targets[normalizeName(name)] = true
    end

    local function readFrom(instance)
        local ok, attrs = pcall(function()
            return instance:GetAttributes()
        end)
        if not ok or type(attrs) ~= "table" then return nil end
        for attrName, value in pairs(attrs) do
            if targets[normalizeName(attrName)] and value ~= nil and tostring(value) ~= "" then
                return value
            end
        end
        return nil
    end

    local direct = readFrom(root)
    if direct ~= nil then return direct end
    for _, desc in ipairs(root:GetDescendants()) do
        local value = readFrom(desc)
        if value ~= nil then return value end
    end
    return nil
end

function getAuctionGuiCategory(root)
    local attr = getFirstAttributeByNames(root, { "Category", "ItemCategory", "ItemToolTipCategory", "Type" })
    local normalizedAttr = normalizeAuctionCategory(attr)
    if normalizedAttr then return normalizedAttr end

    local text = getAuctionTextByNames(root, { "Category", "Category_Text", "Type", "Type_Text", "ItemType" })
        or getAuctionTextMatching(root, function(value)
            return AUCTION_CATEGORY_ALIASES[normalizeName(value)] ~= nil
        end)
    return normalizeAuctionCategory(text)
end

function getAuctionGuiImage(root, lot)
    local imageDisplay = root and root:FindFirstChild("ImageDisplay", true)
    local vector = imageDisplay and imageDisplay:FindFirstChild("Vector")
    if vector and vector:IsA("ImageLabel") then
        local vectorImage = normalizeAssetRef(vector.Image)
        if vectorImage and not isDefaultAuctionIcon(vectorImage) then
            return vectorImage
        end
    end

    local attrImage = normalizeAssetRef(getFirstAttributeByNames(root, {
        "ItemToolTipImage",
        "TooltipImage",
        "Icon",
        "Image",
        "AssetId",
        "Thumbnail"
    }))
    if attrImage and not isDefaultAuctionIcon(attrImage) then
        return attrImage
    end

    local detectedImage = normalizeAssetRef(detectImage(root))
    if detectedImage and not isDefaultAuctionIcon(detectedImage) then
        return detectedImage
    end

    local catalogImage = resolveAuctionCatalogImage(lot)
    if catalogImage and not isDefaultAuctionIcon(catalogImage) then
        return catalogImage
    end

    return attrImage or detectedImage or catalogImage
end

function textLooksLikeAuctionMoney(text)
    local raw = tostring(text or "")
    if raw == "" then return false end
    if string.find(raw, "\194\162", 1, true) ~= nil then return true end
    local compact = raw:gsub("%s+", "")
    return compact:match("^[%d%.,]+[kKmMbBtTqQ][a-zA-Z]*$") ~= nil
end

function getAuctionGuiPriceText(root)
    if not root then return nil end

    local buyButton = root:FindFirstChild("BuyButton", true)
    if buyButton then
        local text = getAuctionTextAtPath(buyButton, { "Text", "TextLabel" })
            or getAuctionTextByNames(buyButton, { "Price", "Cost" })
            or getAuctionTextFrom(buyButton)
        if textLooksLikeAuctionMoney(text) then return text end
    end

    local direct = getAuctionTextByNames(root, { "Price", "Price_Text", "Cost", "Cost_Text" })
    if textLooksLikeAuctionMoney(direct) then return direct end

    return getAuctionTextMatching(root, function(text, desc)
        if not textLooksLikeAuctionMoney(text) then return false end
        if hasAncestorNamed(desc, { "RobuxButton", "DevProduct", "Robux" }, root) then return false end
        if hasAncestorNamed(desc, { "RefreshIn", "Timer", "Time" }, root) then return false end
        return true
    end)
end

function getAuctionGuiStockText(root)
    local stockText = getAuctionTextByNames(root, { "Stock_Text" })
    if stockText and stockText ~= "" then return stockText end
    return getAuctionTextByNames(root, { "StockText", "Stock" }) or ""
end

function getAuctionGuiTimerText(root)
    if not root then return "" end
    local refreshIn = root:FindFirstChild("RefreshIn", true)
    if refreshIn then
        return getAuctionTextAtPath(refreshIn, { "Timer" })
            or getAuctionTextByNames(refreshIn, { "Timer", "RefreshIn", "Text" })
            or getAuctionTextFrom(refreshIn)
            or ""
    end
    return getAuctionTextByNames(root, { "Timer", "Time", "RefreshIn" }) or ""
end

function primeAuctionGuiForLiveValues()
    local auctionGui = PlayerGui and PlayerGui:FindFirstChild("Auction")
    if not auctionGui then return false end
    local frame = auctionGui:FindFirstChild("Frame", true)

    if auctionGui:IsA("ScreenGui") then
        if auctionGui.Enabled == false then
            auctionGui.Enabled = true
            auctionGuiPrimedAt = os.clock()
            auctionGuiAutoHidden = true
            if frame and frame:IsA("GuiObject") then
                frame.Visible = false
            end
        elseif auctionGuiPrimedAt <= 0 then
            auctionGuiPrimedAt = os.clock() - 1
        end
    end

    if auctionGuiAutoHidden and frame and frame:IsA("GuiObject") then
        frame.Visible = false
    end

    return auctionGuiPrimedAt > 0 and (os.clock() - auctionGuiPrimedAt) > 0.25
end

function isDefaultAuctionPlaceholderLot(lot)
    if type(lot) ~= "table" then return false end
    local startPrice = tonumber(lot.startPrice or lot.currentPrice or lot.price or lot.cost)
    local stockQuantity = tonumber(lot.stockQuantity or lot.stock or lot.quantity or lot.count)
    return startPrice == 100000 and stockQuantity == 16
end

function parseCompactMoney(text)
    local raw = tostring(text or ""):gsub("%s+", "")
    raw = raw:gsub("\194\162", "")
    local numberText, suffix = raw:match("([%d%.,]+)([%a]*)")
    if not numberText then return 0 end
    suffix = string.lower(suffix or "")
    if suffix == "" then
        numberText = numberText:gsub("[,%.]", "")
    else
        numberText = numberText:gsub(",", ".")
    end
    local value = tonumber(numberText)
    if not value then return 0 end
    if suffix == "k" then value = value * 1000
    elseif suffix == "m" then value = value * 1000000
    elseif suffix == "b" then value = value * 1000000000
    elseif suffix == "t" then value = value * 1000000000000
    elseif suffix == "q" or suffix == "qa" or suffix == "qd" or suffix == "quad" then value = value * 1000000000000000
    elseif suffix == "qi" then value = value * 1000000000000000000
    elseif suffix == "sx" then value = value * 1000000000000000000000
    elseif suffix == "sp" then value = value * 1000000000000000000000000
    elseif suffix == "oc" then value = value * 1000000000000000000000000000
    elseif suffix == "no" then value = value * 1000000000000000000000000000000
    elseif suffix == "dc" then value = value * 1000000000000000000000000000000000 end
    return math.max(0, math.floor(value))
end

function parseDurationSeconds(text)
    local raw = string.lower(tostring(text or ""))
    local total = 0
    local hours = tonumber(raw:match("(%d+)%s*h")) or 0
    local minutes = tonumber(raw:match("(%d+)%s*m")) or 0
    local seconds = tonumber(raw:match("(%d+)%s*s")) or 0
    total = hours * 3600 + minutes * 60 + seconds
    if total <= 0 then
        local a, b, c = raw:match("(%d+)%s*:%s*(%d+)%s*:%s*(%d+)")
        if a and b and c then
            total = tonumber(a) * 3600 + tonumber(b) * 60 + tonumber(c)
        else
            a, b = raw:match("(%d+)%s*:%s*(%d+)")
            if a and b then
                total = tonumber(a) * 60 + tonumber(b)
            end
        end
    end
    return total
end

function parseAuctionStockText(stockText)
    local raw = tostring(stockText or "")
    local lowerStock = string.lower(raw)
    local soldOut = string.find(lowerStock, "sold") ~= nil
        or string.find(lowerStock, "out") ~= nil
        or string.find(lowerStock, "expired") ~= nil
    if soldOut then return 0, true end

    local parsedStock = raw:match("[xX]%s*([%d,%s%.]+)")
        or raw:match("([%d][%d,%s%.]*)")
    if not parsedStock then return nil, false end

    local cleaned = parsedStock:gsub("[%s,%.]", "")
    local value = tonumber(cleaned)
    if value == nil then return nil, false end
    return math.max(0, math.floor(value)), false
end

function getAuctionDataFromGui()
    local auctionGui = PlayerGui and PlayerGui:FindFirstChild("Auction")
    if not auctionGui then return nil end
    local hasActiveSnapshot = latestAuctionSnapshot and (os.clock() - latestAuctionSnapshotAt) < 15
    local guiDynamicTrusted = primeAuctionGuiForLiveValues() or not hasActiveSnapshot
    local frame = auctionGui:FindFirstChild("Frame", true)
    local scrollingFrame = frame and frame:FindFirstChild("ScrollingFrame", true)
    if not scrollingFrame then return nil end

    local serverNow = getServerNow()
    local lots = {}
    local header = frame:FindFirstChild("Header")
    local headerTimerText = guiDynamicTrusted and getAuctionGuiTimerText(header) or ""
    local headerDuration = guiDynamicTrusted and parseDurationSeconds(headerTimerText) or 0
    local refreshAt = headerDuration > 0 and (serverNow + headerDuration) or 0

    for _, card in ipairs(scrollingFrame:GetChildren()) do
        pcall(function()
            if card and card.Parent and card:IsA("GuiObject") then
                local main = card:FindFirstChild("Main_Frame", true) or card:FindFirstChild("Frame", true) or card
                local priceText = getFirstTextMatching(main, function(text)
                    return string.find(text, "Р’Сћ") or string.find(text, "\194\162")
                end)
                local stockText = getFirstTextByNames(main, { "Stock_Text", "StockText", "Stock" }) or ""
                local timerText = getFirstTextByNames(main, { "RefreshIn", "Timer", "Time" }) or ""
                priceText = guiDynamicTrusted and getAuctionGuiPriceText(main) or nil
                stockText = guiDynamicTrusted and getAuctionGuiStockText(main) or ""
                timerText = guiDynamicTrusted and getAuctionGuiTimerText(main) or ""
                local nameText = getFirstAttributeByNames(main, { "ItemToolTip", "DisplayName", "ItemName", "Name" })
                    or getAuctionTextByNames(main, { "ItemName", "Item_Name", "Name", "Title" })
                    or card:GetAttribute("ItemToolTip")
                    or card:GetAttribute("DisplayName")

                if (priceText or stockText ~= "" or nameText) and normalizeName(card.Name) ~= "uilistlayout" then
                    local duration = parseDurationSeconds(timerText)
                    local expiresAt = duration > 0 and (serverNow + duration) or 0
                    if headerDuration <= 0 and expiresAt > 0 and (refreshAt == 0 or expiresAt < refreshAt) then
                        refreshAt = expiresAt
                    end

                    local stock, soldOut = parseAuctionStockText(stockText)

                    local currentPrice = parseCompactMoney(priceText)
                    local cardLotId = normalizeAuctionLotId(card.Name)
                    local cardKey = normalizeName(card.Name)
                    local isAuctionLotCard = string.sub(cardKey, 1, 10) == "lotauction" or string.sub(cardKey, 1, 7) == "auction"
                    local looksLikeTemplateAuctionRow = not isAuctionLotCard
                        and currentPrice == 1000 and stock == 16 and duration <= 0 and headerDuration <= 0
                    local looksLikeDefaultDynamic = currentPrice == 100000 and stock == 16
                    local rowDynamicTrusted = guiDynamicTrusted and not looksLikeDefaultDynamic

                    local expired = false
                    if rowDynamicTrusted then
                        local expiredObj = main:FindFirstChild("EXPIRED", true)
                        if expiredObj and expiredObj:IsA("GuiObject") and expiredObj.Visible then
                            expired = true
                        end
                        local outObj = main:FindFirstChild("OUT_OF_STOCK", true)
                        if outObj and outObj:IsA("GuiObject") and outObj.Visible then
                            soldOut = true
                            stock = 0
                        end
                    else
                        stock = nil
                        currentPrice = 0
                        expiresAt = 0
                        soldOut = false
                    end

                    if not looksLikeTemplateAuctionRow then
                        local category = getAuctionGuiCategory(main) or "Auction"
                        local rarity = getAuctionTextAtPath(main, { "Rarity", "Rarity_Text" })
                            or getFirstAttributeByNames(main, { "ItemToolTipRarity", "Rarity" })
                            or ""
                        local amountNode = main:FindFirstChild("ImageDisplay")
                        amountNode = amountNode and amountNode:FindFirstChild("Amount") or main:FindFirstChild("Amount")
                        
                        local amountText = nil
                        if amountNode and isInstanceVisible(amountNode) then
                            amountText = getAuctionTextFrom(amountNode)
                        end
                        
                        local countAttr = getFirstAttributeByNames(main, { "Amount", "Count" })
                        local imageDisplay = main:FindFirstChild("ImageDisplay")
                        local subtitleAttr = getFirstAttributeByNames(main, { "ItemToolTipSubtitle", "Subtitle" })
                            or (imageDisplay and getFirstAttributeByNames(imageDisplay, { "ItemToolTipSubtitle", "Subtitle" }) or nil)

                        local count = 1
                        if amountText and amountText ~= "" then
                            local countText = tostring(amountText):match("[xX]%s*([%d,%s%.]+)") or tostring(amountText):match("([%d][%d,%s%.]*)")
                            count = countText and tonumber((countText:gsub("[%s,%.]", ""))) or 1
                        elseif countAttr and tostring(countAttr) ~= "" then
                            local countText = tostring(countAttr):match("[xX]%s*([%d,%s%.]+)") or tostring(countAttr):match("([%d][%d,%s%.]*)")
                            count = countText and tonumber((countText:gsub("[%s,%.]", ""))) or 1
                        elseif subtitleAttr and tostring(subtitleAttr) ~= "" then
                            local countText = tostring(subtitleAttr):match("[xX]%s*([%d,%s%.]+)")
                            count = countText and tonumber((countText:gsub("[%s,%.]", ""))) or 1
                        end
                        local lotName = nameText or tostring(card.Name)
                        local lot = {
                            category = category,
                            item = lotName,
                            name = lotName,
                            displayName = lotName,
                            count = count
                        }

                        table.insert(lots, {
                            lotId = cardLotId,
                            uiLotId = tostring(card.Name),
                            orderIndex = getAuctionLotIndex(cardLotId),
                            item = lotName,
                            name = lotName,
                            category = category,
                            count = count,
                            rarity = rarity,
                            image = getAuctionGuiImage(main, lot),
                            stock = stock,
                            stockQuantity = stock,
                            stockUnknown = not rowDynamicTrusted or (stock == nil and not soldOut),
                            stockUnlimited = false,
                            currentPrice = currentPrice > 0 and currentPrice or nil,
                            priceUnknown = not rowDynamicTrusted or currentPrice <= 0,
                            expiresAt = expiresAt,
                            soldOut = soldOut,
                            expired = expired,
                            dynamicTrusted = rowDynamicTrusted,
                            looksLikeDefaultDynamic = looksLikeDefaultDynamic
                        })
                    end
                end
            end
        end)
    end

    if #lots == 0 then return nil end
    table.sort(lots, function(a, b)
        return tostring(a.lotId or "") < tostring(b.lotId or "")
    end)
    return {
        lots = lots,
        refreshAt = refreshAt,
        serverNow = serverNow,
        source = "gui",
        dynamicTrusted = guiDynamicTrusted
    }
end

function getAuctionData()
    if not latestAuctionSnapshot or (os.clock() - latestAuctionSnapshotAt) > AUCTION_REQUEST_INTERVAL then
        requestAuctionSnapshot(false)
    end
    local snapshot = latestAuctionSnapshot
    if type(snapshot) ~= "table" then return getAuctionDataFromGui() end

    local rawLots = getAuctionRawLots(snapshot)
    if type(rawLots) ~= "table" then return getAuctionDataFromGui() end

    local guiData = getAuctionDataFromGui()
    local guiLotsById = {}
    local guiLotsByIndex = {}
    local guiLotsByPosition = {}
    if guiData and type(guiData.lots) == "table" then
        for position, guiLot in ipairs(guiData.lots) do
            if guiLot and guiLot.lotId then
                local normalizedLotId = normalizeAuctionLotId(guiLot.lotId)
                guiLotsById[normalizedLotId] = guiLot
                local lotIndex = tonumber(guiLot.orderIndex) or getAuctionLotIndex(normalizedLotId)
                if lotIndex ~= nil then
                    guiLotsByIndex[lotIndex] = guiLot
                end
                guiLotsByPosition[position] = guiLot
            end
        end
    end

    local lots = {}
    local orderedRawLots = {}
    for rawIndex, lot in pairs(rawLots) do
        if type(lot) == "table" and lot.lotId then
            table.insert(orderedRawLots, {
                rawIndex = tonumber(rawIndex),
                lotId = tostring(lot.lotId),
                lot = lot
            })
        end
    end
    table.sort(orderedRawLots, function(a, b)
        if a.rawIndex and b.rawIndex and a.rawIndex ~= b.rawIndex then
            return a.rawIndex < b.rawIndex
        end
        return tostring(a.lotId or "") < tostring(b.lotId or "")
    end)

    for position, raw in ipairs(orderedRawLots) do
        pcall(function()
            local lot = raw.lot
            if type(lot) == "table" and lot.lotId then
                local lotId = normalizeAuctionLotId(lot.lotId)
                local lotIndex = getAuctionLotIndex(lotId)
                local rawIndex = raw.rawIndex
                local guiLot = guiLotsById[lotId]
                    or (lotIndex ~= nil and guiLotsByIndex[lotIndex] or nil)
                    or guiLotsByPosition[position]
                local placeholderLot = isDefaultAuctionPlaceholderLot(lot)
                local stock = getAuctionStockMapValue(latestAuctionStock, lot, lotId, lotIndex, position, rawIndex)
                local hasLiveStock = stock ~= nil
                if stock == nil and type(snapshot.stock) == "table" then
                    stock = getAuctionStockMapValue(snapshot.stock, lot, lotId, lotIndex, position, rawIndex)
                    hasLiveStock = stock ~= nil
                end
                stock = normalizeAuctionStockValue(stock)
                if stock == nil then
                    hasLiveStock = false
                end
                local useGuiDynamic = guiLot and guiLot.dynamicTrusted == true
                if useGuiDynamic and guiLot.stock ~= nil then
                    stock = guiLot.stock
                    hasLiveStock = true
                end
                if stock == nil and not placeholderLot then
                    stock = getAuctionLotFallbackStock(lot)
                end
                local currentPrice = getLotCurrentPrice(lot)
                local priceKnown = hasReliableAuctionPrice(lot)
                if useGuiDynamic and tonumber(guiLot.currentPrice) and tonumber(guiLot.currentPrice) > 0 then
                    currentPrice = tonumber(guiLot.currentPrice)
                    priceKnown = true
                end
                if placeholderLot and not useGuiDynamic then
                    priceKnown = false
                    currentPrice = nil
                    stock = nil
                    hasLiveStock = false
                end
                local stockUnknown = stock == nil and (lot.stockQuantity ~= nil or placeholderLot)
                local stockUnlimited = not stockUnknown and stock == nil and lot.stockQuantity == nil
                if stockUnknown then
                    stock = nil
                end
                if not priceKnown then
                    currentPrice = nil
                end
                local soldOut = (stock ~= nil and stock <= 0) or (useGuiDynamic and guiLot.soldOut == true)
                local lotExpiresAt = placeholderLot and not useGuiDynamic and 0 or getAuctionLotExpiry(lot)
                local expired = lotExpiresAt > 0 and lotExpiresAt <= getServerNow()
                if useGuiDynamic and guiLot.expired ~= nil then
                    expired = guiLot.expired == true
                end
                if soldOut and currentPrice ~= nil then
                    local frozenPrice = latestAuctionSoldOutPrices[lotId]
                    if frozenPrice == nil then
                        latestAuctionSoldOutPrices[lotId] = currentPrice
                        frozenPrice = currentPrice
                    end
                    currentPrice = frozenPrice
                elseif not soldOut then
                    latestAuctionSoldOutPrices[lotId] = nil
                end
                local stockQuantity = nil
                if not stockUnknown then
                    stockQuantity = hasLiveStock and stock or (useGuiDynamic and guiLot.stock ~= nil and guiLot.stock or (lot.stockQuantity or stock))
                end
                table.insert(lots, {
                    lotId = lotId,
                    item = guiLot and guiLot.item or lot.item,
                    name = guiLot and guiLot.name or getLotDisplayName(lot),
                    category = guiLot and guiLot.category or lot.category,
                    type = lot.type,
                    mutation = lot.mutation,
                    size = lot.size,
                    count = guiLot and guiLot.count or lot.count or 1,
                    rarity = guiLot and guiLot.rarity or getLotRarity(lot),
                    image = guiLot and guiLot.image or getLotImage(lot),
                    stock = stock,
                    stockQuantity = stockQuantity,
                    stockUnknown = stockUnknown,
                    stockUnlimited = stockUnlimited,
                    currentPrice = currentPrice,
                    priceUnknown = not priceKnown,
                    robuxPrice = lot.robuxPrice,
                    rolledAt = lot.rolledAt,
                    expiresAt = useGuiDynamic and guiLot.expiresAt and guiLot.expiresAt > 0 and guiLot.expiresAt or lotExpiresAt,
                    soldOut = soldOut,
                    expired = expired,
                    dynamicSource = useGuiDynamic and "gui" or "snapshot"
                })
            end
        end)
    end

    table.sort(lots, function(a, b)
        return tostring(a.lotId or "") < tostring(b.lotId or "")
    end)

    if #lots == 0 then
        return getAuctionDataFromGui()
    end

    local rollIntervalSeconds = tonumber(snapshot.rollIntervalSeconds) or 0
    local rollWindowUnix = tonumber(snapshot.rollWindowUnix) or 0
    local timerShiftSeconds = tonumber(snapshot.timerShiftSeconds) or 0
    local refreshAt = 0
    local serverNow = getServerNow()
    if rollIntervalSeconds > 0 and rollWindowUnix > 0 then
        refreshAt = rollWindowUnix + rollIntervalSeconds + timerShiftSeconds
    end
    if refreshAt <= serverNow then
        local nextLotExpiry = 0
        for _, lot in ipairs(lots) do
            local expiresAt = tonumber(lot.expiresAt) or 0
            if expiresAt > serverNow and (nextLotExpiry == 0 or expiresAt < nextLotExpiry) then
                nextLotExpiry = expiresAt
            end
        end
        if nextLotExpiry > 0 then
            refreshAt = nextLotExpiry
        end
    end
    if guiData and tonumber(guiData.refreshAt) and tonumber(guiData.refreshAt) > serverNow then
        refreshAt = tonumber(guiData.refreshAt)
    end


    return {
        lots = lots,
        stock = latestAuctionStock,
        rollIntervalSeconds = rollIntervalSeconds,
        rollWindowUnix = rollWindowUnix,
        timerShiftSeconds = timerShiftSeconds,
        refreshAt = refreshAt,
        serverNow = serverNow
    }
end

local fruitImageCache = {}
local fruitImageCacheByKey = {}
local fruitImagesWatched = {}
local fruitImagesFolderConnected = false
local fruitImageCacheBuilt = false
local fruitListCache = nil

function getFruitImagesFolder()
    local root = SharedModules or ReplicatedStorage:FindFirstChild("SharedModules")
    local seedData = root and root:FindFirstChild("SeedData")
    return seedData and seedData:FindFirstChild("FruitImages") or nil
end

function readFruitImageEntry(entry)
    if not entry then return nil end
    if entry:IsA("StringValue") or entry:IsA("IntValue") or entry:IsA("NumberValue") then
        return normalizeAssetRef(entry.Value)
    end
    if entry:IsA("ImageLabel") or entry:IsA("ImageButton") then
        return normalizeAssetRef(entry.Image)
    end
    local attr = entry:GetAttribute("Image") or entry:GetAttribute("ImageId") or entry:GetAttribute("TextureId")
    return normalizeAssetRef(attr)
end

function setFruitImageCacheValue(entry)
    local name = cleanScrapedName(entry and entry.Name)
    if not name or name == "" then return end

    local image = readFruitImageEntry(entry)
    local key = normalizeName(name)
    if fruitImageCache[name] ~= image or fruitImageCacheByKey[key] ~= image then
        fruitImageCache[name] = image
        fruitImageCacheByKey[key] = image
        fruitListCache = nil
    end
end

function removeFruitImageCacheValue(entry)
    local name = cleanScrapedName(entry and entry.Name)
    if not name or name == "" then return end
    fruitImageCache[name] = nil
    fruitImageCacheByKey[normalizeName(name)] = nil
    fruitListCache = nil
end

function watchFruitImageEntry(entry)
    if not entry or fruitImagesWatched[entry] then return end
    fruitImagesWatched[entry] = entry.Changed:Connect(function()
        setFruitImageCacheValue(entry)
    end)
end

function ensureFruitImageCache()
    local folder = getFruitImagesFolder()
    if not folder then return end

    if not fruitImagesFolderConnected then
        fruitImagesFolderConnected = true
        folder.ChildAdded:Connect(function(entry)
            setFruitImageCacheValue(entry)
            watchFruitImageEntry(entry)
        end)
        folder.ChildRemoved:Connect(function(entry)
            removeFruitImageCacheValue(entry)
            local conn = fruitImagesWatched[entry]
            if conn then
                conn:Disconnect()
                fruitImagesWatched[entry] = nil
            end
        end)
    end

    if fruitImageCacheBuilt then return end
    fruitImageCacheBuilt = true
    for _, entry in ipairs(folder:GetChildren()) do
        setFruitImageCacheValue(entry)
        watchFruitImageEntry(entry)
    end
end

function getFruitImage(fruitName)
    ensureFruitImageCache()
    local name = cleanScrapedName(fruitName)
    if not name then return nil end
    return fruitImageCache[name] or fruitImageCacheByKey[normalizeName(name)]
end

-- ================== FRUIT VALUE CALCULATOR DATA SOURCE ==================
-- The website calculator uses live in-game modules instead of a hand-written
-- price list. Mutations are read from ReplicatedStorage.SharedModules.MutationData
-- children and then adjusted by live selling FastFlags.
local calculatorDataCache = nil
local calculatorDataCacheAt = -60
local CALCULATOR_DATA_REFRESH_INTERVAL = 60
local cachedFastFlags = false
local cachedAsserts = false

function getUserGeneratedChild(...)
    local node = ReplicatedStorage:FindFirstChild("UserGenerated")
    if not node then return nil end
    local names = { ... }
    for _, name in ipairs(names) do
        node = node and node:FindFirstChild(name)
        if not node then return nil end
    end
    return node
end

function getFastFlagsModule()
    if cachedFastFlags ~= false then return cachedFastFlags end
    local module = safeRequireModule(getUserGeneratedChild("FastFlags"))
    if module then
        cachedFastFlags = module
    end
    return module
end

function getAssertsModule()
    if cachedAsserts ~= false then return cachedAsserts end
    local module = safeRequireModule(getUserGeneratedChild("Lang", "Asserts"))
    if module then
        cachedAsserts = module
    end
    return module
end

function getFastFlagValue(flagName, defaultValue, assertFactory)
    local fastFlags = getFastFlagsModule()
    local asserts = getAssertsModule()
    if not (fastFlags and fastFlags.Replicated and asserts and assertFactory) then
        return defaultValue
    end

    local okAssert, assertValue = pcall(function()
        return assertFactory(asserts)
    end)
    if not okAssert then
        return defaultValue
    end

    local okFlag, flag = pcall(function()
        return fastFlags.Replicated(flagName, assertValue, defaultValue)
    end)
    if not (okFlag and flag and flag.Get) then
        return defaultValue
    end

    local okValue, value = pcall(function()
        return flag:Get()
    end)
    if okValue and value ~= nil then
        return value
    end
    return defaultValue
end

function cleanNumberMap(input, fallback)
    local out = {}
    if type(fallback) == "table" then
        for key, value in pairs(fallback) do
            local n = tonumber(value)
            if type(key) == "string" and n then out[key] = n end
        end
    end
    if type(input) == "table" then
        for key, value in pairs(input) do
            local n = tonumber(value)
            if type(key) == "string" and n then out[key] = n end
        end
    end
    return out
end

function readNumberField(source, names)
    if type(source) ~= "table" then return nil end
    for _, fieldName in ipairs(names) do
        local value = source[fieldName]
        local n = tonumber(value)
        if n and n > 0 then return n end
        if type(value) == "string" then
            local parsed = tonumber((value:gsub(",", "."):match("([%d%.]+)")))
            if parsed and parsed > 0 then return parsed end
        end
    end
    return nil
end

function readAverageWeight(entry)
    local fields = {
        "AverageWeight", "AvgWeight", "MeanWeight", "DefaultWeight", "BaseWeight",
        "FruitWeight", "AverageFruitWeight", "AvgFruitWeight", "DefaultFruitWeight", "BaseFruitWeight",
        "CropWeight", "AverageCropWeight", "AvgCropWeight", "HarvestWeight", "AverageHarvestWeight",
        "ProduceWeight", "DefaultMass", "BaseMass", "Weight", "Mass", "Size", "BaseSize", "DefaultSize"
    }
    local direct = readNumberField(entry, fields)
    if direct then return direct end

    local minWeight = readNumberField(entry, { "MinWeight", "MinimumWeight", "MinMass", "MinimumMass", "MinSize" })
    local maxWeight = readNumberField(entry, { "MaxWeight", "MaximumWeight", "MaxMass", "MaximumMass", "MaxSize" })
    if minWeight and maxWeight then
        return (minWeight + maxWeight) / 2
    end

    for _, nestedName in ipairs({ "WeightData", "FruitData", "CropData", "HarvestData", "Config", "Selling", "SellData" }) do
        local nested = entry[nestedName]
        local nestedValue = readNumberField(nested, fields)
        if nestedValue then return nestedValue end
        local nestedMin = readNumberField(nested, { "MinWeight", "MinimumWeight", "MinMass", "MinimumMass", "MinSize" })
        local nestedMax = readNumberField(nested, { "MaxWeight", "MaximumWeight", "MaxMass", "MaximumMass", "MaxSize" })
        if nestedMin and nestedMax then
            return (nestedMin + nestedMax) / 2
        end
    end
    return nil
end

local plantAverageSizeCache = nil

function getDefaultPlantAverageSize()
    if plantAverageSizeCache then return plantAverageSizeCache end
    local sizeModule = safeRequireModule(getSharedModule("PlantSizeMultipliers"))
    local tiers = nil
    if sizeModule and sizeModule.GetDefaultPlantTiers then
        local ok, result = pcall(function()
            return sizeModule.GetDefaultPlantTiers()
        end)
        if ok and type(result) == "table" then
            tiers = result
        end
    end
    if type(tiers) ~= "table" then
        tiers = {
            { min = 0.95, max = 1.05, weight = 2000 },
            { min = 1.45, max = 1.55, weight = 250 },
            { min = 1.9, max = 2.1, weight = 125 },
            { min = 2.85, max = 3.15, weight = 62.5 },
            { min = 3.8, max = 4.2, weight = 31.25 },
            { min = 5.8, max = 6.2, weight = 15.625 },
            { min = 9.5, max = 12.5, weight = 3 },
            { min = 12, max = 17, weight = 0.05 },
            { min = 20, max = 35, weight = 0.0001 }
        }
    end
    local weighted, totalWeight = 0, 0
    for _, tier in pairs(tiers) do
        if type(tier) == "table" then
            local minSize = tonumber(tier.min) or tonumber(tier.Min) or tonumber(tier.minimum)
            local maxSize = tonumber(tier.max) or tonumber(tier.Max) or tonumber(tier.maximum)
            local weight = tonumber(tier.weight) or tonumber(tier.Weight) or 0
            if minSize and maxSize and weight > 0 then
                weighted = weighted + ((minSize + maxSize) / 2) * weight
                totalWeight = totalWeight + weight
            end
        end
    end
    plantAverageSizeCache = totalWeight > 0 and (weighted / totalWeight) or 1
    return plantAverageSizeCache
end

function getNumberMapValue(map, name, fallback)
    if type(map) ~= "table" then return fallback end
    if map[name] ~= nil then
        local n = tonumber(map[name])
        if n then return n end
    end
    local target = string.lower(tostring(name or ""))
    for key, value in pairs(map) do
        if string.lower(tostring(key or "")) == target then
            local n = tonumber(value)
            if n then return n end
        end
    end
    return fallback
end

function calculateCalculatorSizePower(fruitName, weight, config)
    local safeWeight = tonumber(weight) or 1
    if safeWeight < 0.01 then safeWeight = 0.01 end
    config = type(config) == "table" and config or {}
    local dr = type(config.diminishingReturns) == "table" and config.diminishingReturns or {}
    local exponent = getNumberMapValue(config.sizeExponentOverrides, fruitName, tonumber(config.sizeExponent) or 2.65)
    local sizePower = safeWeight ^ exponent

    if dr.enabled ~= false then
        local knee = (tonumber(dr.knee) or 5) * getNumberMapValue(dr.kneeMultipliers, fruitName, 1)
        if knee > 0 and safeWeight > knee then
            local tailBase = tonumber(dr.tailExponent) or 1.5
            local tailMultiplier = getNumberMapValue(dr.tailExponentMultipliers, fruitName, 1)
            local tailExponent = math.min(tailBase * tailMultiplier, exponent)
            sizePower = (knee ^ exponent) * ((safeWeight / knee) ^ tailExponent)
        end
    end

    if sizePower <= 0 then return 1 end
    return sizePower
end

function buildSeedMeta(seedData)
    local meta = {}
    if type(seedData) ~= "table" then return meta end
    for _, entry in pairs(seedData) do
        if type(entry) == "table" then
            local seedName = entry.SeedName or entry.Name or entry.FruitName
            if type(seedName) == "string" and seedName ~= "" then
                local value = {
                    isSingleHarvest = entry.IsSingleHarvest == true,
                    rarity = entry.Rarity or entry.Tier,
                    image = normalizeAssetRef(entry.Image or entry.Icon or entry.AssetId),
                    averageWeight = readAverageWeight(entry) or getDefaultPlantAverageSize()
                }
                meta[seedName] = value
                meta[normalizeName(seedName)] = value
            end
        end
    end
    return meta
end

function getMutationMultiplier(mutationData, mutationName, rawEntry)
    if type(mutationName) ~= "string" or mutationName == "" then return nil end

    -- Try resolving ReturnPriceMultiplier via GC dynamically to bypass require restrictions
    local gc = getgc or (debug and debug.getregistry)
    if gc then
        local foundFunc = nil
        pcall(function()
            for _, v in ipairs(gc(true)) do
                if type(v) == "table" and rawget(v, "ReturnPriceMultiplier") and type(v.ReturnPriceMultiplier) == "function" then
                    foundFunc = v.ReturnPriceMultiplier
                    break
                end
            end
        end)
        if foundFunc then
            local ok, value = pcall(foundFunc, mutationName)
            local n = tonumber(value)
            if ok and n and n > 0 then return n end
        end
    end

    if type(mutationData) == "table" and mutationData.ReturnPriceMultiplier then
        local ok, value = pcall(function()
            return mutationData.ReturnPriceMultiplier(mutationName)
        end)
        local n = tonumber(value)
        if ok and n and n > 0 then return n end
    end

    if type(rawEntry) == "number" then
        return rawEntry
    end
    if type(rawEntry) == "table" then
        local raw = rawEntry.PriceMultiplier or rawEntry.Multiplier or rawEntry.Value or rawEntry.SellMultiplier or rawEntry.SellValueMultiplier
        local n = tonumber(raw)
        if n and n > 0 then return n end
    end
    return nil
end

function collectMutationEntriesFromInstance(moduleScript)
    local entries = {}
    if not moduleScript then return entries end

    local function findExistingEntry(name)
        local key = normalizeName(name)
        for existingName, entry in pairs(entries) do
            if normalizeName(existingName) == key then
                return existingName, entry
            end
        end
        return nil, nil
    end

    local function putEntry(name, multiplier, rawEntry)
        if type(name) ~= "string" or name == "" then return end
        local cleanName = cleanScrapedName(name)
        if not cleanName or cleanName == "" then return end
        local n = tonumber(multiplier)
        if not n and type(rawEntry) == "table" then
            n = tonumber(rawEntry.PriceMultiplier or rawEntry.Multiplier or rawEntry.Value or rawEntry.SellMultiplier or rawEntry.SellValueMultiplier)
        end
        if not n or n <= 0 then return end

        local existingName, entry = findExistingEntry(cleanName)
        if entry then
            entry.PriceMultiplier = n
            entry.Raw = rawEntry or entry.Raw
            return
        end

        entries[cleanName] = {
            Name = cleanName,
            PriceMultiplier = n,
            Raw = rawEntry
        }
    end

    local function addFromInstance(inst)
        local name = inst:GetAttribute("Name")
            or inst:GetAttribute("MutationName")
            or inst:GetAttribute("Mutation")
            or inst.Name
        local multiplier = inst:GetAttribute("PriceMultiplier")
            or inst:GetAttribute("Multiplier")
            or inst:GetAttribute("Value")
            or inst:GetAttribute("SellMultiplier")
            or inst:GetAttribute("SellValueMultiplier")

        if multiplier == nil and (inst:IsA("NumberValue") or inst:IsA("IntValue")) then
            multiplier = inst.Value
        elseif multiplier == nil and inst:IsA("StringValue") then
            multiplier = tonumber(inst.Value)
        end

        putEntry(name, multiplier)
    end

    pcall(function()
        addFromInstance(moduleScript)
        for _, desc in ipairs(moduleScript:GetDescendants()) do
            addFromInstance(desc)
        end

        for _, child in ipairs(moduleScript:GetChildren()) do
            if child:IsA("ModuleScript") then
                local mutationModule = safeRequireModule(child)
                if type(mutationModule) == "table" then
                    local name = mutationModule.Name
                        or mutationModule.MutationName
                        or mutationModule.Mutation
                        or child.Name
                    putEntry(name, mutationModule.PriceMultiplier, mutationModule)
                end
            end
        end
    end)

    local defaults = {}
    for name, entry in pairs(entries) do
        if entry and entry.PriceMultiplier then
            defaults[name] = entry.PriceMultiplier
        end
    end

    local overrideMultipliers = getFastFlagValue(
        "Game.Mutations.PriceMultipliers",
        defaults,
        function(asserts) return asserts.Map(asserts.String, asserts.FinitePositive) end
    )
    if type(overrideMultipliers) == "table" then
        for name, multiplier in pairs(overrideMultipliers) do
            putEntry(name, multiplier)
        end
    end

    return entries
end

function getMutationDataList(mutationData)
    local byKey = {}
    local mutations = {}

    local function addMutation(name, multiplier, rawEntry)
        if type(name) ~= "string" or name == "" then return end
        local cleanName = cleanScrapedName(name)
        if not cleanName or cleanName == "" then return end
        local value = tonumber(multiplier) or getMutationMultiplier(mutationData, cleanName, rawEntry)
        if not value or value <= 0 then return end
        local key = normalizeName(cleanName)
        if byKey[key] then return end
        byKey[key] = true
        table.insert(mutations, {
            name = cleanName,
            multiplier = value
        })
    end

    addMutation("None", 1)

    if type(mutationData) == "table" then
        for key, entry in pairs(mutationData) do
            if type(key) == "string" and key ~= "ReturnPriceMultiplier" then
                local name = key
                if type(entry) == "table" then
                    name = entry.Name or entry.MutationName or entry.Mutation or key
                end
                addMutation(name, nil, entry)
            end
        end
    end

    table.sort(mutations, function(a, b)
        if normalizeName(a.name) == "none" then return true end
        if normalizeName(b.name) == "none" then return false end
        return tostring(a.name) < tostring(b.name)
    end)
    return mutations
end

function getCalculatorData()
    local now = os.clock()
    if calculatorDataCache and (now - calculatorDataCacheAt) < CALCULATOR_DATA_REFRESH_INTERVAL then
        return calculatorDataCache
    end

    local sellValueData = safeRequireModule(getSharedModule("SellValueData"))
    local seedData = safeRequireModule(getSharedModule("SeedData"))
    local mutationData = collectMutationEntriesFromInstance(getSharedModule("MutationData"))
    if type(sellValueData) ~= "table" then
        return calculatorDataCache
    end

    local seedMeta = buildSeedMeta(seedData)
    local defaultExponentOverrides = { Mushroom = 1.9, Bamboo = 1.75 }
    local emptyFruitMap = {}
    for fruitName, _ in pairs(sellValueData) do
        if type(fruitName) == "string" then
            emptyFruitMap[cleanScrapedName(fruitName) or fruitName] = 1
        end
    end

    local sizeExponentOverrides = getFastFlagValue(
        "Game.Selling.SizeExponentOverrides",
        defaultExponentOverrides,
        function(asserts) return asserts.Map(asserts.String, asserts.FinitePositive) end
    )
    local kneeMultipliers = getFastFlagValue(
        "Game.Selling.SizeDiminishingReturns.KneeMultipliers",
        emptyFruitMap,
        function(asserts) return asserts.Map(asserts.String, asserts.FinitePositive) end
    )
    local tailExponentMultipliers = getFastFlagValue(
        "Game.Selling.SizeDiminishingReturns.TailExponentMultipliers",
        emptyFruitMap,
        function(asserts) return asserts.Map(asserts.String, asserts.FinitePositive) end
    )
    local priceMultipliers = getFastFlagValue(
        "Game.Sell.PriceMultipliers",
        { Mushroom = 0.5 },
        function(asserts) return asserts.Map(asserts.String, asserts.FinitePositive) end
    )

    local calculatorConfig = {
        sizeMultiplier = getFastFlagValue("Game.Selling.SizeMultiplier", 1, function(asserts) return asserts.FinitePositive end),
        mutationMultiplier = getFastFlagValue("Game.Selling.MutationMultiplier", 1, function(asserts) return asserts.FinitePositive end),
        sizeExponent = getFastFlagValue("Game.Selling.SizeExponent", 2.65, function(asserts) return asserts.FinitePositive end),
        sizeExponentOverrides = cleanNumberMap(sizeExponentOverrides, defaultExponentOverrides),
        singleHarvestMutationBonusScale = getFastFlagValue("Game.Selling.SingleHarvestMutationBonusScale", 0.15, function(asserts) return asserts.FiniteNonNegative end),
        minimumValues = { Carrot = 4 },
        globalMultiplier = getFastFlagValue("Game.Sell.GlobalMultiplier", 1, function(asserts) return asserts.FinitePositive end),
        priceMultipliers = cleanNumberMap(priceMultipliers, { Mushroom = 0.5 }),
        diminishingReturns = {
            enabled = getFastFlagValue("Game.Selling.SizeDiminishingReturns.Enabled", true, function(asserts) return asserts.Boolean end) ~= false,
            knee = getFastFlagValue("Game.Selling.SizeDiminishingReturns.Knee", 5, function(asserts) return asserts.FinitePositive end),
            tailExponent = getFastFlagValue("Game.Selling.SizeDiminishingReturns.TailExponent", 1.5, function(asserts) return asserts.FinitePositive end),
            kneeMultipliers = cleanNumberMap(kneeMultipliers, {}),
            tailExponentMultipliers = cleanNumberMap(tailExponentMultipliers, {})
        }
    }

    local fruits = {}
    for fruitName, baseValue in pairs(sellValueData) do
        local value = tonumber(baseValue)
        if type(fruitName) == "string" and value and value >= 0 then
            local cleanName = cleanScrapedName(fruitName)
            local meta = seedMeta[fruitName] or seedMeta[normalizeName(fruitName)] or {}
            local averageWeight = tonumber(meta.averageWeight) or getDefaultPlantAverageSize()
            local averageSizePower = calculateCalculatorSizePower(cleanName, averageWeight, calculatorConfig)
            local baseValuePerKg = averageSizePower > 0 and (value / averageSizePower) or value
            table.insert(fruits, {
                name = cleanName,
                baseValue = value,
                baseValuePerKg = baseValuePerKg,
                averageSizePower = averageSizePower,
                image = getFruitImage(fruitName) or meta.image,
                rarity = meta.rarity,
                isSingleHarvest = meta.isSingleHarvest == true,
                averageWeight = averageWeight
            })
        end
    end

    table.sort(fruits, function(a, b)
        if a.baseValue == b.baseValue then
            return tostring(a.name) < tostring(b.name)
        end
        return a.baseValue > b.baseValue
    end)

    calculatorDataCache = {
        source = "live-data",
        scrapedAt = os.time(),
        fruits = fruits,
        mutations = getMutationDataList(mutationData),
        config = calculatorConfig
    }
    calculatorDataCacheAt = now
    return calculatorDataCache
end

local latestFruitEntries = {}
local latestFruitEntriesByKey = {}
local latestFruitSnapshotAt = 0
local fruitServerOffset = 0
local fruitNextRefreshUnix = 0
local fruitRequestPending = false
local lastFruitRequestAt = -FRUIT_REQUEST_INTERVAL
local fruitSnapshotConnected = false

function applyFruitSnapshot(snapshot)
    if type(snapshot) ~= "table" then return false end

    if type(snapshot.server_now_unix) == "number" then
        fruitServerOffset = snapshot.server_now_unix - os.time()
    end
    if type(snapshot.nextRefreshUnix) == "number" then
        fruitNextRefreshUnix = snapshot.nextRefreshUnix
    end

    local rawEntries = snapshot.entries
        or snapshot.fruits
        or snapshot.multipliers
        or snapshot.fruitMultipliers

    if type(rawEntries) ~= "table" then
        if DEBUG then
            warn("[Grow a Garden 2 Stocker] FruitStock snapshot missing entries table")
        end
        return false
    end

    local entries = {}
    local entriesByKey = {}
    local count = 0

    local function addEntry(fruitName, rawEntry)
        if type(rawEntry) ~= "table" and type(rawEntry) ~= "number" then return end

        local name = fruitName
        local multiplier = 1
        local tier = "normal"

        if type(rawEntry) == "number" then
            multiplier = rawEntry
        else
            name = rawEntry.name or rawEntry.key or rawEntry.fruit or rawEntry.itemName or rawEntry.seed or name
            local rawMultiplier = rawEntry.multiplier or rawEntry.rate or rawEntry.value or rawEntry.mult or rawEntry[1]
            if type(rawMultiplier) == "string" then
                rawMultiplier = string.match(rawMultiplier:gsub(",", "."), "([%d%.]+)")
            end
            multiplier = tonumber(rawMultiplier) or 1
            if type(rawEntry.tier) == "string" then tier = rawEntry.tier end
        end

        if type(name) ~= "string" or name == "" then return end
        local cleanName = cleanScrapedName(name)
        if not cleanName or cleanName == "" then return end

        local info = {
            multiplier = multiplier,
            tier = tier
        }
        entries[cleanName] = info
        entriesByKey[normalizeName(cleanName)] = info
        count = count + 1
    end

    for fruitName, rawEntry in pairs(rawEntries) do
        addEntry(type(fruitName) == "string" and fruitName or nil, rawEntry)
    end

    if count <= 0 then
        if DEBUG then
            warn("[Grow a Garden 2 Stocker] FruitStock snapshot had no usable entries")
        end
        return false
    end

    latestFruitEntries = entries
    latestFruitEntriesByKey = entriesByKey
    fruitListCache = nil
    latestFruitSnapshotAt = os.clock()
    return true
end

function getFruitStockNetworking()
    local networking = getNetworkingModule()
    local fruitStock = networking and networking.FruitStock or nil
    if fruitStock then
        writeDebugLog("FruitStock networking obtained via Sharing Module")
    else
        writeDebugLog("FruitStock networking sharing module failed, trying fallback")
        fruitStock = getFallbackNetworking("FruitStock")
    end
    return fruitStock
end

function requestFruitSnapshot(force)
    local now = os.clock()
    if fruitRequestPending then return false end
    if not force and (now - lastFruitRequestAt) < FRUIT_REQUEST_INTERVAL then
        return false
    end

    local fruitStock = getFruitStockNetworking()
    local requestRemote = fruitStock and fruitStock.Request
    if not requestRemote then return false end

    fruitRequestPending = true
    lastFruitRequestAt = now

    local ok, result = pcall(function()
        if requestRemote.Fire then
            return requestRemote:Fire()
        end
        if requestRemote.FireServer then
            return requestRemote:FireServer()
        end
        if requestRemote.InvokeServer then
            return requestRemote:InvokeServer()
        end
        if requestRemote.Invoke then
            return requestRemote:Invoke()
        end
        return nil
    end)

    fruitRequestPending = false
    if ok and type(result) == "table" then
        return applyFruitSnapshot(result)
    end
    if DEBUG and not ok then
        warn("[Grow a Garden 2 Stocker] FruitStock.Request failed: " .. tostring(result))
    end
    return false
end

function connectFruitStockSnapshot(onSnapshot)
    if fruitSnapshotConnected then return end
    local fruitStock = getFruitStockNetworking()
    local snapshotEvent = fruitStock and fruitStock.Snapshot
    if not snapshotEvent then return end

    local connected = false
    local ok, err = pcall(function()
        if snapshotEvent.OnClientEvent then
            snapshotEvent.OnClientEvent:Connect(function(snapshot)
                if applyFruitSnapshot(snapshot) and onSnapshot then
                    onSnapshot()
                end
            end)
            connected = true
        elseif snapshotEvent.Connect then
            snapshotEvent:Connect(function(snapshot)
                if applyFruitSnapshot(snapshot) and onSnapshot then
                    onSnapshot()
                end
            end)
            connected = true
        end
    end)

    fruitSnapshotConnected = ok and connected
    if DEBUG and not ok then
        warn("[Grow a Garden 2 Stocker] Failed to connect FruitStock.Snapshot: " .. tostring(err))
    end
end

function getFruitRefreshTimer()
    if fruitNextRefreshUnix <= 0 then
        requestFruitSnapshot(false)
    end
    if fruitNextRefreshUnix <= 0 then return nil end
    return math.max(0, math.floor(fruitNextRefreshUnix - (os.time() + fruitServerOffset)))
end

function addFruitName(list, seen, name)
    local cleanName = cleanScrapedName(name)
    if not cleanName or cleanName == "" then return end
    local key = normalizeName(cleanName)
    if key == "" or seen[key] then return end
    seen[key] = true
    table.insert(list, cleanName)
end

function getKnownFruitNames()
    ensureFruitImageCache()

    local names = {}
    local seen = {}

    for fruitName in pairs(fruitImageCache) do
        addFruitName(names, seen, fruitName)
    end

    for fruitName in pairs(latestFruitEntries) do
        addFruitName(names, seen, fruitName)
    end

    table.sort(names, function(a, b)
        return string.lower(a) < string.lower(b)
    end)
    return names
end

function getFruitEntry(fruitName)
    if not fruitName then return nil end
    return latestFruitEntries[fruitName] or latestFruitEntriesByKey[normalizeName(fruitName)]
end

function getFruitMultipliers()
    ensureFruitImageCache()
    if latestFruitSnapshotAt == 0 or (os.clock() - latestFruitSnapshotAt) > FRUIT_REQUEST_INTERVAL then
        requestFruitSnapshot(false)
    end
    if fruitListCache and #fruitListCache > 0 then return fruitListCache end

    local multipliers = {}
    for _, fruitName in ipairs(getKnownFruitNames()) do
        local entry = getFruitEntry(fruitName)
        local multiplier = entry and tonumber(entry.multiplier) or 1
        local tier = entry and entry.tier or "normal"
        table.insert(multipliers, {
            name = fruitName,
            image = getFruitImage(fruitName),
            key = fruitName,
            multiplier = multiplier,
            tier = tier
        })
    end

    table.sort(multipliers, function(a, b)
        if a.multiplier == b.multiplier then
            return string.lower(a.name or "") < string.lower(b.name or "")
        end
        return a.multiplier > b.multiplier
    end)

    if #multipliers > 0 then
        fruitListCache = multipliers
    end
    return multipliers
end

-- ================== STATE POLLING + UPDATE ==================
-- Compact hash of a fruit list, used by the fast poll to detect value changes.
function fruitHash(list)
    local h = ""
    for _, m in ipairs(list) do
        h = h .. (m.key or "?") .. ":" .. tostring(m.multiplier) .. ":" .. tostring(m.tier) .. ":" .. tostring(m.image) .. "|"
    end
    return h
end

local lastUpdateTime = 0
local updatePending = false
local pendingFruitData = nil

-- updateAPI(fruitData): fruitData is an optional pre-scraped fruit list. If nil,
-- fruits are scraped fresh inside. We ALWAYS send live fruit data (never a stale
-- cache) so the website/bot reflects in-game multiplier changes immediately.
function updateAPI(fruitData)
    pendingFruitData = fruitData or pendingFruitData
    if updatePending then return end
    local now = os.clock()
    local elapsed = now - lastUpdateTime
    if elapsed < 1.0 then
        updatePending = true
        local waitLeft = 1.0 - elapsed
        safeTaskDelay(waitLeft, function()
            updatePending = false
            local dataToSend = pendingFruitData
            pendingFruitData = nil
            updateAPI(dataToSend)
        end)
        return
    end
    lastUpdateTime = now
    local dataToSend = pendingFruitData
    pendingFruitData = nil

    local success, err = pcall(function()
        local function resolveShopPath(shopName, innerName)
            local shop = findChildByNormalizedName(PlayerGui, { shopName })
            if not shop then return nil end
            local frame = findChildByNormalizedName(shop, { "Frame" })
            if not frame then return nil end
            return findChildByNormalizedName(frame, { innerName })
        end

        local phase, phaseImage, weathers, endTime = getActiveWeatherAndPhase()
        local isNight = isNightPhase(phase)
        local weatherCatalog = getWeatherCatalog()
        if not phaseImage then
            phaseImage = getCatalogImageByName(weatherCatalog, phase)
        end
        for weatherName, info in pairs(weathers or {}) do
            if info and info.image and not isWeatherImageValidForName(weatherName, info.image) then
                info.image = nil
            end
            if info and not info.image then
                info.image = getCatalogImageByName(weatherCatalog, weatherName)
            end
            if info and info.image and not isWeatherImageValidForName(weatherName, info.image) then
                info.image = nil
            end
        end

        local data = {
            password = API_PASSWORD,
            jobId = game.JobId ~= "" and game.JobId or "studio",
            restockTimes = getRestockTimes(),
            weather = {
                night = isNight,
                phase = phase,
                phaseImage = phaseImage,
                weathers = weathers,
                endTime = endTime
            },
            weatherCatalog = weatherCatalog,
            shops = {
                CrateShop = scrapeShopSafe(resolveShopPath("CrateShop", "ScrollingFrame")),
                GearShop = scrapeShopSafe(resolveShopPath("GearShop", "ScrollingFrame")),
                SeedShop_Normal = scrapeShopSafe(resolveShopPath("SeedShop", "NormalShop"))
            },
            -- ALWAYS send live fruit data (never a stale cache) so the website reflects
            -- in-game multiplier changes immediately.
            fruitMultipliers = dataToSend or fruitData or getFruitMultipliers(),
            -- Seconds until the next in-game multiplier refresh (dynamic countdown).
            fruitRefreshTimer = getFruitRefreshTimer(),
            calculatorData = getCalculatorData(),
            auction = getAuctionData()
        }

        safeTaskSpawn(function()
            local encodeOk, encoded = pcall(function() return HttpService:JSONEncode(data) end)
            if not encodeOk then
                warn("[Grow a Garden 2 Stocker] JSON encoding failed: " .. tostring(encoded))
                return
            end

            -- Try updating via WebSocket first
            local ws = getWebSocketClient()
            if ws then
                local wsPayload = {
                    type = "update-stock",
                    password = API_PASSWORD,
                    data = data
                }
                local encodeOk2, encodedWs = pcall(function() return HttpService:JSONEncode(wsPayload) end)
                if encodeOk2 then
                    local sendFunc = ws.Send or ws.send
                    local wsSuccess, wsErr = pcall(function()
                        sendFunc(ws, encodedWs)
                    end)
                    if wsSuccess then
                        if DEBUG then
                            print("[Grow a Garden 2 Stocker] Stock data updated instantly via WebSocket!")
                        end
                        return -- Success, skip HTTP fallback
                    else
                        warn("[Grow a Garden 2 Stocker] WebSocket send failed: " .. tostring(wsErr) .. ". Falling back to HTTP POST...")
                        -- Reset connection on error
                        pcall(function() ws:Close() end)
                        pcall(function() ws:close() end)
                        wsConnection = nil
                    end
                end
            end

            -- Fallback HTTP POST update
            local ok, response = makeHttpRequest(API_URL, "POST",
                { ["Content-Type"] = "application/json", ["X-API-Password"] = API_PASSWORD }, encoded)
            if ok then
                if DEBUG then
                    print("[Grow a Garden 2 Stocker] Stock data updated via HTTP POST: " .. tostring(response))
                end
            else
                warn("[Grow a Garden 2 Stocker] Failed to update stock data: " .. tostring(response))
            end
        end)
    end)
    if not success then
        warn("[Grow a Garden 2 Stocker] Error during updateAPI: " .. tostring(err))
    end
end

-- ================== EVENT HOOKS ==================
-- FruitStock.Snapshot is the same source FruitStockPriceController uses for x4/x5 values.
pcall(function()
    connectFruitStockSnapshot(function()
        updateAPI(getFruitMultipliers())
    end)
    requestFruitSnapshot(true)
end)

pcall(function()
    connectAuctionSnapshot(function()
        updateAPI(nil)
    end)
    requestAuctionSnapshot(true)
end)

safeTaskSpawn(function()
    for attempt = 1, AUCTION_STARTUP_RETRY_COUNT do
        if latestAuctionSnapshot and type(getAuctionRawLots(latestAuctionSnapshot)) == "table" then
            updateAPI(nil)
            return
        end
        connectAuctionSnapshot(function()
            updateAPI(nil)
        end)
        local gotSnapshot = requestAuctionSnapshot(true)
        if gotSnapshot or (latestAuctionSnapshot and type(getAuctionRawLots(latestAuctionSnapshot)) == "table") then
            writeDebugLog("Auction startup snapshot ready on attempt " .. tostring(attempt))
            updateAPI(nil)
            return
        end
        safeTaskWait(AUCTION_STARTUP_RETRY_INTERVAL)
    end
    writeDebugLog("Auction startup snapshot was not ready; using passive Snapshot event/polling")
    updateAPI(nil)
end)

safeTaskSpawn(function()
    while not fruitSnapshotConnected do
        safeTaskWait(5)
        connectFruitStockSnapshot(function()
            updateAPI(getFruitMultipliers())
        end)
    end
end)

safeTaskSpawn(function()
    while not auctionSnapshotConnected do
        safeTaskWait(2)
        connectAuctionSnapshot(function()
            updateAPI(nil)
        end)
        requestAuctionSnapshot(true)
    end
end)

safeTaskSpawn(function()
    while true do
        local gotSnapshot = requestAuctionSnapshot(not latestAuctionSnapshot)
        if gotSnapshot then
            updateAPI(nil)
        end
        safeTaskWait(latestAuctionSnapshot and AUCTION_REQUEST_INTERVAL or 1)
    end
end)

safeTaskSpawn(function()
    while not latestFruitEntries do
        safeTaskWait(5)
        requestFruitSnapshot(true)
    end
end)

local StockValues = ReplicatedStorage:WaitForChild("StockValues", 10)
if StockValues then
    print("[Grow a Garden 2 Stocker] Monitoring StockValues folder for updates...")
    for _, shopFolder in ipairs(StockValues:GetChildren()) do
        local nextRestock = shopFolder:FindFirstChild("UnixNextRestock")
        if nextRestock then
            nextRestock.Changed:Connect(function()
                safeTaskWait(1.5)
                updateAPI(nil)
            end)
        end
    end
else
    if DEBUG then
        warn("[Grow a Garden 2 Stocker] StockValues folder not found in ReplicatedStorage.")
    end
end

-- ================== LOOPS ==================
-- Fast poll: detect phase / weather / fruit-multiplier changes. Fruits are scraped
-- once here and passed DIRECTLY to updateAPI (no stale cache) so the website always
-- reflects the latest in-game values the moment they change.
local lastPhase = nil
local lastWeathersHash = ""
local lastWeatherCatalogHash = ""
local lastFruitHash = ""
local lastAuctionHash = ""

safeTaskSpawn(function()
    while true do
        safeTaskWait(POLL_INTERVAL)
        local phase, _, weathers = getActiveWeatherAndPhase()
        local weathersHash = getWeathersHash(weathers)
        local weatherCatalogHash = getWeatherCatalogHash(getWeatherCatalog())

        local freshFruits = getFruitMultipliers()
        local fh = fruitHash(freshFruits)
        local fruitChanged = (fh ~= lastFruitHash)
        local auctionHash = getAuctionHash(getAuctionData())
        local auctionChanged = (auctionHash ~= lastAuctionHash)

        if phase ~= lastPhase or weathersHash ~= lastWeathersHash or weatherCatalogHash ~= lastWeatherCatalogHash or fruitChanged or auctionChanged then
            lastPhase = phase
            lastWeathersHash = weathersHash
            lastWeatherCatalogHash = weatherCatalogHash
            lastFruitHash = fh
            lastAuctionHash = auctionHash
            -- Pass the freshly scraped fruit list so updateAPI doesn't re-scrape,
            -- and the data sent to the API is guaranteed current.
            updateAPI(freshFruits)
        end
    end
end)

-- Fallback periodic update: scrape everything fresh inside updateAPI (fruitData=nil
-- means "scrape fresh"), guaranteeing the site gets current data even if the fast
-- poll detected no change (e.g. UI re-opened, values rotated server-side).
local function bypassLoadingScreen()
    local PlayerGui = game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui", 10)
    if not PlayerGui then return end
    
    pcall(function()
        -- 1. Find and destroy LoadingScreenMenu from workspace
        for _, child in ipairs(workspace:GetChildren()) do
            if child.Name == "LoadingScreenMenu" then
                child:Destroy()
                writeDebugLog("Destroyed LoadingScreenMenu in workspace")
            end
        end

        -- 2. Unlock all ScreenGuis by disconnecting "Enabled" change connections
        if getconnections then
            pcall(function()
                for _, conn in ipairs(getconnections(PlayerGui.ChildAdded)) do
                    pcall(function() conn:Disconnect() end)
                end
            end)
            
            for _, child in ipairs(PlayerGui:GetChildren()) do
                if child:IsA("ScreenGui") then
                    pcall(function()
                        for _, conn in ipairs(getconnections(child:GetPropertyChangedSignal("Enabled"))) do
                            pcall(function() conn:Disconnect() end)
                        end
                    end)
                end
            end
        end
        
        -- 3. Reset camera and spoof loading state attributes
        local localPlayer = game:GetService("Players").LocalPlayer
        if localPlayer then
            pcall(function()
                localPlayer:SetAttribute("LoadingScreenActive", false)
                localPlayer:SetAttribute("LoadingScreenDone", true)
            end)
        end
        
        if workspace.CurrentCamera and workspace.CurrentCamera.CameraType == Enum.CameraType.Scriptable then
            workspace.CurrentCamera.CameraType = Enum.CameraType.Custom
            writeDebugLog("Reset camera locked by loading screen")
        end
    end)
end

-- Fallback periodic update: scrape everything fresh inside updateAPI (fruitData=nil
-- means "scrape fresh"), guaranteeing the site gets current data even if the fast
-- poll detected no change (e.g. UI re-opened, values rotated server-side).
safeTaskSpawn(function()
    while true do
        pcall(bypassLoadingScreen)
        updateAPI(nil)
        safeTaskWait(UPDATE_INTERVAL)
    end
end)

-- Fruit multipliers no longer need GUI/card scraping, asset-map scans, or forced
-- FruitStockPrice visibility; snapshots drive updates directly.

-- Apply client optimizations LAST, so all monitoring hooks are already connected.
bypassLoadingScreen()
optimizeClient()

print("[Grow a Garden 2 Stocker] Scraper loaded (" .. (MOBILE_SAFE_MODE and "Mobile Safe Mode" or "Extreme Optimization") .. ")!")
