// protocol.h
// Спецификация UDP-протокола для Loop (см. docs/pr1-udp-protocol.md).
// Структуры упакованы (#pragma pack(1)) — без выравнивания, чтобы бинарный layout
// был одинаковым на обеих сторонах независимо от компилятора/платформы.
//
// Многобайтовые целочисленные поля ЗАГОЛОВКА передаются в сетевом порядке байт
// (big-endian) через htons/htonl — см. serialize()/deserialize() ниже.
// Поля полезной нагрузки (payload), включая float, передаются как есть (raw),
// в предположении little-endian хостов на обеих сторонах (x86/x64/ARM —
// подавляющее большинство современных устройств). Это осознанное упрощение
// для учебного проекта, оговорённое в документации протокола.
#pragma once

#include <cstdint>
#include <cstring>
#include <vector>

#ifdef _WIN32
    #include <winsock2.h>
#else
    #include <arpa/inet.h>
#endif

#include "crc32.h"

namespace proto {

constexpr uint8_t kMagic = 0xA5;      // сигнатура пакетов протокола Loop
constexpr uint16_t kMaxPayload = 512; // с запасом хватает под все payload'ы ниже

enum class PacketType : uint8_t {
    // Клиент -> сервер
    AUTH         = 1, // логин/пароль (доп. задание)
    MOVEMENT     = 2, // новая позиция карта
    SHOOT        = 3, // имитация выстрела
    // Сервер -> клиент
    AUTH_RESULT  = 10,
    STATE_UPDATE = 11, // подтверждение MOVEMENT + актуальное состояние
    SHOOT_RESULT = 12,
    ERROR_RESP   = 13, // неизвестный тип / битый checksum / прочие ошибки
};

#pragma pack(push, 1)

// Заголовок пакета — 12 байт, одинаков для всех типов.
struct PacketHeader {
    uint8_t  magic;       // должен быть kMagic, иначе пакет отбрасывается
    uint8_t  type;        // PacketType
    uint32_t sequence;    // порядковый номер пакета (у клиента — монотонно растёт)
    uint16_t payloadSize; // размер payload в байтах, идущего сразу за заголовком
    uint32_t checksum;    // CRC32(payload); 0, если целостность не проверяется
};
static_assert(sizeof(PacketHeader) == 12, "PacketHeader must be tightly packed to 12 bytes");

// ---- Payload'ы: клиент -> сервер ----------------------------------------

struct AuthPayload {
    char username[32]; // \0-дополненная строка
    char password[32];
};

struct MovementPayload {
    float x;
    float y;
};

struct ShootPayload {
    float dirX;   // направление выстрела (нормализованный вектор)
    float dirY;
    uint32_t weaponId;
};

// ---- Payload'ы: сервер -> клиент -----------------------------------------

struct AuthResultPayload {
    uint8_t success; // 0/1
    char message[64];
};

struct StateUpdatePayload {
    uint32_t clientId;
    float x;
    float y;
    uint32_t health;
    uint32_t ackSequence; // sequence из обработанного запроса клиента
};

struct ShootResultPayload {
    uint8_t hit;          // 0/1
    uint32_t targetId;    // 0, если целей не было
    uint32_t ackSequence;
};

struct ErrorPayload {
    char message[64];
};

#pragma pack(pop)

// Собрать пакет "заголовок + payload" в один буфер, готовый к sendto().
// Целочисленные поля заголовка переводятся в сетевой порядок байт.
template <typename Payload>
inline std::vector<uint8_t> buildPacket(PacketType type, uint32_t sequence, const Payload& payload, bool withChecksum = true) {
    static_assert(sizeof(Payload) <= kMaxPayload, "payload too large");

    PacketHeader header{};
    header.magic = kMagic;
    header.type = static_cast<uint8_t>(type);
    header.sequence = htonl(sequence);
    header.payloadSize = htons(static_cast<uint16_t>(sizeof(Payload)));
    header.checksum = withChecksum
        ? htonl(crc32::compute(&payload, sizeof(Payload)))
        : 0;

    std::vector<uint8_t> buf(sizeof(PacketHeader) + sizeof(Payload));
    std::memcpy(buf.data(), &header, sizeof(PacketHeader));
    std::memcpy(buf.data() + sizeof(PacketHeader), &payload, sizeof(Payload));
    return buf;
}

// Результат разбора входящего пакета.
struct ParsedPacket {
    bool valid = false;          // magic корректен и размер буфера согласован с заголовком
    bool checksumOk = true;      // сходится ли CRC32 (true, если checksum не использовался, т.е. 0)
    PacketType type{};
    uint32_t sequence = 0;
    const uint8_t* payload = nullptr; // указывает внутрь исходного буфера
    uint16_t payloadSize = 0;
};

// Разобрать сырые байты, пришедшие из recvfrom(), в заголовок + указатель на payload.
// Байты заголовка переводятся из сетевого порядка обратно в host order.
inline ParsedPacket parsePacket(const uint8_t* data, std::size_t len) {
    ParsedPacket result;
    if (len < sizeof(PacketHeader)) {
        return result; // слишком короткий пакет — даже заголовок не помещается
    }

    PacketHeader header;
    std::memcpy(&header, data, sizeof(PacketHeader));
    if (header.magic != kMagic) {
        return result; // не наш протокол / мусорный пакет
    }

    uint32_t sequence = ntohl(header.sequence);
    uint16_t payloadSize = ntohs(header.payloadSize);
    uint32_t checksum = ntohl(header.checksum);

    if (len != sizeof(PacketHeader) + payloadSize) {
        return result; // заявленный размер не совпадает с тем, что реально пришло
    }

    result.valid = true;
    result.type = static_cast<PacketType>(header.type);
    result.sequence = sequence;
    result.payload = data + sizeof(PacketHeader);
    result.payloadSize = payloadSize;
    result.checksumOk = (checksum == 0) || (checksum == crc32::compute(result.payload, payloadSize));
    return result;
}

// Безопасно скопировать payload разобранного пакета в структуру нужного типа.
// Возвращает false, если размеры не совпадают (защита от некорректных/чужих пакетов).
template <typename Payload>
inline bool readPayload(const ParsedPacket& pkt, Payload& out) {
    if (pkt.payloadSize != sizeof(Payload)) {
        return false;
    }
    std::memcpy(&out, pkt.payload, sizeof(Payload));
    return true;
}

} // namespace proto
