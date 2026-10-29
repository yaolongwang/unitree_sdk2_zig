//! Ownership and errors for the SDK C ABI. Owning values must be deinitialized
//! exactly once; copying a handle does not transfer or duplicate ownership.
const std = @import("std");
const raw = @import("raw");

pub const Error = error{
    InvalidArgument,
    NativeException,
    OutOfMemory,
    Unsupported,
    Timeout,
    RemoteError,
};

/// Positive status codes are preserved by lastStatus() and the raw C API.
pub fn check(status: i32) Error!void {
    switch (status) {
        0 => {},
        -1 => return error.InvalidArgument,
        -2 => return error.NativeException,
        -3 => return error.OutOfMemory,
        -4 => return error.Unsupported,
        -5, 3104 => return error.Timeout,
        else => return error.RemoteError,
    }
}

/// Error text is thread-local and valid until the next FFI operation.
pub fn lastError() []const u8 {
    return std.mem.span(raw.usdk_last_error());
}

pub fn lastStatus() i32 {
    return raw.usdk_last_status();
}

pub fn string(value: []const u8) raw.usdk_string {
    return .{ .data = value.ptr, .len = value.len };
}

pub fn bytes(value: []const u8) raw.usdk_bytes {
    return .{ .data = value.ptr, .len = value.len };
}

pub const Buffer = struct {
    value: raw.usdk_buffer = .{ .data = null, .len = 0 },

    pub fn copy(value: []const u8) Error!Buffer {
        var result: Buffer = .{};
        try check(raw.usdk_buffer_copy(bytes(value), &result.value));
        return result;
    }

    pub fn slice(self: Buffer) []const u8 {
        if (self.value.len == 0) return &.{};
        return self.value.data[0..self.value.len];
    }

    pub fn deinit(self: *Buffer) void {
        raw.usdk_buffer_free(&self.value);
    }
};

/// Global DDS factory. All clients and channels must be destroyed before deinit.
pub const ChannelFactory = struct {
    pub fn init(domain: u32, network_interface: ?[:0]const u8) Error!void {
        try check(raw.usdk_channel_init(domain, if (network_interface) |name| name.ptr else null));
    }

    pub fn initConfigFile(filename: [:0]const u8) Error!void {
        try check(raw.usdk_channel_init_config_file(filename.ptr));
    }

    /// JSON configuration follows Unitree's DdsParameter schema, including QoS.
    pub fn initConfigJson(json: []const u8) Error!void {
        try check(raw.usdk_channel_init_config_json(string(json)));
    }

    pub fn deinit() Error!void {
        try check(raw.usdk_channel_release());
    }
};

pub const Client = struct {
    handle: *raw.usdk_client,

    /// Creates a custom RPC client. Register each API before calling it.
    pub fn init(service: []const u8, version: []const u8, enable_lease: bool) Error!Client {
        var handle: ?*raw.usdk_client = null;
        try check(raw.usdk_client_create(string(service), string(version), enable_lease, &handle));
        return .{ .handle = handle.? };
    }

    pub fn deinit(self: *Client) void {
        raw.usdk_client_destroy(self.handle);
        self.* = undefined;
    }

    pub fn setTimeout(self: Client, seconds: f32) Error!void {
        try check(raw.usdk_client_set_timeout(self.handle, seconds));
    }

    pub fn setTimeoutUs(self: Client, microseconds: i64) Error!void {
        try check(raw.usdk_client_set_timeout_us(self.handle, microseconds));
    }

    pub fn apiVersion(self: Client) Error!Buffer {
        var result: Buffer = .{};
        try check(raw.usdk_client_api_version(self.handle, &result.value));
        return result;
    }

    pub fn serverApiVersion(self: Client) Error!Buffer {
        var result: Buffer = .{};
        try check(raw.usdk_client_server_api_version(self.handle, &result.value));
        return result;
    }

    pub fn waitLease(self: Client) Error!void {
        try check(raw.usdk_client_wait_lease(self.handle));
    }

    pub fn leaseId(self: Client) Error!i64 {
        var result: i64 = 0;
        try check(raw.usdk_client_lease_id(self.handle, &result));
        return result;
    }

    pub fn registerApi(self: Client, api_id: i32, priority: i32) Error!void {
        try check(raw.usdk_client_register_api(self.handle, api_id, priority));
    }

    pub fn call(self: Client, api_id: i32, parameter: []const u8) Error!Buffer {
        var result: Buffer = .{};
        try check(raw.usdk_client_call(self.handle, api_id, string(parameter), &result.value));
        return result;
    }

    pub fn callBinary(self: Client, api_id: i32, parameter: []const u8) Error!Buffer {
        var result: Buffer = .{};
        try check(raw.usdk_client_call_binary(self.handle, api_id, bytes(parameter), &result.value));
        return result;
    }

    /// Sends a request with the SDK no-reply policy.
    pub fn send(self: Client, api_id: i32, parameter: []const u8) Error!void {
        try check(raw.usdk_client_send(self.handle, api_id, string(parameter)));
    }

    pub fn sendBinary(self: Client, api_id: i32, parameter: []const u8) Error!void {
        try check(raw.usdk_client_send_binary(self.handle, api_id, bytes(parameter)));
    }

    pub fn sendMixed(self: Client, api_id: i32, parameter: []const u8, binary: []const u8) Error!void {
        try check(raw.usdk_client_send_mixed(self.handle, api_id, string(parameter), bytes(binary)));
    }
};

test "status translation preserves SDK timeout and distinguishes bridge errors" {
    try check(0);
    try std.testing.expectError(error.InvalidArgument, check(-1));
    try std.testing.expectError(error.Timeout, check(3104));
    try std.testing.expectError(error.RemoteError, check(3205));
}
