---
title: El-get + Flycheckのインストール時のエラー
---

最近Emacsの挙動が少し怪しくなってきていた。心当たりはすこしあって、Emacsのバージョンを上げた際に面倒くさくて全てのプラグインをバイトコンパイルし直さなかった。
一旦全てのパッケージを最新にアップデートしたかったこともあり、el-get-dir以下を全て削除してインストールし直した際にflycheckのインストールでエラーが出たのでその時のメモ。

## エラー

flycheckのインストールの際に起きたエラー。

```sh
doc/flycheck.texi:6: 警告: unrecognized encoding name `UTF-8'.
doc/flycheck.texi:86: @pxref expected braces.
doc/flycheck.texi:86: ` {Installation}
and @ref{Quickstart} res...' is too long for expansion; not expanded.
doc/flycheck.texi:86: First argument to cross-reference may not be empty.
./doc/flycheck.texi:75: 次 reference to nonexistent node `Introduction' (perhaps incorrect sectioning?).
./doc/flycheck.texi:85: 相互 reference to nonexistent node `Introduction' (perhaps incorrect sectioning?).
makeinfo: エラーにより、出力ファイル `doc/flycheck.info' を削除します。
       -- 残したい場合には `--force' オプションを使ってください。
```

軽く調べてみた感じだと[https://github.com/flycheck/flycheck/issues/299](https://github.com/flycheck/flycheck/issues/299)にある通り、texinfoのバージョンが古いと発生する模様。エラーとなるコマンドは

```sh
$ makeinfo -o doc/flycheck.info doc/flycheck.texi
```

で、OSX10.10の標準のmakeinfoは4.8らしい。

```sh
$ makeinfo --version
makeinfo (GNU texinfo) 4.8

Copyright (C) 2004 Free Software Foundation, Inc.
There is NO warranty.  You may redistribute this software
under the terms of the GNU General Public License.
For more information about these matters, see the files named COPYING.
```

## インストール

とりあえず、Homebrewで新しいtexinfoをインストールするべし。

```sh
$ brew info texinfo
texinfo: stable 5.2 (bottled)
http://www.gnu.org/software/texinfo/

This formula is keg-only.
Mac OS X already provides this software and installing another version in
parallel can cause all kinds of trouble.

Software that uses TeX, such as lilypond and octave, require a newer versqion
of these files.

/usr/local/Cellar/texinfo/5.2 (396 files, 8.1M)
  Poured from bottle
From: https://github.com/Homebrew/homebrew/blob/master/Library/Formula/texinfo.rb

$ brew install texinfo
```

texinfoは標準でOSXにインストールされているパッケージなので`--force`を付けてlinkする。

```sh
$ brew link --force texinfo
```

後は、再びインストールすれば問題ない・・・が、自分の環境ではもう少し問題ががが。

## Emacs PATH問題

OSXでEmacs(GUI版)を起動した際に[EmacsでPATHの設定が引き継がれない問題をエレガントに解決する](http://qiita.com/catatsuy/items/3dda714f4c60c435bb25)の様な問題がある。

私の場合は[exec-path-from-shell](https://github.com/purcell/exec-path-from-shell)というパッケージを利用してこの問題を解決していたが、このパッケージ自体もel-getで管理していたためflycheckのインストール中にはまだロードされていなかった。

なので、PATH問題の解決にexec-path-from-shellを使うのをやめ、上のQiitaにある関数を定義した。

```elisp
(defun set-exec-path-from-shell-PATH ()
  "Set up Emacs' `exec-path' and PATH environment variable to match that used by the user's shell.

This is particularly useful under Mac OSX, where GUI apps are not started from a shell."
  (interactive)
  (let ((path-from-shell (replace-regexp-in-string "[ \t\n]*$" "" (shell-command-to-string "$SHELL --login -i -c 'echo $PATH'"))))
    (setenv "PATH" path-from-shell)
    (setq exec-path (split-string path-from-shell path-separator))))

(set-exec-path-from-shell-PATH)
```

後はこの関数をel-getの初期化の前に呼んであげれば無事インストールできると思う。
