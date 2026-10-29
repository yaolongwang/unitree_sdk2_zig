# 高级 RPC 传输

`transport` 绑定上游的 `ClientStub`、`ServerStub`、`RequestFuture`、`RequestFutureQueue`、`LeaseServer` 和 `LeaseCache`。机器人客户端适合正常业务调用；高级传输适合自定义服务、需要控制完整请求头的协议和自行管理异步响应的应用。

所有 `Request` / `Response` 都使用 `messages.api` 中同一套 C 视图。`identity.id`、`api_id`、`lease.id`、`priority`、`noreply`、文本和二进制负载均原样转换。调用方负责为同一客户端尚未结束的请求分配不同的 ID。

```zig
const sdk = @import("unitree_sdk2");

try sdk.ChannelFactory.init(0, "eth0");
defer sdk.ChannelFactory.deinit() catch {};
var client = try sdk.transport.ClientStub.init("custom_service");
defer client.deinit();

var request = sdk.messages.init(sdk.messages.api.Request);
request.header.identity.id = 1;
request.header.identity.api_id = 1001;
request.parameter = sdk.core.string("{}");
var future = try client.sendRequest(&request, 1_000_000);
defer future.deinit();
var response = try future.wait(1_000_000);
defer response.deinit();
const status = response.value().header.status.code;
_ = status;
```

`ClientStub.sendRequest` 的超时控制 DDS 写入；`RequestFuture.wait` 的超时控制响应等待，单位都为微秒，等待参数为 0 表示无限等待。传输成功并不代表机器人状态码为零：检查返回消息的 `header.status.code`。返回的 `Message(Response)` 是深拷贝，独立于客户端、future 和回调生命周期。响应或超时中的第一个结果成为终态，后续 `ready` 不再改变它；超时仅移除仍指向本 future 的队列条目，重试业务请求时分配新的 ID。

`ServerStub.init` 启动接收。回调获得可发送任意响应的 `ResponseSender`，以及本次回调内有效的借用 `Request` 视图。`ResponseSender` 没有销毁方法。回调可以复制请求以延后处理；延后发送时必须保证服务端仍存活。服务端应自行遵守 `noreply` 并设置对应的响应身份字段。禁止在回调中销毁同一个服务端。

`RequestFuture.init`、`ready` 和 `FutureQueue` 可用于自定义调度器。每个 future handle 持有共享所有权，`get` 返回的 handle 需要独立 `deinit`。队列的 `put`、`get`、`remove`、`size` 保留上游行为；`setQueue` 会关联超时清理逻辑并将尚未使用的 future 插入队列，无需再次 `put`。重复 `put`，以及成功关联、等待或完成后的 `setQueue`，均返回 false。修改 ID 应在 `setQueue`、等待、完成和跨线程共享之前进行。future 以弱引用关联队列，不形成共享引用环；队列销毁后，不再被其他 handle 持有的条目会立即释放。`wait` 和 `ready` 可以并发调用，同一 handle 的销毁需等该 handle 的所有调用结束。

`LeaseServer.init` 接受完整租约服务名（通常是 `<service>_lease`）和微秒租期，后调用 `start`。C++ 上游保留传入名称，不自动追加后缀。`denied` 使用上游的租约检查和到期逻辑。`LeaseCache` 是不需要 DDS 的本地状态容器，公开 set、renew、clear、id、name、lastModified；它本身不提供同步。

独立的 `sdk.LeaseClient.init` 同样接收完整租约服务名，并立即开始申请/续期。它的 `setTimeout` 与 `setTimeoutUs` 会等待正在执行的 RPC 完成，再更新后续请求的超时，避免与后台线程并发修改同一个 SDK 字段。

## 关闭与资源释放

客户端关闭时先停止并等待响应回调，再释放请求队列。不要在响应回调中销毁同一个客户端；关闭前应结束应用侧对该客户端的并发调用。

正在等待 RPC 响应的租约申请仍受客户端 timeout 约束，关闭会等该调用返回。已取得租约后的周期等待可立即唤醒。服务端销毁先拒绝新的分发，等待当前处理器及响应发送结束，然后关闭队列和通道。

先释放客户端、服务端及其租约对象，最后释放进程级 `ChannelFactory`。
