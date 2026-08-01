#pragma once

#include "ssr/ssr.h"
#include "ssr/agent_dataplane_backend.hpp"

#include <optional>

namespace ssr {

enum class MockFailurePoint : std::uint8_t {
    Open,
    Reset,
    Configure,
    Synchronize,
    Start,
    Stop,
};

class MockDataplaneBackend final: public DataplaneBackend {
public:
    MockDataplaneBackend() = default;

    void open() override;
    void close() noexcept override;
    void reset() override;
    void configure(const RunConfig& config) override;
    void start() override;
    void stop() override;

    [[nodiscard]]
    DataplaneStatus status() const override;

    [[nodiscard]]
    const std::optional<RunConfig>& config() const noexcept
    {
        return config_;
    };

    // Inject a one-shot failure
    void fail_next(MockFailurePoint point) noexcept;

    void clear_failures() noexcept;

private:
    void require_open() const;

    DataplaneStatus dataplane_status_;
    std::optional<RunConfig> config_;

    void maybe_fail(MockFailurePoint point);
    std::optional<MockFailurePoint> failure_point_;
};

} // namespace ssr

