---
title: ActiveRecord Sharding
---

[前回](/posts/2015-11-19-activerecord-connection)の続き

ActiveRecordが実際にDBにクエリを発行する場合`ActiveRecord::Base.connection`を経由する。話を単純にする為に、クエリの実行だけに限定してShardingを実現しようと思った場合このメソッドがそれぞれのShardに対して確立されたコネクションを返せば良い。

一番多く採用されている実現方法はconnectionメソッドを上書きしてproxyを経由させるパターンで、多くのGemで採用されている。その他にもコネクションの確立方法・管理などで既存のGemがどうやって実現しているかをいくつか紹介する。

## Octopus

おそらく一番有名なのかもしれないGem。[kovyrin/db-charmer](https://github.com/kovyrin/db-charmer)の影響を少なからず受けている。

実際に置き換えているのは、ActiveRecord::BaseにOctopus::Modelをextendした際に実行されるhijack_methodsで行われている。

```ruby
# lib/octopus/model.rb

def hijack_methods
  # ...

  class << self
    # ...

    alias_method_chain :connection, :octopus
    alias_method_chain :connection_pool, :octopus
    alias_method_chain :clear_all_connections!, :octopus
    alias_method_chain :clear_active_connections!, :octopus
    alias_method_chain :connected?, :octopus

    # ...
  end
end

def connection_with_octopus
  if should_use_normal_connection?
    connection_without_octopus
  else
    connection_proxy.current_model = self
    connection_proxy
  end
end

def connection_proxy
  ActiveRecord::Base.class_variable_defined?(:@@connection_proxy) &&
    ActiveRecord::Base.class_variable_get(:@@connection_proxy) ||
    ActiveRecord::Base.class_variable_set(:@@connection_proxy, Octopus::Proxy.new)
end
```

Octopus::Proxyはそこそこにツラみを伴うアレなクラスで、Shard毎のコネクションの切り替え以外にもShardへのコネクション確立(プールの作成)と管理もProxyクラス自身で行っている。つまりActiveRecordのConnectionHandlerのような役割を自前で実装している。初めてconnectionが実行されたタイミングでインスタンスが生成され、initalizeで各Shardへのプールを作成する。

内部ではTLSを使ってShardを管理していて、method_missiongでその時に指定されているShardのコネクションを取得してProxyする。簡単なダミーコードで説明すると

```ruby
Thread.current[:octopus_shard]              # => nil
ActiveRecord::Base.connection.execute(...)  # => default connection.

Octopus.using(:shard1) do
  Thread.current[:octopus_shard]             # => :shard1
  ActiveRecord::Base.connection.execute(...) # => :shard1 connection.
end
```

のような感じ。 Shardへの振り分けはProxyのmethod_missingで

```ruby
def method_missing(method, *args, &block)
  if should_clean_connection_proxy?(method)
    conn = select_connection
    self.last_current_shard = current_shard
    clean_connection_proxy
    conn.send(method, *args, &block)
  elsif should_send_queries_to_shard_slave_group?(method)
    send_queries_to_shard_slave_group(method, *args, &block)
  elsif should_send_queries_to_slave_group?(method)
    send_queries_to_slave_group(method, *args, &block)
  elsif should_send_queries_to_replicated_databases?(method)
    send_queries_to_selected_slave(method, *args, &block)
  else
    select_connection.send(method, *args, &block)
  end
end
```

現在のShardに対するconnectionを取得してそのconnectionに対してsendでdelegateする実装になっている。その他にも実際にはRelation・Associationの対応でもう少し作りこみが必要だが基本的な考え方はこれで問題ない。

## SwitchPoint

ShardingではなくR/W splittingに使われているGem。コネクションを切り替えるという点ではだいたい似ているので紹介しておく。軽量なGemで見通しも良いので何か1つガッツリ読みこんで勉強したいのであればこのGemを選択するの良いかもしれない。

SwitchPoint::ModelをincludeしたModelに対してconnectionを差し替える。その後use_switch_pointを実行することでproxyを有効にする。

```ruby
# lib/switch_point/model.rb

def self.included(model)
  model.singleton_class.class_eval do
    include ClassMethods
    alias_method_chain :connection, :switch_point
    alias_method_chain :cache, :switch_point
    alias_method_chain :uncached, :switch_point
  end
end

module ClassMethods
  def connection_with_switch_point
    if switch_point_proxy
      switch_point_proxy.connection
    else
      connection_without_switch_point
    end
  end

  def switch_point_proxy
    if @switch_point_name
      ProxyRepository.checkout(@switch_point_name)
    elsif self == ActiveRecord::Base
      nil
    else
      superclass.switch_point_proxy
    end
  end
end
```

コネクションはProxyRepository.checkoutのタイミングで未初期化の@switch_point_nameであれば作成される。また、継承関係にも対応していて自身でuse_switch_pointを実行していないクラスは親クラスのproxyをたどることでActiveRecordの様にコネクションを使い回す様になっている。

コネクションの確立方法は、ActiveRecord::Baseを継承するダミークラスを作成してそのクラスを使ってestablish_connectionを実行している。

```ruby
# lib/switch_point/proxy.rb

def define_model(name, mode)
  model_name = SwitchPoint.config.model_name(name, mode)
  if model_name
    model = Class.new(ActiveRecord::Base)
    Proxy.const_set(model_name, model)
    model.establish_connection(SwitchPoint.config.database_name(name, mode))
    model
  elsif mode == :readonly
    # Re-use writable connection
    Proxy.const_get(SwitchPoint.config.model_name(name, :writable))
  else
    Class.new(ActiveRecord::Base)
  end
end
```

後は必要に応じてクラスを取り出してconnectionを取得する。この方式のいいところはOctopusと違ってestablish_connection経由でのコネクション確立なのでActiveRecordの変更に比較的強い所と、ActiveRecord::BaseのConnectionHandlerに管理を任せられる部分にある(clear_active_connections!等の確保済みコネクションに対する処理の辺り)。

SwitchPointもproxy内部でmodeがTLSで管理されていてreadとwriteのコネクションを切り替える仕組みになっている。

```ruby
Article.with_readonly { Article.first } # Read from db-blog-slave
Category.with_readonly { Category.first } # Also read from db-blog-slave
Comment.with_readonly { Comment.first } # Read from db-comment-slave

Article.with_readonly do
  article = Article.first  # Read from db-blog-slave
  article.title = 'new title'
  Article.with_writable do
    article.save!  # Write to db-blog-master
    article.reload  # Read from db-blog-master
    Category.first  # Read from db-blog-master
  end
end
```

## ActiveRecord::Turntable

ドリコム製のライブラリ。これまでにあったGemとはアプローチが大きく異なりconnectionを上書きしない。更に`Ocotpus.using`のようなShardの指定を明示的に行わずにShardingを実現している。また、クラスタでUniqなIDを生成するためのSequencerが付いてきたりする。

```ruby
# lib/active_record/turntable/base.rb

def turntable(cluster_name, shard_key_name, options = {})
  # ...

  self.turntable_cluster =
    self.turntable_clusters[cluster_name] ||= Cluster.new(
                                                turntable_config[:clusters][cluster_name],
                                                options
                                              )
  turntable_replace_connection_pool
end

def turntable_replace_connection_pool
  ch = connection_handler
  cp = ConnectionProxy.new(self, turntable_cluster)
  pp = PoolProxy.new(cp)
  ch.class_to_pool.clear if defined?(ch.class_to_pool)
  ch.send(:class_to_pool)[name] = ch.send(:owner_to_pool)[name] = pp
end
```

[前回](/2015/11/19/activerecord-connection/)見たConnectionHandlerのowner_to_poolをConnectionProxyで置き換えている。PoolProxyはプール全体のコネクションに実行する必要のあるメソッドをproxyしている。

コネクションの確立方法はSwitchPoint等と同様に、Shard毎にActiveRecord::Baseを継承するダミークラスを作成してestablish_connectionするパターン。

```ruby
def get_or_set_connection_class
  if Connections.const_defined?(name.classify)
    klass = Connections.const_get(name.classify)
  else
    klass = Class.new(ActiveRecord::Base)
    Connections.const_set(name.classify, klass)
    klass.abstract_class = true
  end
  klass
end

def create_connection_class
  klass = get_or_set_connection_class
  klass.remove_connection
  klass.establish_connection ActiveRecord::Base.connection_pool.spec.config[:shards][name].with_indifferent_access
  klass
end
```

後は必要に応じてクラスを取り出してconnectionとconnection_poolを取得する。ただ、Turntableの場合は変更が大きすぎて確保済みのコネクションに対する処理などは自前で行う必要があるっぽいけど。


実際にコネクションを切り替える部分は

```ruby
# lib/active_record/turntable/connection_proxy.rb

def method_missing(method, *args, &block)
  clear_query_cache_if_needed(method)
  if shard_fixed?
    connection.send(method, *args, &block)
  elsif mixable?(method, *args)
    fader = @mixer.build_fader(method, *args, &block)
    logger.debug { "[ActiveRecord::Turntable] Sending method: #{method}, " +
      "sql: #{args.first}, " +
      "shards: #{fader.shards_query_hash.keys.map(&:name)}" }
    fader.execute
  else
    connection.send(method, *args, &block)
  end
end
```

となっている。`shard_fixed?`はOctopus.usingでShardを指定した時の様に、Shardが指定されていて判定する必要がない場合。通常のクエリなどで判定の必要がある場合には`@mixer.build_fader`でクエリから対象のShardを判定している。この中で引数のSQLを[wvanbergen/sql_tree](https://github.com/wvanbergen/sql_tree)を使ってSQLをパースして対象Shardを絞り込んでいる。大分マッチョだ。

## Other

その他にも、開発が止まってるものやReplication系の物も含めるといくつかライブラリはある。

* [taiki45/mixed_gauge](https://github.com/taiki45/mixed_gauge)
* [zendesk/active_record_shards](https://github.com/zendesk/active_record_shards)
* [mperham/data_fabric](https://github.com/mperham/data_fabric)
* [technoweenie/masochism](https://github.com/technoweenie/masochism)
* [r7kamura/replicat](https://github.com/r7kamura/replicat)
* [schoefmax/multi_db](https://github.com/schoefmax/multi_db)
* [mixonic/ShardTheLove](https://github.com/mixonic/ShardTheLove)

## Yet Another

クエリの実行だけに絞って見てきたが、実際には

* Relation
* Association
* Migration
* QueryCache
* インスタンスの処理
  * saveなどで呼ばれるtransactionのコネクション指定
* その他connection操作
  * clear_all_connections!
  * clear_active_connections!
  * etc.

などコネクションの差替え以外にも作りこまなければいけない部分が多い。が、基本的には上で見てきた切替えがベースとなる。

今私が作っているソーシャルゲームはRailsで書いていてDB ShardingはOctopusを使用しているんだけど、なかなか使いづらい所や不満もそこそこにはあったりする。もう直ってるけどコネクションプールを独自で管理してるのでコネクションがリクエストごとにロストしたりしてたこともある。また、他のDB系のライブラリ(annotate_modelsやdatabase_rewinderとか)が手を入れないとうまく動かない。都度パッチを投げても良いんだけど別の実装アイディアもあったりするので、最近プロトタイプ的な感じで1から新しく設計し始めている。

Sharding用のライブラリはザックリと「コネクションの管理」と「シャードの特定」の2つの要素に分解してそれぞれをコンパクトに実装するのが大切だと思っている。コネクションの管理は各シャードへのコネクション確立とModelがクエリを実行するコネクションの切替部分、シャードの特定はその上で実装されるShardingやReplicationのロジックのことを指している。今作ろうとしているものはコネクションの管理をメインに行うつもりだ。

特にコネクション管理をコンパクトに保つのはとても大切で、ActiveRecordの変更に追従するのは非常に困難であることはよく知られている。(実際に[kovyrin/db-charmer](https://github.com/kovyrin/db-charmer)の作者は[ギブアップ](http://kovyrin.net/2014/11/14/dbcharmer-suspended/)してしまった)コネクションの管理をうまく一般化・抽象化することができればそのGemが土台となって、ActiveRecordとの互換性を気にせず本当に作りたかった機能に注力出来て皆ハッピーみたいな事が出来ればとか考えていたりする。

まあ実際にやってみるとActiveRecordの設計から大きく外れないように設計し、更には内部のAPIなどを極力呼ばない様に作っていくの抜け道を探しているような、パズルをしているような間隔でそれはそれで楽しいものだ。一種の縛りプレイをやっているような感覚に近いかもしれない。

もう少し設計が固まってきたら、また纏めたいと思う。
