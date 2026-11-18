#include <catch2/catch_test_macros.hpp>
#include <catch2/catch_approx.hpp>
#include "telemetry/telemetry.hpp"
using Catch::Approx;

TEST_CASE("Known RTT sequence determines complete statistics") {
    Telemetry t;
    CHECK(t.OnPingSent(1, 0));
    CHECK(t.OnPong(1, 100000) == ResponseStatus::Received);
    CHECK(t.SrttMs() == Approx(100));
    CHECK(t.MeanJitterMs() == 0);
    CHECK(t.OnPingSent(2, 200000));
    t.OnPong(2, 320000);
    CHECK(t.SrttMs() == Approx(102.5));
    CHECK(t.OnPingSent(3, 400000));
    t.OnPong(3, 480000);
    CHECK(t.OnPingSent(4, 600000));
    CHECK(t.ExpireOverdue(1600001) == 1);
    const auto s = t.Summary();
    REQUIRE(s.mean);
    REQUIRE(s.srtt);
    CHECK(*s.min == 80);
    CHECK(*s.max == 120);
    CHECK(*s.mean == 100);
    CHECK(*s.median == 100);
    CHECK(*s.srtt == Approx(99.6875));
    CHECK(s.jitter == 30);
    CHECK(s.lossPercent == 25);
    CHECK(s.sent == s.received + s.timeouts);
    CHECK(t.PendingCount() == 0);
}
TEST_CASE("Even median and no successful data are represented correctly") {
    Telemetry t;
    CHECK_FALSE(t.Summary().mean);
    CHECK(t.Summary().lossPercent == 0);
    t.OnPingSent(1, 0);
    t.OnPong(1, 10000);
    t.OnPingSent(2, 100000);
    t.OnPong(2, 130000);
    CHECK(*t.Summary().median == 20);
    Telemetry lost;
    lost.OnPingSent(1, 0);
    lost.ExpireOverdue(1000001);
    CHECK_FALSE(lost.Summary().srtt);
    CHECK_FALSE(lost.Summary().min);
    CHECK(lost.Summary().lossPercent == 100);
}
TEST_CASE("Timeout boundary is inclusive for received PONG") {
    for (const auto delta : {999999ULL, 1000000ULL, 1000001ULL}) {
        Telemetry t;
        t.OnPingSent(1, 10);
        const auto events = t.ProcessPong(1, 10, 10 + delta);
        CHECK(events.back().status == (delta <= 1000000 ? ResponseStatus::Received : ResponseStatus::Late));
        CHECK(t.Summary().timeouts == (delta > 1000000 ? 1 : 0));
    }
    Telemetry t;
    t.OnPingSent(1, 0);
    CHECK(t.ExpireOverdue(1000000) == 0);
    CHECK(t.ExpireOverdue(1000001) == 1);
    CHECK(t.ExpireOverdue(2000000) == 0);
}
TEST_CASE("Late after expiration is not a duplicate and never erases loss") {
    for (const bool expireFirst : {false, true}) {
        Telemetry t;
        t.OnPingSent(1, 0);
        if (expireFirst)
            CHECK(t.ExpireOverdue(1000001) == 1);
        auto events = t.ProcessPong(1, 0, 1200000);
        CHECK(events.size() == (expireFirst ? 1 : 2));
        CHECK(events.back().status == ResponseStatus::Late);
        CHECK(t.OnPong(1, 1300000) == ResponseStatus::Duplicate);
        const auto s = t.Summary();
        CHECK(s.timeouts == 1);
        CHECK(s.late == 1);
        CHECK(s.duplicates == 1);
        CHECK(s.received == 0);
        CHECK(s.lossPercent == 100);
        CHECK_FALSE(s.srtt);
    }
}
TEST_CASE("Duplicate unknown invalid timestamps and reordered answers do not corrupt metrics") {
    Telemetry t;
    t.OnPingSent(1, 100);
    t.OnPingSent(2, 200);
    CHECK(t.ProcessPong(1, 101, 1000).back().status == ResponseStatus::Invalid);
    CHECK(t.ProcessPong(1, 100, 99).back().status == ResponseStatus::Invalid);
    CHECK(t.OnPong(999, 500) == ResponseStatus::Unknown);
    CHECK(t.PendingCount() == 2);
    CHECK(t.OnPong(2, 10200) == ResponseStatus::Received);
    CHECK(t.OnPong(1, 20100) == ResponseStatus::Received);
    CHECK(t.OnPong(1, 30000) == ResponseStatus::Duplicate);
    CHECK(t.SampleCount() == 2);
    CHECK(*t.Summary().srtt == Approx(11.25));
    CHECK(t.MeanJitterMs() == 10);
}
TEST_CASE("Records are bounded pending entries cannot be overwritten and history expires") {
    Telemetry t(1000000, 2);
    CHECK(t.OnPingSent(65535, 0, "a", 1));
    CHECK(t.OnPingSent(0, 100, "a", 2));
    CHECK_FALSE(t.OnPingSent(65535, 200));
    CHECK_FALSE(t.OnPingSent(1, 200));
    t.OnPong(65535, 1000);
    CHECK(t.OnPingSent(1, 2000));
    CHECK(t.RecordCount() == 2);
    CHECK(t.OnPong(65535, 3000) == ResponseStatus::Unknown);
    t.OnPong(0, 4000);
    CHECK(t.OnPingSent(0, 5000, "b", 1));
    CHECK(t.ProcessPong(0, 100, 6000).back().status == ResponseStatus::Invalid);
    CHECK(t.ProcessPong(0, 5000, 6000).back().status == ResponseStatus::Received);
    CHECK(t.RecordCount() == 2);
    REQUIRE_THROWS_AS(Telemetry(0), std::invalid_argument);
    REQUIRE_THROWS_AS(Telemetry(1, 0), std::invalid_argument);
}
TEST_CASE("Runs do not share smoothing or pending records") {
    Telemetry a, b;
    a.OnPingSent(1, 0, "a");
    a.OnPong(1, 100000);
    CHECK(b.OnPong(1, 200000) == ResponseStatus::Unknown);
    CHECK_FALSE(b.Summary().srtt);
}
