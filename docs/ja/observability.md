# 可観測性

Akamata はリクエスト、データベース、アウトバウンド HTTP、およびアプリケーション定義を測定します
1 つの単調クロックとリクエストスコープの割り当て不要のトレースによるタイミング。
OpenTelemetry よりも意図的に小さいため、データは次のように公開できます。
SQL、生の URL を配置しない Prometheus メトリクス、JSON ログ、または `Server-Timing`
または、無制限のユーザー値をラベルに追加します。

## クイックスタート

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

既存の `requestId`、`accessLog`、`metrics`、および `metricsHandler` API は次のとおりです。
まだ利用可能です。 `metrics` は、デフォルトで `.web` ヒストグラム プロファイルになりました。

ミドルウェアの順序は重要です。リクエスト ID とアクセス ログはメトリクスをラップする必要があります。
アプリケーション。 `Server-Timing` は、出力するスパンのコードをラップする必要があります。

## リクエストコンテキスト

すべての `Context` には `TraceContext` が埋め込まれます。有効期間はリクエストと同じです
そして割り当てません。これは `c.user_data` とは別のものであり、そのまま残ります。
セッション、JWT クレーム、アプリケーション ミドルウェア。

```zig
const request_id = c.requestId();       // ?[]const u8
const route = c.routePattern();         // e.g. /api/news/:id
```

ルーターは登録されたルート テンプレートのみを書き込みます。生の動的パスは次のとおりです。
メトリックラベルとしては決して使用されません。 `requestId` は印刷可能な受信メールを受け入れます
`X-Request-ID` 最大 64 バイト、または UUIDv4 を生成し、専用の
トレースフィールドを取得し、それを応答でエコーします。

## 軽量スパン

```zig
fn create(c: *Ctx) !void {
    var title = c.startSpan("r2.title.put");
    defer title.end();
    try putTitleImage(...);
}
```

`defer` は、成功時とエラー時にスパンを閉じます。ネストにまたがり、その親を保持します
インデックスを作成し、固定の 24 エントリのリクエスト バッファを使用します。超過スパンは次のようにカウントされます。
落とした。リクエスト HashMap やヒープ割り当てはありません。コンプタイム/静的を優先する
名前。 ID、SQL、URL、ユーザー名、またはその他の入力から名前を構築しないでください。

次のプレフィックスも安全なリクエスト集約にフィードします。

- `r2.` / `storage.` → 保存期間と操作回数
- `http.` / `fetch.` → 手動スパンとして使用される場合のアウトバウンド HTTP 集約
- `db.`、`serialize`、`framework`、`middleware` → 分類されたスパンレコード

自動的に計測されるアウトバウンド HTTP には `c.fetch(request)` を使用します。記録します
URL を保持せずに、カウント、期間、エラーを追跡します。直接
`am.http_client.send` は互換性を考慮して実装されていません。

## データベースのインストルメンテーション

ハンドラーで `c.db()` を使用し、その値をモデル/クエリ関数に渡します。

```zig
var stmt = try c.db().prepare("SELECT id, title FROM news");
defer stmt.deinit();
while ((try stmt.step()) == .row) { ... }
```

`c.db()` は、このリクエスト トレースにバインドされた `Db` の軽量コピーを返します。それはあります
共有データベースハンドルを変更しないでください。計測は次の場所に集中されています。
`Db`/`Stmt` vtable ファサード:

- `exec()` は `exec` として 1 回計測されます。
- 準備されたステートメントは、最初の `step()` で 1 回計時/カウントされます。
- さらに行ステップを実行してもカウントは増加しません。
- `reset()` は、新しい実行ライフサイクルを開始します。
- エラーにより、固定バックエンド エラー カウンターが増加します。

バックエンドは、固定セット `sqlite`、`d1`、`turso`、`other` です。 D1の場合は最初
ステップには単一の `d1_run()` JSPI サスペンドが含まれているため、その期間は正確に
D1 バインド/生待機とブリッジ オーバーヘッド (`prepare()` やすべての行ではありません)。
SQLite は最初の `sqlite3_step` を測定します。 Turso は Hrana HTTP パイプラインを測定します
待ってください。デフォルトでは、SQL テキストはエクスポートまたはログに記録されません。

`c.state().db` を呼び出すと、リクエストのインストルメンテーションがバイパスされます。これは保存されます
ソースの互換性と、リクエスト外の初期化/移行コード用。

## メトリクス

互換性のために保持されているリクエスト シリーズ:

- `akamata_requests_total`
- `akamata_requests_in_flight`
- `akamata_requests_by_status{class}`
- `akamata_requests_by_method{method}`
- `akamata_request_latency_seconds` ヒストグラム/カウント/合計
- ネイティブ プロセス RSS、最初の観測時間、稼働時間

新しい固定カーディナリティ シリーズ:

- `akamata_request_errors_total{class="handler"}`
- `akamata_db_operations_total{backend}`
- `akamata_db_operation_duration_seconds{backend}`
- `akamata_db_errors_total{backend}`
- `akamata_outbound_http_requests_total`
- `akamata_outbound_http_errors_total`
- `akamata_outbound_http_duration_seconds`

`.web` 境界は、10、25、50、100、250、500 ミリ秒、1、2.5、および 5 秒です。
`.fast` は、以前の 100 μs から 100 ms のプロファイルを保存します。

```zig
am.mw.metricsWithConfig(State, &counters, .{ .latency_profile = .fast })
```

プロセス RSS は、意味のある情報がないため、ワーカーではゼロとして報告されます。
RSSを処理します。ワーカー分離カウンタはコールド スタート時にリセットされ、複数のワーカーに分割される場合があります
は分離されるため、`/metrics` は診断エンドポイントであり、永続的なグローバル カウンターではありません。
構造化ログ、Cloudflare Workers Analytics、または将来のエクスポーターを使用して、
フリート全体の生産データ。

## サーバーのタイミング

これは、内部コンポーネント名をクライアントに明らかにするため、オプトインです。

```zig
_ = try app.useAll(am.mw.serverTiming(State, .{
    .enabled = true,
    .include_named_spans = true,
}));
```

例: `サーバータイミング: db;dur=38.700, storage;dur=154.600,
r2.title.put;dur=71.200`。名前には ASCII 文字、数字のみを含める必要があります。
`.`、`_`、または `-` であり、48 バイトに制限されます。 SQL や属性は出力されません。
パブリック実稼働応答で名前付きスパンまたはミドルウェア全体を無効にします。

## 構造化されたアクセスログ

`accessLogWithOptions` は、コンパクトなリクエスト集約を発行します。

```json
{"request_id":"…","method":"GET","path":"-","route":"/api/news/:id","status":200,"duration_ms":42.100,"db":{"queries":1,"execs":0,"errors":0,"duration_ms":37.800},"outbound_http":{"requests":0,"duration_ms":0.000},"storage":{"operations":0,"duration_ms":0.000}}
```

パスに電子メール アドレス、トークン、
検索用語やその他の PII。 Akamata は認証ヘッダー、本文、
SQL、バインド値、または完全な送信 URL。リクエスト ID は、
リクエストログからアプリケーションエラーログへ。エラー自体は制限されたままです
スタック/エラー文字列をラベルとして使用するのではなく、メトリクス (`handler`、バックエンド) を使用します。

## ネイティブ クロックとワーカー クロック

ウォールのタイムスタンプと期間は別のものです。ネイティブ期間の使用
`clock_gettime(CLOCK_MONOTONIC)`;ワーカーは `akamata_monotonic_ns` をインポートし、バックアップされます
by `performance.now() * 1_000_000`。 JSON タイムスタンプは realtime/`Date.now()` を使用します
ウォールタイムとしてのみ。 `Date.now()` は一定期間使用されません。これにより短くなります
ワーカーのリクエストと JSPI の一時停止をマイクロ/ミリ秒の解像度で表示します。

## 生産パターン

`GET /api/news` の場合、`c.db()` を通じてクエリを実行すると、ログ/Server-Timing が表示されます。
リクエストの合計と D1 の合計。イメージを作成するには、各 R2 操作を次のようにラップします。
`r2.title.put` や `r2.main.put` などの安定した名前。ストレージの合計とそれぞれ
名前付きスパンは、R2 固有のフレームワーク依存関係を追加せずに表示されます。
移行を `db.migrate` でラップして、コールド初期化作業を区別します。

現在、ストリーミング期間は時間ではなく、ミドルウェア/ハンドラーの完了を意味します。
クライアントが最後のバイトを消費するまで。 WebSocket の持続時間はアップグレードを意味します
ソケットの有効期間ではなく、リクエストの完了です。

## カーディナリティと将来のエクスポーター

固定列挙型と登録されたルート テンプレートのみが適切なメトリック ラベルです。
生のパス、SQL、URL、エラー テキスト、リクエスト ID、または任意のラベルを付けないでください。
スパン名。スパン レコードは、名前、親、および期間を小さな単位ですでに保持しています。
リクエスト構造。トレース/スパン ID と `Observer.onRequestEnd/onDbEnd` フック
ハンドラー スパンを変更せずに、後で OTLP または分析エンジンに追加できます
使用法。完全な OpenTelemetry SDK/OTLP エクスポーターは意図的に範囲外です。
