#pragma once

#include "ssr/config.hpp"
#include "ssr/coordination.hpp"

#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include <vector>

namespace ssr {

class ClusterControlError : public std::runtime_error {
public:
    using std::runtime_error::runtime_error;
};

// Cluster-wide configuration
struct ClusterConfig {
    std::vector<MacAddress> replica_macs;

    std::uint16_t ethernet_type = 0;
    std::uint32_t round_length_ns = 0;

    void validate() const;

    [[nodiscard]]
    std::size_t replica_count() const noexcept
    {
        return replica_macs.size();
    }

    // Generate the node-local dataplane configuration
    [[nodiscard]]
    SsrConfig for_node(NodeId node_id) const;
};

enum class NodeAgentState : std::uint8_t {
    Idle,
    Ready,
    Running,
    Stopped,
    Failed,
};

enum class CoordinatorState : std::uint8_t {
    CollectingNodes,
    Idle,
    Preparing,
    Ready,
    Running,
    Stopping,
    Stopped,
    Resetting,
    Failed,
};

} // namespace ssr
