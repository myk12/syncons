#pragma once

#include <cstdint>
#include <string>
#include <vector>
#include <array>
#include <stdexcept>
#include <map>

namespace ssr {

using NodeId = std::uint32_t;

struct MacAddress {
    std::array<std::uint8_t, 6> bytes{};

    [[nodiscard]]
    bool is_zero() const noexcept
    {
        for (const auto byte : bytes) {
            if (byte != 0) {
                return false;
            }
        }
        return true;
    }

    friend bool operator==(const MacAddress&, const MacAddress&) = default;
};

struct RunConfig {
    std::uint64_t run_id = 0;
    std::uint64_t start_time_ns = 0;
    std::uint32_t replica_num = 0;
    std::uint32_t round_length_ns = 0;

    void validate() const
    {
        if (replica_num == 0) {
            throw std::invalid_argument("replica_num must be greater than 0");
        }

        if (round_length_ns == 0) {
            throw std::invalid_argument("round_length_ns must be greater than 0");
        }

        if (start_time_ns == 0) {
            throw std::invalid_argument("start_time_ns must be greater than 0");
        }
    }
};

/*
 * A session identifies one complete cluster run.
 *
 * reset/configure/start/restart operations belonging to different
 * sesssions must never be mixed.
 */
struct SessionId {
    std::uint64_t high = 0;
    std::uint64_t low = 0;

    [[nodiscard]]
    bool is_zero() const noexcept
    {
        return high == 0 && low == 0;
    }

    [[nodiscard]]
    bool operator==(const SessionId& other) const noexcept
    {
        return high == other.high && low == other.low;
    }
    
    [[nodiscard]]
    bool operator!=(const SessionId& other) const noexcept
    {
        return !(*this == other);
    }
};

enum class AgentState : std::uint8_t {
    Idle,
    Configured,
    Running,
    Stopped,
};

enum class DataplaneState : std::uint8_t {
    Closed,
    Open,
    Configured,
    Running,
    Halted,
};

struct DataplaneStatus {
    DataplaneState state = DataplaneState::Closed;

    bool config_valid  = false;
    bool running = false;
    bool idle = false;

    std::uint32_t error_code = 0;
};

// Cluster-wide configuration
struct ClusterConfig {
    std::vector<MacAddress> replica_macs;

    std::uint16_t ethernet_type = 0;
    std::uint32_t round_length_ns = 0;

    [[nodiscard]]
    std::size_t replica_count() const noexcept
    {
        return replica_macs.size();
    }

    void validate() const
    {
        if (replica_macs.empty()) {
            throw std::invalid_argument("ClusterConfig must have at least one replica MAC address");
        }

        if (ethernet_type == 0) {
            throw std::invalid_argument("ClusterConfig ethernet_type must be non-zero");
        }

        if (round_length_ns == 0) {
            throw std::invalid_argument("ClusterConfig round_length_ns must be non-zero");
        }
    }
};

enum class CoordinatorState : std::uint8_t {
    Idle,
    Ready,
    Running,
    Stopped,
};

struct TimeSync {
    std::int64_t estimated_offset_ns = 0;
    std::uint64_t uncertainty_ns = 0;
};

struct SyncResult {
    bool synchronized = false;
    TimeSync time_sync;
    std::uint32_t round_length_ns = 0;
};

using SyncResults = std::map<NodeId, SyncResult>;

} // namespace ssr
