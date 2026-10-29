#ifndef UNITREE_SDK2_ZIG_INTERNAL_HPP
#define UNITREE_SDK2_ZIG_INTERNAL_HPP

#include "usdk.h"
#include <unitree/robot/client/client.hpp>
#include <cmath>
#include <cstring>
#include <memory>
#include <limits>
#include <stdexcept>
#include <string>
#include <type_traits>
#include <vector>

struct usdk_client {
    std::unique_ptr<unitree::robot::Client> value;
};

namespace usdk {
void set_error(int32_t status, const char *message) noexcept;
int32_t fail(const char *message) noexcept;
void require_channel();

template <class F> int32_t guard(F &&function) noexcept {
    set_error(0, "");
    try {
        const int32_t status = function();
        if (status != 0) {
            // Preserve a detailed error produced by fail() in the same call.
            if (usdk_last_status() != status)
                set_error(status, status > 0 ? "Unitree SDK returned a non-zero status" : "Bridge operation failed");
        }
        return status;
    } catch (const std::bad_alloc &) {
        set_error(USDK_OUT_OF_MEMORY, "Out of memory");
        return USDK_OUT_OF_MEMORY;
    } catch (const std::invalid_argument &error) {
        set_error(USDK_INVALID_ARGUMENT, error.what());
        return USDK_INVALID_ARGUMENT;
    } catch (const std::exception &error) {
        set_error(USDK_EXCEPTION, error.what());
        return USDK_EXCEPTION;
    } catch (...) {
        set_error(USDK_EXCEPTION, "Unknown C++ exception");
        return USDK_EXCEPTION;
    }
}

inline std::string string(usdk_string view) {
    if (!view.data && view.len) throw std::invalid_argument("Null string with non-zero length");
    if (view.len > static_cast<size_t>(PTRDIFF_MAX)) throw std::invalid_argument("String length exceeds pointer range");
    return view.len ? std::string(view.data, view.len) : std::string();
}
inline std::vector<uint8_t> bytes(usdk_bytes view) {
    if (!view.data && view.len) throw std::invalid_argument("Null bytes with non-zero length");
    if (view.len > static_cast<size_t>(PTRDIFF_MAX)) throw std::invalid_argument("Byte length exceeds pointer range");
    return view.len ? std::vector<uint8_t>(view.data, view.data + view.len) : std::vector<uint8_t>();
}
inline std::string service_name(usdk_string view) {
    auto name = string(view);
    if (name.empty() || name.find('\0') != std::string::npos)
        throw std::invalid_argument("Service name must be nonempty and contain no NUL");
    return name;
}
int32_t copy_buffer(const void *data, size_t size, usdk_buffer *out);
inline unitree::robot::Client &client(usdk_client *handle) {
    if (!handle || !handle->value) throw std::invalid_argument("Null client");
    return *handle->value;
}
}
#endif
