#include "reliability/reliable_channel.hpp"

#include <stdexcept>
#include <utility>

ReliableChannel::ReliableChannel(std::uint32_t maxAttempts) : maxAttempts_(maxAttempts) {
    if (maxAttempts == 0) {
        throw std::invalid_argument("maxAttempts must include the original transmission");
    }
}

bool ReliableChannel::OnSent(std::uint16_t sequence, std::vector<std::uint8_t> bytes, std::uint64_t nowUs) {
    // Нельзя перезаписывать пакет с этим номером, пока он ждёт подтверждения.
    return pending_.try_emplace(sequence, PendingPacket{sequence, std::move(bytes), nowUs, nowUs}).second;
}

std::optional<Acknowledgement> ReliableChannel::OnAckReceived(std::uint16_t sequence, std::uint64_t nowUs) {
    const auto it = pending_.find(sequence);
    if (it == pending_.end() || nowUs < it->second.lastSentAtUs) {
        return std::nullopt;
    }

    const auto& packet = it->second;
    const auto elapsedUs = nowUs - packet.firstSentAtUs;
    Acknowledgement ack{sequence, packet.attempts, elapsedUs, std::nullopt};
    // По правилу Карна измеряем RTT только там, где ACK однозначно относится к первой отправке.
    if (packet.attempts == 1) {
        ack.rttSampleMs = elapsedUs / 1000.0;
    }
    pending_.erase(it);
    return ack;
}

DeliveryBatch ReliableChannel::CollectForRetransmission(std::uint64_t nowUs,
                                                        std::uint64_t adaptiveTimeoutUs) {
    DeliveryBatch due;
    if (adaptiveTimeoutUs == 0) {
        throw std::invalid_argument("adaptiveTimeoutUs must be positive");
    }

    for (auto it = pending_.begin(); it != pending_.end();) {
        auto& packet = it->second;
        if (nowUs < packet.lastSentAtUs || nowUs - packet.lastSentAtUs < adaptiveTimeoutUs) {
            ++it;
            continue;
        }
        // После последней разрешённой отправки также ждём полный RTO для ACK.
        if (packet.attempts >= maxAttempts_) {
            due.failed.push_back(std::move(packet));
            it = pending_.erase(it);
            ++failedCount_;
            continue;
        }

        due.retransmissions.push_back(&packet);
        packet.lastSentAtUs = nowUs;
        ++packet.attempts;
        ++it;
    }
    return due;
}

SequenceStatus SequenceWindow::Observe(std::uint16_t sequence) {
    if (!newest_) {
        newest_ = sequence;
        seen_.set(0);
        return SequenceStatus::New;
    }

    // Половина диапазона uint16_t задаёт порядок по модулю 65536, включая переход 65535 → 0.
    constexpr unsigned halfRange = 32768;
    const auto forward = static_cast<std::uint16_t>(sequence - *newest_);
    if (forward != 0 && forward < halfRange) {
        seen_ <<= forward;
        newest_ = sequence;
        seen_.set(0);
        return SequenceStatus::New;
    }

    // Запоздавшую команду ещё можно применить, если её номер остаётся внутри окна.
    const auto back = static_cast<std::uint16_t>(*newest_ - sequence);
    if (back >= kCapacity) {
        return SequenceStatus::TooOld;
    }
    if (seen_.test(back)) {
        return SequenceStatus::Duplicate;
    }
    seen_.set(back);
    return SequenceStatus::New;
}
