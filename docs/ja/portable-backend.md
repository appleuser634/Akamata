# Portable Backend / Realtime アーキテクチャ

Akamata は Zig 型を HTTP、永続イベント、Realtime、生成 client で共有する契約の
中心に置きます。Cloudflare binding と Native resource は小さな adapter の背後に
置き、application code へ platform 固有 API を露出させません。

## Typed contract と event

`am.events.Descriptor(T, options)` は struct／enum／tagged union から name、
version、安定した type id、JSON serializer を導出します。
`am.events.Protocol(U, v)` は tagged union を検査し、event type、event/correlation
id、payload を持つ versioned envelope を生成します。未知 event は接続を壊さず
無視または拒否し、未知 field は additive evolution のため decode 時に無視します。
破壊的変更では protocol version を上げます。

`FixedBytes(N)`、`BoundedString(N)`、`BoundedSlice(T,N)` は heap allocation
なしで上限を型へ保持し、validation、OpenAPI、embedded metadata で共有します。

## Persistent delivery と Realtime の分離

`am.queue.Producer` は at-least-once の永続経路です。event id、attempt、retry
上限、idempotency key、correlation id、failure metadata を持ちます。consumer は
冪等でなければならず Exactly-once は保証しません。Native adapter は既存
`am.jobs`、Workers adapter は Cloudflare Queues を利用します。

`am.realtime.Service` は ephemeral／session-oriented な経路です。typed room は
direct send、broadcast、disconnect、presence と同一 identity の複数接続を扱います。
Native は既存 WebSocket の send callback を登録します。Workers の
`/realtime/:room` は hibernation API、WebSocket attachment、per-room SQLite を
使う汎用 `AkamataRealtimeRoom` Durable Object へ routing されます。

## Principal、binding、capability

`am.identity.Credential` は Bearer、API token、shared secret、custom header を
表します。`Context.setPrincipal`／`principal(T)` は account、client/device、
service 等の任意 typed principal を attach し、既存 JWT API を維持します。

D1、R2、Durable Objects、Queues、Secrets、vars は `am.binding.*` で宣言します。
`am.binding.validate(Env, .workers)` は重複と target 非互換を compile-time 検出
します。実 binding 名の source of truth は Wrangler なので `wrangler types` でも
照合してください。

capability には `outbound_tcp`、`r2`、`queues`、`web_crypto`、
`persistent_storage` が加わりました。Secret は意図的な reveal が必要です。
`observability.Activity` は payload／credential を持たず、id、attempt、room、
transport、backend、duration、normalized error のみを記録します。

## Storage、streaming、TCP、client generation

`am.storage.Store` は put/get/delete/head/list、metadata、Range、conditional を
共通化します。body は pull 型の `am.stream.Reader`／`Writer` で渡し buffering と
backpressure を明示します。`parseRange` と `evaluate` は filesystem/R2 間で
HTTP Range／ETag 判定を共有します。`am.net.Connector` は timeout と将来の TLS
方針を持つ portable outbound TCP contract です。

`am.protocol_gen.generate` は TypeScript realtime union／envelope／WebSocket
helper、または C struct／event metadata を生成します。C slice は pointer と長さを
明示し runtime reflection を使いません。既存 REST TypeScript generator は互換です。

## Native と Workers、現在の制約

| 項目 | Native | Workers |
|---|---|---|
| HTTP/contract | `App(State)` | 同じ Zig API |
| SQL | SQLite/Turso | portable `Db` 上の D1/Turso |
| Realtime | Native adapter + 既存 WS | hibernation 対応 DO |
| Background | SQLite jobs adapter | Queues adapter contract |
| Object | filesystem adapter contract | R2 adapter contract |
| TCP | native connector contract | Workers Socket contract |

一部 platform adapter は contract-complete ですが end-to-end production-complete
ではありません。Workers HTTP→WASM bridge は request 全体を buffer します。
真の zero-copy request streaming、streaming multipart、完全な R2/Queue/TCP host
bridge、live Cloudflare integration test は残課題です。`examples/device_messaging`
は一つの application contract が Native／Workers 両方で compile することを検証します。

## Performance と trade-off

Apple Silicon／ReleaseFast（2026-08-21）で typed JSON event encode は 223 ns/op、
broadcast は 1/10/100 接続で 211/256/697 ns/op でした。network throughput ではなく
framework microbenchmark です。HTTP regression は既存 router benchmark を使います。

tagged union specialization は runtime schema lookup を除く一方、event type 数に応じ
code size と build time を増やします。platform 境界は VTable を維持し backend 実装
の重複を抑えます。D1/R2/Queues/DO の latency は実 Cloudflare account で測定し、
placeholder resource の値を production 実測として扱いません。
