@echo off
REM ==========================================================================
REM  rtl\conv2\sim\run_wave_l2.bat -- REAL-DATA L1+L2 simulation with waveforms (GUI)
REM
REM    test.jpg (320x240x3) -> L1 (160x120x8) -> L2 (80x60x16), real weights
REM    from rtl\conv2\conv_wrom\wrom.hex (315 words: L1 67 + L2 248).
REM    DUT = c2all.tb_top_l2  (L2_EN=1, real data, real parameters)
REM
REM  Waves are grouped in DATA-FLOW order by rtl\conv2\sim\wave_l2.do (15 groups):
REM    DDR read stim -> conv_in_dma -> conv_band12 -> conv_win_load
REM      -> shared conv_l1 (L1 phase: dw/pw/BN/pool) -> write conv_plane
REM      -> scheduler/handshake
REM      -> **L2**: conv_win_load_plane (zero padding) -> same conv_l1 (cfg_l2=1)
REM      -> conv_wb_fifo (deferred drain) -> plane write mux -> readback compare
REM
REM  Artifacts: rtl\conv2\sim\wave_l2.wlf (waves), rtl\conv2\sim\transcript_wave_l2
REM  Verdict  : "TB_TOP_L2 RESULT: PASS/FAIL" at the end of transcript_wave_l2
REM
REM  NOTE: -gDUMP_ALL=0 skips the full-frame text dumps (faster GUI run).
REM        Drop it if you also want the dump files for dump_all_report.py.
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

echo.
echo ============ [1/2] compile (library c2all, incl. IP sim models) ============
%VLIB% rtl/conv2/work
%VMAP% -modelsim_quiet c2all rtl/conv2/work
%VLOG% -work c2all -sv -timescale "1ns/1ps" +incdir+ip/bram_10kb -f rtl/conv2/filelist.f
if errorlevel 1 goto err

echo.
echo ============ [2/2] launch GUI: L1+L2 real-data simulation (tb_top_l2) ============
echo   golden must be up to date:  python rtl\conv2\picture_and_para\gen_stim.py
echo   waves: rtl\conv2\sim\wave_l2.wlf    log: rtl\conv2\sim\transcript_wave_l2
%VSIM% -gui -voptargs=+acc -gDUMP_ALL=0 -l rtl/conv2/sim/transcript_wave_l2 -wlf rtl/conv2/sim/wave_l2.wlf -do rtl/conv2/sim/wave_l2.do c2all.tb_top_l2

echo.
echo ============ simulation window closed ============
pause
exit /b 0

:err
echo.
echo *** COMPILE FAILED -- please send me the errors above ***
pause
exit /b 1
