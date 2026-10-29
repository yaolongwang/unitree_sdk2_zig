//! Exercise the Zig scheduling layer over local DDS, without a robot.
const std = @import("std");
const sdk = @import("unitree_sdk2");

const Cloud = sdk.messages.ros2.PointCloud2;
const AsyncPublisher = sdk.scheduling.AsyncPublisher(Cloud);
const CachedSubscriber = sdk.scheduling.CachedSubscriber(Cloud);
const RealtimePublisher = sdk.scheduling.RealtimePublisher(Cloud);
const topic = "rt/zig_scheduling_loopback";

fn timeout(milliseconds: i64) std.Io.Timeout {
    return .{ .duration = .{ .raw = .fromMilliseconds(milliseconds), .clock = .awake } };
}

const Source = struct {
    frame: [11]u8 = "owned-frame".*,
    name: [8]u8 = "position".*,
    bytes: [4]u8 = .{ 1, 2, 3, 255 },
    field: sdk.messages.ros2.PointField = sdk.messages.init(sdk.messages.ros2.PointField),

    fn message(self: *Source, marker: i32) Cloud {
        self.field.name = .{ .data = &self.name, .len = self.name.len };
        self.field.offset = 4;
        self.field.count = 3;
        self.field.datatype = @backingInt(sdk.messages.PointFieldType.float32);
        var result = sdk.messages.init(Cloud);
        result.header.frame_id = .{ .data = &self.frame, .len = self.frame.len };
        result.header.stamp.sec = marker;
        result.fields = .{ .data = &self.field, .len = 1 };
        result.data = .{ .data = &self.bytes, .len = self.bytes.len };
        result.width = 1;
        result.height = 1;
        result.point_step = 4;
        result.row_step = 4;
        result.is_dense = 1;
        return result;
    }

    fn overwrite(self: *Source) void {
        @memset(&self.frame, 'x');
        @memset(&self.name, 'y');
        @memset(&self.bytes, 0);
        self.field.count = 99;
    }
};

fn expectCloud(value: *const Cloud, marker: i32) !void {
    try std.testing.expectEqual(marker, value.header.stamp.sec);
    try std.testing.expectEqualStrings("owned-frame", value.header.frame_id.data[0..value.header.frame_id.len]);
    try std.testing.expectEqual(@as(usize, 1), value.fields.len);
    const field = value.fields.data[0];
    try std.testing.expectEqualStrings("position", field.name.data[0..field.name.len]);
    try std.testing.expectEqual(@as(u32, 3), field.count);
    try std.testing.expectEqual(@as(u32, 4), field.offset);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 255 }, value.data.data[0..value.data.len]);
}

fn waitSnapshot(subscriber: *CachedSubscriber, io: std.Io, marker: i32) !sdk.Message(Cloud) {
    const deadline = timeout(5000).toDeadline(io);
    while (true) {
        // Read the revision first: an update between these operations is either
        // observed by snapshot or makes waitForUpdate return immediately.
        const revision = subscriber.stats().revision;
        if (try subscriber.snapshot()) |owned| {
            var snapshot = owned;
            if (snapshot.value().header.stamp.sec == marker) return snapshot;
            snapshot.deinit();
        }
        _ = try subscriber.cache.waitForUpdate(revision, deadline);
    }
}

fn asyncRoundTrip(publisher: AsyncPublisher, subscriber: *CachedSubscriber, io: std.Io, marker: i32) !sdk.Message(Cloud) {
    var source: Source = .{};
    const message = source.message(marker);
    try publisher.send(&message);
    source.overwrite();
    try publisher.waitIdle(timeout(5000));
    var snapshot = try waitSnapshot(subscriber, io, marker);
    errdefer snapshot.deinit();
    try expectCloud(snapshot.value(), marker);
    try subscriber.checkLastCallback();
    return snapshot;
}

const Prepare = struct {
    calls: usize = 0,

    fn run(message: *Cloud, context: ?*anyopaque) void {
        const self: *Prepare = @ptrCast(@alignCast(context.?));
        self.calls += 1;
        message.header.stamp.sec += 1;
    }
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try sdk.ChannelFactory.init(223, "lo");
    defer sdk.ChannelFactory.deinit() catch {};

    const subscriber = try CachedSubscriber.init(allocator, io, topic, 8);
    defer subscriber.deinit();
    var publisher = try AsyncPublisher.init(allocator, io, topic, .{ .capacity = 4, .wait_us = 1_000_000 });
    defer publisher.deinit();
    const empty = sdk.messages.init(Cloud);
    try std.testing.expectError(error.Stopped, publisher.send(&empty));
    try std.testing.expectError(error.Stopped, subscriber.waitForConnection(timeout(1)));
    try subscriber.start();
    try publisher.start();
    try std.testing.expectError(error.AlreadyStarted, subscriber.start());
    try std.testing.expectError(error.AlreadyStarted, publisher.start());

    var first = try asyncRoundTrip(publisher, subscriber, io, 1);
    defer first.deinit();
    try subscriber.waitForConnection(timeout(1000));
    publisher.stop(.drain);
    subscriber.stop();
    try std.testing.expect(!publisher.stats().running);
    try std.testing.expect(subscriber.stats().closed);
    try std.testing.expectError(error.Stopped, publisher.send(&empty));
    // Stop preserves cached data; reset releases it, but neither invalidates
    // independent snapshots held by the consumer.
    var stopped = (try subscriber.snapshot()).?;
    defer stopped.deinit();
    subscriber.reset();
    try std.testing.expect((try subscriber.snapshot()) == null);
    try expectCloud(first.value(), 1);
    try expectCloud(stopped.value(), 1);

    try subscriber.start();
    try publisher.start();
    var second = try asyncRoundTrip(publisher, subscriber, io, 2);
    defer second.deinit();
    publisher.stop(.discard);
    try std.testing.expectEqual(@as(u64, 2), publisher.stats().sent);
    try std.testing.expectEqual(@as(u64, 0), publisher.stats().errors);
    try std.testing.expectEqual(@as(u64, 0), subscriber.stats().errors);
    try expectCloud(first.value(), 1);

    const realtime = try RealtimePublisher.init(allocator, io, topic, .{ .capacity = 2, .wait_us = 1_000_000 });
    defer realtime.deinit();
    var prepare: Prepare = .{};
    realtime.prepare = Prepare.run;
    realtime.prepare_context = &prepare;
    try std.testing.expect(!realtime.tryLock());
    try realtime.start();
    try std.testing.expect(realtime.tryLock());
    try std.testing.expect(!realtime.tryLock());
    var source: Source = .{};
    realtime.message = source.message(2);
    try realtime.unlockAndPublish();
    source.overwrite();
    try realtime.publisher.waitIdle(timeout(5000));
    var prepared = try waitSnapshot(subscriber, io, 3);
    defer prepared.deinit();
    try expectCloud(prepared.value(), 3);
    try std.testing.expectEqual(@as(usize, 1), prepare.calls);
    realtime.stop(.drain);
    try std.testing.expect(!realtime.tryLock());

    // A failed publish must release the edit lock, allowing the next lifecycle
    // to acquire it. The explicit lock API also works while stopped.
    realtime.lock();
    try std.testing.expectError(error.Stopped, realtime.unlockAndPublish());
    try realtime.start();
    try std.testing.expect(realtime.tryLock());
    realtime.unlock();
    realtime.stop(.discard);
    subscriber.stop();
    subscriber.reset();
    try expectCloud(second.value(), 2);
    try expectCloud(prepared.value(), 3);
    std.debug.print("Zig scheduling DDS loopback: dynamic ownership, snapshots, restart, and realtime prepare passed\n", .{});
}
