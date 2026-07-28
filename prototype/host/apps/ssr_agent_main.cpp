#include "ssr/coordinator_event_client.hpp"
#include "ssr/mock_dataplane.hpp"
#include "ssr/node_agent.hpp"
#include "ssr/node_agent_service.hpp"

#include <grpcpp/grpcpp.h>

#include <cstdint>
#include <exception>
#include <iostream>
#include <limits>
#include <memory>
#include <stdexcept>
#include <string>
#include <string_view>

namespace {

struct AgentOptions {
    std::uint32_t node_id = 0;
    std::string listen_address;
    std::string coordinator_address;
};

void print_usage_and_exit(
    const std::string_view program,
    const int exit_code
)
{
    std::cerr
        << "Usage:\n"
        << "  " << program 
        << " --node-id <node_id>"
        << " --listen <ip:port>"
        << " --coordinator <ip:port>\n"
        << "Example:\n"
        << "  " << program
        << " --node-id 1"
        << " --listen 0.0.0.0:50051"
        << " --coordinator 127.0.0.1:50052\n";

    std::exit(exit_code);
}

AgentOptions parse_options(
    const int argc,
    char* argv[]
)
{
    AgentOptions options{};

    for (int index = 1; index < argc; ++index) {
        const std::string_view arg = argv[index];

        const auto require_value = [&](const std::string_view option) -> std::string {
            if (index + 1 >= argc) {
                throw std::invalid_argument(
                    std::string("Missing value for option '") + std::string(option) + "'"
                );
            }

            ++index;
            return argv[index];
        };

        if (arg == "--node-id") {
            options.node_id = static_cast<std::uint32_t>(std::stoul(require_value(arg)));
        } else if (arg == "--listen") {
            options.listen_address = require_value(arg);
        } else if (arg == "--coordinator") {
            options.coordinator_address = require_value(arg);
        } else if (arg == "--help" || arg == "-h") {
            print_usage_and_exit(argv[0], 0);
        } else {
            throw std::invalid_argument(
                std::string("Unknown option: '") + std::string(arg) + "'"
            );
        }
    }

    if (options.listen_address.empty()) {
        throw std::invalid_argument("Missing required option: --listen");
    }

    if (options.coordinator_address.empty()) {
        throw std::invalid_argument("Missing required option: --coordinator");
    }

    return options;
}
}// namespace

int main(const int argc, char* argv[])
{
    try {
        const AgentOptions options = parse_options(argc, argv);

        const auto node_id = static_cast<ssr::NodeId>(options.node_id);
        ssr::MockDataplaneBackend dataplane_backend;
        ssr::NodeAgent node_agent(node_id, dataplane_backend);
        ssr::CoordinatorEventClient event_client(node_id, options.coordinator_address);
        ssr::NodeAgentServiceImpl service(node_agent, event_client);

        grpc::ServerBuilder builder;

        int selected_port = 0;
        builder.AddListeningPort(options.listen_address, grpc::InsecureServerCredentials(), &selected_port);
        builder.RegisterService(&service);

        std::unique_ptr<grpc::Server> server = builder.BuildAndStart();

        if (server == nullptr || selected_port <= 0) {
            throw std::runtime_error("Failed to start gRPC server");
        }

        std::cout
            << "SSR Node Agent started\n"
            << "  Node ID: " << node_id << "\n"
            << "  Listening on: " << options.listen_address << "\n"
            << "  Coordinator: " << options.coordinator_address << "\n";
        
        server->Wait();
    } catch (const std::exception& ex) {
        std::cerr
            << "ssr-agent failed: "
            << ex.what() << "\n"; 
        return 1;
    }
}
