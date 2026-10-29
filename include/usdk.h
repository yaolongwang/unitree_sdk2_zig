#ifndef UNITREE_SDK2_ZIG_H
#define UNITREE_SDK2_ZIG_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Input views are borrowed for the duration of a call. A null pointer is valid
 * only with zero length. Handles must not be copied or destroyed concurrently
 * with calls using them. No C++ exception crosses this ABI. */
typedef struct { const uint8_t *data; size_t len; } usdk_bytes;
typedef struct { const char *data; size_t len; } usdk_string;
typedef struct { uint8_t *data; size_t len; } usdk_buffer;
typedef struct usdk_client usdk_client;
typedef struct usdk_server usdk_server;
typedef struct usdk_reply usdk_reply;
typedef struct usdk_lease_client usdk_lease_client;

enum usdk_status {
    USDK_OK = 0,
    USDK_INVALID_ARGUMENT = -1,
    USDK_EXCEPTION = -2,
    USDK_OUT_OF_MEMORY = -3,
    USDK_UNSUPPORTED = -4,
    USDK_TIMEOUT = -5
};

/* Positive values are the original Unitree SDK/robot response codes. Error
 * information is per calling thread and survives until the next guarded call. */
uint32_t usdk_abi_version(void);
const char *usdk_last_error(void);
int32_t usdk_last_status(void);
int32_t usdk_buffer_copy(usdk_bytes data, usdk_buffer *out);
void usdk_buffer_free(usdk_buffer *buffer);
int64_t usdk_monotonic_time_ns(void);

/* ChannelFactory is process-global. Initialize before creating any client,
 * publisher, subscriber, or server. Release only after destroying all of them. */
int32_t usdk_channel_init(uint32_t domain, const char *network_interface);
int32_t usdk_channel_init_config_file(const char *filename);
int32_t usdk_channel_init_config_json(usdk_string json);
int32_t usdk_channel_release(void);

int32_t usdk_client_create(usdk_string service, usdk_string version, bool enable_lease, usdk_client **out);
void usdk_client_destroy(usdk_client *client);
int32_t usdk_client_set_timeout(usdk_client *client, float seconds);
int32_t usdk_client_set_timeout_us(usdk_client *client, int64_t microseconds);
int32_t usdk_client_api_version(usdk_client *client, usdk_buffer *out);
int32_t usdk_client_server_api_version(usdk_client *client, usdk_buffer *out);
int32_t usdk_client_wait_lease(usdk_client *client);
int32_t usdk_client_lease_id(usdk_client *client, int64_t *out);
/* Register/call/send apply to the generic client made by usdk_client_create. */
int32_t usdk_client_register_api(usdk_client *client, int32_t api_id, int32_t priority);
int32_t usdk_client_call(usdk_client *client, int32_t api_id, usdk_string parameter, usdk_buffer *out);
int32_t usdk_client_call_binary(usdk_client *client, int32_t api_id, usdk_bytes parameter, usdk_buffer *out);
int32_t usdk_client_send(usdk_client *client, int32_t api_id, usdk_string parameter);
int32_t usdk_client_send_binary(usdk_client *client, int32_t api_id, usdk_bytes parameter);
int32_t usdk_client_send_mixed(usdk_client *client, int32_t api_id, usdk_string parameter, usdk_bytes binary);

/* Register handlers before start. The request and reply handle are valid only
 * during the callback. Set reply bytes before returning. Callback may run on
 * SDK threads; never destroy its server from inside the callback. */
typedef int32_t (*usdk_request_callback)(void *user, int32_t api_id, usdk_bytes request, usdk_reply *reply);
int32_t usdk_reply_set(usdk_reply *reply, usdk_bytes data);
int32_t usdk_server_create(usdk_string service, usdk_string version, usdk_server **out);
int32_t usdk_server_register(usdk_server *server, int32_t api_id, bool binary, bool check_lease, usdk_request_callback callback, void *user);
int32_t usdk_server_start(usdk_server *server, bool priority_queue);
int32_t usdk_server_start_lease(usdk_server *server, int64_t term_us);
int32_t usdk_server_current_api_id(usdk_server *server, int32_t *out);
int32_t usdk_server_name(usdk_server *server, usdk_buffer *out);
int32_t usdk_server_api_version(usdk_server *server, usdk_buffer *out);
void usdk_server_destroy(usdk_server *server);

/* Standalone lease client, for advanced users managing a service lease. */
int32_t usdk_lease_client_create(usdk_string service, usdk_lease_client **out);
int32_t usdk_lease_client_wait(usdk_lease_client *client);
int32_t usdk_lease_client_applied(usdk_lease_client *client, bool *out);
int32_t usdk_lease_client_id(usdk_lease_client *client, int64_t *out);
int32_t usdk_lease_client_set_timeout(usdk_lease_client *client, float seconds);
int32_t usdk_lease_client_set_timeout_us(usdk_lease_client *client, int64_t microseconds);
void usdk_lease_client_destroy(usdk_lease_client *client);

#ifdef __cplusplus
}
#endif
#endif
