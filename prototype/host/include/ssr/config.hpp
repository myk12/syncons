#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include <vector>

namespace ssr {

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

struct SsrConfig {
    std::uint32_t replica_id = 0;
    std::uint32_t replica_num = 0;

    // replica_macs[i] is the MAC address of replica i
    std::vector<MacAddress> replica_macs;

    std::uint16_t ethernet_type = 0x88B5; // default to Ethertype for SSR
    std::uint32_t round_length_ns = 0;

    void validate() const
    {
        constexpr std::uint32_t max_replicas = 7;

        if (replica_num == 0 || replica_num > max_replicas) {
            throw std::invalid_argument(
                "replica_num must be in [1, " + std::to_string(max_replicas) + "]"
            );
        }

        if (replica_id >= replica_num) {
            throw std::invalid_argument(
                "replica_id must be in [0, replica_num - 1]"
            );
        }

        if (replica_macs.size() != replica_num) {
            throw std::invalid_argument(
                "replica_macs must have size equal to replica_num"
            );
        }

        if (round_length_ns == 0) {
            throw std::invalid_argument(
                "round_length_ns must be greater than 0"
            );
        }

        for (std::size_t i = 0; i < replica_macs.size(); ++i) {
            if (replica_macs[i].is_zero()) {
                throw std::invalid_argument(
                    "replica_macs[" + std::to_string(i) + "] must not be zero"
                );
            }

            for (std::size_t j = i + 1; j < replica_macs.size(); ++j) {
                if (replica_macs[i] == replica_macs[j]) {
                    throw std::invalid_argument(
                        "replica MAC addresses must be unique, but replica_macs[" + std::to_string(i) + "] and replica_macs[" + std::to_string(j) + "] are equal"
                    );
                }
            }
        }
    }

    [[nodiscard]]
    const MacAddress& local_mac() const
    {
        validate();
        return replica_macs.at(replica_id);
    }
};

struct SyncResult {
    bool synchronized = false;

    std::int64_t estimated_offset_ns = 0;

    std::uint64_t uncertainty_ns = 0;
};


struct StartConfig {
    std::uint64_t first_round_id = 0;
    std::uint64_t first_round_timestamp_ns = 0;
    std::uint64_t first_run_id = 0;

    void validate() const
    {
        if (first_round_timestamp_ns == 0) {
            throw std::invalid_argument(
                "first_round_timestamp_ns must be greater than 0"
            );
        }
    }
};

} // namespace ssr
