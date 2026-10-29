// Offline FFI boundary and output-lifetime tests. No DDS factory is started.
#include "clients_internal.hpp"
#include <cassert>
#include <cstring>
#include <iostream>
#include <limits>
#include <map>
#include <stdexcept>
#include <string>
#include <vector>

static std::string string(usdk_string value) {
    return value.len ? std::string(value.data, value.len) : std::string();
}

struct CallbackState {
    unsigned calls = 0;
    std::string name;
    std::string status;
};

static void callback(void* context, usdk_string name, usdk_string status) {
    auto& state = *static_cast<CallbackState*>(context);
    ++state.calls;
    state.name = string(name);
    state.status = string(status);
}

static void throwing_callback(void*, usdk_string, usdk_string) {
    throw std::runtime_error("configuration callback failure");
}

static void invalid_arguments() {
    usdk_client empty;
    assert(usdk_go2_sport_move(nullptr, 0, 0, 0) == USDK_INVALID_ARGUMENT);
    assert(usdk_b2_sport_free_euler(&empty, true) == USDK_INVALID_ARGUMENT);
    assert(usdk_r1_loco_set_task_id(&empty, 2.5) == USDK_INVALID_ARGUMENT);
    assert(usdk_go2_sport_create(false, nullptr) == USDK_INVALID_ARGUMENT);
    usdk_client* uninitialized = reinterpret_cast<usdk_client*>(uintptr_t(1));
    assert(usdk_go2_sport_create(false, &uninitialized) == USDK_INVALID_ARGUMENT);
    assert(uninitialized == nullptr);

    uint8_t volume = 73;
    assert(usdk_g1_audio_get_volume(&empty, &volume) == USDK_INVALID_ARGUMENT);
    assert(volume == 0);
    assert(usdk_g1_audio_get_volume(&empty, nullptr) == USDK_INVALID_ARGUMENT);

    usdk_string result{"previous", 8};
    usdk_client_output* owner = reinterpret_cast<usdk_client_output*>(uintptr_t(1));
    assert(usdk_go2_config_get(nullptr, {"name", 4}, &result, &owner) == USDK_INVALID_ARGUMENT);
    assert(result.data == nullptr && result.len == 0 && owner == nullptr);

    const int32_t sentinel = 99;
    usdk_client_ints ids{&sentinel, 1};
    const usdk_string sentinel_name{"old", 3};
    usdk_client_strings names{&sentinel_name, 1};
    owner = reinterpret_cast<usdk_client_output*>(uintptr_t(1));
    assert(usdk_h2_loco_get_available_fsm_ids(&empty, &ids, &names, &owner) == USDK_INVALID_ARGUMENT);
    assert(ids.data == nullptr && ids.len == 0);
    assert(names.data == nullptr && names.len == 0);
    assert(owner == nullptr);

    // Validate length before pointer arithmetic or allocation. This is a valid
    // one-byte address coupled with an impossible range, not a bad pointer.
    const uint8_t byte = 1;
    const float scalar = 1;
    assert(usdk::guard([&]() -> int32_t {
        (void)usdk_clients::copy(&byte, std::numeric_limits<size_t>::max());
        return 0;
    }) == USDK_INVALID_ARGUMENT);
    assert(usdk::guard([&]() -> int32_t {
        (void)usdk_clients::copy(&scalar, static_cast<size_t>(PTRDIFF_MAX) / sizeof(float) + 1);
        return 0;
    }) == USDK_INVALID_ARGUMENT);
    assert(usdk::guard([]() -> int32_t {
        (void)usdk_clients::copy<float>(nullptr, 1);
        return 0;
    }) == USDK_INVALID_ARGUMENT);
    assert(usdk_clients::copy<float>(nullptr, 0).empty());
    assert(usdk::guard([]() -> int32_t {
        (void)usdk::string({nullptr, 1});
        return 0;
    }) == USDK_INVALID_ARGUMENT);
    assert(usdk::string({nullptr, 0}).empty());
    usdk_client_output_destroy(nullptr);
}

struct Service {
    std::string name;
    int32_t status;
    int32_t protect;
};
struct Meta {
    std::string name;
    std::string lastModified;
    int32_t size;
    int32_t epoch;
};

static void owned_outputs() {
    auto owner = std::make_unique<usdk_client_output>();
    std::string embedded("a\0b", 3);
    const auto text = usdk_clients::output(*owner, embedded);
    embedded.assign("changed");
    const auto binary = usdk_clients::output(*owner, std::vector<uint8_t>{0, 255, 0, 42});
    const auto floats = usdk_clients::output(*owner, std::vector<float>{-1, 0.5f, 3});
    const auto ints = usdk_clients::output(*owner, std::vector<int>{-1, 0, INT32_MAX});
    const auto strings = usdk_clients::output(*owner, std::vector<std::string>{"", "short", std::string(200, 'x')});
    const auto map = usdk_clients::output(*owner, std::map<std::string, std::string>{{"a", "one"}, {"b", std::string("n\0l", 3)}});
    const auto services = usdk_clients::services(*owner, std::vector<Service>{{"one", 1, 0}, {"two", 0, 1}});
    const auto meta = usdk_clients::meta(*owner, Meta{"config", "2026-10-29", -1, 7});

    // Reallocation of the owner's bookkeeping must not invalidate any earlier
    // view, including short strings residing inside their C++ objects.
    for (int index = 0; index < 1000; ++index)
        (void)usdk_clients::output(*owner, std::to_string(index));
    assert(text.len == 3 && std::memcmp(text.data, "a\0b", 3) == 0);
    assert(binary.len == 4 && binary.data[1] == 255 && binary.data[2] == 0);
    assert(floats.len == 3 && floats.data[1] == 0.5f);
    assert(ints.len == 3 && ints.data[2] == INT32_MAX);
    assert(strings.len == 3 && strings.data[0].len == 0);
    assert(string(strings.data[1]) == "short" && string(strings.data[2]) == std::string(200, 'x'));
    assert(map.len == 2 && string(map.data[0].key) == "a" && string(map.data[0].value) == "one");
    assert(map.data[1].value.len == 3 && std::memcmp(map.data[1].value.data, "n\0l", 3) == 0);
    assert(services.len == 2 && string(services.data[1].name) == "two" && services.data[1].protect == 1);
    assert(string(meta.name) == "config" && string(meta.last_modified) == "2026-10-29" && meta.size == -1 && meta.epoch == 7);
    usdk_client_output_destroy(owner.release());
}

static void callback_boundary() {
    CallbackState state;
    const std::string name("n\0ame", 5);
    const std::string status("ok\0", 3);
    usdk_clients::config_callback(callback, &state, name, status);
    assert(state.calls == 1 && state.name == name && state.status == status);
    assert(usdk_last_status() == 0);
    usdk_clients::config_callback(throwing_callback, nullptr, name, status);
    assert(usdk_last_status() == USDK_EXCEPTION);
    assert(std::strstr(usdk_last_error(), "configuration callback failure"));
    usdk_clients::config_callback(nullptr, nullptr, name, status);
    assert(usdk_last_status() == USDK_INVALID_ARGUMENT);
}

int main() {
    invalid_arguments();
    owned_outputs();
    callback_boundary();
    std::cout << "Clients: argument boundaries, output ownership and callback exceptions passed\n";
}
