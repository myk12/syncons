#include "ssr/mock_dataplane.hpp"

#include <utility>
#include <string>

namespace ssr {

const char* failure_point_name(
    const ssr::MockFailurePoint point
) noexcept
{
    switch (point) {
        case MockFailurePoint::Open: return "Open";
        case MockFailurePoint::Reset: return "Reset";
        case MockFailurePoint::Configure: return "Configure";
        case MockFailurePoint::Synchronize: return "Synchronize";
        case MockFailurePoint::Start: return "Start";
        case MockFailurePoint::Stop: return "Stop";
    }
    return "Unknown";
}

void MockDataplaneBackend::require_open() const
{
    if (state_ == DataplaneState::Closed) {
        throw DataplaneError("Dataplane is closed");
    }
}

void MockDataplaneBackend::open()
{
    if (state_ != DataplaneState::Closed) {
        throw DataplaneError("Dataplane is already open");
    }

    maybe_fail(MockFailurePoint::Open);

    state_ = DataplaneState::Ready;
}

void MockDataplaneBackend::close() noexcept
{
    config_.reset();
    sync_result_.reset();
    start_config_.reset();
    failure_point_.reset();

    state_ = DataplaneState::Closed;
}

void MockDataplaneBackend::reset()
{
    require_open();

    maybe_fail(MockFailurePoint::Reset);

    config_.reset();
    sync_result_.reset();
    start_config_.reset();

    state_ = DataplaneState::Reset;
}

void MockDataplaneBackend::configure(const SsrConfig& config)
{
    require_open();

    if (state_ != DataplaneState::Reset) {
        throw DataplaneError("Dataplane must be in Reset state to configure");
    }

    config.validate();

    maybe_fail(MockFailurePoint::Configure);

    config_ = config;
    sync_result_.reset();
    start_config_.reset();

    state_ = DataplaneState::Configured;
}

void MockDataplaneBackend::synchronize(const SyncResult& result)
{
    require_open();

    if (state_ != DataplaneState::Configured) {
        throw DataplaneError("Dataplane must be in Configured state to synchronize");
    }

    if (!result.synchronized) {
        throw DataplaneError("SyncResult must indicate synchronized");
    }

    maybe_fail(MockFailurePoint::Synchronize);

    sync_result_ = result;
    state_ = DataplaneState::Synchronized;
}

void MockDataplaneBackend::start(const StartConfig& config)
{
    require_open();

    if (state_ != DataplaneState::Synchronized &&
        state_ != DataplaneState::Stopped) {
        throw DataplaneError("Dataplane must be in Synchronized or Stopped state to start");
    }

    if (!config_.has_value()) {
        throw DataplaneError("Dataplane must be configured before starting");
    }

    if (!sync_result_.has_value() ||
        !sync_result_->synchronized) {
        throw DataplaneError("Dataplane must be synchronized before starting");
    }

    config.validate();

    maybe_fail(MockFailurePoint::Start);

    start_config_ = config;
    state_ = DataplaneState::Running;
}

void MockDataplaneBackend::stop()
{
    require_open();

    if (state_ != DataplaneState::Running) {
        throw DataplaneError("Dataplane must be in Running state to stop");
    }

    maybe_fail(MockFailurePoint::Stop);

    // Stop preserves static configuration and synchronization.
    state_ = DataplaneState::Stopped;
}


DataplaneStatus MockDataplaneBackend::status() const
{
    DataplaneStatus result;

    result.state = state_;
    result.config_valid = config_.has_value();
    result.sync_valid = sync_result_.has_value() && sync_result_->synchronized;
    result.running = (state_ == DataplaneState::Running);
    result.idle = (state_ != DataplaneState::Closed &&
                    state_ != DataplaneState::Running &&
                    state_ != DataplaneState::Failed);
    
    result.error_code = 0; // No error codes in mock implementation
    return result;
}

void MockDataplaneBackend::fail_next(const MockFailurePoint point) noexcept
{
    failure_point_ = point;
}

void MockDataplaneBackend::clear_failures() noexcept
{
    failure_point_.reset();
}

void MockDataplaneBackend::maybe_fail(const MockFailurePoint point)
{
    if (!failure_point_.has_value()) {
        return;
    }

    if (*failure_point_ != point) {
        return;
    }

    // Consume the injected failure before throwing.
    // This is important because rollback may invoke reset(), and we
    // want a Configure failure to happen only once.
    failure_point_.reset();

    throw DataplaneError(
        "Injected failure at point: " + std::string(failure_point_name(point))
    );
}

} // namespace ssr
