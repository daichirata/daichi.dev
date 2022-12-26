---
title: Kafka Consumer 0.9 の挙動
---

Apache Kafka 0.9.0より新しいConsumer実装が追加されました。Broker側の実装自体はv0.8.2で既に追加されていましたが、公式実装として`org.apache.kafka.clients.consumer.KafkaConsumer`が同梱されるようになりました。

新しいAPIを用いたConsumerはOffsetの管理とConsumerGroupに紐づくConsumerの管理をBroker側で行ってくれるようになります。詳細に関しては[Kafkaのwiki](https://cwiki.apache.org/confluence/display/KAFKA/Consumer+Client+Re-Design)に詳しくまとめられています。が、更新されていない資料が多く実際のフローと異なっている所が多いので、実装ベースで現在のConsumerのフローについて確認していきます。

![](/assets/images/posts/2016-02-15-kafka-consumer-0.9/diagram.png)

## 起動時の処理

### 1. Brokerのクラスタの、いずれか1つのサーバーへ接続を試みる。

起動時に渡されたBrokerの接続先の中から、ランダムに1つのサーバーを選んで接続を試みる。この段階ではどのBrokerに接続しても構わない。

#### 1.1. 接続を確立できた場合

トピックのメタデータを取得するリクエストを投げる。

[Topic Metadata Request](https://cwiki.apache.org/confluence/display/KAFKA/A+Guide+To+The+Kafka+Protocol#AGuideToTheKafkaProtocol-TopicMetadataRequest)

```
TopicMetadataRequest => [TopicName]
  TopicName => string
```

```
TopicMetadataResponse => [Broker][TopicMetadata]
  Broker => NodeId Host Port  (any number of brokers may be returned)
    NodeId => int32
    Host => string
    Port => int32
  TopicMetadata => TopicErrorCode TopicName [PartitionMetadata]
    TopicErrorCode => int16
  PartitionMetadata => PartitionErrorCode PartitionId Leader Replicas Isr
    PartitionErrorCode => int16
    PartitionId => int32
    Leader => int32
    Replicas => [int32]
    Isr => [int32]
```

このAPIでは主に、以下の情報を返す。

* Requestで指定したTopicは存在するか
* TopicにはどれくらいのPartitionが存在するのか
* TopicのPartitionのリーダーはどのBrokerか
* BrokerのHostとPort

Topicの指定がなければクラスタ上に存在する全てのTopic情報を返す。ここで取得した情報を保持しておき、以降のPartitionへの接続や各ConsumerのPartitoinの割当の計算で使用する。

#### 1.2. 接続できなかった場合

起動時に渡されたBrokerの接続先の中から、別のBrokerへ接続を試みる。

#### 1.3. 全てのBrokerに接続できなかった場合

1から処理を繰り返すか、そのまま終了する。

### 2. ConsumerGroupのCoordinatorを取得する

ConsumerGroupのOffsetとMemberを管理する特定のBrokerを、KafkaではCoordinatorと呼ぶ。以降、OffsetのFetchとCommitはこのBrokerに対して行う。

[Group Coordinator Request](https://cwiki.apache.org/confluence/display/KAFKA/A+Guide+To+The+Kafka+Protocol#AGuideToTheKafkaProtocol-GroupCoordinatorRequest)

```
GroupCoordinatorRequest => GroupId
  GroupId => string
```

```
GroupCoordinatorResponse => ErrorCode CoordinatorId CoordinatorHost CoordinatorPort
  ErrorCode => int16
  CoordinatorId => int32
  CoordinatorHost => string
  CoordinatorPort => int32
```

取得したCoordinatorが現在接続しているBrokerと異なる場合、Coordinatorに対して接続を試みる。

### 3. Coordinatorに対して、自身をConsumerとして登録する

[Join Group Request](https://cwiki.apache.org/confluence/display/KAFKA/A+Guide+To+The+Kafka+Protocol#AGuideToTheKafkaProtocol-JoinGroupRequest)

```
JoinGroupRequest => GroupId SessionTimeout MemberId ProtocolType GroupProtocols
  GroupId => string
  SessionTimeout => int32
  MemberId => string
  ProtocolType => string
  GroupProtocols => [ProtocolName ProtocolMetadata]
    ProtocolName => string
    ProtocolMetadata => bytes
```

```
JoinGroupResponse => ErrorCode GenerationId GroupProtocol LeaderId MemberId Members
  ErrorCode => int16
  GenerationId => int32
  GroupProtocol => string
  LeaderId => string
  MemberId => string
  Members => [MemberId MemberMetadata]
    MemberId => string
    MemberMetadata => bytes
```

MemberIdは、初回接続時には空で構わない。その場合はResponseで新しくMemberIdが生成される。この生成されたIdをRebalance等でConsumerが再接続する際に指定する。

GenerationIdは、新しいConsumerがJoinしてきた等でRebalanceが発生する毎に新しく採番される。Coordinatorは現在のGenerationIdと、そのIDが発行されているConsumer数を管理していて、そのIDに紐づく全てのConsumerがRequestを投げてくるまでResponseをブロックする。
そうすることで、次のAPIでPartitionの割当を行う際に有効なConsumerを確定させ、ResponseのMembersでその情報を返す。

初めてConsumerGroupに対してJoinしてきたConsumerをリーダーとして設定する。Partitionの割当はリーダーだけがこの後のSyncGroup APIで行う。

### 4. ConsumerGroup全体のPartitionの割当情報を同期する

[SyncGroup Request](https://cwiki.apache.org/confluence/display/KAFKA/A+Guide+To+The+Kafka+Protocol#AGuideToTheKafkaProtocol-SyncGroupRequest)

```
SyncGroupRequest => GroupId GenerationId MemberId GroupAssignment
  GroupId => string
  GenerationId => int32
  MemberId => string
  GroupAssignment => [MemberId MemberAssignment]
    MemberId => string
    MemberAssignment => bytes
```

```
SyncGroupResponse => ErrorCode MemberAssignment
  ErrorCode => int16
  MemberAssignment => bytes
```

このAPIは、リーダーかそうでないかで目的が異なる。

* リーダーの場合 -> Partitionの割当を行う。
  * TopicMetadataで取得したTopic/Partitionの情報と、JoinGroupで取得したメンバーの情報を元にPartitionの割当を行いGroupAssignmentに指定してRequestを投げる。

* その他の場合 -> Partitionの割当を取得する。
  * リーダーがRequestを投げてくるまでResponseがブロックされる。

これらの情報は先ほどのJoinGroupで発行されたGenerationIdで世代管理されており、Rebalanceが発生した場合には新規に生成と割当を行う必要がある。

Partitionの割当戦略に関してはライブラリの実装方法による。Broker側に割当戦略を移行する予定ではあるみたいだが、今のところ実装はされていない。(多分)

### 5. Coordinatorに対して、一定間隔でHeartbeatを投げる

[Heartbeat Request](https://cwiki.apache.org/confluence/display/KAFKA/A+Guide+To+The+Kafka+Protocol#AGuideToTheKafkaProtocol-HeartbeatRequest)

```
HeartbeatRequest => GroupId GenerationId MemberId
  GroupId => string
  GenerationId => int32
  MemberId => string
```

```
HeartbeatResponse => ErrorCode
  ErrorCode => int16
```

設定で指定している時間にheartbeatのRequestが無ければ、そのConsumerはkickの扱いになる。
誰かがkickされた後、その他のConsumerのheartbeatでREBALANCE_IN_PROGRESSのエラーが返り、それを契機にRebalanceの処理が実行される。

### 6. 担当するPartitionのOffsetを取得する

[Offset Fetch Request](https://cwiki.apache.org/confluence/display/KAFKA/A+Guide+To+The+Kafka+Protocol#AGuideToTheKafkaProtocol-OffsetFetchRequest)

```
OffsetFetchRequest => ConsumerGroup [TopicName [Partition]]
  ConsumerGroup => string
  TopicName => string
  Partition => int32
```

```
OffsetFetchResponse => [TopicName [Partition Offset Metadata ErrorCode]]
  TopicName => string
  Partition => int32
  Offset => int64
  Metadata => string
  ErrorCode => int16
```

### 7. Offset情報を元にメッセージを取得する

[Fetch Request](https://cwiki.apache.org/confluence/display/KAFKA/A+Guide+To+The+Kafka+Protocol#AGuideToTheKafkaProtocol-FetchRequest)

```
FetchRequest => ReplicaId MaxWaitTime MinBytes [TopicName [Partition FetchOffset MaxBytes]]
  ReplicaId => int32
  MaxWaitTime => int32
  MinBytes => int32
  TopicName => string
  Partition => int32
  FetchOffset => int64
  MaxBytes => int32
```

```
FetchResponse => [TopicName [Partition ErrorCode HighwaterMarkOffset MessageSetSize MessageSet]]
  TopicName => string
  Partition => int32
  ErrorCode => int16
  HighwaterMarkOffset => int64
  MessageSetSize => int32
```

## おわり

まだまだ各言語のライブラリの対応状況がマチマチなので簡単には使えない状態です。只、これまでのConsumerはそれぞれの言語でJavaクライアントに沿って、Zookeeperに同じような構造でデータを保存して、挙動を合わせるみたいな流れだったので、ある程度Broker側に処理が移行するのはJava以外のConsumerクライアントを書いている側からすると大分書きやすくなりそうです。
