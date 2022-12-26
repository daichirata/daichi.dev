---
title: passengerがaptでインストール出来ない
---

Ubuntu14.04でpassengerをインストールしようとしたらエラーが出た。

```sh
vagrant@vagrant-ubuntu-trusty-64:~$ sudo apt-get install -y nginx-extras passenger
Reading package lists... Done
Building dependency tree
Reading state information... Done
The following extra packages will be installed:
  fontconfig-config fonts-dejavu-core libfontconfig1 libgd3 libjbig0
  libjpeg-turbo8 libjpeg8 liblua5.1-0 libperl5.18 libtiff5 libvpx1
  nginx-common passenger-dev passenger-doc
Suggested packages:
  libgd-tools fcgiwrap nginx-doc ssl-cert
The following NEW packages will be installed:
  fontconfig-config fonts-dejavu-core libfontconfig1 libgd3 libjbig0
  libjpeg-turbo8 libjpeg8 liblua5.1-0 libperl5.18 libtiff5 libvpx1
  nginx-common nginx-extras passenger passenger-dev passenger-doc
0 upgraded, 16 newly installed, 0 to remove and 2 not upgraded.
Need to get 6,695 kB/8,970 kB of archives.
After this operation, 52.3 MB of additional disk space will be used.
Get:1 https://oss-binaries.phusionpassenger.com/apt/passenger/ trusty/main nginx-common all 1:1.6.3-8.5.0.8~trusty1 [36.3 kB]
Err https://oss-binaries.phusionpassenger.com/apt/passenger/ trusty/main nginx-common all 1:1.6.3-8.5.0.8~trusty1
  HttpError500
Err https://oss-binaries.phusionpassenger.com/apt/passenger/ trusty/main passenger amd64 1:5.0.8-1~trusty1
  HttpError500
Err https://oss-binaries.phusionpassenger.com/apt/passenger/ trusty/main passenger-dev amd64 1:5.0.8-1~trusty1
  HttpError500
Err https://oss-binaries.phusionpassenger.com/apt/passenger/ trusty/main passenger-doc all 1:5.0.8-1~trusty1
  HttpError500
Err https://oss-binaries.phusionpassenger.com/apt/passenger/ trusty/main nginx-extras amd64 1:1.6.3-8.5.0.8~trusty1
  HttpError500
E: Failed to fetch https://oss-binaries.phusionpassenger.com/apt/passenger/pool/trusty/main/n/nginx/nginx-common_1.6.3-8.5.0.8~trusty1_all.deb  HttpError500

E: Failed to fetch https://oss-binaries.phusionpassenger.com/apt/passenger/pool/trusty/main/p/passenger/passenger_5.0.8-1~trusty1_amd64.deb  HttpError500

E: Failed to fetch https://oss-binaries.phusionpassenger.com/apt/passenger/pool/trusty/main/p/passenger/passenger-dev_5.0.8-1~trusty1_amd64.deb  HttpError500

E: Failed to fetch https://oss-binaries.phusionpassenger.com/apt/passenger/pool/trusty/main/p/passenger/passenger-doc_5.0.8-1~trusty1_all.deb  HttpError500

E: Failed to fetch https://oss-binaries.phusionpassenger.com/apt/passenger/pool/trusty/main/n/nginx/nginx-extras_1.6.3-8.5.0.8~trusty1_amd64.deb  HttpError500

E: Unable to fetch some archives, maybe run apt-get update or try with --fix-missing?
```

[passenger5の公開に伴ってリポジトリが変わった](https://blog.phusion.nl/2015/03/08/passenger-4-apt-repository-now-available/)らしい。が、公式のドキュメントも変更されてないし既存の広く使われているリポジトリに対するこういう変更は辛みしか無いんじゃないだろうか。OSS版はsource.listに

```
deb https://oss-binaries.phusionpassenger.com/apt/passenger/4 <CODENAME> main
```

を指定すれば良いとのこと。
