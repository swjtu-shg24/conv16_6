@echo off
REM ==========================================================================
REM  rtl\conv2\run_wave.bat -- GLOBAL simulation with waveforms (GUI)
REM
REM    double-click          = full frame 320x240x3 -> 160x120x8  (tb_top_full, 4-7 min)
REM    run_wave.bat small    = small image 80x40x3 -> 40x20x8     (tb_top, ~30 s)
REM
REM  Waves are grouped in DATA-FLOW order by rtl\conv2\wave_full.do:
REM    DDR read stim -> conv_in_dma (16B->5B realign) -> conv_band12 -> conv_win_load
REM      -> conv_l1 (dw 3x3 -> pw 1x1 -> quant -> 2x2 pool) -> write conv_plane
REM      -> readback check -> scheduler/handshake -> result bus
REM
REM  Artifacts: rtl\conv2\wave.wlf (waves), rtl\conv2\transcript_wave (text log)
REM  Verdict  : "TB_TOP_FULL RESULT: PASS/FAIL" at the end of transcript_wave
REM ==========================================================================
cd /d %~dp0..\..
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

set TB=c2all.tb_top_full
if /i "%1"=="small" set TB=c2all.tb_top

echo.
echo ============ [1/2] compile (library c2all, incl. IP sim models) ============
%VLIB% rtl/conv2/work
%VMAP% -modelsim_quiet c2all rtl/conv2/work
%VLOG% -work c2all -sv -timescale "1ns/1ps" +incdir+ip/bram_10kb -f rtl/conv2/filelist.f
if errorlevel 1 goto err

echo.
echo ============ [2/2] launch GUI simulation: %TB% ============
echo   waves: rtl\conv2\wave.wlf    log: rtl\conv2\transcript_wave
%VSIM% -gui -voptargs=+acc -l rtl/conv2/transcript_wave -wlf rtl/conv2/wave.wlf -do rtl/conv2/wave_full.do %TB%

echo.
echo ============ simulation window closed ============
pause
exit /b 0

:err
echo.
echo *** COMPILE FAILED -- please send me the errors above ***
pause
exit /b 1