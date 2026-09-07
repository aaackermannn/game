// game_client.h
// ООП-обёртка клиентской логики поверх UdpSocket: авторизация,
// периодическая отправка MOVEMENT/SHOOT, разбор ответов сервера.
#pragma once

#include "../net/protocol.h"
#include "../net/udp_socket.h"

#include <string>

class GameClient {
public:
    GameClient(const std::string& host, const std::string& port);

    // Отправляет AUTH и печатает результат. Не блокирует дальнейшую работу
    // при отказе — см. docs/pr1-udp-protocol.md, раздел "Авторизация".
    void authenticate(const std::string& login, const std::string& password);

    // Бесконечный цикл: каждые intervalSec секунд отправляет MOVEMENT,
    // а каждый 3-й тик — ещё и SHOOT.
    [[noreturn]] void run(double intervalSec);

private:
    // Отправляет собранный пакет, печатает его, ждёт и разбирает один ответ.
    bool sendAndPrint(const std::vector<uint8_t>& packet, const char* label);

    UdpSocket socket_;
    uint32_t sequence_ = 0;
};
