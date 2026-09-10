@echo off
cd /d %~dp0
echo Starting ModelSim simulation...

vsim -do "do sim_10_10.do"

