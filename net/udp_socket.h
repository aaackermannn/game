// udp_socket.h
// RAII-обёртка над UDP-сокетом. Адрес резолвится через getaddrinfo() —
// как в канонических listener.c / talker.c из Beej's Guide to Network
// Programming, §6.3 (Datagram Sockets), а не вручную через sockaddr_in.
#pragma once

#include "net_compat.h"

#include <cstddef>
#include <cstdint>
#include <string>

class UdpSocket {
public:
    UdpSocket() = default;
    ~UdpSocket();

    UdpSocket(const UdpSocket&) = delete;
    UdpSocket& operator=(const UdpSocket&) = delete;

    // Серверный режим (аналог listener.c): резолвит локальный адрес с
    // AI_PASSIVE и делает bind(). port — например "27015".
    void bindAsServer(const std::string& port);

    // Клиентский режим (аналог talker.c): резолвит адрес удалённого хоста
    // и запоминает его как получателя по умолчанию для send().
    void connectAsClient(const std::string& host, const std::string& port);

    // Отправить получателю, зафиксированному в connectAsClient().
    int send(const void* data, std::size_t len) const;

    // Отправить произвольному адресу (сервер отвечает конкретному клиенту).
    int sendTo(const void* data, std::size_t len, const sockaddr_storage& to, socklen_compat toLen) const;

    // Принять пакет; from/fromLen заполняются адресом отправителя.
    // Возвращает количество принятых байт или отрицательное значение при ошибке/таймауте.
    int receive(void* buf, std::size_t bufSize, sockaddr_storage& from, socklen_compat& fromLen) const;

    void setRecvTimeoutMs(int ms) const;

private:
    void resolveAndCreate(const char* host, const std::string& port, bool passive);
    void close();

    socket_t sock_ = kInvalidSocket;
    sockaddr_storage dest_{};
    socklen_compat destLen_ = 0;
};
