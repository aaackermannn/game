#pragma once
#include <cstddef>
#include <cstdint>
#include <optional>
#include <vector>

constexpr std::uint16_t kProtocolVersion = 2;
// Размер заголовка на проводе задан форматом. Выравнивание структуры C++ на него не влияет.
constexpr std::size_t kHeaderSize = 8;
enum class PacketType : std::uint8_t { Ping = 1, Pong = 2, Movement = 3, Shoot = 4, Ack = 5 };
struct PacketHeader {
    PacketType type{};
    std::uint16_t sequenceNumber = 0, payloadSize = 0, protocolVersion = 0;
    bool requiresAck = false;
};
struct PingPayload {
    std::uint64_t clientSendTimeUs = 0;
};
struct PongPayload {
    // Метка клиента связывает ответ с отправкой. Две метки сервера используются для диагностики.
    std::uint64_t clientSendTimeUs = 0, serverReceiveTimeUs = 0, serverSendTimeUs = 0;
};
struct MovementPayload {
    float x = 0.0f, y = 0.0f;
};
struct ShootPayload {
    float dirX = 0.0f, dirY = 0.0f;
    std::uint32_t weaponId = 0;
};
struct AckPayload {
    std::uint16_t acknowledgedSequence = 0;
};
enum class ParseError { None, Truncated, UnknownType, WrongType, Version, Length, AckFlag, AckSequence };
const char* ParseErrorName(ParseError error);
void WriteU16(std::vector<std::uint8_t>& out, std::uint16_t value);
void WriteU64(std::vector<std::uint8_t>& out, std::uint64_t value);
std::optional<std::uint16_t> ReadU16(const std::uint8_t*& cursor, const std::uint8_t* end);
std::optional<std::uint64_t> ReadU64(const std::uint8_t*& cursor, const std::uint8_t* end);
std::optional<PacketHeader> ParseHeader(const std::uint8_t* data, std::size_t size,
                                        ParseError* error = nullptr);
std::vector<std::uint8_t> SerializePing(std::uint16_t sequence, std::uint64_t sentUs);
std::vector<std::uint8_t> SerializePong(std::uint16_t sequence, const PongPayload& payload);
std::vector<std::uint8_t> SerializeMovement(std::uint16_t sequence, const MovementPayload& payload);
std::vector<std::uint8_t> SerializeShoot(std::uint16_t sequence, const ShootPayload& payload);
std::vector<std::uint8_t> SerializeAck(std::uint16_t acknowledgedSequence);
std::optional<PingPayload> ParsePing(const std::uint8_t* data, std::size_t size, PacketHeader& header,
                                     ParseError* error = nullptr);
std::optional<PongPayload> ParsePong(const std::uint8_t* data, std::size_t size, PacketHeader& header,
                                     ParseError* error = nullptr);
std::optional<MovementPayload> ParseMovement(const std::uint8_t* data, std::size_t size, PacketHeader& header,
                                             ParseError* error = nullptr);
std::optional<ShootPayload> ParseShoot(const std::uint8_t* data, std::size_t size, PacketHeader& header,
                                       ParseError* error = nullptr);
std::optional<AckPayload> ParseAck(const std::uint8_t* data, std::size_t size, PacketHeader& header,
                                   ParseError* error = nullptr);
