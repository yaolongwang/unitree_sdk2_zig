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
        // This path throws and catches a C++ exception before DDS is initialized.
        try std.testing.expectError(error.InvalidArgument, sdk.Client.init("consumer", "1.0.0", false));
    }
    std.debug.print("Downstream package import, runtime, exceptions and CRC passed\n", .{});
}
