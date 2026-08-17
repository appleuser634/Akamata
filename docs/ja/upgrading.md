# v0.0.1からのアップグレード

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
管理下のproxyがclient由来headerを必ず上書きする場合だけ`trust_proxy_headers = true`を設定します。
defaultの500 JSONはZig内部error名を公開しません。詳細はserver-side logまたは必要に応じて
custom `onError`で扱ってください。

## Inputと生成API description

`c.input(T)`では、non-optionalかつdefaultのない全fieldが、`__schema.validates`の`required`
rule有無に関係なく必須です。partial updateではoptionalまたはdefault付きfieldにしてください。

OpenAPIとclient生成は通常の`get`、`post`などuntyped routeも収録します。request／response／
query schemaをreflectionする場合は`endpoint()`を使います。生成pathが増える点に注意してください。
Zig client targetは引き続き完全なtransport実装ではなく生成stubです。

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
