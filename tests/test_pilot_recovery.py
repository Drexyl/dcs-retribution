"""Tests for CSAR pilot recovery: rescued pilots are spared instead of killed,
players return next turn, AI pilots sit out one turn, and AICSAR AI rescues spare
a random AI loss of the correct side.
"""

from __future__ import annotations

import random
from types import SimpleNamespace
from typing import Any, cast
from unittest.mock import MagicMock

from game.debriefing import AirLosses, Debriefing, StateData
from game.settings import Settings
from game.sim.missionresultsprocessor import (
    AI_PILOT_RECOVERY_TURNS,
    MissionResultsProcessor,
)
from game.squadrons.pilot import Pilot, PilotStatus
from game.squadrons.squadron import Squadron
from game.theater import Player


def _loss(pilot: Pilot) -> Any:
    """A FlyingUnit-like loss with its own squadron (owned aircraft to burn)."""
    squadron = SimpleNamespace(owned_aircraft=5, destroyed_aircraft=0)
    flight = SimpleNamespace(squadron=squadron, unit_type="Su-27")
    return SimpleNamespace(pilot=pilot, flight=flight)


def _squadron(roster: list[Pilot], pilot_limit: int = 16) -> Squadron:
    squadron = Squadron.__new__(Squadron)
    squadron.current_roster = roster
    squadron.settings = cast(
        Settings, SimpleNamespace(squadron_pilot_limit=pilot_limit)
    )
    return squadron


# --- Pilot state machine ---------------------------------------------------


def test_ai_recovery_counts_down_to_active() -> None:
    pilot = Pilot("Ivan", player=False)
    pilot.begin_recovery(AI_PILOT_RECOVERY_TURNS)
    assert pilot.recovering and pilot.alive
    assert pilot.turns_until_available == 2

    pilot.advance_recovery()  # first decrement (same cycle as the rescue)
    assert pilot.recovering and pilot.turns_until_available == 1

    pilot.advance_recovery()  # the turn after -> back to duty
    assert pilot.status is PilotStatus.Active
    assert pilot.turns_until_available == 0


def test_advance_recovery_noop_for_non_recovering() -> None:
    pilot = Pilot("Active Andy")
    pilot.advance_recovery()
    assert pilot.status is PilotStatus.Active


# --- Squadron slot accounting + recovery pass ------------------------------


def test_recovering_pilot_reserves_its_slot() -> None:
    active = Pilot("A")
    recovering = Pilot("R")
    recovering.begin_recovery(2)
    squadron = _squadron([active, recovering], pilot_limit=16)

    assert squadron.recovering_pilots == [recovering]
    assert squadron.active_pilots == [active]
    # Recovering pilot holds its slot, so only 14 are unfilled (not 15).
    assert squadron._number_of_unfilled_pilot_slots == 14


def test_process_pilot_recovery_reactivates_when_done() -> None:
    recovering = Pilot("R")
    recovering.begin_recovery(2)
    squadron = _squadron([recovering])

    squadron._process_pilot_recovery()
    assert recovering.recovering  # still out for the sat-out turn

    squadron._process_pilot_recovery()
    assert recovering.status is PilotStatus.Active


# --- commit_air_losses interception ----------------------------------------


def _debriefing(
    losses: list[Any],
    rescued_ids: set[int],
    ai_random: dict[Player, int],
) -> Debriefing:
    debriefing = Debriefing.__new__(Debriefing)
    debriefing.air_losses = AirLosses(player=losses, enemy=[])
    debriefing.rescued_pilot_ids = rescued_ids
    debriefing.ai_random_rescues = ai_random
    return debriefing


def _processor(invulnerable_player_pilots: bool = False) -> MissionResultsProcessor:
    game = SimpleNamespace(
        settings=SimpleNamespace(invulnerable_player_pilots=invulnerable_player_pilots)
    )
    return MissionResultsProcessor(cast(Any, game))


def test_exact_rescue_spares_player_and_recovers_ai() -> None:
    ai = Pilot("AI exact", player=False)
    player = Pilot("Player exact", player=True)
    killed = Pilot("AI killed", player=False)
    losses = [_loss(ai), _loss(player), _loss(killed)]

    debriefing = _debriefing(losses, {id(ai), id(player)}, {})
    _processor().commit_air_losses(debriefing)

    assert ai.status is PilotStatus.Recovering  # AI sits out
    assert player.status is PilotStatus.Active  # player returns next turn
    assert killed.status is PilotStatus.Dead
    # Airframes are still lost regardless of pilot survival.
    for loss in losses:
        assert loss.flight.squadron.owned_aircraft == 4
        assert loss.flight.squadron.destroyed_aircraft == 1


def test_ai_random_rescue_spares_one_random_ai_loss() -> None:
    ai1 = Pilot("AI 1", player=False)
    ai2 = Pilot("AI 2", player=False)
    player = Pilot("Player", player=True)
    losses = [_loss(ai1), _loss(ai2), _loss(player)]

    debriefing = _debriefing(losses, set(), {Player.BLUE: 1})
    random.seed(0)
    _processor().commit_air_losses(debriefing)

    recovering = [p for p in (ai1, ai2) if p.status is PilotStatus.Recovering]
    dead = [p for p in (ai1, ai2) if p.status is PilotStatus.Dead]
    assert len(recovering) == 1 and len(dead) == 1  # exactly one AI spared
    # The random pool never touches player pilots.
    assert player.status is PilotStatus.Dead


def test_ai_random_capped_by_available_losses() -> None:
    ai = Pilot("AI", player=False)
    losses = [_loss(ai)]
    # Two rescues reported but only one AI actually lost -> spare just the one.
    debriefing = _debriefing(losses, set(), {Player.BLUE: 5})
    _processor().commit_air_losses(debriefing)
    assert ai.status is PilotStatus.Recovering


def test_invulnerable_player_pilot_still_not_killed_without_rescue() -> None:
    player = Pilot("Ace", player=True)
    debriefing = _debriefing([_loss(player)], set(), {})
    _processor(invulnerable_player_pilots=True).commit_air_losses(debriefing)
    assert player.status is PilotStatus.Active


# --- state.json round trip -------------------------------------------------


def test_statedata_parses_rescue_fields() -> None:
    data = {
        "mission_ended": True,
        "rescued_pilots": ["Enfield11", "Chevy61"],
        "rescued_ai_random": ["Blue", "RED", "blue"],
    }
    state = StateData.from_json(data, cast(Any, MagicMock()))
    assert state.rescued_pilots == ["Enfield11", "Chevy61"]
    assert state.rescued_ai_random == ["blue", "red", "blue"]


def test_statedata_defaults_rescue_fields_when_absent() -> None:
    state = StateData.from_json({"mission_ended": True}, cast(Any, MagicMock()))
    assert state.rescued_pilots == []
    assert state.rescued_ai_random == []
