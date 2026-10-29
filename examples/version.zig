//! 读取 Go2 运动服务的 API 版本，不发送运动指令。
const std = @import("std");
const sdk = @import("unitree_sdk2");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) {
        std.debug.print("用法：version <连接机器人的网卡>\n", .{});
        return error.InvalidArguments;
    }
    // 使用连接机器人的网卡初始化 DDS，再创建类型化客户端。
    try sdk.ChannelFactory.init(0, args[1]);
    defer sdk.ChannelFactory.deinit() catch {};
    var sport = try sdk.go2.SportClient.init(false);
    defer sport.deinit();
    try sport.setTimeout(3.0);
    // 服务端返回的版本字符串由 Buffer 持有，需要显式释放。
    var version = try sport.client.serverApiVersion();
    defer version.deinit();
    std.debug.print("运动服务 API 版本：{s}\n", .{version.slice()});
}
