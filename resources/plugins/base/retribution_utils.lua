-- retribution_utils.lua
--
-- Small MOOSE-backed helpers shared by the DCS Retribution plugin scripts.
--
-- These cover the handful of operations the plugins used to get from MIST and
-- that have no one-line MOOSE equivalent (spawning a group from a plain data
-- table, respawning / teleporting a group by name, listing unit names by
-- coalition and category, resolving mission-editor group ids). Everything
-- with a direct MOOSE equivalent (UTILS.*, TIMER, MESSAGE, GROUP, ZONE, ...)
-- is called directly from the plugin scripts instead.
--
-- Part of the mandatory "base" plugin; must be loaded after Moose.lua.

assert(
    _DATABASE ~= nil and UTILS ~= nil,
    "retribution_utils.lua requires MOOSE; make sure Moose.lua is loaded first"
)

RetUtils = {}

-- Lookups -----------------------------------------------------------------------

-- Group category lookup accepting the names MIST used as well as the DCS enum.
local GROUP_CATEGORY_BY_NAME = {
    plane = Group.Category.AIRPLANE,
    airplane = Group.Category.AIRPLANE,
    helicopter = Group.Category.HELICOPTER,
    vehicle = Group.Category.GROUND,
    ground = Group.Category.GROUND,
    ground_unit = Group.Category.GROUND,
    ship = Group.Category.SHIP,
    train = Group.Category.TRAIN,
}

local function resolve_category(category)
    if type(category) == "number" then
        return category
    end
    if type(category) == "string" then
        return GROUP_CATEGORY_BY_NAME[string.lower(category)]
    end
    return nil
end

local function resolve_country(cntry)
    if type(cntry) == "number" then
        return cntry
    end
    if type(cntry) == "string" then
        return country.id[string.upper((cntry:gsub("%s+", "_")))]
    end
    return nil
end

local function is_air(category_id)
    return category_id == Group.Category.AIRPLANE
        or category_id == Group.Category.HELICOPTER
end

-- Mission-editor group id -> group name. Built lazily, once, from the MOOSE
-- template database (group ids are static for mission-editor groups).
local group_name_by_id = nil

--- Returns the name of the mission-editor group with the given group id.
function RetUtils.getGroupNameById(group_id)
    if not group_name_by_id then
        group_name_by_id = {}
        for name, entry in pairs(_DATABASE.Templates.Groups) do
            if entry.groupId then
                group_name_by_id[entry.groupId] = name
            end
        end
    end
    return group_name_by_id[tonumber(group_id)]
end

--- Returns the DCS group id of the group the given DCS unit belongs to.
function RetUtils.getGroupId(unit)
    if not unit then
        return nil
    end
    local group = unit:getGroup()
    if group then
        return group:getID()
    end
    -- Fall back to the mission template (e.g. a client unit whose group object
    -- is not accessible).
    local entry = _DATABASE.Templates.Units[unit:getName()]
    return entry and entry.GroupId or nil
end

--- Returns the names of all live units of the given coalitions and group
-- categories.
-- @param sides list of coalition.side values; nil for every coalition.
-- @param categories list of Group.Category values; nil for every category.
-- @return array of unit names.
function RetUtils.getUnitNames(sides, categories)
    sides = sides
        or { coalition.side.RED, coalition.side.BLUE, coalition.side.NEUTRAL }
    local names = {}
    local function collect(groups)
        for _, group in ipairs(groups) do
            for _, unit in ipairs(group:getUnits()) do
                names[#names + 1] = unit:getName()
            end
        end
    end
    for _, side in ipairs(sides) do
        if categories then
            for _, category in ipairs(categories) do
                collect(coalition.getGroups(side, category))
            end
        else
            collect(coalition.getGroups(side))
        end
    end
    return names
end

-- Scheduling --------------------------------------------------------------------

-- Scripted work that blocks the simulation for longer than this is reported in
-- dcs.log, so a stalling script can be identified from the log.
local SLOW_CALL_SECONDS = 0.05
local clock = os and os.clock

local function describe_function(fn)
    local info = debug and debug.getinfo and debug.getinfo(fn, "S")
    if info then
        return string.format("%s:%s", tostring(info.short_src), tostring(info.linedefined))
    end
    return tostring(fn)
end

--- Calls fn(...) protected. An error is written to dcs.log instead of being
-- raised, and a call that takes longer than 50 ms is reported there too.
-- @param label name used in the log lines; defaults to the function's source
--        location.
-- @return true and the function's first result, or false on error.
function RetUtils.guardedCall(label, fn, ...)
    local started = clock and clock()
    local ok, result
    if RetProfiler then
        -- Books the time under fn's own script rather than under the MOOSE
        -- timer that called it.
        ok, result = pcall(RetProfiler.measure, fn, ...)
    else
        ok, result = pcall(fn, ...)
    end
    if not ok then
        env.error(
            string.format(
                "RetUtils: error in %s: %s",
                label or describe_function(fn),
                tostring(result)
            )
        )
    end
    if started then
        local elapsed = clock() - started
        if elapsed > SLOW_CALL_SECONDS then
            env.warning(
                string.format(
                    "RetUtils: slow script call: %s took %.0f ms",
                    label or describe_function(fn),
                    elapsed * 1000
                )
            )
        end
    end
    return ok, result
end

--- Creates a MOOSE TIMER whose callback runs through RetUtils.guardedCall: an
-- error is written to dcs.log instead of killing the timer, so a repeating
-- timer keeps running after a failed call, and slow calls are reported.
-- Start it with :Start(delay, interval) and stop it with :Stop(), as with any
-- TIMER.
--
-- Unlike a plain TIMER, it is safe to stop from inside its own callback. A
-- plain repeating TIMER stopped that way still hands DCS its next call time
-- when the callback returns, so it keeps firing forever.
-- @param fn function to call.
-- @param ... arguments passed to fn on every call.
function RetUtils.newTimer(fn, ...)
    local scheduled
    local function protected(...)
        RetUtils.guardedCall(nil, fn, ...)
        if scheduled.stopRequested then
            -- Without an interval MOOSE ends the timer instead of rescheduling it.
            scheduled.dT = nil
        end
    end
    scheduled = TIMER:New(protected, ...)
    local moose_stop = scheduled.Stop
    scheduled.Stop = function(self, delay)
        if not delay or delay <= 0 then
            self.stopRequested = true
        end
        return moose_stop(self, delay)
    end
    return scheduled
end

-- Geometry ----------------------------------------------------------------------

--- Horizontal distance in metres between two points. Each point may be a Vec2
-- ({x, y}) or a Vec3 ({x, y, z}); a Vec3's altitude is ignored. Allocation
-- free, so it is safe to call from tight loops.
function RetUtils.get2DDist(point1, point2)
    local dx = point1.x - point2.x
    local dz = (point1.z or point1.y) - (point2.z or point2.y)
    return math.sqrt(dx * dx + dz * dz)
end

--- Random Vec2 inside a circle (or ring) around a Vec2/Vec3 centre, uniformly
-- distributed over the area.
-- @param point Vec2 or Vec3 centre.
-- @param radius outer radius in metres (default 1000).
-- @param inner_radius optional inner radius in metres.
function RetUtils.getRandPointInCircle(point, radius, inner_radius)
    local cx, cz = point.x, point.z or point.y
    radius = radius or 1000
    if radius <= 0 then
        return { x = cx, y = cz }
    end
    local inner = inner_radius or 0
    if inner > radius then
        inner = 0
    end
    local theta = 2 * math.pi * math.random()
    local distance = math.sqrt(
        inner * inner + (radius * radius - inner * inner) * math.random()
    )
    return { x = cx + math.cos(theta) * distance, y = cz + math.sin(theta) * distance }
end

-- Spawning ----------------------------------------------------------------------

local dynamic_group_index = 0

--- Spawns a group from a plain group data table through the MOOSE database.
--
-- The table is the DCS group table plus:
--   country / countryId  -- country name or country.id value (required)
--   category             -- Group.Category value or "vehicle" / "plane" / ...
--   name / groupName     -- optional, generated when absent
-- Units may use `unitName` instead of `name`; missing unit names, skills and
-- the usual air-unit defaults are filled in. Group and unit ids are assigned
-- by DCS when not supplied.
--
-- The group template is registered with MOOSE, so GROUP:FindByName(),
-- GROUP:GetTemplate() and friends work on the result.
-- @return the spawned group table (its `name` is the group name), or nil.
function RetUtils.spawnGroup(group_data)
    local group = UTILS.DeepCopy(group_data)

    local country_id = resolve_country(group.countryId or group.country)
    if not country_id then
        env.error(
            "RetUtils.spawnGroup: unknown country "
                .. tostring(group.countryId or group.country)
        )
        return nil
    end
    local category_id = resolve_category(group.category)
    if not category_id then
        env.error(
            "RetUtils.spawnGroup: unknown category " .. tostring(group.category)
        )
        return nil
    end

    group.name = group.groupName or group.name
    if not group.name then
        dynamic_group_index = dynamic_group_index + 1
        group.name = string.format("Retribution dyn group %d", dynamic_group_index)
    end

    group.hidden = group.hidden or false
    group.visible = group.visible or false
    if type(group.start_time) ~= "number" then
        group.start_time = group.startTime and UTILS.Round(group.startTime) or 0
    end

    for index, unit in pairs(group.units) do
        unit.name = unit.unitName or unit.name
            or string.format("%s unit%d", group.name, index)
        unit.unitName = nil
        unit.skill = unit.skill or "Random"
        if is_air(category_id) then
            local plane = category_id == Group.Category.AIRPLANE
            if unit.alt_type ~= "BARO" then
                unit.alt_type = "RADIO"
            end
            unit.speed = unit.speed or (plane and 150 or 60)
            if not unit.alt then
                unit.alt = plane and 2000 or 500
                unit.alt_type = "RADIO"
            end
        elseif category_id == Group.Category.GROUND then
            if unit.playerCanDrive == nil then
                unit.playerCanDrive = true
            end
        end
    end

    -- A bare array of waypoints is accepted in place of { points = ... }.
    if group.route then
        if not group.route.points and group.route[1] then
            group.route = { points = group.route }
        end
    else
        group.route = { points = { {} } }
    end

    group.groupName = nil
    group.clone = nil
    group.category = nil
    group.country = nil
    group.countryId = nil
    group.startTime = nil
    group.tasks = {}

    group.CountryID = country_id
    group.CategoryID = category_id
    group.CoalitionID = coalition.getCountryCoalition(country_id)
    _DATABASE:Spawn(group)

    return group
end

local dynamic_static_index = 0

--- Spawns a static object from a plain data table.
--
-- The table is the DCS static object table plus `country` / `countryId`
-- (country name or country.id value). A table in "group with one unit" form
-- ({ units = { {...} } }) is flattened first. As with the MIST helper this
-- replaces, an object with a `mass` is spawned as cargo.
-- @return the spawned static table (its `name` is the object name), or nil.
function RetUtils.spawnStatic(static_data)
    local static = UTILS.DeepCopy(static_data)
    if static.units and static.units[1] then
        for key, value in pairs(static.units[1]) do
            static[key] = value
        end
        static.units = nil
    end

    local country_id = resolve_country(static.countryId or static.country)
    if not country_id then
        env.error(
            "RetUtils.spawnStatic: unknown country "
                .. tostring(static.countryId or static.country)
        )
        return nil
    end

    static.name = static.name or static.unitName
    if not static.name then
        dynamic_static_index = dynamic_static_index + 1
        static.name = string.format("Retribution dyn static %d", dynamic_static_index)
    end
    static.unitName = nil
    static.dead = static.dead or false
    static.heading = static.heading or math.rad(math.random(360))
    if static.categoryStatic then
        static.category = static.categoryStatic
    end
    if static.mass then
        static.category = "Cargos"
    end
    static.shape_name = static.shape_name or static.shapeName
    static.country = nil
    static.countryId = nil

    if type(static.x) ~= "number"
        or type(static.y) ~= "number"
        or type(static.type) ~= "string"
    then
        env.error("RetUtils.spawnStatic: missing x, y or type for " .. static.name)
        return nil
    end

    coalition.addStaticObject(country_id, static)
    _DATABASE:AddStatic(static.name)
    return static
end

--- Re-adds a group from a (modified) MOOSE template, replacing the live group
-- of the same name in place. coalition.addGroup with an existing name swaps
-- the units and only fires S_EVENT_BIRTH, so no loss/kill events are emitted.
-- @param template a template as returned by GROUP:GetTemplate().
function RetUtils.respawnFromTemplate(template)
    template.CoalitionID = template.CoalitionID or template.SpawnCoalitionID
    template.CategoryID = template.CategoryID or template.SpawnCategoryID
    template.CountryID = template.CountryID or template.SpawnCountryID
    template.SpawnCoalitionID = nil
    template.SpawnCategoryID = nil
    template.SpawnCountryID = nil
    return _DATABASE:Spawn(template)
end

-- Respawning / teleporting mission groups ----------------------------------------

local VALID_SURFACES_BY_CATEGORY = {
    [Group.Category.SHIP] = {
        [land.SurfaceType.WATER] = true,
        [land.SurfaceType.SHALLOW_WATER] = true,
    },
    [Group.Category.GROUND] = {
        [land.SurfaceType.LAND] = true,
        [land.SurfaceType.ROAD] = true,
    },
}

local PARKING_KEYS = { "parking", "parking_id", "parking_landing", "parking_landing_id" }

--- Respawns or teleports a group that has a MOOSE template (every
-- mission-editor group, and every group spawned with RetUtils.spawnGroup).
--
-- vars:
--   groupName / gpName  -- name of the group (required)
--   action              -- "respawn": rebuild the group from its template, all
--                          units alive, at the template (or `point`) position.
--                          "teleport" (default): move the live group, keeping
--                          only the units that are still alive.
--   point               -- optional Vec3; the first unit is placed there and
--                          the rest keep their offsets. For aircraft, point.y
--                          is the new altitude when it is clear of the ground.
--   route               -- optional array of waypoints replacing the template
--                          route (an empty table spawns the group without one).
--   anyTerrain          -- skip the surface check for ships / ground units.
--
-- The group is always spawned active, even if its template is late-activated.
-- The MOOSE template itself is left untouched, so every respawn starts from
-- the original mission-editor definition.
-- @return the spawned group table (its `name` is the group name), or nil if
--         the group is unknown, not alive (teleport) or the point is on a
--         surface the group cannot be placed on.
function RetUtils.teleportGroup(vars)
    local name = vars.groupName or vars.gpName
    local entry = name and _DATABASE.Templates.Groups[name]
    if not entry then
        env.error("RetUtils.teleportGroup: no template for group " .. tostring(name))
        return nil
    end

    local group = UTILS.DeepCopy(entry.Template)
    local category_id = entry.CategoryID
    local country_id = entry.CountryID
    local action = string.lower(vars.action or "teleport")
    local respawn = action == "respawn"

    if not respawn then
        -- Rebuild the unit list from the units that are alive right now.
        local live = Group.getByName(name)
        if not live or not live:isExist() then
            env.warning("RetUtils.teleportGroup: group " .. name .. " is not alive")
            return nil
        end
        local template_units = {}
        for _, unit in pairs(group.units) do
            template_units[unit.name] = unit
        end
        local units = {}
        for _, live_unit in ipairs(live:getUnits()) do
            local unit_name = live_unit:getName()
            local unit = template_units[unit_name]
                or { name = unit_name, type = live_unit:getTypeName(), skill = "Average" }
            local position = live_unit:getPosition()
            unit.x = position.p.x
            unit.y = position.p.z
            unit.alt = position.p.y
            unit.heading = math.atan2(position.x.z, position.x.x)
            unit.speed = UTILS.VecNorm(live_unit:getVelocity())
            units[#units + 1] = unit
        end
        if #units == 0 then
            env.warning("RetUtils.teleportGroup: group " .. name .. " has no live units")
            return nil
        end
        group.units = units
    end

    local point = vars.point
    if point then
        local target = { x = point.x, y = point.z or point.y }
        local valid_surfaces = VALID_SURFACES_BY_CATEGORY[category_id]
        if valid_surfaces
            and not vars.anyTerrain
            and not valid_surfaces[land.getSurfaceType(target)]
        then
            env.error(
                "RetUtils.teleportGroup: point for " .. name .. " is not on a valid surface"
            )
            return nil
        end

        local first = group.units[1]
        local dx, dy = target.x - first.x, target.y - first.y
        local plane = category_id == Group.Category.AIRPLANE
        for _, unit in pairs(group.units) do
            unit.x = unit.x + dx
            unit.y = unit.y + dy
            if is_air(category_id) then
                local ground = land.getHeight({ x = unit.x, y = unit.y })
                if point.z and point.y > 0 and point.y > ground + 10 then
                    unit.alt = point.y
                elseif plane then
                    unit.alt = ground + math.random(300, 9000)
                else
                    unit.alt = ground + math.random(200, 3000)
                end
            end
        end
        if group.x and group.y then
            group.x = group.x + dx
            group.y = group.y + dy
        end
    end

    if vars.route then
        if #vars.route > 0 then
            group.route = { points = UTILS.DeepCopy(vars.route) }
        else
            group.route = {}
        end
    end

    if point or vars.route then
        -- The group no longer starts from its mission-editor parking spots.
        for _, unit in pairs(group.units) do
            for _, key in ipairs(PARKING_KEYS) do
                unit[key] = nil
            end
        end
    end

    -- A delayed mission-editor start only applies while that time is still ahead.
    local start_time = tonumber(group.start_time) or 0
    if respawn and start_time > 0 then
        local elapsed = timer.getAbsTime() - timer.getTime0()
        start_time = elapsed > start_time and 0 or start_time - elapsed
    elseif not respawn then
        start_time = 0
    end
    group.start_time = start_time
    group.lateActivation = false
    group.name = name

    group.CoalitionID = nil
    group.CategoryID = nil
    group.CountryID = nil
    group.SpawnCoalitionID = nil
    group.SpawnCategoryID = nil
    group.SpawnCountryID = nil

    coalition.addGroup(country_id, category_id, group)
    _DATABASE:AddGroup(name)
    for _, unit in pairs(group.units) do
        _DATABASE:AddUnit(unit.name)
    end
    return group
end

--- Respawns a group from its mission template: all units alive, at their
-- template positions, with the template route and waypoint tasks. Spawns the
-- group active even if the template is late-activated.
-- @return the spawned group table, or nil if the group has no template.
function RetUtils.respawnGroup(name)
    return RetUtils.teleportGroup({ groupName = name, action = "respawn" })
end

-- Ground routing ----------------------------------------------------------------

--- Builds a ground waypoint at a Vec2/Vec3 point.
-- @param point Vec2 or Vec3.
-- @param formation DCS waypoint action ("Off Road", "On Road", "Cone", ...);
--        defaults to "Cone".
-- @param speed speed in m/s; defaults to 20 km/h.
function RetUtils.groundWaypoint(point, formation, speed)
    local vec2 = UTILS.Vec3toVec2(UTILS.Vec2toVec3(point))
    local waypoint = COORDINATE:NewFromVec2(vec2):WaypointGround(
        speed and UTILS.MpsToKmph(speed) or 20,
        formation or "Cone"
    )
    return waypoint
end

--- Position (Vec3) of the first living unit of a DCS group or group name.
function RetUtils.getLeadPos(group)
    if type(group) == "string" then
        group = Group.getByName(group)
    end
    if not group then
        return nil
    end
    for _, unit in ipairs(group:getUnits()) do
        if unit:isExist() then
            return unit:getPoint()
        end
    end
    return nil
end

--- Immediately sends a DCS group (object or name) along a list of waypoints.
function RetUtils.routeGroup(group, waypoints)
    if type(group) == "string" then
        group = Group.getByName(group)
    end
    local controller = group and group:getController()
    if not controller then
        return false
    end
    controller:setTask({
        id = "Mission",
        params = { route = { points = UTILS.DeepCopy(waypoints) } },
    })
    return true
end
