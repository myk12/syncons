#include "ssr/agent_dataplane_backend_mock.hpp"

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
    if (dataplane_status_.state == DataplaneState::Closed) {
        throw DataplaneError("Dataplane is closed");
    }
}

void MockDataplaneBackend::open()
{
    printf("MockDataplaneBackend::open called\n");
    if (dataplane_status_.state != DataplaneState::Closed) {
        throw DataplaneError("Dataplane is already open");
    }

    maybe_fail(MockFailurePoint::Open);

    dataplane_status_.state = DataplaneState::Open;
    printf("MockDataplaneBackend::open succeeded, state is now Open\n");
}

void MockDataplaneBackend::close() noexcept
{
    printf("MockDataplaneBackend::close called\n");
    config_.reset();
    failure_point_.reset();

    dataplane_status_.state = DataplaneState::Closed;
}

void MockDataplaneBackend::reset()
{
    printf("MockDataplaneBackend::reset called\n");
    require_open();

    maybe_fail(MockFailurePoint::Reset);

    config_.reset();

    dataplane_status_.state = DataplaneState::Closed; // Reset transitions to Closed for simplicity in mock
}

void MockDataplaneBackend::configure(const RunConfig& config)
{
    printf("MockDataplaneBackend::configure called\n");
    require_open();

    if (dataplane_status_.state != DataplaneState::Open) {
        throw DataplaneError("Dataplane must be in Open state to configure");
    }

    config.validate();

    maybe_fail(MockFailurePoint::Configure);

    config_ = config;

    dataplane_status_.state = DataplaneState::Configured;
    printf("MockDataplaneBackend::configure succeeded, state is now Configured\n");
}

void MockDataplaneBackend::start()
{
    printf("MockDataplaneBackend::start called\n");
    require_open();

    if (dataplane_status_.state != DataplaneState::Configured) {
        throw DataplaneError("Dataplane must be in Configured state to start");
    }

    if (!config_.has_value()) {
        throw DataplaneError("Dataplane must be configured before starting");
    }

    maybe_fail(MockFailurePoint::Start);

    dataplane_status_.state = DataplaneState::Running;
    printf("MockDataplaneBackend::start succeeded, state is now Running\n");
}

void MockDataplaneBackend::stop()
{
    printf("MockDataplaneBackend::stop called\n");
    require_open();

    if (dataplane_status_.state != DataplaneState::Running) {
        throw DataplaneError("Dataplane must be in Running state to stop");
    }

    maybe_fail(MockFailurePoint::Stop);

    // Stop preserves static configuration and synchronization.
    dataplane_status_.state = DataplaneState::Closed; // Transition to Closed for simplicity in mock
    printf("MockDataplaneBackend::stop succeeded, state is now Closed\n");
}

DataplaneStatus MockDataplaneBackend::status() const
{
    DataplaneStatus result;

    result.state = dataplane_status_.state;
    result.config_valid = config_.has_value();
    result.running = (dataplane_status_.state == DataplaneState::Running);
    result.idle = (dataplane_status_.state != DataplaneState::Closed &&
                    dataplane_status_.state != DataplaneState::Running &&
                    dataplane_status_.state != DataplaneState::Halted);
    
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
