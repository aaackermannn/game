#pragma once
#include <cstdint>
#include <stdexcept>
#include <string>

namespace app {
// Xorshift32 и целочисленные операции дают одинаковую последовательность решений при одинаковом seed.
class Emulator {
public:
    struct Decision {
        bool drop;
        unsigned delayMs;
    };
    Emulator(const std::string& profile, std::uint32_t seed) : profile_(profile), state_(seed ? seed : 1) {
        if (profile != "baseline" && profile != "delay_50" && profile != "delay_100" && profile != "jitter" &&
            profile != "loss_5" && profile != "combined" && profile != "loss_10" && profile != "loss_20" &&
            profile != "delay_100_loss_5" && profile != "jitter_loss_10")
            throw std::invalid_argument("unknown emulator profile");
    }
    Decision Next() {
        // Для каждого ответа отдельно выбираем потерю и задержку из двух чисел генератора.
        const auto loss = NextRandom();
        const auto jitter = NextRandom();
        unsigned lossThreshold = 0;
        if (profile_ == "loss_5" || profile_ == "combined" || profile_ == "delay_100_loss_5")
            lossThreshold = 500;
        if (profile_ == "loss_10" || profile_ == "jitter_loss_10")
            lossThreshold = 1000;
        if (profile_ == "loss_20")
            lossThreshold = 2000;
        unsigned delay = 0;
        if (profile_ == "delay_50")
            delay = 50;
        if (profile_ == "delay_100" || profile_ == "delay_100_loss_5")
            delay = 100;
        if (profile_ == "jitter" || profile_ == "combined" || profile_ == "jitter_loss_10")
            delay = 50 + jitter % 101;
        return {loss % 10000 < lossThreshold, delay};
    }

private:
    std::uint32_t NextRandom() {
        state_ ^= state_ << 13;
        state_ ^= state_ >> 17;
        state_ ^= state_ << 5;
        return state_;
    }
    std::string profile_;
    std::uint32_t state_;
};
}
