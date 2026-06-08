# Containers 用静的 musl バイナリを 2 段ビルドで作る。
# OpenSSL は alpine から静的リンク版を取得。
#
# 使い方: プロジェクトルートで
#   docker build -f deploy/mobus/Dockerfile -t mobus .
#   docker run --rm -p 8080:8080 -v $PWD/data:/data \
#     -e JWT_SECRET=xxx -e WEATHER_KEY=xxx mobus

FROM alpine:3.20 AS build
RUN apk add --no-cache zig=0.16.0-r0 || true
# zig パッケージが追従していない場合は upstream tarball を取る:
RUN apk add --no-cache curl tar xz && \
    curl -fsSL -o /tmp/zig.tar.xz "https://ziglang.org/download/0.16.0/zig-linux-x86_64-0.16.0.tar.xz" && \
    mkdir -p /opt/zig && \
    tar -C /opt/zig --strip-components=1 -xJf /tmp/zig.tar.xz && \
    rm /tmp/zig.tar.xz
ENV PATH="/opt/zig:${PATH}"
RUN apk add --no-cache openssl-dev openssl-libs-static musl-dev build-base bash
WORKDIR /src
COPY . .
RUN ./third_party/sqlite/fetch.sh
RUN zig build \
    -Dbackend=native -Dexample=mobus \
    -Dtarget=x86_64-linux-musl -Doptimize=ReleaseFast

FROM scratch
COPY --from=build /src/zig-out/bin/mobus /mobus
ENV AKAMATA_PORT=8080
ENV DATABASE_PATH=/data/mobus.db
EXPOSE 8080
ENTRYPOINT ["/mobus"]
