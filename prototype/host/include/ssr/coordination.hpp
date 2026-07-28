#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <span>
#include <stdexcept>
#include <optional>
#include <vector>

namespace ssr {

using NodeId = std::uint32_t;

constexpr NodeId kBroadcastNodeId = static_cast<NodeId>(0xFFFFFFFFU);

/*
 * A session identifies one complete cluster run.
 *
 * reset/configure/start/restart operations belonging to different
 * sesssions must never be mixed.
 */
struct SessionId {
    std::uint64_t high = 0;
    std::uint64_t low = 0;

    [[nodiscard]]
    bool is_zero() const noexcept
    {
        return high == 0 && low == 0;
    }

    [[nodiscard]]
    bool operator==(const SessionId& other) const noexcept
    {
        return high == other.high && low == other.low;
    }
    
    [[nodiscard]]
    bool operator!=(const SessionId& other) const noexcept
    {
        return !(*this == other);
    }
};

enum class CoordinationMessageType : std::uint16_t {
    RegisterRequest = 1,
    RegisterResponse = 2,

    ConfigureRequest = 3,
    ConfigureReady = 4,

    SynchronizeRequest = 5,
    SynchronizeReady = 6,

    StartPrepare = 7,
    StartReady = 8,
    StartCommit = 9,

    StopRequest = 10,
    StopReady = 11,

    Error = 12,
    Heartbeat = 13,
};

enum class CoordinationMessageFlags : std::uint32_t {
    None = 0,
    AckRequired = 1U << 0,
    Response = 1U << 1,
};

[[nodiscard]]
constexpr CoordinationMessageFlags operator|(
    CoordinationMessageFlags lhs,
    CoordinationMessageFlags rhs
) noexcept
{
    return static_cast<CoordinationMessageFlags>(
        static_cast<std::uint32_t>(lhs) | static_cast<std::uint32_t>(rhs)
    );
}

[[nodiscard]]
constexpr bool has_flag(
    CoordinationMessageFlags value,
    CoordinationMessageFlags flag
) noexcept
{
    return (static_cast<std::uint32_t>(value) &
            static_cast<std::uint32_t>(flag)) != 0;
}

class CoordinationProtocolError : public std::runtime_error {
public:
    using std::runtime_error::runtime_error;
};

/*
 * Wire header layout:
 *
 * 0       4    magic
 * 4       2    version
 * 6       2    message type
 * 8       4    flags
 * 12      4    payload size
 * 16      4    source node
 * 20      4    target node
 * 24      8    session number
 * 32      8    session ID high
 * 40      8    session ID low
 * 
 * Total: 48 bytes
 * 
 * All multi-byte fields are encoded in network byte order (big-endian).
 */
struct CoordinationMessageHeader {
    CoordinationMessageType type = CoordinationMessageType::Error;
    CoordinationMessageFlags flags = CoordinationMessageFlags::None;
    std::uint32_t payload_size = 0;

    NodeId source_node = 0;
    NodeId target_node =  kBroadcastNodeId;

    std::uint64_t sequence_number = 0;

    SessionId session_id{};

    void validate() const;
};

constexpr std::uint32_t kCoordinationMagic = 0x53535243; // "SSRC"
constexpr std::uint16_t kCoordinationVersion = 1;
constexpr std::size_t kCoordinationHeaderSize = 48;
constexpr std::size_t kCoordinationMaxPayloadSize = 1024U * 1024U; // 1 MB

using EncodedCoordinationHeader = 
    std::array<std::byte, kCoordinationHeaderSize>;

[[nodiscard]]
EncodedCoordinationHeader encode_coordination_header(
    const CoordinationMessageHeader& header
);

[[nodiscard]]
CoordinationMessageHeader decode_coordination_header(
    std::span<const std::byte> data
);

// A complete coordination message consists of:
// - fixed-size header + variable-size payload
struct CoordinationMessage {
    CoordinationMessageHeader header;
    std::vector<std::byte> payload;

    void validate() const;
};

using EncodedCoordinationMessage = std::vector<std::byte>;

[[nodiscard]]
EncodedCoordinationMessage encode_coordination_message(
    const CoordinationMessage& message
);

[[nodiscard]]
CoordinationMessage decode_coordination_message(
    std::span<const std::byte> data
);

// TCP is a byte-stream protocol and does not preserve message boundaries.
// This decoder accepts arbitrary byte chunks and returns complete coordination
// messages when enough bytes have arrived.
class CoordinationStreamDecoder {
public:
    void push(std::span<const std::byte> data);

    [[nodiscard]]
    std::optional<CoordinationMessage> pop_message();

    [[nodiscard]]
    std::size_t buffered_size() const noexcept
    {
        return buffer_.size();
    }

    void clear() noexcept
    {
        buffer_.clear();
    }

private:
    std::vector<std::byte> buffer_;
};

} // namespace ssr

