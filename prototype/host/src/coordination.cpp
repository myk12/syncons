#include "ssr/coordination.hpp"

#include <string>

namespace ssr {
namespace {

void put_u16(
    std::span<std::byte> output,
    std::size_t& offset,
    const std::uint16_t value
)
{
    output[offset++] = static_cast<std::byte>((value >> 8) & 0xFF);
    output[offset++] = static_cast<std::byte>(value & 0xFF);
}

void put_u32(
    std::span<std::byte> output,
    std::size_t& offset,
    const std::uint32_t value
)
{
    output[offset++] = static_cast<std::byte>((value >> 24) & 0xFF);
    output[offset++] = static_cast<std::byte>((value >> 16) & 0xFF);
    output[offset++] = static_cast<std::byte>((value >> 8) & 0xFF);
    output[offset++] = static_cast<std::byte>(value & 0xFF);
}

void put_u64(
    std::span<std::byte> output,
    std::size_t& offset,
    const std::uint64_t value
)
{
    output[offset++] = static_cast<std::byte>((value >> 56) & 0xFF);
    output[offset++] = static_cast<std::byte>((value >> 48) & 0xFF);
    output[offset++] = static_cast<std::byte>((value >> 40) & 0xFF);
    output[offset++] = static_cast<std::byte>((value >> 32) & 0xFF);
    output[offset++] = static_cast<std::byte>((value >> 24) & 0xFF);
    output[offset++] = static_cast<std::byte>((value >> 16) & 0xFF);
    output[offset++] = static_cast<std::byte>((value >> 8) & 0xFF);
    output[offset++] = static_cast<std::byte>(value & 0xFF);
}

std::uint16_t get_u16(
    std::span<const std::byte> input,
    std::size_t& offset
)
{
    const std::uint32_t high = std::to_integer<std::uint32_t>(input[offset++]);
    const std::uint32_t low = std::to_integer<std::uint32_t>(input[offset++]);
    const std::uint32_t value = (high << 8) | low;

    return static_cast<std::uint16_t>(value);
}

std::uint32_t get_u32(
    std::span<const std::byte> input,
    std::size_t& offset
)
{
    const std::uint32_t b1 = std::to_integer<std::uint32_t>(input[offset++]);
    const std::uint32_t b2 = std::to_integer<std::uint32_t>(input[offset++]);
    const std::uint32_t b3 = std::to_integer<std::uint32_t>(input[offset++]);
    const std::uint32_t b4 = std::to_integer<std::uint32_t>(input[offset++]);

    const std::uint32_t value = (b1 << 24) | (b2 << 16) | (b3 << 8) | b4;

    return value;
}

std::uint64_t get_u64(
    std::span<const std::byte> input,
    std::size_t& offset
)
{
    const std::uint64_t b1 = std::to_integer<std::uint64_t>(input[offset++]);
    const std::uint64_t b2 = std::to_integer<std::uint64_t>(input[offset++]);
    const std::uint64_t b3 = std::to_integer<std::uint64_t>(input[offset++]);
    const std::uint64_t b4 = std::to_integer<std::uint64_t>(input[offset++]);
    const std::uint64_t b5 = std::to_integer<std::uint64_t>(input[offset++]);
    const std::uint64_t b6 = std::to_integer<std::uint64_t>(input[offset++]);
    const std::uint64_t b7 = std::to_integer<std::uint64_t>(input[offset++]);
    const std::uint64_t b8 = std::to_integer<std::uint64_t>(input[offset++]);

    const std::uint64_t value =
        (b1 << 56) | (b2 << 48) | (b3 << 40) | (b4 << 32) |
        (b5 << 24) | (b6 << 16) | (b7 << 8) | b8;

    return value;
}

bool is_valid_message_type(
    const CoordinationMessageType type
) noexcept
{
    switch (type) {
        case CoordinationMessageType::RegisterRequest:
        case CoordinationMessageType::RegisterResponse:
        case CoordinationMessageType::ConfigureRequest:
        case CoordinationMessageType::ConfigureReady:
        case CoordinationMessageType::SynchronizeRequest:
        case CoordinationMessageType::SynchronizeReady:
        case CoordinationMessageType::StartPrepare:
        case CoordinationMessageType::StartReady:
        case CoordinationMessageType::StartCommit:
        case CoordinationMessageType::StopRequest:
        case CoordinationMessageType::StopReady:
        case CoordinationMessageType::Error:
        case CoordinationMessageType::Heartbeat:
            return true;
        default:
            return false;
    }

    return false;
}

} // namespace

void CoordinationMessageHeader::validate() const
{
    if (!is_valid_message_type(type)) {
        throw CoordinationProtocolError(
            "Invalid CoordinationMessageType: " + std::to_string(static_cast<std::uint8_t>(type))
        );
    }

    if (session_id.is_zero()) {
        throw CoordinationProtocolError(
            "SessionId cannot be zero"
        );
    }

    if (source_node == kBroadcastNodeId) {
        throw CoordinationProtocolError(
            "Source node cannot be broadcast node"
        );
    }

    if (sequence_number == 0) {
        throw CoordinationProtocolError(
            "Sequence number cannot be zero"
        );
    }

    if (payload_size > kCoordinationMaxPayloadSize) {
        throw CoordinationProtocolError(
            "Payload size exceeds maximum allowed size"
        );
    }
}

EncodedCoordinationHeader encode_coordination_header(
    const CoordinationMessageHeader& header
)
{
    header.validate();

    EncodedCoordinationHeader result{};

    std::span<std::byte> output(result);
    std::size_t offset = 0;

    put_u32(output, offset, kCoordinationMagic);
    put_u16(output, offset, kCoordinationVersion);

    put_u16(output, offset, static_cast<std::uint16_t>(header.type));
    put_u32(output, offset, static_cast<std::uint32_t>(header.flags));
    put_u32(output, offset, header.payload_size);
    put_u32(output, offset, header.source_node);
    put_u32(output, offset, header.target_node);
    put_u64(output, offset, header.sequence_number);
    put_u64(output, offset, header.session_id.high);
    put_u64(output, offset, header.session_id.low);

    if (offset != kCoordinationHeaderSize) {
        throw std::logic_error(
            "Internal error: encoded header size mismatch"
        );
    }

    return result;
}

CoordinationMessageHeader decode_coordination_header(
    const std::span<const std::byte> data
)
{
    if (data.size() != kCoordinationHeaderSize) {
        throw CoordinationProtocolError(
            "Data size is not equal to coordination header size"
        );
    }

    std::size_t offset = 0;

    const auto magic = get_u32(data, offset);
    if (magic != kCoordinationMagic) {
        throw CoordinationProtocolError(
            "Invalid coordination magic number"
        );
    }

    const auto version = get_u16(data, offset);
    if (version != kCoordinationVersion) {
        throw CoordinationProtocolError(
            "Unsupported coordination version"
        );
    }

    CoordinationMessageHeader result;
    result.type = static_cast<CoordinationMessageType>(get_u16(data, offset));
    result.flags = static_cast<CoordinationMessageFlags>(get_u32(data, offset));
    result.payload_size = get_u32(data, offset);
    result.source_node = get_u32(data, offset);
    result.target_node = get_u32(data, offset);
    result.sequence_number = get_u64(data, offset);
    result.session_id.high = get_u64(data, offset);
    result.session_id.low = get_u64(data, offset);

    if (offset != data.size()) {
        throw std::logic_error(
            "Internal error: decoded header size mismatch"
        );
    }

    result.validate();

    return result;
}

void CoordinationMessage::validate() const
{
    header.validate();

    if (payload.size() != static_cast<std::size_t>(header.payload_size)) {
        throw CoordinationProtocolError(
            "Payload size does not match header payload_size"
        );
    }

    if (payload.size() > kCoordinationMaxPayloadSize) {
        throw CoordinationProtocolError(
            "Payload size exceeds maximum allowed size"
        );
    }
}

EncodedCoordinationMessage encode_coordination_message(
    const CoordinationMessage& message
)
{
    message.validate();

    const auto encoded_header = encode_coordination_header(message.header);

    EncodedCoordinationMessage result;

    result.reserve(encoded_header.size() + message.payload.size());

    result.insert(result.end(), encoded_header.begin(), encoded_header.end());
    result.insert(result.end(), message.payload.begin(), message.payload.end());

    return result;
}

CoordinationMessage decode_coordination_message(
    const std::span<const std::byte> data
)
{
    if (data.size() < kCoordinationHeaderSize) {
        throw CoordinationProtocolError(
            "Data size is smaller than coordination header size"
        );
    }

    const auto header_data = data.first(kCoordinationHeaderSize);

    auto header = decode_coordination_header(header_data);

    const std::size_t expected_size = kCoordinationHeaderSize + static_cast<std::size_t>(header.payload_size);

    if (data.size() != expected_size) {
        throw CoordinationProtocolError(
            "Data size does not match expected size based on header payload_size"
        );
    }

    CoordinationMessage result;

    result.header = header;

    const auto payload_data = data.subspan(kCoordinationHeaderSize);
    result.payload.assign(payload_data.begin(), payload_data.end());

    result.validate();

    return result;
}

void CoordinationStreamDecoder::push(std::span<const std::byte> data)
{
    buffer_.insert(buffer_.end(), data.begin(), data.end());
}

std::optional<CoordinationMessage> CoordinationStreamDecoder::pop_message()
{
    // We can not determine the frame size until the complete fixed-size
    // header has arrived.

    if (buffer_.size() < kCoordinationHeaderSize) {
        return std::nullopt;
    }

    CoordinationMessageHeader header;

    try {
        const std::span<const std::byte> buffered_data(
            buffer_.data(),
            buffer_.size()
        );

        header = decode_coordination_header(buffered_data.first(kCoordinationHeaderSize));
    } catch (...) {
        // The beginning of the stream is invalid. Retaining it would cause 
        // every subsequent pop_message() call to fail on the same bytes.
        buffer_.clear();
        throw;
    }

    const std::size_t frame_size = kCoordinationHeaderSize + static_cast<std::size_t>(header.payload_size);

    // This header is complete but the payload may still be split
    // across future TCP recv() calls.
    if (buffer_.size() < frame_size) {
        return std::nullopt;
    }

    CoordinationMessage message;

    try {
        const std::span<const std::byte> frame_data(
            buffer_.data(),
            frame_size
        );

        message = decode_coordination_message(frame_data);
    } catch (...) {
        // The frame is invalid. Retaining it would cause 
        // every subsequent pop_message() call to fail on the same bytes.
        buffer_.clear();
        throw;
    }

    using DifferenceType = std::vector<std::byte>::difference_type;

    const auto erase_end = buffer_.begin() + static_cast<DifferenceType>(frame_size);
    buffer_.erase(buffer_.begin(), erase_end);

    return message;
}

} // namespace ssr
