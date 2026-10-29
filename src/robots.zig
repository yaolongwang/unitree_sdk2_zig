//! Robot-specific conveniences from upstream dds_wrapper. Publishers are
//! synchronous and report write failures; applications own their scheduling.
//! Subscriber callbacks retain the channel module's borrowed-view lifetime.
const std = @import("std");
const raw = @import("raw");
const messages = @import("messages.zig");
const channel = @import("channel.zig");
const clients = @import("clients.zig");
const crc = @import("crc.zig");
const remote_control = @import("remote_control.zig");
const termination = @import("termination.zig");
const scheduling = @import("scheduling.zig");

pub const go2 = struct {
    pub const JointIndex = remote_control.low_level.Go2Joint;

    pub const publisher = struct {
        pub const LowCmd = PreparedPublisher(messages.go2.LowCmd, "rt/lowcmd", .go2_command);
        pub const LowState = PreparedPublisher(messages.go2.LowState, "rt/lowstate", .low_state);
        pub const SportModeState = PreparedPublisher(messages.go2.SportModeState, "rt/sportmodestate", .plain);
        pub const WirelessController = PreparedPublisher(messages.go2.WirelessController, "rt/wirelesscontroller", .wireless);
        pub const MotorCmds = SequencePublisher(messages.go2.MotorCmds, messages.go2.MotorCmd, "cmds");
        pub const MotorStates = SequencePublisher(messages.go2.MotorStates, messages.go2.MotorState, "states");
    };

    pub const subscription = struct {
        pub const LowState = TopicSubscriber(messages.go2.LowState, "rt/lowstate");
        pub const LowCmd = TopicSubscriber(messages.go2.LowCmd, "rt/lowcmd");
        pub const SportModeState = TopicSubscriber(messages.go2.SportModeState, "rt/sportmodestate");
        pub const MotorStates = TopicSubscriber(messages.go2.MotorStates, null);
        pub const MotorCmds = TopicSubscriber(messages.go2.MotorCmds, null);
    };

    pub fn gaitType(state: *const messages.go2.SportModeState) u32 {
        return state.gait_type;
    }

    pub fn position(state: *const messages.go2.SportModeState) [3]f32 {
        return state.position;
    }

    pub fn velocity(state: *const messages.go2.SportModeState) [3]f32 {
        return state.velocity;
    }

    pub const ShutdownOptions = struct {
        rpc_timeout_seconds: f32 = 3,
        retry_interval_ms: u32 = 3000,
        max_release_attempts: ?u32 = null,
    };

    /// Release the default motion controller, as go2::shutdown does upstream.
    /// Network and cancellation errors are returned. max_release_attempts null
    /// keeps retrying until CheckMode reports an empty controller name.
    pub fn shutdown(io: std.Io, options: ShutdownOptions) !void {
        var client = try clients.b2.MotionSwitcherClient.init();
        defer client.deinit();
        try client.setTimeout(options.rpc_timeout_seconds);
        var attempts: u32 = 0;
        while (true) {
            var mode = try client.checkMode();
            defer mode.deinit();
            if (mode.value.name.len == 0) return;
            if (options.max_release_attempts) |maximum| {
                if (attempts >= maximum) return error.Timeout;
            }
            try client.releaseMode();
            attempts +|= 1;
            try std.Io.sleep(io, .fromMilliseconds(options.retry_interval_ms), .awake);
        }
    }

    /// One iteration for applications that already own a scheduler. Returns
    /// true when no default controller remains, false after requesting release.
    pub fn shutdownStep(client: anytype) !bool {
        var mode = try client.checkMode();
        defer mode.deinit();
        if (mode.value.name.len == 0) return true;
        try client.releaseMode();
        return false;
    }
};

pub const g1 = struct {
    pub const JointIndex = enum(u8) {
        left_hip_pitch = 0,
        left_hip_roll,
        left_hip_yaw,
        left_knee,
        left_ankle_pitch,
        left_ankle_roll,
        right_hip_pitch,
        right_hip_roll,
        right_hip_yaw,
        right_knee,
        right_ankle_pitch,
        right_ankle_roll,
        waist_yaw,
        waist_roll,
        waist_pitch,
        left_shoulder_pitch,
        left_shoulder_roll,
        left_shoulder_yaw,
        left_elbow,
        left_wrist_roll,
        left_wrist_pitch,
        left_wrist_yaw,
        right_shoulder_pitch,
        right_shoulder_roll,
        right_shoulder_yaw,
        right_elbow,
        right_wrist_roll,
        right_wrist_pitch,
        right_wrist_yaw,
    };

    pub const arm_joints: [17]JointIndex = .{
        .left_shoulder_pitch, .left_shoulder_roll, .left_shoulder_yaw, .left_elbow,
        .left_wrist_roll,     .left_wrist_pitch,   .left_wrist_yaw,    .right_shoulder_pitch,
        .right_shoulder_roll, .right_shoulder_yaw, .right_elbow,       .right_wrist_roll,
        .right_wrist_pitch,   .right_wrist_yaw,    .waist_yaw,         .waist_roll,
        .waist_pitch,
    };

    pub const publisher = struct {
        pub const LowState = PreparedPublisher(messages.hg.LowState, "rt/lowstate", .low_state);
        pub const LowCmd = PreparedPublisher(messages.hg.LowCmd, "rt/lowcmd", .hg_command);
        pub const ArmSdk = PreparedPublisher(messages.hg.LowCmd, "rt/arm_sdk", .plain);
    };

    pub const subscription = struct {
        pub const LowCmd = TopicSubscriber(messages.hg.LowCmd, "rt/lowcmd");
        pub const ArmSdk = TopicSubscriber(messages.hg.LowCmd, "rt/arm_sdk");
        pub const LowState = TopicSubscriber(messages.hg.LowState, "rt/lowstate");
        pub const InspireHandState = TopicSubscriber(messages.go2.MotorStates, "rt/inspire/state");
        pub const Dex3LeftHandState = TopicSubscriber(messages.hg.HandState, "rt/dex3/left/state");
        pub const Dex3RightHandState = TopicSubscriber(messages.hg.HandState, "rt/dex3/right/state");
    };

    /// The robot's mode 0 denotes simulation and accepts every command mode.
    pub fn checkModeMachine(command: *const messages.hg.LowCmd, state: *const messages.hg.LowState) bool {
        return state.mode_machine == 0 or state.mode_machine == command.mode_machine;
    }

    pub fn setArmWeight(command: *messages.hg.LowCmd, coefficient: f32) error{InvalidArgument}!void {
        if (!std.math.isFinite(coefficient)) return error.InvalidArgument;
        command.motor_cmd[29].q = std.math.clamp(coefficient, 0, 1);
    }

    pub fn armWeight(command: *const messages.hg.LowCmd) f32 {
        return command.motor_cmd[29].q;
    }
};

pub const r1 = struct {
    pub const JointIndex = enum(u8) {
        left_hip_pitch = 0,
        left_hip_roll,
        left_hip_yaw,
        left_knee,
        left_ankle_pitch,
        left_ankle_roll,
        right_hip_pitch,
        right_hip_roll,
        right_hip_yaw,
        right_knee,
        right_ankle_pitch,
        right_ankle_roll,
        waist_roll,
        waist_yaw,
        left_shoulder_pitch = 15,
        left_shoulder_roll,
        left_shoulder_yaw,
        left_elbow,
        left_wrist_roll,
        right_shoulder_pitch = 22,
        right_shoulder_roll,
        right_shoulder_yaw,
        right_elbow,
        right_wrist_roll,
        head_pitch = 29,
        head_yaw,
    };

    pub const arm_joints: [13]JointIndex = .{
        .left_shoulder_pitch, .left_shoulder_roll, .left_shoulder_yaw,
        .left_elbow,          .left_wrist_roll,    .right_shoulder_pitch,
        .right_shoulder_roll, .right_shoulder_yaw, .right_elbow,
        .right_wrist_roll,    .waist_yaw,          .head_pitch,
        .head_yaw,
    };

    pub const publisher = struct {
        pub const ArmSdk = PreparedPublisher(messages.hg.LowCmd, "rt/arm_sdk", .plain);
    };

    /// R1 encodes arm weight as an integer percentage in mode_pr, unlike G1.
    pub fn setArmWeight(command: *messages.hg.LowCmd, coefficient: f32) error{InvalidArgument}!void {
        if (!std.math.isFinite(coefficient)) return error.InvalidArgument;
        command.mode_pr = @intFromFloat(std.math.clamp(coefficient, 0, 1) * 100);
    }

    pub fn armWeight(command: *const messages.hg.LowCmd) f32 {
        return @as(f32, @floatFromInt(command.mode_pr)) / 100;
    }
};

/// Tracks the all-zero wireless packet timeout used by Go2/G1 LowState.update.
/// Call update for each received state; all timestamps use the caller's clock.
pub const JoystickMonitor = struct {
    joystick: remote_control.Joystick = .{},
    timeout_ms: u32 = 3000,
    last_active_ns: ?i64 = null,
    timed_out: bool = false,

    pub fn update(self: *JoystickMonitor, bytes: *const [40]u8, now_ns: i64) void {
        const active = for (bytes) |byte| {
            if (byte != 0) break true;
        } else false;
        if (active) {
            self.last_active_ns = now_ns;
            self.timed_out = false;
        } else {
            self.timed_out = if (self.last_active_ns) |previous|
                @as(i128, now_ns) - previous > @as(i128, self.timeout_ms) * std.time.ns_per_ms
            else
                true;
        }
        self.joystick.extract(remote_control.Remote.decode(bytes) catch unreachable, now_ns);
    }

    pub fn isJoystickTimeout(self: JoystickMonitor) bool {
        return self.timed_out;
    }
};

const Preparation = enum { plain, go2_command, hg_command, low_state, wireless };

/// Corresponds to model Publisher wrappers without owning a background thread.
/// message is application-owned. Call write to prepare CRC/joystick and publish.
pub fn PreparedPublisher(comptime T: type, comptime topic: [:0]const u8, comptime preparation: Preparation) type {
    return struct {
        const Self = @This();
        pub const Message = T;
        pub const default_topic = topic;

        native: channel.Publisher(T),
        message: T,
        remote: ?remote_control.Remote = null,
        /// Borrowed until the next write; when set, takes precedence over remote.
        joystick: ?*const remote_control.Joystick = null,

        pub fn newMessage() T {
            var result = std.mem.zeroes(T);
            if (preparation == .go2_command) {
                result.head = .{ 0xfe, 0xef };
                result.level_flag = 0xff;
                for (&result.motor_cmd) |*motor| motor.mode = 1;
            }
            return result;
        }

        pub fn init() !Self {
            return initTopic(topic);
        }

        pub fn initTopic(topic_name: [:0]const u8) !Self {
            return .{ .native = try channel.Publisher(T).init(topic_name), .message = newMessage() };
        }

        /// Owned asynchronous editing/publishing with the same defaults and
        /// preparation rules. Call start after construction.
        pub fn initRealtime(allocator: std.mem.Allocator, io: std.Io, options: scheduling.PublisherOptions) !*scheduling.RealtimePublisher(T) {
            return initRealtimeTopic(allocator, io, topic, options);
        }

        pub fn initRealtimeTopic(allocator: std.mem.Allocator, io: std.Io, topic_name: [:0]const u8, options: scheduling.PublisherOptions) !*scheduling.RealtimePublisher(T) {
            const Adapter = struct {
                fn invoke(message: *T, _: ?*anyopaque) void {
                    Self.prepare(message, null);
                }
            };
            const publisher = try scheduling.RealtimePublisher(T).init(allocator, io, topic_name, options);
            publisher.message = newMessage();
            publisher.prepare = Adapter.invoke;
            return publisher;
        }

        /// Pure preparation can also be used with an application-owned publisher.
        pub fn prepare(message: *T, remote: ?remote_control.Remote) void {
            if (preparation == .low_state) {
                if (remote) |packet| message.wireless_remote = packet.encode();
                crc.update(message);
            } else if (preparation == .go2_command or preparation == .hg_command) {
                crc.update(message);
            } else if (preparation == .wireless) {
                if (remote) |packet| {
                    message.lx = packet.lx;
                    message.ly = packet.ly;
                    message.rx = packet.rx;
                    message.ry = packet.ry;
                    message.keys = packet.buttons.bits();
                }
            }
        }

        pub fn write(self: *Self, wait_us: i64) !void {
            const remote = if (self.joystick) |joystick| joystick.combine() else self.remote;
            prepare(&self.message, remote);
            try self.native.write(&self.message, wait_us);
        }

        pub fn deinit(self: *Self) void {
            self.native.deinit();
        }
    };
}

/// Owned vector storage for upstream MotorCmds/MotorStates publishers.
pub fn SequencePublisher(comptime T: type, comptime Element: type, comptime field: []const u8) type {
    return struct {
        const Self = @This();
        pub const Message = T;
        native: channel.Publisher(T),
        allocator: std.mem.Allocator,
        values: []Element,

        pub fn init(allocator: std.mem.Allocator, topic_name: [:0]const u8, count: usize) !Self {
            const values = try allocator.alloc(Element, count);
            errdefer allocator.free(values);
            for (values) |*value| value.* = std.mem.zeroes(Element);
            return .{ .native = try channel.Publisher(T).init(topic_name), .allocator = allocator, .values = values };
        }

        /// The upstream publishing wrappers default to one motor element.
        pub fn initDefault(allocator: std.mem.Allocator, topic_name: [:0]const u8) !Self {
            return init(allocator, topic_name, 1);
        }

        /// Async sender deep-copies views, so values may change after send.
        pub fn initAsync(allocator: std.mem.Allocator, io: std.Io, topic_name: [:0]const u8, options: scheduling.PublisherOptions) !scheduling.AsyncPublisher(T) {
            return scheduling.AsyncPublisher(T).init(allocator, io, topic_name, options);
        }

        pub fn resize(self: *Self, count: usize) !void {
            const previous = self.values.len;
            self.values = try self.allocator.realloc(self.values, count);
            if (count > previous) {
                for (self.values[previous..]) |*value| value.* = std.mem.zeroes(Element);
            }
        }

        /// A borrowed message view, invalid after resize or deinit.
        pub fn view(self: Self) T {
            var message: T = undefined;
            @field(message, field) = .{ .data = if (self.values.len == 0) null else self.values.ptr, .len = self.values.len };
            return message;
        }

        pub fn write(self: Self, wait_us: i64) !void {
            const message = self.view();
            try self.native.write(&message, wait_us);
        }

        pub fn deinit(self: *Self) void {
            self.native.deinit();
            self.allocator.free(self.values);
            self.* = undefined;
        }
    };
}

/// Model default topics and timeout/wait behavior over the typed DDS subscriber.
/// Retain callback data with channel.Message(T).clone when a snapshot is needed.
pub fn TopicSubscriber(comptime T: type, comptime topic: ?[:0]const u8) type {
    return struct {
        const Self = @This();
        pub const Message = T;
        pub const default_topic = topic;
        native: channel.Subscriber(T),
        timeout_ms: u32 = 1000,

        pub fn init(comptime Context: type, context: *Context, comptime callback: fn (*Context, *const T) void, queue_len: i64) !Self {
            return initTopic(topic orelse return error.TopicRequired, Context, context, callback, queue_len);
        }

        pub fn initTopic(topic_name: [:0]const u8, comptime Context: type, context: *Context, comptime callback: fn (*Context, *const T) void, queue_len: i64) !Self {
            return .{ .native = try channel.Subscriber(T).init(topic_name, Context, context, callback, queue_len) };
        }

        /// Synchronized latest-state receiver with owned snapshots. Call start
        /// after construction. Dynamic fields are copied before callback return.
        pub fn initCached(allocator: std.mem.Allocator, io: std.Io, queue_len: i64) !*scheduling.CachedSubscriber(T) {
            return initCachedTopic(allocator, io, topic orelse return error.TopicRequired, queue_len);
        }

        pub fn initCachedTopic(allocator: std.mem.Allocator, io: std.Io, topic_name: [:0]const u8, queue_len: i64) !*scheduling.CachedSubscriber(T) {
            return scheduling.CachedSubscriber(T).init(allocator, io, topic_name, queue_len);
        }

        pub fn setTimeoutMs(self: *Self, timeout_ms: u32) void {
            self.timeout_ms = timeout_ms;
        }

        pub fn isTimeout(self: Self, now_ns: i64) !bool {
            return termination.lostConnection(now_ns, try self.native.lastDataTime(), self.timeout_ms);
        }

        /// max_wait_ms null matches upstream's unbounded connection wait.
        /// Uses the SDK monotonic clock to match lastDataTime and caller Io for
        /// cancelable sleeping, then waits 100 ms for stable communication.
        pub fn waitForConnection(self: Self, io: std.Io, max_wait_ms: ?u32) !void {
            const start_ns = raw.usdk_monotonic_time_ns();
            while (try self.isTimeout(raw.usdk_monotonic_time_ns())) {
                if (max_wait_ms) |maximum| {
                    if (@as(i128, raw.usdk_monotonic_time_ns()) - start_ns >= @as(i128, maximum) * std.time.ns_per_ms)
                        return error.Timeout;
                }
                try std.Io.sleep(io, .fromMilliseconds(100), .awake);
            }
            try std.Io.sleep(io, .fromMilliseconds(100), .awake);
        }

        pub fn lastDataTime(self: Self) !i64 {
            return self.native.lastDataTime();
        }

        pub fn deinit(self: *Self) void {
            self.native.deinit();
        }
    };
}

test "model joint indices and arm groups preserve upstream gaps and ordering" {
    try std.testing.expectEqual(@as(u8, 11), @backingInt(go2.JointIndex.rear_left_calf));
    try std.testing.expectEqual(@as(u8, 28), @backingInt(g1.JointIndex.right_wrist_yaw));
    try std.testing.expectEqual(@as(u8, 12), @backingInt(g1.JointIndex.waist_yaw));
    try std.testing.expectEqual(@as(u8, 12), @backingInt(r1.JointIndex.waist_roll));
    try std.testing.expectEqual(@as(u8, 22), @backingInt(r1.JointIndex.right_shoulder_pitch));
    try std.testing.expectEqual(@as(u8, 30), @backingInt(r1.JointIndex.head_yaw));
    try std.testing.expectEqual(g1.JointIndex.waist_pitch, g1.arm_joints[16]);
    try std.testing.expectEqual(r1.JointIndex.head_yaw, r1.arm_joints[12]);
}

test "G1 and R1 use distinct clamped arm weight encodings" {
    var command = std.mem.zeroes(messages.hg.LowCmd);
    try g1.setArmWeight(&command, 1.2);
    try std.testing.expectEqual(@as(f32, 1), g1.armWeight(&command));
    try std.testing.expectEqual(@as(u8, 0), command.mode_pr);
    try r1.setArmWeight(&command, 0.567);
    try std.testing.expectEqual(@as(u8, 56), command.mode_pr);
    try std.testing.expectApproxEqAbs(@as(f32, 0.56), r1.armWeight(&command), 0.0001);
    try r1.setArmWeight(&command, -1);
    try std.testing.expectEqual(@as(u8, 0), command.mode_pr);
    try std.testing.expectError(error.InvalidArgument, r1.setArmWeight(&command, std.math.nan(f32)));
    var state = std.mem.zeroes(messages.hg.LowState);
    command.mode_machine = 3;
    try std.testing.expect(g1.checkModeMachine(&command, &state));
    state.mode_machine = 2;
    try std.testing.expect(!g1.checkModeMachine(&command, &state));
    state.mode_machine = 3;
    try std.testing.expect(g1.checkModeMachine(&command, &state));
}

test "model publishers apply message defaults, joystick fields and CRC" {
    var command = go2.publisher.LowCmd.newMessage();
    try std.testing.expectEqualSlices(u8, &.{ 0xfe, 0xef }, &command.head);
    try std.testing.expectEqual(@as(u8, 1), command.motor_cmd[19].mode);
    try std.testing.expectEqual(@as(f32, 0), command.motor_cmd[19].q);
    go2.publisher.LowCmd.prepare(&command, null);
    try std.testing.expect(crc.verify(&command));

    var state = g1.publisher.LowState.newMessage();
    const remote: remote_control.Remote = .{ .buttons = .{ .a = true }, .lx = 0.5 };
    g1.publisher.LowState.prepare(&state, remote);
    try std.testing.expect(crc.verify(&state));
    try std.testing.expect((try remote_control.Remote.decode(&state.wireless_remote)).buttons.a);

    var wireless = go2.publisher.WirelessController.newMessage();
    go2.publisher.WirelessController.prepare(&wireless, remote);
    try std.testing.expectEqual(@as(f32, 0.5), wireless.lx);
    try std.testing.expectEqual(@as(u16, 0x100), wireless.keys);
}

test "joystick watchdog observes the strict three-second all-zero timeout" {
    var monitor: JoystickMonitor = .{};
    var bytes = (remote_control.Remote{ .lx = 1 }).encode();
    monitor.update(&bytes, 1_000_000_000);
    try std.testing.expect(!monitor.isJoystickTimeout());
    @memset(&bytes, 0);
    monitor.update(&bytes, 4_000_000_000);
    try std.testing.expect(!monitor.isJoystickTimeout());
    monitor.update(&bytes, 4_000_000_001);
    try std.testing.expect(monitor.isJoystickTimeout());
    bytes[2] = 1;
    monitor.update(&bytes, 5_000_000_000);
    try std.testing.expect(!monitor.isJoystickTimeout());
}

test "shutdown step releases only when an active controller is reported" {
    const FakeClient = struct {
        active: bool = true,
        releases: usize = 0,
        const Result = struct {
            value: struct { name: []const u8 },
            fn deinit(_: *@This()) void {}
        };
        fn checkMode(self: *@This()) !Result {
            return .{ .value = .{ .name = if (self.active) "sport" else "" } };
        }
        fn releaseMode(self: *@This()) !void {
            self.releases += 1;
            self.active = false;
        }
    };
    var client: FakeClient = .{};
    try std.testing.expect(!try go2.shutdownStep(&client));
    try std.testing.expectEqual(@as(usize, 1), client.releases);
    try std.testing.expect(try go2.shutdownStep(&client));
    try std.testing.expectEqual(@as(usize, 1), client.releases);
}
