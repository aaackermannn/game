#include "app/emulator.hpp"
#include "app/options.hpp"
#include "protocol/packet.hpp"
#include "transport/udp_socket.hpp"
#include <algorithm>
#include <csignal>
#include <iostream>
#include <queue>

namespace {
volatile std::sig_atomic_t running = 1;
void Stop(int) { running = 0; }
struct Pending {
    std::uint64_t due, order;
    transport::Endpoint destination;
    std::uint16_t sequence;
    PongPayload payload;
    bool operator<(const Pending& other) const { return due == other.due ? order > other.order : due > other.due; }
};
}
int main(int argc, char** argv) {
    if (argc == 2 && std::string(argv[1]) == "--help") {
        std::cout << "server --bind 127.0.0.1 --port 27015 --profile baseline --seed 20261031 --duration-ms 0\n"; return 0;
    }
    try {
        app::Options opts(argc, argv, {"--bind", "--port", "--profile", "--seed", "--duration-ms"});
        const auto port = opts.Number("--port", 27015, 1, 65535);
        const auto duration = opts.Number("--duration-ms", 0, 0, 86400000);
        const auto seed = opts.Number("--seed", 20261031, 1, 0xffffffffu);
        const auto profile = opts.Text("--profile", "baseline");
        app::Emulator emulator(profile, static_cast<std::uint32_t>(seed));
        transport::UdpSocket socket(opts.Text("--bind", "127.0.0.1"), std::to_string(port), true);
        std::signal(SIGINT, Stop); std::signal(SIGTERM, Stop);
        std::priority_queue<Pending> queue;
        const auto start = app::NowUs(); std::uint64_t order = 0;
        std::cout << "READY " << socket.Peer().ToString() << " profile=" << profile << " seed=" << seed << std::endl;
        while (running && (!duration || app::NowUs() - start < duration * 1000)) {
            while (!queue.empty() && queue.top().due <= app::NowUs()) {
                auto packet = queue.top(); queue.pop();
                packet.payload.serverSendTimeUs = app::NowUs();
                socket.SendTo(SerializePong(packet.sequence, packet.payload), packet.destination);
                std::cout << "PONG seq=" << packet.sequence << " peer=" << packet.destination.ToString() << std::endl;
            }
            const auto now = app::NowUs();
            const int wait = queue.empty() ? 10 : static_cast<int>(std::min<std::uint64_t>(10, (queue.top().due > now ? queue.top().due - now + 999 : 0) / 1000));
            const auto datagram = socket.Receive(wait);
            if (!datagram) continue;
            const auto received = app::NowUs();
            ParseError error{}; const auto header = ParseHeader(datagram->bytes.data(), datagram->bytes.size(), &error);
            if (!header) { std::cout << "REJECT " << ParseErrorName(error) << " peer=" << datagram->from.ToString() << std::endl; continue; }
            if (header->type == PacketType::Movement || header->type == PacketType::Shoot) {
                std::cout << "COMMAND type=" << static_cast<unsigned>(header->type) << " seq=" << header->sequenceNumber << std::endl; continue;
            }
            PacketHeader pingHeader{};
            const auto ping = ParsePing(datagram->bytes.data(), datagram->bytes.size(), pingHeader, &error);
            if (!ping) { std::cout << "REJECT " << ParseErrorName(error) << std::endl; continue; }
            const auto decision = emulator.Next();
            std::cout << "PING seq=" << header->sequenceNumber << " peer=" << datagram->from.ToString()
                      << " drop=" << decision.drop << " delay_ms=" << decision.delayMs << std::endl;
            if (decision.drop) continue;
            if (queue.size() >= 4096) { std::cerr << "REJECT send_queue_full\n"; continue; }
            queue.push(Pending{received + decision.delayMs * 1000, order++, datagram->from, header->sequenceNumber,
                               PongPayload{ping->clientSendTimeUs, received, 0}});
        }
        std::cout << "STOP pending=" << queue.size() << std::endl; return 0;
    } catch (const std::exception& e) { std::cerr << "server: " << e.what() << '\n'; return 1; }
}
