#include "ssr/node_event_store.hpp"

#include <algorithm>
#include <stdexcept>

namespace ssr {

NodeEventStore::NodeEventStore(
    const std::size_t max_events
)
    : max_history_size_(max_events)
{
    if (max_history_size_ == 0) {
        throw std::invalid_argument("max_events must be greater than zero");
    }
}

NodeEventAcceptResult NodeEventStore::accept(
    const control::v1::NodeEventReport& report
)
{
    if (report.sequence_number() == 0) {
        throw std::invalid_argument("Event report sequence number must be greater than zero");
    }

    std::scoped_lock lock(mutex_);

    auto& acknowledged = acknowledged_sequence_numbers_[report.node_id()];

    if (report.sequence_number() <= acknowledged) {
        // This is a duplicate or out-of-order report; ignore it.
        return NodeEventAcceptResult{
            .acknowledged_sequence_number = acknowledged,
            .newly_accepted = false
        };
    }

    acknowledged = report.sequence_number();

    latest_events_[report.node_id()] = report;
    history_.push_back(report);

    while (history_.size() > max_history_size_) {
        history_.pop_front();
    }

    return NodeEventAcceptResult{
        .acknowledged_sequence_number = acknowledged,
        .newly_accepted = true
    };
}

std::optional<control::v1::NodeEventReport> NodeEventStore::latest(
    const std::uint32_t node_id
) const
{
    std::scoped_lock lock(mutex_);

    auto it = latest_events_.find(node_id);
    if (it != latest_events_.end()) {
        return it->second;
    }

    return std::nullopt;
}

std::vector<control::v1::NodeEventReport> NodeEventStore::history() const
{
    std::scoped_lock lock(mutex_);

    return std::vector<control::v1::NodeEventReport>(history_.begin(), history_.end());
}

} // namespace ssr