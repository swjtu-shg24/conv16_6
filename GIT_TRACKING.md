# GIT 追踪说明（conv10_10）

> 目标：**只跟踪源码、工程配置和仿真/构建脚本**，把所有仿真、综合、布局布线的产物排除在外。
> 规则文件：[`.gitignore`](./.gitignore)（白名单式：先全忽略，再逐条放行）。

---

## 1. 策略总览

| 类别 | 是否跟踪 | 规则 |
|---|---|---|
| RTL 源码 `*.v` `*.sv` `*.vh` `*.svh` | ✅ | `!*.v` `!*.sv` ... |
| 仿真 filelist `*.f` | ✅ | `!*.f` |
| 仿真脚本 `*.do` `*.bat` `*.sh` `*.tcl` | ✅ | 第 2.3 节 |
| Efinity 工程文件 `*.xml` | ✅ | `conv10_10.xml`、`conv10_10.peri.xml`、`package_settings.xml` |
| 配置 `*.json` `*.ini` | ✅ | `feature_map.json`、`pe.json` ... |
| 时序约束 `*.sdc`、引脚约束 `*.lpf`/`*.pdc` | ✅ | 但 **`outflow/` 里的除外** |
| 文档 `*.md` `README*` | ✅ | 第 2.4 节 |
| 仿真产物 `work/` `*.wlf` `wlft*` `transcript` | ❌ | 第 3.3 节 |
| Efinity 输出 `outflow/` `ooc/` `ip/` `db/` | ❌ | 第 3.1 节 |
| Efinity 工作目录 `work_pnr/` `work_syn/` `work_pt/`（**含 `run_efx_*.sh`**） | ❌ | 第 3.1 / 3.2 节 |
| 报告/中间件 `*.rpt` `*.log` `*.csv` `*.vdb` `*.primplace` ... | ❌ | 第 3.4 节 |

**为什么用白名单而不是黑名单**：产物类型会随工具版本变化（新增 `*.rst`、`*.json5` 之类），黑名单很容易漏；白名单则是「没放行的都不进」，漏不掉。

---

## 2. 会被跟踪的文件（当前工程）

```
.gitignore
.gitattributes                 （可选）
GIT_TRACKING.md
conv10_10.xml                  Efinix 工程配置
conv10_10.peri.xml             Efinix 工程配置
package_settings.xml           工程/器件设置
feature_map.json               数据配置
pe_10_10_conv.sdc.sdc          时序约束
rtl/dsp48/efx_dsp48.v          Efinix DSP48 模型
rtl/sys/generate_resetn.v      复位生成
rtl/pe/pe.v  rtl/pe/pe.json    单个 PE
rtl/pe_test/*.v/*.f/*.do/*.bat   DSP 配置验证（pe_test.v / pe_test_tb.v / filelist.f / sim_test.do / run.bat）
rtl/pe_test_top.v              综合用测试顶层
rtl/pe_16_6/**                 16×6 PE 阵列（.v/.f/.do/.bat/.json）
rtl/pe10_10/**                 10×10 PE 阵列（.v/.f/.do/.bat/.json）
```

> **不再跟踪**：`work_syn/run_efx_map.sh`、`work_pnr/run_efx_pnr.sh`、`work_pnr/run_efx_pgm.sh`
> （Efinity 自动生成，内含本机绝对路径）—— 见第 3.2 节与第 6 节。

---

## 3. 会被忽略的产物

```
outflow/            比特流(.bit)、网表(.netlist/.map.v)、报告(.rpt/.xml/.csv)、
                    .lpf/.sdc/.pt 等 —— 全部是生成物
ooc/  ip/  db/      综合/IP 中间目录
work/  work_pnr/  work_syn/  work_pt/
work_*/run_efx_*.sh                     Efinix 自动生成，内含本机绝对路径 -> 不跟踪（2026-09-20）
work/  *.qdb *.qtl *.qpg *.vstf        综合/仿真的库文件
*.wlf  wlft*  transcript                ModelSim 波形库与日志
*.rpt *.log *.out *.bak *.csv *.vdb *.primplace *.io_place
```

---

## 4. 常用命令

```bash
# 看当前哪些文件会被跟踪（复核用）—— 建议第一次先跑这个
git status --short

# 排查"某个文件为什么没被跟踪 / 为什么被跟踪"
git check-ignore -v outflow/conv10_10.map.v
git check-ignore -v rtl/pe/pe.v

# 强制把某个被忽略的文件纳入跟踪（比如手写的 .lpf）
git add -f outflow/conv10_10.lpf

# 查看被忽略的文件清单
git status --ignored --short
```

---

## 5. 首次使用步骤

```bash
cd d:/my_code/fpga/yilisi/conv10_10

# 1) 先复核清单，确认没有多余的产物被放进来
git status --short

# 2) 确认无误后提交
git add -A
git commit -m "chore: 添加 .gitignore，仓库只跟踪源码/配置/脚本"

# 3) 如果发现某个产物以前已经被 commit 进去了，把它从索引里移出（保留磁盘文件）
#    ✅ 本仓库已于 2026-09-10 执行完毕，共移出 94 个产物文件
#    ✅ 2026-09-20 又移出 2 个机器相关脚本（详见第 6 节）：
#       git rm --cached work_syn/run_efx_map.sh work_pnr/run_efx_pnr.sh
#    （当前共跟踪 188 个源码/配置文件，可用 `git ls-files | wc -l` 复核）
# git rm -r --cached outflow work work_pnr work_syn work_pt ip ooc
# git commit -m "chore: 停止跟踪仿真/综合产物"
```

---

## 6. 需要你人工确认的 2 项

| 项 | 说明 | 处理 |
|---|---|---|
| `outflow/conv10_10.lpf` | 引脚约束。**如果这是你手写的**（不是 Efinity 生成的），默认规则会忽略它 | 方案 1：把它复制到仓库里一个非产物目录（推荐，例如 `constraints/conv10_10.lpf`）<br>方案 2：`git add -f outflow/conv10_10.lpf`（每次改动都要 -f，容易忘） |
| ~~`work_*/run_efx_*.sh`~~ | Efinix 生成的命令行流程脚本，记录了综合/布局参数 | ✅ **已决（2026-09-20）：不跟踪**。脚本内容是本机绝对路径（`D:/Efinity/...` vs `E:/yilisi/project/conv16_6/...`），两台机器一交替就冲突，且无共享价值。`.gitignore` 里旧的 `!work_*/run_efx_*.sh` 放行规则已删除，并从索引移出（**磁盘文件保留**，Efinity 需要时会重新生成） |
| `ip/` | 若里面有**手写**的源码（不是 Efinity 生成的 IP 包装） | 在 `.gitignore` 里加例外，例如 `!ip/my_ip/*.v` |

---

## 7. 可选：再加一个 `.gitattributes`

Windows 下 `run.bat` / `.do` 需要 CRLF、源码用 LF，可以避免"整个文件都变了"的假 diff：

```gitattributes
* text=auto eol=lf
*.bat  text eol=crlf
*.do   text eol=crlf
*.bit  binary
*.wlf  binary
```

> 注意：`.gitattributes` 要在**首次提交之前**加，否则已有的文件行尾不会自动规范化。

---

## 8. 提交前自检清单

- [ ] `git status --short` 里**没有** `outflow/`、`work*/`、`*.wlf`、`transcript`
- [ ] 只有 `.v/.sv/.f/.do/.bat/.sh/.xml/.json/.sdc/.lpf/.md` 这几类文件
- [ ] 改动了 RTL 后，`*.wf`/报告的改动**没有**出现在待提交列表里
- [ ] 新增目录时确认里面的源码能被 `git status` 看到（看不到就是被第 3 节误伤了）
