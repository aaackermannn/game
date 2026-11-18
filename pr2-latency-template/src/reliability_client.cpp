#include "app/reliability_client.hpp"
#include "app/options.hpp"
#include "protocol/packet.hpp"
#include "reliability/adaptive_timeout.hpp"
#include "reliability/reliable_channel.hpp"
#include "telemetry/telemetry.hpp"
#include "transport/udp_socket.hpp"
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <locale>

namespace {
constexpr auto CsvHeader = "experiment_id;run_id;event;sequence;at_ms;attempts;rto_ms;time_to_ack_ms";

class DeliveryCsv {
public:
    DeliveryCsv(const std::filesystem::path& path, std::string experiment, std::string run,
                std::uint64_t start)
        : experiment_(std::move(experiment)), run_(std::move(run)), start_(start) {
        if (!path.parent_path().empty())
            std::filesystem::create_directories(path.parent_path());
        const bool existing = std::filesystem::exists(path) && std::filesystem::file_size(path) != 0;
        if (existing) {
            // Сохраняем предыдущие серии и запрещаем смешивать схемы или повторять идентификатор запуска.
            std::ifstream input(path);
            std::string line;
            std::getline(input, line);
            if (!line.empty() && line.back() == '\r')
                line.pop_back();
            if (line != CsvHeader)
                throw std::runtime_error("existing CSV has incompatible schema");
            while (std::getline(input, line)) {
                const auto first = line.find(';');
                if (first == std::string::npos)
                    throw std::runtime_error("malformed reliability CSV");
                const auto second = line.find(';', first + 1);
                if (second == std::string::npos)
                    throw std::runtime_error("malformed reliability CSV");
                if (line.compare(first + 1, second - first - 1, run_) == 0)
                    throw std::runtime_error("run-id already present in CSV");
            }
        }
        out_.open(path, std::ios::app);
        if (!out_)
            throw std::runtime_error("cannot open reliability CSV");
        out_.imbue(std::locale::classic());
        out_ << std::fixed << std::setprecision(6);
        if (!existing)
            out_ << CsvHeader << '\n';
    }

    void Write(const char* event, std::optional<std::uint16_t> sequence, std::uint64_t now,
               std::optional<unsigned> attempts, double rto, std::optional<double> timeToAck = std::nullopt) {
        out_ << experiment_ << ';' << run_ << ';' << event << ';';
        if (sequence)
            out_ << *sequence;
        out_ << ';' << (now - start_) / 1000.0 << ';';
        if (attempts)
            out_ << *attempts;
        out_ << ';' << rto << ';';
        if (timeToAck)
            out_ << *timeToAck;
        out_ << '\n' << std::flush;
        if (!out_)
            throw std::runtime_error("reliability CSV write failed");
    }

private:
    std::ofstream out_;
    std::string experiment_, run_;
    std::uint64_t start_;
};

void Receive(const transport::Datagram& datagram, std::uint64_t now, Telemetry& telemetry,
             ReliableChannel& channel, AdaptiveTimeout& timer, DeliveryCsv& csv) {
    const auto& bytes = datagram.bytes;
    auto header = ParseHeader(bytes.data(), bytes.size());
    if (!header)
        return;
    if (header->type == PacketType::Ack) {
        const auto ack = ParseAck(bytes.data(), bytes.size(), *header);
        if (!ack)
            return;
        const auto result = channel.OnAckReceived(ack->acknowledgedSequence, now);
        if (!result)
            return; // Повторный ACK или поздний ACK после события failed.
        // По Карну измерение от ACK после повторной передачи неоднозначно.
        if (result->rttSampleMs)
            timer.OnSample(*result->rttSampleMs);
        csv.Write("acknowledged", result->sequence, now, result->attempts, timer.RtoMs(),
                  result->timeToAckUs / 1000.0);
    } else if (header->type == PacketType::Pong) {
        const auto pong = ParsePong(bytes.data(), bytes.size(), *header);
        if (!pong || pong->serverSendTimeUs < pong->serverReceiveTimeUs)
            return;
        // PR2 проверяет номер, эхо-метку и срок ответа. Для RTO берём только принятый замер.
        for (const auto& event : telemetry.ProcessPong(header->sequenceNumber, pong->clientSendTimeUs, now)) {
            if (event.status != ResponseStatus::Received || !event.rttMs)
                continue;
            timer.OnSample(*event.rttMs);
            csv.Write("pong_sample", event.sequence, now, std::nullopt, timer.RtoMs());
        }
    }
}
}

int app::RunReliability(const Options& opts) {
    const auto port = opts.Number("--port", 27015, 1, 65535);
    const auto count = opts.Number("--count", 50, 1, 60000);
    const auto interval = opts.Number("--interval-ms", 200, 20, 1000) * 1000;
    const auto probeInterval = opts.Number("--ping-interval-ms", 500, 100, 10000) * 1000;
    const auto maxAttempts = static_cast<unsigned>(opts.Number("--max-attempts", 5, 1, 10));
    const auto probeTimeout = opts.Number("--timeout-ms", 1000, 1, 60000) * 1000;
    const auto experiment = opts.Text("--experiment", "baseline");
    const auto run = opts.Text("--run-id", "run_" + std::to_string(NowUs()));
    ValidateId(experiment);
    ValidateId(run);

    transport::UdpSocket socket(opts.Text("--host", "127.0.0.1"), std::to_string(port), false);
    ReliableChannel channel(maxAttempts);
    AdaptiveTimeout timer;
    Telemetry telemetry(probeTimeout);
    const auto start = NowUs();
    DeliveryCsv csv(opts.Text("--csv", "docs/reliability_samples.csv"), experiment, run, start);
    std::uint64_t sent = 0, nextProbe = start;
    std::uint16_t probeSequence = 0;

    // Учёт PING и SHOOT независим. Окно дедупликации сервера видит только номера SHOOT.
    while (sent < count || channel.PendingCount() != 0) {
        auto now = NowUs();
        if (now >= nextProbe) {
            const auto sequence = probeSequence++;
            if (telemetry.OnPingSent(sequence, now)) {
                socket.Send(SerializePing(sequence, now));
            } else {
                // При долгом прогоне 16-битный номер может повториться. Следующая проба получит новый номер.
                std::cerr << "PING skipped: sequence still present in telemetry\n";
            }
            nextProbe = now + probeInterval;
        }
        if (sent < count && now >= start + sent * interval) {
            const auto sequence = static_cast<std::uint16_t>(sent++);
            now = NowUs();
            auto bytes = SerializeShoot(sequence, {1.0f, 0.0f, 1});
            socket.Send(bytes);
            if (!channel.OnSent(sequence, std::move(bytes), now))
                throw std::runtime_error("duplicate pending SHOOT sequence");
            csv.Write("sent", sequence, now, 1, timer.RtoMs());
        }

        const auto packet = socket.Receive(1);
        now = NowUs();
        if (packet && packet->from == socket.Peer())
            Receive(*packet, now, telemetry, channel, timer, csv);
        telemetry.Expire(now);

        const auto due = channel.CollectForRetransmission(now, timer.RtoUs());
        for (const auto* retry : due.retransmissions) {
            socket.Send(retry->rawBytes);
            csv.Write("retransmit", retry->sequence, now, retry->attempts, timer.RtoMs());
        }
        // Событие говорит, что подтверждение не пришло. Сервер мог применить выстрел до потери ACK.
        for (const auto& failure : due.failed) {
            csv.Write("failed", failure.sequence, now, failure.attempts, timer.RtoMs());
            std::cerr << "SHOOT not confirmed seq=" << failure.sequence << " attempts=" << failure.attempts
                      << '\n';
        }
    }
    csv.Write("final", std::nullopt, NowUs(), std::nullopt, timer.RtoMs());
    return 0;
}
