from __future__ import annotations

from dataclasses import dataclass

from ..protocol.types import CommittedRoundRecord, ControlPlaneState, InstalledConfig, JsonDict, MembershipState, PendingConfig, PendingConfigStatus, RepairLog, RepairSnapshot, SimulationTiming, bitmap_set


# The current simulator deliberately exposes one conservative control-plane
# strategy. It reacts to node interruptions, chooses a repair prefix, and then
# drives rejoin through prepare/ack/commit plus node-local future-round
# activation. Cluster mediates all transport to and from nodes.
def _clone_repair_prefix(committed_rounds: tuple[CommittedRoundRecord, ...]) -> RepairLog:
    return RepairLog(entries=tuple(entry.with_timing(commit_time_ns=None, app_delivery_time_ns=None) for entry in committed_rounds))


def _select_repair_prefix(
    dataplane_snapshots: list[RepairSnapshot],
) -> RepairLog:
    if not dataplane_snapshots:
        return RepairLog()
    source = max(
        dataplane_snapshots,
        key=lambda node: (len(node.committed_rounds), -int(node.node_id)),
    )
    return _clone_repair_prefix(source.committed_rounds)


@dataclass
class OnlineRejoinControlPlane:
    cutover_slack_rounds: int = 10

    def __post_init__(self) -> None:
        self.timing = SimulationTiming()
        self.node_count = 0
        self.current_state: ControlPlaneState | None = None
        self._repair_snapshot_source = lambda: []
        self._scheduled: list[tuple[int, str, int | None]] = []
        self._applied: list[JsonDict] = []
        self._observed_events: list[JsonDict] = []
        self._collecting_targets: set[int] = set()
        self._episode_targets: set[int] = set()
        self._queued_interruptions: dict[int, int] = {}
        self._collection_deadline_ns: int | None = None
        self._next_episode_id = 1
        self._active_episode_id: int | None = None
        self._episode_members_bitmap: int | None = None
        self._prepare_round: int | None = None
        self._prepare_acks: set[int] = set()
        self._last_prepare_acks: set[int] = set()
        self._pending_future: PendingConfig | None = None

    def set_timing(self, timing: SimulationTiming) -> None:
        self.timing = timing

    def set_repair_snapshot_source(self, source) -> None:
        # Runtime supplies a read-only dataplane snapshot function. The control
        # plane owns the recovery policy; runtime only provides visibility.
        self._repair_snapshot_source = source

    def _schedule_action(self, time_ns: int, action: str, episode_id: int | None = None) -> None:
        self._scheduled.append((time_ns, action, episode_id))

    def _record_applied_action(self, *, time_ns: int, action: str, **details: object) -> None:
        record = {"time_ns": time_ns, "action": action}
        record.update(details)
        self._applied.append(record)

    def _initial_state(self, node_count: int) -> ControlPlaneState:
        full_membership = bitmap_set(node_count, *range(node_count))
        return ControlPlaneState(
            installed_config=InstalledConfig(
                membership_epoch=0,
                members_bitmap=full_membership,
                run_id=0,
            ),
            node_states={node_id: MembershipState.ACTIVE for node_id in range(node_count)},
        )

    def _rebuild_repair_logs(self) -> None:
        # Recompute repair payloads for nodes currently under recovery. The
        # repair log is exposed through ControlPlaneState and later written into
        # per-node mailbox transactions by ClusterRun.
        assert self.current_state is not None
        repair_targets = {
            node_id
            for node_id, state in self.current_state.node_states.items()
            if state in (MembershipState.RECOVERING, MembershipState.REJOIN_PENDING)
        }
        if not repair_targets:
            if self.current_state.repair_logs:
                self.current_state = ControlPlaneState(
                    installed_config=self.current_state.installed_config,
                    node_states=self.current_state.node_states,
                    pending_config=self.current_state.pending_config,
                )
            return
        repair_prefix = _select_repair_prefix(self._repair_snapshot_source())
        if len(repair_prefix) == 0:
            return
        repair_logs = {node_id: repair_prefix for node_id in repair_targets}
        self.current_state = ControlPlaneState(
            installed_config=self.current_state.installed_config,
            node_states=self.current_state.node_states,
            pending_config=self.current_state.pending_config,
            repair_logs=repair_logs,
        )

    def rebuild_repair_logs(self) -> None:
        self._rebuild_repair_logs()

    def _future_members(self) -> set[int]:
        assert self._pending_future is not None
        return {
            node_id
            for node_id in range(self.node_count)
            if self._pending_future.members_bitmap & (1 << node_id)
        }

    def _episode_active(self) -> bool:
        return (
            bool(self._episode_targets)
            or self._pending_future is not None
            or self._active_episode_id is not None
        )

    def _mark_node_failed(self, node_id: int) -> None:
        assert self.current_state is not None
        if self.current_state.node_states.get(node_id) == MembershipState.FAILED:
            return
        updated = dict(self.current_state.node_states)
        updated[node_id] = MembershipState.FAILED
        self.current_state = ControlPlaneState(
            installed_config=self.current_state.installed_config,
            node_states=updated,
            pending_config=self.current_state.pending_config,
            repair_logs=self.current_state.repair_logs,
        )

    def _begin_collection_window(self, current_time_ns: int) -> None:
        if self._collecting_targets or self._episode_active():
            return
        if not self._queued_interruptions:
            return
        self._collecting_targets = set(self._queued_interruptions)
        self._queued_interruptions.clear()
        self._collection_deadline_ns = current_time_ns + self.timing.cp_collection_delay_ns

    def _episode_members(self) -> set[int]:
        assert self.current_state is not None
        active_members = {
            node_id
            for node_id, state in self.current_state.node_states.items()
            if state == MembershipState.ACTIVE
        }
        return active_members | self._episode_targets

    def _schedule_episode(self) -> None:
        assert self._collection_deadline_ns is not None
        self._active_episode_id = self._next_episode_id
        self._next_episode_id += 1
        episode_members = self._episode_members()
        self._episode_members_bitmap = bitmap_set(self.node_count, *sorted(episode_members))
        repair_start = self._collection_deadline_ns + self.timing.cp_decision_delay_ns
        prepare_at = repair_start + self.timing.repair_delay_ns
        self._prepare_round = int(prepare_at // self.timing.round_length_ns) + 1
        self._schedule_action(repair_start, "mark_recovering", self._active_episode_id)
        self._schedule_action(prepare_at, "prepare_online_rejoin", self._active_episode_id)
        self._schedule_action(
            prepare_at + self.timing.install_delay_ns,
            "abort_online_rejoin",
            self._active_episode_id,
        )

    def _close_collection_window_if_due(self, current_time_ns: int) -> None:
        if self._collection_deadline_ns is None:
            return
        if current_time_ns < self._collection_deadline_ns:
            return
        if not self._collecting_targets:
            self._collection_deadline_ns = None
            return

        assert self.current_state is not None
        self._episode_targets = set(self._collecting_targets)
        self._collecting_targets.clear()
        self._schedule_episode()
        self._collection_deadline_ns = None

    def _node_states_with_targets(
        self,
        target_state: MembershipState,
    ) -> dict[int, MembershipState]:
        assert self.current_state is not None
        updated = dict(self.current_state.node_states)
        for node_id in self._episode_targets:
            updated[node_id] = target_state
        return updated

    def _clear_episode_state(self) -> None:
        cleared_episode_id = self._active_episode_id
        self._episode_targets = set()
        self._active_episode_id = None
        self._episode_members_bitmap = None
        self._prepare_round = None
        self._prepare_acks = set()
        if cleared_episode_id is not None:
            self._scheduled = [
                (time_ns, action, episode_id)
                for time_ns, action, episode_id in self._scheduled
                if episode_id != cleared_episode_id
            ]

    def _install_pending_future(self, pending: PendingConfig) -> None:
        assert self.current_state is not None
        self._pending_future = pending
        self.current_state = ControlPlaneState(
            installed_config=self.current_state.installed_config,
            node_states=self.current_state.node_states,
            pending_config=pending,
            repair_logs=self.current_state.repair_logs,
        )

    def _update_node_states(self, node_states: dict[int, MembershipState], *, pending_config: PendingConfig | None = None) -> None:
        assert self.current_state is not None
        self.current_state = ControlPlaneState(
            installed_config=self.current_state.installed_config,
            node_states=node_states,
            pending_config=pending_config,
            repair_logs=self.current_state.repair_logs,
        )

    #####################################################################
    #            Event-driven control-plane state machine               #
    #####################################################################
    # This is the core of the control-plane state machine.
    # It adopts a event-driven style, where external stimuli (node interruptions and PrepareAck events) 
    # are delivered through observe_event, and all internal state transitions are scheduled as future actions. 
    # The advance_to_time method is responsible for advancing the control plane's internal clock, applying 
    # any scheduled actions that are due, and refreshing repair logs as needed.
    def _apply_action(self, action: str, at_ns: int, episode_id: int | None) -> None:
        # Apply an internal control-plane state-machine action once its
        # scheduled time becomes visible at the current round boundary.
        assert self.current_state is not None
        assert self.node_count > 0
        if episode_id is not None and episode_id != self._active_episode_id:
            return

        if action == "mark_recovering":
            assert self._episode_targets
            self._update_node_states(
                self._node_states_with_targets(MembershipState.RECOVERING),
                pending_config=self.current_state.pending_config,
            )
            self._record_applied_action(
                time_ns=at_ns,
                action=action,
                node_ids=sorted(self._episode_targets),
            )
            return

        if action == "prepare_online_rejoin":
            assert self._prepare_round is not None
            assert self._episode_members_bitmap is not None
            pending = PendingConfig(
                membership_epoch=self.current_state.installed_config.membership_epoch + 1,
                members_bitmap=self._episode_members_bitmap,
                effective_round=self._prepare_round + self.cutover_slack_rounds,
                run_id=self.current_state.installed_config.run_id + 1,
                status=PendingConfigStatus.PREPARED,
            )
            self._prepare_acks = set()
            self._install_pending_future(pending)
            self._update_node_states(
                self._node_states_with_targets(MembershipState.REJOIN_PENDING),
                pending_config=pending,
            )
            self._record_applied_action(
                time_ns=at_ns,
                action=action,
                node_ids=sorted(self._episode_targets),
                members_bitmap=self._episode_members_bitmap,
                effective_round=pending.effective_round,
            )
            return

        if action == "commit_online_rejoin":
            if self._pending_future is None:
                return
            commit_visible_round = int(at_ns // self.timing.round_length_ns) + 1
            effective_round = max(
                self._pending_future.effective_round,
                commit_visible_round + 1,
            )
            committed = PendingConfig(
                membership_epoch=self._pending_future.membership_epoch,
                members_bitmap=self._pending_future.members_bitmap,
                effective_round=effective_round,
                run_id=self._pending_future.run_id,
                status=PendingConfigStatus.COMMITTED,
            )
            self._install_pending_future(committed)
            self._record_applied_action(
                time_ns=at_ns,
                action=action,
                node_ids=sorted(self._episode_targets),
                effective_round=committed.effective_round,
            )
            return

        if action == "abort_online_rejoin":
            if self._pending_future is None or self._pending_future.status != PendingConfigStatus.PREPARED:
                return
            retry_targets = set(self._episode_targets) | set(self._queued_interruptions)
            updated_states = {
                node_id: (MembershipState.FAILED if node_id in retry_targets else MembershipState.ACTIVE)
                for node_id in range(self.node_count)
            }
            self.current_state = ControlPlaneState(
                installed_config=self.current_state.installed_config,
                node_states=updated_states,
                pending_config=None,
            )
            self._record_applied_action(
                time_ns=at_ns,
                action=action,
                node_ids=sorted(self._episode_targets),
            )
            for node_id in retry_targets:
                self._queued_interruptions.setdefault(node_id, at_ns)
            self._pending_future = None
            self._clear_episode_state()
            self._begin_collection_window(at_ns)
            return

        raise ValueError(f"unknown control-plane action {action!r}")

    def _maybe_activate_cutover(self, round_id: int) -> None:
        # The control plane tracks the same future-round cutover boundary as the
        # nodes. Nodes still switch locally; this updates the authoritative CP
        # view once that boundary has been reached.
        if self._pending_future is None:
            return
        if self._pending_future.status != PendingConfigStatus.COMMITTED:
            return
        if round_id < self._pending_future.effective_round:
            return

        self.current_state = ControlPlaneState(
            installed_config=InstalledConfig(
                membership_epoch=self._pending_future.membership_epoch,
                members_bitmap=self._pending_future.members_bitmap,
                run_id=self._pending_future.run_id,
            ),
            node_states={
                node_id: (
                    MembershipState.ACTIVE
                    if self._pending_future.members_bitmap & (1 << node_id)
                    else MembershipState.FAILED
                )
                for node_id in range(self.node_count)
            },
            pending_config=None,
        )
        self._record_applied_action(
            time_ns=round_id * self.timing.round_length_ns,
            action="activate_online_rejoin",
            node_ids=sorted(self._episode_targets),
            effective_round=self._pending_future.effective_round,
        )
        self._pending_future = None
        self._clear_episode_state()
        self._begin_collection_window(round_id * self.timing.round_length_ns)

    def _note_interruption(self, target: int, available_at_ns: int) -> None:
        self._mark_node_failed(target)
        if (
            self._collection_deadline_ns is not None
            and available_at_ns <= self._collection_deadline_ns
            and not self._episode_targets
        ):
            self._collecting_targets.add(target)
            return
        self._queued_interruptions.setdefault(target, available_at_ns)
        self._begin_collection_window(available_at_ns)

    def _note_prepare_ack(self, event: JsonDict) -> None:
        assert self._pending_future is not None
        config = event.get("config") or {}
        if int(config.get("run_id", -1)) != self._pending_future.run_id:
            return
        if int(config.get("effective_round", -1)) != self._pending_future.effective_round:
            return

        self._prepare_acks.add(int(event["node_id"]))
        if self._prepare_acks >= self._future_members():
            self._last_prepare_acks = set(self._prepare_acks)
            if not any(
                action == "commit_online_rejoin" and scheduled_episode_id == self._active_episode_id
                for _, action, scheduled_episode_id in self._scheduled
            ):
                self._schedule_action(
                    int(event["available_at_ns"]) + self.timing.cp_decision_delay_ns,
                    "commit_online_rejoin",
                    self._active_episode_id,
                )

    def advance_to_time(self, time_ns: int, node_count: int) -> None:
        if self.current_state is None:
            self.node_count = node_count
            self.current_state = self._initial_state(node_count)

        self._begin_collection_window(time_ns)
        self._close_collection_window_if_due(time_ns)
        ready = [item for item in self._scheduled if item[0] <= time_ns]
        self._scheduled = [item for item in self._scheduled if item[0] > time_ns]
        for action_time_ns, action, episode_id in sorted(
            ready,
            key=lambda item: (item[0], item[1], -1 if item[2] is None else item[2]),
        ):
            self._apply_action(action, action_time_ns, episode_id)
        self._begin_collection_window(time_ns)
        self._close_collection_window_if_due(time_ns)
        self._rebuild_repair_logs()

    def observe_event(self, event: JsonDict) -> None:
        # Node-originated interruptions and PrepareAck events are delivered here
        # only through ClusterRun; nodes never call into the control plane
        # directly.
        self._observed_events.append(dict(event))
        if event["kind"] in {"NodeCrashed", "NodeHalted"}:
            self._note_interruption(
                int(event["node_id"]),
                int(event["available_at_ns"]),
            )
            return

        if event["kind"] != "PrepareAck" or self._pending_future is None:
            return
        if self._pending_future.status != PendingConfigStatus.PREPARED:
            return
        self._note_prepare_ack(event)

    def __call__(self, round_id: int, node_count: int) -> ControlPlaneState:
        if self.current_state is None:
            self.node_count = node_count
            self.current_state = self._initial_state(node_count)
        self._maybe_activate_cutover(round_id)
        self._rebuild_repair_logs()
        return self.current_state

    def debug_snapshot(self) -> JsonDict:
        return {
            "scheduled_actions": [
                {"time_ns": time_ns, "action": action, "episode_id": episode_id}
                for time_ns, action, episode_id in sorted(
                    self._scheduled,
                    key=lambda item: (item[0], item[1], -1 if item[2] is None else item[2]),
                )
            ],
            "applied_actions": list(self._applied),
            "observed_events": list(self._observed_events),
            "collection_deadline_ns": self._collection_deadline_ns,
            "active_episode_id": self._active_episode_id,
            "collecting_targets": sorted(self._collecting_targets),
            "episode_targets": sorted(self._episode_targets),
            "episode_members_bitmap": self._episode_members_bitmap,
            "queued_interruptions": [
                {"node_id": node_id, "available_at_ns": available_at_ns}
                for node_id, available_at_ns in sorted(self._queued_interruptions.items())
            ],
            "prepare_acks": sorted(self._prepare_acks or self._last_prepare_acks),
            "pending_future": None
            if self._pending_future is None
            else {
                "membership_epoch": self._pending_future.membership_epoch,
                "members_bitmap": self._pending_future.members_bitmap,
                "effective_round": self._pending_future.effective_round,
                "run_id": self._pending_future.run_id,
                "status": self._pending_future.status.value,
            },
        }
