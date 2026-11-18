#include "app/emulator.hpp"
#include "app/options.hpp"
#include "protocol/packet.hpp"
#include "reliability/reliable_channel.hpp"
#include "transport/udp_socket.hpp"
#include <algorithm>
#include <csignal>
#include <iostream>
#include <queue>
#include <unordered_map>

namespace {
constexpr std::size_t MaxQueuedReplies = 4096;
constexpr std::size_t MaxClientEndpoints = 4096;
volatile std::sig_atomic_t running = 1;
void Stop(int) {
    running = 0;
}
struct Pending {
    std::uint64_t due, order;
    transport::Endpoint destination;
    std::uint16_t sequence;
    std::optional<PongPayload> pong; // Если PONG отсутствует, очередь хранит ACK.
    // Вершина очереди хранит ближайший срок отправки. При равных сроках сохраняем порядок поступления.
    bool operator<(const Pending& other) const {
        return due == other.due ? order > other.order : due > other.due;
    }
};
}
int main(int argc, char** argv) {
    if (argc == 2 && std::string(argv[1]) == "--help") {
        std::cout
            << "server --bind 127.0.0.1 --port 27015 --profile baseline --seed 20261031 --duration-ms 0\n";
        return 0;
    }
    try {
        app::Options opts(argc, argv, {"--bind", "--port", "--profile", "--seed", "--duration-ms"});
        const auto port = opts.Number("--port", 27015, 1, 65535);
        const auto duration = opts.Number("--duration-ms", 0, 0, 86400000);
        const auto seed = opts.Number("--seed", 20261031, 1, 0xffffffffu);
        const auto profile = opts.Text("--profile", "baseline");
        app::Emulator emulator(profile, static_cast<std::uint32_t>(seed));
        // Пробы PING не сдвигают последовательность потерь ACK при том же seed.
        app::Emulator ackEmulator(profile, static_cast<std::uint32_t>(seed));
        transport::UdpSocket socket(opts.Text("--bind", "127.0.0.1"), std::to_string(port), true);
        std::signal(SIGINT, Stop);
        std::signal(SIGTERM, Stop);
        std::priority_queue<Pending> queue;
        std::unordered_map<std::string, SequenceWindow> clientWindows;
        const auto start = app::NowUs();
        std::uint64_t order = 0;
        std::cout << "READY " << socket.Peer().ToString() << " profile=" << profile << " seed=" << seed
                  << std::endl;
        while (running && (!duration || app::NowUs() - start < duration * 1000)) {
            // Метку отправки ставим перед отправкой PONG, чтобы серверные метки отражали время в очереди.
            while (!queue.empty() && queue.top().due <= app::NowUs()) {
                auto packet = queue.top();
                queue.pop();
                if (packet.pong) {
                    packet.pong->serverSendTimeUs = app::NowUs();
                    socket.SendTo(SerializePong(packet.sequence, *packet.pong), packet.destination);
                    std::cout << "PONG seq=" << packet.sequence << " peer=" << packet.destination.ToString()
                              << std::endl;
                } else {
                    socket.SendTo(SerializeAck(packet.sequence), packet.destination);
                }
            }
            const auto now = app::NowUs();
            // Ждём входящий пакет до ближайшей отправки, округляя ожидание до мс и ограничивая его 10 мс.
            const int wait = queue.empty()
                                 ? 10
                                 : static_cast<int>(std::min<std::uint64_t>(
                                       10, (queue.top().due > now ? queue.top().due - now + 999 : 0) / 1000));
            const auto datagram = socket.Receive(wait);
            if (!datagram)
                continue;
            const auto received = app::NowUs();
            ParseError error{};
            auto header = ParseHeader(datagram->bytes.data(), datagram->bytes.size(), &error);
            if (!header) {
                std::cout << "REJECT " << ParseErrorName(error) << " peer=" << datagram->from.ToString()
                          << std::endl;
                continue;
            }
            if (header->type == PacketType::Shoot) {
                const auto shoot =
                    ParseShoot(datagram->bytes.data(), datagram->bytes.size(), *header, &error);
                const auto peer = datagram->from.ToString();
                if (!shoot) {
                    std::cout << "REJECT " << ParseErrorName(error) << " peer=" << peer << std::endl;
                    continue;
                }
                auto window = clientWindows.find(peer);
                if (window == clientWindows.end()) {
                    if (clientWindows.size() >= MaxClientEndpoints) {
                        std::cerr << "REJECT client_window_capacity peer=" << peer << '\n';
                        continue;
                    }
                    window = clientWindows.try_emplace(peer).first;
                }
                const auto sequence = header->sequenceNumber;
                const auto status = window->second.Observe(sequence);
                if (status == SequenceStatus::TooOld) {
                    // За границей окна сервер не может подтвердить, применялся ли именно этот выстрел.
                    std::cout << "STALE seq=" << sequence << " peer=" << peer << std::endl;
                    continue;
                }

                // Запланировать ACK нужно и для дубля, но применить выстрел можно только для нового номера.
                const auto decision = ackEmulator.Next();
                std::cout << "ACK seq=" << sequence << " peer=" << peer << " drop=" << decision.drop
                          << " delay_ms=" << decision.delayMs << std::endl;
                if (!decision.drop) {
                    if (decision.delayMs == 0)
                        socket.SendTo(SerializeAck(sequence), datagram->from);
                    else if (queue.size() < MaxQueuedReplies)
                        queue.push(Pending{received + decision.delayMs * 1000, order++, datagram->from,
                                           sequence, std::nullopt});
                    else
                        std::cerr << "REJECT send_queue_full\n";
                }
                if (status == SequenceStatus::New) {
                    // В учебном выделенном сервере эта запись представляет один вызов обработки выстрела.
                    std::cout << "COMMAND type=4 seq=" << sequence << " peer=" << peer
                              << " weapon_id=" << shoot->weaponId << " dir_x=" << shoot->dirX
                              << " dir_y=" << shoot->dirY << std::endl;
                } else {
                    std::cout << "DUPLICATE seq=" << sequence << " peer=" << peer << std::endl;
                }
                continue;
            }
            if (header->type == PacketType::Movement) {
                std::cout << "COMMAND type=" << static_cast<unsigned>(header->type)
                          << " seq=" << header->sequenceNumber << std::endl;
                continue;
            }
            PacketHeader pingHeader{};
            const auto ping = ParsePing(datagram->bytes.data(), datagram->bytes.size(), pingHeader, &error);
            if (!ping) {
                std::cout << "REJECT " << ParseErrorName(error) << std::endl;
                continue;
            }
            const auto decision = emulator.Next();
            std::cout << "PING seq=" << header->sequenceNumber << " peer=" << datagram->from.ToString()
                      << " drop=" << decision.drop << " delay_ms=" << decision.delayMs << std::endl;
            if (decision.drop)
                continue;
            if (queue.size() >= MaxQueuedReplies) {
                std::cerr << "REJECT send_queue_full\n";
                continue;
            }
            // Сохраняем адрес отправителя и исходную метку клиента. Очередь позволяет принимать новые PING во время задержки.
            queue.push(Pending{received + decision.delayMs * 1000, order++, datagram->from,
                               header->sequenceNumber, PongPayload{ping->clientSendTimeUs, received, 0}});
        }
        std::cout << "STOP pending=" << queue.size() << std::endl;
        return 0;
    } catch (const std::exception& e) {
        std::cerr << "server: " << e.what() << '\n';
        return 1;
    }
}
