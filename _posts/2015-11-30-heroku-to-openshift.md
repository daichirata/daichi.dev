---
title: ブログをHerokuからOpenShiftに移行する
---

![](/assets/images/posts/2015-11-30-heroku-to-openshift/top.png)

Herokuを無料で使い続けることが難しくなってしまい、[以前のブログ](http://a-newcomer.com)(Sinatra/[Lokka](https://github.com/lokka/lokka))はどこかに移行しておきたいと思い色々検討した。

意外とHerokuの様に使えるPassがなくて、低スペックとはいえ無料で無制限にっていうのは色々と難しい所あったのかなーとか思いつつもとりあえず、ブログだけ移行できればよかったので3つのアプリまでは無料で動かすことが出来て、Herokuライクに使えそうな[OpenShift Online](https://www.openshift.com)に移行してみた。
Onlineの方はDockerを使ったOpenShift v3ではなくGearとかCartridgeの奴。

## rhc

WebConsoleも不自由しないくらいには作りこまれているが[OpenShift Developers](https://developers.openshift.com)が全て[rhc](https://github.com/openshift/rhc)コマンドなので、先ずはrhcをインストールする。大体herokuコマンドのような物だと思えば良い。

```sh
$ gem install rhc
```

ちなみに、OpenShift Developersは結構細かくドキュメントが記載されていて正直ここを見ながらやるだけで特に移行に困ることはなかったの結構良かった。

次に、rhcのセットアップを行う。

```sh
$ rhc setup
```

聞かれたとおりに登録メールアドレスやパスワードを入力していく。初めのほうで

```
If you have your own OpenShift server, you can specify it now. Just hit enter to use the server for OpenShift Online: openshift.redhat.com.
Enter the server hostname: |openshift.redhat.com|
```

と聞かれるかもしれないが、今回はOpenShift OnlineなのでそのままEnterで問題ない。

```
Please enter a namespace (letters and numbers only) |<none>|:
```

の部分に関してはユーザーごとのnamespaceを自分で決めることが出来てそれがドメインの一部になる。
私はdaichをnamespaceにしたのでアプリは http://xxxx-daich.rhcloud.com というFQDNが割り当てられることになる。

## Application

今のところ作成可能なアプリケーションは以下のとおり。

```
Do-It-Yourself 0.1                      rhc create-app <app name> diy-0.1
JBoss Application Server 7              rhc create-app <app name> jbossas-7
JBoss Data Virtualization 6             rhc create-app <app name> jboss-dv-6.1.0
JBoss Enterprise Application Platform 6 rhc create-app <app name> jbosseap-6
JBoss Unified Push Server 1.0.0.Beta1   rhc create-app <app name> jboss-unified-push-1
JBoss Unified Push Server 1.0.0.Beta2   rhc create-app <app name> jboss-unified-push-2
Jenkins Server                          rhc create-app <app name> jenkins-1
Node.js 0.10                            rhc create-app <app name> nodejs-0.10
PHP 5.3                                 rhc create-app <app name> php-5.3
PHP 5.4                                 rhc create-app <app name> php-5.4
PHP 5.4 with Zend Server 6.1            rhc create-app <app name> zend-6.1
Perl 5.10                               rhc create-app <app name> perl-5.10
Python 2.6                              rhc create-app <app name> python-2.6
Python 2.7                              rhc create-app <app name> python-2.7
Python 3.3                              rhc create-app <app name> python-3.3
Ruby 1.8                                rhc create-app <app name> ruby-1.8
Ruby 1.9                                rhc create-app <app name> ruby-1.9
Ruby 2.0                                rhc create-app <app name> ruby-2.0
Tomcat 6 (JBoss EWS 1.0)                rhc create-app <app name> jbossews-1.0
Tomcat 7 (JBoss EWS 2.0)                rhc create-app <app name> jbossews-2.0
Vert.x 2.1                              rhc create-app <app name> jboss-vertx-2.1
WildFly Application Server 10           rhc create-app <app name> jboss-wildfly-10
WildFly Application Server 8.2.1.Final  rhc create-app <app name> jboss-wildfly-8
WildFly Application Server 9            rhc create-app <app name> jboss-wildfly-9
```

Sinatraを動かしたいのでRuby 2.0を使用する。

```sh
$ rhc app create anewcomer ruby-2.0

Application Options
-------------------
Domain:     daich
Cartridges: ruby-2.0
Gear Size:  default
Scaling:    no

Creating application 'anewcomer' ... done

Waiting for your DNS name to be available ... done

Cloning into 'anewcomer'...
Warning: Permanently added the RSA host key for IP address 'xxx.xxx.xxx.xxx' to the list of known hosts.

Your application 'anewcomer' is now available.

  URL:        http://anewcomer-daich.rhcloud.com/
  SSH to:     xxxx
  Git remote: xxxxx
  Cloned to:  /path/to/dir/anewcomer

Run 'rhc show-app anewcomer' for more details about your app.
```

後は出力されたGit remoteにpushするだけで良い。

## Database

今のところ追加出来るCartridgeは以下のとおり。

```sh
$ rhc cartridge list

jbossas-7                JBoss Application Server 7              web
jboss-dv-6.1.0 (!)       JBoss Data Virtualization 6             web
jbosseap-6 (*)           JBoss Enterprise Application Platform 6 web
jboss-unified-push-1 (!) JBoss Unified Push Server 1.0.0.Beta1   web
jboss-unified-push-2 (!) JBoss Unified Push Server 1.0.0.Beta2   web
jenkins-1                Jenkins Server                          web
nodejs-0.10              Node.js 0.10                            web
perl-5.10                Perl 5.10                               web
php-5.3                  PHP 5.3                                 web
php-5.4                  PHP 5.4                                 web
zend-6.1                 PHP 5.4 with Zend Server 6.1            web
python-2.6               Python 2.6                              web
python-2.7               Python 2.7                              web
python-3.3               Python 3.3                              web
ruby-1.8                 Ruby 1.8                                web
ruby-1.9                 Ruby 1.9                                web
ruby-2.0                 Ruby 2.0                                web
jbossews-1.0             Tomcat 6 (JBoss EWS 1.0)                web
jbossews-2.0             Tomcat 7 (JBoss EWS 2.0)                web
jboss-vertx-2.1 (!)      Vert.x 2.1                              web
jboss-wildfly-10 (!)     WildFly Application Server 10           web
jboss-wildfly-8 (!)      WildFly Application Server 8.2.1.Final  web
jboss-wildfly-9 (!)      WildFly Application Server 9            web
diy-0.1                  Do-It-Yourself 0.1                      web
cron-1.4                 Cron 1.4                                addon
jenkins-client-1         Jenkins Client                          addon
mongodb-2.4              MongoDB 2.4                             addon
mysql-5.1                MySQL 5.1                               addon
mysql-5.5                MySQL 5.5                               addon
phpmyadmin-4             phpMyAdmin 4.0                          addon
postgresql-8.4           PostgreSQL 8.4                          addon
postgresql-9.2           PostgreSQL 9.2                          addon
rockmongo-1.1            RockMongo 1.1                           addon
switchyard-0             SwitchYard 0.8.0                        addon
haproxy-1.4              Web Load Balancer                       addon

Note: Web cartridges can only be added to new applications.

(*) denotes a cartridge with additional usage costs.

(!) denotes a cartridge that will not receive automatic security updates.
```

Herokuではデフォルトのまま使用していたのでPostgreSQLだったが今回はMySQL5.5を使用する。

```sh
$ rhc cartridge add mysql-5.5mysql-5.5 --app anewcomer

Adding mysql-5.5 to application 'anewcomer' ... done

mysql-5.5 (MySQL 5.5)
---------------------
  Gears:          Located with ruby-2.0
  Connection URL: mysql://$OPENSHIFT_MYSQL_DB_HOST:$OPENSHIFT_MYSQL_DB_PORT/
  Database Name:  xxxx
  Password:       xxxx
  Username:       xxxx

MySQL 5.5 database added.  Please make note of these credentials:

       Root User: xxxx
   Root Password: xxxx
   Database Name: xxxx

Connection URL: mysql://$OPENSHIFT_MYSQL_DB_HOST:$OPENSHIFT_MYSQL_DB_PORT/

You can manage your new MySQL database by also embedding phpmyadmin.
The phpmyadmin username and password will be the same as the MySQL credentials above.
```

UserやPasswordが出力されているが、基本的にDBの情報は全て環境変数として提供されているのでそこからアクセスする。
[MySQL on OpenShift](https://developers.openshift.com/en/databases-mysql.html)

## Heroku to OpenShift

アプリケーションを作成した際に出来た初期リポジトリをクローンしてきて、中にある`.openshift`ディレクトリをherokuにDeployしているアプリにコピーしておく。
その後openshiftをremoteとして追加してpushする。内部ではPassengerが動いていてRackベースのアプリはconfig.ruを元に起動する。

```
# Template Repository Layout
tmp/               Temporary storage
public/            Content (images, CSS, etc. available to the public)
config.ru          This file is used by Rack-based servers to start the application.
.openshift/        Location for OpenShift specific files
    action_hooks/  See the Action Hooks documentation
    markers/       See the Markers section below
```

次にOpenShiftで動かすために変更した部分。

database.yml

```yaml
production:
  dsn: <%= "#{ENV['OPENSHIFT_MYSQL_DB_URL']}/#{ENV['OPENSHIFT_APP_NAME']}" %>
```

Gemfile

```ruby
# RubyGemsミラーがOpenShift内部にあってこっちのほうが早い
# https://developers.openshift.com/en/ruby-getting-started.html#_ruby_mirror
source 'http://mirror.ops.rhcloud.com/mirror/ruby/'

# 1.5.2でなければ動かない
gem 'rack', '1.5.2'
```

config.ru

```ruby
# default_externalを直接指定しておかないとうまく動かない所がある。
# Railsを参考にしたけどこの辺のベストプラクティスよくわかってない。
Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8
```

次に環境変数を設定する。人によっては不要かもしれない。

```sh
$ rhc env set RACK_ENV=production BUNDLE_WITHOUT=development:test:postgresql -a anewcomer
```

最後に、Passengerのhot deployに対応させておく。

```sh
$ touch .openshift/markers/hot_deploy
```

.openshiftにはこういう設定や、DeployやStart等のActionHookを置いてくことになる。

取り敢えずここで一旦remoteにpushしたらデプロイが実行されると思うので、
その後sshで接続してrakeタスクを実行してDBをセットアップして動作確認を行う。

```sh
$ rhc app ssh anewcomer

# $OPENSHIFT_REPO_DIRにデプロイされたアプリケーションのPathがセットされてる
> cd $OPENSHIFT_REPO_DIR
> bundle exec rake db:setup RACK_ENV=production
```

特に問題がなければこれで一旦初期状態のアプリが表示されていると思う。

## Data Migration

データの移行には[taps](https://github.com/ricardochimal/taps)を使う。

```sh
$ gem i taps sqlite3 mysql pg
```

herokuはDBへのエンドポイントがあったがOpenShiftには多分無い。
接続したい場合にはrhcにport-forwardを行うコマンドがあるのでそれで一時的に接続できるようにする。

```sh
$ rhc port-forward anewcomer

Checking available ports ... done
Forwarding ports ...

To connect to a service running on OpenShift, use the Local address

Service Local                OpenShift
------- --------------- ---- ------------------
httpd   127.0.0.1:8080   =>  xx.xx.xx.xx:8080
mysql   127.0.0.1:3306   =>  xx.xx.xx.xx:3306
ruby    127.0.0.1:26226  =>  xx.xx.xx.xx:26226

Press CTRL-C to terminate port forwarding
```

別ターミナルでtapsのサーバーを立てる。

```sh
taps server 'mysql://username:password@127.0.0.1:3306/app_name?encoding=utf8' tapsuser tapspass
```

MySQLの接続情報は作成時に表示さていた情報。わからない場合はsshしてechoするかWebConsoleで確認できるかも。

あとはHerokuのPostgreSQLからpushする。

```sh
taps push 'postgres://username:password@xxx.xxx.xxx.xxx.compute-1.amazonaws.com:5432/dbname' http://tapsuser:tapspass@localhost:5000
```

これだけで異なるミドルウェア・PaaS間でのデータ移行が済んでしまうtapsは最高に便利。

## Naked Domain

OpenShiftもHerokuと同じようにCNAMEでのカスタムドメイン設定しか出来ないので、aliasだけ設定しておく

```
$ rhc alias add anewcomer a-newcomer.com
```

あとはapex alias等の参照先を、最初に付与されたFQDN(anewcomer-daich.rhcloud.comとか)に設定すれば転送されるはず。

## Action Hook

最後に、pushするたびに自動的にmigrationを実行させたいので実行権限付きのファイルを.openshift/action_hooks/deployに置く。

```bash
#!/bin/bash

echo "Starting deploy script"
cd $OPENSHIFT_REPO_DIR

bundle exec rake db:migrate RACK_ENV="production"
```

他にも色々なActionが用意されてるので大抵のことはカバーできそう。

## 終わり

結構調べながらやってたんだけどそこそこスムーズに移行できてよかった。
OpenShiftも個人でブログを動かすくらいにしか使っていない分の使い勝手は全く問題ないと思う。

ただ、ブログに対してアプリケーションを動かすこと自体がちょっとめんどくさくなってしまって今はGithub Pages + Jekyllで運用しているんだけど、こうやってちょっと頑張って移行した手前そのうち向こうのブログにも何か書いていきたい。
