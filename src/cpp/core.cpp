#include "internal.hpp"
#include <unitree/robot/channel/channel_factory.hpp>
#include <unitree/common/time/time_tool.hpp>
#include <atomic>
#include <cstdlib>
#include <limits>
#include <mutex>

// The pinned SDK declares GetLeaseId in client.hpp but omits its definition
// from both shipped archives. Define that declared member here, using its real
// members (no object-layout casts). Remove when upgrading to an SDK that defines it.
int64_t unitree::robot::Client::GetLeaseId() {
    return mEnableLease && mLeaseClientPtr ? mLeaseClientPtr->GetId() : 0;
}

namespace {
thread_local int32_t error_status = 0;
thread_local char error_message[2048] = {};
std::atomic<bool> channel_initialized{false};
std::mutex channel_mutex;

class GenericClient final : public unitree::robot::Client {
public:
    GenericClient(const std::string &name, const std::string &version, bool lease)
        : Client(name, lease) { SetApiVersion(version); }
    void Init() override {}
    using Client::Call;
    using Client::RegistApi;
};
GenericClient &generic(usdk_client *handle) {
    auto *value = dynamic_cast<GenericClient *>(&usdk::client(handle));
    if (!value) throw std::invalid_argument("Operation requires a generic RPC client");
    return *value;
}
}

namespace usdk {
void set_error(int32_t status, const char *message) noexcept {
    error_status = status;
    const size_t length = std::min(std::strlen(message), sizeof(error_message) - 1);
    std::memcpy(error_message, message, length);
    error_message[length] = 0;
}
int32_t fail(const char *message) noexcept {
    set_error(USDK_INVALID_ARGUMENT, message);
    return USDK_INVALID_ARGUMENT;
}
void require_channel() {
    if (!channel_initialized.load()) throw std::invalid_argument("Initialize ChannelFactory first");
}
int32_t copy_buffer(const void *data, size_t size, usdk_buffer *out) {
    if (!out || (!data && size)) return fail("Invalid buffer arguments");
    *out = {};
    if (size > static_cast<size_t>(PTRDIFF_MAX)) return fail("Buffer is too large");
    auto *memory = static_cast<uint8_t *>(std::malloc(size + 1));
    if (!memory) throw std::bad_alloc();
    if (size) std::memcpy(memory, data, size);
    memory[size] = 0;
    *out = {memory, size};
    return 0;
}
}

extern "C" {
uint32_t usdk_abi_version() { return 1; }
const char *usdk_last_error() { return error_message; }
int32_t usdk_last_status() { return error_status; }
int64_t usdk_monotonic_time_ns() { return unitree::common::GetCurrentMonotonicTimeNanosecond(); }
int32_t usdk_buffer_copy(usdk_bytes data, usdk_buffer *out) {
    return usdk::guard([&] { return usdk::copy_buffer(data.data, data.len, out); });
}
void usdk_buffer_free(usdk_buffer *buffer) {
    if (buffer) { std::free(buffer->data); *buffer = {}; }
}
int32_t usdk_channel_init(uint32_t domain, const char *network_interface) {
    return usdk::guard([&]() -> int32_t {
        if (domain > INT32_MAX) return usdk::fail("Domain exceeds int32 range");
        std::lock_guard<std::mutex> lock(channel_mutex);
        if (channel_initialized) return usdk::fail("ChannelFactory is already initialized");
        unitree::robot::ChannelFactory::Instance()->Init(static_cast<int32_t>(domain), network_interface ? network_interface : "");
        channel_initialized = true;
        return 0;
    });
}
int32_t usdk_channel_init_config_file(const char *filename) {
    return usdk::guard([&]() -> int32_t {
        if (!filename) return usdk::fail("Null configuration filename");
        std::lock_guard<std::mutex> lock(channel_mutex);
        if (channel_initialized) return usdk::fail("ChannelFactory is already initialized");
        unitree::robot::ChannelFactory::Instance()->Init(std::string(filename));
        channel_initialized = true;
        return 0;
    });
}
int32_t usdk_channel_init_config_json(usdk_string json) {
    return usdk::guard([&]() -> int32_t {
        auto value = unitree::common::FromJsonString(usdk::string(json));
        const auto &map = unitree::common::AnyCast<unitree::common::JsonMap>(value);
        std::lock_guard<std::mutex> lock(channel_mutex);
        if (channel_initialized) return usdk::fail("ChannelFactory is already initialized");
        unitree::robot::ChannelFactory::Instance()->Init(map);
        channel_initialized = true;
        return 0;
    });
}
int32_t usdk_channel_release() {
    return usdk::guard([]() -> int32_t {
        std::lock_guard<std::mutex> lock(channel_mutex);
        if (channel_initialized) unitree::robot::ChannelFactory::Instance()->Release();
        channel_initialized = false;
        return 0;
    });
}
int32_t usdk_client_create(usdk_string service, usdk_string version, bool lease, usdk_client **out) {
    return usdk::guard([&]() -> int32_t {
        if (!out) return usdk::fail("Null client output");
        *out = nullptr;
        const auto name = usdk::service_name(service);
        usdk::require_channel();
        auto handle = std::make_unique<usdk_client>();
        handle->value = std::make_unique<GenericClient>(name, usdk::string(version), lease);
        handle->value->Init();
        *out = handle.release();
        return 0;
    });
}
void usdk_client_destroy(usdk_client *client) { delete client; }
int32_t usdk_client_set_timeout(usdk_client *handle, float seconds) {
    return usdk::guard([&]() -> int32_t {
        // Match the SDK's float multiplication before checking the conversion.
        const float microseconds = seconds * 1e6f;
        if (!std::isfinite(microseconds) || microseconds < 1.0f || static_cast<double>(microseconds) >= static_cast<double>(INT64_MAX))
            return usdk::fail("Timeout must be finite and at least one microsecond");
        usdk::client(handle).SetTimeout(seconds); return 0;
    });
}
int32_t usdk_client_set_timeout_us(usdk_client *handle, int64_t microseconds) {
    return usdk::guard([&]() -> int32_t {
        if (microseconds <= 0) return usdk::fail("Timeout must be positive");
        usdk::client(handle).SetTimeout(microseconds); return 0;
    });
}
int32_t usdk_client_api_version(usdk_client *handle, usdk_buffer *out) {
    return usdk::guard([&] { const auto &v = usdk::client(handle).GetApiVersion(); return usdk::copy_buffer(v.data(), v.size(), out); });
}
int32_t usdk_client_server_api_version(usdk_client *handle, usdk_buffer *out) {
    return usdk::guard([&] { const auto v = usdk::client(handle).GetServerApiVersion(); return usdk::copy_buffer(v.data(), v.size(), out); });
}
int32_t usdk_client_wait_lease(usdk_client *handle) {
    return usdk::guard([&]() -> int32_t { usdk::client(handle).WaitLeaseApplied(); return 0; });
}
int32_t usdk_client_lease_id(usdk_client *handle, int64_t *out) {
    return usdk::guard([&]() -> int32_t { if (!out) return usdk::fail("Null lease output"); *out = usdk::client(handle).GetLeaseId(); return 0; });
}
int32_t usdk_client_register_api(usdk_client *handle, int32_t api, int32_t priority) {
    return usdk::guard([&]() -> int32_t { generic(handle).RegistApi(api, priority); return 0; });
}
int32_t usdk_client_call(usdk_client *handle, int32_t api, usdk_string parameter, usdk_buffer *out) {
    return usdk::guard([&]() -> int32_t {
        if (!out) return usdk::fail("Null response output");
        *out = {};
        std::string response;
        int32_t status = generic(handle).Call(api, usdk::string(parameter), response);
        if (status) return status;
        return usdk::copy_buffer(response.data(), response.size(), out);
    });
}
int32_t usdk_client_call_binary(usdk_client *handle, int32_t api, usdk_bytes parameter, usdk_buffer *out) {
    return usdk::guard([&]() -> int32_t {
        if (!out) return usdk::fail("Null response output");
        *out = {};
        std::vector<uint8_t> response;
        int32_t status = generic(handle).Call(api, usdk::bytes(parameter), response);
        if (status) return status;
        return usdk::copy_buffer(response.data(), response.size(), out);
    });
}
int32_t usdk_client_send(usdk_client *handle, int32_t api, usdk_string parameter) {
    return usdk::guard([&] { return generic(handle).Call(api, usdk::string(parameter)); });
}
int32_t usdk_client_send_binary(usdk_client *handle, int32_t api, usdk_bytes parameter) {
    return usdk::guard([&] { return generic(handle).Call(api, usdk::bytes(parameter)); });
}
int32_t usdk_client_send_mixed(usdk_client *handle, int32_t api, usdk_string parameter, usdk_bytes binary) {
    return usdk::guard([&] { return generic(handle).Call(api, usdk::string(parameter), usdk::bytes(binary)); });
}
}
