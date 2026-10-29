//! Owned asynchronous publishing, synchronized state snapshots and periodic work.
//! Pass a thread-safe std.Io (for example std.Io.Threaded.io()). The Io instance,
//! callback contexts and allocators must outlive every object using them.
//! Lifecycle calls (start/stop/deinit) must be serialized by their owner. Do not
//! stop or deinit an object from its own worker/callback thread.
const std = @import("std");
const channel = @import("channel.zig");
const core = @import("core.zig");

pub const Overflow = enum { reject_new, drop_oldest };
pub const StopMode = enum { drain, discard };

pub const QueueStats = struct {
    accepted: u64 = 0,
    sent: u64 = 0,
    dropped: u64 = 0,
    errors: u64 = 0,
    queued: usize = 0,
    in_flight: bool = false,
    running: bool = false,
    last_error: ?anyerror = null,
    /// Original SDK status, captured on the worker that observed the failure.
    last_status: i32 = 0,
};

/// An owned FIFO worker. Sender supplies send(*const Item), release(*Item),
/// deinit(), and optionally lastStatus(). Successful enqueue transfers the item
/// to this queue; failed enqueue leaves ownership with the caller.
pub fn QueuedSender(comptime Item: type, comptime Sender: type) type {
    return struct {
        const Self = @This();
        allocator: std.mem.Allocator,
        io: std.Io,
        sender: Sender,
        slots: []Item,
        overflow: Overflow,
        mutex: std.Io.Mutex = .init,
        changed: std.Io.Condition = .init,
        thread: ?std.Thread = null,
        head: usize = 0,
        count: usize = 0,
        stopping: bool = true,
        drain: bool = false,
        metrics: QueueStats = .{},

        /// Takes ownership of sender on success. Capacity must be nonzero.
        pub fn init(allocator: std.mem.Allocator, io: std.Io, sender: Sender, capacity: usize, overflow: Overflow) !*Self {
            if (capacity == 0) return error.InvalidArgument;
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);
            const slots = try allocator.alloc(Item, capacity);
            self.* = .{ .allocator = allocator, .io = io, .sender = sender, .slots = slots, .overflow = overflow };
            return self;
        }

        pub fn start(self: *Self) !void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.thread != null) return error.AlreadyStarted;
            self.stopping = false;
            self.drain = false;
            self.metrics.running = true;
            self.thread = std.Thread.spawn(.{}, run, .{self}) catch |err| {
                self.stopping = true;
                self.metrics.running = false;
                return err;
            };
        }

        pub fn enqueue(self: *Self, item: Item) error{ Stopped, QueueFull }!void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.stopping or self.thread == null) return error.Stopped;
            if (self.count == self.slots.len) {
                self.metrics.dropped +|= 1;
                if (self.overflow == .reject_new) return error.QueueFull;
                var previous = self.popLocked();
                Sender.release(&previous);
            }
            self.slots[(self.head + self.count) % self.slots.len] = item;
            self.count += 1;
            self.metrics.accepted +|= 1;
            // Idle waiters share this condition; wake the worker as well.
            self.changed.broadcast(self.io);
        }

        /// Wait until all accepted items have been processed or discarded.
        pub fn waitIdle(self: *Self, timeout: std.Io.Timeout) !void {
            const deadline = timeout.toDeadline(self.io);
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            while (self.count != 0 or self.metrics.in_flight) {
                try self.changed.waitTimeout(self.io, &self.mutex, deadline);
            }
        }

        /// Discard pending items. An in-flight send is allowed to finish.
        pub fn clear(self: *Self) usize {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            const count = self.count;
            self.clearLocked();
            self.changed.broadcast(self.io);
            return count;
        }

        /// Stops accepting new work, wakes the worker and joins it. drain sends
        /// pending work; discard releases it. Either mode waits for an in-flight
        /// native send, so use a finite DDS write timeout for bounded shutdown.
        pub fn stop(self: *Self, mode: StopMode) void {
            self.mutex.lockUncancelable(self.io);
            self.stopping = true;
            self.drain = mode == .drain;
            if (!self.drain) self.clearLocked();
            const thread = self.thread;
            self.changed.broadcast(self.io);
            self.mutex.unlock(self.io);
            if (thread) |worker| worker.join();
            self.mutex.lockUncancelable(self.io);
            self.thread = null;
            self.metrics.running = false;
            self.mutex.unlock(self.io);
        }

        pub fn stats(self: *Self) QueueStats {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            var result = self.metrics;
            result.queued = self.count;
            return result;
        }

        pub fn resetStats(self: *Self) void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.metrics = .{ .running = self.metrics.running, .in_flight = self.metrics.in_flight };
        }

        pub fn deinit(self: *Self) void {
            self.stop(.discard);
            self.sender.deinit();
            const allocator = self.allocator;
            allocator.free(self.slots);
            allocator.destroy(self);
        }

        fn clearLocked(self: *Self) void {
            while (self.count != 0) {
                var item = self.popLocked();
                Sender.release(&item);
                self.metrics.dropped +|= 1;
            }
        }

        fn popLocked(self: *Self) Item {
            const item = self.slots[self.head];
            self.head = (self.head + 1) % self.slots.len;
            self.count -= 1;
            return item;
        }

        fn run(self: *Self) void {
            self.mutex.lockUncancelable(self.io);
            while (true) {
                while (self.count == 0 and !self.stopping)
                    self.changed.waitUncancelable(self.io, &self.mutex);
                if (self.stopping and (!self.drain or self.count == 0)) break;
                var item = self.popLocked();
                self.metrics.in_flight = true;
                self.mutex.unlock(self.io);

                var failure: ?anyerror = null;
                var status: i32 = 0;
                self.sender.send(&item) catch |err| {
                    failure = err;
                    if (@hasDecl(Sender, "lastStatus")) status = self.sender.lastStatus();
                };
                Sender.release(&item);

                self.mutex.lockUncancelable(self.io);
                self.metrics.in_flight = false;
                if (failure) |err| {
                    self.metrics.errors +|= 1;
                    self.metrics.last_error = err;
                    self.metrics.last_status = status;
                } else self.metrics.sent +|= 1;
                self.changed.broadcast(self.io);
            }
            self.metrics.running = false;
            self.changed.broadcast(self.io);
            self.mutex.unlock(self.io);
        }
    };
}

pub const PublisherOptions = struct {
    capacity: usize = 1,
    overflow: Overflow = .reject_new,
    wait_us: i64 = 0,
};

fn DdsSender(comptime T: type) type {
    return struct {
        publisher: channel.Publisher(T),
        wait_us: i64,
        fn send(self: *@This(), item: *const channel.Message(T)) !void {
            try self.publisher.write(item.value(), self.wait_us);
        }
        fn release(item: *channel.Message(T)) void {
            item.deinit();
        }
        pub fn lastStatus(_: *@This()) i32 {
            return core.lastStatus();
        }
        fn deinit(self: *@This()) void {
            self.publisher.deinit();
        }
    };
}

/// Deep-copies each submitted DDS message before returning to the producer.
/// The queue owns nested strings/sequences until send or drop completes.
pub fn AsyncPublisher(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const Queue = QueuedSender(channel.Message(T), DdsSender(T));
        queue: *Queue,

        pub fn init(allocator: std.mem.Allocator, io: std.Io, topic: [:0]const u8, options: PublisherOptions) !Self {
            var sender: DdsSender(T) = .{ .publisher = try channel.Publisher(T).init(topic), .wait_us = options.wait_us };
            errdefer sender.deinit();
            return .{ .queue = try Queue.init(allocator, io, sender, options.capacity, options.overflow) };
        }

        pub fn start(self: Self) !void {
            try self.queue.start();
        }

        pub fn send(self: Self, message: *const T) !void {
            var owned = try channel.Message(T).clone(message);
            errdefer owned.deinit();
            try self.queue.enqueue(owned);
        }

        pub fn waitIdle(self: Self, timeout: std.Io.Timeout) !void {
            try self.queue.waitIdle(timeout);
        }

        pub fn stats(self: Self) QueueStats {
            return self.queue.stats();
        }

        pub fn clear(self: Self) usize {
            return self.queue.clear();
        }

        pub fn stop(self: Self, mode: StopMode) void {
            self.queue.stop(mode);
        }

        pub fn deinit(self: *Self) void {
            self.queue.deinit();
            self.* = undefined;
        }
    };
}

/// Editable message plus the upstream lock/unlock-and-publish protocol. The
/// object has a stable heap address. Nested message views must remain valid
/// while editing; unlockAndPublish clones them before releasing the edit lock.
pub fn RealtimePublisher(comptime T: type) type {
    return struct {
        const Self = @This();
        allocator: std.mem.Allocator,
        io: std.Io,
        publisher: AsyncPublisher(T),
        mutex: std.Io.Mutex = .init,
        message: T,
        prepare: ?*const fn (*T, ?*anyopaque) void = null,
        prepare_context: ?*anyopaque = null,

        pub fn init(allocator: std.mem.Allocator, io: std.Io, topic: [:0]const u8, options: PublisherOptions) !*Self {
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);
            self.* = .{ .allocator = allocator, .io = io, .publisher = try AsyncPublisher(T).init(allocator, io, topic, options), .message = std.mem.zeroes(T) };
            return self;
        }

        pub fn start(self: *Self) !void {
            try self.publisher.start();
        }

        /// Returns false while stopped or another producer owns the edit lock.
        pub fn tryLock(self: *Self) bool {
            if (!self.mutex.tryLock()) return false;
            if (!self.publisher.stats().running) {
                self.mutex.unlock(self.io);
                return false;
            }
            return true;
        }

        pub fn lock(self: *Self) void {
            self.mutex.lockUncancelable(self.io);
        }

        pub fn unlock(self: *Self) void {
            self.mutex.unlock(self.io);
        }

        /// Always releases the edit lock, including on clone/queue failure.
        pub fn unlockAndPublish(self: *Self) !void {
            defer self.unlock();
            if (self.prepare) |prepare| prepare(&self.message, self.prepare_context);
            try self.publisher.send(&self.message);
        }

        pub fn stop(self: *Self, mode: StopMode) void {
            self.publisher.stop(mode);
        }

        pub fn stats(self: *Self) QueueStats {
            return self.publisher.stats();
        }

        pub fn deinit(self: *Self) void {
            self.publisher.deinit();
            self.allocator.destroy(self);
        }
    };
}

pub const CacheStats = struct {
    revision: u64 = 0,
    received: u64 = 0,
    errors: u64 = 0,
    has_value: bool = false,
    closed: bool = false,
    last_received_ns: ?i96 = null,
    last_error: ?anyerror = null,
    last_status: i32 = 0,
};

/// Storage supplies Owned, clone(*const Value), read(*const Owned), release,
/// and optionally lastStatus. The cache owns its stored value; snapshot() gives
/// callers an independent owned copy, never an unlocked borrowed pointer.
/// clone and release can run on different caller threads; Storage and any
/// shared allocator or context they use must support that concurrency.
pub fn SnapshotCache(comptime Value: type, comptime Storage: type) type {
    return struct {
        const Self = @This();
        io: std.Io,
        storage: Storage,
        mutex: std.Io.Mutex = .init,
        changed: std.Io.Condition = .init,
        current: ?Storage.Owned = null,
        metrics: CacheStats = .{},

        pub fn init(io: std.Io, storage: Storage) Self {
            return .{ .io = io, .storage = storage };
        }

        pub fn update(self: *Self, value: *const Value) !void {
            var next = self.storage.clone(value) catch |err| {
                var status: i32 = 0;
                if (@hasDecl(Storage, "lastStatus")) status = self.storage.lastStatus();
                self.mutex.lockUncancelable(self.io);
                self.metrics.errors +|= 1;
                self.metrics.last_error = err;
                self.metrics.last_status = status;
                self.changed.broadcast(self.io);
                self.mutex.unlock(self.io);
                return err;
            };
            errdefer Storage.release(&next);
            self.mutex.lockUncancelable(self.io);
            if (self.metrics.closed) {
                self.mutex.unlock(self.io);
                return error.Stopped;
            }
            var previous = self.current;
            self.current = next;
            self.metrics.revision +|= 1;
            self.metrics.received +|= 1;
            self.metrics.has_value = true;
            self.metrics.last_received_ns = std.Io.Clock.awake.now(self.io).toNanoseconds();
            self.changed.broadcast(self.io);
            self.mutex.unlock(self.io);
            if (previous) |*owned| Storage.release(owned);
        }

        pub fn snapshot(self: *Self) !?Storage.Owned {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.current) |*owned| return try self.storage.clone(Storage.read(owned));
            return null;
        }

        /// Runs a short callback while holding the cache lock. Do not retain
        /// pointers or call back into this cache from callback.
        pub fn withLatest(self: *Self, comptime Result: type, comptime Context: type, context: *Context, callback: fn (*Context, *const Value) Result) ?Result {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.current) |*owned| return callback(context, Storage.read(owned));
            return null;
        }

        pub fn waitForUpdate(self: *Self, after_revision: u64, timeout: std.Io.Timeout) !u64 {
            const deadline = timeout.toDeadline(self.io);
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.metrics.closed) return error.Stopped;
            while (!self.metrics.has_value or self.metrics.revision <= after_revision) {
                if (self.metrics.closed) return error.Stopped;
                try self.changed.waitTimeout(self.io, &self.mutex, deadline);
            }
            return self.metrics.revision;
        }

        pub fn stats(self: *Self) CacheStats {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            return self.metrics;
        }

        pub fn isTimeout(self: *Self, timeout_ms: u32) bool {
            const latest = self.stats().last_received_ns orelse return true;
            const now = std.Io.Clock.awake.now(self.io).toNanoseconds();
            return @as(i128, now) - latest > @as(i128, timeout_ms) * std.time.ns_per_ms;
        }

        pub fn reset(self: *Self) void {
            self.mutex.lockUncancelable(self.io);
            var previous = self.current;
            self.current = null;
            self.metrics.has_value = false;
            self.metrics.last_received_ns = null;
            self.metrics.revision +|= 1;
            self.changed.broadcast(self.io);
            self.mutex.unlock(self.io);
            if (previous) |*owned| Storage.release(owned);
        }

        pub fn close(self: *Self) void {
            self.mutex.lockUncancelable(self.io);
            self.metrics.closed = true;
            self.changed.broadcast(self.io);
            self.mutex.unlock(self.io);
        }

        pub fn reopen(self: *Self) void {
            self.mutex.lockUncancelable(self.io);
            self.metrics.closed = false;
            self.mutex.unlock(self.io);
        }

        /// Join callers/waiters before destroying the cache itself.
        pub fn deinit(self: *Self) void {
            self.close();
            self.reset();
        }
    };
}

fn DdsStorage(comptime T: type) type {
    return struct {
        pub const Owned = channel.Message(T);
        fn clone(_: @This(), value: *const T) !Owned {
            return Owned.clone(value);
        }
        fn read(owned: *const Owned) *const T {
            return owned.value();
        }
        fn release(owned: *Owned) void {
            owned.deinit();
        }
        pub fn lastStatus(_: @This()) i32 {
            return core.lastStatus();
        }
    };
}

pub fn StateCache(comptime T: type) type {
    return SnapshotCache(T, DdsStorage(T));
}

/// Stable callback context, owned topic name and synchronized latest message.
/// init allocates resources; start begins DDS reception. stop joins callbacks,
/// preserves the last snapshot and can be followed by start. reset drops data.
pub fn CachedSubscriber(comptime T: type) type {
    return struct {
        const Self = @This();
        allocator: std.mem.Allocator,
        io: std.Io,
        topic: [:0]u8,
        queue_len: i64,
        timeout_ms: std.atomic.Value(u32) = .init(1000),
        native: ?channel.Subscriber(T) = null,
        cache: StateCache(T),

        pub fn init(allocator: std.mem.Allocator, io: std.Io, topic: [:0]const u8, queue_len: i64) !*Self {
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);
            const owned_topic = try allocator.dupeSentinel(u8, topic, 0);
            self.* = .{ .allocator = allocator, .io = io, .topic = owned_topic, .queue_len = queue_len, .cache = .init(io, .{}) };
            self.cache.close();
            return self;
        }

        pub fn start(self: *Self) !void {
            if (self.native != null) return error.AlreadyStarted;
            self.cache.reopen();
            self.native = channel.Subscriber(T).init(self.topic, Self, self, onMessage, self.queue_len) catch |err| {
                self.cache.close();
                return err;
            };
        }

        pub fn stop(self: *Self) void {
            if (self.native) |*native| native.deinit();
            self.native = null;
            self.cache.close();
        }

        pub fn snapshot(self: *Self) !?channel.Message(T) {
            return self.cache.snapshot();
        }

        pub fn reset(self: *Self) void {
            self.cache.reset();
        }

        pub fn setTimeoutMs(self: *Self, timeout_ms: u32) void {
            self.timeout_ms.store(timeout_ms, .monotonic);
        }

        pub fn isTimeout(self: *Self) bool {
            return self.cache.isTimeout(self.timeout_ms.load(.monotonic));
        }

        pub fn waitForConnection(self: *Self, timeout: std.Io.Timeout) !void {
            const deadline = timeout.toDeadline(self.io);
            while (true) {
                const latest = self.cache.stats();
                if (latest.closed) return error.Stopped;
                if (!self.isTimeout()) return;
                _ = try self.cache.waitForUpdate(latest.revision, deadline);
            }
        }

        pub fn stats(self: *Self) CacheStats {
            return self.cache.stats();
        }

        /// Includes conversion failures that happened before the Zig callback.
        /// Serialize with start/stop/deinit, which own the native handle.
        pub fn checkLastCallback(self: *Self) !void {
            if (self.native) |native| return native.checkLastCallback();
            return error.Stopped;
        }

        pub fn deinit(self: *Self) void {
            self.stop();
            self.cache.deinit();
            const allocator = self.allocator;
            allocator.free(self.topic);
            allocator.destroy(self);
        }

        fn onMessage(self: *Self, message: *const T) void {
            self.cache.update(message) catch {};
        }
    };
}

pub const PeriodicStats = struct {
    running: bool = false,
    calls: u64 = 0,
    errors: u64 = 0,
    missed_periods: u64 = 0,
    last_error: ?anyerror = null,
};

/// A recurrent task with interruptible waits and fixed-deadline scheduling.
/// First invocation is immediate. Interval 0 runs cooperatively with yield.
pub const PeriodicTask = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    interval_ns: u64,
    callback: *const fn (?*anyopaque) anyerror!void,
    context: ?*anyopaque,
    mutex: std.Io.Mutex = .init,
    changed: std.Io.Condition = .init,
    thread: ?std.Thread = null,
    stopping: bool = true,
    metrics: PeriodicStats = .{},

    pub fn init(allocator: std.mem.Allocator, io: std.Io, interval_ns: u64, callback: *const fn (?*anyopaque) anyerror!void, context: ?*anyopaque) !*PeriodicTask {
        const self = try allocator.create(PeriodicTask);
        self.* = .{ .allocator = allocator, .io = io, .interval_ns = interval_ns, .callback = callback, .context = context };
        return self;
    }

    pub fn start(self: *PeriodicTask) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.thread != null) return error.AlreadyStarted;
        self.stopping = false;
        self.metrics.running = true;
        self.thread = std.Thread.spawn(.{}, run, .{self}) catch |err| {
            self.stopping = true;
            self.metrics.running = false;
            return err;
        };
    }

    pub fn stop(self: *PeriodicTask) void {
        self.mutex.lockUncancelable(self.io);
        self.stopping = true;
        const thread = self.thread;
        self.changed.broadcast(self.io);
        self.mutex.unlock(self.io);
        if (thread) |worker| worker.join();
        self.mutex.lockUncancelable(self.io);
        self.thread = null;
        self.metrics.running = false;
        self.mutex.unlock(self.io);
    }

    pub fn stats(self: *PeriodicTask) PeriodicStats {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.metrics;
    }

    pub fn deinit(self: *PeriodicTask) void {
        self.stop();
        self.allocator.destroy(self);
    }

    fn run(self: *PeriodicTask) void {
        var next = std.Io.Clock.awake.now(self.io).toNanoseconds();
        self.mutex.lockUncancelable(self.io);
        while (!self.stopping) {
            self.mutex.unlock(self.io);
            var failure: ?anyerror = null;
            self.callback(self.context) catch |err| {
                failure = err;
            };
            self.mutex.lockUncancelable(self.io);
            self.metrics.calls +|= 1;
            if (failure) |err| {
                self.metrics.errors +|= 1;
                self.metrics.last_error = err;
            }
            if (self.stopping) break;
            if (self.interval_ns == 0) {
                self.mutex.unlock(self.io);
                std.Thread.yield() catch {};
                self.mutex.lockUncancelable(self.io);
                continue;
            }
            next += self.interval_ns;
            const now = std.Io.Clock.awake.now(self.io).toNanoseconds();
            if (now > next) {
                const missed = @divTrunc(now - next, self.interval_ns) + 1;
                self.metrics.missed_periods +|= @intCast(missed);
                next += missed * self.interval_ns;
            }
            while (!self.stopping and std.Io.Clock.awake.now(self.io).toNanoseconds() < next) {
                self.changed.waitTimeout(self.io, &self.mutex, .{ .deadline = .{ .raw = .fromNanoseconds(next), .clock = .awake } }) catch |err| switch (err) {
                    error.Timeout => {},
                    error.Canceled => {
                        self.stopping = true;
                    },
                };
            }
        }
        self.metrics.running = false;
        self.mutex.unlock(self.io);
    }
};

/// Concurrent sample increments with an explicit reporting interval. Call take
/// or reset from one control thread; sample may run on any producer thread.
pub const FrequencySampler = struct {
    count: std.atomic.Value(u64) = .init(0),
    last_ns: i96,

    pub fn init(now_ns: i96) FrequencySampler {
        return .{ .last_ns = now_ns };
    }

    pub fn sample(self: *FrequencySampler) void {
        _ = self.count.fetchAdd(1, .monotonic);
    }

    pub fn take(self: *FrequencySampler, now_ns: i96) ?f64 {
        const elapsed = @as(i128, now_ns) - self.last_ns;
        if (elapsed <= 0) return null;
        const count = self.count.swap(0, .acq_rel);
        self.last_ns = now_ns;
        return @as(f64, @floatFromInt(count)) * std.time.ns_per_s / @as(f64, @floatFromInt(elapsed));
    }

    pub fn reset(self: *FrequencySampler, now_ns: i96) void {
        _ = self.count.swap(0, .acq_rel);
        self.last_ns = now_ns;
    }
};

const TestItem = struct {
    value: u32,
    released: *std.atomic.Value(usize),
};

const TestSender = struct {
    context: *Context,
    const Context = struct {
        entered: std.Io.Event = .unset,
        gate: std.Io.Event = .unset,
        closed: bool = false,
        sent: [8]u32 = @splat(0),
        sent_len: usize = 0,
    };
    fn send(self: *@This(), item: *const TestItem) !void {
        if (item.value == 1) {
            self.context.entered.set(std.testing.io);
            self.context.gate.waitUncancelable(std.testing.io);
        }
        if (item.value == 13) return error.MockFailure;
        self.context.sent[self.context.sent_len] = item.value;
        self.context.sent_len += 1;
    }
    fn release(item: *TestItem) void {
        _ = item.released.fetchAdd(1, .monotonic);
    }
    pub fn lastStatus(_: *@This()) i32 {
        return 777;
    }
    fn deinit(self: *@This()) void {
        self.context.closed = true;
    }
};

fn testTimeout(milliseconds: i64) std.Io.Timeout {
    return .{ .duration = .{ .raw = .fromMilliseconds(milliseconds), .clock = .awake } };
}

fn waitTestEvent(event: *std.Io.Event) !void {
    const deadline = testTimeout(2000).toDeadline(std.testing.io);
    while (!event.isSet()) {
        event.waitTimeout(std.testing.io, deadline) catch |err| {
            if (err != error.Timeout) return err;
            if (std.Io.Clock.awake.now(std.testing.io).nanoseconds >= deadline.deadline.raw.nanoseconds)
                return error.Timeout;
        };
    }
}

test "queued sender owns accepted items and reports reject-new overflow and errors" {
    var context: TestSender.Context = .{};
    var released: std.atomic.Value(usize) = .init(0);
    const Queue = QueuedSender(TestItem, TestSender);
    const queue = try Queue.init(std.testing.allocator, std.testing.io, .{ .context = &context }, 2, .reject_new);
    defer queue.deinit();
    defer context.gate.set(std.testing.io);
    try std.testing.expectError(error.Stopped, queue.enqueue(.{ .value = 0, .released = &released }));
    try queue.start();
    try std.testing.expectError(error.AlreadyStarted, queue.start());
    try queue.enqueue(.{ .value = 1, .released = &released });
    try waitTestEvent(&context.entered);
    try queue.enqueue(.{ .value = 2, .released = &released });
    try queue.enqueue(.{ .value = 13, .released = &released });
    try std.testing.expectError(error.QueueFull, queue.enqueue(.{ .value = 4, .released = &released }));
    try std.testing.expectEqual(@as(u64, 1), queue.stats().dropped);
    try std.testing.expectError(error.Timeout, queue.waitIdle(testTimeout(1)));
    context.gate.set(std.testing.io);
    try queue.waitIdle(testTimeout(2000));
    queue.stop(.drain);
    const stats = queue.stats();
    try std.testing.expectEqual(@as(u64, 3), stats.accepted);
    try std.testing.expectEqual(@as(u64, 2), stats.sent);
    try std.testing.expectEqual(@as(u64, 1), stats.errors);
    try std.testing.expectEqual(error.MockFailure, stats.last_error.?);
    try std.testing.expectEqual(@as(i32, 777), stats.last_status);
    try std.testing.expectEqualSlices(u32, &.{ 1, 2 }, context.sent[0..context.sent_len]);
    try std.testing.expectEqual(@as(usize, 3), released.load(.acquire));
    try std.testing.expect(!stats.running);
    try queue.start();
    try queue.enqueue(.{ .value = 7, .released = &released });
    queue.stop(.drain);
    try std.testing.expectEqual(@as(usize, 4), released.load(.acquire));
    queue.resetStats();
    try std.testing.expectEqual(@as(u64, 0), queue.stats().accepted);
}

test "drop-oldest preserves FIFO ordering and releases discarded ownership" {
    var context: TestSender.Context = .{};
    var released: std.atomic.Value(usize) = .init(0);
    const Queue = QueuedSender(TestItem, TestSender);
    const queue = try Queue.init(std.testing.allocator, std.testing.io, .{ .context = &context }, 2, .drop_oldest);
    defer queue.deinit();
    defer context.gate.set(std.testing.io);
    try queue.start();
    try queue.enqueue(.{ .value = 1, .released = &released });
    try waitTestEvent(&context.entered);
    try queue.enqueue(.{ .value = 2, .released = &released });
    try queue.enqueue(.{ .value = 3, .released = &released });
    try queue.enqueue(.{ .value = 4, .released = &released });
    try std.testing.expectEqual(@as(usize, 1), released.load(.acquire));
    context.gate.set(std.testing.io);
    queue.stop(.drain);
    try std.testing.expectEqualSlices(u32, &.{ 1, 3, 4 }, context.sent[0..context.sent_len]);
    try std.testing.expectEqual(@as(usize, 4), released.load(.acquire));
    try std.testing.expectEqual(@as(u64, 1), queue.stats().dropped);
}

test "clear releases queued items while the in-flight item remains owned by worker" {
    var context: TestSender.Context = .{};
    var released: std.atomic.Value(usize) = .init(0);
    const Queue = QueuedSender(TestItem, TestSender);
    const queue = try Queue.init(std.testing.allocator, std.testing.io, .{ .context = &context }, 2, .reject_new);
    defer queue.deinit();
    defer context.gate.set(std.testing.io);
    try queue.start();
    try queue.enqueue(.{ .value = 1, .released = &released });
    try waitTestEvent(&context.entered);
    try queue.enqueue(.{ .value = 2, .released = &released });
    try queue.enqueue(.{ .value = 3, .released = &released });
    try std.testing.expectEqual(@as(usize, 2), queue.clear());
    try std.testing.expectEqual(@as(usize, 2), released.load(.acquire));
    context.gate.set(std.testing.io);
    queue.stop(.discard);
    try std.testing.expectEqualSlices(u32, &.{1}, context.sent[0..context.sent_len]);
    try std.testing.expectEqual(@as(usize, 3), released.load(.acquire));
}

const TestValue = struct { text: []const u8 };
const TestStorage = struct {
    allocator: std.mem.Allocator,
    fail: *const bool,
    const Owned = struct {
        value: TestValue,
        allocator: std.mem.Allocator,
        fn deinit(self: *@This()) void {
            self.allocator.free(self.value.text);
        }
    };
    fn clone(self: @This(), value: *const TestValue) !Owned {
        if (self.fail.*) return error.MockCloneFailed;
        return .{ .value = .{ .text = try self.allocator.dupe(u8, value.text) }, .allocator = self.allocator };
    }
    fn read(owned: *const Owned) *const TestValue {
        return &owned.value;
    }
    fn release(owned: *Owned) void {
        owned.deinit();
    }
    pub fn lastStatus(_: @This()) i32 {
        return 888;
    }
};

test "snapshot cache deep-copies callback data and survives reset and clone failure" {
    var fail = false;
    var cache = SnapshotCache(TestValue, TestStorage).init(std.testing.io, .{ .allocator = std.testing.allocator, .fail = &fail });
    defer cache.deinit();
    try std.testing.expect((try cache.snapshot()) == null);
    try std.testing.expect(cache.isTimeout(1000));
    var source = [_]u8{ 'a', 'b', 'c' };
    try cache.update(&.{ .text = &source });
    source[0] = 'z';
    var snapshot = (try cache.snapshot()).?;
    defer snapshot.deinit();
    try std.testing.expectEqualStrings("abc", snapshot.value.text);
    const revision = try cache.waitForUpdate(0, testTimeout(1));
    try std.testing.expectEqual(@as(u64, 1), revision);
    try std.testing.expectError(error.Timeout, cache.waitForUpdate(revision, testTimeout(1)));
    fail = true;
    try std.testing.expectError(error.MockCloneFailed, cache.update(&.{ .text = "failed" }));
    fail = false;
    try std.testing.expectEqual(@as(u64, 1), cache.stats().received);
    try std.testing.expectEqual(@as(i32, 888), cache.stats().last_status);
    cache.reset();
    try std.testing.expect((try cache.snapshot()) == null);
    try std.testing.expectEqualStrings("abc", snapshot.value.text);
    cache.close();
    try std.testing.expectError(error.Stopped, cache.update(&.{ .text = "closed" }));
    try std.testing.expectError(error.Stopped, cache.waitForUpdate(0, .none));
    cache.reopen();
    try cache.update(&.{ .text = "again" });
    try std.testing.expect(!cache.isTimeout(1000));
}

test "snapshot cache readers never observe partially updated dynamic values" {
    const Cache = SnapshotCache(TestValue, TestStorage);
    const fail = false;
    var cache = Cache.init(std.testing.io, .{ .allocator = std.testing.allocator, .fail = &fail });
    defer cache.deinit();
    const Writer = struct {
        fn run(target: *Cache) void {
            for (0..100) |index| {
                var bytes: [64]u8 = @splat(@as(u8, @intCast(index)));
                target.update(&.{ .text = &bytes }) catch unreachable;
                @memset(&bytes, 0xff);
            }
        }
    };
    const writer = try std.Thread.spawn(.{}, Writer.run, .{&cache});
    defer writer.join();
    for (0..100) |_| {
        if (try cache.snapshot()) |owned| {
            var snapshot = owned;
            defer snapshot.deinit();
            try std.testing.expectEqual(@as(usize, 64), snapshot.value.text.len);
            for (snapshot.value.text) |byte| try std.testing.expectEqual(snapshot.value.text[0], byte);
        }
    }
}

test "periodic stop interrupts a long interval and preserves callback errors across restart" {
    const Context = struct {
        entered: std.Io.Event = .unset,
        fn callback(pointer: ?*anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(pointer.?));
            self.entered.set(std.testing.io);
            return error.MockTickFailed;
        }
    };
    var context: Context = .{};
    const task = try PeriodicTask.init(std.testing.allocator, std.testing.io, 10 * std.time.ns_per_s, Context.callback, &context);
    defer task.deinit();
    try task.start();
    try waitTestEvent(&context.entered);
    task.stop();
    try std.testing.expectEqual(@as(u64, 1), task.stats().calls);
    try std.testing.expectEqual(error.MockTickFailed, task.stats().last_error.?);
    context.entered.reset();
    try task.start();
    try waitTestEvent(&context.entered);
    task.stop();
    try std.testing.expectEqual(@as(u64, 2), task.stats().calls);
    try std.testing.expectEqual(@as(u64, 2), task.stats().errors);
    try std.testing.expect(!task.stats().running);
}

test "periodic work records missed deadlines instead of invoking a catch-up burst" {
    const Context = struct {
        entered: std.Io.Event = .unset,
        count: usize = 0,
        fn callback(pointer: ?*anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(pointer.?));
            self.count += 1;
            if (self.count == 1) {
                try std.Io.sleep(std.testing.io, .fromMilliseconds(20), .awake);
            } else self.entered.set(std.testing.io);
        }
    };
    var context: Context = .{};
    const task = try PeriodicTask.init(std.testing.allocator, std.testing.io, std.time.ns_per_ms, Context.callback, &context);
    defer task.deinit();
    try task.start();
    try waitTestEvent(&context.entered);
    task.stop();
    try std.testing.expect(task.stats().missed_periods >= 1);
}

test "frequency sampling uses elapsed time and preserves samples on a non-increasing clock" {
    var frequency = FrequencySampler.init(0);
    for (0..200) |_| frequency.sample();
    try std.testing.expectEqual(@as(f64, 400), frequency.take(500_000_000).?);
    for (0..7) |_| frequency.sample();
    try std.testing.expect(frequency.take(500_000_000) == null);
    try std.testing.expectEqual(@as(f64, 14), frequency.take(1_000_000_000).?);
    frequency.reset(2_000_000_000);
    try std.testing.expectEqual(@as(f64, 0), frequency.take(3_000_000_000).?);
}
