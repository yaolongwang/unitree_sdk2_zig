//! Unitree word-wise CRC, including the four low-level command/state layouts.
//! Encoding reads fields individually and writes zero padding. It never hashes
//! native struct memory, and is independent of host endianness and padding.
const std = @import("std");
const messages = @import("messages.zig");

pub const polynomial: u32 = 0x04c11db7;
pub const initial: u32 = 0xffffffff;

/// CRC16 from dds_wrapper/common/crc.h (reflected polynomial 0xa001,
/// initial 0xffff, no final XOR). Length is not truncated to an unsigned short.
pub fn crc16(bytes: []const u8) u16 {
    var crc: u16 = 0xffff;
    for (bytes) |byte| {
        crc ^= byte;
        for (0..8) |_| {
            crc = if (crc & 1 != 0) (crc >> 1) ^ 0xa001 else crc >> 1;
        }
    }
    return crc;
}

/// Compute the Unitree CRC over numeric 32-bit words. No final XOR is applied.
pub fn fromWords(words: []const u32) u32 {
    var crc = initial;
    for (words) |word| crc = updateWord(crc, word);
    return crc;
}

/// Decode little-endian words and compute their CRC. The supplied bytes do not
/// include a trailing checksum. A partial word is an error, never truncated.
pub fn fromBytes(bytes: []const u8) error{UnalignedByteLength}!u32 {
    if (bytes.len % 4 != 0) return error.UnalignedByteLength;
    var crc = initial;
    var offset: usize = 0;
    while (offset < bytes.len) : (offset += 4) {
        const word = std.mem.readInt(u32, bytes[offset..][0..4], .little);
        crc = updateWord(crc, word);
    }
    return crc;
}

fn updateWord(previous: u32, word: u32) u32 {
    var crc = previous ^ word;
    for (0..32) |_| {
        crc = if (crc & 0x80000000 != 0) (crc << 1) ^ polynomial else crc << 1;
    }
    return crc;
}

/// Exact packed size including the final checksum word.
pub fn encodedSize(comptime T: type) comptime_int {
    if (T == messages.go2.LowCmd) return 812;
    if (T == messages.go2.LowState) return 1180;
    if (T == messages.hg.LowCmd) return 1004;
    if (T == messages.hg.LowState) return 2092;
    @compileError("Unitree CRC supports go2/hg LowCmd and LowState only");
}

/// Encode the official low-level CRC layout, including the existing crc field.
/// `message` is a pointer to one of go2/hg LowCmd/LowState.
pub fn encode(message: anytype) [encodedSize(@TypeOf(message.*))]u8 {
    const T = @TypeOf(message.*);
    var writer: Writer(encodedSize(T)) = .{};
    if (T == messages.go2.LowCmd) {
        writeGo2Header(&writer, message);
        for (message.motor_cmd) |motor| {
            writer.put(motor.mode);
            writer.zero(3);
            writeMotorCommand(&writer, motor);
        }
        writer.put(message.bms_cmd.off);
        writer.put(message.bms_cmd.reserve);
        writer.put(message.wireless_remote);
        writer.put(message.led);
        writer.put(message.fan);
        writer.put(message.gpio);
        writer.zero(1);
        writer.put(message.reserve);
    } else if (T == messages.go2.LowState) {
        writeGo2Header(&writer, message);
        writeImu(&writer, message.imu_state);
        writer.zero(3);
        for (message.motor_state) |motor| {
            writer.put(motor.mode);
            writer.zero(3);
            writer.put(motor.q);
            writer.put(motor.dq);
            writer.put(motor.ddq);
            writer.put(motor.tau_est);
            writer.put(motor.q_raw);
            writer.put(motor.dq_raw);
            writer.put(motor.ddq_raw);
            writer.put(motor.temperature);
            writer.zero(3);
            writer.put(motor.lost);
            writer.put(motor.reserve);
        }
        const bms = message.bms_state;
        writer.put(bms.version_high);
        writer.put(bms.version_low);
        writer.put(bms.status);
        writer.put(bms.soc);
        writer.put(bms.current);
        writer.put(bms.cycle);
        writer.put(bms.bq_ntc);
        writer.put(bms.mcu_ntc);
        writer.put(bms.cell_vol);
        writer.put(message.foot_force);
        writer.put(message.foot_force_est);
        writer.put(message.tick);
        writer.put(message.wireless_remote);
        writer.put(message.bit_flag);
        writer.zero(3);
        writer.put(message.adc_reel);
        writer.put(message.temperature_ntc1);
        writer.put(message.temperature_ntc2);
        writer.zero(2);
        writer.put(message.power_v);
        writer.put(message.power_a);
        writer.put(message.fan_frequency);
        writer.put(message.reserve);
    } else if (T == messages.hg.LowCmd) {
        writer.put(message.mode_pr);
        writer.put(message.mode_machine);
        writer.zero(2);
        for (message.motor_cmd) |motor| {
            writer.put(motor.mode);
            writer.zero(3);
            writeMotorCommand(&writer, motor);
        }
        writer.put(message.reserve);
    } else if (T == messages.hg.LowState) {
        writer.put(message.version);
        writer.put(message.mode_pr);
        writer.put(message.mode_machine);
        writer.zero(2);
        writer.put(message.tick);
        writeImu(&writer, message.imu_state);
        writer.zero(2);
        for (message.motor_state) |motor| {
            writer.put(motor.mode);
            writer.zero(3);
            writer.put(motor.q);
            writer.put(motor.dq);
            writer.put(motor.ddq);
            writer.put(motor.tau_est);
            writer.put(motor.temperature);
            writer.put(motor.vol);
            writer.put(motor.sensor);
            writer.put(motor.motorstate);
            writer.put(motor.reserve);
        }
        writer.put(message.wireless_remote);
        writer.put(message.reserve);
    }
    writer.put(message.crc);
    std.debug.assert(writer.offset == encodedSize(T));
    return writer.data;
}

/// Compute without mutating the message. Its existing checksum is ignored.
pub fn compute(message: anytype) u32 {
    const bytes = encode(message);
    return fromBytes(bytes[0 .. bytes.len - 4]) catch unreachable;
}

/// Write the computed checksum to the message.
pub fn update(message: anytype) void {
    message.crc = compute(message);
}

/// Check a received low-level message against its checksum field.
pub fn verify(message: anytype) bool {
    return compute(message) == message.crc;
}

fn Writer(comptime size: usize) type {
    return struct {
        data: [size]u8 = @splat(0),
        offset: usize = 0,

        fn zero(self: *@This(), count: usize) void {
            self.offset += count;
            std.debug.assert(self.offset <= size);
        }

        fn put(self: *@This(), value: anytype) void {
            const T = @TypeOf(value);
            switch (@typeInfo(T)) {
                .array => for (value) |element| self.put(element),
                .float => self.put(@as(u32, @bitCast(value))),
                .int => {
                    const U = switch (@bitSizeOf(T)) {
                        8 => u8,
                        16 => u16,
                        32 => u32,
                        else => @compileError("Unexpected low-level CRC integer width"),
                    };
                    var bits: U = @bitCast(value);
                    for (0..@sizeOf(T)) |_| {
                        self.data[self.offset] = @truncate(bits);
                        self.offset += 1;
                        if (@bitSizeOf(T) > 8) bits >>= 8;
                    }
                },
                else => @compileError("CRC encoding must write each scalar field explicitly"),
            }
        }
    };
}

fn writeGo2Header(writer: anytype, message: anytype) void {
    writer.put(message.head);
    writer.put(message.level_flag);
    writer.put(message.frame_reserve);
    writer.put(message.sn);
    writer.put(message.version);
    writer.put(message.bandwidth);
    writer.zero(2);
}

fn writeMotorCommand(writer: anytype, motor: anytype) void {
    writer.put(motor.q);
    writer.put(motor.dq);
    writer.put(motor.tau);
    writer.put(motor.kp);
    writer.put(motor.kd);
    writer.put(motor.reserve);
}

fn writeImu(writer: anytype, imu: anytype) void {
    writer.put(imu.quaternion);
    writer.put(imu.gyroscope);
    writer.put(imu.accelerometer);
    writer.put(imu.rpy);
    writer.put(imu.temperature);
}

fn populateFixture(pointer: anytype, counter: *usize) void {
    const T = @TypeOf(pointer.*);
    switch (@typeInfo(T)) {
        .@"struct" => |info| inline for (info.field_names) |field_name| {
            populateFixture(&@field(pointer, field_name), counter);
        },
        .array => for (pointer) |*element| populateFixture(element, counter),
        .float => {
            counter.* += 1;
            pointer.* = @as(f32, @floatFromInt(@as(i32, @intCast(counter.* % 13)) - 6)) * 0.125;
        },
        .int => |info| {
            counter.* += 1;
            pointer.* = if (info.signedness == .unsigned)
                @intCast(counter.* % 97)
            else
                -@as(T, @intCast(counter.* % 17));
        },
        else => @compileError("Unexpected fixture field"),
    }
}

test "word order, polynomial and non-reflected CRC" {
    try std.testing.expectEqual(initial, fromWords(&.{}));
    try std.testing.expectEqual(@as(u32, 0xc704dd7b), fromWords(&.{0}));
    try std.testing.expectEqual(fromWords(&.{0x12345678}), try fromBytes(&.{ 0x78, 0x56, 0x34, 0x12 }));
    try std.testing.expectError(error.UnalignedByteLength, fromBytes(&.{ 1, 2, 3 }));
}

test "CRC16 matches the upstream lookup table check vector" {
    try std.testing.expectEqual(@as(u16, 0xffff), crc16(""));
    try std.testing.expectEqual(@as(u16, 0x4b37), crc16("123456789"));
}

test "all four formats match independent reference and native CRC fixtures" {
    // Verified independently by tests/reference/crc_reference.py using C++ SDK layouts and CRC.
    // reference: go2.LowCmd = 0xea59b621
    // reference: go2.LowState = 0x4963a432
    // reference: hg.LowCmd = 0x0b2681f9
    // reference: hg.LowState = 0xab47bd70
    const types = .{ messages.go2.LowCmd, messages.go2.LowState, messages.hg.LowCmd, messages.hg.LowState };
    const expected = [_]u32{ 0xea59b621, 0x4963a432, 0x0b2681f9, 0xab47bd70 };
    inline for (types, expected) |T, checksum| {
        var first: T = undefined;
        var second: T = undefined;
        @memset(std.mem.asBytes(&first), 0xa5);
        @memset(std.mem.asBytes(&second), 0x5a);
        var first_counter: usize = 0;
        var second_counter: usize = 0;
        populateFixture(&first, &first_counter);
        populateFixture(&second, &second_counter);
        try std.testing.expectEqual(checksum, compute(&first));
        try std.testing.expectEqual(checksum, compute(&second));
        const first_bytes = encode(&first);
        const second_bytes = encode(&second);
        try std.testing.expectEqualSlices(u8, &first_bytes, &second_bytes);
        update(&first);
        try std.testing.expect(verify(&first));
        first.crc ^= 1;
        try std.testing.expect(!verify(&first));
        try std.testing.expectEqual(checksum, compute(&first));
    }
}
