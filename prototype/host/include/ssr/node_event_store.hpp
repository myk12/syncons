#pragma once

#include "ssr_control.pb.h"

#include <cstddef>
#include <cstdint>
#include <deque>
#include <mutex>
#include <optional>
#include <unordered_map>
#include <vector>

namespace ssr {

struct NodeEventAcceptResult {
    std::uint64_t acknowledged_sequence_number = 0;
    bool newly_accepted = false;
};

class NodeEventStore {
public:
    explicit NodeEventStore(std::size_t max_events = 1024);

    [[nodiscard]]
    NodeEventAcceptResult accept(const control::v1::NodeEventReport& report);

    [[nodiscard]]
    std::optional<control::v1::NodeEventReport> latest(std::uint32_t node_id) const;

    [[nodiscard]]
    std::vector<control::v1::NodeEventReport> history() const;

private:
    std::size_t max_history_size_;
    mutable std::mutex mutex_;

    std::unordered_map<std::uint32_t, std::uint64_t> acknowledged_sequence_numbers_;

    std::unordered_map<std::uint32_t, control::v1::NodeEventReport> latest_events_;
    std::deque<control::v1::NodeEventReport> history_;
};

} // namespace ssr
