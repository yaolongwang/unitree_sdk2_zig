//! Wireless remote protocol and explicit state tracking without a hidden clock.
const std = @import("std");
const messages = @import("messages.zig");

pub const packet_size = 40;

/// Bit positions in the two little-endian key bytes at packet offset 2.
pub const Button = enum(u4) {
    r1,
    l1,
    start,
    select,
    r2,
    l2,
    f1,
    f2,
    a,
    b,
    x,
    y,
    up,
    right,
    down,
    left,
};

pub const Buttons = packed struct(u16) {
    r1: bool = false,
    l1: bool = false,
    start: bool = false,
    select: bool = false,
    r2: bool = false,
    l2: bool = false,
    f1: bool = false,
    f2: bool = false,
    a: bool = false,
    b: bool = false,
    x: bool = false,
    y: bool = false,
    up: bool = false,
    right: bool = false,
    down: bool = false,
    left: bool = false,

    pub fn fromBits(raw_bits: u16) Buttons {
        return @bitCast(raw_bits);
    }

    pub fn bits(self: Buttons) u16 {
        return @bitCast(self);
    }

    pub fn isPressed(self: Buttons, button: Button) bool {
        return self.bits() & (@as(u16, 1) << @backingInt(button)) != 0;
    }
};

/// All 40 bytes round-trip, including the otherwise unused L2 analog field and
/// reserved bytes. Floating-point payload bits are preserved without clamping.
pub const Remote = struct {
    head: [2]u8 = .{ 0, 0 },
    buttons: Buttons = .{},
    lx: f32 = 0,
    rx: f32 = 0,
    ry: f32 = 0,
    l2: f32 = 0,
    ly: f32 = 0,
    reserve: [16]u8 = @splat(0),

    pub fn decode(bytes: []const u8) error{InvalidLength}!Remote {
        if (bytes.len != packet_size) return error.InvalidLength;
        return .{
            .head = bytes[0..2].*,
            .buttons = Buttons.fromBits(std.mem.readInt(u16, bytes[2..4], .little)),
            .lx = readFloat(bytes[4..8]),
            .rx = readFloat(bytes[8..12]),
            .ry = readFloat(bytes[12..16]),
            .l2 = readFloat(bytes[16..20]),
            .ly = readFloat(bytes[20..24]),
            .reserve = bytes[24..40].*,
        };
    }

    pub fn encode(self: Remote) [packet_size]u8 {
        var bytes: [packet_size]u8 = undefined;
        bytes[0..2].* = self.head;
        std.mem.writeInt(u16, bytes[2..4], self.buttons.bits(), .little);
        writeFloat(bytes[4..8], self.lx);
        writeFloat(bytes[8..12], self.rx);
        writeFloat(bytes[12..16], self.ry);
        writeFloat(bytes[16..20], self.l2);
        writeFloat(bytes[20..24], self.ly);
        bytes[24..40].* = self.reserve;
        return bytes;
    }
};

fn readFloat(bytes: *const [4]u8) f32 {
    return @bitCast(std.mem.readInt(u32, bytes, .little));
}

fn writeFloat(bytes: *[4]u8, value: f32) void {
    std.mem.writeInt(u32, bytes, @bitCast(value), .little);
}

/// Edges are valid until the next update, including updates with unchanged keys.
pub const Tracker = struct {
    pressed: Buttons = .{},
    on_pressed: Buttons = .{},
    on_released: Buttons = .{},

    pub fn update(self: *Tracker, current: Buttons) void {
        const previous = self.pressed.bits();
        const next = current.bits();
        self.on_pressed = Buttons.fromBits(next & ~previous);
        self.on_released = Buttons.fromBits(previous & ~next);
        self.pressed = current;
    }
};

/// One button's edges and repeated-click count. The first click has count 0;
/// subsequent clicks no more than 300 ms apart increment it by default.
pub const ButtonState = struct {
    pressed: bool = false,
    on_pressed: bool = false,
    on_released: bool = false,
    click_count: u32 = 0,
    last_pressed_ns: ?i64 = null,
    click_interval_ns: i64 = 300_000_000,

    pub fn update(self: *ButtonState, pressed: bool, now_ns: i64) void {
        self.on_pressed = pressed and !self.pressed;
        self.on_released = !pressed and self.pressed;
        if (self.on_pressed) {
            const consecutive = if (self.last_pressed_ns) |previous|
                now_ns >= previous and @as(i128, now_ns) - previous <= self.click_interval_ns
            else
                false;
            self.click_count = if (consecutive) self.click_count +| 1 else 0;
            self.last_pressed_ns = now_ns;
        }
        self.pressed = pressed;
    }

    pub fn resetClickCount(self: *ButtonState) void {
        self.click_count = 0;
    }
};

/// Exponential smoothing, a deadzone, and an absolute-value activation threshold.
/// `smooth` is the new sample's weight. Set it to 1 for unfiltered input.
pub const AxisState = struct {
    data: f32 = 0,
    pressed: bool = false,
    on_pressed: bool = false,
    on_released: bool = false,
    smooth: f32 = 0.03,
    deadzone: f32 = 0.01,
    threshold: f32 = 0.5,

    pub fn update(self: *AxisState, value: f32) void {
        const input = if (@abs(value) < self.deadzone) 0 else value;
        const next = self.data * (1 - self.smooth) + input * self.smooth;
        const pressed = @abs(next) > self.threshold;
        self.on_pressed = pressed and @abs(self.data) < self.threshold;
        self.on_released = !pressed and @abs(self.data) > self.threshold;
        self.pressed = pressed;
        self.data = next;
    }
};

/// Track Remote packet buttons, smoothed axes, repeated clicks, and inactivity.
/// Fourteen buttons participate; F1/F2 are not decoded, emitted, or reset.
/// Click counts reset after more than 500 ms of button inactivity by default.
/// Axis motion does not restart the inactivity timer.
/// Timestamps come from the caller's monotonic clock; synchronize shared access.
pub const RemoteTracker = struct {
    keys: [16]ButtonState = @splat(.{}),
    lx: AxisState = .{},
    ly: AxisState = .{},
    rx: AxisState = .{},
    ry: AxisState = .{},
    last_active_ns: i64,
    inactive_timeout_ns: i64 = 500_000_000,

    const active_buttons = [_]Button{ .l2, .r2, .select, .start, .l1, .r1, .left, .down, .right, .up, .y, .x, .b, .a };

    pub fn init(now_ns: i64) RemoteTracker {
        return .{ .last_active_ns = now_ns };
    }

    pub fn button(self: *RemoteTracker, key: Button) *ButtonState {
        return &self.keys[@backingInt(key)];
    }

    pub fn extract(self: *RemoteTracker, remote: Remote, now_ns: i64) void {
        var active = false;
        for (active_buttons) |key| {
            const pressed = remote.buttons.isPressed(key);
            self.button(key).update(pressed, now_ns);
            active = active or pressed;
        }
        self.lx.update(remote.lx);
        self.ly.update(remote.ly);
        self.rx.update(remote.rx);
        self.ry.update(remote.ry);
        if (active) {
            self.last_active_ns = now_ns;
        } else if (@as(i128, now_ns) - self.last_active_ns > self.inactive_timeout_ns) {
            self.resetAllClickCounts();
            self.last_active_ns = now_ns;
        }
    }

    pub fn extractPacket(self: *RemoteTracker, bytes: []const u8, now_ns: i64) error{InvalidLength}!void {
        self.extract(try Remote.decode(bytes), now_ns);
    }

    pub fn resetAllClickCounts(self: *RemoteTracker) void {
        for (active_buttons) |key| self.button(key).resetClickCount();
    }

    pub fn combine(self: RemoteTracker) Remote {
        var bits: u16 = 0;
        for (active_buttons) |key| {
            if (self.keys[@backingInt(key)].pressed) bits |= @as(u16, 1) << @backingInt(key);
        }
        return .{ .buttons = Buttons.fromBits(bits), .lx = self.lx.data, .ly = self.ly.data, .rx = self.rx.data, .ry = self.ry.data };
    }
};

/// A first click counts as 1, subsequent clicks less than 500 ms apart increment
/// it, and release retains held time for one update.
pub const KeyState = struct {
    pressed: bool = false,
    on_pressed: bool = false,
    on_released: bool = false,
    click_count: u32 = 0,
    pressed_time: f32 = 0,
    last_pressed_ns: ?i64 = null,

    pub fn update(self: *KeyState, pressed: bool, now_ns: i64) void {
        self.on_pressed = pressed and !self.pressed;
        self.on_released = !pressed and self.pressed;
        if (self.on_pressed) {
            const repeated = if (self.last_pressed_ns) |previous|
                now_ns >= previous and @as(i128, now_ns) - previous < 500_000_000
            else
                false;
            self.click_count = if (repeated) self.click_count +| 1 else 1;
            self.last_pressed_ns = now_ns;
        }
        if (pressed) {
            const elapsed = @as(i128, now_ns) - self.last_pressed_ns.?;
            self.pressed_time = @as(f32, @floatFromInt(elapsed)) / std.time.ns_per_s;
        } else if (!self.on_released) {
            self.pressed_time = 0;
        }
        self.pressed = pressed;
    }
};

/// Smoothed signed axis with a positive activation threshold and KeyState timing.
pub const JoystickAxis = struct {
    key: KeyState = .{},
    data: f32 = 0,
    smooth: f32 = 0.03,
    deadzone: f32 = 0.01,
    threshold: f32 = 0.5,

    pub fn update(self: *JoystickAxis, value: f32, now_ns: i64) void {
        const input = if (@abs(value) < self.deadzone) 0 else value;
        self.data = self.data * (1 - self.smooth) + input * self.smooth;
        self.key.update(self.data > self.threshold, now_ns);
    }
};

/// Buttons, smoothed axes, and trigger synthesis. LS/RS have
/// no corresponding wireless bits and are left for a host input adapter.
pub const Joystick = struct {
    keys: [16]KeyState = @splat(.{}),
    ls: KeyState = .{},
    rs: KeyState = .{},
    lx: JoystickAxis = .{},
    ly: JoystickAxis = .{},
    rx: JoystickAxis = .{},
    ry: JoystickAxis = .{},
    lt: JoystickAxis = .{},
    rt: JoystickAxis = .{},

    pub fn button(self: *Joystick, key: Button) *KeyState {
        return &self.keys[@backingInt(key)];
    }

    pub fn extract(self: *Joystick, remote: Remote, now_ns: i64) void {
        for (&self.keys, 0..) |*key, index| {
            key.update(remote.buttons.isPressed(@fromBackingInt(@as(u4, @intCast(index)))), now_ns);
        }
        self.lx.update(remote.lx, now_ns);
        self.ly.update(remote.ly, now_ns);
        self.rx.update(remote.rx, now_ns);
        self.ry.update(remote.ry, now_ns);
        self.lt.update(if (remote.buttons.l2) 1 else 0, now_ns);
        self.rt.update(if (remote.buttons.r2) 1 else 0, now_ns);
    }

    pub fn combine(self: Joystick) Remote {
        var raw_bits: u16 = 0;
        for (self.keys, 0..) |key, index| {
            if (key.pressed) raw_bits |= @as(u16, 1) << @as(u4, @intCast(index));
        }
        var buttons = Buttons.fromBits(raw_bits);
        buttons.l2 = self.lt.data > 0.5;
        buttons.r2 = self.rt.data > 0.5;
        return .{
            .buttons = buttons,
            .lx = self.lx.data,
            .ly = self.ly.data,
            .rx = self.rx.data,
            .ry = self.ry.data,
        };
    }
};

/// Low-level constants and initial message values used by upstream examples.
pub const low_level = struct {
    pub const high_level: u8 = 0xee;
    pub const low_level_flag: u8 = 0xff;
    pub const trigger_level: u8 = 0xf0;
    pub const position_stop: f32 = 2.146e9;
    pub const velocity_stop: f32 = 16000;

    pub const Go2Joint = enum(u8) {
        front_right_hip,
        front_right_thigh,
        front_right_calf,
        front_left_hip,
        front_left_thigh,
        front_left_calf,
        rear_right_hip,
        rear_right_thigh,
        rear_right_calf,
        rear_left_hip,
        rear_left_thigh,
        rear_left_calf,
    };

    pub const HgMode = enum(u8) { pr = 0, ab = 1 };

    /// Match Go2 InitLowCmd: FE EF header, low-level flag, motor mode 1,
    /// position/velocity stop sentinels and zero torque/gains. Call crc.update
    /// after setting the desired fields and before publishing.
    pub fn initGo2Command() messages.go2.LowCmd {
        var command = std.mem.zeroes(messages.go2.LowCmd);
        command.head = .{ 0xfe, 0xef };
        command.level_flag = low_level_flag;
        for (&command.motor_cmd) |*motor| {
            motor.mode = 1;
            motor.q = position_stop;
            motor.dq = velocity_stop;
        }
        return command;
    }

    /// Construct an all-zero HG command with caller-supplied machine mode.
    /// Motor modes remain passive (0). The Go2 stop sentinels are not assumed
    /// to have the same meaning on HG devices. Call crc.update before use.
    pub fn initHgCommand(mode: HgMode, mode_machine: u8) messages.hg.LowCmd {
        var command = std.mem.zeroes(messages.hg.LowCmd);
        command.mode_pr = @backingInt(mode);
        command.mode_machine = mode_machine;
        return command;
    }
};

test "wireless packet offsets and every bit round trip" {
    const remote: Remote = .{
        .head = .{ 0xfe, 0xef },
        .buttons = .{ .r1 = true, .l2 = true, .a = true, .left = true },
        .lx = 1,
        .rx = -0.5,
        .ry = 0.25,
        .l2 = 0.75,
        .ly = -1,
        .reserve = @splat(0xa5),
    };
    const bytes = remote.encode();
    try std.testing.expectEqualSlices(u8, &.{ 0xfe, 0xef, 0x21, 0x81 }, bytes[0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0x80, 0x3f }, bytes[4..8]);
    const decoded = try Remote.decode(&bytes);
    try std.testing.expectEqual(remote, decoded);
    for (0..16) |index| {
        const key: Button = @fromBackingInt(@as(u4, @intCast(index)));
        const buttons = Buttons.fromBits(@as(u16, 1) << @as(u4, @intCast(index)));
        try std.testing.expect(buttons.isPressed(key));
        var raw_packet: [packet_size]u8 = @splat(0x7f);
        std.mem.writeInt(u16, raw_packet[2..4], buttons.bits(), .little);
        const packet = (try Remote.decode(&raw_packet)).encode();
        try std.testing.expectEqualSlices(u8, &raw_packet, &packet);
    }
    try std.testing.expectError(error.InvalidLength, Remote.decode(bytes[0..39]));
    var special = bytes;
    std.mem.writeInt(u32, special[4..8], 0x7fc01234, .little);
    std.mem.writeInt(u32, special[8..12], 0x80000000, .little);
    std.mem.writeInt(u32, special[12..16], 0x7f800000, .little);
    const round_trip = (try Remote.decode(&special)).encode();
    try std.testing.expectEqualSlices(u8, &special, &round_trip);
}

test "button edges do not repeat and clicks use the supplied clock" {
    var tracker: Tracker = .{};
    tracker.update(.{ .a = true });
    try std.testing.expect(tracker.on_pressed.a);
    tracker.update(.{ .a = true });
    try std.testing.expectEqual(@as(u16, 0), tracker.on_pressed.bits());
    tracker.update(.{ .b = true });
    try std.testing.expect(tracker.on_released.a and tracker.on_pressed.b);

    var button: ButtonState = .{};
    button.update(true, 1_000_000_000);
    try std.testing.expectEqual(@as(u32, 0), button.click_count);
    button.update(false, 1_100_000_000);
    try std.testing.expect(button.on_released);
    button.update(true, 1_300_000_000);
    try std.testing.expectEqual(@as(u32, 1), button.click_count);
    button.update(false, 1_400_000_000);
    button.update(true, 2_000_000_000);
    try std.testing.expectEqual(@as(u32, 0), button.click_count);
}

test "axis deadzone and threshold edges" {
    var axis: AxisState = .{ .smooth = 1 };
    axis.update(0.005);
    try std.testing.expectEqual(@as(f32, 0), axis.data);
    axis.update(-0.75);
    try std.testing.expect(axis.on_pressed);
    axis.update(-1);
    try std.testing.expect(!axis.on_pressed and axis.pressed);
    axis.update(0.5);
    try std.testing.expect(axis.on_released);
    axis.update(0.75);
    // Edge detection compares the previous value strictly with the threshold.
    try std.testing.expect(axis.pressed and !axis.on_pressed);
}

test "remote tracker resets clicks after strict button inactivity and ignores axis motion" {
    var joystick = RemoteTracker.init(1_000_000_000);
    joystick.lx.smooth = 1;
    const pressed: Remote = .{ .buttons = .{ .a = true, .l2 = true, .f1 = true }, .lx = -0.75 };
    joystick.extract(pressed, 1_000_000_000);
    joystick.extract(.{}, 1_100_000_000);
    joystick.extract(pressed, 1_200_000_000);
    try std.testing.expectEqual(@as(u32, 1), joystick.button(.a).click_count);
    const combined = joystick.combine();
    try std.testing.expect(combined.buttons.a and combined.buttons.l2 and !combined.buttons.f1);
    try std.testing.expectEqual(@as(f32, -0.75), combined.lx);
    joystick.extract(.{ .lx = 1 }, 1_700_000_000);
    try std.testing.expectEqual(@as(u32, 1), joystick.button(.a).click_count);
    joystick.extract(.{ .lx = 1 }, 1_700_000_001);
    try std.testing.expectEqual(@as(u32, 0), joystick.button(.a).click_count);
    try std.testing.expectEqual(@as(f32, 1), joystick.lx.data);
    try std.testing.expectError(error.InvalidLength, joystick.extractPacket(&.{0}, 2_000_000_000));
}

test "low-level initialization matches upstream fields" {
    const command = low_level.initGo2Command();
    try std.testing.expectEqualSlices(u8, &.{ 0xfe, 0xef }, &command.head);
    try std.testing.expectEqual(@as(u8, 0xff), command.level_flag);
    for (command.motor_cmd) |motor| {
        try std.testing.expectEqual(@as(u8, 1), motor.mode);
        try std.testing.expectEqual(low_level.position_stop, motor.q);
        try std.testing.expectEqual(low_level.velocity_stop, motor.dq);
        try std.testing.expectEqual(@as(f32, 0), motor.kp + motor.kd + motor.tau);
    }
    const hg = low_level.initHgCommand(.ab, 7);
    try std.testing.expectEqual(@as(u8, 1), hg.mode_pr);
    try std.testing.expectEqual(@as(u8, 7), hg.mode_machine);
    for (hg.motor_cmd) |motor| try std.testing.expectEqual(@as(u8, 0), motor.mode);
}

test "joystick tracks hold duration, repeated clicks, and positive-axis thresholds" {
    var joystick: Joystick = .{};
    joystick.lx.smooth = 1;
    joystick.lt.smooth = 1;
    const remote: Remote = .{ .buttons = .{ .a = true, .l2 = true }, .lx = -1 };
    joystick.extract(remote, 1_000_000_000);
    try std.testing.expectEqual(@as(u32, 1), joystick.button(.a).click_count);
    try std.testing.expect(!joystick.lx.key.pressed);
    try std.testing.expect(joystick.lt.key.pressed);
    joystick.extract(remote, 1_100_000_000);
    try std.testing.expectApproxEqAbs(@as(f32, 0.1), joystick.button(.a).pressed_time, 0.0001);
    joystick.extract(.{}, 1_200_000_000);
    try std.testing.expect(joystick.button(.a).on_released);
    try std.testing.expectApproxEqAbs(@as(f32, 0.1), joystick.button(.a).pressed_time, 0.0001);
    joystick.extract(remote, 1_300_000_000);
    try std.testing.expectEqual(@as(u32, 2), joystick.button(.a).click_count);
    const combined = joystick.combine();
    try std.testing.expect(combined.buttons.a and combined.buttons.l2);
    try std.testing.expectEqual(@as(f32, -1), combined.lx);
}
