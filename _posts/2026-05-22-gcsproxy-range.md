---
title: gcsproxy で Range リクエストに対応した話
---

自分の趣味で開発している [gcsproxy](https://github.com/daichirata/gcsproxy) という小さなツールがある。Google Cloud Storage の private なバケットの前段に置いてリバースプロキシとして動かす事で、アクセス制限を別レイヤーに押し付けたり、IAP の後ろで静的サイトを配信したりするためのもの。

このプロジェクトに対して [Range リクエストに対応してほしいという Issue](https://github.com/daichirata/gcsproxy/issues/40) がだいぶ前から来ていて、大きなオブジェクトを動画として配信する時のシークや、レジュームダウンロード、CDN からのオリジン読み出しなどでよく使われる機能なので対応してみる事にした。

実は同じ機能を実現する [Pull Request #29](https://github.com/daichirata/gcsproxy/pull/29) も既にあって、こちらは Go の stdlib にある `http.ServeContent` の内部実装をほぼそのまま gcsproxy 内に持ち込むスタイル。仕組み的にはこれでも動くのだけど 500 行を超える追加になっていて、stdlib の実装の更新を追従しなければいけないことも含めると個人的にはちょっとアプローチが合わないなという感じがあり、一旦 Range について真面目に調べ直して gcsproxy のユースケースに見合った実装を入れる事にした。

## Range と RFC

HTTP の `Range` ヘッダの仕様は元々 RFC 7233 で定義されていて、現在は HTTP/1.1 の改訂版である [RFC 9110](https://httpwg.org/specs/rfc9110.html) に統合されている。

リクエスト側のフォーマットは

```
Range: bytes=N-M
Range: bytes=N-
Range: bytes=-N
Range: bytes=0-99,200-299    ← マルチレンジ
```

の四種類があって、サーバーが range をサポートする場合は

- 範囲が満たせる場合: `206 Partial Content` + `Content-Range: bytes N-M/<total>` で要求された部分を返す
- 範囲が満たせない場合: `416 Range Not Satisfiable` + `Content-Range: bytes */<total>` を返す
- マルチレンジを満たす場合: `multipart/byteranges` の MIME メッセージとして複数の範囲をまとめて返す

という挙動になる。一方でサーバーが range をサポートしている事を広告するための `Accept-Ranges: bytes` ヘッダや、クライアントがキャッシュ整合性のために送る `If-Range` ヘッダなど周辺の機能もそれなりにある。

個人的に面白いと思う点として、「Range は MUST じゃない」事がある。つまり Range ヘッダを送って 416 を期待していたところで、サーバーが無視して 200 でフルボディを返しても仕様違反にはならない。`Range: items=0-10` のような非 `bytes` 単位の指定については RFC 9110 §14.2 に明確に "MUST ignore" と書かれていて、未知の単位を 416 にしてしまうのはむしろ仕様違反になる。

> An origin server MUST ignore a Range header field that contains a range unit it does not understand.

`Range: bytes=abc-def` や `Range: bytes=500-100` のような Range の構文がそもそも壊れているケースについては、RFC 上は厳密に書かれていない印象。Go の `http.ServeContent` のように一律 416 にしているサーバもあれば、エラー時は ignore して 200 で返すサーバもある。リバースプロキシとしては「不正なヘッダで動いていたダウンロードを壊さない」方が運用上嬉しい場面が多いので、gcsproxy では後述するように後者寄せにした。

## Range と Content-Encoding

GCS 特有の話として、GCS にオブジェクトを `Content-Encoding: gzip` 付きでアップロードした場合、ダウンロード時に GCS 側で「解凍済みのバイトを返す」というトランスコーディングがデフォルトで行われる、というのがある。便利な機能ではあるのだけど Range と組み合わせた時の挙動が直感的でなくて、実機で確認したところ次のようになった。

```
=== gzip object (Content-Encoding: gzip, 圧縮済サイズ 40 byte) ===
NewRangeReader(0,10): len=20  body="0123456789abcdefghij"  ← 解凍済みの全 20 byte が返ってくる
```

Range で 10 byte を要求したにも関わらず **解凍済みの全 20 byte が返ってくる**。なので gcsproxy としては gzip-stored なオブジェクトに対する Range リクエストは、`NewRangeReader` の戻り値を信頼してそのまま返してしまうと「206 を返しているのに body が要求バイト数を超える」という壊れたレスポンスになってしまう。

対応案としては

- そもそも gzip-stored なオブジェクトに対する Range は 416 で返す
- Range を無視して 200 でフルボディを返す

の二択になるが、リバースプロキシとしては機能的なものは出来るだけ提供したいので 200 フルボディを返す方を選択した。あと一応 `Accept-Ranges: bytes` の広告もしないようにして、行儀の良いクライアントが Range を投げない様にしている。

## gcsproxy ではどう実装したか

Range の細かな仕様や GCS 特有の挙動を踏まえて、結果的に gcsproxy の Range 対応は次のような形に落ち着いた。

| シナリオ | 挙動 |
|---|---|
| `bytes=N-M` / `bytes=N-` / `bytes=-N` で範囲内 | `206 Partial Content` + `Content-Range` + 要求バイトのみ |
| マルチレンジ `bytes=0-99,200-299` | 最初の range のみを `206` で返す (`multipart/byteranges` は非対応) |
| 範囲外 / `last < first` (`bytes=500-100`) | `416 Range Not Satisfiable` + `Content-Range: bytes */<size>` |
| 非 `bytes` 単位 (`items=0-10`) | `200` でフルボディ (RFC 9110 §14.2 に従って ignore) |
| パース不能 (`bytes=abc-def`) | `200` でフルボディ (MUST ignore を拡張) |
| `Content-Encoding: gzip` なオブジェクト | `200` でフルボディ (GCS の transcoding で Range が意味をなさない) |
| `If-Range` | 第一版では未対応 |

`multipart/byteranges` 非対応や `If-Range` 非対応のような割り切りで実装をかなり小さく保てたのと、GCS の `NewRangeReader(ctx, offset, length)` という API が「offset と length を取って Range request を GCS にそのまま投げる」というそのものズバリな仕様だったお陰で、stdlib の `http.ServeContent` から実装を持ってくる必要が無く、結果的に追加コードは 100 行強 + テストで 300 行強位に収まった。

stdlib の `http.ServeContent` がそれなりに大きいのは、`io.ReadSeeker` を入力として汎用的に動くように作られていて、ファイルサイズの取得や Seek 中のエラーハンドリング、`multipart/byteranges` のメッセージ生成、conditional request (`If-Match` や `If-None-Match`) の全セット対応など、汎用 HTTP file server として必要な物が全部入っているからで、gcsproxy のように既に GCS の object メタデータが手元にある状態で range API を呼ぶだけの薄いプロキシとしては必要のない物が大半だった、という構造的な違いがある。

## おわり

ということで、gcsproxy で Range リクエストに対応しつつ、現実的なエッジケース (特に GCS の gzip transcoding) を踏まえた挙動に落ち着く事が出来た。Range は単純に見える機能の割に Content-Encoding 周りの相互作用が思いの外複雑で、stdlib のソースを読んだり実機で GCS の挙動を確認したりと意外と勉強になった。

仕様としては未対応の `If-Range` (リクエストヘッダのバージョンが一致したら range、違ったら full body を返す機能) や、`multipart/byteranges` のサポートをどうするかは需要次第というところもあるので、第一版としてはこんなもんかなという感じ。
