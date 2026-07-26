#pragma once

#include "ssr/config.hpp"

#include <cstdint>
#include <stdexcept>

namespace ssr {

class DataplaneError : public std::runtime_error {
public:
    using std::runtime_error::runtime_error;
};

enum class DataplaneState : std::uint8_t {
    Closed,
    Ready,
    Reset,
    Configured,
    Synchronized,
    Running,
    Stopped,
    Failed,
};

struct DataplaneStatus {
    DataplaneState state = DataplaneState::Closed;

    bool config_valid  = false;
    bool sync_valid    = false;
    bool running = false;
    bool idle = false;

    std::uint32_t error_code = 0;
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

    virtual void configure(const SsrConfig& config) = 0;

    virtual void synchronize(const SyncResult& result) = 0;

    virtual void start(const StartConfig& config) = 0;

    virtual void stop() = 0;

    [[nodiscard]] virtual DataplaneStatus status() const = 0;
};

} // namespace ssr
