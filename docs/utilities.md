# 数据、遥控器与型号便利层

这些模块使用 Zig 0.17；CRC、字段准备、关节定义、遥控器和终止条件计算不需要原生 SDK。`robots` 中实际打开 DDS 通道或调用运动切换器的函数需要 Linux 原生桥。

## CRC

`crc.compute(&message)`、`crc.update(&message)` 和 `crc.verify(&message)` 支持 `messages.go2.LowCmd`、`go2.LowState`、`hg.LowCmd`、`hg.LowState`。`compute` 忽略现有 `crc` 字段，`update` 写入它，`verify` 检查接收到的值。每次修改消息后都需要重新计算。

```zig
const sdk = @import("unitree_sdk2");

var command = sdk.low_level.initGo2Command();
// 设置本次所需的各字段后计算校验值。
sdk.crc.update(&command);
const checksum_matches = sdk.crc.verify(&command);
```

`crc.encode` 返回包含末尾 CRC 字的固定长度字节数组；它逐字段写入 little-endian 值，并将协议中的 padding 写为零，不读取 C/C++ 结构体的 padding。长度分别为 812、1180、1004、2092 字节。这是上游 CRC 使用的低层对象布局，不是 DDS CDR 序列化。

`crc.fromWords` 接收数值 `u32` 数组，`crc.fromBytes` 接收 little-endian 字节序列，后者拒绝不足四字节的尾部。两者初值为 `0xffffffff`，多项式为 `0x04c11db7`，没有反射或末尾 XOR。`crc.crc16` 另行实现 `dds_wrapper/common/crc.h` 的 CRC16：反射多项式 `0xa001`、初值 `0xffff`，不截断为上游 `unsigned short` 长度。

## 遥控器

`remote_control.Remote.decode` 要求完整的 40 字节，`encode` 保留全部位，包括头、偏移 16 的 L2 模拟量和末尾 16 个保留字节。原始浮点值不裁剪，NaN payload 和负零位模式可往返。

| 字节偏移         | 字段                             |
| ---------------- | -------------------------------- |
| 0–1              | head                             |
| 2–3              | little-endian 按键位图           |
| 4、8、12、16、20 | lx、rx、ry、l2、ly，各四字节 f32 |
| 24–39            | reserve                          |

按键位依次为 `r1`、`l1`、`start`、`select`、`r2`、`l2`、`f1`、`f2`、`a`、`b`、`x`、`y`、`up`、`right`、`down`、`left`。可用 `remote.buttons.a` 或 `remote.buttons.isPressed(.a)` 读取；`Tracker.update` 产生 `on_pressed`、`on_released` 和当前 `pressed`。

不同状态类型采用以下点击计数和轴处理规则：

| Zig 类型       | 行为                                                                         |
| -------------- | ---------------------------------------------------------------------------- |
| `ButtonState`  | 首次点击计 0，相隔不超过 300 ms 的下一次点击加 1                             |
| `AxisState`    | 默认 smooth=0.03、deadzone=0.01、threshold=0.5；按轴值绝对值判断阈值         |
| `KeyState`     | 首次点击计 1，相隔严格小于 500 ms 的连击增加；释放时保留按下时长一个更新周期 |
| `JoystickAxis` | 默认 smooth=0.03、deadzone=0.01、threshold=0.5；仅当轴值大于正阈值时视为按下 |
| `Joystick`     | 16 按键、四轴、LT/RT，支持 `extract` / `combine`；LS/RS 由主机输入提供       |

状态更新显式接收应用单调时钟的 `now_ns`。`Joystick.combine` 将未使用的字节置零。调用 `joystick.button(.a)` 访问一个按键的边缘、连击和时长；LB/RB 对应 l1/r1，back 对应 select。

`RemoteTracker` 用于追踪连续的 `Remote` 报文，维护按键边缘、连击计数、平滑轴值和空闲复位。`RemoteTracker.init(now_ns)` 从应用时钟建立空闲起点，按键与四轴分别使用 `ButtonState` 和 `AxisState`。`extractPacket(bytes, now_ns)` 解析完整遥控数据，`combine()` 返回 `Remote`。默认连续超过 500 ms 无按键活动后清零点击计数，也可显式调用 `resetAllClickCounts()`。轴运动不重置按钮空闲计时；F1/F2 不参与提取、合成或批量清零。主机手柄的设备发现和轮询由应用的输入适配器负责，本库处理遥控数据与状态。

完整示例见 [remote_control.zig](../examples/remote_control.zig)，可直接运行 `zig build run-remote_control -Dnative=false`。

## 终止条件

`termination` 对应 G1/H2 的七个函数：`badOrientation`、`jointVelocityOutOfLimit`、`angularVelocityOutOfLimit`、`motorWindingOverheat`、`motorCasingOverheat`、`lowBattery`、`lostConnection`。`termination.defaults` 保存原默认阈值：1 rad、10 rad/s、6 rad/s、120°C、85°C、20% 和 1000 ms。

状态/电池函数接收 `*const messages.hg.LowState` 或 `*const messages.hg.BmsState` 以及显式阈值。姿态使用 `[w,x,y,z]` 四元数并沿用上游未归一化、未 clamp 的计算；无效四元数可产生 NaN，其比较结果为 false。不能把该判断视为四元数有效性校验。

`lostConnection(now_ns, last_available_ns, timeout_ms)` 使用单调时钟纳秒；仅在严格超过阈值时返回 true，负的 last timestamp 表示尚无数据。内部使用 i128 差值，避免极端 i64 时间戳溢出。

## 低层初始化和型号定义

`low_level.initGo2Command` 对应官方低层例程的初始化：头为 FE EF、level_flag 为 FF、20 个 motor.mode 为 1、q/dq 使用 `position_stop = 2.146e9` / `velocity_stop = 16000`，增益和转矩为零。`initHgCommand(mode, mode_machine)` 创建被动 mode=0 的 HG 命令，PR/AB 分别为 0/1。初始化函数不自动计算 CRC。

`robots.go2.JointIndex`、`robots.g1.JointIndex`、`robots.r1.JointIndex` 对应固定上游 `defines.h`，使用 Zig 的 snake_case 标签。G1 与 R1 的腰部索引不同；R1 保留原始索引空洞。`g1.arm_joints` 有 17 项（14 手臂、3 腰部），`r1.arm_joints` 有 13 项。

`robots.g1.setArmWeight(&command, weight)` 把 clamp 后的系数写入 `motor_cmd[29].q`；R1 的同名函数将其乘 100 后截断为整数写入 `mode_pr`。相应 `armWeight` 可读取。非有限输入返回 `error.InvalidArgument`。`g1.checkModeMachine` 比较命令/状态的 `mode_machine`；状态为 0 时按上游模拟环境规则接受任意命令模式。

## 型号发布订阅

以下类型均在 `robots` 下。固定消息 publisher 提供 `newMessage`、`init`、`initTopic`、`prepare`、`write` 和 `deinit`；消息存储位于 `.message`。订阅者提供 `init`、`initTopic`、`setTimeoutMs`、`isTimeout`、`waitForConnection`、`lastDataTime`、`deinit`，接收用户回调。需要保存动态消息时可在回调内用 `sdk.Message(T).clone`。

| 命名空间         | 类型与默认主题                                                                                                                                                   |
| ---------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| go2.publisher    | LowCmd→`rt/lowcmd`、LowState→`rt/lowstate`、SportModeState→`rt/sportmodestate`、WirelessController→`rt/wirelesscontroller`；MotorCmds/MotorStates 由调用者给主题 |
| go2.subscription | LowCmd、LowState、SportModeState 使用同名默认主题；MotorCmds/MotorStates 由调用者给主题                                                                          |
| g1.publisher     | LowCmd→`rt/lowcmd`、LowState→`rt/lowstate`、ArmSdk→`rt/arm_sdk`                                                                                                  |
| g1.subscription  | LowCmd、LowState、ArmSdk 使用同名默认主题；InspireHandState→`rt/inspire/state`、Dex3LeftHandState→`rt/dex3/left/state`、Dex3RightHandState→`rt/dex3/right/state` |
| r1.publisher     | ArmSdk→`rt/arm_sdk`                                                                                                                                              |

固定消息 publisher 的 `write` 同步准备并发布数据，失败返回错误。需要上游实时编辑/异步发送行为时，使用 `initRealtime` 或 `initRealtimeTopic`；需要缓存订阅时，使用 `initCached` 或 `initCachedTopic`。这些入口返回下面的 scheduling 类型，构造后显式调用 `start`。

Go2 publisher.LowCmd 的默认值匹配 `dds_wrapper`：仅头、level_flag、motor.mode 非零，q/dq 初始为零。它与上述官方低层例程使用 stop sentinel 的初始化不同。Go2/HG LowCmd 和 LowState 的发布准备会更新 CRC；LowState 可设置 `.remote` 或 `.joystick` 来更新 `wireless_remote`。WirelessController 从同样来源提取四轴和键值。ArmSdk 的准备沿用上游，不额外写 CRC。

MotorCmds/MotorStates publisher 使用 `init(allocator, topic, count)` 或默认 count=1 的 `initDefault`，拥有 `.values` 数组；支持 `resize`、`view`、`write`、`deinit`。`view` 借用数组内存，resize/deinit 后失效。

`waitForConnection(io, max_wait_ms)` 使用 SDK 的单调时间和显式 Zig `std.Io` 可取消睡眠；null 表示一直等待。`robots.JoystickMonitor.update(&state.wireless_remote, now_ns)` 等价于 Go2/G1 LowState 的遥控器更新和空包超时检测，阈值默认 3000 ms；没有过有效包时报告超时。`go2.gaitType` / `position` / `velocity` 提取 SportModeState 字段，无需 Eigen。

`robots.go2.shutdown(io, options)` 执行 MotionSwitcher 检查/释放循环，默认 RPC 超时 3 秒、每次释放间隔 3 秒，可指定最大释放次数；网络错误和取消会直接返回。已有调度器可调用 `shutdownStep(&client)`：无活动控制器时返回 true，已请求释放时返回 false。以上函数只在调用时运行，导入模块不会打开通道或改变机器人状态。

## 异步发布、缓存与周期任务

`scheduling` 使用线程安全的显式 `std.Io`，例如 `std.Io.Threaded.io()`。Io、allocator 和 callback context 必须活到使用它们的对象关闭之后。对象创建后调用 `start`；`stop` 会唤醒等待并 join 工作线程，之后可再次 `start`。生命周期操作由同一控制方串行执行，不能在自身工作线程/回调内 stop/deinit。

- `AsyncPublisher(T)`：`send(&message)` 在返回前深复制字符串和序列，有界 FIFO 由工作线程写入 DDS。`PublisherOptions` 指定 capacity、overflow（reject_new 或 drop_oldest）、DDS wait_us。`stats` 保留 accepted/sent/dropped/errors、queued/in_flight/running、最近 Zig 错误和工作线程原始 SDK status。`waitIdle`、`clear`、`stop(.drain)`、`stop(.discard)` 分别等待清空、丢弃队列、排空关闭、丢弃关闭；关闭均等待正在执行的写入。
- `RealtimePublisher(T)`：拥有可编辑 `.message`，提供 `tryLock` / `lock` / `unlock` / `unlockAndPublish`。最后一个方法在锁内执行 prepare 和深复制，成功或错误都释放编辑锁。支持 `.prepare` 和 `.prepare_context`；型号 `initRealtime` 已设置对应默认消息及 CRC 准备。队列满时返回 QueueFull，而不是静默覆盖。这里的“Realtime”延续上游名称，不保证硬实时期限；深复制可分配内存。
- `CachedSubscriber(T)`：拥有 topic 和稳定回调地址，收到消息后深复制并加锁替换最新状态。`snapshot()` 返回独立拥有的 `Message(T)`，调用者最终 deinit；`cache.withLatest` 在锁内短时访问，不能把借用指针带出回调。`cache.waitForUpdate` 按 revision 等待；`waitForConnection`、`isTimeout` 使用接收时间。`stop` 关闭 DDS 并保留最后快照，`reset` 清空快照，`start` 可恢复接收。`stats` 记录克隆错误，`checkLastCallback` 另检查 native 转换错误。销毁前应结束外部读者/等待者。
- `PeriodicTask`：首次 callback 立即调用，随后按固定期限运行；慢 callback 会记录并跳过 missed_periods，避免追赶突发。stop 可打断长间隔等待；callback 错误保存在 stats 并继续下一周期。interval_ns=0 为协作式连续循环。
- `FrequencySampler`：并发 `sample()` 计数，控制线程用 `take(now_ns)` 获取实际时间段内 Hz 并清零，或用 `reset` 重置。可配合 PeriodicTask 定期报告，不强制输出日志。

模型快捷入口同样使用这套实现：`robots.go2.publisher.LowCmd.initRealtime(allocator, io, options)`、`robots.g1.subscription.LowState.initCached(allocator, io, queue_len)`。MotorCmds/MotorStates 提供 `initAsync`，发送其 `view()` 后原数组可立即继续修改。动态字段始终遵循各对象的拥有/借用约定。

## 通用队列与 Future

`sdk.sync` 提供有界队列和 Future，用于应用侧同步，不需要 DDS。两个类型均接收线程安全的 `std.Io`，开始并发使用后不能移动对象；销毁前必须停止并 join 所有使用者和等待者。

`BoundedQueue(T).init(allocator, io, capacity)` 创建有界 FIFO。`put(value, false)` 在满时返回 `QueueFull`，此时值仍归调用者；成功时队列接管值的嵌套资源责任。`put(value, true)` 在满时替换最旧项，并把被替换的 `?T` 返回给调用者释放。`get(timeout)` 取出并转移一个值；超时返回 `Timeout`，不会修改其他项。所有 T 都只按值浅复制，不推测字符串、指针或切片的释放方式。

`interrupt()` 让当前阻塞的读取者返回 `Interrupted`，之后队列仍可使用。`close()` 拒绝新写入并唤醒等待者，已有项仍可逐个取出，排空后返回 `Closed`。`size()` 加锁读取长度；`clear(context, release)` 对每个待处理值调用一次释放函数。释放函数在队列锁内执行，不能重入该队列。调用 `deinit()` 前必须完成全部线程并排空或 clear；它只释放环形缓冲区。

`Future(T).init(allocator, io)` 创建未完成结果。`ready(value)` 或 `try fail(reason)` 只允许一个完成者成功，重复完成返回 false。`wait(timeout)` 等待完成，`getResult(timeout)` 返回 `.value: T` 或 `.failure: []const u8`；超时后仍可再次等待。`fail` 独立复制错误文本，文本保持有效直到 future 销毁。`close()` 让未完成的等待者返回 `Closed`，保留已完成的结果。

Future 支持多个读取者重复取值，因此 T 使用浅复制、共享读取语义，不转移或释放嵌套资源。使用可自由复制的值，或由外部 owner 管理的只读资源；所有读取者不能分别释放同一个切片。`deinit()` 仅释放 future 自己复制的错误文本。需要一次性转移资源时使用队列，或在应用层显式管理唯一 owner。

单次后台任务可使用 `std.Thread.spawn` 配合 `sync.Future`，在线程内使用 `std.Thread.getCurrentId()` 获取并发布线程 ID。`timerfd_*` 的 Linux 专用入口由 `std.os.linux` 提供；跨平台定时使用 `PeriodicTask`。调用 C 接口可使用 Zig 的 C ABI 导入，运行时动态符号查找可使用 `std.DynLib`；共享状态由显式对象或模块管理。
