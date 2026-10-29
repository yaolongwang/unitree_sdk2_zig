//! Typed DDS channels. Initialize the process-wide factory before creating them.
//! Handles own resources and must not be copied. Close all channels before release.
const raw = @import("raw");
const core = @import("core.zig");
const messages = @import("messages.zig");
const std = @import("std");

pub const Info = struct {
    /// Static library storage, valid for the library lifetime.
    dds_name: [:0]const u8,
    size: usize,
};

pub fn info(comptime T: type) !Info {
    var name: [*c]const u8 = null;
    var size: usize = 0;
    try core.check(raw.usdk_message_info(messages.typeId(T), &name, &size));
    return .{ .dds_name = std.mem.span(name), .size = size };
}

/// Validate sequence pointers, lengths, and boolean values without network I/O.
pub fn validate(comptime T: type, value: *const T) !void {
    try core.check(raw.usdk_message_validate(messages.typeId(T), value));
}

/// A deep copy of a message, including all nested strings and sequences.
pub fn Message(comptime T: type) type {
    return struct {
        const Self = @This();
        handle: ?*raw.usdk_owned_message,

        pub fn clone(source: *const T) !Self {
            var handle: ?*raw.usdk_owned_message = null;
            try core.check(raw.usdk_message_clone(messages.typeId(T), source, &handle));
            return .{ .handle = handle };
        }

        /// The returned view remains valid until deinit; nested storage is read-only.
        pub fn value(self: Self) *const T {
            return @ptrCast(@alignCast(raw.usdk_message_data(self.handle).?));
        }

        pub fn deinit(self: *Self) void {
            raw.usdk_message_destroy(self.handle);
            self.handle = null;
        }
    };
}

pub fn Publisher(comptime T: type) type {
    return struct {
        const Self = @This();
        handle: ?*raw.usdk_publisher,

        pub fn init(topic_name: [:0]const u8) !Self {
            var handle: ?*raw.usdk_publisher = null;
            try core.check(raw.usdk_publisher_create(messages.typeId(T), topic_name, &handle));
            return .{ .handle = handle };
        }

        /// Copies the view into the native message before publishing.
        /// wait_us is the SDK's subscriber-match timeout in microseconds.
        pub fn write(self: Self, message: *const T, wait_us: i64) !void {
            try core.check(raw.usdk_publisher_write(self.handle, message, wait_us));
        }

        /// Borrowed until this publisher is destroyed.
        pub fn topic(self: Self) ![]const u8 {
            var name: raw.usdk_string = undefined;
            try core.check(raw.usdk_publisher_topic(self.handle, &name));
            return name.data[0..name.len];
        }

        pub fn deinit(self: *Self) void {
            raw.usdk_publisher_destroy(self.handle);
            self.handle = null;
        }
    };
}

pub fn Subscriber(comptime T: type) type {
    return struct {
        const Self = @This();
        handle: ?*raw.usdk_subscriber,

        /// callback runs on an SDK thread. Its view is borrowed only for that call.
        /// context must outlive this subscriber. Do not deinit inside the callback.
        pub fn init(
            topic_name: [:0]const u8,
            comptime Context: type,
            context: *Context,
            comptime callback: fn (*Context, *const T) void,
            queue_len: i64,
        ) !Self {
            const Adapter = struct {
                fn invoke(message: ?*const anyopaque, user: ?*anyopaque) callconv(.c) void {
                    callback(@ptrCast(@alignCast(user.?)), @ptrCast(@alignCast(message.?)));
                }
            };
            var handle: ?*raw.usdk_subscriber = null;
            try core.check(raw.usdk_subscriber_create(messages.typeId(T), topic_name, Adapter.invoke, context, queue_len, &handle));
            return .{ .handle = handle };
        }

        /// Monotonic nanoseconds at the last bridge callback entry; zero before any.
        /// Safe to query concurrently with delivery while the handle remains alive.
        pub fn lastDataTime(self: Self) !i64 {
            var value: i64 = 0;
            try core.check(raw.usdk_subscriber_last_data_time(self.handle, &value));
            return value;
        }

        /// Borrowed until this subscriber is destroyed.
        pub fn topic(self: Self) ![]const u8 {
            var name: raw.usdk_string = undefined;
            try core.check(raw.usdk_subscriber_topic(self.handle, &name));
            return name.data[0..name.len];
        }

        /// Check conversion errors in the most recent native callback.
        pub fn checkLastCallback(self: Self) !void {
            try core.check(raw.usdk_subscriber_last_error(self.handle));
        }

        pub fn deinit(self: *Self) void {
            raw.usdk_subscriber_destroy(self.handle);
            self.handle = null;
        }
    };
}
