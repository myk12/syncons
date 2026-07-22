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

import struct

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


async def configure_ssr(tb, ssr_rb):
    tb.log.info("Configure SSR dataplane")

    await ssr_rb.write_dword(ssr.RBB_COMMON + ssr.COMMON_REG_CONFIG_REPLICA_ID, 0x00000000)
    await ssr_rb.write_dword(ssr.RBB_COMMON + ssr.COMMON_REG_CONFIG_REPLICA_NUM, 0x00000003)
    await ssr_rb.write_dword(ssr.RBB_COMMON + ssr.COMMON_REG_CONFIG_ROUND_LEN_NS, 0x0BEBC200)
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


async def activate_consensus_core(tb, ssr_rb):
    await ssr_rb.write_dword(ssr.CONSENSUS_REG_GLOBAL_ENABLE, 0x1)
    await ssr_rb.write_dword(ssr.CONSENSUS_REG_CTRL_RUN_ID, 0x1)
    await ssr_rb.write_dword(ssr.CONSENSUS_REG_CTRL_MEMBERSHIP, 0x7)
    await ssr_rb.write_dword(ssr.CONSENSUS_REG_CTRL_ACTIVATE, 0x1)

    for _ in range(8):
        await RisingEdge(tb.dut.clk)

async def wait_for_halt(tb, ssr_rb, timeout_cycles=128):
    for _ in range(timeout_cycles):
        halt = await ssr_rb.read_dword(ssr.CONSENSUS_REG_HALT)
        if halt:
            return True
        await RisingEdge(tb.dut.clk)
    return False

def configure_packet(tb, run_id, knowledge_vec, node_id, round_id, payload):
    packet = bytearray(64)

    # Ethernet Heade
    packet[12:14] = struct.pack(">H", 0x88B5)

    # Consensus Header
    packet[14:22] = struct.pack(">Q", run_id)
    packet[22] = knowledge_vec & 0xFF
    packet[23] = node_id & 0xFF
    packet[24:32] = struct.pack(">Q", round_id)

    # Payload
    for i in range(4):
        shift = i * 64
        word = (payload >> shift) & 0xFFFFFFFFFFFFFFFF

        packet[32 + i*8 : 40 + i*8] = struct.pack(">Q", word)

    # return bytes(packet)
    return int.from_bytes(packet, "little")

async def parse_packet(tb, packet):
    # Ethernet
    ethernet_type = int.from_bytes(packet[12:14], "big")

    # Consensus Header
    run_id = int.from_bytes(packet[14:22], "big")
    knowledge_vec = packet[22]
    node_id = packet[23]
    round_id = int.from_bytes(packet[24:32], "big")

    # Payload
    payload = 0
    for i in range(4):
        word = int.from_bytes(packet[32 + i*8 : 40 + i*8], "big")
        payload |= word << (64 * i)

    return {
        "ethernet_type": ethernet_type,
        "run_id": run_id,
        "knowledge_vec": knowledge_vec,
        "node_id": node_id,
        "round_id": round_id,
        "payload": payload,
    }

async def send_packet(tb, dut, packet_to_send):
    ssr_dp_path = dut.core_pcie_inst.core_inst.app.app_block_inst.ssr_dataplane_inst

    ssr_dp_path.s_axis_if_rx_tdata.value = packet_to_send
    ssr_dp_path.s_axis_if_rx_tvalid.value = 1
    ssr_dp_path.s_axis_if_rx_tlast.value = 1
    ssr_dp_path.s_axis_if_rx_tdest.value = 0

    return

@cocotb.test()
async def run_test_ssr_dataplane_end_to_end(dut):
    '''
    Testbench steps:
    1. inits
    2. load up tx buffer with multiple proposals
    3. start the consensus core and new run
    4. start sending in packets to the rx, make sure that the core doesn't stop
    5. make sure that the tx is sending out the correct proposals that we loaded
    
    6. reset and try the same thing but with the tx buffer not completely full
    7. make sure that the tx is still sending out packets even if they sometimes don't have proposals

    8. reset and try with the sound set getting smaller but the current core still being part of it
    9. check that the tx is stil sending out packets, just not to ones are aren't part of the sound set anymore

    10. reset and try with the sound set causing the current core to halt
    11. check nothing gets sent out
    '''

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

    tb.log.info("Test SSR DMA Proposal Datapath")

    # path to ssr dataplane
    ssr_dp_path = dut.core_pcie_inst.core_inst.app.app_block_inst.ssr_dataplane_inst

    proposal_count = 7
    slot_bytes = 1024
    stride = slot_bytes

    # allocate memory for DMA buffer
    mem = tb.rc.mem_pool.alloc_region(proposal_count*stride)
    mem_base = mem.get_absolute_address(0)

    # fill DMA buffer with test data
    for i in range(proposal_count):
        payload = bytearray([(x+i) % 256 for x in range(slot_bytes)])
        mem[i*stride:(i+1)*stride] = payload

    await ssr_rb.write_dword(ssr.PROP_DMA_REG_ADDR_LO, mem_base & 0xffffffff)                # address low
    await ssr_rb.write_dword(ssr.PROP_DMA_REG_ADDR_HI, (mem_base >> 32) & 0xffffffff)          # address high
    await ssr_rb.write_dword(ssr.PROP_DMA_REG_LEN, slot_bytes)                                      # length
    await ssr_rb.write_dword(ssr.PROP_DMA_REG_STRIDE_LO, stride & 0xffffffff)                                   # stride low
    await ssr_rb.write_dword(ssr.PROP_DMA_REG_STRIDE_HI, (stride >> 32) & 0xffffffff)          # stride high
    await ssr_rb.write_dword(ssr.PROP_DMA_REG_COUNT, proposal_count)                              # control (set start bit)

    # await ssr_rb.write_dword(ssr.PROP_DMA_REG_CONTROL, 0x00000001)                                  # control (set start bit)

    # status = await ssr_rb.read_dword(ssr.PROP_DMA_REG_STATUS)
    # tb.log.info("SSR DMA Proposal status: 0x%08x", status)

    await activate_consensus_core(tb, ssr_rb)

    while (ssr_dp_path.reg_wr_addr.value != 0x3010 or ssr_dp_path.reg_wr_ack != 1):
        await RisingEdge(tb.dut.clk)

    for i in range(20):
        await RisingEdge(tb.dut.clk)

    tb.log.info("First Cycle of Startup - no TX expected")

    for i in range(1,3):
        packet = configure_packet(tb, 0x1, 0x7, i, 0, 0xDEADBEEF)
        await send_packet(tb, dut, packet)

        for j in range(5):
            await RisingEdge(tb.dut.clk)

    tb.log.info("Second Cycle of Startup - TX expected")




    tb.log.info("First Full Cycle - no halt expected")



    tb.log.info("Remaning Cycles - shouldn't halt")


    payload = bytes([x % 256 for x in range(64)])
    tx_data = int.from_bytes(payload, byteorder="little")
    tx_keep = (1 << 64) - 1

    ssr_dp_path.m_axis_if_tx_tready.value = 1
    ssr_dp_path.m_axis_if_rx_tready.value = 1

    ssr_dp_path.s_axis_if_tx_tdata.value = tx_data
    ssr_dp_path.s_axis_if_tx_tkeep.value = tx_keep
    ssr_dp_path.s_axis_if_tx_tvalid.value = 1
    ssr_dp_path.s_axis_if_tx_tlast.value = 1
    ssr_dp_path.s_axis_if_tx_tid.value = 0
    ssr_dp_path.s_axis_if_tx_tdest.value = 0
    ssr_dp_path.s_axis_if_tx_tuser.value = 0

    for _ in range(8):
        await RisingEdge(tb.dut.clk)

    assert int(ssr_dp_path.m_axis_if_tx_tvalid.value) == 1
    assert int(ssr_dp_path.m_axis_if_tx_tlast.value) == 1
    assert int(ssr_dp_path.m_axis_if_tx_tdata.value) == tx_data
    assert int(ssr_dp_path.m_axis_if_tx_tkeep.value) == tx_keep

    ssr_dp_path.s_axis_if_rx_tdata.value = tx_data
    ssr_dp_path.s_axis_if_rx_tkeep.value = tx_keep
    ssr_dp_path.s_axis_if_rx_tvalid.value = 1
    ssr_dp_path.s_axis_if_rx_tlast.value = 1
    ssr_dp_path.s_axis_if_rx_tid.value = 0
    ssr_dp_path.s_axis_if_rx_tdest.value = 0
    ssr_dp_path.s_axis_if_rx_tuser.value = 0

    for _ in range(8):
        await RisingEdge(tb.dut.clk)

    assert int(ssr_dp_path.m_axis_if_rx_tvalid.value) == 1
    assert int(ssr_dp_path.m_axis_if_rx_tlast.value) == 1
    assert int(ssr_dp_path.m_axis_if_rx_tdata.value) == tx_data
    assert int(ssr_dp_path.m_axis_if_rx_tkeep.value) == tx_keep

    tb.log.info("Read back the consensus halt signal in the healthy case")
    halt = await ssr_rb.read_dword(ssr.CONSENSUS_REG_HALT)
    assert halt == 0, "Consensus dataplane should not halt while behaving normally"

    tb.log.info("Force an invalid consensus configuration and verify halt goes high")
    await ssr_rb.write_dword(ssr.CONSENSUS_REG_CTRL_MEMBERSHIP, 0x0)
    await ssr_rb.write_dword(ssr.CONSENSUS_REG_CTRL_RUN_ID, 0x2)
    await ssr_rb.write_dword(ssr.CONSENSUS_REG_GLOBAL_ENABLE, 0x1)
    await ssr_rb.write_dword(ssr.CONSENSUS_REG_CTRL_ACTIVATE, 0x1)

    halt_observed = await wait_for_halt(tb, ssr_rb)
    assert halt_observed, "Consensus dataplane did not assert halt for the invalid configuration"
