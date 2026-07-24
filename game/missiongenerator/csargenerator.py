from __future__ import annotations

import logging
import textwrap
from typing import TYPE_CHECKING, Optional

from dcs.action import DoScript
from dcs.country import Country
from dcs.mission import StartType as DcsStartType
from dcs.task import Transport
from dcs.terrain import NoParkingSlotError
from dcs.translation import String
from dcs.triggers import TriggerStart

from game.dcs.aircrafttype import AircraftType
from game.theater import Airfield

if TYPE_CHECKING:
    from dcs import Mission

    from game import Game
    from game.coalition import Coalition

# The OpsCSAR Lua plugin (resources/plugins/opscsar/OpsCSAR.lua) finds these
# player-flyable rescue helicopters at runtime by this name prefix and hands them
# to MOOSE Ops.CSAR via CSAR:SetOwnSetPilotGroups(). Keep the two in sync.
CSAR_HELO_NAME_PREFIX = "CSAR Rescue"


class CsarGenerator:
    """Spawns a player-flyable rescue helicopter at each friendly airfield for
    any coalition that has Ops.CSAR enabled in the Gameplay settings.

    DCS's multiplayer slot list is generated once when the mission loads, so a
    Client-skill group spawned at runtime by a Lua script never becomes a
    joinable slot. The rescue helicopter therefore has to be a real group baked
    into the .miz at generation time, which is what this generator does. The
    OpsCSAR Lua plugin finds these groups at runtime by their "CSAR Rescue "
    name prefix and hands them to Ops.CSAR.
    """

    def __init__(
        self, mission: Mission, game: Game, p_country: Country, e_country: Country
    ) -> None:
        self.mission = mission
        self.game = game
        self.p_country = p_country
        self.e_country = e_country

    def generate(self) -> None:
        self._inject_settings()
        if self.game.settings.opscsar_blue:
            self._generate_for_side(self.game.blue, self.p_country)
        if self.game.settings.opscsar_red:
            self._generate_for_side(self.game.red, self.e_country)

    def _inject_settings(self) -> None:
        # OpsCSAR.lua (resources/plugins/opscsar/) is always injected but must
        # only activate for the sides actually enabled here, and needs to know
        # whether AI ejections are rescuable. It cannot reliably infer the
        # per-side enabled state at runtime by counting rescue-helo groups:
        # unoccupied Client (player-slot) groups are not live groups until a
        # player joins, so a count taken at mission start is always unreliable.
        # These runtime-only flags are therefore passed explicitly via a small
        # standalone global (Ops.CSAR is driven by these Gameplay settings, not
        # the plugin-options mechanism). Injected as real Lua boolean literals.
        def lua_bool(value: bool) -> str:
            return "true" if value else "false"

        s = self.game.settings
        lua = textwrap.dedent(f"""\
            OpsCSAR_Settings = OpsCSAR_Settings or {{}}
            OpsCSAR_Settings.enabledBlue = {lua_bool(s.opscsar_blue)}
            OpsCSAR_Settings.enabledRed = {lua_bool(s.opscsar_red)}
            OpsCSAR_Settings.rescueAiPilots = {lua_bool(s.opscsar_rescue_ai_pilots)}
            """)
        trigger = TriggerStart(comment="Ops.CSAR settings")
        trigger.add_action(DoScript(String(lua)))
        self.mission.triggerrules.triggers.append(trigger)

    def _generate_for_side(self, coalition: Coalition, country: Country) -> None:
        self._warn_if_aicsar_also_enabled(coalition)

        any_generated = False
        for cp in self.game.theater.control_points_for(coalition.player):
            if not isinstance(cp, Airfield):
                continue
            heli = self._pick_rescue_helicopter_at(coalition, cp)
            if heli is None:
                logging.warning(
                    "Ops.CSAR: no helicopter squadron based at %s; skipping "
                    "player CSAR rescue helo generation there.",
                    cp.name,
                )
                continue
            heli.dcs_unit_type.load_payloads()
            self._spawn_rescue_helo(cp, country, heli)
            any_generated = True

        if not any_generated:
            logging.warning(
                "Ops.CSAR: no helicopter squadrons based at any %s airfield; no "
                "CSAR rescue helicopters were generated.",
                coalition.faction.name,
            )

    def _warn_if_aicsar_also_enabled(self, coalition: Coalition) -> None:
        # FlightControl's AICSAR (a separate, AI-flown rescue system) can be
        # enabled independently of Ops.CSAR. Running both for the same side is
        # not an error, but ejections in range will get a duplicate response
        # (an AICSAR AI helo AND an Ops.CSAR player slot) -- worth flagging.
        if not self.game.settings.plugins.get("flightcontrol", False):
            return
        option_id = (
            "flightcontrol.aiCsarRed"
            if coalition.player.is_red
            else "flightcontrol.aiCsarBlue"
        )
        try:
            aicsar_enabled = self.game.settings.plugin_option(option_id)
        except KeyError:
            aicsar_enabled = False
        if aicsar_enabled:
            logging.warning(
                "Ops.CSAR and FlightControl's AICSAR are both enabled for %s. "
                "Ejections in range may get a duplicate rescue response.",
                coalition.faction.name,
            )

    def _spawn_rescue_helo(
        self, cp: Airfield, country: Country, heli: AircraftType
    ) -> None:
        name = f"{CSAR_HELO_NAME_PREFIX} {cp.name}"
        start_type = (
            DcsStartType.Warm
            if self.game.settings.opscsar_warm_startup
            else DcsStartType.Cold
        )
        try:
            group = self.mission.flight_group_from_airport(
                country=country,
                name=name,
                aircraft_type=heli.dcs_unit_type,
                airport=cp.airport,
                maintask=Transport,
                start_type=start_type,
                group_size=1,
            )
        except NoParkingSlotError:
            logging.warning(
                "Ops.CSAR: no free parking for CSAR rescue helo at %s", cp.name
            )
            return
        group.units[0].set_client()

    @staticmethod
    def _pick_rescue_helicopter_at(
        coalition: Coalition, cp: Airfield
    ) -> Optional[AircraftType]:
        # Helicopter types actually stationed at this airfield, so the rescue
        # helo reflects what's in that base's inventory rather than a single
        # type picked for the whole air wing.
        #
        # cabin_size > 0 is required, not just preferred: a rescue helo needs
        # to actually be able to carry the recovered pilot, so an airfield
        # whose only helicopter(s) have no troop capacity (e.g. a pure
        # scout/attack type) is skipped entirely, the same as an airfield with
        # no helicopter squadron at all -- not given a helicopter that can't do
        # the job.
        candidates = [
            squadron.aircraft
            for squadron in coalition.air_wing.iter_squadrons()
            if squadron.location == cp
            and squadron.owned_aircraft > 0
            and squadron.aircraft.helicopter
            and squadron.aircraft.flyable
            and squadron.aircraft.cabin_size > 0
        ]
        if not candidates:
            return None
        # Prefer the greatest troop capacity; tie-break deterministically by
        # name when multiple qualifying helicopter squadrons share an airfield.
        candidates.sort(key=lambda a: (-a.cabin_size, a.variant_id))
        return candidates[0]
