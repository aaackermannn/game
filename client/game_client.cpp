// game_client.cpp
#include "game_client.h"

#include "../net/net_compat.h"

#include <chrono>
#include <cmath>
#include <cstdio>
#include <iostream>
#include <thread>

namespace {
constexpr int kRecvTimeoutMs = 1500;
}

GameClient::GameClient(const std::string& host, const std::string& port) {
    socket_.connectAsClient(host, port);
    socket_.setRecvTimeoutMs(kRecvTimeoutMs);
}

bool GameClient::sendAndPrint(const std::vector<uint8_t>& packet, const char* label) {
    int sent = socket_.send(packet.data(), packet.size());
    if (sent < 0) {
        std::cerr << "  [" << label << "] send() failed: " << lastSocketError() << std::endl;
        return false;
    }

    std::vector<uint8_t> buf(2048);
    sockaddr_storage from{};
    socklen_compat fromLen = 0;
    int n = socket_.receive(buf.data(), buf.size(), from, fromLen);
    if (n <= 0) {
        std::cout << "  [" << label << "] нет ответа от сервера (таймаут)" << std::endl;
        return false;
    }

    proto::ParsedPacket pkt = proto::parsePacket(buf.data(), static_cast<std::size_t>(n));
    if (!pkt.valid) {
        std::cout << "  [" << label << "] получен некорректный пакет" << std::endl;
        return false;
    }

    switch (pkt.type) {
        case proto::PacketType::AUTH_RESULT: {
            proto::AuthResultPayload resp{};
            if (proto::readPayload(pkt, resp)) {
                std::cout << "  [" << label << "] AUTH_RESULT: " << (resp.success ? "успех" : "отказ")
                          << " (" << resp.message << ")" << std::endl;
            }
            return true;
        }
        case proto::PacketType::STATE_UPDATE: {
            proto::StateUpdatePayload resp{};
            if (proto::readPayload(pkt, resp)) {
                std::cout << "  [" << label << "] STATE_UPDATE: id=" << resp.clientId
                          << " x=" << resp.x << " y=" << resp.y
                          << " health=" << resp.health
                          << " ack=" << resp.ackSequence << std::endl;
            }
            return true;
        }
        case proto::PacketType::SHOOT_RESULT: {
            proto::ShootResultPayload resp{};
            if (proto::readPayload(pkt, resp)) {
                std::cout << "  [" << label << "] SHOOT_RESULT: "
                          << (resp.hit ? "попадание" : "промах")
                          << " target=" << resp.targetId
                          << " ack=" << resp.ackSequence << std::endl;
            }
            return true;
        }
        case proto::PacketType::ERROR_RESP: {
            proto::ErrorPayload resp{};
            if (proto::readPayload(pkt, resp)) {
                std::cout << "  [" << label << "] ERROR_RESP: " << resp.message << std::endl;
            }
            return false;
        }
        default:
            std::cout << "  [" << label << "] неожиданный тип ответа" << std::endl;
            return false;
    }
}

void GameClient::authenticate(const std::string& login, const std::string& password) {
    proto::AuthPayload req{};
    std::snprintf(req.username, sizeof(req.username), "%s", login.c_str());
    std::snprintf(req.password, sizeof(req.password), "%s", password.c_str());

    auto packet = proto::buildPacket(proto::PacketType::AUTH, ++sequence_, req);
    std::cout << "Отправка AUTH (login=" << login << ")" << std::endl;
    sendAndPrint(packet, "AUTH");
}

void GameClient::run(double intervalSec) {
    float x = 0.0f, y = 0.0f;
    int tick = 0;

    for (;;) {
        ++tick;

        // Простое имитационное движение по кругу.
        x = std::cos(tick * 0.3f) * 10.0f;
        y = std::sin(tick * 0.3f) * 10.0f;

        proto::MovementPayload move{x, y};
        auto movePacket = proto::buildPacket(proto::PacketType::MOVEMENT, ++sequence_, move);
        std::cout << "Tick " << tick << ": MOVEMENT x=" << x << " y=" << y
                  << " (seq=" << sequence_ << ")" << std::endl;
        sendAndPrint(movePacket, "MOVEMENT");

        if (tick % 3 == 0) {
            proto::ShootPayload shoot{0.0f, 1.0f, 1};
            auto shootPacket = proto::buildPacket(proto::PacketType::SHOOT, ++sequence_, shoot);
            std::cout << "Tick " << tick << ": SHOOT weapon=1 (seq=" << sequence_ << ")" << std::endl;
            sendAndPrint(shootPacket, "SHOOT");
        }

        std::this_thread::sleep_for(std::chrono::milliseconds(static_cast<int>(intervalSec * 1000)));
    }
}
