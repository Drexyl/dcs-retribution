from types import SimpleNamespace
from typing import Any, cast

from dcs import Mission
from dcs.mapping import Point
from dcs.terrain import Caucasus
from dcs.unitgroup import VehicleGroup

from game import Game
from game.missiongenerator.ctldtemplategenerator import (
    TROOP_LOADOUTS,
    CtldTemplateGenerator,
)
from game.missiongenerator.missiondata import CargoInfo, LogisticsInfo, MissionData
from game.theater.player import Player


def _game() -> Game:
    countries = {Player.BLUE: "USA", Player.RED: "Russia"}
    terrain = Caucasus()
    control_points = [
        SimpleNamespace(captured=Player.RED, position=Point(1000, 2000, terrain)),
        SimpleNamespace(captured=Player.BLUE, position=Point(5000, 6000, terrain)),
    ]
    return cast(
        Game,
        SimpleNamespace(
            theater=SimpleNamespace(controlpoints=control_points),
            coalition_for=lambda player: SimpleNamespace(
                faction=SimpleNamespace(country=SimpleNamespace(name=countries[player]))
            ),
        ),
    )


def _logistics(player: Player, cargo: list[CargoInfo]) -> LogisticsInfo:
    return LogisticsInfo(
        pilot_names=["pilot"],
        transport=cast(Any, None),
        blue=player,
        cargo=cargo,
    )


def _groups(mission: Mission, country: str) -> dict[str, VehicleGroup]:
    return {g.name: g for g in mission.country(country).vehicle_group}


def test_templates_per_coalition_with_logistics() -> None:
    mission = Mission(Caucasus())
    mission_data = MissionData()
    mission_data.logistics = [
        _logistics(Player.BLUE, [CargoInfo("M-113", "zone a", 2)]),
        _logistics(Player.BLUE, [CargoInfo("M-113", "zone b", 1)]),
    ]

    CtldTemplateGenerator(mission, _game(), mission_data).generate()

    blue = _groups(mission, "USA")
    assert not _groups(mission, "Russia")
    assert len(mission_data.ctld_troop_templates) == len(TROOP_LOADOUTS)
    for template in mission_data.ctld_troop_templates:
        group = blue[template.group_name]
        assert template.side == 2
        assert len(group.units) == template.troops
        assert group.late_activation and group.hidden
    assert [t.unit_type for t in mission_data.ctld_crate_templates] == ["M-113"]
    crate_group = blue[mission_data.ctld_crate_templates[0].group_name]
    assert [u.type for u in crate_group.units] == ["M-113"]
    assert crate_group.late_activation
    assert crate_group.units[0].position.x == 5000


def test_troop_composition_matches_coalition() -> None:
    mission = Mission(Caucasus())
    mission_data = MissionData()
    mission_data.logistics = [_logistics(Player.RED, [])]

    CtldTemplateGenerator(mission, _game(), mission_data).generate()

    red = _groups(mission, "Russia")
    six = red["CTLD Red Troops (6)"]
    assert sorted(u.type for u in six.units) == sorted(
        ["Soldier AK"] * 4 + ["Paratrooper AKS-74", "Paratrooper RPG-16"]
    )
    assert "SA-18 Igla manpad" in [u.type for u in red["CTLD Red Troops (12)"].units]
    assert mission_data.ctld_troop_templates[0].side == 1
    assert not mission_data.ctld_crate_templates
    unit_names = [u.name for g in red.values() for u in g.units]
    assert len(unit_names) == len(set(unit_names))


def test_no_templates_without_logistics() -> None:
    mission = Mission(Caucasus())
    mission_data = MissionData()

    CtldTemplateGenerator(mission, _game(), mission_data).generate()

    assert not mission_data.ctld_troop_templates
    assert not _groups(mission, "USA")
