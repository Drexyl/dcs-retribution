"""Template groups for the MOOSE CTLD plugin.

MOOSE's CTLD spawns troops and crate-built vehicles from groups that exist in
the mission as late-activated templates. This generator adds one hidden,
late-activated template group per troop loadout and per airlifted vehicle type
for every coalition that has logistics flights, and records their names in the
mission data so the CTLD plugin can register them as cargo.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import TYPE_CHECKING

from dcs import Mission
from dcs.mapping import Point
from dcs.point import PointAction
from dcs.unit import Vehicle
from dcs.unitgroup import VehicleGroup
from dcs.vehicles import AirDefence, Infantry

from game.missiongenerator.missiondata import (
    CtldCrateTemplate,
    CtldTroopTemplate,
    MissionData,
)
from game.theater.player import Player

if TYPE_CHECKING:
    from game import Game

# Soldier types per role, matching what the original CTLD script spawned.
_SOLDIER_TYPES: dict[str, dict[Player, str]] = {
    "inf": {Player.BLUE: Infantry.Soldier_M4.id, Player.RED: Infantry.Soldier_AK.id},
    "mg": {
        Player.BLUE: Infantry.Soldier_M249.id,
        Player.RED: Infantry.Paratrooper_AKS_74.id,
    },
    "at": {
        Player.BLUE: Infantry.Paratrooper_RPG_16.id,
        Player.RED: Infantry.Paratrooper_RPG_16.id,
    },
    "aa": {
        Player.BLUE: AirDefence.Soldier_stinger.id,
        Player.RED: AirDefence.SA_18_Igla_manpad.id,
    },
}

# The troop loadouts offered in the CTLD menu, as in the original CTLD config.
TROOP_LOADOUTS: list[tuple[int, dict[str, int]]] = [
    (2, {"inf": 2}),
    (4, {"inf": 4}),
    (6, {"inf": 4, "mg": 1, "at": 1}),
    (10, {"inf": 5, "mg": 2, "at": 2, "aa": 1}),
    (12, {"inf": 6, "mg": 2, "at": 2, "aa": 2}),
    (24, {"inf": 13, "mg": 4, "at": 4, "aa": 3}),
]

# Spacing between the units of a template; CTLD keeps the template's layout
# when it spawns the group.
_UNIT_SPACING = 3


@dataclass(frozen=True)
class _TemplateUnit:
    name: str
    type_id: str


class CtldTemplateGenerator:
    def __init__(self, mission: Mission, game: Game, mission_data: MissionData) -> None:
        self.mission = mission
        self.game = game
        self.mission_data = mission_data

    def generate(self) -> None:
        sides: dict[Player, set[str]] = {}
        for logistics in self.mission_data.logistics:
            cargo_types = sides.setdefault(logistics.blue, set())
            cargo_types.update(cargo.unit_type for cargo in logistics.cargo)

        for player, cargo_types in sides.items():
            self._generate_for_side(player, sorted(cargo_types))

    def _generate_for_side(self, player: Player, cargo_types: list[str]) -> None:
        side = 2 if player.is_blue else 1
        color = "Blue" if player.is_blue else "Red"
        position = self._template_position(player)

        for troops, composition in TROOP_LOADOUTS:
            group_name = f"CTLD {color} Troops ({troops})"
            units = [
                _TemplateUnit(f"{group_name} #{index + 1}", type_id)
                for index, type_id in enumerate(
                    _SOLDIER_TYPES[role][player]
                    for role, count in composition.items()
                    for _ in range(count)
                )
            ]
            self._add_template(player, group_name, units, position)
            self.mission_data.ctld_troop_templates.append(
                CtldTroopTemplate(
                    side=side,
                    name=f"Retribution Troops ({troops})",
                    group_name=group_name,
                    troops=troops,
                )
            )

        for unit_type in cargo_types:
            group_name = f"CTLD {color} {unit_type}"
            self._add_template(
                player,
                group_name,
                [_TemplateUnit(f"{group_name} #1", unit_type)],
                position,
            )
            self.mission_data.ctld_crate_templates.append(
                CtldCrateTemplate(side=side, unit_type=unit_type, group_name=group_name)
            )

    def _template_position(self, player: Player) -> Point:
        for control_point in self.game.theater.controlpoints:
            if control_point.captured == player:
                return control_point.position
        return self.game.theater.controlpoints[0].position

    def _add_template(
        self,
        player: Player,
        group_name: str,
        units: list[_TemplateUnit],
        position: Point,
    ) -> VehicleGroup:
        country = self.mission.country(
            self.game.coalition_for(player).faction.country.name
        )
        group = VehicleGroup(self.mission.next_group_id(), group_name)
        for index, template_unit in enumerate(units):
            unit = Vehicle(
                self.mission.terrain,
                self.mission.next_unit_id(),
                template_unit.name,
                template_unit.type_id,
            )
            unit.position = position.point_from_heading(90, index * _UNIT_SPACING)
            group.add_unit(unit)
        waypoint = group.add_waypoint(group.units[0].position, PointAction.OffRoad, 0)
        waypoint.ETA_locked = True
        group.late_activation = True
        group.hidden = True
        country.add_vehicle_group(group)
        return group
