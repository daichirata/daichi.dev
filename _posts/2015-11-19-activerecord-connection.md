---
title: ActiveRecord Connection
---

ActiveRecordのShardingライブラリを設計する際に、対応する必要があるコネクション管理と実際にコネクションがどのように使用されているのかの部分について書き留めておく。
対象のバージョンは4.2.4だけど4系なら大体同じなので問題ないと思う。

データベースへの接続はinitializerで行われる。

```ruby
# active_record/railtie.rb

initializer "active_record.initialize_database" do |app|
  ActiveSupport.on_load(:active_record) do
    self.configurations = Rails.application.config.database_configuration

    begin
      establish_connection
    rescue ActiveRecord::NoDatabaseError
      warn <<-end_warning
Oops - You have a database configured, but it doesn't exist yet!

Here's how to get started:

  1. Configure your database in config/database.yml.
  2. Run `bin/rake db:create` to create the database.
  3. Run `bin/rake db:setup` to load your database schema.
end_warning
      raise
    end
  end
end
```

## #establish_connection

```ruby
# active_record/connection_handling.rb

def establish_connection(spec = nil)
  spec     ||= DEFAULT_ENV.call.to_sym
  resolver =   ConnectionAdapters::ConnectionSpecification::Resolver.new configurations
  spec     =   resolver.spec(spec)

  unless respond_to?(spec.adapter_method)
    raise AdapterNotFound, "database configuration specifies nonexistent #{spec.config[:adapter]} adapter"
  end

  remove_connection
  connection_handler.establish_connection self, spec
end
```

spec周りの処理は本質とは関係ないのでざっくりとした理解で問題ない。environment、Hash、URL(String)のどれかを受け取りHashに展開し直す。


```ruby
# active_record/connection_adapters/abstract/connection_pool.rb

# ActiveRecord::ConnectionAdapters::ConnectionHandler
def establish_connection(owner, spec)
  @class_to_pool.clear
  raise RuntimeError, "Anonymous class is not allowed." unless owner.name
  owner_to_pool[owner.name] = ConnectionAdapters::ConnectionPool.new(spec)
end
```

owner_to_poolの実装は`@owner_to_pool[Process.pid]`になっていて、代入の結果以下の構造になる。
(@owner_to_poolは実際にはThreadSafe::Cacheのインスタンスだが、Hashのように振る舞う)

```
{ 71941 => { "ActiveRecord::Base" => #<ActiveRecord::ConnectionAdapters::ConnectionPool:...> } }
```

プロセスID毎に、establish_connectionを実行したクラス名 => プールのHash構造になっている。プロセスごとに保持している理由はforkへの対応。
クラスオブジェクト自身ではなくクラス名がkeyになっている理由は、
development modeでクラス再読み込みするのでクラスオブジェクトをそのまま使用していると参照が消えずリークしてしまうから。

それを踏まえ、Railsを起動直後のConnectionHandlerの構造は以下になる。

```
#<ActiveRecord::ConnectionAdapters::ConnectionHandler:0x007f835c5da700
  @class_to_pool=
    #<ThreadSafe::Cache:0x007f835c5da5e8
      @backend=
        { 71941 =>
          #<ThreadSafe::Cache:0x007f835c6033a8
            @backend=
              { "ActiveRecord::Base" => #<ActiveRecord::ConnectionAdapters::ConnectionPool:...> }
            @default_proc=nil> },
      @default_proc=#<Proc:...>>,
  @owner_to_pool=
    #<ThreadSafe::Cache:0x007f835c5da6b0
      @backend=
        { 71941 =>
          #<ThreadSafe::Cache:0x007f835c4ba0f0
            @backend=
              { "ActiveRecord::Base" => #<ActiveRecord::ConnectionAdapters::ConnectionPool:...> },
            @default_proc=nil> },
      @default_proc=#<Proc:...>>
```

@class_to_poolに関しては、Modelがコネクションを取得する際に使用するプールを特定するためのキャッシュなのでここでは見ない。

データベースにはこの段階では接続せずコネクションプールを初期するだけで、
コネクションが必要になった段階で接続するように遅延処理されている。

## #connection

実際にデータベースに接続されるのはconnectionを読んだタイミング。

```ruby
# active_record/connection_handling.rb

def connection
  retrieve_connection
end

def retrieve_connection
  connection_handler.retrieve_connection(self)
end
```

```ruby
# active_record/connection_adapters/abstract/connection_pool.rb

# ActiveRecord::ConnectionAdapters::ConnectionHandler
def retrieve_connection(klass) #:nodoc:
  pool = retrieve_connection_pool(klass)
  raise ConnectionNotEstablished, "No connection pool for #{klass}" unless pool
  conn = pool.connection
  raise ConnectionNotEstablished, "No connection for #{klass} in connection pool" unless conn
  conn
end
```

それぞれがちょっとした処理になってるので2つに分けて見ていく。

#### retrieve_connection_pool(klass)

klassに対応するpoolを取得する。

```ruby
def retrieve_connection_pool(klass)
  class_to_pool[klass.name] ||= begin
    until pool = pool_for(klass)
      klass = klass.superclass
      break unless klass <= Base
    end

    class_to_pool[klass.name] = pool
  end
end
```

class_to_poolの実装は`@class_to_pool[Process.pid]`になっていて、代入の結果以下の構造になる。
(@class_to_poolは実際にはThreadSafe::Cacheのインスタンスだが、Hashのように振る舞う)

```
{ 71941 => { "ActiveRecord::Base" => #<ActiveRecord::ConnectionAdapters::ConnectionPool:...>,
             "MyModel" => #<ActiveRecord::ConnectionAdapters::ConnectionPool:...> } }
```

先ほどのowner_to_poolと似ているが役割が異なっている。
owner_to_poolはプールを所持している(establish_connectionを実行した)クラスを管理している。
class_to_poolはクラスが使用するプールを管理している。プールを所持していない場合、
親クラスが所持するプールを使用するので分けて管理している。

実装は、class_to_pool[klass.name]が存在しない場合にpool_for(klass)でクラスが所持するプールの取得を試みる。
プールを所持していなければActiveRecord::Baseまで親クラスをたどり続ける。継承関係にあるクラスが明示的にestablish_connectionを呼ばない限り、
親クラスのコネクションを共有するのはこの処理のおかげである。

ちなみにclass_to_poolはキャッシュなので、新規にestablish_connectionが呼ばれた際にはclearされる。
establish_connectionが呼ばれた瞬間から、既にキャッシュされているクラスが違うプールを使用する可能性があるから。

pool_forの実装は以下になっている。

```ruby
def pool_for(owner)
  owner_to_pool.fetch(owner.name) {
    if ancestor_pool = pool_from_any_process_for(owner)
      # A connection was established in an ancestor process that must have
      # subsequently forked. We can't reuse the connection, but we can copy
      # the specification and establish a new connection with it.
      establish_connection owner, ancestor_pool.spec
    else
      owner_to_pool[owner.name] = nil
    end
  }
end
```

owner_to_poolのkeyが存在するのは下記の2パターン。

* 明示的にestablish_connectionを呼ばれた
* 既に一度引数としてownerが渡されている

pool_from_any_process_for(owner)は@owner_to_pool全体からowner.nameに対応するプールを探す。
プールが存在する場合、別プロセス(親プロセス)でプールを生成していたということになる。
つまりコメントの通りで、forkされてたら(子プロセスなら)親のプールのspecを元に再接続している。

そして得られたプールを`class_to_pool[klass.name] = pool`でキャッシュにセットしている。
プールがない場合にnilをセットしているのは2回目以降この処理を行わないため。

#### pool.connection

@reserved_connections[current_connection_id]に取得済みのコネクションがなければcheckoutしている。
checkoutはpoolからコネクションを(余っていれば)取得する処理。

```ruby
def connection
  # this is correctly done double-checked locking
  # (ThreadSafe::Cache's lookups have volatile semantics)
  @reserved_connections[current_connection_id] || synchronize do
    @reserved_connections[current_connection_id] ||= checkout
  end
end
```

@reserved_connectionsもThreadSafe::Cacheのインスタンスだ。チェックアウトされたコネクションはスレッドごとに保持されているため、その他のスレッドからは使用されないという仕組みだ。

```ruby
def checkout
  synchronize do
    conn = acquire_connection
    conn.lease
    checkout_and_verify(conn)
  end
end
```

checkoutの処理は、3段階に別れる。

* acquire_connection

コネクション取得処理。中身の処理の内容は

1. 利用可能なコネクションのキューからをコネクションを取得
2. (1で取得出来なかった場合) プール上限に達していなければ新規コネクション作成
3. (2でプール上限に達してた場合) timeout付きで再度キューから取得できるのを待つ。だめなら例外

となる。

* conn.lease

自身のスレッドをコネクションのownerにする。
acquire_connectionの3.でコネクションが足りていない場合、すでに終了しているスレッドが確保しているコネクションを回収する処理があってその時のためにセットされている。

* checkout_and_verify(conn)

コネクションがactiveかどうかを判定し、activeではない場合には再接続を試みる。
activeかどうかの実装はadapter毎に定義されている(mysql2はpingを投げてる)。
再接続だめそうならプールからコネクションを削除して例外を投げる。

それぞれの実装詳細は面倒くさいので、ここから先は自分の目で確かめよう！

つまり、あるプロセスが最低限１つ持っているプールをそれぞれのスレッドで取り合っている仕組みになっている。
そのため、unicorn等のプロセスモデルのサーバーなら余り関係のない話だしpumaのようなスレッドモデルのサーバーならプールの調整が大切なのである。

これらの仕組みを元に、既存のライブラリがどのようにしてShardingを実現しているかはまた次回。
