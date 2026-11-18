#pragma once
#include <cstdint>
#include <optional>
#include <string>
#include <vector>
#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <winsock2.h>
#include <ws2tcpip.h>
#else
#include <sys/socket.h>
#include <netinet/in.h>
#include <netdb.h>
#include <unistd.h>
#endif

namespace transport {
#ifdef _WIN32
using SocketHandle = SOCKET;
constexpr auto InvalidSocket = INVALID_SOCKET;
#else
using SocketHandle = int;
constexpr auto InvalidSocket = -1;
#endif
struct Endpoint {
    sockaddr_in address{};
    bool operator==(const Endpoint& other) const;
    std::string ToString() const;
};
struct Datagram {
    std::vector<std::uint8_t> bytes;
    Endpoint from;
};
class NetworkRuntime {
public:
    NetworkRuntime();
    ~NetworkRuntime();
    NetworkRuntime(const NetworkRuntime&) = delete;
    NetworkRuntime& operator=(const NetworkRuntime&) = delete;
};
class UdpSocket {
public:
    UdpSocket(const std::string& host, const std::string& port, bool bindServer);
    ~UdpSocket();
    UdpSocket(const UdpSocket&) = delete;
    UdpSocket& operator=(const UdpSocket&) = delete;
    void Send(const std::vector<std::uint8_t>& bytes) const;
    void SendTo(const std::vector<std::uint8_t>& bytes, const Endpoint& destination) const;
    std::optional<Datagram> Receive(int waitMs) const;
    const Endpoint& Peer() const {
        return peer_;
    }

private:
    NetworkRuntime runtime_;
    SocketHandle socket_ = InvalidSocket;
    Endpoint peer_;
};
}
