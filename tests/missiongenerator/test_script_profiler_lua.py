"""Runs script_profiler.lua under Lua 5.1 with a mocked DCS scripting API.

The profiler wraps timer.scheduleFunction and world.addEventHandler for every
script in the mission, so these tests check both that the scripts still behave
exactly as before and that the time is booked against the right script.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

import pytest

lua51 = pytest.importorskip("lupa.lua51")

PROFILER = (
    Path(__file__).resolve().parents[2]
    / "resources"
    / "plugins"
    / "base"
    / "script_profiler.lua"
)

MOCK_ENVIRONMENT = """
log = {}
env = { info = function(message) log[#log + 1] = message end }
-- Real time and mission time are driven by the tests.
fake_clock = 0
mission_time = 0
os.clock = function() return fake_clock end
timers = {}
handlers = {}
timer = {
    getTime = function() return mission_time end,
    scheduleFunction = function(fn, argument, time)
        timers[#timers + 1] = { fn = fn, argument = argument, time = time }
        return #timers
    end,
}
world = {
    addEventHandler = function(handler) handlers[#handlers + 1] = handler end,
}
-- Stands in for a mission script that takes `seconds` of real time.
function work(seconds) fake_clock = fake_clock + seconds end
-- Loads `code` the way DCS loads a script file: as its own main chunk.
function load_script(label, code)
    RetProfiler.loading(label)
    assert(loadstring(code, "=" .. label .. " chunk"))()
    RetProfiler.loading(nil)
end
-- Runs the profiler's own report timer, which is always the first one.
function run_report(seconds_of_mission_time)
    mission_time = mission_time + seconds_of_mission_time
    return timers[1].fn(nil, mission_time)
end
"""


@pytest.fixture
def lua() -> Any:
    runtime = lua51.LuaRuntime(unpack_returned_tuples=True)
    runtime.execute(MOCK_ENVIRONMENT)
    runtime.execute(PROFILER.read_text(encoding="utf-8"))
    return runtime


def _log(lua: Any) -> list[str]:
    return list(lua.globals().log.values())


def test_report_names_each_script_and_the_simulation_speed(lua: Any) -> None:
    lua.execute("""
        load_script("ctld/CTLD.lua", [[
            timer.scheduleFunction(function(_, now) work(2) return now + 1 end, nil, 1)
        ]])
        load_script("splashdamage3/splash.lua", [[
            world.addEventHandler({ onEvent = function() work(0.5) end })
        ]])
        for _ = 1, 3 do timers[2].fn(nil, 10) end
        handlers[1]:onEvent({ id = 1 })
        work(63.5)
        next_report = run_report(60)
        """)
    assert lua.globals().next_report == 120
    (line,) = _log(lua)
    assert "60 s of mission time took 70 s (speed 0.86x)" in line
    assert "mission scripts used 6.5 s" in line
    assert "Busiest: ctld/CTLD.lua 6.0 s (3 calls, max 2000 ms); " in line
    assert "splashdamage3/splash.lua 0.5 s (1 calls, max 500 ms)" in line


def test_totals_start_again_after_each_report(lua: Any) -> None:
    lua.execute("""
        load_script("arty/arty.lua", [[
            timer.scheduleFunction(function() work(1) end, nil, 1)
        ]])
        timers[2].fn(nil, 1)
        run_report(60)
        run_report(60)
        """)
    first, second = _log(lua)
    assert "arty/arty.lua 1.0 s" in first
    assert "mission scripts used 0.0 s" in second
    assert second.endswith("Busiest: none")


def test_nested_measured_work_is_not_counted_twice(lua: Any) -> None:
    # A MOOSE timer calls into another script through RetProfiler.measure (which
    # is what RetUtils.guardedCall does): the inner script gets its own time and
    # MOOSE keeps only what it used itself.
    lua.execute("""
        load_script("ewrj/EW script.lua", [[
            function jam(a, b, c, d) jam_arguments = { a, b, c, d } work(3) return "jammed" end
            timer.scheduleFunction(function() end, nil, 1)
        ]])
        load_script("base/Moose.lua", [[
            timer.scheduleFunction(function()
                work(1)
                measured = RetProfiler.measure(jam, 1, 2, 3, 4)
            end, nil, 1)
        ]])
        timers[3].fn(nil, 1)
        run_report(60)
        """)
    assert lua.globals().measured == "jammed"
    assert list(lua.globals().jam_arguments.values()) == [1, 2, 3, 4]
    (line,) = _log(lua)
    assert "mission scripts used 4.0 s" in line
    assert "ewrj/EW script.lua 3.0 s (1 calls, max 3000 ms)" in line
    assert "base/Moose.lua 1.0 s (1 calls, max 4000 ms)" in line


def test_scheduled_functions_behave_as_before(lua: Any) -> None:
    lua.execute("""
        timer_id = timer.scheduleFunction(function(argument, now)
            seen = { argument, now }
            return now + 5
        end, "payload", 42)
        rescheduled = timers[2].fn(timers[2].argument, 42)
        timer.scheduleFunction(function() error("boom") end, nil, 1)
        ok, message = pcall(timers[3].fn, nil, 1)
        """)
    g = lua.globals()
    assert g.timer_id == 2
    assert g.timers[2].argument == "payload"
    assert g.timers[2].time == 42
    assert list(g.seen.values()) == ["payload", 42]
    assert g.rescheduled == 47
    # The error still reaches DCS, with the script's own message.
    assert g.ok is False
    assert "boom" in g.message


def test_event_handler_keeps_its_identity_and_is_wrapped_once(lua: Any) -> None:
    lua.execute("""
        handler = { calls = 0 }
        function handler:onEvent(event)
            self.calls = self.calls + 1
            last_event = event
        end
        world.addEventHandler(handler)
        world.addEventHandler(handler)
        handlers[2]:onEvent({ id = 7 })
        same_table = handlers[1] == handler and handlers[2] == handler
        """)
    g = lua.globals()
    assert g.same_table is True
    assert g.handler.calls == 1
    assert g.last_event.id == 7


def test_unlabelled_script_is_reported_under_its_file_name(lua: Any) -> None:
    lua.execute("""
        local chunk = assert(loadstring(
            "timer.scheduleFunction(function() work(1) end, nil, 1)",
            "C:\\\\Temp\\\\DCS\\\\~mis00001234.lua"
        ))
        chunk()
        timers[2].fn(nil, 1)
        run_report(60)
        """)
    (line,) = _log(lua)
    assert "Busiest: ~mis00001234.lua 1.0 s" in line


def test_does_nothing_in_a_sanitised_environment() -> None:
    runtime = lua51.LuaRuntime(unpack_returned_tuples=True)
    runtime.execute(MOCK_ENVIRONMENT)
    runtime.execute("os = nil original_schedule = timer.scheduleFunction")
    runtime.execute(PROFILER.read_text(encoding="utf-8"))
    runtime.execute("""
        RetProfiler.loading("anything")
        result = RetProfiler.measure(function(a, b) return a + b end, 1, 2)
        untouched = timer.scheduleFunction == original_schedule and #timers == 0
        """)
    assert runtime.globals().result == 3
    assert runtime.globals().untouched is True


def test_profiler_is_the_first_base_script() -> None:
    # It can only measure scripts that are loaded after it, MOOSE included.
    import json

    orders = json.loads((PROFILER.parent / "plugin.json").read_text(encoding="utf-8"))
    assert orders["scriptsWorkOrders"][0]["file"] == "script_profiler.lua"
