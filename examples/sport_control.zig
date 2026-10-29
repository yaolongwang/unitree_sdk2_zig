//! 使用 Go2 类型化客户端执行一次起身、趴下、平衡站立或停止移动。
const std = @import("std");
const sdk = @import("unitree_sdk2");

const Action = enum { stand, lie, balance, stop };

fn usage() void {
    std.debug.print("用法：sport_control <连接机器人的网卡> <stand|lie|balance|stop>\n", .{});
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len == 2 and std.mem.eql(u8, args[1], "--help")) {
        usage();
        return;
    }
    // 参数确认后才打开 DDS；不传动作时只显示用法。
    if (args.len != 3) {
        usage();
        return error.InvalidArguments;
    }
    const action = std.meta.stringToEnum(Action, args[2]) orelse {
        usage();
        return error.InvalidArguments;
    };

    try sdk.ChannelFactory.init(0, args[1]);
    defer sdk.ChannelFactory.deinit() catch {};
    var sport = try sdk.go2.SportClient.init(false);
    defer sport.deinit();
    try sport.setTimeout(3.0);

    // 每次运行只发送所选动作，不在退出时额外切换机器人姿态。
    const result = switch (action) {
        .stand => sport.standUp(),
        .lie => sport.standDown(),
        .balance => sport.balanceStand(),
        .stop => sport.stopMove(),
    };
    result catch |err| {
        // 在其他 SDK 调用覆盖线程错误信息之前，读取原始状态码。
        std.debug.print("指令失败：{s}，SDK 状态={d}，详情={s}\n", .{
            @errorName(err), sdk.lastStatus(), sdk.lastError(),
        });
        return err;
    };
    std.debug.print("已发送 {s} 指令\n", .{@tagName(action)});
}
