---
title: RustだけでRuby native extensionを書く
---

この記事は [Rust Advent Calendar 2015](http://qiita.com/advent-calendar/2015/rust-lang) 10日目の記事です。

Rustは共有ライブラリを生成してCのプログラムとリンクすることが可能らしいので、Rubyからrequireしてちゃんと動くnative extensionをRustだけを使って書いてみる。

既に似たようなことを[やっている例](https://www.youtube.com/watch?v=IqrwPVtSHZI)はあるんだけど、Cファイルを用意してそこからRustを呼び出す形になっているので、今回はCを書かずにやってみたいと思う。ちなみに実用性は特に無いのであしからず。

## Dylib

Rustで共有ライブラリを作成してCから呼び出すには、以下のようにすればよい。

```rust
#![crate_type = "dylib"]

#[no_mangle]
pub extern fn rust_test(s: i32) {
    println!("rust_test {0}", s);
}
```

`#[no_mangle]`でマングリング前の関数名をシンボルテーブルに登録し、`extern`でC ABIを用いるようにする。後はこのファイルを`rustc`を使ってコンパイルする。

```sh
$ rustc test.rs
```

この共有ライブラリをリンクするC側のコードは特別なことをする必要は無い。

```c
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

void rust_test(int32_t i);

int main() {
    rust_test(10);

    return 0;
}
```

あとは以下のようにコンパイルすれば良い。

```sh
$ cc -L. -ltest test.c -o test
$ ./test
rust_test 10
```

## FFI

RustからCを呼び出すには[Rustの他言語関数インターフェース（FFI）のガイド - Qiita](http://qiita.com/kondei/items/b448fd7e15a0a1784309)に日本語訳があるのでそれをみるのがわかりやすいと思う。

```rust
extern crate libc;
use libc::size_t;

#[link(name = "snappy")]
extern {
    fn snappy_max_compressed_length(source_length: size_t) -> size_t;
}

fn main() {
    let x = unsafe { snappy_max_compressed_length(100) };
    println!("max compressed length of a 100 byte buffer: {}", x);
}
```

ざっくりと説明すると、Cの型は`libc`というcrateに大体定義されているのでそれを使えば良い。後はexternブロック内に関数シグネチャを定義していく。C側の関数を実際に呼び出す際にはRustの安全機構外の関数を呼ぶことになるので`unsafe`ブロックで囲う必要がある。`link`attributeを指定すると、指定ライブラリとリンクしたバイナリが生成される。が、今回はリンクさせたくないのでattributeは使用しない。

## Ruby native extension

Rubyのnative extensionはロード時にdlsymで`Init_<file_name>`という関数のポインタを取得して実行を試みる。それに合わせた関数を定義してあげるとそこがエントリーポイントになる。

まずは最小構成でrequire出来るライブラリを作成してみる。

* Cargo.toml

```toml
[package]
name = "rust"
version = "0.1.0"

[lib]
name = "rust"
crate-type = ["dylib"]
```

* src/lib.rs

```rust
#![allow(non_snake_case)]

#[no_mangle]
pub extern fn Init_rust() {
    println!("Init_rust");
}
```

コンパイルして実際にRubyから呼び出してみる。Ruby側でロードしたタイミングで標準出力に文字列が出力されるはず。

```sh
$ cargo build
   Compiling rust v0.1.0 (file:///Users/xxxx)

# RubyはDynamic Loadingなファイルをロードする為、.bundleに書き換える
$ mv target/debug/librust.dylib rust.bundle

$ irb -r./rust
Init_rust
irb(main):001:0>
```

次に、RustからRubyのクラスを定義してみる。今回からはlibcを使用するためCargo.tomlに下記を追加する。ちなみにポインタのサイズとかはOSXに合わせて決め打ちする。

* Cargo.toml

```toml
[dependencies]
libc = "0.2.2"
```

次に、src/lib.rsを以下のように書き換える。

* src/lib.rs

```rust
#![allow(non_snake_case, non_camel_case_types)]

extern crate libc;
use std::ffi::CString;

type VALUE = libc::c_ulong;

extern {
    static rb_cObject: VALUE;

    fn rb_define_class(name: *const libc::c_char, rb_super: VALUE) -> VALUE;
}

#[no_mangle]
pub extern fn Init_rust() {
    let c_name = CString::new("Rust").unwrap();

    unsafe { rb_define_class(c_name.as_ptr(), rb_cObject) };
}
```

`VALUE`はRubyのデータを扱うC側の型で、構造体に対するポインタ又は値その物。`rb_cObject`はC側の外部変数なので、Rustから参照するにはexternブロック内でstaticとして定義する。今回は書き換える必要は無いので`*mut`はつけない。`rb_define_class`はC側では

```c
VALUE rb_define_class(const char *name, VALUE super);
```

という関数なのでそれに対応する関数シグネチャをRust側に定義する。RustからC側の関数に文字列を渡す場合には`std::ffi::CString`を経由する必要がある。

これらをlink attributeを使わずにコンパイルする為には、linkerにオプションを渡す必要がある(link-argsはstable releaseでは使えない)。 が、`cargo build`ではlinkerにオプションを渡せない仕様になっているので`cargo rustc`を使用する。ただ、linkerにオプションを渡すことは推奨されていない。今のrustcはccを使ってるけど、今後はllvmを直接使うかもしれないし他の何かに置き換わった場合それらのオプションが無意味になるから。今回はちょっとしたお遊びなので無視して渡している。

```sh
cargo rustc -Clink-args='-Wl,-undefined,dynamic_lookup'
   Compiling rust v0.1.0 (file:///Users/xxxxx)

mv target/debug/librust.dylib ./rust.bundle

$ irb -r./rust
irb(main):001:0> Rust
=> Rust
irb(main):002:0> Rust.new
=> #<Rust:0x007fe25200ffa0>
```

ちゃんとRubyの世界で`Rust`が定義されていてインスタンスが生成できる。

後は、必要そうな関数をピックアップしてRust側に外部変数や関数シグネチャなどを追加していけば良い。試しに、よくあるフィボナッチ数を求める関数を持ったクラスを定義してみる。

* src/fib.rs

```rust
pub fn fib(n: u32) -> u32 {
    if n <= 1 {
        n
    } else {
        fib(n - 1) + fib(n - 2)
    }
}
```

* src/lib.rs

```rust
#![allow(non_snake_case, non_camel_case_types)]

extern crate libc;
mod fib;

use std::ffi::CString;

type VALUE = libc::c_ulong;

extern {
    static rb_cObject: VALUE;

    fn rb_define_class(name: *const libc::c_char, rb_super: VALUE) -> VALUE;

    fn rb_define_method(klass: VALUE,
                        name: *const libc::c_char,
                        func: extern fn(v: VALUE, v2: VALUE),
                        argc: libc::c_int) -> libc::c_void;

    fn rb_num2long(val: VALUE) -> libc::c_long;
}

fn rb_int2fix(num: u32) -> VALUE {
    return ((num as VALUE) << 1) | 0x01;
}

extern fn rb_fib(_: VALUE, rb_num: VALUE) {
    let num = unsafe { rb_num2long(rb_num) } as u32;
    let result = fib::fib(num);

    rb_int2fix(result);
}

#[no_mangle]
pub extern fn Init_rust() {
    let c_name = CString::new("Rust").unwrap();
    let fib = CString::new("fib").unwrap();

    unsafe {
        let rb_cRust = rb_define_class(c_name.as_ptr(), rb_cObject);

        rb_define_method(rb_cRust, fib.as_ptr(), rb_fib, 1);
    }
}
```

実行してみると正しく動いていることが分かる。

```sh
$ cargo rustc -Clink-args='-Wl,-undefined,dynamic_lookup'
   Compiling ruby v0.1.0 (file:///Users/xxxxxxxx)

$ irb -r ./target/debug/rust
irb(main):001:0> Rust.new.fib(10)
=> 55
```

今回作成したファイルは[daichirata/rust_ruby_extention](https://github.com/daichirata/rust_ruby_extension)に置いてる。

## つらいところ

CのヘッダーからRustの定義ファイルを生成する[crabtw/rust-bindgen](https://github.com/crabtw/rust-bindgen)というツールが一応あって、このツールを元にRubyのヘッダーファイルの定義を出力すると[こうなる。](https://github.com/daichirata/rust_ruby_extension/blob/master/src/bindgen.rs)完璧な変換までは難しくて、そのままではエラーになって使うことが出来ないんだけど、結構参考になると思うので一旦出力してこのファイルを見ながらやると捗ると思う。

ただ、当然なんだけどCのマクロには対応していないので、対応するCの関数があれば良いんだけど無かった場合には自分で実装する必要がある。例えばCのintをVALUEに変換する`FIX2LONG`マクロとか。Rubyは比較的対応する関数が多い気がするので意外となんとかなるかも？

後、Rustの可変長引数への対応もすごく微妙でやり方がわからなかったので、上の例ではごまかしている部分がある。`rb_define_method`というC側の関数は3番目の引数に関数ポインタを受け取るんだけど、引数が可変長引数として定義されている。Rustでもexternブロック内の関数シグネチャには可変長に定義できるっぽいので初めは

```rust
extern {
    fn rb_define_method(klass: VALUE,
                        name: *const libc::c_char,
                        func: extern fn(v: VALUE, ...),
                        argc: libc::c_int) -> libc::c_void;
}
```

と定義していたんだけど、rb_fibを渡している部分で型が一致しないとかでコンパイルが通らないので結局あきらめて、2つの引数を受け取る関数のポインタとして定義してお茶をにごしている。bindgenで生成される奴でもよくわからなかったのでこの辺に詳しい人是非教えて下さい。

## おまけ

link attributeを使って正攻法でビルドするには、rubyを共有ライブラリ付きでビルドした上でbuild.rsを追加すれば良い。

```sh
$ RUBY_CONFIGURE_OPTS="--enable-shared" rbenv install 2.2.3
```

* build.rs

```rust
use std::process::Command;

fn main() {
    let output = Command::new("ruby")
        .arg("-e")
        .arg("puts RbConfig::CONFIG['libdir']")
        .output()
        .unwrap_or_else(|e| { panic!("failed to execute process: {}", e) });

    println!("cargo:rustc-link-search=native={}", String::from_utf8_lossy(&output.stdout));
}
```

後は、externの前の行に`#[link(name = "ruby")]`と書けば`cargo build`でビルドできる。ただ、librubyにリンクされていて依存関係がある所だけ注意しておいたほうがいい。
