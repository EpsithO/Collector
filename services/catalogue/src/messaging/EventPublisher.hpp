//
// Created by matheo on 29/08/2026.
//

#pragma once

#include <string>

namespace collector {

    class EventPublisher {
    public:
        virtual ~EventPublisher() = default;

        EventPublisher(const EventPublisher&)            = delete;
        EventPublisher& operator=(const EventPublisher&) = delete;
        EventPublisher(EventPublisher&&)                 = delete;
        EventPublisher& operator=(EventPublisher&&)      = delete;

        virtual void publish(const std::string& routingKey,
                             const std::string& body) = 0;

    protected:
        EventPublisher() = default;
    };

}