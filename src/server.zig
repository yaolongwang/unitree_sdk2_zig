//! Custom RPC servers with text/binary handlers and lease enforcement.
const raw = @import("raw");
const core = @import("core.zig");
const std = @import("std");

/// Local lease bookkeeping matching the SDK LeaseContext. Terms are microseconds.
pub const Lease = struct {
    id: i64 = 0,
    term_us: i64 = 1_000_000,

    pub fn update(self: *Lease, id: i64, term_us: i64) void {
        self.* = .{ .id = id, .term_us = term_us };
    }

    pub fn reset(self: *Lease) void {
        self.* = .{};
    }

    pub fn valid(self: Lease) bool {
        return self.id != 0;
    }
};

/// Allocate SDK topic names; the caller frees the returned sentinel slice.
pub fn requestTopic(allocator: std.mem.Allocator, service: []const u8) ![:0]u8 {
    if (service.len == 0 or std.mem.findScalar(u8, service, 0) != null) return error.InvalidArgument;
    return allocator.printSentinel("rt/api/{s}/request", .{service}, 0);
}

pub fn responseTopic(allocator: std.mem.Allocator, service: []const u8) ![:0]u8 {
    if (service.len == 0 or std.mem.findScalar(u8, service, 0) != null) return error.InvalidArgument;
    return allocator.printSentinel("rt/api/{s}/response", .{service}, 0);
}

pub const Reply = struct {
    handle: *raw.usdk_reply,

    /// Copies response bytes before the handler returns, so stack data is safe.
    pub fn set(self: Reply, data: []const u8) core.Error!void {
        try core.check(raw.usdk_reply_set(self.handle, core.bytes(data)));
    }
};

pub const Server = struct {
    handle: *raw.usdk_server,

    pub const Handler = *const fn (user: ?*anyopaque, api_id: i32, request: []const u8, reply: Reply) i32;

    pub fn init(service: []const u8, version: []const u8) core.Error!Server {
        var handle: ?*raw.usdk_server = null;
        try core.check(raw.usdk_server_create(core.string(service), core.string(version), &handle));
        return .{ .handle = handle.? };
    }

    /// Register before start(). The context must outlive the server.
    pub fn register(self: Server, api_id: i32, binary: bool, check_lease: bool, comptime handler: Handler, user: ?*anyopaque) core.Error!void {
        const Adapter = struct {
            fn callback(context: ?*anyopaque, id: i32, data: raw.usdk_bytes, reply: ?*raw.usdk_reply) callconv(.c) i32 {
                const input: []const u8 = if (data.len == 0) &.{} else data.data[0..data.len];
                return handler(context, id, input, .{ .handle = reply.? });
            }
        };
        try core.check(raw.usdk_server_register(self.handle, api_id, binary, check_lease, Adapter.callback, user));
    }

    pub fn start(self: Server, priority_queue: bool) core.Error!void {
        try core.check(raw.usdk_server_start(self.handle, priority_queue));
    }

    pub fn startLease(self: Server, term_us: i64) core.Error!void {
        try core.check(raw.usdk_server_start_lease(self.handle, term_us));
    }

    /// Meaningful only when called on the thread handling a request.
    pub fn currentApiId(self: Server) core.Error!i32 {
        var id: i32 = 0;
        try core.check(raw.usdk_server_current_api_id(self.handle, &id));
        return id;
    }

    pub fn name(self: Server) core.Error!core.Buffer {
        var result: core.Buffer = .{};
        try core.check(raw.usdk_server_name(self.handle, &result.value));
        return result;
    }

    pub fn apiVersion(self: Server) core.Error!core.Buffer {
        var result: core.Buffer = .{};
        try core.check(raw.usdk_server_api_version(self.handle, &result.value));
        return result;
    }

    pub fn deinit(self: *Server) void {
        raw.usdk_server_destroy(self.handle);
        self.* = undefined;
    }
};

pub const LeaseClient = struct {
    handle: *raw.usdk_lease_client,

    pub fn init(service: []const u8) core.Error!LeaseClient {
        var handle: ?*raw.usdk_lease_client = null;
        try core.check(raw.usdk_lease_client_create(core.string(service), &handle));
        return .{ .handle = handle.? };
    }

    pub fn waitApplied(self: LeaseClient) core.Error!void {
        try core.check(raw.usdk_lease_client_wait(self.handle));
    }

    pub fn applied(self: LeaseClient) core.Error!bool {
        var result = false;
        try core.check(raw.usdk_lease_client_applied(self.handle, &result));
        return result;
    }

    pub fn id(self: LeaseClient) core.Error!i64 {
        var result: i64 = 0;
        try core.check(raw.usdk_lease_client_id(self.handle, &result));
        return result;
    }

    pub fn setTimeout(self: LeaseClient, seconds: f32) core.Error!void {
        try core.check(raw.usdk_lease_client_set_timeout(self.handle, seconds));
    }

    pub fn setTimeoutUs(self: LeaseClient, microseconds: i64) core.Error!void {
        try core.check(raw.usdk_lease_client_set_timeout_us(self.handle, microseconds));
    }

    pub fn deinit(self: *LeaseClient) void {
        raw.usdk_lease_client_destroy(self.handle);
        self.* = undefined;
    }
};

test "lease reset and standard RPC topic naming" {
    var lease: Lease = .{};
    try std.testing.expect(!lease.valid());
    lease.update(42, 500_000);
    try std.testing.expect(lease.valid());
    lease.reset();
    try std.testing.expectEqual(@as(i64, 1_000_000), lease.term_us);
    const request = try requestTopic(std.testing.allocator, "sport");
    defer std.testing.allocator.free(request);
    try std.testing.expectEqualStrings("rt/api/sport/request", request);
    const response = try responseTopic(std.testing.allocator, "sport");
    defer std.testing.allocator.free(response);
    try std.testing.expectEqualStrings("rt/api/sport/response", response);
}
