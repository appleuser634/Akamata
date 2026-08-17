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

resource generatorはmodel/repository、OpenAPI contract付きの型付きlist/create handler、factory test、timestamp付きmigrationを作成します。route wiringは暗黙に編集しません。`Resource.Routes(State)`をinstantiateして`register`を明示的に呼び出してください。destroyは誤ったdata消失を避けるためmigrationを残します。

`api diff`はpathまたはHTTP operationが削除されると失敗します。現時点では削除を検出し、schema levelの互換性までは推論しません。

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
