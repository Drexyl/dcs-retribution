-- ctld_config_test.lua
--
-- Standalone unit test for resources/plugins/ctld/ctld-config.lua under a
-- mocked DCS/MOOSE environment. Run by tests/missiongenerator/
-- test_lua_plugin_scripts.py (through lupa), or locally with:
--
--   lua tests/missiongenerator/ctld_config_test.lua

local SCRIPT = "resources/plugins/ctld/ctld-config.lua"

local passed = 0
local function check(cond, label)
    if not cond then
        error("FAILED: " .. label, 2)
    end
    passed = passed + 1
end

-- Mock state, reset by setup().
local ctlds        -- CTLD instances by coalition name
local timers       -- every TIMER started: { fn, delay, interval }
local event_handlers
local units        -- unit name -> mocked MOOSE UNIT
local dcs_units    -- unit name -> mocked DCS unit (carriers)
local dcs_groups   -- group name -> mocked DCS group (JTACs)
local smokes       -- zone names smoked
local autolases
local errors
local spawns       -- groups spawned through SPAWN

-- Ground height under every mocked unit.
local GROUND = 100

local function mock_coordinate(x, y, z)
    local coordinate = { x = x, y = y, z = z }
    function coordinate:GetLandHeight() return GROUND end
    function coordinate:GetVec2() return { x = self.x, y = self.z } end
    function coordinate:Translate(distance, angle)
        local a = math.rad(angle)
        return mock_coordinate(self.x + distance * math.cos(a), self.y, self.z + distance * math.sin(a))
    end
    return coordinate
end

local function mock_cargo(cargo_type, templates)
    local cargo = { cargo_type = cargo_type, templates = templates, dropped = false }
    function cargo:GetType() return self.cargo_type end
    function cargo:GetTemplates() return self.templates end
    function cargo:WasDropped() return self.dropped end
    function cargo:SetWasDropped(dropped) self.dropped = dropped end
    return cargo
end

local function mock_unit(name, type_name, options)
    options = options or {}
    local unit = {
        name = name,
        type_name = type_name,
        alive = options.alive ~= false,
        player = options.player or false,
        in_air = options.in_air or false,
        agl = options.agl or 0,
        zones = options.zones or {},
        -- Trigger zones the unit is in, by name.
        in_zones = options.in_zones or {},
        heading = options.heading or 0,
    }
    function unit:GetName() return self.name end
    function unit:GetTypeName() return self.type_name end
    function unit:IsAlive() return self.alive end
    function unit:IsPlayer() return self.player end
    function unit:InAir() return self.in_air end
    function unit:GetGroup() return { unit_name = self.name } end
    function unit:GetHeading() return self.heading end
    function unit:GetCoordinate() return mock_coordinate(1000, GROUND + self.agl, 2000) end
    function unit:IsInZone(zone) return self.in_zones[zone.name] == true end
    units[name] = unit
    return unit
end

local function new_ctld(side)
    local ctld = {
        side = side,
        zones = {},
        pickupZones = {},
        dropOffZones = {},
        troop_cargo = {},
        crate_cargo = {},
        capabilities = {},
        fixed_wing = {},
        Loaded_Cargo = {},
        loads = {},
        unloads = {},
        preloads = {},
        injected = {},
        mass_updates = {},
        deployed = {},
        CargoCounter = 0,
        TroopCounter = 0,
        DroppedTroops = {},
        coalition = side == "blue" and 2 or 1,
        basetype = "container_cargo",
        started = false,
    }
    function ctld:SetOwnSetPilotGroups(set) self.pilot_set = set return self end
    function ctld:AddCTLDZone(name, zone_type, color, active, beacon, length, width)
        local zone = { name = name, type = zone_type, color = color, active = active, length = length, width = width }
        table.insert(self.zones, zone)
        if zone_type == CTLD.CargoZoneType.LOAD then table.insert(self.pickupZones, zone) end
        if zone_type == CTLD.CargoZoneType.DROP then table.insert(self.dropOffZones, zone) end
        return self
    end
    function ctld:SetUnitCapabilities(unit_type, crates, troops, cratelimit, trooplimit, length, weight)
        self.capabilities[unit_type] = {
            crates = crates, troops = troops, cratelimit = cratelimit,
            trooplimit = trooplimit, length = length, cargoweightlimit = weight,
        }
        return self
    end
    function ctld:AddAllowedFixedWingType(unit_type) self.fixed_wing[unit_type] = true return self end
    function ctld:AddTroopsCargo(name, templates, cargo_type, troops, mass)
        table.insert(self.troop_cargo, { Name = name, Templates = templates, troops = troops, mass = mass,
            GetName = function(c) return c.Name end })
        return self
    end
    function ctld:AddCratesCargo(name, templates, cargo_type, crates, mass)
        table.insert(self.crate_cargo, { Name = name, Templates = templates, crates = crates, mass = mass })
        return self
    end
    function ctld:Start() self.started = true return self end
    function ctld:_GetUnitCapabilities(unit)
        return self.capabilities[unit:GetTypeName()] or { troops = false, trooplimit = 0, cargoweightlimit = 0 }
    end
    function ctld:_FindTroopsCargoObject(name)
        for _, cargo in ipairs(self.troop_cargo) do
            if cargo.Name == name then return cargo end
        end
    end
    function ctld:_FindCratesCargoObject(name)
        for _, cargo in ipairs(self.crate_cargo) do
            if cargo.Name == name then return cargo end
        end
    end
    function ctld:IsUnitInZone(unit, zone_type) return unit.zones[zone_type] == true end
    function ctld:IsUnitInAir(unit) return unit.agl >= 4 end
    function ctld:PreloadTroops(unit, name)
        table.insert(self.preloads, { unit = unit:GetName(), cargo = name })
        self.Loaded_Cargo[unit:GetName()] = { Troopsloaded = 1 }
    end
    function ctld:_LoadTroops(group, unit, cargo, inject)
        table.insert(self.loads, { unit = unit:GetName(), cargo = cargo.Name, inject = inject })
        self.Loaded_Cargo[unit:GetName()] = { Troopsloaded = cargo.troops }
    end
    function ctld:_UnloadTroops(group, unit)
        table.insert(self.unloads, unit:GetName())
        self.Loaded_Cargo[unit:GetName()] = { Troopsloaded = 0 }
    end
    function ctld:_UpdateUnitCargoMass(unit) table.insert(self.mass_updates, unit:GetName()) return self end
    function ctld:__TroopsDeployed(delay, group, unit, troops, cargo_type)
        table.insert(self.deployed, { group = group, unit = unit, troops = troops, cargo_type = cargo_type })
    end
    function ctld:InjectStatics(zone, cargo, random)
        table.insert(self.injected, { zone = zone.name, cargo = cargo })
    end
    return ctld
end

local function setup(options, data)
    ctlds, timers, event_handlers, units, dcs_units, dcs_groups = {}, {}, {}, {}, {}, {}
    smokes, autolases, errors, spawns = {}, {}, {}, {}
    RetributionCTLD = nil

    env = {
        info = function() end,
        warning = function(m) table.insert(errors, m) end,
        error = function(m) table.insert(errors, m) end,
    }
    world = {
        event = { S_EVENT_BIRTH = 15 },
        addEventHandler = function(handler) table.insert(event_handlers, handler) end,
    }
    Unit = { getByName = function(name) return dcs_units[name] end }
    Group = { getByName = function(name) return dcs_groups[name] end }
    SMOKECOLOR = { Green = 0, Red = 1, White = 2, Orange = 3, Blue = 4 }

    CTLD = {
        CargoZoneType = { LOAD = "load", DROP = "drop", MOVE = "move", SHIP = "ship" },
        UnitTypeCapabilities = {
            ["UH-1H"] = { cratelimit = 1, trooplimit = 8, length = 15, cargoweightlimit = 700 },
        },
    }
    function CTLD:New(side, prefixes, alias)
        local ctld = new_ctld(side)
        ctlds[side] = ctld
        return ctld
    end
    CTLD_CARGO = { Enum = { TROOPS = "Troops", VEHICLE = "Vehicle" } }
    function CTLD_CARGO:New(id, name, templates, cargo_type, moved, direct, crates, pos, dropped, mass)
        local cargo = { ID = id, Name = name, Templates = templates, CargoType = cargo_type, mass = mass }
        function cargo:SetStaticTypeAndShape(category, type_name) self.static = { category, type_name } end
        return cargo
    end

    SET_GROUP = {}
    function SET_GROUP:New()
        local set = { groups = {} }
        function set:FilterCoalitions(side) self.side = side return self end
        function set:FilterFunction(fn) self.filter = fn return self end
        function set:FilterStart() return self end
        function set:AddGroupsByName(name) table.insert(self.groups, name) return self end
        return set
    end
    TIMER = {}
    function TIMER:New(fn)
        local timer_object = { fn = fn }
        function timer_object:Start(delay, interval)
            self.delay, self.interval = delay, interval
            table.insert(timers, self)
            return self
        end
        return timer_object
    end
    UNIT = { FindByName = function(_, name) return units[name] end }
    -- Troop templates hold as many soldiers as their name says, e.g. "CTLD Blue Troops (24)".
    _DATABASE = {
        GetGroupTemplate = function(_, name)
            local count = tonumber(name:match("%((%d+)%)"))
            if not count then return nil end
            local template_units = {}
            for i = 1, count do template_units[i] = { name = name .. " #" .. i } end
            return { units = template_units }
        end,
    }
    SPAWN = {}
    function SPAWN:NewWithAlias(template, alias)
        local spawn = { template = template, alias = alias }
        function spawn:InitDelayOff() return self end
        function spawn:InitCoalition(coalition) self.coalition = coalition return self end
        function spawn:InitSetUnitAbsolutePositions(positions) self.positions = positions return self end
        function spawn:InitValidateAndRepositionGroundUnits() return self end
        function spawn:SpawnFromVec2(vec2)
            self.vec2 = vec2
            table.insert(spawns, self)
            return { spawn = self }
        end
        return spawn
    end
    ZONE = {
        FindByName = function(_, name)
            return {
                name = name,
                GetCoordinate = function()
                    return { Smoke = function(_, color) table.insert(smokes, { zone = name, color = color }) end }
                end,
            }
        end,
    }
    AUTOLASE = {}
    function AUTOLASE:New(recce, side, alias)
        local autolase = { recce = recce, side = side, codes = {} }
        function autolase:SetLasingParameters(distance, duration) self.distance = distance return self end
        function autolase:SetLaserCoolDown(on) self.cooldown = on return self end
        function autolase:SetMaxLasingTargets(n) self.max = n return self end
        function autolase:SetSmokeTargets(on) self.smoke = on return self end
        function autolase:SetRecceLaserCode(unit, code) self.codes[unit] = code return self end
        table.insert(autolases, autolase)
        return autolase
    end

    local plugin_options = {
        debug = false, slingload = false, smoke = true, airliftcrates = true,
        autolase = true, jtacsmoke = true, fc3LaserCode = false, logisticunit = true,
    }
    for key, value in pairs(options or {}) do
        plugin_options[key] = value
    end

    dcsRetribution = data or {
        plugins = {},
        Carriers = { { unit_name = "CVN-74", dcsGroupName = "Carrier" } },
        JTACs = {
            { dcsGroupName = "JTAC 1", dcsUnit = "JTAC 1 Unit", laserCode = "1688" },
            { dcsGroupName = "JTAC 2", dcsUnit = "JTAC 2 Unit", laserCode = "1687" },
        },
        Logistics = {
            flights = {
                {
                    pilot_names = { "Huey 1", "Huey 2" }, group_name = "Huey group",
                    pickup_zone = "Huey pickup", drop_off_zone = "Huey dropoff",
                    target_zone = "Huey target", side = "2", aircraft_type = "UH-1H", preload = "false",
                },
                {
                    pilot_names = { "Herc 1" }, group_name = "Herc group",
                    target_zone = "Herc target", side = "2", aircraft_type = "Hercules", preload = "true",
                },
                {
                    pilot_names = { "C-130J 1" }, group_name = "C-130J group",
                    target_zone = "C-130J target", side = "2", aircraft_type = "C-130J-30", preload = "true",
                },
                {
                    pilot_names = { "Hip 1" }, group_name = "Hip group",
                    pickup_zone = "Hip pickup", drop_off_zone = "Hip dropoff",
                    side = "1", aircraft_type = "Mi-8MT", preload = "false",
                },
            },
            transports = {
                { aircraft_type = "UH-1H", cabin_size = "8", troops = "true", crates = "true", helicopter = "true" },
                { aircraft_type = "Hercules", cabin_size = "24", troops = "true", crates = "true", helicopter = "false" },
                { aircraft_type = "C-130J-30", cabin_size = "24", troops = "true", crates = "true", helicopter = "false" },
                { aircraft_type = "Mi-8MT", cabin_size = "12", troops = "true", crates = "false", helicopter = "true" },
            },
            troop_templates = {
                { side = "2", name = "Retribution Troops (6)", template = "CTLD Blue Troops (6)", troops = "6" },
                { side = "2", name = "Retribution Troops (2)", template = "CTLD Blue Troops (2)", troops = "2" },
                { side = "2", name = "Retribution Troops (24)", template = "CTLD Blue Troops (24)", troops = "24" },
                { side = "2", name = "Retribution Troops (10)", template = "CTLD Blue Troops (10)", troops = "10" },
                { side = "1", name = "Retribution Troops (12)", template = "CTLD Red Troops (12)", troops = "12" },
            },
            crate_templates = {
                { side = "2", unit = "M-113", template = "CTLD Blue M-113" },
            },
            crates = {
                { side = "2", unit = "M-113", zone = "crate zone" },
                { side = "2", unit = "M-113", zone = "crate zone" },
                { side = "2", unit = "Unknown", zone = "crate zone" },
            },
        },
    }
    dcsRetribution.plugins.ctld = plugin_options

    dcs_units["CVN-74"] = { getCoalition = function() return 2 end }
    dcs_groups["JTAC 1"] = { getCoalition = function() return 2 end }
    dcs_groups["JTAC 2"] = { getCoalition = function() return 2 end }

    dofile(SCRIPT)
end

local function timers_with(delay, interval)
    local found = {}
    for _, t in ipairs(timers) do
        if t.delay == delay and t.interval == interval then
            table.insert(found, t)
        end
    end
    return found
end

local function run_ai_check()
    local ai = timers_with(2, 2)
    check(#ai == 1, "one repeating AI transport timer")
    ai[1].fn()
end

-- Scenarios ---------------------------------------------------------------------

local function test_one_instance_per_coalition_with_flights()
    setup()
    check(ctlds.blue and ctlds.red, "an instance for blue and red")
    check(ctlds.blue.started and ctlds.red.started, "instances started")
    check(RetributionCTLD.instances[2] ~= nil and RetributionCTLD.instances[1] ~= nil, "instances exported")
    local set = ctlds.blue.pilot_set
    check(set.side == "blue", "pilot set filtered by coalition")
    check(set.filter({ GetName = function() return "Huey group" end }) == true, "own transport group gets menus")
    check(set.filter({ GetName = function() return "Hip group" end }) == false, "other coalition's group excluded")
    check(set.filter({ GetName = function() return "Viper group" end }) == false, "non-transport group excluded")
end

local function test_zones()
    setup()
    local by_name = {}
    for _, zone in ipairs(ctlds.blue.zones) do
        by_name[zone.name] = zone
    end
    check(by_name["Huey pickup"].type == "load" and by_name["Huey pickup"].active, "pickup zone is an active load zone")
    check(by_name["Huey dropoff"].type == "drop", "drop-off zone")
    check(by_name["Huey target"].type == "move", "target zone is a move zone")
    check(by_name["Herc target"].type == "move", "fixed-wing target zone")
    check(by_name["CVN-74"].type == "ship" and by_name["CVN-74"].length == 300, "carrier is a ship zone")
    for _, zone in ipairs(ctlds.red.zones) do
        check(zone.name ~= "CVN-74", "carrier not added to the other coalition")
    end
end

local function test_capabilities()
    setup()
    local huey = ctlds.blue.capabilities["UH-1H"]
    check(huey.troops and huey.crates and huey.trooplimit == 8, "Huey troop capacity from Retribution")
    check(huey.cratelimit == 1 and huey.length == 15, "Huey keeps MOOSE's crate limit and length")
    check(huey.cargoweightlimit >= 800, "a full Huey cabin of troops fits the mass limit")
    local herc = ctlds.blue.capabilities["Hercules"]
    check(herc.trooplimit == 24 and herc.cratelimit == 1, "unknown types get one crate")
    check(ctlds.blue.enableFixedWing == true and ctlds.blue.fixed_wing["Hercules"], "fixed-wing transport allowed")
    local hip = ctlds.red.capabilities["Mi-8MT"]
    check(hip.crates == false and hip.cratelimit == 0, "no crates when Retribution says so")
    check(ctlds.red.enableFixedWing == nil, "no fixed wing for red")
end

local function test_cargo_registration()
    setup()
    check(#ctlds.blue.troop_cargo == 4 and #ctlds.red.troop_cargo == 1, "troop cargo per coalition")
    local cargo = ctlds.blue.troop_cargo[1]
    check(cargo.Templates[1] == "CTLD Blue Troops (6)" and cargo.troops == 6 and cargo.mass == 100, "troop cargo fields")
    check(#ctlds.blue.crate_cargo == 1 and #ctlds.red.crate_cargo == 0, "crate cargo per coalition")
    check(ctlds.blue.crate_cargo[1].Name == "M-113" and ctlds.blue.crate_cargo[1].crates == 1, "one crate per vehicle")
    check(ctlds.blue.dropcratesanywhere == true, "crates can be unpacked anywhere")
end

local function test_ai_loads_in_pickup_zone_and_unloads_in_dropoff()
    setup()
    local huey = mock_unit("Huey 1", "UH-1H", { zones = { load = true } })
    run_ai_check()
    check(#ctlds.blue.loads == 1, "AI loads troops in the pickup zone")
    check(ctlds.blue.loads[1].cargo == "Retribution Troops (6)", "largest troop cargo that fits 8 seats")
    check(ctlds.blue.loads[1].inject == true, "loaded without menu checks")

    run_ai_check()
    check(#ctlds.blue.loads == 1, "no second load while troops are on board")

    huey.zones = { drop = true }
    huey.in_air = true
    huey.agl = 50
    run_ai_check()
    check(#ctlds.blue.unloads == 0, "no unload while airborne")

    huey.in_air = false
    huey.agl = 0
    run_ai_check()
    check(#ctlds.blue.unloads == 1 and ctlds.blue.unloads[1] == "Huey 1", "AI unloads after landing in the drop-off zone")
end

local function test_ai_on_carrier_and_inair_bug()
    setup()
    -- On deck: InAir false, but 20 m above the sea.
    mock_unit("Huey 1", "UH-1H", { zones = { ship = true }, agl = 20 })
    -- On the ground, but reporting InAir (CH-47F style).
    mock_unit("Huey 2", "UH-1H", { zones = { load = true }, in_air = true, agl = 0.5 })
    run_ai_check()
    check(#ctlds.blue.loads == 2, "loads on a carrier deck and despite a wrong InAir")
end

local function test_players_and_dead_units_ignored()
    setup()
    mock_unit("Huey 1", "UH-1H", { zones = { load = true }, player = true })
    mock_unit("Huey 2", "UH-1H", { zones = { load = true }, alive = false })
    run_ai_check()
    check(#ctlds.blue.loads == 0, "players and dead units are not serviced")
end

local function loaded_troops(unit_name, ctld)
    local troops = mock_cargo("Troops", { "CTLD Blue Troops (24)" })
    local crate = mock_cargo("Vehicle", { "CTLD Blue M-113" })
    ctld.Loaded_Cargo[unit_name] = { Troopsloaded = 24, Cratesloaded = 1, Cargo = { troops, crate } }
    return troops, crate
end

local function test_fixed_wing_paradrop()
    setup()
    local ctld = ctlds.blue
    local c130 = mock_unit("C-130J 1", "C-130J-30", { in_air = true, agl = 300, heading = 90 })
    local troops, crate = loaded_troops("C-130J 1", ctld)

    run_ai_check()
    check(troops.dropped == false and #timers_with(60, nil) == 0, "no drop before the target zone")

    c130.in_zones = { ["C-130J target"] = true }
    run_ai_check()
    check(troops.dropped == true, "troops jump over the target zone")
    check(#ctld.unloads == 0, "MOOSE's own unload is not used")
    local loaded = ctld.Loaded_Cargo["C-130J 1"]
    check(loaded.Troopsloaded == 0 and loaded.Cratesloaded == 1 and loaded.Cargo[1] == crate, "crates stay on board")
    check(ctld.mass_updates[1] == "C-130J 1", "cargo mass updated")
    local landing = timers_with(60, nil)
    check(#landing == 1, "troops land after descending 300 m at 5 m/s")
    check(#spawns == 0, "nobody on the ground while under canopy")

    run_ai_check()
    check(#timers_with(60, nil) == 1, "no second drop")

    landing[1].fn()
    check(#spawns == 1, "the troop group spawns on landing")
    local spawn = spawns[1]
    check(spawn.template == "CTLD Blue Troops (24)" and spawn.coalition == 2, "spawned from the template")
    check(#spawn.positions == 24, "every paratrooper placed")
    local first, last = spawn.positions[1], spawn.positions[24]
    check(math.abs(last.y - first.y - 23 * 15) < 0.01 and math.abs(first.x - last.x) < 0.01, "strung out along the track")
    check(math.abs((first.y + last.y) / 2 - 2000) < 0.01, "centred on the drop point")
    check(first.heading == 90, "facing the aircraft's heading")
    check(ctld.TroopCounter == 1 and ctld.DroppedTroops[1] ~= nil, "CTLD tracks the dropped troops")
    check(#ctld.deployed == 1 and ctld.deployed[1].cargo_type == "Troops", "CTLD moves them into the target zone")
end

local function test_paradrop_exclusions()
    setup()
    local ctld = ctlds.blue
    -- The Anubis Hercules drops paratroopers from its loadout.
    mock_unit("Herc 1", "Hercules", { in_air = true, agl = 300, in_zones = { ["Herc target"] = true } })
    local herc_troops = loaded_troops("Herc 1", ctld)
    -- A landed C-130J does not parachute anyone.
    mock_unit("C-130J 1", "C-130J-30", { in_zones = { ["C-130J target"] = true } })
    local c130_troops = loaded_troops("C-130J 1", ctld)
    -- Helicopters land to unload.
    mock_unit("Huey 1", "UH-1H", { in_air = true, agl = 300, in_zones = { ["Huey target"] = true } })
    local huey_troops = loaded_troops("Huey 1", ctld)
    run_ai_check()
    check(not herc_troops.dropped and not c130_troops.dropped and not huey_troops.dropped, "nobody jumps")
    check(#ctld.unloads == 0, "nobody unloads")

    setup()
    mock_unit("C-130J 1", "C-130J-30", { in_air = true, agl = 300, in_zones = { ["C-130J target"] = true }, player = true })
    local player_troops = loaded_troops("C-130J 1", ctlds.blue)
    run_ai_check()
    check(not player_troops.dropped, "players drop their own troops")
end

local function test_preload()
    setup()
    local preload_timers = timers_with(5, nil)
    check(#preload_timers == 1, "one preload timer")
    preload_timers[1].fn()
    check(#ctlds.blue.preloads == 0, "unit not yet spawned")

    mock_unit("Herc 1", "Hercules")
    check(#event_handlers == 1, "birth handler registered")
    event_handlers[1]:onEvent({ id = 15, initiator = { getName = function() return "Herc 1" end } })
    local birth_timers = timers_with(5, nil)
    check(#birth_timers == 2, "preload scheduled after birth")
    birth_timers[2].fn()
    check(#ctlds.blue.preloads == 1, "preloaded once alive")
    check(ctlds.blue.preloads[1].cargo == "Retribution Troops (24)", "fills the 24-seat cabin")

    event_handlers[1]:onEvent({ id = 15, initiator = { getName = function() return "Herc 1" end } })
    check(#timers_with(5, nil) == 2, "no second preload")
    event_handlers[1]:onEvent({ id = 15, initiator = { getName = function() return "Huey 1" end } })
    check(#timers_with(5, nil) == 2, "units without preload ignored")
end

local function test_airlift_crates()
    setup()
    local crate_timers = timers_with(3, nil)
    check(#crate_timers == 1, "crate timer")
    crate_timers[1].fn()
    local injected = ctlds.blue.injected
    check(#injected == 2, "a crate per known cargo")
    check(injected[1].zone == "crate zone" and injected[1].cargo.Name == "M-113", "crate in its zone")
    check(injected[1].cargo ~= injected[2].cargo, "each crate has its own cargo object")
    check(injected[1].cargo.ID ~= injected[2].cargo.ID, "cargo ids are unique")
    check(injected[1].cargo.mass == 500 and injected[1].cargo.CargoType == "Vehicle", "vehicle crate mass")
    check(#errors == 1, "unknown crate reported")
end

local function test_options_off()
    setup({ airliftcrates = false, smoke = false, autolase = false })
    check(#timers_with(3, nil) == 0, "no crate spawning")
    check(#timers_with(1, 290) == 0, "no zone smoke")
    check(#autolases == 0, "no autolase")
end

local function test_zone_smoke()
    setup()
    local smoke_timers = timers_with(1, 290)
    check(#smoke_timers == 1, "repeating zone smoke")
    smoke_timers[1].fn()
    local smoked = {}
    for _, s in ipairs(smokes) do
        smoked[s.zone] = s.color
    end
    check(smoked["Huey pickup"] == SMOKECOLOR.Blue, "pickup smoked blue")
    check(smoked["Huey dropoff"] == SMOKECOLOR.Green, "drop-off smoked green")
    check(smoked["Huey target"] == nil, "target zones not smoked")
end

local function test_autolase()
    setup()
    check(#autolases == 1, "one autolase for blue")
    local autolase = autolases[1]
    check(autolase.side == "blue" and #autolase.recce.groups == 2, "both JTACs are recce")
    check(autolase.codes["JTAC 1 Unit"] == 1688 and autolase.codes["JTAC 2 Unit"] == 1687, "Retribution laser codes")
    check(autolase.smoke == true and autolase.cooldown == false and autolase.max == 2, "autolase settings")

    setup({ fc3LaserCode = true, jtacsmoke = false })
    check(autolases[1].codes["JTAC 1 Unit"] == 1113, "FC3 laser code")
    check(autolases[1].smoke == nil, "no target smoke")
end

local function test_without_retribution_data()
    ctlds = {}
    dcsRetribution = nil
    dofile(SCRIPT)
    check(next(ctlds) == nil, "nothing set up without Retribution data")
end

local tests = {
    test_one_instance_per_coalition_with_flights,
    test_zones,
    test_capabilities,
    test_cargo_registration,
    test_ai_loads_in_pickup_zone_and_unloads_in_dropoff,
    test_ai_on_carrier_and_inair_bug,
    test_players_and_dead_units_ignored,
    test_fixed_wing_paradrop,
    test_paradrop_exclusions,
    test_preload,
    test_airlift_crates,
    test_options_off,
    test_zone_smoke,
    test_autolase,
    test_without_retribution_data,
}

for _, t in ipairs(tests) do
    t()
end

print(string.format("ok - %d assertions across %d scenarios", passed, #tests))
