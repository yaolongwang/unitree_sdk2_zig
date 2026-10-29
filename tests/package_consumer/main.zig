const std = @import("std");
const sdk = @import("unitree_sdk2");
const options = @import("options");

pub fn main() !void {
    var command = std.mem.zeroes(sdk.messages.hg.LowCmd);
    sdk.crc.update(&command);
    std.debug.assert(sdk.crc.verify(&command));
    if (options.native) {
        var buffer = try sdk.Buffer.copy("downstream package");
        defer buffer.deinit();
        std.debug.assert(std.mem.eql(u8, buffer.slice(), "downstream package"));
        std.debug.assert(sdk.raw.usdk_abi_version() == 1);
    }
    std.debug.print("Downstream package import, runtime and CRC passed\n", .{});
}
