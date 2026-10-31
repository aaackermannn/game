#include "telemetry/telemetry.hpp"
#include <algorithm>
#include <cmath>
#include <numeric>
#include <stdexcept>

const char* StatusName(ResponseStatus status) {
    switch (status) {
    case ResponseStatus::Received: return "received";
    case ResponseStatus::Timeout: return "timeout";
    case ResponseStatus::Late: return "late_response";
    case ResponseStatus::Duplicate: return "duplicate_response";
    case ResponseStatus::Unknown: return "unknown_response";
    case ResponseStatus::Invalid: return "invalid_response";
    }
    return "invalid_response";
}
Telemetry::Telemetry(std::uint64_t timeoutUs, std::size_t capacity) : timeoutUs_(timeoutUs), capacity_(capacity) {
    if (!timeoutUs || !capacity || capacity > 65536) throw std::invalid_argument("invalid telemetry limits");
}
bool Telemetry::OnPingSent(std::uint16_t seq, std::uint64_t now, const std::string& experiment, std::size_t sample) {
    const auto existing = inFlight_.find(seq);
    if (existing != inFlight_.end() && (existing->second.state == FlightState::Pending || now <= existing->second.sentAtUs)) return false;
    if (existing != inFlight_.end()) {
        const auto old = existing->second.sentAtUs;
        history_.erase(std::remove(history_.begin(), history_.end(), std::make_pair(seq, old)), history_.end());
        inFlight_.erase(existing);
    }
    if (inFlight_.size() == capacity_) {
        const auto removable = std::find_if(history_.begin(), history_.end(), [&](const auto& item) {
            return inFlight_.at(item.first).state != FlightState::Pending;
        });
        if (removable == history_.end()) return false;
        inFlight_.erase(removable->first); history_.erase(removable);
    }
    inFlight_.emplace(seq, FlightRecord{now, experiment, sample ? sample : counters_.sent + 1, FlightState::Pending, 1});
    history_.emplace_back(seq, now); ++pending_; ++counters_.sent; return true;
}
ResponseEvent Telemetry::Event(ResponseStatus status, std::uint16_t seq, const FlightRecord* record, std::uint64_t now,
                              std::optional<double> rtt) const {
    return {status, seq, record ? std::optional<FlightRecord>(*record) : std::nullopt,
            rtt, status == ResponseStatus::Received ? std::optional<double>(srttMs_) : std::nullopt, now};
}
std::vector<ResponseEvent> Telemetry::ProcessPong(std::uint16_t seq, std::uint64_t echo, std::uint64_t now) {
    const auto it = inFlight_.find(seq);
    if (it == inFlight_.end()) { ++counters_.unknown; return {Event(ResponseStatus::Unknown, seq, nullptr, now)}; }
    auto& f = it->second;
    if (echo != f.sentAtUs || now < f.sentAtUs) { ++counters_.invalid; return {Event(ResponseStatus::Invalid, seq, &f, now)}; }
    if (f.state == FlightState::Received || f.state == FlightState::LateReceived) {
        ++counters_.duplicates; return {Event(ResponseStatus::Duplicate, seq, &f, now)};
    }
    std::vector<ResponseEvent> events;
    if (f.state == FlightState::Pending && now - f.sentAtUs > timeoutUs_) {
        f.state = FlightState::TimedOut; --pending_; ++counters_.timeouts;
        events.push_back(Event(ResponseStatus::Timeout, seq, &f, now));
    }
    if (f.state == FlightState::TimedOut) {
        f.state = FlightState::LateReceived; ++counters_.late;
        events.push_back(Event(ResponseStatus::Late, seq, &f, now)); return events;
    }
    const double rtt = (now - f.sentAtUs) / 1000.0;
    if (!rtts_.empty()) jitterSumMs_ += std::abs(rtt - rtts_.back());
    srttMs_ = rtts_.empty() ? rtt : 0.875 * srttMs_ + 0.125 * rtt;
    rtts_.push_back(rtt); ++counters_.received; --pending_; f.state = FlightState::Received;
    events.push_back(Event(ResponseStatus::Received, seq, &f, now, rtt)); return events;
}
ResponseStatus Telemetry::OnPong(std::uint16_t seq, std::uint64_t now) {
    const auto it = inFlight_.find(seq);
    return ProcessPong(seq, it == inFlight_.end() ? 0 : it->second.sentAtUs, now).back().status;
}
std::vector<ResponseEvent> Telemetry::Expire(std::uint64_t now) {
    std::vector<ResponseEvent> events;
    for (const auto& item : history_) {
        auto& f = inFlight_.at(item.first);
        if (f.state == FlightState::Pending && now >= f.sentAtUs && now - f.sentAtUs > timeoutUs_) {
            f.state = FlightState::TimedOut; --pending_; ++counters_.timeouts;
            events.push_back(Event(ResponseStatus::Timeout, item.first, &f, now));
        }
    }
    return events;
}
double Telemetry::MeanJitterMs() const { return rtts_.size() > 1 ? jitterSumMs_ / (rtts_.size() - 1) : 0; }
Statistics Telemetry::Summary() const {
    auto s = counters_; s.jitter = MeanJitterMs(); s.lossPercent = s.sent ? 100.0 * s.timeouts / s.sent : 0;
    if (!rtts_.empty()) {
        auto sorted = rtts_; std::sort(sorted.begin(), sorted.end());
        s.min = sorted.front(); s.max = sorted.back(); s.mean = std::accumulate(sorted.begin(), sorted.end(), 0.0) / sorted.size();
        const auto n = sorted.size(); s.median = n % 2 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2; s.srtt = srttMs_;
    }
    return s;
}
