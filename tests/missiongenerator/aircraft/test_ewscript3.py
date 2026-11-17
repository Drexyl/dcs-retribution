from __future__ import annotations

from types import SimpleNamespace
from typing import Any, Optional

import pytest

from game.ato.flightwaypointtype import FlightWaypointType
from game.data.weapons import Weapon
from game.missiongenerator.aircraft import ewscript3

ALQ99_HI = "{SUPERHORNET_PYLON_03_MB_ALQ_99_HI_BAND}"
ALQ99_LO = "{SUPERHORNET_PYLON_06_CN_ANALQ_99_LO_BAND}"
ALQ249 = "{SUPERHORNET_PYLON_03_MB_ALQ_249_MID_BAND}"
EA6B_ALQ99 = "{EA6B_ANALQ991}"


def _weapon(clsid: str) -> Weapon:
    weapon = Weapon.with_clsid(clsid)
    assert weapon is not None, clsid
    return weapon


def _member(clsids: list[Optional[str]]) -> Any:
    pylons = {
        i: (_weapon(c) if c is not None else None) for i, c in enumerate(clsids, 1)
    }
    return SimpleNamespace(loadout=SimpleNamespace(pylons=pylons))


def _flight(
    built_in: bool = False,
    waypoint_types: tuple[Any, ...] = (),
    built_in_ecm: bool = False,
) -> Any:
    waypoints = [SimpleNamespace(waypoint_type=t) for t in waypoint_types]
    return SimpleNamespace(
        squadron=SimpleNamespace(
            aircraft=SimpleNamespace(
                has_built_in_jamming=built_in, has_built_in_ecm=built_in_ecm
            )
        ),
        flight_plan=SimpleNamespace(iter_waypoints=lambda: iter(waypoints)),
    )


@pytest.mark.parametrize(
    "clsids,expected,max_targets",
    [
        ([ALQ99_HI, ALQ99_LO, ALQ99_HI], "3xALQ99", 6),
        ([ALQ99_HI, None, ALQ99_HI], "2xALQ99", 4),
        ([None, ALQ99_LO, None], "1xALQ99", 2),
        ([ALQ249, None, ALQ249], "2xALQ249", 6),
        ([ALQ249, ALQ99_LO, ALQ249], "2xALQ249_1xALQ99", 9),
        ([ALQ249, ALQ99_LO, ALQ99_HI], "1xALQ249_2xALQ99", 6),
        ([ALQ249, ALQ99_LO, None], "1xALQ249_1xALQ99", 4),
        ([ALQ249, None, None], "1xALQ249", 4),
        ([EA6B_ALQ99] * 5, "3xALQ99", 6),
    ],
)
def test_loadout_key_from_pods(
    clsids: list[Optional[str]], expected: str, max_targets: int
) -> None:
    member = _member(clsids)
    flight = _flight()
    assert ewscript3.jammer_loadout_key(member, flight) == expected
    assert ewscript3.jammer_max_targets(member, flight) == max_targets


ALQ131 = "{6D21ECEA-F85B-4E8D-9D51-31DC9B8AA4EF}"
ALQ184 = "ALQ_184"
ALQ164 = "{ALQ_164_RF_Jammer}"


def test_self_protection_pods_are_not_aea_jammers() -> None:
    assert ewscript3.jammer_loadout_key(_member([ALQ184]), _flight()) is None


@pytest.mark.parametrize(
    "clsid,gen,pod",
    [
        (ALQ131, 1, "AN/ALQ-131 ECM"),
        (ALQ184, 2, "AN/ALQ-184 ECM"),
        (ALQ164, 3, "AN/ALQ-164 DECM Pod"),
    ],
)
def test_self_protection_generation(clsid: str, gen: int, pod: str) -> None:
    spj = ewscript3.self_protection_jammer(_member([clsid]), _flight(), _settings())
    assert spj == (gen, pod)


def test_self_protection_best_pod_wins() -> None:
    member = _member([ALQ131, ALQ164])
    assert ewscript3.self_protection_jammer(member, _flight(), _settings()) == (
        3,
        "AN/ALQ-164 DECM Pod",
    )


@pytest.mark.parametrize(
    "option,expected", [(True, (3, "internal ECM")), (False, None)]
)
def test_self_protection_internal_ecm(
    option: bool, expected: Optional[tuple[int, str]]
) -> None:
    flight = _flight(built_in_ecm=True)
    settings = _settings(internal_ecm=option)
    assert ewscript3.self_protection_jammer(_member([None]), flight, settings) == (
        expected
    )


def test_aea_jammer_is_not_self_protection() -> None:
    member = _member([ALQ99_HI, ALQ184])
    flight = _flight(built_in_ecm=True)
    assert ewscript3.self_protection_jammer(member, flight, _settings()) is None


def test_no_ecm_no_self_protection() -> None:
    assert ewscript3.self_protection_jammer(
        _member([None]), _flight(), _settings()
    ) is (None)


def test_register_self_protect_script() -> None:
    assert ewscript3.register_self_protect_script(
        "Viper-1", 2, "AN/ALQ-184 ECM", ai=True
    ) == (
        "if AEA_RegisterSelfProtect then AEA_RegisterSelfProtect("
        '"Viper-1", {gen=2, pod="AN/ALQ-184 ECM", ai=true}) end'
    )


def test_no_pods_no_jammer() -> None:
    assert ewscript3.jammer_loadout_key(_member([None, None]), _flight()) is None


def test_built_in_jamming_without_pods() -> None:
    flight = _flight(built_in=True)
    assert ewscript3.jammer_loadout_key(_member([None]), flight) == "2xALQ99"
    assert ewscript3.jammer_max_targets(_member([None]), flight) == 4


@pytest.mark.parametrize(
    "types,gated",
    [
        ((FlightWaypointType.TAKEOFF, FlightWaypointType.JOIN), True),
        ((FlightWaypointType.TAKEOFF, FlightWaypointType.PATROL_TRACK), True),
        ((FlightWaypointType.TAKEOFF, FlightWaypointType.LANDING_POINT), False),
    ],
)
def test_flight_has_jamming_window(types: tuple[Any, ...], gated: bool) -> None:
    assert ewscript3.flight_has_jamming_window(_flight(waypoint_types=types)) is gated


def test_register_script_ai() -> None:
    script = ewscript3.register_jammer_script(
        'Growler "1"', "2xALQ99", ai=True, gated=True, max_targets=4
    )
    assert script == (
        "if AEA_RegisterJammer then AEA_RegisterJammer("
        '"Growler \\"1\\"", {loadout="2xALQ99", ai=true, gated=true, maxTargets=4})'
        " end"
    )


def test_register_script_player() -> None:
    script = ewscript3.register_jammer_script(
        "Growler-1", "2xALQ249", ai=False, gated=True, max_targets=4
    )
    assert '{loadout="2xALQ249", ai=false}' in script


def test_set_armed_script() -> None:
    assert ewscript3.set_armed_script("Growler-1", False) == (
        'if AEA_SetArmed then AEA_SetArmed("Growler-1", false) end'
    )


def _settings(
    enabled: bool = True,
    ai: bool = True,
    players: bool = True,
    spj: bool = True,
    spj_players: bool = True,
    internal_ecm: bool = True,
) -> Any:
    from game.settings import Settings

    settings = Settings()
    settings.plugins["EWScript3"] = enabled
    settings.set_plugin_option("EWScript3.ai_enabled", ai)
    settings.set_plugin_option("EWScript3.players_enabled", players)
    settings.set_plugin_option("EWScript3.spj_enabled", spj)
    settings.set_plugin_option("EWScript3.spj_players", spj_players)
    settings.set_plugin_option("EWScript3.spj_internal_ecm", internal_ecm)
    return settings


def _configurator(
    settings: Any, is_player: bool, pods: Optional[list[Optional[str]]] = None
) -> tuple[Any, Any, Any, Any]:
    from dcs import Mission

    from game.missiongenerator.aircraft.flightgroupconfigurator import (
        FlightGroupConfigurator,
    )

    flight = _flight(waypoint_types=(FlightWaypointType.JOIN,))
    flight.coalition = SimpleNamespace(game=SimpleNamespace(settings=settings))
    configurator = FlightGroupConfigurator.__new__(FlightGroupConfigurator)
    configurator.flight = flight
    configurator.mission = Mission()
    member = _member(pods or [ALQ99_HI, ALQ99_LO, ALQ99_HI])
    member.is_player = is_player
    unit = SimpleNamespace(name="Growler-1")
    return configurator, member, unit, configurator.mission


def _scripts(mission: Any) -> list[str]:
    from dcs.action import DoScript

    return [
        action.text.id
        for trigger in mission.triggerrules.triggers
        for action in trigger.actions
        if isinstance(action, DoScript)
    ]


def test_configurator_registers_ai_jammer() -> None:
    configurator, member, unit, mission = _configurator(_settings(), False)
    configurator.handle_ewscript3(member, unit)
    scripts = _scripts(mission)
    assert len(scripts) == 1
    assert 'AEA_RegisterJammer("Growler-1"' in scripts[0]
    assert "ai=true, gated=true, maxTargets=6" in scripts[0]


def test_configurator_registers_player_jammer() -> None:
    configurator, member, unit, mission = _configurator(_settings(), True)
    configurator.handle_ewscript3(member, unit)
    assert '{loadout="3xALQ99", ai=false}' in _scripts(mission)[0]


@pytest.mark.parametrize(
    "settings,is_player",
    [
        (dict(enabled=False), False),
        (dict(ai=False), False),
        (dict(players=False), True),
    ],
)
def test_configurator_respects_options(
    settings: dict[str, bool], is_player: bool
) -> None:
    configurator, member, unit, mission = _configurator(
        _settings(**settings), is_player
    )
    configurator.handle_ewscript3(member, unit)
    assert _scripts(mission) == []


def test_configurator_registers_self_protection() -> None:
    configurator, member, unit, mission = _configurator(_settings(), False, [ALQ184])
    configurator.handle_ewscript3(member, unit)
    scripts = _scripts(mission)
    assert len(scripts) == 1
    assert (
        'AEA_RegisterSelfProtect("Growler-1", {gen=2, pod="AN/ALQ-184 ECM", ai=true})'
        in scripts[0]
    )


@pytest.mark.parametrize(
    "settings,is_player",
    [
        (dict(spj=False), False),
        (dict(spj_players=False), True),
        (dict(enabled=False), False),
    ],
)
def test_configurator_self_protection_options(
    settings: dict[str, bool], is_player: bool
) -> None:
    configurator, member, unit, mission = _configurator(
        _settings(**settings), is_player, [ALQ184]
    )
    configurator.handle_ewscript3(member, unit)
    assert _scripts(mission) == []


def test_waypoint_window_only_for_ai_jammers() -> None:
    from dcs import Point
    from dcs.point import MovingPoint
    from dcs.task import RunScript
    from dcs.terrain import Caucasus

    from game.missiongenerator.aircraft.waypoints.pydcswaypointbuilder import (
        PydcsWaypointBuilder,
    )

    flight = _flight()
    flight.coalition = SimpleNamespace(game=SimpleNamespace(settings=_settings()))
    ai_jammer = _member([ALQ249, None, ALQ249])
    ai_jammer.is_player = False
    player_jammer = _member([ALQ249, None, ALQ249])
    player_jammer.is_player = True
    no_pods = _member([None])
    no_pods.is_player = False
    flight.iter_members = lambda: iter([ai_jammer, player_jammer, no_pods])

    builder = PydcsWaypointBuilder.__new__(PydcsWaypointBuilder)
    builder.flight = flight
    builder.group = SimpleNamespace(  # type: ignore[assignment]
        units=[SimpleNamespace(name=n) for n in ("AI-1", "Player-2", "Bomber-3")]
    )
    waypoint = MovingPoint(Point(0, 0, Caucasus()))
    builder.ewscript3_window(waypoint, True)
    scripts = [t for t in waypoint.tasks if isinstance(t, RunScript)]
    assert len(scripts) == 1
    assert (
        'AEA_SetArmed("AI-1", true)' in scripts[0].params["action"]["params"]["command"]
    )
