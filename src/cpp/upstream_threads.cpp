// ABI-compatible replacements for the pinned SDK's thread.cpp.o and
// recurrent_thread.cpp.o. Build against the real declarations; the public
// classes retain their exact upstream layout.
#include <unitree/common/os.hpp>
#include <unitree/common/thread/recurrent_thread.hpp>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cxxabi.h>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <system_error>
#include <thread>
#include <unordered_map>

namespace {
using unitree::common::Thread;

struct ThreadControl {
    std::mutex mutex;
    std::condition_variable changed;
    std::atomic<bool> stopped{false};
    bool started = false;
};

struct ThreadRegistry {
    std::mutex mutex;
    std::unordered_map<const Thread *, std::shared_ptr<ThreadControl>> entries;
};

ThreadRegistry& registry() {
    // SDK singleton destructors can release threads during static teardown.
    // Keep the registry itself alive until process exit; every thread entry is
    // still erased when its owning Thread is destroyed.
    static ThreadRegistry *instance = new ThreadRegistry;
    return *instance;
}

thread_local std::shared_ptr<ThreadControl> current_sdk_thread;

std::shared_ptr<ThreadControl> find_control(const Thread *thread) {
    auto& records = registry();
    std::lock_guard<std::mutex> lock(records.mutex);
    const auto found = records.entries.find(thread);
    return found == records.entries.end() ? nullptr : found->second;
}

void remove_control(const Thread *thread) {
    auto& records = registry();
    std::lock_guard<std::mutex> lock(records.mutex);
    records.entries.erase(thread);
}

void request_stop(const std::shared_ptr<ThreadControl>& control) {
    if (!control) return;
    {
        std::lock_guard<std::mutex> lock(control->mutex);
        control->stopped.store(true, std::memory_order_release);
    }
    control->changed.notify_all();
}

void sleep_interruptible(const std::shared_ptr<ThreadControl>& control, uint64_t microseconds) {
    // Bounded chunks also avoid overflow in chrono's signed representation for
    // unusually large upstream uint64_t intervals.
    while (microseconds != 0) {
        const uint64_t chunk = std::min<uint64_t>(microseconds, 1000000);
        const auto duration = std::chrono::microseconds(chunk);
        if (control) {
            std::unique_lock<std::mutex> lock(control->mutex);
            if (control->changed.wait_for(lock, duration, [&] {
                    return control->stopped.load(std::memory_order_acquire);
                })) return;
        } else {
            std::this_thread::sleep_for(duration);
        }
        microseconds -= chunk;
    }
}

void join_thread(pthread_t& thread) noexcept {
    if (thread == 0) return;
    // Wrap and the recurrent loop keep local copies of everything needed after
    // invoking user code, including the future and the callback. Self-destruction
    // therefore must detach rather than attempt an impossible self-join.
    const int result = pthread_equal(thread, pthread_self())
        ? pthread_detach(thread) : pthread_join(thread, nullptr);
    if (result != 0) std::terminate();
    thread = 0;
}

int32_t run_recurrent(const std::shared_ptr<ThreadControl>& control,
                      const std::function<void()>& callback, uint64_t interval) {
    if (!control) throw std::logic_error("SDK thread control is unavailable");
    while (!control->stopped.load(std::memory_order_acquire)) {
        const auto started = std::chrono::steady_clock::now();
        try {
            callback();
        } catch (const __cxxabiv1::__forced_unwind&) {
            throw;
        } catch (const std::exception& error) {
            // Match the upstream recurrent contract: a failed tick does not
            // terminate lease renewal or other later callbacks.
            std::fprintf(stderr, "Execute Func error: %s\n", error.what());
        } catch (...) {
            std::fprintf(stderr, "Execute Func error: unknown exception\n");
        }
        if (interval == 0) {
            std::this_thread::yield();
        } else {
            const auto elapsed = std::chrono::duration_cast<std::chrono::microseconds>(
                std::chrono::steady_clock::now() - started).count();
            if (elapsed >= 0 && static_cast<uint64_t>(elapsed) < interval)
                sleep_interruptible(control, interval - static_cast<uint64_t>(elapsed));
        }
    }
    return 0;
}

struct ThreadStart {
    Thread *thread;
    std::shared_ptr<ThreadControl> control;
};

void *thread_entry(void *argument) {
    // SDK RPC paths contain catch-all handlers that are not cancellation-safe.
    // Shut down through their normal interruption paths, never pthread_cancel.
    pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, nullptr);
    std::unique_ptr<ThreadStart> start(static_cast<ThreadStart *>(argument));
    current_sdk_thread = start->control;
    {
        std::unique_lock<std::mutex> lock(start->control->mutex);
        start->control->changed.wait(lock, [&] { return start->control->started; });
    }
    Thread *thread = start->thread;
    start.reset();
    thread->Wrap();
    current_sdk_thread.reset();
    return nullptr;
}
} // namespace

namespace usdk {
// Internal cooperation hook used by upstream_lease.cpp. No SDK layout or public
// C ABI changes are needed to interrupt a lease callback's renewal delay.
void sleep_current_sdk_thread(uint64_t microseconds) {
    sleep_interruptible(current_sdk_thread, microseconds);
}
} // namespace usdk

namespace unitree {
namespace common {

Thread::~Thread() {
    request_stop(find_control(this));
    join_thread(mThreadId);
    remove_control(this);
}

uint64_t Thread::GetThreadId() const {
    return static_cast<uint64_t>(mThreadId);
}

void Thread::SetCpu() {
    if (mCpuId != UT_CPU_ID_NONE)
        OsHelper::Instance()->CpuSet(GetThreadId(), static_cast<size_t>(mCpuId));
}

void Thread::SetName() {
    if (!mName.empty()) OsHelper::Instance()->SetThreadName(GetThreadId(), mName);
}

void Thread::SetPriority(int32_t priority) {
    OsHelper::Instance()->SetScheduler(GetThreadId(),
        priority > 0 ? SCHED_FIFO : SCHED_OTHER, priority > 0 ? priority : 0);
}

void Thread::Wrap() {
    // A callback may release its owning handle. Keep future publication and
    // callable destruction independent of the object's lifetime after invocation.
    const auto future = mFuturePtr;
    try {
        const auto function = mFunc;
        SetCpu();
        SetName();
        future->Ready(function());
    } catch (const __cxxabiv1::__forced_unwind&) {
        // Cancellation is disabled, but an explicit pthread_exit still uses
        // forced unwinding on GNU systems. It must never be swallowed.
        future->Fault(Any("SDK thread exited before completion"));
        throw;
    } catch (const std::exception& error) {
        future->Fault(Any(std::string(error.what())));
    } catch (...) {
        future->Fault(Any("unknown SDK thread exception"));
    }
}

void Thread::CreateThreadNative() {
    if (mThreadId != 0) throw std::logic_error("SDK thread already started");
    const auto control = std::make_shared<ThreadControl>();
    auto start = std::make_unique<ThreadStart>(ThreadStart{this, control});
    {
        auto& records = registry();
        std::lock_guard<std::mutex> lock(records.mutex);
        if (!records.entries.emplace(this, control).second)
            throw std::logic_error("duplicate SDK thread control");
    }
    const int result = pthread_create(&mThreadId, nullptr, thread_entry, start.get());
    if (result != 0) {
        mThreadId = 0;
        remove_control(this);
        throw std::system_error(result, std::generic_category(), "pthread_create");
    }
    start.release();
    {
        std::lock_guard<std::mutex> lock(control->mutex);
        control->started = true;
    }
    control->changed.notify_all();
}

RecurrentThread::~RecurrentThread() {
    __atomic_store_n(&mQuit, true, __ATOMIC_RELEASE);
    request_stop(find_control(this));
    // The derived callback member must remain alive until execution finishes.
    // Joining only in Thread::~Thread would run after this member was destroyed.
    join_thread(mThreadId);
}

int32_t RecurrentThread::ThreadFunc() {
    const auto control = find_control(this);
    const auto callback = mFunc;
    const auto interval = mIntervalMicrosec;
    return run_recurrent(control, callback, interval);
}

int32_t RecurrentThread::ThreadFunc_0() {
    const auto control = find_control(this);
    const auto callback = mFunc;
    return run_recurrent(control, callback, 0);
}

bool RecurrentThread::Wait(int64_t microsec) {
    __atomic_store_n(&mQuit, true, __ATOMIC_RELEASE);
    request_stop(find_control(this));
    return FutureWrapper::Wait(microsec);
}

} // namespace common
} // namespace unitree
