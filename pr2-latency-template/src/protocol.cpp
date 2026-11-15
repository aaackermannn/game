#include "protocol/packet.hpp"

#include <cstring>
#include <limits>

namespace {
constexpr std::uint16_t kPingPayloadSize = 8;
constexpr std::uint16_t kPongPayloadSize = 24;
constexpr std::uint16_t kMovementPayloadSize = 8;
constexpr std::uint16_t kShootPayloadSize = 12;
constexpr std::uint16_t kAckPayloadSize = 2;

static_assert(sizeof(float) == sizeof(std::uint32_t) && std::numeric_limits<float>::is_iec559,
              "Loop positions and directions require IEEE 754 binary32");

constexpr bool RequiresAck(PacketType type) {
    return type == PacketType::Shoot;
}

void SetError(ParseError* out, ParseError value) {
    if (out)
        *out = value;
}
std::vector<std::uint8_t> Header(PacketType type, std::uint16_t seq, std::uint16_t size) {
    std::vector<std::uint8_t> out;
    out.reserve(kHeaderSize + size);
    // Порядок на проводе: тип, номер, размер, версия и однобайтовый флаг ACK.
    out.push_back(static_cast<std::uint8_t>(type));
    WriteU16(out, seq);
    WriteU16(out, size);
    WriteU16(out, kProtocolVersion);
    out.push_back(RequiresAck(type) ? 1 : 0);
    return out;
}

std::optional<PacketHeader> ParseTypedHeader(const std::uint8_t* data, std::size_t size,
                                             PacketType type, ParseError* error) {
    const auto header = ParseHeader(data, size, error);
    if (header && header->type != type) {
        SetError(error, ParseError::WrongType);
        return std::nullopt;
    }
    return header;
}

void WriteU32(std::vector<std::uint8_t>& out, std::uint32_t value) {
    for (int shift = 24; shift >= 0; shift -= 8)
        out.push_back(static_cast<std::uint8_t>(value >> shift));
}

std::uint32_t ReadU32(const std::uint8_t*& cursor) {
    // Вызывается только после проверки точного размера датаграммы в ParseTypedHeader.
    std::uint32_t value = 0;
    for (int i = 0; i < 4; ++i)
        value = (value << 8) | *cursor++;
    return value;
}

void WriteFloat(std::vector<std::uint8_t>& out, float value) {
    // Сохраняем IEEE 754 биты координаты без числового преобразования в целое.
    std::uint32_t bits;
    std::memcpy(&bits, &value, sizeof(bits));
    WriteU32(out, bits);
}

float ReadFloat(const std::uint8_t*& cursor) {
    const auto bits = ReadU32(cursor);
    float value;
    std::memcpy(&value, &bits, sizeof(value));
    return value;
}
} // namespace
const char* ParseErrorName(ParseError error) {
    switch (error) {
    case ParseError::None:
        return "none";
    case ParseError::Truncated:
        return "truncated_header";
    case ParseError::UnknownType:
        return "unknown_type";
    case ParseError::WrongType:
        return "wrong_type";
    case ParseError::Version:
        return "unsupported_version";
    case ParseError::Length:
        return "invalid_payload_length";
    case ParseError::AckFlag:
        return "invalid_requires_ack";
    case ParseError::AckSequence:
        return "invalid_ack_sequence";
    }
    return "invalid";
}
// В сетевом порядке big-endian сначала пишем старший байт, независимо от порядка байтов в памяти.
void WriteU16(std::vector<std::uint8_t>& out, std::uint16_t value) {
    out.push_back(static_cast<std::uint8_t>(value >> 8));
    out.push_back(static_cast<std::uint8_t>(value));
}
void WriteU64(std::vector<std::uint8_t>& out, std::uint64_t value) {
    for (int shift = 56; shift >= 0; shift -= 8)
        out.push_back(static_cast<std::uint8_t>(value >> shift));
}
// Перед чтением проверяем остаток буфера. Курсор сдвигается только после успешной проверки.
std::optional<std::uint16_t> ReadU16(const std::uint8_t*& p, const std::uint8_t* end) {
    if (!p || !end || end - p < 2)
        return std::nullopt;
    const auto v = static_cast<std::uint16_t>((std::uint16_t(p[0]) << 8) | p[1]);
    p += 2;
    return v;
}
std::optional<std::uint64_t> ReadU64(const std::uint8_t*& p, const std::uint8_t* end) {
    if (!p || !end || end - p < 8)
        return std::nullopt;
    std::uint64_t v = 0;
    for (int i = 0; i < 8; ++i)
        v = (v << 8) | *p++;
    return v;
}
std::optional<PacketHeader> ParseHeader(const std::uint8_t* data, std::size_t size, ParseError* error) {
    SetError(error, ParseError::None);
    if (!data || size < kHeaderSize) {
        SetError(error, ParseError::Truncated);
        return std::nullopt;
    }
    const auto type = static_cast<PacketType>(data[0]);
    std::uint16_t expected = 0;
    switch (type) {
    case PacketType::Ping:
        expected = kPingPayloadSize;
        break;
    case PacketType::Pong:
        expected = kPongPayloadSize;
        break;
    case PacketType::Movement:
        expected = kMovementPayloadSize;
        break;
    case PacketType::Shoot:
        expected = kShootPayloadSize;
        break;
    case PacketType::Ack:
        expected = kAckPayloadSize;
        break;
    default:
        SetError(error, ParseError::UnknownType);
        return std::nullopt;
    }
    const auto* p = data + 1;
    const auto* end = data + kHeaderSize;
    const auto seq = *ReadU16(p, end), length = *ReadU16(p, end), version = *ReadU16(p, end);
    if (version != kProtocolVersion) {
        SetError(error, ParseError::Version);
        return std::nullopt;
    }
    // Длина должна подходить типу пакета и точно совпадать с размером его нагрузки в датаграмме.
    if (length != expected || size != kHeaderSize + length) {
        SetError(error, ParseError::Length);
        return std::nullopt;
    }
    const auto requiresAck = *p;
    if (requiresAck > 1 || (requiresAck == 1) != RequiresAck(type)) {
        SetError(error, ParseError::AckFlag);
        return std::nullopt;
    }
    return PacketHeader{type, seq, length, version, requiresAck == 1};
}
std::vector<std::uint8_t> SerializePing(std::uint16_t sequence, std::uint64_t sentUs) {
    auto out = Header(PacketType::Ping, sequence, kPingPayloadSize);
    WriteU64(out, sentUs);
    return out;
}
std::vector<std::uint8_t> SerializePong(std::uint16_t sequence, const PongPayload& payload) {
    // Нагрузка PONG содержит три метки по 8 байт. Исходная клиентская метка возвращается без изменений.
    auto out = Header(PacketType::Pong, sequence, kPongPayloadSize);
    WriteU64(out, payload.clientSendTimeUs);
    WriteU64(out, payload.serverReceiveTimeUs);
    WriteU64(out, payload.serverSendTimeUs);
    return out;
}
std::vector<std::uint8_t> SerializeMovement(std::uint16_t sequence, const MovementPayload& payload) {
    auto out = Header(PacketType::Movement, sequence, kMovementPayloadSize);
    WriteFloat(out, payload.x);
    WriteFloat(out, payload.y);
    return out;
}
std::vector<std::uint8_t> SerializeShoot(std::uint16_t sequence, const ShootPayload& payload) {
    auto out = Header(PacketType::Shoot, sequence, kShootPayloadSize);
    WriteFloat(out, payload.dirX);
    WriteFloat(out, payload.dirY);
    WriteU32(out, payload.weaponId);
    return out;
}
std::vector<std::uint8_t> SerializeAck(std::uint16_t acknowledgedSequence) {
    // Как в PONG, номер в ответе повторяет номер запроса. В ACK он также указан в нагрузке.
    auto out = Header(PacketType::Ack, acknowledgedSequence, kAckPayloadSize);
    WriteU16(out, acknowledgedSequence);
    return out;
}
std::optional<PingPayload> ParsePing(const std::uint8_t* data, std::size_t size, PacketHeader& header,
                                     ParseError* error) {
    const auto parsed = ParseTypedHeader(data, size, PacketType::Ping, error);
    if (!parsed)
        return std::nullopt;
    const auto* p = data + kHeaderSize;
    const auto sent = ReadU64(p, data + size);
    if (!sent)
        return std::nullopt;
    header = *parsed;
    return PingPayload{*sent};
}
std::optional<PongPayload> ParsePong(const std::uint8_t* data, std::size_t size, PacketHeader& header,
                                     ParseError* error) {
    const auto parsed = ParseTypedHeader(data, size, PacketType::Pong, error);
    if (!parsed)
        return std::nullopt;
    const auto* p = data + kHeaderSize;
    const auto sent = ReadU64(p, data + size), received = ReadU64(p, data + size),
               serverSent = ReadU64(p, data + size);
    if (!sent || !received || !serverSent)
        return std::nullopt;
    header = *parsed;
    return PongPayload{*sent, *received, *serverSent};
}
std::optional<MovementPayload> ParseMovement(const std::uint8_t* data, std::size_t size,
                                             PacketHeader& header, ParseError* error) {
    const auto parsed = ParseTypedHeader(data, size, PacketType::Movement, error);
    if (!parsed)
        return std::nullopt;
    const auto* p = data + kHeaderSize;
    const MovementPayload payload{ReadFloat(p), ReadFloat(p)};
    header = *parsed;
    return payload;
}
std::optional<ShootPayload> ParseShoot(const std::uint8_t* data, std::size_t size, PacketHeader& header,
                                       ParseError* error) {
    const auto parsed = ParseTypedHeader(data, size, PacketType::Shoot, error);
    if (!parsed)
        return std::nullopt;
    const auto* p = data + kHeaderSize;
    const ShootPayload payload{ReadFloat(p), ReadFloat(p), ReadU32(p)};
    header = *parsed;
    return payload;
}
std::optional<AckPayload> ParseAck(const std::uint8_t* data, std::size_t size, PacketHeader& header,
                                   ParseError* error) {
    const auto parsed = ParseTypedHeader(data, size, PacketType::Ack, error);
    if (!parsed)
        return std::nullopt;
    const auto* p = data + kHeaderSize;
    const auto sequence = *ReadU16(p, data + size);
    if (sequence != parsed->sequenceNumber) {
        SetError(error, ParseError::AckSequence);
        return std::nullopt;
    }
    header = *parsed;
    return AckPayload{sequence};
}
