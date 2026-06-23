# 原生 aarch64 musl-gcc 用 musl 1.2.5 重建(canadian-cross)— 复现指南

**日期**: 2026-06-23
**目的**: 重建在 aarch64 Termux 上本地编译用的 **原生** musl-gcc 工具链
(`musl-gcc-15.1.0-linux-aarch64`),使其链接 **musl 1.2.5**(而非 1.2.6),
避开 Android 13 seccomp 对 `set_robust_list` 的 SIGSYS。
**背景与根因**: 见 [2026-06-23-termux-android-adaptation.md](./2026-06-23-termux-android-adaptation.md) §6。

> 一句话:musl ≥1.2.6 启动期注册主线程 robust list(`set_robust_list`),
> Android 13 app 沙盒 seccomp 把它 TRAP 成 SIGSYS → 整个 1.2.6 工具链在 Termux 上
> 启动即 "Bad system call"。1.2.5 不调该 syscall。必须用 1.2.5 **重建**(换 libc 文件
> 无用,musl 已静态链进每个 gcc/g++/as 二进制)。

---

## 0. 为什么是 canadian-cross

原生包的 gcc/g++ 二进制要 **跑在 aarch64**(host=target=aarch64)。三种构建法:
- A. 真 aarch64 机器:直接 musl-cross-make。
- B. qemu-aarch64 模拟构建:gcc bootstrap 模拟下 10+ 小时。
- **C. canadian-cross(本指南)**:本机 x86_64 速度,用现成的 x86_64-host aarch64
  交叉工具链去编译 host=aarch64 的 gcc/g++。本次实测 build 全程 ~15 分钟(8 核)。

musl-cross-make 通过 `NATIVE = 1`(`HOST = $(TARGET)`)支持 canadian/native 构建:
它用 **PATH 里已有的 `<target>-gcc` 交叉编译器** 来编 host=target 的工具链。

---

## 1. 前置条件

| 依赖 | 说明 |
|---|---|
| 交叉工具链 `aarch64-linux-musl-gcc`(**musl 1.2.5**) | `~/.mcpp/.../xpkgs/xim-x-aarch64-linux-musl-gcc/15.1.0/bin`;**必须在 PATH**(NATIVE 构建用它编 host 部分) |
| 本机 `gcc`/`g++`/`make` | 编 build 端工具 |
| musl-cross-make + 源码 | `~/.xlings/.../xim-x-musl-cross-make/0.0.1/musl-cross-make`;已含 musl-1.2.5、gcc-15.1.0、binutils-2.44、gmp/mpfr/mpc 源 |
| `setarch` | 关 ASLR(绕 gawk PMA segfault,见 §3.2) |
| `qemu-aarch64` + binfmt | 本机验证产物(strace / 跑 hello) |

确认交叉工具链是 1.2.5(关键):
```bash
qemu-aarch64 <cross>/aarch64-linux-musl/lib/libc.so 2>&1 | grep -i version   # → Version 1.2.5
# 或:用它编个 hello,strace 应只有 set_tid_address、无 set_robust_list
```

---

## 2. 构建步骤(最终可用版)

```bash
# 1) 复制一份 musl-cross-make(别污染已安装的)
cp -a ~/.xlings/data/xpkgs/xim-x-musl-cross-make/0.0.1/musl-cross-make mcm-native
cd mcm-native

# 2) 写 config.mak(最终可用,已剔除所有踩坑项)
cat > config.mak <<'EOF'
GCC_VER = 15.1.0
MUSL_VER = 1.2.5
TARGET = aarch64-linux-musl
NATIVE = 1
COMMON_CONFIG += CFLAGS="-g0 -Os" CXXFLAGS="-g0 -Os"
COMMON_CONFIG += LDFLAGS="-static --static -s"
COMMON_CONFIG += --disable-nls
GCC_CONFIG += --enable-languages=c,c++ --disable-multilib
EOF

# 3) 交叉工具链入 PATH + 关 ASLR 构建
export PATH="$HOME/.mcpp/registry/data/xpkgs/xim-x-aarch64-linux-musl-gcc/15.1.0/bin:$PATH"
which aarch64-linux-musl-gcc        # 必须能找到
setarch $(uname -m) -R make -j8
setarch $(uname -m) -R make install OUTPUT="$(pwd)/output-native"
```

产物在 `output-native/`(`bin aarch64-linux-musl include lib libexec share`)。

### config.mak 关键项说明
- `NATIVE = 1`：触发 HOST=TARGET 的 canadian-cross。
- `MUSL_VER = 1.2.5`：**核心**。不写则吃 musl-cross-make 默认(可能漂到 1.2.6)。
  → 已在 `xim-pkgindex/pkgs/m/musl-cross-make.lua` 的 config.mak 模板里 **显式 pin**,
  根治版本漂移。
- `LDFLAGS = "-static --static -s"`:产物静态(免 loader)+ 链接期 strip。
  双 `--static` 穿透 binutils libtool(单 `-static` 会被丢成 dynamic)。
- `CFLAGS/CXXFLAGS = "-g0 -Os"`:去调试信息 + 优化体积。
- **不要** `--disable-decimal-float`(见 §3.3)、不要 `--disable-libquadmath`。

---

## 3. 踩坑与修复(按出现顺序)

### 3.1 `cannot find a C compiler`(NATIVE 直接进 native 阶段)
NATIVE=1 **不自动建 stage-1 交叉工具链**,它期望 `aarch64-linux-musl-gcc` 已在 PATH。
→ **把交叉工具链 bin 加进 PATH** 再 make。

### 3.2 ⭐ gawk PMA segfault(系统 gawk 5.2.1)
```
gawk: opt-functions.awk:62: fatal error: internal error: segfault
make[3]: *** [options-urls.cc] Error 134
```
GNU Awk 5.2.x 的 **PMA(persistent memory allocator, "Avon")** 在某些 ASLR 地址下
segfault(地址相关,非确定性)。
→ **全程 `setarch $(uname -m) -R make ...` 关 ASLR**,稳定绕过。

### 3.3 gawk 崩溃残留的损坏 `options-urls.cc`
即使加了 `setarch -R` 续构建,仍报:
```
options-urls.cc:3362:30: error: expected '}' at end of input
```
是 **第一次 gawk segfault 留下的截断 `options-urls.cc`**,make 见文件已存在不重生成,
直接编译损坏文件。
→ 删掉让其重生成:
```bash
find build -name options-urls.cc -delete
find build -name options-urls.o  -delete
```

### 3.4 `--disable-decimal-float` 炸 libgcc
```
No rule to make target '.../libdecnumber/no/decimal32.c', needed by 'decimal32.o'
make[3]: *** [all-target-libgcc] Error 2
```
`--disable-decimal-float` 把 decimal 格式设成 `no`,但 libgcc 仍引用 `libdecnumber/no/decimal32.c`
(不存在)。已工作的交叉工具链没用这个 flag。
→ **从 GCC_CONFIG 删掉 `--disable-decimal-float`**(改了 configure 项 → 需 `rm -rf obj_gcc` 重配 gcc)。

### 3.5 默认 sysroot 找不到头文件(native 布局差异)
产物 g++ 编译报 `fatal error: stdio.h: No such file or directory`。
原因:NATIVE 构建是 **native 布局**——系统头在 `<prefix>/include`、库在 `<prefix>/lib`,
gcc sysroot=`<prefix>`;但 gcc 默认在 `<sysroot>/usr/include` 找系统头。
(旧交叉包是 `<prefix>/aarch64-linux-musl/include` + sysroot=该 triple 子目录,所以能找到。)
→ **加 usr/ 相对软链**,让默认 sysroot 解析到位(无需重建):
```bash
cd output-native
mkdir -p usr
ln -sfn ../include usr/include
ln -sfn ../lib     usr/lib
```
(gcc 对不存在的目录会静默跳过,所以 `-E -v` 的搜索列表里看不到 usr/include,但建好后能用。)

---

## 4. 验证(打包前必做)

```bash
OUT=output-native
# ★ 关键:strace 必须 0 次 set_robust_list(否则 Android 13 仍 SIGSYS)
qemu-aarch64 -strace $OUT/bin/aarch64-linux-musl-g++ --version 2>&1 | grep -c set_robust_list   # → 0
# 二进制类型 + musl 版本
file $OUT/bin/aarch64-linux-musl-g++          # ARM aarch64, statically linked, stripped
# C + C++ 默认 sysroot 编译 + qemu 跑
printf '#include <stdio.h>\nint main(){puts("c-ok");}\n'      > /tmp/t.c
printf '#include <iostream>\nint main(){std::cout<<"cpp-ok\\n";}\n' > /tmp/t.cpp
qemu-aarch64 $OUT/bin/aarch64-linux-musl-gcc /tmp/t.c   -o /tmp/tc  -static && qemu-aarch64 /tmp/tc
qemu-aarch64 $OUT/bin/aarch64-linux-musl-g++ /tmp/t.cpp -o /tmp/tcpp -static && qemu-aarch64 /tmp/tcpp
```

本次实测:`set_robust_list` 0 次;`g++ (GCC) 15.1.0`;C/C++ 均 OK。

---

## 5. 打包(套用 §5 of analysis 的 Termux 修复)

构建已用 `-g0 -Os -s` 内建 strip(无需再 strip)。还需 **dereference hardlink**
(Android `link()` 失败,见 analysis §5):

```bash
cd mcm-native
cp -a output-native musl-gcc-15.1.0-linux-aarch64     # 规范顶层目录名
tar --hard-dereference -czf musl-gcc-15.1.0-linux-aarch64.tar.gz musl-gcc-15.1.0-linux-aarch64
# 校验:0 个 hardlink('h'),符号链接全相对(无 /tmp 构建路径绝对软链)
tar tzvf musl-gcc-15.1.0-linux-aarch64.tar.gz | awk '{print substr($1,1,1)}' | sort | uniq -c
tar tzvf musl-gcc-15.1.0-linux-aarch64.tar.gz | awk '$1~/^l/' | grep -c "/tmp/"   # → 0
```

**本次产物**:`musl-gcc-15.1.0-linux-aarch64.tar.gz`
- 压缩 **80 MB** / 解压 **194 MB**(对比旧坏包 790MB / 1.86GB)。
- sha256 `2277f07cd4fff2111f37182ad49dc331ccc13b6aef7dde31c704bf7dbdb0f326`。
- musl 1.2.5、静态、0 hardlink、usr/ sysroot 软链、14 个相对符号链接。

---

## 6. 上传 xlings-res(GLOBAL + CN)

`musl-gcc.lua` **无 sha pin** → 资产透明替换,免改索引。

```bash
# GitHub(GLOBAL)— 可覆盖
gh release upload 15.1.0 -R xlings-res/musl-gcc musl-gcc-15.1.0-linux-aarch64.tar.gz --clobber

# GitCode(CN)— 同名资产 gtc 无法覆盖(obs_callback 400),需先删旧再传
#   (gtc 无 delete 子命令;用 GitCode 网页/API 删 musl-gcc-15.1.0-linux-aarch64.tar.gz)
gtc release upload xlings-res/musl-gcc musl-gcc-15.1.0-linux-aarch64.tar.gz --tag 15.1.0
# 验证两端字节一致:
curl -sL <github|gitcode 同名 url> | sha256sum   # 应 = 2277f07c...
```

---

## 7. 根治(已落地,防复发)

`xim-pkgindex/pkgs/m/musl-cross-make.lua` 的 config.mak 模板已 **显式 pin `MUSL_VER = 1.2.5`**
(commit `fix(musl-cross-make): pin MUSL_VER = 1.2.5 ...`),所有后续构建(交叉 + 原生)
锁定 1.2.5,不再漂到 1.2.6+。**今后任何"在 Android 上运行"的 musl-static 产物都必须 ≤1.2.5,
或 patch 掉 musl 启动期的 `set_robust_list`**(robust mutex 极少用)。

---

## 8. Termux 端最终验证

```bash
rm -rf ~/.mcpp                       # 清掉装坏的旧 1.2.6 工具链
cd hello && mcpp build               # 装新 80MB 包 → 解压(无 hardlink)→ g++ 不再 SIGSYS → 编译通过
```
```
