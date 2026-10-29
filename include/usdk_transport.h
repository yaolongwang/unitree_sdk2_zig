#ifndef USDK_TRANSPORT_H
#define USDK_TRANSPORT_H
#include "usdk_messages.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct usdk_client_stub usdk_client_stub;
typedef struct usdk_server_stub usdk_server_stub;
typedef struct usdk_request_future usdk_request_future;
typedef struct usdk_future_queue usdk_future_queue;
typedef struct usdk_lease_server usdk_lease_server;
typedef struct usdk_lease_cache usdk_lease_cache;

/* Requests are copied for each send. The caller supplies unique request IDs.
 * send timeout is the DDS writer timeout, not the response timeout. */
int32_t usdk_client_stub_create(usdk_string service, usdk_client_stub **out);
int32_t usdk_client_stub_send(usdk_client_stub *client, const usdk_api_Request *request, int64_t timeout_us);
int32_t usdk_client_stub_request(usdk_client_stub *client, const usdk_api_Request *request, int64_t timeout_us, usdk_request_future **out);
void usdk_client_stub_destroy(usdk_client_stub *client);

/* A future handle owns a shared reference. Destroying it does not invalidate
 * other handles obtained from the queue. Response outputs are owned messages.
 * Set the ID before set_queue, wait or ready. A zero wait timeout is unbounded.
 * Completion or timeout is terminal: later ready calls preserve the first result.
 * set_queue associates and inserts only an unused future; repeated calls return
 * accepted=false. Association is weak, so destroying the queue releases entries.
 * Wait/ready may run concurrently; destroy requires all calls on that handle to finish. */
int32_t usdk_future_create(int64_t request_id, usdk_request_future **out);
int32_t usdk_future_set_id(usdk_request_future *future, int64_t request_id);
int32_t usdk_future_id(const usdk_request_future *future, int64_t *out);
int32_t usdk_future_wait(usdk_request_future *future, int64_t timeout_us, usdk_owned_message **out);
int32_t usdk_future_ready(usdk_request_future *future, const usdk_api_Response *response);
int32_t usdk_future_set_queue(usdk_request_future *future, usdk_future_queue *queue, bool *accepted);
void usdk_future_destroy(usdk_request_future *future);

int32_t usdk_future_queue_create(usdk_future_queue **out);
int32_t usdk_future_queue_put(usdk_future_queue *queue, int64_t request_id, const usdk_request_future *future, bool *inserted);
/* A missing entry succeeds with *out == NULL. Get follows upstream removal semantics. */
int32_t usdk_future_queue_get(usdk_future_queue *queue, int64_t request_id, usdk_request_future **out);
int32_t usdk_future_queue_remove(usdk_future_queue *queue, int64_t request_id);
int32_t usdk_future_queue_size(usdk_future_queue *queue, size_t *out);
void usdk_future_queue_destroy(usdk_future_queue *queue);

/* Borrowed Request and its nested pointers are valid only during the callback.
 * The callback may send arbitrary Response objects through the supplied stub.
 * Do not destroy the stub inside its own callback. */
typedef void (*usdk_stub_callback)(usdk_server_stub *server, const usdk_api_Request *request, void *user);
int32_t usdk_server_stub_create(usdk_string service, usdk_stub_callback callback, void *user, bool priority_queue, usdk_server_stub **out);
int32_t usdk_server_stub_send(usdk_server_stub *server, const usdk_api_Response *response, int64_t timeout_us);
int32_t usdk_server_stub_last_error(const usdk_server_stub *server);
void usdk_server_stub_destroy(usdk_server_stub *server);

/* service is the complete lease-service name, normally "<service>_lease". */
int32_t usdk_lease_server_create(usdk_string service, int64_t term_us, usdk_lease_server **out);
int32_t usdk_lease_server_start(usdk_lease_server *server, bool priority_queue);
int32_t usdk_lease_server_denied(usdk_lease_server *server, int64_t lease_id, bool *out);
int32_t usdk_lease_server_name(const usdk_lease_server *server, usdk_buffer *out);
void usdk_lease_server_destroy(usdk_lease_server *server);

/* LeaseCache is a local value: no channel initialization is needed. It is not
 * internally synchronized. last_modified_us == 0 requests upstream's clock. */
int32_t usdk_lease_cache_create(usdk_lease_cache **out);
int32_t usdk_lease_cache_set(usdk_lease_cache *cache, int64_t id, usdk_string name, int64_t last_modified_us);
int32_t usdk_lease_cache_renew(usdk_lease_cache *cache, int64_t last_modified_us);
int32_t usdk_lease_cache_clear(usdk_lease_cache *cache);
int32_t usdk_lease_cache_id(const usdk_lease_cache *cache, int64_t *out);
int32_t usdk_lease_cache_last_modified(const usdk_lease_cache *cache, int64_t *out);
int32_t usdk_lease_cache_name(const usdk_lease_cache *cache, usdk_buffer *out);
void usdk_lease_cache_destroy(usdk_lease_cache *cache);

#ifdef __cplusplus
}
#endif
#endif
