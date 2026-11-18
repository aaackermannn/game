#pragma once
#include <chrono>
#include <cstdint>
#include <initializer_list>
#include <map>
#include <set>
#include <stdexcept>
#include <string>

namespace app {
// Монотонные часы позволяют измерять RTT независимо от изменений системной даты и времени.
inline std::uint64_t NowUs() {
    return static_cast<std::uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(
                                          std::chrono::steady_clock::now().time_since_epoch())
                                          .count());
}
class Options {
public:
    Options(int argc, char** argv, std::initializer_list<std::string> allowed) {
        const std::set<std::string> names(allowed);
        for (int i = 1; i < argc; ++i) {
            const std::string key = argv[i];
            if (!names.count(key) || i + 1 == argc || values_.count(key))
                throw std::invalid_argument("invalid/duplicate option: " + key);
            values_[key] = argv[++i];
        }
    }
    std::string Text(const std::string& key, const std::string& fallback) const {
        const auto it = values_.find(key);
        return it == values_.end() ? fallback : it->second;
    }
    std::uint64_t Number(const std::string& key, std::uint64_t fallback, std::uint64_t low,
                         std::uint64_t high) const {
        const auto s = Text(key, std::to_string(fallback));
        if (s.empty() || s.find_first_not_of("0123456789") != std::string::npos)
            throw std::invalid_argument("invalid integer: " + key);
        const auto n = std::stoull(s);
        if (n < low || n > high)
            throw std::invalid_argument("out of range: " + key);
        return n;
    }

private:
    std::map<std::string, std::string> values_;
};
// Ограничиваем алфавит идентификаторов, чтобы их можно было записать в CSV и JSON без экранирования.
inline void ValidateId(const std::string& id) {
    if (id.empty() || id.size() > 80 ||
        id.find_first_not_of("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-") !=
            std::string::npos)
        throw std::invalid_argument("id must contain 1..80 ASCII letters, digits, '_' or '-'");
}
}
