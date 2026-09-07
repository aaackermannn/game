// net_compat.h
// Тонкая кроссплатформенная обёртка над Berkeley Sockets / Winsock,
// чтобы server.cpp и client.cpp не были захламлены #ifdef'ами.
#pragma once

#ifdef _WIN32
    #define WIN32_LEAN_AND_MEAN
    #include <winsock2.h>
    #include <ws2tcpip.h>
    #pragma comment(lib, "ws2_32.lib")

    using socket_t = SOCKET;
    constexpr socket_t kInvalidSocket = INVALID_SOCKET;

    // recvfrom()/getaddrinfo() и т.п. на Winsock ожидают fromlen как int*,
    // на POSIX — как socklen_t*. Единый алиас, чтобы не плодить #ifdef по коду.
    using socklen_compat = int;

    inline int closeSocket(socket_t s) { return closesocket(s); }
#else
    #include <sys/socket.h>
    #include <netinet/in.h>
    #include <arpa/inet.h>
    #include <netdb.h>   // getaddrinfo/freeaddrinfo/addrinfo
    #include <unistd.h>
    #include <cerrno>
    #include <cstring>

    using socket_t = int;
    constexpr socket_t kInvalidSocket = -1;
    using socklen_compat = socklen_t;

    inline int closeSocket(socket_t s) { return close(s); }
#endif

#include <cstdint>
#include <stdexcept>
#include <string>

// RAII-инициализация сокетной подсистемы. На Windows нужен WSAStartup/WSACleanup,
// на Linux/macOS это no-op — Berkeley sockets готовы к использованию сразу.
class NetGuard {
public:
    NetGuard() {
#ifdef _WIN32
        WSADATA wsaData;
        int err = WSAStartup(MAKEWORD(2, 2), &wsaData);
        if (err != 0) {
            throw std::runtime_error("WSAStartup failed: " + std::to_string(err));
        }
#endif
    }
    ~NetGuard() {
#ifdef _WIN32
        WSACleanup();
#endif
    }
    NetGuard(const NetGuard&) = delete;
    NetGuard& operator=(const NetGuard&) = delete;
};

// Установить таймаут на recvfrom(), чтобы клиент/сервер не блокировались навечно
// при отсутствии ответа/трафика (нужно для периодической отправки и логов "нет ответа").
inline void setRecvTimeout(socket_t sock, int milliseconds) {
#ifdef _WIN32
    DWORD timeout = static_cast<DWORD>(milliseconds);
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, reinterpret_cast<const char*>(&timeout), sizeof(timeout));
#else
    timeval tv{};
    tv.tv_sec = milliseconds / 1000;
    tv.tv_usec = (milliseconds % 1000) * 1000;
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, reinterpret_cast<const char*>(&tv), sizeof(tv));
#endif
}

inline std::string lastSocketError() {
#ifdef _WIN32
    return std::to_string(WSAGetLastError());
#else
    return std::string(strerror(errno));
#endif
}
