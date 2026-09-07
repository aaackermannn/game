cmake_minimum_required(VERSION 3.15)
project(Loop CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_executable(loop_server
    server/server.cpp
    server/game_server.cpp
    net/udp_socket.cpp
)
add_executable(loop_client
    client/client.cpp
    client/game_client.cpp
    net/udp_socket.cpp
)

if (WIN32)
    target_link_libraries(loop_server PRIVATE ws2_32)
    target_link_libraries(loop_client PRIVATE ws2_32)
endif()
