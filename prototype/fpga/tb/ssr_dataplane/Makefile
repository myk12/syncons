# ==============================================================================
# FPGA Raft Consensus - Project Makefile
# ==============================================================================

# 1. Definition of directories
CORUNDUM_DIR = ../../../corundum
RTL_DIR   = ../../rtl
TB_DIR    = ./
BUILD_DIR = build
SIM_DIR   = sim

# 2. Top-level test module name (corresponding to the module name in tb/tb_3node_cluster.v)
TOP_MODULE = tb_3node_cluster
TOP_MODULE_CORE = tb_consensus_core
TOP_MODULE_DMA_READER = tb_proposal_dma_reader
TOP_MODULE_PROPOSAL_BUFFER = tb_proposal_buffer
TOP_MODULE_PROPOSAL_PATH = tb_proposal_path

# 3. Source file definitions
# Note: This strictly corresponds to the tree structure you provided
RTL_SRCS = $(RTL_DIR)/consensus_scheduler.v \
           $(RTL_DIR)/consensus_tx.v \
           $(RTL_DIR)/consensus_rx.v \
           $(RTL_DIR)/consensus_core.v \
           $(RTL_DIR)/consensus_node.v

CORE_RTL_SRC = $(RTL_DIR)/consensus_core.v

PROP_DMA_READER_SRC = $(RTL_DIR)/proposal_dma_reader.v

PROP_BUFFER_SRC = $(RTL_DIR)/proposal_buffer.v \
				  $(CORUNDUM_DIR)/fpga/lib/pcie/rtl/dma_psdpram.v

PROP_PATH_SRC = $(RTL_DIR)/proposal_dma_reader.v \
				$(RTL_DIR)/proposal_buffer.v \
				$(CORUNDUM_DIR)/fpga/lib/pcie/rtl/dma_psdpram.v

# Testbench source files (including Switch model and Cluster TB)
TB_SRCS  = $(TB_DIR)/atomic_broadcast_switch.v \
           $(TB_DIR)/$(TOP_MODULE).v

CORE_TB_SRCS  = $(TB_DIR)/$(TOP_MODULE_CORE).v

PROP_DMA_READER_TB_SRCS = $(TB_DIR)/$(TOP_MODULE_DMA_READER).v

PROP_BUFFER_TB_SRCS = $(TB_DIR)/$(TOP_MODULE_PROPOSAL_BUFFER).v

PROP_PATH_TB_SRCS = $(TB_DIR)/$(TOP_MODULE_PROPOSAL_PATH).v

# core.v SECTION 1 (CSR) + SECTION 2 (timing)
TOP_MODULE_CORE_TIMING = tb_core_timing
CORE_TIMING_SRC        = $(RTL_DIR)/core.v
CORE_TIMING_TB_SRCS    = $(TB_DIR)/$(TOP_MODULE_CORE_TIMING).v

# tx_engine, driven by the real consensus_core
TOP_MODULE_TX_ENGINE = tb_tx_engine
TX_ENGINE_SRC        = $(RTL_DIR)/core.v $(RTL_DIR)/tx_engine.v
TX_ENGINE_TB_SRCS    = $(TB_DIR)/$(TOP_MODULE_TX_ENGINE).v

# rx_engine, in a full three-node loop with tx_engine and consensus_core
TOP_MODULE_RX_ENGINE = tb_rx_engine
RX_ENGINE_SRC        = $(RTL_DIR)/core.v $(RTL_DIR)/tx_engine.v $(RTL_DIR)/rx_engine.v
RX_ENGINE_TB_SRCS    = $(TB_DIR)/$(TOP_MODULE_RX_ENGINE).v

# The wrapper itself: ssr_dataplane with the real core, tx_engine and the new
# transmit mux, plus every module it instantiates. This is the only bench that
# exercises ssr_dataplane.v's own wiring - the CSR block decode, the tag that
# tells an SSR completion from a host one, and the merge onto the port.
#
# consensus_core lives in core.v, NOT consensus_core.v. Both declare a module of
# that name; only one may be in this list.
TOP_MODULE_SSR_DATAPLANE = tb_ssr_dataplane
SSR_DATAPLANE_SRC        = $(RTL_DIR)/ssr_dataplane.v \
                           $(RTL_DIR)/core.v \
                           $(RTL_DIR)/tx_engine.v \
                           $(RTL_DIR)/ssr_tx_mux.v \
                           $(RTL_DIR)/proposal_dma_reader.v \
                           $(RTL_DIR)/proposal_buffer.v \
                           $(RTL_DIR)/commit_buffer.v \
                           $(RTL_DIR)/commit_dma_writer.v \
                           $(RTL_DIR)/consensus_rx.v \
                           $(RTL_DIR)/consensus_rx_splitter.v \
                           $(CORUNDUM_DIR)/fpga/lib/pcie/rtl/dma_psdpram.v
SSR_DATAPLANE_TB_SRCS    = $(TB_DIR)/$(TOP_MODULE_SSR_DATAPLANE).v

# core.v SECTION 3 (consensus pipeline + FSM)
TOP_MODULE_CORE_PROTOCOL = tb_core_protocol
CORE_PROTOCOL_SRC        = $(RTL_DIR)/core.v
CORE_PROTOCOL_TB_SRCS    = $(TB_DIR)/$(TOP_MODULE_CORE_PROTOCOL).v

# 4. Compiler configuration (Icarus Verilog)
# -g2012: Enable SystemVerilog support
# -Wall:  Show all warnings
# -I:     Specify header file search path
IV_FLAGS = -g2012 -Wall -I $(RTL_DIR)

# ==============================================================================
# 5. Build Targets
# ==============================================================================

.PHONY: all clean run view check tb_core tb_prop_dma_reader tb_prop_buffer tb_prop_path tb_core_timing tb_core_protocol tb_tx_engine tb_rx_engine tb_ssr_dataplane

# Default target: compile and run
all: run

# Run simulation
run: $(BUILD_DIR)/sim.out
	@echo "------------------------------------------------"
	@echo "🚀 Running Simulation..."
	@echo "------------------------------------------------"
	vvp $(BUILD_DIR)/sim.out

# Compilation step for Consensus Core only
tb_core: $(BUILD_DIR) $(CORE_RTL_SRC) $(CORE_TB_SRCS)
	@echo "------------------------------------------------"
	@echo "🚀 Running Consensus Core Simulation..."
	@echo "------------------------------------------------"
	iverilog $(IV_FLAGS) -o $(BUILD_DIR)/sim_core.out $(CORE_RTL_SRC) $(CORE_TB_SRCS)
	vvp $(BUILD_DIR)/sim_core.out

# Compilation step for Proposal DMA Reader only
tb_prop_dma_reader: $(BUILD_DIR) $(PROP_DMA_READER_SRC) $(PROP_DMA_READER_TB_SRCS)
	@echo "------------------------------------------------"
	@echo "🚀 Running Proposal DMA Reader Simulation..."
	@echo "------------------------------------------------"
	iverilog $(IV_FLAGS) -o $(BUILD_DIR)/sim_prop_dma_reader.out $(PROP_DMA_READER_SRC) $(PROP_DMA_READER_TB_SRCS)
	vvp $(BUILD_DIR)/sim_prop_dma_reader.out

# Compilation step for Proposal Buffer only
tb_prop_buffer: $(BUILD_DIR) $(PROP_BUFFER_SRC) $(PROP_BUFFER_TB_SRCS)
	@echo "------------------------------------------------"
	@echo "🚀 Running Proposal Buffer Simulation..."
	@echo "------------------------------------------------"
	iverilog $(IV_FLAGS) -o $(BUILD_DIR)/sim_prop_buffer.out $(PROP_BUFFER_SRC) $(PROP_BUFFER_TB_SRCS)
	vvp $(BUILD_DIR)/sim_prop_buffer.out

# Compilation step for core.v timing + CSR
tb_core_timing: $(BUILD_DIR) $(CORE_TIMING_SRC) $(CORE_TIMING_TB_SRCS)
	@echo "------------------------------------------------"
	@echo "🚀 Running core.v timing/CSR Simulation..."
	@echo "------------------------------------------------"
	iverilog $(IV_FLAGS) -o $(BUILD_DIR)/sim_core_timing.out $(CORE_TIMING_SRC) $(CORE_TIMING_TB_SRCS)
	vvp $(BUILD_DIR)/sim_core_timing.out

# Compilation step for tx_engine
tb_tx_engine: $(BUILD_DIR) $(TX_ENGINE_SRC) $(TX_ENGINE_TB_SRCS)
	@echo "------------------------------------------------"
	@echo "🚀 Running tx_engine Simulation..."
	@echo "------------------------------------------------"
	iverilog $(IV_FLAGS) -o $(BUILD_DIR)/sim_tx_engine.out $(TX_ENGINE_SRC) $(TX_ENGINE_TB_SRCS)
	vvp $(BUILD_DIR)/sim_tx_engine.out

# Compilation step for rx_engine
tb_rx_engine: $(BUILD_DIR) $(RX_ENGINE_SRC) $(RX_ENGINE_TB_SRCS)
	@echo "------------------------------------------------"
	@echo "🚀 Running rx_engine Simulation..."
	@echo "------------------------------------------------"
	iverilog $(IV_FLAGS) -o $(BUILD_DIR)/sim_rx_engine.out $(RX_ENGINE_SRC) $(RX_ENGINE_TB_SRCS)
	vvp $(BUILD_DIR)/sim_rx_engine.out

# Compilation step for core.v consensus pipeline.
# Run at both 3 and 5 nodes: several protocol properties are vacuous at 3. A
# 3-member quorum is 2 and cannot shrink below 2, so a 3-node cluster cannot
# express a sound set ratcheting past its own tolerance bound.
CORE_PROTOCOL_NODE_COUNTS = 3 5

tb_core_protocol: $(BUILD_DIR) $(CORE_PROTOCOL_SRC) $(CORE_PROTOCOL_TB_SRCS)
	@for n in $(CORE_PROTOCOL_NODE_COUNTS); do \
		echo "------------------------------------------------"; \
		echo "🚀 core.v protocol Simulation, NODE_COUNT=$$n"; \
		echo "------------------------------------------------"; \
		iverilog $(IV_FLAGS) -DSSR_TB_NODE_COUNT=$$n \
			-o $(BUILD_DIR)/sim_core_protocol_$$n.out \
			$(CORE_PROTOCOL_SRC) $(CORE_PROTOCOL_TB_SRCS) || exit 1; \
		vvp $(BUILD_DIR)/sim_core_protocol_$$n.out || exit 1; \
	done

# Compilation step for the whole ssr_dataplane wrapper
tb_ssr_dataplane: $(BUILD_DIR) $(SSR_DATAPLANE_SRC) $(SSR_DATAPLANE_TB_SRCS)
	@echo "------------------------------------------------"
	@echo "🚀 Running ssr_dataplane Integration Simulation..."
	@echo "------------------------------------------------"
	iverilog $(IV_FLAGS) -o $(BUILD_DIR)/sim_ssr_dataplane.out $(SSR_DATAPLANE_TB_SRCS) $(SSR_DATAPLANE_SRC)
	vvp $(BUILD_DIR)/sim_ssr_dataplane.out

# Compilation step for Proposal Path only
tb_prop_path: $(BUILD_DIR) $(PROP_PATH_TB_SRCS) $(PROP_PATH_SRC)
	@echo "------------------------------------------------"
	@echo "🚀 Running Proposal Path Simulation..."
	@echo "------------------------------------------------"
	iverilog $(IV_FLAGS) -o $(BUILD_DIR)/sim_prop_path.out $(PROP_PATH_TB_SRCS) $(PROP_PATH_SRC)
	vvp $(BUILD_DIR)/sim_prop_path.out

$(BUILD_DIR)/sim.out: $(BUILD_DIR) $(RTL_SRCS) $(TB_SRCS)
	@echo "------------------------------------------------"
	@echo "🛠️  Compiling RTL and Testbench..."
	@echo "------------------------------------------------"
	iverilog $(IV_FLAGS) -o $(BUILD_DIR)/sim.out $(RTL_SRCS) $(TB_SRCS)

# Create build directory
$(BUILD_DIR):
	@mkdir -p $(BUILD_DIR)

# Clean build artifacts
clean:
	@echo "🧹 Cleaning up..."
	rm -rf $(BUILD_DIR)
	@echo "Done."

# Check if files exist (for debugging purposes)
check:
	@echo "Checking source files..."
	@ls -l $(RTL_SRCS) $(TB_SRCS) $(CORE_RTL_SRC) $(CORE_TB_SRCS) $(PROP_DMA_READER_SRC) $(PROP_DMA_READER_TB_SRCS) $(PROP_BUFFER_SRC) $(PROP_BUFFER_TB_SRCS) $(PROP_PATH_TB_SRCS) $(PROP_PATH_SRC)
	@echo "All source files are present."
