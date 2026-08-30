//
// Created by matheo on 29/08/2026.
//

#pragma once

#include <memory>
#include <stdexcept>
#include <string>

#include "EventPublisher.hpp"

namespace collector {

    // Levée quand un événement n'a pas pu être remis au broker.
    // Type dédié plutôt que std::runtime_error : permet de l'attraper
    // spécifiquement sans intercepter une erreur sans rapport.
    class PublishError : public std::runtime_error {
    public:
        using std::runtime_error::runtime_error;
    };

    // Implémentation RabbitMQ du contrat EventPublisher.
    //
    // Aucun en-tête de la bibliothèque AMQP n'est inclus ici : tout le
    // détail vit dans Impl, défini dans le .cpp. Les fichiers qui incluent
    // ce header ne tirent donc pas rabbitmq-c derrière eux, et la
    // dépendance reste confinée à une seule unité de compilation.
    class RabbitMqEventPublisher final : public EventPublisher {
    public:
        // Ouvre la connexion, le canal et active les accusés de réception.
        // Lève PublishError si le broker est injoignable.
        RabbitMqEventPublisher(std::string host,
                               int         port,
                               std::string user,
                               std::string password,
                               std::string exchange);

        // Déclaré ici, défini dans le .cpp : Impl y est un type incomplet,
        // le compilateur ne saurait pas comment le détruire.
        ~RabbitMqEventPublisher() override;

        void publish(const std::string& routingKey,
                     const std::string& body) override;

    private:
        struct Impl;
        std::unique_ptr<Impl> impl_;
    };

}  // namespace collector