#include <catch2/catch_test_macros.hpp>
#include "app/emulator.hpp"
#include "app/options.hpp"

TEST_CASE("Seeded emulator is repeatable and delay profiles have exact bounds") {
    for (const auto* profile : {"baseline", "delay_50", "delay_100", "jitter", "loss_5", "combined"}) {
        app::Emulator a(profile, 20261031), b(profile, 20261031);
        unsigned drops = 0;
        for (int i = 0; i < 1000; ++i) {
            const auto x = a.Next(), y = b.Next();
            REQUIRE(x.drop == y.drop);
            REQUIRE(x.delayMs == y.delayMs);
            drops += x.drop;
            if (std::string(profile) == "baseline" || std::string(profile) == "loss_5")
                CHECK(x.delayMs == 0);
            if (std::string(profile) == "delay_50")
                CHECK(x.delayMs == 50);
            if (std::string(profile) == "delay_100")
                CHECK(x.delayMs == 100);
            if (std::string(profile) == "jitter" || std::string(profile) == "combined")
                CHECK((x.delayMs >= 50 && x.delayMs <= 150));
        }
        if (std::string(profile) == "loss_5" || std::string(profile) == "combined")
            CHECK((drops > 20 && drops < 90));
        else
            CHECK(drops == 0);
    }
    REQUIRE_THROWS_AS(app::Emulator("bogus", 1), std::invalid_argument);
}
TEST_CASE("Identifiers cannot corrupt CSV or JSON output") {
    REQUIRE_NOTHROW(app::ValidateId("baseline_2026-10"));
    for (const auto* id : {"", "x;y", "a\nb", "\"quoted\""})
        REQUIRE_THROWS_AS(app::ValidateId(id), std::invalid_argument);
}
