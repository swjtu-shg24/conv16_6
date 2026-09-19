@echo off
chcp 65001 > nul
REM ==========================================================================
REM  rtl\conv2\conv_sched\run.bat —— 本模块单独仿真
REM ==========================================================================
cd /d %~dp0..\..\..
vsim -c -do rtl/conv2/conv_sched/run.do
pause
