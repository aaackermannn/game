#pragma once
#include <cstdint>
#include <stdexcept>
#include <string>

namespace app {
// Explicit PRNG and integer mapping make the decisions portable across C++ libraries.
class Emulator {
public:
    struct Decision { bool drop; unsigned delayMs; };
    Emulator(const std::string& profile, std::uint32_t seed) : profile_(profile), state_(seed ? seed : 1) {
        if (profile != "baseline" && profile != "delay_50" && profile != "delay_100" && profile != "jitter" &&
            profile != "loss_5" && profile != "combined") throw std::invalid_argument("unknown emulator profile");
    }
    Decision Next() {
        const auto loss = NextRandom(); const auto jitter = NextRandom();
        const bool drop = (profile_ == "loss_5" || profile_ == "combined") && loss % 10000 < 500;
        unsigned delay = 0;
        if (profile_ == "delay_50") delay = 50;
        if (profile_ == "delay_100") delay = 100;
        if (profile_ == "jitter" || profile_ == "combined") delay = 50 + jitter % 101;
        return {drop, delay};
    }
private:
    std::uint32_t NextRandom() { state_ ^= state_ << 13; state_ ^= state_ >> 17; state_ ^= state_ << 5; return state_; }
    std::string profile_;
    std::uint32_t state_;
};
}
