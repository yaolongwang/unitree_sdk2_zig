# 示例

从仓库根目录执行命令。`zig build examples` 只编译示例，不运行机器人指令。

| 示例                                     | 用途                        | 运行命令                                      |
| ---------------------------------------- | --------------------------- | --------------------------------------------- |
| [low_command.zig](low_command.zig)       | 本地构造低层命令并计算 CRC  | `zig build run-low_command -Dnative=false`    |
| [remote_control.zig](remote_control.zig) | 本地解析遥控报文与按键状态  | `zig build run-remote_control -Dnative=false` |
| [rpc_loopback.zig](rpc_loopback.zig)     | 本机文本 RPC 服务与调用     | `zig build run-rpc_loopback`                  |
| [version.zig](version.zig)               | 读取 Go2 运动服务版本       | `zig build run-version -- eth0`               |
| [low_state.zig](low_state.zig)           | 接收 Go2 低层状态，持续五秒 | `zig build run-low_state -- eth0`             |
| [sport_control.zig](sport_control.zig)   | 向 Go2 发送一次运动指令     | `zig build run-sport_control -- eth0 stand`   |

前两个示例可在 Windows、macOS 和 Linux 运行，其余需要 Linux 原生 SDK。连接机器人时，将 `eth0` 替换为实际网卡名。

`sport_control` 的动作参数为 `stand`（起身）、`lie`（趴下）、`balance`（平衡站立）、`stop`（停止移动）。它会实际发送所选指令；`--help` 仅显示用法。
