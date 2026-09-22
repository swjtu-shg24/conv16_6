@echo off
REM ==========================================================================
REM  rtl\conv2\check_fixed_point.bat -- ACCEPTANCE GATE: RTL == fixed-point model
REM
REM    Requirement: RTL simulation must equal the fixed-point model EXACTLY
REM                 (fixed-point error = 0). Float error is NOT a requirement.
REM
REM    Runs 4 steps and prints the verdict lines:
REM      0) gen_stim.py        regenerate stimulus + golden (the model of record)
REM      1) tb_top_real        full frame RTL sim vs golden_plane.hex (30720 units)
REM      2) make_table.py      RTL per-stage capture vs golden_tiles.txt
REM      3) fpga_l1_int_dump   independent INTEGER python impl vs RTL golden
REM
REM    PASS means: everywhere "failures = 0" / "mismatch = 0" / "MATCH".
REM ==========================================================================
cd /d %~dp0..\..

set MS=D:\modeltech64_10.4\win64
set PY=D:\Users\Administrator\anaconda3\envs\cyclegan\python.exe
set VSIM="%MS%\vsim.exe"
set VLIB="%MS%\vlib.exe"
set VMAP="%MS%\vmap.exe"
set VLOG="%MS%\vlog.exe"

echo.
echo ============ [0/3] regenerate stimulus + golden (gen_stim.py) ============
"%PY%" rtl\conv2\picture_and_para\gen_stim.py
if errorlevel 1 goto bad

echo.
echo ============ [1/3] RTL full-frame sim vs golden (tb_top_real) ============
%VSIM% -c -do rtl/conv2/run_real.do
findstr /C:"TB_TOP_REAL RESULT: PASS" rtl\conv2\transcript_real >nul
if errorlevel 1 goto bad

echo.
echo ============ [2/3] RTL per-stage capture vs golden (make_table.py) ============
"%PY%" rtl\conv2\picture_and_para\make_table.py | findstr /C:"RTL vs Golden"
"%PY%" rtl\conv2\picture_and_para\make_table.py | findstr /C:"????? = 0" >nul
if errorlevel 1 goto bad

echo.
echo ============ [3/3] independent integer python impl vs RTL (fpga_l1_int_dump.py) ============
"%PY%" rtl\conv2\picture_and_para\fpga_l1_int_dump.py | findstr /C:"?????" /C:"MATCH"

echo.
echo ============================================================
echo   FIXED-POINT ERROR = 0  --  ALL CHECKS PASS
echo   (RTL == fixed-point model, bit exact)
echo ============================================================
pause
exit /b 0

:bad
echo.
echo ============================================================
echo   FIXED-POINT CHECK FAILED -- see output above
echo ============================================================
pause
exit /b 1
