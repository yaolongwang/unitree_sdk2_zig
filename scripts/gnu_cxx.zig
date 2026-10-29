//! 为 Zig 的 C++ 编译配置目标 GNU 头文件与运行库，不调用外部编译器。

const std = @import("std");
const Build = std.Build;
const LazyPath = Build.LazyPath;

pub const Options = struct {
    sysroot: ?[]const u8,
    gcc_version: ?[]const u8,

    pub fn fromBuild(b: *Build) Options {
        return .{
            .sysroot = b.option([]const u8, "sysroot", "Target GNU sysroot (defaults to / for native Linux builds)"),
            .gcc_version = b.option([]const u8, "gcc-version", "GNU C++ header/runtime version within the sysroot (auto-detected by default)"),
        };
    }
};

const GnuCxx = struct {
    includes: []const LazyPath,
    libraries: []const LazyPath,
};

pub const Toolchain = union(enum) {
    ready: GnuCxx,
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
                // linkSystemLibrary("stdc++") 会被 Zig 解释为 libc++；这里必须传入 GNU 库文件。
                for (gnu.libraries) |library| module.addObjectFile(library);
                module.addRPath(gnu.libraries[0].dirname());
                module.addRPath(gnu.libraries[1].dirname());
                for ([_][]const u8{ "pthread", "m", "dl" }) |name|
                    module.linkSystemLibrary(name, .{ .use_pkg_config = .no });
                artifact.link_eh_frame_hdr = true;
            },
        }
    }
};

// 固定上游 CycloneDDS 的 CDR 数据区含 4 字节前缀，64 位读写可能非对齐。
// 两种受支持的 Linux 架构均沿用上游的访问方式；仅关闭 Clang 对齐检查，保留其他检查。
pub const flags: []const []const u8 = &.{ "-std=c++17", "-nostdinc++", "-pthread", "-Wall", "-Wextra", "-fno-sanitize=alignment" };

pub fn resolve(b: *Build, target: Build.ResolvedTarget, options: Options) Toolchain {
    const host = b.graph.host.result;
    const root = options.sysroot orelse if (host.os.tag == .linux and host.cpu.arch == target.result.cpu.arch)
        "/"
    else
        return .{ .unavailable = "Native C++ requires -Dsysroot=<target GNU sysroot> when cross-compiling; Zig provides the compiler, the sysroot provides GNU headers and libraries." };

    const arch = @tagName(target.result.cpu.arch);
    const triple = findTriple(b, root, arch) orelse return .{
        .unavailable = b.fmt("No GNU runtime directory for {s} in {s}/usr/lib/gcc; provide a matching -Dsysroot.", .{ arch, root }),
    };
    const gcc_parent = join(b, root, b.fmt("usr/lib/gcc/{s}", .{triple}));
    const version = options.gcc_version orelse findVersion(b, gcc_parent) orelse return .{
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
    for ([_][]const u8{ "libstdc++.so.6", "libgcc_s.so.1" }) |name| {
        const path = findRuntime(b, root, triple, name) orelse return .{
            .unavailable = b.fmt("Missing {s} for {s} in GNU sysroot {s}.", .{ name, triple, root }),
        };
        libraries.append(b.allocator, b.graph.cwdRelativePath(path)) catch @panic("OOM");
    }
    for ([_][]const u8{ "libgcc_eh.a", "libgcc.a" }) |name| {
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
