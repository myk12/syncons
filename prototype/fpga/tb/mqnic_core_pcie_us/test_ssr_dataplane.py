# SPDX-License-Identifier: BSD-2-Clause-Views
# Copyright (c) 2021-2023 The Regents of the University of California

import logging
import os
import sys

import cocotb_test.simulator
import pytest

import cocotb
from cocotb.log import SimLog
from cocotb.triggers import RisingEdge, Timer

try:
    from test_mqnic_core_pcie_us import TB, wait_sink_slots
    import mqnic
    import ssr_dataplane as ssr
except ImportError:
    sys.path.insert(0, os.path.join(os.path.dirname(__file__)))
    try:
        from test_mqnic_core_pcie_us import TB, wait_sink_slots
        import mqnic
        import ssr_dataplane as ssr
    finally:
        del sys.path[0]


RBB_CONSENSUS = 0x00003000
CONSENSUS_REG_HALT = RBB_CONSENSUS + 0x000
CONSENSUS_REG_GLOBAL_ENABLE = RBB_CONSENSUS + 0x004
CONSENSUS_REG_CTRL_RUN_ID = RBB_CONSENSUS + 0x008
CONSENSUS_REG_CTRL_MEMBERSHIP = RBB_CONSENSUS + 0x00C
CONSENSUS_REG_CTRL_ACTIVATE = RBB_CONSENSUS + 0x010
CONSENSUS_REG_CTRL_REBOOT = RBB_CONSENSUS + 0x014


async def configure_ssr(tb, ssr_rb):
    tb.log.info("Configure SSR dataplane")

    await ssr_rb.write_dword(ssr.RBB_COMMON + ssr.COMMON_REG_CONFIG_REPLICA_ID, 0x00000001)
    await ssr_rb.write_dword(ssr.RBB_COMMON + ssr.COMMON_REG_CONFIG_REPLICA_NUM, 0x00000003)
    await ssr_rb.write_dword(ssr.RBB_COMMON + ssr.COMMON_REG_CONFIG_ROUND_LEN_NS, 0x00000800)
    await ssr_rb.write_dword(ssr.RBB_COMMON + ssr.COMMON_REG_CONFIG_ETH_TYPE, 0x00000177)

    mac_addrs = [
        [0x00, 0x11, 0x22, 0x33, 0x44, 0x55],
        [0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb],
        [0xcc, 0xdd, 0xee, 0xff, 0x00, 0x11],
    ]
    for i, mac in enumerate(mac_addrs):
        mac_int = (mac[0] << 40) | (mac[1] << 32) | (mac[2] << 24) | (mac[3] << 16) | (mac[4] << 8) | mac[5]
        await ssr_rb.write_dword(ssr.RBB_COMMON + ssr.COMMON_REG_CONFIG_MACTABLE_ADDR_LO + i * 8, mac_int & 0xffffffff)
        await ssr_rb.write_dword(ssr.RBB_COMMON + ssr.COMMON_REG_CONFIG_MACTABLE_ADDR_HI + i * 8, (mac_int >> 32) & 0xffff)

    await ssr_rb.write_dword(CONSENSUS_REG_GLOBAL_ENABLE, 0x1)
    await ssr_rb.write_dword(CONSENSUS_REG_CTRL_RUN_ID, 0x1)
    await ssr_rb.write_dword(CONSENSUS_REG_CTRL_MEMBERSHIP, 0x7)
    await ssr_rb.write_dword(CONSENSUS_REG_CTRL_ACTIVATE, 0x1)

    for _ in range(8):
        await RisingEdge(tb.dut.clk)


async def wait_for_halt(tb, ssr_rb, timeout_cycles=128):
    for _ in range(timeout_cycles):
        halt = await ssr_rb.read_dword(CONSENSUS_REG_HALT)
        if halt:
            return True
        await RisingEdge(tb.dut.clk)
    return False


@cocotb.test()
async def run_test_ssr_dataplane_end_to_end(dut):
    tb = TB(dut, msix_count=2 ** len(dut.core_pcie_inst.irq_index))
    await tb.init()

    tb.log.info("Init driver")
    await tb.driver.init_pcie_dev(tb.rc.find_device(tb.dev.functions[0].pcie_id))
    for interface in tb.driver.interfaces:
        await interface.ndevs[0].open()

    app_reg_blocks = mqnic.RegBlockList()
    await app_reg_blocks.enumerate_reg_blocks(tb.driver.app_hw_regs)

    ssr_rb = app_reg_blocks.find(ssr.SSR_RB_TYPE, ssr.SSR_RB_VERSION)
    assert ssr_rb is not None, "SSR register block not found"

    tb.log.info("Check basic SSR register block identity")
    assert await ssr_rb.read_dword(ssr.RBB_COMMON + ssr.COMMON_REG_TYPE) == ssr.SSR_RB_TYPE
    assert await ssr_rb.read_dword(ssr.RBB_COMMON + ssr.COMMON_REG_VERSION) == ssr.SSR_RB_VERSION
    assert await ssr_rb.read_dword(ssr.RBB_COMMON + ssr.COMMON_REG_FEATURES) == ssr.SSR_RB_FEATURES

    await configure_ssr(tb, ssr_rb)

    tb.log.info("Healthy packet send/receive path")
    payload = bytes([x % 256 for x in range(64)])
    tx_data = int.from_bytes(payload, byteorder="little")
    tx_keep = (1 << 64) - 1

    dut.m_axis_if_tx_tready.value = 1
    dut.m_axis_if_rx_tready.value = 1

    dut.s_axis_if_tx_tdata.value = tx_data
    dut.s_axis_if_tx_tkeep.value = tx_keep
    dut.s_axis_if_tx_tvalid.value = 1
    dut.s_axis_if_tx_tlast.value = 1
    dut.s_axis_if_tx_tid.value = 0
    dut.s_axis_if_tx_tdest.value = 0
    dut.s_axis_if_tx_tuser.value = 0

    for _ in range(8):
        await RisingEdge(tb.dut.clk)

    assert int(dut.m_axis_if_tx_tvalid.value) == 1
    assert int(dut.m_axis_if_tx_tlast.value) == 1
    assert int(dut.m_axis_if_tx_tdata.value) == tx_data
    assert int(dut.m_axis_if_tx_tkeep.value) == tx_keep

    dut.s_axis_if_rx_tdata.value = tx_data
    dut.s_axis_if_rx_tkeep.value = tx_keep
    dut.s_axis_if_rx_tvalid.value = 1
    dut.s_axis_if_rx_tlast.value = 1
    dut.s_axis_if_rx_tid.value = 0
    dut.s_axis_if_rx_tdest.value = 0
    dut.s_axis_if_rx_tuser.value = 0

    for _ in range(8):
        await RisingEdge(tb.dut.clk)

    assert int(dut.m_axis_if_rx_tvalid.value) == 1
    assert int(dut.m_axis_if_rx_tlast.value) == 1
    assert int(dut.m_axis_if_rx_tdata.value) == tx_data
    assert int(dut.m_axis_if_rx_tkeep.value) == tx_keep

    tb.log.info("Read back the consensus halt signal in the healthy case")
    halt = await ssr_rb.read_dword(CONSENSUS_REG_HALT)
    assert halt == 0, "Consensus dataplane should not halt while behaving normally"

    tb.log.info("Force an invalid consensus configuration and verify halt goes high")
    await ssr_rb.write_dword(CONSENSUS_REG_CTRL_MEMBERSHIP, 0x0)
    await ssr_rb.write_dword(CONSENSUS_REG_CTRL_RUN_ID, 0x2)
    await ssr_rb.write_dword(CONSENSUS_REG_GLOBAL_ENABLE, 0x1)
    await ssr_rb.write_dword(CONSENSUS_REG_CTRL_ACTIVATE, 0x1)

    halt_observed = await wait_for_halt(tb, ssr_rb)
    assert halt_observed, "Consensus dataplane did not assert halt for the invalid configuration"
