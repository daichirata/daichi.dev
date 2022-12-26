---
title: 本番導入出来なかったけどGoでちょっと早いfluent-loggerを作った時の話
---

この記事は[Go4 Advent Calendar 2017](https://qiita.com/advent-calendar/2017/go4)の12/15のエントリです。

[Go2 Advent Calendar 2017](https://qiita.com/advent-calendar/2017/go2)の１日目の記事で、[go-fluent-clientの紹介](https://medium.com/@lestrrat/go-fluent-client%E3%81%AE%E7%B4%B9%E4%BB%8B-312e90fb0668) という lestrrat さんの投稿があり、そういえば今年の初めに転職やら色々あって導入までは出来なかった Go の fluent-logger 作ったなということを思い出したので、当時どんな感じで作っていたかを踏まえて簡単に紹介してみようと思います。

[daichirata/fluent-logger-go](https://github.com/daichirata/fluent-logger-go)

元のコードに関しては導入しないと決めた時にとりあえずファイルだけ Github に上げてるだけの状態だったので一旦別ブランチに退避して、今回は当時を再現しつつ１からコミットし直してみたいと思います。

そもそもなんでわざわざ作ったかというと、最近は Go をそもそもあまり触っていないので当時と同じ状況なのかどうかはわかりませんが、その時のモチベーションとして

* fluentdに対して非同期にメッセージを送信したい (ここの送信でレスポンスに影響を出したくない)
* 送信できなかったメッセージは、そのイベントをキャッチしてファイルや別経路の出力に退避させたい
* embedされた構造体を、そのまま logger に渡しても上手くエンコードして送信して欲しい
  * ちょっとここは記憶が曖昧ですが、確か何らかの制限があって Post するときには自分で map にして渡すのが一番安全という感じだったような気がします

という所があって、オフィシャルで対応するのは大改造が必要っぽくてちょっと厳しそう + logger だけなら作るのそんなに大変じゃなそうだったので作ったとかだったような。

最終的には結構いい感じの速さになったんですが、不真面目なのでわりと感で最適化するアンチパターンで作っているので最適化の余地はかなりありそう。そもそも実戦投入出来ていないので導入もオススメ出来ません。

というわけでそれでは後発らしく、より速く、よりちょっと便利を目指してやって行きましょう。

## Initial Commit

[884b834e213fc999a3484feeba77fbeb68d2a942](https://github.com/daichirata/fluent-logger-go/commit/884b834e213fc999a3484feeba77fbeb68d2a942#diff-40646a6e1108f49d452915ba3515c206)

最初のコミットに関しては、とりあえず動くことを目標に作ったので基本的に全ての機能が `logger.go` に同期処理で書かれてます。


``` go
type Logger struct {
 	conf Config
	conn io.WriteCloser
	bmu	 sync.Mutex // buffer mutex
	cmu	 sync.Mutex // connection mutex
	buf	 []byte
}
```

``` go
func (logger *Logger) PostWithTime(tag string, t time.Time, obj interface{}) error {
	record := []interface{}{
		tag,
		t.Unix(),
		obj,
	}

	buf := bytes.NewBuffer([]byte{})
	enc := msgpack.NewEncoder(buf)
	if err := enc.Encode(record); err != nil {
		return err
	}
	raw := buf.Bytes()

	logger.bmu.Lock()
	logger.buf = append(logger.buf, raw...)
	logger.bmu.Unlock()

	return logger.send()
}
```

`PostWithTime` でエンコードした後に `logger.buf` にデータを詰めて後は `send()` で送信してる感じで、一旦 buf に詰めてるのは送信に失敗した時にそのまま pending として扱う為です。
Mutex を２つ持っているところとかが中々にダサいですが、最初としてはまあこんな所でしょう。この状態で一旦公式とベンチマークを取ってみます。(ちなみに、benchmarkは[このファイル](https://github.com/daichirata/fluent-logger-go/commit/884b834e213fc999a3484feeba77fbeb68d2a942#diff-65a092dcffc14579e220e826bc337b8d)を最初からコミットしているので、今後は常にこちらを実行しています。)

```
cd benchmark && go test -bench . -benchmem
enable dummay daemon
goos: darwin
goarch: amd64
pkg: github.com/daichirata/fluent-logger-go/benchmark
BenchmarkStructDaichirata-4   	  100000	     14693 ns/op	    1958 B/op	      14 allocs/op
BenchmarkStructOfficial-4     	  100000	     18444 ns/op	    4891 B/op	      35 allocs/op
BenchmarkMapDaichirata-4      	  100000	     15340 ns/op	    1671 B/op	      13 allocs/op
BenchmarkMapOfficial-4        	  100000	     19802 ns/op	    5971 B/op	      62 allocs/op
PASS
ok  	github.com/daichirata/fluent-logger-go/benchmark	7.535s
```

意外な事に現段階で既にオフィシャルより早いですが、そもそも機能が少ないという所もあるのでこの値より遅くならない事を目標にやって行きましょう。


## 送信を非同期に

[38301f437e598c84b097a7a4487d6fe927f56403](https://github.com/daichirata/fluent-logger-go/commit/38301f437e598c84b097a7a4487d6fe927f56403)


先ずは、最初の目標として送信部分の非同期対応を行います。対応内容としては

* fluentdへの接続を確立出来た後、送信用の goroutine を１つ立ち上げる
* buffer に対する dirty channel を用意し、`Post` 実行時に send を呼び出す代わりに dirty に非同期で通知する
* 送信用 goroutine は、 dirty channel か ticker を契機に送信処理を実行する
  * dirty -> 新規書き込み
  * ticker -> 送信失敗時の pending データの送信

という感じです。正直まだまだ現段階では問題が沢山有ります。(この実装だとdirtyへの通知多いよねとか) が、これからコードをどんどん変えていくことになるのでどんどん先に行っちゃいましょう。

```
cd benchmark && go test -bench . -benchmem
enable dummay daemon
goos: darwin
goarch: amd64
pkg: github.com/daichirata/fluent-logger-go/benchmark
BenchmarkStructDaichirata-4   	  200000	     10172 ns/op	    1389 B/op	      14 allocs/op
BenchmarkStructOfficial-4     	  100000	     20515 ns/op	    4839 B/op	      35 allocs/op
BenchmarkMapDaichirata-4      	  200000	     11976 ns/op	    1107 B/op	      13 allocs/op
BenchmarkMapOfficial-4        	   50000	     23154 ns/op	    5929 B/op	      62 allocs/op
PASS
ok  	github.com/daichirata/fluent-logger-go/benchmark	8.343s
```

ナイーブな非同期対応でも、正常系だけ見ればそれなりに効果は出るっぽいですね。

## Buffer を別の構造体として管理

[e0f40b163ac68657d734463a30a601190d64a498](https://github.com/daichirata/fluent-logger-go/commit/e0f40b163ac68657d734463a30a601190d64a498)

この先作り込んでいく前に、早めの段階で logger の buffer を外に切り出してます。これで書込みの時と送信の時に logger 側から直接 Mutex を操作する必要がなくなったので、少し見通しが良くなったでしょうか。

```
cd benchmark && go test -bench . -benchmem
enable dummay daemon
goos: darwin
goarch: amd64
pkg: github.com/daichirata/fluent-logger-go/benchmark
BenchmarkStructDaichirata-4   	  200000	      7210 ns/op	    1601 B/op	      14 allocs/op
BenchmarkStructOfficial-4     	  100000	     18486 ns/op	    4896 B/op	      35 allocs/op
BenchmarkMapDaichirata-4      	  200000	      7657 ns/op	    1194 B/op	      13 allocs/op
BenchmarkMapOfficial-4        	  100000	     20273 ns/op	    5967 B/op	      62 allocs/op
PASS
ok  	github.com/daichirata/fluent-logger-go/benchmark	7.419s
```

パフォーマンス向上への影響も大きですね。 buffer を切り出すことでロックの粒度が細かくなったお陰で `send` のスループットが上がったからでしょうか。

## エンコード用の byte slice を Pool で管理

[d0cdf96d8d53cee100097ee77d07bd4519452f10](https://github.com/daichirata/fluent-logger-go/commit/d0cdf96d8d53cee100097ee77d07bd4519452f10)

基本的に logger などのように文字列など場合によっては大きなデータを扱いつつ、返り値としてはエラーなどしか返さないようなライブラリの場合は大抵 `sync.Pool` による最適化が可能です(ベストでは無いかもしれませんが)。 今回のケースで言うと `Post` で受け取った構造体を MessagePack にエンコードする際の byte slice は送信後その領域自体を使いますことが可能です。なので buffer に `Add` する際のデータを `[]byte` から `Message` 構造体に変え、その構造体を使いまわすように変更してみます。

```
cd benchmark && go test -bench . -benchmem
enable dummay daemon
goos: darwin
goarch: amd64
pkg: github.com/daichirata/fluent-logger-go/benchmark
BenchmarkStructDaichirata-4   	  200000	      6122 ns/op	    1311 B/op	       8 allocs/op
BenchmarkStructOfficial-4     	  100000	     18993 ns/op	    4889 B/op	      35 allocs/op
BenchmarkMapDaichirata-4      	  200000	      6570 ns/op	     988 B/op	       7 allocs/op
BenchmarkMapOfficial-4        	  100000	     20283 ns/op	    5974 B/op	      62 allocs/op
PASS
ok  	github.com/daichirata/fluent-logger-go/benchmark	7.036s
```

狙い通り、 allocation をかなり抑えることが出来てるっぽいですね。

ついでに、 MessagePack のデコーダー自体も byte slice と対になるようにして使いまわすようにしてみました。

[2620523219a24ad483ee54883cf1f60d86e6ef0e](https://github.com/daichirata/fluent-logger-go/commit/2620523219a24ad483ee54883cf1f60d86e6ef0e)

```
cd benchmark && go test -bench . -benchmem
enable dummay daemon
goos: darwin
goarch: amd64
pkg: github.com/daichirata/fluent-logger-go/benchmark
BenchmarkStructDaichirata-4   	  200000	      5872 ns/op	    1257 B/op	       6 allocs/op
BenchmarkStructOfficial-4     	  100000	     18894 ns/op	    4890 B/op	      35 allocs/op
BenchmarkMapDaichirata-4      	  200000	      6557 ns/op	     908 B/op	       5 allocs/op
BenchmarkMapOfficial-4        	  100000	     20657 ns/op	    5969 B/op	      62 allocs/op
PASS
ok  	github.com/daichirata/fluent-logger-go/benchmark	6.993s
```

更に抑えられてていい感じですね。

## buffer の dirty 通知を抑える

[b81248d643ed44e2b7619bf47be88e285c33e05b](https://github.com/daichirata/fluent-logger-go/commit/b81248d643ed44e2b7619bf47be88e285c33e05b)

最初の方で話していたとおり、今の実装だと dirty への書き込みが多すぎて、無駄に goroutine を抱えることになります。(と言うか `send` が止まると無限に増える) buffer への読み書きは常にロックを取ったシーケンシャルな処理なので、そこで対処できそうです。

* buffer の領域を新規書き込みと、再送中のデータに分離
* 新規書き込み時、新規書き込みの領域にデータが溜まっていない(そのデータのみ)場合のみ、dirty 通知を行う
  * データが既にある場合、通知済みで pop されるのを待っている状態なので不要です

という感じで対応してみました。

```
cd benchmark && go test -bench . -benchmem
enable dummay daemon
goos: darwin
goarch: amd64
pkg: github.com/daichirata/fluent-logger-go/benchmark
BenchmarkStructDaichirata-4   	  200000	      5759 ns/op	    1516 B/op	       8 allocs/op
BenchmarkStructOfficial-4     	  100000	     18354 ns/op	    4897 B/op	      35 allocs/op
BenchmarkMapDaichirata-4      	  200000	      5508 ns/op	    1220 B/op	       7 allocs/op
BenchmarkMapOfficial-4        	  100000	     20165 ns/op	    5960 B/op	      62 allocs/op
PASS
ok  	github.com/daichirata/fluent-logger-go/benchmark	6.666s
```

領域が増えたことで allocation とメモリの消費量が増えてしまっていますが、対応しなければ行けない所なので諦めましょう。ちょっとだけ性能が改善しているのは誤差か或いは goroutine の起動が抑えられているからかもしれません。

## 再送系の処理を CircuitBreaker で改善

ネットワークの再送といえばAWSでよく使われるので Exponential Backoff の概念が最近だとよく見かけます。

``` ruby
MAX_RETRIES = 10
retries = 0
begin
    // 何かの処理
rescue => e
  if retries < MAX_RETRIES
    retries += 1
    sleep 2 ** i
    retry
  else
    raise
  end
end
```

今回は更に、書き込みでエラーが起きた際には別の出力に切り替えるみたいな処理を間に挟みたいと思っているので、上記リトライに近いことが出来て更にブロックせずに扱いやすい CircuitBreaker を導入します。

[3112bd1ec8a12ed164560fa34bd5598b0caabcf1](https://github.com/daichirata/fluent-logger-go/commit/3112bd1ec8a12ed164560fa34bd5598b0caabcf1)

先ずはバッファ周りの処理と書き込み処理を分離。

[cd0e0b7e95988cd7416b9386cfa74c22c7f64c36](https://github.com/daichirata/fluent-logger-go/commit/cd0e0b7e95988cd7416b9386cfa74c22c7f64c36)

次に CircuitBreaker を導入します。

``` go
func (logger *Logger) Subscribe() <-chan circuit.BreakerEvent {
```

で channel でイベントを受け取れるようにしているので、 fluent の書き込みに失敗した時にログを吐いて監視システムで拾うとかすると便利かもしれません。

```
cd benchmark && go test -bench . -benchmem
enable dummay daemon
goos: darwin
goarch: amd64
pkg: github.com/daichirata/fluent-logger-go/benchmark
BenchmarkStructDaichirata-4   	  200000	      5970 ns/op	    1447 B/op	       8 allocs/op
BenchmarkStructOfficial-4     	  100000	     19022 ns/op	    4856 B/op	      35 allocs/op
BenchmarkMapDaichirata-4      	  200000	      6034 ns/op	    1091 B/op	       6 allocs/op
BenchmarkMapOfficial-4        	  100000	     21286 ns/op	    5938 B/op	      62 allocs/op
PASS
ok  	github.com/daichirata/fluent-logger-go/benchmark	7.005s
```

パフォーマンス的にも特に問題なさそうですね。

## ErrorHandler の概念を追加

[af41bfd784ca84efef94a7b09d024953367c6657](https://github.com/daichirata/fluent-logger-go/commit/af41bfd784ca84efef94a7b09d024953367c6657)

最後に、一番やりたかったエラーが起きたときにハンドルする為のAPIを追加していきます。Go には `http.HandlerFunc` という関数型に対して関数を定義するという中々カッコイイ機能があるので、それを参考にします。

``` go
type Logger struct {
	ErrorHandler ErrorHandler

// ......

if logger.ErrorHandler != nil && len(messages) > logger.conf.PendingLimit {
	err = logger.ErrorHandler.HandleError(err, data)
}

// ......

type ErrorHandler interface {
	HandleError(error, []byte) error
}

type ErrorHandlerFunc func(error, []byte) error

func (f ErrorHandlerFunc) HandleError(err error, data []byte) error {
	return f(err, data)
}
```

このように定義しており、無名関数を `ErrorHandlerFunc` にキャストするか或いは `HandleError` を実装した構造体で、エラーが発生した場合に処理を受けれるようになっています。

具体的な使用例を幾つか追加していて、例えば書き込みに失敗した場合、もう一つの logger にフォールバックしたり、データをJSONとして指定した io.Writer に流すとかを出来るようにしています。

[error_handler.go](https://github.com/daichirata/fluent-logger-go/commit/af41bfd784ca84efef94a7b09d024953367c6657#diff-6380769465fc46693ec2f678e1e26be3)

``` go
logger, err := fluent.NewLogger(fluent.Config{})
if err != nil {
	// TODO: Handle error.
}

// Logging error.
logger.ErrorHandler = fluent.ErrorHandlerFunc(func(err error, _ []byte) error {
	log.Println(err)
	return err
})

// Fallback logger.
fallback, err := fluent.NewLogger(fluent.Config{})
if err != nil {
	// TODO: Handle error.
}
logger.ErrorHandler = fluent.NewFallbackHandler(fallback)

// Fallback json to stdout.
logger.ErrorHandler = fluent.NewFallbackJSONHandler(os.Stdout)
```

この機能の特徴として、`HandleError` と送信のエラー判定を結合させています。つまり、この関数がエラーを返さなかった場合はメッセージは pending にならずに成功したものとして扱います。逆にいうとエラーを返した場合は同じメッセージが何回も流れて来ます。フォールバックさせる場合には再送周りをコントロールする必要があるので、この方が何かと都合が良かったりするので一旦この形で落ち着いています。

## パフォーマンス

というわけで、色々やってきましたが最終的なベンチマークはこんな感じになりました。

```
cd benchmark && go test -bench . -benchmem
enable dummay daemon
goos: darwin
goarch: amd64
pkg: github.com/daichirata/fluent-logger-go/benchmark
BenchmarkStructDaichirata-4   	  200000	      6027 ns/op	    1474 B/op	       8 allocs/op
BenchmarkStructOfficial-4     	  100000	     18551 ns/op	    4889 B/op	      35 allocs/op
BenchmarkMapDaichirata-4      	  200000	      7070 ns/op	     929 B/op	       6 allocs/op
BenchmarkMapOfficial-4        	  100000	     21664 ns/op	    5930 B/op	      62 allocs/op
PASS
ok  	github.com/daichirata/fluent-logger-go/benchmark	7.227s
```

結構誤差が出るので参考程度ですが、そこそこ良い結果にはなっているのではないでしょうか。ついでに lestrrat さんの奴のもやってみました。

``` go
// +build bench

package fluent_test

import (
	"testing"

	daichirata "github.com/daichirata/fluent-logger-go"
	official "github.com/fluent/fluent-logger-golang/fluent"
	k0kubun "github.com/k0kubun/fluent-logger-go"
	lestrrat "github.com/lestrrat/go-fluent-client"
)

const tag = "debug.test"
const postsPerIter = 1

func BenchmarkK0kubun(b *testing.B) {
	c := k0kubun.NewLogger(k0kubun.Config{})
	for i := 0; i < b.N; i++ {
		for j := 0; j < postsPerIter; j++ {
			c.Post(tag, map[string]interface{}{"count": j})
		}
	}
}

func BenchmarkDaichirata(b *testing.B) {
	c, _ := daichirata.NewLogger(daichirata.Config{})
	for i := 0; i < b.N; i++ {
		for j := 0; j < postsPerIter; j++ {
			c.Post(tag, map[string]interface{}{"count": j})
		}
	}
	c.Close()
}

func BenchmarkLestrrat(b *testing.B) {
	c, _ := lestrrat.New()
	for i := 0; i < b.N; i++ {
		for j := 0; j < postsPerIter; j++ {
			if c.Post(tag, map[string]interface{}{"count": j}) != nil {
				b.Logf("whoa Post failed")
			}
		}
	}
	c.Shutdown(nil)
}

func BenchmarkLestrratUnbuffered(b *testing.B) {
	c, _ := lestrrat.New(lestrrat.WithBuffered(false))
	for i := 0; i < b.N; i++ {
		for j := 0; j < postsPerIter; j++ {
			if c.Post(tag, map[string]interface{}{"count": j}) != nil {
				b.Logf("whoa Post failed")
			}
		}
	}
	c.Shutdown(nil)
}

func BenchmarkOfficial(b *testing.B) {
	c, _ := official.New(official.Config{})
	for i := 0; i < b.N; i++ {
		for j := 0; j < postsPerIter; j++ {
			if c.Post(tag, map[string]interface{}{"count": j}) != nil {
				b.Logf("whoa Post failed")
			}
		}
	}
	c.Close()
}
```

```
$ go test -run=none -bench=. -benchmem -tags bench

goos: darwin
goarch: amd64
pkg: github.com/lestrrat/go-fluent-client
BenchmarkK0kubun-4              	  500000	      3191 ns/op	    1679 B/op	      13 allocs/op
BenchmarkDaichirata-4           	  500000	      3152 ns/op	     829 B/op	      10 allocs/op
BenchmarkLestrrat-4             	  500000	      3838 ns/op	     529 B/op	       7 allocs/op
BenchmarkLestrratUnbuffered-4   	  300000	      8682 ns/op	     512 B/op	       7 allocs/op
BenchmarkOfficial-4             	  200000	      8893 ns/op	     896 B/op	       9 allocs/op
PASS
ok  	github.com/lestrrat/go-fluent-client	10.610s
```

というわけで、 `github.com/k0kubun/fluent-logger-go` と大体同じくらいでしょうか。(ただ、こちらは終了時に buffer を flush することが出来ないっぽいのでちょっと実用的には微妙かなという感じはありますが) それにしても lestrrat さんのやつはエンコーダーとデコーダーを自作してるみたいですし 7 allocs/op 凄いですね。

## 終わり

最近 Go を全然書いていないので久しぶりに触る機会で来て楽しかった。おわり。
