add_executable(catalogue
        src/main.cpp
)

target_link_libraries(catalogue PRIVATE Drogon::Drogon)