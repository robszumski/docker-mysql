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
#http.set_debug_output($stdout)

# Read command line flags
parser = OptionParser.new do|opts|
  opts.banner = "Usage: bootstrap.rb [options]"
  opts.on('-h', '--hostname http://ip-or-hostname', 'Hostname') do |hostname|
    parsedHostname = URI.parse(hostname)
    puts "COMMAND: Parsed hostname is #{parsedHostname.to_s}"
  end
end
parser.parse!

hostname = parsedHostname.host
port = parsedHostname.port

# Generate user/pass
def generateUsername
  username_base = "admin"
  username_random = ('a'..'z').to_a.shuffle[0,8].join
  username = username_base + "_" + username_random
end
username = generateUsername

def generatePassword
  password = SecureRandom.hex
  encrypted_password = password; #encrypt this!
end
password = generatePassword

# Save to etcd
def register (hostname, port)
  http = Net::HTTP.new("172.17.42.1", 4001)
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
end
register(parsedHostname.host, parsedHostname.port)

def etcdWrite (keyPath, value, comment)
  http = Net::HTTP.new("172.17.42.1", 4001)
  writeRequest = Net::HTTP::Put.new(keyPath)
  writeRequest.set_form_data('value' => value)
  writeResponse = http.request(writeRequest);
  case writeResponse.code
    when "201", "200"
      puts "WRITE: #{comment} written successfully."
    else
      puts "WRITE: Could not write username. Received unknown code #{writeResponse.code} from etcd"
  end
end

# Generate new creds if needed
if generateCredentials
  # Write Username
  path = "/v2/keys/services/buildafund-mysql/instances/#{hostname}:#{port}/user"
  etcdWrite(path, username, "Username #{username}")
  # Write Password
  path = "/v2/keys/services/buildafund-mysql/instances/#{hostname}:#{port}/password"
  etcdWrite(path, password, "Password")
else
  puts "WRITE: Credentials already exist. Skipping generation."
end

# Read current master
def readLeader (etcdPath)
  http = Net::HTTP.new("172.17.42.1", 4001)
  leaderRequest = Net::HTTP::Get.new(etcdPath)
  leaderResponse = http.request(leaderRequest)
  leaderValue = nil
  case
    when leaderResponse.code.eql?("404")
      # this should work. etcd is returning the wrong status code
    when leaderResponse.body.include?("get leader error: read lock error: Cannot reach servers after 3 time")
      puts "ELECTION: Encountered 'get leader error'"
      puts "ELECITON: Leader not found. Attempting Election"
    when leaderResponse.body.empty?
      puts "ELECTION: Encountered empty body"
      puts "ELECTION: Leader not found. Attempting Election"
    else
      leaderString = "http://" + leaderResponse.body.to_s
      parsedLeader = URI.parse(leaderString)
      puts "ELECTION: Elected leader is #{parsedLeader.to_s}"
      leaderValue = Hash.new
      leaderValue['host'] = parsedLeader.host.to_s
      leaderValue['port'] = parsedLeader.port.to_s
      leaderValue['full'] = "#{parsedLeader.host}:#{parsedLeader.port}"
  end
  return leaderValue
end
path = "/mod/v2/leader/buildafund-mysql"
currentLeader = readLeader(path)

# Attempt to become master
def becomeLeader(etcdPath, value)
  http = Net::HTTP.new("172.17.42.1", 4001)
  electionRequest = Net::HTTP::Put.new(etcdPath)
    electionRequest.set_form_data('name' => value)
    electionResponse = http.request(electionRequest)
    case electionResponse.code
      when "200"
        puts "ELECTION: Election successful. #{value} is now the master."
        return true
    end
end

if currentLeader.nil?
  path = "/mod/v2/leader/buildafund-mysql?ttl=60"
  isNewLeader = becomeLeader(path, "#{parsedHostname.host}:#{parsedHostname.port}")
  if isNewLeader
    currentLeader = Hash.new()
    currentLeader["host"] = parsedHostname.host.to_s
    currentLeader["port"] = parsedHostname.port.to_s
    currentLeader["full"] = "#{parsedHostname.host}:#{parsedHostname.port}"
  end
end

# Read all instances
def etcdRead(etcdPath)
  http = Net::HTTP.new("172.17.42.1", 4001)
  instancesRequest = Net::HTTP::Get.new(etcdPath)
  instancesResponse = http.request(instancesRequest)
  instances = JSON.parse(instancesResponse.body)

  instanceDetails = Hash.new
  instances['node']['nodes'].each do |instance|
    name = instance['key'].split('/')[-1]
    serverId = Integer(instance['createdIndex'])
    keyData = Hash.new
    instance['nodes'].each do |keys|
      keyName = keys['key'].split('/')[-1]
      keyValue = keys['value'].chomp('"').reverse.chomp('"').reverse #remove quotes, crazy
      keyData[keyName] = keyValue
      instanceDetails[name] = keyData
    end
    return instanceDetails
  end
end

instances = etcdRead("/v2/keys/services/buildafund-mysql/instances?recursive=true")
instances.each do |name, data|
  if currentLeader["full"].eql?(name)
    currentLeader["user"] = data["user"]
    currentLeader["password"] = data["password"]
  end
end

# Write config file based on role
puts "----------------------------Generated Config--------------------------------"
cnf_template = File.read('/usr/scripts/replication.cnf.erb')
cnf = ERB.new(cnf_template)
puts cnf.result()
File.open('/etc/mysql/conf.d/replication.cnf', 'w') { |file| file.write(cnf.result()) }
puts "-------------------------------End Config-----------------------------------"

# Start mysql
#=begin
puts "MYSQL: Installing DB"
installMysql = `mysql_install_db`
puts "MYSQL: Starting process"
mysqlPID = spawn("/usr/bin/mysqld_safe & sleep 10")
puts mysqlPID
Process.wait(mysqlPID)
puts "MYSQL: Granting replication users access"
`echo "CREATE USER '#{username}'@'%' IDENTIFIED BY '#{password}';" | mysql`
`echo "CREATE USER '#{username}'@'localhost' IDENTIFIED BY '#{password}';" | mysql`
`echo "GRANT REPLICATION SLAVE ON *.* TO '#{username}'@'%'; FLUSH PRIVILEGES;" | mysql`

# If slave, configure
if !"#{hostname}:#{port}".eql?(currentLeader)
  puts "SLAVE: Setting master to #{currentLeader["full"]}"
  puts "SLAVE: Setting username to #{currentLeader["user"]}"
  puts "SLAVE: Setting log position to X"
  `echo "CHANGE MASTER TO MASTER_HOST='#{currentLeader["host"]}', MASTER_PORT= #{currentLeader["port"]}, MASTER_USER='#{currentLeader["user"]}', MASTER_PASSWORD='#{currentLeader["password"]}', MASTER_LOG_FILE='', MASTER_LOG_POS=4;" | mysql`
else
  puts "MASTER: No configuration was needed."
end
#=end