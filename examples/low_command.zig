//! 在本地构造 Go2 低层命令并计算 CRC，不创建发布者或发送数据。
const std = @import("std");
const sdk = @import("unitree_sdk2");

pub fn main() !void {
    // 初始化消息头、电机模式及位置/速度停用值，增益和力矩默认为零。
    var command = sdk.low_level.initGo2Command();
    // 修改任何命令字段后，都需要重新计算 CRC。
    sdk.crc.update(&command);
    std.debug.print("Go2 命令：{d} 字节，CRC=0x{x}，校验通过={}\n", .{
        sdk.crc.encodedSize(@TypeOf(command)),
        command.crc,
        sdk.crc.verify(&command),
    });
}
