#include "reliability/adaptive_timeout.hpp"
#include "reliability/reliable_channel.hpp"

#include <catch2/catch_approx.hpp>
#include <catch2/catch_test_macros.hpp>
#include <limits>
#include <stdexcept>

using Catch::Approx;

TEST_CASE("Reliability resends the original bytes no more than once per RTO") {
    ReliableChannel channel(3);
    const std::vector<std::uint8_t> original{0x04, 0x00, 0x01};
    REQUIRE(channel.OnSent(1, original, 50));
    REQUIRE_FALSE(channel.OnSent(1, {0x99}, 55));
    CHECK(channel.CollectForRetransmission(49, 200'000).retransmissions.empty());
    CHECK(channel.CollectForRetransmission(200'049, 200'000).retransmissions.empty());

    const auto due = channel.CollectForRetransmission(200'050, 200'000);
    REQUIRE(due.retransmissions.size() == 1);
    CHECK(due.retransmissions.front()->sequence == 1);
    CHECK(due.retransmissions.front()->rawBytes == original);
    CHECK(due.retransmissions.front()->attempts == 2);
    CHECK(due.retransmissions.front()->firstSentAtUs == 50);
    CHECK(due.retransmissions.front()->lastSentAtUs == 200'050);
    CHECK(due.failed.empty());
    CHECK(channel.CollectForRetransmission(200'050, 200'000).retransmissions.empty());
    CHECK(channel.CollectForRetransmission(500'049, 300'000).retransmissions.empty());

    const auto next = channel.CollectForRetransmission(500'050, 300'000);
    REQUIRE(next.retransmissions.size() == 1);
    CHECK(next.retransmissions.front()->attempts == 3);
}

TEST_CASE("The attempt limit includes the original datagram and waits for the last ACK") {
    ReliableChannel channel(2);
    REQUIRE(channel.OnSent(7, {0x07}, 0));
    REQUIRE(channel.CollectForRetransmission(200'000, 200'000).retransmissions.size() == 1);
    CHECK(channel.CollectForRetransmission(399'999, 200'000).failed.empty());
    CHECK(channel.PendingCount() == 1);
    CHECK(channel.FailedCount() == 0);

    const auto due = channel.CollectForRetransmission(400'000, 200'000);
    CHECK(due.retransmissions.empty());
    REQUIRE(due.failed.size() == 1);
    CHECK(due.failed.front().sequence == 7);
    CHECK(due.failed.front().attempts == 2);
    CHECK(channel.PendingCount() == 0);
    CHECK(channel.FailedCount() == 1);
    CHECK_FALSE(channel.OnAckReceived(7, 400'100));
    CHECK(channel.CollectForRetransmission(1'000'000, 200'000).failed.empty());
    CHECK(channel.FailedCount() == 1);
}

TEST_CASE("Only first-attempt ACKs produce RTT samples and duplicates are ignored") {
    ReliableChannel channel;
    REQUIRE(channel.OnSent(3, {}, 500));
    REQUIRE(channel.OnSent(4, {}, 1000));
    CHECK_FALSE(channel.OnAckReceived(3, 499));
    CHECK_FALSE(channel.OnAckReceived(999, 600));

    const auto first = channel.OnAckReceived(3, 750);
    REQUIRE(first);
    CHECK(first->sequence == 3);
    CHECK(first->attempts == 1);
    CHECK(first->timeToAckUs == 250);
    REQUIRE(first->rttSampleMs);
    CHECK(*first->rttSampleMs == Approx(0.25));
    CHECK_FALSE(channel.OnAckReceived(3, 751));

    REQUIRE(channel.CollectForRetransmission(201'000, 200'000).retransmissions.size() == 1);
    const auto retry = channel.OnAckReceived(4, 250'000);
    REQUIRE(retry);
    CHECK(retry->attempts == 2);
    CHECK(retry->timeToAckUs == 249'000);
    CHECK_FALSE(retry->rttSampleMs);
    CHECK(channel.PendingCount() == 0);
}

TEST_CASE("A single attempt never retransmits and zero limits are rejected") {
    REQUIRE_THROWS_AS(ReliableChannel(0), std::invalid_argument);
    ReliableChannel channel(1);
    REQUIRE(channel.OnSent(1, {}, 0));
    CHECK_THROWS_AS(channel.CollectForRetransmission(1, 0), std::invalid_argument);
    const auto due = channel.CollectForRetransmission(100'000, 100'000);
    CHECK(due.retransmissions.empty());
    CHECK(due.failed.size() == 1);
}

TEST_CASE("Jacobson estimation uses deviation from the old SRTT and clamps the result") {
    AdaptiveTimeout timeout;
    CHECK(timeout.RtoMs() == 1000.0);
    timeout.OnSample(std::numeric_limits<double>::infinity());
    timeout.OnSample(-20.0);
    CHECK(timeout.RtoMs() == 1000.0);

    timeout.OnSample(100.0);
    CHECK(timeout.SrttMs() == Approx(100.0));
    CHECK(timeout.RttVarMs() == Approx(50.0));
    CHECK(timeout.RtoMs() == Approx(300.0));

    timeout.OnSample(120.0);
    CHECK(timeout.SrttMs() == Approx(102.5));
    CHECK(timeout.RttVarMs() == Approx(42.5));
    CHECK(timeout.RtoUs() == 272'500);

    AdaptiveTimeout quick;
    quick.OnSample(1.0);
    CHECK(quick.RtoUs() == 100'000);
    AdaptiveTimeout slow;
    slow.OnSample(1200.0);
    CHECK(slow.RtoUs() == 3'000'000);

    AdaptiveTimeout rounded;
    rounded.OnSample(100.00025);
    CHECK(rounded.RtoUs() == 300'001);
}

TEST_CASE("Sequence windows handle wraparound, reordering, duplicates and old traffic") {
    SequenceWindow endpoint;
    CHECK(endpoint.Observe(65'534) == SequenceStatus::New);
    CHECK(endpoint.Observe(0) == SequenceStatus::New);
    CHECK(endpoint.Observe(65'535) == SequenceStatus::New);
    CHECK(endpoint.Observe(65'535) == SequenceStatus::Duplicate);
    CHECK(endpoint.Observe(65'534) == SequenceStatus::Duplicate);

    CHECK(endpoint.Observe(1023) == SequenceStatus::New);
    CHECK(endpoint.Observe(0) == SequenceStatus::Duplicate);
    CHECK(endpoint.Observe(65'535) == SequenceStatus::TooOld);
    CHECK(endpoint.Observe(1023 + 32'768) == SequenceStatus::TooOld);
    CHECK(endpoint.Observe(3000) == SequenceStatus::New);
    CHECK(endpoint.Observe(1023) == SequenceStatus::TooOld);
    CHECK(endpoint.Observe(2999) == SequenceStatus::New);

    SequenceWindow otherEndpoint;
    CHECK(otherEndpoint.Observe(0) == SequenceStatus::New);
}
