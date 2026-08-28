# ---------- Étape 1 : build ----------
FROM debian:bookworm AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential cmake git pkg-config \
        python3 python3-pip ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN pip3 install --break-system-packages --no-cache-dir conan \
    && conan profile detect --force

WORKDIR /src

# Copié seul pour que la couche des dépendances reste en cache
COPY conanfile.txt .
RUN conan install . \
        --output-folder=/opt/conan \
        --build=missing \
        -s build_type=Release \
        -s compiler.cppstd=20

RUN find /opt/conan -name "conan_toolchain.cmake" ; ls -la /opt/conan

COPY CMakeLists.txt .
COPY services/ ./services/

RUN cmake -S . -B /build \
        -DCMAKE_TOOLCHAIN_FILE=/opt/conan/conan_toolchain.cmake \
        -DCMAKE_BUILD_TYPE=Release \
    && cmake --build /build --target catalogue -j"$(nproc)"

# ---------- Étape 2 : runtime ----------
FROM debian:bookworm-slim AS runtime

RUN apt-get update && apt-get install -y --no-install-recommends \
        libstdc++6 curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN useradd --system --uid 10001 --no-create-home collector

COPY --from=builder /build/bin/catalogue /usr/local/bin/catalogue

USER 10001
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/catalogue"]