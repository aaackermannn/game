// crc32.h
// Табличная реализация CRC-32 (полином 0xEDB88320, как в zip/Ethernet/PNG).
// Используется для поля Checksum в заголовке пакета (доп. задание).
#pragma once

#include <array>
#include <cstddef>
#include <cstdint>

namespace crc32 {

inline const std::array<uint32_t, 256>& table() {
    static const std::array<uint32_t, 256> t = [] {
        std::array<uint32_t, 256> tbl{};
        constexpr uint32_t polynomial = 0xEDB88320u;
        for (uint32_t i = 0; i < 256; ++i) {
            uint32_t c = i;
            for (int k = 0; k < 8; ++k) {
                c = (c & 1) ? (polynomial ^ (c >> 1)) : (c >> 1);
            }
            tbl[i] = c;
        }
        return tbl;
    }();
    return t;
}

// Считает CRC32 над буфером data[0..len). Возвращает 0 для пустого буфера.
inline uint32_t compute(const void* data, std::size_t len) {
    const auto& tbl = table();
    const auto* bytes = static_cast<const unsigned char*>(data);
    uint32_t crc = 0xFFFFFFFFu;
    for (std::size_t i = 0; i < len; ++i) {
        crc = tbl[(crc ^ bytes[i]) & 0xFFu] ^ (crc >> 8);
    }
    return crc ^ 0xFFFFFFFFu;
}

} // namespace crc32
