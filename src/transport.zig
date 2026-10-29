//! Advanced RPC transport with explicit DDS request/response headers and futures.
//! Owning handles must not be copied. All timeouts and lease terms use microseconds.
const raw = @import("raw");
const core = @import("core.zig");
const messages = @import("messages.zig");
const channel = @import("channel.zig");

pub const ClientStub = struct {
    handle: ?*raw.usdk_client_stub,

    pub fn init(service: []const u8) core.Error!ClientStub {
        var result: ClientStub = .{ .handle = null };
        try core.check(raw.usdk_client_stub_create(core.string(service), &result.handle));
        return result;
    }

    /// Send without making a response future. The caller sets noreply if desired.
    pub fn send(self: ClientStub, request: *const messages.api.Request, timeout_us: i64) core.Error!void {
        try core.check(raw.usdk_client_stub_send(self.handle, request, timeout_us));
    }

    /// The request ID must be unique among this client's outstanding requests.
    /// timeout_us controls the DDS write, while RequestFuture.wait controls the reply.
    pub fn sendRequest(self: ClientStub, request: *const messages.api.Request, timeout_us: i64) core.Error!RequestFuture {
        var result: RequestFuture = .{ .handle = null };
        try core.check(raw.usdk_client_stub_request(self.handle, request, timeout_us, &result.handle));
        return result;
    }

    pub fn deinit(self: *ClientStub) void {
        raw.usdk_client_stub_destroy(self.handle);
        self.handle = null;
    }
};

pub const RequestFuture = struct {
    handle: ?*raw.usdk_request_future,

    pub fn init(request_id: i64) core.Error!RequestFuture {
        var result: RequestFuture = .{ .handle = null };
        try core.check(raw.usdk_future_create(request_id, &result.handle));
        return result;
    }

    /// Set before setQueue, wait, ready, or sharing with another thread.
    pub fn setId(self: RequestFuture, request_id: i64) core.Error!void {
        try core.check(raw.usdk_future_set_id(self.handle, request_id));
    }

    pub fn id(self: RequestFuture) core.Error!i64 {
        var result: i64 = 0;
        try core.check(raw.usdk_future_id(self.handle, &result));
        return result;
    }

    /// Returns an owned deep copy, independent of both the future and its client.
    /// Zero waits indefinitely. Timeout is terminal, removes this future's queue
    /// entry and makes later ready calls no-ops. Do not reuse a timed-out request.
    pub fn wait(self: RequestFuture, timeout_us: i64) core.Error!channel.Message(messages.api.Response) {
        var handle: ?*raw.usdk_owned_message = null;
        try core.check(raw.usdk_future_wait(self.handle, timeout_us, &handle));
        return .{ .handle = handle };
    }

    /// Complete a manually created future. The response is copied before returning.
    /// The first response or timeout wins; subsequent completions are ignored.
    pub fn ready(self: RequestFuture, response: *const messages.api.Response) core.Error!void {
        try core.check(raw.usdk_future_ready(self.handle, response));
    }

    /// Associates and inserts an unused future; a separate put is not necessary.
    /// Returns false after a successful association, wait or ready. The future
    /// holds only a weak queue reference, so pending entries cannot retain a queue.
    pub fn setQueue(self: RequestFuture, queue: *FutureQueue) core.Error!bool {
        var accepted = false;
        try core.check(raw.usdk_future_set_queue(self.handle, queue.handle, &accepted));
        return accepted;
    }

    pub fn deinit(self: *RequestFuture) void {
        raw.usdk_future_destroy(self.handle);
        self.handle = null;
    }
};

pub const FutureQueue = struct {
    handle: ?*raw.usdk_future_queue,

    pub fn init() core.Error!FutureQueue {
        var result: FutureQueue = .{ .handle = null };
        try core.check(raw.usdk_future_queue_create(&result.handle));
        return result;
    }

    /// Follows upstream Put semantics, including its duplicate-ID result.
    pub fn put(self: FutureQueue, request_id: i64, future: RequestFuture) core.Error!bool {
        var inserted = false;
        try core.check(raw.usdk_future_queue_put(self.handle, request_id, future.handle, &inserted));
        return inserted;
    }

    /// The returned handle owns its reference and must be deinitialized separately.
    pub fn get(self: FutureQueue, request_id: i64) core.Error!?RequestFuture {
        var handle: ?*raw.usdk_request_future = null;
        try core.check(raw.usdk_future_queue_get(self.handle, request_id, &handle));
        return if (handle != null) .{ .handle = handle } else null;
    }

    pub fn remove(self: FutureQueue, request_id: i64) core.Error!void {
        try core.check(raw.usdk_future_queue_remove(self.handle, request_id));
    }

    pub fn size(self: FutureQueue) core.Error!usize {
        var result: usize = 0;
        try core.check(raw.usdk_future_queue_size(self.handle, &result));
        return result;
    }

    pub fn deinit(self: *FutureQueue) void {
        raw.usdk_future_queue_destroy(self.handle);
        self.handle = null;
    }
};

/// A borrowed sender supplied to ServerStub callbacks. It has no destroy operation.
pub const ResponseSender = struct {
    handle: ?*raw.usdk_server_stub,

    pub fn send(self: ResponseSender, response: *const messages.api.Response, timeout_us: i64) core.Error!void {
        try core.check(raw.usdk_server_stub_send(self.handle, response, timeout_us));
    }
};

pub const ServerStub = struct {
    handle: ?*raw.usdk_server_stub,

    /// Starts receiving immediately. Context must outlive the stub. The request view
    /// expires when callback returns; use channel.Message(Request).clone to retain it.
    pub fn init(
        service: []const u8,
        comptime Context: type,
        context: *Context,
        comptime callback: fn (*Context, ResponseSender, *const messages.api.Request) void,
        priority_queue: bool,
    ) core.Error!ServerStub {
        const Adapter = struct {
            fn invoke(server: ?*raw.usdk_server_stub, request: [*c]const messages.api.Request, user: ?*anyopaque) callconv(.c) void {
                callback(@ptrCast(@alignCast(user.?)), .{ .handle = server }, @ptrCast(request));
            }
        };
        var result: ServerStub = .{ .handle = null };
        try core.check(raw.usdk_server_stub_create(core.string(service), Adapter.invoke, context, priority_queue, &result.handle));
        return result;
    }

    pub fn sender(self: ServerStub) ResponseSender {
        return .{ .handle = self.handle };
    }

    pub fn checkLastCallback(self: ServerStub) core.Error!void {
        try core.check(raw.usdk_server_stub_last_error(self.handle));
    }

    pub fn deinit(self: *ServerStub) void {
        raw.usdk_server_stub_destroy(self.handle);
        self.handle = null;
    }
};

pub const LeaseServer = struct {
    handle: ?*raw.usdk_lease_server,

    pub fn init(service: []const u8, term_us: i64) core.Error!LeaseServer {
        var result: LeaseServer = .{ .handle = null };
        try core.check(raw.usdk_lease_server_create(core.string(service), term_us, &result.handle));
        return result;
    }

    pub fn start(self: LeaseServer, priority_queue: bool) core.Error!void {
        try core.check(raw.usdk_lease_server_start(self.handle, priority_queue));
    }

    pub fn denied(self: LeaseServer, lease_id: i64) core.Error!bool {
        var result = false;
        try core.check(raw.usdk_lease_server_denied(self.handle, lease_id, &result));
        return result;
    }

    pub fn name(self: LeaseServer) core.Error!core.Buffer {
        var result: core.Buffer = .{};
        try core.check(raw.usdk_lease_server_name(self.handle, &result.value));
        return result;
    }

    pub fn deinit(self: *LeaseServer) void {
        raw.usdk_lease_server_destroy(self.handle);
        self.handle = null;
    }
};

/// Local upstream lease bookkeeping. Synchronize access when sharing this handle.
pub const LeaseCache = struct {
    handle: ?*raw.usdk_lease_cache,

    pub fn init() core.Error!LeaseCache {
        var result: LeaseCache = .{ .handle = null };
        try core.check(raw.usdk_lease_cache_create(&result.handle));
        return result;
    }

    pub fn set(self: LeaseCache, lease_id: i64, lease_name: []const u8, last_modified_us: i64) core.Error!void {
        try core.check(raw.usdk_lease_cache_set(self.handle, lease_id, core.string(lease_name), last_modified_us));
    }

    pub fn renew(self: LeaseCache, last_modified_us: i64) core.Error!void {
        try core.check(raw.usdk_lease_cache_renew(self.handle, last_modified_us));
    }

    pub fn clear(self: LeaseCache) core.Error!void {
        try core.check(raw.usdk_lease_cache_clear(self.handle));
    }

    pub fn id(self: LeaseCache) core.Error!i64 {
        var result: i64 = 0;
        try core.check(raw.usdk_lease_cache_id(self.handle, &result));
        return result;
    }

    pub fn lastModified(self: LeaseCache) core.Error!i64 {
        var result: i64 = 0;
        try core.check(raw.usdk_lease_cache_last_modified(self.handle, &result));
        return result;
    }

    pub fn name(self: LeaseCache) core.Error!core.Buffer {
        var result: core.Buffer = .{};
        try core.check(raw.usdk_lease_cache_name(self.handle, &result.value));
        return result;
    }

    pub fn deinit(self: *LeaseCache) void {
        raw.usdk_lease_cache_destroy(self.handle);
        self.handle = null;
    }
};
