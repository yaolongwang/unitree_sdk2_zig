# 使用指南

[English](usage.md) | **简体中文** · [README](../README.zh-CN.md)

调用路径为 Zig → C ABI 桥接 → 官方 C++ SDK → DDS。协议扩展使用同一套原生 RPC 客户端，应用直接使用随库提供的 Zig 接口。

## 环境要求

| 环境                         | 支持情况                                                              |
| ---------------------------- | --------------------------------------------------------------------- |
| Linux GNU，x86_64 或 aarch64 | 原生 SDK 通信及完整 Zig API                                           |
| Windows 或 macOS             | 使用 `-Dnative=false` 构建纯数据层                                    |
| Zig                          | **0.17.0**                                                            |
| 原生构建依赖                 | 目标系统的 GNU C++ 头文件、`libstdc++` 和 `libgcc`；编译器由 Zig 提供 |

应用代码完全使用 Zig，通过 `@import("unitree_sdk2")` 调用本库。官方 `translate-c` 包负责导入 C 头文件，Zig 构建 API 负责编译 C++17 桥接并链接 SDK。构建过程会自动下载固定版本的 [Unitree SDK2](https://github.com/unitreerobotics/unitree_sdk2) 和 [translate-c](https://codeberg.org/ziglang/translate-c/)。`translate-c` 只在构建期运行，部署所需的原生运行库见下文；构建不依赖外部 C++ 编译器、CMake、Eigen 或 Boost。

原生桥接使用 GNU C++ 头文件和运行库，以匹配官方 SDK。本机 Linux 构建默认从 `/` 查找，需安装发行版的 GNU C++ 开发包。`-Dgcc-version` 可选择具体版本；默认选择 `usr/lib/gcc/<triple>/` 下最新的版本。支持 Debian/Ubuntu 和 Arch Linux 常用的 `<arch>-linux-gnu`、`<arch>-pc-linux-gnu` 目录布局。

交叉编译时，提供包含 `usr/include/c++/<版本>`、架构专属 C++ 和 libc 头文件、`libstdc++.so.6`、`libgcc_s.so.1`，以及 `usr/lib/gcc/<triple>/<版本>/{libgcc.a,libgcc_eh.a}` 的目标 sysroot。sysroot 使用绝对路径，作为包依赖传入时也一样。例如目标机器人为 ARM64、glibc 2.31，并使用 GCC 9 运行库文件：

```sh
zig build -Dtarget=aarch64-linux-gnu.2.31 -Dsysroot=/path/to/arm64-sysroot -Dgcc-version=9 -j2
```

该命令也可在 Windows 或 macOS 上执行，生成的程序在 Linux 上运行。在 PowerShell 中，应给含路径或带点版本号的 `-D...` 参数加引号。目标 glibc 版本应匹配部署环境的基线。`-Dbridge=/绝对路径/libunitree_sdk2_zig.so` 可复用已有桥接库；编译 C++ 测试仍需要 GNU 开发文件。

## 快速开始

在 Linux 上，从仓库根目录执行：

```sh
zig build -j2
zig build run-rpc_loopback -j2
```

回环示例在本机运行 RPC 服务端和客户端，无需机器人。已有固定版本 SDK 源码时，可直接指定路径：

```sh
zig build -Dsdk-root=/path/to/unitree_sdk2 -j2
```

SDK 的版本和包哈希统一定义在 `build.zig.zon`；构建、生成和覆盖检查共用 Zig 依赖缓存。`sdk-root` 是所有流程的本地路径覆盖，必须包含 `include/`、`lib/<arch>/` 和 `thirdparty/`，不触发下载。在 Windows、macOS 或 Linux 上构建纯数据层：

```sh
zig build test check examples -Dnative=false
zig build run-low_command -Dnative=false
```

第二条命令仅在本地构造低层命令并计算 CRC。

## 作为依赖使用

使用发布的源码归档时，在应用目录执行 `zig fetch --save=unitree_sdk2 <发布归档URL>`，由 Zig 自动将 URL 和内容哈希写入应用的 `build.zig.zon`。本库导出的模块名为 `unitree_sdk2`。

本地开发时，也可以将本仓库放在应用目录旁，在应用的 `build.zig.zon` 中添加：

```zig
.dependencies = .{
    .unitree_sdk2 = .{ .path = "../unitree_sdk2_zig" },
},
```

在应用的 `build.zig` 中，为依赖传入相同的目标平台和优化模式：

```zig
const sdk = b.dependency("unitree_sdk2", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("unitree_sdk2", sdk.module("unitree_sdk2"));

// 安装桥接库、DDS 运行库和第三方许可证文件。
@import("unitree_sdk2").installRuntime(b, sdk);
```

纯数据层应用应传入 `.native = false`，并省略 `installRuntime`。完整的依赖使用示例见 [tests/package_consumer](../tests/package_consumer)。

交叉编译依赖时，在 `b.dependency` 中随相同的 `.target` 传入 `.sysroot = "/目标/sysroot/绝对路径"`，并按需传入 `.@"gcc-version" = "9"`。下游示例已提供对应的 `-Dsysroot` 和 `-Dgcc-version` 选项。

原生安装包含 `bin/`、`lib/` 和 `share/licenses/unitree_sdk2/`。部署时保留这些目录的相对位置；可执行文件从 `../lib` 查找运行库。GNU C++ 运行库由目标系统提供。自定义打包可以使用 `bridge` 和 `dds_runtime` 命名构建输出。

## API 概览

### 机器人客户端

下面的完整程序读取 Go2 运动服务的版本：

```zig
const std = @import("std");
const sdk = @import("unitree_sdk2");

pub fn main() !void {
    try sdk.ChannelFactory.init(0, "eth0");
    defer sdk.ChannelFactory.deinit() catch {};

    var sport = try sdk.go2.SportClient.init(false);
    defer sport.deinit();
    try sport.setTimeout(3.0);

    var version = try sport.client.serverApiVersion();
    defer version.deinit();
    std.debug.print("Sport API version: {s}\n", .{version.slice()});
}
```

请将网络接口设为连接机器人的网卡。其他型号通过 `sdk.b2`、`sdk.g1`、`sdk.h1`、`sdk.h2`、`sdk.r1`、`sdk.a2` 和 `sdk.as2` 访问。`sdk.MotionSwitcherClient` 提供共用的运动控制切换服务。

C++ 重载采用明确的 Zig 方法名，例如 `moveWithMode` 和 `executeActionByName`；默认参数需要显式传入。完整映射与补充便捷方法见[客户端方法参考](clients.md)。

### 消息与通道

DDS 类型分组位于 `sdk.messages.go2`、`hg`、`hg_doubleimu`、`ros2` 和 `api` 下。每种类型均可用于 `sdk.Publisher(T)`、`sdk.Subscriber(T)` 和 `sdk.Message(T)`。

```zig
const LowState = sdk.messages.go2.LowState;

const Receiver = struct {
    fn onState(_: *@This(), state: *const LowState) void {
        std.debug.print("Battery: {d}%\n", .{state.bms_state.soc});
    }
};

// 调用 ChannelFactory.init 后，在持有订阅者的作用域内创建订阅：
var receiver: Receiver = .{};
var subscription = try sdk.Subscriber(LowState).init(
    "rt/lowstate", Receiver, &receiver, Receiver.onState, 1,
);
defer subscription.deinit();
```

接收消息期间，需要保持所属作用域存活。回调消息是借用视图；使用 `sdk.Message(T).clone(message)` 可保留独立的深拷贝。`sdk.robots` 还提供各型号的默认主题、关节索引、消息初始化和 CRC 准备功能。

### 调度与传输

- `sdk.scheduling.AsyncPublisher(T)` 通过有界队列发送深拷贝消息。
- `sdk.scheduling.RealtimePublisher(T)` 提供加锁、编辑、发布流程。它可能分配内存，不保证硬实时期限。
- `sdk.scheduling.CachedSubscriber(T)` 保存最新消息，并返回具有独立所有权的快照。
- `sdk.scheduling.PeriodicTask` 和 `FrequencySampler` 支持周期任务与频率测量。
- `sdk.sync.BoundedQueue(T)` 和 `Future(T)` 提供应用层同步能力，并明确规定所有权。
- `sdk.transport` 提供 RPC stub、请求 Future、请求队列和租约工具。

调度与同步使用显式传入、支持线程安全的 `std.Io` 实例。生命周期与超时语义见[工具文档](utilities.md)和[传输文档](transport.md)。

## 所有权与并发

| 值                             | 生命周期与使用责任                                                        |
| ------------------------------ | ------------------------------------------------------------------------- |
| 客户端、服务端、发布者、订阅者 | 拥有资源的句柄，只能销毁一次。复制句柄不会复制资源所有权。                |
| 客户端 `Owned(T)` 返回值       | 通过 `.value` 访问，调用 `.deinit()` 释放。后续客户端调用不会影响其存储。 |
| `Buffer`                       | 通过 `.slice()` 读取，调用 `.deinit()` 释放。                             |
| 回调消息及嵌套视图             | 仅在当前回调中有效；需要保留时应克隆。                                    |
| `Message(T)` 和缓存快照        | 拥有全部嵌套存储，调用 `.deinit()` 释放。                                 |
| 回调上下文、分配器和 `std.Io`  | 必须存活到所有使用它们的操作或对象结束之后。                              |

回调在 SDK 工作线程上执行。应用需要同步共享状态，串行执行生命周期操作，并在销毁对象前结束所有外部使用。不要在订阅者或服务端自身的回调中销毁它。同一客户端的有状态调用需要外部串行化。

释放进程级 `ChannelFactory` 之前，先销毁所有依赖 DDS 的对象。订阅时间戳记录桥接回调入口处的单调时钟纳秒值；零表示尚未收到消息，不能作为 Unix 时间戳使用。

C++ 异常在 C 边界转换为状态码。Zig 错误区分参数、分配、原生异常、超时和远端失败。在发生错误的线程上立即读取 `sdk.lastStatus()` 和 `sdk.lastError()`，可取得原始数值状态码与错误文本；后续 FFI 操作可能覆盖它们。`sdk.raw` 直接提供 C ABI。

## 示例

| 命令                                          | 用途                           |
| --------------------------------------------- | ------------------------------ |
| `zig build run-rpc_loopback`                  | 本机 RPC echo，无需机器人      |
| `zig build run-low_command -Dnative=false`    | 构造命令并计算 CRC，不发送数据 |
| `zig build run-remote_control -Dnative=false` | 解析遥控报文与按键边沿         |
| `zig build run-low_state -- eth0`             | 接收 Go2 低层状态，持续五秒    |
| `zig build run-version -- eth0`               | 读取 Go2 运动服务版本          |
| `zig build run-sport_control -- eth0 stand`   | 向 Go2 发送起身指令            |

完整列表和动作参数见[示例说明](../examples/README.md)。`zig build examples` 只编译，不执行这些程序。

## API 文档

执行 `zig build docs`，然后打开 `zig-out/docs/index.html` 查看生成的 Zig API 参考。
