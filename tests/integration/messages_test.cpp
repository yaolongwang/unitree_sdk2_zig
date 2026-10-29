#include "usdk_messages.h"
#include <cassert>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <limits>

int main() {
    // Every exported type can pass through the native conversion layer.
    for (uint32_t id = 1; id <= USDK_MESSAGE_COUNT; ++id) {
        const char *name = nullptr;
        size_t size = 0;
        assert(usdk_message_info(id, &name, &size) == 0);
        assert(name && size);
        void *zero = std::calloc(1, size);
        assert(zero);
        assert(usdk_message_validate(id, zero) == 0);
        usdk_owned_message *owned = nullptr;
        assert(usdk_message_clone(id, zero, &owned) == 0);
        assert(owned && usdk_message_data(owned));
        assert(usdk_message_validate(id, usdk_message_data(owned)) == 0);
        usdk_message_destroy(owned);
        std::free(zero);
    }

    // Fixed arrays, nested messages, signed fields, and non-zero low-level values.
    usdk_go2_LowCmd command{};
    command.head[0] = 0xfe;
    command.head[1] = 0xef;
    command.level_flag = 0xff;
    command.motor_cmd[19].mode = 1;
    command.motor_cmd[19].q = -1.25f;
    command.motor_cmd[19].kp = 35.f;
    command.motor_cmd[19].reserve[2] = 0xabcdef12;
    command.crc = 0x543210fe;
    usdk_owned_message *owned = nullptr;
    assert(usdk_message_clone(USDK_MESSAGE_GO2_LOWCMD, &command, &owned) == 0);
    const auto *copy = static_cast<const usdk_go2_LowCmd *>(usdk_message_data(owned));
    assert(copy->head[0] == 0xfe && copy->head[1] == 0xef);
    assert(copy->motor_cmd[19].q == -1.25f && copy->motor_cmd[19].kp == 35.f);
    assert(copy->motor_cmd[19].reserve[2] == 0xabcdef12 && copy->crc == 0x543210fe);
    usdk_message_destroy(owned);

    // Deep copy a DDS request including embedded NUL, binary bytes, and int64 IDs.
    char parameter[] = {'a', '\0', 'b'};
    uint8_t binary[] = {0, 1, 255};
    usdk_api_Request request{};
    request.header.identity.id = INT64_C(0x123456789abcdef);
    request.header.identity.api_id = 1234;
    request.header.policy.priority = -8;
    request.parameter = {parameter, sizeof(parameter)};
    request.binary = {binary, sizeof(binary)};
    assert(usdk_message_clone(USDK_MESSAGE_API_REQUEST, &request, &owned) == 0);
    parameter[0] = 'z';
    binary[2] = 0;
    const auto *request_copy = static_cast<const usdk_api_Request *>(usdk_message_data(owned));
    assert(request_copy->header.identity.id == request.header.identity.id);
    assert(request_copy->header.policy.priority == -8);
    assert(request_copy->parameter.len == 3 && request_copy->parameter.data[0] == 'a' && request_copy->parameter.data[1] == '\0');
    assert(request_copy->binary.data[2] == 255);
    usdk_message_destroy(owned);

    // A sequence of nested messages with their own strings exercises recursive ownership.
    char field_name[] = "position";
    usdk_ros2_PointField field{};
    field.name = {field_name, 8};
    field.count = 3;
    field.datatype = 7;
    field.offset = 4;
    usdk_ros2_PointCloud2 cloud{};
    cloud.fields = {&field, 1};
    cloud.header.frame_id = {"lidar", 5};
    cloud.is_dense = 1;
    assert(usdk_message_clone(USDK_MESSAGE_ROS2_POINTCLOUD2, &cloud, &owned) == 0);
    std::memset(field_name, 'x', 8);
    const auto *cloud_copy = static_cast<const usdk_ros2_PointCloud2 *>(usdk_message_data(owned));
    assert(cloud_copy->fields.len == 1);
    assert(cloud_copy->fields.data[0].name.len == 8);
    assert(std::memcmp(cloud_copy->fields.data[0].name.data, "position", 8) == 0);
    assert(cloud_copy->fields.data[0].count == 3 && cloud_copy->is_dense == 1);
    usdk_message_destroy(owned);

    // Invalid pointers, lengths, boolean representation, and type IDs fail before DDS.
    request.binary = {nullptr, 1};
    assert(usdk_message_validate(USDK_MESSAGE_API_REQUEST, &request) == -1);
    cloud.is_dense = 2;
    assert(usdk_message_validate(USDK_MESSAGE_ROS2_POINTCLOUD2, &cloud) == -1);
    assert(usdk_message_clone(0, &command, &owned) == -1 && !owned);
    assert(usdk_message_validate(USDK_MESSAGE_GO2_LOWCMD, nullptr) == -1);
    request.parameter = {"x", std::numeric_limits<size_t>::max()};
    request.binary = {};
    assert(usdk_message_validate(USDK_MESSAGE_API_REQUEST, &request) == USDK_INVALID_ARGUMENT);
    cloud.is_dense = 1;
    cloud.fields = {&field, static_cast<size_t>(PTRDIFF_MAX) / sizeof(field) + 1};
    assert(usdk_message_validate(USDK_MESSAGE_ROS2_POINTCLOUD2, &cloud) == USDK_INVALID_ARGUMENT);
    const char *type_name = "old";
    size_t type_size = 42;
    assert(usdk_message_info(0, &type_name, &type_size) == USDK_INVALID_ARGUMENT);
    assert(type_name == nullptr && type_size == 0);
    type_size = 42;
    assert(usdk_message_info(USDK_MESSAGE_GO2_LOWCMD, nullptr, &type_size) == USDK_INVALID_ARGUMENT);
    assert(type_size == 0);
    usdk_string topic{"old", 3};
    assert(usdk_publisher_topic(nullptr, &topic) == USDK_INVALID_ARGUMENT);
    assert(topic.data == nullptr && topic.len == 0);
    topic = {"old", 3};
    assert(usdk_subscriber_topic(nullptr, &topic) == USDK_INVALID_ARGUMENT);
    assert(topic.data == nullptr && topic.len == 0);
    int64_t last_time = 42;
    assert(usdk_subscriber_last_data_time(nullptr, &last_time) == USDK_INVALID_ARGUMENT);
    assert(last_time == 0);
    assert(usdk_subscriber_last_error(nullptr) == USDK_INVALID_ARGUMENT);
    assert(usdk_last_status() == USDK_INVALID_ARGUMENT);
    usdk_publisher *publisher = nullptr;
    assert(usdk_publisher_create(USDK_MESSAGE_GO2_LOWCMD, "rt/test", &publisher) == -1 && !publisher);
    usdk_message_destroy(nullptr);
    usdk_publisher_destroy(nullptr);
    usdk_subscriber_destroy(nullptr);
    std::cout << "72 message conversions, deep ownership, and invalid-input checks passed\n";
}
