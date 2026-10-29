#include "usdk_messages.h"
#include <atomic>
#include <cassert>
#include <chrono>
#include <cstring>
#include <iostream>
#include <stdexcept>
#include <thread>

struct Receiver {
    std::atomic<usdk_owned_message *> copy{nullptr};
    std::atomic<bool> throw_on_receive{false};
};

static void receive(const void *message, void *user) {
    auto& receiver = *static_cast<Receiver *>(user);
    if (receiver.throw_on_receive.load()) throw std::runtime_error("DDS callback failed");
    usdk_owned_message *copy = nullptr;
    if (usdk_message_clone(USDK_MESSAGE_ROS2_POINTCLOUD2, message, &copy) != 0) return;
    usdk_owned_message *empty = nullptr;
    if (!receiver.copy.compare_exchange_strong(empty, copy)) usdk_message_destroy(copy);
}

int main() {
    assert(usdk_channel_init(221, "lo") == 0);
    Receiver receiver;
    usdk_subscriber *subscriber = nullptr;
    usdk_publisher *publisher = nullptr;
    assert(usdk_subscriber_create(USDK_MESSAGE_ROS2_POINTCLOUD2, "rt/zig_ffi_loopback", receive, &receiver, 4, &subscriber) == 0);
    assert(usdk_publisher_create(USDK_MESSAGE_ROS2_POINTCLOUD2, "rt/zig_ffi_loopback", &publisher) == 0);
    int64_t last_time = -1;
    assert(usdk_subscriber_last_data_time(subscriber, &last_time) == 0 && last_time == 0);
    usdk_string topic{};
    assert(usdk_publisher_topic(publisher, &topic) == 0);
    assert(topic.len == std::strlen("rt/zig_ffi_loopback"));
    assert(usdk_subscriber_topic(subscriber, &topic) == 0);

    usdk_ros2_PointField field{};
    field.name = {"x", 1};
    field.count = 1;
    field.datatype = USDK_POINT_FIELD_FLOAT32;
    const uint8_t bytes[] = {1, 2, 3, 255};
    usdk_ros2_PointCloud2 cloud{};
    cloud.header.frame_id = {"zig_loopback", 12};
    cloud.header.stamp.sec = -23;
    cloud.fields = {&field, 1};
    cloud.data = {bytes, sizeof(bytes)};
    cloud.width = 1;
    cloud.height = 1;
    cloud.point_step = 4;
    cloud.row_step = 4;
    cloud.is_dense = 1;
    for (unsigned i = 0; i < 20 && !receiver.copy.load(); ++i) {
        assert(usdk_publisher_write(publisher, &cloud, 100000) == 0);
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
    assert(receiver.copy.load());
    const auto *copy = static_cast<const usdk_ros2_PointCloud2 *>(usdk_message_data(receiver.copy.load()));
    assert(copy->header.stamp.sec == -23);
    assert(copy->header.frame_id.len == 12 && std::memcmp(copy->header.frame_id.data, "zig_loopback", 12) == 0);
    assert(copy->fields.len == 1 && copy->fields.data[0].datatype == USDK_POINT_FIELD_FLOAT32);
    assert(copy->data.len == 4 && copy->data.data[3] == 255);
    assert(usdk_subscriber_last_data_time(subscriber, &last_time) == 0);
    assert(last_time > 0 && usdk_subscriber_last_error(subscriber) == 0);
    const int64_t first_time = last_time;
    // Callback errors stay within the native boundary, and querying them copies
    // the failure status into the caller's TLS rather than leaving stale success.
    receiver.throw_on_receive.store(true);
    assert(usdk_publisher_write(publisher, &cloud, 100000) == 0);
    for (unsigned i = 0; i < 100 && usdk_subscriber_last_error(subscriber) == 0; ++i) {
        assert(usdk_subscriber_last_data_time(subscriber, &last_time) == 0);
        assert(last_time >= first_time);
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    assert(usdk_subscriber_last_error(subscriber) == USDK_EXCEPTION);
    assert(usdk_last_status() == USDK_EXCEPTION);
    assert(usdk_subscriber_last_data_time(subscriber, &last_time) == 0 && last_time >= first_time);
    usdk_subscriber_destroy(subscriber);
    usdk_publisher_destroy(publisher);
    usdk_message_destroy(receiver.copy.load());
    assert(usdk_channel_release() == 0);
    std::cout << "DDS loopback: nested ownership, callback exceptions, and atomic reception time passed\n";
}
