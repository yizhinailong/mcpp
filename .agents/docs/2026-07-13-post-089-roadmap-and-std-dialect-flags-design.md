# 0.0.89 后路线:std 模块方言旗标一致性(#210)+ 遗留优化清单 — 设计方案

> 2026-07-13 · 基于 0.0.89(f6fd39e,Part A 抽象层 + Part B MinGW 已落地)
> 输入:issue #210(`-freflection` 未进 std BMI 预构建)+ 0.0.89 交付后的遗留清单
> 前置文档:`2026-07-13-toolchain-backend-abstraction-msvc-mingw-design.md`(主设计,Part C 未动)
> + `2026-07-13-compiler-dialect-touchpoint-audit.md`

## 0. 一句话

最高优先是 **D1:方言类编译旗标(`-freflection` 一类"改变标准库头暴露什么声明"的 flag)
必须成为模块图全局属性,走 `-std=` 已有的通道**——进 std/std.compat BMI 预构建命令、
进全局 `$cxxflags`、进扫描命令;指纹早已把它算进缓存键,漏的只是命令构造(#210 根因,
报告者定位完全正确)。其余为 Part C(MSVC 原生构建)启动核对表、Part A 债务收尾、
MinGW 打磨与发布基建四组小项。

## 1. D1 — std 模块 BMI 方言旗标一致性(issue #210)

### 1.1 根因(代码落地)

- `prepare.cppm:2636` `ensure_built(*tc, fp.hex, standard, m->cppStandard.flag, …)` —
  std BMI 预构建**只接收语言标准 flag**(#98/#100 的成果),用户 `[build].cxxflags`
  不在形参里;gcc/clang 的 `std_module_build_command(s)` 相应只拼 `cppStandardFlag`。
- 用户 cxxflags 的既有通道是 **per-unit** `$unit_cxxflags`(ninja_backend.cppm:512)——
  只到项目自身 TU,std BMI 与依赖包 BMI 都看不到。
- 指纹**已经**包含它(`canonical_compile_flags(*m)`,prepare.cppm:2624)→ 缓存键正确、
  目录会分裂,但分裂出的目录里装的仍是不带该 flag 的 std BMI——**缓存不背锅,
  命令构造背锅**(与 issue 的诊断一致)。
- 为什么 `-freflection` 致命:libstdc++ 的 `<meta>` 整体被
  `__cpp_impl_reflection >= 202603L` 守卫,该宏仅由 `-freflection` 定义——不带它编出的
  std BMI **结构上**不含 `std::meta`。

### 1.2 关键推论:只修 std 不够(报告者的 fmt.gcm 二次错误)

报告者手工给 std BMI 加上 `-freflection` 后,混合构建立刻在 `fmt.gcm` 上撞出 BMI 兼容
错误:依赖包的模块 TU 仍按包自有 flags(无 `-freflection`)编译,导入"带反射的 std"
时 GCC 的模块方言校验拒绝。结论:**这类 flag 与 `-std=` 同性质——是整张模块图的方言,
不是某个 TU 的私货**。修法必须让它落在 `-std=` 走过的每一处:

| `-std=` 今天到达的地方 | 机制 | D1 后方言旗标同样到达 |
|---|---|---|
| 项目/依赖所有 TU | 全局 `$cxxflags`(flags.cppm `cxx_std_flag`) | ✓ |
| std / std.compat BMI 预构建 | `ensure_built(cpp_standard_flag)` | ✓ |
| P1689 扫描命令 | scan 规则里的 `$cxxflags` | ✓ |
| 指纹 / BMI 缓存键 | `fpi.cppStandard` + canonical flags | ✓(已在,无需改) |

依赖包的**其余** cxxflags 仍是包所有制(0.0.72 接口宏传播模型不动)——全图化的只有
方言子集。

### 1.3 机制设计

**a. 提取(known-list,数据表)**:`manifest`/`prepare` 层新增
`extract_dialect_flags(buildConfig.cxxflags) → std::vector<std::string>`,识别表初始值:

```
-freflection  -fno-reflection      (P2996;GCC 16+)
-fcontracts   -fno-contracts       (P2900)
-fchar8_t     -fno-char8_t
-fno-exceptions  -fno-rtti
-D_GLIBCXX_USE_CXX11_ABI=<v>       (libstdc++ ABI 开关)
```

判据:**改变标准库头声明集或模块方言校验参与项**的 flag 才入表;`-O/-g/-W*/-I/-fPIC`
等永不入表(它们要么无害要么本就该 per-unit)。命中的 flag **不从 per-unit 里移除**
(重复无害,语义幂等),只是additionally 全图化——实现最小、行为可解释。

**b. 显式逃生舱**:`[build] dialect_cxxflags = [...]`(manifest 新键)——用户可显式
声明"这几个 flag 是全图方言",绕过识别表滞后(新编译器新 flag 出现时不必等 mcpp
发版)。`dialect_cxxflags ∪ extract(cxxflags)` 去重后为最终 `dialectFlags`。

**c. 注入点(全部现成通道,无新管线)**:
- `BuildPlan` 增 `dialectFlags`(plan.cppm:316 旁,与 cppStandardFlag 同源填充);
- flags.cppm:`f.cxx` 拼接 `cxx_std_flag` 处追加(→ 全局 `$cxxflags`,自动覆盖
  项目 TU、依赖 TU、模块规则、scan 规则);`f.cc` 不加(C 无此类方言;若来日有,
  按需拆 c/cxx 两表);
- `ensure_built` 增一个 `dialect_flags` 形参 → gcc/clang(未来 msvc)的
  `std_module_build_commands` 拼进命令;`metadata_for` 哈希的是完整命令串 →
  **std-module.json 自然失效重建,无需新缓存逻辑**;
- `std_build_commands` 记录进 std-module.json(现状已记录命令,自动带上)。

**d. 诊断(轻量)**:`mcpp why toolchain`/`self doctor` 输出 dialectFlags 与
std-module.json 里记录的构建命令,便于人工核对;不做"猜测性 mismatch 告警"
(有了 c 之后 mismatch 在结构上不可能,残留场景只有手改缓存)。

### 1.4 测试

- 单测:`extract_dialect_flags`(命中/不命中/去重/`dialect_cxxflags` 合并)。
- e2e `98_reflection_import_std.sh`(`# requires: gcc`,gcc 16.1.0 支持 `-freflection`):
  复刻 #210 的最小工程(`[build] cxxflags=["-freflection"]` + `std::meta` 遍历成员),
  断言 build+run 输出;再断言 std-module.json 的命令串含 `-freflection`。
  加一个带依赖模块的变体(本地 path dep 提供一个 `import std;` 的模块)覆盖 1.2 的
  全图一致性(fmt.gcm 类回归)。
- 现有 85/98 号 host-aware 教训:断言写平台无关。

### 1.5 非目标

- 把任意 root cxxflags 传给依赖(包所有制不变;只有方言子集全图化)。
- Clang 侧反射 flag 的字面支持(机制 flag-无关;Clang 落地 P2996 后往表里加一行)。
- `[package].standard` 之外再造第二个"标准"概念——`dialect_cxxflags` 是 flag 直传,
  不做语义化(`reflection = true` 这类糖等用户需求明确再加)。

## 2. Part C — MSVC 原生构建:启动核对表(引用主设计 §5,补 0.0.89 后现状)

| 件 | 主设计 | 0.0.89 现状 | 剩余 |
|---|---|---|---|
| CommandDialect msvc 行 | §5.2 | **数据已在**(dialect.cppm) | 无 |
| BmiTraits ifc 行 + 拼写 | §3/§5 | **已在**(model.cppm) | 无 |
| envOverrides 缝 | §5.1 | **已在**(ninja child env) | fast-path 缓存不持久化 envOverrides(C1 一并处理:fast path 重新 derive) |
| C1 find_windows_sdk + INCLUDE/LIB/PATH 合成 | §5.1 | 未做 | 全部 |
| C2 ninja 发射:SeparateLinker / rspfile / deps=msvc | §5.2 | **只有字段,无发射逻辑**(ninja_backend 注释着 TODO) | 全部;VSLANG=1033 细节 |
| C3 std.ixx staging | §5.3 | 未做(stdmod 第三分支;std.compat staging 的 clang 硬编码同时 registry 化) | 全部 |
| C4 .ifc + /scanDependencies | §5.4 | dyndep 参数化已就绪 | scan 驱动接线 |
| C5 link.exe/lib.exe | §5.5 | linkmodel PE 空模型已在(target 键控) | 链接后端 |
| C6/C7 e2e + 删门 | §5.6 | 95 号已断言门信息 | 全部;删门时改 95 |
| cppStandardFlag GNU 拼写 | 审计表 | `normalize_cpp_standard` 仍产 `-std=…` | C2 时经 dialect.stdPrefix 产出 |

## 3. Part A 债务收尾(可并入 C 的第一个 PR)

- **A4 后半**:std 模块命令 / p1689 scan 的 `env LD_LIBRARY_PATH=…` shell 前缀迁到
  argv+env(clang.cppm `_WIN32` 引号 workaround 随之可删);stdmod 的 `shellEsc`
  单引号硬编码 → `shq`(平台感知)。
- **A6 清零**:`build_program.cppm host_base_flags` 的 is_clang 双路 → caps/dialect;
  `p1689.cppm scan_file` GCC 专属 flags → 与 ninja scan 规则共用 dialect/caps 判定。

## 4. MinGW 打磨(一个杂项 PR)

1. Linux(及 macOS)上 `toolchain install/default mingw` → 明确报
   "mingw is a Windows-only toolchain"(现:不带版本时 `invalid xpkg target 'xim:mingw-gcc@'`)。
   落点:lifecycle 在 `to_xim_package` 后对 `mingw-gcc` 加平台门。
2. e2e 97 的 objdump 路径去硬编码(从 `toolchain list`/安装目录 glob 版本)。
3. doctor 增 mingw 段(Windows:已装版本 / 未装一行提示)。
4. abi 细化:`is_mingw_target` → libc `ucrt`(评估对既有 ABI 兼容门的影响后再动;
   0.0.89 刻意跳过)。
5. mingw-gcc 版本跟踪:xim-pkgindex 的 version-check.py 增加 winlibs 源
   (releases API → 重打包脚本化:`.agents/tools/repack-winlibs.sh`,把 0.0.89 手工
   流程固化)——等 winlibs 下个 GCC 版本时一并做。

## 5. 发布基建

- **mirror_res.sh 修复版(b4c25ad)待实战检验**:下一个 release(0.0.90)的
  publish-ecosystem 是真考,预期 2-4 分钟;若仍紧张,`timeout-minutes: 20 → 30`
  兜底(一行)。验收:该 job 全自动成功(镜像+索引 PR),无人工介入。
- **gtc 的 python3 shim 断链**(xlings 侧):`~/.xlings` 的 python3 shim 指向缺失的
  xim python payload;本机一直用 `/usr/bin/python3` 绕。根因修复属 xlings 仓
  (shim 目标校验/重装提示),单独 issue 过去。
- publish-ecosystem 的索引 bump 步骤在 job 被杀时不可重入拉起——本次 0.0.89 手工补了
  #383;修复版脚本 + timeout 兜底后应不再发生,不另做机制。

## 6. 排期建议(PR 粒度)

1. **PR-1(0.0.90,优先——用户在 #210 等)**:D1 全量(提取器 + dialect_cxxflags +
   三注入点 + e2e 98 两变体)+ §5 的 timeout 兜底一行。发布走全自动闭环,
   顺带完成 mirror 修复版的实战验收。
2. **PR-2 起(0.0.91+)**:Part C 按 C1+C2 → C3 → C4 → C5 → C6/C7 切 2-3 个 PR
   (临时单 CI 分支迭代,同 0.0.88/89 流程),A 债务(§3)并入第一个。
3. **杂项 PR**:MinGW 打磨 §4 的 1-3(4/5 视时机)。

## 7. 风险

| 风险 | 对策 |
|---|---|
| dialectFlags 全图化改变依赖 BMI 缓存键 → 首次升级全量重建 | 本来就该重建(旧缓存语义错);CHANGELOG 说明 |
| 识别表滞后于新编译器 flag | `dialect_cxxflags` 逃生舱;表是纯数据,补一行发补丁版 |
| `-fno-exceptions/-fno-rtti` 全图化影响依赖包(包可能假设异常可用) | 这两项入表与否单独评审;首版可只收 reflection/contracts/char8_t/ABI 宏,保守起步 |
| e2e 98 依赖 gcc16 的 -freflection 在 CI 工具链可用 | 报告者已在 xlings gcc@16.1.0 复现语法路径;e2e 标 `requires: gcc` 并在 flag 不被驱动接受时 SKIP(探测 `g++ -freflection -E -x c++ /dev/null`) |
