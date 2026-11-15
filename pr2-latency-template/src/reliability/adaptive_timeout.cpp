#include "reliability/adaptive_timeout.hpp"
#include "telemetry/telemetry.hpp"

#include <algorithm>
#include <cmath>

void AdaptiveTimeout::OnSample(double rttMs) {
    if (!std::isfinite(rttMs) || rttMs < 0.0) {
        return;
    }
    if (!initialized_) {
        srttMs_ = rttMs;
        rttVarMs_ = rttMs / 2.0;
        initialized_ = true;
        return;
    }

    // Отклонение вычисляется по прежнему SRTT, до добавления нового измерения.
    rttVarMs_ = (1.0 - kBeta) * rttVarMs_ + kBeta * std::abs(srttMs_ - rttMs);
    srttMs_ = SmoothSrtt(srttMs_, rttMs);
}

double AdaptiveTimeout::RtoMs() const {
    if (!initialized_) {
        return kInitialRtoMs;
    }
    return std::clamp(srttMs_ + 4.0 * rttVarMs_, kMinRtoMs, kMaxRtoMs);
}

std::uint64_t AdaptiveTimeout::RtoUs() const {
    // Округляем вверх, чтобы пересылка не началась раньше рассчитанного срока.
    return static_cast<std::uint64_t>(std::ceil(RtoMs() * 1000.0));
}
