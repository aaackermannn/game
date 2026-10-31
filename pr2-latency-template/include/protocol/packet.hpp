#pragma once
#include <cstddef>
#include <cstdint>
#include <optional>
#include <vector>

constexpr std::uint16_t kProtocolVersion = 1;
constexpr std::size_t kHeaderSize = 7;
enum class PacketType : std::uint8_t { Ping = 1, Pong = 2, Movement = 3, Shoot = 4 };
struct PacketHeader {
    PacketType type{};
    std::uint16_t sequenceNumber = 0, payloadSize = 0, protocolVersion = 0;
};
struct PingPayload { std::uint64_t clientSendTimeUs = 0; };
struct PongPayload {
    std::uint64_t clientSendTimeUs = 0, serverReceiveTimeUs = 0, serverSendTimeUs = 0;
};
enum class ParseError { None, Truncated, UnknownType, WrongType, Version, Length };
const char* ParseErrorName(ParseError error);
void WriteU16(std::vector<std::uint8_t>& out, std::uint16_t value);
void WriteU64(std::vector<std::uint8_t>& out, std::uint64_t value);
std::optional<std::uint16_t> ReadU16(const std::uint8_t*& cursor, const std::uint8_t* end);
std::optional<std::uint64_t> ReadU64(const std::uint8_t*& cursor, const std::uint8_t* end);
std::optional<PacketHeader> ParseHeader(const std::uint8_t* data, std::size_t size, ParseError* error = nullptr);
std::vector<std::uint8_t> SerializePing(std::uint16_t sequence, std::uint64_t sentUs);
std::vector<std::uint8_t> SerializePong(std::uint16_t sequence, const PongPayload& payload);
std::optional<PingPayload> ParsePing(const std::uint8_t* data, std::size_t size, PacketHeader& header, ParseError* error = nullptr);
std::optional<PongPayload> ParsePong(const std::uint8_t* data, std::size_t size, PacketHeader& header, ParseError* error = nullptr);
