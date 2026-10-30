const sdk = @import("unitree_sdk2");

comptime {
    @setEvalBranchQuota(100000);
    referenceAll(sdk.clients);
    referenceAll(sdk.core);
    referenceAll(sdk.rpc);
    referenceAll(sdk.transport);
    referenceAll(sdk.robots);
    referenceAll(sdk.scheduling);
    referenceAll(sdk.sync.BoundedQueue(u32));
    referenceAll(sdk.sync.Future(u32));
    referenceAll(sdk.scheduling.AsyncPublisher(sdk.messages.go2.LowCmd));
    referenceAll(sdk.scheduling.RealtimePublisher(sdk.messages.go2.LowCmd));
    referenceAll(sdk.scheduling.CachedSubscriber(sdk.messages.go2.LowState));
    referenceAll(sdk.constants);
    referenceAll(sdk.Publisher(sdk.messages.go2.LowCmd));
    referenceAll(sdk.Subscriber(sdk.messages.go2.LowState));
    referenceAll(sdk.Message(sdk.messages.ros2.PointCloud2));
}

fn referenceAll(comptime T: type) void {
    inline for (@typeInfo(T).@"struct".decl_names) |name| {
        const decl = @field(T, name);
        _ = &@field(T, name);
        if (@TypeOf(decl) == type) {
            if (@typeInfo(decl) == .@"struct") referenceAll(decl);
        }
    }
}

export fn unitreeSdk2CompileCheck() void {}
