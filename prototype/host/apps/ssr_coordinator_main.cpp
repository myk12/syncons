#include "ssr/ssr.h"
#include "ssr/coordinator.hpp"
#include "ssr/proto_conversion.hpp"
#include "ssr/agent.hpp"


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
#include <fstream>
#include <stdexcept>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace {

struct CoordinatorConfig {
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

/*
 * Example configuration file:
    [Coordinator]
    address = 127.0.0.1:50050

    [Agent]
    replica0 = 0.0.0.0:50051
    mac0 = 00:00:00:00:00:01
    replica1 = 0.0.0.0:50053
    mac1 = 00:00:00:00:00:02
    replica2 = 0.0.0.0:50055
    mac2 = 00:00:00:00:00:03

    [Dataplane]
    round_length_ns = 2000
 *
 */
bool parse_config_file(
    const std::string& file_path,
    CoordinatorConfig& config
)
{
    // check if file exists
    std::ifstream file(file_path);
    if (!file.is_open()) {
        printf("Configuration file '%s' does not exist or cannot be opened\n", file_path.c_str());
        return false;
    }

    // parse file line by line
    std::string line;
    std::string current_section;
    while (std::getline(file, line)) {
        // trim whitespace
        line.erase(0, line.find_first_not_of(" \t\n\r"));
        line.erase(line.find_last_not_of(" \t\n\r") + 1);
        // erase all whitespace
        line.erase(std::remove_if(line.begin(), line.end(), ::isspace), line.end());

        // skip empty lines and comments
        if (line.empty() || line[0] == '#') {
            continue;
        } else if (line[0] == '[' && line.back() == ']') {
            current_section = line.substr(1, line.size() - 2);
        } else if (current_section == "Coordinator") {
            // Parse Coordinator options
            if (line.rfind("address", 0) == 0) {
                const std::string value = line.substr(line.find('=') + 1);
                config.listen_address = value;
            }
        } else if (current_section == "Agent") {
            // Parse Agent options
            if (line.rfind("replica", 0) == 0) {
                const std::string value = line.substr(line.find('=') + 1);
                const std::string id_str = line.substr(7, 1); // "replica" is 7 characters
                const std::uint32_t node_id = parse_u32(id_str, "replica ID");
                printf("Parsed replica ID %u with address %s\n", node_id, value.c_str());
                config.node_addresses[node_id] = value;
            } else if (line.rfind("mac", 0) == 0) {
                const std::string value = line.substr(line.find('=') + 1);
                const std::string id_str = line.substr(3, 1); // "mac" is 3 characters
                const std::uint32_t node_id = parse_u32(id_str, "mac ID");
                printf("Parsed mac ID %u with address %s\n", node_id, value.c_str());
                config.node_macs[node_id] = value;
            }
        } else if (current_section == "Dataplane") {
            // Parse Dataplane options
            if (line.rfind("round_length_ns", 0) == 0) {
                const std::string value = line.substr(line.find('=') + 1);
                config.round_length_ns = parse_u32(value, "round_length_ns");
            }
        } else {
            throw std::invalid_argument(
                "Unknown section in configuration file: '" + current_section + "'"
            );
        }
    }

    return true;
}

[[noreturn]]
void print_usage_and_exit(const char* program_name, int exit_code)
{
    std::cerr << "Usage: " << program_name << " [config]\n"
              << "Options:\n"
              << "  --file <path>               Path to configuration file\n"
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

CoordinatorConfig parse_options(int argc, char* argv[])
{
    CoordinatorConfig config;

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

        if (arg == "--file") {
            const std::string file_path = require_value(arg);
            if (!parse_config_file(file_path, config)) {
                throw std::invalid_argument(
                    "Failed to parse configuration file: " + file_path
                );
            }
        } else if (arg == "--listen") {
            config.listen_address = require_value(arg);
        } else if (arg == "--node") {
            const auto [node_id, address] = parse_id_value(require_value(arg), arg);

            if (!config.node_addresses.emplace(node_id, std::move(address)).second) {
                throw std::invalid_argument(
                    "Duplicate node ID in --node config: " + std::to_string(node_id)
                );
            }
        } else if (arg == "--mac") {
            const auto [node_id, mac_str] = parse_id_value(require_value(arg), arg);

            if (!config.node_macs.emplace(node_id, std::move(mac_str)).second) {
                throw std::invalid_argument(
                    "Duplicate node ID in --mac config: " + std::to_string(node_id)
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
            config.ethernet_type = static_cast<std::uint16_t>(value);
        } else if (arg == "--help" || arg == "-h") {
            print_usage_and_exit(argv[0], 0);
        } else {
            throw std::invalid_argument(
                std::string("Unknown option: ") + std::string(arg)
            );
        }
    }

    if (config.listen_address.empty()) {
        throw std::invalid_argument("Missing required option: --listen");
    }

    if (config.node_addresses.empty()) {
        throw std::invalid_argument("At least one --node option must be specified");
    }

    if (config.node_addresses.size() != config.node_macs.size()) {
        throw std::invalid_argument(
            "The number of --node config must match the number of --mac config"
        );
    }

    for (std::uint32_t expected = 0; expected < config.node_addresses.size(); ++expected) {
        printf("Checking for node ID %u in configuration\n", expected);
        if (!config.node_addresses.contains(expected) ||
            !config.node_macs.contains(expected)) {
            throw std::invalid_argument(
                "Missing --node or --mac option for node ID: " + std::to_string(expected)
            );
        }
    }

    return config;
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
        case ssr::CoordinatorState::Idle: return "Idle";
        case ssr::CoordinatorState::Ready: return "Ready";
        case ssr::CoordinatorState::Running: return "Running";
        case ssr::CoordinatorState::Stopped: return "Stopped";
        default: return "Unknown";
    }
}

void print_results(const std::vector<ssr::AgentRPCResult>& results)
{
    for (const auto& result : results) {
        std::cout << "Node ID: " << result.node_id
                  << ", Status: " << (result.ok() ? "OK" : "Error")
                  << ", Message: " << result.message << "\n";
        
        if (!result.ok()) {
            std::cout << "  gRPC Status Code: " << static_cast<int>(result.status_code) << "\n";
        }

        std::cout << "  Node State: " << ssr::control::v1::AgentState_Name(result.reply.state()) << "\n";
        if (result.reply.has_dataplane_status()) {
            std::cout << "  Dataplane State: " << ssr::control::v1::DataplaneState_Name(result.reply.dataplane_status().state()) << "\n";
        }
    }
}

void print_operation(const ssr::ClusterOptResult& operation_result)
{
    std::cout << "Final Coordinator State: " << coordinator_state_name(operation_result.final_state) << "\n";
    std::cout << "Node Results:\n";
    print_results(operation_result.results);
}

} // namespace

int main(const int argc, char* argv[])
{
    printf("SSR Coordinator starting...\n");
    try {
        const CoordinatorConfig config = parse_options(argc, argv);

        std::vector<ssr::AgentEndpoint> endpoints;
        endpoints.reserve(config.node_addresses.size());

        ssr::ClusterConfig cluster_config{};
        cluster_config.ethernet_type = config.ethernet_type;
        cluster_config.round_length_ns = config.round_length_ns;

        for (const auto& [node_id, address] : config.node_addresses) {
            endpoints.push_back(
                ssr::AgentEndpoint{
                    .node_id = node_id,
                    .address = address,
                    .ip_address = address.substr(0, address.find(':')),
                    .port = static_cast<std::uint16_t>(std::stoi(address.substr(address.find(':') + 1))),
                    .mac_address = config.node_macs.at(node_id)
                }
            );

            cluster_config.replica_macs.push_back(parse_mac(config.node_macs.at(node_id)));
        }

        cluster_config.validate();

        ssr::RunConfig run_config{};
        run_config.run_id = 1; // This could be generated or configured as needed
        run_config.start_time_ns = 7000; // This will be set when starting the run
        run_config.replica_num = static_cast<std::uint32_t>(cluster_config.replica_count());
        run_config.round_length_ns = cluster_config.round_length_ns;

        ssr::SSRCoordinator coordinator(std::move(endpoints));
        std::cout << "SSR Coordinator started\n"
                    << "  listen: " << config.listen_address << "\n"
                    << "  nodes: " << endpoints.size() << "\n\n"
                    << "Commands:\n"
                    << "  status\n"
                    << "  prepare\n"
                    << "  start\n"
                    << "  stop\n"
                    << "  quit\n";
        
        std::string command;

        while (std::cout << "ssr> " && std::getline(std::cin, command)) {
            if (command == "quit" || command == "exit") {
                break;
            }

            if (command.empty()) {
                continue;
            }

            if (command == "help") {
                std::cout << "Available commands:\n"
                          << "  status  - Get the status of the coordinator and agents\n"
                          << "  prepare - Prepare the agents for a run\n"
                          << "  start   - Start the run on all agents\n"
                          << "  stop    - Stop the run on all agents\n"
                          << "  quit    - Exit the coordinator\n";
                continue;
            }

            if (command == "status") {
                std::cout << "coordinator-state=" << coordinator_state_name(coordinator.state()) << "\n";
                print_results(coordinator.agents_get_status());
                continue;
            }

            switch (coordinator.state()) {
                case ssr::CoordinatorState::Idle:
                    if (command == "prepare") {
                        print_operation(coordinator.agents_prepare(create_session_id(), run_config));
                    } else {
                        std::cerr << "Invalid command in Idle state. Only 'prepare', 'status', or 'quit' are allowed.\n";
                    }
                    break;
                case ssr::CoordinatorState::Ready:
                    if (command == "start") {
                        print_operation(coordinator.agents_start());
                    } else if (command == "stop") {
                        print_operation(coordinator.agents_stop());
                    } else {
                        std::cerr << "Invalid command in Ready state. Only 'start', 'stop', 'status', or 'quit' are allowed.\n";
                    }
                    break;
                case ssr::CoordinatorState::Running:
                    if (command == "stop") {
                        print_operation(coordinator.agents_stop());
                    } else {
                        std::cerr << "Invalid command in Running state. Only 'stop', 'status', or 'quit' are allowed.\n";
                    }
                    break;
                case ssr::CoordinatorState::Stopped:
                

                    break;
                default:
                    std::cerr << "Unknown coordinator state.\n";
                    continue;
            }
        }

        return 0;
    } catch (const std::exception& ex) {
        std::cerr << "ssr-coordinator failed: " << ex.what() << "\n";
        return 1;
    }
}
