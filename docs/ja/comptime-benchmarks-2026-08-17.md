# Compile-time routing benchmark — 2026-08-17

最大Hello World値だけでなく、route/middleware増加時のscalingを測定しました。両variantは
同じ`App`、HTTP server、handler、response coreを使い、`runtime`は通常登録、`static`は
`Routes`/`mountStatic`とstatic middleware合成を使用します。

環境はApple M2（8 core、16 GB）、macOS 26.5、Zig 0.16.0、oha 1.15.0、ReleaseFast、
loopback、16 connections、各3秒×3回の中央値です。

## Static pathのroute scaling

|Routes|Runtime req/s|Static req/s|差|Runtime P50/P95/P99|Static P50/P95/P99|Runtime/Static RSS|Runtime/Static binary|
|---:|---:|---:|---:|---|---|---:|---:|
|1|153,721|148,967|-3.09%|0.091/0.178/0.336 ms|0.089/0.197/0.385 ms|1,824/1,808 KB|494,320/494,480 B|
|10|151,394|151,160|-0.15%|0.091/0.183/0.341 ms|0.091/0.192/0.348 ms|1,808/1,808 KB|495,984/496,320 B|
|100|149,446|145,195|-2.84%|0.090/0.191/0.388 ms|0.090/0.206/0.404 ms|1,904/1,888 KB|527,184/527,392 B|
|500|151,495|147,871|-2.39%|0.090/0.185/0.344 ms|0.090/0.210/0.442 ms|2,288/2,304 KB|725,664/781,056 B|

10 routesは同等です。100/500 routesのstatic値はspecialization閾値32を超えるため共有
fallbackを使います。500 routesを全展開したprototypeは137,922 req/s、837,728 bytesまで
悪化したため、測定結果に基づいて選択的fallbackを導入しました。残る2〜3%差は短時間runの
分散内であり、性能向上とは主張しません。

## 100 routesでのroute型／middleware scaling

|Case|Runtime req/s|Static req/s|差|Runtime P99|Static P99|
|---|---:|---:|---:|---:|---:|
|Parameter、middleware 0|144,575|140,845|-2.58%|0.420 ms|0.474 ms|
|Wildcard、middleware 0|142,714|144,007|+0.91%|0.428 ms|0.378 ms|
|Static、middleware 3|149,403|146,601|-1.88%|0.399 ms|0.385 ms|
|Static、middleware 6|148,558|145,993|-1.73%|0.413 ms|0.414 ms|

route/middleware増加による単調なthroughput崩壊はありません。static middlewareはsliceと
index dispatchを除去しますが、このnetwork-level workloadではrun間noise未満です。
従って現時点では静的合成手段であり、throughput向上として宣伝しません。

## 既存hot pathの回帰確認

通常の1-route `GET /hello`を変更前`c7b0811`と比較しました。wrk、4 threads、16
connections、5秒×3回で、順序bias確認後のcurrent中央値171,455 req/s、baseline
171,809 req/s（-0.21%）でした。rangeは重なり、P50は73〜74 µsで、明確な回帰は
ありません。

既存defaultは100 requestsごとにconnectionをrecycleするため、wrk read errorと短時間
P99 noiseが発生します。この挙動は今回変更していません。

## Sizeとstartup

新APIをinstantiateしないapplicationでは、native benchが1,850,776から1,850,584 bytes
（-192 bytes）、Workers chat WASMが98,894から99,104 bytes（+210 bytes、+0.21%）でした。

1/10/100 static routesの増加は160/336/208 bytesです。500-route static benchmarkは
55,392 bytes（+7.63%）増加しており、large graphをさらにspecializeしない理由です。
readiness値は約180〜360 msですがprocess/polling overheadを含み分散が大きいため、JSONに
記録するだけでregression gateには使用しません。

再現command:

```console
DURATION=3s CONNECTIONS=16 OUT=/tmp/router.csv \
  examples/router_bench/run_matrix.sh
```

集計dataは[`benchmark-results/20260817-comptime-router.json`](../../benchmark-results/20260817-comptime-router.json)です。
