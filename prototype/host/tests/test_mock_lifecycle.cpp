#include "ssr/mock_dataplane.hpp"

#include <exception>
#include <iostream>
#include <stdexcept>
#include <string_view>

namespace {

void require(
    const bool condition,
    const std::string_view message
)
{
    if (!condition) {
        throw std::runtime_error(std::string(message));
    }
}

template <typename Exception, typename Function>
void require_throws(
    Function&& func,
    const std::string_view message
)
{
    bool threw = false;

    try {
        func();
    } catch (const Exception&) {
        threw = true;
    }

    if (!threw) {
        throw std::runtime_error(std::string(message));
    }
}

ssr::SsrConfig make_test_config()
{
    ssr::SsrConfig config;

    config.replica_id = 0;
    config.replica_num = 3;
    config.ethernet_type = 0x88B5;
    config.round_length_ns = 2000;

    config.replica_macs = {
        ssr::MacAddress{{0x00, 0x11, 0x22, 0x33, 0x44, 0x55}},
        ssr::MacAddress{{0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb}},
        ssr::MacAddress{{0xcc, 0xdd, 0xee, 0xff, 0x00, 0x11}},
    };

    return config;
}

void test_normal_lifecycle()
{
    ssr::MockDataplaneBackend dataplane;

    require(
        dataplane.status().state == ssr::DataplaneState::Closed,
        "Dataplane should be in Closed state after construction"
    );

    dataplane.open();

    require(
        dataplane.status().state == ssr::DataplaneState::Ready,
        "Dataplane should be in Ready state after open()"
    );

    dataplane.reset();

    const auto config = make_test_config();

    dataplane.configure(config);

    require(
        dataplane.status().config_valid,
        "Dataplane should have valid configuration after configure()"
    );

    require(
        dataplane.status().state == ssr::DataplaneState::Configured,
        "Dataplane should be in Configured state after configure()"
    );

    const ssr::SyncResult sync_result{
        .synchronized = true,
        .estimated_offset_ns = 0,
        .uncertainty_ns = 100,
    };

    dataplane.synchronize(sync_result);

    require(
        dataplane.status().sync_valid,
        "Dataplane should have valid synchronization after synchronize()"
    );

    require(
        dataplane.status().state == ssr::DataplaneState::Synchronized,
        "Dataplane should be in Synchronized state after synchronize()"
    );

    const ssr::StartConfig start_config{
        .first_round_id = 0,
        .first_round_timestamp_ns = 1'000'000ULL,
        .first_run_id = 1,
    };

    dataplane.start(start_config);

    require(
        dataplane.status().running,
        "Dataplane should be running after start()"
    );

    require(
        dataplane.status().state == ssr::DataplaneState::Running,
        "Dataplane should be in Running state after start()"
    );

    dataplane.stop();

    require(
        !dataplane.status().running,
        "Dataplane should not be running after stop()"
    );

    require(
        dataplane.status().state == ssr::DataplaneState::Stopped,
        "Dataplane should be in Stopped state after stop()"
    );

    const ssr::StartConfig second_start{
        .first_round_id = 0,
        .first_round_timestamp_ns = 2'000'000ULL,
        .first_run_id = 0,
    };

    dataplane.start(second_start);

    require(
        dataplane.status().running,
        "Dataplane should be running after second start()"
    );

    dataplane.stop();

    dataplane.reset();

    require(
        !dataplane.status().config_valid,
        "Dataplane should not have valid configuration after reset()"
    );

    require(
        !dataplane.status().sync_valid,
        "Dataplane should not have valid synchronization after reset()"
    );

    require(
        dataplane.status().state == ssr::DataplaneState::Reset,
        "Dataplane should be in Reset state after reset()"
    );

    dataplane.close();

    require(
        dataplane.status().state == ssr::DataplaneState::Closed,
        "Dataplane should be in Closed state after close()"
    );
}

void test_invalid_transition()
{
    ssr::MockDataplaneBackend dataplane;

    dataplane.open();
    dataplane.reset();

    const ssr::StartConfig start_config{
        .first_round_id = 0,
        .first_round_timestamp_ns = 1'000'000ULL,
        .first_run_id = 0,
    };

    require_throws<ssr::DataplaneError>(
        [&]() { dataplane.start(start_config); },
        "Dataplane should throw when starting without synchronization"
    );

    // Failed start must not change the state
    require(
        dataplane.status().state == ssr::DataplaneState::Reset,
        "Dataplane should remain in Reset state after failed start()"
    );
}

void test_invalid_configuration()
{
    ssr::MockDataplaneBackend dataplane;

    dataplane.open();
    dataplane.reset();

    auto config = make_test_config();

    // Duplicate MAC addresses
    config.replica_macs[2] = config.replica_macs[1];

    require_throws<std::invalid_argument>(
        [&]() { config.validate(); },
        "Dataplane should throw when configuring with duplicate MAC addresses"
    );

    require_throws<std::invalid_argument>(
        [&]() { dataplane.configure(config); },
        "Dataplane should throw when configuring with invalid configuration"
    );

    require(
        dataplane.status().state == ssr::DataplaneState::Reset,
        "Dataplane should remain in Reset state after failed configure()"
    );

    require(
        !dataplane.status().config_valid,
        "Dataplane should not have valid configuration after failed configure()"
    );
}

void test_injected_configure_failure()
{
    ssr::MockDataplaneBackend dataplane;

    dataplane.open();
    dataplane.reset();

    auto config = make_test_config();

    dataplane.fail_next(ssr::MockFailurePoint::Configure);

    require_throws<ssr::DataplaneError>(
        [&]() { dataplane.configure(config); },
        "Dataplane should throw when injected failure occurs during configure()"
    );

    require(
        dataplane.status().state == ssr::DataplaneState::Reset,
        "Dataplane should remain in Reset state after failed configure()"
    );

    require(
        !dataplane.status().config_valid,
        "Dataplane should not have valid configuration after failed configure()"
    );

    dataplane.configure(config);

    require(
        dataplane.status().state == ssr::DataplaneState::Configured,
        "Dataplane should be in Configured state after successful configure()" 
    );
}

} // namespace

int main()
{
    try {
        std::cout << "Running SSR mock lifecycle tests..." << std::endl;
        std::cout << "[Test] normal lifecycle" << std::endl;
        test_normal_lifecycle();
        std::cout << "[Test] invalid transition" << std::endl;
        test_invalid_transition();
        std::cout << "[Test] invalid configuration" << std::endl;
        test_invalid_configuration();
        std::cout << "[Test] injected configure failure" << std::endl;
        test_injected_configure_failure();
        std::cout << "SSR mock lifecycle tests passed." << std::endl;

        return 0;
    } catch (const std::exception& e) {
        std::cerr << "SSR mock lifecycle tests failed: " << e.what() << std::endl;
        return 1;
    }
}