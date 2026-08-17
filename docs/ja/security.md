# Security

Akamataは、解釈が曖昧なHTTP/1 framingをframework boundaryで拒否します。HTTP/1.1 requestには、正しい`Host` headerが1つだけ必要です。header colon前のwhitespace、obs-fold、重複した`Host`／`Content-Length`、CL/TEの併用、未対応のtransfer coding、不正なchunk、上限を超えるinputは拒否します。

## Native serverの制限

threaded native runtimeではaccept処理と、上限付きのconnection workerを分離しています。defaultはheader 10秒、body 30秒、keep-alive idle 5秒、request全体60秒、1 connectionあたり100 requests、同時1,024 connections、header 64 KiB、body 4 MiBです。`ServeOptions`で変更できます。Internetへ公開する場合は継続的に保守されているTLS reverse proxyを前段に置いてください。ただし、不正なframingをproxyが修正することには依存しないでください。

`ServeOptions.trust_proxy_headers`のdefaultは`false`で、`c.req.ip()`は
`X-Forwarded-For`、`CF-Connecting-IP`、`X-Real-IP`を無視します。threaded native
serverはsocket peerを返し、peer metadataがないtargetでは`null`になり得ます。有効化には
direct peerを認可する`trusted_proxy_fn`も必要です。Internet公開native serverで全peerを
許可しないでください。
Akamataのrate limiterはprocess／isolate内だけで動作します。複数nodeではshared limiterが必要です。

`secureHeaders`はhandlerより前に適用されるため、streaming responseにもsecurity policyが付きます。HSTSのdefaultはHTTPS本番環境向けです。平文HTTPの開発hostでは、browserへ利用できないHTTPS policyを記憶させないよう`strict_transport_security`を無効にしてください。

## 認証とcookie

`am.mw.jwt`はHS256だけを受け付け、defaultで`exp`を必須とし、`exp`と`nbf`を検証します。32 bytes以上のentropyを持つrandom secretを使用してください。`now_fn`は再現可能なtest用です。`leeway_seconds`は必要最小限にします。
URLはlogやhistoryへ残るためquery tokenはdefaultで無効です。Authorization headerを使えない
限定的なWebSocket handshakeでだけ`allow_query_token=true`を指定してください。

Sessionには32 bytes以上のstable secretが必要です。署名cookieには有効期限が含まれ、persistent Storeを使用してもrequest時に検証されます。Session／CSRF cookieはdefaultで`Secure`です。平文HTTPのlocal開発でだけ明示的に無効化してください。Session cookieには`HttpOnly`と`SameSite=Lax`も付きます。login時と権限変更時は`session.rotate(c)`でSIDを更新してください。

cookie認証を使うstate-changing routeにはCSRF middlewareを適用します。CORSはCSRF対策の代わりにはなりません。Akamataは`origin="*"`と`credentials=true`の組み合わせを拒否します。信頼するoriginをexactに指定し、request Originを無条件に反射しないでください。

## WebSocketとupload

WebSocket handshakeではversion 13と正しい16-byte nonceが必要です。Client frameにはmaskが必須です。reserved bit／opcode、不正または大きすぎるcontrol frame、不正なfragmentation／close payload／UTF-8 text、設定上限を超えるmessageを拒否します。`UpgradeOptions`はdefaultで60秒のread timeoutを持ち、exact matchの`allowed_origins` allowlistを設定できます。

multipartとURL-encoded parserにはbody、part／field、header、boundary、個数の上限があります。uploadされたfilenameは表示用metadataとして扱い、filesystem pathとして直接使用しないでください。

## Migration note

- JWT middlewareは期限切れtokenと`exp`のないtokenをdefaultで拒否します。移行目的で必要な場合だけ`require_exp=false`を指定してください。
- Session／CSRF cookieのdefaultが`Secure`になりました。local HTTPでは明示的に無効化します。
- Session cookie formatに期限を追加したため、従来の2要素cookieは無効になります。
- 重複Content-Lengthなど、以前は許容していた曖昧なHTTP syntaxを拒否します。

脆弱性の報告方法はrepositoryの[security policy](../../SECURITY.md)を参照してください。
