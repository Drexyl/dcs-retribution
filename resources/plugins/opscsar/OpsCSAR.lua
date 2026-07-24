--------------------------------------------------------------------------------
-- Retribution Plugin: OpsCSAR.lua
--
-- Player-flown Combat Search & Rescue via MOOSE Ops.CSAR.
--
-- Turned on per coalition by the "Ops.CSAR player rescue helicopters (Blue/Red)"
-- options in Retribution's Mission Generator -> Gameplay settings. When enabled,
-- CsarGenerator (Python) bakes a player-flyable "CSAR Rescue <airfield>"
-- helicopter slot into the .miz at each friendly airfield (DCS multiplayer slots
-- must exist at mission load; they cannot be created at runtime). This script
-- self-gates on the presence of those groups: for each coalition that has any
-- "CSAR Rescue" group, it sets up Ops.CSAR and hands those helicopters to it.
--
-- Self-contained: does not depend on the FlightControl plugin.
--------------------------------------------------------------------------------

env.info("[OpsCSAR] === OpsCSAR.lua loading ===")

-- Rescue-helo groups baked into the mission by CsarGenerator use this name
-- prefix (keep in sync with game/missiongenerator/csargenerator.py).
local RESCUE_HELO_PREFIX = "CSAR Rescue"

local function log(msg) env.info("[OpsCSAR] " .. tostring(msg)) end
local function warn(msg) env.warning("[OpsCSAR] " .. tostring(msg)) end

-- Report a recovered pilot to the campaign by appending the ejected aircraft's
-- DCS unit name to the shared `rescued_pilots` global (declared in the base
-- plugin's dcs_retribution.lua, serialized into state.json). Retribution maps
-- the unit name back to the exact pilot and spares them instead of killing.
local function emitRescuedUnit(unitName)
    -- "Aircraft" is MOOSE's placeholder when the original unit name was lost
    -- (csarUsePara path); it can't be mapped back, so skip it.
    if not unitName or unitName == "" or unitName == "Aircraft" then return end
    if type(rescued_pilots) ~= "table" then
        warn("rescued_pilots global missing; base plugin not loaded?")
        return
    end
    rescued_pilots[#rescued_pilots + 1] = unitName
    dirty_state = true
    log("Reported recovered pilot from unit: " .. unitName)
end

-- Per-side enable state and options are injected by CsarGenerator (Python) as
-- the global OpsCSAR_Settings, driven by the Mission Generator -> Gameplay
-- checkboxes. We gate on these rather than counting rescue-helo groups at
-- runtime: unoccupied Client (player-slot) groups are not live groups until a
-- player joins, so any group count taken here would be unreliable.
local function opsCsarEnabledForSide(side)
    if not OpsCSAR_Settings then return false end
    if side == coalition.side.RED then
        return OpsCSAR_Settings.enabledRed == true
    end
    return OpsCSAR_Settings.enabledBlue == true
end

-- "Ops.CSAR: Enable AI Pilot Rescue" (Mission Generator -> Gameplay). Also
-- spawns a downed pilot for AI ejections (not just player ejections), so there
-- is CSAR activity to fly even when no human has gone down.
local function rescueAiPilotsEnabled()
    if OpsCSAR_Settings and type(OpsCSAR_Settings.rescueAiPilots) == "boolean" then
        return OpsCSAR_Settings.rescueAiPilots
    end
    return true
end

local _uid = 7300000
local function nextId() _uid = _uid + 1; return _uid end

local function sideName(side)
    if side == coalition.side.BLUE then return "BLUE" end
    if side == coalition.side.RED then return "RED" end
    return "NEUTRAL"
end

local function sideText(side)
    return (side == coalition.side.RED) and "red" or "blue"
end

local function getCountryId(side)
    local key = (side == coalition.side.RED) and "red" or "blue"
    local c = env.mission and env.mission.coalition and env.mission.coalition[key]
    if c and c.country and c.country[1] and c.country[1].id then
        return c.country[1].id
    end
    if side == coalition.side.RED then
        return (country and country.id and country.id.CJTF_RED) or country.id.RUSSIA
    end
    return (country and country.id and country.id.CJTF_BLUE) or country.id.USA
end

local function pilotUnitType(side)
    return (side == coalition.side.RED) and "Infantry AK" or "Soldier M4"
end

local function mashUnitType(side)
    return (side == coalition.side.RED) and "Ural-375" or "M 818"
end

--------------------------------------------------------------------------------
-- SRS detection (mirrors the Airboss plugin: MOOSE auto-loads a Moose_MSRS
-- config file and sets the global MSRS_Config when SRS is available).
--------------------------------------------------------------------------------
local srs = { enabled = false, path = nil, port = 5002 }
local function detectSRS()
    if MSRS_Config then
        srs.enabled = true
        srs.path = MSRS_Config.Path or (MSRS and MSRS.path)
        srs.port = MSRS_Config.Port or (MSRS and MSRS.port) or 5002
        log("SRS: Moose_MSRS config found -> voice enabled")
    else
        log("SRS: no Moose_MSRS config -> CSAR uses text/subtitle")
    end
end

--------------------------------------------------------------------------------
-- Runtime group templates (no Mission Editor placement): register into the MOOSE
-- database so SPAWN/CSAR can resolve them. Both registrations are required --
-- _RegisterGroupTemplate() for SPAWN:_GetTemplate(), and AddGroup() so the
-- GROUP:FindByName() guard inside SPAWN:NewWithAlias()/SPAWN:New() succeeds.
--------------------------------------------------------------------------------
local function makeGroundTemplate(name, unitType, x, y)
    return {
        name = name,
        groupId = nextId(),
        task = "Ground Nothing",
        hidden = false,
        lateActivation = true,
        uncontrolled = false,
        x = x, y = y,
        start_time = 0,
        route = { points = { [1] = {
            x = x, y = y, alt = 0, alt_type = "BARO",
            type = "Turning Point", action = "Off Road",
            speed = 0, ETA = 0, ETA_locked = true, speed_locked = true,
            formation_template = "",
            task = { id = "ComboTask", params = { tasks = {} } },
        } } },
        units = { [1] = {
            name = name .. " Unit", unitId = nextId(), type = unitType, skill = "High",
            x = x, y = y, alt = 0, alt_type = "BARO", heading = 0, psi = 0, speed = 0,
        } },
    }
end

local function registerPilotTemplate(side)
    local name = "OPSCSAR_PILOT_" .. sideText(side)
    local ok, err = pcall(function()
        local tpl = makeGroundTemplate(name, pilotUnitType(side), 0, 0)
        _DATABASE:_RegisterGroupTemplate(tpl, side, Group.Category.GROUND, getCountryId(side), name)
        _DATABASE:AddGroup(name)
    end)
    if not ok then
        warn("Pilot template registration failed for " .. sideName(side) .. ": " .. tostring(err))
        return nil
    end
    return name
end

-- Iterate friendly airdromes of a coalition.
local function forEachFriendlyAirdrome(side, fn)
    for _, airbase in ipairs(world.getAirbases() or {}) do
        pcall(function()
            local desc = airbase:getDesc()
            if desc and desc.category == Airbase.Category.AIRDROME
                and airbase:getCoalition() == side then
                fn(airbase)
            end
        end)
    end
end

-- Spawn a live MASH ground group at an airfield so Ops.CSAR has a rescue point.
-- SPAWN:NewFromTemplate registers only the live spawned instance (no empty
-- coordinate-less GROUP wrapper to pollute CSAR's MASH-prefixed set).
local function spawnMashAt(airbase, side)
    local pt = airbase:getPoint()
    -- getPoint() is a Vec3: .x = north, .y = altitude, .z = east. 2D uses (x, z).
    local name = "MASH " .. airbase:getName()
    local ok, err = pcall(function()
        local tpl = makeGroundTemplate(name, mashUnitType(side), pt.x, pt.z)
        SPAWN:NewFromTemplate(tpl, name)
            :InitCountry(getCountryId(side))
            :InitCategory(Group.Category.GROUND)
            :InitCoalition(side)
            :Spawn()
    end)
    if not ok then warn("MASH spawn failed at " .. airbase:getName() .. ": " .. tostring(err)) end
end

--------------------------------------------------------------------------------
-- Per-coalition Ops.CSAR setup
--------------------------------------------------------------------------------
local services = {}

-- FlightControl's AICSAR (a separate, AI-flown rescue system) can be enabled
-- independently of Ops.CSAR. Running both for the same side isn't an error, but
-- ejections in range get a duplicate response (an AICSAR AI helo AND an
-- Ops.CSAR player slot) -- worth flagging loudly so it's not mistaken for a bug.
local function warnIfAicsarAlsoEnabled(side)
    local fc = dcsRetribution and dcsRetribution.plugins and dcsRetribution.plugins.flightcontrol
    -- Unconditional diagnostic: if the message still doesn't show, this line in
    -- dcs.log will say exactly why (plugin missing vs. option off vs. display
    -- failure below).
    log(string.format(
        "AICSAR-overlap check for %s: flightcontrol plugin present=%s, aiCsarBlue=%s, aiCsarRed=%s",
        sideName(side), tostring(fc ~= nil), tostring(fc and fc.aiCsarBlue), tostring(fc and fc.aiCsarRed)))
    if not fc then return end
    local aicsarOn = (side == coalition.side.RED) and fc.aiCsarRed or fc.aiCsarBlue
    if not aicsarOn then return end

    local msg = string.format(
        "Both AICSAR (FlightControl) and Ops.CSAR are enabled for %s -- "
        .. "ejections in range may get a duplicate rescue response.",
        sideName(side))
    warn(msg)

    -- ToAll() (not ToCoalition(side)): this is a mission-configuration notice,
    -- not coalition-sensitive tactical info, and the tester may not be on the
    -- affected side, so broadcast it to everyone in the mission.
    --
    -- Shown twice, well after mission start: a single message at t+3s (when
    -- this whole setup runs) can easily expire on the loading screen before a
    -- player has actually loaded into the cockpit. The delays below are
    -- relative to now, so the message appears at roughly t+18s and t+93s.
    for _, delay in ipairs({ 15, 90 }) do
        local ok, err = pcall(function()
            MESSAGE:New(msg, 30, "OpsCSAR"):ToAll(nil, delay)
        end)
        if not ok then
            warn("MESSAGE display (delay=" .. delay .. ") failed: " .. tostring(err))
        end
    end
end

local function setupForSide(side)
    -- Gate on the injected Gameplay setting, not on a runtime group count
    -- (unoccupied player-slot rescue helos are not live groups yet, so counting
    -- them here is unreliable -- see opsCsarEnabledForSide).
    if not opsCsarEnabledForSide(side) then
        log(sideName(side) .. ": Ops.CSAR not enabled in settings -> skipped")
        return
    end

    warnIfAicsarAlsoEnabled(side)

    local pilotTpl = registerPilotTemplate(side)
    if not pilotTpl then return end

    -- One MASH rescue point per friendly airfield.
    forEachFriendlyAirdrome(side, function(ab) spawnMashAt(ab, side) end)

    -- The player-flyable "CSAR Rescue <airfield>" slots baked in by
    -- CsarGenerator. A continuously-updating SET_GROUP (FilterStart) is
    -- correct here: these are Client slots, so they only become live groups
    -- when a player joins them, and the set picks each up via the Birth event
    -- at that point. It's expected to be empty at mission start.
    local rescueSet = SET_GROUP:New()
        :FilterCoalitions(sideText(side))
        :FilterPrefixes({ RESCUE_HELO_PREFIX })
        :FilterStart()

    local ok, err = pcall(function()
        local csar = CSAR:New(side, pilotTpl, sideName(side) .. " CSAR")
        if not csar then return end
        -- Reactive: a downed pilot spawns when an aircraft ejects; players fly a
        -- rescue helicopter to recover them. enableForAI decides whether downed
        -- AI pilots (not just players) become rescue targets.
        local enableForAI = rescueAiPilotsEnabled()
        csar.enableForAI = enableForAI
        csar:SetOwnSetPilotGroups(rescueSet)
        if srs.enabled and csar.SetSRSRadio then
            pcall(function() csar:SetSRSRadio(true, srs.path, nil, nil, srs.port) end)
        end
        -- Report recovered pilots to the campaign. The Rescued event carries
        -- only a count, and CSAR nils its per-pilot inTransitGroups records just
        -- before firing it, so capture each pilot's original unit name at Boarded
        -- (pickup) and flush them when the heli delivers them (Rescued).
        local pendingByHeli = {}
        function csar:OnAfterBoarded(From, Event, To, HeliName, WoundedGroupName, Description)
            pcall(function()
                local groups = self.inTransitGroups and self.inTransitGroups[HeliName]
                local rec = groups and groups[WoundedGroupName]
                local unit = rec and rec.originalUnit
                if unit and unit ~= "" then
                    pendingByHeli[HeliName] = pendingByHeli[HeliName] or {}
                    table.insert(pendingByHeli[HeliName], unit)
                end
            end)
        end
        function csar:OnAfterRescued(From, Event, To, HeliUnit, HeliName, PilotsSaved)
            local list = pendingByHeli[HeliName]
            pendingByHeli[HeliName] = nil
            if not list then return end
            for _, unit in ipairs(list) do emitRescuedUnit(unit) end
        end

        csar:Start()
        services[side] = csar
        -- rescueSet:Count() is typically 0 here: player rescue slots become
        -- live only as players join them; the set fills in via Birth events.
        log(string.format("Ops.CSAR started for %s (rescue helos join dynamically; "
            .. "%d live now, enableForAI=%s)",
            sideName(side), rescueSet:Count(), tostring(enableForAI)))
    end)
    if not ok then warn("Ops.CSAR setup failed for " .. sideName(side) .. ": " .. tostring(err)) end
end

local function run()
    if not (AIRBASE and SPAWN and GROUP and SET_GROUP and CSAR and _DATABASE) then
        warn("MOOSE not ready (missing required classes); aborting Ops.CSAR setup")
        return
    end
    log("=== Ops.CSAR starting ===")
    detectSRS()
    setupForSide(coalition.side.BLUE)
    setupForSide(coalition.side.RED)
    log("=== Ops.CSAR setup complete ===")
end

-- Defer so the MOOSE database and mission groups (rescue-helo slots) are fully
-- registered before we query and start CSAR.
timer.scheduleFunction(function()
    local ok, err = pcall(run)
    if not ok then warn("run() error: " .. tostring(err)) end
end, nil, timer.getTime() + 3)

env.info("[OpsCSAR] OpsCSAR.lua loaded; setup scheduled")
