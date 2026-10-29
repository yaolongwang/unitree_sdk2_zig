#include "unitree_sdk2_zig.h"
#include <unitree/common/json/jsonize.hpp>
#include <atomic>
#include <cassert>
#include <chrono>
#include <cmath>
#include <cstring>
#include <iostream>
#include <string>
#include <thread>

static usdk_string text(const char *value) { return {value, std::strlen(value)}; }
static usdk_bytes bytes(const char *value) { return {reinterpret_cast<const uint8_t *>(value), std::strlen(value)}; }
static void ok(int32_t status) {
    if (status) {
        std::cerr << "status=" << status << ": " << usdk_last_error() << '\n';
        std::abort();
    }
}

struct Echo {
    std::atomic<unsigned> calls{0};
};
static int32_t echo(void *user, int32_t api, usdk_bytes request, usdk_reply *reply) {
    auto &state = *static_cast<Echo *>(user);
    state.calls.fetch_add(1);
    if (api == 1004) return 4321;
    if (api == 1005) std::this_thread::sleep_for(std::chrono::milliseconds(80));
    return usdk_reply_set(reply, request);
}

static int32_t sport(void *, int32_t api, usdk_bytes request, usdk_reply *reply) {
    if (api == 7006) return usdk_reply_set(reply, bytes("{\"data\":[0.25,0.5,0.75]}"));
    if (api == 7008) return usdk_reply_set(reply, bytes("{\"ids\":[1,4],\"names\":[\"Damp\",\"Stand\"]}"));
    if (api == 1008) {
        const std::string parameter(reinterpret_cast<const char *>(request.data), request.len);
        assert(parameter.find("0.25") != std::string::npos);
    }
    return usdk_reply_set(reply, bytes("{}"));
}

static int32_t audio_stop(void *, int32_t api, usdk_bytes request, usdk_reply *reply) {
    assert(api == 1004);
    const std::string parameter(reinterpret_cast<const char *>(request.data), request.len);
    assert(parameter.find("app_name") != std::string::npos);
    if (parameter.find("reject") != std::string::npos) return 4321;
    return usdk_reply_set(reply, bytes("{}"));
}

struct ArmActions {
    const std::string special_name = std::string("teach \"turn\"\\path\nnext") + '\0' + "tail";
    std::atomic<unsigned> names{0};
    std::atomic<unsigned> ids{0};
};

static int32_t arm_action(void *user, int32_t api, usdk_bytes request, usdk_reply *reply) {
    auto& state = *static_cast<ArmActions *>(user);
    const std::string parameter(reinterpret_cast<const char *>(request.data), request.len);
    unitree::common::JsonMap json;
    unitree::common::FromJsonString(parameter, json);
    assert(json.size() == 1);
    if (api == 7108) {
        std::string name;
        unitree::common::FromJson(json.at("action_name"), name);
        state.names.fetch_add(1);
        if (name == state.special_name) return 4321;
        assert(name == "ordinary name");
    } else {
        assert(api == 7106);
        int32_t id = 0;
        unitree::common::FromJson(json.at("action_id"), id);
        assert(id == 17);
        state.ids.fetch_add(1);
    }
    return usdk_reply_set(reply, bytes("{}"));
}

int main() {
    assert(usdk_abi_version() == 1);
    assert(usdk_client_set_timeout(nullptr, 1.0f) == USDK_INVALID_ARGUMENT);
    assert(std::strstr(usdk_last_error(), "Null client"));
    assert(usdk_last_status() == USDK_INVALID_ARGUMENT);
    usdk_client *uninitialized = nullptr;
    assert(usdk_go2_sport_create(false, &uninitialized) == USDK_INVALID_ARGUMENT);
    assert(!uninitialized);

    const uint8_t binary[] = {0, 1, 2, 0, 255};
    usdk_buffer copied{};
    ok(usdk_buffer_copy({binary, sizeof(binary)}, &copied));
    assert(copied.len == sizeof(binary) && std::memcmp(copied.data, binary, sizeof(binary)) == 0);
    usdk_buffer_free(&copied);
    assert(!copied.data && copied.len == 0);
    assert(usdk_buffer_copy({nullptr, 3}, &copied) == USDK_INVALID_ARGUMENT);

    // Loopback-only interface and a non-default DDS domain keep these requests
    // entirely within this test process; no robot or external network is used.
    ok(usdk_channel_init(227, "lo"));
    assert(usdk_channel_init(227, "lo") == USDK_INVALID_ARGUMENT);

    Echo state;
    usdk_server *server = nullptr;
    ok(usdk_server_create(text("zig_ffi_echo"), text("1.2.3"), &server));
    for (int id : {1001, 1003, 1004, 1005}) ok(usdk_server_register(server, id, false, false, echo, &state));
    ok(usdk_server_register(server, 1002, true, false, echo, &state));
    assert(usdk_server_register(server, 1001, false, false, echo, &state) == USDK_INVALID_ARGUMENT);
    ok(usdk_server_start(server, true));
    assert(usdk_server_register(server, 1006, false, false, echo, &state) == USDK_INVALID_ARGUMENT);

    usdk_client *client = nullptr;
    ok(usdk_client_create(text("zig_ffi_echo"), text("1.2.3"), false, &client));
    ok(usdk_client_set_timeout(client, 2.0f));
    assert(usdk_client_set_timeout(client, NAN) == USDK_INVALID_ARGUMENT);
    assert(usdk_client_set_timeout(client, 0.0000001f) == USDK_INVALID_ARGUMENT);
    // This float is below INT64_MAX / 1e6 in double arithmetic, but the SDK's
    // actual float multiplication rounds up to 2^63 before integer conversion.
    assert(usdk_client_set_timeout(client, 9223372013568.0f) == USDK_INVALID_ARGUMENT);
    for (int id : {1001, 1002, 1003, 1004, 1005}) ok(usdk_client_register_api(client, id, 0));
    usdk_buffer response{};
    ok(usdk_client_call(client, 1001, text("hello Zig"), &response));
    assert(response.len == 9 && std::memcmp(response.data, "hello Zig", 9) == 0);
    usdk_buffer_free(&response);
    ok(usdk_client_call_binary(client, 1002, {binary, sizeof(binary)}, &response));
    assert(response.len == sizeof(binary) && std::memcmp(response.data, binary, sizeof(binary)) == 0);
    usdk_buffer_free(&response);
    ok(usdk_client_api_version(client, &response));
    assert(std::string(reinterpret_cast<char *>(response.data), response.len) == "1.2.3");
    usdk_buffer_free(&response);
    ok(usdk_client_server_api_version(client, &response));
    assert(std::string(reinterpret_cast<char *>(response.data), response.len) == "1.2.3");
    usdk_buffer_free(&response);
    int64_t lease_id = -1;
    ok(usdk_client_lease_id(client, &lease_id));
    assert(lease_id == 0);
    assert(usdk_client_call(client, 1999, text("{}"), &response) == 3103);
    assert(usdk_client_call(client, 1004, text("{}"), &response) == 4321);
    assert(usdk_last_status() == 4321 && response.len == 0);
    ok(usdk_client_send(client, 1003, text("no reply")));
    ok(usdk_client_set_timeout_us(client, 10000));
    assert(usdk_client_call(client, 1005, text("timeout"), &response) == 3104);
    std::this_thread::sleep_for(std::chrono::milliseconds(100));
    assert(state.calls.load() >= 5);
    usdk_client_destroy(client);
    usdk_server_destroy(server);

    // Typed clients are exercised against an in-process server using the real
    // upstream serializers. This validates output ownership across RPC calls.
    usdk_server *sport_server = nullptr;
    ok(usdk_server_create(text("sport"), text("1.0.0.0"), &sport_server));
    for (int id : {1008, 7006, 7008}) ok(usdk_server_register(sport_server, id, false, false, sport, nullptr));
    ok(usdk_server_start(sport_server, false));

    usdk_client *go2 = nullptr;
    ok(usdk_go2_sport_create(false, &go2));
    ok(usdk_client_set_timeout(go2, 2.0f));
    ok(usdk_go2_sport_move(go2, 0.25f, 0.0f, 0.0f));
    assert(usdk_go2_sport_move(go2, NAN, 0.0f, 0.0f) == USDK_INVALID_ARGUMENT);
    assert(usdk_go2_sport_move(go2, 0.0f, INFINITY, 0.0f) == USDK_INVALID_ARGUMENT);
    // Cross-client handles must produce a normal error, not undefined behavior.
    assert(usdk_g1_loco_damp(go2) == USDK_INVALID_ARGUMENT);
    usdk_client_destroy(go2);

    usdk_client *g1 = nullptr;
    ok(usdk_g1_loco_create(&g1));
    ok(usdk_client_set_timeout(g1, 2.0f));
    usdk_client_floats phase{};
    usdk_client_output *phase_owner = nullptr;
    ok(usdk_g1_loco_get_phase(g1, &phase, &phase_owner));
    assert(phase.len == 3 && phase.data[0] == 0.25f && phase.data[2] == 0.75f);
    usdk_client_destroy(g1);
    assert(phase.data[1] == 0.5f); // Result owns its storage independently.
    usdk_client_output_destroy(phase_owner);

    usdk_client *h2 = nullptr;
    ok(usdk_h2_loco_create(&h2));
    ok(usdk_client_set_timeout(h2, 2.0f));
    usdk_client_ints ids{};
    usdk_client_strings names{};
    usdk_client_output *names_owner = nullptr;
    ok(usdk_h2_loco_get_available_fsm_ids(h2, &ids, &names, &names_owner));
    assert(ids.len == 2 && names.len == 2 && ids.data[1] == 4);
    assert(names.data[1].len == 5 && std::memcmp(names.data[1].data, "Stand", 5) == 0);
    usdk_client_output_destroy(names_owner);
    const float nonfinite[] = {0.0f, NAN};
    assert(usdk_h2_loco_set_punch_api(h2, {nonfinite, 2}) == USDK_INVALID_ARGUMENT);
    usdk_client_destroy(h2);

    usdk_client *b2 = nullptr;
    ok(usdk_b2_sport_create(false, &b2));
    usdk_client_b2_path_point path[30]{};
    path[29].yaw = INFINITY;
    assert(usdk_b2_sport_trajectory_follow(b2, {path, 30}) == USDK_INVALID_ARGUMENT);
    usdk_client_destroy(b2);
    usdk_server_destroy(sport_server);

    // The pinned SDK ignores PlayStop's Call status. All generated audio
    // clients must propagate actual remote failures while retaining the wire API.
    usdk_server *audio_server = nullptr;
    ok(usdk_server_create(text("voice"), text("1.0.0.0"), &audio_server));
    ok(usdk_server_register(audio_server, 1004, false, false, audio_stop, nullptr));
    ok(usdk_server_start(audio_server, false));
    struct AudioApi {
        int32_t (*create)(usdk_client **);
        int32_t (*stop)(usdk_client *, usdk_string);
    };
    const AudioApi audio_apis[] = {
        {usdk_a2_audio_create, usdk_a2_audio_play_stop},
        {usdk_as2_audio_create, usdk_as2_audio_play_stop},
        {usdk_g1_audio_create, usdk_g1_audio_play_stop},
        {usdk_r1_audio_create, usdk_r1_audio_play_stop},
    };
    for (const auto& api : audio_apis) {
        usdk_client *audio = nullptr;
        ok(api.create(&audio));
        ok(usdk_client_set_timeout(audio, 2.0f));
        assert(api.stop(audio, text("reject")) == 4321);
        assert(usdk_last_status() == 4321);
        ok(api.stop(audio, text("accept")));
        usdk_client_destroy(audio);
    }
    usdk_server_destroy(audio_server);

    // Parse the actual wire JSON, including characters unsafe for string
    // concatenation and an embedded NUL. Numeric presets keep their own route.
    ArmActions actions;
    usdk_server *arm_server = nullptr;
    usdk_client *arm_client = nullptr;
    ok(usdk_server_create(text("arm"), text("1.0.0.14"), &arm_server));
    ok(usdk_server_register(arm_server, 7108, false, false, arm_action, &actions));
    ok(usdk_server_register(arm_server, 7106, false, false, arm_action, &actions));
    ok(usdk_server_start(arm_server, false));
    ok(usdk_g1_arm_create(&arm_client));
    ok(usdk_client_set_timeout(arm_client, 2.0f));
    ok(usdk_g1_arm_execute_action_by_name(arm_client, text("ordinary name")));
    assert(usdk_g1_arm_execute_action_by_name(arm_client,
        {actions.special_name.data(), actions.special_name.size()}) == 4321);
    assert(usdk_last_status() == 4321);
    ok(usdk_g1_arm_execute_action(arm_client, 17));
    assert(actions.names.load() == 2 && actions.ids.load() == 1);
    usdk_client_destroy(arm_client);
    usdk_server_destroy(arm_server);

    Echo draining;
    usdk_server *draining_server = nullptr;
    usdk_client *draining_client = nullptr;
    ok(usdk_server_create(text("zig_ffi_drain"), text("1"), &draining_server));
    ok(usdk_server_register(draining_server, 1005, false, false, echo, &draining));
    ok(usdk_server_start(draining_server, false));
    ok(usdk_client_create(text("zig_ffi_drain"), text("1"), false, &draining_client));
    ok(usdk_client_register_api(draining_client, 1005, 0));
    std::thread request_thread([&] {
        usdk_buffer result{};
        ok(usdk_client_call(draining_client, 1005, text("drain before destroy"), &result));
        assert(result.len == 20);
        usdk_buffer_free(&result);
    });
    for (unsigned i = 0; i < 200 && !draining.calls.load(); ++i)
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    assert(draining.calls.load() == 1);
    usdk_server_destroy(draining_server);
    request_thread.join();
    usdk_client_destroy(draining_client);

    usdk_server *leased_server = nullptr;
    usdk_client *leased_client = nullptr;
    ok(usdk_server_create(text("zig_ffi_leased"), text("1"), &leased_server));
    ok(usdk_server_register(leased_server, 1001, false, true, echo, &state));
    ok(usdk_server_start_lease(leased_server, 1000000));
    ok(usdk_server_start(leased_server, false));
    ok(usdk_client_create(text("zig_ffi_leased"), text("1"), true, &leased_client));
    ok(usdk_client_register_api(leased_client, 1001, 0));
    lease_id = 0;
    for (unsigned i = 0; i < 400 && !lease_id; ++i) {
        ok(usdk_client_lease_id(leased_client, &lease_id));
        if (!lease_id) std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    assert(lease_id != 0);
    ok(usdk_client_call(leased_client, 1001, text("leased echo"), &response));
    assert(response.len == 11);
    usdk_buffer_free(&response);
    usdk_client_destroy(leased_client);
    usdk_server_destroy(leased_server);

    // A destroyed lease client must have joined its worker. Keep the process
    // alive so a background cancellation failure cannot be hidden by exit().
    std::this_thread::sleep_for(std::chrono::milliseconds(100));

    ok(usdk_channel_release());
    std::cout << "RPC loopback: text, binary, no-reply, status, timeout, typed outputs and ownership passed\n";
}
