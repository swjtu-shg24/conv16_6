@echo off
REM ==========================================================================
REM  rtl\conv2\conv_plane\run.bat -- self-check for this module folder only
REM    Double-click it, or from the project root:
REM        vsim -c -do rtl/conv2/conv_plane/run.do
REM    work\ transcript\ *.wlf all stay inside this folder.
REM    Verdict = the  "TB_XXX RESULT: PASS/FAIL"  line at the end of transcript.
REM ==========================================================================
cd /d %~dp0..\..\..
REM -- ModelSim tools: use the local install by FULL PATH.  Bare names fail when
REM    MODEL_TECH is unset, because vlog/vmap then look for modelsim.ini only in
REM    the current directory (argv[0] based lookup).
set VSIM=vsim
set VLIB=vlib
set VMAP=vmap
set VLOG=vlog
if exist "D:\modeltech64_10.4\win64\vsim.exe" set VSIM="D:\modeltech64_10.4\win64\vsim.exe"
if exist "D:\modeltech64_10.4\win64\vlib.exe" set VLIB="D:\modeltech64_10.4\win64\vlib.exe"
if exist "D:\modeltech64_10.4\win64\vmap.exe" set VMAP="D:\modeltech64_10.4\win64\vmap.exe"
if exist "D:\modeltech64_10.4\win64\vlog.exe" set VLOG="D:\modeltech64_10.4\win64\vlog.exe"
%VSIM% -c -do rtl/conv2/conv_plane/run.do
pause