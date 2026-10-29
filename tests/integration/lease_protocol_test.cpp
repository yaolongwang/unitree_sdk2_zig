#include "unitree_sdk2_zig.h"
#include <atomic>
#include <cassert>
#include <chrono>
#include <cstring>
#include <iostream>
#include <string>
#include <thread>

static usdk_string text(const char *value) { return {value, std::strlen(value)}; }

struct LeaseService {
    std::atomic<unsigned> applies{0};
    std::atomic<unsigned> renewals{0};
    std::atomic<bool> release_first_reply{false};
};

static void handle(usdk_server_stub *server, const usdk_api_Request *request, void *context) {
    auto &state = *static_cast<LeaseService *>(context);
    usdk_api_Response response{};
    response.header.identity = request->header.identity;
    const auto api = request->header.identity.api_id;
    if (api == 101) {
        assert(request->header.lease.id == 0);
        const std::string parameter(request->parameter.data, request->parameter.len);
        assert(parameter.find("\"name\"") != std::string::npos);
        assert(parameter.find('/') != std::string::npos);
        // First lease expires quickly; after reapplication use a long period
        // to verify that destroying the client interrupts its renewal sleep.
        const auto index = state.applies.fetch_add(1);
        if (index == 0) {
            while (!state.release_first_reply)
                std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
        response.data = text(index == 0 ? "{\"id\":567,\"term\":10000}" : "{\"id\":567,\"term\":100000000}");
    } else {
        assert(api == 102);
        assert(request->header.lease.id == 567);
        assert(request->parameter.len == 0);
        state.renewals.fetch_add(1);
        response.header.status.code = 3206; // Lease rejected: clear and reapply.
    }
    assert(usdk_server_stub_send(server, &response, 1000000) == 0);
}

int main() {
    using namespace std::chrono;
    assert(usdk_channel_init(224, "lo") == 0);
    LeaseService state;
    usdk_server_stub *server = nullptr;
    assert(usdk_server_stub_create(text("zig_lease_protocol"), handle, &state, false, &server) == 0);
    usdk_lease_client *client = nullptr;
    assert(usdk_lease_client_create(text("zig_lease_protocol"), &client) == 0);
    assert(usdk_lease_client_set_timeout(client, 9223372013568.0f) == USDK_INVALID_ARGUMENT);
    const auto deadline = steady_clock::now() + seconds(5);
    while (!state.applies && steady_clock::now() < deadline)
        std::this_thread::sleep_for(milliseconds(2));
    assert(state.applies == 1);
    // The background Call owns the timeout until its response arrives. Both
    // setters must work while running, without racing that inherited field.
    std::atomic<bool> configuring{false};
    std::atomic<bool> configured{false};
    std::thread configure([&] {
        configuring = true;
        assert(usdk_lease_client_set_timeout(client, 0.25f) == 0);
        assert(usdk_lease_client_set_timeout_us(client, 250000) == 0);
        configured = true;
    });
    while (!configuring) std::this_thread::yield();
    std::this_thread::sleep_for(milliseconds(20));
    assert(!configured);
    state.release_first_reply = true;
    configure.join();
    assert(configured);
    int64_t id = 0;
    while (steady_clock::now() < deadline) {
        assert(usdk_lease_client_id(client, &id) == 0);
        if (state.applies >= 2 && id == 567) break;
        std::this_thread::sleep_for(milliseconds(2));
    }
    assert(state.applies >= 2 && state.renewals >= 1 && id == 567);
    bool applied = false;
    assert(usdk_lease_client_applied(client, &applied) == 0 && applied);
    assert(usdk_lease_client_wait(client) == 0);
    const auto stopped_at = steady_clock::now();
    usdk_lease_client_destroy(client);
    assert(steady_clock::now() - stopped_at < seconds(2));
    const auto calls = state.applies.load() + state.renewals.load();
    std::this_thread::sleep_for(milliseconds(100));
    assert(state.applies.load() + state.renewals.load() == calls);
    usdk_server_stub_destroy(server);
    assert(usdk_channel_release() == 0);
    std::cout << "Lease protocol: synchronized timeouts, apply, header ID, renewal rejection, reapply, and interruptible shutdown passed\n";
}
