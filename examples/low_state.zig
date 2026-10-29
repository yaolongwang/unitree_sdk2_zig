//! 订阅 Go2 低层状态，接收五秒后退出，不发送控制命令。
const std = @import("std");
const sdk = @import("unitree_sdk2");

const Receiver = struct {
    // 接收回调运行在 SDK 线程上，使用原子计数与主线程共享结果。
    count: std.atomic.Value(u64) = .init(0),

    fn receive(self: *Receiver, message: *const sdk.messages.go2.LowState) void {
        // message 只在本次回调中有效；需要长期保留时使用 Message.clone。
        const count = self.count.fetchAdd(1, .monotonic);
        if (count == 0) {
            std.debug.print("首条状态：tick={d}，关节 0 位置={d}\n", .{
                message.tick,
                message.motor_state[0].q,
            });
        }
    }
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) {
        std.debug.print("用法：low_state <连接机器人的网卡>\n", .{});
        return error.InvalidArguments;
    }
    // 先创建进程级 DDS 环境；defer 逆序执行，订阅者会先于环境关闭。
    try sdk.ChannelFactory.init(0, args[1]);
    defer sdk.ChannelFactory.deinit() catch {};
    // 回调上下文必须一直存活到订阅者关闭之后。
    var receiver: Receiver = .{};
    var subscriber = try sdk.Subscriber(sdk.messages.go2.LowState).init(
        "rt/lowstate",
        Receiver,
        &receiver,
        Receiver.receive,
        16,
    );
    defer subscriber.deinit();
    try std.Io.sleep(init.io, .fromSeconds(5), .awake);
    try subscriber.checkLastCallback();
    std.debug.print("共收到 {d} 条状态\n", .{receiver.count.load(.acquire)});
}
