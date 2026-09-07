// server.cpp — точка входа UDP-сервера Loop.
// Вся логика — в GameServer (game_server.h/.cpp); здесь только парсинг
// аргументов и инициализация сокетной подсистемы.
//
// Запуск: server.exe [port]   (по умолчанию порт 27015)

#include "../net/net_compat.h"
#include "game_server.h"

#include <iostream>
#include <string>

int main(int argc, char** argv) {
    std::string port = argc >= 2 ? argv[1] : "27015";

    try {
        NetGuard netGuard;
        GameServer server(port);
        server.run();
    } catch (const std::exception& ex) {
        std::cerr << "Fatal: " << ex.what() << std::endl;
        return 1;
    }

    return 0;
}
