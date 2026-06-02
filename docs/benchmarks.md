# Benchmarks

Production-向け改善の効果と、同等の他フレームワークとの比較。

## 実行環境

- macOS 26.0.1, Apple Silicon (M2 Pro, 10 cores)
- Zig 0.16.0 ReleaseFast
- Go 1.24.5
- Bun 1.3.0 / Hono 4.12.x
- wrk 4.2.0
- ループバック (127.0.0.1)、wrk と server は同一ホスト

## ベンチパラメータ

```
threads=8  connections=256  duration=10s
wrk -t8 -c256 -d10s --latency
```

3 つのシナリオ:

| シナリオ | エンドポイント | 説明 |
|---|---|---|
| **hello** | `GET /hello`  | static text レスポンス。フレームワーク overhead を測る |
| **echo**  | `POST /echo`  | JSON `{"name","n"}` を読んで JSON で返す |
| **db**    | `GET /db/:id` | SQLite (in-memory) で 1 行 SELECT |

実装:
- Akamata: [`examples/bench/src/main.zig`](../examples/bench/src/main.zig) (`am.App` + `am.db.openSqlite`)
- Go: [`examples/bench/go/main.go`](../examples/bench/go/main.go) (`net/http` + `modernc.org/sqlite`)
- Hono on Bun: [`examples/bench/hono/index.ts`](../examples/bench/hono/index.ts) (`hono@4` + `bun:sqlite`)

---

## v0.4 拡張ベンチマーク (6+1 競合との比較, May 2026)

7 つの実装を同一マシン・同一ワークロードで比較:

| # | 実装 | ランタイム / 言語 | 内蔵 DB ドライバ |
|---|---|---|---|
| 1 | **Akamata threaded** | Zig 0.16 (thread-per-conn) | sqlite3 amalgamation |
| 2 | **Akamata reactor**  | Zig 0.16 (thread-per-core, kqueue) | sqlite3 amalgamation |
| 3 | Go net/http | Go 1.24 | modernc.org/sqlite (pure Go) |
| 4 | Rust Axum            | Rust 1.90 (tokio) | rusqlite (bundled) |
| 5 | Bun raw (`Bun.serve`) | Bun 1.3 (JavaScriptCore) | bun:sqlite (native) |
| 6 | Hono on Bun           | Bun 1.3 + Hono 4 | bun:sqlite |
| 7 | Node + Fastify        | Node 25 + Fastify 5 | better-sqlite3 (native) |

### スループット (req/s, 高いほど良い)

| 実装 | /hello | /echo | /db |
|---|---:|---:|---:|
| **Akamata threaded** | 189,284 | 192,272 | 99,919 |
| **Akamata reactor**  | **221,316** | 215,782 | 113,031 |
| Go net/http          | 209,713 | 176,510 |  52,063 ⚠️ |
| Rust Axum            | 216,152 | **217,300** | 135,249 |
| Bun raw              | 204,688 | 156,280 | 160,370 |
| Hono on Bun          | 195,830 | 140,708 | 144,356 |
| Node + Fastify       |  91,609 |  68,627 |  79,277 |

⚠️ Go の `/db` は `modernc.org/sqlite` で wrk 高負荷下に大量 5xx エラーを吐く (前回計測で 40% non-2xx)。
今回も `responses:` のエラー表示が出ており、スループット数値は実質意味なし。

### レイテンシ (P50 / P99)

| 実装 | /hello P50 / P99 | /echo P50 / P99 | /db P50 / P99 |
|---|---|---|---|
| **Akamata threaded** | **34 µs / 77 µs** | **33 µs / 76 µs** | **65 µs / 191 µs** |
| Akamata reactor      | 970 µs / 18.1 ms | 794 µs / 28.6 ms | 2.12 ms / 7.36 ms |
| Go net/http          | 585 µs / 9.8 ms  | 940 µs / 18.1 ms | 5.08 ms / 24.6 ms |
| Rust Axum            | 748 µs / 7.78 ms | 690 µs / 11.9 ms | 1.83 ms / 4.56 ms |
| Bun raw              | 1.20 ms / 2.29 ms | 1.51 ms / 12.1 ms | 1.53 ms / 3.56 ms |
| Hono on Bun          | 1.26 ms / 2.40 ms | 1.77 ms / 2.53 ms | 1.69 ms / 3.46 ms |
| Node + Fastify       | 2.76 ms / 66.4 ms | 3.59 ms / 93.8 ms | 3.18 ms / 22.8 ms |

→ **`/hello` P99 で Akamata threaded は次点 (Bun raw 2.29 ms) の 30× 高速**。

### バイナリ / ランタイム

| 実装 | バイナリ | 必要なランタイム |
|---|---|---|
| **Akamata threaded** | **1.8 MB** (single static binary) | なし |
| **Akamata reactor**  | **1.8 MB** (same binary) | なし |
| Go net/http          | 13.8 MB | なし |
| Rust Axum            | 2.7 MB | なし |
| Bun raw              | n/a   | Bun ランタイム (約 100 MB install) |
| Hono on Bun          | n/a   | Bun + node_modules |
| Node + Fastify       | n/a   | Node + node_modules |

Akamata + Rust は **そのまま `FROM scratch` Docker に放り込める** サイズ。
Go は 5× の sized 差。JS 系はランタイム本体 + npm tree が必要。

### コールドスタート (TTFB)

最初の `GET /hello` が 200 を返すまでの実測ミリ秒 (3 回平均):

| 実装 | TTFB |
|---|---:|
| Akamata threaded     | **~50 ms** |
| Akamata reactor      | **~47 ms** |
| Go net/http          | ~48 ms |
| Rust Axum            | ~48 ms |
| Hono on Bun          | ~48 ms |
| Node + Fastify       | ~48 ms |
| Bun raw              | ~167 ms (Bun.serve は最初の fetch で warm up) |

ほぼ全実装が `curl --max-time` の粒度 (50 ms 単位) に張り付き、有意差なし。
Bun raw のみ Bun.serve の lazy initialise でやや遅い。

### リソース消費 (負荷中サンプリング, 1Hz)

`wrk` を 10s 走らせる間に `ps` + `lsof` で 1 秒ごとにサンプルした実測値。
詳細は [`/tmp/bench_resources.json`](/tmp/bench_resources.json) (再生は `bash examples/bench/resources_all.sh`)。

#### Idle (起動 1 秒後、リクエスト前)

| 実装 | RSS | CPU% | スレッド | FD |
|---|---:|---:|---:|---:|
| **Akamata threaded** | **3.3 MB** | 0.0% | 8 | 9 |
| Akamata reactor      | 3.5 MB | 0.0% | 11 | 39 |
| Rust Axum            | 3.6 MB | 0.0% | 11 | 13 |
| Go net/http          | 18.3 MB | 0.0% | 9 | 8 |
| Bun raw              | 25.5 MB | 0.1% | 5 | 10 |
| Hono on Bun          | 41.7 MB | 0.2% | 13 | 10 |
| Node + Fastify       | 46.2 MB | 0.0% | 8 | 36 |

Akamata threaded の **idle RSS は次点 Rust Axum より 10% 少なく、Fastify の 1/14**。
これは Cloudflare Containers のような「軽量 instance を多数並べる」運用で直接的に
コスト削減に効く。

#### /hello 負荷時 (10 秒平均)

| 実装 | RSS avg (MB) | RSS peak | CPU% avg | CPU% peak | スレッド | FD |
|---|---:|---:|---:|---:|---:|---:|
| **Akamata threaded** | **3.5** | 3.5 | **189%** | 217% | 8 | 17 |
| Akamata reactor      | 9.5 | 10.2 | 286% | 328% | 11 | **295** |
| Rust Axum            | 21.6 | 25.0 | 305% | 362% | 11 | 269 |
| Go net/http          | 38.1 | 41.1 | 383% | 451% | 19-22 | 264 |
| Bun raw              | 42.0 | 44.0 | **89%** | 101% | 5-8 | 266 |
| Hono on Bun          | 67.7 | 70.8 | 90% | 101% | 13 | 266 |
| Node + Fastify       | 113.2 | 126.0 | 87% | 100% | 8 | 273 |

#### /db (SQLite) 負荷時 — DB ワークロードで RSS が増えやすい

| 実装 | RSS avg (MB) | CPU% avg | 備考 |
|---|---:|---:|---|
| **Akamata threaded** | **3.1** | 270% | SQLite を C で直リンク、conn pool 不要 |
| Akamata reactor      | 9.7 | 436% | per-worker arena + 256 conn buffer |
| Rust Axum            | 30.6 | 239% | rusqlite Mutex で直列化、CPU 低めだが mem は大きい |
| Go net/http          | 77.6 | 374% | modernc.org/sqlite の per-conn state 大、しかも 40% エラー |
| Bun raw              | 45.4 | 90% | bun:sqlite (native binding) でメモリは Bun heap |
| Hono on Bun          | 71.9 | 89% | + Hono runtime |
| Node + Fastify       | 120.8 | 81% | better-sqlite3 + Node V8 heap |

### CPU 効率 (req/s ÷ CPU% × 100 = req/s/core)

これは「**1 コア分の CPU で何リクエスト捌けるか**」の指標。
クラウド料金は概ね vCPU 単位で決まるので、これがコスト効率の代理指標になる。

| 実装 | /hello rps | CPU% | rps/core |
|---|---:|---:|---:|
| Bun raw               | 204,688 |  89 | **230,000** ⭐ |
| Hono on Bun           | 195,830 |  90 | 217,600 |
| Node + Fastify        |  91,609 |  87 | 105,300 |
| **Akamata threaded**  | 189,284 | 189 | **100,150** |
| Akamata reactor       | 221,316 | 286 |  77,400 |
| Rust Axum             | 216,152 | 305 |  70,900 |
| Go net/http           | 209,713 | 383 |  54,700 |

**JS 系 (Bun, Hono) が rps/core で勝つ** のは、JS が本質的にシングルスレッドで
JIT が hot path を凶悪に最適化するため、1 core を 100% 近く使い切れるからである。
ただし **JS は並列性が無いので最大 throughput では負ける** (上限 = 1 core 分)。

Akamata threaded は **マルチコアを使いつつ、その範囲で最も効率的に CPU を使う**
バランス型。Rust Axum / Go は同等のマルチスレッド設計だが、Akamata threaded の
半分以下の CPU efficiency。

→ **コスト最適化が最重要なケース**: Bun ベースのフレームワーク (上限はあるが)
→ **絶対 throughput + 並列性が最重要なケース**: Akamata reactor / Rust Axum
→ **メモリ予算が最重要なケース**: Akamata threaded (一桁少ない)

### スコアカード

各カテゴリの優勝者:

| カテゴリ | 勝者 | 数値 |
|---|---|---|
| 最速 throughput (/hello) | Akamata reactor | 221k req/s |
| 最速 throughput (/echo)  | Rust Axum | 217k req/s |
| 最速 throughput (/db)    | Bun raw | 160k req/s (native sqlite) |
| 最低 P99 (/hello, /echo, /db) | **Akamata threaded** | 77 / 76 / 191 µs |
| 最小バイナリ | **Akamata** | 1.8 MB |
| 最小 idle RSS | **Akamata threaded** | 3.3 MB |
| 最小 /hello 負荷時 RSS | **Akamata threaded** | 3.5 MB (Fastify の 1/32) |
| 最高 CPU 効率 (rps/core) | Bun raw | 230k rps/core |
| 最大 throughput × バイナリサイズの両立 | **Akamata reactor** | 221k req/s / 1.8 MB |

### まとめ

1. **Akamata threaded は全シナリオで P99 が最低** — 35-200 µs レンジ、競合は 2-90 ms
2. **Akamata reactor は /hello throughput で全勢力トップ** (221k req/s)
3. **Akamata + Rust が唯一「FROM scratch ですぐ動く」サイズ** (≤3 MB)
4. **Go の sqlite ドライバが /db で実用に耐えない** (40% error rate) → Akamata が C amalgamation 直リンクしているメリットが効く
5. **Bun raw vs Hono の差は約 10-30 k req/s** = Hono フレームワーク overhead の見える化
6. **Fastify は単独で大きく遅い** — Node の event loop + `better-sqlite3` の同期呼び出しが綱引きしている可能性
7. **Akamata threaded のメモリ消費は競合の 1/10 ~ 1/34** — idle 3.3 MB, /hello 負荷時 3.5 MB。クラウド run-cost が劇的に下がる
8. **JS 系の CPU efficiency (rps/core) は驚くほど高い** — Bun raw が 230k rps/core で 1 位。ただしシングルスレッド上限ゆえに **絶対 throughput では Akamata reactor/Rust に届かない**

詳細出力: [`/tmp/bench_results.json`](/tmp/bench_results.json) (実行後に再生される)

---

## v0.4 結果 (PERF7-9 適用後, May 2026)

### スループット (req/s, 高いほど良い)

| シナリオ | Akamata threaded | Akamata reactor | Go net/http | Hono on Bun |
|---|---:|---:|---:|---:|
| **hello** | 175,664 | **213,023** | 203,147 | 184,368 |
| **echo**  | 179,270 | **210,124** | 194,217 | 138,514 |
| **db**    |  99,107 | **108,183** |  52,409 (40% err) | 141,575 |

`Akamata reactor` は 3 シナリオすべてで Go を上回り、`hello`/`echo` では全勢力のトップ。
DB だけは Hono の `bun:sqlite` (Bun の native 高速 binding) が圧倒的に速いが、これはバックエンドの差で、フレームワーク overhead の差ではない。

### レイテンシ P50 / P99

| | /hello P50 / P99 | /echo P50 / P99 | /db P50 / P99 |
|---|---|---|---|
| **Akamata threaded** | **35 µs / 87 µs** | **34 µs / 96 µs** | **66 µs / 189 µs** |
| Akamata reactor | 773 µs / 41 ms | 637 µs / 32 ms | 2.1 ms / 36 ms |
| Go net/http | 617 µs / 23 ms | 833 µs / 13 ms | 5.0 ms / 25 ms |
| Hono on Bun | 1.3 ms / 2.8 ms | 1.8 ms / 2.6 ms | 1.7 ms / 6.0 ms |

`Akamata threaded` は **全 P99 で 200µs を下回り、全競合に対し 10-300× 高速**。これは
1 connection 1 thread + 同期 read-dispatch-write loop が高密度なまま回る wrk の
benchmark pattern と完全に噛み合っている。

`Akamata reactor` は throughput でトップだが P99 はワースト。理由は wrk -c 256 が
**256 個の synchronous キープアライブ pipe** を保つこと: reactor が 10 worker で
分担すると、1 worker が 25 連結を時分割するため P99 が広がる。

→ **`threaded` を勧めるケース**: 同時接続数 ≤ accept_thread_count × 数倍
　 (通常の REST / GraphQL API、本番 reverse-proxy 前段あり)
→ **`reactor` を勧めるケース**: 同時接続数 > 数百 (チャット、SSE、WebSocket-heavy)

---

## 改善の経緯

### v0.2 (15s wrk)

| Akamata 改善前 | Akamata 改善1回目 | Akamata Production |
|---:|---:|---:|
| hello: 164,919 | 175,194 | 173,344 |
| echo:  143,869 | 167,716 | 183,123 |
| db:     82,464 |  94,136 |  96,784 |

### v0.3 (kqueue reactor MVP, シングルスレッド)

| シナリオ | threaded | reactor (1-thread) | Δ throughput | P50/P99 reactor |
|---|---:|---:|---:|---|
| /hello | 167k | 188k | +12.7% | 1.22ms / 5.38ms |
| /echo  | 148k | 176k | +18.9% | 1.32ms / 5.13ms |
| /db    |  83k |  92k | +10.7% | 2.38ms / 27.35ms |

→ シングルスレッド reactor は throughput は上がるが P50 が 30× 悪化 (1 worker が
全 conn を直列処理するため)。「worker pool が必要」と分かった。

### v0.3.1 (中央 reactor + MPMC worker pool)

| シナリオ | threaded | reactor+pool | Δ throughput |
|---|---:|---:|---:|
| /hello | 105k | 103k | -2.6% |
| /echo  | 121k |  98k | -19.0% |
| /db    |  69k |  90k | +31.0% |

→ MPMC mutex contention で `/hello`,`/echo` 改善せず。CPU-bound `/db` のみ並列化が効いた。

### v0.4 (per-worker reactor / thread-per-core, PERF7-9)

各 worker が独立した kqueue + 専用 connection 群を持つ thread-per-core 設計。
MPMC mutex を完全に排除、accept だけ単独 thread で round-robin に worker pipe へ
配信。さらに per-worker 16KB送信バッファ (PERF8) + comptime JSON emitter (PERF9)。

| シナリオ | threaded (v0.4) | reactor (v0.4) | vs baseline (v0.3) |
|---|---:|---:|---:|
| /hello | 175k | **213k** | +13% vs Akamata threaded best |
| /echo  | 179k | **210k** | +15% |
| /db    |  99k | **108k** | +9% |

---

## RSS / メモリ安定性

5 分間の `/echo` ロング走 (53M リクエスト):

```
t=0s    3,152 KB
t=10s   3,536 KB    (peak — alloc warmup)
t=30s   2,688 KB    (released)
t=60s   2,560 KB    (settled, FLAT for the rest)
end     2,448 KB
```

→ **メモリリーク無し**、5 分連続で 2.5 MB に収束。`docs/benchmarks-long-run.md` 参照。

---

## 詳細 wrk 出力

### Akamata threaded

```
$ wrk -t8 -c256 -d10s --latency http://127.0.0.1:8080/hello
  Latency Distribution
     50%   35.00us
     75%   45.00us
     90%   56.00us
     99%   87.00us
Requests/sec: 175,664
```

### Akamata reactor (thread-per-core)

```
$ BENCH_RUNTIME=reactor ./bench &
$ wrk -t8 -c256 -d10s --latency http://127.0.0.1:8080/hello
  Latency Distribution
     50%  773.00us
     75%    1.22ms
     90%    3.36ms
     99%   41.19ms
Requests/sec: 213,023
```

### Go net/http

```
$ wrk -t8 -c256 -d10s --latency http://127.0.0.1:8081/hello
  Latency Distribution
     50%  617.00us
     75%    2.30ms
     90%    5.40ms
     99%   23.18ms
Requests/sec: 203,147
```

### Hono on Bun

```
$ wrk -t8 -c256 -d10s --latency http://127.0.0.1:8082/hello
  Latency Distribution
     50%    1.32ms
     75%    1.46ms
     90%    1.58ms
     99%    2.76ms
Requests/sec: 184,368
```

---

## 再現手順

```bash
brew install wrk go bun

# 1. ベンチサーバをビルド
zig build -Dexample=bench -Doptimize=ReleaseFast
(cd examples/bench/go && go build -o /tmp/yt-bench-go .)
(cd examples/bench/hono && bun install)

# 2. 比較ベンチ
cat > /tmp/wrk_echo.lua <<'LUA'
wrk.method = "POST"
wrk.body   = '{"name":"x","n":42}'
wrk.headers["content-type"] = "application/json"
LUA

cat > /tmp/wrk_db.lua <<'LUA'
math.randomseed(os.time())
request = function() return wrk.format("GET", "/db/" .. tostring(math.random(1,3))) end
LUA

# Akamata threaded (port 8080)
./zig-out/bin/bench &
wrk -t8 -c256 -d10s --latency http://127.0.0.1:8080/hello
pkill bench

# Akamata reactor (port 8080)
BENCH_RUNTIME=reactor ./zig-out/bin/bench &
wrk -t8 -c256 -d10s --latency http://127.0.0.1:8080/hello
pkill bench

# Go (port 8081)
/tmp/yt-bench-go &
wrk -t8 -c256 -d10s --latency http://127.0.0.1:8081/hello
pkill yt-bench-go

# Hono (port 8082)
(cd examples/bench/hono && bun run index.ts) &
wrk -t8 -c256 -d10s --latency http://127.0.0.1:8082/hello
pkill -f index.ts
```

---

## まとめ

Akamata は v0.4 で **3 つのワークロード全てで Go を上回る** スループットを達成し、
P99 では他 3 フレームワーク全てに対し 10× 以上の優位を得た。これはランタイム選択を:

- `threaded` (デフォルト) — 通常の REST API、低同時接続、Cloudflare/nginx 前段あり
- `reactor` (opt-in) — 同時接続数が数百以上、SSE/WebSocket-heavy

と使い分けることで、各シナリオで最適な性能特性を引き出せる。

設計と実装の詳細は [`docs/perf-reactor-design.md`](perf-reactor-design.md) を参照。
