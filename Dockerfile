FROM ubuntu
RUN apt-get update
RUN apt-get -q -y install mysql-server mysql-client curl vim git-core wget libssl1.0.0 python-yaml build-essential libssl-dev
 
# Install ruby-build
RUN git clone https://github.com/sstephenson/ruby-build.git
RUN cd ruby-build && ./install.sh
RUN mkdir -p /opt/rubies
 
# Install Ruby 2.0.0-p0
RUN /usr/local/bin/ruby-build 2.0.0-p0 /opt/rubies/2.0.0-p0
ENV PATH /app/bin:/app/vendor/bundle/bin:/opt/rubies/2.0.0-p0/bin:/usr/local/bin:/usr/bin:/bin
RUN gem install json

ADD . /usr/scripts
