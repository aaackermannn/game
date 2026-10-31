#include "protocol/packet.hpp"

namespace {
void SetError(ParseError* out, ParseError value) { if (out) *out = value; }
std::vector<std::uint8_t> Header(PacketType type, std::uint16_t seq, std::uint16_t size) {
    std::vector<std::uint8_t> out;
    out.reserve(kHeaderSize + size);
    out.push_back(static_cast<std::uint8_t>(type));
    WriteU16(out, seq); WriteU16(out, size); WriteU16(out, kProtocolVersion);
    return out;
}
}
const char* ParseErrorName(ParseError error) {
    switch (error) {
    case ParseError::None: return "none";
    case ParseError::Truncated: return "truncated_header";
    case ParseError::UnknownType: return "unknown_type";
    case ParseError::WrongType: return "wrong_type";
    case ParseError::Version: return "unsupported_version";
    case ParseError::Length: return "invalid_payload_length";
    }
    return "invalid";
}
void WriteU16(std::vector<std::uint8_t>& out, std::uint16_t value) {
    out.push_back(static_cast<std::uint8_t>(value >> 8)); out.push_back(static_cast<std::uint8_t>(value));
}
void WriteU64(std::vector<std::uint8_t>& out, std::uint64_t value) {
    for (int shift = 56; shift >= 0; shift -= 8) out.push_back(static_cast<std::uint8_t>(value >> shift));
}
std::optional<std::uint16_t> ReadU16(const std::uint8_t*& p, const std::uint8_t* end) {
    if (!p || !end || end - p < 2) return std::nullopt;
    const auto v = static_cast<std::uint16_t>((std::uint16_t(p[0]) << 8) | p[1]); p += 2; return v;
}
std::optional<std::uint64_t> ReadU64(const std::uint8_t*& p, const std::uint8_t* end) {
    if (!p || !end || end - p < 8) return std::nullopt;
    std::uint64_t v = 0;
    for (int i = 0; i < 8; ++i) v = (v << 8) | *p++;
    return v;
}
std::optional<PacketHeader> ParseHeader(const std::uint8_t* data, std::size_t size, ParseError* error) {
    SetError(error, ParseError::None);
    if (!data || size < kHeaderSize) { SetError(error, ParseError::Truncated); return std::nullopt; }
    const auto type = static_cast<PacketType>(data[0]);
    std::uint16_t expected = 0;
    switch (type) {
    case PacketType::Ping: expected = 8; break;
    case PacketType::Pong: expected = 24; break;
    case PacketType::Movement: expected = 8; break;
    case PacketType::Shoot: expected = 12; break;
    default: SetError(error, ParseError::UnknownType); return std::nullopt;
    }
    const auto* p = data + 1;
    const auto* end = data + kHeaderSize;
    const auto seq = *ReadU16(p, end), length = *ReadU16(p, end), version = *ReadU16(p, end);
    if (version != kProtocolVersion) { SetError(error, ParseError::Version); return std::nullopt; }
    if (length != expected || size != kHeaderSize + length) { SetError(error, ParseError::Length); return std::nullopt; }
    return PacketHeader{type, seq, length, version};
}
std::vector<std::uint8_t> SerializePing(std::uint16_t sequence, std::uint64_t sentUs) {
    auto out = Header(PacketType::Ping, sequence, 8); WriteU64(out, sentUs); return out;
}
std::vector<std::uint8_t> SerializePong(std::uint16_t sequence, const PongPayload& payload) {
    auto out = Header(PacketType::Pong, sequence, 24);
    WriteU64(out, payload.clientSendTimeUs); WriteU64(out, payload.serverReceiveTimeUs);
    WriteU64(out, payload.serverSendTimeUs); return out;
}
std::optional<PingPayload> ParsePing(const std::uint8_t* data, std::size_t size, PacketHeader& header, ParseError* error) {
    const auto parsed = ParseHeader(data, size, error);
    if (!parsed) return std::nullopt;
    if (parsed->type != PacketType::Ping) { SetError(error, ParseError::WrongType); return std::nullopt; }
    const auto* p = data + kHeaderSize; const auto sent = ReadU64(p, data + size);
    if (!sent) return std::nullopt;
    header = *parsed; return PingPayload{*sent};
}
std::optional<PongPayload> ParsePong(const std::uint8_t* data, std::size_t size, PacketHeader& header, ParseError* error) {
    const auto parsed = ParseHeader(data, size, error);
    if (!parsed) return std::nullopt;
    if (parsed->type != PacketType::Pong) { SetError(error, ParseError::WrongType); return std::nullopt; }
    const auto* p = data + kHeaderSize;
    const auto sent = ReadU64(p, data + size), received = ReadU64(p, data + size), serverSent = ReadU64(p, data + size);
    if (!sent || !received || !serverSent) return std::nullopt;
    header = *parsed; return PongPayload{*sent, *received, *serverSent};
}
