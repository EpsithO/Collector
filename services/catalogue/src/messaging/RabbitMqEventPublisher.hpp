//
// Created by matheo on 29/08/2026.
//

#pragma once

#include <memory>
#include <stdexcept>
#include <string>

#include "EventPublisher.hpp"

namespace collector {


    class PublishError : public std::runtime_error {
    public:
        using std::runtime_error::runtime_error;
    };


    class RabbitMqEventPublisher final : public EventPublisher {
    public:

        RabbitMqEventPublisher(std::string host,
                               int         port,
                               std::string user,
                               std::string password,
                               std::string exchange);


        ~RabbitMqEventPublisher() override;

        void publish(const std::string& routingKey,
                     const std::string& body) override;

    private:
        struct Impl;
        std::unique_ptr<Impl> impl_;
    };

}  // namespace collector