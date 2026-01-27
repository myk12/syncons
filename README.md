# FPGA-Accelerated Consensus for Synchronous Data Center Networks

**Research Project | MPI-INF**

This repository contains the Verilog RTL implementation and verification environment for a high-performance, hardware-accelerated consensus protocol designed specifically for **synchronous** data center networks.

The project targets **FPGA SmartNICs (e.g., Corundum on Xilinx Alveo)** to offload distributed consensus logic, enabling deterministic, low-latency coordination in hybrid optical/electrical networks.

## 🏗 System Architecture

The system is designed as a standalone engine that integrates into an FPGA NIC (e.g., Corundum) via AXI-Stream interfaces.

**Code snippet**

```
graph TD
    PTP[PTP Hardware Clock] --> Scheduler
    Scheduler[Consensus Scheduler] -- Control Pulses --> Core
    Scheduler -- Gating Signals --> TX
    Scheduler -- Gating Signals --> RX
  
    subgraph "Consensus Engine"
        Core[Consensus Core FSM] -- State/Proposal --> TX[TX Engine]
        RX[RX Engine] -- Parsed Data --> Core
    end
  
    TX -- AXI Stream (512b) --> MAC[Ethernet MAC]
    MAC -- AXI Stream (512b) --> RX
```

### Key Design Decisions

1. **Global Synchronization:** The system relies on PTP (IEEE 1588) to align `Slot IDs` across the cluster.
2. **Single-Cycle Packets:** Custom protocol headers are packed into a single 512-bit flit to maximize throughput and minimize logic depth.
3. **Guard Band Protection:** The scheduler strictly enforces "Silence" during optical switching guard bands to prevent data loss or bit errors.

## 📂 Module Descriptions

The source code is located in the `rtl/` directory.

| **Module**         | **File**            | **Description**                                                                                                                                                                                                                                    |
| ------------------------ | ------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Consensus Core** | `consensus_core.v`      | **The Brain.**Implements the main Finite State Machine (`IDLE`,`COLLECT`,`FAIL_DETECT`,`COMMIT`). It maintains the Knowledge Matrix, detects node failures based on missing heartbeats, and determines when data is safe to commit.              |
| **Scheduler**      | `consensus_scheduler.v` | **The Heartbeat.**Takes a global PTP time input and generates precise control pulses (`new_slot`,`commit_start`) and gating signals (`tx_allowed`,`rx_enabled`). It manages the Time Slot lifecycle, including Guard Bands and Commit Windows.   |
| **TX Engine**      | `consensus_tx.v`        | **Packet Generator.**Assembles the custom Ethernet frame. It handles the mapping of internal state to network byte order (Big Endian for headers, Little Endian for payloads) and ensures wire-speed transmission over the 512-bit AXI-Stream interface. |
| **RX Engine**      | `consensus_rx.v`        | **Packet Parser.**Filters incoming traffic based on EtherType (`0x88B5`) and validates the `Slot ID`to prevent replay attacks or stale data processing. It extracts the sender's Knowledge Vector and Proposal for the Core.                         |
| **Consensus Node** | `consensus_node.v`      | **Top Level Wrapper.**Interconnects the Core, Scheduler, TX, and RX modules. It exposes the standard AXI-Stream interfaces for easy integration into the Corundum NIC wrapper.                                                                           |

## 🧪 Simulation & Verification

The project includes a comprehensive simulation environment located in `tb/` and `sim/`.

* **Simulator:** Icarus Verilog (`iverilog`)
* **Waveform Viewer:** GTKWave

### Key Testbenches

* **`tb_3node_cluster.v`** : The primary system integration test. It instantiates **3 full Consensus Nodes** and a virtual broadcast switch (`atomic_broadcast_switch.v`).
* Simulates a full distributed cluster.
* Verifies  **Safety** : All nodes reach the same commit decision.
* Verifies  **Liveness** : System recovers from node crashes (simulated by disabling TX on specific nodes).
* **`tb_consensus_core.v`** : Unit test for the state machine logic.

### How to Run

Use the provided `Makefile` to compile and run simulations.

**Bash**

```
# Clean previous builds
make clean

# Compile and run the 3-node system simulation
make sim
# Output: build/sim.out

# View the waveform
gtkwave build/dump.vcd
```

## 📂 Repository Structure

**Plaintext**

```
.
├── Makefile                 # Build script for iverilog simulation
├── README.md                # Project documentation
├── build/                   # Compilation artifacts and simulation logs
├── doc/                     # Design documents and diagrams
├── rtl/                     # Synthesizable Verilog Source Code
│   ├── consensus_core.v     # Main FSM and Logic
│   ├── consensus_scheduler.v# PTP-based Timing Control
│   ├── consensus_tx.v       # AXI-Stream Transmitter
│   ├── consensus_rx.v       # AXI-Stream Receiver
│   └── consensus_node.v     # Top-Level Wrapper
├── tb/                      # Testbenches
│   ├── atomic_broadcast_switch.v # Virtual switch for simulation
│   ├── tb_3node_cluster.v   # Full system integration test
│   └── tb_consensus_core.v  # Unit test for core logic
└── consensus_core.gtkw      # GTKWave save file for easy debugging
```

## 🔜 Future Work

* Integration with Corundum NIC Reference Design.
* Implementation of "Blind/Mute" detection recovery strategies.
* Hardware-in-the-loop testing on Xilinx Alveo boards.
