// udp_socket.cpp
#include "udp_socket.h"

#include <cstring>
#include <stdexcept>

UdpSocket::~UdpSocket() {
    close();
}

void UdpSocket::resolveAndCreate(const char* host, const std::string& port, bool passive) {
    addrinfo hints{};
    hints.ai_family = AF_INET; // IPv4 — сознательное упрощение, см. docs/pr1-udp-protocol.md
    hints.ai_socktype = SOCK_DGRAM;
    hints.ai_protocol = IPPROTO_UDP;
    if (passive) {
        hints.ai_flags = AI_PASSIVE; // "любой локальный адрес" — для bind() на сервере
    }

    addrinfo* res = nullptr;
    int rc = getaddrinfo(host, port.c_str(), &hints, &res);
    if (rc != 0) {
        throw std::runtime_error("getaddrinfo() failed for " +
                                  (host ? std::string(host) : std::string("(any)")) + ":" + port);
    }

    sock_ = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
    if (sock_ == kInvalidSocket) {
        freeaddrinfo(res);
        throw std::runtime_error("socket() failed: " + lastSocketError());
    }

    if (passive) {
        if (bind(sock_, res->ai_addr, static_cast<int>(res->ai_addrlen)) != 0) {
            freeaddrinfo(res);
            throw std::runtime_error("bind() failed: " + lastSocketError());
        }
    } else {
        std::memset(&dest_, 0, sizeof(dest_));
        std::memcpy(&dest_, res->ai_addr, res->ai_addrlen);
        destLen_ = static_cast<socklen_compat>(res->ai_addrlen);
    }

    freeaddrinfo(res);
}

void UdpSocket::bindAsServer(const std::string& port) {
    resolveAndCreate(nullptr, port, /*passive=*/true);
}

void UdpSocket::connectAsClient(const std::string& host, const std::string& port) {
    resolveAndCreate(host.c_str(), port, /*passive=*/false);
}

int UdpSocket::send(const void* data, std::size_t len) const {
    return sendto(sock_, reinterpret_cast<const char*>(data), static_cast<int>(len), 0,
                  reinterpret_cast<const sockaddr*>(&dest_), destLen_);
}

int UdpSocket::sendTo(const void* data, std::size_t len, const sockaddr_storage& to, socklen_compat toLen) const {
    return sendto(sock_, reinterpret_cast<const char*>(data), static_cast<int>(len), 0,
                  reinterpret_cast<const sockaddr*>(&to), toLen);
}

int UdpSocket::receive(void* buf, std::size_t bufSize, sockaddr_storage& from, socklen_compat& fromLen) const {
    fromLen = sizeof(from);
    return recvfrom(sock_, reinterpret_cast<char*>(buf), static_cast<int>(bufSize), 0,
                     reinterpret_cast<sockaddr*>(&from), &fromLen);
}

void UdpSocket::setRecvTimeoutMs(int ms) const {
    setRecvTimeout(sock_, ms);
}

void UdpSocket::close() {
    if (sock_ != kInvalidSocket) {
        closeSocket(sock_);
        sock_ = kInvalidSocket;
    }
}
