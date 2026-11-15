#pragma once

#include <cstdint>

class AdaptiveTimeout {
public:
    // Получает RTT успешной пробы PONG или однозначного ACK.
    void OnSample(double rttMs);

    double SrttMs() const { return srttMs_; }
    double RttVarMs() const { return rttVarMs_; }
    double RtoMs() const;
    std::uint64_t RtoUs() const;

private:
    static constexpr double kBeta = 0.25;
    static constexpr double kMinRtoMs = 100.0;
    static constexpr double kMaxRtoMs = 3000.0;
    static constexpr double kInitialRtoMs = 1000.0;

    double srttMs_ = 0.0;
    double rttVarMs_ = 0.0;
    bool initialized_ = false;
};
