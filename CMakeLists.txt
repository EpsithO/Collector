cmake_minimum_required(VERSION 4.3)
project(CollectorCesi)

set(CMAKE_CXX_STANDARD 26)

add_executable(CollectorCesi main.cpp
        services/catalogue/src/main.cpp)
