---
title: golang.org/x/time/rate
---

[golang.org/x](https://pkg.go.dev/golang.org/x) には Go プロジェクト配下なんだけどメインツリー外の、いわゆる準標準的なライブラリが管理されています。Go の language server 実装である [gopls](https://pkg.go.dev/golang.org/x/tools/gopls) なんかもこの配下で管理されていて、Go 本体よりゆるい互換性で開発されていると明言されている通り割とアグレッシブで面白い機能を持ったライブラリがあります。ライブラリから機能に対するインスピレーションを得られる事も多々あるので、今回はその中から適当に面白い奴として `golang.org/x/time/rate` を取り上げます。

[golang.org/x/time/rate](https://pkg.go.dev/golang.org/x/time/rate)

このライブラリには主に `Limiter` と `Sometimes` の２つの機能があるのでそれぞれについて書きます。

## Limiter

Limiter は [トークンバケット](https://ja.wikipedia.org/wiki/%E3%83%88%E3%83%BC%E3%82%AF%E3%83%B3%E3%83%90%E3%82%B1%E3%83%83%E3%83%88)というアルゴリズムを用いて秒間のイベント(回数\|量)を制限する事ができます。これにより、サーバーや特定のリソースに対して過剰な負荷をかけないようにすることが出来ます。例えばトークンを貯めるバケットの上限が 10 で秒間 5 ずつトークンが貯まる設定の場合、常にイベントが発生している場合は最大 5 rps のペースでイベントを実行(トークンを消費)する事ができ、2 秒以上イベントの発生が無い場合は 10 までトークンを貯めることが出来ます。なのでその瞬間に限って言うとイベントの処理時間を無視すれば貯蓄していた 10 トークン分のイベント + 秒間に補填される 5 トークンで 15 rps までバーストすることが出来るといったような感じです。


使用方法としてまず初めに `NewLimiter` 関数を使用して制限するための Limiter を作成します。

``` go
// func NewLimiter(r Limit , b int) *Limiter
limiter := rate.NewLimiter(5, 1)
```

第一引数がトークンが秒間に溜まる速度、第二引数がトークンバケットのサイズです。この例でいうと秒間 5 トークン補充されるので最大 5 rps までイベントを実行することが出来ますが、トークンバケットのサイズは 1 なのでトークンを 1 つしかストック出来ないのでバーストすることは出来ません。

`Every` 関数で interval の間隔でトークンが 1 つ補充されるという指定をすることも出来ます。

``` go
// func Every(interval time.Duration) Limit
limiter := rate.NewLimiter(rate.Every(300*time.Millisecond), 1)
```

この例の場合は 300 ms 毎にトークンが 1 つ補填されるようになり、約 3.3 rps のペースでイベントを実行する事が出来ます。

その後に `Wait` 関数を使用してイベントの実行が許可されるまでブロックします。


``` go
package main

import (
	"context"
	"fmt"
	"sync"
	"time"

	"golang.org/x/time/rate"
)

func main() {
	ctx := context.Background()
	var wg sync.WaitGroup

	limiter := rate.NewLimiter(5, 1)

	for i := 0; i < 30; i++ {
		wg.Add(1)
		i := i
		go func() {
			if err := limiter.Wait(ctx); err != nil {
				panic(err)
			}
			fmt.Printf("%s: %d\n", time.Now(), i)
			wg.Done()
		}()
	}
	wg.Wait()
}
```

このコードの [Playground がこちら](https://go.dev/play/p/wyq7rAhZSUN) で、以下のような実行結果になります。

``` shell
2009-11-10 23:00:00 +0000 UTC m=+0.000000001: 19
2009-11-10 23:00:00.2 +0000 UTC m=+0.200000001: 14
2009-11-10 23:00:00.4 +0000 UTC m=+0.400000001: 11
2009-11-10 23:00:00.6 +0000 UTC m=+0.600000001: 9
2009-11-10 23:00:00.8 +0000 UTC m=+0.800000001: 10
2009-11-10 23:00:01 +0000 UTC m=+1.000000001: 13
2009-11-10 23:00:01.2 +0000 UTC m=+1.200000001: 4
2009-11-10 23:00:01.4 +0000 UTC m=+1.400000001: 0
2009-11-10 23:00:01.6 +0000 UTC m=+1.600000001: 1
2009-11-10 23:00:01.8 +0000 UTC m=+1.800000001: 2
2009-11-10 23:00:02 +0000 UTC m=+2.000000001: 3
2009-11-10 23:00:02.2 +0000 UTC m=+2.200000001: 16
2009-11-10 23:00:02.4 +0000 UTC m=+2.400000001: 15
2009-11-10 23:00:02.6 +0000 UTC m=+2.600000001: 6
2009-11-10 23:00:02.8 +0000 UTC m=+2.800000001: 5
2009-11-10 23:00:03 +0000 UTC m=+3.000000001: 17
2009-11-10 23:00:03.2 +0000 UTC m=+3.200000001: 18
2009-11-10 23:00:03.4 +0000 UTC m=+3.400000001: 7
2009-11-10 23:00:03.6 +0000 UTC m=+3.600000001: 8
2009-11-10 23:00:03.8 +0000 UTC m=+3.800000001: 12

Program exited.
```

ちゃんと想定通り秒間 5 rps でイベントを実行出来ていると思います。

ただ、ここまでの内容であればこのライブラリを使用しなくても例えば `time.Ticker` を使用して 200 ms 間隔で処理をするだけでよかったりで `Limiter` を使うメリットをそこまで感じないかなと思いますが、このライブラリの面白い所は `Wait` で消費するトークンの量を指定することが出来る点にあります。トークンの量を指定する事で可能な面白い事の一つとして、トークンを byte に置き換えることでディスクやネットワークへの書き込みや読み込みの制限を簡単に実装することが出来ます。実現するには `WaitN` 関数を使います。

``` go
// 複数のトークンを一度に消費するので、トークンバケットの上限を 1 以上に設定します
limiter := rate.NewLimiter(2, 8)

// limiter を生成した瞬間はトークンが最大まで溜まっている状態なので
// 動作確認のために一旦トークンを全て消費
limiter.WaitN(ctx, 8)

// 4 トークン消費可能になるまでブロックする
limiter.WaitN(ctx, 4)
```

この指定の場合、`WaitN` で 4 トークンを要求しているのでトークンバケットが空の場合トークンが補填されまで 2 秒感の間 `WaitN` で処理がブロックされます。余談ですが `Wait` 関数は内部で 1 トークンを要求する `WantN` 関数の呼び出しとして実装されています。

これを `io.Writer` の interface に合わせる事で以下のような物が実装可能になります。

``` go
package main

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"math/rand"
	"time"

	"golang.org/x/time/rate"
)

func main() {
	// 500 KB
	data := make([]byte, 500*1024)
	rand.Read(data)

	reader := bytes.NewReader(data)
	writer := &bytes.Buffer{}
	// 100 KB ずつトークンが補填され、秒間最大で 100 KBまで読み書きが行われる
	limiter := rate.NewLimiter(100*1024, 100*1024)
	limiter.WaitN(context.TODO(), 100*1024) // 最初に溜まっている全てのトークンを消費

	rw := &ReadWriter{w: writer, r: reader, limiter: limiter}

	readStart := time.Now()

	// 500 KB のデータを一括で読み込む
	buf := make([]byte, 500*1024)
	n, err := rw.Read(buf)
	if err != nil {
		panic(err)
	}
	for i := range buf {
		if data[i] != buf[i] {
			panic("OMG!")
		}
	}
	// 5 秒でデータを読み切る
	fmt.Printf("readed %d bytes in %s\n", n, time.Since(readStart))

	writeStart := time.Now()

	// 500 KB のデータを一括で書き込む
	n, err = rw.Write(data)
	if err != nil {
		panic(err)
	}
	buf = writer.Bytes()
	for i := range buf {
		if data[i] != buf[i] {
			panic("OMG!")
		}
	}
	// 5 秒でデータを読み切る
	fmt.Printf("wrote %d bytes in %s\n", n, time.Since(writeStart))
}

type ReadWriter struct {
	w       io.Writer
	r       io.Reader
	limiter *rate.Limiter
}

func (rw *ReadWriter) Read(p []byte) (int, error) {
	var n int

	for n < len(p) {
		// 一度に消費できるトークンの最大値に合わせて一度に読み込む量を調整する
		size := len(p[n:])
		if size > rw.limiter.Burst() {
			size = rw.limiter.Burst()
		}

		rn, err := rw.r.Read(p[n : n+size])
		if err != nil {
			return n, err
		}
		n += rn

		// 読み込んだバイト数をトークンに見立てて消費させる事で秒間の読込レートを制御する
		if err := rw.limiter.WaitN(context.TODO(), rn); err != nil {
			return n, err
		}
	}
	return n, nil
}

func (rw *ReadWriter) Write(b []byte) (int, error) {
	var n int

	for n < len(b) {
		// 一度に消費できるトークンの最大値に合わせて一度に書き込む量を調整する
		size := len(b[n:])
		if size > rw.limiter.Burst() {
			size = rw.limiter.Burst()
		}

		wn, err := rw.w.Write(b[n : n+size])
		if err != nil {
			return n, err
		}
		n += wn

		// 書き込んだバイト数をトークンに見立てて消費させる事で秒間の書込レートを制御する
		if err := rw.limiter.WaitN(context.TODO(), wn); err != nil {
			return n, err
		}
	}
	return n, nil
}
```

このコードの [Playground がこちら](https://go.dev/play/p/NyyYhBiBP1E) で、以下のような実行結果になります。

``` shell
readed 512000 bytes in 5s
wrote 512000 bytes in 5s

Program exited.
```

特にこの例では Go の `io.Writer` と `io.Reader` の汎用性の高さや強力さも相まって簡単な実装だけであらゆる書込と読込の速度を制御する事が出来る `ReadWriter` をここまで簡単に実装する事が出来ています。ほかにもトークンの予約を行うための `Reserve` 関数や動的に Limit を変更するための `SetLimit` 関数などがあるのでプログラマブルに挙動を変える事も可能です。トークンを何に見立てるかのアイディア次第ではもっと面白い使い方もある事でしょう。

## Sometimes

`Sometimes` はとても小さなライブラリで時間と回数に応じたイベントの実行タイミングを制限することが出来ます。具体的には

- 最初の n 回だけ実行する
- n 回毎に実行する
- n 秒毎に実行する

を or の組み合わせで制御することが出来ます。

``` go
type Sometimes struct {
	First    int           // 指定した数を N とした場合、最初の N 回分だけ実行する
	Every    int           // 指定した数を N とした場合、N 回毎に実行する
	Interval time.Duration // 最後に実行した時間から Interval 分時間が経過していればもう一度実行する
}
```

なので例えば

- 最初の 10 回はログを出力したい
- 10 回を超えた後は 1 秒に 1 回だけログを出力してくれれば良い

という指定を行いたい場合は

``` go
var sometimes = rate.Sometimes{First: 10, Interval: 1*time.Second}

func Spammy() {
        sometimes.Do(func() { log.Info("here I am!") })
}
```

といった感じで指定する事が可能です。ただ `Sometimes` に関しては機能が少なく、実際に使用する場合には n 秒毎に x 回 (例えば 10 秒ごとに 50 件だけログを出力) といった形で x 秒毎に First をリセットしたいとか、もう少し細かい制御を行いたいケースも多いので `Sometimes` を直接使える機会はそこまで多くないかもしれません。
