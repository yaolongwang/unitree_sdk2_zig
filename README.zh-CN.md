# Unitree SDK2 for Zig

[English](README.md) | **简体中文**

官方 [Unitree SDK2 C++ SDK](https://github.com/unitreerobotics/unitree_sdk2) 的 Zig 绑定，提供类型化机器人客户端、DDS 消息和低层控制工具。

机器人应用可以完全使用 Zig 编写。导入 `unitree_sdk2` 即可控制机器人、收发消息和处理状态；本库通过 C ABI 桥接官方 C++ SDK，由 SDK 完成 DDS 通信。

支持 **Go2、B2、G1、H1、H2、R1、A2、AS2**。

## 功能

- 26 个机器人客户端、307 个 C++ SDK 方法、6 个协议扩展方法、72 种 DDS 消息。
- 自定义 RPC 服务、异步请求与租约管理。
- 消息发布、订阅与拥有独立存储的状态快照。
- CRC、无线遥控器解码与型号专属控制工具。

## 快速开始

需要 **Zig 0.17.0**，C++ 桥接由 Zig 编译和链接。原生通信支持 **Linux GNU x86_64 / aarch64**，需要目标系统的 GNU C++ 头文件与运行库。

在仓库根目录执行：

```sh
zig build -j2
zig build run-rpc_loopback -j2
```

构建时会自动下载固定版本的 SDK 和官方 `translate-c` 包。回环示例在本机运行，无需机器人。

Windows 和 macOS 可通过 `-Dnative=false` 使用数据层，也可提供目标 GNU sysroot 交叉编译 Linux 程序。将本库接入项目的方法见[使用指南](docs/usage.zh-CN.md)。

## 文档

- [使用方法与所有权](docs/usage.zh-CN.md)
- [客户端方法](docs/clients.md) · [DDS 消息](docs/messages.md)
- [RPC 与租约](docs/transport.md)
- [低层工具与调度](docs/utilities.md)
- [示例与运行命令](examples/README.md)
- [参与贡献](CONTRIBUTING.md#简体中文)

## 许可证

第三方许可证全文及版权声明统一收录在 [NOTICE](NOTICE)。
