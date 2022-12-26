---
title: ElasticsearchとGCPのTCP Keepaliveではまった話
---

今回はGCP上にElasticsearchクラスタを組もうとしてはまった話をします。ちゃんとドキュメント読めと言われればそこまでなんだけど、ミドルウェアが間に入ってて気づくのに遅れてしまった…。

## TL;DR

GCEのファイヤーウォールはinactiveコネクションを10分で切断するので、Elasticsearchのクラスタを構築する場合はnet.ipv4.tcp_keepalive_timeの設定を変える必要があるよ。

## 安定しないクラスタ

事の発端はGCEインスタンスで構築していたElasticsearchのクラスタが、一定間隔でノード間の疎通に失敗して切断・再接続を繰り返していました。

* OS: CentOS 7.2
* Elasticsearch: 2.3.1

{% raw %}
```
[INFO ][discovery.gce              ] [elasticsearch-1] master_left [{elasticsearch-2}{4TPArCtHQMKgWaLod3ZMjA}{10.2.101.5}{10.2.101.5:9300}], reason [failed to ping, tried [3] times, each with  maximum [30s] timeout]
[WARN ][discovery.gce              ] [elasticsearch-1] master left (reason = failed to ping, tried [3] times, each with  maximum [30s] timeout), current nodes: {{elasticsearch-3}{JtcxuuucRXiClrl6q7qL8A}{10.2.101.5}{10.2.101.5:9300},{elasticsearch-1}{RQvtZKAJTfGmbmWETYY0fw}{10.2.101.4}{elasticsearch-1.c.cyberagent-013.internal/10.2.101.4:9300},}
[INFO ][cluster.service            ] [elasticsearch-1] removed {{elasticsearch-2}{4TPArCtHQMKgWaLod3ZMjA}{10.2.101.5}{10.2.101.5:9300},}, reason: zen-disco-master_failed ({elasticsearch-2}{4TPArCtHQMKgWaLod3ZMjA}{10.2.101.5}{10.2.101.5:9300})
[DEBUG][action.admin.cluster.health] [elasticsearch-1] connection exception while trying to forward request with action name [cluster:monitor/health] to master node [{elasticsearch-2}{4TPArCtHQMKgWaLod3ZMjA}{10.2.101.5}{10.2.101.5:9300}], scheduling a retry. Error: [org.elasticsearch.transport.NodeDisconnectedException: [elasticsearch-2][10.2.101.5:9300][cluster:monitor/health] disconnected]
```
{% endraw %}

最初はエラーメッセージから、負荷やGCなどでノード間のpingがtime outしているのかと思いその辺の設定を変えて様子を見てみました。

[Zen Discovery](https://www.elastic.co/guide/en/elasticsearch/reference/current/modules-discovery-zen.html)

```yaml
discovery.zen.fd.ping_timeout: 60s
discovery.zen.fd.ping_retries: 6
```

これで解決すればよかったんですが、設定を変えてみても状況は一向に変わらず、GCなども発生している様子がなかったので本格的に調査します。

Elasticsearchのクラスタ内部のノード間通信には[Transport module](https://www.elastic.co/guide/en/elasticsearch/reference/current/modules-transport.html)が使用されていて、Nettyを使って非同期に通信しています。まず初めに、このTransport周りのログをTRACEレベルまで出力するように変更します。

```shell
curl -XPUT localhost:9200/_cluster/settings -d '
{
  "transient" : {
    "logger.transport" : "TRACE",
    "logger.org.elasticsearch.transport" : "TRACE"
  }
}'
```

その上でログを見てみると、どうもネットワークレイヤでそもそも接続できていない様なログが出力されていました。

{% raw %}
```
[2016-04-27 16:07:43,207][TRACE][transport.netty          ] [elasticsearch-1] close connection exception caught on transport layer [[id: 0xa2b52d5c, /10.2.101.4:40290 => /10.2.101.5:9300]], disconnecting from relevant node
java.io.IOException: Connection timed out
        at sun.nio.ch.FileDispatcherImpl.read0(Native Method)
        at sun.nio.ch.SocketDispatcher.read(SocketDispatcher.java:39)
        at sun.nio.ch.IOUtil.readIntoNativeBuffer(IOUtil.java:223)
        at sun.nio.ch.IOUtil.read(IOUtil.java:192)
        at sun.nio.ch.SocketChannelImpl.read(SocketChannelImpl.java:380)
        at org.jboss.netty.channel.socket.nio.NioWorker.read(NioWorker.java:64)
        at org.jboss.netty.channel.socket.nio.AbstractNioWorker.process(AbstractNioWorker.java:108)
        at org.jboss.netty.channel.socket.nio.AbstractNioSelector.run(AbstractNioSelector.java:337)
        at org.jboss.netty.channel.socket.nio.AbstractNioWorker.run(AbstractNioWorker.java:89)
        at org.jboss.netty.channel.socket.nio.NioWorker.run(NioWorker.java:178)
        at org.jboss.netty.util.ThreadRenamingRunnable.run(ThreadRenamingRunnable.java:108)
        at org.jboss.netty.util.internal.DeadLockProofWorker$1.run(DeadLockProofWorker.java:42)
        at java.util.concurrent.ThreadPoolExecutor.runWorker(ThreadPoolExecutor.java:1142)
        at java.util.concurrent.ThreadPoolExecutor$Worker.run(ThreadPoolExecutor.java:617)
        at java.lang.Thread.run(Thread.java:745)
```
{% endraw %}

後、先程は気づいてなかったんですがtransportで切断されているログも出力されていました。

{% raw %}
```
[INFO][discovery.gce  ] [elasticsearch-1] master_left [{elasticsearch-2}{Xa2Cq98mQie1WcaXFfHraQ}{10.2.101.5}{10.2.101.5:9300}], reason [transport disconnected]
[WARN][discovery.gce  ] [elasticsearch-1] master left (reason = transport disconnected), current nodes: {{elasticsearch-1}{fjLqVUoxRB6RRNCecJSAaw}{10.2.101.4}{10.2.101.4:9300},}
[INFO][cluster.service] [elasticsearch-1] removed {{elasticsearch-2}{Xa2Cq98mQie1WcaXFfHraQ}{10.2.101.5}{10.2.101.5:9300},}, reason: zen-disco-master_failed ({elasticsearch-2}{Xa2Cq98mQie1WcaXFfHraQ}{10.2.101.16}{10.2.101.16:9300})
```
{% endraw %}

対象のノード間でpingコマンドを実行したまま様子を見てみたんですが、特にネットワークが切れてるようでは無かったのでノード間のtcp接続を確認してみます。

* ノード 1

```sh
$ netstat --tcp -t -o -n | grep 9300 | sort -k5
tcp6       0      0 10.2.101.4:9300         10.2.101.5:37638        ESTABLISHED keepalive (4107.47/0/1) 
tcp6       0      0 10.2.101.4:9300         10.2.101.5:37637        ESTABLISHED keepalive (4107.47/0/1) 
tcp6       0      0 10.2.101.4:9300         10.2.101.5:37636        ESTABLISHED keepalive (4107.47/0/1) 
tcp6       0      0 10.2.101.4:9300         10.2.101.5:37635        ESTABLISHED keepalive (4107.47/0/1) 
tcp6       0      0 10.2.101.4:9300         10.2.101.5:37634        ESTABLISHED keepalive (4107.47/0/1) 
tcp6       0      0 10.2.101.4:9300         10.2.101.5:37633        ESTABLISHED keepalive (5221.58/0/0) 
tcp6       0      0 10.2.101.4:9300         10.2.101.5:37632        ESTABLISHED keepalive (5172.43/0/0) 
tcp6       0      0 10.2.101.4:9300         10.2.101.5:37631        ESTABLISHED keepalive (5172.43/0/0) 
tcp6       0      0 10.2.101.4:9300         10.2.101.5:37630        ESTABLISHED keepalive (5188.81/0/0) 
tcp6       0      0 10.2.101.4:9300         10.2.101.5:37629        ESTABLISHED keepalive (5188.82/0/0) 
tcp6       0      0 10.2.101.4:9300         10.2.101.5:37628        ESTABLISHED keepalive (5221.58/0/0) 
tcp6       0      0 10.2.101.4:9300         10.2.101.5:37627        ESTABLISHED keepalive (4205.77/0/0) 
tcp6       0      0 10.2.101.4:9300         10.2.101.5:37626        ESTABLISHED keepalive (5319.89/0/0) 
tcp6       0      0 10.2.101.4:42254        10.2.101.5:9300         ESTABLISHED keepalive (4107.47/0/1) 
tcp6       0      0 10.2.101.4:42253        10.2.101.5:9300         ESTABLISHED keepalive (4107.47/0/1) 
tcp6       0      0 10.2.101.4:42252        10.2.101.5:9300         ESTABLISHED keepalive (4107.47/0/1) 
tcp6       0      0 10.2.101.4:42251        10.2.101.5:9300         ESTABLISHED keepalive (4107.47/0/1) 
tcp6       0      0 10.2.101.4:42250        10.2.101.5:9300         ESTABLISHED keepalive (4107.47/0/1) 
tcp6       0      0 10.2.101.4:42249        10.2.101.5:9300         ESTABLISHED keepalive (4107.47/0/1) 
tcp6       0      0 10.2.101.4:42248        10.2.101.5:9300         ESTABLISHED keepalive (5319.89/0/0) 
tcp6       0      0 10.2.101.4:42247        10.2.101.5:9300         ESTABLISHED keepalive (5319.89/0/0) 
tcp6       0      0 10.2.101.4:42246        10.2.101.5:9300         ESTABLISHED keepalive (5319.89/0/0) 
tcp6       0      0 10.2.101.4:42245        10.2.101.5:9300         ESTABLISHED keepalive (5319.89/0/0) 
tcp6       0      0 10.2.101.4:42244        10.2.101.5:9300         ESTABLISHED keepalive (5319.89/0/0) 
tcp6       0      0 10.2.101.4:42243        10.2.101.5:9300         ESTABLISHED keepalive (5319.89/0/0) 
tcp6       0      0 10.2.101.4:42242        10.2.101.5:9300         ESTABLISHED keepalive (5319.89/0/0) 
```

* ノード 2

```sh
$ netstat --tcp -t -o -n | grep 9300 | sort -k5
tcp6       0      0 10.2.101.5:9300         10.2.101.4:42254        ESTABLISHED keepalive (4107.47/0/1)
tcp6       0      0 10.2.101.5:9300         10.2.101.4:42253        ESTABLISHED keepalive (4107.47/0/1)
tcp6       0      0 10.2.101.5:9300         10.2.101.4:42252        ESTABLISHED keepalive (4107.47/0/1)
tcp6       0      0 10.2.101.5:9300         10.2.101.4:42251        ESTABLISHED keepalive (4107.47/0/1)
tcp6       0      0 10.2.101.5:9300         10.2.101.4:42250        ESTABLISHED keepalive (4107.47/0/1)
tcp6       0      0 10.2.101.5:9300         10.2.101.4:42249        ESTABLISHED keepalive (5221.58/0/0)
tcp6       0      0 10.2.101.5:9300         10.2.101.4:42248        ESTABLISHED keepalive (5172.43/0/0)
tcp6       0      0 10.2.101.5:9300         10.2.101.4:42247        ESTABLISHED keepalive (5172.43/0/0)
tcp6       0      0 10.2.101.5:9300         10.2.101.4:42246        ESTABLISHED keepalive (5188.81/0/0)
tcp6       0      0 10.2.101.5:9300         10.2.101.4:42245        ESTABLISHED keepalive (5188.82/0/0)
tcp6       0      0 10.2.101.5:9300         10.2.101.4:42244        ESTABLISHED keepalive (5221.58/0/0)
tcp6       0      0 10.2.101.5:9300         10.2.101.4:42243        ESTABLISHED keepalive (4205.77/0/0)
tcp6       0      0 10.2.101.5:9300         10.2.101.4:42242        ESTABLISHED keepalive (5319.89/0/0)
tcp6       0      0 10.2.101.5:37638        10.2.101.4:9300         ESTABLISHED keepalive (4107.47/0/1)
tcp6       0      0 10.2.101.5:37637        10.2.101.4:9300         ESTABLISHED keepalive (4107.47/0/1)
tcp6       0      0 10.2.101.5:37636        10.2.101.4:9300         ESTABLISHED keepalive (4107.47/0/1)
tcp6       0      0 10.2.101.5:37635        10.2.101.4:9300         ESTABLISHED keepalive (4107.47/0/1)
tcp6       0      0 10.2.101.5:37634        10.2.101.4:9300         ESTABLISHED keepalive (4107.47/0/1)
tcp6       0      0 10.2.101.5:37633        10.2.101.4:9300         ESTABLISHED keepalive (4107.47/0/1)
tcp6       0      0 10.2.101.5:37632        10.2.101.4:9300         ESTABLISHED keepalive (5319.89/0/0)
tcp6       0      0 10.2.101.5:37631        10.2.101.4:9300         ESTABLISHED keepalive (5319.89/0/0)
tcp6       0      0 10.2.101.5:37630        10.2.101.4:9300         ESTABLISHED keepalive (5319.89/0/0)
tcp6       0      0 10.2.101.5:37629        10.2.101.4:9300         ESTABLISHED keepalive (5319.89/0/0)
tcp6       0      0 10.2.101.5:37628        10.2.101.4:9300         ESTABLISHED keepalive (5319.89/0/0)
tcp6       0      0 10.2.101.5:37627        10.2.101.4:9300         ESTABLISHED keepalive (5319.89/0/0)
tcp6       0      0 10.2.101.5:37626        10.2.101.4:9300         ESTABLISHED keepalive (5319.89/0/0)
```

これを見てみると、Elasticsearchはノード間で互いに13本のコネクションを作成していることがわかります。このままwatchコマンドで定期的に監視していると、どうやら一部のコネクションでTCP Keepaliveのprobe packetのやり取りに失敗していて、それが原因でノード間のコネクションがクローズされている事がわかりました。

そもそもTCP Keepaliveのprobe packetは無通信だった場合にのみ送信されるはずだし、一部のコネクションのみやり取りに失敗している原因が良くわかりません。とりあえずカーネルのデフォルト設定だとprobe packetを送り始めるのが2時間後で確認が非常に辛いので、カーネルパラメータを変更して間隔を短くしてみます。

```sh
$ sysctl -w \
net.ipv4.tcp_keepalive_time=100 \
net.ipv4.tcp_keepalive_intvl=60 \
net.ipv4.tcp_keepalive_probes=3
```

その状態で様子を見てみると、なんと今度は問題が発生せずElasticsearchのクラスタも安定して動作するようになりました。GCEのネットワーク仕様的に切断されていそうな挙動だったので調べて見ると、しっかりドキュメントに書かれてました。がーん。

## Networks and Firewalls

[Using Networks and Firewalls - Compute Engine — Google Cloud Platform](https://cloud.google.com/compute/docs/networking#networks)  
[Tips, Troubleshooting, & Known Issues - Compute Engine — Google Cloud Platform](https://cloud.google.com/compute/docs/troubleshooting)

GCEのネットワークはインスタンス間の通信であっても、L2ではなく必ずゲートウェイを経由するL3で通信します。そして各インスタンスに対して許可するINBOUNDトラフィックをファイヤーウォールで管理、設定していて、このファイヤーウォールがinactiveなTCPコネクションを10分で切断します。なので、コネクションを維持したい場合は下記設定が推奨されています。

```
sudo /sbin/sysctl -w net.ipv4.tcp_keepalive_time=60 net.ipv4.tcp_keepalive_intvl=60 net.ipv4.tcp_keepalive_probes=5
```

ソース読んでないので適当ですが、多分Elasticsearchはノード間で13本コネクションを作成した後コネクションをプールしていて、使われないコネクションが幾つか存在するのかもしれません。そのコネクションがファイアーウォールに切断され、TCP Keepaliveで検知されるタイミングでノード間の接続が切れたとElasticsearchが検知して、クラスタから切断されるっていうのが今回の内容でした。

## おわり

最初はElasticsearch側の問題だと思っていろいろ設定をみたり、GithubのIssueとかを漁っていて結構気づくのに時間がかかってしまいました。最近はGCPでシステムを構成することも大分多くなってきたと思いますが、他のシステムでも似たような事がおきる可能性は十分にあると思うので、頭の片隅にとどめておいたほうが良さそうです。

