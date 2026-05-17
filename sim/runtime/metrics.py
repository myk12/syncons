from __future__ import annotations

from dataclasses import dataclass, field
from typing import Protocol


@dataclass(frozen=True, slots=True)
class RoundSummary:
    round_id: int
    start_time_ns: int
    end_time_ns: int
    committed_txns: int


class MetricsSink(Protocol):
    def on_round_complete(self, summary: RoundSummary) -> None:
        ...


class NoOpMetricsSink:
    def on_round_complete(self, summary: RoundSummary) -> None:
        pass


@dataclass
class InMemoryMetricsCollector:
    rounds: list[RoundSummary] = field(default_factory=list)

    def on_round_complete(self, summary: RoundSummary) -> None:
        self.rounds.append(summary)
