#!/usr/bin/ruby
# DESCRIPTION:
# This script takes list of servers and passwords, uploads given script on
# them using SFTP, logs in on the server via SSH and executes uploaded
# script using sudo. After execution uploaded script is removed from
# remote server.
#
# README:
# 1) Download this script.
# 2) Create CSV file with names of servers and passwords (I assume that login is the same on each server).
#    Format of the file is following:
#    SERVER,PASSWORD
# 3) Create script that you want to execute.
# 4) Adjust variables in this script, run it and let it do all the work for you. :-)

require 'rubygems'
require 'net/ssh'
require 'net/sftp'

### IMPORTANT ###################
# Change variables below:
login_default = "your-login"
script_name = "your-script1.sh"
list_of_servers = "your-servers.csv"
#################################

IO.readlines(list_of_servers).each do |line|
	line.chomp!
	line = line.gsub(/^"/, '').gsub!(/"$/, '').gsub(/","/, ',')
	server = line.split(',')[0]
	password = line.split(',')[1]
	puts "---- " + server
	$stdout.flush
	puts "sftp connection..."
	Net::SSH.start(server, login_default, :password => password) do |ssh|
		chan = ssh.sftp.connect do |sftp|
			sftp.upload!(script_name, "/tmp/" + script_name)
		end
	end
	puts "ssh connection..."
	Net::SSH.start(server, login_default, :password => password) do |ssh|
		first_nl = true
		ssh.open_channel do |ch|
			ch.exec "/usr/bin/sudo -p 'sudo password: ' /bin/sh /tmp/" + script_name do |ch, success|
				abort "could not execute sudo" unless success
				ch.on_data do |ch, data|
					print data
				end
				ch.on_extended_data do |ch, id, data|
					if (id == 1)
						if data =~ /sudo password: /
							ch.send_data(password + "\n")
						else
							if (data == "\n")
								if (first_nl == true)
									first_nl = false
								else
									print data
								end
							else
								print data
							end
						end
					end
				end
			end
		end
		ssh.loop
	end
	puts "ssh connection, removing file..."
	Net::SSH.start(server, login_default, :password => password) do |ssh|
		ssh.open_channel do |ch|
			ch.exec "rm /tmp/" + script_name do |ch, success|
				abort "could not execute rm" unless success
				ch.on_data do |ch, data|
					print data
				end
				ch.on_extended_data do |ch, id, data|
					print data
				end
			end
		end
		ssh.loop
	end
end
