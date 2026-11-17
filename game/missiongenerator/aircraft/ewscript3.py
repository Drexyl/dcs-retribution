"""Helpers for the EW Script 3.0 plugin (Timberwolf's EA-18G AEA script).

The Lua side lives in resources/plugins/EWScript3. Only aircraft carrying offensive
(stand-off / escort) jamming pods - ALQ-99, ALQ-249 - or aircraft flagged with
``has_built_in_jamming`` are registered as AEA jammers. Aircraft carrying
self-protection pods (``WeaponType.JAMMER``) or, optionally, internal ECM
(``has_built_in_ecm``) are registered as self-protection jammers, which only protect
the carrier.
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


#: Default (AI) simultaneously jammed groups per loadout - mirrors LOADOUTS[k].maxT in the Lua
#: script. The ALQ-249 (NGJ-MB) is a multi-beam AESA, so NGJ loadouts jam more groups at once.
MAX_TARGETS = {
    "1xALQ99": 2,
    "2xALQ99": 4,
    "3xALQ99": 6,
    "1xALQ249": 4,
    "1xALQ249_1xALQ99": 4,
    "1xALQ249_2xALQ99": 6,
    "2xALQ249": 6,
    "2xALQ249_1xALQ99": 9,
}


def loadout_key_for_pods(alq99: int, alq249: int, built_in: bool) -> Optional[str]:
    """Map pod counts to one of the AEA script's LOADOUTS keys (nearest entry)."""
    if alq249 >= 2:
        return "2xALQ249_1xALQ99" if alq99 >= 1 else "2xALQ249"
    if alq249 == 1:
        if alq99 >= 2:
            return "1xALQ249_2xALQ99"
        if alq99 == 1:
            return "1xALQ249_1xALQ99"
        return "1xALQ249"
    if alq99 >= 3:
        return "3xALQ99"
    if alq99 == 2:
        return "2xALQ99"
    if alq99 == 1:
        return "1xALQ99"
    if built_in:
        return "2xALQ99"
    return None


def jammer_loadout_key(member: FlightMember, flight: Flight) -> Optional[str]:
    alq99, alq249 = count_offensive_jammer_pods(member)
    return loadout_key_for_pods(
        alq99, alq249, flight.squadron.aircraft.has_built_in_jamming
    )


def jammer_max_targets(member: FlightMember, flight: Flight) -> int:
    key = jammer_loadout_key(member, flight)
    return MAX_TARGETS.get(key, 4) if key is not None else 4


def spj_generation_for_year(year: Optional[int]) -> int:
    """Self-protection pod generation: 1 before 1985, 2 up to 1995, 3 after."""
    if year is None:
        return 2
    if year < 1985:
        return 1
    if year <= 1995:
        return 2
    return 3


def self_protection_jammer(
    member: FlightMember, flight: Flight, settings: Settings
) -> Optional[tuple[int, str]]:
    """(generation, pod name) of the member's self-protection jammer, if any.

    Aircraft registered as AEA jammers are skipped - the AEA jammer covers its own aircraft.
    """
    if jammer_loadout_key(member, flight) is not None:
        return None
    best: Optional[tuple[int, str]] = None
    for weapon in member.loadout.pylons.values():
        if weapon is None or weapon.weapon_group.type is not WeaponType.JAMMER:
            continue
        group = weapon.weapon_group
        gen = spj_generation_for_year(group.introduction_year)
        if best is None or gen > best[0]:
            best = (gen, group.name)
    if best is not None:
        return best
    if flight.squadron.aircraft.has_built_in_ecm and ewscript3_option(
        settings, "spj_internal_ecm"
    ):
        return 3, "internal ECM"
    return None


def flight_has_jamming_window(flight: Flight) -> bool:
    return any(
        wpt.waypoint_type in WINDOW_OPEN_WAYPOINTS
        for wpt in flight.flight_plan.iter_waypoints()
    )


def register_jammer_script(
    unit_name: str, loadout: str, ai: bool, gated: bool, max_targets: int
) -> str:
    unit = _lua_str(unit_name)
    if ai:
        cfg = (
            f'{{loadout="{loadout}", ai=true, gated={str(gated).lower()}, '
            f"maxTargets={max_targets}}}"
        )
    else:
        cfg = f'{{loadout="{loadout}", ai=false}}'
    return f'if AEA_RegisterJammer then AEA_RegisterJammer("{unit}", {cfg}) end'


def set_armed_script(unit_name: str, armed: bool) -> str:
    unit = _lua_str(unit_name)
    return f'if AEA_SetArmed then AEA_SetArmed("{unit}", {str(armed).lower()}) end'


def register_self_protect_script(unit_name: str, gen: int, pod: str, ai: bool) -> str:
    unit = _lua_str(unit_name)
    cfg = f'{{gen={gen}, pod="{_lua_str(pod)}", ai={str(ai).lower()}}}'
    return (
        "if AEA_RegisterSelfProtect then "
        f'AEA_RegisterSelfProtect("{unit}", {cfg}) end'
    )


def _lua_str(text: str) -> str:
    return text.replace("\\", "\\\\").replace('"', '\\"')
