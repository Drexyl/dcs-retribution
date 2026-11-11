-- the state.json file will be updated according to this schedule and on mission end
local WRITESTATE_SCHEDULE_IN_SECONDS = 15

-- Minimal logger writing to dcs.log. Global: other plugins (e.g. LotATC export)
-- log through it.
logger = {}
function logger:info(message)
    env.info("DCSRetribution|" .. tostring(message))
end
function logger:warn(message)
    env.warning("DCSRetribution|" .. tostring(message))
end
function logger:error(message)
    env.error("DCSRetribution|" .. tostring(message))
end
logger:info("Check that json.lua is loaded : json = "..tostring(json))

crash_events = {} -- killed aircraft will be added via S_EVENT_CRASH event
dead_events = {} -- killed units will be added via S_EVENT_DEAD event
unit_lost_events = {} -- killed units will be added via S_EVENT_UNIT_LOST
kill_events = {} -- killed units will be added via S_EVENT_KILL
base_capture_events = {}
destroyed_objects_positions = {} -- will be added via S_EVENT_DEAD event
ejection_events = {} -- {unit=<aircraft unit name>, x=, z=} added via S_EVENT_EJECTION
csar_rescued = {} -- UUID strings of downed pilots rescued by Ops.CSAR (see OpsCSAR.lua)
mission_ended = false
dirty_state = false -- Track if state has changed and needs writing

local function ends_with(str, ending)
   return ending == "" or str:sub(-#ending) == ending
end

local function messageAll(message)
    MESSAGE:New(message, 25):ToAll()
end

-- The event lists only ever grow, and encoding them is by far the most expensive
-- part of writing the state (tens of microseconds per entry), so each entry is
-- encoded once and the encoded text is kept. A write then costs time
-- proportional to the new entries rather than to everything recorded so far.
local encoded_lists = {}

local function encode_append_only_list(key, list)
    local cache = encoded_lists[key]
    if not cache or cache.list ~= list or cache.count > #list then
        -- First use, or the list was replaced or shortened: start over.
        cache = { list = list, count = 0, parts = {} }
        encoded_lists[key] = cache
    end
    for i = cache.count + 1, #list do
        cache.parts[i] = json:encode(list[i])
    end
    cache.count = #list
    return '"' .. key .. '":[' .. table.concat(cache.parts, ",") .. "]"
end

local function encode_state()
    return "{"
        .. table.concat({
            encode_append_only_list("crash_events", crash_events),
            encode_append_only_list("dead_events", dead_events),
            encode_append_only_list("base_capture_events", base_capture_events),
            encode_append_only_list("unit_lost_events", unit_lost_events),
            encode_append_only_list("kill_events", kill_events),
            '"mission_ended":' .. tostring(mission_ended == true),
            encode_append_only_list("destroyed_objects_positions", destroyed_objects_positions),
            -- Ejection entries are updated in place when the pilot lands, so this
            -- (short) list is encoded in full every time.
            '"ejection_events":' .. json:encode(ejection_events),
            encode_append_only_list("csar_rescued", csar_rescued),
        }, ",")
        .. "}"
end

function write_state()
    local _debriefing_file_location = debriefing_file_location
    if not debriefing_file_location or debriefing_file_location == "" then
        error("Unable to save DCS Retribution state: debriefing file path is unavailable")
    end

    if not json then
        error("Unable to save DCS Retribution state, JSON library is not loaded")
    end

    local started = os and os.clock()
    -- Encode before opening the file, so the previous state is not truncated if
    -- encoding fails.
    local state = encode_state()

    local fp, open_error = io.open(_debriefing_file_location, 'w')
    if not fp then
        error("Unable to open state file for writing: "..tostring(_debriefing_file_location).." ("..tostring(open_error)..")")
    end
    local ok, write_error = pcall(function()
        fp:write(state)
    end)
    fp:close()
    if not ok then
        error(write_error)
    end

    if started then
        local elapsed = os.clock() - started
        if elapsed > 0.05 then
            logger:warn(string.format("writing the state took %.0f ms (%d bytes)", elapsed * 1000, #state))
        end
    end
end

local function canWrite(name)
    local f = io.open(name, "a")
    if f then
        f:close()
        return true
    end
    return false
end

local function testDebriefingFilePath(folderPath, folderName, useCurrentStamping)
    if folderPath then
        local filePath = nil
        if not ends_with(folderPath, "\\") then
            folderPath = folderPath .. "\\"
        end
        if useCurrentStamping then
            filePath = string.format("%sstate-%s.json",folderPath, tostring(os.time()))
        else 
            filePath = string.format("%sstate.json",folderPath)
        end
        local isOk = canWrite(filePath)
        if isOk then 
            logger:info(string.format("The state.json file will be created in %s : (%s)",folderName, filePath))
            return filePath
        end
    end
    return nil
end

local function discoverDebriefingFilePath()   
    -- establish a search pattern into the following modes
    -- 1. Environment variable RETRIBUTION_EXPORT_DIR, to support dedicated server hosting
    -- 2. Embedded DCS Retribution dcsRetribution.installPath (set by the app to its install path), to support locally hosted single player
    -- 3. System temporary folder, as set in the TEMP environment variable
    -- 4. Working directory.
    
    local useCurrentStamping = nil
    if os then  
        useCurrentStamping = os.getenv("RETRIBUTION_EXPORT_STAMPED_STATE")
    end

    local installPath = nil
    if dcsRetribution then
        installPath = dcsRetribution.installPath
    end
    
    if os then
        local result = nil
        -- try using the RETRIBUTION_EXPORT_DIR environment variable
        result = testDebriefingFilePath(os.getenv("RETRIBUTION_EXPORT_DIR"), "RETRIBUTION_EXPORT_DIR", useCurrentStamping)
        if result then
            return result
        end
        -- no joy ? maybe there is a valid path in the mission ?
        result = testDebriefingFilePath(installPath, "the DCS Retribution install folder", useCurrentStamping)
        if result then
            return result
        end
        -- there's always the possibility of using the system temporary folder
        result = testDebriefingFilePath(os.getenv("TEMP"), "TEMP", useCurrentStamping)
        if result then
            return result
        end
    end

    -- nothing worked, let's try the last resort folder : current directory.
    if lfs then
        return testDebriefingFilePath(lfs.writedir().."Missions\\", "the working directory", useCurrentStamping)
    end
    
    return nil
end

debriefing_file_location = discoverDebriefingFilePath()
local error_message_shown = false

write_state_error_handling = function()
    local _debriefing_file_location = debriefing_file_location
    if not debriefing_file_location then 
        _debriefing_file_location = "[nil]"
        logger:error("Unable to find where to write DCS Retribution state")
    end

    -- Only write if state has changed since last write
    if dirty_state then
        if pcall(write_state) then
            dirty_state = false -- Reset dirty flag after successful write
            error_message_shown = false
        else
            if not error_message_shown then
                messageAll("Unable to write DCS Retribution state to ".._debriefing_file_location..
                        "\nYou can abort the mission in DCS Retribution.\n"..
                        "\n\nPlease fix your setup in DCS Retribution, make sure you are pointing to the right installation directory from the File/Preferences menu. Then after fixing the path restart DCS Retribution, and then restart DCS."..
                        "\n\nYou can also try to fix the issue manually by replacing the file <dcs_installation_directory>/Scripts/MissionScripting.lua by the one provided there : <dcs_retribution_folder>/resources/scripts/MissionScripting.lua. And then restart DCS. (This will also have to be done again after each DCS update)"..
                        "\n\nIt's not worth playing, the state of the mission will not be recorded.")
                error_message_shown = true
            end
        end
    end

    -- Reschedule quickly if mission is over and we still have unsaved changes,
    -- otherwise use the normal cadence.
    local next_schedule_in_seconds = WRITESTATE_SCHEDULE_IN_SECONDS
    if mission_ended and dirty_state then
        next_schedule_in_seconds = 1
    end
    TIMER:New(write_state_error_handling):Start(next_schedule_in_seconds)
end

activeWeapons = {}
local function onEvent(event)
    if event.id == world.event.S_EVENT_CRASH and event.initiator then
        crash_events[#crash_events + 1] = event.initiator.getName(event.initiator)
        dirty_state = true
    end
   
    if event.id == world.event.S_EVENT_UNIT_LOST and event.initiator then
        unit_lost_events[#unit_lost_events + 1] = event.initiator.getName(event.initiator)
        dirty_state = true
    end
	
	if event.id == world.event.S_EVENT_KILL and event.target then
        kill_events[#kill_events + 1] = event.target.getName(event.target)
        dirty_state = true
    end

    if event.id == world.event.S_EVENT_DEAD and event.initiator and event.initiator.getName then
        dead_events[#dead_events + 1] = event.initiator.getName(event.initiator)
        local position = event.initiator.getPosition(event.initiator)
        local destruction = {}
        destruction.x = position.p.x
        destruction.y = position.p.y
        destruction.z = position.p.z
        destruction.type = event.initiator:getTypeName()
        -- True heading in degrees (grid heading plus the map's north correction).
        destruction.orientation = math.deg(
            UTILS.GetDirectionRadians(position.x, position.p)
        )
        -- Only track actual units/buildings, not debris/crash models
        if destruction.type ~= nil and 
           string.find(destruction.type, "GENERIC_CRASH_MODEL") == nil and
           string.find(destruction.type, "_CRASH") == nil then
            destroyed_objects_positions[#destroyed_objects_positions + 1] = destruction
        end
        dirty_state = true
    end

    -- Ejection: record the aircraft unit name and its position so Retribution can
    -- place a downed pilot for CSAR. The landing-after-ejection event refines the
    -- position to where the pilot's parachute actually touched down.
    if event.id == world.event.S_EVENT_EJECTION and event.initiator and event.initiator.getName then
        local ok, name = pcall(function() return event.initiator:getName() end)
        if ok and name then
            local ejection = { unit = name }
            local posOk, position = pcall(function() return event.initiator:getPosition() end)
            if posOk and position and position.p then
                ejection.x = position.p.x
                ejection.z = position.p.z
            end
            ejection_events[#ejection_events + 1] = ejection
            dirty_state = true
        end
    end

    if event.id == world.event.S_EVENT_LANDING_AFTER_EJECTION and event.initiator then
        local posOk, position = pcall(function() return event.initiator:getPoint() end)
        if posOk and position then
            -- Refine the most recent ejection that has no landing position yet.
            for i = #ejection_events, 1, -1 do
                local ej = ejection_events[i]
                if not ej.landed then
                    ej.x = position.x
                    ej.z = position.z
                    ej.landed = true
                    dirty_state = true
                    break
                end
            end
        end
    end

    if event.id == world.event.S_EVENT_MISSION_END then
        mission_ended = true
        dirty_state = true
        if pcall(write_state) then
            dirty_state = false
        end
    end

end

world.addEventHandler({
    onEvent = function(_, event)
        -- Protected, and reported in dcs.log if a single event takes too long.
        RetUtils.guardedCall("dcs_retribution event handler", onEvent, event)
    end,
})

dirty_state = true
write_state_error_handling()

-- Stall monitor
-- Once per second of mission time, compares how much real time went by. When the
-- simulation falls well behind real time (a freeze, which players see as other
-- aircraft warping) the stall is written to dcs.log with its mission time, so it
-- can be matched against the "slow script call" lines and the rest of the log.
-- A stall with no slow script call next to it was not caused by a mission script.
-- Timers do not run while the server is paused, so a pause is reported as one
-- stall of the pause's length when the mission resumes.
local STALL_CHECK_INTERVAL_SECONDS = 1
local STALL_REPORT_THRESHOLD_SECONDS = 0.75

local function start_stall_monitor()
    if not (os and os.clock) then
        return
    end
    local last_real = os.clock()
    local last_mission = timer.getTime()
    timer.scheduleFunction(function(_, now)
        local real = os.clock()
        local behind = (real - last_real) - (now - last_mission)
        if behind > STALL_REPORT_THRESHOLD_SECONDS then
            logger:warn(string.format(
                "simulation stalled for %.1f s (mission time %.0f s, script memory %.0f MB)",
                behind, now, collectgarbage("count") / 1024
            ))
        end
        last_real, last_mission = real, now
        return now + STALL_CHECK_INTERVAL_SECONDS
    end, nil, timer.getTime() + STALL_CHECK_INTERVAL_SECONDS)
end

start_stall_monitor()

-- Escort leash
-- Escorts are kept within their engagement range relative to the escorted group.
-- This is driven by the mission-injected dcsRetribution.Escorts table.

local function escort_leash_get_group(id)
    local group_id = tonumber(id)
    if not group_id or group_id <= 0 then
        return nil
    end
    -- DCS has no Group.getByID; resolve the mission group id to a name via the
    -- MOOSE template database.
    local name = RetUtils.getGroupNameById(group_id)
    return name and Group.getByName(name) or nil
end

local function escort_leash_set_roe(group, roe)
    if not group then
        return
    end
    local controller = group:getController()
    if controller then
        controller:setOption(AI.Option.Air.id.ROE, roe)
    end
end

local function escort_leash_update()
    -- Keep running even if dcsRetribution data isn't available yet (trigger ordering)
    if not dcsRetribution or type(dcsRetribution.Escorts) ~= "table" then
        return timer.getTime() + 10
    end

    for _, pair in pairs(dcsRetribution.Escorts) do
        local escort_group = escort_leash_get_group(pair.escortGroupId)
        local escorted_group = escort_leash_get_group(pair.escortedGroupId)

        -- If the escorted group no longer exists (dead/despawned), ensure escort isn't stuck.
        if escort_group and not escorted_group then
            escort_leash_set_roe(escort_group, AI.Option.Air.val.ROE.OPEN_FIRE)
        elseif escort_group and escorted_group then
            local escort_unit = escort_group:getUnit(1)
            local escorted_unit = escorted_group:getUnit(1)
            if escort_unit and escorted_unit then
                local escort_pos = escort_unit:getPoint()
                local escorted_pos = escorted_unit:getPoint()
                local dx = escort_pos.x - escorted_pos.x
                local dz = escort_pos.z - escorted_pos.z
                local distance = math.sqrt(dx * dx + dz * dz)

                local max_dist = tonumber(pair.engagementRangeMeters) or 0
                if max_dist > 0 and distance > max_dist then
                    escort_leash_set_roe(escort_group, AI.Option.Air.val.ROE.RETURN_FIRE)
                else
                    escort_leash_set_roe(escort_group, AI.Option.Air.val.ROE.OPEN_FIRE)
                end
            end
        end
    end

    return timer.getTime() + 10
end

timer.scheduleFunction(escort_leash_update, nil, timer.getTime() + 1)
