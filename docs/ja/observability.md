# Observability

Akamataでは、request全体に加えてDB、outbound HTTP、storage、アプリケーション独自処理の所要時間を計測できます。計測には共通のmonotonic clockとrequest-localな`TraceContext`を使用し、通常のrequest処理では追加のheap確保を必要としません。

これは完全なOpenTelemetry実装ではありません。SQL、raw URL、ユーザー入力などcardinalityの高い値をlabelへ含めず、Prometheus metrics、structured log、`Server-Timing`から処理時間の内訳を確認するための軽量な基盤です。

## Quick start

```zig
var counters: am.mw.MetricsCounters = .{};

_ = try app.useAll(am.mw.requestId(State));
_ = try app.useAll(am.mw.accessLogWithOptions(State, .{
    .format = .json,
    .include_raw_path = false,
}));
_ = try app.useAll(am.mw.metricsWithConfig(State, &counters, .{
    .latency_profile = .web,
}));
_ = try app.useAll(am.mw.serverTiming(State, .{ .enabled = false }));
_ = try app.get("/metrics", am.mw.metricsHandler(State, &counters));
```

従来の`requestId`、`accessLog`、`metrics`、`metricsHandler`も引き続き利用できます。`metrics`のdefault histogram profileは`.web`です。

middlewareは外側から`requestId`、`accessLog`、`metrics`、`serverTiming`、application handlerの順に登録します。`Server-Timing`は、出力対象となるspanを作る処理の外側に置く必要があります。

## Request context

すべての`Context`はrequestと同じlifetimeを持つ`TraceContext`を内包します。session、JWT claims、application middleware向けの`c.user_data`とは独立しているため、middleware同士でpointerを共有しません。

```zig
const request_id = c.requestId();   // ?[]const u8
const route = c.routePattern();     // 例: /api/news/:id
```

routerが保存するのは登録済みroute templateだけです。`/api/news/42`のようなraw pathをmetrics labelには使用しません。`requestId` middlewareは、印字可能で64 byte以下の`X-Request-ID`を引き継ぎ、それ以外の場合はUUIDv4を生成します。値は専用fieldへ保存され、response headerにも返されます。

## Lightweight span

```zig
fn create(c: *Ctx) !void {
    var title = c.startSpan("r2.title.put");
    defer title.end();
    try putTitleImage(...);
}
```

`defer`を使うため、正常終了時だけでなくerror return時にもspanが閉じられます。spanはnestでき、parent indexを保持します。requestごとに固定24 entryのbufferを使用し、上限を超えたspanはdropped countへ加算されます。request-localな`HashMap`やheap確保は行いません。

span名にはcomptimeまたはstaticな文字列を使用してください。ID、SQL、URL、usernameなどの入力値からspan名を生成してはいけません。次のprefixはrequest aggregateにも反映されます。

- `r2.`／`storage.`: storage durationとoperation count
- `http.`／`fetch.`: manual spanとして使った場合のoutbound HTTP aggregate
- `db.`、`serialize`、`framework`、`middleware`: 分類済みspan record

自動計測が必要なoutbound HTTPには`c.fetch(request)`を使用します。URLを保持せず、request count、duration、error countを記録します。互換性維持のため、`am.http_client.send`を直接呼んだ場合は自動計測されません。

## DB instrumentation

handlerでは`c.db()`を取得し、model／query関数へ渡します。

```zig
var stmt = try c.db().prepare("SELECT id, title FROM news");
defer stmt.deinit();
while ((try stmt.step()) == .row) { ... }
```

`c.db()`は共有DB handleを変更せず、現在のrequest traceへ関連付けた軽量な`Db` copyを返します。計測は`Db`／`Stmt` vtable facadeに集約されています。

- `exec()`は`exec` operationとして1回だけ計測します。
- prepared statementは最初の`step()`で1回だけcountとdurationを記録します。
- 複数rowを読むための追加`step()`ではcountを増やしません。
- `reset()`後は新しい実行lifecycleとして扱います。
- error時は固定backendのerror counterを増やします。

backendは`sqlite`、`d1`、`turso`、`other`の固定集合です。D1では最初の`step()`に1回の`d1_run()` JSPI suspendが含まれるため、D1のbind／raw awaitとbridge overheadを計測できます。`prepare()`やrowごとに同じ時間を重複計上しません。SQLiteは最初の`sqlite3_step`、TursoはHrana HTTP pipelineの待ち時間を計測します。SQL本文はdefaultではexportもlog出力もしません。

`c.state().db`を直接使うとrequest instrumentationを通りません。この経路はsource compatibilityと、request外で行う初期化／migration向けに残されています。

## Metrics

互換性を維持しているrequest series:

- `akamata_requests_total`
- `akamata_requests_in_flight`
- `akamata_requests_by_status{class}`
- `akamata_requests_by_method{method}`
- `akamata_request_latency_seconds` histogram／count／sum
- native processのRSS、初回観測時刻、uptime

固定cardinalityの追加series:

- `akamata_request_errors_total{class="handler"}`
- `akamata_db_operations_total{backend,operation}`
- `akamata_db_operation_duration_seconds{backend,operation}`
- `akamata_db_errors_total{backend}`
- `akamata_outbound_http_requests_total`
- `akamata_outbound_http_errors_total`
- `akamata_outbound_http_duration_seconds`

`.web` profileの境界は10、25、50、100、250、500 ms、1、2.5、5 sです。従来の100 µs〜100 ms向けbucketは`.fast`で選択できます。

```zig
am.mw.metricsWithConfig(State, &counters, .{ .latency_profile = .fast })
```

Workersには意味のあるprocess RSSがないため、RSSは0として出力されます。また、counterはisolateのcold startでresetされ、複数isolateへ分散します。Workers上の`/metrics`は診断用endpointであり、fleet全体の永続counterではありません。本番環境ではstructured logやCloudflare Workers Analyticsなども併用してください。

## Server-Timing

内部component名をclientへ公開するため、defaultでは無効です。

```zig
_ = try app.useAll(am.mw.serverTiming(State, .{
    .enabled = true,
    .include_named_spans = true,
}));
```

出力例:

```http
Server-Timing: db;dur=38.700, storage;dur=154.600, r2.title.put;dur=71.200
```

span名に使用できるのはASCII letter、digit、`.`、`_`、`-`で、最大48 byteです。SQLやattributeは出力されません。公開された本番responseではnamed spanを無効にするか、middleware自体を使用しない構成を検討してください。

## Structured access log

`accessLogWithOptions`はrequest aggregateをcompactなJSONで出力します。

```json
{"request_id":"…","method":"GET","path":"-","route":"/api/news/:id","status":200,"duration_ms":42.100,"db":{"queries":1,"execs":0,"errors":0,"duration_ms":37.800},"outbound_http":{"requests":0,"duration_ms":0.000},"storage":{"operations":0,"duration_ms":0.000}}
```

pathにemail address、token、検索語などのPIIが入る可能性がある場合は`include_raw_path = false`を指定してください。Akamataはauthorization header、body、SQL、bind value、outbound URL全体をlogへ出しません。request IDはrequest logとapplication error logを関連付けるために使えます。stack traceや任意のerror文字列をmetrics labelにはしません。

## nativeとWorkersのclock

wall clockとduration計測は分離されています。nativeのdurationには`clock_gettime(CLOCK_MONOTONIC)`を使用します。Workersでは`akamata_monotonic_ns`をimportし、JavaScript側の`performance.now() * 1_000_000`で実装します。JSON timestampにはwall clockとしてrealtime／`Date.now()`を使いますが、durationには`Date.now()`を使用しません。このため短いWorkers requestやJSPI suspendもµs／ms単位で確認できます。

## 本番環境での利用例

`GET /api/news`で`c.db()`を通してqueryを実行すると、request totalとD1 totalをlogまたは`Server-Timing`で比較できます。画像投稿では、各R2 operationを`r2.title.put`、`r2.main.put`のような安定した名前のspanで囲みます。R2専用APIをframeworkへ追加しなくても、storage totalと個別spanを確認できます。cold initializationを区別したい場合はmigrationを`db.migrate` spanで囲みます。

streamingのdurationは、現在はclientが最後のbyteを読み終えるまでの時間ではなく、middleware／handlerが完了するまでの時間です。WebSocketもsocket lifetimeではなくupgrade requestの完了までを表します。

## Cardinalityと将来のexporter

metrics labelに適しているのは固定enumと登録済みroute templateだけです。raw path、SQL、URL、error text、request ID、任意のspan名をlabelへ使用しないでください。

span recordは小さなrequest-local structureにname、parent、durationを保持します。将来はhandler側のspan APIを変えずにtrace／span IDや`Observer.onRequestEnd`／`onDbEnd` hookを追加し、OTLPやCloudflare Analytics Engineへ拡張できます。完全なOpenTelemetry SDK／OTLP exporterは現在のscope外です。
