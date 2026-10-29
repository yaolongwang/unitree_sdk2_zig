//! 在本地解析遥控报文，演示按键边沿和摇杆状态，无需机器人。
const std = @import("std");
const sdk = @import("unitree_sdk2");
const remote_control = sdk.remote_control;

pub fn main() !void {
    // 构造一帧示例报文；接入机器人时可直接读取 LowState.wireless_remote。
    const source: remote_control.Remote = .{
        .buttons = .{ .a = true },
        .lx = 0.5,
        .ly = -0.25,
    };
    const packet = source.encode();
    const remote = try remote_control.Remote.decode(&packet);
    std.debug.print("报文 {d} 字节：A={}，左摇杆=({d}, {d})\n", .{
        packet.len, remote.buttons.a, remote.lx, remote.ly,
    });

    // 时间戳单位为纳秒，实际应用应传入同一单调时钟的采样值。
    // 连续输入报文后，可读取按下/释放边沿、连击计数和平滑后的轴值。
    var tracker = remote_control.RemoteTracker.init(0);
    try tracker.extractPacket(&packet, 20 * std.time.ns_per_ms);
    std.debug.print("A 刚按下={}，平滑后的左轴={d}\n", .{
        tracker.button(.a).on_pressed, tracker.lx.data,
    });

    // 下一帧全部按键释放；按住状态变为 false，释放边沿只持续一帧。
    tracker.extract(.{}, 40 * std.time.ns_per_ms);
    std.debug.print("A 按住={}，A 刚释放={}\n", .{
        tracker.button(.a).pressed, tracker.button(.a).on_released,
    });
}
