#!/usr/bin/ruby

require 'rubygems'
gem 'json'
require 'json'
require 'pp'
require 'erb'
require 'net/http'
require 'securerandom'
require 'optparse'

options = {:port => 3306, :hostname => nil}
attemptElection = false
generateCredentials = true
currentLeader = nil
currentLeaderHost = nil
currentLeaderPort = nil
hostname = nil
port = nil
serverId = nil
parsedHostname = nil

parser = OptionParser.new do|opts|
  opts.banner = "Usage: bootstrap.rb [options]"
  opts.on('-h', '--hostname ip or hostname', 'Hostname') do |hostname|
    parsedHostname = URI.parse(hostname)
    puts "COMMAND: Parsed hostname is #{parsedHostname.to_s}"
    hostname = parsedHostname.host
    port = parsedHostname.port
  end
end
parser.parse!

# Generate user/pass
username_base = "admin"
username_random = ('a'..'z').to_a.shuffle[0,8].join
username = username_base + "_" + username_random
password = SecureRandom.hex
encrypted_password = password; #encrypt this!

# Initialize http
http = Net::HTTP.new("172.17.42.1", 4001)

# Save to etcd
#http.set_debug_output($stdout)
registerRequest = Net::HTTP::Put.new("/v2/keys/services/buildafund-mysql/instances/#{hostname}:#{port}")
registerRequest.set_form_data('dir' => 'true', 'ttl' => 60)
registerResponse = http.request(registerRequest);
case registerResponse.code
  when "201"
    puts "REGISTER: register success"
  when "403"
    puts "REGISTER: Already registered. Updating TTL"
    generateCredentials = false;
    registerRequest = Net::HTTP::Put.new("/v2/keys/services/buildafund-mysql/instances/#{hostname}:#{port}")
    registerRequest.set_form_data('prevExist' => 'true', 'dir' => 'true', 'ttl' => 60)
    registerResponse = http.request(registerRequest);
  when "404"
    puts "REGISTER: Could not register. Received 404 from etcd"
  else
    puts "REGISTER: Could not register. Received unknown code #{registerResponse.code} from etcd"
end

# Generate new creds if needed
if generateCredentials
  # Write username to etcd
  writeRequest = Net::HTTP::Put.new("/v2/keys/services/buildafund-mysql/instances/#{hostname}:#{port}/user")
  writeRequest.set_form_data('value' => username)
  writeResponse = http.request(writeRequest);
  case writeResponse.code
    when "201", "200"
      puts "WRITE: Username #{username} written successfully."
    else
      puts "WRITE: Could not write username. Received unknown code #{writeResponse.code} from etcd"
  end

  # Write password to etcd
  passwordRequest = Net::HTTP::Put.new("/v2/keys/services/buildafund-mysql/instances/#{hostname}:#{port}/password")
  passwordRequest.set_form_data('value' => password)
  passwordResponse = http.request(passwordRequest);
  case passwordResponse.code
    when "201", "200"
      puts "WRITE: Password written successfully."
    else
      puts "WRITE: Could not write password. Received unknown code #{passwordResponse.code} from etcd"
  end
else
  puts "WRITE: Credentials already exist. Skipping generation."
end

# Read current master
leaderRequest = Net::HTTP::Get.new("/mod/v2/leader/buildafund-mysql")
leaderResponse = http.request(leaderRequest)
case
  when leaderResponse.code.eql?("404")
    # this should work. etcd is returning the wrong status code
  when leaderResponse.body.include?("get leader error: read lock error: Cannot reach servers after 3 time")
    attemptElection = true
    puts "ELECTION: Encountered 'get leader error'"
    puts "ELECITON: Leader not found. Attempting Election"
  when leaderResponse.body.empty?
    attemptElection = true
    puts "ELECTION: Encountered empty body"
    puts "ELECTION: Leader not found. Attempting Election"
  else
    currentLeader = "http://" + leaderResponse.body.to_s
    parsedLeader = URI.parse(currentLeader)
    puts "ELECTION: Elected leader is #{parsedLeader.to_s}"
    currentLeaderHost = parsedLeader.host.to_s
    currentLeaderPort = parsedLeader.port.to_s
    currentLeader = "#{currentLeaderHost}:#{currentLeaderPort}"
end

# Attempt to become master
if attemptElection
  electionRequest = Net::HTTP::Put.new("/mod/v2/leader/buildafund-mysql?ttl=60")
  electionRequest.set_form_data('name' => hostname + ':' + port.to_s)
  electionResponse = http.request(electionRequest)
  case electionResponse.code
    when "200"
      puts "ELECTION: Election successful. #{hostname}:#{port} is now the master."
      currentLeader = "#{hostname}:#{port}"
      currentLeaderHost = hostname.to_s
      currentLeaderPort = port.to_s
  end
end

# Read all instances
#http.set_debug_output($stdout)
instancesRequest = Net::HTTP::Get.new("/v2/keys/services/buildafund-mysql/instances?recursive=true")
instancesResponse = http.request(instancesRequest)
instances = JSON.parse(instancesResponse.body)

slaveDetails = Hash.new
leaderDetails = Hash.new
instances['node']['nodes'].each do |instance|
  name = instance['key'].split('/')[-1]
  serverId = Integer(instance['createdIndex'])
  keyData = Hash.new
  instance['nodes'].each do |keys|
    keyName = keys['key'].split('/')[-1]
    keyValue = keys['value'].chomp('"').reverse.chomp('"').reverse #remove quotes, crazy
    keyData[keyName] = keyValue
    if !currentLeader.eql?(name)
      slaveDetails[name] = keyData
    else
      leaderDetails[name] = keyData
    end
  end
end
#puts "slave:"
#pp slaveDetails
#puts "leader:"
#pp leaderDetails

# Write config file based on role
puts "----------------------------Generated Config--------------------------------"
cnf_template = File.read('/usr/scripts/replication.cnf.erb')
cnf = ERB.new(cnf_template)
puts cnf.result()
File.open('/etc/mysql/conf.d/replication.cnf', 'w') { |file| file.write(cnf.result()) }
puts "-------------------------------End Config-----------------------------------"

# Start mysql
puts "MYSQL: Installing DB"
installMysql = `mysql_install_db`
puts "MYSQL: Starting process"
mysqlPID = spawn("/usr/bin/mysqld_safe & sleep 10")
puts "MYSQL: Granting replication users access"
puts mysqlPID
#grantUser = `echo "GRANT ALL ON *.* TO #{username}@'%' IDENTIFIED BY '#{password}' WITH GRANT OPTION; FLUSH PRIVILEGES" | mysql`