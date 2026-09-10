@echo off
cd /d %~dp0
echo Starting ModelSim simulation...

vsim -do "do sim_16_6.do"

