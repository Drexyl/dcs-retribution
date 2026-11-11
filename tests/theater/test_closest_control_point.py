from __future__ import annotations

from typing import Any
from unittest.mock import MagicMock, PropertyMock

from dcs import Point

from game.theater.conflicttheater import ConflictTheater


def _control_point(x: float, neutral: bool | None) -> Any:
    """A stand-in control point.

    `neutral=None` models a control point whose coalition is not set yet, as is
    the case while a campaign is being loaded: reading `captured` raises.
    """
    cp = MagicMock()
    cp.is_fleet = False
    cp.position = Point(x, 0, MagicMock())
    if neutral is None:
        type(cp).captured = PropertyMock(side_effect=RuntimeError("coalition not set"))
    else:
        cp.captured.is_neutral = neutral
    return cp


def _theater(*control_points: Any) -> Any:
    theater = MagicMock()
    theater.controlpoints = list(control_points)
    return theater


def test_closest_control_point_works_before_coalitions_are_set() -> None:
    # Supply routes are resolved while the campaign is loading, before any
    # control point has a coalition. The default lookup must not read ownership.
    near = _control_point(10, neutral=None)
    far = _control_point(500, neutral=None)
    theater = _theater(far, near)

    closest = ConflictTheater.closest_control_point(theater, Point(0, 0, MagicMock()))

    assert closest is near


def test_closest_control_point_can_skip_neutral_points() -> None:
    neutral = _control_point(10, neutral=True)
    owned = _control_point(500, neutral=False)
    theater = _theater(neutral, owned)
    origin = Point(0, 0, MagicMock())

    assert ConflictTheater.closest_control_point(theater, origin) is neutral
    assert (
        ConflictTheater.closest_control_point(theater, origin, include_neutral=False)
        is owned
    )
