#pragma once

#include "ssr/dataplane_backend.hpp"

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

    void configure(const SsrConfig& config) override;

    void synchronize(const SyncResult& result) override;

    void start(const StartConfig& config) override;

    void stop() override;

    [[nodiscard]]
    DataplaneStatus status() const override;

    [[nodiscard]]
    const std::optional<SsrConfig>& config() const noexcept
    {
        return config_;
    }

    [[nodiscard]]
    const std::optional<SyncResult>& sync_result() const noexcept
    {
        return sync_result_;
    }

    [[nodiscard]]
    const std::optional<StartConfig>& start_config() const noexcept
    {
        return start_config_;
    }

    // Inject a one-shot failure
    void fail_next(MockFailurePoint point) noexcept;

    void clear_failures() noexcept;

private:
    void require_open() const;

    DataplaneState state_ = DataplaneState::Closed;

    std::optional<SsrConfig> config_;
    std::optional<SyncResult> sync_result_;
    std::optional<StartConfig> start_config_;

    void maybe_fail(MockFailurePoint point);
    std::optional<MockFailurePoint> failure_point_;
};

} // namespace ssr

