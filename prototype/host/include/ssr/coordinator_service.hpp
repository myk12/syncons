#pragma once

#include "ssr/node_event_store.hpp"
#include "ssr_control.grpc.pb.h"

#include <functional>

namespace ssr {

class CoordinatorServiceImpl final : public control::v1::CoordinatorService::Service {
public:
    using EventObserver = std::function<void(const control::v1::NodeEventReport&)>;

    explicit CoordinatorServiceImpl(NodeEventStore& event_store, EventObserver observer = {});

    grpc::Status ReportNodeEvent(
        grpc::ServerContext* context,
        const control::v1::NodeEventReport* request,
        control::v1::ReportNodeEventReply* reply) override;
    
private:
    NodeEventStore& event_store_;
    EventObserver observer_;
};

} // namespace ssr
