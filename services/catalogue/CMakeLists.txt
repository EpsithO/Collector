find_package(rabbitmq-c CONFIG REQUIRED)


add_executable(catalogue
        src/main.cpp
        src/messaging/EventPublisher.hpp
        src/messaging/RabbitMqEventPublisher.hpp
        src/messaging/RabbitMqEventPublisher.cpp
)

target_link_libraries(catalogue PRIVATE
        Drogon::Drogon
        rabbitmq::rabbitmq-static
)