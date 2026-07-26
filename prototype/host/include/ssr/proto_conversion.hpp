#pragma once

#include "ssr/cluster.hpp"
#include "ssr/dataplane_backend.hpp"
#include "ssr/node_agent.hpp"

#include "ssr_control.pb.h"

namespace ssr {

[[nodiscard]]
SessionId session_id_from_proto(
    const control::v1::SessionId& input
);

void session_id_to_proto(
    const SessionId& input,
    control::v1::SessionId* output
);

[[nodiscard]]
MacAddress mac_address_from_proto(
    const control::v1::MacAddress& input
);

void mac_address_to_proto(
    const MacAddress& input,
    control::v1::MacAddress* output
);

[[nodiscard]]
ClusterConfig cluster_config_from_proto(
    const control::v1::ClusterConfig& input
);

void cluster_config_to_proto(
    const ClusterConfig& input,
    control::v1::ClusterConfig* output
);

[[nodiscard]]
SyncResult sync_result_from_proto(
    const control::v1::SyncResult& input
);

void sync_result_to_proto(
    const SyncResult& input,
    control::v1::SyncResult* output
);

[[nodiscard]]
StartConfig start_config_from_proto(
    const control::v1::StartConfig& input
);

void start_config_to_proto(
    const StartConfig& input,
    control::v1::StartConfig* output
);

[[nodiscard]]
control::v1::NodeState node_state_to_proto(
    NodeAgentState state
) noexcept;

[[nodiscard]]
control::v1::DataplaneState dataplane_state_to_proto(
    DataplaneState state
) noexcept;

void dataplane_status_to_proto(
    const DataplaneStatus& input,
    control::v1::DataplaneStatus* output
);

} // namespace ssr

