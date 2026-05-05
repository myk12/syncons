from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass, field
from .types import CommittedRoundEntry, ControlPlaneTransaction, HaltRecord, MembershipState, NodeStatus, OutboundPacket, PayloadFactory, Packet, PendingConfigStatus, RepairLog, RoundStage, bitmap_members, bitmap_text


def default_payload(node_id: int, round_id: int) -> str:
    return f"node{node_id}:round{round_id}"


@dataclass
class Node:
    node_id: int
    node_count: int
    payload_factory: PayloadFactory = default_payload
    status: NodeStatus = NodeStatus.RUNNING
    current_round: int = 0
    status_reason: str | None = None
    committed_rounds: list[CommittedRoundEntry] = field(default_factory=list)
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
        self.trace: list[str] = []
        self.last_round_boundary_evaluation: dict[str, object] | None = None
        self.last_control_plane_action = "none"
        self.last_control_plane_details: list[str] = []
        self._control_plane_event_outbox: list[dict[str, object]] = []
        self._pending_control_plane_transaction: ControlPlaneTransaction | None = None
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
        self.trace.append(f"round {round_id}: reset fast-path pipeline")

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
        self.last_control_plane_details.append(
            "activate_pending "
            + f"membership_epoch={pending.membership_epoch} "
            + f"members={bitmap_text(pending.members_bitmap, self.node_count)} "
            + f"run_id={pending.run_id}"
        )
        self.trace.append(
            "round "
            + str(round_id)
            + ": locally activates committed pending config "
            + f"membership_epoch={pending.membership_epoch} "
            + f"members={bitmap_text(pending.members_bitmap, self.node_count)} "
            + f"run_id={pending.run_id}"
        )
        return True

    def _emit_control_plane_event(self, event: dict[str, object]) -> None:
        self._control_plane_event_outbox.append(event)

    def drain_control_plane_events(self) -> list[dict[str, object]]:
        events = list(self._control_plane_event_outbox)
        self._control_plane_event_outbox.clear()
        return events

    def write_control_plane_transaction(self, transaction: ControlPlaneTransaction) -> None:
        # ClusterRun writes one aggregated control-plane mailbox transaction and
        # raises a logical IRQ. The node does not pull global CP state itself.
        self._pending_control_plane_transaction = transaction
        self._control_plane_irq_pending = True

    def _apply_control_plane_transaction(self, round_id: int, transaction: ControlPlaneTransaction) -> None:
        # Apply the contents of a cluster-delivered control-plane mailbox
        # transaction. This may reboot a halted/crashed node, install repair
        # state, stage a pending config, or update the installed config.
        previous_state = self.membership_state
        previous_epoch = self.installed_membership_epoch
        previous_bitmap = self.installed_membership
        previous_run_id = self.run_id

        membership_state = transaction.membership_state
        self.installed_membership_epoch = transaction.installed_config.membership_epoch
        self.installed_membership = transaction.installed_config.members_bitmap
        self.current_sound_set = self.installed_membership
        self.run_id = transaction.installed_config.run_id
        self.pending_config = transaction.pending_config
        self.membership_state = membership_state
        repair_log = transaction.repair_log

        if self.status in (NodeStatus.CRASHED, NodeStatus.HALTED) and membership_state in (MembershipState.RECOVERING, MembershipState.REJOIN_PENDING, MembershipState.ACTIVE):
            self.status = NodeStatus.RUNNING
            self.status_reason = "rebooted_under_control_plane"
            self.halted_round = None
            self.halt_details = None
            self.last_control_plane_details.append(
                f"reboot membership_state={membership_state.value} run_id={self.run_id}"
            )
            self.trace.append(
                f"round {round_id}: rebooted into membership state {membership_state.value} with run_id {self.run_id}"
            )

        if repair_log is not None and self._needs_repair_log(repair_log):
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
            self.last_control_plane_details.append(
                "activate_installed "
                + f"membership_epoch={self.installed_membership_epoch} "
                + f"members={bitmap_text(self.installed_membership, self.node_count)}"
            )
            self.trace.append(
                "round "
                + str(round_id)
                + f": control plane activated installed_membership_epoch={self.installed_membership_epoch} "
                + f"installed={bitmap_text(self.installed_membership, self.node_count)}"
            )
        elif config_changed:
            self._reset_pipeline(round_id)
            self.last_control_plane_details.append(
                "install_config "
                + f"membership_epoch={self.installed_membership_epoch} "
                + f"members={bitmap_text(self.installed_membership, self.node_count)}"
            )
            self.trace.append(
                "round "
                + str(round_id)
                + f": installed config updated to membership_epoch={self.installed_membership_epoch} "
                + f"members={bitmap_text(self.installed_membership, self.node_count)}"
            )

        if self.run_id != previous_run_id:
            self.last_control_plane_details.append(f"install_run_id={self.run_id}")
            self.trace.append(
                f"round {round_id}: control plane installs run_id {self.run_id}"
            )

        if self.pending_config is not None:
            self.last_control_plane_details.append(
                "pending_config "
                + f"status={self.pending_config.status.value} "
                + f"effective_round={self.pending_config.effective_round} "
                + f"members={bitmap_text(self.pending_config.members_bitmap, self.node_count)} "
                + f"run_id={self.pending_config.run_id}"
            )

    def _consume_control_plane_transaction(self, round_id: int) -> bool:
        # Consume one pending mailbox transaction at the start of the round.
        # This models the node-side handling path of a driver/firmware control
        # interrupt without letting the node talk to the control plane directly.
        if not self._control_plane_irq_pending or self._pending_control_plane_transaction is None:
            return False
        previous_pending = self.pending_config
        transaction = self._pending_control_plane_transaction
        self._pending_control_plane_transaction = None
        self._control_plane_irq_pending = False
        self.last_control_plane_details.append("consume_cp_irq")
        self._apply_control_plane_transaction(round_id, transaction)
        if (
            self.pending_config is not None
            and self.pending_config.status == PendingConfigStatus.PREPARED
            and self.pending_config != previous_pending
        ):
            self.last_control_plane_details.append("emit_PrepareAck")
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
        if not self.committed_rounds:
            return None
        return int(self.committed_rounds[-1].round)

    def _log_digest(self) -> str:
        return self._digest_for_committed_rounds(self.committed_rounds)

    def _digest_for_committed_rounds(
        self,
        committed_rounds: list[CommittedRoundEntry] | tuple[CommittedRoundEntry, ...],
    ) -> str:
        committed_prefix = [entry.digest_projection() for entry in committed_rounds]
        encoded = json.dumps(committed_prefix, sort_keys=True, separators=(",", ":")).encode()
        return hashlib.sha256(encoded).hexdigest()

    def _needs_repair_log(self, repair_log: RepairLog | None) -> bool:
        if repair_log is None:
            return False
        if len(repair_log) != len(self.committed_rounds):
            return True
        return self._digest_for_committed_rounds(repair_log.entries) != self._log_digest()

    # TODO:
    # In a real implementation, the repair log will not necessarily install in
    # the dataplane node itself. A local driver/agent may apply it on the node's
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
        self.committed_rounds = list(repair_log.entries)
        digest = self._log_digest()[:12]
        self.last_control_plane_details.append(
            f"repair_log len={len(self.committed_rounds)} digest={digest}"
        )
        self.trace.append(
            f"round {round_id}: repaired committed log len={len(self.committed_rounds)} digest={digest}"
        )

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
            sound_set_lineage=None if not self.committed_rounds else self.committed_rounds[-1].sound_set,
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
        trace_message: str,
        evaluation: dict[str, object],
    ) -> tuple[str, None]:
        self.status = NodeStatus.HALTED
        self.halted_round = self.current_round
        self.status_reason = halt_reason
        evaluation["decision"] = "HALT"
        evaluation["halt_reason"] = halt_reason
        self.last_round_boundary_evaluation = evaluation
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
        self.trace.append(f"round {self.current_round}: halt on round {stage.round_id}, {trace_message}")
        return "HALT", None

    def _set_boundary_skip(self, *, reason: str, stage_round: int | None = None) -> None:
        self.last_round_boundary_evaluation = {
            "evaluated": False,
            "reason": reason,
            "stage_round": stage_round,
        }

    #
    # Main entry point for advancing the protocol by one round.
    # Time layering:
        # - commit_stage carries the previous round's exchanged sound-set rows;
        # - this round's boundary derives the agreed row, commit set, and sound set;
        # - the resulting sound set is then emitted as this round's sound bitmap.
    #
    def advance_round(self, new_round: int) -> OutboundPacket | None:
        self.current_round = new_round

        # 1. Activate any pending config if it is due, before doing anything else. 
        # This ensures that we are always operating with the most up-to-date configuration, 
        # and that any control-plane-delivered config changes take effect at the intended round boundary.
        self.last_control_plane_action = "none"
        self.last_control_plane_details = []
        if self.status == NodeStatus.CRASHED and self.halted_round == new_round:
            self._set_boundary_skip(reason="crash_injected_at_round_start")
            self.trace.append(f"round {new_round}: crash injected at round start, no control-plane work or shift")
            return None
        self._activate_pending_config_if_due(new_round)
        self.last_control_plane_action = "applied" if self._consume_control_plane_transaction(new_round) else "none"

        # 2. Check if we are in a state that allows us to participate in the protocol. 
        # If not, we skip the round without mutating any state.
        if self.status != NodeStatus.RUNNING:
            self._set_boundary_skip(reason=f"status_{self.status.value.lower()}")
            self.trace.append(f"round {new_round}: {self.status.value.lower()}, no shift")
            return None

        if self.membership_state != MembershipState.ACTIVE or not (self.current_sound_set & (1 << self.node_id)):
            if self.membership_state != MembershipState.ACTIVE:
                skip_reason = f"membership_state_{self.membership_state.value.lower()}"
            else:
                skip_reason = "local_node_excluded_from_current_sound_set"
            self._set_boundary_skip(reason=skip_reason)
            self.trace.append(
                f"round {new_round}: membership_state={self.membership_state.value}, no fast-path participation"
            )
            return None

        # 3. !!! Critical Section !!!: Evaluate the round boundary using the
        # previous round's frozen sound-matrix evidence.
        self.commit_stage = self.evidence_stage
        self.evidence_stage = self.current_stage
        decision, sound_set = self._evaluate_round_boundary()

        emitted_sound_set = self.current_sound_set
        if sound_set is not None:
            self.current_sound_set = sound_set
            emitted_sound_set = sound_set
            self.trace.append(
                f"round {new_round}: continue on sound set {bitmap_text(sound_set, self.node_count)}"
            )

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
            self.trace.append(f"round {new_round}: fail-stop triggered")
            return None

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
        self.trace.append(
            "round "
            + str(new_round)
            + f": tx run_id={packet.run_id} "
            + f"sound={bitmap_text(packet.sound_bitmap, self.node_count)} payload={packet.payload} "
            + f"dst={outbound.destinations}"
        )
        return outbound

    # !!!!!!! IMPORTANT !!!!!!! 
    # The logic in this method encodes the core safety rules of the protocol.
    def _evaluate_round_boundary(self) -> tuple[str, int | None]:
        stage = self.commit_stage
        if stage.round_id < 0:
            self.last_round_boundary_evaluation = {
                "evaluated": False,
                "reason": "pipeline_not_warm",
                "stage_round": stage.round_id,
            }
            return "SKIP", None

        rows = self._observation_rows(stage)
        commit_set = self._commit_set(stage)
        sound_set = self._sound_set(stage)
        agreed_row = self._agreed_row(stage)
        local_row = stage.sound_matrix.get(self.node_id, 0)
        previous_sound_set = self.current_sound_set

        evaluation = {
            "evaluated": True,
            "stage_round": stage.round_id,
            "membership_epoch": stage.membership_epoch,
            "installed_membership": stage.installed_membership,
            "quorum": self._quorum_for_membership(stage.installed_membership),
            "observation_rows": dict(sorted(rows.items())),
            "self_row": local_row,
            "agreed_row": agreed_row,
            "commit_set": commit_set,
            "sound_set": sound_set,
            "previous_sound_set": previous_sound_set,
        }

        # 1. If there is no agreed row, or if the commit set or sound set cannot be formed,
        # then we cannot safely continue and must halt.
        if agreed_row is None or commit_set is None or sound_set is None:
            if agreed_row is None:
                halt_reason = "no_agreed_row"
                trace_message = "no agreed row"
            elif commit_set is None:
                halt_reason = "commit_set_not_valid"
                trace_message = "commit set not locally valid"
            else:
                halt_reason = "no_sound_set"
                trace_message = "no sound set"
            return self._enter_halt_state(
                stage=stage,
                rows=rows,
                local_row=local_row,
                halt_reason=halt_reason,
                trace_message=trace_message,
                evaluation=evaluation,
            )

        # 2. If the sound set does not include the local node, then we are not part of the agreement and must halt.
        if not (sound_set & (1 << self.node_id)):
            halt_reason = "local_node_excluded_from_sound_set"
            return self._enter_halt_state(
                stage=stage,
                rows=rows,
                local_row=local_row,
                halt_reason=halt_reason,
                trace_message="local node excluded from sound set",
                evaluation=evaluation,
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
                trace_message=(
                    f"sound set {bitmap_text(sound_set, self.node_count)} expands outside previous set "
                    f"{bitmap_text(self.current_sound_set, self.node_count)}"
                ),
                evaluation=evaluation,
            )

        committed = CommittedRoundEntry(
            round=stage.round_id,
            membership_epoch=stage.membership_epoch,
            installed_membership=stage.installed_membership,
            commit_set=commit_set,
            members=tuple(bitmap_members(commit_set, self.node_count)),
            agreed_row=agreed_row,
            sound_set=sound_set,
            observation_rows=dict(sorted(rows.items())),
            proposals={
                member: stage.proposals[member]
                for member in bitmap_members(commit_set, self.node_count)
            },
        )
        self.committed_rounds.append(committed)
        evaluation["decision"] = "CONTINUE"
        self.last_round_boundary_evaluation = evaluation
        self.trace.append(
            f"round {self.current_round}: commit round {stage.round_id} on row {bitmap_text(agreed_row, self.node_count)} with sound set {bitmap_text(sound_set, self.node_count)}"
        )
        return "CONTINUE", sound_set

    def receive(self, packet: Packet) -> None:
        if self.status != NodeStatus.RUNNING:
            self.trace.append(
                f"round {self.current_round}: ignored packet from node {packet.src_id}, local node {self.status.value.lower()}"
            )
            return

        if self.membership_state != MembershipState.ACTIVE:
            self.trace.append(
                f"round {self.current_round}: ignored packet from node {packet.src_id}, membership_state={self.membership_state.value}"
            )
            return

        if not (self.current_sound_set & (1 << packet.src_id)):
            self.trace.append(
                f"round {self.current_round}: drop packet from node {packet.src_id}, sender outside local fast-path universe"
            )
            return

        if packet.run_id != self.run_id:
            self.trace.append(
                f"round {self.current_round}: drop packet from node {packet.src_id}, run_id {packet.run_id} != local {self.run_id}"
            )
            return

        if packet.round_id == self.current_round:
            self.current_stage.sound_bitmap |= 1 << packet.src_id
            self.current_stage.proposals[packet.src_id] = packet.payload
            # The sender's current-round sound bitmap becomes row evidence for
            # the next boundary evaluation of the currently pending stage.
            self.evidence_stage.sound_matrix[packet.src_id] = packet.sound_bitmap
            self.trace.append(
                f"round {self.current_round}: rx current packet from node {packet.src_id}, "
                f"run_id={packet.run_id} sound={bitmap_text(packet.sound_bitmap, self.node_count)}"
            )
            return

        if packet.round_id < self.current_round - 1:
            self.trace.append(
                f"round {self.current_round}: drop stale packet from node {packet.src_id} for round {packet.round_id}"
            )
            return

        self.trace.append(
            f"round {self.current_round}: ignore late packet from node {packet.src_id} for round {packet.round_id}"
        )

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
            self.trace.append(f"round {round_id}: crash fault injected")

    def _stage_debug_snapshot(self, stage: RoundStage) -> dict[str, object]:
        return {
            "round": stage.round_id,
            "membership_epoch": stage.membership_epoch,
            "installed_membership": stage.installed_membership,
            "sound_bitmap": stage.sound_bitmap,
            "proposals": dict(sorted(stage.proposals.items())),
            "sound_matrix": {
                member: stage.sound_matrix.get(member, 0)
                for member in range(self.node_count)
            },
        }

    def round_debug_snapshot(self) -> dict[str, object]:
        return {
            "node_id": self.node_id,
            "status": self.status.value,
            "status_reason": self.status_reason,
            "membership_state": self.membership_state.value,
            "membership_epoch": self.installed_membership_epoch,
            "installed_membership": self.installed_membership,
            "current_sound_set": self.current_sound_set,
            "run_id": self.run_id,
            "pending_config": None
            if self.pending_config is None
            else {
                "membership_epoch": self.pending_config.membership_epoch,
                "members_bitmap": self.pending_config.members_bitmap,
                "effective_round": self.pending_config.effective_round,
                "run_id": self.pending_config.run_id,
                "status": self.pending_config.status.value,
            },
            "committed_rounds": [
                entry.to_snapshot()
                for entry in self.committed_rounds
            ],
            "last_round_boundary_evaluation": self.last_round_boundary_evaluation,
            "current_stage": self._stage_debug_snapshot(self.current_stage),
            "evidence_stage": self._stage_debug_snapshot(self.evidence_stage),
            "commit_stage": self._stage_debug_snapshot(self.commit_stage),
        }

    def snapshot(self, *, include_trace: bool = True) -> dict[str, object]:
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
            "committed_rounds": [entry.to_snapshot() for entry in self.committed_rounds],
            "halted_round": self.halted_round,
            "halt_details": None if self.halt_details is None else self.halt_details.to_snapshot(),
        }
        if include_trace:
            snapshot["trace"] = self.trace
        return snapshot
