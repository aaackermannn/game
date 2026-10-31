#include <catch2/catch_test_macros.hpp>
#include "protocol/packet.hpp"
#include <limits>

TEST_CASE("PING has the specified big-endian bytes") {
    const std::vector<std::uint8_t> expected{1,0x12,0x34,0,8,0,1,1,2,3,4,5,6,7,8};
    REQUIRE(SerializePing(0x1234,0x0102030405060708ULL) == expected);
}
TEST_CASE("PING and PONG preserve all boundary fields") {
    for (const auto seq : {std::uint16_t(0),std::uint16_t(65535)}) {
        for (const auto stamp : {std::uint64_t(0),std::numeric_limits<std::uint64_t>::max()}) {
            PacketHeader h{};
            auto bytes = SerializePing(seq,stamp); REQUIRE(bytes.size() == 15);
            const auto ping = ParsePing(bytes.data(),bytes.size(),h);
            REQUIRE(ping); CHECK(h.sequenceNumber == seq); CHECK(ping->clientSendTimeUs == stamp);
            bytes = SerializePong(seq,{stamp,0x1020304050607080ULL,stamp}); REQUIRE(bytes.size() == 31);
            const auto pong = ParsePong(bytes.data(),bytes.size(),h);
            REQUIRE(pong); CHECK(h.sequenceNumber == seq); CHECK(pong->clientSendTimeUs == stamp);
            CHECK(pong->serverReceiveTimeUs == 0x1020304050607080ULL); CHECK(pong->serverSendTimeUs == stamp);
        }
    }
}
TEST_CASE("PONG payload has independently specified bytes") {
    const auto bytes = SerializePong(0x1234,{1,2,3});
    const std::vector<std::uint8_t> expected{2,0x12,0x34,0,24,0,1, 0,0,0,0,0,0,0,1, 0,0,0,0,0,0,0,2, 0,0,0,0,0,0,0,3};
    CHECK(bytes == expected);
}
TEST_CASE("All truncations and trailing bytes are rejected without modifying output") {
    for (const bool pong : {false,true}) {
        auto bytes = pong ? SerializePong(42,{1,2,3}) : SerializePing(42,1);
        PacketHeader h{PacketType::Shoot,99,12,1};
        for (std::size_t size = 0; size < bytes.size(); ++size) {
            const bool accepted = pong ? bool(ParsePong(bytes.data(),size,h)) : bool(ParsePing(bytes.data(),size,h));
            CHECK_FALSE(accepted);
            CHECK(h.sequenceNumber == 99);
        }
        bytes.push_back(0);
        CHECK_FALSE(ParseHeader(bytes.data(),bytes.size()));
    }
    PacketHeader h{}; CHECK_FALSE(ParsePing(nullptr,0,h)); CHECK_FALSE(ParsePong(nullptr,31,h));
}
TEST_CASE("Header rejects type version and every incorrect declared payload size") {
    for (const bool pong : {false,true}) {
        const auto valid = pong ? SerializePong(1,{1,2,3}) : SerializePing(1,1);
        auto bytes = valid; bytes[0] = 255; ParseError e{};
        CHECK_FALSE(ParseHeader(bytes.data(),bytes.size(),&e)); CHECK(e == ParseError::UnknownType);
        bytes = valid; bytes[6] = 2;
        CHECK_FALSE(ParseHeader(bytes.data(),bytes.size(),&e)); CHECK(e == ParseError::Version);
        for (unsigned n = 0; n <= 65535; ++n) {
            if (n == (pong ? 24u : 8u)) continue;
            bytes = valid; bytes[3] = static_cast<std::uint8_t>(n >> 8); bytes[4] = static_cast<std::uint8_t>(n);
            REQUIRE_FALSE(ParseHeader(bytes.data(),bytes.size()));
        }
    }
}
TEST_CASE("Direction validation and buffer reader bounds") {
    PacketHeader h{}; auto ping = SerializePing(1,0); auto pong = SerializePong(1,{0,0,0});
    CHECK_FALSE(ParsePong(ping.data(),ping.size(),h)); CHECK_FALSE(ParsePing(pong.data(),pong.size(),h));
    for (std::size_t size=0;size<8;++size) {
        const auto* p = ping.data(); const auto* original = p;
        CHECK_FALSE(ReadU64(p,p+size)); CHECK(p == original);
    }
    const auto* p = ping.data(); CHECK_FALSE(ReadU16(p,p+1)); CHECK(p == ping.data());
}
