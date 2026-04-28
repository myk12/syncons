from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass, field
from .types import ControlPlaneState, EpochStage, MembershipState, NodeStatus, OutboundPacket, PayloadFactory, Packet, bitmap_members, bitmap_text


def default_payload(node_id: int, epoch_id: int) -> str:
    return f"node{node_id}:epoch{epoch_id}"


@dataclass
class Node:
    node_id: int
    node_count: int
    payload_factory: PayloadFactory = default_payload
    status: NodeStatus = NodeStatus.RUNNING
    current_epoch: int = 0
    status_reason: str | None = None
    committed_epochs: list[dict[str, object]] = field(default_factory=list)
    halted_epoch: int | None = None
    halt_details: dict[str, object] | None = None

    def __post_init__(self) -> None:
        self.membership_state = MembershipState.ACTIVE
        self.installed_membership_epoch = 0
        self.installed_membership = (1 << self.node_count) - 1
        self.fast_path_bitmap = self.installed_membership
        self.run_id = 0
        self.pending_config = None
        self.current_stage = EpochStage(epoch_id=-1, membership_epoch=0, membership_bitmap=0)
        self.ack_stage = EpochStage(epoch_id=-1, membership_epoch=0, membership_bitmap=0)
        self.commit_stage = EpochStage(epoch_id=-2, membership_epoch=0, membership_bitmap=0)
        self.trace: list[str] = []
        self.last_boundary_evaluation: dict[str, object] | None = None

    def _quorum_for_bitmap(self, membership_bitmap: int) -> int:
        return max(1, membership_bitmap.bit_count() // 2 + 1)

    def _observation_rows(self, stage: EpochStage) -> dict[int, int]:
        members = bitmap_members(stage.membership_bitmap, self.node_count)
        return {member: stage.ack_matrix.get(member, 0) for member in members}

    def _row_is_valid(self, src: int, row: int) -> bool:
        if row == 0:
            return True
        return bool(row & (1 << src))

    # A certified row is one that has a quorum of witnesses in agreement 
    # on the same non-zero bitmap, and the local node must be included 
    # in that bitmap.
    def _certified_row(self, stage: EpochStage) -> int | None:
        members = bitmap_members(stage.membership_bitmap, self.node_count)
        quorum = self._quorum_for_bitmap(stage.membership_bitmap)
        rows = self._observation_rows(stage)

        for src, row in rows.items():
            # If the row is not valid according to the sender's own bitmap, ignore it.
            if not self._row_is_valid(src, row):
                return None

        local_row = rows.get(self.node_id, 0)
        if local_row == 0:
            return None
        
        # Count how many witnesses have the same row as the local node. We require a quorum 
        # of witnesses in agreement on the same row for it to be certified.
        witness_count = sum(1 for member in members if rows[member] == local_row)
        if witness_count < quorum:
            return None

        return local_row

    # A witness core is the set of nodes that have the same certified row as the local node. 
    # It may be a subset of the commit set, but it must include the local node and must not 
    # expand outside the previous witness core.
    def _witness_core(self, stage: EpochStage) -> int | None:
        rows = self._observation_rows(stage)
        certified_row = self._certified_row(stage)
        if certified_row is None:
            return None

        core = 0
        for member, row in rows.items():
            if row == certified_row:
                core |= 1 << member
        return core

    # Backward-compatible alias used by tests that focus on the runnable-group rule.
    def _candidate_quorum(self, stage: EpochStage) -> int | None:
        return self._witness_core(stage)

    # A commit set is a certified row for which all members have made a proposal. 
    # It may be the same as the witness core or a subset of it, but it must include 
    # the local node.
    def _commit_set(self, stage: EpochStage) -> int | None:
        certified_row = self._certified_row(stage)
        if certified_row is None:
            return None
        
        # If any member of the certified row has not made a proposal, then the 
        # commit set is not valid and we cannot commit.
        commit_members = bitmap_members(certified_row, self.node_count)
        if any(member not in stage.proposals for member in commit_members):
            return None
        return certified_row

    def _reset_pipeline(self, epoch_id: int) -> None:
        self.fast_path_bitmap = self.installed_membership
        self.current_stage = EpochStage(
            epoch_id=-1,
            membership_epoch=self.installed_membership_epoch,
            membership_bitmap=self.fast_path_bitmap,
        )
        self.ack_stage = EpochStage(
            epoch_id=-1,
            membership_epoch=self.installed_membership_epoch,
            membership_bitmap=self.fast_path_bitmap,
        )
        self.commit_stage = EpochStage(
            epoch_id=-2,
            membership_epoch=self.installed_membership_epoch,
            membership_bitmap=self.fast_path_bitmap,
        )
        self.trace.append(f"epoch {epoch_id}: reset fast-path pipeline")

    def _needs_control_plane_transaction(self, control_state: ControlPlaneState) -> bool:
        membership_state = control_state.node_states.get(self.node_id, MembershipState.FAILED)
        return any(
            (
                membership_state != self.membership_state,
                control_state.membership_epoch != self.installed_membership_epoch,
                control_state.installed_membership != self.installed_membership,
                control_state.run_id != self.run_id,
                control_state.pending_config != self.pending_config,
            )
        )

    def _apply_control_plane_transaction(self, epoch_id: int, control_state: ControlPlaneState) -> None:
        previous_state = self.membership_state
        previous_epoch = self.installed_membership_epoch
        previous_bitmap = self.installed_membership
        previous_run_id = self.run_id

        membership_state = control_state.node_states.get(self.node_id, MembershipState.FAILED)
        self.installed_membership_epoch = control_state.membership_epoch
        self.installed_membership = control_state.installed_membership
        self.fast_path_bitmap = self.installed_membership
        self.run_id = control_state.run_id
        self.pending_config = control_state.pending_config
        self.membership_state = membership_state

        if self.status == NodeStatus.CRASHED and membership_state in (MembershipState.RECOVERING, MembershipState.REJOIN_PENDING, MembershipState.ACTIVE):
            self.status = NodeStatus.RUNNING
            self.status_reason = "rebooted_under_control_plane"
            self.trace.append(
                f"epoch {epoch_id}: rebooted into membership state {membership_state.value} with run_id {self.run_id}"
            )

        if previous_state != MembershipState.ACTIVE and membership_state == MembershipState.ACTIVE:
            self._reset_pipeline(epoch_id)
            self.trace.append(
                "epoch "
                + str(epoch_id)
                + f": control plane activated installed_membership_epoch={self.installed_membership_epoch} "
                + f"installed={bitmap_text(self.installed_membership, self.node_count)}"
            )
        elif previous_epoch != self.installed_membership_epoch or previous_bitmap != self.installed_membership:
            self.trace.append(
                "epoch "
                + str(epoch_id)
                + f": installed config updated to epoch={self.installed_membership_epoch} "
                + f"members={bitmap_text(self.installed_membership, self.node_count)}"
            )

        if self.run_id != previous_run_id:
            self.trace.append(
                f"epoch {epoch_id}: control plane installs run_id {self.run_id}"
            )

    def poll_control_plane(self, epoch_id: int, control_state: ControlPlaneState) -> bool:
        if not self._needs_control_plane_transaction(control_state):
            return False

        self._apply_control_plane_transaction(epoch_id, control_state)
        return True

    def _new_current_stage(self, epoch_id: int) -> EpochStage:
        payload = self.payload_factory(self.node_id, epoch_id)
        return EpochStage(
            epoch_id=epoch_id,
            membership_epoch=self.installed_membership_epoch,
            membership_bitmap=self.fast_path_bitmap,
            my_bitmap=1 << self.node_id,
            proposals={self.node_id: payload},
            ack_matrix={},
        )

    def _default_destinations(self) -> tuple[int, ...]:
        return tuple(
            member
            for member in bitmap_members(self.fast_path_bitmap, self.node_count)
            if member != self.node_id
        )

    def _committed_frontier(self) -> int | None:
        if not self.committed_epochs:
            return None
        return int(self.committed_epochs[-1]["epoch"])

    def _log_digest(self) -> str:
        committed_prefix = [
            {
                "epoch": entry["epoch"],
                "membership_epoch": entry["membership_epoch"],
                "bitmap": entry["bitmap"],
                "proposals": entry["proposals"],
            }
            for entry in self.committed_epochs
        ]
        encoded = json.dumps(committed_prefix, sort_keys=True, separators=(",", ":")).encode()
        return hashlib.sha256(encoded).hexdigest()

    def advance_epoch(self, new_epoch: int) -> OutboundPacket | None:
        # 1. Check if the node is already halted or crashed
        if self.status != NodeStatus.RUNNING:
            self.trace.append(f"epoch {new_epoch}: {self.status.value.lower()}, no shift")
            return None

        self.current_epoch = new_epoch

        # 2. Check if the node is eligible for fast-path participation
        if self.membership_state != MembershipState.ACTIVE or not (self.fast_path_bitmap & (1 << self.node_id)):
            self.trace.append(
                f"epoch {new_epoch}: membership_state={self.membership_state.value}, no fast-path participation"
            )
            return None

        # 3. Shift the pipeline stages and evaluate the new witness core plus commit set
        self.commit_stage = self.ack_stage
        self.ack_stage = self.current_stage
        self.ack_stage.ack_matrix[self.node_id] = self.ack_stage.my_bitmap
        decision, continuation_group = self._evaluate_epoch_boundary()

        if continuation_group is not None:
            self.fast_path_bitmap = continuation_group
            self.trace.append(
                f"epoch {new_epoch}: continue on witness core {bitmap_text(continuation_group, self.node_count)}"
            )
        self.current_stage = self._new_current_stage(new_epoch)

        # 4. If commit failed, halt the node
        if decision == "HALT":
            self.trace.append(f"epoch {new_epoch}: fail-stop triggered")
            return None

        # 5. If commit succeeded, prepare the packet for the new epoch
        packet = Packet(
            epoch_id=new_epoch,
            src_id=self.node_id,
            run_id=self.run_id,
            ack_bitmap=self.ack_stage.my_bitmap,
            payload=self.current_stage.proposals[self.node_id],
        )
        outbound = OutboundPacket(
            packet=packet,
            destinations=self._default_destinations(),
        )
        self.trace.append(
            "epoch "
            + str(new_epoch)
            + f": tx run_id={packet.run_id} "
            + f"ack={bitmap_text(packet.ack_bitmap, self.node_count)} payload={packet.payload} "
            + f"dst={outbound.destinations}"
        )
        return outbound

    # !!!!!!! IMPORTANT !!!!!!! 
    # The logic in this method encodes the core safety rules of the protocol.
    def _evaluate_epoch_boundary(self) -> tuple[str, int | None]:
        stage = self.commit_stage
        if stage.epoch_id < 0:
            self.last_boundary_evaluation = {
                "evaluated": False,
                "reason": "pipeline_not_warm",
                "stage_epoch": stage.epoch_id,
            }
            return "SKIP", None

        rows = self._observation_rows(stage)
        commit_set = self._commit_set(stage)
        witness_core = self._witness_core(stage)
        certified_row = self._certified_row(stage)
        local_row = stage.ack_matrix.get(self.node_id, 0)
        previous_core = self.fast_path_bitmap

        evaluation = {
            "evaluated": True,
            "stage_epoch": stage.epoch_id,
            "membership_epoch": stage.membership_epoch,
            "membership_bitmap": stage.membership_bitmap,
            "quorum": self._quorum_for_bitmap(stage.membership_bitmap),
            "observation_rows": dict(sorted(rows.items())),
            "self_row": local_row,
            "certified_row": certified_row,
            "commit_set": commit_set,
            "witness_core": witness_core,
            "previous_witness_core": previous_core,
        }

        # 1. If there is no certified row, or if the commit set or witness core cannot be formed, 
        # then we cannot safely continue and must halt.
        if certified_row is None or commit_set is None or witness_core is None:
            self.status = NodeStatus.HALTED
            self.halted_epoch = self.current_epoch

            if certified_row is None:
                halt_reason = "no_certified_row"
            elif commit_set is None:
                halt_reason = "commit_set_not_valid"
            else:
                halt_reason = "no_witness_core"

            evaluation["decision"] = "HALT"
            evaluation["halt_reason"] = halt_reason
            self.last_boundary_evaluation = evaluation
            self.status_reason = halt_reason
            self.halt_details = {
                "failed_epoch": stage.epoch_id,
                "membership_epoch": stage.membership_epoch,
                "installed_membership_epoch": stage.membership_epoch,
                "run_id": self.run_id,
                "membership_bitmap": stage.membership_bitmap,
                "quorum": self._quorum_for_bitmap(stage.membership_bitmap),
                "observation_rows": dict(sorted(rows.items())),
                "self_row": local_row,
                "committed_frontier": self._committed_frontier(),
                "witness_core_lineage": None if not self.committed_epochs else self.committed_epochs[-1]["witness_core"],
                "log_digest": self._log_digest(),
                "halt_reason": halt_reason,
            }
            self.trace.append(
                f"epoch {self.current_epoch}: halt on epoch {stage.epoch_id}, no certified row"
            )
            return "HALT", None

        # 2. If the witness core does not include the local node, then we are not part of the agreement and must halt.
        if not (witness_core & (1 << self.node_id)):
            self.status = NodeStatus.HALTED
            self.halted_epoch = self.current_epoch
            halt_reason = "local_node_excluded_from_witness_core"
            evaluation["decision"] = "HALT"
            evaluation["halt_reason"] = halt_reason
            self.last_boundary_evaluation = evaluation
            self.status_reason = halt_reason
            self.halt_details = {
                "failed_epoch": stage.epoch_id,
                "membership_epoch": stage.membership_epoch,
                "installed_membership_epoch": stage.membership_epoch,
                "run_id": self.run_id,
                "membership_bitmap": stage.membership_bitmap,
                "quorum": self._quorum_for_bitmap(stage.membership_bitmap),
                "observation_rows": dict(sorted(rows.items())),
                "self_row": local_row,
                "committed_frontier": self._committed_frontier(),
                "witness_core_lineage": None if not self.committed_epochs else self.committed_epochs[-1]["witness_core"],
                "log_digest": self._log_digest(),
                "halt_reason": halt_reason,
            }
            self.trace.append(
                f"epoch {self.current_epoch}: halt on epoch {stage.epoch_id}, local node excluded from witness core"
            )
            return "HALT", None

        # 3. If the witness core expands outside the previous witness core, 
        # then we have a safety violation and must halt.
        if (witness_core & self.fast_path_bitmap) != witness_core:
            self.status = NodeStatus.HALTED
            self.halted_epoch = self.current_epoch
            halt_reason = "witness_core_not_subset_of_previous_core"
            evaluation["decision"] = "HALT"
            evaluation["halt_reason"] = halt_reason
            self.last_boundary_evaluation = evaluation
            self.status_reason = halt_reason
            self.halt_details = {
                "failed_epoch": stage.epoch_id,
                "membership_epoch": stage.membership_epoch,
                "installed_membership_epoch": stage.membership_epoch,
                "run_id": self.run_id,
                "membership_bitmap": stage.membership_bitmap,
                "quorum": self._quorum_for_bitmap(stage.membership_bitmap),
                "observation_rows": dict(sorted(rows.items())),
                "self_row": local_row,
                "committed_frontier": self._committed_frontier(),
                "witness_core_lineage": None if not self.committed_epochs else self.committed_epochs[-1]["witness_core"],
                "log_digest": self._log_digest(),
                "halt_reason": halt_reason,
            }
            self.trace.append(
                f"epoch {self.current_epoch}: halt on epoch {stage.epoch_id}, witness core {bitmap_text(witness_core, self.node_count)} expands outside previous core {bitmap_text(self.fast_path_bitmap, self.node_count)}"
            )
            return "HALT", None

        committed = {
            "epoch": stage.epoch_id,
            "membership_epoch": stage.membership_epoch,
            "membership_bitmap": stage.membership_bitmap,
            "bitmap": commit_set,
            "members": bitmap_members(commit_set, self.node_count),
            "certified_row": certified_row,
            "witness_core": witness_core,
            "observation_rows": dict(sorted(rows.items())),
            "proposals": dict(sorted(stage.proposals.items())),
        }
        self.committed_epochs.append(committed)
        evaluation["decision"] = "CONTINUE"
        self.last_boundary_evaluation = evaluation
        self.trace.append(
            f"epoch {self.current_epoch}: commit epoch {stage.epoch_id} on row {bitmap_text(certified_row, self.node_count)} with witness core {bitmap_text(witness_core, self.node_count)}"
        )
        return "CONTINUE", witness_core

    def receive(self, packet: Packet) -> None:
        if self.status != NodeStatus.RUNNING:
            self.trace.append(
                f"epoch {self.current_epoch}: ignored packet from node {packet.src_id}, local node {self.status.value.lower()}"
            )
            return

        if self.membership_state != MembershipState.ACTIVE:
            self.trace.append(
                f"epoch {self.current_epoch}: ignored packet from node {packet.src_id}, membership_state={self.membership_state.value}"
            )
            return

        if not (self.fast_path_bitmap & (1 << packet.src_id)):
            self.trace.append(
                f"epoch {self.current_epoch}: drop packet from node {packet.src_id}, sender outside local fast-path universe"
            )
            return

        if packet.run_id != self.run_id:
            self.trace.append(
                f"epoch {self.current_epoch}: drop packet from node {packet.src_id}, run_id {packet.run_id} != local {self.run_id}"
            )
            return

        if packet.epoch_id == self.current_epoch:
            self.current_stage.my_bitmap |= 1 << packet.src_id
            self.current_stage.proposals[packet.src_id] = packet.payload
            self.ack_stage.ack_matrix[packet.src_id] = packet.ack_bitmap
            self.trace.append(
                f"epoch {self.current_epoch}: rx current packet from node {packet.src_id}, "
                f"run_id={packet.run_id} ack={bitmap_text(packet.ack_bitmap, self.node_count)}"
            )
            return

        if packet.epoch_id < self.current_epoch - 1:
            self.trace.append(
                f"epoch {self.current_epoch}: drop stale packet from node {packet.src_id} for epoch {packet.epoch_id}"
            )
            return

        self.trace.append(
            f"epoch {self.current_epoch}: ignore late packet from node {packet.src_id} for epoch {packet.epoch_id}"
        )

    def crash(self, epoch_id: int) -> None:
        if self.status == NodeStatus.RUNNING:
            self.status = NodeStatus.CRASHED
            self.status_reason = "crash_fault"
            self.halted_epoch = epoch_id
            self.trace.append(f"epoch {epoch_id}: crash fault injected")

    def _stage_debug_snapshot(self, stage: EpochStage) -> dict[str, object]:
        return {
            "epoch": stage.epoch_id,
            "membership_epoch": stage.membership_epoch,
            "membership_bitmap": stage.membership_bitmap,
            "my_bitmap": stage.my_bitmap,
            "proposals": dict(sorted(stage.proposals.items())),
            "ack_rows": {
                member: stage.ack_matrix.get(member, 0)
                for member in range(self.node_count)
            },
        }

    def epoch_debug_snapshot(self) -> dict[str, object]:
        return {
            "node_id": self.node_id,
            "status": self.status.value,
            "status_reason": self.status_reason,
            "membership_state": self.membership_state.value,
            "membership_epoch": self.installed_membership_epoch,
            "installed_membership": self.installed_membership,
            "fast_path_bitmap": self.fast_path_bitmap,
            "run_id": self.run_id,
            "last_boundary_evaluation": self.last_boundary_evaluation,
            "current_stage": self._stage_debug_snapshot(self.current_stage),
            "ack_stage": self._stage_debug_snapshot(self.ack_stage),
            "commit_stage": self._stage_debug_snapshot(self.commit_stage),
        }

    def snapshot(self) -> dict[str, object]:
        return {
            "node_id": self.node_id,
            "status": self.status.value,
            "status_reason": self.status_reason,
            "membership_state": self.membership_state.value,
            "membership_epoch": self.installed_membership_epoch,
            "run_id": self.run_id,
            "installed_membership": self.installed_membership,
            "fast_path_bitmap": self.fast_path_bitmap,
            "active_membership": self.installed_membership,
            "pending_config": None
            if self.pending_config is None
            else {
                "membership_epoch": self.pending_config.membership_epoch,
                "members_bitmap": self.pending_config.members_bitmap,
                "effective_epoch": self.pending_config.effective_epoch,
                "run_id": self.pending_config.run_id,
            },
            "current_epoch": self.current_epoch,
            "committed_epochs": self.committed_epochs,
            "halted_epoch": self.halted_epoch,
            "halt_details": self.halt_details,
            "trace": self.trace,
        }
