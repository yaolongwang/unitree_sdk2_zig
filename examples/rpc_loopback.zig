//! 在本机运行 RPC 服务端和客户端，完成一次文本回显，无需机器人。
const std = @import("std");
const sdk = @import("unitree_sdk2");

fn echo(_: ?*anyopaque, _: i32, request: []const u8, reply: sdk.rpc.Reply) i32 {
    // 回复对象会复制数据；返回值是传给客户端的服务状态码。
    reply.set(request) catch return sdk.constants.internal.ut_robot_err_server_internal;
    return 0;
}

pub fn main() !void {
    // 使用回环网卡和独立 domain，客户端与服务端共用同一 DDS 环境。
    try sdk.ChannelFactory.init(226, "lo");
    defer sdk.ChannelFactory.deinit() catch {};

    var server = try sdk.Server.init("zig_example", "1.0.0");
    defer server.deinit();
    // 注册文本 API 1001，不要求客户端持有租约。
    try server.register(1001, false, false, echo, null);
    try server.start(false);

    var client = try sdk.Client.init("zig_example", "1.0.0", false);
    defer client.deinit();
    try client.setTimeout(2.0);
    try client.registerApi(1001, 0);
    // 响应拥有独立缓冲区，读取后由调用者释放。
    var response = try client.call(1001, "来自 Zig 0.17 的消息");
    defer response.deinit();
    std.debug.print("RPC 响应：{s}\n", .{response.slice()});
}
