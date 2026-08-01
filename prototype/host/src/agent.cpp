#include "ssr/ssr.h"
#include "ssr/agent.hpp"
#include "ssr/agent_dataplane_backend_mock.hpp"

#include <stdexcept>

namespace ssr {

void SSRAgent::prepare(
    const SessionId& session_id,
    const RunConfig& run_config
)
{
    printf("SSRAgent::[%u]::prepare called with session_id: %lu\n", node_id_, session_id.high);
    if (state_ != AgentState::Idle &&
        state_ != AgentState::Stopped)
    {
        throw std::runtime_error(
            "Cannot prepare a new session while in state " +
            std::to_string(static_cast<std::uint8_t>(state_))
        );
    }
    
    try {
        if (backend_.status().state == DataplaneState::Closed) {
            backend_.open();
        }
        
        backend_.configure(run_config);

        // If all operations succeed, transition to Configured state
        state_ = AgentState::Configured;
    }
    catch (const std::exception& e) {
        state_ = AgentState::Idle;
        throw;
    }
}

void SSRAgent::start(
    const SessionId& session_id
)
{
    printf("SSRAgent::[%u]::start called with session_id: %lu\n", node_id_, session_id.high);
    if (state_ != AgentState::Configured) {
        throw std::runtime_error(
            "Cannot start a session while in state " +
            std::to_string(static_cast<std::uint8_t>(state_))
        );
    }

    try {
        backend_.start();
        state_ = AgentState::Running;
    }
    catch (const std::exception& e) {
        state_ = AgentState::Idle;
        throw;
    }
}

void SSRAgent::stop(
    const SessionId& session_id
)
{
    printf("SSRAgent::[%u]::stop called with session_id: %lu\n", node_id_, session_id.high);
    if (state_ != AgentState::Running) {
        throw std::runtime_error(
            "Cannot stop a session while in state " +
            std::to_string(static_cast<std::uint8_t>(state_))
        );
    }

    try {
        backend_.stop();
        state_ = AgentState::Stopped;
    }
    catch (const std::exception& e) {
        state_ = AgentState::Idle;
        throw;
    }
}

} // namespace ssr
