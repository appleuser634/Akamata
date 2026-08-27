# v0.0.1からのアップグレード

## framework依存と生成fileの更新

対象releaseに付属するCLIを使用してください。Workers projectでは生成済みの
JavaScript bridgeもframework/runtime ABIの一部なので、`build.zig.zon`だけの更新では
不十分です。

```bash
akamata update --to=v0.1.1 --sync
```

`akamata update`は現在の`.akamata`依存releaseを検出し、対象archiveのhashを解決して、
その依存のURL/hashだけを更新します。その後Native buildと、Wrangler設定がある場合は
Workers buildを検証します。`--to`省略時はCLIに組み込まれた最新stable releaseを選び、
`--dry-run`ではfile更新もbuildも行いません。

`akamata sync`のmanaged fileは`.akamata/managed-files.json`に記録されます。

- `deploy/worker/index.mjs`
- `deploy/worker/wasm_dispatch.mjs`
- `deploy/worker/internal_routes.mjs`
- `deploy/worker/realtime_object.mjs`

application source、`build.zig`、`wrangler.toml`はuser-ownedであり書き換えません。
managed fileのSHA-256が生成時hashと異なる場合は差分概要を表示してdefaultで拒否します。
`--force`時も置換前に`.bak`を保存します。manifest導入前のv0.1.0 glueは、公式templateと
完全一致する場合だけ自動移行します。

```bash
akamata update --to=v0.1.1 --sync --dry-run
akamata update --to=v0.1.1 --sync
git diff
```

このページはv0.0.1以降の`main`における挙動変更をまとめます。曖昧な状態を意図的に
startup errorまたはrequest errorへ変えた箇所があるため、deploy前に全testを実行してください。

## RouteとGroup

routeとmiddlewareの登録は`prepare()`、test clientによる最初のdispatch、または`serve()`
より前に完了してください。それ以降はfreezeされます。重複または等価なpath、曖昧なdynamic
shape、重複parameter名、末尾以外のwildcard、16個を超えるcaptureは登録時に失敗します。

`basePath()`は軽量な`Group`値を返します。型推論を使う通常のコードはそのままです。

```zig
var api = try app.basePath("/api");
_ = try api.get("/users", listUsers);
```

`*App`として宣言したり、Groupを個別に`deinit()`したりしないでください。prefix、route、
middleware resource、session store、rate limiter allocationは親Appが所有します。

HTTP semanticsも変わります。`HEAD`は`GET`へfallbackでき、wire上のbodyは抑制されます。
既知のpathに異なるmethodを送ると`404`ではなく`405`と`Allow`を返します。

## Proxy trustとerror

forwarding headerはdefaultで`c.req.ip()`へ影響しません。clientがapplicationへ直接接続できず、
管理下のproxyがclient由来headerを必ず上書きする場合だけ`trust_proxy_headers = true`と
`trusted_proxy_fn`を設定します。
defaultの500 JSONはZig内部error名を公開しません。詳細はserver-side logまたは必要に応じて
custom `onError`で扱ってください。

## Inputと生成API description

`c.input(T)`では、non-optionalかつdefaultのない全fieldが、`__schema.validates`の`required`
rule有無に関係なく必須です。partial updateではoptionalまたはdefault付きfieldにしてください。

OpenAPIとclient生成は通常の`get`、`post`などuntyped routeも収録します。request／response／
query schemaをreflectionする場合は`endpoint()`を使います。生成pathが増える点に注意してください。
未完成のZig client targetはruntime panicを含むstubを生成せず、生成時に
`error.UnsupportedTarget`を返します。

## Databaseとmigration

repositoryのoptional fieldは`Stmt.columnIsNull()`により、SQL `NULL`を0、`false`、空文字列と
区別します。以前のcoercionを補正するworkaroundがあれば除去を検討してください。

SQLiteの`execAll()`はSQLite parserへscript全体を渡します。他backendのsplitterはquoteと
commentを認識し、不正なscriptを拒否します。SQLiteとTursoのversioned migrationは
`schema_migrations`記録を含めてfile単位でatomicです。D1 bridgeは非transactionalなので、
D1 migrationは小さくidempotentにしてください。

## 推奨する確認

`zig build test`、`zig build integration`、`zig build tasks-test`を実行し、使用する全deploy
targetをbuildしてください。重複route、必須input欠落、`HEAD`／`405`、proxy IP、nullable
model field、意図的に失敗するmigrationもapplication側で確認します。
