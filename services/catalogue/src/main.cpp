//
// Created by matheo on 28/08/2026.
//
#include <drogon/drogon.h>

int main()
{
    drogon::app().registerHandler(
        "/health",
        [](const drogon::HttpRequestPtr &,
           std::function<void(const drogon::HttpResponsePtr &)> &&callback)
        {
            Json::Value body;
            body["status"] = "ok";
            body["service"] = "catalogue";

            auto resp = drogon::HttpResponse::newHttpJsonResponse(body);
            callback(resp);
        },
        {drogon::Get});

    LOG_INFO << "catalogue démarre sur 0.0.0.0:8080";

    drogon::app()
        .addListener("0.0.0.0", 8080)
        .setThreadNum(0)
        .run();
}