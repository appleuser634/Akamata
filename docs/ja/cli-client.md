# CLI API client

Akamata CLIには、requestごとにcurl optionへ変換せずapplicationを試せるHTTP clientがあります。Akamata自身のnative HTTP／TLS stackを使用するため、applicationから利用できるprotocol実装と同じ経路をCLIでも検証できます。

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
