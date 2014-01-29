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
logPosition = nil
globalTTL = 6000
#http.set_debug_output($stdout)

# Read command line flags
parser = OptionParser.new do|opts|
  opts.banner = "Usage: bootstrap.rb [options]"
  opts.on('-h', '--hostname http://ip-or-hostname', 'Hostname') do |hostname|
    parsedHostname = URI.parse(hostname)
    puts "COMMAND: Parsed full hostname is #{parsedHostname.to_s}"
    puts "COMMAND: Parsed host is #{parsedHostname.host}"
    puts "COMMAND: Parsed port is #{parsedHostname.port}"
  end
end
parser.parse!

hostname = parsedHostname.host
port = parsedHostname.port

def generateUsername
  username_base = "admin"
  username_random = ('a'..'z').to_a.shuffle[0,8].join
  username = username_base + "_" + username_random
end

def generatePassword
  password = SecureRandom.hex
  encrypted_password = password; #encrypt this!
end

def register (hostname, port, options={})
  # Set default values
  defaults = {
    :redirLimit => 10,
    :leaderIPAddress => "172.17.42.1",
    :leaderPort => 4001,
    :prevExist => "false",
    :ttl => 60
  }
  # Merge defaults with provided options
  options = defaults.merge(options)

  raise ArgumentError, 'HTTP redirect too deep' if options[:redirLimit] == 0
  http = Net::HTTP.new(options[:leaderIPAddress], options[:leaderPort])
  registerRequest = Net::HTTP::Put.new("/v2/keys/services/buildafund-mysql/instances/#{hostname}:#{port}")
  registerRequest.set_form_data('dir' => 'true', 'ttl' => options[:ttl], 'prevExist' => options[:prevExist])
  registerResponse = http.request(registerRequest);
  case registerResponse
    when Net::HTTPSuccess
      # Process successful response
      puts "REGISTER: register success. TTL of #{options[:ttl]}"
    when Net::HTTPPreconditionFailed
      puts "REGISTER: Already registered. Updating TTL with another #{options[:ttl]}"
      generateCredentials = false
      options[:prevExist] = true
      options[:redirLimit] = options[:redirLimit]-1
      # remerge defaults
      options = defaults.merge(options)
      register(hostname, port, options)
    when registerResponse.code.eql?("404")
      puts "REGISTER: Could not register. Received 404 from etcd"
    when Net::HTTPRedirection
      newLeaderIPAddress = URI.parse(registerResponse['location']).host
      newLeaderPort = URI.parse(registerResponse['location']).port
      puts "REGISTER: Redirect to #{newLeaderIPAddress}:#{newLeaderPort}"
      puts "REGISTER: Submitting #{hostname}:#{port}" 
      register(hostname, port, :redirLimit => options[:redirLimit]-1, :leaderIPAddress => newLeaderIPAddress, :leaderPort => newLeaderPort)
    else
      puts "REGISTER: Encountered error #{registerResponse.error!}"
      puts "REGISTER: Could not register. Received unknown code #{registerResponse.code} from etcd"
    end
end

def etcdWrite (etcdPath, value, comment, options={})
  # Set default values
  defaults = {
    :redirLimit => 10,
    :leaderIPAddress => "172.17.42.1",
    :leaderPort => 4001
  }
  # Merge defaults with provided options
  options = defaults.merge(options)

  raise ArgumentError, 'HTTP redirect too deep' if options[:redirLimit] == 0

  http = Net::HTTP.new(options[:leaderIPAddress], options[:leaderPort])
  writeRequest = Net::HTTP::Put.new(etcdPath)
  writeRequest.set_form_data('value' => value)
  writeResponse = http.request(writeRequest);
  case writeResponse
    when Net::HTTPSuccess
      # Process successful response
      puts "WRITE: #{comment} written successfully."
    when Net::HTTPRedirection
      newLeaderIPAddress = URI.parse(writeResponse['location']).host
      newLeaderPort = URI.parse(writeResponse['location']).port
      puts "WRITE: Redirect to #{newLeaderIPAddress}:#{newLeaderPort}"
      etcdWrite(etcdPath, value, comment, :redirLimit => options[:redirLimit]-1, :leaderIPAddress => newLeaderIPAddress, :leaderPort => newLeaderPort)
    else
      puts "WRITE: Encountered error #{writeResponse.error!}"
      puts "WRITE: Could not write username. Received unknown code #{writeResponse.code} from etcd"
    end
end

def readLeader (etcdPath, options={})
  # Set default values
  defaults = {
    :redirLimit => 10,
    :leaderIPAddress => "172.17.42.1",
    :leaderPort => 4001
  }
  # Merge defaults with provided options
  options = defaults.merge(options)

  raise ArgumentError, 'HTTP redirect too deep' if options[:redirLimit] == 0

  http = Net::HTTP.new(options[:leaderIPAddress], options[:leaderPort])
  leaderRequest = Net::HTTP::Get.new(etcdPath)
  leaderResponse = http.request(leaderRequest)
  leaderValue = nil
  case
    when leaderResponse.code.eql?("404")
      # this should work. etcd is returning the wrong status code
    when leaderResponse.body.include?("get leader error: read lock error:")
      puts "ELECTION: Encountered 'get leader error'"
      puts "ELECITON: Leader not found. Attempting Election"
    when leaderResponse.body.empty?
      puts "ELECTION: Encountered empty body"
      puts "ELECTION: Leader not found. Attempting Election"
    when Net::HTTPSuccess
      leaderString = "http://" + leaderResponse.body.to_s
      parsedLeader = URI.parse(leaderString)
      puts "ELECTION: Elected leader is #{parsedLeader.to_s}"
      leaderValue = Hash.new
      leaderValue['host'] = parsedLeader.host.to_s
      leaderValue['port'] = parsedLeader.port.to_s
      leaderValue['full'] = "#{parsedLeader.host}:#{parsedLeader.port}"
    else
      puts "ELECTION: Encountered error #{registerResponse.error!} when reading leader."
  end
  return leaderValue
end

def becomeLeader(etcdPath, value, options={})
  # Set default values
  defaults = {
    :redirLimit => 10,
    :leaderIPAddress => "172.17.42.1",
    :leaderPort => 4001
  }
  # Merge defaults with provided options
  options = defaults.merge(options)

  raise ArgumentError, 'HTTP redirect too deep' if options[:redirLimit] == 0

  http = Net::HTTP.new(options[:leaderIPAddress], options[:leaderPort])
  electionRequest = Net::HTTP::Put.new(etcdPath)
    electionRequest.set_form_data('name' => value)
    electionResponse = http.request(electionRequest)
    case electionResponse
      when Net::HTTPSuccess
        # Process successful response
        puts "ELECTION: Election successful. #{value} is now the master."
        return true
      when Net::HTTPRedirection
        newLeaderIPAddress = URI.parse(electionResponse['location']).host
        newLeaderPort = URI.parse(electionResponse['location']).port
        puts "ELECTION: Redirect to #{newLeaderIPAddress}:#{newLeaderPort}"
        becomeLeader(etcdPath, value, :redirLimit => options[:redirLimit]-1, :leaderIPAddress => newLeaderIPAddress, :leaderPort => newLeaderPort)
      else
        puts "ELECTION: Encountered error #{electionResponse.error!}"
      end
end

def etcdRead(etcdPath, options={})
  # Set default values
  defaults = {
    :redirLimit => 10,
    :leaderIPAddress => "172.17.42.1",
    :leaderPort => 4001
  }
  # Merge defaults with provided options
  options = defaults.merge(options)

  raise ArgumentError, 'HTTP redirect too deep' if options[:redirLimit] == 0

  http = Net::HTTP.new(options[:leaderIPAddress], options[:leaderPort])
  instancesRequest = Net::HTTP::Get.new(etcdPath)
  instancesResponse = http.request(instancesRequest)
  case instancesResponse
    when Net::HTTPSuccess
      instances = JSON.parse(instancesResponse.body)
      return instances
    when Net::HTTPRedirection
      newLeaderIPAddress = URI.parse(instancesResponse['location']).host
      newLeaderPort = URI.parse(instancesResponse['location']).port
      puts "READ: Redirect to #{newLeaderIPAddress}:#{newLeaderPort}"
      etcdRead(etcdPath, :redirLimit => options[:redirLimit]-1, :leaderIPAddress => newLeaderIPAddress, :leaderPort => newLeaderPort)
    else
      puts "READ: Encountered error #{instancesResponse.error!}"
    end
end

# Generate a username for this machine
username = generateUsername

# Generate a password for this machine
password = generatePassword

# Register this machine in etcd
register(hostname, port, :ttl => globalTTL)

# If needed, generate creds and save to registered instance
if generateCredentials
  # Write username to registered instance
  path = "/v2/keys/services/buildafund-mysql/instances/#{hostname}:#{port}/user"
  etcdWrite(path, username, "Username #{username}")
  # Write password to registered instance
  path = "/v2/keys/services/buildafund-mysql/instances/#{hostname}:#{port}/password"
  etcdWrite(path, password, "Password")
else
  puts "WRITE: Credentials already exist. Skipping generation."
end

# Read the current leader
path = "/mod/v2/leader/buildafund-mysql"
currentLeader = readLeader(path)

# If there isn't a leader, attempt to become the leader
if currentLeader.nil?
  path = "/mod/v2/leader/buildafund-mysql?ttl=#{globalTTL}"
  isNewLeader = becomeLeader(path, "#{parsedHostname.host}:#{parsedHostname.port}")
  if isNewLeader
    currentLeader = Hash.new()
    currentLeader["host"] = parsedHostname.host.to_s
    currentLeader["port"] = parsedHostname.port.to_s
    currentLeader["full"] = "#{parsedHostname.host}:#{parsedHostname.port}"
    # Write log position
    path = "/v2/keys/services/buildafund-mysql/log"
    etcdWrite(path, 0, "Log position 0")
  end
end

# Read all instances
instances = etcdRead("/v2/keys/services/buildafund-mysql/instances?recursive=true")
# Process successful response
instanceDetails = Hash.new
instances['node']['nodes'].each do |instance|
  name = instance['key'].split('/')[-1]
  keyData = Hash.new
  serverId = Integer(instance['createdIndex'])
  puts "READ: Server ID is #{instance['createdIndex']} for #{name}"
  keyData['id'] = serverId
  instance['nodes'].each do |keys|
    keyName = keys['key'].split('/')[-1]
    keyValue = keys['value'].chomp('"').reverse.chomp('"').reverse #remove quotes, crazy
    keyData[keyName] = keyValue
    instanceDetails[name] = keyData
  end
end
instanceDetails.each do |name, data|
  # Pull out info to connect to leader
  if currentLeader["full"].eql?(name)
    currentLeader["user"] = data["user"]
    currentLeader["password"] = data["password"]
    puts "DEBUG: Found #{data["user"]} and #{data["password"]}"
  end
  # Pull out the server ID
  if "#{hostname}:#{port}".eql?(name)
    serverId = data['id']
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
puts "MYSQL: PID is #{mysqlPID}"
Process.wait(mysqlPID)
puts "MYSQL: Granting replication users access"
`echo "CREATE USER '#{username}'@'%' IDENTIFIED BY '#{password}';" | mysql`
`echo "CREATE USER '#{username}'@'localhost' IDENTIFIED BY '#{password}';" | mysql`
`echo "GRANT ALL PRIVILEGES ON *.* TO '#{username}'@'%'; FLUSH PRIVILEGES;" | mysql`

# If slave, configure
if !"#{hostname}:#{port}".eql?(currentLeader['full'])
  puts "SLAVE: Setting master to #{currentLeader["full"]}"
  puts "SLAVE: Setting username to #{currentLeader["user"]}"
  puts "SLAVE: Slave username is #{username}"
  puts "SLAVE: Slave password is #{password}"
  # Read log position of leader
  logResponse = etcdRead("/v2/keys/services/buildafund-mysql/log")
  logPosition = logResponse['node']['value']
  puts "SLAVE: Setting log position to #{logPosition}"
  `echo "CHANGE MASTER TO MASTER_HOST='#{currentLeader["host"]}', MASTER_PORT= #{currentLeader["port"]}, MASTER_USER='#{currentLeader["user"]}', MASTER_PASSWORD='#{currentLeader["password"]}', MASTER_LOG_FILE='mysql-bin.000003', MASTER_LOG_POS=#{logPosition}; START SLAVE;" | mysql`
else
  puts "MASTER: No configuration was needed."
end
#=end
