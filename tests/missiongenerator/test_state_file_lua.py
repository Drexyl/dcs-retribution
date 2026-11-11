"""Runs dcs_retribution.lua's state writer under Lua 5.1 with a mocked DCS/MOOSE.

The state file is encoded incrementally (each event is encoded once and the text
is reused on later writes), so these tests check that what lands on disk is
still exactly the JSON document the debriefing code expects, write after write.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import pytest

lua51 = pytest.importorskip("lupa.lua51")

BASE_PLUGIN = Path(__file__).resolve().parents[2] / "resources" / "plugins" / "base"

MOCK_ENVIRONMENT = """
warnings = {}
env = {
    info = function() end,
    warning = function(message) warnings[#warnings + 1] = message end,
    error = function() end,
}
-- Real time is driven by the tests.
fake_clock = 0
os.clock = function() return fake_clock end
scheduled = {}
world = {
    event = {
        S_EVENT_CRASH = 1, S_EVENT_UNIT_LOST = 2, S_EVENT_KILL = 3, S_EVENT_DEAD = 4,
        S_EVENT_EJECTION = 5, S_EVENT_LANDING_AFTER_EJECTION = 6, S_EVENT_MISSION_END = 7,
    },
    addEventHandler = function(handler) event_handler = handler end,
}
timer = {
    getTime = function() return 0 end,
    scheduleFunction = function(fn) scheduled[#scheduled + 1] = fn end,
}
TIMER = {
    New = function() return { Start = function() end } end,
}
MESSAGE = { New = function() return { ToAll = function() end } end }
UTILS = { GetDirectionRadians = function() return 0 end }
RetUtils = {
    getGroupNameById = function() return nil end,
    guardedCall = function(_, fn, ...) return pcall(fn, ...) end,
}
"""


def _read(path: Path) -> str:
    return path.read_text(encoding="utf-8-sig")


@pytest.fixture
def lua(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Any:
    # dcs_retribution.lua looks for a writable folder via this variable first.
    monkeypatch.setenv("RETRIBUTION_EXPORT_DIR", str(tmp_path))
    monkeypatch.delenv("RETRIBUTION_EXPORT_STAMPED_STATE", raising=False)
    runtime = lua51.LuaRuntime(unpack_returned_tuples=True)
    runtime.execute(MOCK_ENVIRONMENT)
    runtime.execute(_read(BASE_PLUGIN / "json.lua"))
    runtime.execute(_read(BASE_PLUGIN / "dcs_retribution.lua"))
    return runtime


def _state(tmp_path: Path) -> Any:
    return json.loads((tmp_path / "state.json").read_text(encoding="utf-8"))


def test_initial_state_file_has_every_key(lua: Any, tmp_path: Path) -> None:
    # Loading the script writes the state once.
    assert _state(tmp_path) == {
        "crash_events": [],
        "dead_events": [],
        "base_capture_events": [],
        "unit_lost_events": [],
        "kill_events": [],
        "mission_ended": False,
        "destroyed_objects_positions": [],
        "ejection_events": [],
        "csar_rescued": [],
    }


def test_state_is_complete_after_incremental_writes(lua: Any, tmp_path: Path) -> None:
    lua.execute("""
        dead_events[#dead_events + 1] = 'Tank "Alpha" | 1'
        kill_events[#kill_events + 1] = "Backslash \\\\ unit"
        destroyed_objects_positions[#destroyed_objects_positions + 1] =
            { x = 1.5, y = 2, z = -3.25, type = "T-72B", orientation = 90 }
        ejection_events[#ejection_events + 1] = { unit = "Viper 1-1", x = 10, z = 20 }
        write_state()
        """)
    first = _state(tmp_path)
    assert first["dead_events"] == ['Tank "Alpha" | 1']
    assert first["kill_events"] == ["Backslash \\ unit"]
    assert first["destroyed_objects_positions"] == [
        {"x": 1.5, "y": 2, "z": -3.25, "type": "T-72B", "orientation": 90}
    ]
    assert first["ejection_events"] == [{"unit": "Viper 1-1", "x": 10, "z": 20}]

    # A second write must contain the old entries, the new ones, and the
    # in-place update of an existing ejection entry.
    lua.execute("""
        dead_events[#dead_events + 1] = "Second"
        base_capture_events[#base_capture_events + 1] = "cp||2||Base"
        csar_rescued[#csar_rescued + 1] = "uuid-1"
        ejection_events[1].x = 11
        ejection_events[1].landed = true
        mission_ended = true
        write_state()
        """)
    second = _state(tmp_path)
    assert second["dead_events"] == ['Tank "Alpha" | 1', "Second"]
    assert second["kill_events"] == ["Backslash \\ unit"]
    assert second["base_capture_events"] == ["cp||2||Base"]
    assert second["csar_rescued"] == ["uuid-1"]
    assert second["ejection_events"] == [
        {"unit": "Viper 1-1", "x": 11, "z": 20, "landed": True}
    ]
    assert second["mission_ended"] is True


def test_replaced_list_is_encoded_from_scratch(lua: Any, tmp_path: Path) -> None:
    lua.execute("""
        csar_rescued[#csar_rescued + 1] = "old-1"
        csar_rescued[#csar_rescued + 1] = "old-2"
        write_state()
        csar_rescued = { "new-1" }
        write_state()
        """)
    assert _state(tmp_path)["csar_rescued"] == ["new-1"]


def test_matches_a_full_encode_of_the_same_state(lua: Any, tmp_path: Path) -> None:
    lua.execute("""
        for i = 1, 300 do
            dead_events[i] = "Unit #" .. i
            unit_lost_events[i] = "Unit #" .. i
            destroyed_objects_positions[i] =
                { x = i + 0.5, y = 0, z = -i, type = "Type " .. i, orientation = i % 360 }
            if i % 100 == 0 then
                write_state()
            end
        end
        reference = json:encode({
            crash_events = crash_events,
            dead_events = dead_events,
            base_capture_events = base_capture_events,
            unit_lost_events = unit_lost_events,
            kill_events = kill_events,
            mission_ended = mission_ended,
            destroyed_objects_positions = destroyed_objects_positions,
            ejection_events = ejection_events,
            csar_rescued = csar_rescued,
        })
        """)
    assert _state(tmp_path) == json.loads(lua.globals().reference)


def test_stall_monitor_reports_only_when_real_time_runs_ahead(lua: Any) -> None:
    # The stall monitor is the first function the script schedules.
    lua.execute("""
        monitor = scheduled[1]
        -- One second of mission time took one second of real time: healthy.
        fake_clock = 1.0
        next_call = monitor(nil, 1)
        healthy_warnings = #warnings
        -- The next second of mission time took four seconds of real time.
        fake_clock = 5.0
        monitor(nil, 2)
        """)
    assert lua.globals().next_call == 2
    assert lua.globals().healthy_warnings == 0
    stall_warnings = list(lua.globals().warnings.values())
    assert len(stall_warnings) == 1
    assert "simulation stalled for 3.0 s" in stall_warnings[0]


def test_events_are_recorded_through_the_registered_handler(
    lua: Any, tmp_path: Path
) -> None:
    lua.execute("""
        local unit = {
            getName = function() return "Viper 1-1" end,
        }
        event_handler:onEvent({ id = world.event.S_EVENT_CRASH, initiator = unit })
        event_handler:onEvent({ id = world.event.S_EVENT_MISSION_END })
        """)
    state = _state(tmp_path)
    assert state["crash_events"] == ["Viper 1-1"]
    assert state["mission_ended"] is True
