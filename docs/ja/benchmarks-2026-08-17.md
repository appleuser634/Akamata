# Performance regression report — 2026-08-17

現行DX改善後revisionと変更直前revisionを、同じmachine・compiler・負荷生成toolでA/B測定したperformance regression reportです。

## 結論

**今回の変更による明確なperformance劣化は確認されませんでした。** 安定性の高い16 connection測定で、throughput中央値の差は`hello +0.14%`、`echo +0.07%`、`db -1.38%`でした。3回の測定rangeは重なっており、通常のscheduler／thermal／SQLite競合による変動範囲です。

idle RSSは両revisionとも3,056 KB、ReleaseFast binary増加は320 bytes（+0.017%）でした。負荷時RSSはscenarioにより-2.2%から+4.3%で、単発1 Hz samplingの変動範囲です。

## 比較対象

|区分|Revision|
|---|---|
|Current|`74fbe89ad5aadfaaf0d9644f20bbd6b883935274`|
|変更直前baseline|`3a18d6c`|

両revisionを別worktreeでそれぞれ`zig build -Dexample=bench -Doptimize=ReleaseFast`によりbuildしました。currentとbaselineのapplication source、route、SQLite workload、server optionは同一です。

## 測定環境

- Apple M2、8 core（Performance 4 + Efficiency 4）、16 GB
- macOS 26.5、Darwin 25.5.0、arm64
- Zig 0.16.0
- wrk 4.2.0_2
- loopback `127.0.0.1`、HTTP/1.1
- serverとload generatorは同一host
- observability middlewareなし

過去資料はM2 Pro 10 core上の結果なので、絶対値を直接regression判定へ使用していません。

## 主要A/B結果

`threads=4 connections=16 duration=5s`を各scenario 3回実行した中央値です。この条件は256 connection測定よりSQLite varianceが小さく、framework hot pathの比較に適しています。

|Scenario|Current req/s|Baseline req/s|差|Current P50|Baseline P50|Current P99|Baseline P99|
|---|---:|---:|---:|---:|---:|---:|---:|
|`GET /hello`|171,639|171,404|**+0.14%**|74 µs|74 µs|310 µs|380 µs|
|`POST /echo`|169,851|169,728|**+0.07%**|75 µs|74 µs|543 µs|378 µs|
|`GET /db/:id`|86,028|87,234|**-1.38%**|148 µs|146 µs|1.02 ms|0.99 ms|

throughputの3回range:

|Scenario|Current range|Baseline range|
|---|---:|---:|
|hello|170,547–171,857|160,037–171,624 req/s|
|echo|169,590–169,861|169,557–170,495 req/s|
|db|85,409–87,562|85,771–87,524 req/s|

P99は5秒測定では一度のscheduler stallに敏感です。echoのP99中央値は増えていますが、throughput、P50、個別rangeが安定しており、持続的なhot-path回帰を示すものではありません。

## 高並行度測定

既存benchmarkと同じ`threads=8 connections=256 duration=10s`を3回実行しました。

|Scenario|Current中央値|Baseline中央値|Current range|Baseline range|
|---|---:|---:|---:|---:|
|hello|178,863|177,347|178,715–179,610|176,383–179,053|
|echo|177,665|176,262|177,538–177,883|175,594–178,301|
|db|35,340|47,205|34,195–50,919|38,571–49,871|

hello／echoはcurrentが約0.8%高い一方、dbは双方ともvarianceが非常に大きく、この条件だけでは判定不能です。256 connectionが同時に単一in-memory SQLite databaseへアクセスするため、SQLite mutex競合とmacOS schedulingの影響が支配的です。

さらにcurrent／baselineの両方で、約100 successful requestごとにwrkのread errorが1件発生しました。これは`max_requests_per_connection = 100`によりserverが意図的にconnectionをrecycleする一方、wrkが同じkeep-alive connectionを再利用するためです。HTTP 5xxではありませんが、reconnectがP99へ混入するため、過去資料の数十µs P99とは同一条件ではありません。

## Resource比較

`resources.sh`による1 Hz単発samplingです。

|Metric|Current|Baseline|差|
|---|---:|---:|---:|
|ReleaseFast binary|1,850,632 B|1,850,312 B|+320 B（+0.017%）|
|Idle RSS|3,056 KB|3,056 KB|0%|
|hello RSS average|20,859 KB|21,332 KB|-2.2%|
|echo RSS average|24,426 KB|23,944 KB|+2.0%|
|db RSS average|23,062 KB|22,105 KB|+4.3%|
|Peak threads|252–253|252–253|同等|
|Peak FD|251–252|252|同等|

負荷時RSSはconnection worker stackとmacOS resident-page accountingに影響されます。差が一方向でなく、idle値、thread数、FD数が一致しているため、今回の変更によるresource leakとは判断しません。

## 過去benchmarkとの関係

過去のM2 Pro記録はthreaded版でhello 189k、echo 192k、db 99.9k req/sでした。今回のM2はPerformance coreが4、総coreが8で、過去環境の10 core M2 Proより小さいため、絶対throughputが低いこと自体は回帰の証拠になりません。

同一hardware A/Bでは、今回追加したlifecycle field、route metadata、budget branchは、metadataを持たないbare benchmark routeのhot pathへ測定可能なoverheadを追加していません。

## Benchmark infrastructure上の課題

今後の測定精度向上には以下が必要です。

1. benchmark serverでは`max_requests_per_connection`を十分大きくし、connection recycle benchmarkを別scenarioへ分離する。
2. raw wrk outputをcommit hash付きartifactとして保存する。
3. scenario順をrandomizeまたはA/B交互実行し、thermal driftを抑える。
4. SQLite benchmarkは256 connectionだけでなく16 connection中央値も必須とする。
5. P99 regression判定には5秒ではなく最低30秒、可能なら複数process runを使用する。
6. CPU%はprocess lifetime平均ではなくinterval samplingまたはenergy counterを使う。

## 再現command

```console
zig build -Dexample=bench -Doptimize=ReleaseFast
./zig-out/bin/bench

CONN=16 THREADS=4 DURATION=5s examples/bench/run.sh current 8080 hello
CONN=16 THREADS=4 DURATION=5s examples/bench/run.sh current 8080 echo
CONN=16 THREADS=4 DURATION=5s examples/bench/run.sh current 8080 db
```

集計済みmachine-readable dataは[`benchmark-results/20260817-dx-regression.json`](../../benchmark-results/20260817-dx-regression.json)に保存しています。
