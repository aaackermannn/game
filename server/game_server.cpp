// game_server.cpp
#include "game_server.h"

#include <chrono>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <iostream>
#include <sstream>

namespace {

// Захардкоженная база логин/пароль для простой авторизации (доп. задание).
const std::unordered_map<std::string, std::string> kCredentials = {
    {"player1", "pass123"},
    {"player2", "pass456"},
    {"admin",   "admin123"},
};

std::string addrToKey(const sockaddr_storage& addr) {
    const auto* in = reinterpret_cast<const sockaddr_in*>(&addr);
    char ipBuf[INET_ADDRSTRLEN];
    inet_ntop(AF_INET, const_cast<in_addr*>(&in->sin_addr), ipBuf, sizeof(ipBuf));
    std::ostringstream oss;
    oss << ipBuf << ":" << ntohs(in->sin_port);
    return oss.str();
}

std::string nowTimestamp() {
    auto t = std::time(nullptr);
    std::tm tmBuf{};
#ifdef _WIN32
    localtime_s(&tmBuf, &t);
#else
    localtime_r(&t, &tmBuf);
#endif
    char buf[32];
    std::strftime(buf, sizeof(buf), "%Y-%m-%d %H:%M:%S", &tmBuf);
    return buf;
}

} // namespace

Logger::Logger(const std::string& path) : file_(path, std::ios::app) {}

void Logger::log(const std::string& line) {
    std::string full = "[" + nowTimestamp() + "] " + line;
    std::cout << full << std::endl;
    if (file_.is_open()) {
        file_ << full << std::endl;
    }
}

GameServer::GameServer(const std::string& port) : logger_("server.log"), rng_(std::random_device{}()) {
    socket_.bindAsServer(port);
    logger_.log("Loop UDP server started on port " + port);
}

ClientState& GameServer::clientFor(const std::string& key) {
    auto& client = clients_[key]; // создаст запись при первом обращении
    if (client.id == 0) {
        client.id = nextClientId_++;
        logger_.log("Новый клиент " + key + " -> id=" + std::to_string(client.id));
    }
    return client;
}

void GameServer::run() {
    std::vector<uint8_t> recvBuf(2048);

    for (;;) {
        sockaddr_storage fromAddr{};
        socklen_compat fromLen = 0;
        int n = socket_.receive(recvBuf.data(), recvBuf.size(), fromAddr, fromLen);
        if (n <= 0) {
            continue; // ошибка приёма / таймаут — просто ждём следующий пакет
        }

        std::string key = addrToKey(fromAddr);
        ClientState& client = clientFor(key);

        proto::ParsedPacket pkt = proto::parsePacket(recvBuf.data(), static_cast<std::size_t>(n));
        if (!pkt.valid) {
            logger_.log("[" + key + "] отброшен: некорректный пакет (magic/размер)");
            continue;
        }
        if (!pkt.checksumOk) {
            handleBadChecksum(pkt, fromAddr, fromLen, key);
            continue;
        }

        dispatch(pkt, fromAddr, fromLen, key, client);
    }
}

void GameServer::dispatch(const proto::ParsedPacket& pkt, const sockaddr_storage& from, socklen_compat fromLen,
                           const std::string& key, ClientState& client) {
    switch (pkt.type) {
        case proto::PacketType::AUTH:
            handleAuth(pkt, from, fromLen, key, client);
            break;
        case proto::PacketType::MOVEMENT:
            handleMovement(pkt, from, fromLen, key, client);
            break;
        case proto::PacketType::SHOOT:
            handleShoot(pkt, from, fromLen, key, client);
            break;
        default:
            handleUnknown(pkt, from, fromLen, key);
            break;
    }
}

void GameServer::handleAuth(const proto::ParsedPacket& pkt, const sockaddr_storage& from, socklen_compat fromLen,
                             const std::string& key, ClientState& client) {
    proto::AuthPayload req{};
    if (!proto::readPayload(pkt, req)) return;

    std::string login(req.username, strnlen(req.username, sizeof(req.username)));
    std::string password(req.password, strnlen(req.password, sizeof(req.password)));

    auto it = kCredentials.find(login);
    bool ok = (it != kCredentials.end() && it->second == password);
    client.authenticated = ok;
    client.username = login;

    logger_.log("[" + key + "] AUTH login='" + login + "' -> " + (ok ? "OK" : "FAIL"));

    proto::AuthResultPayload resp{};
    resp.success = ok ? 1 : 0;
    std::snprintf(resp.message, sizeof(resp.message), ok ? "welcome, %s" : "invalid credentials", login.c_str());
    reply(proto::PacketType::AUTH_RESULT, pkt.sequence, resp, from, fromLen);
}

void GameServer::handleMovement(const proto::ParsedPacket& pkt, const sockaddr_storage& from, socklen_compat fromLen,
                                 const std::string& key, ClientState& client) {
    proto::MovementPayload req{};
    if (!proto::readPayload(pkt, req)) return;
    client.x = req.x;
    client.y = req.y;

    logger_.log("[" + key + "] MOVEMENT seq=" + std::to_string(pkt.sequence) +
                " x=" + std::to_string(req.x) + " y=" + std::to_string(req.y) +
                (client.authenticated ? "" : " (не авторизован)"));

    proto::StateUpdatePayload resp{};
    resp.clientId = client.id;
    resp.x = client.x;
    resp.y = client.y;
    resp.health = client.health;
    resp.ackSequence = pkt.sequence;
    reply(proto::PacketType::STATE_UPDATE, pkt.sequence, resp, from, fromLen);
}

void GameServer::handleShoot(const proto::ParsedPacket& pkt, const sockaddr_storage& from, socklen_compat fromLen,
                              const std::string& key, ClientState& /*client*/) {
    proto::ShootPayload req{};
    if (!proto::readPayload(pkt, req)) return;

    logger_.log("[" + key + "] SHOOT seq=" + std::to_string(pkt.sequence) +
                " dir=(" + std::to_string(req.dirX) + "," + std::to_string(req.dirY) + ")" +
                " weapon=" + std::to_string(req.weaponId));

    // Простая имитация попадания: если есть другие клиенты, случайно
    // выбираем цель и решаем "попал/промазал" с вероятностью 50%.
    proto::ShootResultPayload resp{};
    resp.ackSequence = pkt.sequence;
    resp.targetId = 0;
    resp.hit = 0;

    std::vector<uint32_t> otherIds;
    for (const auto& [k, c] : clients_) {
        if (k != key) otherIds.push_back(c.id);
    }
    if (!otherIds.empty()) {
        std::uniform_int_distribution<size_t> pick(0, otherIds.size() - 1);
        resp.targetId = otherIds[pick(rng_)];
        std::uniform_int_distribution<int> coin(0, 1);
        resp.hit = static_cast<uint8_t>(coin(rng_));
    }

    reply(proto::PacketType::SHOOT_RESULT, pkt.sequence, resp, from, fromLen);
}

void GameServer::handleUnknown(const proto::ParsedPacket& pkt, const sockaddr_storage& from, socklen_compat fromLen,
                                const std::string& key) {
    logger_.log("[" + key + "] неизвестный тип пакета: " + std::to_string(static_cast<int>(pkt.type)));
    proto::ErrorPayload err{};
    std::snprintf(err.message, sizeof(err.message), "unknown packet type");
    reply(proto::PacketType::ERROR_RESP, pkt.sequence, err, from, fromLen);
}

void GameServer::handleBadChecksum(const proto::ParsedPacket& pkt, const sockaddr_storage& from, socklen_compat fromLen,
                                    const std::string& key) {
    logger_.log("[" + key + "] отброшен: неверная контрольная сумма (CRC32)");
    proto::ErrorPayload err{};
    std::snprintf(err.message, sizeof(err.message), "bad checksum");
    reply(proto::PacketType::ERROR_RESP, pkt.sequence, err, from, fromLen);
}
