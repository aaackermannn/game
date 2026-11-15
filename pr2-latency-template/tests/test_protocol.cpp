#include <catch2/catch_test_macros.hpp>
#include "protocol/packet.hpp"
#include <limits>

TEST_CASE("PING has the specified big-endian bytes") {
    const std::vector<std::uint8_t> expected{1, 0x12, 0x34, 0, 8, 0, 2, 0, 1, 2, 3, 4, 5, 6, 7, 8};
    REQUIRE(SerializePing(0x1234, 0x0102030405060708ULL) == expected);
}
TEST_CASE("PING and PONG preserve all boundary fields") {
    for (const auto seq : {std::uint16_t(0), std::uint16_t(65535)}) {
        for (const auto stamp : {std::uint64_t(0), std::numeric_limits<std::uint64_t>::max()}) {
            PacketHeader h{};
            auto bytes = SerializePing(seq, stamp);
            REQUIRE(bytes.size() == 16);
            const auto ping = ParsePing(bytes.data(), bytes.size(), h);
            REQUIRE(ping);
            CHECK(h.sequenceNumber == seq);
            CHECK(ping->clientSendTimeUs == stamp);
            bytes = SerializePong(seq, {stamp, 0x1020304050607080ULL, stamp});
            REQUIRE(bytes.size() == 32);
            const auto pong = ParsePong(bytes.data(), bytes.size(), h);
            REQUIRE(pong);
            CHECK(h.sequenceNumber == seq);
            CHECK(pong->clientSendTimeUs == stamp);
            CHECK(pong->serverReceiveTimeUs == 0x1020304050607080ULL);
            CHECK(pong->serverSendTimeUs == stamp);
        }
    }
}
TEST_CASE("PONG payload has independently specified bytes") {
    const auto bytes = SerializePong(0x1234, {1, 2, 3});
    const std::vector<std::uint8_t> expected{2, 0x12, 0x34, 0, 24, 0, 2, 0,
                                             0, 0,    0,    0, 0,  0, 0, 1,
                                             0, 0,    0,    0, 0,  0, 0, 2,
                                             0, 0,    0,    0, 0,  0, 0, 3};
    CHECK(bytes == expected);
}
TEST_CASE("All truncations and trailing bytes are rejected without modifying output") {
    for (const bool pong : {false, true}) {
        auto bytes = pong ? SerializePong(42, {1, 2, 3}) : SerializePing(42, 1);
        PacketHeader h{PacketType::Shoot, 99, 12, kProtocolVersion, true};
        for (std::size_t size = 0; size < bytes.size(); ++size) {
            const bool accepted =
                pong ? bool(ParsePong(bytes.data(), size, h)) : bool(ParsePing(bytes.data(), size, h));
            CHECK_FALSE(accepted);
            CHECK(h.sequenceNumber == 99);
        }
        bytes.push_back(0);
        CHECK_FALSE(ParseHeader(bytes.data(), bytes.size()));
    }
    PacketHeader h{};
    CHECK_FALSE(ParsePing(nullptr, 0, h));
    CHECK_FALSE(ParsePong(nullptr, 32, h));
}
TEST_CASE("Header rejects type version and every incorrect declared payload size") {
    for (const bool pong : {false, true}) {
        const auto valid = pong ? SerializePong(1, {1, 2, 3}) : SerializePing(1, 1);
        auto bytes = valid;
        bytes[0] = 255;
        ParseError e{};
        CHECK_FALSE(ParseHeader(bytes.data(), bytes.size(), &e));
        CHECK(e == ParseError::UnknownType);
        bytes = valid;
        bytes[6] = 1;
        CHECK_FALSE(ParseHeader(bytes.data(), bytes.size(), &e));
        CHECK(e == ParseError::Version);
        for (unsigned n = 0; n <= 65535; ++n) {
            if (n == (pong ? 24u : 8u))
                continue;
            bytes = valid;
            bytes[3] = static_cast<std::uint8_t>(n >> 8);
            bytes[4] = static_cast<std::uint8_t>(n);
            REQUIRE_FALSE(ParseHeader(bytes.data(), bytes.size()));
        }
    }
}
TEST_CASE("SHOOT and MOVEMENT preserve Loop fields and signal delivery policy") {
    const auto shotBytes = SerializeShoot(0xCAFE, {1.0f, -0.5f, 0xA1B2C3D4u});
    const std::vector<std::uint8_t> expected{4, 0xCA, 0xFE, 0, 12, 0, 2, 1,
                                             0x3F, 0x80, 0, 0, 0xBF, 0, 0, 0,
                                             0xA1, 0xB2, 0xC3, 0xD4};
    CHECK(shotBytes == expected);
    PacketHeader header{};
    const auto shot = ParseShoot(shotBytes.data(), shotBytes.size(), header);
    REQUIRE(shot);
    CHECK(header.requiresAck);
    CHECK(header.sequenceNumber == 0xCAFE);
    CHECK(shot->dirX == 1.0f);
    CHECK(shot->dirY == -0.5f);
    CHECK(shot->weaponId == 0xA1B2C3D4u);

    const auto movementBytes = SerializeMovement(42, {-8.0f, 2.5f});
    const auto movement = ParseMovement(movementBytes.data(), movementBytes.size(), header);
    REQUIRE(movement);
    CHECK_FALSE(header.requiresAck);
    CHECK(movement->x == -8.0f);
    CHECK(movement->y == 2.5f);
}
TEST_CASE("ACK carries the shot number in header and payload in big endian") {
    const std::vector<std::uint8_t> expected{5, 0x12, 0x34, 0, 2, 0, 2, 0, 0x12, 0x34};
    CHECK(SerializeAck(0x1234) == expected);
    PacketHeader header{};
    for (const auto sequence : {std::uint16_t(0), std::numeric_limits<std::uint16_t>::max()}) {
        const auto bytes = SerializeAck(sequence);
        const auto ack = ParseAck(bytes.data(), bytes.size(), header);
        REQUIRE(ack);
        CHECK(ack->acknowledgedSequence == sequence);
        CHECK(header.sequenceNumber == sequence);
        CHECK_FALSE(header.requiresAck);
    }

    auto malformed = expected;
    malformed.back() ^= 1;
    ParseError error{};
    header.sequenceNumber = 42;
    CHECK_FALSE(ParseAck(malformed.data(), malformed.size(), header, &error));
    CHECK(error == ParseError::AckSequence);
    CHECK(header.sequenceNumber == 42);

    for (std::size_t size = 0; size < expected.size(); ++size) {
        CHECK_FALSE(ParseAck(expected.data(), size, header));
        CHECK(header.sequenceNumber == 42);
    }
    malformed = expected;
    malformed.push_back(0);
    CHECK_FALSE(ParseAck(malformed.data(), malformed.size(), header, &error));
    CHECK(error == ParseError::Length);
}
TEST_CASE("Only SHOOT requires ACK and flag bytes other than zero or one are invalid") {
    for (auto bytes : {SerializePing(1, 1), SerializePong(1, {}), SerializeMovement(1, {}),
                       SerializeShoot(1, {}), SerializeAck(1)}) {
        ParseError error{};
        bytes[7] ^= 1;
        CHECK_FALSE(ParseHeader(bytes.data(), bytes.size(), &error));
        CHECK(error == ParseError::AckFlag);
        bytes[7] = 2;
        CHECK_FALSE(ParseHeader(bytes.data(), bytes.size(), &error));
        CHECK(error == ParseError::AckFlag);
    }
}
TEST_CASE("Direction validation and buffer reader bounds") {
    PacketHeader h{};
    auto ping = SerializePing(1, 0);
    auto pong = SerializePong(1, {0, 0, 0});
    CHECK_FALSE(ParsePong(ping.data(), ping.size(), h));
    CHECK_FALSE(ParsePing(pong.data(), pong.size(), h));
    for (std::size_t size = 0; size < 8; ++size) {
        const auto* p = ping.data();
        const auto* original = p;
        CHECK_FALSE(ReadU64(p, p + size));
        CHECK(p == original);
    }
    const auto* p = ping.data();
    CHECK_FALSE(ReadU16(p, p + 1));
    CHECK(p == ping.data());
}
