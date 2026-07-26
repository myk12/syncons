#include "ssr/cluster.hpp"

#include <limits>

namespace ssr {

void ClusterConfig::validate() const
{
    constexpr std::size_t max_replicas = 7;

    if (replica_macs.empty()) {
        throw std::invalid_argument("Cluster must contain at least one replica");
    }

    if (replica_macs.size() > max_replicas) {
        throw std::invalid_argument("Cluster cannot contain more than " + std::to_string(max_replicas) + " replicas");
    }

    // Reuse SsrConfig validation for the common fiedls and MAC table
    SsrConfig config;

    config.replica_id = 0; // dummy value
    config.replica_num = static_cast<std::uint32_t>(replica_macs.size());
    config.replica_macs = replica_macs;
    config.ethernet_type = ethernet_type;
    config.round_length_ns = round_length_ns;

    config.validate();
}

SsrConfig ClusterConfig::for_node(NodeId node_id) const
{
    validate();

    if (node_id >= replica_macs.size()) {
        throw std::invalid_argument(
            "node_id must be in [0, replica_count() - 1]"
        );
    }

    SsrConfig config;

    config.replica_id = static_cast<std::uint32_t>(node_id);
    config.replica_num = static_cast<std::uint32_t>(replica_macs.size());
    config.replica_macs = replica_macs;
    config.ethernet_type = ethernet_type;
    config.round_length_ns = round_length_ns;

    return config;
}

} // namespace ssr
