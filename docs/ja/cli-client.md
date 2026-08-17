# CLI API client

Akamata CLIには、requestごとにcurl optionへ変換せずapplicationを試せるHTTP clientがあります。Akamata自身のnative HTTP／TLS stackを使用するため、applicationから利用できるprotocol実装と同じ経路をCLIでも検証できます。

## Full-screen TUI

request argumentなしでclientを実行します。

```console
akamata client
# 明示する場合
akamata client --tui --base-url=http://127.0.0.1:8080
```

TUIは検出したendpoint一覧、編集可能なrequest、整形済みresponseを一画面に表示します。

- `j`／`k`: endpoint選択
- `Enter`: 実行。宣言済み`{path}` parameterは入力promptを表示してencode
- `m`: HTTP method切り替え
- `e`: pathまたはabsolute URL編集
- `h`: request header編集
- `b`: JSON／raw body編集
- `u`: base URL変更
- `r`: endpoint metadata再取得
- `?`: help、`q`: 終了

endpoint検出では最初に`zig build run -- akamata-openapi`を実行します。現在のAkamata scaffoldはroute登録後にこのlocal inspection protocolへ応答し、serverを起動せず終了します。そのため、web APIに`/openapi.json`等を追加しなくても、登録された全routeをTUIから参照できます。旧applicationでは`/openapi.json`取得へfallbackし、どちらも利用できない場合はmanual requestで開始します。

runnerを起動するのは、現在のprojectの`src/main.zig`にinspection markerが明示されている場合だけです。そのためAkamata framework repository自体からTUIを実行しても、example serverを誤って起動せずmanual modeで開始します。

request実行時にはapplication serverが起動している必要があります。inspectionとservingを分離することで、public API surfaceを変更しません。

## 直接request

```console
akamata client /health
akamata client GET /notes --query=page=2 --query=q=zig
akamata client POST /notes --json='{"title":"from CLI","body":"hello"}'
```

最短形式ではGETと`http://127.0.0.1:8080`が既定値です。`--json=@request.json`または`--data=@payload.txt`でbodyをfileから読み込めます。JSONはnetwork request前にparseされ、明示指定がなければ`content-type: application/json`を追加します。

```console
akamata client GET /me --base-url=https://api.example.com \
  --bearer="$TOKEN" --header=x-request-source:terminal
```

GET、HEAD、POST、PUT、DELETE、PATCH、OPTIONSに対応します。pathの代わりにabsolute URLも指定できます。

## Contract駆動の呼び出し

applicationが生成OpenAPI documentを公開している場合、`operationId`で呼び出せます。

```console
akamata api call getNote --param=id=42
akamata api call createNote --json=@note.json
akamata api call getNote --spec=/internal/openapi.json --param=id=42
```

CLIは`/openapi.json`を取得し、operationのmethod／pathを解決します。`--param`値はpercent encodeし、未解決path parameterがあれば拒否します。OpenAPI endpointはapplication側で登録する必要があり、暗黙には公開されません。

## 出力とautomation

JSON responseは既定でpretty printします。`--raw`はbodyを変更せず出力し、`--include`はstatus／headerも表示します。script／CIでは`--fail`を指定すると4xx／5xxでnon-zeroになります。transport error、不正input、size超過、未知operation、path parameter不足は常に失敗します。

response上限は既定4 MiBで、`--max-bytes=N`により最大64 MiBまで変更できます。

## Security

- header、Bearer token、URLのCR／LF injectionを拒否します。
- query／path parameter値をpercent encodeします。
- HTTPSではAkamataのcertificate／hostname検証を使用します。
- response allocationには上限があります。
- command line上のsecretはshell historyやprocess listに見える場合があります。短命なenvironment variableを推奨します。

全optionは`akamata help client`で確認できます。`-H=name:value`は`--header=name:value`のaliasです。
