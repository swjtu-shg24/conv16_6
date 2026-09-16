@echo off
chcp 65001 > nul
REM ===========================================================================
REM  run_mb2.bat —— MobileNet 前端（10x10 PE 阵列，3 级 dw3x3 + pw1x1）
REM                 输入 160x160x3 -> ... -> 20x20x64（640x480 时即 80x60x64）
REM
REM  双击即可：编译 -> 载入 -> 按数据流分组加好波形 -> 跑完 -> 打开 Wave
REM  自检结果看 transcript 末尾：
REM     LB0/L1O/LB1/L2O/LB2 mismatches = 0 且 MB2 RESULT: PASS
REM ===========================================================================

cd /d %~dp0

echo.
echo ============================================================
echo   MobileNet front-end : 3 x (dw3x3 + pw1x1), 10x10 PE array
echo   compiling + loading + adding waves ...
echo ============================================================
echo.

vsim -do "do mb2/sim_mb2.do"

echo.
echo simulation finished - waveform is in the Wave window.
pause
