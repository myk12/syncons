from __future__ import annotations

from dataclasses import dataclass, field

from .types import EpochStage, MembershipState, NodeStatus, PayloadFactory, Packet, bitmap_members, bitmap_text


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
        self.local_membership_epoch = 0
        self.active_membership = (1 << self.node_count) - 1
        self.current_stage = EpochStage(epoch_id=-1, membership_epoch=0, membership_bitmap=0)
        self.ack_stage = EpochStage(epoch_id=-1, membership_epoch=0, membership_bitmap=0)
        self.commit_stage = EpochStage(epoch_id=-2, membership_epoch=0, membership_bitmap=0)
        self.trace: list[str] = []

    def _quorum_for_bitmap(self, membership_bitmap: int) -> int:
        return max(1, membership_bitmap.bit_count() // 2 + 1)

    def _reset_pipeline(self, epoch_id: int) -> None:
        self.current_stage = EpochStage(epoch_id=-1, membership_epoch=self.local_membership_epoch, membership_bitmap=self.active_membership)
        self.ack_stage = EpochStage(epoch_id=-1, membership_epoch=self.local_membership_epoch, membership_bitmap=self.active_membership)
        self.commit_stage = EpochStage(epoch_id=-2, membership_epoch=self.local_membership_epoch, membership_bitmap=self.active_membership)
        self.trace.append(f"epoch {epoch_id}: reset fast-path pipeline")

    def apply_control_plane(
        self,
        epoch_id: int,
        membership_epoch: int,
        active_membership: int,
        membership_state: MembershipState,
    ) -> None:
        previous_state = self.membership_state
        previous_epoch = self.local_membership_epoch
        previous_bitmap = self.active_membership

        self.local_membership_epoch = membership_epoch
        self.active_membership = active_membership
        self.membership_state = membership_state

        if self.status == NodeStatus.CRASHED and membership_state in (MembershipState.RECOVERING, MembershipState.REJOIN_PENDING, MembershipState.ACTIVE):
            self.status = NodeStatus.RUNNING
            self.status_reason = "rebooted_under_control_plane"
            self.trace.append(f"epoch {epoch_id}: rebooted into membership state {membership_state.value}")

        if previous_state != MembershipState.ACTIVE and membership_state == MembershipState.ACTIVE:
            self._reset_pipeline(epoch_id)
            self.trace.append(
                f"epoch {epoch_id}: control plane activated membership_epoch={membership_epoch} active={bitmap_text(active_membership, self.node_count)}"
            )

    def _new_current_stage(self, epoch_id: int) -> EpochStage:
        payload = self.payload_factory(self.node_id, epoch_id)
        return EpochStage(
            epoch_id=epoch_id,
            membership_epoch=self.local_membership_epoch,
            membership_bitmap=self.active_membership,
            my_bitmap=1 << self.node_id,
            proposals={self.node_id: payload},
            ack_matrix={},
        )

    def advance_epoch(self, new_epoch: int) -> Packet | None:
        if self.status != NodeStatus.RUNNING:
            self.trace.append(f"epoch {new_epoch}: {self.status.value.lower()}, no shift")
            return None

        self.current_epoch = new_epoch

        if self.membership_state != MembershipState.ACTIVE or not (self.active_membership & (1 << self.node_id)):
            self.trace.append(
                f"epoch {new_epoch}: membership_state={self.membership_state.value}, no fast-path participation"
            )
            return None

        self.commit_stage = self.ack_stage
        self.ack_stage = self.current_stage
        self.ack_stage.ack_matrix[self.node_id] = self.ack_stage.my_bitmap
        commit_result = self._evaluate_commit()
        self.current_stage = self._new_current_stage(new_epoch)

        if commit_result == "HALT":
            self.trace.append(f"epoch {new_epoch}: fail-stop triggered")
            return None

        packet = Packet(
            epoch_id=new_epoch,
            src_id=self.node_id,
            membership_epoch=self.local_membership_epoch,
            ack_bitmap=self.ack_stage.my_bitmap,
            payload=self.current_stage.proposals[self.node_id],
        )
        self.trace.append(
            f"epoch {new_epoch}: tx membership_epoch={packet.membership_epoch} ack={bitmap_text(packet.ack_bitmap, self.node_count)} payload={packet.payload}"
        )
        return packet

    def _evaluate_commit(self) -> str:
        stage = self.commit_stage
        if stage.epoch_id < 0:
            return "SKIP"

        # Fast path tolerates minority omission/crash faults, but it does not
        # tolerate inconsistent views or loss of quorum for the validation window.
        nonzero_rows = {src: row for src, row in stage.ack_matrix.items() if row != 0}
        liveness_count = len(nonzero_rows)
        mismatch_rows = {
            src: row
            for src, row in nonzero_rows.items()
            if row != stage.my_bitmap
        }
        quorum = self._quorum_for_bitmap(stage.membership_bitmap)

        if liveness_count >= quorum and not mismatch_rows:
            committed = {
                "epoch": stage.epoch_id,
                "membership_epoch": stage.membership_epoch,
                "membership_bitmap": stage.membership_bitmap,
                "bitmap": stage.my_bitmap,
                "members": bitmap_members(stage.my_bitmap, self.node_count),
                "proposals": dict(sorted(stage.proposals.items())),
            }
            self.committed_epochs.append(committed)
            self.trace.append(
                f"epoch {self.current_epoch}: commit epoch {stage.epoch_id} with view {bitmap_text(stage.my_bitmap, self.node_count)}"
            )
            return "COMMIT"

        self.status = NodeStatus.HALTED
        self.halted_epoch = self.current_epoch
        self.status_reason = "view_mismatch_or_no_quorum"
        self.halt_details = {
            "failed_epoch": stage.epoch_id,
            "membership_epoch": stage.membership_epoch,
            "membership_bitmap": stage.membership_bitmap,
            "expected_bitmap": stage.my_bitmap,
            "ack_rows": dict(sorted(stage.ack_matrix.items())),
            "liveness_count": liveness_count,
            "quorum": quorum,
            "mismatch_rows": dict(sorted(mismatch_rows.items())),
        }
        self.trace.append(
            f"epoch {self.current_epoch}: halt on epoch {stage.epoch_id}, rows={liveness_count}, mismatches={list(mismatch_rows)}"
        )
        return "HALT"

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

        if packet.membership_epoch != self.local_membership_epoch:
            self.trace.append(
                f"epoch {self.current_epoch}: drop packet from node {packet.src_id}, membership_epoch {packet.membership_epoch} != local {self.local_membership_epoch}"
            )
            return

        if not (self.active_membership & (1 << packet.src_id)):
            self.trace.append(
                f"epoch {self.current_epoch}: drop packet from inactive node {packet.src_id}"
            )
            return

        if packet.epoch_id == self.current_epoch:
            self.current_stage.my_bitmap |= 1 << packet.src_id
            self.current_stage.proposals[packet.src_id] = packet.payload
            self.ack_stage.ack_matrix[packet.src_id] = packet.ack_bitmap
            self.trace.append(
                f"epoch {self.current_epoch}: rx current packet from node {packet.src_id}, "
                f"membership_epoch={packet.membership_epoch} ack={bitmap_text(packet.ack_bitmap, self.node_count)}"
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

    def snapshot(self) -> dict[str, object]:
        return {
            "node_id": self.node_id,
            "status": self.status.value,
            "status_reason": self.status_reason,
            "membership_state": self.membership_state.value,
            "membership_epoch": self.local_membership_epoch,
            "active_membership": self.active_membership,
            "current_epoch": self.current_epoch,
            "committed_epochs": self.committed_epochs,
            "halted_epoch": self.halted_epoch,
            "halt_details": self.halt_details,
            "trace": self.trace,
        }
