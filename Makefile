# ==============================================================================
# FPGA Raft Consensus - Project Makefile
# ==============================================================================

# 1. Definition of directories
RTL_DIR   = rtl
TB_DIR    = tb
BUILD_DIR = build
SIM_DIR   = sim

# 2. Top-level test module name (corresponding to the module name in tb/tb_3node_cluster.v)
TOP_MODULE = tb_3node_cluster
TOP_MODULE_CORE = tb_consensus_core

# 3. Source file definitions
# Note: This strictly corresponds to the tree structure you provided
RTL_SRCS = $(RTL_DIR)/consensus_scheduler.v \
           $(RTL_DIR)/consensus_tx.v \
           $(RTL_DIR)/consensus_rx.v \
           $(RTL_DIR)/consensus_core.v \
           $(RTL_DIR)/consensus_nic.v

CORE_RTL_SRC = $(RTL_DIR)/consensus_core.v

# Testbench source files (including Switch model and Cluster TB)
TB_SRCS  = $(TB_DIR)/atomic_broadcast_switch.v \
           $(TB_DIR)/$(TOP_MODULE).v

CORE_TB_SRCS  = $(TB_DIR)/$(TOP_MODULE_CORE).v

# 4. Compiler configuration (Icarus Verilog)
# -g2012: Enable SystemVerilog support
# -Wall:  Show all warnings
# -I:     Specify header file search path
IV_FLAGS = -g2012 -Wall -I $(RTL_DIR)

# ==============================================================================
# 5. Build Targets
# ==============================================================================

.PHONY: all clean run view check tb_core

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

# Compilation step
$(BUILD_DIR)/sim.out: $(BUILD_DIR) $(RTL_SRCS) $(TB_SRCS)
	@echo "------------------------------------------------"
	@echo "🛠️  Compiling RTL and Testbench..."
	@echo "------------------------------------------------"
	iverilog $(IV_FLAGS) -o $(BUILD_DIR)/sim.out $(RTL_SRCS) $(TB_SRCS)

# Create build directory
$(BUILD_DIR):
	@mkdir -p $(BUILD_DIR)

# View waveform (requires GTKWave)
# Note: Ensure $dumpfile in TB outputs to build/ directory
view:
	@echo "------------------------------------------------"
	@echo "📈 Opening Waveform..."
	@echo "------------------------------------------------"
	@if [ -f $(BUILD_DIR)/$(TOP_MODULE).vcd ]; then \
		gtkwave $(BUILD_DIR)/$(TOP_MODULE).vcd; \
	else \
		echo "Error: Waveform file not found at $(BUILD_DIR)/$(TOP_MODULE).vcd"; \
	fi

# Clean build artifacts
clean:
	@echo "🧹 Cleaning up..."
	rm -rf $(BUILD_DIR)
	@echo "Done."

# Check if files exist (for debugging purposes)
check:
	@echo "Checking source files..."
	@ls -l $(RTL_SRCS) $(TB_SRCS)
	@echo "All source files are present."
	@echo "------------------------------------------------"
