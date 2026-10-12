# RTL-to-GDSII 5-stage RISC-V project
SHELL := /bin/bash
RTL   := $(wildcard rtl/*.v)

.PHONY: all sim waves synth lint hex openlane clean
all: sim synth

hex: sw/test.hex
sw/test.hex: sw/test.S sw/asm.py
	python3 sw/asm.py sw/test.S sw/test.hex

sim: hex
	@mkdir -p sim
	iverilog -g2012 -DSIM -o sim/tb.vvp tb/tb_rv32_core.v $(RTL)
	vvp sim/tb.vvp | tee sim/sim.log
	@grep -q "\[TB\] PASS" sim/sim.log

# optional: dump a waveform and open it in GTKWave
waves: hex
	@mkdir -p sim
	iverilog -g2012 -DSIM -DVCD -o sim/tb.vvp tb/tb_rv32_core.v $(RTL)
	vvp sim/tb.vvp && gtkwave sim/tb_rv32_core.vcd &

lint:
	iverilog -g2012 -Wall -o /dev/null $(RTL)

# Quick technology-independent synthesis sanity check (no PDK needed)
synth:
	@mkdir -p sim
	yosys -q -p "read_verilog $(RTL); hierarchy -top rv32_core; synth -flatten -top rv32_core; check -assert; tee -o sim/synth_stat.txt stat"
	@grep -E "Number of cells" sim/synth_stat.txt | head -1

# Full RTL-to-GDSII (needs Docker + OpenLane 2 + sky130A PDK; see README)
openlane:
	bash scripts/run_openlane.sh

clean:
	rm -rf sim openlane/runs openlane/src
