# DB バックエンド

`am.db.Db` は vtable 抽象。同じハンドラコードが native (SQLite), Workers (D1), Turso (libsql/Hrana) で動く。

## 共通 API

```zig
pub const Db = struct {
    pub fn prepare(self: Db, sql: []const u8) !Stmt
    pub fn exec(self: Db, sql: []const u8) !void
    pub fn execAll(self: Db, script: []const u8) !void   // ; 区切りで複数実行
    pub fn close(self: Db) void
};

pub const Stmt = struct {
    pub fn bind(self: Stmt, idx: usize, v: Value) !void
    pub fn bindAll(self: Stmt, args: anytype) !void       // タプルを 1-origin で
    pub fn step(self: Stmt) !StepResult                   // .row | .done
    pub fn fetchOne(self: Stmt, comptime T: type) !T      // 1 行を struct にマップ
    pub fn readRow(self: Stmt, comptime T: type) !T
    pub fn columnInt/Float/Text/Blob(self: Stmt, idx) !...
    pub fn reset(self: Stmt) !void
    pub fn deinit(self: Stmt) void
};
```

## URL スキーマで透過選択

```zig
var db = try am.db.open(alloc, url);
```

| URL                          | バックエンド          |
|------------------------------|------------------------|
| `file:chat.db`               | SQLite (native)        |
| `libsql://example.turso.io`  | Turso/libsql (HTTP)    |
| `https://example.turso.io`   | Turso/libsql (HTTP)    |
| `d1:DB`                      | Cloudflare D1 (Workers)|

`d1:` は実行ターゲットが `wasm32-freestanding` のときのみ有効。それ以外は SQLite/Turso が選ばれる。

### 4 つの組み合わせサポート状況

| デプロイ先 | DB | サポート | 経路 |
|---|---|---|---|
| **VPS / Container (native)** | SQLite | ✅ | `file:` → `sqlite3.c` を直接リンク |
| **VPS / Container (native)** | Turso  | ✅ | `libsql://` → `std.crypto.tls.Client` で直接 HTTP/1.1 を送る (依存なし) |
| **Cloudflare Workers (wasm)** | D1     | ✅ | `d1:` → JSPI で D1 binding を同期呼び出し |
| **Cloudflare Workers (wasm)** | Turso  | ✅ | `libsql://` → `akamata_http.akamata_fetch` (Suspending fetch) 経由 |

全てハンドラ側のコードは同一 (`am.db.open(url)` の URL だけ環境変数で切り替える)。

## SQLite (native)

```zig
var db = try am.db.openSqlite(alloc, "chat.db");
defer db.close();
try db.execAll(@embedFile("schema.sql"));
```

`third_party/sqlite/sqlite3.c` を `build.zig` が `addCSourceFile` でリンク。`PRAGMA journal_mode=WAL; foreign_keys=ON` がデフォルトで有効。

## Turso (libsql / Hrana v3 over HTTP)

```zig
var db = try am.db.openTurso(alloc, "libsql://your-db.turso.io", auth_token);
```

`src/db/turso.zig` が Hrana v3 (`POST /v3/pipeline`) を喋る。baton トークンでステートフルセッションを継続。ステートメントは Hrana の execute オペレーションに変換され、行は `args` / `cols` JSON から読み戻す。

メリット:
- VPS / Containers から **任意の Turso DB** を参照できる
- D1 と違い同期的に呼べる (HTTP は std.Io.net で `await` 不要)
- マルチリージョン読み取りレプリカが標準サポート

## D1 (Workers) — JSPI 実装

```zig
// am.db.open("d1:DB") もしくは直接:
var db = try am.db.openD1(alloc);
```

### 実装: JavaScript Promise Integration (JSPI)

D1 の JS API は async (各 `prepare/bind/all` が Promise) なので Zig の同期セマンティクスと根本的に折り合いが悪い。Akamata は V8 の **JSPI** (JavaScript Promise Integration) を使ってこのギャップを完全に吸収する:

1. **JS host** (`deploy/.../worker/index.mjs`) が各 async D1 関数を `new WebAssembly.Suspending(fn)` でラップ
2. wasm エントリ `handle_fetch` を `WebAssembly.promising(...)` でラップ
3. Zig 側はインポートを通常の `extern fn` として呼ぶだけ — V8 がスタックを park/resume する

**重要 — 1 ステートメント 1 サスペンド**: JSPI の suspend/resume は wasm コールスタック全体を park/resume するため、JS 側が I/O をしなくてもコストがかかる。したがって**実際に await するのは `d1_run`（クエリ実行 + 全行マテリアライズ）だけ**にし、`d1_step` / `d1_column_*` は同期インポートにする。Zig 側は最初の `step()` で `d1_run` を遅延実行し、以降は同期的に行カーソルを進める。これで N 行の SELECT が「1 サスペンド」で済む（素朴に `d1_step` を Suspending でラップすると **1 行 1 サスペンド**になり、20 行のタイムラインで ~20 回の不要なスタックスイッチが発生する）。

```js
// 抜粋: deploy/mobus/worker/index.mjs
// 唯一の async D1 op: bind + run で全行をマテリアライズ。
d1_run: new WebAssembly.Suspending(async (h) => {
  const e = d1stmts.get(h);
  const bound = e.bindArgs.length > 0 ? e.base.bind(...e.bindArgs) : e.base;
  const out = await bound.raw({ columnNames: true });
  e.columnNames = Array.isArray(out) && out.length > 0 ? out[0] : [];
  e.rows = Array.isArray(out) && out.length > 0 ? out.slice(1) : [];
  e.cursor = 0;
  return e.rows.length;
}),
// 同期: マテリアライズ済みの行カーソルを進めるだけ（サスペンドしない）。
d1_step(h) {
  const e = d1stmts.get(h);
  if (!e || e.rows == null) return -1;
  if (e.cursor >= e.rows.length) { e.currentRow = null; return 0; }
  e.currentRow = e.rows[e.cursor++];
  return 1;
},
// ...
handleFetchAsync = WebAssembly.promising(exports_ref.handle_fetch);
```

```zig
// src/db/d1.zig — Zig 側はただの extern fn
extern "akamata_d1" fn d1_step(stmt: i32) i32;
```

### Zero overhead

- **Zig コード変更ゼロ**: SQLite/Turso/D1 で完全に同じハンドラが動く
- **コードサイズ膨張ゼロ**: Asyncify (Binaryen) のような全関数 CPS 変換と違い、wasm バイナリには何も追加されない
- **通常実行の overhead ゼロ**: 同期パスは普通の関数呼び出し
- **同じパターンが KV / R2 / Durable Objects / `fetch()` に流用可能**

### 後方互換 (古いランタイム向け)

旧 Miniflare や JSPI 未対応の wrangler では `WebAssembly.Suspending` が無い。その場合 JS host は `-2` センチネルを返すスタブにフォールバックし、Zig 側は `D1Error.BridgeNotImplemented` を投げる。fail-closed なのでサイレント失敗にはならない。

```zig
return switch (rc) {
    0 => {},
    -2 => D1Error.BridgeNotImplemented,
    else => D1Error.ExecFailed,
};
```

### パフォーマンス特性 (D1 vs Turso vs SQLite)

| バックエンド | 1 クエリの理論レイテンシ | 備考 |
|---|---|---|
| SQLite (native) | ~10us | 同一プロセス、メモリアクセスのみ |
| Turso (HTTP) | 1 RTT (~10-50ms) | リージョン間 raw HTTP/2 |
| D1 (JSPI / Workers) | ~5-15ms | Cloudflare 内部、edge-local 配置 |

JSPI の wasm stack switch 1 回は **µs オーダー**だが、resume は JS のマイクロタスクキューを経由するため**回数が効く**。「1 ステートメント 1 サスペンド」設計（上記の `d1_run` + 同期 `d1_step`）を守れば 1 クエリ 1 サスペンドに収まり、ネットワーク往復に対して無視できる。逆に行ごとにサスペンドすると 1 リクエストで数十回のスタックスイッチが積み上がり、ネイティブ比で数 ms の乖離（実測で P90 ~20ms）になる。実測すべきは:

1. **コールドスタート**: `wrangler dev` での初回 `handle_fetch` (wasm instantiate + D1 接続)
2. **P50/P99 レイテンシ**: シンプルな `SELECT 1` をループで打つ
3. **スループット**: 同時 100 接続 × 10s の `INSERT` + `SELECT`
4. **Turso との比較**: 同じテーブル定義・同じクエリで HTTP libsql の値と比較

### 計測手順 (out-of-band)

```bash
# wrangler でローカル D1 を立てる
cd examples/mobus
wrangler d1 execute mobus --local --file=schema.sql
wrangler dev --local --port 8787

# 別ターミナルから wrk
wrk -t4 -c100 -d15s --latency http://127.0.0.1:8787/api/messages

# Turso 同等
TURSO_URL=libsql://your-db.turso.io TURSO_TOKEN=... ./zig-out/bin/mobus
wrk -t4 -c100 -d15s --latency http://127.0.0.1:8080/api/messages
```

実値は環境依存 (Workers なら CF edge の場所、Turso なら DB のリージョン) なので、ベンチマークは「自分の本番デプロイ先で取る」のが原則。

## マイグレーション

| バックエンド | 起動時 |
|---|---|
| native SQLite | `db.execAll(@embedFile("schema.sql"))` を `main()` で |
| Turso         | `db.execAll(...)` 同上 (HTTP に発行) |
| D1 (Workers)  | `wrangler d1 execute <DB> --file=schema.sql` をデプロイ前に手動実行 (Workers の起動時刻はホットリロードしたい場合 `db.execAll()` でも OK だが、本番では out-of-band 推奨) |
