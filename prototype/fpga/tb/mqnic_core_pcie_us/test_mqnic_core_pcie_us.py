# SPDX-License-Identifier: BSD-2-Clause-Views
# Copyright (c) 2021-2023 The Regents of the University of California

import logging
import os
import struct
import sys

import scapy.utils
from scapy.layers.l2 import Ether
from scapy.layers.inet import IP, UDP

import cocotb_test.simulator
import pytest

import cocotb
from cocotb.log import SimLog
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, Timer

from cocotbext.axi import AxiStreamBus
from cocotbext.axi import AxiSlave, AxiBus, SparseMemoryRegion
from cocotbext.eth import EthMac
from cocotbext.pcie.core import RootComplex
from cocotbext.pcie.xilinx.us import UltraScalePlusPcieDevice

try:
    import mqnic
except ImportError:
    # attempt import from current directory
    sys.path.insert(0, os.path.join(os.path.dirname(__file__)))
    try:
        import mqnic
    finally:
        del sys.path[0]


class TB(object):
    def __init__(self, dut, msix_count=32):
        self.dut = dut

        self.log = SimLog("cocotb.tb")
        self.log.setLevel(logging.DEBUG)

        # PCIe
        self.rc = RootComplex()

        self.rc.max_payload_size = 0x1  # 256 bytes
        self.rc.max_read_request_size = 0x2  # 512 bytes

        self.dev = UltraScalePlusPcieDevice(
            # configuration options
            pcie_generation=3,
            # pcie_link_width=16,
            user_clk_frequency=250e6,
            alignment="dword",
            cq_straddle=len(dut.pcie_if_inst.pcie_us_if_cq_inst.rx_req_tlp_valid_reg) > 1,
            cc_straddle=len(dut.pcie_if_inst.pcie_us_if_cc_inst.out_tlp_valid) > 1,
            rq_straddle=len(dut.pcie_if_inst.pcie_us_if_rq_inst.out_tlp_valid) > 1,
            rc_straddle=len(dut.pcie_if_inst.pcie_us_if_rc_inst.rx_cpl_tlp_valid_reg) > 1,
            rc_4tlp_straddle=len(dut.pcie_if_inst.pcie_us_if_rc_inst.rx_cpl_tlp_valid_reg) > 2,
            pf_count=1,
            max_payload_size=1024,
            enable_client_tag=True,
            enable_extended_tag=True,
            enable_parity=False,
            enable_rx_msg_interface=False,
            enable_sriov=False,
            enable_extended_configuration=False,

            pf0_msi_enable=False,
            pf0_msi_count=32,
            pf1_msi_enable=False,
            pf1_msi_count=1,
            pf2_msi_enable=False,
            pf2_msi_count=1,
            pf3_msi_enable=False,
            pf3_msi_count=1,
            pf0_msix_enable=True,
            pf0_msix_table_size=msix_count-1,
            pf0_msix_table_bir=0,
            pf0_msix_table_offset=0x00010000,
            pf0_msix_pba_bir=0,
            pf0_msix_pba_offset=0x00018000,
            pf1_msix_enable=False,
            pf1_msix_table_size=0,
            pf1_msix_table_bir=0,
            pf1_msix_table_offset=0x00000000,
            pf1_msix_pba_bir=0,
            pf1_msix_pba_offset=0x00000000,
            pf2_msix_enable=False,
            pf2_msix_table_size=0,
            pf2_msix_table_bir=0,
            pf2_msix_table_offset=0x00000000,
            pf2_msix_pba_bir=0,
            pf2_msix_pba_offset=0x00000000,
            pf3_msix_enable=False,
            pf3_msix_table_size=0,
            pf3_msix_table_bir=0,
            pf3_msix_table_offset=0x00000000,
            pf3_msix_pba_bir=0,
            pf3_msix_pba_offset=0x00000000,

            # signals
            # Clock and Reset Interface
            user_clk=dut.clk,
            user_reset=dut.rst,
            # user_lnk_up
            # sys_clk
            # sys_clk_gt
            # sys_reset
            # phy_rdy_out

            # Requester reQuest Interface
            rq_bus=AxiStreamBus.from_prefix(dut, "m_axis_rq"),
            pcie_rq_seq_num0=dut.s_axis_rq_seq_num_0,
            pcie_rq_seq_num_vld0=dut.s_axis_rq_seq_num_valid_0,
            pcie_rq_seq_num1=dut.s_axis_rq_seq_num_1,
            pcie_rq_seq_num_vld1=dut.s_axis_rq_seq_num_valid_1,
            # pcie_rq_tag0
            # pcie_rq_tag1
            # pcie_rq_tag_av
            # pcie_rq_tag_vld0
            # pcie_rq_tag_vld1

            # Requester Completion Interface
            rc_bus=AxiStreamBus.from_prefix(dut, "s_axis_rc"),

            # Completer reQuest Interface
            cq_bus=AxiStreamBus.from_prefix(dut, "s_axis_cq"),
            # pcie_cq_np_req
            # pcie_cq_np_req_count

            # Completer Completion Interface
            cc_bus=AxiStreamBus.from_prefix(dut, "m_axis_cc"),

            # Transmit Flow Control Interface
            # pcie_tfc_nph_av=dut.pcie_tfc_nph_av,
            # pcie_tfc_npd_av=dut.pcie_tfc_npd_av,

            # Configuration Management Interface
            cfg_mgmt_addr=dut.cfg_mgmt_addr,
            cfg_mgmt_function_number=dut.cfg_mgmt_function_number,
            cfg_mgmt_write=dut.cfg_mgmt_write,
            cfg_mgmt_write_data=dut.cfg_mgmt_write_data,
            cfg_mgmt_byte_enable=dut.cfg_mgmt_byte_enable,
            cfg_mgmt_read=dut.cfg_mgmt_read,
            cfg_mgmt_read_data=dut.cfg_mgmt_read_data,
            cfg_mgmt_read_write_done=dut.cfg_mgmt_read_write_done,
            # cfg_mgmt_debug_access

            # Configuration Status Interface
            # cfg_phy_link_down
            # cfg_phy_link_status
            # cfg_negotiated_width
            # cfg_current_speed
            cfg_max_payload=dut.cfg_max_payload,
            cfg_max_read_req=dut.cfg_max_read_req,
            # cfg_function_status
            # cfg_vf_status
            # cfg_function_power_state
            # cfg_vf_power_state
            # cfg_link_power_state
            # cfg_err_cor_out
            # cfg_err_nonfatal_out
            # cfg_err_fatal_out
            # cfg_local_error_out
            # cfg_local_error_valid
            # cfg_rx_pm_state
            # cfg_tx_pm_state
            # cfg_ltssm_state
            cfg_rcb_status=dut.cfg_rcb_status,
            # cfg_obff_enable
            # cfg_pl_status_change
            # cfg_tph_requester_enable
            # cfg_tph_st_mode
            # cfg_vf_tph_requester_enable
            # cfg_vf_tph_st_mode

            # Configuration Received Message Interface
            # cfg_msg_received
            # cfg_msg_received_data
            # cfg_msg_received_type

            # Configuration Transmit Message Interface
            # cfg_msg_transmit
            # cfg_msg_transmit_type
            # cfg_msg_transmit_data
            # cfg_msg_transmit_done

            # Configuration Flow Control Interface
            cfg_fc_ph=dut.cfg_fc_ph,
            cfg_fc_pd=dut.cfg_fc_pd,
            cfg_fc_nph=dut.cfg_fc_nph,
            cfg_fc_npd=dut.cfg_fc_npd,
            cfg_fc_cplh=dut.cfg_fc_cplh,
            cfg_fc_cpld=dut.cfg_fc_cpld,
            cfg_fc_sel=dut.cfg_fc_sel,

            # Configuration Control Interface
            # cfg_hot_reset_in
            # cfg_hot_reset_out
            # cfg_config_space_enable
            # cfg_dsn
            # cfg_bus_number
            # cfg_ds_port_number
            # cfg_ds_bus_number
            # cfg_ds_device_number
            # cfg_ds_function_number
            # cfg_power_state_change_ack
            # cfg_power_state_change_interrupt
            cfg_err_cor_in=dut.status_error_cor,
            cfg_err_uncor_in=dut.status_error_uncor,
            # cfg_flr_in_process
            # cfg_flr_done
            # cfg_vf_flr_in_process
            # cfg_vf_flr_func_num
            # cfg_vf_flr_done
            # cfg_pm_aspm_l1_entry_reject
            # cfg_pm_aspm_tx_l0s_entry_disable
            # cfg_req_pm_transition_l23_ready
            # cfg_link_training_enable

            # Configuration Interrupt Controller Interface
            # cfg_interrupt_int
            # cfg_interrupt_sent
            # cfg_interrupt_pending
            # cfg_interrupt_msi_enable
            # cfg_interrupt_msi_mmenable
            # cfg_interrupt_msi_mask_update
            # cfg_interrupt_msi_data
            # cfg_interrupt_msi_select
            # cfg_interrupt_msi_int
            # cfg_interrupt_msi_pending_status
            # cfg_interrupt_msi_pending_status_data_enable
            # cfg_interrupt_msi_pending_status_function_num
            # cfg_interrupt_msi_sent
            # cfg_interrupt_msi_fail
            cfg_interrupt_msix_enable=dut.cfg_interrupt_msix_enable,
            cfg_interrupt_msix_mask=dut.cfg_interrupt_msix_mask,
            cfg_interrupt_msix_vf_enable=dut.cfg_interrupt_msix_vf_enable,
            cfg_interrupt_msix_vf_mask=dut.cfg_interrupt_msix_vf_mask,
            cfg_interrupt_msix_address=dut.cfg_interrupt_msix_address,
            cfg_interrupt_msix_data=dut.cfg_interrupt_msix_data,
            cfg_interrupt_msix_int=dut.cfg_interrupt_msix_int,
            cfg_interrupt_msix_vec_pending=dut.cfg_interrupt_msix_vec_pending,
            cfg_interrupt_msix_vec_pending_status=dut.cfg_interrupt_msix_vec_pending_status,
            cfg_interrupt_msix_sent=dut.cfg_interrupt_msix_sent,
            cfg_interrupt_msix_fail=dut.cfg_interrupt_msix_fail,
            # cfg_interrupt_msi_attr
            # cfg_interrupt_msi_tph_present
            # cfg_interrupt_msi_tph_type
            # cfg_interrupt_msi_tph_st_tag
            cfg_interrupt_msi_function_number=dut.cfg_interrupt_msi_function_number,

            # Configuration Extend Interface
            # cfg_ext_read_received
            # cfg_ext_write_received
            # cfg_ext_register_number
            # cfg_ext_function_number
            # cfg_ext_write_data
            # cfg_ext_write_byte_enable
            # cfg_ext_read_data
            # cfg_ext_read_data_valid
        )

        # self.dev.log.setLevel(logging.DEBUG)

        self.rc.make_port().connect(self.dev)

        self.driver = mqnic.Driver()

        self.dev.functions[0].configure_bar(0, 2**len(dut.core_pcie_inst.axil_ctrl_araddr), ext=True, prefetch=True)
        if hasattr(dut.core_pcie_inst, 'pcie_app_ctrl'):
            self.dev.functions[0].configure_bar(2, 2**len(dut.core_pcie_inst.axil_app_ctrl_araddr), ext=True, prefetch=True)

        core_inst = dut.core_pcie_inst.core_inst

        # Ethernet
        self.port_mac = []

        eth_int_if_width = len(core_inst.m_axis_tx_tdata) / len(core_inst.m_axis_tx_tvalid)
        eth_clock_period = 6.4
        eth_speed = 10e9

        if eth_int_if_width == 64:
            # 10G
            eth_clock_period = 6.4
            eth_speed = 10e9
        elif eth_int_if_width == 128:
            # 25G
            eth_clock_period = 2.56
            eth_speed = 25e9
        elif eth_int_if_width == 512:
            # 100G
            eth_clock_period = 3.102
            eth_speed = 100e9

        for iface in core_inst.iface:
            for k in range(len(iface.port)):
                cocotb.start_soon(Clock(iface.port[k].port_rx_clk, eth_clock_period, units="ns").start())
                cocotb.start_soon(Clock(iface.port[k].port_tx_clk, eth_clock_period, units="ns").start())

                iface.port[k].port_rx_rst.setimmediatevalue(0)
                iface.port[k].port_tx_rst.setimmediatevalue(0)

                mac = EthMac(
                    tx_clk=iface.port[k].port_tx_clk,
                    tx_rst=iface.port[k].port_tx_rst,
                    tx_bus=AxiStreamBus.from_prefix(iface.interface_inst.port[k].port_inst.port_tx_inst, "m_axis_tx"),
                    tx_ptp_time=iface.port[k].port_tx_ptp_ts_tod if core_inst.PTP_TS_FMT_TOD.value else iface.port[k].port_tx_ptp_ts_rel,
                    tx_ptp_ts=iface.interface_inst.port[k].port_inst.port_tx_inst.s_axis_tx_cpl_ts,
                    tx_ptp_ts_tag=iface.interface_inst.port[k].port_inst.port_tx_inst.s_axis_tx_cpl_tag,
                    tx_ptp_ts_valid=iface.interface_inst.port[k].port_inst.port_tx_inst.s_axis_tx_cpl_valid,
                    rx_clk=iface.port[k].port_rx_clk,
                    rx_rst=iface.port[k].port_rx_rst,
                    rx_bus=AxiStreamBus.from_prefix(iface.interface_inst.port[k].port_inst.port_rx_inst, "s_axis_rx"),
                    rx_ptp_time=iface.port[k].port_rx_ptp_ts_tod if core_inst.PTP_TS_FMT_TOD.value else iface.port[k].port_rx_ptp_ts_rel,
                    ifg=12, speed=eth_speed
                )

                self.port_mac.append(mac)

        dut.eth_tx_status.setimmediatevalue(2**len(core_inst.m_axis_tx_tvalid)-1)
        dut.eth_tx_fc_quanta_clk_en.setimmediatevalue(2**len(core_inst.m_axis_tx_tvalid)-1)
        dut.eth_rx_status.setimmediatevalue(2**len(core_inst.m_axis_tx_tvalid)-1)
        dut.eth_rx_lfc_req.setimmediatevalue(0)
        dut.eth_rx_pfc_req.setimmediatevalue(0)
        dut.eth_rx_fc_quanta_clk_en.setimmediatevalue(2**len(core_inst.m_axis_tx_tvalid)-1)

        # DDR
        self.ddr_group_size = core_inst.DDR_GROUP_SIZE.value
        self.ddr_ram = []
        self.ddr_axi_if = []
        if hasattr(core_inst, 'ddr'):
            ram = None
            for i, ch in enumerate(core_inst.ddr.dram_if_inst.ch):
                cocotb.start_soon(Clock(ch.ch_clk, 3.332, units="ns").start())
                ch.ch_rst.setimmediatevalue(0)
                ch.ch_status.setimmediatevalue(1)

                if i % self.ddr_group_size == 0:
                    ram = SparseMemoryRegion()
                    self.ddr_ram.append(ram)
                self.ddr_axi_if.append(AxiSlave(AxiBus.from_prefix(ch, "axi_ch"), ch.ch_clk, ch.ch_rst, target=ram))

        # HBM
        self.hbm_group_size = core_inst.HBM_GROUP_SIZE.value
        self.hbm_ram = []
        self.hbm_axi_if = []
        if hasattr(core_inst, 'hbm'):
            ram = None
            for i, ch in enumerate(core_inst.hbm.dram_if_inst.ch):
                cocotb.start_soon(Clock(ch.ch_clk, 2.222, units="ns").start())
                ch.ch_rst.setimmediatevalue(0)
                ch.ch_status.setimmediatevalue(1)

                if i % self.hbm_group_size == 0:
                    ram = SparseMemoryRegion()
                    self.hbm_ram.append(ram)
                self.hbm_axi_if.append(AxiSlave(AxiBus.from_prefix(ch, "axi_ch"), ch.ch_clk, ch.ch_rst, target=ram))

        dut.ctrl_reg_wr_wait.setimmediatevalue(0)
        dut.ctrl_reg_wr_ack.setimmediatevalue(0)
        dut.ctrl_reg_rd_data.setimmediatevalue(0)
        dut.ctrl_reg_rd_wait.setimmediatevalue(0)
        dut.ctrl_reg_rd_ack.setimmediatevalue(0)

        cocotb.start_soon(Clock(dut.ptp_clk, 6.4, units="ns").start())
        dut.ptp_rst.setimmediatevalue(0)
        cocotb.start_soon(Clock(dut.ptp_sample_clk, 8, units="ns").start())

        dut.s_axis_stat_tdata.setimmediatevalue(0)
        dut.s_axis_stat_tid.setimmediatevalue(0)
        dut.s_axis_stat_tvalid.setimmediatevalue(0)

        self.loopback_enable = False
        cocotb.start_soon(self._run_loopback())

    async def init(self):

        for mac in self.port_mac:
            mac.rx.reset.setimmediatevalue(0)
            mac.tx.reset.setimmediatevalue(0)

        self.dut.ptp_rst.setimmediatevalue(0)

        for ram in self.ddr_axi_if + self.ddr_axi_if:
            ram.write_if.reset.setimmediatevalue(0)

        await RisingEdge(self.dut.clk)
        await RisingEdge(self.dut.clk)

        for mac in self.port_mac:
            mac.rx.reset.setimmediatevalue(1)
            mac.tx.reset.setimmediatevalue(1)

        self.dut.ptp_rst.setimmediatevalue(1)

        for ram in self.ddr_axi_if + self.ddr_axi_if:
            ram.write_if.reset.setimmediatevalue(1)

        await FallingEdge(self.dut.rst)
        await Timer(100, 'ns')

        await RisingEdge(self.dut.clk)
        await RisingEdge(self.dut.clk)

        for mac in self.port_mac:
            mac.rx.reset.setimmediatevalue(0)
            mac.tx.reset.setimmediatevalue(0)

        self.dut.ptp_rst.setimmediatevalue(0)

        for ram in self.ddr_axi_if + self.ddr_axi_if:
            ram.write_if.reset.setimmediatevalue(0)

        await self.rc.enumerate()

    async def _run_loopback(self):
        while True:
            await RisingEdge(self.dut.clk)

            if self.loopback_enable:
                for mac in self.port_mac:
                    if not mac.tx.empty():
                        await mac.rx.send(await mac.tx.recv())


@cocotb.test()
async def run_test_nic(dut):

    tb = TB(dut, msix_count=2**len(dut.core_pcie_inst.irq_index))

    await tb.init()

    tb.log.info("Init driver")
    await tb.driver.init_pcie_dev(tb.rc.find_device(tb.dev.functions[0].pcie_id))
    for interface in tb.driver.interfaces:
        await interface.ndevs[0].open()

    tb.log.info("Init complete")

    tb.log.info("Send and receive single packet")

    for interface in tb.driver.interfaces:
        data = bytearray([x % 256 for x in range(1024)])

        await interface.ndevs[0].start_xmit(data, 0)

        pkt = await tb.port_mac[interface.index*interface.port_count].tx.recv()
        tb.log.info("Packet: %s", pkt)

        await tb.port_mac[interface.index*interface.port_count].rx.send(pkt)

        pkt = await interface.ndevs[0].recv()

        tb.log.info("Packet: %s", pkt)
        if interface.if_feature_rx_csum:
            assert pkt.rx_checksum == ~scapy.utils.checksum(bytes(pkt.data[14:])) & 0xffff

    tb.log.info("RX and TX checksum tests")

    payload = bytes([x % 256 for x in range(256)])
    eth = Ether(src='5A:51:52:53:54:55', dst='DA:D1:D2:D3:D4:D5')
    ip = IP(src='192.168.1.100', dst='192.168.1.101')
    udp = UDP(sport=1, dport=2)
    test_pkt = eth / ip / udp / payload

    if tb.driver.interfaces[0].if_feature_tx_csum:
        test_pkt2 = test_pkt.copy()
        test_pkt2[UDP].chksum = scapy.utils.checksum(bytes(test_pkt2[UDP]))

        await tb.driver.interfaces[0].ndevs[0].start_xmit(test_pkt2.build(), 0, 34, 6)
    else:
        await tb.driver.interfaces[0].ndevs[0].start_xmit(test_pkt.build(), 0)

    pkt = await tb.port_mac[0].tx.recv()
    tb.log.info("Packet: %s", pkt)

    await tb.port_mac[0].rx.send(pkt)

    pkt = await tb.driver.interfaces[0].ndevs[0].recv()

    tb.log.info("Packet: %s", pkt)
    if tb.driver.interfaces[0].if_feature_rx_csum:
        assert pkt.rx_checksum == ~scapy.utils.checksum(bytes(pkt.data[14:])) & 0xffff
    assert Ether(pkt.data).build() == test_pkt.build()

    tb.log.info("Queue mapping offset test")

    data = bytearray([x % 256 for x in range(1024)])

    tb.loopback_enable = True

    for k in range(4):
        await tb.driver.interfaces[0].set_rx_queue_map_indir_table(0, 0, tb.driver.interfaces[0].ndevs[0].rxq[k].index)

        await tb.driver.interfaces[0].ndevs[0].start_xmit(data, 0)

        pkt = await tb.driver.interfaces[0].ndevs[0].recv()

        tb.log.info("Packet: %s", pkt)
        if tb.driver.interfaces[0].if_feature_rx_csum:
            assert pkt.rx_checksum == ~scapy.utils.checksum(bytes(pkt.data[14:])) & 0xffff
        assert pkt.queue == tb.driver.interfaces[0].ndevs[0].rxq[k].index

    tb.loopback_enable = False

    await tb.driver.interfaces[0].ndevs[0].update_rx_queue_map_indir_table()

    tb.log.info("Queue mapping RSS mask test")

    await tb.driver.interfaces[0].set_rx_queue_map_rss_mask(0, 0x00000003)

    tb.loopback_enable = True

    queues = set()

    for k in range(64):
        payload = bytes([x % 256 for x in range(256)])
        eth = Ether(src='5A:51:52:53:54:55', dst='DA:D1:D2:D3:D4:D5')
        ip = IP(src='192.168.1.100', dst='192.168.1.101')
        udp = UDP(sport=1, dport=k+0)
        test_pkt = eth / ip / udp / payload

        if tb.driver.interfaces[0].if_feature_tx_csum:
            test_pkt2 = test_pkt.copy()
            test_pkt2[UDP].chksum = scapy.utils.checksum(bytes(test_pkt2[UDP]))

            await tb.driver.interfaces[0].ndevs[0].start_xmit(test_pkt2.build(), 0, 34, 6)
        else:
            await tb.driver.interfaces[0].ndevs[0].start_xmit(test_pkt.build(), 0)

    for k in range(64):
        pkt = await tb.driver.interfaces[0].ndevs[0].recv()

        tb.log.info("Packet: %s", pkt)
        if tb.driver.interfaces[0].if_feature_rx_csum:
            assert pkt.rx_checksum == ~scapy.utils.checksum(bytes(pkt.data[14:])) & 0xffff

        queues.add(pkt.queue)

    assert len(queues) == 4

    tb.loopback_enable = False

    await tb.driver.interfaces[0].set_rx_queue_map_rss_mask(0, 0xffffffff)

    tb.log.info("Multiple small packets")

    count = 64

    pkts = [bytearray([(x+k) % 256 for x in range(60)]) for k in range(count)]

    tb.loopback_enable = True

    for p in pkts:
        await tb.driver.interfaces[0].ndevs[0].start_xmit(p, 0)

    for k in range(count):
        pkt = await tb.driver.interfaces[0].ndevs[0].recv()

        tb.log.info("Packet: %s", pkt)
        assert pkt.data == pkts[k]
        if tb.driver.interfaces[0].if_feature_rx_csum:
            assert pkt.rx_checksum == ~scapy.utils.checksum(bytes(pkt.data[14:])) & 0xffff

    tb.loopback_enable = False

    tb.log.info("Multiple TX queues")

    count = 1024

    pkts = [bytearray([(x+k) % 256 for x in range(60)]) for k in range(count)]

    tb.loopback_enable = True

    for k in range(len(pkts)):
        await tb.driver.interfaces[0].ndevs[0].start_xmit(pkts[k], k % tb.driver.interfaces[0].ndevs[0].txq_count)

    for k in range(count):
        pkt = await tb.driver.interfaces[0].ndevs[0].recv()

        tb.log.info("Packet: %s", pkt)
        if tb.driver.interfaces[0].if_feature_rx_csum:
            assert pkt.rx_checksum == ~scapy.utils.checksum(bytes(pkt.data[14:])) & 0xffff

    tb.loopback_enable = False

    tb.log.info("Multiple large packets")

    count = 64

    pkts = [bytearray([(x+k) % 256 for x in range(1514)]) for k in range(count)]

    tb.loopback_enable = True

    for p in pkts:
        await tb.driver.interfaces[0].ndevs[0].start_xmit(p, 0)

    for k in range(count):
        pkt = await tb.driver.interfaces[0].ndevs[0].recv()

        tb.log.info("Packet: %s", pkt)
        assert pkt.data == pkts[k]
        if tb.driver.interfaces[0].if_feature_rx_csum:
            assert pkt.rx_checksum == ~scapy.utils.checksum(bytes(pkt.data[14:])) & 0xffff

    tb.loopback_enable = False

    tb.log.info("Jumbo frames")

    count = 64

    pkts = [bytearray([(x+k) % 256 for x in range(9014)]) for k in range(count)]

    tb.loopback_enable = True

    for p in pkts:
        await tb.driver.interfaces[0].ndevs[0].start_xmit(p, 0)

    for k in range(count):
        pkt = await tb.driver.interfaces[0].ndevs[0].recv()

        tb.log.info("Packet: %s", pkt)
        assert pkt.data == pkts[k]
        if tb.driver.interfaces[0].if_feature_rx_csum:
            assert pkt.rx_checksum == ~scapy.utils.checksum(bytes(pkt.data[14:])) & 0xffff

    tb.loopback_enable = False

    if len(tb.driver.interfaces) > 1:
        tb.log.info("All interfaces")

        count = 64

        pkts = [bytearray([(x+k) % 256 for x in range(1514)]) for k in range(count)]

        tb.loopback_enable = True

        for k, p in enumerate(pkts):
            await tb.driver.interfaces[k % len(tb.driver.interfaces)].ndevs[0].start_xmit(p, 0)

        for k in range(count):
            pkt = await tb.driver.interfaces[k % len(tb.driver.interfaces)].ndevs[0].recv()

            tb.log.info("Packet: %s", pkt)
            assert pkt.data == pkts[k]
            if tb.driver.interfaces[0].if_feature_rx_csum:
                assert pkt.rx_checksum == ~scapy.utils.checksum(bytes(pkt.data[14:])) & 0xffff

        tb.loopback_enable = False

    if len(tb.driver.interfaces[0].ndevs) > 1:
        tb.log.info("All interface 0 netdevs")

        for ndev in tb.driver.interfaces[0].ndevs:
            if not ndev.port_up:
                await ndev.open()

        count = 64

        pkts = [bytearray([(x+k) % 256 for x in range(1514)]) for k in range(count)]

        tb.loopback_enable = True

        queues = set()

        for k, p in enumerate(pkts):
            await tb.driver.interfaces[0].ndevs[k % len(tb.driver.interfaces[0].ndevs)].start_xmit(p, 0)

        for k in range(count):
            pkt = await tb.driver.interfaces[0].ndevs[k % len(tb.driver.interfaces[0].ndevs)].recv()

            tb.log.info("Packet: %s", pkt)
            assert pkt.data == pkts[k]
            if tb.driver.interfaces[0].if_feature_rx_csum:
                assert pkt.rx_checksum == ~scapy.utils.checksum(bytes(pkt.data[14:])) & 0xffff

        tb.loopback_enable = False

    if tb.driver.interfaces[0].if_feature_lfc:
        tb.log.info("Test LFC pause frame RX")

        await tb.driver.interfaces[0].ports[0].set_lfc_ctrl(mqnic.MQNIC_PORT_LFC_CTRL_TX_LFC_EN | mqnic.MQNIC_PORT_LFC_CTRL_RX_LFC_EN)
        await tb.driver.hw_regs.read_dword(0)

        lfc_xoff = Ether(src='DA:D1:D2:D3:D4:D5', dst='01:80:C2:00:00:01', type=0x8808) / struct.pack('!HH', 0x0001, 2000)

        await tb.port_mac[0].rx.send(bytes(lfc_xoff))

        count = 16

        pkts = [bytearray([(x+k) % 256 for x in range(1514)]) for k in range(count)]

        tb.loopback_enable = True

        for p in pkts:
            await tb.driver.interfaces[0].ndevs[0].start_xmit(p, 0)

        for k in range(count):
            pkt = await tb.driver.interfaces[0].ndevs[0].recv()

            tb.log.info("Packet: %s", pkt)
            assert pkt.data == pkts[k]
            if tb.driver.interfaces[0].if_feature_rx_csum:
                assert pkt.rx_checksum == ~scapy.utils.checksum(bytes(pkt.data[14:])) & 0xffff

        tb.loopback_enable = False

    tb.log.info("TEST SSR Application")
    app_reg_blocks = mqnic.RegBlockList()
    await app_reg_blocks.enumerate_reg_blocks(tb.driver.app_hw_regs)

    #dma_bench_rb = app_reg_blocks.find(0x12348101, 0x00000100)

    #mem = tb.rc.mem_pool.alloc_region(16*1024*1024)
    #mem_base = mem.get_absolute_address(0)

@cocotb.test()
async def run_test_ssr_dataplane(dut):

    tb = TB(dut, msix_count=2**len(dut.core_pcie_inst.irq_index))

    await tb.init()

    tb.log.info("Init driver")
    await tb.driver.init_pcie_dev(tb.rc.find_device(tb.dev.functions[0].pcie_id))
    for interface in tb.driver.interfaces:
        await interface.ndevs[0].open()

    tb.log.info("Init complete")

    tb.log.info("TEST SSR Application")
    SSR_RB_TYPE     = 0x53535201
    SSR_RB_VERSION  = 0x00000100
    SSR_RB_FEATURES = 0x0000000f

    app_reg_blocks = mqnic.RegBlockList()
    await app_reg_blocks.enumerate_reg_blocks(tb.driver.app_hw_regs)

    tb.log.info("Found %d application register blocks", len(app_reg_blocks))
    ssr_rb = app_reg_blocks.find(SSR_RB_TYPE, SSR_RB_VERSION)
    assert ssr_rb is not None, "SSR register block not found"

    # ----------------------------------------------------------------------
    #           Basic register read/write tests
    # ----------------------------------------------------------------------   
    # check SSR register block
    tb.log.info("Check SSR register block")
    assert await ssr_rb.read_dword(0x00) == SSR_RB_TYPE, "Invalid SSR register block type"
    assert await ssr_rb.read_dword(0x04) == SSR_RB_VERSION, "Invalid SSR register block version"
    assert await ssr_rb.read_dword(0x0c) == SSR_RB_FEATURES, "Invalid SSR register block features"

    # test scratch register
    tb.log.info("Test SSR scratch register")
    await ssr_rb.write_dword(0x1c, 0x12345678)
    assert await ssr_rb.read_dword(0x1c) == 0x12345678, "SSR scratch register read/write failed"

    # test replica configuration register
    tb.log.info("Test SSR replica configuration register")
    await ssr_rb.write_dword(0x020, 0x00000001)     # replica_id
    await ssr_rb.write_dword(0x024, 0x00000003)     # replica_num
    await ssr_rb.write_dword(0x028, 0x00000800)     # round_length_ns
    await ssr_rb.write_dword(0x02c, 0x00000177)     # ethernet_type

    status = await ssr_rb.read_dword(0x014)
    assert status & 0x1 == 1, "SSR application should be inactive"

    assert await ssr_rb.read_dword(0x020) == 1, "SSR replica_id register read/write failed"
    assert await ssr_rb.read_dword(0x024) == 3, "SSR replica_num register read/write failed"
    assert await ssr_rb.read_dword(0x028) == 0x800, "SSR round_length_ns register read/write failed"
    assert await ssr_rb.read_dword(0x02c) == 0x177, "SSR ethernet_type register read/write failed"

    # test MAC address registers
    tb.log.info("Test SSR MAC address registers")
    mac_addrs = [
        [0x00, 0x11, 0x22, 0x33, 0x44, 0x55],
        [0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb],
        [0xcc, 0xdd, 0xee, 0xff, 0x00, 0x11],
    ]
    for i, mac in enumerate(mac_addrs):
        mac_int = (mac[0] << 40) | (mac[1] << 32) | (mac[2] << 24) | (mac[3] << 16) | (mac[4] << 8) | mac[5]
        await ssr_rb.write_dword(0x100 + i*8, mac_int & 0xffffffff)
        await ssr_rb.write_dword(0x100 + i*8 + 4, (mac_int >> 32) & 0xffff)

    for i, mac in enumerate(mac_addrs):
        mac_int = (mac[0] << 40) | (mac[1] << 32) | (mac[2] << 24) | (mac[3] << 16) | (mac[4] << 8) | mac[5]
        mac_int_rd = (await ssr_rb.read_dword(0x100 + i*8)) | ((await ssr_rb.read_dword(0x100 + i*8 + 4)) << 32)
        assert mac_int_rd == mac_int, "SSR MAC address register read/write failed"

    # ----------------------------------------------------------------------
    #           SSR application DMA read test
    # ----------------------------------------------------------------------
    # allocate DMA buffer and fill with test data
    tb.log.info("SSR application DMA read test")
    mem = tb.rc.mem_pool.alloc_region(16*1024*1024)
    mem_base = mem.get_absolute_address(0)

    tb.log.info("Fill DMA buffer with test data")
    mem[0:1024] = bytearray([x % 256 for x in range(1024)])

    # write pcie read descriptor
    tb.log.info("Write SSR DMA read descriptor")
    await ssr_rb.write_dword(0x1000, (mem_base+0x0000) & 0xffffffff)                # address low
    await ssr_rb.write_dword(0x1004, (mem_base+0x0000 >> 32) & 0xffffffff)          # address high
    await ssr_rb.write_dword(0x1008, 1024)                                      # length
    await ssr_rb.write_dword(0x100c, 0x00000001)                                  # control (set start bit)

    tb.log.info("Start SSR DMA read")
    await Timer(2000, 'ns')

    # read status and check for completion
    tb.log.info("Read SSR DMA read status")
    status = await ssr_rb.read_dword(0x1010)

    tb.log.info("SSR DMA read status: 0x%08x", status)

