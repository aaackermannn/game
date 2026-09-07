// game_server.h
// ООП-обёртка серверной логики поверх UdpSocket: приём пакетов, обработка
// команд MOVEMENT/SHOOT/AUTH, хранение состояния клиентов, логирование.
#pragma once

#include "../net/net_compat.h"
#include "../net/protocol.h"
#include "../net/udp_socket.h"

#include <fstream>
#include <map>
#include <random>
#include <string>
#include <unordered_map>
#include <vector>

// Пишет каждую строку одновременно в stdout и в лог-файл (server.log).
class Logger {
public:
    explicit Logger(const std::string& path);
    void log(const std::string& line);

private:
    std::ofstream file_;
};

// Авторитетное состояние одного подключившегося клиента.
struct ClientState {
    uint32_t id = 0;
    float x = 0.0f;
    float y = 0.0f;
    uint32_t health = 100;
    bool authenticated = false;
    std::string username;
};

class GameServer {
public:
    explicit GameServer(const std::string& port);

    // Бесконечный цикл: recvfrom() -> разбор -> обработка -> ответ.
    [[noreturn]] void run();

private:
    void dispatch(const proto::ParsedPacket& pkt, const sockaddr_storage& from, socklen_compat fromLen,
                  const std::string& key, ClientState& client);

    void handleAuth(const proto::ParsedPacket& pkt, const sockaddr_storage& from, socklen_compat fromLen,
                     const std::string& key, ClientState& client);
    void handleMovement(const proto::ParsedPacket& pkt, const sockaddr_storage& from, socklen_compat fromLen,
                         const std::string& key, ClientState& client);
    void handleShoot(const proto::ParsedPacket& pkt, const sockaddr_storage& from, socklen_compat fromLen,
                      const std::string& key, ClientState& client);
    void handleUnknown(const proto::ParsedPacket& pkt, const sockaddr_storage& from, socklen_compat fromLen,
                        const std::string& key);
    void handleBadChecksum(const proto::ParsedPacket& pkt, const sockaddr_storage& from, socklen_compat fromLen,
                            const std::string& key);

    template <typename Payload>
    void reply(proto::PacketType type, uint32_t sequence, const Payload& payload,
               const sockaddr_storage& to, socklen_compat toLen) {
        auto packet = proto::buildPacket(type, sequence, payload);
        socket_.sendTo(packet.data(), packet.size(), to, toLen);
    }

    ClientState& clientFor(const std::string& key);

    UdpSocket socket_;
    Logger logger_;
    std::map<std::string, ClientState> clients_; // ключ: "ip:port"
    uint32_t nextClientId_ = 1;
    std::mt19937 rng_;
};
