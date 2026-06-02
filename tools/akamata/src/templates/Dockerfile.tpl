FROM alpine:3.20 AS build
RUN apk add --no-cache curl tar xz musl-dev build-base bash && \
    curl -fsSL -o /tmp/zig.tar.xz "https://ziglang.org/download/0.16.0/zig-linux-x86_64-0.16.0.tar.xz" && \
    mkdir -p /opt/zig && tar -C /opt/zig --strip-components=1 -xJf /tmp/zig.tar.xz && rm /tmp/zig.tar.xz
ENV PATH="/opt/zig:${PATH}"
WORKDIR /src
COPY . .
RUN zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseFast

FROM scratch
COPY --from=build /src/zig-out/bin/{{NAME}} /{{NAME}}
EXPOSE 8080
ENTRYPOINT ["/{{NAME}}"]
