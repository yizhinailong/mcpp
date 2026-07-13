# 工具链后端抽象层 + MSVC 原生构建 + MinGW 生态入驻 — 设计方案

> 2026-07-13 · 基于 0.0.88(msvc@system 检测已落地)代码审计
> 姊妹文档:`2026-07-13-msvc-system-toolchain-detection-design.md`(Phase 1,已发布)、
> `2026-05-15-clang-parity-and-toolchain-abstraction.md`(BmiTraits 抽象,已实现)、
> `2026-07-08-scanner-backend-abstraction-design.md`(扫描后端,P1689 为通用格式)

## 0. 一句话

mcpp 的工具链抽象**骨架已存在但未完成**:BMI 机制、能力查询、C 库链接模型、依赖扫描
四条缝是对的,但 flags/ninja 规则/进程执行三层仍硬编码 GNU 方言。本方案分三部分:
**A. 补齐抽象层**(命令方言 traits + 后端接口规范化 + exec 层去 POSIX 化,对现有
GCC/Clang 零行为变化);**B. MinGW 入 xlings 生态**(复用 GCC 后端,纯打包+平台工作,
xlings-res gh/gtc 双端镜像);**C. MSVC 原生 cl.exe 构建后端**(新方言 + env 模型 +
.ifc 管线 + link.exe/lib.exe,只用系统安装的 MSVC,最后删除 prepare 的构建门)。

## 1. 现状评估(审计结论,file:line 落地)

### 1.1 已有的、正确的抽象缝(保留并扩展)

| 抽象 | 位置 | 现状 |
|---|---|---|
| `BmiTraits` / `bmi_traits(tc)` | model.cppm:56-118 | 数据表驱动 BMI 目录/扩展名/输出旗标;MSVC `.ifc` 分支 0.0.88 已预置;消费方 ninja_backend:264、flags:263、prepare:2738(bmi_cache CacheKey) |
| `ProviderCapabilities` / `capabilities_for(tc)` | provider.cppm:26-107 | 设计定位就是"取代散落的 is_clang/is_gcc"(文件头注释),但**只有 flags.cppm:128 一个消费者**——设计意图未兑现 |
| `linkmodel`(C 库链接模型) | linkmodel.cppm 全文 | 最完整的抽象:payload-first/sysroot/Clang cfg-bypass 单点解析;但全部 GNU 驱动语法,无 PE/MSVC 概念 |
| `abi_profile`(ABI 维度) | abi.cppm:45-96 | 数据驱动;**`mingw → msvcrt` 映射已在**(:76);MSVC cxxAbi 已在(:93) |
| dyndep 参数化 | dyndep.cppm:36-39 | `DyndepOptions{bmiDir,bmiExt}` 由 bmi_traits 喂,编译器无关 |
| 扫描后端(P1689 通用格式) | 2026-07-08 设计 | "p1689 一个后端、按工具链选驱动(GCC 内建 / clang-scan-deps / **MSVC /scanDependencies 已预留**)" |
| per-compiler provider 模块 | gcc.cppm / clang.cppm / llvm.cppm / msvc.cppm | 事实上的后端实现体;但导出面**签名不对齐**(见 1.3) |
| cfg 谓词 / manifest | prepare.cppm:60-85 | `mingw → windows` 已识别(:67);`[toolchain]` per-platform schema 就绪 |

### 1.2 未抽象的三层(本方案 Part A 的对象)

1. **flags.cppm `compute_flags` ≈25 处方言分支**(flags.cppm:128-440):`-o/-c/-I/-D/-std=`
   全 GNU 拼写;`-static-libstdc++`(:290)、libatomic GNU-ld 段(:62-120)、macOS 专属
   链接路径(:324-429)、binutils `-B`(:212-224)全部 if/else 内联。
2. **ninja 规则模板全 GNU**(ninja_backend.cppm):`cxx_object` `-c $in -o $out`(:359),
   `cxx_link` `$cxx $in -o $out`(:375),`cxx_archive` 字面 `ar rcs`(:379——
   provider.cppm:96 早已声明 `lib.exe` 但无人发射),无 `deps = msvc`,**无响应文件**
   (Windows 8191 字符命令上限风险)。
3. **exec/env 层 POSIX-only**:`compiler_env_prefix` 生成 `env LD_LIBRARY_PATH=… `
   **shell 字符串前缀**(probe.cppm:229)拼进 std 模块构建命令;`shq` 单引号 POSIX
   引用(xlings.cppm:533)对 `cl.exe /flag` 和 `C:\Program Files\…` 皆不成立
   (clang.cppm:182-213 的 `_WIN32` workaround 已经暴露了这个债)。

### 1.3 后端接口不对齐(Part A 规范化对象)

gcc.cppm/clang.cppm 的导出面即事实接口,但:GCC `std_module_build_command` 返回单命令、
Clang 返回 vector;`matches_version_output` 参数个数不同;enrich 一个带 envPrefix 一个
不带;archive_tool/find_scan_deps/std.compat 只有 Clang 有。MSVC/MinGW 接入前先对齐。

### 1.4 结论

**抽象层需要先做**(用户判断正确)。但不是推倒重来——路线是"补完既有缝",延续
2026-05-15 文档的既定原则:**值类型 traits + per-compiler provider 模块 + 中心查询点,
不引入虚函数/继承层次**(该文档 §2.3/§8 的取舍依然成立:差异是数据和少量函数,
不是多态行为)。

## 2. 目标后端模型(Part A 的产出形态)

一个"编译器后端"= **三张 traits 表 + 一组签名规范化的 provider 函数**,全部按
`CompilerId` 分发,消费侧不再出现 `is_clang()/is_gcc()` 内联分支:

```
后端 = { BmiTraits            (已有,保留)
       , ProviderCapabilities (已有,提升为必经查询点)
       , CommandDialect       (新增,本方案核心)
       }
     + provider 模块函数(签名统一):
         matches_version_output(head, full)        → bool
         enrich_toolchain(Toolchain&, envPrefix)   → void/expected
         std_module_commands(tc, ctx)              → vector<Cmd>   // 统一 vector
         staged_std_bmi_path(outputDir)            → path
         archive_tool(tc)                          → path
         scan_driver(tc)                           → ScanDriver    // 2026-07-08 §3a
         post_install(cfg, payload)                → void          // PE = no-op
```

### 2.1 `CommandDialect`(新,src/toolchain/dialect.cppm)

命令行**拼写**的单一数据点。两个实例:`gnu`(GCC/Clang/MinGW 共用)与 `msvc`:

```cpp
struct CommandDialect {
    // 拼写函数(纯字符串,无 I/O)
    std::string std_flag(std::string_view std);        // "-std=c++23" | "/std:c++latest"
    std::string define(std::string_view kv);           // "-DX=1"      | "/DX=1"
    std::string include(const fs::path& dir);          // "-Ip"        | "/Ip"
    std::string compile_only();                        // "-c"         | "/c"
    std::string output_obj(const fs::path& o);         // "-o p"       | "/Fo:p"
    std::string opt(std::string_view level);           // "-O2"        | "/O2"
    std::string debug();                               // "-g"         | "/Zi /FS"
    std::string_view obj_ext;                          // ".o"         | ".obj"
    std::string_view always_flags;                     // ""           | "/nologo /EHsc /utf-8"
    // ninja 侧
    std::string_view ninja_deps_mode;                  // "gcc"(-MF) | "msvc"(/showIncludes)| ""
    bool wants_rspfile_link = false;                   // msvc: link/archive 走 rspfile
    // 链接形态
    enum class Link { Driver, SeparateLinker } link;   // g++/clang++ 直链 | link.exe
    std::string archive_cmd_template;                  // "$ar rcs $out $in" | "$ar /nologo /OUT:$out @$out.rsp"
};
CommandDialect dialect_for(const Toolchain& tc);       // MSVC → msvc,其余 → gnu
```

**为什么值得单独一张表**:审计表里"Output/include/define syntax""对象扩展名"
"archive 命令""deps 模式""响应文件"五行的公共分母就是它;GCC/Clang/MinGW 共享
`gnu` 实例意味着 Part A 对现有后端**零行为变化**,而 MSVC 只是第二行数据。

### 2.2 env 模型(exec 层去 POSIX 化)

`Toolchain` 增加 `std::vector<std::pair<std::string,std::string>> envOverrides`:

- GCC/Clang:现 `compilerRuntimeDirs` → `LD_LIBRARY_PATH`,从"shell 字符串前缀"
  改为 envOverrides 数据(消费方 `capture_exec(argv, env)` 早已支持干净 env 对,
  execute.cppm:337-344——只是 std 模块命令那条路没用它)。
- MSVC:`INCLUDE` / `LIB` / `PATH`(见 Part C §5.1)。
- ninja 规则内的 `$toolenv` 相应改为跨平台形式(POSIX `env A=B …` / Windows
  `cmd /c "set A=B && …"`)或——更优——写进 ninja 全局 `env` 不进 command 字符串;
  实施时以「compile_commands.json 仍可被 clangd 消费」为约束选形式。

### 2.3 明确不做

- 虚基类/继承后端(既定原则,理由见 2026-05-15 §2.3)。
- 统一 BMI 目录名、合并 GCC/Clang std 模块流程(同文档 §8)。
- 一次性大改:每步对现有工具链**零 diff**(验收:e2e 语料上 before/after 的
  build.ninja 逐字节比对,仅允许注释/变量重排的白名单差异)。

## 3. Part A — 抽象层补齐(实施拆分)

| 步 | 内容 | 改动文件 | 验收 |
|---|---|---|---|
| A1 | `CommandDialect` + `dialect_for`;`gnu` 实例 | 新 dialect.cppm | 单测:两实例拼写 |
| A2 | flags.cppm 骨架改用 caps+dialect+bmi_traits 拼写(-D/-I/-o/-std= 等经 dialect;分支逻辑不动) | flags.cppm | **ninja 零 diff 门** |
| A3 | ninja 规则模板参数化:object/link/archive/scan 命令模板出自 dialect;`deps=` 出自 `ninja_deps_mode`;rspfile 支持(gnu 不启用) | ninja_backend.cppm | 零 diff 门 + e2e |
| A4 | envOverrides 数据化:std 模块命令 / p1689 scan 从 `env …` 字符串前缀迁移到 argv+env;`shq` 收敛到平台感知 quoting | probe/gcc/clang/stdmod/p1689 | Linux/macOS/Windows CI 全绿 |
| A5 | provider 函数签名规范化(§1.3;`std_module_commands` 统一 vector 等) | gcc/clang/detect/stdmod | 纯重构,零 diff |
| A6 | `capabilities_for` 提升为 flags/prepare 的必经查询点,消灭消费侧残余 `is_clang/is_gcc` 内联(林 7 节清单逐个迁移;`is_musl_target` 保留——那是 libc 维度不是方言) | flags/prepare/build_program | grep 门:`src/build/` 内 `is_clang\|is_gcc` 零命中 |
| A7 | linkmodel 增加 `Mode::WindowsPE`(空模型:无 loader/rpath/payload;DLL 部署已有既有机制 plan.cppm:75-79) | linkmodel.cppm | 现有路径零 diff |

A2/A3 的**零 diff 门**是本 Part 的安全带:抽象错了会立刻显形,而不是三个月后在
Windows 上开盲盒。A 全程不改用户可见行为,可与 B 并行评审、必须先于 C 合入。

## 4. Part B — MinGW 入 xlings 生态

### 4.1 定位

MinGW-w64 **就是 GCC 后端**(`CompilerId::GCC`,triple `x86_64-w64-mingw32`,
libstdc++,gcm.cache/.gcm,GNU 方言)——它验证的是"平台变、方言不变"时抽象层是否
成立,同时给 Windows 用户一条**不依赖 Visual Studio** 的原生工具链(与 msvc@system
形成互补)。类比:musl-gcc 之于 Linux(自包含、静态友好),MinGW 之于 Windows。

### 4.2 上游与打包(xlings-res 双端)

- **上游**:winlibs 独立构建 **GCC 16.1.0 + MinGW-w64 14.0.0 (UCRT)** zip
  (github.com/brechtsanders/winlibs_mingw releases,2026-06-10 打包)。选它的理由:
  ① 与 mcpp 全线 gcc@16.1.0 floor 对齐(GCC 15 有模块模板实例化丢失问题,见
  remediation A2);② 自包含(自带 binutils/CRT/libstdc++);③ UCRT 运行时(与
  msvcrt 旧 ABI 切割,与 MSVC 侧 abi.cppm `mingw → msvcrt` 映射一致——实施时把
  该映射细化为 `ucrt`);④ zip 直发 GitHub releases,可按既有流程镜像。
- **打包流程**(完全复用 mcpp/llvm 的既有管线,见 [[release-publish-pipeline]]):
  上游 zip → 重命名为 xlings-res 约定 `mingw-gcc-<ver>-windows-x86_64.zip` →
  `gh release create` 到 `xlings-res/mingw-gcc`(新仓)+ `gtc release create/upload`
  GitCode 同名仓 → **双端逐资产 GET 核验(200+字节数)** → xim-pkgindex 新增
  `pkgs/m/mingw-gcc.lua`(windows 块,`XLINGS_RES` sentinel + sha256,格式抄
  mcpp.lua 0.0.88 后的 checked 条目)。
- **打包时必须验证**:zip 内 `include/c++/16.1.0/bits/std.cc` 存在(import std 依赖;
  winlibs 是完整 libstdc++,预期存在,但这是发布门禁不是假设)。

### 4.3 mcpp 侧改动(小,因为后端是现成的)

| 层 | 改动 | 位置 |
|---|---|---|
| spec/registry | 用户面名 `mingw`:`mcpp toolchain install mingw 16.1.0` / `default mingw@16.1.0`;`to_xim_package` 映射 xim 名 `mingw-gcc`;`frontend_candidates_for("mingw-gcc") → {"g++.exe","g++"}`;`available_toolchain_indexes` 增列(仅 Windows 显示) | registry.cppm:90-105,151,245 |
| 检测 | `-dumpmachine` 返回 `x86_64-w64-mingw32` → 走既有 GCC enrich;新增 `is_mingw_target(tc)`(triple 含 `-w64-mingw32`);abi.cppm libc 细化 `ucrt` | detect/model/abi |
| flags | Windows 上跳过 glibc payload/sysroot 流(`CLibMode::None`——MinGW 自带 CRT,同 musl 自包含逻辑);`-static-libgcc -static-libstdc++` 作为 Windows+GCC 默认(免 libstdc++-6.dll/libgcc_s DLL 伴随部署,静态化这两个运行时是 MinGW 分发惯例;`[build].linkage` 仍可覆盖) | flags.cppm(A 完成后是数据/分支各一处) |
| post-install | PE → 无 patchelf/specs 修复;`ensure_post_install_fixup` 的 `is_windows return`(post_install.cppm:413)已天然正确,补 `needsGccPostInstallFixup=false` | registry.cppm:186 |
| 运行 | exe 后缀/DLL 部署/`runtime_alias` 复用既有 Windows 机制;GCC 内建 P1689 扫描 + dyndep 原样工作 | 无改动预期 |

### 4.4 测试与 CI

- e2e:`97_mingw_toolchain.sh`(`# requires: mingw`,run_all.sh 探测 xim 装的
  g++.exe),覆盖 install→default→new→build→run→多模块→import std→静态产物
  (`ldd`/dumpbin 无 libstdc++ DLL 依赖)。
- ci-windows.yml 新步骤 "Toolchain: MinGW — install → build → run"(放 LLVM
  self-host rebuild **之前**,教训见 msvc-system-toolchain 记忆:该步会作废
  `$MCPP_SELF` 路径)。注意 runner 自带 MinGW g++ 在 PATH(run_all.sh:70 注释),
  测试必须显式用 xim 安装的那份,不吃 PATH。
- 首发范围:Windows 原生 x86_64。**Linux→Windows 交叉(mingw cross)不在本期**
  (登记为后续:registry 已有 `<triple>-g++` 交叉前端机制可复用)。

### 4.5 发布闭环

同 mcpp 0.0.88 流程:功能 PR(带版本号)→ 全 CI → 合入 → xim-pkgindex PR(引用
已镜像好的 xlings-res 资产)→ `xlings install`/`mcpp toolchain install mingw` 端到端
验证。注:mingw-gcc 包本身**不随 mcpp release 走**,是独立的 xlings-res 制品仓 +
索引条目(同 llvm/musl-gcc 模式),版本跟随 winlibs 上游。

## 5. Part C — MSVC 原生构建后端(cl.exe,只用系统安装)

前置:Part A 合入。0.0.88 已交付:发现/识别(msvc.cppm)、`CompilerId::MSVC` 分类
(detect)、`bmi_traits` ifc 分支、`msvc@system` 解析(prepare)、构建门(prepare.cppm:870-877,
**本 Part 最后一步删除它**)。

### 5.1 C1 — 环境模型(新:`msvc::build_env()`)

cl.exe/link.exe 依赖 vcvars 注入的环境。mcpp **不调用 vcvarsall.bat**(慢、shell 出参
不可靠),而是从检测结果直接合成(这正是 vswhere 时代微软推荐的做法):

- 新增 `find_windows_sdk()`:`HKLM\SOFTWARE\...\Windows Kits\Installed Roots` 或
  `C:\Program Files (x86)\Windows Kits\10\Include\<10.x.y.z>\` 取最高版本;产出
  `{sdkRoot, sdkVersion}`。SDK 缺失 = 硬错误 + 指引(装 VS workload 自带;检测层
  `toolchain default msvc` 时即预警,doctor 同步报告)。
- `build_env(inst, sdk)` →
  `INCLUDE = <tools>\include; <sdk>\Include\<v>\{ucrt,um,shared,winrt}`
  `LIB     = <tools>\lib\<arch>; <sdk>\Lib\<v>\{ucrt,um}\<arch>`
  `PATH   += <tools>\bin\Host<arch>\<arch>`(mspdb*.dll 等)
  → 存入 `Toolchain::envOverrides`(A4 机制),ninja 经 `$toolenv` 消费。
- fingerprint:INCLUDE/LIB 路径含 tools+SDK 版本号,连同 cl banner driverIdent
  (0.0.88 已入)→ SDK/工具集升级自然失效 BMI 缓存。

### 5.2 C2 — 方言与规则(A1/A3 的第二行数据)

`msvc` CommandDialect:`/std:c++latest`(std 模块要求;`[build].std="c++20"` 时映射
`/std:c++20` 并禁 import std)、`/D` `/I` `/c` `/Fo:` `/O2|/Od` `/Zi /FS`、
`always_flags = "/nologo /EHsc /utf-8"`、`obj_ext=".obj"`、`ninja_deps_mode="msvc"`
(`/showIncludes`,ninja 原生支持;**风险**:非英文 VS 的 showIncludes 前缀,须设
`msvc_deps_prefix` 或强制 `VSLANG=1033`,登记为实施细则)、`wants_rspfile_link=true`、
`Link::SeparateLinker`、archive 模板 `lib.exe /nologo /OUT:$out @rsp`。
CRT 线接 `[build].linkage`:默认 `/MD`,`static → /MT`(+`/DEBUG` profile 对应 `/MDd|/MTd`)。

### 5.3 C3 — std 模块 staging(stdmod 第三分支)

```
cl /nologo /std:c++latest /EHsc /c "<tools>\modules\std.ixx"
   /ifcOutput <stage>\ifc.cache\std.ifc /Fo:<stage>\std.obj
```
单命令(比 Clang 简单);消费侧 `/reference std=<...>\std.ifc`,链接侧把 `std.obj`
计入(同 GCC/Clang 的 std.o 既有机制)。`std.compat.ixx` 同目录同法(MSVC 有官方
std.compat)。`staged_std_bmi_path` 走 registry 分发(registry.cppm:276 加分支)。

### 5.4 C4 — 命名模块 .ifc 管线

- 编译:`cxx_module` 规则 msvc 形态 `/c /ifcOutput $bmi_out /Fo:$out`(bmi_traits
  `needsExplicitModuleOutput=true` 已就绪);消费:`/ifcSearchDir ifc.cache`
  (dialect 的 `bmi_search_flags`,对应 Clang 的 `-fprebuilt-module-path`)。
- 扫描:`cl /scanDependencies <ddi> /c <tu>` 输出 P1689 —— 即 2026-07-08 设计
  §3a 预留的第三个 p1689 驱动;dyndep 端 `DyndepOptions{ifc.cache,.ifc}` 零改动。
- 头文件依赖:`deps=msvc`(C2),GCC/Clang 的 `-MF` 路不动。

### 5.5 C5 — 链接/静态库后端

- `cxx_link`(msvc):`link.exe /nologo /OUT:$out @$out.rsp`(objs+libs 进 rsp;
  LIB 环境提供搜索路径,依赖包的 `[runtime] library_dirs` → `/LIBPATH:`)。
- `cxx_archive`:`lib.exe /nologo /OUT:$out @rsp`。
- `cxx_shared`:`link.exe /DLL /OUT:$out /IMPLIB:$lib`;plan.cppm:196 的
  `is_windows` 裸 import-lib 路径已兼容;DLL 部署复用 0.0.73 机制。
- linkmodel `Mode::WindowsPE`(A7):无 loader/rpath/payload,干净空模型。

### 5.6 C6/C7 — 测试、CI、删门

- 单测:dialect 拼写、build_env 合成(路径拼接纯函数,Linux 可测)、scanDependencies
  P1689 样例解析。
- e2e `98_msvc_native_build.sh`(`requires: msvc`):hello → 多模块 → import std →
  静态库 → 增量(touch 单 cppm 只重编该 TU,验 dyndep)→ gtest 依赖包(BMI 缓存)。
- ci-windows.yml:MSVC 步骤从"检测+门断言"升级为真实 build/run 矩阵(llvm + msvc
  + mingw 三工具链并列)。迭代仍走"临时分支只留 windows CI"模式(0.0.88 已验证省时)。
- **最后一个 commit**:删 prepare.cppm:870-877 构建门 + 更新 95 号 e2e(门断言改为
  构建成功断言)+ docs/03-toolchains.md 撤"not yet supported"注记。门在,C 的任何
  中间态都可安全合入 main;门删,即宣布支持。

### 5.7 风险与对策

| 风险 | 对策 |
|---|---|
| .ifc 与 cl 版本强耦合(补丁版都可能拒读) | driverIdent=banner 已入 fingerprint(0.0.88)→ 换版本自然全量重建 |
| 非英文 VS:/showIncludes 前缀本地化 | `VSLANG=1033` 入 envOverrides 或 ninja `msvc_deps_prefix`;e2e 断言 deps 生效 |
| 命令行长度(8191) | rspfile(C2 起链接/归档默认走 rsp) |
| `/std:c++latest` 语义漂移 | 项目 `[build].std` 显式时按映射表;std 模块 TU 恒 latest(微软官方要求) |
| SDK 与 VC tools 版本组合爆炸 | 只取"最新 VC tools + 最新 SDK"(与 vswhere -latest 同策略,0.0.88 已确立);组合进 fingerprint |
| runner 镜像 VS 布局变化(已遇 `\18\` 目录) | 三级发现 + CI 每日矩阵会先于用户炸;fallback years 表已含 "18"/"19" |

## 6. 排期与依赖(建议合入顺序)

```
A(抽象层,零行为变化,1-2 个 PR:A1-A5 / A6-A7)
│
├─→ B(MinGW:mcpp 侧 1 个 PR + xlings-res/mingw-gcc 资产仓 + 索引 PR)
│      └ 仅依赖 A 的少量部分(其实 B 大部分可与 A 并行,合入排 A 后避免 rebase 噪音)
│
└─→ C(MSVC 原生:C1+C2 → C3 → C4 → C5 → C6/C7,2-3 个 PR,门最后删)
       └ 硬依赖 A1/A3/A4(方言/规则/exec)
```

**B 先于 C** 的理由:① 便宜——后端现成,验证抽象的"平台维";② 用户价值即时——
Windows 无 VS 用户立刻有原生工具链;③ C 是大石头(新方言+env+链接器),让它踩着
A+B 两轮验证过的地基。每轮均沿用 0.0.88 流程:临时分支精简 CI 迭代 → 带版本号真
PR → 全 CI → 合入 → release → 生态闭环(publish-ecosystem 已自动化镜像+索引 PR;
MinGW 资产仓是额外的手动 gh+gtc 双端镜像 + GET 核验)。

## 7. 非目标(本轮明确不做)

- Linux→Windows MinGW 交叉编译(机制已预留:`<triple>-g++` 交叉前端,后续独立设计)。
- clang-cl(MSVC 方言的 Clang 驱动——现有 MSVC-ABI Clang 路径已覆盖该生态位)。
- `mcpp pack` 的 PE 支持(pack/pipeline.cppm 是 ELF/patchelf 专属,独立议题)。
- MSYS2/Cygwin 环境适配;i686 32 位 MinGW。
- xvm 多版本 MSVC 并存选择(恒"最新 VC tools",pin-verify 已够用)。
