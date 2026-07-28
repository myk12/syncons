#include "ssr/proto_conversion.hpp"

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include <string>
#include <limits>

namespace ssr {

SessionId session_id_from_proto(
    const control::v1::SessionId& input
)
{
    SessionId result = SessionId{
        .high = input.high(),
        .low = input.low()
    };

    return result;
}

void session_id_to_proto(
    const SessionId& input,
    control::v1::SessionId* output
)
{
    if (output == nullptr) {
        throw std::invalid_argument("output pointer is null");
    }

    output->set_high(input.high);
    output->set_low(input.low);
}

MacAddress mac_address_from_proto(
    const control::v1::MacAddress& input
)
{
    const std::string& encoded = input.value();

    if (encoded.size() != 6) {
        throw std::invalid_argument("Invalid MAC address length: " + std::to_string(encoded.size()));
    }

    MacAddress result{};

    for (std::size_t i = 0; i < 6; ++i) {
        result.bytes[i] = static_cast<std::uint8_t>(encoded[i]);
    }

    if (result.is_zero()) {
        throw std::invalid_argument("MAC address cannot be all zeros");
    }

    return result;
}

void mac_address_to_proto(
    const MacAddress& input,
    control::v1::MacAddress* const output
)
{
    if (output == nullptr) {
        throw std::invalid_argument("output pointer is null");
    }

    std::string encoded;
    encoded.resize(input.bytes.size());

    for (std::size_t i = 0; i < input.bytes.size(); ++i) {
        encoded[i] = static_cast<char>(input.bytes[i]);
    }

    output->set_value(std::move(encoded));
}

ClusterConfig cluster_config_from_proto(
    const control::v1::ClusterConfig& input
)
{
    ClusterConfig result{};

    result.replica_macs.reserve(static_cast<std::size_t>(input.replica_macs_size()));

    for (const auto& encoded_mac : input.replica_macs()) {
        result.replica_macs.push_back(mac_address_from_proto(encoded_mac));
    }

    result.ethernet_type = static_cast<uint16_t>(input.ethernet_type());
    result.round_length_ns = input.round_length_ns();

    result.validate();

    return result;
}

void cluster_config_to_proto(
    const ClusterConfig& input,
    control::v1::ClusterConfig* const output
)
{
    if (output == nullptr) {
        throw std::invalid_argument("output pointer is null");
    }

    output->clear_replica_macs();
    for (const auto& mac : input.replica_macs) {
        mac_address_to_proto(mac, output->add_replica_macs());
    }

    output->set_ethernet_type(input.ethernet_type);
    output->set_round_length_ns(input.round_length_ns);
}

SyncResult sync_result_from_proto(
    const control::v1::SyncResult& input
)
{
    return SyncResult{
        .synchronized = input.synchronized(),
        .estimated_offset_ns = input.estimated_offset_ns(),
        .uncertainty_ns = input.uncertainty_ns()
    };
}

void sync_result_to_proto(
    const SyncResult& input,
    control::v1::SyncResult* const output
)
{
    if (output == nullptr) {
        throw std::invalid_argument("output pointer is null");
    }

    output->set_synchronized(input.synchronized);
    output->set_estimated_offset_ns(input.estimated_offset_ns);
    output->set_uncertainty_ns(input.uncertainty_ns);
}

StartConfig start_config_from_proto(
    const control::v1::StartConfig& input
)
{
    StartConfig result{
        .first_round_id = input.first_round_id(),
        .first_round_timestamp_ns = input.first_round_timestamp_ns(),
        .first_run_id = input.first_run_id(),
    };

    result.validate();

    return result;
}

void start_config_to_proto(
    const StartConfig& input,
    control::v1::StartConfig* const output
)
{
    if (output == nullptr) {
        throw std::invalid_argument("output pointer is null");
    }

    output->set_first_round_id(static_cast<uint32_t>(input.first_round_id));
    output->set_first_round_timestamp_ns(input.first_round_timestamp_ns);
    output->set_first_run_id(static_cast<uint32_t>(input.first_run_id));
}

control::v1::NodeState node_state_to_proto(
    const NodeAgentState state
) noexcept
{
    switch (state) {
        case NodeAgentState::Idle:
            return control::v1::NODE_STATE_IDLE;
        case NodeAgentState::Ready:
            return control::v1::NODE_STATE_READY;
        case NodeAgentState::Running:
            return control::v1::NODE_STATE_RUNNING;
        case NodeAgentState::Stopped:
            return control::v1::NODE_STATE_STOPPED;
        case NodeAgentState::Failed:
            return control::v1::NODE_STATE_FAILED;
        default:
            return control::v1::NODE_STATE_UNSPECIFIED;
    }

    return control::v1::NODE_STATE_UNSPECIFIED;
}

control::v1::DataplaneState dataplane_state_to_proto(
    const DataplaneState state
) noexcept
{
    switch (state) {
        case DataplaneState::Closed:
            return control::v1::DATAPLANE_STATE_CLOSED;
        case DataplaneState::Ready:
            return control::v1::DATAPLANE_STATE_READY;
        case DataplaneState::Reset:
            return control::v1::DATAPLANE_STATE_RESET;
        case DataplaneState::Configured:
            return control::v1::DATAPLANE_STATE_CONFIGURED;
        case DataplaneState::Synchronized:
            return control::v1::DATAPLANE_STATE_SYNCHRONIZED;
        case DataplaneState::Running:
            return control::v1::DATAPLANE_STATE_RUNNING;
        case DataplaneState::Stopped:
            return control::v1::DATAPLANE_STATE_STOPPED;
        default:
            return control::v1::DATAPLANE_STATE_UNSPECIFIED;
    }

    return control::v1::DATAPLANE_STATE_UNSPECIFIED;
}

void dataplane_status_to_proto(
    const DataplaneStatus& input,
    control::v1::DataplaneStatus* const output
)
{
    if (output == nullptr) {
        throw std::invalid_argument("output pointer is null");
    }

    output->set_state(dataplane_state_to_proto(input.state));
    output->set_config_valid(input.config_valid);
    output->set_sync_valid(input.sync_valid);
    output->set_running(input.running);
}

} // namespace ssr