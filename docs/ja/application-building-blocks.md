# アプリケーション向けbuilding blocks

Akamataは共通処理の80%を短くしつつ、`Db.prepare`、raw SQL、`Request`、
`Response`、`storage.Store`へ自然に降りられる設計を維持します。

## Queryとvalidation

```zig
const PartRow = struct { id: i64, sku: []const u8 };
var q = try am.model.Query.init(db, arena, "parts", "id, sku");
_ = try q.whereEq("active", true);
_ = try q.whereIn("category_id", category_ids);
_ = try q.orderBy("id", .desc);
const parts = try q.limit(50).offset(0).fetchAll(PartRow);

const totals = try am.db.fetchAll(TotalRow, db, arena,
    "SELECT category_id, COUNT(*) FROM parts GROUP BY category_id", .{});
try Parts.updateFields(db, arena, id, .{ .name = input.name, .price = input.price });
const loaded = try am.model.preload.belongsTo(Part, "category", parts, db, arena);
```

Builderは等価、`IN`、order、pagingだけを扱います。JOIN、OR、aggregate、
DB固有SQLにはraw SQLを使用してください。handlerでは
Queryに応じて次の最小レイヤーを選びます。

- primary key CRUDとpartial updateは`Repo(Model)`／`updateFields`
- 単一tableのfilter、order、paginationは`Query`
- 通常の外部keyをN+1なしで読む場合は`preload.belongsTo`
- aggregateやprojectionを任意DTOへ写す場合は`am.db.fetchAll(DTO, ...)`
- 複雑なJOIN、CTE、window関数、在庫引当、認可条件等の業務SQLは`Db.prepare`

例えばparts一覧は`Query`とcategoryの`preload.belongsTo`で短くできますが、
在庫予約はconstraintを伴う明示的なraw statementとして残します。Akamataは
row mappingを共通化しても、業務transactionやD1非対応transactionを隠しません。

byte stringはSQLite/D1共通で、`[N]u8`、`*[N]u8`、`[]u8`、`[]const u8`を
全長N byteのTEXTとしてbindします。BLOBは`am.db.Value{ .blob = bytes }`を
明示してください。他のarray/slice element型は誤変換せずcompile errorになります。

handlerでは
`(try c.validatedJson(Input)) orelse return`によりJSON parseとvalidationを
一度に実行できます。`__schema.validates`を持つ任意DTOで利用でき、失敗は
HTTP 422と`{"error_kind":"validation","errors":[...]}`に統一されます。

## Securityとsession

`am.crypto`はportableなrandom bytes/hex、SHA-256/hex、timing-safe比較、
same-origin比較を提供します。Workers externをアプリから呼ぶ必要はありません。
Sessionは署名付きSecure/HttpOnly/SameSite cookie、lookup、rotate、destroy、
`revoke(c)`を提供します。CSRFは`Origin`、`Sec-Fetch-Site`、session内token
hashとの照合も有効化できます。

```zig
_ = try app.use(am.mw.csrf(State, .{
    .expected_origin = "https://parts.example",
    .bind_to_session = true,
}));
```

tenantごとにHostが異なる場合は
`.origin_verifier = am.mw.csrfOriginMatchesHost`、proxyでHostを書き換える場合は
独自verifierを指定できます。`.session_verifier`によりアプリ独自DB sessionの
token hashとも照合できます。hookを指定してもdouble-submitとFetch Metadata検証は
無効になりません。

標準の400/401/403/404/409/422/500変換は
`try app.onError(am.errors.defaultHandler(State));`で登録できます。独自global
handlerも従来どおり登録可能です。

## Config、storage、test、運用

`am.config.load(Config, allocator)`はstring、int、bool、enum、optional、defaultを
扱います。`Config.__config.names`でenv名、`secrets`で非表示属性を宣言します。
`am.StorageFactory`はcompile時にnative filesystemまたはWorkers R2を選び、同じ
`am.storage.Store`を返します。

Testing clientには`.json`、`.csrf`、`.multipart`、`CookieJar`、
`expectStatus`、`expectHeader`を追加しました。in-memory SQLiteとversioned
migrationをtest setupで組み合わせられます。`Db.ping()`はportable health check、
static配信とsecure headerは既存の`am.mw.serveStatic`、`am.mw.secureHeaders`を使います。

Typed management commandは`am.management.Command(Context)`と
`am.management.run`で登録します。`am.idempotency.claim`は単一のatomicな
`INSERT ... ON CONFLICT`とrequest hash照合を使用します。

## D1のatomic workflow

D1 transactionは引き続き非対応で、`Db.begin()`はfail-closedです。以下を推奨します。

- constraintと`RETURNING`を含むsingle statement
- 複数table更新を一つのSQLite statementに閉じるtrigger
- transaction性を仮定しない独立処理の`Db.batch`
- retryされるworkflowのunique idempotency keyとrequest hash
- 小さくrepeatableなversioned migration

JSPI呼び出しをまたぐtransaction emulationは行いません。
