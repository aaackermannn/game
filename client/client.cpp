// client.cpp — точка входа UDP-клиента Loop.
// Вся логика — в GameClient (game_client.h/.cpp); здесь только парсинг
// аргументов и инициализация сокетной подсистемы.
//
// Запуск: client.exe [host] [port] [interval_sec] [login] [password]
//   По умолчанию: 127.0.0.1 27015 1.0 player1 pass123

#include "../net/net_compat.h"
#include "game_client.h"

#include <iostream>
#include <string>

int main(int argc, char** argv) {
    std::string host = argc >= 2 ? argv[1] : "127.0.0.1";
    std::string port = argc >= 3 ? argv[2] : "27015";
    double interval = argc >= 4 ? std::atof(argv[3]) : 1.0;
    std::string login = argc >= 5 ? argv[4] : "player1";
    std::string password = argc >= 6 ? argv[5] : "pass123";

    try {
        NetGuard netGuard;
        GameClient client(host, port);

        std::cout << "Loop UDP client -> " << host << ":" << port
                  << " (интервал " << interval << " c)" << std::endl;

        client.authenticate(login, password);
        client.run(interval);
    } catch (const std::exception& ex) {
        std::cerr << "Fatal: " << ex.what() << std::endl;
        return 1;
    }

    return 0;
}
