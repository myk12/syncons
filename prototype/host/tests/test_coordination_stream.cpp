#include "ssr/coordination.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <exception>
#include <iostream>
#include <optional>
#include <stdexcept>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace {

void require(
    const bool condition,
    const std::string_view message
)
{
    if (!condition) {
        throw std::runtime_error(std::string(message));
    }
}

template <typename ExpectedException, typename Function>
void require_throws(
    Function&& func,
    const std::string_view message
)
{
    bool caught_expected = false;

    try {
        std::forward<Function>(func)();
    } catch (const ExpectedException&) {
        caught_expected = true;
    } catch (const std::exception& exception) {
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


// =======================================================
//                  Test utilities
// =======================================================
ssr::CoordinationMessage make_message(
    const std::uint64_t sequence_number,
    std::vector<std::byte> payload
)
{
    ssr::CoordinationMessage message;

    message.header.type = ssr::CoordinationMessageType::Heartbeat;
    message.header.flags = ssr::CoordinationMessageFlags::None;
    message.header.source_node = 1;
    message.header.target_node = 0;

    message.header.sequence_number = sequence_number;

    message.header.session_id.high = 0x123456789abcdef0;
    message.header.session_id.low = 0x0fedcba987654321;

    require(
        payload.size() <= ssr::kCoordinationMaxPayloadSize,
        "Payload size exceeds maximum allowed size"
    );

    message.header.payload_size = static_cast<std::uint32_t>(payload.size());
    message.payload = std::move(payload);

    return message;
}

void require_message_equal(
    const ssr::CoordinationMessage& actual,
    const ssr::CoordinationMessage& expected
)
{
    require(
        actual.header.type == expected.header.type,
        "CoordinationMessage type mismatch"
    );

    require(
        actual.header.flags == expected.header.flags,
        "CoordinationMessage flags mismatch"
    );

    require(
        actual.header.source_node == expected.header.source_node,
        "CoordinationMessage source_node mismatch"
    );

    require(
        actual.header.target_node == expected.header.target_node,
        "CoordinationMessage target_node mismatch"
    );

    require(
        actual.header.sequence_number == expected.header.sequence_number,
        "CoordinationMessage sequence_number mismatch"
    );

    require(
        actual.header.session_id == expected.header.session_id,
        "CoordinationMessage session_id mismatch"
    );

    require(
        actual.payload == expected.payload,
        "CoordinationMessage payload mismatch"
    );
}

// =======================================================
//                  Test cases
// =======================================================

void test_complete_message_roundtrip()
{
    const auto original = make_message(
        42,
        std::vector<std::byte>{std::byte{0x01}, std::byte{0x02}, std::byte{0x03}}
    );

    const auto encoded = ssr::encode_coordination_message(original);

    require(
        encoded.size() == sizeof(ssr::CoordinationMessageHeader) + original.payload.size(),
        "Encoded message size mismatch"
    );

    const auto decoded = ssr::decode_coordination_message(encoded);

    require_message_equal(decoded, original);
}

void test_empty_payload()
{
    const auto original = make_message(
        100,
        std::vector<std::byte>{}
    );

    const auto encoded = ssr::encode_coordination_message(original);

    require(
        encoded.size() == sizeof(ssr::CoordinationMessageHeader),
        "Encoded message size mismatch for empty payload"
    );

    const auto decoded = ssr::decode_coordination_message(encoded);

    require_message_equal(decoded, original);
}

void test_payload_size_mismatch_rejected()
{
    auto message = make_message(
        200,
        std::vector<std::byte>{std::byte{0xAA}, std::byte{0xBB}}
    );

    message.header.payload_size = 10; // Intentionally incorrect

    require_throws<ssr::CoordinationProtocolError>(
        [&]() { static_cast<void>(ssr::encode_coordination_message(message)); },
        "Expected encode_coordination_message to throw due to payload size mismatch"
    );
}

void test_one_byte_at_a_time()
{
    const auto original = make_message(
        300,
        std::vector<std::byte>{std::byte{0xDE}, std::byte{0xAD}, std::byte{0xBE}, std::byte{0xEF}}
    );

    const auto encoded = ssr::encode_coordination_message(original);
    
    ssr::CoordinationStreamDecoder decoder;

    std::optional<ssr::CoordinationMessage> decoded_message;

    for (std::size_t index = 0; index < encoded.size(); ++index) {
        const std::array<std::byte, 1> chunk{encoded[index]};

        decoder.push(chunk);

        auto result = decoder.pop_message();

        if (index + 1 < encoded.size()) {
            require(
                !result.has_value(),
                "Expected no complete message until all bytes are pushed"
            );
        } else {
            decoded_message = std::move(result);
        }
    }

    require(
        decoded_message.has_value(),
        "Expected a complete message after all bytes are pushed"
    );

    require_message_equal(decoded_message.value(), original);

    require(
        decoder.buffered_size() == 0,
        "Expected no buffered bytes after all bytes are pushed"
    );
}

void test_two_messages_in_one_chunk()
{
    const auto message1 = make_message(
        400,
        std::vector<std::byte>{std::byte{0x11}, std::byte{0x22}}
    );

    const auto message2 = make_message(
        401,
        std::vector<std::byte>{std::byte{0x33}, std::byte{0x44}, std::byte{0x55}}
    );

    const auto encoded1 = ssr::encode_coordination_message(message1);
    const auto encoded2 = ssr::encode_coordination_message(message2);

    std::vector<std::byte> combined;
    combined.reserve(encoded1.size() + encoded2.size());
    combined.insert(combined.end(), encoded1.begin(), encoded1.end());
    combined.insert(combined.end(), encoded2.begin(), encoded2.end());

    ssr::CoordinationStreamDecoder decoder;

    decoder.push(combined);

    const auto decoded_first = decoder.pop_message();

    require(
        decoded_first.has_value(),
        "Expected first message to be decoded"
    );

    require_message_equal(decoded_first.value(), message1);

    const auto decoded_second = decoder.pop_message();

    require(
        decoded_second.has_value(),
        "Expected second message to be decoded"
    );

    require_message_equal(decoded_second.value(), message2);

    require(
        decoder.buffered_size() == 0,
        "Expected no buffered bytes after decoding two messages"
    );
}

void test_partial_second_message_preserved()
{
    const auto first = make_message(
        500,
        std::vector<std::byte>{std::byte{0xAA}}
    );

    const auto second = make_message(
        501,
        std::vector<std::byte>{std::byte{0xBB}, std::byte{0xCC}}
    );

    const auto encoded_first = ssr::encode_coordination_message(first);
    const auto encoded_second = ssr::encode_coordination_message(second);

    const std::size_t partial_size = encoded_second.size() / 2;

    std::vector<std::byte> first_chunk;
    first_chunk.insert(first_chunk.end(), encoded_first.begin(), encoded_first.end());
    first_chunk.insert(first_chunk.end(), encoded_second.begin(), encoded_second.begin() + static_cast<std::vector<std::byte>::difference_type>(partial_size));

    ssr::CoordinationStreamDecoder decoder;

    decoder.push(first_chunk);

    const auto decoded_first = decoder.pop_message();

    require(
        decoded_first.has_value(),
        "Expected first message to be decoded"
    );

    require_message_equal(decoded_first.value(), first);

    require(
        !decoder.pop_message().has_value(),
        "Expected no complete second message yet"
    );

    const auto remaining_begin = encoded_second.begin() + static_cast<std::vector<std::byte>::difference_type>(partial_size);
    const std::span<const std::byte> remaining(
        remaining_begin,
        encoded_second.end()
    );

    decoder.push(remaining);

    const auto decoded_second = decoder.pop_message();

    require(
        decoded_second.has_value(),
        "Expected second message to be decoded after pushing remaining bytes"
    );

    require_message_equal(decoded_second.value(), second);
}

void test_invalid_stream_clears_buffer()
{
    const auto message = make_message(
        600,
        std::vector<std::byte>{std::byte{0x01}, std::byte{0x02}}
    );

    auto encoded = ssr::encode_coordination_message(message);

    // Corrupt the first byte of the protocol magic.
    encoded[0] = std::byte{0xFF};

    ssr::CoordinationStreamDecoder decoder;

    decoder.push(encoded);

    require_throws<ssr::CoordinationProtocolError>(
        [&]() { static_cast<void>(decoder.pop_message()); },
        "Expected pop_message to throw due to invalid stream"
    );

    require(
        decoder.buffered_size() == 0,
        "Expected buffered bytes to be cleared after invalid stream"
    );
}

} // namespace

int main()
{
    try {
        std::cout << "Running coordination stream tests..." << std::endl;

        std::cout << "[Test] complete message roundtrip" << std::endl;
        test_complete_message_roundtrip();

        std::cout << "[Test] empty payload" << std::endl;
        test_empty_payload();

        std::cout << "[Test] payload size mismatch rejected" << std::endl;
        test_payload_size_mismatch_rejected();

        std::cout << "[Test] one byte at a time" << std::endl;
        test_one_byte_at_a_time();

        std::cout << "[Test] two messages in one chunk" << std::endl;
        test_two_messages_in_one_chunk();

        std::cout << "[Test] partial second message preserved" << std::endl;
        test_partial_second_message_preserved();

        std::cout << "[Test] invalid stream clears buffer" << std::endl;
        test_invalid_stream_clears_buffer();

        std::cout << "All coordination stream tests passed!" << std::endl;

        return 0;

    } catch (const std::exception& e) {
        std::cerr << "Error occurred: " << e.what() << std::endl;
        return 1;
    }
}