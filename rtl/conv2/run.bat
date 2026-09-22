@echo off
REM ==========================================================================
REM  rtl\conv2\run.bat -- top-level entry (run from anywhere, it cd's first)
REM    1/4 full compile check of every source (library c2all)
REM    2/4 run each module folder's own run.do (own library, own artifacts)
REM    3/4 end-to-end: conv_top small image 80x40x3 -> 40x20x8 (tb_top)
REM    4/4 REAL stimulus: test.jpg + real weight ROM (tb_top_real)
REM  Verdict = the "TB_XXX RESULT: PASS/FAIL" lines printed above.
REM ==========================================================================
cd /d %~dp0..\..
REM    ^ was %~dp0..\. which only went up to rtl\, but filelist.f paths are relative
REM      to the PROJECT ROOT (rtl/conv2/...) -> it looked in rtl\rtl\conv2\. Fixed.
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
echo ============ [1/3] full compile check (all sources) ============
%VLIB% rtl/conv2/work
%VMAP% -modelsim_quiet c2all rtl/conv2/work
%VLOG% -work c2all -sv -timescale "1ns/1ps" +incdir+ip/bram_10kb -f rtl/conv2/filelist.f

echo.
echo ============ [2/3] per-module self-check ============
for %%M in (conv_cmp4_tree conv_pool_arr conv_mem_unit conv_band12 conv_win_load conv_in_dma conv_l1 conv_sched conv_plane conv_wrom) do (
    echo.
    echo --------------------- %%M ---------------------
    %VSIM% -c -do rtl/conv2/%%M/run.do
)

echo.
echo ============ [3/4] top-level end-to-end (tb_top small image) ============
%VSIM% -c -do rtl/conv2/run.do

echo.
echo ============ [4/4] REAL stimulus: test.jpg + wrom.hex (tb_top_real) ============
echo   need stimulus files first:  python rtl\conv2\picture_and_para\gen_stim.py
%VSIM% -c -do rtl/conv2/run_real.do

echo.
echo ============================================================
echo   conv2 self-check finished (see TB_* RESULT above)
echo ============================================================
pause