# Contributing / 贡献指南

## English

Use Zig 0.17.0. Zig compiles all C++ sources and links the native binaries. Native communication requires Linux GNU headers and runtime libraries for the target; install GNU C++ development files or supply `-Dsysroot`. Regeneration requires Python 3.10+.

`build.zig.zon` is the single source of the C++ SDK URL and package hash. Zig resolves one cached SDK directory and passes it to compilation, generation and verification. No separate Git checkout or fetch script is used. Python runs maintenance scripts only. Supplemental RPC metadata is maintained in `scripts/protocol_extensions.json`.

### Source layout

- `src/*.zig`: public Zig modules and unit tests.
- `src/cpp/`: handwritten bridge code; `src/cpp/generated/`: generated bridge code.
- `include/`: public C ABI declarations.
- `examples/`: runnable programs with Chinese comments.
- `docs/`: usage and API documentation.

Keep C++ object layouts behind the C ABI. Document ownership and callback lifetimes. Files marked `Generated` must be changed through their generator; commit the resulting files.

Generators use UTF-8 and sort filesystem paths by their POSIX strings so Windows and Linux produce identical output. CI checks generated files on both platforms.

Use current Zig 0.17 APIs in handwritten code and generator templates. Some deprecated aliases still compile, so check the installed standard library's deprecation notes as well as compilation. Emit current builtin names directly instead of relying on `zig fmt` to migrate generated code.

### Build and test

```sh
zig build test check examples -Dnative=false
zig fmt --check build.zig build.zig.zon src tests examples scripts

# Linux native checks
zig build test check examples test-native -j2
zig build run-rpc_loopback -j2
zig build test-crc -j2
```

Run checks appropriate to the change. `tests/compile/` checks public API compilation, `tests/integration/` exercises native communication, and `tests/reference/` holds protocol references. To check downstream use, run `zig build run` in `tests/package_consumer/`. CI also checks installed runtime library paths.

`scripts/gnu_cxx.zig` configures target GNU headers and libraries for the bridge, native tests, and CRC reference. `translate-c` handles C declarations separately. To compile all native tests without executing target binaries:

```sh
zig build check-native -Dtarget=aarch64-linux-gnu.2.31 -Dsysroot=/path/to/arm64-sysroot -Dgcc-version=9 -j2
```

The pinned CycloneDDS CDR implementation uses unaligned 64-bit accesses on the supported Linux architectures. C++ compilation disables Clang's alignment sanitizer for compatibility; other sanitizer checks and Zig runtime checks retain their normal optimization-mode settings.

`test-native` includes the native CRC reference. `test-crc` can run it independently: source generation, C++ compilation and output verification are dependencies in one Zig build graph. It shares `-Dsysroot` and `-Dgcc-version` with the bridge and never starts a recursive build. Native checks execute on the target platform.

### Code generation

```sh
zig build check-upstream -Dsdk-tools -Dnative=false
zig build regenerate -Dsdk-tools -Dnative=false
```

`check-upstream` checks both generators, coverage, the independent source inventory and CRC layouts. `regenerate` updates bindings, API docs and the coverage report in sequence; review the resulting changes. Edit generator templates in `scripts/`, not generated files. Upgrade the SDK only in `build.zig.zon`, then regenerate and review the compatibility implementations in `src/cpp/`.

`-Dsdk-tools` enables SDK sources for maintenance even when native compilation is disabled. Ordinary `-Dnative=false` consumers do not fetch the C++ SDK. `-Dpython=/path/to/python` selects the maintenance interpreter. Every script receives an explicit `--sdk` directory from Zig. `-Dsdk-root=/path/to/sdk` overrides that directory for all consumers; it does not fetch another copy.

Coverage schema v3 distinguishes C++ SDK methods (307 methods plus 26 initializers), six supplemental protocol methods, convenience aliases, 72 DDS messages, constants, wrapper adaptations, and the library's Zig utilities. Protocol extensions are checked against local metadata and their native adapters. The report records the dependency declaration and a fingerprint of the actual SDK headers, so verification also works with source archives without `.git`. A local override is not package-hash-verified; changed headers are detected against the stored fingerprint.

### Packaging

Release source archives containing the generated bindings and the complete third-party `NOTICE`. When updating the SDK, refresh its license texts in `NOTICE`; retain copyright notices and consolidate identical terms. Update the explicit `scripts/` and `tests/` file list in `build.zig.zon` when adding files. Package directory entries include all descendants and do not honor `.gitignore`. Before release, test the archive with `zig fetch --save=unitree_sdk2 <archive>` in a separate consumer project, then build and run it.

## 简体中文

使用 Zig 0.17.0，所有 C++ 源码和原生二进制均由 Zig 编译、链接。原生通信需要目标 Linux GNU 的头文件与运行库；安装 GNU C++ 开发文件，或通过 `-Dsysroot` 指定。重新生成代码需要 Python 3.10+。

`build.zig.zon` 是 C++ SDK 下载地址和包哈希的唯一来源。Zig 解析出同一个缓存目录，交给编译、生成和检查流程；不再单独维护 Git 检出或拉取脚本。Python 只运行维护脚本。补充 RPC 协议数据保存在 `scripts/protocol_extensions.json`。

### 源码位置

- `src/*.zig`：公开 Zig 模块及单元测试。
- `src/cpp/`：手写桥接；`src/cpp/generated/`：生成桥接。
- `include/`：公开 C ABI 声明。
- `examples/`：可运行示例，注释使用中文。
- `docs/`：使用方法与 API 文档。

C ABI 不暴露 C++ 对象布局，接口需说明所有权和回调寿命。带有 `Generated` 标记的文件通过对应生成器修改，并提交生成结果。

生成器使用 UTF-8，并按 POSIX 路径字符串排序，确保 Windows 和 Linux 输出一致；CI 在两个平台核对生成文件。

手写代码和生成器模板均使用 Zig 0.17 当前 API。部分弃用别名仍能编译，应同时检查本机标准库的弃用说明。生成器直接输出当前 builtin 名称，不依赖 `zig fmt` 迁移旧语法。

### 构建与测试

```sh
zig build test check examples -Dnative=false
zig fmt --check build.zig build.zig.zon src tests examples scripts

# Linux 原生检查
zig build test check examples test-native -j2
zig build run-rpc_loopback -j2
zig build test-crc -j2
```

执行与改动相关的检查。`tests/compile/` 检查公开 API 编译，`tests/integration/` 检查原生通信，`tests/reference/` 保存协议参考。在 `tests/package_consumer/` 运行 `zig build run` 检查下游依赖接入；CI 还会检查安装后的运行库路径。

`scripts/gnu_cxx.zig` 为桥接、原生测试和 CRC 对照统一配置目标 GNU 头文件与运行库；`translate-c` 单独处理 C 声明。只编译所有原生测试、暂不执行目标程序时：

```sh
zig build check-native -Dtarget=aarch64-linux-gnu.2.31 -Dsysroot=/目标/arm64-sysroot -Dgcc-version=9 -j2
```

固定版本 CycloneDDS 的 CDR 实现在受支持的 Linux 架构上使用非对齐的 64 位读写。C++ 编译为此关闭 Clang 对齐检查，其他 sanitizer 检查和 Zig 运行时检查仍按优化模式配置。

`test-native` 已包含原生 CRC 对照，也可单独运行 `test-crc`。源码生成、C++ 编译和输出核验都在同一个 Zig 构建图中，共用 `-Dsysroot` 和 `-Dgcc-version`，不会递归启动子构建。原生运行检查需在目标平台执行。

### 代码生成

```sh
zig build check-upstream -Dsdk-tools -Dnative=false
zig build regenerate -Dsdk-tools -Dnative=false
```

`check-upstream` 核对两个生成器、覆盖清单、独立源码清单和 CRC 布局。`regenerate` 顺序更新绑定、API 文档和覆盖清单，执行后检查差异。修改 `scripts/` 下的生成器模板，不手改生成文件。升级 SDK 时只修改 `build.zig.zon` 中的版本和哈希，再重新生成并复核 `src/cpp/` 中的兼容实现。

`-Dsdk-tools` 让关闭原生编译的维护流程也能使用 SDK 源码；普通 `-Dnative=false` 使用方不会下载 C++ SDK。`-Dpython=/path/to/python` 可选择维护脚本的解释器。所有脚本均由 Zig 显式传入 `--sdk` 目录。`-Dsdk-root=/path/to/sdk` 统一覆盖所有流程的 SDK 目录，不额外下载。

覆盖清单 v3 分别记录 C++ SDK 方法（307 个方法及 26 个初始化入口）、6 个协议扩展方法、便利别名、72 种 DDS 消息、常量、包装层适配和本库的 Zig 工具。协议扩展按本地数据及原生适配实现核验。清单记录依赖声明及实际 SDK 头文件指纹，因此没有 `.git` 的源码归档也能核验。本地路径覆盖不经过包哈希校验；头文件变化会在与已存指纹比较时被发现。

### 打包

源码归档需包含生成绑定及完整的第三方声明 `NOTICE`。升级 SDK 时同步更新 `NOTICE` 中的许可证原文，保留版权声明，并合并相同条款。新增工具或测试文件时，更新 `build.zig.zon` 中逐文件列出的 `scripts/`、`tests/` 路径。目录路径会递归收录文件，不受 `.gitignore` 过滤。发布前，在独立使用方项目执行 `zig fetch --save=unitree_sdk2 <归档路径>`，再构建并运行。
