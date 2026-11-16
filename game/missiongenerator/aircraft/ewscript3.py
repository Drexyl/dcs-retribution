"""Helpers for the EW Script 3.0 plugin (Timberwolf's EA-18G AEA script).

The Lua side lives in resources/plugins/EWScript3. Only aircraft carrying offensive
(stand-off / escort) jamming pods - ALQ-99, ALQ-249 - or aircraft flagged with
``has_built_in_jamming`` are registered as AEA jammers. Self-protection pods
(``WeaponType.JAMMER``) are left to EW Script 2.1.
"""

from __future__ import annotations

from typing import Any, Optional, TYPE_CHECKING

from game.ato.flightwaypointtype import FlightWaypointType
from game.data.weapons import WeaponType

if TYPE_CHECKING:
    from game.ato import Flight
    from game.ato.flightmember import FlightMember
    from game.settings import Settings

PLUGIN_ID = "EWScript3"

#: Waypoints opening the AI jamming window (closed at SPLIT / PATROL).
WINDOW_OPEN_WAYPOINTS = {FlightWaypointType.JOIN, FlightWaypointType.PATROL_TRACK}


def ewscript3_enabled(settings: Settings) -> bool:
    return bool(settings.plugins.get(PLUGIN_ID))


def ewscript3_option(settings: Settings, key: str) -> Any:
    try:
        return settings.plugin_option(f"{PLUGIN_ID}.{key}")
    except KeyError:
        return None


def count_offensive_jammer_pods(member: FlightMember) -> tuple[int, int]:
    """Return (alq99_class, alq249) pod counts for the member's loadout."""
    alq99 = 0
    alq249 = 0
    for weapon in member.loadout.pylons.values():
        if (
            weapon is None
            or weapon.weapon_group.type is not WeaponType.OFFENSIVE_JAMMER
        ):
            continue
        if "249" in weapon.weapon_group.name:
            alq249 += 1
        else:
            alq99 += 1
    return alq99, alq249


def loadout_key_for_pods(alq99: int, alq249: int, built_in: bool) -> Optional[str]:
    """Map pod counts to one of the AEA script's LOADOUTS keys (nearest entry)."""
    if alq249 >= 2:
        return "2xALQ249_1xALQ99" if alq99 >= 1 else "2xALQ249"
    if alq249 == 1:
        if alq99 >= 2:
            return "2xALQ249_1xALQ99"
        if alq99 == 1:
            return "2xALQ99"
        return "1xALQ99"
    if alq99 >= 3:
        return "3xALQ99"
    if alq99 == 2:
        return "2xALQ99"
    if alq99 == 1:
        return "1xALQ99"
    if built_in:
        return "2xALQ99"
    return None


def max_targets_for_pods(alq99: int, alq249: int) -> int:
    pods = alq99 + alq249
    if pods >= 3:
        return 6
    if pods == 2:
        return 4
    return 2


def jammer_loadout_key(member: FlightMember, flight: Flight) -> Optional[str]:
    alq99, alq249 = count_offensive_jammer_pods(member)
    return loadout_key_for_pods(
        alq99, alq249, flight.squadron.aircraft.has_built_in_jamming
    )


def jammer_max_targets(member: FlightMember, flight: Flight) -> int:
    alq99, alq249 = count_offensive_jammer_pods(member)
    if alq99 + alq249 == 0:
        # built-in jamming only
        return 4
    return max_targets_for_pods(alq99, alq249)


def flight_has_jamming_window(flight: Flight) -> bool:
    return any(
        wpt.waypoint_type in WINDOW_OPEN_WAYPOINTS
        for wpt in flight.flight_plan.iter_waypoints()
    )


def register_jammer_script(
    unit_name: str, loadout: str, ai: bool, gated: bool, max_targets: int
) -> str:
    unit = unit_name.replace("\\", "\\\\").replace('"', '\\"')
    if ai:
        cfg = (
            f'{{loadout="{loadout}", ai=true, gated={str(gated).lower()}, '
            f"maxTargets={max_targets}}}"
        )
    else:
        cfg = f'{{loadout="{loadout}", ai=false}}'
    return f'if AEA_RegisterJammer then AEA_RegisterJammer("{unit}", {cfg}) end'


def set_armed_script(unit_name: str, armed: bool) -> str:
    unit = unit_name.replace("\\", "\\\\").replace('"', '\\"')
    return f'if AEA_SetArmed then AEA_SetArmed("{unit}", {str(armed).lower()}) end'
