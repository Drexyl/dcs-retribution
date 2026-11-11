-- Script profiler for DCS Retribution missions.
--
-- Once a minute of mission time this writes one line to dcs.log saying how fast
-- the simulation ran against real time and how much of that time each mission
-- script used:
--
--   RetProfiler: 60 s of mission time took 71 s (speed 0.85x), mission scripts
--   used 9.4 s, script memory 310 MB. Busiest: ctld/CTLD.lua 6.1 s (812 calls,
--   max 40 ms); base/Moose.lua 2.2 s (5400 calls, max 12 ms); ...
--
-- A mission that runs slower than real time is what players on a dedicated
-- server see as other aircraft warping. If the scripts' share is small, the
-- time is going to DCS itself (AI, pathfinding) or to server-side scripts that
-- were loaded before the mission (DCS-gRPC, Olympus), which are not measured.
--
-- It works by wrapping timer.scheduleFunction and world.addEventHandler, so it
-- has to be the first script the mission loads. It needs nothing but the DCS
-- scripting API. Time is attributed to the file that defines the function DCS
-- calls, so everything driven by a MOOSE timer or event counts as Moose.lua
-- unless it runs through RetUtils.guardedCall.

RetProfiler = {}

local clock = os and os.clock
local getinfo = debug and debug.getinfo

if not (clock and getinfo and timer and world) then
    -- Sanitised scripting environment: nothing to measure with.
    RetProfiler.loading = function() end
    RetProfiler.measure = function(fn, ...)
        return fn(...)
    end
    return
end

local REPORT_INTERVAL_SECONDS = 60
local REPORT_ENTRIES = 6

local schedule_function = timer.scheduleFunction
local add_event_handler = world.addEventHandler

local loading_label = nil
local labels = {} -- chunk source -> script name given by the mission generator
local sources = setmetatable({}, { __mode = "k" }) -- function -> chunk source
local wrapped_handlers = setmetatable({}, { __mode = "k" })
local totals = {} -- chunk source -> { time, calls, longest }
-- Time used by measured calls nested inside the one being measured, so that a
-- script called by another is not counted twice.
local nested_time = 0

--- Told by the mission which script file the next trigger action loads, so the
-- report can name scripts instead of DCS's temporary file names.
-- @param label script name, or nil once the file has been loaded.
function RetProfiler.loading(label)
    loading_label = label
end

-- While a script file is loading, the innermost main chunk on the stack is that
-- file: remember its source under the name the generator gave.
local function note_loading_source()
    if not loading_label then
        return
    end
    local level = 3
    while true do
        local info = getinfo(level, "S")
        if not info then
            return
        end
        if info.what == "main" then
            if not labels[info.source] then
                labels[info.source] = loading_label
            end
            return
        end
        level = level + 1
    end
end

local function source_of(fn)
    if type(fn) ~= "function" then
        return "?"
    end
    local source = sources[fn]
    if not source then
        local info = getinfo(fn, "S")
        source = info and info.source or "?"
        sources[fn] = source
    end
    return source
end

local function account(source, fn, ...)
    local outer_nested = nested_time
    nested_time = 0
    local started = clock()
    local ok, result = pcall(fn, ...)
    local elapsed = clock() - started
    local entry = totals[source]
    if not entry then
        entry = { time = 0, calls = 0, longest = 0 }
        totals[source] = entry
    end
    entry.time = entry.time + elapsed - nested_time
    entry.calls = entry.calls + 1
    if elapsed > entry.longest then
        entry.longest = elapsed
    end
    nested_time = outer_nested + elapsed
    if not ok then
        -- Hand the error on to DCS, which logs it as it always did.
        error(result, 0)
    end
    return result
end

--- Runs fn(...) and books its time under the file that defines fn, taking it
-- off whatever measured call it is running inside. For work that DCS reaches
-- through another script's timer (MOOSE's, typically).
-- @param fn function to call.
-- @param ... arguments passed to fn.
-- @return fn's first result.
function RetProfiler.measure(fn, ...)
    return account(source_of(fn), fn, ...)
end

timer.scheduleFunction = function(fn, argument, time)
    note_loading_source()
    if type(fn) ~= "function" then
        return schedule_function(fn, argument, time)
    end
    local source = source_of(fn)
    return schedule_function(function(arg, now)
        return account(source, fn, arg, now)
    end, argument, time)
end

world.addEventHandler = function(handler)
    note_loading_source()
    if type(handler) == "table" and not wrapped_handlers[handler] then
        local on_event = handler.onEvent
        if type(on_event) == "function" then
            wrapped_handlers[handler] = true
            local source = source_of(on_event)
            handler.onEvent = function(self, event)
                return account(source, on_event, self, event)
            end
        end
    end
    return add_event_handler(handler)
end

local function label_of(source)
    local label = labels[source]
    if label then
        return label
    end
    -- A file DCS loaded shows up under its temporary path; a trigger's inline
    -- script shows up as its own text.
    local text = source:gsub("%s+", " ")
    local file = text:match("([^/\\]+%.lua)$")
    if file then
        return file
    end
    if #text > 40 then
        text = text:sub(1, 40) .. "..."
    end
    return text
end

local function report(real_seconds, mission_seconds)
    local rows = {}
    local script_seconds = 0
    for source, entry in pairs(totals) do
        rows[#rows + 1] = { label = label_of(source), entry = entry }
        script_seconds = script_seconds + entry.time
    end
    totals = {}
    table.sort(rows, function(x, y)
        return x.entry.time > y.entry.time
    end)
    local busiest = {}
    for i = 1, math.min(REPORT_ENTRIES, #rows) do
        local entry = rows[i].entry
        busiest[i] = string.format(
            "%s %.1f s (%d calls, max %.0f ms)",
            rows[i].label,
            entry.time,
            entry.calls,
            entry.longest * 1000
        )
    end
    local speed = real_seconds > 0 and mission_seconds / real_seconds or 1
    env.info(
        string.format(
            "RetProfiler: %.0f s of mission time took %.0f s (speed %.2fx), "
                .. "mission scripts used %.1f s, script memory %.0f MB. Busiest: %s",
            mission_seconds,
            real_seconds,
            speed,
            script_seconds,
            collectgarbage("count") / 1024,
            #busiest > 0 and table.concat(busiest, "; ") or "none"
        )
    )
end

local last_real = clock()
local last_mission = timer.getTime()

schedule_function(function(_, now)
    local real = clock()
    -- A profiler failure must never reach the mission.
    pcall(report, real - last_real, now - last_mission)
    last_real, last_mission = real, now
    return now + REPORT_INTERVAL_SECONDS
end, nil, timer.getTime() + REPORT_INTERVAL_SECONDS)
