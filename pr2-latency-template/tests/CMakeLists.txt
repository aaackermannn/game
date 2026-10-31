include(FetchContent)
FetchContent_Declare(
    catch2
    GIT_REPOSITORY https://github.com/catchorg/Catch2.git
    GIT_TAG v3.5.2
)
FetchContent_MakeAvailable(catch2)

add_executable(unit_tests test_protocol.cpp test_telemetry.cpp test_emulator.cpp)
target_link_libraries(unit_tests PRIVATE Catch2::Catch2WithMain protocol telemetry)
add_test(NAME unit_tests COMMAND unit_tests)
set_tests_properties(unit_tests PROPERTIES TIMEOUT 30)
find_package(Python3 REQUIRED COMPONENTS Interpreter)
if(Python3_Interpreter_FOUND)
    add_test(NAME csv_analysis COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/test_analysis.py)
    add_test(NAME udp_integration COMMAND ${Python3_EXECUTABLE}
        ${CMAKE_CURRENT_SOURCE_DIR}/test_integration.py --client $<TARGET_FILE:client> --server $<TARGET_FILE:server>)
    set_tests_properties(udp_integration PROPERTIES TIMEOUT 45)
endif()
