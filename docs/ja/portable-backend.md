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
direct、broadcast、senderを除くbroadcast、実transport close、presence、同一
identityの複数接続を扱います。接続時はcredential抽出→application認証→typed
Principal→参加許可→Principalからidentity/実roomを導出、の順を必須にします。
pathはauthorization入力であってroom keyではなく、queryやclientの
`X-Akamata-*` headerをPrincipalとして信頼しません。

受信messageはsize上限、typed decode、version検査の後にapplication handlerへ
渡ります。Durable Objectは自動broadcastしません。handlerがdirect／broadcast／
sender除外／disconnectを明示した場合だけ作用します。Nativeも同じdecode/handler
contractを使い、`disconnectWithReason`はregistry cleanupだけでなく実WebSocketを
closeします。

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
HTTP Range／ETag 判定を共有します。filesystemはpositional read、R2はJSPI越しの
ReadableStream/WritableStreamを利用し、いずれも64 KiB chunkで転送します。
`serveDownload`はHEAD/200/206/304/412/416、Content-Length、Content-Range、
Accept-Rangesを扱い、固定長streamはchunk framingと混在させません。absolute、
空segment、backslash、`..`を含むobject keyはadapter到達前に拒否します。
`am.net.Connector` は timeout と将来の TLS
方針を持つ portable outbound TCP contract です。

`am.protocol_gen.generate` は TypeScript realtime union／envelope／WebSocket
helper、または C struct／event metadata を生成します。integer widthは`uint8_t`等へ
予測可能にmappingし、fixed bytesはarray、bounded string/sliceはinline array+length、
optionalはpresence flag、event payloadはtagged C unionになります。heapやruntime
reflectionは不要です。既存 REST TypeScript generator は互換です。

## Embedded向けportable reference

`examples/device_messaging/src/application.zig`は両targetで共有され、login/JWT、
persistent record、bounded report、認証済みRealtime、object upload、Range downloadを
実装します。Native entryはSQLite/Native WS/filesystem、Workers entryはD1/DO/R2だけを
wiringします。QueueはStateの必須依存にしていません。

永続recordをcommitしてからephemeral notificationを送ってください。WebSocket通知を
取り逃してもRESTで復元できることが原則であり、Realtimeをsource of truthにしません。

## SQLite / D1 portable subset

prepared statement、NULL、明示的`ORDER BY`、pagination、affected rows、insert idを
共通範囲とします。SQLite transactionと異なり`Db.batch`のD1 fallbackはatomicでは
ありません。atomicityが必要ならD1で保証されるworkflowまたはDOを使います。JSを
通るD1整数は2^53-1までに制限するかtext/blobで保存してください。busy/retry、unique、
foreign-key errorはまだ全backend共通のtyped errorへ完全正規化されていません。

## Native と Workers、現在の制約

| 項目 | Native | Workers |
|---|---|---|
| HTTP/contract | `App(State)` | 同じ Zig API |
| SQL | SQLite/Turso | portable `Db` 上の D1/Turso |
| Realtime | 認証WS + typed handler | 認証gateway + hibernation DO |
| Background | SQLite jobs adapter | Queues adapter contract |
| Object | streaming filesystem adapter | streaming R2 adapter |
| TCP | native connector contract | Workers Socket contract |

Workers HTTP→WASM bridgeは受信request全体を現在もbufferするためzero-copyでは
ありません。R2 list、ETag/custom metadataの完全伝播、streaming multipart、TCP実adapter、
live WebSocket自動probeは残課題です。`zig build cloudflare-live-test`は3つの
`AKAMATA_LIVE_*`環境変数を明示した場合だけdeployed D1/R2を確認し、通常CIはunit/mockを
利用します。

## Performance と trade-off

Apple Silicon／ReleaseFast（2026-08-21）でtyped JSON event encodeは130 ns/op、
Native callback broadcastは1/10/100接続で145/178/644 ns/opでした。従来記録は
223 nsおよび211/256/697 nsです。WebSocket/network latencyではなくframework
microbenchmarkです。credentialなしにDO/R2のproduction値は報告しません。

ReleaseSmallの`device_messaging` referenceはNative 222,816→1,257,024 bytes、
WASM 32,306→178,966 bytesへ増加しました。旧targetはhealthだけのcompile proof、
新targetはJWT/SQL/Realtime/Storage/stream handlerをlinkするためcore単体の肥大化比較では
ありませんが、実deploy costではあります。参照しないadditive moduleはZigのlazy
analysis/dead-code eliminationでlinkされません。feature別size budgetは残課題です。

tagged union specialization は runtime schema lookup を除く一方、event type 数に応じ
code size と build time を増やします。platform 境界は VTable を維持し backend 実装
の重複を抑えます。D1/R2/Queues/DO の latency は実 Cloudflare account で測定し、
placeholder resource の値を production 実測として扱いません。
