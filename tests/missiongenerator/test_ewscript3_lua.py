"""Behavioural tests of the EW Script 3.0 Lua plugin against a mocked DCS API."""

from __future__ import annotations

from pathlib import Path
from typing import Any, Iterator

import pytest

lupa = pytest.importorskip("lupa.lua51")

REPO = Path(__file__).resolve().parents[2]
PLUGIN = REPO / "resources" / "plugins" / "EWScript3"
MOCK = Path(__file__).parent / "ewscript3_dcs_mock.lua"

WORLD = """
NM = 1852
addGroup(coalition.side.BLUE, Group.Category.AIRPLANE, "Growler", {
  {name="Growler-1", type="EA-18G", pos={x=0, y=7000, z=0}, radar=true},
})
addGroup(coalition.side.BLUE, Group.Category.AIRPLANE, "Strike", {
  {name="Strike-1", type="F-16C_50", pos={x=5000, y=7000, z=0}, radar=true},
})
addGroup(coalition.side.RED, Group.Category.GROUND, "SA-11 site", {
  {name="SA11-SR", type="SA-11 Buk SR 9S18M1", pos={x=40*NM, y=0, z=0}, attr={["SAM SR"]=true}, radarOn=true},
  {name="SA11-LN", type="SA-11 Buk LN 9A310M1", pos={x=40*NM+200, y=0, z=0}, attr={["SAM TR"]=true}, radarOn=false},
})
addGroup(coalition.side.BLUE, Group.Category.GROUND, "Blue Hawk", {
  {name="Hawk-SR", type="Hawk sr", pos={x=-20*NM, y=0, z=0}, attr={["SAM SR"]=true}, radarOn=true},
  {name="Hawk-TR", type="Hawk tr", pos={x=-20*NM, y=0, z=200}, attr={["SAM TR"]=true}, radarOn=true},
})
"""


class Sim:
    def __init__(self, options: str, ewrj: bool = False) -> None:
        self.lua = lupa.LuaRuntime()
        self.lua.execute(MOCK.read_text(encoding="utf-8"))
        self.lua.execute("math.randomseed(1)")
        self.lua.execute(WORLD)
        ewrj_cfg = ", ewrj = {}" if ewrj else ""
        self.lua.execute(
            f"dcsRetribution = {{plugins = {{EWScript3 = {{{options}}}{ewrj_cfg}}}}}"
        )
        self.lua.execute(
            (PLUGIN / "Growler_AEA_with_MRAD.lua").read_text(encoding="utf-8")
        )
        self.lua.execute((PLUGIN / "ewscript3_config.lua").read_text(encoding="utf-8"))
        self.g: Any = self.lua.globals()

    def run(self, code: str) -> None:
        self.lua.execute(code)

    def advance(self, seconds: float) -> None:
        self.g.advance(seconds)

    def logs(self) -> list[str]:
        return list(self.g.LOG.values())

    def roe(self) -> dict[str, int]:
        return dict(self.g.ROE)

    def has_log(self, *needles: str) -> bool:
        return any(all(n in line for n in needles) for line in self.logs())


@pytest.fixture
def sim() -> Iterator[Sim]:
    s = Sim("DEBUG_LOG=true, ai_hold_sec=30")
    s.run(
        'AEA_RegisterJammer("Growler-1", '
        '{loadout="2xALQ99", ai=true, gated=true, maxTargets=4})'
    )
    yield s


def light_up(sim: Sim) -> None:
    sim.run('U("SA11-LN")._radarOn = true; U("SA11-LN")._tracked = U("Strike-1")')


def test_ai_jammer_silent_outside_mission_window(sim: Sim) -> None:
    light_up(sim)
    sim.advance(20)
    assert not sim.has_log("XMIT ON")
    assert "SA11-SR" not in sim.roe() and "SA11-LN" not in sim.roe()


def test_ai_jammer_waits_for_threat_when_armed(sim: Sim) -> None:
    sim.run('AEA_SetArmed("Growler-1", true)')
    sim.advance(20)
    assert sim.has_log("ARMED")
    assert not sim.has_log("XMIT ON")


def test_ai_jammer_transmits_when_package_lit_up(sim: Sim) -> None:
    sim.run('AEA_SetArmed("Growler-1", true)')
    sim.advance(4)
    light_up(sim)
    sim.advance(30)
    assert sim.has_log("XMIT ON", "LIT UP", "tracking Strike-1")
    # enemy SAM radars are jammed (suppressed or resisting through ECCM) ...
    assert sim.has_log("JAM 1/1 groups in range [SA-11 site]")
    # ... friendly SAMs never are
    assert "Hawk-SR" not in sim.roe() and "Hawk-TR" not in sim.roe()


def test_ai_jammer_goes_quiet_after_hold(sim: Sim) -> None:
    sim.run('AEA_SetArmed("Growler-1", true)')
    light_up(sim)
    sim.advance(10)
    sim.run('U("SA11-LN")._radarOn = false; U("SA11-LN")._tracked = nil')
    sim.advance(20)
    assert not sim.has_log("XMIT OFF")
    sim.advance(30)
    assert sim.has_log("XMIT OFF", "no threat for 30s")
    # suppressed SAMs are released again
    assert all(v == 2 for v in sim.roe().values())


def test_ai_jammer_stops_at_split(sim: Sim) -> None:
    sim.run('AEA_SetArmed("Growler-1", true)')
    light_up(sim)
    sim.advance(10)
    sim.run('AEA_SetArmed("Growler-1", false)')
    sim.advance(4)
    assert sim.has_log("XMIT OFF", "outside mission window")


def test_ungated_ai_jammer_reacts_anywhere() -> None:
    s = Sim("DEBUG_LOG=true")
    s.run('AEA_RegisterJammer("Growler-1", {loadout="2xALQ99", ai=true, gated=false})')
    light_up(s)
    s.advance(10)
    assert s.has_log("XMIT ON")


def test_window_gating_option_disabled() -> None:
    s = Sim("DEBUG_LOG=true, ai_window_gating=false")
    s.run('AEA_RegisterJammer("Growler-1", {loadout="2xALQ99", ai=true, gated=true})')
    light_up(s)
    s.advance(10)
    assert s.has_log("XMIT ON")


def test_search_radar_only_with_option() -> None:
    quiet = Sim("DEBUG_LOG=true")
    quiet.run('AEA_RegisterJammer("Growler-1", {ai=true, gated=false})')
    quiet.advance(10)
    assert not quiet.has_log("XMIT ON")

    s = Sim("DEBUG_LOG=true, ai_jam_search=true")
    s.run('AEA_RegisterJammer("Growler-1", {ai=true, gated=false})')
    s.advance(10)
    assert s.has_log("XMIT ON", "SEARCH radar")


def test_missile_disruption_only_hits_enemy_radar_missiles(sim: Sim) -> None:
    sim.run('AEA_SetArmed("Growler-1", true)')
    light_up(sim)
    sim.advance(6)
    sim.run("""
      fireShot(U("Growler-1"), makeWeapon("AIM120", coalition.side.BLUE, "AIM_120C",
        Weapon.GuidanceType.RADAR_ACTIVE, {x=3000,y=7000,z=0}, U("SA11-LN")))
      fireShot(U("SA11-LN"), makeWeapon("HARM", coalition.side.RED, "X_58",
        Weapon.GuidanceType.RADAR_PASSIVE, {x=2000,y=7000,z=0}, U("Growler-1")))
      for i = 1, 20 do
        fireShot(U("SA11-LN"), makeWeapon("SAM" .. i, coalition.side.RED, "SA9M317",
          Weapon.GuidanceType.RADAR_SEMI_ACTIVE, {x=6000,y=7000,z=0}, U("Strike-1")))
      end
    """)
    sim.advance(10)
    destroyed = list(sim.g.DESTROYED.values())
    assert "AIM120" not in destroyed
    assert "HARM" not in destroyed
    assert 0 < len([d for d in destroyed if d.startswith("SAM")]) < 20
    assert sim.has_log("POWER NORM -> HIGH")


def test_unregistered_set_armed_is_ignored(sim: Sim) -> None:
    sim.run('AEA_SetArmed("Nobody", true)')
    assert sim.has_log("Nobody", "not a registered jammer")


def test_ai_disabled_option_skips_registration() -> None:
    s = Sim("DEBUG_LOG=true, ai_enabled=false")
    s.run('AEA_RegisterJammer("Growler-1", {ai=true, gated=false})')
    light_up(s)
    s.advance(10)
    assert s.has_log("AI jammers disabled")
    assert not s.has_log("XMIT ON")


def test_player_jammer_menu_and_manual_xmit() -> None:
    s = Sim("DEBUG_LOG=true")
    s.run('U("Growler-1")._player = "Pilot"')
    s.run('AEA_RegisterJammer("Growler-1", {loadout="2xALQ249", ai=false})')
    s.advance(3)
    assert s.has_log("AEA menu built", "2xALQ249")
    # player jammers are never switched on by the AI controller
    light_up(s)
    s.advance(10)
    assert not s.has_log("XMIT ON")


def test_name_prefix_fallback_registers_units() -> None:
    s = Sim("DEBUG_LOG=true")
    s.run("""
      addGroup(coalition.side.BLUE, Group.Category.AIRPLANE, "Manual", {
        {name="[EA-18G] Manual-1", type="EA-18G", pos={x=0, y=7000, z=1000}},
      })
    """)
    s.advance(2)
    assert s.has_log("[EA-18G] Manual-1: registered (AI)")


def test_both_ew_scripts_enabled_warns() -> None:
    s = Sim("", ewrj=True)
    assert any("both enabled" in line for line in s.logs())
    assert any("both enabled" in line for line in s.g.OUT.values())


def test_no_warning_without_ewrj() -> None:
    s = Sim("")
    assert not any("both enabled" in line for line in s.logs())
