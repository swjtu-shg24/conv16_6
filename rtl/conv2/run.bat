@echo off
chcp 65001 > nul
REM ==========================================================================
REM  rtl\conv2\run.bat —— 顶层（本层）入口，在工程根目录执行
REM   ① 全量编译检查（库 c2all，work 落在本文件夹 rtl\conv2\work）
REM   ② 依次跑每个模块文件夹自己的 run.do（各自独立库、独立产物）
REM   ③ 端到端：conv_top 小图 80x40x3 -> 40x20x8（tb_top）
REM   自检结论看各 transcript 末尾的  TB_XXX RESULT: PASS / FAIL
REM ==========================================================================
cd /d %~dp0..\.

echo.
echo ============ [1/3] full compile check (all sources) ============
vlib rtl/conv2/work
vmap -modelsim_quiet c2all rtl/conv2/work
vlog -work c2all -sv -timescale "1ns/1ps" +incdir+ip/bram_10kb -f rtl/conv2/filelist.f

echo.
echo ============ [2/3] per-module self-check ============
for %%M in (conv_cmp4_tree conv_pool_arr conv_mem_unit conv_band12 conv_win_load conv_in_dma conv_l1 conv_sched conv_plane) do (
    echo.
    echo --------------------- %%M ---------------------
    vsim -c -do rtl/conv2/%%M/run.do
)

echo.
echo ============ [3/3] top-level end-to-end (tb_top) ============
vsim -c -do rtl/conv2/run.do

echo.
echo ============================================================
echo   conv2 self-check finished (see TB_* RESULT above)
echo ============================================================
pause
