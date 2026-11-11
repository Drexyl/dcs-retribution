from __future__ import annotations

from typing import cast
from unittest.mock import Mock

from dcs import Mission
from dcs.condition import (
    AllOfCoalitionOutsideZone,
    FlagIsFalse,
    FlagIsTrue,
    PartOfCoalitionInZone,
)

from game import Game
from game.missiongenerator.triggergenerator import TriggerGenerator
from game.theater.controlpoint import ControlPoint


def _capture_trigger_conditions(flag_condition_true: bool) -> list[object]:
    cp = Mock(spec=ControlPoint)
    cp.id = "cp-id"
    cp.full_name = "Test Field"
    generator = TriggerGenerator(Mission(), cast(Game, None))
    trigger = generator._create_capture_trigger(
        trigger_zone_id=1,
        flag=600,
        capturing_coalition="red",
        losing_coalition="blue",
        capturing_coalition_int=1,
        cp=cp,
        flag_condition_true=flag_condition_true,
    )
    return list(trigger.rules)


def test_capture_trigger_checks_flag_before_scanning_zones() -> None:
    # DCS evaluates trigger conditions in order and stops at the first false
    # one, so the cheap flag check must come before the per-unit zone scans.
    conditions = _capture_trigger_conditions(flag_condition_true=False)

    assert [type(c) for c in conditions] == [
        FlagIsFalse,
        AllOfCoalitionOutsideZone,
        PartOfCoalitionInZone,
    ]


def test_recapture_trigger_checks_flag_before_scanning_zones() -> None:
    conditions = _capture_trigger_conditions(flag_condition_true=True)

    assert [type(c) for c in conditions] == [
        FlagIsTrue,
        AllOfCoalitionOutsideZone,
        PartOfCoalitionInZone,
    ]
