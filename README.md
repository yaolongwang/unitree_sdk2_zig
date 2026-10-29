# Unitree SDK2 for Zig

**English** | [简体中文](README.zh-CN.md)

Zig bindings for the official [Unitree SDK2 C++ SDK](https://github.com/unitreerobotics/unitree_sdk2), with typed robot clients, DDS messages, and low-level control tools.

Write your robot application entirely in Zig. Import `unitree_sdk2` to control the robot, exchange messages, and process state; the library bridges the official C++ SDK through a C ABI, and the SDK handles DDS communication.

Supports **Go2, B2, G1, H1, H2, R1, A2, and AS2**.

## Features

- 26 robot clients, 307 C++ SDK methods, six protocol extension methods, and 72 DDS message types.
- Custom RPC services, asynchronous requests, and lease management.
- Message publishing, subscriptions, and owned state snapshots.
- CRC, wireless remote decoding, and model-specific control helpers.

## Quick start

Requires **Zig 0.17.0**. Zig compiles and links the C++ bridge. Native communication runs on **Linux GNU x86_64 / aarch64** and requires the target's GNU C++ headers and runtime libraries.

From the repository root:

```sh
zig build -j2
zig build run-rpc_loopback -j2
```

The build downloads the pinned SDK and official `translate-c` package automatically. The loopback example runs locally without a robot.

Windows and macOS can use the data layer with `-Dnative=false`, or cross-compile for Linux with a target GNU sysroot. See the [usage guide](docs/usage.md) to add the library to your project.

## Documentation

- [Usage and ownership](docs/usage.md)
- [Client methods](docs/clients.md) · [DDS messages](docs/messages.md)
- [RPC and leases](docs/transport.md)
- [Low-level tools and scheduling](docs/utilities.md)
- [Examples](examples/README.md)
- [Contributing](CONTRIBUTING.md#english)

## License

Full third-party license texts and copyright notices are collected in [NOTICE](NOTICE).
