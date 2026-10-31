#pragma once
#include <cstddef>
#include <cstdint>
#include <deque>
#include <optional>
#include <string>
#include <unordered_map>
#include <vector>

enum class ResponseStatus { Received, Timeout, Late, Duplicate, Unknown, Invalid };
const char* StatusName(ResponseStatus status);
enum class FlightState { Pending, Received, TimedOut, LateReceived };
struct FlightRecord {
    std::uint64_t sentAtUs = 0;
    std::string experimentId;
    std::size_t sample = 0;
    FlightState state = FlightState::Pending;
    unsigned attempts = 1;
};
struct ResponseEvent {
    ResponseStatus status;
    std::uint16_t sequence;
    std::optional<FlightRecord> flight;
    std::optional<double> rttMs, srttMs;
    std::uint64_t atUs;
};
struct Statistics {
    std::size_t sent = 0, received = 0, timeouts = 0, late = 0, duplicates = 0, unknown = 0, invalid = 0;
    std::optional<double> min, max, mean, median, srtt;
    double jitter = 0, lossPercent = 0;
};
class Telemetry {
public:
    explicit Telemetry(std::uint64_t timeoutUs = 1'000'000, std::size_t capacity = 1024);
    bool OnPingSent(std::uint16_t sequence, std::uint64_t nowUs, const std::string& experimentId = "test", std::size_t sample = 0);
    // Emits timeout + late_response atomically if the expiration scan has not run yet.
    std::vector<ResponseEvent> ProcessPong(std::uint16_t sequence, std::uint64_t echoedUs, std::uint64_t nowUs);
    ResponseStatus OnPong(std::uint16_t sequence, std::uint64_t nowUs);
    std::vector<ResponseEvent> Expire(std::uint64_t nowUs);
    std::size_t ExpireOverdue(std::uint64_t nowUs) { return Expire(nowUs).size(); }
    Statistics Summary() const;
    double SrttMs() const { return srttMs_; }
    double MeanJitterMs() const;
    std::size_t SampleCount() const { return rtts_.size(); }
    std::size_t PendingCount() const { return pending_; }
    std::size_t RecordCount() const { return inFlight_.size(); }
private:
    ResponseEvent Event(ResponseStatus status, std::uint16_t seq, const FlightRecord* record, std::uint64_t nowUs,
                        std::optional<double> rtt = std::nullopt) const;
    std::uint64_t timeoutUs_;
    std::size_t capacity_, pending_ = 0;
    std::unordered_map<std::uint16_t, FlightRecord> inFlight_;
    std::deque<std::pair<std::uint16_t, std::uint64_t>> history_;
    Statistics counters_;
    std::vector<double> rtts_;
    double srttMs_ = 0, jitterSumMs_ = 0;
};
