@echo off
chcp 65001 > nul
REM ==========================================================================
REM  rtl\conv2\conv_band12\run.bat —— 本模块单独仿真
REM  双击即可；work/ transcript/ band.wlf 都落在本文件夹内
REM ==========================================================================
cd /d %~dp0..\..\..
vsim -c -do rtl/conv2/conv_band12/run.do
pause
