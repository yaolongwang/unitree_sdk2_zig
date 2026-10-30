const std = @import("std");
const Translator = @import("translate_c").Translator;

const cpp_sources = [_][]const u8{
    "upstream_threads.cpp",
    "upstream_lease.cpp",
    "core.cpp",
    "server.cpp",
    "transport.cpp",
    "generated/clients_support.cpp",
    "generated/clients_a2_audio.cpp",
    "generated/clients_a2_sport.cpp",
    "generated/clients_as2_audio.cpp",
    "generated/clients_as2_sport.cpp",
    "generated/clients_b2_back_video.cpp",
    "generated/clients_b2_config.cpp",
    "generated/clients_b2_front_video.cpp",
    "generated/clients_b2_motion_switcher.cpp",
    "generated/clients_b2_robot_state.cpp",
    "generated/clients_b2_sport.cpp",
    "generated/clients_g1_agv.cpp",
    "generated/clients_g1_arm.cpp",
    "generated/clients_g1_audio.cpp",
    "generated/clients_g1_loco.cpp",
    "generated/clients_go2_config.cpp",
    "generated/clients_go2_obstacles_avoid.cpp",
    "generated/clients_go2_robot_state.cpp",
    "generated/clients_go2_sport.cpp",
    "generated/clients_go2_utrack.cpp",
    "generated/clients_go2_video.cpp",
    "generated/clients_go2_vui.cpp",
    "generated/clients_h1_loco.cpp",
    "generated/clients_h2_arm.cpp",
    "generated/clients_h2_loco.cpp",
    "generated/clients_r1_audio.cpp",
    "generated/clients_r1_loco.cpp",
    "generated/messages.cpp",
    "generated/messages_api.cpp",
    "generated/messages_go2.cpp",
    "generated/messages_hg.cpp",
    "generated/messages_hg_doubleimu.cpp",
    "generated/messages_ros2.cpp",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const native = b.option(bool, "native", "Build and link the Linux SDK bridge") orelse (target.result.os.tag == .linux);
    const linkage = b.option(std.builtin.LinkMode, "linkage", "Bridge linkage: dynamic or static") orelse .dynamic;
    const gnu_options = GnuCxx.Options.fromBuild(b);
    const sdk_root = b.option([]const u8, "sdk-root", "Existing pinned Unitree SDK2 source directory");
    const prebuilt = b.option([]const u8, "bridge", "Use an existing bridge library with the selected linkage");
    const sdk_tools = b.option(bool, "sdk-tools", "Enable SDK generation and source checks in data-only builds") orelse false;
    const python = b.option([]const u8, "python", "Python executable for maintenance steps") orelse
        if (b.graph.host.result.os.tag == .windows) "python" else "python3";
    // All SDK consumers share this one resolution. Data-only consumers need no SDK download.
    const sdk: ?std.Build.LazyPath = if (native or sdk_tools)
        if (sdk_root) |path| b.graph.cwdRelativePath(path) else b.dependency("unitree_sdk2_native", .{}).path("")
    else
        null;
    const crc_test = addSdkTasks(b, sdk, python, native, target, gnu_options);

    const translated: Translator = .init(b.dependency("translate_c", .{}), .{
        .name = "unitree_sdk2_raw",
        .c_source_file = b.path("include/unitree_sdk2_zig.h"),
        .target = target,
        .optimize = optimize,
        .func_bodies = false,
    });
    translated.addIncludePath(b.path("include"));
    // Keep the generated declarations private to the fully linked SDK module.
    // Consumers can access the C ABI through unitree_sdk2.raw.
    const raw = translated.mod;
    const module = b.addModule("unitree_sdk2", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "raw", .module = raw }},
    });

    const unit_tests = b.addTest(.{ .root_module = module });
    b.step("test", "Run deterministic Zig data and protocol tests").dependOn(&b.addRunArtifact(unit_tests).step);

    const check_module = b.createModule(.{
        .root_source_file = b.path("tests/compile/check.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "unitree_sdk2", .module = module }},
    });
    const check = b.addObject(.{ .name = "unitree_sdk2_check", .root_module = check_module });
    b.step("check", "Compile every typed client and public declaration").dependOn(&check.step);

    if (native) {
        if (target.result.os.tag != .linux or target.result.abi != .gnu or
            (target.result.cpu.arch != .x86_64 and target.result.cpu.arch != .aarch64))
            @panic("The upstream SDK requires Linux GNU x86_64 or aarch64. Use -Dnative=false for the data-only layer.");

        const native_sdk = sdk.?;
        const arch = @tagName(target.result.cpu.arch);
        const dds_source = native_sdk.path(b, b.fmt("thirdparty/lib/{s}", .{arch}));
        // Git on Windows may check out upstream symlinks as text files. Stage
        // real ELF copies under both names so native builds work from that tree.
        const dds_files = b.addWriteFiles();
        for ([_][]const u8{ "libddsc.so", "libddscxx.so" }) |name| {
            _ = dds_files.addCopyFile(dds_source.path(b, name), name);
            _ = dds_files.addCopyFile(dds_source.path(b, name), b.fmt("{s}.0", .{name}));
        }
        const dds_path = dds_files.getDirectory();
        const gnu = GnuCxx.resolve(b, target, gnu_options);
        const library = if (prebuilt) |path|
            b.graph.cwdRelativePath(path)
        else
            buildNative(b, native_sdk, dds_path, target, gnu, optimize, linkage);
        module.addObjectFile(library);
        if (linkage == .static) {
            linkDds(b, module, dds_path);
            gnu.linkModule(module);
        }
        module.addRPathSpecial("$ORIGIN/../lib");
        module.addRPath(library.dirname());
        module.addRPath(dds_path);
        b.addNamedLazyPath("bridge", library);
        b.addNamedLazyPath("dds_runtime", dds_path);

        const runtime = b.addWriteFiles();
        for ([_][]const u8{ "libddsc.so", "libddscxx.so", "libddsc.so.0", "libddscxx.so.0" }) |name|
            _ = runtime.addCopyFile(dds_path.path(b, name), name);
        if (linkage == .dynamic) {
            _ = runtime.addCopyFile(library, "libunitree_sdk2_zig.so");
        } else {
            b.getInstallStep().dependOn(&b.addInstallFileWithDir(library, .lib, "libunitree_sdk2_zig.a").step);
        }
        b.addNamedLazyPath("native_runtime", runtime.getDirectory());
        b.installDirectory(.{ .source_dir = runtime.getDirectory(), .install_dir = .lib, .install_subdir = "" });

        const integration = b.step("test-native", "Run all native ABI, DDS and RPC loopback tests without a robot");
        const check_native = b.step("check-native", "Compile all native tests without running them");
        for ([_][]const u8{ "rpc_test", "messages_test", "messages_loopback", "transport_test", "clients_test", "thread_lifecycle_test", "lease_protocol_test" }) |name| {
            const test_module = b.createModule(.{ .target = target, .optimize = .debug });
            const object = cppObject(b, native_sdk, target, gnu, .debug, b.path(b.fmt("tests/integration/{s}.cpp", .{name})), name);
            test_module.addObjectFile(object.getEmittedBin());
            test_module.addObjectFile(library);
            if (linkage == .static) linkDds(b, test_module, dds_path);
            test_module.addRPath(library.dirname());
            test_module.addRPath(dds_path);
            const executable = b.addExecutable(.{ .name = name, .root_module = test_module });
            gnu.configure(b, executable, true);
            check_native.dependOn(&executable.step);
            integration.dependOn(&b.addRunArtifact(executable).step);
        }
        const scheduling_loopback = b.addExecutable(.{
            .name = "scheduling_loopback",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/integration/scheduling_loopback.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "unitree_sdk2", .module = module }},
            }),
        });
        check_native.dependOn(&scheduling_loopback.step);
        integration.dependOn(&b.addRunArtifact(scheduling_loopback).step);

        integration.dependOn(crc_test);
    }

    const examples = b.step("examples", "Compile examples (without running robot commands)");
    for ([_][]const u8{ "low_command", "remote_control", "rpc_loopback", "low_state", "version", "sport_control" }) |name| {
        const data_only = std.mem.eql(u8, name, "low_command") or std.mem.eql(u8, name, "remote_control");
        if (!native and !data_only) continue;
        const example = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("examples/{s}.zig", .{name})),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "unitree_sdk2", .module = module }},
            }),
        });
        examples.dependOn(&b.addInstallArtifact(example, .{}).step);
        const run = b.addRunArtifact(example);
        run.addPassthruArgs();
        b.step(b.fmt("run-{s}", .{name}), b.fmt("Run the {s} example", .{name})).dependOn(&run.step);
    }

    b.installDirectory(.{ .source_dir = b.path("include"), .install_dir = .header, .install_subdir = "" });
    installProjectLicense(b, b);
    b.installFile("NOTICE", "share/licenses/unitree_sdk2/NOTICE");
    const docs = b.addObject(.{ .name = "unitree_sdk2_docs", .root_module = module });
    const install_docs = b.addInstallDirectory(.{ .source_dir = docs.getEmittedDocs(), .install_dir = .prefix, .install_subdir = "docs" });
    b.step("docs", "Generate Zig API documentation").dependOn(&install_docs.step);
}

/// Install the selected native runtime libraries and their notices.
/// Use with a dependency configured with native=true.
pub fn installRuntime(b: *std.Build, dependency: *std.Build.Dependency) void {
    b.installDirectory(.{ .source_dir = dependency.namedLazyPath("native_runtime"), .install_dir = .lib, .install_subdir = "" });
    installProjectLicense(b, dependency.builder);
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(dependency.path("NOTICE"), .prefix, "share/licenses/unitree_sdk2/NOTICE").step);
}

fn installProjectLicense(b: *std.Build, source: *std.Build) void {
    const license = source.path("LICENSE");
    // Detect a later addition without making every build reconfigure.
    b.dependOnDirectoryContents(source.path(""));
    source.root.access(b.graph.io, "LICENSE", .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => std.debug.panic("Cannot access project LICENSE: {s}", .{@errorName(err)}),
    };
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(license, .prefix, "share/licenses/unitree_sdk2/LICENSE").step);
}

fn cppModule(b: *std.Build, sdk: std.Build.LazyPath, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) *std.Build.Module {
    const module = b.createModule(.{ .target = target, .optimize = optimize, .link_libcpp = false, .pic = true });
    for ([_][]const u8{ "include", "src/cpp", "src/cpp/generated" }) |path| module.addIncludePath(b.path(path));
    for ([_][]const u8{ "include", "thirdparty/include", "thirdparty/include/ddscxx" }) |path| module.addSystemIncludePath(sdk.path(b, path));
    return module;
}

fn cppObject(b: *std.Build, sdk: std.Build.LazyPath, target: std.Build.ResolvedTarget, gnu: GnuCxx.Toolchain, optimize: std.lang.Optimize, source: std.Build.LazyPath, name: []const u8) *std.Build.Step.Compile {
    const module = cppModule(b, sdk, target, optimize);
    module.addCSourceFile(.{ .file = source, .flags = GnuCxx.flags });
    const object = b.addObject(.{ .name = name, .root_module = module });
    gnu.configure(b, object, false);
    return object;
}

fn linkDds(b: *std.Build, module: *std.Build.Module, dds_path: std.Build.LazyPath) void {
    module.addObjectFile(dds_path.path(b, "libddscxx.so"));
    module.addObjectFile(dds_path.path(b, "libddsc.so"));
}

fn buildNative(b: *std.Build, sdk: std.Build.LazyPath, dds_path: std.Build.LazyPath, target: std.Build.ResolvedTarget, gnu: GnuCxx.Toolchain, optimize: std.lang.Optimize, linkage: std.builtin.LinkMode) std.Build.LazyPath {
    const module = b.createModule(.{ .target = target, .optimize = optimize });
    // 先提供桥接对象，再扫描 SDK 静态库，保留线程、租约和 Future 的完整兼容实现。
    for (cpp_sources) |source| {
        const object = cppObject(b, sdk, target, gnu, optimize, b.path(b.fmt("src/cpp/{s}", .{source})), std.Io.Dir.path.stem(source));
        module.addObjectFile(object.getEmittedBin());
    }
    const sdk_library = sdk.path(b, b.fmt("lib/{s}/libunitree_sdk2.a", .{@tagName(target.result.cpu.arch)}));
    module.addObjectFile(sdk_library);
    if (linkage == .static) {
        // Resolve SDK references before archiving. This excludes its service main.
        const combined = b.addObject(.{ .name = "unitree_sdk2_zig_objects", .root_module = module });
        const archive_module = b.createModule(.{ .target = target, .optimize = optimize });
        archive_module.addObjectFile(combined.getEmittedBin());
        return b.addLibrary(.{ .name = "unitree_sdk2_zig", .linkage = .static, .root_module = archive_module }).getEmittedBin();
    }
    const library = b.addLibrary(.{ .name = "unitree_sdk2_zig", .linkage = .dynamic, .root_module = module });
    linkDds(b, module, dds_path);
    module.addRPathSpecial("$ORIGIN");
    module.addRPath(dds_path);
    library.linker_allow_shlib_undefined = false;
    gnu.configure(b, library, true);
    return library.getEmittedBin();
}

/// Maintenance scripts only read the SDK and write this repository or build-cache outputs.
fn sdkScript(b: *std.Build, sdk: std.Build.LazyPath, python: []const u8, script: []const u8) *std.Build.Step.Run {
    const run = b.addSystemCommand(&.{python});
    run.addFileArg(b.path(script));
    run.addArg("--sdk");
    run.addDirectoryArg(sdk);
    run.setCwd(b.path(""));
    run.setEnvironmentVariable("PYTHONDONTWRITEBYTECODE", "1");
    // Scripts inspect source trees and generated files; always recheck their current contents.
    run.has_side_effects = true;
    return run;
}

fn addSdkTasks(b: *std.Build, sdk: ?std.Build.LazyPath, python: []const u8, native: bool, target: std.Build.ResolvedTarget, gnu_options: GnuCxx.Options) *std.Build.Step {
    const regenerate = b.step("regenerate", "Regenerate all bindings, API docs and coverage from the pinned SDK");
    const check_upstream = b.step("check-upstream", "Check generated bindings, coverage, SDK source inventory and CRC layouts");
    const check_generated_files = b.addSystemCommand(&.{ python, "-B" });
    check_generated_files.addFileArg(b.path("scripts/generated_files.py"));
    check_generated_files.addArg("--self-test");
    check_generated_files.setCwd(b.path(""));
    check_generated_files.has_side_effects = true;
    check_upstream.dependOn(&check_generated_files.step);
    const test_crc = b.step("test-crc", "Check CRC layouts and, with native enabled, execute the C++ reference");
    const source = sdk orelse {
        const unavailable = b.addFail("This maintenance step needs SDK sources. Add -Dsdk-tools (data-only) or -Dnative=true (Linux GNU).");
        for ([_]*std.Build.Step{ regenerate, check_upstream, test_crc }) |step| step.dependOn(&unavailable.step);
        return test_crc;
    };

    const generate_clients = sdkScript(b, source, python, "scripts/generate_clients.py");
    generate_clients.addArgs(&.{ "--zig-exe", b.graph.zig_exe });
    const generate_messages = sdkScript(b, source, python, "scripts/generate_messages.py");
    generate_messages.step.dependOn(&generate_clients.step);
    const write_coverage = sdkScript(b, source, python, "scripts/check_coverage.py");
    write_coverage.addArg("--write");
    write_coverage.step.dependOn(&generate_messages.step);
    regenerate.dependOn(&write_coverage.step);

    const check_clients = sdkScript(b, source, python, "scripts/generate_clients.py");
    check_clients.addArgs(&.{ "--check", "--zig-exe", b.graph.zig_exe });
    const check_messages = sdkScript(b, source, python, "scripts/generate_messages.py");
    check_messages.addArg("--check");
    check_messages.step.dependOn(&check_clients.step);
    const check_coverage = sdkScript(b, source, python, "scripts/check_coverage.py");
    check_coverage.step.dependOn(&check_messages.step);
    const inventory = sdkScript(b, source, python, "scripts/audit_upstream.py");
    inventory.addArg("--check");
    inventory.addFileArg(b.path("tests/reference/coverage.json"));
    inventory.step.dependOn(&check_coverage.step);
    const check_crc = sdkScript(b, source, python, "tests/reference/crc_reference.py");
    check_upstream.dependOn(&inventory.step);
    check_upstream.dependOn(&check_crc.step);

    if (native) {
        const emit = sdkScript(b, source, python, "tests/reference/crc_reference.py");
        emit.addArg("--emit-cpp");
        const cpp = emit.addOutputFileArg("crc_reference.cpp");
        const gnu = GnuCxx.resolve(b, target, gnu_options);
        const object = cppObject(b, source, target, gnu, .debug, cpp, "crc_reference");
        const module = b.createModule(.{ .target = target, .optimize = .debug });
        module.addObjectFile(object.getEmittedBin());
        const executable = b.addExecutable(.{ .name = "crc_reference", .root_module = module });
        gnu.configure(b, executable, true);
        const run = b.addRunArtifact(executable);
        const verify = sdkScript(b, source, python, "tests/reference/crc_reference.py");
        verify.addArg("--native-result");
        verify.addFileArg(run.captureStdOut(.{}));
        test_crc.dependOn(&verify.step);
    } else {
        test_crc.dependOn(&check_crc.step);
    }
    return test_crc;
}

/// Configure GNU headers and runtime libraries for the Zig C++ compiler.
const GnuCxx = struct {
    const Build = std.Build;
    const LazyPath = Build.LazyPath;

    pub const Options = struct {
        sysroot: ?[]const u8,
        gcc_version: ?[]const u8,
        cxx_linkage: std.builtin.LinkMode = .dynamic,

        pub fn fromBuild(b: *Build) Options {
            return .{
                .sysroot = b.option([]const u8, "sysroot", "Target GNU sysroot (ARM64 defaults to the bundled Ubuntu 20.04 files)"),
                .gcc_version = b.option([]const u8, "gcc-version", "GNU C++ header/runtime version within the sysroot (auto-detected by default)"),
                .cxx_linkage = b.option(std.builtin.LinkMode, "cxx-linkage", "GNU libstdc++ linkage: dynamic or static; libgcc_s stays shared") orelse .dynamic,
            };
        }
    };

    const Paths = struct {
        includes: []const LazyPath,
        libraries: []const LazyPath,
    };

    pub const Toolchain = union(enum) {
        ready: Paths,
        unavailable: []const u8,

        /// 将缺少 sysroot 的错误绑定到原生编译步骤，预编译桥接和纯编译检查仍可使用。
        pub fn configure(self: Toolchain, b: *Build, artifact: *Build.Step.Compile, link_runtime: bool) void {
            switch (self) {
                .unavailable => |message| artifact.step.dependOn(&b.addFail(message).step),
                .ready => |gnu| {
                    const module = artifact.root_module;
                    // 对象编译只使用显式的目标头文件，避免 Zig 混入另一版本的 libc 头文件。
                    // libc 留到最终链接；GNU 头文件仍按系统头文件处理。
                    module.link_libc = link_runtime;
                    module.link_libcpp = false;
                    for (gnu.includes) |include| module.addSystemIncludePath(include);
                    if (!link_runtime) return;
                    self.linkModule(module);
                    artifact.link_eh_frame_hdr = true;
                },
            }
        }

        /// Attach the GNU runtime to applications that use a static bridge.
        pub fn linkModule(self: Toolchain, module: *Build.Module) void {
            switch (self) {
                .unavailable => |message| std.debug.panic("{s}", .{message}),
                .ready => |gnu| {
                    module.link_libc = true;
                    module.link_libcpp = false;
                    // Zig maps the name stdc++ to libc++. Use the GNU files directly.
                    for (gnu.libraries) |library| module.addObjectFile(library);
                    for ([_][]const u8{ "pthread", "m", "dl" }) |name|
                        module.linkSystemLibrary(name, .{ .use_pkg_config = .no });
                },
            }
        }
    };

    // 固定上游 CycloneDDS 的 CDR 数据区含 4 字节前缀，64 位读写可能非对齐。
    // 两种受支持的 Linux 架构均沿用上游的访问方式；仅关闭 Clang 对齐检查，保留其他检查。
    pub const flags: []const []const u8 = &.{ "-std=c++17", "-nostdinc++", "-pthread", "-Wall", "-Wextra", "-fno-sanitize=alignment" };

    pub fn resolve(b: *Build, target: Build.ResolvedTarget, options: Options) Toolchain {
        const host = b.graph.host.result;
        const bundled = options.sysroot == null and target.result.cpu.arch == .aarch64 and
            target.result.os.tag == .linux and target.result.abi == .gnu;
        const root = options.sysroot orelse if (bundled)
            b.dependency("sysroot_aarch64", .{}).builder.root.joinString(b.allocator, "") catch @panic("OOM")
        else if (host.os.tag == .linux and host.cpu.arch == target.result.cpu.arch)
            "/"
        else
            return .{ .unavailable = "Native C++ requires -Dsysroot=<target GNU sysroot> when cross-compiling; Zig provides the compiler, the sysroot provides GNU headers and libraries." };

        const arch = @tagName(target.result.cpu.arch);
        const triple = findTriple(b, root, arch) orelse return .{
            .unavailable = b.fmt("No GNU runtime directory for {s} in {s}/usr/lib/gcc; provide a matching -Dsysroot.", .{ arch, root }),
        };
        const gcc_parent = join(b, root, b.fmt("usr/lib/gcc/{s}", .{triple}));
        const version = options.gcc_version orelse (if (bundled) "9" else findVersion(b, gcc_parent)) orelse return .{
            .unavailable = b.fmt("No GCC version found in {s}; install GNU C++ development files or specify -Dgcc-version.", .{gcc_parent}),
        };
        const gcc_dir = join(b, gcc_parent, version);
        const common_include = join(b, root, b.fmt("usr/include/c++/{s}", .{version}));
        const arch_include = firstExisting(b, &.{
            join(b, root, b.fmt("usr/include/{s}/c++/{s}", .{ triple, version })),
            join(b, common_include, triple),
        }) orelse return .{ .unavailable = b.fmt("Missing GNU C++ target headers for {s}, GCC {s}, under {s}.", .{ triple, version, root }) };
        if (!exists(b, join(b, common_include, "vector")))
            return .{ .unavailable = b.fmt("Missing GNU C++ headers in {s}.", .{common_include}) };

        var includes: std.ArrayList(LazyPath) = .empty;
        for ([_][]const u8{ common_include, arch_include, join(b, root, "usr/include"), join(b, root, b.fmt("usr/include/{s}", .{triple})) }) |path| {
            if (exists(b, path)) includes.append(b.allocator, b.graph.cwdRelativePath(path)) catch @panic("OOM");
        }

        var libraries: std.ArrayList(LazyPath) = .empty;
        if (options.cxx_linkage == .static) {
            const path = join(b, gcc_dir, "libstdc++.a");
            if (!exists(b, path)) return .{ .unavailable = b.fmt("Missing GNU C++ static library {s}.", .{path}) };
            libraries.append(b.allocator, b.graph.cwdRelativePath(path)) catch @panic("OOM");
        } else {
            const path = findRuntime(b, root, triple, "libstdc++.so.6") orelse return .{
                .unavailable = b.fmt("Missing libstdc++.so.6 for {s} in GNU sysroot {s}.", .{ triple, root }),
            };
            libraries.append(b.allocator, b.graph.cwdRelativePath(path)) catch @panic("OOM");
        }
        // DDS uses C++ exceptions across shared libraries. Keep one shared unwinder.
        for ([_][]const u8{"libgcc_s.so.1"}) |name| {
            const path = findRuntime(b, root, triple, name) orelse return .{
                .unavailable = b.fmt("Missing {s} for {s} in GNU sysroot {s}.", .{ name, triple, root }),
            };
            libraries.append(b.allocator, b.graph.cwdRelativePath(path)) catch @panic("OOM");
        }
        for ([_][]const u8{"libgcc.a"}) |name| {
            const path = join(b, gcc_dir, name);
            if (!exists(b, path)) return .{ .unavailable = b.fmt("Missing GNU runtime archive {s}.", .{path}) };
            libraries.append(b.allocator, b.graph.cwdRelativePath(path)) catch @panic("OOM");
        }
        return .{ .ready = .{ .includes = includes.toOwnedSlice(b.allocator) catch @panic("OOM"), .libraries = libraries.toOwnedSlice(b.allocator) catch @panic("OOM") } };
    }

    fn findTriple(b: *Build, root: []const u8, arch: []const u8) ?[]const u8 {
        for ([_][]const u8{ b.fmt("{s}-linux-gnu", .{arch}), b.fmt("{s}-pc-linux-gnu", .{arch}) }) |triple| {
            if (exists(b, join(b, root, b.fmt("usr/lib/gcc/{s}", .{triple})))) return triple;
        }
        return null;
    }

    fn findVersion(b: *Build, parent: []const u8) ?[]const u8 {
        b.dependOnDirectoryContents(b.graph.cwdRelativePath(parent));
        var directory = std.Io.Dir.cwd().openDir(b.graph.io, parent, .{ .iterate = true }) catch return null;
        defer directory.close(b.graph.io);
        var iterator = directory.iterate();
        var best: ?[]const u8 = null;
        var best_version: std.SemanticVersion = .{ .major = 0, .minor = 0, .patch = 0 };
        while (iterator.next(b.graph.io) catch return null) |entry| {
            const version = std.SemanticVersion.parse(entry.name) catch std.SemanticVersion{
                .major = std.fmt.parseInt(usize, entry.name, 10) catch continue,
                .minor = 0,
                .patch = 0,
            };
            if (best == null or version.order(best_version) == .gt) {
                best = b.graph.dupeString(entry.name);
                best_version = version;
            }
        }
        return best;
    }

    fn findRuntime(b: *Build, root: []const u8, triple: []const u8, name: []const u8) ?[]const u8 {
        for ([_][]const u8{ b.fmt("usr/lib/{s}", .{triple}), b.fmt("lib/{s}", .{triple}), "usr/lib64", "lib64", "usr/lib", "lib" }) |directory| {
            const path = join(b, root, b.fmt("{s}/{s}", .{ directory, name }));
            if (exists(b, path)) return path;
        }
        return null;
    }

    fn firstExisting(b: *Build, paths: []const []const u8) ?[]const u8 {
        for (paths) |path| if (exists(b, path)) return path;
        return null;
    }

    fn exists(b: *Build, path: []const u8) bool {
        // 存在性检查依赖最近的已有父目录；不能把缺失路径或目录当作文件加入配置缓存。
        var parent = std.Io.Dir.path.dirname(path);
        while (parent) |directory| {
            const handle = std.Io.Dir.cwd().openDir(b.graph.io, directory, .{}) catch {
                parent = std.Io.Dir.path.dirname(directory);
                continue;
            };
            handle.close(b.graph.io);
            b.dependOnDirectoryContents(b.graph.cwdRelativePath(directory));
            break;
        }
        std.Io.Dir.cwd().access(b.graph.io, path, .{}) catch return false;
        return true;
    }

    fn join(b: *Build, parent: []const u8, child: []const u8) []const u8 {
        return std.Io.Dir.path.join(b.allocator, &.{ parent, child }) catch @panic("OOM");
    }
};
