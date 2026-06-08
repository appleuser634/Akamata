# Containers 用静的バイナリ。
# プロジェクトルートで以下を実行してから docker build する想定:
#   zig build -Dbackend=native -Dtarget=x86_64-linux-musl -Doptimize=ReleaseFast
FROM scratch

COPY zig-out/bin/chat /chat
ENV AKAMATA_PORT=8080
ENV AKAMATA_DB=/data/chat.db
EXPOSE 8080
ENTRYPOINT ["/chat"]
