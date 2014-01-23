FROM ubuntu
RUN add-apt-repository ppa:brightbox/ruby-ng-experimental
RUN apt-get update
RUN apt-get -q -y install mysql-server mysql-client curl ruby2.0 ruby2.0-dev rubygems vim
RUN gem install json
RUN curl -L https://github.com/coreos/etcd/releases/download/v0.2.0/etcd-v0.2.0-Linux-x86_64.tar.gz > etcd-v0.2.0-Linux-x86_64.tar.gz
RUN tar -zxvf etcd-v0.2.0-Linux-x86_64.tar.gz
RUN mv etcd-v0.2.0-Linux-x86_64/etcdctl /usr/bin/etcdctl
ADD . /usr/scripts
#RUN /usr/scripts/bootstrap.rb