from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass, field
from .types import (CommittedRound,
                    CommittedRoundRecord,
                    ControlPlaneUpdate,
                    HaltRecord, JsonDict, 
                    MembershipState, NodeStatus, 
                    OutboundPacket, PayloadFactory, 
                    Packet, PendingConfigStatus, 
                    RepairLog, RoundStage, bitmap_members, 
                    NodeRoundResult)


def default_payload(node_id: int, round_id: int) -> str:
    return f"{node_id}_{round_id}"


@dataclass
class Node:
    node_id: int
    node_count: int
    payload_factory: PayloadFactory = default_payload
    status: NodeStatus = NodeStatus.RUNNING
    current_round: int = 0
    status_reason: str | None = None
    committed_frontier: int = -1
    last_committed_sound_set: int | None = None
    commit_digest: str = field(default_factory=lambda: hashlib.sha256(b"syncons-log-empty").hexdigest())
    halted_round: int | None = None
    halt_details: HaltRecord | None = None

    def __post_init__(self) -> None:
        self.membership_state = MembershipState.ACTIVE
        self.installed_membership_epoch = 0     # Membership epoch of the currently installed config
        self.installed_membership = (1 << self.node_count) - 1
        self.current_sound_set = self.installed_membership
        self.run_id = 0
        self.pending_config = None
        self.current_stage = RoundStage(round_id=-1, membership_epoch=0, installed_membership=0)
        self.evidence_stage = RoundStage(round_id=-1, membership_epoch=0, installed_membership=0)
        self.commit_stage = RoundStage(round_id=-2, membership_epoch=0, installed_membership=0)
        self._control_plane_event_outbox: list[JsonDict] = []
        self._pending_control_plane_update: ControlPlaneUpdate | None = None
        self._control_plane_irq_pending = False

    def _quorum_for_membership(self, installed_membership: int) -> int:
        return max(1, installed_membership.bit_count() // 2 + 1)

    def _observation_rows(self, stage: RoundStage) -> dict[int, int]:
        members = bitmap_members(stage.installed_membership, self.node_count)
        return {member: stage.sound_matrix.get(member, 0) for member in members}

    def _row_is_valid(self, src: int, row: int) -> bool:
        if row == 0:
            return True
        return bool(row & (1 << src))

    # An agreed row is the local self row when it is matched by a quorum of
    # identical non-zero rows.
    def _agreed_row(self, stage: RoundStage) -> int | None:
        members = bitmap_members(stage.installed_membership, self.node_count)
        quorum = self._quorum_for_membership(stage.installed_membership)
        rows = self._observation_rows(stage)

        for src, row in rows.items():
            # If the row is not valid according to the sender's own bitmap, ignore it.
            if not self._row_is_valid(src, row):
                return None

        local_row = rows.get(self.node_id, 0)
        if local_row == 0:
            return None
        
        # Count how many members have the same row as the local node. We require
        # quorum agreement on the self row.
        witness_count = sum(1 for member in members if rows[member] == local_row)
        if witness_count < quorum:
            return None

        return local_row

    # A sound set is the set of nodes that have the same agreed row as the local node.
    # It may be a subset of the commit set, but it must include the local node and must not
    # expand outside the previous sound set.
    def _sound_set(self, stage: RoundStage) -> int | None:
        rows = self._observation_rows(stage)
        agreed_row = self._agreed_row(stage)
        if agreed_row is None:
            return None

        core = 0
        for member, row in rows.items():
            if row == agreed_row:
                core |= 1 << member
        return core

    # A commit set is the agreed row, provided that all members named by that
    # row have proposals available locally.
    def _commit_set(self, stage: RoundStage) -> int | None:
        agreed_row = self._agreed_row(stage)
        if agreed_row is None:
            return None
        
        # If any member of the agreed row has not made a proposal, then the 
        # commit set is not valid and we cannot commit.
        commit_members = bitmap_members(agreed_row, self.node_count)
        if any(member not in stage.proposals for member in commit_members):
            return None
        return agreed_row

    def _reset_pipeline(self, round_id: int) -> None:
        self.current_sound_set = self.installed_membership
        self.current_stage = RoundStage(
            round_id=-1,
            membership_epoch=self.installed_membership_epoch,
            installed_membership=self.current_sound_set,
        )
        self.evidence_stage = RoundStage(
            round_id=-1,
            membership_epoch=self.installed_membership_epoch,
            installed_membership=self.current_sound_set,
        )
        self.commit_stage = RoundStage(
            round_id=-2,
            membership_epoch=self.installed_membership_epoch,
            installed_membership=self.current_sound_set,
        )

    def _activate_pending_config_if_due(self, round_id: int) -> bool:
        if self.pending_config is None:
            return False
        if self.pending_config.status != PendingConfigStatus.COMMITTED:
            return False
        if round_id < self.pending_config.effective_round:
            return False

        # Activate the pending config by moving its parameters to the installed config, 
        # updating membership state, and resetting the pipeline. 
        pending = self.pending_config
        self.installed_membership_epoch = pending.membership_epoch
        self.installed_membership = pending.members_bitmap
        self.current_sound_set = self.installed_membership
        self.run_id = pending.run_id
        self.pending_config = None
        self.membership_state = MembershipState.ACTIVE
        self._reset_pipeline(round_id)
        return True

    def _emit_control_plane_event(self, event: JsonDict) -> None:
        self._control_plane_event_outbox.append(event)

    def pull_control_plane_events(self) -> list[JsonDict]:
        events = list(self._control_plane_event_outbox)
        self._control_plane_event_outbox.clear()
        return events

    def push_control_plane_update(self, update: ControlPlaneUpdate) -> None:
        # ClusterRun pushes one aggregated control-plane update and
        # raises a logical IRQ. The node does not pull global CP state itself.
        self._pending_control_plane_update = update
        self._control_plane_irq_pending = True

    def _apply_control_plane_update(self, round_id: int, update: ControlPlaneUpdate) -> None:
        # Apply the contents of a cluster-delivered control-plane update.
        # This may reboot a halted/crashed node, install repair
        # state, stage a pending config, or update the installed config.
        previous_state = self.membership_state
        previous_epoch = self.installed_membership_epoch
        previous_bitmap = self.installed_membership
        previous_run_id = self.run_id

        membership_state = update.membership_state
        self.installed_membership_epoch = update.installed_config.membership_epoch
        self.installed_membership = update.installed_config.members_bitmap
        self.current_sound_set = self.installed_membership
        self.run_id = update.installed_config.run_id
        self.pending_config = update.pending_config
        self.membership_state = membership_state
        repair_log = update.repair_log

        if self.status in (NodeStatus.CRASHED, NodeStatus.HALTED) and membership_state in (MembershipState.RECOVERING, MembershipState.REJOIN_PENDING, MembershipState.ACTIVE):
            self.status = NodeStatus.RUNNING
            self.status_reason = "rebooted_under_control_plane"
            self.halted_round = None
            self.halt_details = None

        if repair_log is not None and self._should_install_repair_log(repair_log):
            self._install_repair_log(round_id, repair_log)

        config_changed = any(
            (
                previous_epoch != self.installed_membership_epoch,
                previous_bitmap != self.installed_membership,
                previous_run_id != self.run_id,
            )
        )

        if previous_state != MembershipState.ACTIVE and membership_state == MembershipState.ACTIVE:
            self._reset_pipeline(round_id)
        elif config_changed:
            self._reset_pipeline(round_id)

        if self.run_id != previous_run_id:
            pass


    def _pull_control_plane_update(self, round_id: int) -> bool:
        # Pull one pending control-plane update at the start of the round.
        # This models the node-side handling path of a driver/firmware control
        # interrupt without letting the node talk to the control plane directly.
        if not self._control_plane_irq_pending or self._pending_control_plane_update is None:
            return False
        previous_pending = self.pending_config
        update = self._pending_control_plane_update
        self._pending_control_plane_update = None
        self._control_plane_irq_pending = False
        self._apply_control_plane_update(round_id, update)
        if (
            self.pending_config is not None
            and self.pending_config.status == PendingConfigStatus.PREPARED
            and self.pending_config != previous_pending
        ):
            self._emit_control_plane_event(
                {
                    "kind": "PrepareAck",
                    "node_id": self.node_id,
                    "config": {
                        "membership_epoch": self.pending_config.membership_epoch,
                        "members_bitmap": self.pending_config.members_bitmap,
                        "effective_round": self.pending_config.effective_round,
                        "run_id": self.pending_config.run_id,
                        "status": self.pending_config.status.value,
                    },
                }
            )
        return True

    def _new_current_stage(self, round_id: int) -> RoundStage:
        payload = self.payload_factory(self.node_id, round_id)
        return RoundStage(
            round_id=round_id,
            membership_epoch=self.installed_membership_epoch,
            installed_membership=self.current_sound_set,
            sound_bitmap=1 << self.node_id,
            proposals={self.node_id: payload},
            sound_matrix={},
        )

    def _default_destinations(self) -> tuple[int, ...]:
        return tuple(
            member
            for member in bitmap_members(self.current_sound_set, self.node_count)
            if member != self.node_id
        )

    def _committed_frontier(self) -> int | None:
        if self.committed_frontier < 0:
            return None
        return self.committed_frontier

    def _log_digest(self) -> str:
        return self.commit_digest

    def _digest_for_committed_rounds(
        self,
        committed_rounds: list[CommittedRoundRecord] | tuple[CommittedRoundRecord, ...],
    ) -> str:
        digest = hashlib.sha256(b"syncons-log-empty").hexdigest()
        for entry in committed_rounds:
            digest = self._extend_log_digest(digest, entry)
        return digest

    def _extend_log_digest(self, previous_digest: str, entry: CommittedRound | CommittedRoundRecord) -> str:
        encoded = json.dumps(
            {
                "previous_digest": previous_digest,
                "entry": entry.digest_projection(),
            },
            sort_keys=True,
            separators=(",", ":"),
        ).encode()
        return hashlib.sha256(encoded).hexdigest()

    def _should_install_repair_log(self, repair_log: RepairLog | None) -> bool:
        if repair_log is None:
            return False
        repair_frontier = -1 if not repair_log.entries else int(repair_log.entries[-1].round)
        if repair_frontier != self.committed_frontier:
            return True
        return self._digest_for_committed_rounds(repair_log.entries) != self._log_digest()

    # TODO:
    # In a real implementation, the repair log will not necessarily install in
    # the data-plane node itself. A local driver/agent may apply it on the node's
    # behalf. Here we install it directly in the node model for simulator
    # simplicity, while still routing the write through the cluster-mediated
    # control-plane mailbox.
    def _install_repair_log(
        self,
        round_id: int,
        repair_log: RepairLog,
    ) -> None:
        if not repair_log:
            return
        if repair_log.entries:
            self.committed_frontier = int(repair_log.entries[-1].round)
            self.last_committed_sound_set = None
        else:
            self.committed_frontier = -1
            self.last_committed_sound_set = None
        self.commit_digest = self._digest_for_committed_rounds(repair_log.entries)
        _ = round_id

    def _build_halt_record(
        self,
        *,
        stage: RoundStage,
        rows: dict[int, int],
        local_row: int,
        halt_reason: str,
    ) -> HaltRecord:
        return HaltRecord(
            failed_round=stage.round_id,
            membership_epoch=stage.membership_epoch,
            installed_membership_epoch=stage.membership_epoch,
            run_id=self.run_id,
            installed_membership=stage.installed_membership,
            quorum=self._quorum_for_membership(stage.installed_membership),
            observation_rows=dict(sorted(rows.items())),
            self_row=local_row,
            committed_frontier=self._committed_frontier(),
            sound_set_lineage=self.last_committed_sound_set,
            log_digest=self._log_digest(),
            halt_reason=halt_reason,
        )

    def _enter_halt_state(
        self,
        *,
        stage: RoundStage,
        rows: dict[int, int],
        local_row: int,
        halt_reason: str,
    ) -> tuple[str, None, tuple[CommittedRound, ...]]:
        self.status = NodeStatus.HALTED
        self.halted_round = self.current_round
        self.status_reason = halt_reason
        self.halt_details = self._build_halt_record(
            stage=stage,
            rows=rows,
            local_row=local_row,
            halt_reason=halt_reason,
        )
        self._emit_control_plane_event(
            {
                "kind": "NodeHalted",
                "node_id": self.node_id,
                "halt_record": self.halt_details.to_snapshot(),
            }
        )
        return "HALT", None, ()

    #
    # Main entry point for advancing the protocol by one round.
    # Time layering:
        # - commit_stage carries the previous round's exchanged sound-set rows;
        # - this round's boundary derives the agreed row, commit set, and sound set;
        # - the resulting sound set is then emitted as this round's sound bitmap.
    #
    def advance_round(self, new_round: int) -> NodeRoundResult:
        self.current_round = new_round

        # 1. Activate any pending config if it is due, before doing anything else. 
        # This ensures that we are always operating with the most up-to-date configuration, 
        # and that any control-plane-delivered config changes take effect at the intended round boundary.
        if self.status == NodeStatus.CRASHED and self.halted_round == new_round:
            return NodeRoundResult(outbound=None, new_commits=())
        self._activate_pending_config_if_due(new_round)
        self._pull_control_plane_update(new_round)

        # 2. Check if we are in a state that allows us to participate in the protocol. 
        # If not, we skip the round without mutating any state.
        if self.status != NodeStatus.RUNNING:
            return NodeRoundResult(outbound=None, new_commits=())

        if self.membership_state != MembershipState.ACTIVE or not (self.current_sound_set & (1 << self.node_id)):
            if self.membership_state != MembershipState.ACTIVE:
                skip_reason = f"membership_state_{self.membership_state.value.lower()}"
            else:
                skip_reason = "local_node_excluded_from_current_sound_set"
            _ = skip_reason
            return NodeRoundResult(outbound=None, new_commits=())

        # 3. !!! Critical Section !!!: Evaluate the round boundary using the
        # previous round's frozen sound-matrix evidence.
        self.commit_stage = self.evidence_stage
        self.evidence_stage = self.current_stage
        decision, sound_set, new_commits = self._evaluate_round_boundary()

        emitted_sound_set = self.current_sound_set
        if sound_set is not None:
            self.current_sound_set = sound_set
            emitted_sound_set = sound_set

        # The sound set derived at this boundary is the row we advertise for
        # the currently pending stage and exchange for the next round's
        # boundary evaluation.
        self.evidence_stage.sound_bitmap = emitted_sound_set
        self.evidence_stage.sound_matrix[self.node_id] = emitted_sound_set
        self.current_stage = self._new_current_stage(new_round)

        # 4. If the decision is to halt, update status and emit control plane event, 
        # but do not prepare a packet for the new round since we are halting and will 
        # not be participating in the next round.
        if decision == "HALT":
            return NodeRoundResult(outbound=None, new_commits=new_commits)

        # 5. If we are continuing, prepare a packet for the new round and return it for sending.
        packet = Packet(
            round_id=new_round,
            src_id=self.node_id,
            run_id=self.run_id,
            sound_bitmap=self.evidence_stage.sound_bitmap,
            payload=self.current_stage.proposals[self.node_id],
        )
        outbound = OutboundPacket(
            packet=packet,
            destinations=self._default_destinations(),
        )
        return NodeRoundResult(outbound=outbound, new_commits=new_commits)

    # !!!!!!! IMPORTANT !!!!!!! 
    # The logic in this method encodes the core safety rules of the protocol.
    def _evaluate_round_boundary(self) -> tuple[str, int | None, tuple[CommittedRound, ...]]:
        stage = self.commit_stage
        if stage.round_id < 0:
            return "SKIP", None, ()

        rows = self._observation_rows(stage)
        commit_set = self._commit_set(stage)
        sound_set = self._sound_set(stage)
        agreed_row = self._agreed_row(stage)
        local_row = stage.sound_matrix.get(self.node_id, 0)
        previous_sound_set = self.current_sound_set

        # 1. If there is no agreed row, or if the commit set or sound set cannot be formed,
        # then we cannot safely continue and must halt.
        if agreed_row is None or commit_set is None or sound_set is None:
            if agreed_row is None:
                halt_reason = "no_agreed_row"
            elif commit_set is None:
                halt_reason = "commit_set_not_valid"
            else:
                halt_reason = "no_sound_set"
            return self._enter_halt_state(
                stage=stage,
                rows=rows,
                local_row=local_row,
                halt_reason=halt_reason,
            )

        # 2. If the sound set does not include the local node, then we are not part of the agreement and must halt.
        if not (sound_set & (1 << self.node_id)):
            halt_reason = "local_node_excluded_from_sound_set"
            return self._enter_halt_state(
                stage=stage,
                rows=rows,
                local_row=local_row,
                halt_reason=halt_reason,
            )

        # 3. If the sound set expands outside the previous sound set,
        # then we have a safety violation and must halt.
        if (sound_set & self.current_sound_set) != sound_set:
            halt_reason = "sound_set_not_subset_of_previous_set"
            return self._enter_halt_state(
                stage=stage,
                rows=rows,
                local_row=local_row,
                halt_reason=halt_reason,
            )

        committed = CommittedRound(
            round=stage.round_id,
            membership_epoch=stage.membership_epoch,
            commit_set=commit_set,
            proposals={
                member: stage.proposals[member]
                for member in bitmap_members(commit_set, self.node_count)
            },
        )
        self.committed_frontier = committed.round
        self.last_committed_sound_set = sound_set
        self.commit_digest = self._extend_log_digest(self.commit_digest, committed)
        return "CONTINUE", sound_set, (committed,)

    def receive(self, packet: Packet) -> None:
        if self.status != NodeStatus.RUNNING:
            return

        if self.membership_state != MembershipState.ACTIVE:
            return

        if not (self.current_sound_set & (1 << packet.src_id)):
            return

        if packet.run_id != self.run_id:
            return

        if packet.round_id == self.current_round:
            self.current_stage.sound_bitmap |= 1 << packet.src_id
            self.current_stage.proposals[packet.src_id] = packet.payload
            # The sender's current-round sound bitmap becomes row evidence for
            # the next boundary evaluation of the currently pending stage.
            self.evidence_stage.sound_matrix[packet.src_id] = packet.sound_bitmap
            return

        if packet.round_id < self.current_round - 1:
            return

    def crash(self, round_id: int) -> None:
        if self.status == NodeStatus.RUNNING:
            self.status = NodeStatus.CRASHED
            self.status_reason = "crash_fault"
            self.halted_round = round_id
            self._emit_control_plane_event(
                {
                    "kind": "NodeCrashed",
                    "node_id": self.node_id,
                }
            )


    def snapshot(self) -> JsonDict:
        snapshot = {
            "node_id": self.node_id,
            "status": self.status.value,
            "status_reason": self.status_reason,
            "membership_state": self.membership_state.value,
            "membership_epoch": self.installed_membership_epoch,
            "run_id": self.run_id,
            "installed_membership": self.installed_membership,
            "current_sound_set": self.current_sound_set,
            "pending_config": None
            if self.pending_config is None
            else {
                "membership_epoch": self.pending_config.membership_epoch,
                "members_bitmap": self.pending_config.members_bitmap,
                "effective_round": self.pending_config.effective_round,
                "run_id": self.pending_config.run_id,
                "status": self.pending_config.status.value,
            },
            "current_round": self.current_round,
            "committed_frontier": self._committed_frontier(),
            "last_committed_sound_set": self.last_committed_sound_set,
            "commit_digest": self.commit_digest,
            "halted_round": self.halted_round,
            "halt_details": None if self.halt_details is None else self.halt_details.to_snapshot(),
        }
        return snapshot
