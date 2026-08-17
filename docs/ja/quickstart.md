# クイックスタート

約5分で、Akamataが生成するNote APIを起動します。

## 必要な環境

- Zig 0.16.x
- GitとPOSIX互換shell
- Cloudflare Workersを利用する場合のみNode.jsとWrangler
- Cloudflare Containersを利用する場合のみDocker

nativeビルドにはSQLite amalgamationが含まれ、libcへリンクします。OpenSSLは任意で、FCMのRS256対応を`-Dopenssl=true`で有効にする場合に限り必要です。

## 1. CLIをインストールする

Akamataをcloneし、インストールスクリプトを実行します。

```bash
git clone https://github.com/appleuser634/Akamata.git
cd Akamata
./scripts/install.sh
akamata help
```

スクリプトはCLIをビルドし、デフォルトでは`$HOME/.local/bin`へインストールします。このディレクトリを`PATH`へ追加してください。source checkout内のCLIを直接使う場合は、次のようにビルドできます。

```bash
zig build cli
./zig-out/bin/akamata help
```

## 2. プロジェクトを生成する

生成される`build.zig.zon`は、release互換のrevisionを固定したGitHub archiveとZig content hashを使用します。Akamata checkoutの場所に依存せず、任意のdirectoryへprojectを作成できます。v0.0.1の初回scaffoldでは、自己参照archiveを避けるためimmutableなrelease準備revisionを参照します。次回以降は直前のstable releaseへpinを更新します。

```bash
cd ~/projects
akamata init myapp --target=both
cd myapp
```

`--target`には`native`、`workers`、`containers`、`both`を指定でき、デフォルトは`native`です。`both`では次のファイルが生成されます。

```text
myapp/
├── .gitignore
├── README.md
├── build.zig
├── build.zig.zon
├── migrations/
│   └── .gitkeep
├── src/
│   ├── main.zig
│   └── worker.zig
└── deploy/
    ├── Dockerfile
    ├── wrangler.toml
    └── worker/
        └── index.mjs
```

scaffoldはHello Worldではなく、SQLiteで動作するNote APIです。validation付きの`Note` modelと、次のrouteを含みます。

| Method | Route | 用途 |
|---|---|---|
| `GET` | `/` | 生成されたAPIの説明 |
| `GET` | `/health` | health check |
| `GET` | `/notes` | Note一覧 |
| `POST` | `/notes` | `{ "title", "body" }`からNoteを作成 |
| `GET` | `/notes/:id` | 1件取得 |
| `DELETE` | `/notes/:id` | 1件削除 |

native entrypointは起動時にmodel schemaとの差分を計算して適用します。Workers entrypointは`migrate.Once`を使用し、isolateごとに初期化を1回実行します。

初回buildでは固定済みAkamata sourceをdownloadします。`build.zig.zon`を編集せずlocal checkoutを試すには、Zig 0.16のpackage overrideを使用します。

```bash
zig build --fork=/path/to/Akamata
```

## 3. native serverを起動する

```bash
zig build run
```

port 8080でlistenしていることが表示されます。別のterminalから確認します。

```bash
curl -sS http://127.0.0.1:8080/
curl -sS http://127.0.0.1:8080/health
curl -sS http://127.0.0.1:8080/notes
curl -sS -X POST -H 'content-type: application/json' \
  -d '{"title":"hello","body":"first note"}' \
  http://127.0.0.1:8080/notes
```

`DATABASE_URL`を指定しない場合、local databaseは`myapp.db`です。

version付きmigrationも利用できます。fresh scaffoldには空の`migrations/` directoryがあり、そのまま適用した場合は成功するno-opです。

```bash
akamata migrate generate add_widgets
# 生成されたSQL fileを編集します。
akamata migrate up
```

適用済みversionは`schema_migrations`へ記録され、同じ`migrate up`を再実行してもskipされます。別directoryには`--dir=PATH`、特定versionまでの適用には`--target=VERSION`を指定します。

SQLiteとTursoではfile単位でatomicです。D1 bridgeは非transactionalなので、D1 migrationは
idempotentにし、レビュー済みdeploy経路を使用してください。

## 4. その他のtargetをビルドする

Workers:

```bash
zig build -Dbackend=workers -Doptimize=ReleaseSmall
cd deploy
npx wrangler dev --local
```

生成されたアプリをD1で動かす前にD1 databaseを作成し、`deploy/wrangler.toml`内でcomment outされている`[[d1_databases]]` bindingを有効にして値を更新してください。アプリ側も変更する場合を除き、binding名は`DB`のままにします。

Containers:

```bash
akamata deploy --containers
docker run --rm -p 8080:8080 akamata-app
```

Wranglerを設定した後、Workersへdeployするには次を実行します。

```bash
npx wrangler login
akamata deploy --workers
```

## 次に読む文書

- [Tutorial](tutorial.md): 完成したアプリを段階的に構築します
- [Handbook](handbook.md): model、repository、migration、deployを短時間で確認します
- [Handler API reference](handler-api.md): 現在のpublic APIとlifetimeを確認します
- [Database backends](db-backends.md): SQLite、D1、Tursoを設定します
- [WebSocket guide](websocket.md)
- [Documentation home](README.md)
