#include "ssr/coordination.hpp"

#include <cstddef>
#include <exception>
#include <iostream>
#include <stdexcept>
#include <string>
#include <string_view>
#include <utility>

namespace {

void require(
    const bool condition,
    const std::string_view message
)
{
    if (!condition) {
        throw std::logic_error(std::string(message));
    }
}

template <typename Exception, typename Function>
void require_throws(
    Function&& func,
    const std::string_view message
)
{
    bool caught_expected = false;

    try {
        std::forward<Function>(func)();
    } catch (const Exception&) {
        caught_expected = true;
    } catch (const std::exception& e) {
        throw std::runtime_error(
            std::string(message) + " (unexpected exception: " + e.what() + ")"
        );
    }

    if (!caught_expected) {
        throw std::runtime_error(std::string(message) + " (no exception thrown)");
    }
}

ssr::CoordinationMessageHeader make_test_header()
{
    ssr::CoordinationMessageHeader header;

    header.type = ssr::CoordinationMessageType::StartPrepare;
    header.flags = ssr::CoordinationMessageFlags::AckRequired;
    header.payload_size = 128;

    header.source_node = 0;
    header.target_node = 2;

    header.sequence_number = 42;

    header.session_id = ssr::SessionId{.high = 0x123456789abcdef0, .low = 0x0fedcba987654321};

    return header;
}

void test_header_round_trip()
{
    const auto original = make_test_header();

    const auto encoded = ssr::encode_coordination_header(original);

    require(
        encoded.size() == ssr::kCoordinationHeaderSize,
        "Encoded header size should match kCoordinationHeaderSize"
    );

    const auto decoded = ssr::decode_coordination_header(encoded);

    require(
        decoded.type == original.type,
        "Decoded header type should match original"
    );
    require(
        decoded.flags == original.flags,
        "Decoded header flags should match original"
    );
    require(
        decoded.payload_size == original.payload_size,
        "Decoded header payload size should match original"
    );
    require(
        decoded.source_node == original.source_node,
        "Decoded header source node should match original"
    );
    require(
        decoded.target_node == original.target_node,
        "Decoded header target node should match original"
    );
    require(
        decoded.sequence_number == original.sequence_number,
        "Decoded header sequence number should match original"
    );
    require(
        decoded.session_id.high == original.session_id.high,
        "Decoded header session ID high should match original"
    );
    require(
        decoded.session_id.low == original.session_id.low,
        "Decoded header session ID low should match original"
    );
}

void test_broadcast_target()
{
    auto header = make_test_header();

    header.type = ssr::CoordinationMessageType::StartCommit;

    header.target_node = ssr::kBroadcastNodeId;

    const auto encoded = ssr::encode_coordination_header(header);

    const auto decoded = ssr::decode_coordination_header(encoded);

    require(
        decoded.target_node == ssr::kBroadcastNodeId,
        "Decoded header target node should match broadcast node ID"
    );
}

void test_zero_session_rejected()
{
    auto header = make_test_header();

    header.session_id = ssr::SessionId{.high = 0, .low = 0};

    require_throws<ssr::CoordinationProtocolError>(
        [&]() { static_cast<void>(ssr::encode_coordination_header(header)); },
        "Encoding a header with zero session ID should throw CoordinationProtocolError"
    );
}

void test_zero_sequence_rejected()
{
    auto header = make_test_header();

    header.sequence_number = 0;

    require_throws<ssr::CoordinationProtocolError>(
        [&]() { static_cast<void>(ssr::encode_coordination_header(header)); },
        "Encoding a header with zero sequence number should throw CoordinationProtocolError"
    );
}

void test_broadcast_source_rejected()
{
    auto header = make_test_header();

    header.source_node = ssr::kBroadcastNodeId;

    require_throws<ssr::CoordinationProtocolError>(
        [&]() { static_cast<void>(ssr::encode_coordination_header(header)); },
        "Encoding a header with broadcast source node should throw CoordinationProtocolError"
    );
}

void test_invalid_magic_rejected()
{
    auto header = make_test_header();

    auto encoded = ssr::encode_coordination_header(header);

    // Corrupt the magic number
    encoded[0] = std::byte{0x00};
    encoded[1] = std::byte{0x00};
    encoded[2] = std::byte{0x00};
    encoded[3] = std::byte{0x00};

    require_throws<ssr::CoordinationProtocolError>(
        [&]() { static_cast<void>(ssr::decode_coordination_header(encoded)); },
        "Decoding a header with invalid magic number should throw CoordinationProtocolError"
    );
}

void test_invalid_version_rejected()
{
    auto header = make_test_header();

    auto encoded = ssr::encode_coordination_header(header);

    // Corrupt the version number
    encoded[4] = std::byte{0xFF};
    encoded[5] = std::byte{0xFF};

    require_throws<ssr::CoordinationProtocolError>(
        [&]() { static_cast<void>(ssr::decode_coordination_header(encoded)); },
        "Decoding a header with invalid version number should throw CoordinationProtocolError"
    );
}

void test_invalid_type_rejected()
{
    auto header = make_test_header();

    auto encoded = ssr::encode_coordination_header(header);

    // Corrupt the message type
    encoded[6] = std::byte{0xFF};
    encoded[7] = std::byte{0xFF};

    require_throws<ssr::CoordinationProtocolError>(
        [&]() { static_cast<void>(ssr::decode_coordination_header(encoded)); },
        "Decoding a header with invalid message type should throw CoordinationProtocolError"
    );
}

void test_oversized_payload_rejected()
{
    auto header = make_test_header();

    header.payload_size = ssr::kCoordinationMaxPayloadSize + 1;

    require_throws<ssr::CoordinationProtocolError>(
        [&]() { static_cast<void>(ssr::encode_coordination_header(header)); },
        "Encoding a header with oversized payload should throw CoordinationProtocolError"
    );
}

void test_invalid_header_size_rejected()
{
    auto header = make_test_header();

    auto encoded = ssr::encode_coordination_header(header);

    // Remove a byte to make the size invalid
    std::span<std::byte> truncated(encoded.data(), encoded.size() - 1);

    require_throws<ssr::CoordinationProtocolError>(
        [&]() { static_cast<void>(ssr::decode_coordination_header(truncated)); },
        "Decoding a header with invalid size should throw CoordinationProtocolError"
    );
}

} // namespace

int main()
{
    try {
        std::cout << "Running SSR coordination protocol tests..." << std::endl;
        std::cout << "[Test] header round trip" << std::endl;
        test_header_round_trip();
        std::cout << "[Test] broadcast target" << std::endl;
        test_broadcast_target();
        std::cout << "[Test] zero session rejected" << std::endl;
        test_zero_session_rejected();
        std::cout << "[Test] zero sequence rejected" << std::endl;
        test_zero_sequence_rejected();
        std::cout << "[Test] broadcast source rejected" << std::endl;
        test_broadcast_source_rejected();
        std::cout << "[Test] invalid magic rejected" << std::endl;
        test_invalid_magic_rejected();
        std::cout << "[Test] invalid version rejected" << std::endl;
        test_invalid_version_rejected();
        std::cout << "[Test] invalid type rejected" << std::endl;
        test_invalid_type_rejected();
        std::cout << "[Test] oversized payload rejected" << std::endl;
        test_oversized_payload_rejected();
        std::cout << "[Test] invalid header size rejected" << std::endl;
        test_invalid_header_size_rejected();
        std::cout << "All tests passed!" << std::endl;
        return 0;
    } catch (const std::exception& e) {
        std::cerr << "SSR coordination protocol tests failed: " << e.what() << std::endl;
        return 1;
    }
}
