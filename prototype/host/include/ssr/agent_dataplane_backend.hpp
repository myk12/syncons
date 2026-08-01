#pragma once

#include "ssr/ssr.h"
#include <stdexcept>
#include <optional>

namespace ssr {

class DataplaneError : public std::runtime_error {
public:
    using std::runtime_error::runtime_error;
};

class DataplaneBackend {
public:
    virtual ~DataplaneBackend() = default;

    // Open the userspace connection to the dataplane.
    virtual void open() = 0;

    virtual void close() noexcept = 0;

    // Start a new SSR software/hardware session
    // reset() clears old configuration, synchronization state,
    // runtime counters, proposal state, and commit state.
    virtual void reset() = 0;

    virtual void configure(const RunConfig& config) = 0;

    virtual void start() = 0;

    virtual void stop() = 0;

    [[nodiscard]] virtual DataplaneStatus status() const = 0;
};

} // namespace ssr
