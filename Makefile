# FPGA HFT Trading System - Makefile
# Supports: Icarus Verilog, Verilator, Vivado

# ---- Configuration ----
IVERILOG    = iverilog
VVP         = vvp
VERILATOR   = verilator
GTKWAVE     = gtkwave

RTL_DIR     = rtl
TB_DIR      = tb

# ---- Source Files (dependency order) ----
PKG         = $(RTL_DIR)/fixed_point_pkg.sv

CORE_RTL    = $(PKG) \
              $(RTL_DIR)/ema_calculator.sv \
              $(RTL_DIR)/market_data_parser.sv \
              $(RTL_DIR)/order_book.sv \
              $(RTL_DIR)/market_maker.sv \
              $(RTL_DIR)/risk_manager.sv \
              $(RTL_DIR)/order_generator.sv \
              $(RTL_DIR)/trading_system_top.sv

SMARTNIC_RTL = $(PKG) \
               $(RTL_DIR)/ema_calculator.sv \
               $(RTL_DIR)/speculative_parser.sv \
               $(RTL_DIR)/order_book.sv \
               $(RTL_DIR)/feature_extractor.sv \
               $(RTL_DIR)/neural_inference.sv \
               $(RTL_DIR)/deterministic_wrapper.sv \
               $(RTL_DIR)/avellaneda_stoikov.sv \
               $(RTL_DIR)/market_maker.sv \
               $(RTL_DIR)/risk_manager.sv \
               $(RTL_DIR)/order_generator.sv \
               $(RTL_DIR)/session_override.sv \
               $(RTL_DIR)/smartnic_top.sv

ALL_RTL     = $(PKG) $(wildcard $(RTL_DIR)/*.sv)

# ---- Default target ----
.PHONY: all clean lint sim-basic sim-smartnic sim-all wave-basic wave-smartnic help

all: sim-all

help:
	@echo "Available targets:"
	@echo "  lint           - Run Verilator lint on all RTL"
	@echo "  sim-basic      - Simulate basic pipeline testbench"
	@echo "  sim-smartnic   - Simulate full SmartNIC testbench"
	@echo "  sim-all        - Run all simulations"
	@echo "  wave-basic     - Open basic testbench waveforms in GTKWave"
	@echo "  wave-smartnic  - Open SmartNIC waveforms in GTKWave"
	@echo "  clean          - Remove simulation artifacts"

# ---- Lint ----
lint:
	$(VERILATOR) --lint-only -Wall --timing $(ALL_RTL)
	@echo "Lint passed."

# ---- Basic Pipeline Simulation ----
sim_basic.vvp: $(CORE_RTL) $(TB_DIR)/tb_trading_system.sv
	$(IVERILOG) -g2012 -o $@ $(CORE_RTL) $(TB_DIR)/tb_trading_system.sv

sim-basic: sim_basic.vvp
	$(VVP) $<
	@echo "Basic simulation complete."

wave-basic: sim-basic
	$(GTKWAVE) trading_system_tb.vcd &

# ---- SmartNIC Simulation ----
sim_smartnic.vvp: $(SMARTNIC_RTL) $(TB_DIR)/tb_smartnic.sv
	$(IVERILOG) -g2012 -o $@ $(SMARTNIC_RTL) $(TB_DIR)/tb_smartnic.sv

sim-smartnic: sim_smartnic.vvp
	$(VVP) $<
	@echo "SmartNIC simulation complete."

wave-smartnic: sim-smartnic
	$(GTKWAVE) smartnic_tb.vcd &

# ---- Run All ----
sim-all: sim-basic sim-smartnic
	@echo "All simulations passed."

# ---- Clean ----
clean:
	rm -f *.vvp *.vcd *.log
	rm -rf obj_dir/
