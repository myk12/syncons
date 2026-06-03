"""In-memory mock dataplane device for control-plane bring-up."""

from __future__ import annotations

from dataclasses import dataclass

from .consensus_regs import ActiveConfig, AppStatus, FastPathStatus, HaltReason, PendingConfig


@dataclass
class MockDataplaneDevice:
    """Simple fake device for early control-plane development.

    The model is intentionally small:
    - active and pending configs are tracked independently
    - activation copies pending -> active immediately
    - round/commit progress can be advanced manually by tests
    - halt state can be injected and cleared explicitly
    """

    app_id: int = 0x53535201
    app_version: int = 1
    active_config: ActiveConfig | None = None
    pending_config: PendingConfig | None = None
    pending_committed: bool = False
    activation_armed: bool = False
    app_enabled: bool = False
    current_round: int = 0
    last_commit_round: int = 0
    last_commit_index: int = 0
    halt_reason: HaltReason = HaltReason.NONE
    halt_round: int = 0
    halt_info: int = 0
    heartbeat: int = 0

    def get_info(self) -> dict[str, int]:
        return {
            "app_id": self.app_id,
            "app_version": self.app_version,
        }

    def get_status(self) -> FastPathStatus:
        self.heartbeat += 1

        status = AppStatus(0)
        if self.app_enabled:
            status |= AppStatus.APP_ENABLED
        if self.app_enabled and self.halt_reason == HaltReason.NONE:
            status |= AppStatus.APP_ACTIVE
        if self.halt_reason != HaltReason.NONE:
            status |= AppStatus.HALT_VALID
        if self.pending_config is not None:
            status |= AppStatus.PENDING_CFG_VALID
        if self.pending_committed:
            status |= AppStatus.PENDING_CFG_COMMITTED
        if self.activation_armed:
            status |= AppStatus.ACTIVATION_ARMED

        return FastPathStatus(
            app_status=status,
            current_round=self.current_round,
            last_commit_round=self.last_commit_round,
            last_commit_index=self.last_commit_index,
            halt_reason=self.halt_reason,
            halt_round=self.halt_round,
            halt_info=self.halt_info,
        )

    def set_active_config(self, cfg: ActiveConfig) -> None:
        self.active_config = cfg

    def set_pending_config(self, cfg: PendingConfig) -> None:
        self.pending_config = cfg
        self.pending_committed = False
        self.activation_armed = False

    def commit_pending_config(self) -> None:
        if self.pending_config is None:
            raise RuntimeError("no pending configuration installed")
        self.pending_committed = True

    def arm_activation(self) -> None:
        if self.pending_config is None or not self.pending_committed:
            raise RuntimeError("pending configuration is not committed")
        self.activation_armed = True

    def enable_app(self) -> None:
        if self.active_config is None:
            raise RuntimeError("active configuration must be installed first")
        self.app_enabled = True

    def disable_app(self) -> None:
        self.app_enabled = False

    def clear_halt(self) -> None:
        self.halt_reason = HaltReason.NONE
        self.halt_round = 0
        self.halt_info = 0

    def soft_reset(self) -> None:
        self.pending_config = None
        self.pending_committed = False
        self.activation_armed = False
        self.app_enabled = False
        self.current_round = 0
        self.last_commit_round = 0
        self.last_commit_index = 0
        self.clear_halt()

    def inject_halt(self, reason: HaltReason, halt_info: int = 0) -> None:
        self.halt_reason = reason
        self.halt_round = self.current_round
        self.halt_info = halt_info

    def advance_round(
        self,
        *,
        commit: bool = False,
        committed_entries: int = 0,
    ) -> None:
        self.current_round += 1

        if (
            self.activation_armed
            and self.pending_config is not None
            and self.current_round >= self.pending_config.activation_round
        ):
            self.active_config = ActiveConfig(
                run_id=self.pending_config.run_id,
                epoch=self.pending_config.epoch,
                membership=self.pending_config.membership,
                round_length_ns=(
                    self.active_config.round_length_ns if self.active_config else 0
                ),
                node_id=self.active_config.node_id if self.active_config else 0,
                cluster_size=(
                    self.active_config.cluster_size if self.active_config else 0
                ),
            )
            self.pending_config = None
            self.pending_committed = False
            self.activation_armed = False

        if commit:
            self.last_commit_round = self.current_round
            self.last_commit_index += committed_entries
