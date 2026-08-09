# WebSocket

HTTP ルートから upgrade する httpz スタイル。WS 専用リスナを建てない。

## ハンドラ

```zig
const Ctx = am.Context(App);

fn wsRoom(ctx: *Ctx) !void {
    var conn = try am.ws.upgrade(Ctx, ctx, .{ .max_message_bytes = 64 * 1024 });
    defer conn.deinit();

    while (true) {
        const msg = conn.readMessage(ctx.arena) catch |e| switch (e) {
            error.ClosedByPeer => return,
            else => return e,
        };
        if (msg.opcode == .text) try conn.sendText(msg.payload);
    }
}
```

ルートは `app.ws("/path", handler)` で宣言する。内部的には `GET` メソッドの `RouteKind.ws` だが、ハンドラ側で `am.ws.upgrade()` を呼び、明示的に接続をアップグレードする。

## ブロードキャスト (例: チャット)

複数 WS への配信は `examples/chat/src/ws_hub.zig` を参照。ルーム ID → `*Conn` の配列を `std.AutoHashMap` で持ち、`std.Thread.Mutex` で保護。

## 制御フレーム

`Conn.readMessage` 内部で:
- `ping` → 同じペイロードで `pong` を自動返信
- `pong` → 無視
- `close` → `ReadError.ClosedByPeer`

明示的にクローズしたい場合: `conn.close(1000, "bye")`。

## Workers 環境

Workers では WS upgrade を JS 側 (`deploy/worker/index.mjs`) が検知して Durable Object (`ChatRoom`) に直接ルーティングする。Zig 側の WS ハンドラは Workers モードでは呼ばれず、DO 側 (`deploy/worker/chat_room.mjs`) が JavaScript で WS セッションを処理する。
