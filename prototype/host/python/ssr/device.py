"""Abstract dataplane device interface for the host-side control plane."""

from __future__ import annotations

from typing import Any, Protocol

from .consensus_regs import ActiveConfig, FastPathStatus, PendingConfig


class DataplaneDevice(Protocol):
    """Minimal device contract required by the control plane.

    Implementations may be backed by a mock, direct MMIO, ioctl, or a future
    userspace library over a kernel driver.
    """

    def get_info(self) -> dict[str, Any]:
        """Return static device/application identity information."""

    def get_status(self) -> FastPathStatus:
        """Return the current fast-path status snapshot."""

    def set_active_config(self, cfg: ActiveConfig) -> None:
        """Install the currently active configuration."""

    def set_pending_config(self, cfg: PendingConfig) -> None:
        """Stage a pending configuration for later activation."""

    def commit_pending_config(self) -> None:
        """Mark the pending configuration committed."""

    def arm_activation(self) -> None:
        """Arm activation for the committed pending configuration."""

    def enable_app(self) -> None:
        """Enable fast-path execution."""

    def disable_app(self) -> None:
        """Disable fast-path execution."""

    def clear_halt(self) -> None:
        """Clear any latched halt condition."""

    def soft_reset(self) -> None:
        """Reset app-visible state while keeping the device reachable."""

