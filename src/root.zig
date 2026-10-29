//! Unitree SDK2 bindings for Zig 0.17. The raw layer exposes a stable C ABI;
//! typed clients and channels own their native handles. See README for lifetimes.
pub const raw = @import("raw");
pub const core = @import("core.zig");
pub const Error = core.Error;
pub const lastError = core.lastError;
pub const lastStatus = core.lastStatus;
pub const Buffer = core.Buffer;
pub const ChannelFactory = core.ChannelFactory;
pub const Client = core.Client;
pub const clients = @import("clients.zig");
pub const constants = @import("constants.zig");
pub const messages = @import("messages.zig");
pub const channel = @import("channel.zig");
pub const Publisher = channel.Publisher;
pub const Subscriber = channel.Subscriber;
pub const Message = channel.Message;
pub const rpc = @import("server.zig");
pub const Server = rpc.Server;
pub const LeaseClient = rpc.LeaseClient;
pub const transport = @import("transport.zig");
pub const crc = @import("crc.zig");
pub const remote_control = @import("remote_control.zig");
pub const low_level = remote_control.low_level;
pub const termination = @import("termination.zig");
pub const robots = @import("robots.zig");
pub const scheduling = @import("scheduling.zig");
pub const sync = @import("sync.zig");

pub const go2 = clients.go2;
pub const b2 = clients.b2;
pub const g1 = clients.g1;
pub const h1 = clients.h1;
pub const h2 = clients.h2;
pub const r1 = clients.r1;
pub const a2 = clients.a2;
pub const as2 = clients.as2;
pub const MotionSwitcherClient = clients.b2.MotionSwitcherClient;

test {
    _ = @import("core.zig");
    _ = @import("server.zig");
    _ = @import("messages.zig");
    _ = @import("crc.zig");
    _ = @import("remote_control.zig");
    _ = @import("termination.zig");
    _ = @import("robots.zig");
    _ = @import("scheduling.zig");
    _ = @import("sync.zig");
}
