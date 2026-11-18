#include "transport/udp_socket.hpp"
#include <cstring>
#include <stdexcept>
#ifndef _WIN32
#include <arpa/inet.h>
#include <cerrno>
#endif

namespace transport {
namespace {
std::runtime_error Error(const char* operation) {
#ifdef _WIN32
    return std::runtime_error(std::string(operation) + ": Winsock " + std::to_string(WSAGetLastError()));
#else
    return std::runtime_error(std::string(operation) + ": " + std::strerror(errno));
#endif
}
void Close(SocketHandle socket) {
#ifdef _WIN32
    closesocket(socket);
#else
    close(socket);
#endif
}
}
// На Windows объект управляет временем жизни Winsock. На POSIX отдельная инициализация не нужна.
NetworkRuntime::NetworkRuntime() {
#ifdef _WIN32
    WSADATA data{};
    const auto rc = WSAStartup(MAKEWORD(2, 2), &data);
    if (rc)
        throw std::runtime_error("WSAStartup: " + std::to_string(rc));
#endif
}
NetworkRuntime::~NetworkRuntime() {
#ifdef _WIN32
    WSACleanup();
#endif
}
bool Endpoint::operator==(const Endpoint& other) const {
    return address.sin_family == other.address.sin_family &&
           address.sin_addr.s_addr == other.address.sin_addr.s_addr &&
           address.sin_port == other.address.sin_port;
}
std::string Endpoint::ToString() const {
    char buffer[INET_ADDRSTRLEN]{};
    if (!inet_ntop(AF_INET, &address.sin_addr, buffer, sizeof(buffer)))
        return "invalid_endpoint";
    return std::string(buffer) + ":" + std::to_string(ntohs(address.sin_port));
}
UdpSocket::UdpSocket(const std::string& host, const std::string& port, bool bindServer) {
    // У сервера peer_ задаёт локальный адрес для bind, у клиента — адрес назначения.
    addrinfo hints{};
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_DGRAM;
    hints.ai_protocol = IPPROTO_UDP;
    if (bindServer)
        hints.ai_flags = AI_PASSIVE;
    addrinfo* result = nullptr;
    const auto rc = getaddrinfo(host.empty() ? nullptr : host.c_str(), port.c_str(), &hints, &result);
    if (rc)
        throw std::runtime_error("getaddrinfo failed: " + std::to_string(rc));
    std::memcpy(&peer_.address, result->ai_addr, sizeof(sockaddr_in));
    socket_ = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    freeaddrinfo(result);
    if (socket_ == InvalidSocket)
        throw Error("socket");
    if (bindServer &&
        bind(socket_, reinterpret_cast<const sockaddr*>(&peer_.address), sizeof(peer_.address)) != 0) {
        const auto error = Error("bind");
        Close(socket_);
        socket_ = InvalidSocket;
        throw error;
    }
}
UdpSocket::~UdpSocket() {
    if (socket_ != InvalidSocket)
        Close(socket_);
}
void UdpSocket::Send(const std::vector<std::uint8_t>& bytes) const {
    SendTo(bytes, peer_);
}
void UdpSocket::SendTo(const std::vector<std::uint8_t>& bytes, const Endpoint& destination) const {
    // 65507 байт — максимальная полезная нагрузка UDP для IPv4 без дополнительных опций IP.
    if (bytes.size() > 65507)
        throw std::invalid_argument("UDP datagram too large");
    const auto n =
        sendto(socket_, reinterpret_cast<const char*>(bytes.data()), static_cast<int>(bytes.size()), 0,
               reinterpret_cast<const sockaddr*>(&destination.address), sizeof(destination.address));
    if (n < 0 || static_cast<std::size_t>(n) != bytes.size())
        throw Error("sendto");
}
std::optional<Datagram> UdpSocket::Receive(int waitMs) const {
    if (waitMs < 0)
        throw std::invalid_argument("negative receive wait");
    // select ограничивает ожидание. recvfrom возвращает вместе с данными адрес отправителя.
    fd_set ready;
    FD_ZERO(&ready);
    FD_SET(socket_, &ready);
    timeval timeout{};
    timeout.tv_sec = waitMs / 1000;
    timeout.tv_usec = (waitMs % 1000) * 1000;
#ifdef _WIN32
    const auto selected = select(0, &ready, nullptr, nullptr, &timeout);
#else
    const auto selected = select(socket_ + 1, &ready, nullptr, nullptr, &timeout);
#endif
    if (selected < 0) {
#ifndef _WIN32
        if (errno == EINTR)
            return std::nullopt;
#endif
        throw Error("select");
    }
    if (!selected)
        return std::nullopt;
    Datagram packet;
    packet.bytes.resize(65536);
#ifdef _WIN32
    int length = sizeof(packet.from.address);
#else
    socklen_t length = sizeof(packet.from.address);
#endif
    const auto n =
        recvfrom(socket_, reinterpret_cast<char*>(packet.bytes.data()), static_cast<int>(packet.bytes.size()),
                 0, reinterpret_cast<sockaddr*>(&packet.from.address), &length);
    if (n < 0) {
#ifdef _WIN32
        // Winsock может вернуть WSAECONNRESET, когда на целевом UDP-порту никто не слушает.
        if (WSAGetLastError() == WSAECONNRESET)
            return std::nullopt;
#else
        if (errno == EINTR)
            return std::nullopt;
#endif
        throw Error("recvfrom");
    }
    packet.bytes.resize(static_cast<std::size_t>(n));
    return packet;
}
}
