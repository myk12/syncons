#pragma once
#include "ssr/ssr.h"
#include "ssr/proto_conversion.hpp"
#include "ssr_control.grpc.pb.h"

#include <mutex>
#include <atomic>
#include <memory>
#include <map>

namespace ssr {

struct AgentEndpoint {
    NodeId node_id{};
    std::string address;
    std::string ip_address;
    std::uint16_t port{};
    std::string mac_address;
};

struct AgentRPCClient {
    NodeId node_id{};
    std::shared_ptr<grpc::Channel> channel;
    std::unique_ptr<control::v1::AgentService::Stub> stub;
};

struct AgentRPCResult {
    NodeId node_id{};
    grpc::StatusCode status_code{};
    std::string message;
    control::v1::AgentReply reply;
    [[nodiscard]] bool ok() const noexcept
    {
        return status_code == grpc::StatusCode::OK;
    }
};

struct ClusterOptResult {
    CoordinatorState final_state = CoordinatorState::Stopped;
    std::vector<AgentRPCResult> results;
    [[nodiscard]] bool ok() const noexcept
    {
        return final_state != CoordinatorState::Stopped && std::all_of(results.begin(), results.end(),
                       [](const AgentRPCResult& result) { return result.ok(); });
    }
};

class SSRCoordinator {
public:
    SSRCoordinator(std::vector<AgentEndpoint> endpoints);

    virtual ~SSRCoordinator() = default;

    SSRCoordinator(const SSRCoordinator&) = delete;
    SSRCoordinator& operator=(const SSRCoordinator&) = delete;

    [[nodiscard]]
    CoordinatorState state() const noexcept
    {
        return state_.load(std::memory_order_acquire);
    }

    //int32_t load_config_from_file(const std::string& config_file_path);
    ClusterOptResult agents_prepare(const SessionId&, const RunConfig&);
    ClusterOptResult agents_start();
    ClusterOptResult agents_stop();
    std::vector<AgentRPCResult> agents_get_status();

private:
    void require_state(CoordinatorState expected, const char* const operation) const;

    mutable std::mutex operation_mutex_;
    std::atomic<CoordinatorState> state_{CoordinatorState::Idle};
    ClusterConfig cluster_config_{};
    std::unordered_map<NodeId, AgentEndpoint> agents_endpoints_;
    std::unordered_map<NodeId, AgentRPCClient> agent_rpc_client_map_;

    SessionId session_id_{};
    std::chrono::milliseconds rpc_timeout_{std::chrono::seconds(5)};

};

} // namespace ssr
