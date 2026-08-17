# 開発体験

Akamataはroute情報をZigの値として保持し、compiler、runtime、OpenAPI生成、client生成、testで共有します。このページはv0.0.2以降に`main`へ追加された開発機能を説明します。tagged releaseに含まれるまでは`main`のrevisionを固定してください。

## Endpoint contractと型付きinput

endpointを一度だけ宣言して登録できます。

```zig
const GetNote = am.contract.Endpoint(.GET, "/notes/:id", showNote, .{
    .response = Note,
    .summary = "Fetch a note",
    .operation_id = "getNote",
});

try GetNote.register(app);
```

このmetadataをOpenAPIと生成clientが共通利用します。input source wrapperによりparse規則の重複も減らせます。

```zig
const id = try am.contract.Path(i64, "id").read(c);
const page = try am.contract.Query(u32, "page").read(c);
const token = try am.contract.Header([]const u8, "authorization").read(c);
const session = try am.contract.Cookie([]const u8, "session").read(c);
const body = try am.contract.Json(CreateNote).read(c);
```

scalar sourceはstring、boolean、integer、floatを扱います。JSONはAkamataのJSON parserが対応する任意の型を使用できます。

## 型付きdependencyとcapability

`am.di.Registry(&.{ Database, Mailer })`はcaller所有のpointerを、hash lookupやallocationなしで型安全に保持します。`am.di.Provider`と`am.di.validate`はproviderの重複、dependency不足、application scopeからrequest scopeへの不正な依存をcompile timeに検出します。

libraryは`am.capability.Set`を公開できます。`am.capability.require`をcomptimeで呼ぶと、native、Workers、containerの非対応構成をdeploy前に拒否できます。filesystemまたはthreadが必須のpackageはWorkers向けbuildで拒否されます。

## Project CLI

```console
akamata inspect
akamata inspect --json
akamata check --quick
akamata check
akamata generate resource note title:[]const\ u8 published:bool
akamata generate resource note --pretend
akamata destroy resource note --force
akamata api diff old-openapi.json new-openapi.json
```

[`akamata client`](cli-client.md)をargumentなしで実行するとfull-screen endpoint explorer、request argument付きでは直接HTTP request、`akamata api call`ではOpenAPI operation駆動の呼び出しを利用できます。生成applicationはHTTP routeではない`akamata-openapi` runner modeでlocal toolingへroute metadataを提供します。

resource generatorはmodel/repository、OpenAPI contract付きの型付きlist/create handler、factory test、timestamp付きmigrationを作成します。route wiringは暗黙に編集しません。`Resource.Routes(State)`をinstantiateして`register`を明示的に呼び出してください。destroyは誤ったdata消失を避けるためmigrationを残します。

`api diff`はpath／HTTP operationの削除に加え、schema／property削除、type変更、required property追加をbreaking changeとして検出します。

## Migration

新しいmigration fileには`-- migrate:up`と`-- migrate:down` sectionが含まれます。

```console
akamata migrate plan
akamata migrate status
akamata migrate up
akamata migrate rollback
akamata migrate redo
```

rollbackはdown SQLが空のfileを拒否します。各commandは生成application runnerへ委譲され、applicationと同一のdatabase設定を使用します。

## Diagnosticsとcontract test

`am.diagnostics.Diagnostic`は安定したcode、severity、hint、source file、text/JSON rendererを提供します。application testではcontractの網羅性を検査できます。

```zig
const audit = try am.testing.auditContracts(&app, arena);
try std.testing.expect(audit.ok());
```

auditは型情報のないrouteと、空でない`operation_id`の重複を報告します。`am.testing.factory`はschema defaultとoverrideの適用前にdeterministicなzero値から開始します。必須pointer／slice fieldは引き続きtestで指定してください。

## 型付きhandler binding

`contract.Bound`はinput structのfieldからrequest extractionをcomptime生成し、runtime reflectionなしで通常のhandlerへ変換します。fieldには`Path`、`Query`、`Header`、`Cookie`、`Json`を指定し、parse済み値を`.value`から取得します。

## Lifecycleとresource budget

`app.lifecycle(.{ .startup = startup, .shutdown = shutdown })`はserver開始前のsetupと`app.deinit`時のteardownを一度だけ実行します。endpoint contractの`limits`ではrequest／response byte、timeout、DB query数、outbound request数、streaming属性を宣言できます。非streaming budgetはrequest-scoped counterとdurationからrouterが強制し、全項目をOpenAPIの`x-akamata-limits`へ出力します。

route moduleで`comptime am.contract.validateGraph(.{ List, Create, Show });`を呼ぶと、App初期化前にmethod／pathとoperation IDの重複を拒否します。

DB testでは`am.testing.DatabaseSandbox`が明示的にcommitしない変更をrollbackします。`malformedJsonCorpus`はcontract fuzz test用のdeterministic seedです。

## Route、configuration、doctor

```console
akamata routes [--json]
akamata routes explain GET /notes/{id}
akamata doctor [--json]
akamata config <show|check>
akamata test [--watch]
akamata runner <command> [args]
```

`routes`は非HTTP inspection runnerを優先し、旧applicationやrepository exampleではliteralなsource registrationへ安全にfallbackします。contract metadataがある場合、`routes explain`はoperation metadata、適用middleware chain、budgetを表示します。`config`は`.env`のkeyと設定有無だけを表示し、secret値を出力しません。`doctor`はentrypoint、build manifest、deployment config、migrationを検査します。`test`はproject testを実行し、`runner`は生成applicationのtyped management-command protocolへ委譲します。新規projectには`db-check`例が含まれます。`akamata api diff`はschema／property削除、type変更、required property追加もbreaking changeとして検出します。
