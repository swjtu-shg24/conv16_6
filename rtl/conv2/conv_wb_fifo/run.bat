@echo off
REM ==========================================================================
REM  rtl\conv2\conv_wb_fifo\run.bat -- self-check for this folder only
REM    Double-click it, or from the project root:
REM        vsim -c -do rtl/conv2/conv_wb_fifo/run.do
REM    work\ transcript\ *.wlf all stay inside this folder.
REM    Verdict = the  "TB_WB_FIFO RESULT: PASS/FAIL"  line at the end.
REM ==========================================================================
cd /d %~dp0..\..\..
set VSIM=vsim
set VLIB=vlib
set VMAP=vmap
set VLOG=vlog
if exist "D:\modeltech64_10.4\win64\vsim.exe" set VSIM="D:\modeltech64_10.4\win64\vsim.exe"
if exist "D:\modeltech64_10.4\win64\vlib.exe" set VLIB="D:\modeltech64_10.4\win64\vlib.exe"
if exist "D:\modeltech64_10.4\win64\vmap.exe" set VMAP="D:\modeltech64_10.4\win64\vmap.exe"
if exist "D:\modeltech64_10.4\win64\vlog.exe" set VLOG="D:\modeltech64_10.4\win64\vlog.exe"
%VSIM% -c -do rtl/conv2/conv_wb_fifo/run.do
pause
