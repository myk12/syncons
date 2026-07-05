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

# 4. Compiler configuration (Icarus Verilog)
# -g2012: Enable SystemVerilog support
# -Wall:  Show all warnings
# -I:     Specify header file search path
IV_FLAGS = -g2012 -Wall -I $(RTL_DIR)

# ==============================================================================
# 5. Build Targets
# ==============================================================================

.PHONY: all clean run view check tb_core tb_prop_dma_reader tb_prop_buffer tb_prop_path

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
