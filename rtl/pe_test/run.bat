@echo off
cd /d %~dp0
echo Starting ModelSim simulation (pe_test: EFX_DSP48 外部累加器模式) ...

vsim -do "do sim_test.do"

