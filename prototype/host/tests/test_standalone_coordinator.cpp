#include "ssr/mock_dataplane.hpp"
#include "ssr/standalone_coordinator.hpp"

#include <exception>
#include <iostream>
#include <stdexcept>
#include <string>
#include <string_view>
#include <utility>

namespace {

// =======================================================
//                  Test utilities
// =======================================================
void require(const bool condition, const std::string_view message)
{
    if (!condition) {
        throw std::runtime_error(std::string(message));
    }
}

template<typename ExpectedException, typename Function>
void require_throws(
    Function&& func,
    const std::string_view message
)
{
    bool caught_expected = false;

    try {
        std::forward<Function>(func)();
    }
    catch (const ExpectedException&) {
        caught_expected = true;
    }
    catch (const std::exception& exception){
        throw std::runtime_error(
            std::string(message) + ": caught unexpected exception: " +
            exception.what()
        );
    }

    if (!caught_expected) {
        throw std::runtime_error(
            std::string(message) + ": did not catch expected exception"
        );
    }
}

ssr::ClusterConfig make_cluster_config()
{
    ssr::ClusterConfig config;

    config.ethernet_type = 0x88B5;
    config.round_length_ns = 2000; // 2 us

    config.replica_macs = {
        ssr::MacAddress{{0x00, 0x11, 0x22, 0x33, 0x44, 0x55}},
        ssr::MacAddress{{0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb}},
        ssr::MacAddress{{0xcc, 0xdd, 0xee, 0xff, 0x00, 0x11}},
    };

    return config;
}

ssr::SessionId make_session_id()
{
    return ssr::SessionId{0x12345678, 0x9abcdef0};
}

ssr::SyncResult make_sync_result()
{
    return ssr::SyncResult{
        .synchronized = true,
        .estimated_offset_ns = 10,
        .uncertainty_ns = 100,
    };
}

ssr::StartConfig make_start_config(
    const std::uint64_t timestamp_ns,
    const std::uint32_t round_id
)
{
    return ssr::StartConfig{
        .first_round_id = round_id,
        .first_round_timestamp_ns = timestamp_ns,
        .first_run_id = 0,
    };
}

void require_node_rolled_back(
    const ssr::NodeAgent& node,
    const ssr::MockDataplaneBackend& backend,
    const std::string_view node_name
)
{
    require(
        node.state() == ssr::NodeAgentState::Idle,
        std::string(node_name) + " should be in Idle state after rollback"
    );

    require(
        !node.session_id().has_value(),
        std::string(node_name) + " should not have an active session after rollback"
    );

    const auto status = backend.status();

    require(
        !status.running,
        std::string(node_name) + " dataplane should not be running after rollback"
    );

    require(
        !status.config_valid,
        std::string(node_name) + " dataplane should not have valid configuration after rollback"
    );

    require(
        !status.sync_valid,
        std::string(node_name) + " dataplane should not have valid synchronization after rollback"
    );
}

//=======================================================
//                  Test cases
//=======================================================

void test_normal_cluster_lifecycle()
{
    ssr::MockDataplaneBackend backend0;
    ssr::MockDataplaneBackend backend1;
    ssr::MockDataplaneBackend backend2;

    ssr::NodeAgent node0(0, backend0);
    ssr::NodeAgent node1(1, backend1);
    ssr::NodeAgent node2(2, backend2);

    ssr::StandaloneCoordinator coordinator(3);

    // Registration order does not need to match node ID order
    coordinator.register_node(node1);
    coordinator.register_node(node0);
    coordinator.register_node(node2);

    require(
        coordinator.registered_node_count() == 3,
        "Expected 3 registered nodes"
    );

    require(
        coordinator.state() == ssr::CoordinatorState::Idle,
        "Expected coordinator state to be Idle after all nodes registered"
    );

    const auto cluster_config = make_cluster_config();

    const auto session_id = make_session_id();

    coordinator.prepare_session(
        session_id,
        cluster_config,
        make_sync_result()
    );

    require(
        node0.state() == ssr::NodeAgentState::Ready &&
        node1.state() == ssr::NodeAgentState::Ready &&
        node2.state() == ssr::NodeAgentState::Ready,
        "All nodes must become Ready after prepare_session"
    );

    require(
        backend0.status().state == ssr::DataplaneState::Synchronized &&
        backend1.status().state == ssr::DataplaneState::Synchronized &&
        backend2.status().state == ssr::DataplaneState::Synchronized,
        "All nodes must have Synchronized dataplane state after prepare_session"
    );

    require(
        backend0.config()->replica_id == 0 &&
        backend1.config()->replica_id == 1 &&
        backend2.config()->replica_id == 2,
        "All nodes must have correct replica_id in their dataplane config after prepare_session"
    );

    coordinator.start_session(make_start_config(1000, 42));

    require(
        coordinator.state() == ssr::CoordinatorState::Running,
        "Expected coordinator state to be Running after start_session"
    );

    require(
        backend0.status().running &&
        backend1.status().running &&
        backend2.status().running,
        "All nodes must have running dataplane state after start_session"
    );

    coordinator.stop_session();

    require(
        coordinator.state() == ssr::CoordinatorState::Stopped,
        "Expected coordinator state to be Stopped after stop_session"
    );

    require(
        node0.state() == ssr::NodeAgentState::Stopped &&
        node1.state() == ssr::NodeAgentState::Stopped &&
        node2.state() == ssr::NodeAgentState::Stopped,
        "All nodes must have Stopped state after stop_session"
    );

    // Restart the same session without reset/configure
    coordinator.start_session(make_start_config(2000, 43));

    require(
        coordinator.state() == ssr::CoordinatorState::Running,
        "Expected coordinator state to be Running after restarting session"
    );

    coordinator.stop_session();
    coordinator.reset();

    require(
        coordinator.state() == ssr::CoordinatorState::Idle,
        "Expected coordinator state to be Idle after reset"
    );

    require(
        node0.state() == ssr::NodeAgentState::Idle &&
        node1.state() == ssr::NodeAgentState::Idle &&
        node2.state() == ssr::NodeAgentState::Idle,
        "All nodes must have Idle state after reset"
    );
}

void test_duplicate_node_rejected()
{
    ssr::MockDataplaneBackend backend0;
    ssr::MockDataplaneBackend duplicate_backend0;

    ssr::NodeAgent node0(0, backend0);
    ssr::NodeAgent duplicate_node0(0, duplicate_backend0);

    ssr::StandaloneCoordinator coordinator(3);

    coordinator.register_node(node0);
    require_throws<ssr::ClusterControlError>(
        [&]() { coordinator.register_node(duplicate_node0); },
        "Expected duplicate node registration to throw ClusterControlError"
    );
}

void test_missing_node_rejected()
{
    ssr::MockDataplaneBackend backend0;
    ssr::MockDataplaneBackend backend1;

    ssr::NodeAgent node0(0, backend0);
    ssr::NodeAgent node1(1, backend1);

    ssr::StandaloneCoordinator coordinator(3);

    coordinator.register_node(node0);
    coordinator.register_node(node1);

    require_throws<ssr::ClusterControlError>(
        [&]() {
            coordinator.prepare_session(
                make_session_id(),
                make_cluster_config(),
                make_sync_result()
            );
        },
        "Expected prepare_session with missing node to throw ClusterControlError"
    );

    require(
        coordinator.state() == ssr::CoordinatorState::CollectingNodes,
        "Expected coordinator state to remain CollectingNodes after failed prepare_session"
    );
}

void test_prepare_failure_rolls_back_cluster()
{
    ssr::MockDataplaneBackend backend0;
    ssr::MockDataplaneBackend backend1;
    ssr::MockDataplaneBackend backend2;

    ssr::NodeAgent node0(0, backend0);
    ssr::NodeAgent node1(1, backend1);
    ssr::NodeAgent node2(2, backend2);

    ssr::StandaloneCoordinator coordinator(3);

    coordinator.register_node(node0);
    coordinator.register_node(node1);
    coordinator.register_node(node2);

    // Node 0 will finish prepare successfully.
    // Node 1 will fail during configure
    // Node 2 will not have started prepare yet.
    backend1.fail_next(ssr::MockFailurePoint::Configure);

    require_throws<ssr::DataplaneError>(
        [&]() {
            coordinator.prepare_session(
                make_session_id(),
                make_cluster_config(),
                make_sync_result()
            );
        },
        "Expected prepare_session to throw due to injected failure"
    );

    require(
        coordinator.state() == ssr::CoordinatorState::Failed,
        "Expected coordinator state to be Failed after prepare_session failure"
    );

    require(
        !coordinator.current_session().has_value(),
        "Expected coordinator to have no current session after prepare_session failure" 
    );

    require_node_rolled_back(node0, backend0, "Node 0");
    require_node_rolled_back(node1, backend1, "Node 1");
    require_node_rolled_back(node2, backend2, "Node 2");

    // explicit reset acknowledges the failed experiment and permits a new session to be prepared.
    coordinator.reset();

    require(
        coordinator.state() == ssr::CoordinatorState::Idle,
        "Expected coordinator state to be Idle after reset"
    );

    auto recovery_session = make_session_id();

    recovery_session.low ^= 1ULL;

    coordinator.prepare_session(
        recovery_session,
        make_cluster_config(),
        make_sync_result()
    );

    require(
        coordinator.state() == ssr::CoordinatorState::Ready,
        "Expected coordinator state to be Ready after successful prepare_session"
    );

    coordinator.start_session(make_start_config(1000, 42));

    require(
        coordinator.state() == ssr::CoordinatorState::Running,
        "Expected coordinator state to be Running after start_session"
    );

    coordinator.stop_session();

    require(
        coordinator.state() == ssr::CoordinatorState::Stopped,
        "Expected coordinator state to be Stopped after stop_session"
    );
}


void test_start_failure_rolls_back_cluster()
{
    ssr::MockDataplaneBackend backend0;
    ssr::MockDataplaneBackend backend1;
    ssr::MockDataplaneBackend backend2;

    ssr::NodeAgent node0(0, backend0);
    ssr::NodeAgent node1(1, backend1);
    ssr::NodeAgent node2(2, backend2);

    ssr::StandaloneCoordinator coordinator(3);

    coordinator.register_node(node0);
    coordinator.register_node(node1);
    coordinator.register_node(node2);

    coordinator.prepare_session(
        make_session_id(),
        make_cluster_config(),
        make_sync_result()
    );

    // Node 1 will fail during start
    backend1.fail_next(ssr::MockFailurePoint::Start);

    require_throws<ssr::DataplaneError>(
        [&]() {
            coordinator.start_session(make_start_config(1000, 42));
        },
        "Expected start_session to throw due to injected failure"
    );

    require(
        coordinator.state() == ssr::CoordinatorState::Failed,
        "Expected coordinator state to be Failed after start_session failure"
    );

    require(
        !coordinator.current_session().has_value(),
        "Expected coordinator to have no current session after start_session failure" 
    );

    require_node_rolled_back(node0, backend0, "Node 0");
    require_node_rolled_back(node1, backend1, "Node 1");
    require_node_rolled_back(node2, backend2, "Node 2");
}

} // namespace

int main()
{
    try {
        std::cout << "Running standalone coordinator tests..." << std::endl;
        std::cout << "[Test] normal cluster lifecycle" << std::endl;
        test_normal_cluster_lifecycle();

        std::cout << "[Test] duplicate node registration rejected" << std::endl;
        test_duplicate_node_rejected();

        std::cout << "[Test] missing node registration rejected" << std::endl;
        test_missing_node_rejected();

        std::cout << "[Test] prepare failure rolls back cluster" << std::endl;
        test_prepare_failure_rolls_back_cluster();

        std::cout << "[Test] start failure rolls back cluster" << std::endl;
        test_start_failure_rolls_back_cluster();

        std::cout << "All tests passed!" << std::endl;
        return 0;
    }
    catch (const std::exception& e) {
        std::cerr << "Test failed: " << e.what() << std::endl;
        return 1;
    }
}
