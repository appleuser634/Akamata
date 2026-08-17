# Compile-time architecture

AkamataではZig compiler自体をframeworkの一部として扱います。既存runtime APIを
柔軟なdefaultとして維持しつつ、applicationがgraphを事前に宣言できる場合は、検証と
一部dispatchをcompile timeへ移します。

## 一つのcore、二つの登録model

既存APIは変更ありません。

```zig
var app = am.App(State).init(gpa, state);
_ = try app.get("/users/:id", getUser);
```

static APIは別frameworkではなく、既存の`contract.Endpoint`、`Context`、OpenAPI
route view、TypeScript client generator、dispatch coreを共有します。

```zig
const GetUser = am.contract.Endpoint(
    .GET, "/users/:id", getUser, .{ .operation_id = "getUser" },
);
const Api = am.Routes(.{GetUser});

comptime {
    Api.validate();
    Api.validateTarget(.workers);
}

_ = try app.mountStatic(Api);
```

`mountStatic`は最後のroute登録として実行します。32 routes以下ではallocation不要の
展開matcherを使い、それを超えるgraphではcompile-time検証を維持したままcompactな
runtime matcherへ自動的に戻ります。100〜500 routesの完全展開はcode sizeと
instruction cacheを悪化させたため、この閾値はzero-costとsizeの境界として意図的に
設けています。

## compilerが検出する問題

route graphは不正な先頭path、method/pathの重複と構造的曖昧性、無名または末尾以外の
wildcard、path parameter重複、operation ID重複を拒否します。`BoundForPath`はさらに、
`Path` inputがrouteに存在すること、source/nameの重複がないこと、JSON bodyが一つだけ
であること、全fieldが対応input markerであることを検証します。

`TypedEndpoint`は`(Context, Inputs) ErrorSet!Response`をreflectionし、入力抽出、JSON
request/response schema、有限error setの完全なHTTP mapping、OpenAPI responsesを一つの
定義から生成します。

```zig
const Inputs = struct {
    id: am.contract.Path(u64, "id"),
    limit: am.contract.Query(?u32, "limit"),
};

fn find(c: *am.Context(State), input: Inputs)
    error{NotFound, DatabaseUnavailable}!User
{ ... }

const Find = am.contract.TypedEndpoint(
    State, .GET, "/users/:id", find,
    .{
        .NotFound = am.Status.not_found,
        .DatabaseUnavailable = am.Status.service_unavailable,
    },
    .{ .operation_id = "findUser" },
);
```

説明文、tag、operation IDはZig型から正しく推論できないため、明示metadataのままです。

## CapabilityとDI

`capability.Kind`はfilesystem、threads、sockets、SQLite、D1、Durable Objects、outbound
HTTP、WebSocket、persistent disk、crypto randomを表します。
`capability.Requires(Endpoint, requirements)`で既存Endpointを装飾し、`validateTarget`が
Workers/native/containerで利用不能な機能をartifact生成前に拒否します。

`di.Graph`は既存のduplicate/missing/scope検査にcycle detectionとdependency-firstな
topological orderを追加します。Registryは引き続きzero-allocationかつcaller-ownedで、
runtime service locatorにはしません。

## Middleware、DB、SQL、ownership

`static_middleware.Chain`はstateless middlewareを直接callへ合成し、runtime sliceと
`Next.index`を除去します。stateful/dynamic middlewareは従来どおり`App.use`を使います。

`db.Static(Backend)`はconcrete backend用direct-dispatch adapterです。portableな
`Db`/`Stmt` VTableは維持しています。`db.Query(sql, Args, Row)`はdeployed schemaを推測
せず、placeholder数、tuple shape、nullableを含む対応Zig typeだけを検証します。
`Stmt.readRow`はnullable fieldを扱い、non-null fieldへのSQL NULLを拒否します。

request sliceは明記がなければborrowedです。`requestAllocator()`はrequest arena lifetimeを
明示し、`ownRequestBytes()`はrequest-owned dataへの移行を見える形にします。application
lifetimeは従来のstateと`App.own`です。

## Trade-off

|Model|柔軟性|compile-time safety|dispatch|binary/build cost|
|---|---|---|---|---|
|Runtime|動的route/plugin選択が可能|登録時error|static hash + dynamic scan|最小|
|Static、≤32 routes|固定graph|最大|展開matcher|生成code/build負荷あり|
|Static、>32 routes|固定graph|最大|共有compact matcher|specializationを制限|

static routingは成熟したruntime hash fast pathより常に速いとは主張しません。第一の保証は
invalid stateの排除であり、選択的閾値によって安全性が無制限なcode growthを起こさない
ようにしています。

## 現在の境界

SQL検証はZigから分かるshapeまでで、DB schemaは検証しません。built-in openerはまだ
portable `Db`を返すため、built-in concrete static handleとschema-aware build stepは今後の
課題です。middleware flatteningもstateless static middlewareが対象です。
