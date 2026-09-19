@echo off
chcp 65001 > nul
REM ==========================================================================
REM  run.bat —— conv 前端仿真（输入 320x240x3 -> 输出 160x120x8）
REM  双击即可：编译 -> 载入 -> 加波形 -> 跑完
REM  自检结果看 transcript 末尾的 CONV RESULT: PASS / FAIL
REM ==========================================================================
cd /d %~dp0..\..

echo.
echo ============================================================
echo   conv front-end : 320x240x3 -^> (dw3x3+pw1x1) -^> 160x120x8
echo   compiling + loading + adding waves ...
echo ============================================================
echo.

vsim -do "do rtl/conv/sim_conv.do"

echo.
echo simulation finished - waveform is in the Wave window.
pause
