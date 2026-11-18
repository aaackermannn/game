#pragma once

#include <bitset>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <unordered_map>
#include <vector>

struct PendingPacket {
    std::uint16_t sequence;
    std::vector<std::uint8_t> rawBytes;
    std::uint64_t firstSentAtUs;
    std::uint64_t lastSentAtUs;
    std::uint32_t attempts = 1;
};

struct Acknowledgement {
    std::uint16_t sequence;
    std::uint32_t attempts;
    std::uint64_t timeToAckUs;
    std::optional<double> rttSampleMs;
};

struct DeliveryBatch {
    // Указатели действуют, пока соответствующие записи остаются в канале.
    std::vector<const PendingPacket*> retransmissions;
    std::vector<PendingPacket> failed;
};

class ReliableChannel {
public:
    explicit ReliableChannel(std::uint32_t maxAttempts = 5);

    bool OnSent(std::uint16_t sequence, std::vector<std::uint8_t> bytes, std::uint64_t nowUs);
    std::optional<Acknowledgement> OnAckReceived(std::uint16_t sequence, std::uint64_t nowUs);
    DeliveryBatch CollectForRetransmission(std::uint64_t nowUs, std::uint64_t adaptiveTimeoutUs);

    std::size_t PendingCount() const {
        return pending_.size();
    }
    std::size_t FailedCount() const {
        return failedCount_;
    }

private:
    std::uint32_t maxAttempts_;
    std::unordered_map<std::uint16_t, PendingPacket> pending_;
    std::size_t failedCount_ = 0;
};

enum class SequenceStatus { New, Duplicate, TooOld };

// Сервер выделяет отдельное окно для каждого адреса и порта клиента.
class SequenceWindow {
public:
    static constexpr std::size_t kCapacity = 1024;

    SequenceStatus Observe(std::uint16_t sequence);

private:
    std::optional<std::uint16_t> newest_;
    std::bitset<kCapacity> seen_;
};
