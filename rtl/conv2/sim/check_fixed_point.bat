@echo off
REM ==========================================================================
REM  rtl\conv2\sim\check_fixed_point.bat -- ACCEPTANCE GATE: RTL == fixed-point model
REM
REM    Requirement: RTL simulation must equal the fixed-point model EXACTLY
REM                 (fixed-point error = 0). Float error is NOT a requirement.
REM
REM    Runs 5 steps and prints the verdict lines:
REM      0) gen_stim.py        regenerate stimulus + golden (the model of record)
REM      1) tb_top_real        L1 full frame RTL sim vs golden_plane.hex (30720 units)
REM      2) make_table.py      RTL per-stage capture vs golden_tiles.txt
REM      3) fpga_l1_int_dump   independent INTEGER python impl vs RTL golden
REM      4) tb_top_l2          L1+L2 full frame, whole plane read back and compared
REM
REM    PASS means: everywhere "failures = 0" / "mismatch = 0" / "MATCH".
REM    NOTE: this file must stay PLAIN ASCII + CRLF (cmd.exe mis-parses UTF-8
REM          Chinese in .bat after chcp).  All patterns below are ASCII.
REM    Runtime: about 3.5 min (step 1) + about 8 min (step 4) on ModelSim 10.4.
REM ==========================================================================
cd /d %~dp0..\..\..

set MS=D:\modeltech64_10.4\win64
set PY=D:\Users\Administrator\anaconda3\envs\cyclegan\python.exe
set VSIM="%MS%\vsim.exe"
set VLIB="%MS%\vlib.exe"
set VMAP="%MS%\vmap.exe"
set VLOG="%MS%\vlog.exe"

echo.
echo ============ [0/4] regenerate stimulus + golden (gen_stim.py) ============
"%PY%" rtl\conv2\picture_and_para\gen_stim.py
if errorlevel 1 goto bad

echo.
echo ============ [1/4] L1 full-frame RTL sim vs golden (tb_top_real) ============
%VSIM% -c -do rtl/conv2/sim/run_real.do
findstr /C:"TB_TOP_REAL RESULT: PASS" rtl\conv2\sim\transcript_real >nul
if errorlevel 1 goto bad

echo.
echo ============ [2/4] RTL per-stage capture vs golden (make_table.py) ============
"%PY%" rtl\conv2\picture_and_para\make_table.py | findstr /C:"RTL vs Golden" /C:"MAKE_TABLE RESULT"
"%PY%" rtl\conv2\picture_and_para\make_table.py | findstr /C:"MAKE_TABLE RESULT: PASS" >nul
if errorlevel 1 goto bad

echo.
echo ============ [3/4] independent integer python impl vs RTL (fpga_l1_int_dump.py) ============
"%PY%" rtl\conv2\picture_and_para\fpga_l1_int_dump.py | findstr /C:"MATCH" /C:"MISMATCH" /C:"FPGA_L1_INT_DUMP RESULT"
"%PY%" rtl\conv2\picture_and_para\fpga_l1_int_dump.py | findstr /C:"FPGA_L1_INT_DUMP RESULT: PASS" >nul
if errorlevel 1 goto bad

echo.
echo ============ [4/4] L1+L2 end-to-end vs golden (tb_top_l2) ============
%VSIM% -c -do rtl/conv2/sim/run_l2.do
findstr /C:"TB_TOP_L2 RESULT: PASS" rtl\conv2\sim\transcript_l2e2e >nul
if errorlevel 1 goto bad
"%PY%" rtl\conv2\picture_and_para\compare_l2_dump.py | findstr /C:"RTL vs Golden" /C:"MAKE_TABLE_L2 RESULT"
"%PY%" rtl\conv2\picture_and_para\compare_l2_dump.py | findstr /C:"MAKE_TABLE_L2 RESULT: PASS" >nul
if errorlevel 1 goto bad
echo ---- [4/4b] full-frame dumps report (every stage of both layers) ----
"%PY%" rtl\conv2\picture_and_para\dump_all_report.py | findstr /C:"DUMP_ALL_REPORT RESULT"
"%PY%" rtl\conv2\picture_and_para\dump_all_report.py | findstr /C:"DUMP_ALL_REPORT RESULT: PASS" >nul
if errorlevel 1 goto bad

echo.
echo ============================================================
echo   FIXED-POINT ERROR = 0  --  ALL CHECKS PASS
echo   (L1 + L2, RTL == fixed-point model, bit exact)
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
