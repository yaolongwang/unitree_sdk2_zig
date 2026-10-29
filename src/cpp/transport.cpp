#include "usdk_transport.h"
#include "messages_internal.hpp"
#include <unitree/robot/client/client_stub.hpp>
#include <unitree/robot/server/server_stub.hpp>
#include <unitree/robot/server/lease_server.hpp>
#include <chrono>
#include <functional>
#include <map>
#include <mutex>
#include <unordered_map>

// Field converters are generated in messages_api.cpp, including nested fields.
void from_view(const usdk_api_Request&, unitree::robot::Request&);
void from_view(const usdk_api_Response&, unitree::robot::Response&);
void to_view(const unitree::robot::Request&, usdk_api_Request&, MessageArena&);
void to_view(const unitree::robot::Response&, usdk_api_Response&, MessageArena&);

namespace {
using unitree::robot::RequestFuture;
using unitree::robot::RequestFutureQueue;

struct FutureState {
    // Accessed under RequestFuture's real mMutexCond. A weak association avoids
    // the upstream queue -> future -> queue ownership cycle.
    std::weak_ptr<RequestFutureQueue> queue;
    int64_t queued_id = 0;
    bool used = false;
};
struct QueueState {
    // Created in the queue's constructor, where the lambda has ordinary member
    // access. It removes only this future, never a replacement with the same ID.
    std::function<void(int64_t, const RequestFuture*)> remove_if;
};
struct FutureRegistry {
    std::mutex mutex;
    std::unordered_map<const RequestFuture*, std::shared_ptr<FutureState>> futures;
    std::unordered_map<const RequestFutureQueue*, std::shared_ptr<QueueState>> queues;
};
FutureRegistry& future_registry() {
    static FutureRegistry registry;
    return registry;
}
std::shared_ptr<FutureState> future_state(const RequestFuture* future) {
    auto& registry = future_registry();
    std::lock_guard<std::mutex> lock(registry.mutex);
    return registry.futures.at(future);
}
void remove_expired_future(const std::shared_ptr<RequestFutureQueue>& queue,
                           int64_t request_id, const RequestFuture* expected) {
    std::shared_ptr<QueueState> state;
    {
        auto& registry = future_registry();
        std::lock_guard<std::mutex> lock(registry.mutex);
        state = registry.queues.at(queue.get());
    }
    state->remove_if(request_id, expected);
}
} // namespace

// Define all strong symbols from request_future.cpp.o and client_stub.cpp.o.
// These repairs retain the official layout, message protocol and queue behavior.
namespace unitree {
namespace robot {
RequestFuture::RequestFuture() : RequestFuture(0) {}
RequestFuture::RequestFuture(int64_t request_id) : mState(DEFER), mRequestId(request_id) {
    auto state = std::make_shared<FutureState>();
    auto& registry = future_registry();
    std::lock_guard<std::mutex> lock(registry.mutex);
    registry.futures.emplace(this, std::move(state));
}
RequestFuture::~RequestFuture() {
    auto& registry = future_registry();
    std::lock_guard<std::mutex> lock(registry.mutex);
    registry.futures.erase(this);
}
void RequestFuture::SetRequestId(int64_t request_id) {
    common::LockGuard<common::MutexCond> lock(mMutexCond);
    if (future_state(this)->used)
        throw std::invalid_argument("Set request ID before queueing, waiting or completing it");
    __atomic_store_n(&mRequestId, request_id, __ATOMIC_RELEASE);
}
int64_t RequestFuture::GetRequestId() const {
    return __atomic_load_n(&mRequestId, __ATOMIC_ACQUIRE);
}
bool RequestFuture::IsDeferred() { return mState == DEFER; }
bool RequestFuture::IsReady() { return mState == READY; }
bool RequestFuture::SetQueue(const RequestFutureQueuePtr& queue) {
    if (!queue) throw std::invalid_argument("Null future queue");
    common::LockGuard<common::MutexCond> lock(mMutexCond);
    const auto state = future_state(this);
    if (state->used) return false;
    const auto request_id = GetRequestId();
    if (!queue->Put(request_id, shared_from_this())) return false;
    state->queue = queue;
    state->queued_id = request_id;
    state->used = true;
    return true;
}
const ResponsePtr& RequestFuture::GetResponse(int64_t microseconds) {
    if (microseconds < 0) throw std::invalid_argument("Negative future timeout");
    std::shared_ptr<RequestFutureQueue> expired_queue;
    int64_t expired_id = 0;
    {
        common::LockGuard<common::MutexCond> lock(mMutexCond);
        const auto state = future_state(this);
        state->used = true;
        const auto started = std::chrono::steady_clock::now();
        while (IsDeferred()) {
            int64_t remaining = 0;
            if (microseconds != 0) {
                const auto elapsed = std::chrono::duration_cast<std::chrono::microseconds>(
                    std::chrono::steady_clock::now() - started).count();
                if (elapsed >= microseconds) {
                    // A timeout is terminal. The returned shared_ptr remains
                    // immutable after unlocking, including when Ready arrives late.
                    mState = READY;
                    expired_queue = state->queue.lock();
                    expired_id = state->queued_id;
                    state->queue.reset();
                    mMutexCond.NotifyAll();
                    break;
                }
                remaining = microseconds - elapsed;
            }
            mMutexCond.Wait(remaining);
        }
    }
    if (expired_queue) remove_expired_future(expired_queue, expired_id, this);
    return mResponsePtr;
}
void RequestFuture::Ready(const ResponsePtr& response) {
    common::LockGuard<common::MutexCond> lock(mMutexCond);
    future_state(this)->used = true;
    if (!IsDeferred()) return;
    mResponsePtr = response;
    mState = READY;
    mMutexCond.NotifyAll();
}
RequestFutureQueue::RequestFutureQueue() {
    auto state = std::make_shared<QueueState>();
    state->remove_if = [this](int64_t request_id, const RequestFuture* expected) {
        common::LockGuard<common::Mutex> lock(mMutex);
        const auto found = mFutureMap.find(request_id);
        if (found != mFutureMap.end() && found->second.get() == expected)
            mFutureMap.erase(found);
    };
    auto& registry = future_registry();
    std::lock_guard<std::mutex> lock(registry.mutex);
    registry.queues.emplace(this, std::move(state));
}
RequestFutureQueue::~RequestFutureQueue() {
    auto& registry = future_registry();
    std::lock_guard<std::mutex> lock(registry.mutex);
    registry.queues.erase(this);
}
RequestFuturePtr RequestFutureQueue::Get(int64_t request_id) {
    common::LockGuard<common::Mutex> lock(mMutex);
    const auto found = mFutureMap.find(request_id);
    if (found == mFutureMap.end()) return {};
    auto result = std::move(found->second);
    mFutureMap.erase(found);
    return result;
}
bool RequestFutureQueue::Put(int64_t request_id, const RequestFuturePtr& future) {
    if (!future) throw std::invalid_argument("Null request future");
    common::LockGuard<common::Mutex> lock(mMutex);
    return mFutureMap.emplace(request_id, future).second;
}
void RequestFutureQueue::Remove(int64_t request_id) {
    common::LockGuard<common::Mutex> lock(mMutex);
    mFutureMap.erase(request_id);
}
size_t RequestFutureQueue::Size() {
    common::LockGuard<common::Mutex> lock(mMutex);
    return mFutureMap.size();
}
ClientStub::ClientStub() = default;
ClientStub::~ClientStub() {
    // Stop and join response callbacks before releasing the queue they access.
    mChannelLaborPtr.reset();
    mFutureQueuePtr.reset();
}
void ClientStub::Init(const std::string& name) {
    if (mChannelLaborPtr) throw std::invalid_argument("Client stub already initialized");
    mFutureQueuePtr = std::make_shared<RequestFutureQueue>();
    auto channel = std::make_shared<ClientChannelLabor<Request, Response>>();
    channel->InitChannel(name, [this](const void* message) { ResponseFunc(message); }, 10);
    mChannelLaborPtr = std::move(channel);
}
bool ClientStub::Send(const Request& request, int64_t timeout) {
    if (!mChannelLaborPtr) throw std::invalid_argument("Client stub is not initialized");
    return mChannelLaborPtr->Send(request, timeout);
}
RequestFuturePtr ClientStub::SendRequest(const Request& request, int64_t timeout) {
    if (!mFutureQueuePtr) throw std::invalid_argument("Client stub is not initialized");
    const auto id = request.header().identity().id();
    auto future = std::make_shared<RequestFuture>(id);
    if (!future->SetQueue(mFutureQueuePtr)) return {};
    try {
        if (Send(request, timeout)) return future;
    } catch (...) {
        remove_expired_future(mFutureQueuePtr, id, future.get());
        throw;
    }
    remove_expired_future(mFutureQueuePtr, id, future.get());
    return {};
}
void ClientStub::ResponseFunc(const void* message) {
    const auto& response = *static_cast<const Response*>(message);
    const auto future = mFutureQueuePtr->Get(response.header().identity().id());
    if (future) future->Ready(std::make_shared<Response>(response));
}
} // namespace robot
} // namespace unitree

struct usdk_client_stub { unitree::robot::ClientStub value; };
struct usdk_request_future { unitree::robot::RequestFuturePtr value; };
struct usdk_future_queue {
    unitree::robot::RequestFutureQueuePtr value = std::make_shared<unitree::robot::RequestFutureQueue>();
};
struct usdk_server_stub {
    std::atomic<int32_t> callback_error{0};
    // Destroy/join the native stub before callback_error storage disappears.
    unitree::robot::ServerStub value;
};
struct usdk_lease_server {
    std::unique_ptr<unitree::robot::LeaseServer> value;
    bool started = false;
};
struct usdk_lease_cache { unitree::robot::LeaseCache value; };

namespace {
std::string service_name(usdk_string service) {
    auto name = usdk::string(service);
    if (name.empty() || name.find('\0') != std::string::npos)
        throw std::invalid_argument("service name must be nonempty and contain no NUL");
    return name;
}
void require_timeout(int64_t timeout_us) {
    if (timeout_us < 0) throw std::invalid_argument("negative timeout");
}
unitree::robot::RequestFuture& future_value(const usdk_request_future *future) {
    if (!future || !future->value) throw std::invalid_argument("null request future");
    return *future->value;
}
}

extern "C" {
int32_t usdk_client_stub_create(usdk_string service, usdk_client_stub **out) {
    if (out) *out = nullptr;
    return usdk::guard([&]() -> int32_t {
        if (!out) throw std::invalid_argument("null client stub output");
        const auto name = service_name(service);
        usdk::require_channel();
        auto handle = std::make_unique<usdk_client_stub>();
        handle->value.Init(name);
        *out = handle.release();
        return 0;
    });
}
int32_t usdk_client_stub_send(usdk_client_stub *client, const usdk_api_Request *request, int64_t timeout_us) {
    return usdk::guard([&]() -> int32_t {
        if (!client || !request) throw std::invalid_argument("null client stub send argument");
        require_timeout(timeout_us);
        unitree::robot::Request value;
        from_view(*request, value);
        return client->value.Send(value, timeout_us) ? 0 : USDK_TIMEOUT;
    });
}
int32_t usdk_client_stub_request(usdk_client_stub *client, const usdk_api_Request *request, int64_t timeout_us, usdk_request_future **out) {
    if (out) *out = nullptr;
    return usdk::guard([&]() -> int32_t {
        if (!client || !request || !out) throw std::invalid_argument("null client stub request argument");
        require_timeout(timeout_us);
        unitree::robot::Request value;
        from_view(*request, value);
        auto handle = std::make_unique<usdk_request_future>();
        handle->value = client->value.SendRequest(value, timeout_us);
        if (!handle->value) return USDK_TIMEOUT;
        *out = handle.release();
        return 0;
    });
}
void usdk_client_stub_destroy(usdk_client_stub *client) {
    (void)usdk::guard([&]() -> int32_t { delete client; return 0; });
}
int32_t usdk_future_create(int64_t request_id, usdk_request_future **out) {
    if (out) *out = nullptr;
    return usdk::guard([&]() -> int32_t {
        if (!out) throw std::invalid_argument("null future output");
        auto handle = std::make_unique<usdk_request_future>();
        handle->value = std::make_shared<unitree::robot::RequestFuture>(request_id);
        *out = handle.release();
        return 0;
    });
}
int32_t usdk_future_set_id(usdk_request_future *future, int64_t request_id) {
    return usdk::guard([&]() -> int32_t { future_value(future).SetRequestId(request_id); return 0; });
}
int32_t usdk_future_id(const usdk_request_future *future, int64_t *out) {
    return usdk::guard([&]() -> int32_t {
        if (!out) throw std::invalid_argument("null future ID output");
        *out = future_value(future).GetRequestId();
        return 0;
    });
}
int32_t usdk_future_wait(usdk_request_future *future, int64_t timeout_us, usdk_owned_message **out) {
    if (out) *out = nullptr;
    return usdk::guard([&]() -> int32_t {
        if (!out) throw std::invalid_argument("null response output");
        require_timeout(timeout_us);
        const auto response = future_value(future).GetResponse(timeout_us);
        if (!response) return USDK_TIMEOUT;
        auto owned = std::make_unique<OwnedMessage<usdk_api_Response>>();
        to_view(*response, owned->value, owned->arena);
        *out = owned.release();
        return 0;
    });
}
int32_t usdk_future_ready(usdk_request_future *future, const usdk_api_Response *response) {
    return usdk::guard([&]() -> int32_t {
        if (!response) throw std::invalid_argument("null future response");
        auto& target = future_value(future);
        auto value = std::make_shared<unitree::robot::Response>();
        from_view(*response, *value);
        target.Ready(value);
        return 0;
    });
}
int32_t usdk_future_set_queue(usdk_request_future *future, usdk_future_queue *queue, bool *accepted) {
    return usdk::guard([&]() -> int32_t {
        if (!queue || !accepted) throw std::invalid_argument("null future queue argument");
        *accepted = future_value(future).SetQueue(queue->value);
        return 0;
    });
}
void usdk_future_destroy(usdk_request_future *future) {
    (void)usdk::guard([&]() -> int32_t { delete future; return 0; });
}
int32_t usdk_future_queue_create(usdk_future_queue **out) {
    if (out) *out = nullptr;
    return usdk::guard([&]() -> int32_t {
        if (!out) throw std::invalid_argument("null future queue output");
        *out = new usdk_future_queue();
        return 0;
    });
}
int32_t usdk_future_queue_put(usdk_future_queue *queue, int64_t request_id, const usdk_request_future *future, bool *inserted) {
    return usdk::guard([&]() -> int32_t {
        if (!queue || !inserted) throw std::invalid_argument("null queue put argument");
        future_value(future);
        *inserted = queue->value->Put(request_id, future->value);
        return 0;
    });
}
int32_t usdk_future_queue_get(usdk_future_queue *queue, int64_t request_id, usdk_request_future **out) {
    if (out) *out = nullptr;
    return usdk::guard([&]() -> int32_t {
        if (!queue || !out) throw std::invalid_argument("null queue get argument");
        auto handle = std::make_unique<usdk_request_future>();
        handle->value = queue->value->Get(request_id);
        if (handle->value) *out = handle.release();
        return 0;
    });
}
int32_t usdk_future_queue_remove(usdk_future_queue *queue, int64_t request_id) {
    return usdk::guard([&]() -> int32_t {
        if (!queue) throw std::invalid_argument("null future queue");
        queue->value->Remove(request_id);
        return 0;
    });
}
int32_t usdk_future_queue_size(usdk_future_queue *queue, size_t *out) {
    return usdk::guard([&]() -> int32_t {
        if (!queue || !out) throw std::invalid_argument("null queue size argument");
        *out = queue->value->Size();
        return 0;
    });
}
void usdk_future_queue_destroy(usdk_future_queue *queue) {
    (void)usdk::guard([&]() -> int32_t { delete queue; return 0; });
}
int32_t usdk_server_stub_create(usdk_string service, usdk_stub_callback callback, void *user, bool priority_queue, usdk_server_stub **out) {
    if (out) *out = nullptr;
    return usdk::guard([&]() -> int32_t {
        if (!callback || !out) throw std::invalid_argument("null server stub argument");
        const auto name = service_name(service);
        usdk::require_channel();
        auto handle = std::make_unique<usdk_server_stub>();
        auto *server = handle.get();
        server->value.Init(name, [server, callback, user](const unitree::robot::RequestPtr& request) {
            const int32_t status = usdk::guard([&]() -> int32_t {
                MessageArena arena;
                usdk_api_Request view{};
                to_view(*request, view, arena);
                callback(server, &view, user);
                return 0;
            });
            server->callback_error.store(status, std::memory_order_relaxed);
        }, priority_queue);
        *out = handle.release();
        return 0;
    });
}
int32_t usdk_server_stub_send(usdk_server_stub *server, const usdk_api_Response *response, int64_t timeout_us) {
    return usdk::guard([&]() -> int32_t {
        if (!server || !response) throw std::invalid_argument("null server stub send argument");
        require_timeout(timeout_us);
        unitree::robot::Response value;
        from_view(*response, value);
        return server->value.Send(value, timeout_us) ? 0 : USDK_TIMEOUT;
    });
}
int32_t usdk_server_stub_last_error(const usdk_server_stub *server) {
    return server ? server->callback_error.load(std::memory_order_relaxed) : USDK_INVALID_ARGUMENT;
}
void usdk_server_stub_destroy(usdk_server_stub *server) {
    (void)usdk::guard([&]() -> int32_t { delete server; return 0; });
}
int32_t usdk_lease_server_create(usdk_string service, int64_t term_us, usdk_lease_server **out) {
    if (out) *out = nullptr;
    return usdk::guard([&]() -> int32_t {
        if (!out || term_us <= 0) throw std::invalid_argument("invalid lease server argument");
        const auto name = service_name(service);
        usdk::require_channel();
        auto handle = std::make_unique<usdk_lease_server>();
        handle->value = std::make_unique<unitree::robot::LeaseServer>(name, term_us);
        handle->value->Init();
        *out = handle.release();
        return 0;
    });
}
int32_t usdk_lease_server_start(usdk_lease_server *server, bool priority_queue) {
    return usdk::guard([&]() -> int32_t {
        if (!server || server->started) throw std::invalid_argument("lease server missing or already started");
        server->value->Start(priority_queue);
        server->started = true;
        return 0;
    });
}
int32_t usdk_lease_server_denied(usdk_lease_server *server, int64_t lease_id, bool *out) {
    return usdk::guard([&]() -> int32_t {
        if (!server || !out) throw std::invalid_argument("null lease check argument");
        *out = server->value->CheckRequestLeaseDenied(lease_id);
        return 0;
    });
}
int32_t usdk_lease_server_name(const usdk_lease_server *server, usdk_buffer *out) {
    return usdk::guard([&]() -> int32_t {
        if (!server || !out) throw std::invalid_argument("null lease server name argument");
        const auto& name = server->value->GetName();
        return usdk::copy_buffer(name.data(), name.size(), out);
    });
}
void usdk_lease_server_destroy(usdk_lease_server *server) {
    (void)usdk::guard([&]() -> int32_t { delete server; return 0; });
}
int32_t usdk_lease_cache_create(usdk_lease_cache **out) {
    if (out) *out = nullptr;
    return usdk::guard([&]() -> int32_t {
        if (!out) throw std::invalid_argument("null lease cache output");
        *out = new usdk_lease_cache();
        return 0;
    });
}
int32_t usdk_lease_cache_set(usdk_lease_cache *cache, int64_t id, usdk_string name, int64_t last_modified_us) {
    return usdk::guard([&]() -> int32_t {
        if (!cache) throw std::invalid_argument("null lease cache");
        cache->value.Set(id, usdk::string(name), last_modified_us);
        return 0;
    });
}
int32_t usdk_lease_cache_renew(usdk_lease_cache *cache, int64_t last_modified_us) {
    return usdk::guard([&]() -> int32_t {
        if (!cache) throw std::invalid_argument("null lease cache");
        cache->value.Renewal(last_modified_us);
        return 0;
    });
}
int32_t usdk_lease_cache_clear(usdk_lease_cache *cache) {
    return usdk::guard([&]() -> int32_t {
        if (!cache) throw std::invalid_argument("null lease cache");
        cache->value.Clear();
        return 0;
    });
}
int32_t usdk_lease_cache_id(const usdk_lease_cache *cache, int64_t *out) {
    return usdk::guard([&]() -> int32_t {
        if (!cache || !out) throw std::invalid_argument("null lease cache ID argument");
        *out = cache->value.GetId();
        return 0;
    });
}
int32_t usdk_lease_cache_last_modified(const usdk_lease_cache *cache, int64_t *out) {
    return usdk::guard([&]() -> int32_t {
        if (!cache || !out) throw std::invalid_argument("null lease cache time argument");
        *out = cache->value.GetLastModified();
        return 0;
    });
}
int32_t usdk_lease_cache_name(const usdk_lease_cache *cache, usdk_buffer *out) {
    return usdk::guard([&]() -> int32_t {
        if (!cache || !out) throw std::invalid_argument("null lease cache name argument");
        const auto& name = cache->value.GetName();
        return usdk::copy_buffer(name.data(), name.size(), out);
    });
}
void usdk_lease_cache_destroy(usdk_lease_cache *cache) {
    (void)usdk::guard([&]() -> int32_t { delete cache; return 0; });
}
}
