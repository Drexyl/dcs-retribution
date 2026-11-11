-- retribution_utils_test.lua
--
-- Standalone unit test for resources/plugins/base/retribution_utils.lua under a
-- mocked DCS/MOOSE environment. Run by tests/missiongenerator/
-- test_lua_plugin_scripts.py (through lupa), or locally with:
--
--   lua    tests/missiongenerator/retribution_utils_test.lua
--   luajit tests/missiongenerator/retribution_utils_test.lua

local SCRIPT = "resources/plugins/base/retribution_utils.lua"

local SURF = { LAND = 1, SHALLOW_WATER = 2, WATER = 3, ROAD = 4, RUNWAY = 5 }

-- Test state, reset by setup().
local added_groups   -- { country, category, data } per coalition.addGroup call
local added_statics  -- { country, data } per coalition.addStaticObject call
local db_spawns      -- templates passed to _DATABASE:Spawn
local live_groups    -- name -> mocked DCS group
local coalition_groups -- side -> category -> list of mocked DCS groups
local surface_fn
local errors, warnings
local now

local function deep_copy(object)
    if type(object) ~= "table" then
        return object
    end
    local copy = {}
    for key, value in pairs(object) do
        copy[deep_copy(key)] = deep_copy(value)
    end
    return copy
end

local function mock_unit(name, x, z, alt, type_name)
    return {
        getName = function()
            return name
        end,
        getTypeName = function()
            return type_name or "T-72B"
        end,
        getPosition = function()
            return {
                p = { x = x, y = alt or 0, z = z },
                x = { x = 0, y = 0, z = 1 }, -- facing east
            }
        end,
        getPoint = function()
            return { x = x, y = alt or 0, z = z }
        end,
        getVelocity = function()
            return { x = 3, y = 0, z = 4 }
        end,
        isExist = function()
            return true
        end,
        getGroup = function()
            return nil
        end,
    }
end

local function mock_group(name, units, id)
    return {
        getName = function()
            return name
        end,
        getID = function()
            return id
        end,
        getUnits = function()
            return units
        end,
        isExist = function()
            return true
        end,
    }
end

local function setup()
    added_groups, added_statics, db_spawns = {}, {}, {}
    live_groups, coalition_groups = {}, {}
    errors, warnings = {}, {}
    now = 100
    surface_fn = function()
        return SURF.LAND
    end

    env = {
        info = function() end,
        warning = function(message)
            warnings[#warnings + 1] = message
        end,
        error = function(message)
            errors[#errors + 1] = message
        end,
    }
    land = {
        SurfaceType = SURF,
        getSurfaceType = function(point)
            return surface_fn(point.x, point.y)
        end,
        getHeight = function()
            return 50
        end,
    }
    country = { id = { USA = 2, RUSSIA = 0, CJTF_BLUE = 80 } }
    coalition = {
        side = { NEUTRAL = 0, RED = 1, BLUE = 2 },
        getCountryCoalition = function(id)
            return id == 0 and 1 or 2
        end,
        addGroup = function(country_id, category_id, data)
            added_groups[#added_groups + 1] =
                { country = country_id, category = category_id, data = data }
        end,
        addStaticObject = function(country_id, data)
            added_statics[#added_statics + 1] = { country = country_id, data = data }
        end,
        getGroups = function(side, category)
            local by_category = coalition_groups[side] or {}
            if category then
                return by_category[category] or {}
            end
            local all = {}
            for _, groups in pairs(by_category) do
                for _, group in ipairs(groups) do
                    all[#all + 1] = group
                end
            end
            return all
        end,
    }
    Group = {
        Category = { AIRPLANE = 0, HELICOPTER = 1, GROUND = 2, SHIP = 3, TRAIN = 4 },
        getByName = function(name)
            return live_groups[name]
        end,
    }
    timer = {
        getTime = function()
            return now
        end,
        getAbsTime = function()
            return 28800 + now
        end,
        getTime0 = function()
            return 28800
        end,
    }

    UTILS = {
        DeepCopy = deep_copy,
        Round = function(num, idp)
            local mult = 10 ^ (idp or 0)
            return math.floor(num * mult + 0.5) / mult
        end,
        VecNorm = function(v)
            return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
        end,
        MpsToKmph = function(mps)
            return mps * 3.6
        end,
        Vec2toVec3 = function(vec, y)
            if not vec.z then
                return { x = vec.x, y = y or 0, z = vec.y }
            end
            return { x = vec.x, y = vec.y, z = vec.z }
        end,
        Vec3toVec2 = function(vec)
            return { x = vec.x, y = vec.z }
        end,
    }
    COORDINATE = {
        NewFromVec2 = function(_, vec2)
            return {
                WaypointGround = function(_, speed_kmh, formation)
                    return {
                        x = vec2.x,
                        y = vec2.y,
                        action = formation,
                        speed = speed_kmh / 3.6,
                        type = "Turning Point",
                    }
                end,
            }
        end,
    }
    -- Mirrors the parts of MOOSE's TIMER that matter here: _Function returns the
    -- next call time for a repeating timer (which makes DCS call it again) unless
    -- the timer has no interval, and Stop() only removes the pending DCS timer.
    TIMER = {}
    TIMER.__index = TIMER
    function TIMER:New(fn, ...)
        return setmetatable({ func = fn, para = { ... }, stops = 0 }, TIMER)
    end
    function TIMER:Start(_, interval)
        self.dT = interval
        return self
    end
    function TIMER:Stop()
        self.stops = self.stops + 1
        return self
    end
    function TIMER:_Function(time)
        self.func(unpack(self.para))
        if self.dT == nil then
            self:Stop()
            return nil
        end
        return time + self.dT
    end
    _DATABASE = {
        Templates = { Groups = {}, Units = {} },
        Spawn = function(_, template)
            db_spawns[#db_spawns + 1] = template
        end,
        AddGroup = function() end,
        AddUnit = function() end,
        AddStatic = function() end,
    }

    RetUtils = nil
    assert(loadfile(SCRIPT))()
end

-- Registers a mission template the way MOOSE stores it.
local function add_template(name, category_id, country_id, template)
    template.name = name
    _DATABASE.Templates.Groups[name] = {
        GroupName = name,
        Template = template,
        groupId = template.groupId,
        CategoryID = category_id,
        CountryID = country_id,
        CoalitionID = coalition.getCountryCoalition(country_id),
    }
end

-- Assertions ------------------------------------------------------------------

local passed = 0
local function check(cond, label)
    if not cond then
        error("FAIL: " .. label, 2)
    end
    passed = passed + 1
end

local function near(a, b)
    return math.abs(a - b) < 1e-6
end

-- Scenarios -------------------------------------------------------------------

local function test_spawn_group_fills_defaults()
    setup()
    local source = {
        country = "usa",
        category = "vehicle",
        name = "Convoy",
        units = {
            { type = "M-113", x = 10, y = 20, unitName = "Convoy lead" },
            { type = "M-113", x = 15, y = 25 },
        },
    }
    local result = RetUtils.spawnGroup(source)

    check(#db_spawns == 1, "group spawned through the MOOSE database")
    local group = db_spawns[1]
    check(result == group and result.name == "Convoy", "returns the spawned table with its name")
    check(group.CountryID == 2 and group.CategoryID == 2, "country and category resolved")
    check(group.CoalitionID == 2, "coalition derived from the country")
    check(group.country == nil and group.category == nil, "helper-only fields removed")
    check(group.units[1].name == "Convoy lead", "unitName mapped to name")
    check(group.units[1].unitName == nil, "unitName removed")
    check(group.units[2].name == "Convoy unit2", "missing unit name generated")
    check(group.units[1].skill == "Random", "default skill")
    check(group.units[1].playerCanDrive == true, "ground units drivable by default")
    check(group.route.points ~= nil, "route always has a points table")
    check(group.start_time == 0, "start time defaults to 0")
    check(source.country == "usa" and source.units[1].unitName == "Convoy lead", "input not mutated")
end

local function test_spawn_group_enum_inputs_and_route_array()
    setup()
    RetUtils.spawnGroup({
        countryId = 0,
        category = Group.Category.HELICOPTER,
        units = { { type = "Mi-8MT", x = 0, y = 0 } },
        route = { { x = 1, y = 2 }, { x = 3, y = 4 } },
    })
    local group = db_spawns[1]
    check(group.CountryID == 0 and group.CategoryID == 1, "numeric country and category accepted")
    check(type(group.name) == "string" and #group.name > 0, "group name generated")
    check(#group.route.points == 2, "bare waypoint array wrapped into points")
    check(group.units[1].alt == 500 and group.units[1].alt_type == "RADIO", "helicopter defaults")
    check(group.units[1].speed == 60, "helicopter default speed")
end

local function test_spawn_group_rejects_unknown_country()
    setup()
    local result = RetUtils.spawnGroup({
        country = "atlantis",
        category = "vehicle",
        units = { { type = "M-113", x = 0, y = 0 } },
    })
    check(result == nil, "unknown country returns nil")
    check(#db_spawns == 0 and #errors == 1, "nothing spawned, error logged")
end

local function test_spawn_static_cargo()
    setup()
    local result = RetUtils.spawnStatic({
        country = "USA",
        category = "Fortifications",
        type = "GeneratorF",
        shape_name = "GeneratorF",
        x = 5,
        y = 6,
        mass = 500,
        name = "Crate #1",
        heading = 0,
    })
    check(#added_statics == 1, "static added")
    local static = added_statics[1].data
    check(added_statics[1].country == 2, "country resolved")
    check(result == static and static.name == "Crate #1", "returns the spawned table")
    check(static.category == "Cargos", "an object with mass is spawned as cargo")
    check(static.dead == false and static.country == nil, "defaults filled, helper field removed")
end

local function test_spawn_static_requires_position()
    setup()
    local result = RetUtils.spawnStatic({ country = "USA", type = "outpost", name = "FOB" })
    check(result == nil and #added_statics == 0, "static without x/y is not spawned")
end

local function test_get_unit_names_filters()
    setup()
    local tank = mock_group("Tanks", { mock_unit("Tank-1", 0, 0), mock_unit("Tank-2", 0, 0) })
    local jet = mock_group("Jets", { mock_unit("Jet-1", 0, 0) })
    local boat = mock_group("Boats", { mock_unit("Boat-1", 0, 0) })
    coalition_groups[1] = { [2] = { tank } }
    coalition_groups[2] = { [0] = { jet }, [3] = { boat } }

    local ground = RetUtils.getUnitNames(nil, { Group.Category.GROUND })
    check(#ground == 2, "both red tanks listed")

    local blue = RetUtils.getUnitNames({ coalition.side.BLUE })
    check(#blue == 2, "all blue units listed when no category is given")

    local blue_air = RetUtils.getUnitNames(
        { coalition.side.BLUE },
        { Group.Category.AIRPLANE, Group.Category.HELICOPTER }
    )
    check(#blue_air == 1 and blue_air[1] == "Jet-1", "category filter applied")
end

local function test_group_id_lookups()
    setup()
    add_template("Escort", 0, 2, { groupId = 42, units = { { name = "Escort-1", x = 0, y = 0 } } })
    check(RetUtils.getGroupNameById(42) == "Escort", "mission group id resolves to its name")
    check(RetUtils.getGroupNameById("42") == "Escort", "numeric strings are accepted")
    check(RetUtils.getGroupNameById(7) == nil, "unknown id returns nil")

    local unit = mock_unit("Escort-1", 0, 0)
    unit.getGroup = function()
        return mock_group("Escort", {}, 42)
    end
    check(RetUtils.getGroupId(unit) == 42, "group id read from the live group")
end

local function test_geometry()
    setup()
    check(near(RetUtils.get2DDist({ x = 0, y = 0 }, { x = 3, y = 4 }), 5), "Vec2 distance")
    check(near(RetUtils.get2DDist({ x = 0, y = 999, z = 0 }, { x = 3, y = -5, z = 4 }), 5), "Vec3 altitude ignored")
    check(near(RetUtils.get2DDist({ x = 0, y = 999, z = 0 }, { x = 3, y = 4 }), 5), "mixed Vec3 / Vec2")

    for _ = 1, 200 do
        local p = RetUtils.getRandPointInCircle({ x = 100, y = 7, z = 200 }, 50, 20)
        local d = RetUtils.get2DDist(p, { x = 100, y = 200 })
        check(d <= 50 + 1e-6 and d >= 20 - 1e-6, "random point inside the ring")
    end
    local centre = RetUtils.getRandPointInCircle({ x = 1, y = 2 }, 0)
    check(centre.x == 1 and centre.y == 2, "zero radius returns the centre")
end

local function test_respawn_group_activates_template()
    setup()
    add_template("Supply", Group.Category.GROUND, 2, {
        groupId = 9,
        lateActivation = true,
        start_time = 0,
        x = 100,
        y = 200,
        units = {
            { name = "Supply-1", type = "M 818", x = 100, y = 200, unitId = 1 },
            { name = "Supply-2", type = "M 818", x = 110, y = 200, unitId = 2 },
        },
        route = { points = { { x = 100, y = 200 }, { x = 500, y = 600 } } },
        CategoryID = Group.Category.GROUND,
        CountryID = 2,
        CoalitionID = 2,
    })

    local result = RetUtils.respawnGroup("Supply")

    check(#added_groups == 1, "group re-added")
    local call = added_groups[1]
    check(call.country == 2 and call.category == Group.Category.GROUND, "country / category from the template")
    check(result == call.data and result.name == "Supply", "group name preserved")
    check(call.data.lateActivation == false, "late activation cleared")
    check(#call.data.units == 2 and call.data.units[2].unitId == 2, "all template units respawned")
    check(#call.data.route.points == 2, "template route kept")
    check(call.data.CategoryID == nil, "MOOSE bookkeeping keys stripped")
    local stored = _DATABASE.Templates.Groups["Supply"].Template
    check(stored.lateActivation == true, "stored template left untouched")
end

local function test_respawn_at_point_shifts_group_and_replaces_route()
    setup()
    add_template("CAP", Group.Category.AIRPLANE, 2, {
        x = 0,
        y = 0,
        units = {
            { name = "CAP-1", type = "F-16C_50", x = 0, y = 0, alt = 30, parking = 4 },
            { name = "CAP-2", type = "F-16C_50", x = 10, y = 5, alt = 30, parking = 5 },
        },
        route = { points = { { x = 0, y = 0, type = "TakeOffParking" } } },
    })

    RetUtils.teleportGroup({
        groupName = "CAP",
        action = "respawn",
        point = { x = 1000, y = 6000, z = 2000 },
        route = { { x = 1000, y = 2000, alt = 6000, type = "Turning Point" } },
    })

    local group = added_groups[1].data
    check(group.units[1].x == 1000 and group.units[1].y == 2000, "lead placed on the point")
    check(group.units[2].x == 1010 and group.units[2].y == 2005, "wingman keeps its offset")
    check(group.units[1].alt == 6000, "aircraft altitude taken from the point")
    check(group.units[1].parking == nil, "parking assignment cleared for an air start")
    check(#group.route.points == 1 and group.route.points[1].type == "Turning Point", "route replaced")
    check(group.x == 1000 and group.y == 2000, "group position shifted")
end

local function test_teleport_rejects_invalid_surface()
    setup()
    add_template("Convoy", Group.Category.GROUND, 2, {
        units = { { name = "Convoy-1", type = "M 818", x = 0, y = 0 } },
        route = { points = {} },
    })
    surface_fn = function()
        return SURF.WATER
    end

    local result = RetUtils.teleportGroup({
        groupName = "Convoy",
        action = "respawn",
        point = { x = 50, y = 0, z = 50 },
    })
    check(result == nil and #added_groups == 0, "ground group is not placed on water")
    check(#errors == 1, "error logged")

    result = RetUtils.teleportGroup({
        groupName = "Convoy",
        action = "respawn",
        point = { x = 50, y = 0, z = 50 },
        anyTerrain = true,
    })
    check(result ~= nil and #added_groups == 1, "anyTerrain skips the surface check")
end

local function test_teleport_keeps_only_live_units()
    setup()
    add_template("Carrier", Group.Category.SHIP, 2, {
        units = {
            { name = "CVN", type = "CVN_73", x = 0, y = 0, unitId = 1 },
            { name = "DDG", type = "USS_Arleigh_Burke_IIa", x = 500, y = 0, unitId = 2 },
        },
        route = { points = { { x = 0, y = 0 }, { x = 9000, y = 0 } } },
    })
    surface_fn = function()
        return SURF.WATER
    end
    -- Only the carrier is still alive, 1 km north of its template position.
    live_groups["Carrier"] = mock_group("Carrier", { mock_unit("CVN", 1000, 0, 0, "CVN_73") })

    RetUtils.teleportGroup({
        groupName = "Carrier",
        action = "teleport",
        point = { x = 3000, y = 0, z = 4000 },
        route = {},
    })

    local group = added_groups[1].data
    check(#group.units == 1 and group.units[1].name == "CVN", "dead units are not respawned")
    check(group.units[1].unitId == 1, "template unit data reused")
    check(group.units[1].x == 3000 and group.units[1].y == 4000, "live unit moved to the point")
    check(near(group.units[1].heading, math.pi / 2), "live heading preserved")
    check(group.units[1].speed == 5, "live speed preserved")
    check(next(group.route) == nil, "empty route spawns the group without one")
end

local function test_teleport_unknown_or_dead_group()
    setup()
    check(RetUtils.teleportGroup({ groupName = "Ghost", action = "respawn" }) == nil, "unknown group returns nil")
    check(#errors == 1, "unknown group logs an error")

    add_template("Gone", Group.Category.GROUND, 2, { units = { { name = "Gone-1", type = "M 818", x = 0, y = 0 } } })
    check(RetUtils.teleportGroup({ groupName = "Gone", action = "teleport" }) == nil, "dead group cannot be teleported")
    check(#added_groups == 0, "nothing spawned")
end

local function test_respawn_from_template_uses_database_spawn()
    setup()
    local template = { name = "Tanks", SpawnCoalitionID = 1, SpawnCategoryID = 2, SpawnCountryID = 0, units = {} }
    RetUtils.respawnFromTemplate(template)
    check(#db_spawns == 1, "template spawned through the MOOSE database")
    check(template.CoalitionID == 1 and template.CategoryID == 2 and template.CountryID == 0, "spawn ids normalised")
    check(template.SpawnCountryID == nil, "Spawn* aliases removed")
end

local function test_protected_timer_survives_errors()
    setup()
    local calls = 0
    local scheduled = RetUtils.newTimer(function(a, b)
        calls = calls + 1
        check(a == "x" and b == 2, "arguments forwarded")
        error("boom")
    end, "x", 2)
    scheduled:Start(nil, 5)
    check(scheduled:_Function(100) == 105, "repeating timer reschedules after an error")
    check(scheduled:_Function(105) == 110, "and keeps rescheduling")
    check(calls == 2, "callback keeps being called after an error")
    check(#errors == 2, "each failure is logged")
end

local function test_timer_stopped_from_its_own_callback_ends()
    setup()
    local scheduled
    local calls = 0
    scheduled = RetUtils.newTimer(function()
        calls = calls + 1
        if calls == 2 then
            scheduled:Stop()
        end
    end)
    scheduled:Start(nil, 2)

    check(scheduled:_Function(10) == 12, "running timer hands DCS its next call time")
    check(scheduled:_Function(12) == nil, "a timer stopped inside its callback is not rescheduled")
    check(scheduled.stops >= 1, "the MOOSE stop still runs")
end

local function test_timer_stopped_from_outside_stays_reusable_until_then()
    setup()
    local scheduled = RetUtils.newTimer(function() end)
    scheduled:Start(nil, 2)
    check(scheduled:_Function(10) == 12, "repeats while running")
    scheduled:Stop()
    check(scheduled.stops == 1, "stop forwarded to MOOSE")
    check(scheduled:_Function(12) == nil, "a late call after an outside stop does not reschedule")
end

local function test_guarded_call_reports_errors_and_slow_calls()
    setup()
    local ok, result = RetUtils.guardedCall("fast", function(a)
        return a * 2
    end, 21)
    check(ok == true and result == 42, "result passed through")
    check(#errors == 0 and #warnings == 0, "a fast, successful call logs nothing")

    ok = RetUtils.guardedCall("broken", function()
        error("boom")
    end)
    check(ok == false and #errors == 1, "errors are caught and logged")
    check(string.find(errors[1], "broken", 1, true) ~= nil, "the label is in the error line")

    -- Busy-wait a little over the 50 ms threshold.
    RetUtils.guardedCall("slow", function()
        local started = os.clock()
        while os.clock() - started < 0.06 do
        end
    end)
    check(#warnings == 1, "a slow call is reported")
    check(string.find(warnings[1], "slow", 1, true) ~= nil, "the label is in the warning line")
end

local function test_ground_routing_helpers()
    setup()
    local waypoint = RetUtils.groundWaypoint({ x = 10, y = 99, z = 20 }, "Off Road", 10)
    check(waypoint.x == 10 and waypoint.y == 20, "Vec3 converted to a map waypoint")
    check(waypoint.action == "Off Road" and near(waypoint.speed, 10), "formation and speed (m/s) kept")
    local default = RetUtils.groundWaypoint({ x = 1, y = 2 })
    check(default.action == "Cone" and near(default.speed, 20 / 3.6), "defaults: Cone at 20 km/h")

    local task
    local group = mock_group("Movers", { mock_unit("Mover-1", 7, 8) })
    group.getController = function()
        return {
            setTask = function(_, t)
                task = t
            end,
        }
    end
    live_groups["Movers"] = group
    check(RetUtils.routeGroup("Movers", { waypoint }) == true, "route assigned by group name")
    check(task.id == "Mission" and #task.params.route.points == 1, "mission task built from the waypoints")
    check(RetUtils.routeGroup("Nobody", { waypoint }) == false, "missing group reported")
    local lead = RetUtils.getLeadPos("Movers")
    check(lead.x == 7 and lead.z == 8, "lead position from the first live unit")
end

-- Driver ----------------------------------------------------------------------

local tests = {
    test_spawn_group_fills_defaults,
    test_spawn_group_enum_inputs_and_route_array,
    test_spawn_group_rejects_unknown_country,
    test_spawn_static_cargo,
    test_spawn_static_requires_position,
    test_get_unit_names_filters,
    test_group_id_lookups,
    test_geometry,
    test_respawn_group_activates_template,
    test_respawn_at_point_shifts_group_and_replaces_route,
    test_teleport_rejects_invalid_surface,
    test_teleport_keeps_only_live_units,
    test_teleport_unknown_or_dead_group,
    test_respawn_from_template_uses_database_spawn,
    test_protected_timer_survives_errors,
    test_timer_stopped_from_its_own_callback_ends,
    test_timer_stopped_from_outside_stays_reusable_until_then,
    test_guarded_call_reports_errors_and_slow_calls,
    test_ground_routing_helpers,
}

for _, t in ipairs(tests) do
    t()
end

print(string.format("ok - %d assertions across %d scenarios", passed, #tests))
