//! Generated, field-wise C views of every pinned SDK DDS message.
//! Variable-length fields borrow storage; clone messages to retain callback data.
const raw = @import("raw");
const std = @import("std");
pub const String = raw.usdk_string;

pub const PointFieldType = enum(u8) {
    int8 = 1,
    uint8 = 2,
    int16 = 3,
    uint16 = 4,
    int32 = 5,
    uint32 = 6,
    float32 = 7,
    float64 = 8,
};

/// Construct a zero-initialized message, including padding and empty sequences.
pub fn init(comptime T: type) T {
    _ = typeId(T);
    return std.mem.zeroes(T);
}

pub const api = struct {
    pub const Request = raw.usdk_api_Request;
    pub const RequestHeader = raw.usdk_api_RequestHeader;
    pub const RequestIdentity = raw.usdk_api_RequestIdentity;
    pub const RequestLease = raw.usdk_api_RequestLease;
    pub const RequestPolicy = raw.usdk_api_RequestPolicy;
    pub const Response = raw.usdk_api_Response;
    pub const ResponseHeader = raw.usdk_api_ResponseHeader;
    pub const ResponseStatus = raw.usdk_api_ResponseStatus;
};

pub const go2 = struct {
    pub const AudioData = raw.usdk_go2_AudioData;
    pub const BmsCmd = raw.usdk_go2_BmsCmd;
    pub const BmsState = raw.usdk_go2_BmsState;
    pub const ConfigChangeStatus = raw.usdk_go2_ConfigChangeStatus;
    pub const Error = raw.usdk_go2_Error;
    pub const Go2FrontVideoData = raw.usdk_go2_Go2FrontVideoData;
    pub const HeightMap = raw.usdk_go2_HeightMap;
    pub const IMUState = raw.usdk_go2_IMUState;
    pub const InterfaceConfig = raw.usdk_go2_InterfaceConfig;
    pub const LidarState = raw.usdk_go2_LidarState;
    pub const LowCmd = raw.usdk_go2_LowCmd;
    pub const LowState = raw.usdk_go2_LowState;
    pub const MotorCmd = raw.usdk_go2_MotorCmd;
    pub const MotorCmds = raw.usdk_go2_MotorCmds;
    pub const MotorState = raw.usdk_go2_MotorState;
    pub const MotorStates = raw.usdk_go2_MotorStates;
    pub const PathPoint = raw.usdk_go2_PathPoint;
    pub const Req = raw.usdk_go2_Req;
    pub const Res = raw.usdk_go2_Res;
    pub const SportModeCmd = raw.usdk_go2_SportModeCmd;
    pub const SportModeState = raw.usdk_go2_SportModeState;
    pub const TimeSpec = raw.usdk_go2_TimeSpec;
    pub const UwbState = raw.usdk_go2_UwbState;
    pub const UwbSwitch = raw.usdk_go2_UwbSwitch;
    pub const VoxelMapCompressed = raw.usdk_go2_VoxelMapCompressed;
    pub const WirelessController = raw.usdk_go2_WirelessController;
};

pub const hg = struct {
    pub const AgvBmsState = raw.usdk_hg_AgvBmsState;
    pub const BmsCmd = raw.usdk_hg_BmsCmd;
    pub const BmsState = raw.usdk_hg_BmsState;
    pub const HandCmd = raw.usdk_hg_HandCmd;
    pub const HandState = raw.usdk_hg_HandState;
    pub const IMUState = raw.usdk_hg_IMUState;
    pub const LowCmd = raw.usdk_hg_LowCmd;
    pub const LowState = raw.usdk_hg_LowState;
    pub const MainBoardState = raw.usdk_hg_MainBoardState;
    pub const MotorCmd = raw.usdk_hg_MotorCmd;
    pub const MotorState = raw.usdk_hg_MotorState;
    pub const PressSensorState = raw.usdk_hg_PressSensorState;
    pub const SportModeState = raw.usdk_hg_SportModeState;
};

pub const hg_doubleimu = struct {
    pub const doubleIMUState = raw.usdk_hg_doubleimu_doubleIMUState;
};

pub const ros2 = struct {
    pub const Header = raw.usdk_ros2_Header;
    pub const Imu = raw.usdk_ros2_Imu;
    pub const MapMetaData = raw.usdk_ros2_MapMetaData;
    pub const OccupancyGrid = raw.usdk_ros2_OccupancyGrid;
    pub const Odometry = raw.usdk_ros2_Odometry;
    pub const Point = raw.usdk_ros2_Point;
    pub const Point32 = raw.usdk_ros2_Point32;
    pub const PointCloud2 = raw.usdk_ros2_PointCloud2;
    pub const PointField = raw.usdk_ros2_PointField;
    pub const PointStamped = raw.usdk_ros2_PointStamped;
    pub const Pose = raw.usdk_ros2_Pose;
    pub const Pose2D = raw.usdk_ros2_Pose2D;
    pub const PoseStamped = raw.usdk_ros2_PoseStamped;
    pub const PoseWithCovariance = raw.usdk_ros2_PoseWithCovariance;
    pub const PoseWithCovarianceStamped = raw.usdk_ros2_PoseWithCovarianceStamped;
    pub const Quaternion = raw.usdk_ros2_Quaternion;
    pub const QuaternionStamped = raw.usdk_ros2_QuaternionStamped;
    pub const String = raw.usdk_ros2_String;
    pub const Time = raw.usdk_ros2_Time;
    pub const Twist = raw.usdk_ros2_Twist;
    pub const TwistStamped = raw.usdk_ros2_TwistStamped;
    pub const TwistWithCovariance = raw.usdk_ros2_TwistWithCovariance;
    pub const TwistWithCovarianceStamped = raw.usdk_ros2_TwistWithCovarianceStamped;
    pub const Vector3 = raw.usdk_ros2_Vector3;
};

/// Stable within the pinned upstream/schema version. Do not persist across regeneration.
pub fn typeId(comptime T: type) u32 {
    @setEvalBranchQuota(10000);
    if (T == go2.AudioData) return 33;
    if (T == go2.BmsCmd) return 34;
    if (T == go2.BmsState) return 35;
    if (T == go2.ConfigChangeStatus) return 36;
    if (T == go2.Error) return 37;
    if (T == go2.Go2FrontVideoData) return 38;
    if (T == go2.HeightMap) return 39;
    if (T == go2.IMUState) return 40;
    if (T == go2.InterfaceConfig) return 41;
    if (T == go2.LidarState) return 42;
    if (T == go2.LowCmd) return 43;
    if (T == go2.LowState) return 44;
    if (T == go2.MotorCmd) return 45;
    if (T == go2.MotorCmds) return 46;
    if (T == go2.MotorState) return 47;
    if (T == go2.MotorStates) return 48;
    if (T == go2.PathPoint) return 49;
    if (T == go2.Req) return 50;
    if (T == go2.Res) return 51;
    if (T == go2.SportModeCmd) return 52;
    if (T == go2.SportModeState) return 53;
    if (T == go2.TimeSpec) return 54;
    if (T == go2.UwbState) return 55;
    if (T == go2.UwbSwitch) return 56;
    if (T == go2.VoxelMapCompressed) return 57;
    if (T == go2.WirelessController) return 58;
    if (T == hg.AgvBmsState) return 59;
    if (T == hg.BmsCmd) return 60;
    if (T == hg.BmsState) return 61;
    if (T == hg.HandCmd) return 62;
    if (T == hg.HandState) return 63;
    if (T == hg.IMUState) return 64;
    if (T == hg.LowCmd) return 65;
    if (T == hg.LowState) return 66;
    if (T == hg.MainBoardState) return 67;
    if (T == hg.MotorCmd) return 68;
    if (T == hg.MotorState) return 69;
    if (T == hg.PressSensorState) return 70;
    if (T == hg.SportModeState) return 71;
    if (T == hg_doubleimu.doubleIMUState) return 72;
    if (T == ros2.Header) return 23;
    if (T == ros2.Imu) return 20;
    if (T == ros2.MapMetaData) return 17;
    if (T == ros2.OccupancyGrid) return 18;
    if (T == ros2.Odometry) return 19;
    if (T == ros2.Point32) return 2;
    if (T == ros2.PointCloud2) return 21;
    if (T == ros2.PointField) return 22;
    if (T == ros2.PointStamped) return 3;
    if (T == ros2.Point) return 4;
    if (T == ros2.Pose2D) return 5;
    if (T == ros2.PoseStamped) return 6;
    if (T == ros2.PoseWithCovarianceStamped) return 7;
    if (T == ros2.PoseWithCovariance) return 8;
    if (T == ros2.Pose) return 9;
    if (T == ros2.QuaternionStamped) return 10;
    if (T == ros2.Quaternion) return 11;
    if (T == ros2.String) return 24;
    if (T == ros2.Time) return 1;
    if (T == ros2.TwistStamped) return 12;
    if (T == ros2.TwistWithCovarianceStamped) return 13;
    if (T == ros2.TwistWithCovariance) return 14;
    if (T == ros2.Twist) return 15;
    if (T == ros2.Vector3) return 16;
    if (T == api.RequestHeader) return 25;
    if (T == api.RequestIdentity) return 26;
    if (T == api.RequestLease) return 27;
    if (T == api.RequestPolicy) return 28;
    if (T == api.Request) return 29;
    if (T == api.ResponseHeader) return 30;
    if (T == api.ResponseStatus) return 31;
    if (T == api.Response) return 32;
    @compileError("T is not a Unitree SDK2 message type");
}
pub const count: usize = 72;

test "message IDs are unique and cover the declared range" {
    var seen: [count + 1]bool = @splat(false);
    var total: usize = 0;
    inline for (.{ api, go2, hg, hg_doubleimu, ros2 }) |Group| {
        inline for (@typeInfo(Group).@"struct".decl_names) |name| {
            const id = typeId(@field(Group, name));
            try std.testing.expect(id > 0 and id <= count);
            try std.testing.expect(!seen[id]);
            seen[id] = true;
            total += 1;
        }
    }
    try std.testing.expectEqual(count, total);
}
