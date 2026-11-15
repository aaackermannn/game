#include "app/options.hpp"
#include "app/reliability_client.hpp"
#include "protocol/packet.hpp"
#include "telemetry/telemetry.hpp"
#include "transport/udp_socket.hpp"
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <locale>
#include <sstream>

namespace {
constexpr const char* CsvHeader =
    "experiment_id;sample;sequence;sent_at_ms;rtt_ms;srtt_ms;status;run_id;event_index;received_at_ms;attempts;server_receive_us;server_send_us";
class Csv {
public:
    Csv(const std::filesystem::path& path, std::string experiment, std::string run, std::uint64_t start)
        : experiment_(std::move(experiment)), run_(std::move(run)), start_(start) {
        if (!path.parent_path().empty())
            std::filesystem::create_directories(path.parent_path());
        const bool existing = std::filesystem::exists(path) && std::filesystem::file_size(path) > 0;
        if (existing) {
            // Проверяем схему и уникальность run_id до записи, чтобы сохранить результаты прошлых запусков.
            std::ifstream input(path);
            std::string header;
            std::getline(input, header);
            if (!header.empty() && header.back() == '\r')
                header.pop_back();
            if (header != CsvHeader)
                throw std::runtime_error("existing CSV has incompatible schema");
            std::string line;
            while (std::getline(input, line)) {
                std::istringstream row(line);
                std::string value;
                for (int i = 0; i < 8 && std::getline(row, value, ';'); ++i)
                    if (i == 7 && value == run_)
                        throw std::runtime_error("run-id already present in CSV");
            }
        }
        out_.open(path, std::ios::app);
        out_.imbue(std::locale::classic());
        if (!out_)
            throw std::runtime_error("cannot open CSV");
        out_ << std::fixed << std::setprecision(6);
        if (!existing)
            out_ << CsvHeader << '\n';
    }
    void Write(const ResponseEvent& e, const PongPayload* pong = nullptr) {
        // Клиентские метки пишем в мс от начала серии. Отсутствующие RTT и SRTT оставляем пустыми.
        out_ << experiment_ << ';';
        if (e.flight)
            out_ << e.flight->sample;
        out_ << ';' << e.sequence << ';';
        if (e.flight)
            out_ << (e.flight->sentAtUs - start_) / 1000.0;
        out_ << ';';
        if (e.rttMs)
            out_ << *e.rttMs;
        out_ << ';';
        if (e.srttMs)
            out_ << *e.srttMs;
        out_ << ';' << StatusName(e.status) << ';' << run_ << ';' << ++event_ << ';'
             << (e.atUs - start_) / 1000.0 << ';';
        if (e.flight)
            out_ << e.flight->attempts;
        out_ << ';';
        if (pong)
            out_ << pong->serverReceiveTimeUs;
        out_ << ';';
        if (pong)
            out_ << pong->serverSendTimeUs;
        out_ << '\n';
        out_.flush();
        if (!out_)
            throw std::runtime_error("CSV write failed");
    }

private:
    std::ofstream out_;
    std::string experiment_, run_;
    std::uint64_t start_, event_ = 0;
};
void Number(std::ostream& out, const std::optional<double>& n) {
    if (n)
        out << *n;
    else
        out << "null";
}
}
int main(int argc, char** argv) {
    if (argc == 2 && std::string(argv[1]) == "--help") {
        std::cout
            << "client --host 127.0.0.1 --port 27015 --experiment baseline --count 50 --interval-ms 500 --timeout-ms 1000 --grace-ms 1200 --csv docs/latency_samples.csv --run-id unique_id\n"
            << "client --mode reliability --count 50 --interval-ms 200 --max-attempts 5 --ping-interval-ms 500 --csv docs/reliability_samples.csv\n";
        return 0;
    }
    try {
        app::Options opts(argc, argv,
                          {"--host", "--port", "--experiment", "--count", "--interval-ms", "--timeout-ms",
                           "--grace-ms", "--csv", "--run-id", "--mode", "--max-attempts", "--ping-interval-ms"});
        const auto mode = opts.Text("--mode", "latency");
        if (mode == "reliability")
            return app::RunReliability(opts);
        if (mode != "latency")
            throw std::invalid_argument("unknown client mode");
        const auto port = opts.Number("--port", 27015, 1, 65535);
        const auto count = opts.Number("--count", 50, 1, 60000);
        const auto interval = opts.Number("--interval-ms", 500, 200, 1000) * 1000;
        const auto timeout = opts.Number("--timeout-ms", 1000, 1, 60000) * 1000;
        const auto grace = opts.Number("--grace-ms", 1200, 0, 60000) * 1000;
        const auto experiment = opts.Text("--experiment", "baseline");
        app::ValidateId(experiment);
        const auto run = opts.Text("--run-id", "run_" + std::to_string(app::NowUs()));
        app::ValidateId(run);
        transport::UdpSocket socket(opts.Text("--host", "127.0.0.1"), std::to_string(port), false);
        const auto start = app::NowUs();
        Csv csv(opts.Text("--csv", "docs/latency_samples.csv"), experiment, run, start);
        Telemetry telemetry(timeout);
        std::size_t sent = 0, malformed = 0, foreign = 0;
        std::uint64_t lastSend = start;
        while (true) {
            auto now = app::NowUs();
            // Срок следующей отправки отсчитывается от начала серии независимо от прихода PONG.
            if (sent < count && now >= start + sent * interval) {
                const auto sequence = static_cast<std::uint16_t>(sent);
                if (now - (start + sent * interval) > interval)
                    std::cerr << "schedule_overrun sample=" << sent + 1 << '\n';
                const auto packet = SerializePing(sequence, now);
                socket.Send(packet);
                // Регистрируем пробу после успешной отправки. Номер пакета начинается с 0, номер пробы в CSV с 1.
                if (!telemetry.OnPingSent(sequence, now, experiment, sent + 1))
                    throw std::runtime_error("inFlight capacity/sequence collision");
                lastSend = now;
                ++sent;
            }
            // Короткое ожидание приёма позволяет регулярно возвращаться к отправкам и тайм-аутам.
            const auto packet = socket.Receive(1);
            if (packet) {
                now = app::NowUs();
                // Проверяем адрес и порт отправителя, формат пакета и порядок серверных меток.
                if (!(packet->from == socket.Peer())) {
                    ++foreign;
                    std::cerr << "REJECT foreign_endpoint " << packet->from.ToString() << '\n';
                } else {
                    PacketHeader header{};
                    ParseError error{};
                    const auto pong = ParsePong(packet->bytes.data(), packet->bytes.size(), header, &error);
                    if (!pong || pong->serverSendTimeUs < pong->serverReceiveTimeUs) {
                        ++malformed;
                        std::cerr << "REJECT " << (pong ? "server_time_order" : ParseErrorName(error))
                                  << '\n';
                    } else
                        for (const auto& event :
                             telemetry.ProcessPong(header.sequenceNumber, pong->clientSendTimeUs, now)) {
                            csv.Write(event, event.status == ResponseStatus::Timeout ? nullptr : &*pong);
                            if (event.status != ResponseStatus::Received)
                                std::cerr << StatusName(event.status) << " seq=" << event.sequence << '\n';
                        }
                }
            }
            // Expire фиксирует тайм-ауты и при полном отсутствии ответов.
            now = app::NowUs();
            for (const auto& event : telemetry.Expire(now))
                csv.Write(event);
            // После последней отправки оставляем окно для поздних ответов и дубликатов.
            if (sent == count && telemetry.PendingCount() == 0 && now - lastSend > timeout + grace)
                break;
        }
        // Скрипт эксперимента читает итоговый JSON после префикса SUMMARY и сохраняет его в manifest.
        const auto s = telemetry.Summary();
        std::cout.imbue(std::locale::classic());
        std::cout << std::fixed << std::setprecision(6);
        std::cout << "SUMMARY {\"experiment_id\":\"" << experiment << "\",\"run_id\":\"" << run
                  << "\",\"sent\":" << s.sent << ",\"received\":" << s.received
                  << ",\"timeouts\":" << s.timeouts << ",\"late\":" << s.late
                  << ",\"duplicates\":" << s.duplicates << ",\"unknown\":" << s.unknown
                  << ",\"invalid\":" << s.invalid + malformed + foreign << ",\"min_ms\":";
        Number(std::cout, s.min);
        std::cout << ",\"max_ms\":";
        Number(std::cout, s.max);
        std::cout << ",\"mean_ms\":";
        Number(std::cout, s.mean);
        std::cout << ",\"median_ms\":";
        Number(std::cout, s.median);
        std::cout << ",\"srtt_ms\":";
        Number(std::cout, s.srtt);
        std::cout << ",\"jitter_ms\":" << s.jitter << ",\"loss_percent\":" << s.lossPercent << "}"
                  << std::endl;
        return 0;
    } catch (const std::exception& e) {
        std::cerr << "client: " << e.what() << '\n';
        return 1;
    }
}
