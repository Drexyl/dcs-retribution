from __future__ import annotations

from dataclasses import dataclass, field
from enum import unique, Enum
from typing import Any

from faker import Faker


@dataclass
class PilotRecord:
    missions_flown: int = field(default=0)


@unique
class PilotStatus(Enum):
    Active = "Active"
    OnLeave = "On leave"
    Dead = "Dead"
    #: Rescued (CSAR) but temporarily unavailable. Alive and holds a roster slot,
    #: but cannot be assigned to flights until ``turns_until_available`` counts
    #: down to zero, at which point the pilot returns to ``Active``.
    Recovering = "Recovering"


@dataclass
class Pilot:
    name: str
    player: bool = field(default=False)
    status: PilotStatus = field(default=PilotStatus.Active)
    record: PilotRecord = field(default_factory=PilotRecord)
    #: Turns remaining before a ``Recovering`` pilot returns to ``Active``.
    #: Only meaningful while ``status is PilotStatus.Recovering``.
    turns_until_available: int = field(default=0)

    def __setstate__(self, state: dict[str, Any]) -> None:
        # Save compat: the field was added for CSAR pilot recovery; older saves
        # won't have it.
        if "turns_until_available" not in state:
            state["turns_until_available"] = 0
        self.__dict__.update(state)

    @property
    def alive(self) -> bool:
        return self.status is not PilotStatus.Dead

    @property
    def on_leave(self) -> bool:
        return self.status is PilotStatus.OnLeave

    @property
    def recovering(self) -> bool:
        return self.status is PilotStatus.Recovering

    def send_on_leave(self) -> None:
        if self.status is not PilotStatus.Active:
            raise RuntimeError("Only active pilots may be sent on leave")
        self.status = PilotStatus.OnLeave

    def return_from_leave(self) -> None:
        if self.status is not PilotStatus.OnLeave:
            raise RuntimeError("Only pilots on leave may be returned from leave")
        self.status = PilotStatus.Active

    def begin_recovery(self, turns: int) -> None:
        """Marks a rescued pilot as recovering for the given number of turns."""
        self.status = PilotStatus.Recovering
        self.turns_until_available = turns

    def advance_recovery(self) -> None:
        """Counts down recovery by one turn, returning to Active when done."""
        if self.status is not PilotStatus.Recovering:
            return
        self.turns_until_available -= 1
        if self.turns_until_available <= 0:
            self.turns_until_available = 0
            self.status = PilotStatus.Active

    def kill(self) -> None:
        self.status = PilotStatus.Dead

    @classmethod
    def random(cls, faker: Faker) -> Pilot:
        return Pilot(faker.name())
