#include "usdk_transport.h"
#include <unitree/robot/future/request_future.hpp>
#include <atomic>
#include <cassert>
#include <chrono>
#include <cstring>
#include <iostream>
#include <thread>

static usdk_string text(const char *value) { return {value, std::strlen(value)}; }

struct EchoState {
    std::atomic<unsigned> calls{0};
    std::atomic<int32_t> send_status{0};
};

static void echo(usdk_server_stub *server, const usdk_api_Request *request, void *user) {
    auto& state = *static_cast<EchoState *>(user);
    assert(request->header.identity.api_id == 4242);
    assert(request->header.lease.id == 312);
    assert(request->header.policy.priority == 5);
    if (!request->header.policy.noreply) {
        usdk_api_Response response{};
        response.header.identity = request->header.identity;
        response.header.status.code = 57;
        response.data = request->parameter;
        response.binary = request->binary;
        state.send_status = usdk_server_stub_send(server, &response, 100000);
    }
    state.calls.fetch_add(1);
}

static void future_lifecycle() {
    using unitree::robot::RequestFuture;
    using unitree::robot::RequestFutureQueue;
    using unitree::robot::Response;
    using unitree::robot::ResponsePtr;

    auto queue = std::make_shared<RequestFutureQueue>();
    auto second_queue = std::make_shared<RequestFutureQueue>();
    auto first = std::make_shared<RequestFuture>(71);
    assert(first->SetQueue(queue));
    assert(!first->SetQueue(queue));
    assert(!first->SetQueue(second_queue));
    assert(queue->Size() == 1 && second_queue->Size() == 0);
    bool rejected_id_change = false;
    try { first->SetRequestId(72); }
    catch (const std::invalid_argument&) { rejected_id_change = true; }
    assert(rejected_id_change && first->GetRequestId() == 71);

    // A failed association must never remove another future with the same ID.
    auto duplicate = std::make_shared<RequestFuture>(71);
    assert(!duplicate->SetQueue(queue));
    assert(!duplicate->GetResponse(1));
    assert(queue->Size() == 1);
    assert(queue->Get(71) == first);
    auto replacement = std::make_shared<RequestFuture>(71);
    assert(replacement->SetQueue(queue));
    assert(!first->GetResponse(1));
    assert(queue->Size() == 1 && queue->Get(71) == replacement);

    auto reply = std::make_shared<Response>();
    reply->data() = "first response";
    // Timeout is terminal; a late response cannot mutate a previously returned
    // shared_ptr reference or make another waiter observe a different outcome.
    first->Ready(reply);
    assert(!first->GetResponse(0));
    auto completed = std::make_shared<RequestFuture>(73);
    completed->Ready(reply);
    auto another = std::make_shared<Response>();
    another->data() = "late duplicate";
    completed->Ready(another);
    assert(completed->GetResponse(0) == reply);
    assert(!completed->SetQueue(queue));

    std::weak_ptr<RequestFutureQueue> weak_queue;
    std::weak_ptr<RequestFuture> weak_future;
    {
        auto pending_queue = std::make_shared<RequestFutureQueue>();
        auto pending = std::make_shared<RequestFuture>(74);
        weak_queue = pending_queue;
        weak_future = pending;
        assert(pending->SetQueue(pending_queue));
    }
    assert(weak_queue.expired() && weak_future.expired());

    // Exercise completion versus timeout with two concurrent readers. All
    // readers must see exactly the same terminal result, including after Ready.
    for (unsigned attempt = 0; attempt < 64; ++attempt) {
        auto future = std::make_shared<RequestFuture>(attempt);
        ResponsePtr results[2];
        std::atomic<bool> start{false};
        std::thread waiters[2];
        for (unsigned index = 0; index < 2; ++index) {
            waiters[index] = std::thread([&, index] {
                while (!start.load()) std::this_thread::yield();
                results[index] = future->GetResponse(100);
            });
        }
        std::thread ready([&] {
            while (!start.load()) std::this_thread::yield();
            if (attempt % 2) std::this_thread::sleep_for(std::chrono::microseconds(200));
            future->Ready(reply);
        });
        start = true;
        for (auto& waiter : waiters) waiter.join();
        ready.join();
        assert(results[0] == results[1]);
        assert(future->GetResponse(0) == results[0]);
    }

    auto indefinite = std::make_shared<RequestFuture>(75);
    std::thread complete([&] { indefinite->Ready(reply); });
    assert(indefinite->GetResponse(0) == reply);
    complete.join();
}

int main() {
    future_lifecycle();
    usdk_lease_cache *cache = nullptr;
    assert(usdk_lease_cache_create(&cache) == 0);
    assert(usdk_lease_cache_set(cache, 97, text("sample"), 12345) == 0);
    int64_t value = 0;
    assert(usdk_lease_cache_id(cache, &value) == 0 && value == 97);
    assert(usdk_lease_cache_last_modified(cache, &value) == 0 && value == 12345);
    usdk_buffer name{};
    assert(usdk_lease_cache_name(cache, &name) == 0 && name.len == 6);
    assert(std::memcmp(name.data, "sample", 6) == 0);
    usdk_buffer_free(&name);
    assert(usdk_lease_cache_renew(cache, 12346) == 0);
    assert(usdk_lease_cache_last_modified(cache, &value) == 0 && value == 12346);
    assert(usdk_lease_cache_clear(cache) == 0);
    assert(usdk_lease_cache_id(cache, &value) == 0 && value == 0);
    usdk_lease_cache_destroy(cache);

    usdk_request_future *manual = nullptr;
    assert(usdk_future_create(40, &manual) == 0);
    assert(usdk_future_set_id(manual, 41) == 0);
    assert(usdk_future_id(manual, &value) == 0 && value == 41);
    usdk_future_queue *queue = nullptr;
    assert(usdk_future_queue_create(&queue) == 0);
    bool accepted = false;
    assert(usdk_future_set_queue(manual, queue, &accepted) == 0 && accepted);
    // SetQueue inserts the future; a repeated Put must report the duplicate.
    assert(usdk_future_queue_put(queue, 41, manual, &accepted) == 0 && !accepted);
    size_t count = 0;
    assert(usdk_future_queue_size(queue, &count) == 0 && count == 1);
    usdk_request_future *extra = nullptr;
    assert(usdk_future_create(43, &extra) == 0);
    assert(usdk_future_queue_put(queue, 43, extra, &accepted) == 0 && accepted);
    assert(usdk_future_queue_size(queue, &count) == 0 && count == 2);
    assert(usdk_future_queue_remove(queue, 43) == 0);
    usdk_future_destroy(extra);
    usdk_request_future *from_queue = nullptr;
    assert(usdk_future_queue_get(queue, 41, &from_queue) == 0 && from_queue);
    assert(usdk_future_id(from_queue, &value) == 0 && value == 41);
    assert(usdk_future_queue_remove(queue, 41) == 0);
    assert(usdk_future_queue_size(queue, &count) == 0 && count == 0);
    usdk_api_Response ready{};
    ready.header.identity.id = 41;
    ready.data = text("ready");
    assert(usdk_future_ready(manual, &ready) == 0);
    usdk_owned_message *owned = nullptr;
    assert(usdk_future_wait(from_queue, 1000, &owned) == 0);
    const auto *ready_response = static_cast<const usdk_api_Response *>(usdk_message_data(owned));
    assert(ready_response->data.len == 5 && std::memcmp(ready_response->data.data, "ready", 5) == 0);
    usdk_message_destroy(owned);
    usdk_future_destroy(from_queue);
    usdk_future_destroy(manual);
    usdk_future_queue_destroy(queue);

    // A deferred future can time out without DDS or hardware.
    assert(usdk_future_create(42, &manual) == 0);
    assert(usdk_future_wait(manual, 1000, &owned) == USDK_TIMEOUT && !owned);
    assert(usdk_future_wait(manual, -1, &owned) == USDK_INVALID_ARGUMENT);
    usdk_future_destroy(manual);

    assert(usdk_channel_init(222, "lo") == 0);
    EchoState state;
    usdk_server_stub *server = nullptr;
    usdk_client_stub *client = nullptr;
    assert(usdk_server_stub_create(text("zig_transport_test"), echo, &state, true, &server) == 0);
    assert(usdk_client_stub_create(text("zig_transport_test"), &client) == 0);
    usdk_api_Request request{};
    request.header.identity.id = 1001;
    request.header.identity.api_id = 4242;
    request.header.lease.id = 312;
    request.header.policy.priority = 5;
    const char payload[] = {'a', '\0', 'b'};
    const uint8_t bytes[] = {1, 0, 255};
    request.parameter = {payload, sizeof(payload)};
    request.binary = {bytes, sizeof(bytes)};
    usdk_request_future *future = nullptr;
    assert(usdk_client_stub_request(client, &request, 1000000, &future) == 0);
    assert(usdk_future_id(future, &value) == 0 && value == 1001);
    assert(usdk_future_wait(future, 2000000, &owned) == 0);
    const auto *response = static_cast<const usdk_api_Response *>(usdk_message_data(owned));
    assert(response->header.identity.id == 1001 && response->header.identity.api_id == 4242);
    assert(response->header.status.code == 57);
    assert(response->data.len == 3 && std::memcmp(response->data.data, payload, 3) == 0);
    assert(response->binary.len == 3 && response->binary.data[2] == 255);
    usdk_future_destroy(future);
    // The cloned response remains valid after destruction of the future.
    assert(response->data.data[2] == 'b');
    usdk_message_destroy(owned);
    request.header.identity.id = 1002;
    request.header.policy.noreply = 1;
    assert(usdk_client_stub_send(client, &request, 1000000) == 0);
    for (unsigned attempt = 0; attempt < 50 && state.calls.load() < 2; ++attempt)
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    assert(state.calls.load() == 2 && state.send_status.load() == 0);
    assert(usdk_server_stub_last_error(server) == 0);
    usdk_client_stub_destroy(client);
    usdk_server_stub_destroy(server);

    usdk_lease_server *lease = nullptr;
    assert(usdk_lease_server_create(text("zig_transport_lease"), 1000000, &lease) == 0);
    assert(usdk_lease_server_name(lease, &name) == 0);
    assert(name.len == std::strlen("zig_transport_lease"));
    assert(std::memcmp(name.data, "zig_transport_lease", name.len) == 0);
    usdk_buffer_free(&name);
    bool denied = true;
    assert(usdk_lease_server_denied(lease, 0, &denied) == 0 && !denied);
    assert(usdk_lease_server_start(lease, false) == 0);
    assert(usdk_lease_server_start(lease, false) == USDK_INVALID_ARGUMENT);
    usdk_lease_server_destroy(lease);
    assert(usdk_channel_release() == 0);
    std::cout << "Transport futures/queues, text+binary RPC loopback, noreply, and leases passed\n";
}
