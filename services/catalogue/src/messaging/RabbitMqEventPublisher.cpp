//
// Created by matheo on 29/08/2026.
//

#include "RabbitMqEventPublisher.hpp"

#include <rabbitmq-c/amqp.h>
#include <rabbitmq-c/tcp_socket.h>

#include <mutex>
#include <string>
#include <utility>

namespace collector {

namespace {

constexpr amqp_channel_t kChannel           = 1;
constexpr int            kHeartbeatSec      = 30;
constexpr int            kConfirmTimeoutSec = 5;

std::string describe(amqp_rpc_reply_t reply, const std::string& context) {
    switch (reply.reply_type) {
        case AMQP_RESPONSE_NORMAL:
            return {};

        case AMQP_RESPONSE_NONE:
            return context + " : reponse absente, connexion probablement fermee";

        case AMQP_RESPONSE_LIBRARY_EXCEPTION:
            return context + " : " + amqp_error_string2(reply.library_error);

        case AMQP_RESPONSE_SERVER_EXCEPTION:
            if (reply.reply.id == AMQP_CONNECTION_CLOSE_METHOD) {
                auto* m = static_cast<amqp_connection_close_t*>(reply.reply.decoded);
                return context + " : connexion fermee par le serveur, code "
                       + std::to_string(m->reply_code);
            }
            if (reply.reply.id == AMQP_CHANNEL_CLOSE_METHOD) {
                auto* m = static_cast<amqp_channel_close_t*>(reply.reply.decoded);
                return context + " : canal ferme par le serveur, code "
                       + std::to_string(m->reply_code);
            }
            return context + " : erreur serveur non identifiee";
    }
    return context + " : statut inattendu";
}

void ensureOk(amqp_rpc_reply_t reply, const std::string& context) {
    if (reply.reply_type != AMQP_RESPONSE_NORMAL) {
        throw PublishError(describe(reply, context));
    }
}

}

struct RabbitMqEventPublisher::Impl {
    std::string host;
    int         port = 0;
    std::string user;
    std::string password;
    std::string exchange;

    amqp_connection_state_t conn      = nullptr;
    bool                    connected = false;
    std::mutex mutex;
    amqp_message_t returned {};

    void connect() {
        conn = amqp_new_connection();
        if (conn == nullptr) {
            throw PublishError("Allocation de la connexion AMQP impossible");
        }

        amqp_socket_t* socket = amqp_tcp_socket_new(conn);
        if (socket == nullptr) {
            amqp_destroy_connection(conn);
            conn = nullptr;
            throw PublishError("Creation de la socket TCP impossible");
        }

        if (amqp_socket_open(socket, host.c_str(), port) != AMQP_STATUS_OK) {
            amqp_destroy_connection(conn);
            conn = nullptr;
            throw PublishError("Connexion a " + host + ":" + std::to_string(port)
                               + " impossible");
        }


        try {
            ensureOk(amqp_login(conn, "/", 0, AMQP_DEFAULT_FRAME_SIZE,
                                kHeartbeatSec, AMQP_SASL_METHOD_PLAIN,
                                user.c_str(), password.c_str()),
                     "Authentification AMQP");

            amqp_channel_open(conn, kChannel);
            ensureOk(amqp_get_rpc_reply(conn), "Ouverture du canal");


            amqp_confirm_select(conn, kChannel);
            ensureOk(amqp_get_rpc_reply(conn),
                     "Activation des accuses de reception");
        } catch (...) {
            amqp_destroy_connection(conn);
            conn = nullptr;
            throw;
        }

        connected = true;
    }

    void disconnect() noexcept {
        if (conn != nullptr) {
            amqp_channel_close(conn, kChannel, AMQP_REPLY_SUCCESS);
            amqp_connection_close(conn, AMQP_REPLY_SUCCESS);
            amqp_destroy_connection(conn);
            conn = nullptr;
        }
        connected = false;
    }


    void waitForConfirm() {
        bool unroutable = false;

        for (;;) {
            amqp_frame_t   frame;
            struct timeval timeout { kConfirmTimeoutSec, 0 };

            if (amqp_simple_wait_frame_noblock(conn, &frame, &timeout)
                != AMQP_STATUS_OK) {
                throw PublishError("Aucun accuse de reception recu du broker");
            }

            if (frame.frame_type != AMQP_FRAME_METHOD) {
                continue;
            }

            switch (frame.payload.method.id) {
                case AMQP_BASIC_ACK_METHOD:
                    if (unroutable) {
                        throw PublishError(
                            "Message non routable : aucune file liee a cette cle");
                    }
                    return;

                case AMQP_BASIC_NACK_METHOD:
                    throw PublishError("Message rejete par le broker");

                case AMQP_BASIC_RETURN_METHOD:
                    unroutable = true;
                    amqp_read_message(conn, frame.channel, &returned, 0);
                    amqp_destroy_message(&returned);
                    continue;

                default:
                    continue;
            }
        }
    }
};

RabbitMqEventPublisher::RabbitMqEventPublisher(std::string host,
                                               int         port,
                                               std::string user,
                                               std::string password,
                                               std::string exchange)
    : impl_(std::make_unique<Impl>()) {
    impl_->host     = std::move(host);
    impl_->port     = port;
    impl_->user     = std::move(user);
    impl_->password = std::move(password);
    impl_->exchange = std::move(exchange);
    impl_->connect();
}

RabbitMqEventPublisher::~RabbitMqEventPublisher() {
    impl_->disconnect();
}


void RabbitMqEventPublisher::publish(const std::string& routingKey,
                                     const std::string& body) {
    std::lock_guard<std::mutex> lock(impl_->mutex);


    if (!impl_->connected) {
        impl_->connect();
    }

    amqp_basic_properties_t props {};
    props._flags = AMQP_BASIC_CONTENT_TYPE_FLAG
                 | AMQP_BASIC_DELIVERY_MODE_FLAG;
    props.content_type  = amqp_cstring_bytes("application/json");
    props.delivery_mode = 2;

    const int rc = amqp_basic_publish(
        impl_->conn,
        kChannel,
        amqp_cstring_bytes(impl_->exchange.c_str()),
        amqp_cstring_bytes(routingKey.c_str()),
        1,
        0,
        &props,

        amqp_bytes_t { body.size(), const_cast<char*>(body.data()) });

    if (rc != AMQP_STATUS_OK) {
        impl_->disconnect();
        throw PublishError(std::string("Publication échouée : ")
                           + amqp_error_string2(rc));
    }

    try {
        impl_->waitForConfirm();
    } catch (...) {

        impl_->disconnect();
        throw;
    }
}

}