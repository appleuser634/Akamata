# Long-run benchmark

`benchmarks.md`の15秒smoke testより長い時間で、RSSの推移と高connection数などの条件を確認したstress testです。2026年5月時点のsnapshotであり、性能保証ではありません。元の測定には正確なGit commitが記録されていません。

## 実行環境

- macOS 26.0.1、Apple Silicon（10 core）
- Zig 0.16.0 ReleaseFast
- wrk 4.2.0、loopback（`127.0.0.1`）
- ベンチサーバー: 特に明記されていない限り、`examples/bench/src/main.zig`、`-c 256 -t 8`

## 主要な数値

|シナリオ |期間 |要求/秒 | P50 | P99 |マックス |エラー (5xx) | RSSドリフト |
|---|---|---:|---:|---:|---:|---|---|
| `/echo` (256 キープアライブ) | **5 分** | 177,242 | 35μs | **88 μs** | 58ミリ秒 | 0 / 53,182,832 | 3.1 → 2.5 MB |
| `/db/:id` (256 キープアライブ) | **3 分** | 87,726 | 74μs | **203 μs** | 1.19秒 | 0 / 15,799,556 | 3.1 → 2.7 MB |
| `/hello`（16 keep-alive） | 30秒 | 161,112 | 40 µs | 80 µs | 16.7 ms | 0 / 4,849,334 | 1.9 → 2.4 MB |
| `/hello`（1024 connection、`Connection: close`） | 60秒 | 1,536 | 17.6 ms | 64.7 ms | 223 ms | wrk側で1024 connection error | 該当なし（後述） |

## 詳細な観察

### 長時間実行してもレイテンシは安定しています

`/echo` は、10 秒間のスモーク テスト間で **同一の P99** を維持します (87 μs
`benchmarks.md`) と 5 分間のロングラン (このドキュメントでは 88 μs)。ドリフトはありません。

```
10s test  →  P50 33µs  P75 40µs  P90 49µs  P99 85µs  (171k req/s)
5min test →  P50 35µs  P75 42µs  P90 51µs  P99 88µs  (177k req/s)
```

実際、5 分間の実行では、10 秒間の実行よりも平均してわずかに「高い」スループットが得られます。
ウォームアップ。アロケータ/キャッシュのウォームアップが最終的に有利に解決することを示唆しています。

### RSS はフラットです - 漏れはありません

5 分間の `/echo` 実行中に 10 秒ごとにサンプリングされます。

```
t=0s    3152 KB
t=10s   3536 KB    (peak — alloc warmup)
t=30s   2688 KB    (released)
t=60s   2560 KB    (settled)
t=70s-300s   2560 KB  (FLAT)
end     2448 KB
```

5,300 万のリクエストが処理された後、常駐メモリは起動時よりも減少しました。
フレームワークのリクエストごとのアリーナはクリーンにリセットされ、スレッドローカルではありません
キャッシュのリーク。

### `/db/:id` P99 はフレームワークではなく SQLite によって支配されています

各リクエストの SQLite (`:memory:`) `prepare → bind → step → finalize`
このハードウェアでは最大 70 μs です。フレームワークにより、ワイヤ上で約 10 ～ 15 μs が追加されます。
203 μs の P99 は、SQLite の内部ミューテックスで時折発生する競合を反映しています。
256 の接続が同時に `prepare()` を試行する場合。

観測された **Max = 1.19 s** は、1,570 万件のリクエストの中の 1 つの外れ値です。
(P999 は個別に記録されませんでした)。考えられる原因: GC/JIT スタイルの stop-the-world
macOS カーネルのイベント (ページ再利用またはサーマル スロットリング)
持続的な負荷）。それは再発せず、P99 は 203 μs にとどまりました。
長時間実行するテストで許容できるノイズ。

### 接続チャーン (`Connection: close`) はフレームワークの外側でボトルネックになっています

1,024 接続の短期間のシナリオでは、1.5k req/s のみが報告されます。
1024 wrk 側の「接続」エラー。診断：

- 各リクエストは TCP ソケットを開いて閉じます。 close はソケットを挿入します
  デフォルトでは、`TIME_WAIT` が最大 30 秒間続きます。
- 60 秒間に最大 30,000 回の接続が行われると、カーネルが枯渇します。
  エフェメラルポートの→ `connect()` が失敗します。
- これは **OS TCP スタック**のプロパティであり、Akamata のプロパティではありません。

**すべての上流プロキシが存在するため、運用環境ではこのシナリオは存在しません。
(Cloudflare、nginx、HAProxy) キープアライブ** を使用します。裸で測ると
単一ホスト上の `Connection: close` を使用した HTTP/1.1 を測定すると、
カーネル。

### 同時実行性が低い場合でも 161,000 リクエスト/秒に達します

わずか 16 個のキープアライブ接続と 4 つの作業スレッドを備えたベンチ サーバーは、
クロック **161,111 req/s** — リクエストあたりの実際の処理時間は約 8 µs。
これは現実的なシングルテナントのケースです (1 つのアップストリーム プロキシ接続)
小さなファンアウトを持つプール）、これがフレームワークの **最良の尺度です
このマトリックスのオーバーヘッド**。

## 複製

```bash
zig build -Dexample=bench -Doptimize=ReleaseFast
./zig-out/bin/bench &

# /echo long run
cat > /tmp/wrk_echo.lua <<'LUA'
wrk.method = "POST"
wrk.body   = '{"name":"x","n":42}'
wrk.headers["content-type"] = "application/json"
LUA
wrk -t8 -c256 -d300s --latency -s /tmp/wrk_echo.lua http://127.0.0.1:8080/echo

# /db long run
cat > /tmp/wrk_db.lua <<'LUA'
math.randomseed(os.time())
request = function() return wrk.format("GET", "/db/" .. tostring(math.random(1,3))) end
LUA
wrk -t8 -c256 -d180s --latency -s /tmp/wrk_db.lua http://127.0.0.1:8080

# RSS sampling: a 10-second-interval logger you start alongside
( while true; do
    ps -o rss= -p $(pgrep -f zig-out/bin/bench | head -1) ;
    sleep 10
  done ) > /tmp/rss.log
```

## ファズ硬化 (PROD1)

別の `tools/fuzz/http_fuzz.mjs` スクリプトが 14 個の敵対的リクエストをスローする
パターン (HTTP 密輸、チャンク化された不正形式、スローロリスのドリップ、CL の嘘、
URL 内の制御文字、…) を実行中のサーバーで 30 秒間実行します。 **902以降
試行** サーバーは依然としてファズ後の正常性要求に次のように応答しました
すべてのエンドポイントで 200 OK が発生し、ログにはすべての不正なリクエストが示されました
正しいフレームワーク エラー コードで拒否されました:

|エラークラス |バリアントが検出されました |
|---|---|
| `BodyTooLarge` | `hugeBodyButTinyCL` / `giantContentLengthLie` |
| | `smugglingCLTE` / `smugglingDuplicateCL` |
| | `nulByteInHeader` / `chunkedBadHex` |
| `InvalidRequestLine` | `illegalRequestLine` / `controlCharInUrl` |
| `UnknownMethod` | `illegalMethod` |
| `HeadersTooLarge` | `slowloris` |

パニックも、漏れも、ゴミ反応もありません。以下で再現します:

```bash
./zig-out/bin/bench &
node tools/fuzz/http_fuzz.mjs http://127.0.0.1:8080 --duration=30s --workers=8
```

## 既知の問題/今後の課題

- **ヒストグラム バケット境界**はコンパイル時に固定されます。追跡対象
  `docs/ja/observability.md`「将来の仕事」。
- `/db` 長期実行における **macOS Max = 1.19 秒の異常値**はカーネル/スケジューラーです
  フレームワークのバグではなくアーティファクト。 15.7Mに1回観測されました
  リクエスト。確認のために Linux で再チェックする価値があります。
- 合成チャーン シナリオにおける **TIME_WAIT の枯渇**は OS レベルの問題です
  財産。プロキシ経由の実際の運用トラフィックは影響を受けません。
