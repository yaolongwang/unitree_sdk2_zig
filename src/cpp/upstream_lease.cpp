// Lifecycle repair for the pinned SDK's lease_client.cpp.o. Define the complete
// translation unit's public symbols so the archive's unsafe destructor is never
// selected. All fields come from the official class declarations; ABI unchanged.
#include <unitree/robot/client/lease_client.hpp>
#include <unitree/common/os.hpp>
#include <iostream>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <unordered_map>

namespace {
using unitree::robot::LeaseClient;

struct LeaseRpcRegistry {
    std::mutex mutex;
    std::unordered_map<const LeaseClient*, std::shared_ptr<std::mutex>> clients;
};

LeaseRpcRegistry& lease_rpc_registry() {
    static LeaseRpcRegistry registry;
    return registry;
}

std::shared_ptr<std::mutex> lease_rpc_mutex(const LeaseClient* client) {
    auto& registry = lease_rpc_registry();
    std::lock_guard<std::mutex> lock(registry.mutex);
    const auto found = registry.clients.find(client);
    if (found == registry.clients.end())
        throw std::logic_error("Lease client RPC state is unavailable");
    return found->second;
}
} // namespace

namespace usdk {
// Implemented by upstream_threads.cpp; a recurrent stop wakes this wait.
void sleep_current_sdk_thread(uint64_t microseconds);

// ClientBase's timeout member is private and is read during Call. Serialize its
// setters with the worker's RPC without changing the official class layout.
void set_lease_client_timeout(unitree::robot::LeaseClient& client, float seconds) {
    const auto mutex = lease_rpc_mutex(&client);
    std::lock_guard<std::mutex> lock(*mutex);
    client.SetTimeout(seconds);
}

void set_lease_client_timeout(unitree::robot::LeaseClient& client, int64_t microseconds) {
    const auto mutex = lease_rpc_mutex(&client);
    std::lock_guard<std::mutex> lock(*mutex);
    client.SetTimeout(microseconds);
}
}

namespace unitree {
namespace robot {

LeaseContext::LeaseContext() : mId(0), mTerm(ROBOT_LEASE_TERM) {}
LeaseContext::~LeaseContext() = default;

void LeaseContext::Update(int64_t id, int64_t term) {
    mId = id;
    mTerm = term;
}

void LeaseContext::Reset() {
    mId = 0;
    mTerm = ROBOT_LEASE_TERM;
}

bool LeaseContext::Valid() const { return mId != 0; }
int64_t LeaseContext::GetId() const { return mId; }
int64_t LeaseContext::GetTerm() const { return mTerm; }

LeaseClient::LeaseClient(const std::string& name)
    : ClientBase(name), mName(name) {
    // Client already appends "_lease" before constructing LeaseClient. The
    // The SDK context identifies the process.
    auto* os = common::OsHelper::Instance();
    mContextName = os->GetHostname() + "/" + os->GetProcessName() + "/" +
                   std::to_string(os->GetProcessId());
    auto rpc_mutex = std::make_shared<std::mutex>();
    auto& registry = lease_rpc_registry();
    std::lock_guard<std::mutex> lock(registry.mutex);
    registry.clients.emplace(this, std::move(rpc_mutex));
}

LeaseClient::~LeaseClient() {
    // mMutex is declared after mThreadPtr and would otherwise be destroyed
    // first. Stop and join now, while context, mutex and RPC channel still live.
    if (mThreadPtr) {
        mThreadPtr->Wait();
        mThreadPtr.reset();
    }
    auto& registry = lease_rpc_registry();
    std::lock_guard<std::mutex> lock(registry.mutex);
    registry.clients.erase(this);
}

void LeaseClient::Init() {
    if (mThreadPtr) return;
    usdk::set_lease_client_timeout(*this, int64_t{ROBOT_CLIENT_TIMEOUT});
    mThreadPtr = common::CreateRecurrentThreadEx(
        "leasecli", UT_CPU_ID_NONE, 0, &LeaseClient::ThreadFunction, this);
}

void LeaseClient::WaitApplied() {
    while (!Applied()) common::MicroSleep(100000);
}

int64_t LeaseClient::GetId() {
    common::LockGuard<common::Mutex> lock(mMutex);
    return mContext.GetId();
}

bool LeaseClient::Applied() {
    common::LockGuard<common::Mutex> lock(mMutex);
    return mContext.Valid();
}

void LeaseClient::Apply() {
    ApplyLeaseParameter parameter;
    parameter.name = mContextName;
    std::string response;
    const auto encoded = common::ToJsonString(parameter);
    int32_t status;
    {
        const auto mutex = lease_rpc_mutex(this);
        std::lock_guard<std::mutex> lock(*mutex);
        status = Call(ROBOT_API_ID_LEASE_APPLY, encoded, response, 0, 0);
    }
    if (status != 0) {
        std::cerr << "call apply lease error. ret:" << status << '\n';
        return;
    }

    ApplyLeaseData data;
    try {
        common::FromJsonString(response, data);
    } catch (const std::exception&) {
        std::cerr << "data from json error.\n";
        return;
    }
    common::LockGuard<common::Mutex> lock(mMutex);
    mContext.Update(data.id, data.term);
}

void LeaseClient::Renewal() {
    std::string response;
    // Snapshot the context before taking the RPC lock. Never nest mMutex with
    // that lock, so readers remain available while a network request waits.
    const int64_t lease_id = GetId();
    // The pinned SDK sends an empty parameter.
    int32_t status;
    {
        const auto mutex = lease_rpc_mutex(this);
        std::lock_guard<std::mutex> lock(*mutex);
        status = Call(ROBOT_API_ID_LEASE_RENEWAL, std::string(), response, 0, lease_id);
    }
    if (status == 0) return;
    std::cerr << "call renewal lease error. ret:" << status << '\n';
    if (status == UT_ROBOT_ERR_SERVER_LEASE_NOT_EXIST) {
        common::LockGuard<common::Mutex> lock(mMutex);
        mContext.Reset();
    }
}

int64_t LeaseClient::GetWaitMicrosec() {
    common::LockGuard<common::Mutex> lock(mMutex);
    int64_t term = mContext.Valid() ? mContext.GetTerm() : 0;
    if (term <= 0) term = ROBOT_LEASE_TERM;
    return static_cast<int64_t>(static_cast<double>(term) * 0.3);
}

void LeaseClient::ThreadFunction() {
    if (Applied()) Renewal();
    else Apply();
    usdk::sleep_current_sdk_thread(static_cast<uint64_t>(GetWaitMicrosec()));
}

} // namespace robot
} // namespace unitree
