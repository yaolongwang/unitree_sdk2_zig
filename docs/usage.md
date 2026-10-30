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

The native bridge uses GNU C++ files to match the official SDK. ARM64 Linux builds use the repository's fixed [GNU development package](../vendor/README.md) by default. It has GCC 9 C++ headers and glibc 2.31 headers. Consumers need no Python setup step. To build for Ubuntu 20.04 ARM64:

```sh
zig build examples -Dtarget=aarch64-linux-gnu.2.31 -Doptimize=ReleaseSafe -j2
```

The build can run on Windows, macOS, or Linux; its output runs on ARM64 Linux. In PowerShell, quote each `-D...` argument with a path or dotted version. Set the target glibc version to the deployment baseline. Compilation on a host does not test execution on the target.

`-Dsysroot=/absolute/path` overrides the bundled files. Native x86_64 Linux builds use `/` by default. x86_64 cross-builds still require an external sysroot. That sysroot must provide C++ and libc headers, `libstdc++.so.6`, `libgcc_s.so.1`, and `usr/lib/gcc/<triple>/<version>/libgcc.a`. Static C++ builds also need `libstdc++.a`. `-Dgcc-version` selects a version; custom sysroots otherwise use the highest version found. Debian/Ubuntu and Arch Linux directory layouts are supported.

### Linkage

| Option                              | Default   | Result                                                                   |
| ----------------------------------- | --------- | ------------------------------------------------------------------------ |
| `-Dlinkage=dynamic` or `static`     | `dynamic` | A shared bridge `.so`, or a static bridge `.a` that contains SDK objects |
| `-Dcxx-linkage=dynamic` or `static` | `dynamic` | Select `libstdc++.so.6` or `libstdc++.a` for the final link              |

For a static bridge and static GNU C++ library:

```sh
zig build examples -Dtarget=aarch64-linux-gnu.2.31 -Dlinkage=static -Dcxx-linkage=static -Doptimize=ReleaseSafe -j2
```

All four option combinations are supported. The Zig module carries the link inputs needed by a static bridge. DDS and glibc remain shared. The build uses shared `libgcc_s` for C++ exception handling. DDS itself still loads `libstdc++.so.6` and `libgcc_s.so.1`, even when the application uses static C++. The target system must provide these shared libraries. This is not a fully static executable.

`-Dbridge=/absolute/path/libunitree_sdk2_zig.so` reuses an existing bridge. For an existing `.a`, also set `-Dlinkage=static`. C++ tests and static consumers still need the GNU development files. Use separate `--prefix` directories when comparing modes; Zig does not remove old installed files when options change.

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

ARM64 dependencies select the bundled package from `.target`. A custom sysroot can be passed as `.sysroot = "/absolute/path/to/sysroot"`, with `.@"gcc-version"` as needed. To select static linkage, pass `.linkage = .static` and `.@"cxx-linkage" = .static`. The consumer example exposes all four options.

Native installations use `bin/`, `lib/`, and `share/licenses/unitree_sdk2/`. Keep these directories together when deploying; executables resolve runtime libraries from `../lib`. `installRuntime` installs DDS and, for a dynamic bridge, the bridge `.so`. Static consumers need no bridge `.so`. The target system supplies the GNU C++ runtime. Custom packaging can use the `bridge`, `dds_runtime`, and `native_runtime` named build outputs.

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
