//
// Created by matheo on 28/08/2026.
//

#include <drogon/drogon.h>

#include <cstdlib>
#include <iostream>
#include <string>

namespace
{
    std::string env(const char *key, const std::string &fallback)
    {
        const char *val = std::getenv(key);
        return val ? std::string(val) : fallback;
    }
}

int main()
{
    // -------------------------------------------------------------------------
    // Logging
    // -------------------------------------------------------------------------

    trantor::Logger::setLogLevel(trantor::Logger::kDebug);

    // -------------------------------------------------------------------------
    // GET /health
    // -------------------------------------------------------------------------

    drogon::app().registerHandler(
        "/health",
        [](const drogon::HttpRequestPtr &,
           std::function<void(const drogon::HttpResponsePtr &)> &&callback)
        {
            Json::Value body;

            body["status"] = "ok";
            body["service"] = "catalogue";

            auto resp =
                drogon::HttpResponse::newHttpJsonResponse(body);

            callback(resp);
        },
        {drogon::Get});

    // -------------------------------------------------------------------------
    // PostgreSQL
    // -------------------------------------------------------------------------

    const auto dbHost = env("DB_HOST", "postgres");

    const auto dbPort =
        static_cast<unsigned short>(
            std::stoi(env("DB_PORT", "5432"))
        );

    const auto dbName = env("DB_NAME", "collector");
    const auto dbUser = env("DB_USER", "collector");
    const auto dbPassword = env("DB_PASSWORD", "");

    drogon::orm::PostgresConfig dbConfig{
        dbHost,
        dbPort,
        dbName,
        dbUser,
        dbPassword,
        2,
        "default",
        false,
        "",
        -1,
        false,
        {}
    };

    drogon::app().addDbClient(dbConfig);

    // -------------------------------------------------------------------------
    // GET /ping
    //
    // Retourne :
    //
    // [
    //     {
    //         "id": 1,
    //         "payload": "hello",
    //         "created_at": "..."
    //     }
    // ]
    // -------------------------------------------------------------------------

    drogon::app().registerHandler(
        "/ping",
        [](const drogon::HttpRequestPtr &,
           std::function<void(const drogon::HttpResponsePtr &)> &&callback)
        {
            auto db =
                drogon::app().getDbClient("default");

            db->execSqlAsync(
                "SELECT id, payload, created_at "
                "FROM ping "
                "ORDER BY id",
                [callback](const drogon::orm::Result &result)
                {
                    Json::Value body(Json::arrayValue);

                    for (const auto &row : result)
                    {
                        Json::Value item;

                        // BIGSERIAL -> PostgreSQL int64
                        // Cast explicite nécessaire pour JsonCpp.
                        item["id"] =
                            static_cast<Json::Int64>(
                                row["id"].as<long long>()
                            );

                        item["payload"] =
                            row["payload"].as<std::string>();

                        item["created_at"] =
                            row["created_at"].as<std::string>();

                        body.append(item);
                    }

                    auto resp =
                        drogon::HttpResponse::newHttpJsonResponse(body);

                    callback(resp);
                },
                [callback](const drogon::orm::DrogonDbException &e)
                {
                    std::cerr
                        << "[catalogue] GET /ping database error: "
                        << e.base().what()
                        << std::endl;

                    Json::Value body;

                    body["error"] = "database_error";
                    body["message"] = e.base().what();

                    auto resp =
                        drogon::HttpResponse::newHttpJsonResponse(body);

                    resp->setStatusCode(
                        drogon::k500InternalServerError);

                    callback(resp);
                });
        },
        {drogon::Get});

    // -------------------------------------------------------------------------
    // POST /ping
    //
    // Body attendu :
    //
    // {
    //     "payload": "hello"
    // }
    // -------------------------------------------------------------------------

    drogon::app().registerHandler(
        "/ping",
        [](const drogon::HttpRequestPtr &req,
           std::function<void(const drogon::HttpResponsePtr &)> &&callback)
        {
            // -----------------------------------------------------------------
            // Parse JSON
            // -----------------------------------------------------------------

            auto json = req->getJsonObject();

            if (!json)
            {
                Json::Value body;

                body["error"] = "invalid_json";
                body["message"] = "JSON body required";

                auto resp =
                    drogon::HttpResponse::newHttpJsonResponse(body);

                resp->setStatusCode(
                    drogon::k400BadRequest);

                callback(resp);
                return;
            }

            // -----------------------------------------------------------------
            // Validate payload
            // -----------------------------------------------------------------

            if (!json->isMember("payload") ||
                !(*json)["payload"].isString())
            {
                Json::Value body;

                body["error"] = "invalid_request";
                body["message"] =
                    "Field 'payload' is required and must be a string";

                auto resp =
                    drogon::HttpResponse::newHttpJsonResponse(body);

                resp->setStatusCode(
                    drogon::k400BadRequest);

                callback(resp);
                return;
            }

            const auto payload =
                (*json)["payload"].asString();

            // -----------------------------------------------------------------
            // INSERT
            // -----------------------------------------------------------------

            auto db =
                drogon::app().getDbClient("default");

            db->execSqlAsync(
                "INSERT INTO ping (payload) "
                "VALUES ($1) "
                "RETURNING id, payload, created_at",
                [callback](const drogon::orm::Result &result)
                {
                    Json::Value body;

                    // BIGSERIAL -> PostgreSQL int64
                    body["id"] =
                        static_cast<Json::Int64>(
                            result[0]["id"].as<long long>()
                        );

                    body["payload"] =
                        result[0]["payload"].as<std::string>();

                    body["created_at"] =
                        result[0]["created_at"].as<std::string>();

                    auto resp =
                        drogon::HttpResponse::newHttpJsonResponse(body);

                    resp->setStatusCode(
                        drogon::k201Created);

                    callback(resp);
                },
                [callback](const drogon::orm::DrogonDbException &e)
                {
                    std::cerr
                        << "[catalogue] POST /ping database error: "
                        << e.base().what()
                        << std::endl;

                    Json::Value body;

                    body["error"] = "database_error";
                    body["message"] = e.base().what();

                    auto resp =
                        drogon::HttpResponse::newHttpJsonResponse(body);

                    resp->setStatusCode(
                        drogon::k500InternalServerError);

                    callback(resp);
                },
                payload);
        },
        {drogon::Post});

    // -------------------------------------------------------------------------
    // Database startup check
    // -------------------------------------------------------------------------

    drogon::app().registerBeginningAdvice(
        []()
        {
            std::cerr
                << "[catalogue] Test connexion PostgreSQL..."
                << std::endl;

            auto db =
                drogon::app().getDbClient("default");

            db->execSqlAsync(
                "SELECT 1",
                [](const drogon::orm::Result &)
                {
                    std::cerr
                        << "[catalogue] Connexion base OK"
                        << std::endl;
                },
                [](const drogon::orm::DrogonDbException &e)
                {
                    std::cerr
                        << "[catalogue] Connexion base KO : "
                        << e.base().what()
                        << std::endl;
                });
        });

    // -------------------------------------------------------------------------
    // Start server
    // -------------------------------------------------------------------------

    LOG_INFO
        << "catalogue démarre sur 0.0.0.0:8080";

    drogon::app()
        .addListener("0.0.0.0", 8080)
        .setThreadNum(0)
        .run();

    return 0;
}