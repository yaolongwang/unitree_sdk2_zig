//! 通用有界队列与单次完成 future，使用调用方提供的线程安全 std.Io。
//! 对象开始并发使用后不得移动；销毁前必须结束所有调用和等待者。
const std = @import("std");

/// Thread-safe FIFO with explicit ownership of accepted elements. put copies T
/// by value and transfers responsibility for its nested resources on success.
/// get and an eviction returned by put transfer that responsibility back to the
/// caller. No element is deep-copied or implicitly destroyed.
pub fn BoundedQueue(comptime T: type) type {
    return struct {
        const Self = @This();
        allocator: std.mem.Allocator,
        io: std.Io,
        slots: []T,
        mutex: std.Io.Mutex = .init,
        changed: std.Io.Condition = .init,
        head: usize = 0,
        count: usize = 0,
        waiting: usize = 0,
        interrupt_generation: u64 = 0,
        closed: bool = false,

        pub fn init(allocator: std.mem.Allocator, io: std.Io, capacity: usize) !Self {
            if (capacity == 0) return error.InvalidArgument;
            return .{ .allocator = allocator, .io = io, .slots = try allocator.alloc(T, capacity) };
        }

        /// With replace=false a full queue returns QueueFull without taking
        /// ownership. With replace=true the returned oldest element belongs to
        /// the caller and must be released or reused. null means no eviction.
        pub fn put(self: *Self, value: T, replace: bool) error{ Closed, QueueFull }!?T {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.closed) return error.Closed;
            var displaced: ?T = null;
            if (self.count == self.slots.len) {
                if (!replace) return error.QueueFull;
                displaced = self.popLocked();
            }
            self.slots[(self.head + self.count) % self.slots.len] = value;
            self.count += 1;
            self.changed.signal(self.io);
            return displaced;
        }

        /// Absolute deadlines prevent spurious wakes from extending a timeout.
        /// close permits draining queued elements, then returns Closed.
        pub fn get(self: *Self, timeout: std.Io.Timeout) !T {
            const deadline = timeout.toDeadline(self.io);
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            const generation = self.interrupt_generation;
            while (self.count == 0) {
                if (self.closed) return error.Closed;
                self.waiting += 1;
                defer self.waiting -= 1;
                try self.changed.waitTimeout(self.io, &self.mutex, deadline);
                if (self.interrupt_generation != generation) return error.Interrupted;
            }
            return self.popLocked();
        }

        pub fn size(self: *Self) usize {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            return self.count;
        }

        /// Wake all current blocked get calls with Interrupted. Future calls
        /// remain usable. This avoids ambiguous spurious-success semantics.
        pub fn interrupt(self: *Self) void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.interrupt_generation +%= 1;
            self.changed.broadcast(self.io);
        }

        /// Reject further puts and wake readers; queued items remain drainable.
        pub fn close(self: *Self) void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.closed = true;
            self.changed.broadcast(self.io);
        }

        /// Release every pending element exactly once using caller policy.
        /// release runs under the queue lock and must not re-enter this queue.
        pub fn clear(self: *Self, context: anytype, release: fn (@TypeOf(context), T) void) usize {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            const removed = self.count;
            while (self.count != 0) release(context, self.popLocked());
            return removed;
        }

        /// First close, join all users, and drain or clear all pending elements.
        /// Only the ring allocation is freed; element resources are never guessed.
        pub fn deinit(self: *Self) void {
            std.debug.assert(self.count == 0 and self.waiting == 0);
            self.allocator.free(self.slots);
            self.* = undefined;
        }

        fn popLocked(self: *Self) T {
            const result = self.slots[self.head];
            self.slots[self.head] = undefined;
            self.head = (self.head + 1) % self.slots.len;
            self.count -= 1;
            return result;
        }
    };
}

/// Single completion with shared, repeatable result reads. T is a shallow value
/// copy, not an ownership transfer: use copyable values or externally owned,
/// immutable resources that outlive the future and all result readers. Readers
/// must not independently release nested pointers/slices. Failure text is copied
/// by fail and owned by the future until deinit. No hidden T destructor is run.
pub fn Future(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const Result = union(enum) { value: T, failure: []const u8 };
        const State = union(enum) { pending, value: T, failure: []const u8, closed };
        allocator: std.mem.Allocator,
        io: std.Io,
        mutex: std.Io.Mutex = .init,
        changed: std.Io.Condition = .init,
        state: State = .pending,
        waiting: usize = 0,

        pub fn init(allocator: std.mem.Allocator, io: std.Io) Self {
            return .{ .allocator = allocator, .io = io };
        }

        /// Exactly one ready/fail call may complete the future. false means an
        /// earlier completion or close won; no resource ownership changes.
        pub fn ready(self: *Self, value: T) bool {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.state != .pending) return false;
            self.state = .{ .value = value };
            self.changed.broadcast(self.io);
            return true;
        }

        /// Allocation failure leaves the future pending. The source text may
        /// be discarded after return, even when another completion already won.
        pub fn fail(self: *Self, reason: []const u8) !bool {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.state != .pending) return false;
            self.state = .{ .failure = try self.allocator.dupe(u8, reason) };
            self.changed.broadcast(self.io);
            return true;
        }

        /// Wait for either a value or a failure. Timeout does not complete or
        /// cancel the future, so a later call may still receive the result.
        pub fn wait(self: *Self, timeout: std.Io.Timeout) !void {
            _ = try self.getResult(timeout);
        }

        /// Returned T is a shallow copy. Returned failure text borrows this
        /// future and is invalid after deinit. Repeated reads are supported.
        pub fn getResult(self: *Self, timeout: std.Io.Timeout) !Result {
            const deadline = timeout.toDeadline(self.io);
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            while (self.state == .pending) {
                self.waiting += 1;
                defer self.waiting -= 1;
                try self.changed.waitTimeout(self.io, &self.mutex, deadline);
            }
            return switch (self.state) {
                .value => |value| .{ .value = value },
                .failure => |reason| .{ .failure = reason },
                .closed => error.Closed,
                .pending => unreachable,
            };
        }

        /// Wake pending waiters with Closed. An already completed result is
        /// preserved; close never discards a successfully delivered value.
        pub fn close(self: *Self) void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.state == .pending) self.state = .closed;
            self.changed.broadcast(self.io);
        }

        /// All waiters/callers and borrowers of failure text must have finished.
        /// Call close and join users first if the future may still be pending.
        pub fn deinit(self: *Self) void {
            std.debug.assert(self.waiting == 0);
            if (self.state == .failure) self.allocator.free(self.state.failure);
            self.* = undefined;
        }
    };
}

fn timeoutMs(milliseconds: i64) std.Io.Timeout {
    return .{ .duration = .{ .raw = .fromMilliseconds(milliseconds), .clock = .awake } };
}

fn awaitWaiters(object: anytype, count: usize) !void {
    const deadline = std.Io.Clock.awake.now(std.testing.io).toNanoseconds() + 2 * std.time.ns_per_s;
    while (true) {
        object.mutex.lockUncancelable(std.testing.io);
        const waiting = object.waiting;
        object.mutex.unlock(std.testing.io);
        if (waiting == count) return;
        if (std.Io.Clock.awake.now(std.testing.io).toNanoseconds() >= deadline) return error.Timeout;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
}

test "queue eviction and rejection preserve nested resource ownership" {
    const Queue = BoundedQueue([]u8);
    var queue = try Queue.init(std.testing.allocator, std.testing.io, 1);
    defer queue.deinit();
    const first = try std.testing.allocator.dupe(u8, "first");
    const second = try std.testing.allocator.dupe(u8, "second");
    try std.testing.expect((try queue.put(first, false)) == null);
    try std.testing.expectError(error.QueueFull, queue.put(second, false));
    const displaced = (try queue.put(second, true)).?;
    try std.testing.expectEqualStrings("first", displaced);
    std.testing.allocator.free(displaced);
    queue.close();
    const result = try queue.get(.none);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("second", result);
    try std.testing.expectError(error.Closed, queue.get(.none));
    try std.testing.expectError(error.Closed, queue.put(result, false));
}

test "queue interrupts blocked readers without closing future operations" {
    const Queue = BoundedQueue(u32);
    const Reader = struct {
        queue: *Queue,
        result: ?anyerror = null,
        fn run(self: *@This()) void {
            _ = self.queue.get(.none) catch |err| {
                self.result = err;
                return;
            };
        }
    };
    var queue = try Queue.init(std.testing.allocator, std.testing.io, 2);
    defer queue.deinit();
    var readers = [_]Reader{ .{ .queue = &queue }, .{ .queue = &queue } };
    var threads: [2]std.Thread = undefined;
    var started: usize = 0;
    defer {
        queue.close();
        for (threads[0..started]) |thread| thread.join();
    }
    for (&readers, 0..) |*reader, index| {
        threads[index] = try std.Thread.spawn(.{}, Reader.run, .{reader});
        started += 1;
    }
    try awaitWaiters(&queue, 2);
    queue.interrupt();
    for (threads) |thread| thread.join();
    started = 0;
    for (readers) |reader| try std.testing.expectEqual(error.Interrupted, reader.result.?);
    try std.testing.expectError(error.Timeout, queue.get(timeoutMs(1)));
    _ = try queue.put(7, false);
    try std.testing.expectEqual(@as(u32, 7), try queue.get(.none));
}

test "queue producer wakes a consumer and clear releases each pending item once" {
    const Queue = BoundedQueue(u32);
    const Reader = struct {
        queue: *Queue,
        result: u32 = 0,
        fn run(self: *@This()) void {
            self.result = self.queue.get(.none) catch 0;
        }
        fn release(sum: *u32, value: u32) void {
            sum.* += value;
        }
    };
    var queue = try Queue.init(std.testing.allocator, std.testing.io, 3);
    defer queue.deinit();
    var reader: Reader = .{ .queue = &queue };
    const thread = try std.Thread.spawn(.{}, Reader.run, .{&reader});
    var joined = false;
    defer if (!joined) {
        queue.close();
        thread.join();
    };
    try awaitWaiters(&queue, 1);
    _ = try queue.put(42, false);
    thread.join();
    joined = true;
    try std.testing.expectEqual(@as(u32, 42), reader.result);
    _ = try queue.put(1, false);
    _ = try queue.put(2, false);
    var sum: u32 = 0;
    try std.testing.expectEqual(@as(usize, 2), queue.clear(&sum, Reader.release));
    try std.testing.expectEqual(@as(u32, 3), sum);
    try std.testing.expectEqual(@as(usize, 0), queue.clear(&sum, Reader.release));
}

test "future completion wakes all readers and duplicate completion is rejected" {
    const Value = Future(u32);
    const Reader = struct {
        future: *Value,
        result: u32 = 0,
        fn run(self: *@This()) void {
            const result = self.future.getResult(.none) catch return;
            self.result = result.value;
        }
    };
    var future = Value.init(std.testing.allocator, std.testing.io);
    defer future.deinit();
    try std.testing.expectError(error.Timeout, future.getResult(timeoutMs(1)));
    var readers = [_]Reader{ .{ .future = &future }, .{ .future = &future } };
    var threads: [2]std.Thread = undefined;
    var started: usize = 0;
    defer {
        future.close();
        for (threads[0..started]) |thread| thread.join();
    }
    for (&readers, 0..) |*reader, index| {
        threads[index] = try std.Thread.spawn(.{}, Reader.run, .{reader});
        started += 1;
    }
    try awaitWaiters(&future, 2);
    try std.testing.expect(future.ready(73));
    for (threads) |thread| thread.join();
    started = 0;
    for (readers) |reader| try std.testing.expectEqual(@as(u32, 73), reader.result);
    try std.testing.expect(!future.ready(99));
    try std.testing.expect(!try future.fail("too late"));
    future.close();
    try std.testing.expectEqual(@as(u32, 73), (try future.getResult(.none)).value);
}

test "future copies failure text and close wakes pending waiters" {
    var future = Future(u32).init(std.testing.allocator, std.testing.io);
    defer future.deinit();
    var reason = [_]u8{ 'b', 'a', 'd' };
    try std.testing.expect(try future.fail(&reason));
    @memset(&reason, 'x');
    try std.testing.expectEqualStrings("bad", (try future.getResult(.none)).failure);
    try std.testing.expect(!future.ready(7));
    var pending = Future(u32).init(std.testing.allocator, std.testing.io);
    defer pending.deinit();
    const Waiter = struct {
        future: *Future(u32),
        result: ?anyerror = null,
        fn run(self: *@This()) void {
            self.future.wait(.none) catch |err| {
                self.result = err;
            };
        }
    };
    var waiter: Waiter = .{ .future = &pending };
    const thread = try std.Thread.spawn(.{}, Waiter.run, .{&waiter});
    var joined = false;
    defer if (!joined) {
        pending.close();
        thread.join();
    };
    try awaitWaiters(&pending, 1);
    pending.close();
    thread.join();
    joined = true;
    try std.testing.expectEqual(error.Closed, waiter.result.?);
    try std.testing.expect(!pending.ready(1));
}
