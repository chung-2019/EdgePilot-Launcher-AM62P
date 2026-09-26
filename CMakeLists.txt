cmake_minimum_required(VERSION 3.16)
project(edgepilot-launcher VERSION 1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)

find_package(Qt6 REQUIRED COMPONENTS Core Gui Network Widgets Qml Quick QuickControls2 Svg)

add_executable(edgepilot-launcher
    main.cpp
    src/systemmonitor.h
    src/systemmonitor.cpp
    src/benchmarkrunner.h
    src/benchmarkrunner.cpp
    src/blescanner.h
    src/blescanner.cpp
    src/deviceprofiles.h
    src/deviceprofiles.cpp
    src/uisyncserver.h
    src/uisyncserver.cpp
    qml.qrc
)

target_include_directories(edgepilot-launcher PRIVATE src)

target_link_libraries(edgepilot-launcher PRIVATE
    Qt6::Core
    Qt6::Gui
    Qt6::Network
    Qt6::Widgets
    Qt6::Qml
    Qt6::Quick
    Qt6::QuickControls2
    Qt6::Svg
)

install(TARGETS edgepilot-launcher RUNTIME DESTINATION /usr/bin)
