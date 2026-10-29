# Usage guide

**English** | [简体中文](usage.zh-CN.md) · [README](../README.md)

The call path is Zig → C ABI bridge → official C++ SDK → DDS. Protocol extensions use the same native RPC clients. Applications use the generated Zig interfaces directly.

## Requirements

| Environment                  | Support                                                                      |
| ---------------------------- | ---------------------------------------------------------------------------- |
| Linux GNU, x86_64 or aarch64 | Native SDK communication and the full Zig API                                |
| Windows or macOS             | Data-only use with `-Dnative=false`                                          |
| Zig                          | **0.17.0**                                                                   |
| Native build dependencies    | Target GNU C++ headers, `libstdc++`, and `libgcc`; Zig provides the compiler |

Write application code entirely in Zig and access the library with `@import("unitree_sdk2")`. The official `translate-c` package imports the C headers, while Zig's build API compiles the C++17 bridge and links the SDK. The build downloads pinned versions of [Unitree SDK2](https://github.com/unitreerobotics/unitree_sdk2) and [translate-c](https://codeberg.org/ziglang/translate-c/) automatically. `translate-c` runs only during the build; deployment includes the native libraries described below. No external C++ compiler, CMake, Eigen, or Boost is required.

The native bridge uses GNU C++ headers and runtime libraries to match the official SDK. On native Linux builds these are discovered under `/`; install the distribution's GNU C++ development packages. `-Dgcc-version` selects a specific installed version; otherwise the latest version under `usr/lib/gcc/<triple>/` is selected. Supported layouts use `<arch>-linux-gnu` or `<arch>-pc-linux-gnu` triplets, as on Debian/Ubuntu and Arch Linux.

For cross-compilation, supply a target sysroot containing `usr/include/c++/<version>`, the architecture-specific C++ and libc headers, `libstdc++.so.6`, `libgcc_s.so.1`, and `usr/lib/gcc/<triple>/<version>/{libgcc.a,libgcc_eh.a}`. Use an absolute sysroot path, including when passing it through a package dependency. For an ARM64 robot with glibc 2.31 and GCC 9 runtime files:

```sh
zig build -Dtarget=aarch64-linux-gnu.2.31 -Dsysroot=/path/to/arm64-sysroot -Dgcc-version=9 -j2
```

This also works from Windows or macOS; the resulting programs run on Linux. In PowerShell, quote each `-D...` argument containing paths or dotted version numbers. The target's glibc version must match the deployment baseline. `-Dbridge=/absolute/path/libunitree_sdk2_zig.so` reuses an existing bridge; compiling the C++ tests still requires the GNU development files.

## Quick start

From a checkout on Linux:

```sh
zig build -j2
zig build run-rpc_loopback -j2
```

The loopback example runs a local RPC server and client without a robot. To use an existing copy of the pinned SDK:

```sh
zig build -Dsdk-root=/path/to/unitree_sdk2 -j2
```

The SDK version and package hash are defined once in `build.zig.zon`; builds, generation and coverage checks share Zig's dependency cache. `sdk-root` overrides the directory for all workflows without downloading and must contain `include/`, `lib/<arch>/`, and `thirdparty/`. For a data-only build on Windows, macOS, or Linux:

```sh
zig build test check examples -Dnative=false
zig build run-low_command -Dnative=false
```

The second command constructs a low-level command and computes its CRC locally.

## Use as a dependency

For a released source archive, run `zig fetch --save=unitree_sdk2 <release-archive-URL>` in your application directory. Zig records the URL and content hash in the application's `build.zig.zon`. This package exports the `unitree_sdk2` module.

For local development, place a checkout beside your application and add it to your application's `build.zig.zon`:

```zig
.dependencies = .{
    .unitree_sdk2 = .{ .path = "../unitree_sdk2_zig" },
},
```

In your application's `build.zig`, pass the same target and optimization mode to the dependency:

```zig
const sdk = b.dependency("unitree_sdk2", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("unitree_sdk2", sdk.module("unitree_sdk2"));

// Install the bridge, DDS runtime, and third-party license files.
@import("unitree_sdk2").installRuntime(b, sdk);
```

For data-only applications, pass `.native = false` and omit `installRuntime`. A complete consumer project is available in [tests/package_consumer](../tests/package_consumer).

For a cross-compiled dependency, also pass `.sysroot = "/absolute/path/to/sysroot"` and, if needed, `.@"gcc-version" = "9"` in `b.dependency` alongside the same `.target`. The consumer example exposes these as `-Dsysroot` and `-Dgcc-version` options.

Native installations use `bin/`, `lib/`, and `share/licenses/unitree_sdk2/`. Keep these directories together when deploying; executables resolve runtime libraries from `../lib`. The target system supplies the GNU C++ runtime. Custom packaging can use the `bridge` and `dds_runtime` named build outputs.

## API overview

### Robot clients

This complete program reads the Go2 sport service version:

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

Choose the network interface connected to your robot. Other families are available as `sdk.b2`, `sdk.g1`, `sdk.h1`, `sdk.h2`, `sdk.r1`, `sdk.a2`, and `sdk.as2`. `sdk.MotionSwitcherClient` exposes the shared motion switcher service.

C++ overloads have explicit Zig names, such as `moveWithMode` and `executeActionByName`; default arguments are passed explicitly. See the [client method reference](clients.md) for exact mappings and additional convenience methods.

### Messages and channels

DDS types are grouped under `sdk.messages.go2`, `hg`, `hg_doubleimu`, `ros2`, and `api`. Each type works with `sdk.Publisher(T)`, `sdk.Subscriber(T)`, and `sdk.Message(T)`.

```zig
const LowState = sdk.messages.go2.LowState;

const Receiver = struct {
    fn onState(_: *@This(), state: *const LowState) void {
        std.debug.print("Battery: {d}%\n", .{state.bms_state.soc});
    }
};

// After ChannelFactory.init, in the scope that owns the subscription:
var receiver: Receiver = .{};
var subscription = try sdk.Subscriber(LowState).init(
    "rt/lowstate", Receiver, &receiver, Receiver.onState, 1,
);
defer subscription.deinit();
```

Keep the owning scope alive while receiving. Callback messages are borrowed views; use `sdk.Message(T).clone(message)` to retain an independent deep copy. `sdk.robots` adds model-specific topics, joint indices, message initialization, and CRC preparation.

### Scheduling and transport

- `sdk.scheduling.AsyncPublisher(T)` sends deep-copied messages through a bounded queue.
- `sdk.scheduling.RealtimePublisher(T)` provides a lock/edit/publish workflow. It may allocate and does not guarantee hard real-time deadlines.
- `sdk.scheduling.CachedSubscriber(T)` stores the latest message and returns independently owned snapshots.
- `sdk.scheduling.PeriodicTask` and `FrequencySampler` support recurrent work and rate measurement.
- `sdk.sync.BoundedQueue(T)` and `Future(T)` provide application-level synchronization with explicit ownership rules.
- `sdk.transport` exposes RPC stubs, request futures, request queues, and lease tools.

Scheduling and synchronization use explicit, thread-safe `std.Io` instances. See [utilities](utilities.md) and [transport](transport.md) for lifecycle and timeout semantics.

## Ownership and concurrency

| Value                                     | Lifetime and responsibility                                                                                |
| ----------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| Clients, servers, publishers, subscribers | Owning handles; destroy exactly once. Copying a handle does not duplicate ownership.                       |
| Client `Owned(T)` results                 | Access through `.value`; call `.deinit()`. Storage remains valid independently of subsequent client calls. |
| `Buffer`                                  | Read with `.slice()` and release with `.deinit()`.                                                         |
| Callback messages and nested views        | Borrowed for that callback only; clone to retain.                                                          |
| `Message(T)` and cache snapshots          | Own all nested storage; release with `.deinit()`.                                                          |
| Callback context, allocator, and `std.Io` | Must outlive every operation or object that uses them.                                                     |

Callbacks run on SDK worker threads. Synchronize application state, serialize lifecycle operations, and finish external users before destroying an object. Never destroy a subscription or server from its own callback. Stateful calls on the same client require external serialization.

Destroy every DDS-dependent object before releasing the process-wide `ChannelFactory`. Subscription timestamps use monotonic nanoseconds at bridge callback entry; zero means no delivery yet. They are not Unix timestamps.

C++ exceptions are translated at the C boundary. Zig errors distinguish argument, allocation, native, timeout, and remote failures. Read `sdk.lastStatus()` and `sdk.lastError()` immediately on the failing thread to obtain the original numeric status and error text; subsequent FFI operations may replace them. `sdk.raw` exposes the C ABI directly.

## Examples

| Command                                       | Purpose                                             |
| --------------------------------------------- | --------------------------------------------------- |
| `zig build run-rpc_loopback`                  | Local RPC echo; no robot needed                     |
| `zig build run-low_command -Dnative=false`    | Construct a command and compute CRC without sending |
| `zig build run-remote_control -Dnative=false` | Decode remote packets and track button edges        |
| `zig build run-low_state -- eth0`             | Receive Go2 low-level state for five seconds        |
| `zig build run-version -- eth0`               | Read the Go2 sport service version                  |
| `zig build run-sport_control -- eth0 stand`   | Send a stand-up command to Go2                      |

See the [example guide](../examples/README.md) for all commands and action parameters. `zig build examples` compiles these programs without running them.

## API documentation

Run `zig build docs`, then open `zig-out/docs/index.html` for the generated Zig API reference.
