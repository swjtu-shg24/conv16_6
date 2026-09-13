# conv16_6_core 使用说明

这个封装将 `feature_map_param` 和 `pe_16_6` 组合成一次处理一个输入块的计算模块。保留现有 PE 实现，只增加任务输入锁存、权重广播、最终结果锁存和握手控制。

## 支持范围

- 单输入通道、单输出通道，步长 1，卷积核高宽分别为 1～3。
- 输入和权重使用 18 位有符号补码，输出是 48 位有符号补码位模式。
- 数学运算采用神经网络常用的互相关顺序，权重不翻转。
- 不包含 padding、DDR、bias、激活、量化或跨输入通道累加。
- 所有外部握手均在 `clk` 域，复位 `rstn` 低有效。

## 数据排列

输入固定使用 18 列的行跨度：`tile_data[y*18+x]`，一共 8 行、144 个元素。
核高 KH、核宽 KW 时，实际使用左上角 `(6+KH-1)` 行、`(16+KW-1)` 列；未使用元素可以填 0。
padding 应在提交 tile 前完成。

权重连续排列：`kernel_data[ky*KW+kx]`。只使用前 `KH*KW` 个权重，其余填 0。
例如高 2、宽 2 时，前四项依次是 `w00,w01,w10,w11`，不是按固定三列排列。

输出按行排列：`result_data[y*16+x]`，共 6 行、16 列。

```text
result_data[y*16+x] = Σ tile_data[(y+ky)*18+x+kx] * kernel_data[ky*KW+kx]
```

## 一次任务

1. 等待 `start_ready=1`，准备 `tile_data`、`kernel_data` 和核宽高。
2. 在 `start && start_ready` 的上升沿，封装接受并锁存全部数据。
3. 接受后撤销 `start`；外部输入数组和尺寸可以改变，内部计算使用锁存值。
4. 封装自动广播权重，统计阵列的有效部分和，保存最后一次输出。
5. `result_valid=1` 后，全部 96 个结果有效并保持。
6. 在 `result_valid && result_ready` 的上升沿，下游接收整块结果；随后允许新任务。

`busy` 覆盖初始化、计算、等待结果被接收三个阶段。非法核尺寸时 `start_ready=0`，任务不会被接受。
本版复位释放后等待 32 个时钟，使现有 PE 中未逐项复位的控制移位寄存器排空；外部始终以 `start_ready` 为准。
中途复位会丢弃当前任务和尚未接收的结果。

`result_ready` 不是 AXI WREADY。如果写回模块没有自己的整块结果缓存，需要在取走全部结果前保持 `result_ready=0`。
本版有意一次只允许一个任务，不支持多任务重叠。

## 例化

```systemverilog
conv16_6_core u_conv (
    .clk(clk), .rstn(rstn),
    .start(tile_start), .start_ready(tile_ready), .busy(conv_busy),
    .kernel_height(kh), .kernel_width(kw),
    .tile_data(padded_tile), .kernel_data(weights),
    .result_data(conv_result), .result_valid(conv_result_valid),
    .result_ready(conv_result_ready)
);
```

综合需要加入 `conv16_6_core.sv`、`feature_map_param.sv`、`pe_16_6.sv`、`../pe/pe.v`，DSP 使用目标工具的 Efinix 原语库。
仿真使用 `filelist_core.f`，其中包含本地 DSP 模型和自检 testbench。不要把 testbench 加入综合源文件。
本次没有修改现有演示顶层或工程 XML；集成时将此封装例化到实际系统顶层，并核对工程源文件的 `.sv` 后缀。

## 仿真

在本目录运行：

```powershell
vsim -do "do sim_core.do"
```

2026-09-13 使用 Questa 验证通过：55 组完整输出块比较，另含下游提前 ready 的测试；覆盖全部九种核尺寸、全 1/正负变化/单点权重、正负输入、忙时重复请求、接受后输入变化、结果背压、非法核尺寸和中途复位。
这是 RTL 功能仿真结果；尚未进行综合、时序收敛或板上验证。

### 查看波形

图形界面脚本会启用内部信号可见性、加载 `wave_core.do` 的分组并运行全部测试；结束后保留窗口，不自动退出。
也可以双击本目录现有的 `run sim16_6_core.bat`。
完整信号历史保存为本目录的 `conv16_6_core.wlf`。

- “当前测试”：`active_kh/active_kw` 是本次测试核尺寸，`active_mode` 的 0/1/2 分别表示全1、正负交替、单点权重，3 表示最后一组提前接收测试。
- “任务与结果握手”：看 `start && start_ready` 接受输入，`result_valid && result_ready` 接收结果。
- “内部任务控制”：看锁存尺寸、权重索引和结果计数。
- “窗口移动”：看加载、向左移动和向上移动时的边缘注入。
- “PE0乘法与累加”：看像素、权重、DSP乘积和外部部分和。
- “结果对照”：对照PE0/15/16/95的部分和、锁存结果和参考值；只在 `result_valid=1` 时比较最终结果。
- “完整数组按需展开”：展开任意输入、权重或输出元素。

测试会在输入接收后故意修改外部 `tile/kernel/kh/kw` 并在忙时再次拉高 `start`，验证内部锁存和启动保护。
因此观察本次真实计算输入应看 `dut.tile_reg/weight_reg/kh_reg/kw_reg`；忙时的第二次 `start` 不应被接受。
`test_passed=1` 表示全部自检结束并通过；仿真结束时检查控制台的 PASS，而不是仅凭看见波形判断正确。

命令行运行并按自检状态返回退出码：

```powershell
vsim -c -do 'do sim_core.do; if {[examine -radix unsigned sim:/conv16_6_core_tb/test_passed] == 1} {quit -code 0 -f} else {quit -code 1 -f}'
```
