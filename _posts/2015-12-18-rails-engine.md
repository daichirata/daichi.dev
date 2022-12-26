---
title: Rails Engineを使ってAPIと管理画面を分離する
---

この記事は [Ruby on Rails Advent Calendar 2015](http://qiita.com/advent-calendar/2015/rails) 15日目の記事です。

これまで携わってきたソーシャルゲームのサーバーサイド開発では、1タイトルに対して主に3つの機能を作成することが多かった。

* API
  * スマートフォンのネイティブアプリケーションから呼ばれるJSON(あるいはJSONフォーマット互換)API
* 管理用画面
  * ユーザー情報管理、その他各種制御処理を行う(BANとか補填とかマスタデータキャッシュ管理とか)。エンジニアとカスタマーサポートチームが使用する
* デバッグ用画面
  * 開発用のWebUI、単純なAPIを呼ぶフォームではなく「カードのレベルをMAXにするボタン」みたいなものが機能ごとに沢山ある

開発を行う場合、大体はAPI用の機能がメインになる。ただ、デバック用画面に関しては完全に社内開発用なので適当で構わないけど、管理用画面に関してはそれなりの作りこみが必要になる。基本的には普通のWebアプリケーション開発と変わらない。[Draper](https://github.com/drapergem/draper)等のデコレーターを導入したりページネーションを導入したりassetsが結構あったりする。モデルもAPIとは別に存在していて、ユーザーのデータを変更することになるので証跡管理用テーブルや、マスタデータの更新管理用テーブルなどがある。それらを、APIサーバーをメインに書かれているRailsアプリケーションに追加して行くことになる。

ページネーションやデコレーター系のgemは全体に影響するので、API用のモデルが何故か`#decorate`メソッドを持っていたり、app以下にdacoratorsディレクトリがあったり、assetsをAPIサーバーでは配信しないように設定を変えたりするのを何とかしたいと思っていた。

単純に、別のRailsアプリケーションとして実装すればいいじゃんっていう話もあるんだけど、結局はAPIも管理用画面も同じユーザーのデータを扱う事になるので管理用画面のアプリケーションからはAPIのモデルを扱う必要がある。なのでRails Engineを使用してアプリケーションを分離してみたのが今回の話。

## Rails Engine

Rails Engineの使い方は[RailsGuides(日本語訳)](http://railsguides.jp/engines.html)を見ると使い方は大体わかると思う。

これを例えば今回はadminという名前で定義してみる。

```sh
$ bin/rails plugin new admin --mountable
```

で、mount可能なエンジンとして定義する。

後は、GemfileでEngineを読み込んでroutes.rbでmountする。


```ruby
# Gemfile

gem 'admin', path: "admin"
```

```ruby
# config/routes.rb

Rails.application.routes.draw do
  mount Admin::Engine => "/admin"
end
```

基本の形はこんな感じ。Engineの中にもbin/railsファイルがあるので、それを使ってファイルをgenerateしながら管理用画面を開発する。デコレーターやassets関連も全部Engine以下に入れる。

そのままでもある程度整理されるので良いんだけど、APIサーバーではそもそもEngineを読み込まない様にする事で完全に分離させる。

先ず、適当に定義したgroup内に移動させる。

```ruby
# Gemfile

group :admin do
  gem 'admin', path: "admin"
end
```

次に環境変数で指定されていた場合のみ、Engineのgroupをrequireするようにする。

```ruby
# config/application.rb

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
# Bundler.require(*Rails.groups)

groups = Rails.groups
groups << :admin if ENV['SERVER_TYPE_ADMIN']
Bundler.require(*groups)
```
後はAdmin::Engineが定義されている場合のみmountを行う。

```ruby
# config/routes.rb

Rails.application.routes.draw do
  if defined?(Admin::Engine)
    mount Admin::Engine, at: :admin
  end
end
```

こうすることで、Engineを読み込まないAPIサーバー側でview用のgemがロードされたり、管理用画面にアクセスされることは無い。assets:precompileなどを行ってもそもそもEngineが読み込まれていないので、デプロイなんかも共通のフローでいけるはず。

## Database

Rails Engineのmigrationは普通は親となるアプリケーションのmigrationにコピーすることになる。が、API側のアプリケーションは[tchandy/octopus](https://github.com/tchandy/octopus)を使ってshardingしていたのでちょっと厳しい。更に、管理系のDBなのでAPI側のアプリケーションと同一のDBに入れることは基本的には無いだろう。

今回はちょっと無理やり、DBの接続設定やmigrationも含めてEngine内で全て完結させることにする。まず初めに、DB接続用のabstract classを作成する。

```ruby
module Admin
  class Base < ActiveRecord::Base
    self.abstract_class = true

    databases = YAML.load_file(Engine.root.join('config/database.yml'))
    octopus_establish_connection databases[Rails.env]

    def self.inherited(child)
      child.custom_octopus_connection = true
      super
    end
  end
end
```

Engine内で追加するモデルは全てこのクラスを継承させてあげる事で、Engine内のconfigを元にしたDBに接続するようになる。

migrationファイルも親にコピーさせずにEngine内で実行できるようにEngine内にrake taskを定義する。


```ruby
# admin/lib/tasks/admin_tasks.rake

namespace :admin do
  task :set_custom_db_config_paths do
    root = Admin::Engine.root

    ENV['SCHEMA']       = root.join('db/schema.rb').to_s
    ENV['DB_STRUCTURE'] = root.join('db/structure.sql').to_s

    Rails.application.config.paths['db/migrate']      = [root.join('db/migrate').to_s]
    Rails.application.config.paths['db/seeds']        = [root.join('db/seeds').to_s]
    Rails.application.config.paths['config/database'] = [root.join('config/database.yml').to_s]

    ActiveRecord::Migrator.migrations_paths = root.join('db/migrate').to_s
  end

  admin_task = ->(name) {
    task name => :set_custom_db_config_paths do
      Rake::Task[name].invoke
    end
  }

  %w(db:drop db:create db:migrate db:rollback db:seed db:version
     db:schema:dump db:schema:load db:structure:dump db:structure:load).each do |t|
    admin_task[t]
  end
end

```

`set_custom_db_config_paths`で、migrationの情報を書き換える。そうすることでmigrationを親アプリにコピーすること無く実行することが出来る。実行したい場合にはEngineを読み込む必要があるので

```sh
$ SERVER_TYPE_ADMIN=1 bin/rake admin:db:create
```

的な感じで実行するか、開発のローカル環境なら[dotenv](https://github.com/bkeepers/dotenv)などを使って常に読みこむようにしておいても良いかもしれない。




## Tips

Rails Engine側で使用するgemは`<engine_path>/<name>.gemspec`に追加する。その場合Bundlerを経由しているわけではないので自動的にrequireされることは無い。なのでgemを追加した場合には`<engine_path>/lib/<name>/engine.rb`でrequireしてあげる必要がある。

```ruby
# admin/admin.gemspec

Gem::Specification.new do |s|
  s.add_dependency "draper"
end
```

```ruby
# admin/lib/admin/engine.rb

require "draper"

module Admin
  class Engine < ::Rails::Engine
    isolate_namespace Admin
  end
end
```

assets系のgemとかを追加した場合には読み込まれずに悩むことになるので気をつけたほうが良い。別に従わずに上で定義したGemfileのgroup内に追加してもいいし、その場合はこれは不要だけど。

後、コントローラーの追加などはちゃんとEngine内のbin/railsでgenerateしたほうが良い。

```ruby
require_dependency "admin/application_controller"

module Admin
  class UsersController < ApplicationController
  end
end
```

あるいは、`require_dependency`をちゃんとつけたほうがいい。何故なのかと言うと、Railsではローカルなどの開発環境ではファイルの変更があった場合にクラスが再ロードされる。その時先に親アプリのApplicationControllerが評価されるpathを通った場合、以降Engine側のApplicationControllerの評価が親アプリのクラスとして実行されてしまうから。

autoloadの問題なので、この様に定義する形でも回避できる。

```ruby
class Admin::UsersController < Admin::ApplicationController
end
```

詳細はRailsGuidesの[このへん](http://railsguides.jp/constant_autoloading_and_reloading.html)が詳しい。

親アプリの何かをEngine側から拡張したい場合には`to_prepare`で追加する。これも上と同様で、そうしないとクラスの再ロード時に問題がでる。

```ruby
module Admin
  class Engine < ::Rails::Engine
    isolate_namespace Admin

    config.to_prepare do
      ::ApplicationController.send(:include, SuperGrateModule)
    end
  end
end
```

ユースケースとしては、refererを見てデバック用画面のフォームからAPIへのリクエストだった場合だけユーザー情報をsessionに格納したり、エラーログにメッセージを追加したりするmoduleをEngine側からincludeさせたりしている。結局は普通の同一プロセスにロードされるRubyプログラムなので、まあなんとでもなると思う。

## おわり

APIサーバーと付随するWebUIをEngineで分離すると、それぞれが開発のサイクルやデプロイのタイミングなんかも異なったりするので安心感があって良い。migration周りは若干バットノウハウ気味だけど用件的にしょうがない部分あるのでまあいいんじゃないかな。

