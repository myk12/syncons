#include "ssr/coordinator_service.hpp"

#include <exception>
#include <stdexcept>
#include <utility>

namespace ssr {

CoordinatorServiceImpl::CoordinatorServiceImpl(
    NodeEventStore& event_store,
    EventObserver observer
)
    : event_store_(event_store),
      observer_(std::move(observer))
{
}

grpc::Status CoordinatorServiceImpl::ReportNodeEvent(
    grpc::ServerContext* context,
    const control::v1::NodeEventReport* request,
    control::v1::ReportNodeEventReply* reply
)
{
    static_cast<void>(context); // Unused parameter

    if (request == nullptr || reply == nullptr) {
        return grpc::Status(grpc::StatusCode::INVALID_ARGUMENT, "Request or reply pointer is null");
    }

    if (request->sequence_number() == 0) {
        return grpc::Status(grpc::StatusCode::INVALID_ARGUMENT, "Event report sequence number must be greater than zero");
    }

    if (request->event() == control::v1::NODE_EVENT_UNSPECIFIED) {
        return grpc::Status(grpc::StatusCode::INVALID_ARGUMENT, "Event report event type must be specified");
    }

    try {
        const NodeEventAcceptResult accept_result = event_store_.accept(*request);

        reply->set_ack_sequence_number(accept_result.acknowledged_sequence_number);

        if (accept_result.newly_accepted && observer_) {
            observer_(*request);
        }

        return grpc::Status::OK;
    } catch (const std::invalid_argument& e) {
        return grpc::Status(grpc::StatusCode::INVALID_ARGUMENT, e.what());
    } catch (const std::exception& e) {
        return grpc::Status(grpc::StatusCode::INTERNAL, e.what());
    }
}

} // namespace ssr