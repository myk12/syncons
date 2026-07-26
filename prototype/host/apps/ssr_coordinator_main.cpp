#include "ssr/cluster_coordinator.hpp"
#include "ssr/coordinator_service.hpp"
#include "ssr/node_event_store.hpp"

#include <grpcpp/grpcpp.h>

#include <algorithm>
#include <array>
#include <chrono>
#include <cstdint>
#include <exception>
#include <iomanip>
#include <iostream>
#include <limits>
#include <map>
#include <memory>
#include <random>
#include <sstream>
#include <stdexcept>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace {

struct CoordinatorOptions {
    std::string listen_address;
    std::map<std::uint32_t, std::string> node_addresses;
    std::map<std::uint32_t, std::string> node_macs;
    std::uint16_t ethernet_type = 0x88B5;
    std::uint32_t round_length_ns = 2000;
};

std::uint32_t parse_u32(
    const std::string& text,
    const std::string_view option_name
)
{
    std::size_t parsed_length = 0;

    const unsigned long value = std::stoul(text, &parsed_length, 0);

    if (parsed_length != text.size() || value > std::numeric_limits<std::uint32_t>::max()) {
        throw std::invalid_argument(
            std::string("Invalid value for option '") + std::string(option_name) +
            "': '" + std::string(text) + "' is not a valid unsigned integer"
        );
    }

    return static_cast<std::uint32_t>(value);
}

std::pair<std::uint32_t, std::string>
parse_id_value(
    const std::string& text,
    const std::string_view option_name
)
{
    const std::size_t delimiter = text.find('=');

    if (delimiter == std::string::npos ||
        delimiter == 0 || delimiter == text.size() - 1) {
        throw std::invalid_argument(
            std::string("Invalid value for option '") + std::string(option_name) +
            "': '" + std::string(text) + "' is not in the format <id>=<value>"
        );
    }

    return {
        parse_u32(text.substr(0, delimiter), option_name),
        text.substr(delimiter + 1)
    };
}

ssr::MacAddress parse_mac(
    const std::string& text
)
{
    ssr::MacAddress result{};
    std::istringstream stream(text);
    std::string component;

    for (std::size_t index = 0; index < result.bytes.size(); ++index) {
        if (!std::getline(stream, component, ':')) {
            throw std::invalid_argument(
                "Invalid MAC address: '" + std::string(text) + "' is not in the format XX:XX:XX:XX:XX:XX"
            );
        }

        if (component.size() != 2) {
            throw std::invalid_argument(
                "Invalid MAC address: '" + std::string(text) + "' is not in the format XX:XX:XX:XX:XX:XX"
            );
        }

        const std::uint32_t value = parse_u32("0x" + component, "MAC address component");

        if (value > 0xFF) {
            throw std::invalid_argument(
                "Invalid MAC address: '" + std::string(text) + "' contains a component out of range"
            );
        }

        result.bytes[index] = static_cast<std::uint8_t>(value);
    }

    if (std::getline(stream, component, ':')) {
        throw std::invalid_argument(
            "Invalid MAC address: '" + std::string(text) + "' is not in the format XX:XX:XX:XX:XX:XX"
        );
    }

    if (result.is_zero()) {
        throw std::invalid_argument(
            "Invalid MAC address: '" + std::string(text) + "' is the zero address"
        );
    }

    return result;
}

[[noreturn]]
void print_usage_and_exit(const char* program_name, int exit_code)
{
    std::cerr << "Usage: " << program_name << " [options]\n"
              << "Options:\n"
              << "  --listen <address>          Address to listen on for gRPC requests\n"
              << "  --node <id>=<address>       Node ID and address of a node agent (can be specified multiple times)\n"
              << "  --mac <id>=<mac>            Node ID and MAC address of a node (can be specified multiple times)\n"
              << "  --ethernet-type <type>      Ethernet type for SSR packets (default: 0x88B5)\n"
              << "  --round-length <ns>         Round length in nanoseconds (default: 2000)\n"
              << "  --help, -h                  Show this help message\n"
              << "Example:\n"
              << "  " << program_name
              << " --listen 0.0.0.0:50051"
              << " --node 0=10.0.0.11:50051"
              << " --mac 0=00:11:22:33:44:55"
              << " --node 1=10.0.0.12:50051"
              << " --mac 1=00:11:22:33:44:56\n";

    std::exit(exit_code);
}

CoordinatorOptions parse_options(int argc, char* argv[])
{
    CoordinatorOptions options;

    for (int index = 1; index < argc; ++index) {
        const std::string_view arg = argv[index];

        const auto require_value =
            [&](const std::string_view option) -> std::string {
                if (index + 1 >= argc) {
                    throw std::invalid_argument(
                        std::string("Missing value for option ")+ std::string(option)
                    );
                }
                ++index;
                return argv[index];
            };

        if (arg == "--listen") {
            options.listen_address = require_value(arg);
        } else if (arg == "--node") {
            const auto [node_id, address] = parse_id_value(require_value(arg), arg);
            
            if (!options.node_addresses.emplace(node_id, std::move(address)).second) {
                throw std::invalid_argument(
                    "Duplicate node ID in --node options: " + std::to_string(node_id)
                );
            }
        } else if (arg == "--mac") {
            const auto [node_id, mac_str] = parse_id_value(require_value(arg), arg);

            if (!options.node_macs.emplace(node_id, std::move(mac_str)).second) {
                throw std::invalid_argument(
                    "Duplicate node ID in --mac options: " + std::to_string(node_id)
                );
            }
        } else if (arg == "--ethernet-type") {
            const std::uint32_t value = parse_u32(require_value(arg), arg);

            if (value > std::numeric_limits<std::uint16_t>::max()) {
                throw std::invalid_argument(
                    "Invalid value for option '" + std::string(arg) +
                    "': '" + std::to_string(value) + "' is out of range for a 16-bit unsigned integer"
                );
            }

            options.ethernet_type = static_cast<std::uint16_t>(value);
        } else if (arg == "--round-length") {
            const std::uint32_t value = parse_u32(require_value(arg), arg);
            options.round_length_ns = value;
        } else if (arg == "--help" || arg == "-h") {
            print_usage_and_exit(argv[0], 0);
        } else {
            throw std::invalid_argument(
                std::string("Unknown option: ") + std::string(arg)
            );
        }
    }

    if (options.listen_address.empty()) {
        throw std::invalid_argument("Missing required option: --listen");
    }

    if (options.node_addresses.empty()) {
        throw std::invalid_argument("At least one --node option must be specified");
    }

    if (options.node_addresses.size() != options.node_macs.size()) {
        throw std::invalid_argument(
            "The number of --node options must match the number of --mac options"
        );
    }

    for (std::uint32_t expected = 0; expected < options.node_addresses.size(); ++expected) {
        if (!options.node_addresses.contains(expected) ||
            !options.node_macs.contains(expected)) {
            throw std::invalid_argument(
                "Missing --node or --mac option for node ID: " + std::to_string(expected)
            );
        }
    }

    return options;
}

ssr::SessionId create_session_id()
{
    std::random_device rd;
    std::mt19937_64 gen(rd());
    std::uniform_int_distribution<std::uint64_t> dis;

    ssr::SessionId session_id{};
    session_id.high = dis(gen);
    session_id.low = dis(gen);

    return session_id;
}

const char* coordinator_state_name(const ssr::CoordinatorState state)
{
    switch (state) {
        case ssr::CoordinatorState::CollectingNodes: return "CollectingNodes";
        case ssr::CoordinatorState::Idle: return "Idle";
        case ssr::CoordinatorState::Preparing: return "Preparing";
        case ssr::CoordinatorState::Ready: return "Ready";
        case ssr::CoordinatorState::Running: return "Running";
        case ssr::CoordinatorState::Stopping: return "Stopping";
        case ssr::CoordinatorState::Stopped: return "Stopped";
        case ssr::CoordinatorState::Resetting: return "Resetting";
        case ssr::CoordinatorState::Failed: return "Failed";
        default: return "Unknown";
    }
}

void print_results(const std::vector<ssr::NodeRpcResult>& results)
{
    for (const auto& result : results) {
        std::cout << "Node ID: " << result.node_id
                  << ", Status: " << (result.ok() ? "OK" : "Error")
                  << ", Message: " << result.message << "\n";
        
        if (!result.ok()) {
            std::cout << "  gRPC Status Code: " << static_cast<int>(result.status_code) << "\n";
        }

        std::cout << "  Node State: " << ssr::control::v1::NodeState_Name(result.reply.state()) << "\n";
        if (result.reply.has_dataplane_status()) {
            std::cout << "  Dataplane State: " << ssr::control::v1::DataplaneState_Name(result.reply.dataplane_status().state()) << "\n";
        }
    }
}

void print_operation(const ssr::ClusterOperationResult& operation_result)
{
    std::cout << "Final Coordinator State: " << coordinator_state_name(operation_result.final_state) << "\n";
    std::cout << "Node Results:\n";
    print_results(operation_result.node_results);

    if (!operation_result.rollback_results.empty()) {
        std::cout << "Rollback Results:\n";
        print_results(operation_result.rollback_results);
    }
}

} // namespace

int main(const int argc, char* argv[])
{
    try {
        const CoordinatorOptions options = parse_options(argc, argv);

        std::vector<ssr::AgentEndpoint> endpoints;
        endpoints.reserve(options.node_addresses.size());

        ssr::ClusterConfig cluster_config{};
        cluster_config.ethernet_type = options.ethernet_type;
        cluster_config.round_length_ns = options.round_length_ns;

        for (const auto& [node_id, address] : options.node_addresses) {
            endpoints.push_back(
                ssr::AgentEndpoint{
                    .node_id = node_id,
                    .address = address
                }
            );

            cluster_config.replica_macs.push_back(parse_mac(options.node_macs.at(node_id)));
        }

        cluster_config.validate();

        ssr::NodeSyncResults sync_results;

        for (const auto& endpoint : endpoints) {
            sync_results.emplace(
                endpoint.node_id, 
                ssr::SyncResult{
                    .synchronized = true,
                    .estimated_offset_ns = 0,
                    .uncertainty_ns = 0
                });
        }

        ssr::ClusterCoordinator coordinator(std::move(endpoints));

        ssr::NodeEventStore event_store;
        ssr::CoordinatorServiceImpl service(
            event_store,
            [&coordinator](
                const ssr::control::v1::NodeEventReport& event_report
            ) {
                coordinator.handle_node_event(event_report);
            }
        );

        grpc::ServerBuilder builder;
        int selected_port = 0;

        builder.AddListeningPort(options.listen_address, grpc::InsecureServerCredentials(), &selected_port);

        builder.RegisterService(&service);

        std::unique_ptr<grpc::Server> server(builder.BuildAndStart());

        if (server == nullptr || selected_port <= 0) {
            throw std::runtime_error("Failed to start gRPC server on address: " + options.listen_address);
        }

        std::cout << "SSR Coordinator started\n"
                    << "  listen: " << options.listen_address << "\n"
                    << "  nodes: " << endpoints.size() << "\n\n"
                    << "Commands:\n"
                    << "  status\n"
                    << "  prepare\n"
                    << "  start\n"
                    << "  stop\n"
                    << "  reset\n"
                    << "  events\n"
                    << "  quit\n";
        
        std::string command;

        while (std::cout << "ssr> " && std::getline(std::cin, command)) {
            try {
                if (command == "status") {
                    std::cout << "coordinator-state=" << coordinator_state_name(coordinator.state()) << "\n";
                    print_results(coordinator.get_status());
                } else if (command == "prepare") {
                    print_operation(coordinator.prepare(create_session_id(), cluster_config, sync_results));
                } else if (command == "start") {
                    const auto now_ns = std::chrono::duration_cast<std::chrono::nanoseconds>(
                        std::chrono::system_clock::now().time_since_epoch()
                    ).count();

                    const ssr::StartConfig start_config{
                        .first_round_id = 0,
                        .first_round_timestamp_ns = static_cast<uint64_t>(now_ns) + 1000000, // Start 1 ms in the future
                        .first_run_id = 1,
                    };

                    print_operation(coordinator.start(start_config));
                } else if (command == "stop") {
                    print_operation(coordinator.stop());
                } else if (command == "reset") {
                    print_operation(coordinator.reset());
                } else if (command == "events") {
                    const auto events = event_store.history();

                    for (const auto& event : events) {
                        std::cout << "node=" << event.node_id()
                                  << ", seq=" << event.sequence_number()
                                  << ", detial=" << event.detail() << "\n";
                    }
                } else if (command == "quit" || command == "exit") {
                    break;
                } else if (!command.empty()) {
                    std::cerr << "Unknown command: " << command << "\n";
                }
            } catch (const std::exception& ex) {
                std::cerr << "Command failed: " << ex.what() << "\n";
            }
        }

        server->Shutdown();
        server->Wait();

        return 0;
    } catch (const std::exception& ex) {
        std::cerr << "ssr-coordinator failed: " << ex.what() << "\n";
        return 1;
    }
}
