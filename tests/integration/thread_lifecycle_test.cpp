#include <unitree/common/thread/recurrent_thread.hpp>
#include <atomic>
#include <cassert>
#include <chrono>
#include <iostream>
#include <stdexcept>
#include <thread>

int main() {
    using namespace unitree::common;
    using namespace std::chrono_literals;
    for (int iteration = 0; iteration < 20; ++iteration) {
        std::atomic<bool> entered{false};
        std::atomic<bool> finished{false};
        auto worker = CreateThread([&] {
            entered = true;
            std::this_thread::sleep_for(5ms);
            finished = true;
            return 0;
        });
        while (!entered) std::this_thread::yield();
        worker.reset();
        assert(finished); // Destruction waits; it cannot cancel an active call.

        std::atomic<unsigned> calls{0};
        auto periodic = CreateRecurrentThread(1000, [&] {
            calls.fetch_add(1);
            std::this_thread::sleep_for(2ms);
        });
        while (!calls) std::this_thread::yield();
        periodic.reset();
        const auto stopped = calls.load();
        std::this_thread::sleep_for(3ms);
        assert(calls == stopped);
    }
    // RecurrentThread::Wait requests a cooperative stop, including interval 0.
    std::atomic<unsigned> calls{0};
    auto periodic = CreateRecurrentThread(0, [&] { calls.fetch_add(1); });
    while (!calls) std::this_thread::yield();
    assert(periodic->Wait(1000000));
    const auto stopped = calls.load();
    periodic.reset();
    assert(calls == stopped);

    auto fault = CreateThread([]() -> int {
        throw std::runtime_error("owned thread failure");
    });
    assert(fault->Wait(1000000) && fault->IsFault());
    assert(AnyCast<std::string>(fault->GetFaultMessage()) == "owned thread failure");
    fault.reset();

    calls = 0;
    auto recovering = CreateRecurrentThread(1000, [&] {
        if (calls.fetch_add(1) == 0) throw std::runtime_error("expected first tick failure");
    });
    const auto deadline = std::chrono::steady_clock::now() + 1s;
    while (calls < 2 && std::chrono::steady_clock::now() < deadline) std::this_thread::yield();
    recovering.reset();
    assert(calls >= 2);
    std::cout << "SDK worker lifecycle: join, cooperative stop, and callback ownership passed\n";
}
