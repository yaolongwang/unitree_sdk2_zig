#include "internal.hpp"
#include <unitree/robot/server/server.hpp>
#include <unitree/robot/client/lease_client.hpp>
#include <condition_variable>
#include <mutex>
#include <set>

namespace usdk {
// Shared with the lease worker's Call lock in upstream_lease.cpp.
void set_lease_client_timeout(unitree::robot::LeaseClient& client, float seconds);
void set_lease_client_timeout(unitree::robot::LeaseClient& client, int64_t microseconds);
}

struct usdk_reply {
    std::vector<uint8_t> data;
};

namespace {
class GenericServer final : public unitree::robot::Server {
public:
    GenericServer(const std::string &name, const std::string &version) : Server(name) {
        SetApiVersion(version);
    }
    ~GenericServer() override {
        // An active ServerRequestHandler still needs mServerStubPtr to send its
        // response. Drain active handlers before resetting the dispatcher, then
        // join it while this class and Server's handler maps are still alive.
        {
            std::unique_lock<std::mutex> lock(dispatch_mutex_);
            closing_ = true;
            dispatch_idle_.wait(lock, [&] { return active_requests_ == 0; });
        }
        mServerStubPtr.reset();
    }
    void Init() override {}
    using Server::RegistHandler;
    using Server::RegistBinaryHandler;
protected:
    void ServerRequestHandler(const unitree::robot::RequestPtr &request) override {
        {
            std::lock_guard<std::mutex> lock(dispatch_mutex_);
            if (closing_) return;
            ++active_requests_;
        }
        (void)usdk::guard([&]() -> int32_t {
            Server::ServerRequestHandler(request);
            return 0;
        });
        {
            std::lock_guard<std::mutex> lock(dispatch_mutex_);
            --active_requests_;
            if (!active_requests_) dispatch_idle_.notify_all();
        }
    }
private:
    std::mutex dispatch_mutex_;
    std::condition_variable dispatch_idle_;
    size_t active_requests_ = 0;
    bool closing_ = false;
};
}

struct usdk_server {
    std::unique_ptr<GenericServer> value;
    std::set<int32_t> registered;
    bool started = false;
    bool lease_started = false;
};
struct usdk_lease_client {
    std::unique_ptr<unitree::robot::LeaseClient> value;
};

namespace {
GenericServer &server(usdk_server *handle) {
    if (!handle || !handle->value) throw std::invalid_argument("Null server");
    return *handle->value;
}
unitree::robot::LeaseClient &lease(usdk_lease_client *handle) {
    if (!handle || !handle->value) throw std::invalid_argument("Null lease client");
    return *handle->value;
}
}

extern "C" {
int32_t usdk_reply_set(usdk_reply *reply, usdk_bytes data) {
    return usdk::guard([&]() -> int32_t {
        if (!reply) return usdk::fail("Null reply");
        reply->data = usdk::bytes(data);
        return 0;
    });
}
int32_t usdk_server_create(usdk_string service, usdk_string version, usdk_server **out) {
    return usdk::guard([&]() -> int32_t {
        if (!out) return usdk::fail("Null server output");
        *out = nullptr;
        const auto name = usdk::service_name(service);
        usdk::require_channel();
        auto handle = std::make_unique<usdk_server>();
        handle->value = std::make_unique<GenericServer>(name, usdk::string(version));
        handle->value->Init();
        *out = handle.release();
        return 0;
    });
}
int32_t usdk_server_register(usdk_server *handle, int32_t api, bool binary, bool check_lease, usdk_request_callback callback, void *user) {
    return usdk::guard([&]() -> int32_t {
        auto &value = server(handle);
        if (!callback) return usdk::fail("Null request callback");
        if (api <= 100) return usdk::fail("API IDs 0..100 are reserved for SDK internals");
        if (handle->started) return usdk::fail("Register handlers before starting the server");
        if (handle->registered.count(api)) return usdk::fail("API ID already registered");
        if (binary) {
            value.RegistBinaryHandler(api, [=](const std::vector<uint8_t> &request, std::vector<uint8_t> &response) {
                return usdk::guard([&]() -> int32_t {
                    usdk_reply reply;
                    const int32_t status = callback(user, api, {request.data(), request.size()}, &reply);
                    response = std::move(reply.data);
                    return status;
                });
            }, check_lease);
        } else {
            value.RegistHandler(api, [=](const std::string &request, std::string &response) {
                return usdk::guard([&]() -> int32_t {
                    usdk_reply reply;
                    const int32_t status = callback(user, api, {reinterpret_cast<const uint8_t *>(request.data()), request.size()}, &reply);
                    if (reply.data.empty()) response.clear();
                    else response.assign(reinterpret_cast<const char *>(reply.data.data()), reply.data.size());
                    return status;
                });
            }, check_lease);
        }
        handle->registered.insert(api);
        return 0;
    });
}
int32_t usdk_server_start(usdk_server *handle, bool priority_queue) {
    return usdk::guard([&]() -> int32_t {
        auto &value = server(handle);
        if (handle->started) return usdk::fail("Server already started");
        value.Start(priority_queue);
        handle->started = true;
        return 0;
    });
}
int32_t usdk_server_start_lease(usdk_server *handle, int64_t term_us) {
    return usdk::guard([&]() -> int32_t {
        auto &value = server(handle);
        if (term_us <= 0) return usdk::fail("Lease term must be positive");
        if (handle->started || handle->lease_started) return usdk::fail("Start a lease once, before starting the server");
        value.StartLease(term_us);
        handle->lease_started = true;
        return 0;
    });
}
int32_t usdk_server_current_api_id(usdk_server *handle, int32_t *out) {
    return usdk::guard([&]() -> int32_t {
        if (!out) return usdk::fail("Null API ID output");
        *out = server(handle).GetCurrentApiId();
        return 0;
    });
}
void usdk_server_destroy(usdk_server *handle) { delete handle; }
int32_t usdk_server_name(usdk_server *handle, usdk_buffer *out) {
    return usdk::guard([&] {
        // The non-const Server overload is declared but absent in the pinned
        // archive. Its public ServerBase getter exposes the same service name.
        const auto &name = static_cast<const unitree::robot::ServerBase &>(server(handle)).GetName();
        return usdk::copy_buffer(name.data(), name.size(), out);
    });
}
int32_t usdk_server_api_version(usdk_server *handle, usdk_buffer *out) {
    return usdk::guard([&] {
        const auto &version = server(handle).GetApiVersion();
        return usdk::copy_buffer(version.data(), version.size(), out);
    });
}
int32_t usdk_lease_client_create(usdk_string service, usdk_lease_client **out) {
    return usdk::guard([&]() -> int32_t {
        if (!out) return usdk::fail("Null lease client output");
        *out = nullptr;
        const auto name = usdk::service_name(service);
        usdk::require_channel();
        auto handle = std::make_unique<usdk_lease_client>();
        handle->value = std::make_unique<unitree::robot::LeaseClient>(name);
        handle->value->Init();
        *out = handle.release();
        return 0;
    });
}
int32_t usdk_lease_client_wait(usdk_lease_client *handle) {
    return usdk::guard([&]() -> int32_t { lease(handle).WaitApplied(); return 0; });
}
int32_t usdk_lease_client_applied(usdk_lease_client *handle, bool *out) {
    return usdk::guard([&]() -> int32_t { if (!out) return usdk::fail("Null applied output"); *out = lease(handle).Applied(); return 0; });
}
int32_t usdk_lease_client_id(usdk_lease_client *handle, int64_t *out) {
    return usdk::guard([&]() -> int32_t { if (!out) return usdk::fail("Null lease ID output"); *out = lease(handle).GetId(); return 0; });
}
void usdk_lease_client_destroy(usdk_lease_client *handle) { delete handle; }
int32_t usdk_lease_client_set_timeout(usdk_lease_client *handle, float seconds) {
    return usdk::guard([&]() -> int32_t {
        const float microseconds = seconds * 1e6f;
        if (!std::isfinite(microseconds) || microseconds < 1.0f || static_cast<double>(microseconds) >= static_cast<double>(INT64_MAX))
            return usdk::fail("Timeout must be finite and at least one microsecond");
        usdk::set_lease_client_timeout(lease(handle), seconds);
        return 0;
    });
}
int32_t usdk_lease_client_set_timeout_us(usdk_lease_client *handle, int64_t microseconds) {
    return usdk::guard([&]() -> int32_t {
        if (microseconds <= 0) return usdk::fail("Timeout must be positive");
        usdk::set_lease_client_timeout(lease(handle), microseconds);
        return 0;
    });
}
}
