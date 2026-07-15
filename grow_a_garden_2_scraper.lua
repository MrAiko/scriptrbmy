-- Save the executor require locally and restore getgenv().require for game client scripts
local require = require
pcall(function()
    if getgenv and getgenv().require then
        getgenv().require = nil
    end
end)

-- Grow a Garden 2 Stock Scraper Script (Extreme-Optimized)
-- Run this script in a Roblox Executor (e.g. Wave, Synapse, Electron, Solara, etc.)

local function bootWait(seconds)
    if type(task) == "table" and type(task.wait) == "function" then
        return task.wait(seconds)
    end
    if type(wait) == "function" then
        return wait(seconds)
    end
end

local function safeGetService(serviceName)
    local ok, service = pcall(function()
        return game:GetService(serviceName)
    end)
    return ok and service or nil
end

local function waitForGameLoaded(timeout)
    local startedAt = os.clock()
    local okLoaded, loaded = pcall(function()
        return game:IsLoaded()
    end)
    while okLoaded and not loaded and (os.clock() - startedAt) < (timeout or 90) do
        bootWait(0.25)
        okLoaded, loaded = pcall(function()
            return game:IsLoaded()
        end)
    end
    return not okLoaded or loaded
end

waitForGameLoaded(90)

local HttpService = safeGetService("HttpService")
local Players = safeGetService("Players")
local ReplicatedStorage = safeGetService("ReplicatedStorage")
local ReplicatedFirst = safeGetService("ReplicatedFirst")
local UserInputService = safeGetService("UserInputService")
local TeleportService = safeGetService("TeleportService")
local GuiService = safeGetService("GuiService")

local function waitForLocalPlayer(timeout)
    local startedAt = os.clock()
    local player = Players and Players.LocalPlayer or nil
    while not player and (os.clock() - startedAt) < (timeout or 60) do
        bootWait(0.2)
        player = Players and Players.LocalPlayer or nil
    end
    return player
end

local function waitForChildSoft(parent, childName, timeout)
    if not parent then return nil end
    local child = parent:FindFirstChild(childName)
    if child then return child end
    local startedAt = os.clock()
    while parent and parent.Parent and not child and (os.clock() - startedAt) < (timeout or 30) do
        bootWait(0.15)
        child = parent:FindFirstChild(childName)
    end
    return child
end

local LocalPlayer = waitForLocalPlayer(60)

-- Every persistent listener belongs to this script run.  A Roblox executor
-- keeps old RBXScriptConnection objects alive when the user executes a newer
-- version of a script in the same session; those orphan listeners were able to
-- multiply UI/world work after a few restarts.  Dispose the previous run first
-- and track this run's listeners so the next launch stays at one listener per
-- signal.
local activeRunConnections = {}

local function disconnectPreviousRunConnections()
    pcall(function()
        local env = getgenv and getgenv() or nil
        if type(env) ~= "table" then return end
        local previous = env.__GAG2_STOCKER_CONNECTIONS
        if type(previous) == "table" then
            for index = #previous, 1, -1 do
                local connection = previous[index]
                pcall(function()
                    if connection and connection.Disconnect then
                        connection:Disconnect()
                    end
                end)
                previous[index] = nil
            end
        end
        local previousSocket = env.__GAG2_STOCKER_WEBSOCKET
        if previousSocket then
            pcall(function() previousSocket:Close() end)
            pcall(function() previousSocket:close() end)
        end
        env.__GAG2_STOCKER_WEBSOCKET = nil
        env.__GAG2_STOCKER_CONNECTIONS = activeRunConnections
    end)
end

disconnectPreviousRunConnections()

-- ================= CONFIGURATION =================
local API_URL = "https://growagarden2stock.site/api/update-stock"
local API_PASSWORD = "mySuperSecretToken123"
local UPDATE_INTERVAL = 180      -- Rare safety refresh; normal updates are event-driven.
local POLL_INTERVAL = 60         -- Lightweight fallback only. Never rebuild every UI/data tree frequently.
local FRUIT_REQUEST_INTERVAL = 60 -- Fallback remote refresh interval if Snapshot event is missed
local DEBUG = false             -- Set to true only to diagnose scraper issues
local ALLOW_GUI_FALLBACK = false -- v185 exposes every tracked value through replicas/attributes/network snapshots.
local MOBILE_SAFE_MODE = UserInputService and UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
-- MuMu reports itself as touch-only, so headless rendering must be enabled
-- explicitly.  The visual sweep below is one-shot and property-only: deleting
-- replicated map roots makes Roblox stream/rebuild them again and costs more CPU.
local HEADLESS_SCRAPER_MODE = true
-- Very low caps such as 3–5 FPS can make some Android executors busy-spin.
-- With 3D rendering already off, 15 FPS is the lower, stable MuMu setting.
local HEADLESS_FPS_CAP = 15 -- Very low caps can busy-spin; 15 is stable on MuMu.
-- Never recursively destroy Workspace/Terrain.  It causes a streaming loop on
-- Roblox clients.  The aggressive mode below still makes the world invisible,
-- disables effects/audio/lights and turns 3D rendering off without that loop.
local NEUTRALIZE_WORLD_VISUALS = true
local MOVE_HEADLESS_CAMERA = false
local CLEAN_PLAYER_GUI = true
local SUSPEND_GAME_LOCAL_SCRIPTS = true -- Scraper uses replicas/remotes directly.
local CLIENT_SCRIPT_WARMUP_SECONDS = 6  -- Let networking initialize before suspending game scripts.
local SHOW_OPTIMIZER_OVERLAY = false    -- A permanent full-screen GUI still costs UI/render time.
local BYPASS_LOADING_SCREEN = true
local AUTO_RECONNECT = true       -- Rejoin the game when Roblox shows disconnect/error prompt.
local LOAD_WATCHDOG_TIMEOUT = 180 -- Rejoin if core game objects never appear after this many seconds.
-- =================================================

local PlayerGui = waitForChildSoft(LocalPlayer, "PlayerGui", 60)
local SharedModules = waitForChildSoft(ReplicatedStorage, "SharedModules", 45)
local clientOptimized = false
local reconnecting = false
local SCRAPER_RUN_ID = tostring(os.clock()) .. ":" .. tostring(math.random(1, 1000000000))

pcall(function()
    local env = getgenv and getgenv() or nil
    if type(env) == "table" then
        env.__GAG2_STOCKER_RUN_ID = SCRAPER_RUN_ID
        env.__GAG2_STOCKER_CONNECTIONS = activeRunConnections
    end
end)

function refreshRuntimeRefs()
    if Players then
        LocalPlayer = Players.LocalPlayer or LocalPlayer
    end
    if LocalPlayer then
        PlayerGui = LocalPlayer:FindFirstChild("PlayerGui") or PlayerGui
    end
    if ReplicatedStorage then
        SharedModules = ReplicatedStorage:FindFirstChild("SharedModules") or SharedModules
    end
    return LocalPlayer, PlayerGui, SharedModules
end

function isCurrentScraperRun()
    local ok, env = pcall(function()
        return getgenv and getgenv() or nil
    end)
    if ok and type(env) == "table" and env.__GAG2_STOCKER_RUN_ID then
        return env.__GAG2_STOCKER_RUN_ID == SCRAPER_RUN_ID
    end
    return true
end

function trackRunConnection(connection)
    if connection then
        table.insert(activeRunConnections, connection)
    end
    return connection
end

-- The guard is intentionally inside the callback too: if an executor cannot
-- disconnect a proprietary signal, an old run becomes an immediate no-op
-- instead of continuing to scan Roblox instances.
function connectRunSignal(signal, callback)
    if not signal or type(callback) ~= "function" then return nil end
    local connection = nil
    local ok = pcall(function()
        connection = signal:Connect(function(...)
            if not isCurrentScraperRun() then return end
            return callback(...)
        end)
    end)
    if ok and connection then
        return trackRunConnection(connection)
    end
    return nil
end

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

function getQueueOnTeleport()
    if type(queue_on_teleport) == "function" then return queue_on_teleport end
    if type(queueonteleport) == "function" then return queueonteleport end
    if type(syn) == "table" and type(syn.queue_on_teleport) == "function" then
        return syn.queue_on_teleport
    end
    local ok, env = pcall(function()
        return getgenv and getgenv() or nil
    end)
    if ok and type(env) == "table" then
        if type(env.queue_on_teleport) == "function" then return env.queue_on_teleport end
        if type(env.queueonteleport) == "function" then return env.queueonteleport end
        if type(env.syn) == "table" and type(env.syn.queue_on_teleport) == "function" then
            return env.syn.queue_on_teleport
        end
    end
    return nil
end

function getTeleportReloadCode()
    local loader = [[
local function w(s)
    if type(task) == "table" and type(task.wait) == "function" then return task.wait(s) end
    if type(wait) == "function" then return wait(s) end
end
pcall(function()
    local t0 = os.clock()
    while not game:IsLoaded() and os.clock() - t0 < 90 do
        w(0.25)
    end
end)
w(1.5)
local env = getgenv and getgenv() or {}
local src = env.__GAG2_STOCKER_RELAUNCH_CODE or env.__GAG2_STOCKER_SOURCE or env.__GAG2_STOCKER_AUTORUN
if type(src) ~= "string" and type(isfile) == "function" and type(readfile) == "function" then
    for _, path in ipairs({
        "grow_a_garden_2_scraper.lua",
        "Grow_a_Garden_2_Scraper.lua",
        "gag2_stocker.lua",
        "GAG2Stocker.lua",
        "autoexec/grow_a_garden_2_scraper.lua",
        "scripts/grow_a_garden_2_scraper.lua"
    }) do
        local okFile, exists = pcall(function() return isfile(path) end)
        if okFile and exists then
            local okRead, content = pcall(function() return readfile(path) end)
            if okRead and type(content) == "string" and #content > 100 then
                src = content
                break
            end
        end
    end
end
if type(src) == "string" and #src > 100 then
    local okLoad, fn = pcall(function() return loadstring(src) end)
    if okLoad and type(fn) == "function" then
        pcall(fn)
    end
end
]]
    local ok, env = pcall(function()
        return getgenv and getgenv() or nil
    end)
    if ok and type(env) == "table" then
        local src = env.__GAG2_STOCKER_RELAUNCH_CODE or env.__GAG2_STOCKER_SOURCE or env.__GAG2_STOCKER_AUTORUN
        if type(src) == "string" and #src > 100 then
            return src
        end
    end
    return loader
end

function queueScraperAfterTeleport()
    local queueFunc = getQueueOnTeleport()
    if not queueFunc then return false end
    local code = getTeleportReloadCode()
    local ok = pcall(function()
        queueFunc(code)
    end)
    return ok
end

function requestReconnect(reason)
    if not isCurrentScraperRun() or not AUTO_RECONNECT or reconnecting then return false end
    reconnecting = true
    refreshRuntimeRefs()
    pcall(function()
        local env = getgenv and getgenv() or nil
        if type(env) == "table" then
            env.__GAG2_STOCKER_LAST_RECONNECT_REASON = tostring(reason or "unknown")
        end
    end)
    queueScraperAfterTeleport()
    warn("[Grow a Garden 2 Stocker] Reconnecting: " .. tostring(reason or "Roblox disconnect"))

    safeTaskSpawn(function()
        if not isCurrentScraperRun() then
            reconnecting = false
            return
        end
        pcall(function()
            if type(setfpscap) == "function" then
                setfpscap(HEADLESS_SCRAPER_MODE and HEADLESS_FPS_CAP or 30)
            end
        end)

        local player = LocalPlayer or waitForLocalPlayer(10)
        local placeId = game.PlaceId
        local jobId = game.JobId
        for attempt = 1, 5 do
            if not isCurrentScraperRun() then
                reconnecting = false
                return
            end
            local okTeleport = false
            if TeleportService and player and placeId and placeId ~= 0 then
                if attempt == 1 and type(jobId) == "string" and jobId ~= "" then
                    okTeleport = pcall(function()
                        TeleportService:TeleportToPlaceInstance(placeId, jobId, player)
                    end)
                end
                if not okTeleport then
                    okTeleport = pcall(function()
                        TeleportService:Teleport(placeId, player)
                    end)
                end
            end
            if okTeleport then
                return
            end
            safeTaskWait(math.min(2 + attempt * 2, 12))
            refreshRuntimeRefs()
            player = LocalPlayer or player
        end
        reconnecting = false
    end)
    return true
end

function isRobloxDisconnectPrompt(instance)
    if not instance then return false end
    local name = string.lower(tostring(instance.Name or ""))
    if name == "errorprompt" or name == "disconnectprompt" then
        return true
    end
    if string.find(name, "error") and (string.find(name, "prompt") or string.find(name, "modal")) then
        return true
    end
    local ok, descendants = pcall(function()
        return instance:GetDescendants()
    end)
    if ok then
        for _, desc in ipairs(descendants) do
            local descName = string.lower(tostring(desc.Name or ""))
            if descName == "errorprompt" or descName == "disconnectprompt" then
                return true
            end
        end
    end
    return false
end

function installAutoReconnectWatchdog()
    if not AUTO_RECONNECT then return end

    pcall(function()
        if GuiService and GuiService.ErrorMessageChanged then
            connectRunSignal(GuiService.ErrorMessageChanged, function()
                safeTaskDelay(0.25, function()
                    requestReconnect("GuiService error message")
                end)
            end)
        end
    end)

    pcall(function()
        local CoreGui = safeGetService("CoreGui")
        if not CoreGui then return end
        local promptHooked = false

        local function hookPromptGui(robloxPromptGui)
            if promptHooked or not robloxPromptGui then return end
            local promptOverlay = robloxPromptGui:FindFirstChild("promptOverlay") or waitForChildSoft(robloxPromptGui, "promptOverlay", 10)
            if not promptOverlay then return end
            promptHooked = true

            local function inspectPrompt(child)
                safeTaskDelay(0.2, function()
                    if isRobloxDisconnectPrompt(child) then
                        requestReconnect("Roblox error prompt")
                    end
                end)
            end

            for _, child in ipairs(promptOverlay:GetChildren()) do
                inspectPrompt(child)
            end
            connectRunSignal(promptOverlay.ChildAdded, inspectPrompt)
            connectRunSignal(promptOverlay.DescendantAdded, function(desc)
                if isRobloxDisconnectPrompt(desc) then
                    requestReconnect("Roblox disconnect descendant")
                end
            end)
        end

        hookPromptGui(CoreGui:FindFirstChild("RobloxPromptGui"))
        connectRunSignal(CoreGui.ChildAdded, function(child)
            if child.Name == "RobloxPromptGui" then
                hookPromptGui(child)
            end
        end)
    end)

    pcall(function()
        if LocalPlayer and LocalPlayer.OnTeleport then
            connectRunSignal(LocalPlayer.OnTeleport, function(state)
                queueScraperAfterTeleport()
                if string.find(tostring(state), "Failed", 1, true) then
                    safeTaskDelay(2, function()
                        requestReconnect("teleport failed")
                    end)
                end
            end)
        end
    end)

    pcall(function()
        if TeleportService and TeleportService.TeleportInitFailed then
            connectRunSignal(TeleportService.TeleportInitFailed, function(player)
                if not LocalPlayer or player == LocalPlayer then
                    safeTaskDelay(2, function()
                        requestReconnect("teleport init failed")
                    end)
                end
            end)
        end
    end)

    safeTaskSpawn(function()
        local startedAt = os.clock()
        while true do
            if not isCurrentScraperRun() then return end
            safeTaskWait(30)
            refreshRuntimeRefs()
            local okLoaded, loaded = pcall(function()
                return game:IsLoaded()
            end)
            local ready = (not okLoaded or loaded) and LocalPlayer and PlayerGui and ReplicatedStorage and SharedModules
            if ready then
                startedAt = os.clock()
            elseif (os.clock() - startedAt) > LOAD_WATCHDOG_TIMEOUT then
                requestReconnect("load watchdog timeout")
                return
            end
        end
    end)
end

installAutoReconnectWatchdog()

-- ================== CLIENT OPTIMIZATION ==================
-- Aggressively reduce client CPU/GPU/RAM usage so the scraper runs with near-zero
-- overhead. All steps are wrapped in pcall so a failure never breaks scraping.
function optimizeClient()
    refreshRuntimeRefs()
    local RunService = game:GetService("RunService")
    local renderingDisabled = false

    -- No per-instance destroy queue is used: it can trigger Roblox streaming
    -- rebuilds.  Rendering/effects are neutralized once below instead.
    -- MuMu is touch-only, so the former mobile-safe branch never capped its
    -- frame rate.  A stock scraper is event/network driven; 15 FPS keeps the
    -- executor scheduler stable while 3D rendering stays disabled.
    local targetFps = HEADLESS_SCRAPER_MODE and HEADLESS_FPS_CAP or 3
    local fpsSetters = {}
    local function addFpsSetter(fn)
        if type(fn) ~= "function" then return end
        for _, existing in ipairs(fpsSetters) do
            if existing == fn then return end
        end
        table.insert(fpsSetters, fn)
    end
    addFpsSetter(setfpscap)
    addFpsSetter(set_fps_cap)
    pcall(function()
        local env = getgenv and getgenv() or nil
        if type(env) == "table" then
            addFpsSetter(env.setfpscap)
            addFpsSetter(env.set_fps_cap)
        end
    end)
    for _, setCap in ipairs(fpsSetters) do
        local ok = pcall(function() setCap(targetFps) end)
        if ok then break end
    end

    -- 1. Stop 3D world rendering entirely.
    -- Headless mode opts into this on MuMu too.  The data sources below are
    -- replicated modules/events, not rendered pixels.
    if HEADLESS_SCRAPER_MODE or not MOBILE_SAFE_MODE then
        renderingDisabled = pcall(function()
            RunService:Set3dRenderingEnabled(false)
        end)
    end

    -- 2. Minimize lighting/shadow cost.
    pcall(function()
        local lighting = game:GetService("Lighting")
        lighting.GlobalShadows = false
        lighting.OutdoorAmbient = Color3.fromRGB(128, 128, 128)
        lighting.Brightness = 0
        lighting.FogEnd = 1
    end)

    -- 3. Force lowest graphics quality.
    pcall(function()
        settings().Rendering.QualityLevel = Enum.QualityLevel.Level01
        settings().Rendering.MeshPartDetailLevel = Enum.MeshPartDetailLevel.Level01
    end)

    -- 4. 3D rendering is already disabled above.  Moving the camera can make
    -- MuMu continuously stream the map, so it is opt-in rather than default.
    if MOVE_HEADLESS_CAMERA then
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

    -- 6. Mute sounds without a global game.DescendantAdded listener.  That
    -- listener wakes up for every replicated object and is very costly in a
    -- busy server; the one-shot visual sweep below handles existing sounds too.
    pcall(function()
        local soundService = game:GetService("SoundService")
        soundService.AmbientReverb = Enum.ReverbType.NoReverb
        pcall(function() soundService.Volume = 0 end)
        for _, sound in ipairs(soundService:GetDescendants()) do
            if sound:IsA("Sound") then
                sound:Stop()
                sound.Volume = 0
            end
        end
    end)

    local function cleanPlayerGui()
        refreshRuntimeRefs()
        local pGui = LocalPlayer and LocalPlayer:FindFirstChild("PlayerGui")
        if not pGui then return end
        for _, child in ipairs(pGui:GetChildren()) do
            -- Protected UIs must remain in the tree for fallback data reads, but
            -- they do not need to be rendered.  ScreenGui.Enabled=false preserves
            -- every label/value while stopping layout, tween and draw work.
            if child:IsA("ScreenGui") or child:IsA("BillboardGui")
                or child:IsA("SurfaceGui") or child:IsA("Sound") then
                pcall(function()
                    if child:IsA("Sound") then
                        child:Stop()
                        child.Volume = 0
                    else
                        child.Enabled = false
                    end
                end)
            end
        end
        -- Nested media/scripts are handled once after the warm-up below. Avoid
        -- walking a large PlayerGui tree twice during startup.
    end

    local function suspendLocalScript(instance)
        if not instance then return false end
        local isClientScript = instance:IsA("LocalScript")
        if not isClientScript and instance:IsA("Script") then
            pcall(function()
                isClientScript = instance.RunContext == Enum.RunContext.Client
            end)
        end
        if not isClientScript then return false end
        local changed = false
        pcall(function()
            if instance.Enabled ~= false then
                instance.Enabled = false
                changed = true
            end
        end)
        -- Compatibility with executors/clients that still expose Disabled.
        pcall(function()
            if instance.Disabled ~= true then
                instance.Disabled = true
                changed = true
            end
        end)
        return changed
    end

    local function suspendClientRoot(root)
        if not root then return 0 end
        local suspended = suspendLocalScript(root) and 1 or 0
        local ok, descendants = pcall(function() return root:GetDescendants() end)
        if not ok or type(descendants) ~= "table" then return suspended end
        for index, instance in ipairs(descendants) do
            if not isCurrentScraperRun() then return suspended end
            if suspendLocalScript(instance) then
                suspended = suspended + 1
            elseif instance:IsA("VideoFrame") then
                pcall(function()
                    instance.Visible = false
                    instance:Pause()
                end)
            elseif instance:IsA("Sound") then
                pcall(function()
                    instance:Stop()
                    instance.Volume = 0
                end)
            elseif instance:IsA("Animator") then
                pcall(function()
                    for _, track in ipairs(instance:GetPlayingAnimationTracks()) do
                        track:Stop(0)
                    end
                end)
            end
            if index % 256 == 0 then safeTaskWait(0.01) end
        end
        return suspended
    end

    if CLEAN_PLAYER_GUI then
        pcall(function()
            cleanPlayerGui()
        end)
    end

    -- Do not destroy replicated Workspace roots or Terrain.  Roblox streams those
    -- instances back immediately, which is slower than the one-shot visual strip
    -- below and was the source of the sustained emulator CPU spike.
    -- 7. Aggressive headless visual strip.  This intentionally runs once and
    -- never subscribes to Workspace.ChildAdded/DescendantAdded.  Roblox can
    -- recreate streamed instances after a destructive listener removes them,
    -- which is the source of the sustained 40-60% CPU regression on MuMu.
    -- Set3dRenderingEnabled(false) is the actual rendering kill-switch; these
    -- properties are a local fallback and also stop effect/audio work.
    local function neutralizeVisualInstance(instance)
        if not instance then return end
        pcall(function()
            if instance:IsA("BasePart") then
                instance.CastShadow = false
                instance.LocalTransparencyModifier = 1
            elseif instance:IsA("ParticleEmitter") then
                instance.Enabled = false
                instance.Rate = 0
                instance.TimeScale = 0
            elseif instance:IsA("Beam") or instance:IsA("Trail")
                or instance:IsA("Smoke") or instance:IsA("Fire")
                or instance:IsA("Sparkles") then
                instance.Enabled = false
            elseif instance:IsA("PointLight") or instance:IsA("SpotLight")
                or instance:IsA("SurfaceLight") then
                instance.Enabled = false
            elseif instance:IsA("PostEffect") or instance:IsA("Highlight")
                or instance:IsA("BillboardGui") or instance:IsA("SurfaceGui") then
                instance.Enabled = false
            elseif instance:IsA("SelectionBox") then
                instance.Visible = false
            elseif instance:IsA("Decal") or instance:IsA("Texture") then
                instance.Transparency = 1
            elseif instance:IsA("Sound") then
                instance:Stop()
                instance.Volume = 0
            end
        end)
    end

    local function neutralizeTerrain()
        local terrain = workspace:FindFirstChildOfClass("Terrain")
        if not terrain then return end
        pcall(function() terrain.Decoration = false end)
        pcall(function() terrain.WaterWaveSize = 0 end)
        pcall(function() terrain.WaterWaveSpeed = 0 end)
        pcall(function() terrain.WaterReflectance = 0 end)
        pcall(function() terrain.WaterTransparency = 1 end)
    end

    if HEADLESS_SCRAPER_MODE and NEUTRALIZE_WORLD_VISUALS then
        safeTaskSpawn(function()
            -- Let the core UI/data replicas attach first; visual work is not on
            -- the scraper's critical path.
            safeTaskWait(0.5)
            if not isCurrentScraperRun() then return end
            neutralizeTerrain()
            -- Set3dRenderingEnabled(false) is already the complete kill-switch.
            -- A full Workspace property sweep is redundant and can itself pin a
            -- large emulator for minutes in a streamed map.
            if renderingDisabled then return end
            local ok, descendants = pcall(function()
                return workspace:GetDescendants()
            end)
            if not ok or type(descendants) ~= "table" then return end
            for index, instance in ipairs(descendants) do
                if not isCurrentScraperRun() then return end
                neutralizeVisualInstance(instance)
                -- Yield in small batches so startup does not freeze MuMu or
                -- starve websocket/event handling.
                if index % 96 == 0 then
                    safeTaskWait(0.02)
                end
            end
        end)
    end

    if HEADLESS_SCRAPER_MODE and SUSPEND_GAME_LOCAL_SCRIPTS then
        safeTaskSpawn(function()
            safeTaskWait(CLIENT_SCRIPT_WARMUP_SECONDS)
            if not isCurrentScraperRun() then return end
            refreshRuntimeRefs()
            local playerScripts = LocalPlayer and LocalPlayer:FindFirstChild("PlayerScripts")
            local backpack = LocalPlayer and LocalPlayer:FindFirstChildOfClass("Backpack")
            local suspended = 0
            suspended = suspended + suspendClientRoot(ReplicatedFirst)
            suspended = suspended + suspendClientRoot(playerScripts)
            suspended = suspended + suspendClientRoot(PlayerGui)
            suspended = suspended + suspendClientRoot(backpack)
            suspended = suspended + suspendClientRoot(LocalPlayer and LocalPlayer.Character)
            if DEBUG then
                print("[Grow a Garden 2 Stocker] Suspended " .. tostring(suspended) .. " game LocalScripts")
            end

            -- New top-level GUIs/controllers are uncommon. Watching only direct
            -- children avoids the very noisy PlayerGui.DescendantAdded signal.
            if PlayerGui then
                connectRunSignal(PlayerGui.ChildAdded, function(child)
                    if child.Name == "OptimizerOverlay" then return end
                    pcall(function()
                        if child:IsA("ScreenGui") or child:IsA("BillboardGui") or child:IsA("SurfaceGui") then
                            child.Enabled = false
                        end
                    end)
                    safeTaskDelay(0.5, function() suspendClientRoot(child) end)
                end)
            end
            if playerScripts then
                connectRunSignal(playerScripts.ChildAdded, function(child)
                    safeTaskDelay(0.25, function() suspendClientRoot(child) end)
                end)
            end
        end)
    end

    -- 8. Optional black overlay. Disabled by default because even a blank
    -- full-screen GUI keeps the 2D renderer active.
    if SHOW_OPTIMIZER_OVERLAY then
        safeTaskSpawn(function()
        pcall(function()
            refreshRuntimeRefs()
            local pGui = PlayerGui or waitForChildSoft(LocalPlayer, "PlayerGui", 15)
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

            sg.Parent = pGui
        end)
        end)
    end

    clientOptimized = true
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

function getPhaseNameFromImageId(imageId)
    if not imageId then return nil end
    local strId = tostring(imageId)
    if string.find(strId, "140465339393451") then return "Blood Moon" end
    if string.find(strId, "84902063004871") then return "Gold Moon" end
    if string.find(strId, "93602895495056") then return "Rainbow Moon" end
    if string.find(strId, "107925838920918") then return "Mega Moon" end
    return nil
end

local isDecorativeWeatherCatalogName

local weatherDataCache = nil
local weatherDataByKeyCache = nil
local weatherDataCacheAt = -999
-- WeatherData and its attribute schema are static for a server session.  Live
-- playing/end-time values are read separately, so reparsing the catalogue every
-- few seconds only burns CPU.
local WEATHER_DATA_REFRESH_INTERVAL = 120

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
    "Rainbow Moon", "Solar Eclipse", "Mega Moon", "MegaMoon", "Megamoon", "Moon", "Night", "Sunset", "Day",
    "Mega", "Blood", "Gold", "Chained", "Pizza", "Solar"
}

function findTimeCycleController()
    local playerScripts = LocalPlayer and LocalPlayer:FindFirstChild("PlayerScripts")
    if not playerScripts then return nil end
    local controllers = findChildByNormalizedName(playerScripts, { "Controllers" })
    return findChildByNormalizedName(controllers or playerScripts, { "TimeCycleController", "TimeCycle" })
end

function getPhasesFolder()
    -- Only read child names. Do not require phase modules from executor context.
    local controller = findTimeCycleController()
    return controller and findChildByNormalizedName(controller, { "Phases" }) or nil
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
local wsNextConnectAttemptAt = 0
-- A short reconnect backoff keeps live shop/weather updates on the socket after
-- a transient emulator/network hiccup.  Failed sends still have HTTP fallback.
local WEBSOCKET_RECONNECT_COOLDOWN = 3

function getWebSocketClient()
    if wsConnection then return wsConnection end
    if isWsConnecting then return nil end
    if os.clock() < wsNextConnectAttemptAt then return nil end
    
    local wsConnectFunc = WebSocket and WebSocket.connect or (syn and syn.websocket and syn.websocket.connect)
    if not wsConnectFunc then
        return nil
    end
    
    isWsConnecting = true
    safeTaskSpawn(function()
        if not isCurrentScraperRun() then
            isWsConnecting = false
            return
        end
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
            if not isCurrentScraperRun() then
                pcall(function() ws:Close() end)
                pcall(function() ws:close() end)
                return
            end
            if DEBUG then
                print("[Grow a Garden 2 Stocker] WebSocket connected successfully!")
            end
            wsConnection = ws
            wsNextConnectAttemptAt = 0
            pcall(function()
                local env = getgenv and getgenv() or nil
                if type(env) == "table" then
                    env.__GAG2_STOCKER_WEBSOCKET = ws
                end
            end)
            
            local onMessage = ws.OnMessage or ws.on_message
            local onClose = ws.OnClose or ws.on_close
            
            if onClose then
                connectRunSignal(onClose, function()
                    if DEBUG then
                        print("[Grow a Garden 2 Stocker] WebSocket closed.")
                    end
                    wsConnection = nil
                    wsNextConnectAttemptAt = os.clock() + WEBSOCKET_RECONNECT_COOLDOWN
                    pcall(function()
                        local env = getgenv and getgenv() or nil
                        if type(env) == "table" and env.__GAG2_STOCKER_WEBSOCKET == ws then
                            env.__GAG2_STOCKER_WEBSOCKET = nil
                        end
                    end)
                end)
            end
            
            if onMessage then
                connectRunSignal(onMessage, function(msg)
                    if DEBUG then
                        print("[Grow a Garden 2 Stocker] WebSocket msg: " .. tostring(msg))
                    end
                end)
            end

            -- A socket can finish its handshake after the startup snapshot was
            -- collected. Re-send the already available auction immediately so
            -- a successful Lua launch never waits for the next shop update.
            safeTaskDelay(0.15, function()
                if not isCurrentScraperRun() or wsConnection ~= ws then return end
                if type(sendAuctionUpdateInstant) == "function" then
                    local ok, sent = pcall(sendAuctionUpdateInstant)
                    if not ok or not sent then
                        if type(updateAPI) == "function" then pcall(updateAPI, nil) end
                    end
                elseif type(updateAPI) == "function" then
                    pcall(updateAPI, nil)
                end
            end)
        else
            wsNextConnectAttemptAt = os.clock() + WEBSOCKET_RECONNECT_COOLDOWN
            warn("[Grow a Garden 2 Stocker] WebSocket connection failed: " .. tostring(ws))
        end
    end)
    
    return wsConnection
end

-- Begin the handshake before the first stock event.  getWebSocketClient is
-- non-blocking, so this does not delay game loading or event subscriptions.
safeTaskDefer(function()
    getWebSocketClient()
end)


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
    if not container then return items end
    for _, desc in ipairs(container:GetDescendants()) do
        if desc:IsA("GuiObject") and not isGenericItemName(desc.Name) then
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
    end
    return items
end

function scrapeShopSafe(container)
    local success, items = pcall(function() return scrapeShop(container) end)
    return success and items or {}
end

-- ================== DIRECT SHOP DATA SOURCE ==================
-- Shop UI is only a presentation layer.  The stock values and the shared item
-- catalogues are authoritative, so keep a compact index of those instead of
-- repeatedly walking every UI card on each poll.
local DIRECT_SHOP_CACHE = {}
local DIRECT_SHOP_CACHE_AT = {}
local DIRECT_SHOP_CACHE_SECONDS = 60 -- Stock/price signals invalidate this immediately.
local REQUIRED_SHARED_MODULE_CACHE = {}
local STOCK_ITEMS_INDEX_CACHE = {}

local SHOP_RARITY_ORDER = {
    Common = 1,
    Uncommon = 2,
    Rare = 3,
    Epic = 4,
    Legendary = 5,
    Mythic = 6,
    Super = 7,
    Secret = 8,
    Exotic = 9,
    Divine = 10,
    Prismatic = 11,
    Transcendent = 12,
    Transendent = 12
}

local SHOP_PRICE_SUFFIXES = {
    { 1000000000000000, "Q" },
    { 1000000000000, "T" },
    { 1000000000, "B" },
    { 1000000, "M" },
    { 1000, "K" }
}

local SHOP_PRICE_OVERRIDE_CONFIG = {
    SeedShop = {
        flagName = "Game.SeedShop.PriceOverrides",
        allowsBasePriceSentinel = false
    },
    GearShop = {
        flagName = "Game.GearShop.PriceOverrides",
        allowsBasePriceSentinel = true
    },
    CrateShop = {
        flagName = "Game.CrateShop.PriceOverrides",
        allowsBasePriceSentinel = true
    }
}

local SHOP_LIMITED_CONFIG = {
    SeedShop = {
        moduleName = "SeedShopLimited",
        flagName = "Game.SeedShop.LimitedEndTimes",
        overrideFolderName = "SeedShopLimitedOverrides"
    },
    CrateShop = {
        moduleName = "CrateShopLimited",
        flagName = "Game.CrateShop.LimitedEndTimes",
        overrideFolderName = "CrateShopLimitedOverrides"
    }
}
local LIMITED_EXPIRY_SCHEDULE = {}

-- The downloaded catalogue says 130M, while the currently replicated flag can
-- report the stale 90M pair. Keep this exception deliberately narrow so valid
-- live balance changes (for example Super Sprinkler 300K -> 3M) still apply.
local KNOWN_BAD_SHOP_PRICE_OVERRIDES = {
    SeedShop = {
        ["Dragon's Breath"] = {
            base = 130000000,
            override = 90000000
        }
    }
}

function getCanonicalShopKey(shopKey)
    if shopKey == "SeedShop" or shopKey == "SeedShop_Normal" then
        return "SeedShop"
    end
    return shopKey
end

function getDirectShopCacheKey(shopKey)
    return getCanonicalShopKey(shopKey) == "SeedShop" and "SeedShop_Normal" or shopKey
end

function formatShopPrice(value)
    value = tonumber(value)
    if not value or value < 0 then return "Unknown" end
    for _, item in ipairs(SHOP_PRICE_SUFFIXES) do
        local size, suffix = item[1], item[2]
        if value >= size then
            local short = value / size
            local text = string.format("%.3f", short):gsub("0+$", ""):gsub("%.$", "")
            return text .. suffix .. "\194\162"
        end
    end
    return tostring(math.floor(value)) .. "\194\162"
end

function readShopImageRef(value)
    if value == nil then return nil end
    if typeof(value) == "Instance" then
        if value:IsA("StringValue") or value:IsA("IntValue") or value:IsA("NumberValue") then
            return normalizeAssetRef(value.Value)
        end
        if value:IsA("ImageLabel") or value:IsA("ImageButton") then
            return normalizeAssetRef(value.Image)
        end
        return nil
    end
    return normalizeAssetRef(value)
end

function getStockValuesShopFolder(shopName)
    local stockValues = ReplicatedStorage:FindFirstChild("StockValues")
    return stockValues and stockValues:FindFirstChild(getCanonicalShopKey(shopName)) or nil
end

function getStockItemsFolder(shopName)
    local shopFolder = getStockValuesShopFolder(shopName)
    return shopFolder and shopFolder:FindFirstChild("Items") or nil
end

function invalidateStockItemsIndex(shopName)
    STOCK_ITEMS_INDEX_CACHE[getCanonicalShopKey(shopName)] = nil
end

function getStockItemsIndex(shopName)
    local canonicalShopKey = getCanonicalShopKey(shopName)
    local itemsFolder = getStockItemsFolder(canonicalShopKey)
    local cached = STOCK_ITEMS_INDEX_CACHE[canonicalShopKey]
    if cached and cached.folder == itemsFolder then
        return cached
    end

    local index = {
        folder = itemsFolder,
        exact = {},
        normalized = {},
        entries = {}
    }
    if itemsFolder then
        for _, stockObject in ipairs(itemsFolder:GetChildren()) do
            local rawName = tostring(stockObject.Name or "")
            if rawName ~= "" then
                index.exact[rawName] = stockObject
                local normalizedName = normalizeName(rawName)
                if normalizedName ~= "" and not index.normalized[normalizedName] then
                    index.normalized[normalizedName] = stockObject
                end
                table.insert(index.entries, stockObject)
            end
        end
    end
    STOCK_ITEMS_INDEX_CACHE[canonicalShopKey] = index
    return index
end

function readStockObjectValue(stockObject)
    if not stockObject then return 0 end
    local ok, value = pcall(function()
        return stockObject.Value
    end)
    local numericValue = ok and tonumber(value) or 0
    return math.max(0, math.floor(numericValue or 0))
end

function readStockValue(shopName, itemName, stockIndex)
    local itemKey = tostring(itemName or "")
    if itemKey == "" then return 0 end
    stockIndex = stockIndex or getStockItemsIndex(shopName)
    local stockObject = stockIndex.exact[itemKey]
    if not stockObject then
        stockObject = stockIndex.normalized[normalizeName(itemKey)]
    end
    return readStockObjectValue(stockObject)
end

function getRequiredSharedModule(moduleName)
    if REQUIRED_SHARED_MODULE_CACHE[moduleName] ~= nil then
        return REQUIRED_SHARED_MODULE_CACHE[moduleName]
    end
    local moduleScript = getSharedModule(moduleName)
    if not moduleScript then return nil end
    local module = safeRequireModule(moduleScript)
    if module then
        REQUIRED_SHARED_MODULE_CACHE[moduleName] = module
    end
    return module
end

-- The in-game controller always builds the full catalogue first and only then
-- applies its per-player visibility flag.  Filtering here used to make disabled
-- or not-yet-loaded items disappear from the API entirely (notably Dragon's
-- Breath), so catalogue membership must not depend on an A/B-test response.
function isSeedShopCatalogItem(seed)
    return type(seed) == "table"
        and seed.RestockShop == true
        and type(seed.SeedName) == "string"
        and seed.SeedName ~= ""
        and not isShopLimitedItemExpired("SeedShop", seed.SeedName)
end

function isGearShopCatalogItem(gear)
    return type(gear) == "table"
        and type(gear.ItemName) == "string"
        and gear.ItemName ~= ""
        and not gear.RobuxOnly
        and not gear.HideFromShop
        and (gear.RestockChance ~= nil or gear.EquippableGear == true)
end

function isCrateShopCatalogItem(crate)
    return type(crate) == "table"
        and type(crate.Name) == "string"
        and crate.Name ~= ""
        and crate.RestockChance ~= nil
        and not isShopLimitedItemExpired("CrateShop", crate.Name)
end

function getShopLimitedEndTime(shopName, itemName)
    local config = SHOP_LIMITED_CONFIG[getCanonicalShopKey(shopName)]
    if not config or type(itemName) ~= "string" or itemName == "" then return nil end

    local module = getRequiredSharedModule(config.moduleName)
    if type(module) == "table" and type(module.GetEndTime) == "function" then
        local ok, endTime = pcall(module.GetEndTime, itemName)
        endTime = ok and tonumber(endTime) or nil
        if endTime and endTime > 0 then return endTime end
    end

    -- Keep the native override-folder precedence even if an executor cannot
    -- require the limited-item helper module.
    local overrideFolder = ReplicatedStorage:FindFirstChild(config.overrideFolderName)
    local override = overrideFolder and overrideFolder:FindFirstChild(itemName)
    if override and override:IsA("NumberValue") and tonumber(override.Value) and override.Value > 0 then
        return tonumber(override.Value)
    end

    local endTimes = getFastFlagValue(config.flagName, {}, function(asserts)
        return asserts.Map(asserts.String, asserts.FiniteNonNegative)
    end)
    local endTime = type(endTimes) == "table" and tonumber(endTimes[itemName]) or nil
    return endTime and endTime > 0 and endTime or nil
end

function isShopLimitedItemExpired(shopName, itemName)
    local config = SHOP_LIMITED_CONFIG[getCanonicalShopKey(shopName)]
    if not config then return false end

    local module = getRequiredSharedModule(config.moduleName)
    if type(module) == "table" and type(module.IsExpired) == "function" then
        local ok, expired = pcall(module.IsExpired, itemName)
        if ok then return expired == true end
    end

    local endTime = getShopLimitedEndTime(shopName, itemName)
    if not endTime then return false end
    local ok, serverNow = pcall(function() return workspace:GetServerTimeNow() end)
    return endTime <= (ok and serverNow or os.time())
end

function scheduleShopLimitedExpiry(shopName, itemName, endTime)
    endTime = tonumber(endTime)
    if not endTime or endTime <= 0 then return end
    local key = getCanonicalShopKey(shopName) .. ":" .. tostring(itemName)
    if LIMITED_EXPIRY_SCHEDULE[key] == endTime then return end
    LIMITED_EXPIRY_SCHEDULE[key] = endTime

    local ok, serverNow = pcall(function() return workspace:GetServerTimeNow() end)
    local delaySeconds = endTime - (ok and serverNow or os.time())
    if delaySeconds <= 0 then return end
    safeTaskDelay(delaySeconds + 0.1, function()
        if not isCurrentScraperRun() or LIMITED_EXPIRY_SCHEDULE[key] ~= endTime then return end
        LIMITED_EXPIRY_SCHEDULE[key] = nil
        invalidateDirectShopCache(shopName)
        if type(updateAPI) == "function" then updateAPI(nil) end
    end)
end

function getShopPriceOverrides(shopName)
    local config = SHOP_PRICE_OVERRIDE_CONFIG[getCanonicalShopKey(shopName)]
    if not config then return {} end

    local overrides = getFastFlagValue(config.flagName, {}, function(asserts)
        if config.allowsBasePriceSentinel then
            return asserts.Map(asserts.String, asserts.AnyOf(asserts.FiniteNonNegative, asserts.Equals(-1)))
        end
        return asserts.Map(asserts.String, asserts.FiniteNonNegative)
    end)
    return type(overrides) == "table" and overrides or {}
end

function getShopPriceOverride(name, overrides)
    if type(name) ~= "string" or type(overrides) ~= "table" then return nil end
    local value = overrides[name]
    if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
        return nil
    end
    return value
end

function isKnownBadShopPriceOverride(shopName, name, basePrice, overridePrice)
    local shopExceptions = KNOWN_BAD_SHOP_PRICE_OVERRIDES[getCanonicalShopKey(shopName)]
    local exception = shopExceptions and shopExceptions[name] or nil
    return exception ~= nil
        and basePrice == exception.base
        and overridePrice == exception.override
end

function resolveShopPrice(shopName, name, basePrice, overrides)
    local base = tonumber(basePrice)
    if base and (base < 0 or base ~= base or base == math.huge or base == -math.huge) then base = nil end
    local override = getShopPriceOverride(name, overrides)
    if override and override >= 0 and not isKnownBadShopPriceOverride(shopName, name, base, override) then
        return override
    end
    return base
end

function makeDirectShopItem(shopName, name, stockIndex, basePrice, rarity, image, order, overrides, source)
    if type(name) ~= "string" or name == "" then return nil end
    local priceRaw = resolveShopPrice(shopName, name, basePrice, overrides)
    return {
        name = name,
        stock = readStockValue(shopName, name, stockIndex),
        price = priceRaw ~= nil and formatShopPrice(priceRaw) or "Unknown",
        priceRaw = priceRaw,
        rarity = rarity or "Common",
        image = readShopImageRef(image),
        order = tonumber(order) or 0,
        source = source or "direct"
    }
end

function sortDirectShopItems(items)
    table.sort(items, function(a, b)
        local ao = tonumber(a.order) or 0
        local bo = tonumber(b.order) or 0
        if ao ~= bo then return ao < bo end
        return tostring(a.name or "") < tostring(b.name or "")
    end)
    return items
end

function buildDirectSeedShop()
    local seedData = getRequiredSharedModule("SeedData")
    if type(seedData) ~= "table" then return {} end
    local shopName = "SeedShop"
    local stockIndex = getStockItemsIndex(shopName)
    local overrides = getShopPriceOverrides(shopName)
    local items = {}
    for index, seed in pairs(seedData) do
        if isSeedShopCatalogItem(seed) then
            local item = makeDirectShopItem(
                shopName,
                seed.SeedName,
                stockIndex,
                seed.PurchasePrice,
                seed.Rarity,
                seed.SeedImage,
                seed.SeedShopDisplayOrder or tonumber(index) or 999999,
                overrides
            )
            if item then
                item.limitedEndTime = getShopLimitedEndTime(shopName, seed.SeedName)
                scheduleShopLimitedExpiry(shopName, seed.SeedName, item.limitedEndTime)
                table.insert(items, item)
            end
        end
    end
    return sortDirectShopItems(items)
end

function buildDirectGearShop()
    local gearData = getRequiredSharedModule("GearShopData")
    local rawItems = type(gearData) == "table" and gearData.Data or nil
    if type(rawItems) ~= "table" then return {} end
    local shopName = "GearShop"
    local stockIndex = getStockItemsIndex(shopName)
    local overrides = getShopPriceOverrides(shopName)
    local items = {}
    for index, gear in pairs(rawItems) do
        if isGearShopCatalogItem(gear) then
            local rarityRank = SHOP_RARITY_ORDER[gear.Rarity or ""] or 0
            local sortPriority = tonumber(gear.SortPriority) or 0
            local order = rarityRank * 1000000 + sortPriority * 10000
            if gear.EquippableGear then
                order = order + 5000 + ((tonumber(gear.Cost) or 0) / 1000000)
            else
                order = order - ((tonumber(gear.RestockChance) or 0) * 100) + ((tonumber(index) or 0) / 1000)
            end
            local item = makeDirectShopItem(
                shopName,
                gear.ItemName,
                stockIndex,
                gear.Cost,
                gear.Rarity,
                gear.IMG,
                order,
                overrides
            )
            if item then table.insert(items, item) end
        end
    end
    return sortDirectShopItems(items)
end

function buildDirectCrateShop()
    local crateData = getRequiredSharedModule("CrateData")
    if type(crateData) ~= "table" or type(crateData.GetAllCrates) ~= "function" then return {} end
    local ok, crates = pcall(function()
        return crateData.GetAllCrates()
    end)
    if not ok or type(crates) ~= "table" then return {} end

    local shopName = "CrateShop"
    local stockIndex = getStockItemsIndex(shopName)
    local overrides = getShopPriceOverrides(shopName)
    local items = {}
    for index, crate in pairs(crates) do
        if isCrateShopCatalogItem(crate) then
            local rarityRank = SHOP_RARITY_ORDER[crate.Rarity or ""] or 0
            local order = rarityRank * 1000000 - ((tonumber(crate.RestockChance) or 0) * 1000) + ((tonumber(index) or 0) / 1000)
            local item = makeDirectShopItem(
                shopName,
                crate.Name,
                stockIndex,
                crate.Cost,
                crate.Rarity,
                crate.IMG,
                order,
                overrides
            )
            if item then
                item.limitedEndTime = getShopLimitedEndTime(shopName, crate.Name)
                scheduleShopLimitedExpiry(shopName, crate.Name, item.limitedEndTime)
                table.insert(items, item)
            end
        end
    end
    return sortDirectShopItems(items)
end

function getDirectShopData(shopKey)
    local cacheKey = getDirectShopCacheKey(shopKey)
    local now = os.clock()
    local cachedItems = DIRECT_SHOP_CACHE[cacheKey]
    if type(cachedItems) == "table" and #cachedItems > 0
        and (now - (DIRECT_SHOP_CACHE_AT[cacheKey] or -999)) < DIRECT_SHOP_CACHE_SECONDS then
        return cachedItems
    end

    local canonicalShopKey = getCanonicalShopKey(shopKey)
    local ok, items = pcall(function()
        if canonicalShopKey == "SeedShop" then
            return buildDirectSeedShop()
        elseif canonicalShopKey == "GearShop" then
            return buildDirectGearShop()
        elseif canonicalShopKey == "CrateShop" then
            return buildDirectCrateShop()
        end
        return {}
    end)

    if not ok or type(items) ~= "table" then
        items = {}
    end
    DIRECT_SHOP_CACHE[cacheKey] = items
    DIRECT_SHOP_CACHE_AT[cacheKey] = now
    return items
end

function getShopData(shopKey, fallbackContainer)
    local directItems = getDirectShopData(shopKey)
    if type(directItems) == "table" and #directItems > 0 then
        return directItems
    end
    if ALLOW_GUI_FALLBACK then
        local container = type(fallbackContainer) == "function" and fallbackContainer() or fallbackContainer
        return scrapeShopSafe(container)
    end
    return {}
end

function getShopsHash()
    local parts = {}
    for _, shopKey in ipairs({ "CrateShop", "GearShop", "SeedShop_Normal" }) do
        local items = getDirectShopData(shopKey)
        table.insert(parts, shopKey)
        for _, item in ipairs(items or {}) do
            table.insert(parts, table.concat({
                tostring(item.name or ""),
                tostring(item.stock or 0),
                tostring(item.price or ""),
                tostring(item.priceRaw or ""),
                tostring(item.rarity or ""),
                tostring(item.image or "")
            }, ":"))
        end
    end
    return table.concat(parts, "|")
end

-- ================== WEATHER / PHASE ==================
function getDefaultPhase()
    local ok, lighting = pcall(function() return game:GetService("Lighting") end)
    local clock = ok and lighting and tonumber(lighting.ClockTime) or nil
    if not clock then return "Day" end
    if clock >= 17 and clock < 19.5 then return "Sunset"
    elseif clock >= 6 and clock < 17 then return "Day"
    else return "Moon" end
end

local phaseSignalEntriesCache = nil
local PHASE_SIGNAL_PREFIXES = { "active", "current", "currentphase", "phase", "is", "playing" }
local PHASE_SIGNAL_SUFFIXES = { "active", "playing", "enabled", "running", "started", "visible", "current", "state", "phase" }

function getPhaseSignalEntries()
    if phaseSignalEntriesCache then return phaseSignalEntriesCache end

    local entries, seen = {}, {}
    local function addKey(rawKey, displayName)
        local key = normalizeName(rawKey)
        if key == "" or seen[key] then return end
        seen[key] = true
        table.insert(entries, {
            key = key,
            name = cleanPhaseName(displayName),
            phaseKey = getPhaseKey(displayName) or key
        })
    end

    for _, phaseName in ipairs(getKnownPhaseNames()) do
        local displayName = cleanPhaseName(phaseName)
        addKey(phaseName, displayName)
        addKey(displayName, displayName)
        addKey(getPhaseKey(phaseName), displayName)
    end

    phaseSignalEntriesCache = entries
    return entries
end

function phaseSignalKeyMatches(signalKey, phaseKey)
    if not signalKey or not phaseKey or signalKey == "" or phaseKey == "" then return false end
    if signalKey == phaseKey then return true end
    for _, prefix in ipairs(PHASE_SIGNAL_PREFIXES) do
        if signalKey == prefix .. phaseKey then return true end
    end
    for _, suffix in ipairs(PHASE_SIGNAL_SUFFIXES) do
        if signalKey == phaseKey .. suffix then return true end
    end
    return false
end

function readPhaseNameFromSignalName(name)
    local signalKey = normalizeName(name)
    if signalKey == "" or isTechnicalPhaseName(signalKey) then return nil end
    if getPhaseKey(signalKey) then
        return cleanPhaseName(signalKey)
    end
    for _, prefix in ipairs(PHASE_SIGNAL_PREFIXES) do
        if string.sub(signalKey, 1, #prefix) == prefix then
            local candidate = string.sub(signalKey, #prefix + 1)
            if getPhaseKey(candidate) then return cleanPhaseName(candidate) end
        end
    end
    for _, suffix in ipairs(PHASE_SIGNAL_SUFFIXES) do
        if #signalKey > #suffix and string.sub(signalKey, -#suffix) == suffix then
            local candidate = string.sub(signalKey, 1, #signalKey - #suffix)
            if getPhaseKey(candidate) then return cleanPhaseName(candidate) end
        end
    end
    for _, entry in ipairs(getPhaseSignalEntries()) do
        if phaseSignalKeyMatches(signalKey, entry.key)
           or phaseSignalKeyMatches(signalKey, entry.phaseKey) then
            return entry.name
        end
    end
    return nil
end

function activeNightHasLiveChildren(activeNight)
    if not activeNight then return false end
    local ok, children = pcall(function() return activeNight:GetChildren() end)
    if not ok or not children then return false end
    return #children > 0
end

function readWorkspacePhaseAttribute(attrName)
    local ok, value = pcall(function()
        return workspace:GetAttribute(attrName)
    end)
    if not ok or type(value) ~= "string" or value == "" then return nil end
    if getPhaseKey(value) then
        return cleanPhaseName(value)
    end
    return nil
end

function getWorkspacePhaseEndTime()
    local ok, value = pcall(function()
        return workspace:GetAttribute("PhaseDuration")
    end)
    value = ok and tonumber(value) or 0
    local now = os.time()
    pcall(function()
        now = workspace:GetServerTimeNow()
    end)
    if value and value > now then
        return math.floor(value)
    end
    return 0
end

function getWorkspaceActivePhase()
    -- TimeCycleController starts script.Phases[ActiveWeather], so ActiveWeather
    -- is the real live phase name (Moon, Bloodmoon, Goldmoon, ...).
    local attrPhase = readWorkspacePhaseAttribute("ActiveWeather")
        or readWorkspacePhaseAttribute("CurrentWeather")
        or readWorkspacePhaseAttribute("ActivePhase")
        or readWorkspacePhaseAttribute("CurrentPhase")
        or readWorkspacePhaseAttribute("Phase")
    if attrPhase then
        return attrPhase
    end

    local activeNight = workspace:FindFirstChild("ActiveNight")
    if activeNight then
        if activeNight:FindFirstChild("Stars") or activeNight:FindFirstChild("Debris") then
            return "Mega Moon"
        end

        local nightPhase = findActivePhaseAsset(activeNight, false)
        if nightPhase and not isTechnicalPhaseName(nightPhase) then
            return nightPhase
        end

        if hasTruthyStateSignal(activeNight, { "Active", "Playing", "Enabled", "Running", "Started" })
           or activeNightHasLiveChildren(activeNight) then
            return "Moon"
        end
    end

    local specialPhase = findActivePhaseAsset(workspace, true)
    if specialPhase and not isTechnicalPhaseName(specialPhase) then
        return specialPhase
    end
    return nil
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
    local raw = string.lower(tostring(timeStr)):gsub("%s+", "")
    
    -- Check for h, m, s suffixes first
    local hours = tonumber(raw:match("(%d+)h")) or 0
    local minutes = tonumber(raw:match("(%d+)m")) or 0
    local seconds = tonumber(raw:match("(%d+)s")) or 0
    if hours > 0 or minutes > 0 or seconds > 0 then
        return hours * 3600 + minutes * 60 + seconds
    end
    
    -- Check for colons format (e.g. HH:MM:SS)
    local a, b, c = raw:match("(%d+):(%d+):(%d+)")
    if a and b and c then
        return tonumber(a) * 3600 + tonumber(b) * 60 + tonumber(c)
    end
    
    -- Check for colons format (e.g. MM:SS)
    local d, e = raw:match("(%d+):(%d+)")
    if d and e then
        return tonumber(d) * 60 + tonumber(e)
    end
    
    local val = tonumber(raw)
    if val then return val end
    
    return 0
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

local weatherFrameCardsCache = nil
local weatherFrameCardsCacheFrame = nil
local weatherFrameCardsCacheAt = -999
local weatherFrameCardsDirty = true
local WEATHER_FRAME_CARDS_CACHE_SECONDS = 45

function invalidateWeatherFrameCards()
    weatherFrameCardsCache = nil
    weatherFrameCardsCacheFrame = nil
    weatherFrameCardsCacheAt = -999
    weatherFrameCardsDirty = true
end

function getWeatherFrameCards(frame)
    local now = os.clock()
    if not weatherFrameCardsDirty and weatherFrameCardsCache and weatherFrameCardsCacheFrame == frame
        and (now - weatherFrameCardsCacheAt) < WEATHER_FRAME_CARDS_CACHE_SECONDS then
        return weatherFrameCardsCache
    end

    local cards, seen = {}, {}
    local function add(inst)
        if not inst or seen[inst] or not inst:IsA("GuiObject") then return end
        local name = resolveWeatherCardName(inst)
        if not name then return end
        seen[inst] = true
        table.insert(cards, inst)
    end

    if not frame then
        weatherFrameCardsCache = cards
        weatherFrameCardsCacheFrame = frame
        weatherFrameCardsCacheAt = now
        weatherFrameCardsDirty = false
        return cards
    end
    for _, child in ipairs(frame:GetChildren()) do
        add(child)
    end
    for _, desc in ipairs(frame:GetDescendants()) do
        add(desc)
    end
    weatherFrameCardsCache = cards
    weatherFrameCardsCacheFrame = frame
    weatherFrameCardsCacheAt = now
    weatherFrameCardsDirty = false
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
    add(getWeatherValues())
    add(ReplicatedStorage:FindFirstChild("TimeCycle"))
    add(ReplicatedStorage:FindFirstChild("TimeCycleState"))
    add(ReplicatedStorage:FindFirstChild("CurrentPhase"))
    add(ReplicatedStorage:FindFirstChild("ActivePhase"))
    add(workspace:FindFirstChild("TimeCycle"))
    add(workspace:FindFirstChild("TimeCycleState"))
    add(workspace:FindFirstChild("CurrentPhase"))
    add(workspace:FindFirstChild("ActivePhase"))
    add(workspace:FindFirstChild("Phase"))

    pcall(function()
        add(game:GetService("Lighting"))
    end)

    local playerScripts = LocalPlayer and LocalPlayer:FindFirstChild("PlayerScripts")
    if playerScripts then
        local controllers = findChildByNormalizedName(playerScripts, { "Controllers" })
        add(findChildByNormalizedName(playerScripts, { "TimeCycleController", "TimeCycle", "WeatherController", "EnvironmentController" }))
        add(findChildByNormalizedName(controllers, { "TimeCycleController", "TimeCycle", "WeatherController", "EnvironmentController" }))
    end

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

-- The fallback state roots can contain thousands of replicated instances.  They
-- are only needed when the authoritative WeatherValues/UI data has a gap, so keep
-- the discovered state and rescan only after a real weather event or a slow safety
-- timeout.  End times are recreated from the current call, not frozen in cache.
local weatherStateScanCache = nil
local weatherStateScanCacheAt = -999
local weatherStateScanDirty = true
local WEATHER_STATE_SCAN_INTERVAL = 45

function invalidateWeatherStateScan()
    weatherStateScanDirty = true
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
    local now = os.clock()
    if not weatherStateScanDirty and weatherStateScanCache
        and (now - weatherStateScanCacheAt) < WEATHER_STATE_SCAN_INTERVAL then
        local cachedWeathers = {}
        for name, info in pairs(weatherStateScanCache.weathers or {}) do
            cachedWeathers[name] = {
                playing = true,
                endTime = endTime or 0,
                image = info.image
            }
        end
        return cachedWeathers, weatherStateScanCache.phase
    end

    local weathers = {}
    local phase = readWorkspacePhaseAttribute("ActiveWeather")
        or readWorkspacePhaseAttribute("CurrentWeather")
        or readWorkspacePhaseAttribute("ActivePhase")
        or readWorkspacePhaseAttribute("CurrentPhase")
        or readWorkspacePhaseAttribute("Phase")
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
        if not inst or isTechnicalPhaseName(inst.Name) then return end

        local attrName = nil
        local okAttrs, attrs = pcall(function() return inst:GetAttributes() end)
        if okAttrs and type(attrs) == "table" then
            for attrKey, attrValue in pairs(attrs) do
                local attrKeyNorm = normalizeName(attrKey)
                local phaseFromSignal = readPhaseNameFromSignalName(attrKey)
                if phaseFromSignal and valueLooksTruthy(attrValue) then
                    phase = phaseFromSignal
                end
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
        local signalPhaseFromInstance = readPhaseNameFromSignalName(inst.Name)
        local signalPhaseActive = activeByState
        local signalPhaseValueObject = inst:IsA("BoolValue") or inst:IsA("StringValue")
            or inst:IsA("IntValue") or inst:IsA("NumberValue")
        if signalPhaseFromInstance and not signalPhaseActive and signalPhaseValueObject then
            local okValue, rawValue = pcall(function() return inst.Value end)
            signalPhaseActive = okValue and valueLooksTruthy(rawValue)
        end

        if attrName then
            addWeather(attrName, inst)
        elseif signalPhaseFromInstance and signalPhaseActive then
            phase = signalPhaseFromInstance
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

    local cachedWeathers = {}
    for name, info in pairs(weathers) do
        cachedWeathers[name] = {
            image = info and info.image or nil
        }
    end
    weatherStateScanCache = {
        phase = phase,
        weathers = cachedWeathers
    }
    weatherStateScanCacheAt = now
    weatherStateScanDirty = false
    return weathers, phase
end

local weatherCatalogCache = {}
local WEATHER_CATALOG_RESCAN_INTERVAL = 600
local WEATHER_CATALOG_SCAN_LIMIT = 5000
local weatherCatalogCacheAt = -WEATHER_CATALOG_RESCAN_INTERVAL
local weatherCatalogLiveCache = nil
local weatherCatalogLiveCacheAt = -999
local weatherCatalogLiveDirty = true
local WEATHER_CATALOG_LIVE_CACHE_SECONDS = 60

function invalidateWeatherCatalogCache()
    weatherCatalogLiveCache = nil
    weatherCatalogLiveCacheAt = -999
    weatherCatalogLiveDirty = true
end

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
    local now = os.clock()
    if not weatherCatalogLiveDirty and weatherCatalogLiveCache
        and (now - weatherCatalogLiveCacheAt) < WEATHER_CATALOG_LIVE_CACHE_SECONDS then
        return weatherCatalogLiveCache
    end

    local catalog = {}
    local function add(rawName, rawImage, isPhase)
        if type(rawName) ~= "string" or rawName == "" then return end
        if isTechnicalPhaseName(rawName) or isDecorativeWeatherCatalogName(rawName) then return end
        local displayName = isPhase and cleanPhaseName(rawName)
            or cleanWeatherStateName(rawName)
            or formatCamelCase(rawName)
            or rawName
        local image = normalizeWeatherImageRef(rawImage)
        if image and not isWeatherImageValidForName(displayName, image) then image = nil end
        local existing = catalog[displayName]
        if not existing or (not existing.image and image) then
            catalog[displayName] = { name = displayName, image = image }
        end
    end

    -- WeatherData and TimeCycleData are the same catalogues consumed by the
    -- v185 controllers. Reading them avoids all PlayerGui and ReplicatedStorage
    -- descendant scans and keeps image selection deterministic.
    for _, entry in ipairs(getWeatherDataEntries()) do
        add(entry.name or entry.rawName, entry.image, false)
    end

    local timeCycleData = getRequiredSharedModule("TimeCycleData")
    local phases = type(timeCycleData) == "table" and timeCycleData.Data or nil
    if type(phases) == "table" then
        for phaseName, phaseInfo in pairs(phases) do
            if type(phaseInfo) == "table" and type(phaseInfo.Weathers) == "table" then
                for weatherName, weatherInfo in pairs(phaseInfo.Weathers) do
                    if type(weatherInfo) == "table" then
                        add(weatherName, weatherInfo.Image or weatherInfo.IMG or weatherInfo.Icon, true)
                    end
                end
            end
        end
    end

    local phaseNames = {
        day = "Day", sunset = "Sunset", moon = "Moon",
        bloodmoon = "Blood Moon", goldmoon = "Gold Moon",
        chainedmoon = "Chained Moon", pizzamoon = "Pizza Moon",
        rainbowmoon = "Rainbow Moon", solareclipse = "Solar Eclipse",
        megamoon = "Mega Moon"
    }
    for phaseKey, image in pairs(PHASE_FALLBACK_IMAGES) do
        if phaseNames[phaseKey] then
            add(phaseNames[phaseKey], image, true)
        end
    end

    weatherCatalogLiveCache = catalog
    weatherCatalogLiveCacheAt = os.clock()
    weatherCatalogLiveDirty = false
    return catalog
end

local activeWeatherCache = nil
local activeWeatherCacheAt = -999
local ACTIVE_WEATHER_CACHE_SECONDS = 30 -- Weather signals invalidate this immediately.

function getActiveWeatherAndPhase()
    local now = os.clock()
    if activeWeatherCache and (now - activeWeatherCacheAt) < ACTIVE_WEATHER_CACHE_SECONDS then
        return activeWeatherCache.phase, activeWeatherCache.phaseImage, activeWeatherCache.weathers, activeWeatherCache.endTime
    end

    -- TimeCycleController treats ActivePhase as the broad phase and
    -- ActiveWeather as the selected day/moon variant. Both are replicated
    -- Workspace attributes, so no visual-state inference is necessary.
    local rawActiveWeather = workspace:GetAttribute("ActiveWeather")
    local rawActivePhase = workspace:GetAttribute("ActivePhase")
    local activePhase = type(rawActiveWeather) == "string" and rawActiveWeather ~= "" and cleanPhaseName(rawActiveWeather)
        or type(rawActivePhase) == "string" and rawActivePhase ~= "" and cleanPhaseName(rawActivePhase)
        or getDefaultPhase()
    local endTime = getWorkspacePhaseEndTime()
    local activeWeathers, valuesEndTime = getActiveWeatherFromWeatherValues(endTime, nil)
    if valuesEndTime and valuesEndTime > endTime then endTime = valuesEndTime end

    local weatherCatalog = getWeatherCatalog()
    local activePhaseImage = getCatalogImageByName(weatherCatalog, activePhase)
        or getPhaseFallbackImage(activePhase)
    for weatherName, info in pairs(activeWeathers or {}) do
        if info and not info.image then
            info.image = getCatalogImageByName(weatherCatalog, weatherName)
        end
    end
    activeWeatherCache = {
        phase = activePhase,
        phaseImage = activePhaseImage,
        weathers = activeWeathers,
        endTime = endTime
    }
    activeWeatherCacheAt = os.clock()
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
    local refreshAt = tonumber(auction.refreshAt) or 0
    local refreshBucket = refreshAt > 0 and math.floor((refreshAt + 2) / 5) or 0
    local parts = {
        "refreshAt:" .. tostring(refreshBucket),
        "refreshSource:" .. tostring(auction.refreshSource or "")
    }
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

-- Fruit multipliers are sourced from FruitImages and FruitStock snapshots.
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
local latestAuctionRollTime = 0
local latestAuctionAt = 0
local latestAuctionSnapshotAt = 0
local latestAuctionStockAt = 0
local auctionSnapshotConnected = false
local auctionStockConnected = false
local auctionRequestPending = false
local lastAuctionRequestAt = -10
local auctionGuiPrimedAt = 0
local auctionGuiAutoHidden = false
local originalAuctionFramePosition = nil
-- RequestSnapshot is only a fallback when event delivery is unavailable/stale.
-- Keep the short value as a remote-call throttle, not a permanent polling rate.
-- A startup shell is retried quickly so the first auction is visible without
-- waiting for the next roll.  Normal health polling still runs only every
-- minute; this value only gates an occasional RequestSnapshot call.
local AUCTION_REQUEST_INTERVAL = 3
local AUCTION_SNAPSHOT_STALE_SECONDS = 90
-- The health loop is only a cheap in-memory check.  A 5-second cadence lets
-- us recover a missed rollover event quickly without polling the network on
-- every tick; RequestSnapshot remains throttled separately.
local AUCTION_EVENT_HEALTH_INTERVAL = 5
local AUCTION_STARTUP_RETRY_INTERVAL = 2
local AUCTION_STARTUP_RETRY_COUNT = 20
local AUCTION_GUI_CACHE_SECONDS = 15
local AUCTION_DATA_CACHE_SECONDS = 15
local auctionGuiDataCache = nil
local auctionGuiDataCacheAt = -999
local auctionDataCache = nil
local auctionDataCacheAt = -999
local auctionRelativeRefreshAnchors = {
    snapshot = { cycleKey = "", refreshAt = 0 },
    gui = { cycleKey = "", refreshAt = 0 }
}
local auctionRefreshProbeToken = 0
local auctionRefreshProbeActive = false
local auctionPublishQueued = false
local AUCTION_PUBLISH_DEBOUNCE_SECONDS = 0.12

function invalidateAuctionCaches()
    auctionGuiDataCache = nil
    auctionGuiDataCacheAt = -999
    auctionDataCache = nil
    auctionDataCacheAt = -999
end

-- Snapshot and StockUpdate can arrive as a burst.  They contain only auction
-- state, so publish that compact payload once after the burst instead of
-- rebuilding/serializing the whole site payload for every individual signal.
function scheduleAuctionPublish()
    if not isCurrentScraperRun() or auctionPublishQueued then return end
    auctionPublishQueued = true
    safeTaskDelay(AUCTION_PUBLISH_DEBOUNCE_SECONDS, function()
        auctionPublishQueued = false
        if not isCurrentScraperRun() then return end
        local ok, sent = pcall(sendAuctionUpdateInstant)
        -- Keep the old reliability guarantee: if the compact WebSocket route
        -- is unavailable, immediately use the normal HTTP/WebSocket stock
        -- publisher instead of waiting for the periodic safety refresh.
        if not ok or not sent then
            updateAPI(nil)
        end
    end)
end

function scheduleAuctionRefreshProbe()
    if auctionRefreshProbeActive then return end
    auctionRefreshProbeActive = true
    auctionRefreshProbeToken = auctionRefreshProbeToken + 1
    local token = auctionRefreshProbeToken
    local delays = { 0.35, 0.8, 1.4, 2.4, 3.8, 5.5, 7.5, 10.0 }
    for index, delaySeconds in ipairs(delays) do
        safeTaskDelay(delaySeconds, function()
            if not isCurrentScraperRun() then return end
            if token ~= auctionRefreshProbeToken then return end
            invalidateAuctionCaches()
            local auctionData = getAuctionData()
            local refreshAt = type(auctionData) == "table" and tonumber(auctionData.refreshAt or 0) or 0
            if refreshAt > getServerNow() then
                local ok, sent = pcall(sendAuctionUpdateInstant)
                if not ok or not sent then
                    updateAPI(nil)
                end
                auctionRefreshProbeActive = false
                auctionRefreshProbeToken = auctionRefreshProbeToken + 1
            elseif index == #delays then
                auctionRefreshProbeActive = false
            end
        end)
    end
end

function getAuctioneerModule()
    if not cachedAuctioneer then
        cachedAuctioneer = safeRequireModule(getSharedModule("Auctioneer"))
    end
    return cachedAuctioneer
end

function getMailboxItemCatalog()
    if cachedMailboxItemCatalog ~= false then return cachedMailboxItemCatalog end

    -- Rebuild the small, data-only portion of MailboxItemCatalog from shared
    -- modules. Requiring the original PlayerScripts module starts UI/controllers;
    -- this resolver provides the same auction metadata without that CPU cost.
    local categories = {}
    local allByName = {}
    local function add(category, name, image, rarity, displayName)
        if type(name) ~= "string" or name == "" then return end
        local itemKey = normalizeName(name)
        local categoryKey = normalizeName(category)
        if itemKey == "" or categoryKey == "" then return end
        local meta = {
            name = type(displayName) == "string" and displayName ~= "" and displayName or name,
            image = readShopImageRef(image),
            rarity = type(rarity) == "string" and rarity or ""
        }
        categories[categoryKey] = categories[categoryKey] or {}
        local existing = categories[categoryKey][itemKey]
        if not existing or (not existing.image and meta.image) then
            categories[categoryKey][itemKey] = meta
        end
        local global = allByName[itemKey]
        if not global or (not global.image and meta.image) then allByName[itemKey] = meta end
    end

    local function firstField(entry, fields)
        if type(entry) ~= "table" then return nil end
        for _, field in ipairs(fields) do
            if entry[field] ~= nil then return entry[field] end
        end
        return nil
    end

    local function ingest(category, data, nameFields, imageFields, rarityFields)
        if type(data) ~= "table" then return end
        local rows = type(data.Data) == "table" and data.Data or data
        for key, entry in pairs(rows) do
            if type(entry) == "table" then
                local name = firstField(entry, nameFields)
                if not name and type(key) == "string" then name = key end
                add(category, name, firstField(entry, imageFields), firstField(entry, rarityFields), name)
            end
        end
    end

    local seedData = getRequiredSharedModule("SeedData")
    if type(seedData) == "table" then
        for _, seed in pairs(seedData) do
            if type(seed) == "table" and type(seed.SeedName) == "string" then
                add("Seeds", seed.SeedName, seed.SeedImage, seed.Rarity, seed.SeedName)
                add("HarvestedFruits", seed.SeedName, seed.FruitImage, seed.Rarity, seed.SeedName)
            end
        end
    end

    ingest("Gears", getRequiredSharedModule("GearShopData"),
        { "ItemName", "Name" }, { "IMG", "Image", "Icon" }, { "Rarity" })
    ingest("Sprinklers", getRequiredSharedModule("SprinklerData"),
        { "SprinklerName", "ItemName", "Name" }, { "Image", "IMG", "Icon" }, { "Rarity" })
    ingest("WateringCans", getRequiredSharedModule("WateringcanData"),
        { "Name", "ItemName" }, { "Image", "IMG", "Icon" }, { "Rarity" })
    ingest("Mushrooms", getRequiredSharedModule("MushroomData"),
        { "Name", "ItemName" }, { "IMG", "Image", "Icon" }, { "Rarity" })
    ingest("Raccoons", getRequiredSharedModule("RaccoonData"),
        { "Name", "ItemName" }, { "IMG", "Image", "Icon" }, { "Rarity" })
    ingest("Gnomes", getRequiredSharedModule("GnomeData"),
        { "Name", "ItemName" }, { "IMG", "Image", "Icon" }, { "Rarity" })
    ingest("PowerHoses", getRequiredSharedModule("PowerHoseData"),
        { "Name", "ItemName" }, { "IMG", "Image", "Icon" }, { "Rarity" })
    ingest("SeedPacks", getRequiredSharedModule("SeedPackData"),
        { "PackName", "Name", "ItemName" }, { "IMG", "Image", "Icon" }, { "Rarity" })
    ingest("Props", getRequiredSharedModule("PropData"),
        { "PropName", "Name", "ItemName" }, { "IMG", "Image", "Icon" }, { "Rarity" })

    local crateData = getRequiredSharedModule("CrateData")
    if type(crateData) == "table" and type(crateData.GetAllCrates) == "function" then
        local ok, crates = pcall(crateData.GetAllCrates)
        if ok then ingest("Crates", crates, { "Name", "CrateName" }, { "IMG", "Image", "Icon" }, { "Rarity" }) end
    else
        ingest("Crates", crateData, { "Name", "CrateName" }, { "IMG", "Image", "Icon" }, { "Rarity" })
    end
    local guildCrateData = getRequiredSharedModule("GuildCrateData")
    ingest("Crates", guildCrateData,
        { "Name", "CrateName" }, { "IMG", "Image", "Icon" }, { "Rarity" })
    local eggData = getRequiredSharedModule("EggData")
    ingest("Eggs", eggData,
        { "EggName", "Name" }, { "IMG", "Image", "Icon" }, { "Rarity" })

    local sharedData = ReplicatedStorage:FindFirstChild("SharedData")
    local petData = sharedData and safeRequireModule(sharedData:FindFirstChild("PetData")) or nil
    ingest("Pets", petData, { "Name", "PetName", "Species" }, { "Image", "IMG", "Icon" }, { "Rarity" })

    for _, folderName in ipairs({ "GearImages", "PropImages" }) do
        local folder = SharedModules and SharedModules:FindFirstChild(folderName)
        if folder then
            local category = folderName == "PropImages" and "Props" or "Gears"
            for _, child in ipairs(folder:GetChildren()) do
                add(category, child.Name, readShopImageRef(child), "", child.Name)
            end
        end
    end

    local function find(category, itemName)
        local itemKey = normalizeName(itemName)
        if itemKey == "" then return nil end
        local categoryRows = categories[normalizeName(category)]
        return categoryRows and categoryRows[itemKey] or allByName[itemKey]
    end

    cachedMailboxItemCatalog = {
        Resolve = function(category, itemName, metadata)
            local lookupName = type(metadata) == "table" and (metadata.FruitName or metadata.Name) or itemName
            local meta = find(category, lookupName) or find(category, itemName)
            local categoryKey = normalizeName(category)
            if not meta and categoryKey == "crates" then
                for _, module in pairs({ guildCrateData, crateData }) do
                    if type(module) == "table" and type(module.GetData) == "function" then
                        local ok, row = pcall(module.GetData, itemName)
                        if ok and type(row) == "table" then
                            meta = {
                                name = row.Name or itemName,
                                image = readShopImageRef(row.IMG or row.Image or row.Icon),
                                rarity = type(row.Rarity) == "string" and row.Rarity or ""
                            }
                            break
                        end
                    end
                end
            elseif not meta and categoryKey == "eggs"
                and type(eggData) == "table" and type(eggData.GetData) == "function" then
                local ok, row = pcall(eggData.GetData, itemName)
                if ok and type(row) == "table" then
                    meta = {
                        name = row.EggName or row.Name or itemName,
                        image = readShopImageRef(row.IMG or row.Image or row.Icon),
                        rarity = type(row.Rarity) == "string" and row.Rarity or ""
                    }
                end
            elseif categoryKey == "pets" and type(petData) == "table" then
                meta = meta or { name = tostring(itemName or ""), image = nil, rarity = "" }
                if not meta.image and type(petData.GetImage) == "function" then
                    local ok, image = pcall(petData.GetImage, lookupName, type(metadata) == "table" and metadata.Size or nil)
                    if ok then meta.image = readShopImageRef(image) end
                end
                if type(petData.GetSpeciesDisplayName) == "function" then
                    local ok, displayName = pcall(petData.GetSpeciesDisplayName, lookupName)
                    if ok and type(displayName) == "string" and displayName ~= "" then meta.name = displayName end
                end
            end
            return meta and meta.name or tostring(itemName or ""), meta and meta.image or ""
        end,
        ResolveRarity = function(category, itemName)
            local meta = find(category, itemName)
            return meta and meta.rarity or ""
        end
    }
    return cachedMailboxItemCatalog
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
            return connectRunSignal(remote.OnClientEvent, callback)
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
    for _, method in ipairs(methods) do
        local okMethod, fn = pcall(function()
            return endpoint[method]
        end)
        if okMethod and type(fn) == "function" then
            local ok, result = pcall(function(...)
                return fn(endpoint, ...)
            end, ...)
            if ok then return true, result end
            lastError = result

            -- A few executor wrappers expose an already-bound closure instead
            -- of a normal method. Try that form only when the method call
            -- failed; a successful nil-returning event must never be fired twice.
            ok, result = pcall(function(...)
                return fn(...)
            end, ...)
            if ok then return true, result end
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

    return false, lastError
end

local function connectNetworkSignal(signal, callback)
    if not signal or type(callback) ~= "function" then return false end

    local okEvent, event = pcall(function()
        return signal.OnClientEvent
    end)
    if okEvent and event and event.Connect then
        local ok, connection = pcall(function()
            return connectRunSignal(event, callback)
        end)
        if ok and connection then return true end
    end

    local okBindable, bindableEvent = pcall(function()
        return signal.Event
    end)
    if okBindable and bindableEvent and bindableEvent.Connect then
        local ok, connection = pcall(function()
            return connectRunSignal(bindableEvent, callback)
        end)
        if ok and connection then return true end
    end

    local okConnect, connectFn = pcall(function()
        return signal.Connect
    end)
    if okConnect and type(connectFn) == "function" then
        local connection = nil
        local ok = pcall(function()
            connection = connectFn(signal, function(...)
                if not isCurrentScraperRun() then return end
                return callback(...)
            end)
        end)
        if ok and connection then
            trackRunConnection(connection)
            return true
        end
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
    if expiresAt and expiresAt > 0 then return math.floor(expiresAt) end
    local rolledAt = tonumber(lot.rolledAt or lot.startedAt)
    local duration = tonumber(lot.durationSeconds or lot.duration or lot.lifetime or lot.last)
    if rolledAt and rolledAt > 0 and duration and duration > 0 then
        return math.floor(rolledAt + duration)
    end
    return 0
end

function normalizeAuctionRefreshAt(refreshAt, serverNow)
    refreshAt = tonumber(refreshAt) or 0
    serverNow = math.floor(tonumber(serverNow) or getServerNow())
    if refreshAt > 0 then refreshAt = math.floor(refreshAt) end
    return refreshAt > serverNow and refreshAt or 0
end

function getStableAuctionRelativeRefreshAt(source, cycleKey, duration, serverNow)
    duration = tonumber(duration) or 0
    serverNow = math.floor(tonumber(serverNow) or getServerNow())
    if duration <= 0 then return 0 end

    local anchor = auctionRelativeRefreshAnchors[source]
    if not anchor then
        anchor = { cycleKey = "", refreshAt = 0 }
        auctionRelativeRefreshAnchors[source] = anchor
    end
    cycleKey = tostring(cycleKey or "")

    -- A relative GUI/snapshot value is an observation of one fixed deadline,
    -- not a fresh duration to add on every scrape. Keep it for the whole lot
    -- cycle, even after it reaches zero; a new lot key starts the next cycle.
    if cycleKey ~= "" and anchor.cycleKey == cycleKey and anchor.refreshAt > 0 then
        return anchor.refreshAt
    end

    anchor.cycleKey = cycleKey
    anchor.refreshAt = serverNow + math.floor(duration)
    return anchor.refreshAt
end

function getAuctionSnapshotRefreshAt(snapshot, serverNow)
    if type(snapshot) ~= "table" then return 0, "unknown" end
    serverNow = math.floor(tonumber(serverNow) or getServerNow())

    local refreshKeys = {
        "refreshAt", "nextRefreshAt", "nextRefreshUnix", "refreshUnix",
        "auctionRefreshAt", "nextAuctionAt", "nextRollAt", "rollEndsAt"
    }
    for _, key in ipairs(refreshKeys) do
        local rawRefreshAt = tonumber(snapshot[key])
        if rawRefreshAt and rawRefreshAt > 0 then
            return normalizeAuctionRefreshAt(rawRefreshAt, serverNow), "snapshot-" .. key
        end
    end

    local rollWindowUnix = tonumber(snapshot.rollWindowUnix or snapshot.rollWindow or snapshot.startedAt)
    local rollIntervalSeconds = tonumber(snapshot.rollIntervalSeconds or snapshot.rollInterval or snapshot.cycleSeconds)
    local timerShiftSeconds = tonumber(snapshot.timerShiftSeconds) or 0
    if rollWindowUnix and rollWindowUnix > 0 and rollIntervalSeconds and rollIntervalSeconds > 0 then
        local refreshAt = normalizeAuctionRefreshAt(rollWindowUnix + rollIntervalSeconds + timerShiftSeconds, serverNow)
        return refreshAt, "snapshot-roll-window"
    end

    local durationKeys = {
        "refreshIn", "nextRefreshIn", "refreshInSeconds",
        "nextRefreshSeconds", "secondsUntilRefresh", "timeUntilRefresh"
    }
    for _, key in ipairs(durationKeys) do
        local duration = tonumber(snapshot[key])
        if duration and duration > 0 then
            local cycleKey = getAuctionSnapshotLotKey(snapshot)
            return getStableAuctionRelativeRefreshAt("snapshot", cycleKey, duration, serverNow), "snapshot-" .. key
        end
    end

    return 0, "unknown"
end

-- Some clients expose the Auctioneer lots before the header timer and roll
-- metadata are replicated.  Keep that first snapshot publishable instead of
-- waiting for the next periodic stock update.  Prefer an authoritative lot
-- expiry or roll schedule; the bounded startup fallback is replaced by the
-- next Snapshot event as soon as it arrives.
function inferAuctionRefreshAt(lots, snapshot, serverNow)
    if type(lots) ~= "table" then return 0, "unknown" end
    snapshot = type(snapshot) == "table" and snapshot or {}
    serverNow = math.floor(tonumber(serverNow) or getServerNow())

    local maxExpiry = 0
    local maxRolledAt = 0
    for _, lot in pairs(lots) do
        if type(lot) == "table" then
            local expiry = getAuctionLotExpiry(lot)
            if expiry > maxExpiry then maxExpiry = expiry end
            local rolledAt = tonumber(lot.rolledAt or lot.startedAt) or 0
            if rolledAt > maxRolledAt then maxRolledAt = rolledAt end
        end
    end
    if maxExpiry > serverNow then
        return maxExpiry, "inferred-lot-expiry"
    end

    local interval = tonumber(snapshot.rollIntervalSeconds or snapshot.rollInterval or snapshot.cycleSeconds) or 0
    if interval > 0 then
        local rollWindow = tonumber(snapshot.rollWindowUnix or snapshot.rollWindow or snapshot.startedAt) or maxRolledAt
        local shift = tonumber(snapshot.timerShiftSeconds) or 0
        local nextRefresh = rollWindow > 0 and (rollWindow + interval + shift) or (serverNow + interval)
        local guard = 0
        while nextRefresh <= serverNow and guard < 120 do
            nextRefresh = nextRefresh + interval
            guard = guard + 1
        end
        if nextRefresh > serverNow then
            return math.floor(nextRefresh), "inferred-next-cycle"
        end
    end

    -- No timer metadata at all: publish now with a short safety deadline. This
    -- is intentionally not a long fake auction; the next live event replaces it.
    return serverNow + 300, "inferred-startup"
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

function getAuctionLotTimestamp(lotId)
    local text = tostring(lotId or "")
    local ts = text:match(":(%d+):")
    if ts then return ts end
    return text:match(":(%d+)")
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
    local serverNow = getServerNow()
    local rollAge = serverNow - latestAuctionRollTime
    if rollAge >= 30 then
        addCandidate(lotIndex)
        addCandidate(lotIndex and tostring(lotIndex) or nil)
        addCandidate(position)
        addCandidate(position and tostring(position) or nil)
        addCandidate(position and position - 1 or nil)
        addCandidate(position and tostring(position - 1) or nil)
        addCandidate(rawIndex)
        addCandidate(rawIndex and tostring(rawIndex) or nil)
    end

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
    local manifestLots = nil
    if type(snapshot.manifest) == "table" and type(snapshot.manifest.lots) == "table" then
        manifestLots = snapshot.manifest.lots
        -- Prefer a populated manifest, but do not let an empty manifest shell
        -- hide a valid top-level `lots` collection from an executor wrapper.
        for _, lot in pairs(manifestLots) do
            if type(lot) == "table" and (lot.lotId or lot.id) then
                return manifestLots
            end
        end
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
            if type(lot) == "table" and (lot.lotId or lot.id) then
                hasIndexedLots = true
                break
            end
        end
        if hasIndexedLots then
            return snapshot.manifest
        end
    end
    return manifestLots
end

-- A response such as {manifest = {lots = {}}} is a valid Packet response,
-- but it is not an auction snapshot that can be published.  The game can
-- return this short-lived shell while Auctioneer is still hydrating the
-- player state.  Treat only lots with an actual lotId as ready.
function getAuctionLotCount(snapshot)
    local lots = getAuctionRawLots(snapshot)
    if type(lots) ~= "table" then return 0 end
    local count = 0
    for _, lot in pairs(lots) do
        if type(lot) == "table" and tostring(lot.lotId or lot.id or "") ~= "" then
            count = count + 1
        end
    end
    return count
end

function hasAuctionLots(snapshot)
    return getAuctionLotCount(snapshot) > 0
end

-- Return the deadline encoded by the raw Auctioneer snapshot.  This is kept
-- separate from getAuctionData(), which intentionally advances an already
-- passed deadline to a safe future fallback.  The health loop needs the raw
-- value so it can notice a missed rollover and request a fresh snapshot now.
function getAuctionRawRollDeadline(snapshot)
    if type(snapshot) ~= "table" then return 0 end
    local directKeys = {
        "refreshAt", "nextRefreshAt", "nextRefreshUnix", "refreshUnix",
        "auctionRefreshAt", "nextAuctionAt", "nextRollAt", "rollEndsAt"
    }
    for _, key in ipairs(directKeys) do
        local value = tonumber(snapshot[key])
        if value and value > 0 then return math.floor(value) end
    end

    local window = tonumber(snapshot.rollWindowUnix or snapshot.rollWindow or snapshot.startedAt) or 0
    local interval = tonumber(snapshot.rollIntervalSeconds or snapshot.rollInterval or snapshot.cycleSeconds) or 0
    local shift = tonumber(snapshot.timerShiftSeconds) or 0
    if window > 0 and interval > 0 then
        return math.floor(window + interval + shift)
    end
    return 0
end

function getAuctionSnapshotLotKey(snapshot)
    local lots = getAuctionRawLots(snapshot)
    if type(lots) ~= "table" then return "" end
    local keys = {}
    for _, lot in pairs(lots) do
        if type(lot) == "table" and (lot.lotId or lot.id) then
            table.insert(keys, normalizeAuctionLotId(lot.lotId or lot.id))
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
            local ok, _, result = pcall(function()
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
    invalidateAuctionCaches()
    local incomingHasLots = getAuctionLotCount(snapshot) > 0
    if not incomingHasLots and type(snapshot.stock) ~= "table" and not latestAuctionSnapshot then
        return false
    end
    if not incomingHasLots and latestAuctionSnapshot then
        -- Do not let an empty startup manifest overwrite a real snapshot that
        -- was received a moment earlier. Merge metadata while preserving the
        -- previous lot collection and its nested manifest.
        local merged = {}
        for key, value in pairs(latestAuctionSnapshot) do
            merged[key] = value
        end
        for key, value in pairs(snapshot) do
            local isLotContainer = key == "lots" or key == "items" or key == "manifest"
            if not isLotContainer then
                merged[key] = value
            elseif type(value) == "table" then
                local candidate = {}
                candidate[key] = value
                -- Empty lots/items/manifest values are hydration shells; keep
                -- the previous non-empty container instead of erasing it.
                if getAuctionLotCount(candidate) > 0 then
                    merged[key] = value
                end
            else
                merged[key] = value
            end
        end
        snapshot = merged
    end
    local previousLotKey = getAuctionSnapshotLotKey(latestAuctionSnapshot)
    local nextLotKey = getAuctionSnapshotLotKey(snapshot)
    -- A first non-empty snapshot is also a new cycle from the scraper's
    -- perspective.  Clear any stock-only shell that may have arrived before
    -- the manifest, otherwise its keys can mask the real lot quantities.
    local lotsChanged = nextLotKey ~= "" and previousLotKey ~= nextLotKey
    latestAuctionSnapshot = snapshot
    local maxRolledAt = 0
    local rawLots = getAuctionRawLots(snapshot)
    if type(rawLots) == "table" then
        for _, lot in pairs(rawLots) do
            if type(lot) == "table" then
                local rolledAt = tonumber(lot.rolledAt or lot.startedAt) or 0
                if rolledAt > maxRolledAt then
                    maxRolledAt = rolledAt
                end
            end
        end
    end
    if lotsChanged then
        latestAuctionSoldOutPrices = {}
        latestAuctionStock = {}
        latestAuctionRollTime = maxRolledAt > 0 and maxRolledAt or getServerNow()
    end
    if latestAuctionRollTime == 0 or (maxRolledAt > 0 and latestAuctionRollTime ~= maxRolledAt) then
        latestAuctionRollTime = maxRolledAt > 0 and maxRolledAt or getServerNow()
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
    scheduleAuctionPublish()
    if incomingHasLots and (lotsChanged or previousLotKey == "") then
        scheduleAuctionRefreshProbe()
    end
    return true
end

function applyAuctionStockUpdate(update, maybeStock)
    local stockPayload, replaceAll = extractAuctionStockPayload(update, maybeStock)
    if type(stockPayload) ~= "table" then return false end
    invalidateAuctionCaches()
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
    scheduleAuctionPublish()
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

    return auctionGuiPrimedAt > 0 and (os.clock() - auctionGuiPrimedAt) > 2.0
end

function isDefaultAuctionPlaceholderLot(lot)
    if type(lot) ~= "table" then return false end
    local startPrice = tonumber(lot.startPrice or lot.currentPrice or lot.price or lot.cost)
    local stockQuantity = tonumber(lot.stockQuantity or lot.stock or lot.quantity or lot.count)
    -- Classic exact match
    if startPrice == 100000 and stockQuantity == 16 then return true end
    -- Price near 100K (may have decremented) with default stock 16
    if startPrice and startPrice >= 95000 and startPrice <= 100000 and stockQuantity == 16 then return true end
    -- No price at all with default stock 16 — snapshot has placeholder shell
    if startPrice == nil and stockQuantity == 16 then return true end
    -- Stock 16 with no price formula fields at all (no startPrice, rolledAt, etc.)
    if stockQuantity == 16 and not tonumber(lot.startPrice) and not tonumber(lot.rolledAt) and not tonumber(lot.expiresAt) and not tonumber(lot.durationSeconds) then return true end
    return false
end

function parseCompactMoney(text)
    if not text then return 0 end
    local raw = string.lower(tostring(text)):gsub("%s+", ""):gsub("[%$%¢₽]", "")
    local numberText, suffix = raw:match("([%d%.,]+)(%a*)")
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
    local expired = string.find(lowerStock, "expired") ~= nil
        or string.find(lowerStock, "ended") ~= nil
        or string.find(lowerStock, "истек") ~= nil
        or string.find(lowerStock, "истёк") ~= nil
    local soldOut = string.find(lowerStock, "sold") ~= nil
        or string.find(lowerStock, "out of stock") ~= nil
        or string.find(lowerStock, "sold out") ~= nil
        or string.find(lowerStock, "%f[%a]out%f[%A]") ~= nil
        or string.find(lowerStock, "нет") ~= nil
        or string.find(lowerStock, "закончился") ~= nil
    if soldOut or expired then return 0, soldOut, expired end

    local parsedStock = raw:match("[xX]%s*([%d,%s%.]+)")
        or raw:match("([%d][%d,%s%.]*)")
    if not parsedStock then
        -- Fallback: strip all non-digits to get pure stock count
        parsedStock = raw:gsub("%D", "")
    end
    if parsedStock == "" then return nil, false, false end

    local cleaned = parsedStock:gsub("[%s,%.]", "")
    local value = tonumber(cleaned)
    if value == nil then return nil, false, false end
    return math.max(0, math.floor(value)), false, false
end

function getAuctionDataFromGui(force)
    local nowClock = os.clock()
    if not force and (nowClock - auctionGuiDataCacheAt) < AUCTION_GUI_CACHE_SECONDS then
        return auctionGuiDataCache
    end
    local function finish(data)
        auctionGuiDataCache = data
        auctionGuiDataCacheAt = os.clock()
        return data
    end

    local auctionGui = PlayerGui and PlayerGui:FindFirstChild("Auction")
    if not auctionGui then return finish(nil) end
    local hasActiveSnapshot = latestAuctionSnapshot and (os.clock() - latestAuctionSnapshotAt) < 15
    local guiPrimed = primeAuctionGuiForLiveValues()
    local guiDynamicTrusted = guiPrimed or not hasActiveSnapshot
    local frame = auctionGui:FindFirstChild("Frame", true)
    local scrollingFrame = frame and frame:FindFirstChild("ScrollingFrame", true)
    if not scrollingFrame then return finish(nil) end

    local serverNow = math.floor(getServerNow())
    local lots = {}
    local header = frame:FindFirstChild("Header", true)
    local headerTimerText = getAuctionGuiTimerText(header) or ""
    local headerDuration = parseDurationSeconds(headerTimerText)
    local refreshAt = 0
    local refreshSource = headerDuration > 0 and "gui-header" or "unknown"

    for _, card in ipairs(scrollingFrame:GetChildren()) do
        if card:IsA("GuiObject") then
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

                local stock, soldOut, textExpired = parseAuctionStockText(stockText)

                local currentPrice = parseCompactMoney(priceText)
                local cardLotId = normalizeAuctionLotId(card.Name)
                local cardKey = normalizeName(card.Name)
                local isAuctionLotCard = string.sub(cardKey, 1, 10) == "lotauction" or string.sub(cardKey, 1, 7) == "auction"
                local looksLikeTemplateAuctionRow = not isAuctionLotCard
                    and currentPrice == 1000 and stock == 16 and duration <= 0 and headerDuration <= 0
                local looksLikeDefaultDynamic = (currentPrice >= 95000 and currentPrice <= 100000) and stock == 16
                local rowDynamicTrusted = guiDynamicTrusted and not looksLikeDefaultDynamic

                local expired = textExpired == true and not soldOut
                if rowDynamicTrusted then
                    local expiredObj = main:FindFirstChild("EXPIRED", true)
                    local outObj = main:FindFirstChild("OUT_OF_STOCK", true)
                    local expiredVisible = expiredObj and expiredObj:IsA("GuiObject") and expiredObj.Visible == true
                    local outVisible = outObj and outObj:IsA("GuiObject") and outObj.Visible == true

                    if expiredVisible then
                        expired = true
                        soldOut = false
                    elseif outVisible then
                        soldOut = true
                        stock = 0
                        expired = false
                    end
                else
                    stock = nil
                    currentPrice = 0
                    expiresAt = 0
                    soldOut = false
                    expired = false
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
    end

    if #lots == 0 then return finish(nil) end
    -- If every lot still shows default placeholder values, the GUI hasn't finished loading.
    -- Suppress this result to avoid publishing stale data that gets corrected seconds later.
    local allDefault = true
    for _, lot in ipairs(lots) do
        if not lot.looksLikeDefaultDynamic then
            allDefault = false
            break
        end
    end
    if allDefault and #lots > 0 then return finish(nil) end
    table.sort(lots, function(a, b)
        return tostring(a.lotId or "") < tostring(b.lotId or "")
    end)
    if headerDuration > 0 then
        local guiCycleKey = getAuctionSnapshotLotKey({ lots = lots })
        refreshAt = getStableAuctionRelativeRefreshAt("gui", guiCycleKey, headerDuration, serverNow)
    end
    refreshAt = normalizeAuctionRefreshAt(refreshAt, serverNow)
    if refreshAt <= serverNow then
        refreshAt, refreshSource = inferAuctionRefreshAt(lots, nil, serverNow)
    end
    return finish({
        lots = lots,
        refreshAt = refreshAt,
        refreshSource = refreshSource,
        serverNow = serverNow,
        source = "gui",
        dynamicTrusted = guiDynamicTrusted
    })
end

function getAuctionData()
    local nowClock = os.clock()
    if auctionDataCache and (nowClock - auctionDataCacheAt) < AUCTION_DATA_CACHE_SECONDS then
        return auctionDataCache
    end
    local function finish(data)
        if type(data) == "table" then
            auctionDataCache = data
            auctionDataCacheAt = os.clock()
        end
        return data
    end

    if not latestAuctionSnapshot
        or not hasAuctionLots(latestAuctionSnapshot)
        or (os.clock() - latestAuctionSnapshotAt) > AUCTION_SNAPSHOT_STALE_SECONDS then
        requestAuctionSnapshot(false)
    end
    local snapshot = latestAuctionSnapshot
    if type(snapshot) ~= "table" then
        return finish(ALLOW_GUI_FALLBACK and getAuctionDataFromGui() or nil)
    end

    local rawLots = getAuctionRawLots(snapshot)
    if type(rawLots) ~= "table" then
        return finish(ALLOW_GUI_FALLBACK and getAuctionDataFromGui() or nil)
    end

    -- Snapshot/StockUpdate are authoritative in v185. GUI cards are delayed,
    -- animated presentation objects and must not be read during normal work.
    local guiData = nil
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
        if type(lot) == "table" and (lot.lotId or lot.id) then
            table.insert(orderedRawLots, {
                rawIndex = tonumber(rawIndex),
                lotId = tostring(lot.lotId or lot.id),
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
            local lot = raw.lot
            if type(lot) == "table" and (lot.lotId or lot.id) then
            local lotId = normalizeAuctionLotId(lot.lotId or lot.id)
            local lotIndex = getAuctionLotIndex(lotId)
            local rawIndex = raw.rawIndex
            local guiLot = guiLotsById[lotId]
            if not guiLot and lotIndex ~= nil then
                local fallbackLot = guiLotsByIndex[lotIndex]
                if fallbackLot then
                    local snapTs = getAuctionLotTimestamp(lotId)
                    local guiTs = getAuctionLotTimestamp(fallbackLot.lotId)
                    if snapTs == nil or guiTs == nil or snapTs == guiTs then
                        guiLot = fallbackLot
                    end
                end
            end
            if not guiLot then
                local fallbackLot = guiLotsByPosition[position]
                if fallbackLot then
                    local snapTs = getAuctionLotTimestamp(lotId)
                    local guiTs = getAuctionLotTimestamp(fallbackLot.lotId)
                    if snapTs == nil or guiTs == nil or snapTs == guiTs then
                        guiLot = fallbackLot
                    end
                end
            end
            -- If the GUI is loaded and shows real lots but this snapshot lot has
            -- no matching GUI card, it is a phantom entry from the Auctioneer
            -- module's internal data — skip it entirely.
            local guiHasLots = guiData and type(guiData.lots) == "table" and #guiData.lots > 0
            if guiHasLots and not guiLot then
                -- phantom lot: exists in network snapshot but not in the player's GUI
            else
            -- AuctioneerController treats Snapshot.manifest.lots as the
            -- authoritative initial state (see the game source's
            -- AuctioneerRequestSnapshot:Fire/applySnapshot path).  The old
            -- placeholder heuristic (100000 price / stock 16) was copied from
            -- the GUI template and incorrectly discarded real startup lots
            -- before the first StockUpdate arrived.  Only GUI fallback data is
            -- allowed to use that heuristic; network snapshots are trusted.
            local placeholderLot = false
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
            if stock == nil and useGuiDynamic and guiLot.stock ~= nil then
                stock = guiLot.stock
                hasLiveStock = true
            end
            if stock == nil and not placeholderLot then
                stock = getAuctionLotFallbackStock(lot)
            end
            local currentPrice = getLotCurrentPrice(lot)
            local priceKnown = hasReliableAuctionPrice(lot)
            if (currentPrice == nil or not priceKnown) and useGuiDynamic and tonumber(guiLot.currentPrice) and tonumber(guiLot.currentPrice) > 0 then
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
            local soldOut = stock ~= nil and stock <= 0
            local lotExpiresAt = placeholderLot and not useGuiDynamic and 0 or getAuctionLotExpiry(lot)
            local expired = lotExpiresAt > 0 and lotExpiresAt <= getServerNow()
            if useGuiDynamic then
                if guiLot.expired == true then
                    expired = true
                    soldOut = false
                elseif guiLot.soldOut == true then
                    soldOut = true
                    expired = false
                elseif guiLot.expired == false then
                    expired = false
                end
            elseif soldOut then
                expired = false
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
                startPrice = tonumber(lot.startPrice),
                minPrice = tonumber(lot.minPrice),
                decrementIntervalSeconds = tonumber(lot.decrementIntervalSeconds),
                decrementPercent = tonumber(lot.decrementPercent),
                robuxPrice = lot.robuxPrice,
                rolledAt = lot.rolledAt,
                expiresAt = useGuiDynamic and guiLot.expiresAt and guiLot.expiresAt > 0 and guiLot.expiresAt or lotExpiresAt,
                soldOut = soldOut,
                expired = expired,
                dynamicSource = useGuiDynamic and "gui" or "snapshot"
            })
            end -- if guiHasLots and not guiLot (phantom check)
        end
    end

    -- Keep authoritative manifest rows even while the first price/stock fields
    -- are still hydrating.  The old filter discarded every price-unknown row,
    -- which made the whole auction look empty until the first StockUpdate or
    -- rollover.  A real lotId is enough to keep the row; the client can show
    -- a temporary "--" price and replace it on the next packet.
    local filteredLots = {}
    for _, lot in ipairs(lots) do
        if type(lot) == "table" and tostring(lot.lotId or "") ~= "" then
            table.insert(filteredLots, lot)
        end
    end
    lots = filteredLots

    table.sort(lots, function(a, b)
        return tostring(a.lotId or "") < tostring(b.lotId or "")
    end)

    if #lots == 0 then
        return finish(ALLOW_GUI_FALLBACK and getAuctionDataFromGui() or nil)
    end

    local rollIntervalSeconds = tonumber(snapshot.rollIntervalSeconds) or 0
    local rollWindowUnix = tonumber(snapshot.rollWindowUnix) or 0
    local serverNow = math.floor(getServerNow())
    if rollWindowUnix == 0 then
        local maxRolledAt = 0
        for _, lot in ipairs(lots) do
            local rolledAt = tonumber(lot.rolledAt or lot.startedAt) or 0
            if rolledAt > maxRolledAt then
                maxRolledAt = rolledAt
            end
        end
        if maxRolledAt > 0 then
            rollWindowUnix = maxRolledAt
        end
    end
    local timerShiftSeconds = tonumber(snapshot.timerShiftSeconds) or 0
    local hasStableRollWindow = rollWindowUnix > 0 and rollIntervalSeconds > 0
    local refreshAt = 0
    local refreshSource = "unknown"
    if hasStableRollWindow then
        refreshAt = normalizeAuctionRefreshAt(rollWindowUnix + rollIntervalSeconds + timerShiftSeconds, serverNow)
        refreshSource = "roll-window"
    else
        refreshAt, refreshSource = getAuctionSnapshotRefreshAt(snapshot, serverNow)
    end
    -- The native AuctioneerController calculates its header from
    -- rollWindowUnix + rollIntervalSeconds + timerShiftSeconds. A GUI duration
    -- is only a fallback when that cycle anchor is genuinely unavailable.
    if ALLOW_GUI_FALLBACK and not hasStableRollWindow and refreshAt <= serverNow and guiData and tonumber(guiData.refreshAt) then
        local guiRefreshAt = normalizeAuctionRefreshAt(guiData.refreshAt, serverNow)
        if guiRefreshAt > serverNow then
            refreshAt = guiRefreshAt
            refreshSource = guiData.refreshSource or "gui-header"
        end
    end

    if refreshAt <= serverNow then
        refreshAt, refreshSource = inferAuctionRefreshAt(lots, snapshot, serverNow)
    end


    return finish({
        lots = lots,
        stock = latestAuctionStock,
        rollIntervalSeconds = rollIntervalSeconds,
        rollWindowUnix = rollWindowUnix,
        timerShiftSeconds = timerShiftSeconds,
        cycleKey = snapshot.cycleKey or snapshot.cycleId or snapshot.roundId or snapshot.auctionId,
        refreshAt = refreshAt,
        refreshSource = refreshSource,
        serverNow = serverNow
    })
end

local fruitImageCache = {}
local fruitImageCacheByKey = {}
local fruitImagesWatched = {}
local fruitImagesFolderConnected = false
local fruitImageCacheBuilt = false
local fruitListCache = nil

-- FruitImages.Bamboo is currently a Roblox PrivateImage placeholder.  Use the
-- harvested Bamboo plant thumbnail, not SeedImages.Bamboo (the seed packet).
local FRUIT_IMAGE_FALLBACKS = {
    bamboo = "138389335854784"
}
local INVALID_FRUIT_IMAGE_ASSETS = {
    bamboo = {
        ["70571153233151"] = true,
        ["131560215426602"] = true
    }
}

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
    fruitImagesWatched[entry] = connectRunSignal(entry.Changed, function()
        setFruitImageCacheValue(entry)
    end)
end

function ensureFruitImageCache()
    local folder = getFruitImagesFolder()
    if not folder then return end

    if not fruitImagesFolderConnected then
        fruitImagesFolderConnected = true
        connectRunSignal(folder.ChildAdded, function(entry)
            setFruitImageCacheValue(entry)
            watchFruitImageEntry(entry)
        end)
        connectRunSignal(folder.ChildRemoved, function(entry)
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
    local key = normalizeName(name)
    local image = fruitImageCache[name] or fruitImageCacheByKey[key]
    local assetId = normalizeAssetRef(image)
    if INVALID_FRUIT_IMAGE_ASSETS[key] and INVALID_FRUIT_IMAGE_ASSETS[key][assetId] then
        image = nil
    end
    return image or FRUIT_IMAGE_FALLBACKS[key]
end

-- ================== FRUIT VALUE CALCULATOR DATA SOURCE ==================
-- The website calculator uses live in-game modules instead of a hand-written
-- price list. Mutations are read from ReplicatedStorage.SharedModules.MutationData
-- children and then adjusted by live selling FastFlags.
local calculatorDataCache = nil
local calculatorDataCacheAt = -60
-- Calculator modules/FastFlags are effectively immutable in one server session.
-- Rebuilding them used to scan executor GC repeatedly every minute.
local CALCULATOR_DATA_REFRESH_INTERVAL = 300
local cachedFastFlags = false
local cachedAsserts = false
local FAST_FLAG_REPLICA_CACHE = {}

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

function getFastFlagReplica(flagName, defaultValue, assertFactory)
    if type(flagName) ~= "string" or flagName == "" then return nil end
    local cached = FAST_FLAG_REPLICA_CACHE[flagName]
    if cached then return cached end

    local fastFlags = getFastFlagsModule()
    if not fastFlags then return nil end

    -- UI modules may have already registered this key.  Reuse that replica
    -- instead of calling Replicated twice (the game rejects duplicate keys).
    local existing = nil
    if type(fastFlags.Get) == "function" then
        local okExisting, result = pcall(fastFlags.Get, flagName)
        if okExisting then existing = result end
    end
    if existing and type(existing.Get) == "function" then
        FAST_FLAG_REPLICA_CACHE[flagName] = existing
        return existing
    end

    local asserts = getAssertsModule()
    if not (fastFlags.Replicated and asserts and assertFactory) then return nil end
    local okAssert, assertValue = pcall(function()
        return assertFactory(asserts)
    end)
    if not okAssert then return nil end

    local okFlag, flag = pcall(fastFlags.Replicated, flagName, assertValue, defaultValue)
    if not (okFlag and flag and type(flag.Get) == "function") then return nil end
    FAST_FLAG_REPLICA_CACHE[flagName] = flag
    return flag
end

function getFastFlagValue(flagName, defaultValue, assertFactory)
    local flag = getFastFlagReplica(flagName, defaultValue, assertFactory)
    if not flag then return defaultValue end

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

local cachedMutationMultiplierResolver = false
local mutationMultiplierResolverChecked = false

function getCachedMutationMultiplierResolver()
    if mutationMultiplierResolverChecked then
        return cachedMutationMultiplierResolver or nil
    end
    mutationMultiplierResolverChecked = true

    -- Some executors cannot require the helper directly.  Resolve it at most once
    -- as a last resort; a getgc(true) walk for every mutation was the largest
    -- calculator-related CPU spike in the old script.
    local gc = getgc or (debug and debug.getregistry)
    if not gc then return nil end
    pcall(function()
        for _, value in ipairs(gc(true)) do
            if type(value) == "table" and type(rawget(value, "ReturnPriceMultiplier")) == "function" then
                cachedMutationMultiplierResolver = value.ReturnPriceMultiplier
                break
            end
        end
    end)
    return cachedMutationMultiplierResolver or nil
end

function getMutationMultiplier(mutationData, mutationName, rawEntry)
    if type(mutationName) ~= "string" or mutationName == "" then return nil end

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

    local resolver = getCachedMutationMultiplierResolver()
    if resolver then
        local ok, value = pcall(resolver, mutationName)
        local n = tonumber(value)
        if ok and n and n > 0 then return n end
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
    local seedShopEnabled = safeRequireModule(getSharedModule("SeedShopEnabled"))
    local mutationData = collectMutationEntriesFromInstance(getSharedModule("MutationData"))
    local isSeedEnabled = type(seedShopEnabled) == "table" and seedShopEnabled.IsSeedEnabled or nil
    if type(sellValueData) ~= "table" or type(isSeedEnabled) ~= "function" then
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
        local enabledOk, enabled = false, false
        if type(fruitName) == "string" then
            enabledOk, enabled = pcall(function()
                return isSeedEnabled(fruitName)
            end)
        end
        if type(fruitName) == "string" and value and value >= 0 and enabledOk and enabled == true then
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

-- FruitImages is only an icon folder. It also contains internal template and
-- model entries (for example FruitPart), so it must never be used as the
-- source of truth for the multiplier list. The game's own multiplier UI uses
-- SellValueData together with SeedShopEnabled.IsSeedEnabled; mirror that
-- authoritative list here and cache it because these modules do not change on
-- every stock tick.
local liveMultiplierFruitCatalog = nil
local liveMultiplierFruitCatalogAt = -60
local liveMultiplierFruitCatalogRevision = 0
local fruitListCacheRevision = -1
local LIVE_MULTIPLIER_FRUIT_CATALOG_REFRESH_INTERVAL = 300

local function getLiveMultiplierFruitCatalog()
    local now = os.clock()
    if liveMultiplierFruitCatalog and (now - liveMultiplierFruitCatalogAt) < LIVE_MULTIPLIER_FRUIT_CATALOG_REFRESH_INTERVAL then
        return liveMultiplierFruitCatalog
    end

    local sellValueData = safeRequireModule(getSharedModule("SellValueData"))
    local seedShopEnabled = safeRequireModule(getSharedModule("SeedShopEnabled"))
    local isSeedEnabled = type(seedShopEnabled) == "table" and seedShopEnabled.IsSeedEnabled or nil

    -- Fail closed rather than publishing the contents of FruitImages when the
    -- authoritative game modules are temporarily unavailable. A previously
    -- validated list remains available, so this cannot create a fake list
    -- during a short replication delay.
    if type(sellValueData) ~= "table" or type(isSeedEnabled) ~= "function" then
        return liveMultiplierFruitCatalog
    end

    local catalog = {}
    for fruitName in pairs(sellValueData) do
        if type(fruitName) == "string" then
            local cleanName = cleanScrapedName(fruitName)
            local key = normalizeName(cleanName)
            if cleanName and cleanName ~= "" and key ~= "" then
                local enabledOk, enabled = pcall(function()
                    return isSeedEnabled(fruitName)
                end)
                if enabledOk and enabled == true then
                    catalog[key] = cleanName
                end
            end
        end
    end

    if next(catalog) == nil then
        return liveMultiplierFruitCatalog
    end

    local changed = not liveMultiplierFruitCatalog
    if not changed then
        for key, name in pairs(catalog) do
            if liveMultiplierFruitCatalog[key] ~= name then
                changed = true
                break
            end
        end
        if not changed then
            for key in pairs(liveMultiplierFruitCatalog) do
                if catalog[key] == nil then
                    changed = true
                    break
                end
            end
        end
    end

    liveMultiplierFruitCatalog = catalog
    liveMultiplierFruitCatalogAt = now
    if changed then
        liveMultiplierFruitCatalogRevision = liveMultiplierFruitCatalogRevision + 1
        fruitListCache = nil
        fruitListCacheRevision = -1
    end
    return liveMultiplierFruitCatalog
end

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
            connectRunSignal(snapshotEvent.OnClientEvent, function(snapshot)
                if applyFruitSnapshot(snapshot) and onSnapshot then
                    onSnapshot()
                end
            end)
            connected = true
        elseif snapshotEvent.Connect then
            connectRunSignal(snapshotEvent, function(snapshot)
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

function getKnownFruitNames(liveCatalog)
    local names = {}
    local seen = {}
    for _, fruitName in pairs(liveCatalog or {}) do
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
    local liveCatalog = getLiveMultiplierFruitCatalog()
    if not liveCatalog then
        return fruitListCache or {}
    end
    if fruitListCache and #fruitListCache > 0 and fruitListCacheRevision == liveMultiplierFruitCatalogRevision then
        return fruitListCache
    end

    local multipliers = {}
    for _, fruitName in ipairs(getKnownFruitNames(liveCatalog)) do
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
        fruitListCacheRevision = liveMultiplierFruitCatalogRevision
    end
    return multipliers
end

-- ================== STATE POLLING + UPDATE ==================
-- Compact hash of a fruit list, used by the fast poll to detect value changes.
function fruitHash(list)
    local parts = {}
    for index, m in ipairs(list or {}) do
        parts[index] = table.concat({
            tostring(m.key or "?"),
            tostring(m.multiplier),
            tostring(m.tier),
            tostring(m.image)
        }, ":")
    end
    return table.concat(parts, "|")
end

function isAuctionDataComplete(auctionData)
    return type(auctionData) == "table"
        and type(auctionData.lots) == "table"
        and #auctionData.lots > 0
        and tonumber(auctionData.refreshAt or 0) ~= nil
        and tonumber(auctionData.refreshAt or 0) > getServerNow()
end

function getPublishableAuctionData()
    local auctionData = getAuctionData()
    if isAuctionDataComplete(auctionData) then
        return auctionData
    end
    scheduleAuctionRefreshProbe()
    return nil
end

function sendAuctionUpdateInstant()
    local ws = getWebSocketClient()
    if not ws then return false end

    local auctionData = getPublishableAuctionData()
    if type(auctionData) ~= "table" then return false end

    local wsPayload = {
        type = "update-auction",
        password = API_PASSWORD,
        data = auctionData
    }
    local encodeOk, encoded = pcall(function() return HttpService:JSONEncode(wsPayload) end)
    if encodeOk then
        local sendFunc = ws.Send or ws.send
        local success, err = pcall(function()
            sendFunc(ws, encoded)
        end)
        if success then
            if DEBUG then
                print("[Grow a Garden 2 Stocker] Instant auction update sent via WebSocket!")
            end
            return true
        else
            if DEBUG then
                warn("[Grow a Garden 2 Stocker] Failed to send instant auction update: " .. tostring(err))
            end
            pcall(function() ws:Close() end)
            pcall(function() ws:close() end)
            wsConnection = nil
            wsNextConnectAttemptAt = os.clock() + WEBSOCKET_RECONNECT_COOLDOWN
        end
    end
    return false
end

local lastUpdateTime = 0
local updatePending = false
local updateInFlight = false
local updateAfterFlight = false
local pendingFruitData = nil
local pendingFreshFruitScrape = false
local lastCalculatorPayloadAt = -999
local CALCULATOR_PAYLOAD_INTERVAL = 180
-- Shop values often arrive as a small burst (timer + several item values).
-- Publish the finished state after a tiny coalescing window instead of adding a
-- visible one-second delay or serializing the same full payload many times.
local LIVE_UPDATE_DEBOUNCE_SECONDS = 0.25

-- Network requests can yield for several seconds on a weak emulator. Keep at
-- most one sender alive and retain only the newest payload while it is busy.
-- This prevents a burst of stock values from becoming dozens of HTTP threads.
local queuedStockPayload = nil
local stockPayloadSenderRunning = false

local function getCalculatorPayloadForUpdate()
    local now = os.clock()
    if (now - lastCalculatorPayloadAt) < CALCULATOR_PAYLOAD_INTERVAL then return nil end
    local data = getCalculatorData()
    if type(data) == "table" then
        lastCalculatorPayloadAt = now
        return data
    end
    return nil
end

local function transmitStockPayload(data)
    if not isCurrentScraperRun() then return end

    local ws = getWebSocketClient()
    if ws then
        local wsPayload = {
            type = "update-stock",
            password = API_PASSWORD,
            data = data
        }
        local encodeOk, encodedWs = pcall(function() return HttpService:JSONEncode(wsPayload) end)
        if encodeOk then
            local sendFunc = ws.Send or ws.send
            local wsSuccess, wsErr = pcall(function()
                sendFunc(ws, encodedWs)
            end)
            if wsSuccess then
                if DEBUG then
                    print("[Grow a Garden 2 Stocker] Stock data updated via WebSocket")
                end
                return
            end
            warn("[Grow a Garden 2 Stocker] WebSocket send failed: " .. tostring(wsErr) .. ". Falling back to HTTP POST...")
            pcall(function() ws:Close() end)
            pcall(function() ws:close() end)
            wsConnection = nil
            wsNextConnectAttemptAt = os.clock() + WEBSOCKET_RECONNECT_COOLDOWN
        end
    end

    local encodeOk, encoded = pcall(function() return HttpService:JSONEncode(data) end)
    if not encodeOk then
        warn("[Grow a Garden 2 Stocker] JSON encoding failed: " .. tostring(encoded))
        return
    end
    local ok, response = makeHttpRequest(API_URL, "POST",
        { ["Content-Type"] = "application/json", ["X-API-Password"] = API_PASSWORD }, encoded)
    if not ok then
        warn("[Grow a Garden 2 Stocker] Failed to update stock data: " .. tostring(response))
    elseif DEBUG then
        print("[Grow a Garden 2 Stocker] Stock data updated via HTTP POST: " .. tostring(response))
    end
end

local function queueStockPayload(data)
    queuedStockPayload = data
    if stockPayloadSenderRunning then return end
    stockPayloadSenderRunning = true
    safeTaskSpawn(function()
        while queuedStockPayload and isCurrentScraperRun() do
            local latest = queuedStockPayload
            queuedStockPayload = nil
            local ok, err = pcall(transmitStockPayload, latest)
            if not ok then
                warn("[Grow a Garden 2 Stocker] Payload send failed: " .. tostring(err))
            end
        end
        stockPayloadSenderRunning = false
        -- An update cannot normally arrive between the loop test and this line,
        -- but keep the queue race-safe for executors with unusual schedulers.
        if queuedStockPayload and isCurrentScraperRun() then
            queueStockPayload(queuedStockPayload)
        end
    end)
end

-- updateAPI(fruitData): fruitData is an optional pre-scraped fruit list. If nil,
-- fruits are scraped fresh inside. We ALWAYS send live fruit data (never a stale
-- cache) so the website/bot reflects in-game multiplier changes immediately.
function updateAPI(fruitData)
    if not isCurrentScraperRun() then return end
    refreshRuntimeRefs()
    -- A stock/weather event asks for a fresh snapshot.  Never let an older
    -- fruit-event table win over that newer request while a burst is coalesced.
    if fruitData == nil then
        pendingFruitData = nil
        pendingFreshFruitScrape = true
    elseif not pendingFreshFruitScrape then
        pendingFruitData = fruitData
    end
    if updateInFlight then
        updateAfterFlight = true
        return
    end
    if updatePending then return end
    local now = os.clock()
    local elapsed = now - lastUpdateTime
    if elapsed < LIVE_UPDATE_DEBOUNCE_SECONDS then
        updatePending = true
        local waitLeft = LIVE_UPDATE_DEBOUNCE_SECONDS - elapsed
        safeTaskDelay(waitLeft, function()
            updatePending = false
            local dataToSend = pendingFreshFruitScrape and nil or pendingFruitData
            pendingFruitData = nil
            pendingFreshFruitScrape = false
            updateAPI(dataToSend)
        end)
        return
    end
    lastUpdateTime = now
    local dataToSend = pendingFreshFruitScrape and nil or pendingFruitData
    pendingFruitData = nil
    pendingFreshFruitScrape = false

    updateInFlight = true
    local success, err = pcall(function()
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

        local activeFruitCatalog = getLiveMultiplierFruitCatalog()
        local activeFruitNames = activeFruitCatalog and getKnownFruitNames(activeFruitCatalog) or nil
        local liveFruitMultipliers = dataToSend or fruitData or getFruitMultipliers()

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
                CrateShop = getShopData("CrateShop"),
                GearShop = getShopData("GearShop"),
                SeedShop_Normal = getShopData("SeedShop_Normal")
            },
            -- ALWAYS send live fruit data (never a stale cache) so the website reflects
            -- in-game multiplier changes immediately.
            fruitMultipliers = liveFruitMultipliers,
            -- Explicit allow-list from the same live game gate used by the
            -- official multiplier UI. The server keeps this with the snapshot
            -- so an old FruitImages/template entry cannot reappear after a
            -- refresh or reconnect.
            fruitMultiplierCatalog = activeFruitNames,
            -- Seconds until the next in-game multiplier refresh (dynamic countdown).
            fruitRefreshTimer = getFruitRefreshTimer(),
            -- Calculator metadata is large and static for a server session.
            -- Send it on startup and on the safety cadence, not with every
            -- individual stock/weather event.
            calculatorData = getCalculatorPayloadForUpdate(),
            auction = getPublishableAuctionData()
        }

        queueStockPayload(data)
    end)
    updateInFlight = false
    if not success then
        warn("[Grow a Garden 2 Stocker] Error during updateAPI: " .. tostring(err))
    end
    if updateAfterFlight and not updatePending then
        updateAfterFlight = false
        updatePending = true
        safeTaskDelay(LIVE_UPDATE_DEBOUNCE_SECONDS, function()
            updatePending = false
            local nextData = pendingFreshFruitScrape and nil or pendingFruitData
            pendingFruitData = nil
            pendingFreshFruitScrape = false
            updateAPI(nextData)
        end)
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
    connectAuctionSnapshot()
    requestAuctionSnapshot(true)
end)

safeTaskSpawn(function()
    for attempt = 1, AUCTION_STARTUP_RETRY_COUNT do
        if latestAuctionSnapshot and hasAuctionLots(latestAuctionSnapshot) then
            updateAPI(nil)
            return
        end
        connectAuctionSnapshot()
        -- The first request is immediate.  Subsequent retries respect the
        -- endpoint throttle instead of firing many Remote requests during
        -- startup when a RemoteEvent simply has no return value.
        requestAuctionSnapshot(attempt == 1)
        if hasAuctionLots(latestAuctionSnapshot) then
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
        if not isCurrentScraperRun() then return end
        safeTaskWait(60)
        connectFruitStockSnapshot(function()
            updateAPI(getFruitMultipliers())
        end)
    end
end)

safeTaskSpawn(function()
    -- Most clients attach immediately. Limit the faster startup retries; the
    -- health loop below still performs a rare late-attachment attempt.
    for _ = 1, 12 do
        if auctionSnapshotConnected and auctionStockConnected then return end
        if not isCurrentScraperRun() then return end
        safeTaskWait(10)
        connectAuctionSnapshot()
        if not hasAuctionLots(latestAuctionSnapshot) then
            requestAuctionSnapshot(false)
        end
    end
end)

safeTaskSpawn(function()
    while true do
        if not isCurrentScraperRun() then return end
        local snapshotAge = latestAuctionSnapshotAt > 0 and (os.clock() - latestAuctionSnapshotAt) or math.huge
        local eventDriven = auctionSnapshotConnected and auctionStockConnected
        local snapshotStale = not latestAuctionSnapshot or snapshotAge > AUCTION_SNAPSHOT_STALE_SECONDS
        local serverNow = math.floor(getServerNow())
        local rawRollDeadline = getAuctionRawRollDeadline(latestAuctionSnapshot)
        -- If Snapshot was missed exactly at the scheduled roll, keep asking for
        -- the authoritative state during a short recovery window.  Without
        -- this, the normal 60-second health poll could leave the old six lots
        -- visible for an entire extra cycle.
        local rollDue = rawRollDeadline > 0
            and serverNow >= rawRollDeadline
            and (serverNow - rawRollDeadline) <= 120

        -- Snapshot/StockUpdate events are authoritative and push changes
        -- immediately.  Poll only as a health fallback when an event is missing
        -- or no fresh snapshot has arrived for a while.
        if not eventDriven then
            connectAuctionSnapshot()
        end
        if not eventDriven or snapshotStale or rollDue then
            requestAuctionSnapshot(false)
        end
        safeTaskWait(AUCTION_EVENT_HEALTH_INTERVAL)
    end
end)

safeTaskSpawn(function()
    while latestFruitSnapshotAt <= 0 do
        if not isCurrentScraperRun() then return end
        safeTaskWait(FRUIT_REQUEST_INTERVAL)
        -- Startup already made an immediate forced request.  Respect the
        -- remote throttle on retries rather than issuing overlapping calls.
        requestFruitSnapshot(false)
    end
end)

local stockValueConnections = {}
local stockItemsFolderRemovalConnections = {}
local stockShopFolderRemovalConnections = {}
local stockValuesFolderConnections = {}
local stockValuesUpdateQueued = false
local shopPriceOverrideConnections = {}
local shopLimitedConnections = {}

function invalidateDirectShopCache(shopName)
    local canonicalShopKey = getCanonicalShopKey(shopName)
    local cacheKey = getDirectShopCacheKey(canonicalShopKey)
    invalidateStockItemsIndex(canonicalShopKey)
    DIRECT_SHOP_CACHE[cacheKey] = nil
    DIRECT_SHOP_CACHE_AT[cacheKey] = nil
end

function scheduleStockValuesUpdate(shopName, delaySeconds)
    invalidateDirectShopCache(shopName)
    if stockValuesUpdateQueued then return end
    stockValuesUpdateQueued = true
    safeTaskDelay(delaySeconds or 0.15, function()
        stockValuesUpdateQueued = false
        if not isCurrentScraperRun() then return end
        pcall(function()
            updateAPI(nil)
        end)
    end)
end

function watchStockValueObject(shopName, valueObject)
    if not valueObject or stockValueConnections[valueObject] then return end
    local ok, conn = pcall(function()
        return connectRunSignal(valueObject:GetPropertyChangedSignal("Value"), function()
            scheduleStockValuesUpdate(shopName, 0.08)
        end)
    end)
    if ok and conn then
        stockValueConnections[valueObject] = conn
    end
end

function watchStockItemsFolder(shopName, itemsFolder)
    if not itemsFolder then return end
    for _, itemValue in ipairs(itemsFolder:GetChildren()) do
        watchStockValueObject(shopName, itemValue)
    end
    if stockValueConnections[itemsFolder] then return end
    local childAddedOk, childAddedConn = pcall(function()
        return connectRunSignal(itemsFolder.ChildAdded, function(itemValue)
            watchStockValueObject(shopName, itemValue)
            scheduleStockValuesUpdate(shopName, 0.12)
        end)
    end)
    if childAddedOk and childAddedConn then
        stockValueConnections[itemsFolder] = childAddedConn
    end
    if not stockItemsFolderRemovalConnections[itemsFolder] then
        local childRemovedOk, childRemovedConn = pcall(function()
            return connectRunSignal(itemsFolder.ChildRemoved, function()
                scheduleStockValuesUpdate(shopName, 0.12)
            end)
        end)
        if childRemovedOk and childRemovedConn then
            stockItemsFolderRemovalConnections[itemsFolder] = childRemovedConn
        end
    end
end

function getShopPriceOverrideReplica(shopName)
    local canonicalShopKey = getCanonicalShopKey(shopName)
    local config = SHOP_PRICE_OVERRIDE_CONFIG[canonicalShopKey]
    if not config then return nil end
    local replica = getFastFlagReplica(config.flagName)
    if replica then return replica end

    -- Register the exact native schema if the shop UI has not done so yet.
    getShopPriceOverrides(canonicalShopKey)
    return getFastFlagReplica(config.flagName)
end

function watchShopPriceOverrideFlags()
    for shopName in pairs(SHOP_PRICE_OVERRIDE_CONFIG) do
        local watchedShopName = shopName
        local replica = getShopPriceOverrideReplica(watchedShopName)
        if replica and not shopPriceOverrideConnections[replica] then
            local connected = false
            local function refreshShopPrices()
                scheduleStockValuesUpdate(watchedShopName, 0.08)
            end
            for _, signalName in ipairs({ "Changed", "Loaded" }) do
                local ok, conn = pcall(function()
                    local signal = replica[signalName]
                    return signal and signal.Connect and connectRunSignal(signal, refreshShopPrices) or nil
                end)
                if ok and conn then connected = true end
            end
            if connected then shopPriceOverrideConnections[replica] = true end
        end
    end
end

function watchShopLimitedSources()
    for shopName, config in pairs(SHOP_LIMITED_CONFIG) do
        local watchedShopName = shopName
        local function refreshLimitedCatalog()
            -- Invalidate old delayed callbacks. The rebuilt catalogue schedules
            -- the new authoritative deadline, if one still exists.
            for key in pairs(LIMITED_EXPIRY_SCHEDULE) do
                if string.sub(key, 1, #watchedShopName + 1) == watchedShopName .. ":" then
                    LIMITED_EXPIRY_SCHEDULE[key] = nil
                end
            end
            scheduleStockValuesUpdate(watchedShopName, 0.08)
        end

        local limitedModule = getRequiredSharedModule(config.moduleName)
        local flag = getFastFlagReplica(config.flagName, {}, function(asserts)
            return asserts.Map(asserts.String, asserts.FiniteNonNegative)
        end)
        if not flag and type(limitedModule) == "table" then
            -- Requiring the native helper registers its LimitedEndTimes flag.
            flag = getFastFlagReplica(config.flagName)
        end
        if flag and not shopLimitedConnections[flag] then
            local connected = false
            for _, signalName in ipairs({ "Changed", "Loaded" }) do
                local ok, connection = pcall(function()
                    local signal = flag[signalName]
                    return signal and signal.Connect and connectRunSignal(signal, refreshLimitedCatalog) or nil
                end)
                if ok and connection then connected = true end
            end
            if connected then shopLimitedConnections[flag] = true end
        end

        local overrideFolder = ReplicatedStorage:FindFirstChild(config.overrideFolderName)
        if overrideFolder and not shopLimitedConnections[overrideFolder] then
            local function watchOverride(valueObject)
                if valueObject and valueObject:IsA("NumberValue") and not shopLimitedConnections[valueObject] then
                    shopLimitedConnections[valueObject] = connectRunSignal(valueObject:GetPropertyChangedSignal("Value"), refreshLimitedCatalog) or true
                end
            end
            for _, child in ipairs(overrideFolder:GetChildren()) do watchOverride(child) end
            connectRunSignal(overrideFolder.ChildAdded, function(child)
                watchOverride(child)
                refreshLimitedCatalog()
            end)
            connectRunSignal(overrideFolder.ChildRemoved, refreshLimitedCatalog)
            shopLimitedConnections[overrideFolder] = true
        end
    end
end

function watchStockShopFolder(shopFolder)
    if not shopFolder then return end
    local shopName = shopFolder.Name
    for _, timerName in ipairs({ "UnixNextRestock", "UnixLastRestock" }) do
        local timerValue = shopFolder:FindFirstChild(timerName)
        if timerValue then
            watchStockValueObject(shopName, timerValue)
        end
    end
    watchStockItemsFolder(shopName, shopFolder:FindFirstChild("Items"))
    if not stockValueConnections[shopFolder] then
        local ok, conn = pcall(function()
            return connectRunSignal(shopFolder.ChildAdded, function(child)
                if child.Name == "Items" then
                    watchStockItemsFolder(shopName, child)
                elseif child.Name == "UnixNextRestock" or child.Name == "UnixLastRestock" then
                    watchStockValueObject(shopName, child)
                end
                scheduleStockValuesUpdate(shopName, 0.12)
            end)
        end)
        if ok and conn then
            stockValueConnections[shopFolder] = conn
        end
    end
    if not stockShopFolderRemovalConnections[shopFolder] then
        local ok, conn = pcall(function()
            return connectRunSignal(shopFolder.ChildRemoved, function(child)
                if child.Name == "Items" or child.Name == "UnixNextRestock" or child.Name == "UnixLastRestock" then
                    scheduleStockValuesUpdate(shopName, 0.12)
                end
            end)
        end)
        if ok and conn then
            stockShopFolderRemovalConnections[shopFolder] = conn
        end
    end
end

function watchStockValuesFolder(stockValuesFolder)
    if not stockValuesFolder then return end
    for _, shopFolder in ipairs(stockValuesFolder:GetChildren()) do
        watchStockShopFolder(shopFolder)
    end
    if stockValuesFolderConnections[stockValuesFolder] then return end

    local _, childAddedConn = pcall(function()
        return connectRunSignal(stockValuesFolder.ChildAdded, function(shopFolder)
            watchStockShopFolder(shopFolder)
            scheduleStockValuesUpdate(shopFolder.Name, 0.15)
        end)
    end)
    local _, childRemovedConn = pcall(function()
        return connectRunSignal(stockValuesFolder.ChildRemoved, function(shopFolder)
            scheduleStockValuesUpdate(shopFolder.Name, 0.15)
        end)
    end)
    if childAddedConn or childRemovedConn then
        stockValuesFolderConnections[stockValuesFolder] = {
            added = childAddedConn,
            removed = childRemovedConn
        }
    end
end

refreshRuntimeRefs()
local StockValues = waitForChildSoft(ReplicatedStorage, "StockValues", 20)
if StockValues then
    print("[Grow a Garden 2 Stocker] Monitoring StockValues folder for updates...")
    watchStockValuesFolder(StockValues)
else
    if DEBUG then
        warn("[Grow a Garden 2 Stocker] StockValues folder not found in ReplicatedStorage.")
    end
end

pcall(function()
    connectRunSignal(ReplicatedStorage.ChildAdded, function(child)
        if child.Name == "StockValues" then
            watchStockValuesFolder(child)
            for _, shopName in ipairs({ "SeedShop", "GearShop", "CrateShop" }) do
                scheduleStockValuesUpdate(shopName, 0.15)
            end
            return
        end
        for shopName, config in pairs(SHOP_LIMITED_CONFIG) do
            if child.Name == config.overrideFolderName then
                watchShopLimitedSources()
                scheduleStockValuesUpdate(shopName, 0.08)
                return
            end
        end
    end)
end)

watchShopPriceOverrideFlags()
watchShopLimitedSources()

-- Flags can register a moment after startup. Retrying briefly keeps live price
-- changes event-driven without adding a permanent polling loop.
safeTaskSpawn(function()
    for _ = 1, 6 do
        if not isCurrentScraperRun() then return end
        watchShopPriceOverrideFlags()
        watchShopLimitedSources()
        safeTaskWait(2)
    end
end)

local environmentUpdateQueued = false
local lastEnvironmentDeepInvalidationAt = -999
local environmentDeepRefreshQueued = false
local ENVIRONMENT_DEEP_INVALIDATION_MIN_INTERVAL = 4

local function getWeatherAttributeChangeMode(attrName)
    local key = string.lower(tostring(attrName or "")):gsub("[^%w]", "")
    if key == "" then return "deep" end
    -- An absolute end time may arrive separately from the state name.  Publish
    -- it promptly, but it does not require rebuilding icon/card indices.
    if key == "endtime" or key == "endsat"
        or string.sub(key, -7) == "playing"
        or string.sub(key, -7) == "endtime" then
        return "light"
    end
    if key == "phaseduration" or key == "duration" or key == "timeleft"
        or key == "remaining" or key == "remainingtime" or key == "timer"
        or key == "countdown"
        or string.find(key, "duration", 1, true) ~= nil
        or string.find(key, "countdown", 1, true) ~= nil
        or string.find(key, "remaining", 1, true) ~= nil then
        return "ignore"
    end
    return "deep"
end

local function invalidateEnvironmentDiscoveryCaches()
    lastEnvironmentDeepInvalidationAt = os.clock()
    weatherDataCache = nil
    weatherDataByKeyCache = nil
    weatherDataCacheAt = -999
    phaseSignalEntriesCache = nil
    invalidateWeatherCatalogCache()
    invalidateWeatherFrameCards()
    invalidateWeatherStateScan()
end

function scheduleEnvironmentUpdate(delaySeconds, needsDeepInvalidation)
    activeWeatherCache = nil
    local now = os.clock()
    -- A countdown changing every second is not a weather transition.  Real
    -- transitions still invalidate immediately; a burst gets one trailing
    -- rescan instead of repeated GetDescendants() calls every 1–2 seconds.
    if needsDeepInvalidation ~= false then
        local elapsed = now - lastEnvironmentDeepInvalidationAt
        if elapsed >= ENVIRONMENT_DEEP_INVALIDATION_MIN_INTERVAL then
            invalidateEnvironmentDiscoveryCaches()
        elseif not environmentDeepRefreshQueued then
            environmentDeepRefreshQueued = true
            safeTaskDelay(ENVIRONMENT_DEEP_INVALIDATION_MIN_INTERVAL - elapsed, function()
                environmentDeepRefreshQueued = false
                if not isCurrentScraperRun() then return end
                invalidateEnvironmentDiscoveryCaches()
                scheduleEnvironmentUpdate(0.05, false)
            end)
        end
    end
    if environmentUpdateQueued then return end
    environmentUpdateQueued = true
    safeTaskDelay(math.max(tonumber(delaySeconds) or 0.2, 0.15), function()
        environmentUpdateQueued = false
        if not isCurrentScraperRun() then return end
        pcall(function()
            updateAPI(nil)
        end)
    end)
end

pcall(function()
    for _, attrName in ipairs({ "ActivePhase", "ActiveWeather", "PhaseDuration" }) do
        connectRunSignal(workspace:GetAttributeChangedSignal(attrName), function()
            scheduleEnvironmentUpdate(0.03, false)
        end)
    end
end)

pcall(function()
    local weatherValues = getWeatherValues()
    if weatherValues then
        local okAttrChanged, attrChanged = pcall(function()
            return weatherValues.AttributeChanged
        end)
        if okAttrChanged and attrChanged and attrChanged.Connect then
            connectRunSignal(attrChanged, function(attrName)
                local changeMode = getWeatherAttributeChangeMode(attrName)
                if changeMode == "ignore" then return end
                scheduleEnvironmentUpdate(0.15, changeMode == "deep")
            end)
        end
    end
end)

-- WeatherValues and workspace attributes are authoritative and already publish
-- a real state change immediately.  Listening to every visual child added to
-- the Weather UI was not: it could turn UI animations into repeated full stock
-- updates, especially on MuMu.  The low-frequency fallback below still covers
-- game versions that expose only the UI.

-- ================== LOOPS ==================
-- All normal state changes are handled above by StockValues, WeatherValues,
-- FruitStock and Auctioneer events.  This is deliberately only a low-frequency
-- safety net for executors/game versions where one of those signals is missing.
local lastPhase = nil
local lastWeathersHash = ""
local lastFruitHash = ""

safeTaskSpawn(function()
    while true do
        if not isCurrentScraperRun() then return end
        safeTaskWait(POLL_INTERVAL)
        local ok, err = pcall(function()
            refreshRuntimeRefs()
            local phase, _, weathers = getActiveWeatherAndPhase()
            local weathersHash = getWeathersHash(weathers)
            local freshFruits = getFruitMultipliers()
            local fh = fruitHash(freshFruits)

            if phase ~= lastPhase or weathersHash ~= lastWeathersHash or fh ~= lastFruitHash then
                lastPhase = phase
                lastWeathersHash = weathersHash
                lastFruitHash = fh
                -- Pass the cached/live snapshot through so the fallback does not
                -- perform a second fruit/catalog/auction/shop reconstruction.
                updateAPI(freshFruits)
            end
        end)
        if not ok and DEBUG then
            warn("[Grow a Garden 2 Stocker] Poll tick failed: " .. tostring(err))
        end
    end
end)

local loadingScreenBypassApplied = false

local function bypassLoadingScreen()
    if not BYPASS_LOADING_SCREEN then
        loadingScreenBypassApplied = true
        return
    end
    -- Repeating getconnections/GUI walks every API refresh both costs CPU and can
    -- disconnect the scraper's own listeners.  A fresh teleport runs a new script,
    -- so one successful pass per script run is enough.
    if loadingScreenBypassApplied and clientOptimized then return end
    refreshRuntimeRefs()
    local currentPlayerGui = PlayerGui or waitForChildSoft(LocalPlayer, "PlayerGui", 10)
    if not currentPlayerGui then return end
    
    pcall(function()
        -- 1. Find and destroy LoadingScreenMenu from workspace
        for _, child in ipairs(workspace:GetChildren()) do
            if child.Name == "LoadingScreenMenu" then
                child:Destroy()
                writeDebugLog("Destroyed LoadingScreenMenu in workspace")
            end
        end

        -- 2. Never disconnect another controller's GUI signals here.  Games
        -- commonly rebuild UI after that, which wastes CPU and can hide the
        -- exact shop/weather replicas used by the scraper.

        -- 3. Mark the local loading state complete without touching unrelated
        -- event connections.
        local localPlayer = LocalPlayer or (Players and Players.LocalPlayer)
        if localPlayer then
            pcall(function()
                localPlayer:SetAttribute("LoadingScreenActive", false)
                localPlayer:SetAttribute("LoadingScreenDone", true)
            end)
        end
        
        if not clientOptimized and workspace.CurrentCamera and workspace.CurrentCamera.CameraType == Enum.CameraType.Scriptable then
            workspace.CurrentCamera.CameraType = Enum.CameraType.Custom
            writeDebugLog("Reset camera locked by loading screen")
        end
        loadingScreenBypassApplied = true
    end)
end

-- Fallback periodic update: scrape everything fresh inside updateAPI (fruitData=nil
-- means "scrape fresh"), guaranteeing the site gets current data even if the fast
-- poll detected no change (e.g. UI re-opened, values rotated server-side).
safeTaskSpawn(function()
    while true do
        if not isCurrentScraperRun() then return end
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

local optimizationModeLabel = HEADLESS_SCRAPER_MODE
    and ("Aggressive Headless " .. tostring(HEADLESS_FPS_CAP) .. " FPS")
    or (MOBILE_SAFE_MODE and "Mobile Safe Mode" or "Extreme Optimization")
print("[Grow a Garden 2 Stocker] Scraper loaded (" .. optimizationModeLabel .. ")!")
