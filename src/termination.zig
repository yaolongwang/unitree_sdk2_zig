//! G1/H2 termination predicates, expressed in Zig without Eigen or a clock.
//! Limits use the same units and strict `>` / `<` comparisons as upstream.
const std = @import("std");
const messages = @import("messages.zig");

pub const Limits = struct {
    orientation_angle: f32 = 1.0,
    joint_velocity: f32 = 10.0,
    angular_velocity: f32 = 6.0,
    winding_temperature: f32 = 120.0,
    casing_temperature: f32 = 85.0,
    battery_soc: f32 = 20.0,
    connection_timeout_ms: i64 = 1000,
};

pub const defaults: Limits = .{};

/// Tilt in radians using the quaternion [w, x, y, z]. As in the upstream Eigen
/// expression, the quaternion is expected to be normalized. It is not silently
/// normalized or clamped: invalid input can produce NaN and a false predicate.
pub fn badOrientation(state: *const messages.hg.LowState, limit_angle: f32) bool {
    const quaternion = state.imu_state.quaternion;
    const gravity_z = 1 - 2 * (quaternion[1] * quaternion[1] + quaternion[2] * quaternion[2]);
    return @abs(std.math.acos(gravity_z)) > limit_angle;
}

pub fn jointVelocityOutOfLimit(state: *const messages.hg.LowState, limit_velocity: f32) bool {
    for (state.motor_state) |motor| {
        if (@abs(motor.dq) > limit_velocity) return true;
    }
    return false;
}

pub fn angularVelocityOutOfLimit(state: *const messages.hg.LowState, limit_velocity: f32) bool {
    for (state.imu_state.gyroscope) |angular_velocity| {
        if (@abs(angular_velocity) > limit_velocity) return true;
    }
    return false;
}

pub fn motorWindingOverheat(state: *const messages.hg.LowState, limit_temperature: f32) bool {
    for (state.motor_state) |motor| {
        if (@as(f32, @floatFromInt(motor.temperature[1])) > limit_temperature) return true;
    }
    return false;
}

pub fn motorCasingOverheat(state: *const messages.hg.LowState, limit_temperature: f32) bool {
    for (state.motor_state) |motor| {
        if (@as(f32, @floatFromInt(motor.temperature[0])) > limit_temperature) return true;
    }
    return false;
}

pub fn lowBattery(state: *const messages.hg.BmsState, limit_soc: f32) bool {
    return @as(f32, @floatFromInt(state.soc)) < limit_soc;
}

/// Pass timestamps from the same monotonic nanosecond clock. A negative last
/// timestamp is the SDK's no-data sentinel and always reports a lost connection.
/// Intermediate arithmetic uses i128, so valid i64 timestamps cannot overflow.
pub fn lostConnection(now_ns: i64, last_available_ns: i64, timeout_ms: i64) bool {
    if (last_available_ns < 0) return true;
    const elapsed_ns = @as(i128, now_ns) - last_available_ns;
    return elapsed_ns > @as(i128, timeout_ms) * std.time.ns_per_ms;
}

test "tilt projection uses quaternion wxyz and ignores pure yaw" {
    var state = std.mem.zeroes(messages.hg.LowState);
    state.imu_state.quaternion = .{ 1, 0, 0, 0 };
    try std.testing.expect(!badOrientation(&state, defaults.orientation_angle));
    const half_sqrt: f32 = @sqrt(0.5);
    state.imu_state.quaternion = .{ half_sqrt, half_sqrt, 0, 0 };
    try std.testing.expect(badOrientation(&state, defaults.orientation_angle));
    state.imu_state.quaternion = .{ half_sqrt, 0, 0, half_sqrt };
    try std.testing.expect(!badOrientation(&state, defaults.orientation_angle));
}

test "velocity and thermal predicates inspect every motor and retain strict limits" {
    var state = std.mem.zeroes(messages.hg.LowState);
    state.motor_state[34].dq = -10;
    try std.testing.expect(!jointVelocityOutOfLimit(&state, 10));
    state.motor_state[34].dq = -10.1;
    try std.testing.expect(jointVelocityOutOfLimit(&state, 10));
    state.imu_state.gyroscope[2] = -6;
    try std.testing.expect(!angularVelocityOutOfLimit(&state, 6));
    state.imu_state.gyroscope[2] = -6.1;
    try std.testing.expect(angularVelocityOutOfLimit(&state, 6));

    state.motor_state[34].temperature = .{ 85, 120 };
    try std.testing.expect(!motorWindingOverheat(&state, 120));
    try std.testing.expect(!motorCasingOverheat(&state, 85));
    state.motor_state[34].temperature = .{ 86, 121 };
    try std.testing.expect(motorWindingOverheat(&state, 120));
    try std.testing.expect(motorCasingOverheat(&state, 85));
}

test "battery and connection thresholds use percent, milliseconds and nanoseconds" {
    var state = std.mem.zeroes(messages.hg.BmsState);
    state.soc = 20;
    try std.testing.expect(!lowBattery(&state, 20));
    state.soc = 19;
    try std.testing.expect(lowBattery(&state, 20));
    try std.testing.expect(!lostConnection(1_000_000_000, 0, 1000));
    try std.testing.expect(lostConnection(1_000_000_001, 0, 1000));
    try std.testing.expect(lostConnection(0, -1, 1000));
    try std.testing.expect(!lostConnection(0, 1, 1000));
    try std.testing.expect(lostConnection(std.math.maxInt(i64), 0, 1000));
}
