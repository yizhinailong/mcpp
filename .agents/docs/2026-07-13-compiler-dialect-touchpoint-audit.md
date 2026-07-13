# 编译器方言触点审计(0.0.88 基线)

> 2026-07-13 · 支撑文档:`2026-07-13-toolchain-backend-abstraction-msvc-mingw-design.md`
> 目的:抽象层(Part A)实施时的逐项迁移清单。基线 commit:a1f4429(0.0.88)。

分支机制按"从最规范到最散落"排序:`CompilerId` switch(model/provider/abi)→
`capabilities_for(tc)`(provider,仅 flags.cppm:128 一个消费者)→ `bmi_traits(tc)` 数据表 →
自由谓词 `is_clang/is_gcc/is_musl_target/is_msvc_target` → `targetTriple.find("…")` 子串
→ `platform::is_windows` constexpr(平台维,与方言维交织)。

## 1. flags.cppm `compute_flags` — 密度最高(≈25 分支)

- :128 `capabilities_for`(唯一消费点);:139 `derive_c_compiler`(g++→gcc 词干改写)
- :165-166 `resolve_clang_driver` + `resolve_link_model`;:172 `isClangWithCfg`
- :177-209 三路 sysroot/payload:Clang+cfg → `--no-default-config -nostdinc++` + libc++
  includes + `kLinkDriverFlags`(linkmodel.cppm:118);否则 CLibMode → `--sysroot` 或
  payload `-B/-L`;:188 macOS `-mmacosx-version-min`
- :212-224 binutils `-B`:仅非 musl 的 GCC;:227 `archive_tool`
- :233-236 musl `-Og` ICE workaround;:253 `-fmodules` keyed on `stdlib_id=="libstdc++"`
- :255-262 `is_clang` → `-fmodule-file=std=` / `std.compat=`
- :263-277 `bmi_traits.needsPrebuiltModulePath` → `-fprebuilt-module-path`
- :278-284 `-std=c++23` / `-D` / `-I` / `-o` 全 GNU 拼写(无 /D /I /Fo 路)
- :289 `-static`;:290 `-static-libstdc++`(`!isClang && !is_windows`)
- :292-306 `-L` + `-Wl,-rpath,`;:315-316 payload C 运行时;:322-323 `is_windows` ld=裸用户 flags
- :324-429 macOS 专属链接路(`-lc++`、`-Wl,-load_hidden`、`-nostdlib++`、`-fuse-ld=lld`、`-isysroot`)
- :430-440 Linux 链接路;:62-120 `atomic_link_flag`(GNU-ld `--push-state --as-needed -latomic`)
- :76-86 `escape_path` ninja 转义混入 flag 字符串

## 2. plan.cppm / ninja_backend.cppm — 命令组装

- plan.cppm:128-132 对象名恒 `.o`/`.m.o`(无 .obj);:162-175 platform lib/exe 扩展;
  :196-212 shared 链接 flags(is_windows 裸 import-lib;GNU `-L/-l/-Wl,-rpath`)
- ninja_backend.cppm:106-115 soname(`__APPLE__`/`__linux__`);:261-263 扫描器选择
  (`is_gcc` 内建 P1689 vs clang-scan-deps);:264 bmi_traits
- :304-312/:387-393 `cp_bmi`/`runtime_alias`:is_windows → PowerShell vs cp/ln
- :334-353 `cxx_module`(needsExplicitModuleOutput → `-fmodule-output`;is_windows 跳
  POSIX restat wrapper);:359-373 `cxx_object`/`c_object` `-c $in -o $out`
- :375-377 `cxx_link` `$cxx $in -o $out`(driver 直链);:379-381 `cxx_archive` 字面 `ar rcs`
  (provider.cppm:96 声明了 lib.exe 但无发射方);:383-385 `cxx_shared`
- :395-428 `cxx_scan`/`cxx_collect`(GCC `-fdeps-*`;Clang `$scan_deps -format=p1689`;
  is_windows 包 `cmd /c`);**无 rspfile**;:815 `capture_exec(nargv,nenv)` 干净 argv

## 3. 模块/BMI 管线

- model.cppm:56-118 `BmiTraits`(gcm/pcm/ifc 三行数据,ifc 0.0.88 已置)
- stdmod.cppm:178-274 `ensure_built` 按 `is_clang` 双分支(GCC 1 命令 / Clang 2 命令
  + std.compat 仅 Clang);:203-216 sysroot flags 出自 linkmodel
- p1689.cppm:318-396 `scan_file` 纯 GCC flags(`--sysroot` only,:338-341);
  scanner.cppm:566-600 `scan_packages_p1689` GCC-only
- dyndep.cppm:36-39 `DyndepOptions{bmiDir,bmiExt}` 已参数化(好缝)
- bmi_cache:CacheKey 的 bmiDirName/manifestTag 由 prepare.cppm:2747-2748 注入

## 4. gcc.cppm / clang.cppm 导出面(事实后端接口;签名不对齐处加粗)

GCC:matches_version_output(**1 参**) / parse_version / find_std_module_source /
enrich_toolchain(**无 envPrefix**) / find_binutils_bin / std_bmi_path /
staged_std_bmi_path / **std_module_build_command(单命令)**
Clang:matches_version_output(**2 参**) / find_libcxx_std_module_source /
enrich_toolchain(**带 envPrefix**) / std_bmi_path / staged_std_bmi_path /
**std_module_build_commands(vector)** / std.compat 三件套(**仅 Clang**)/
archive_tool(**仅 Clang**)/ find_scan_deps(**仅 Clang**);
clang.cppm:182-213 `_WIN32` cmd.exe 引号 workaround(exec 层债的现场证据)

## 5. linkmodel / abi / provider / fingerprint

- linkmodel.cppm:228-229 `clangDriver/clangWithCfg`;:61-95 compile/link_flags
  (Clang isystem+rpath+loader;GCC idirafter+-B/-L);:101-120 ClangDriverModel;
  :139-188 loader 解析(全 ELF,无 PE)
- abi.cppm:67-96 triple 子串 + CompilerId(:76 **mingw→msvcrt 已在**;:93 msvc cxxAbi)
- provider.cppm:26-107 capabilities_for(设计为中心查询点,未兑现)
- fingerprint.cppm:90 十字段,编译器无关(读 tc 字段)

## 6. prepare.cppm 及其余

- prepare.cppm:60-85 cfgpred(:67 **mingw→windows 已识别**);:870-877 MSVC 构建门;
  :882-891 musl→static;:2670-2674 is_clang→scan-deps;:2738-2766 bmi_traits→CacheKey/命名;
  :2902-2906 resolution.json abi
- build_program.cppm:119-190 `host_base_flags` 完整 is_clang/GCC 双路(GNU flags)
- pack/pipeline.cppm:29-105 triple.find("-musl")(ELF/patchelf 专属)
- registry.cppm:90-105 frontend_candidates;:107/:253 derive_c_compiler;:257 archive_tool;
  :276 staged_std_bmi_path;:241 is_system_toolchain
- detect.cppm:47-51 cl 词干短路;:67-107 版本输出分类;:90-101 `_WIN32` effective-triple

## 7. exec/env 层(对 cl.exe 全不成立的三件事)

1. `compiler_env_prefix`(probe.cppm:229)= `env LD_LIBRARY_PATH=… ` **shell 字符串前缀**
   拼进 std 模块命令(gcc.cppm:124 / clang.cppm:220-300);干净 argv+env 机制其实已有
   (execute.cppm:337-344)只是这条路没用。
2. `shq` 单引号 POSIX quoting(xlings.cppm:533、p1689.cppm:305)对 `/flag` 与
   `C:\Program Files\…` 皆破。
3. 无响应文件;链接长命令顶 Windows 8191 上限。

## 8. 迁移总表(→ 设计文档 §2 的后端接口)

| 触点 | 现机制 | 后端须提供 |
|---|---|---|
| 分类 | matches_version_output + cl 词干 | matches/detect → CompilerId |
| stdlib id / 能力 | capabilities_for(欠消费) | 提升为必经查询点 |
| BMI 目录/扩展/输出旗标 | BmiTraits(保留) | bmi_traits() |
| -std/-D/-I/-o/-c/opt/debug/objExt | flags+ninja 硬编码 GNU | **CommandDialect(新)** |
| std 模块构建 | 1 cmd vs vector 不对齐 | std_module_commands() → vector 统一 |
| 扫描 | is_gcc 内建 / scan-deps | scan_driver()(P1689 通用格式,+/scanDependencies) |
| 归档 | 字面 `ar rcs` | dialect.archive_cmd_template(lib.exe /OUT:) |
| 链接形态 | driver 直链唯一 | dialect.Link{Driver,SeparateLinker} |
| C 库模型 | linkmodel(全 ELF) | + Mode::WindowsPE 空模型 |
| env | POSIX env 前缀字符串 | Toolchain::envOverrides(argv+env) |
| quoting/rsp | shq 单引号;无 rsp | 平台感知 quoting;rspfile(msvc 启用) |
| post-install | ELF patchelf;is_windows return | PE = no-op(已正确) |
| 构建门 | prepare.cppm:870 | C 完成后删除 |
