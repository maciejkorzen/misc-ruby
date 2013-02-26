#!/usr/bin/ruby
# == Synopsis
#
# cisco-find-mac: searches all Cisco devices for a given MAC address
#
# == Usage
#
# cisco-find-mac [OPTION]
#
# -h, --help:
#    show help
#
# --login LOGIN
#    login as given SSH user to device
#
# --password PASSWORD
#    authenticate using given password, required
#
# --mac AA:BB:CC:DD:EE:FF
#    MAC address to look for, required

require 'net/ssh'
require 'getoptlong'
require 'rdoc/usage'

# List of devices.
ips = [	"10.1.2.3",
	"10.1.2.4",
	"10.1.2.5",
	"10.1.2.6"
	]

opts = GetoptLong.new(
	[ '--help', '-h', GetoptLong::NO_ARGUMENT ],
	[ '--login', '-l', GetoptLong::REQUIRED_ARGUMENT ],
	[ '--password', '-p', GetoptLong::REQUIRED_ARGUMENT ],
	[ '--mac', '-m', GetoptLong::REQUIRED_ARGUMENT ]
)

login = 'admin'
password = nil
mac = nil
opts.each do |opt, arg|
	case opt
		when '--help'
			RDoc::usage
		when '--login'
			login = arg
		when '--password'
			password = arg
		when '--mac'
			mac = arg
	end
end

if password == nil
	puts "password missing!"
	exit 0
end

if mac == nil
	puts "MAC address is missing!"
	exit 0
end

mac = mac.gsub(/(..):(..):(..):(..):(..):(..)/, '\1\2.\3\4.\5\6')

ips.each do |ipaddr|
	puts "Searching at device #{ipaddr}..."
	Net::SSH.start(ipaddr, login, password) do |session|
		buf = ""
		shell = session.shell.open
		shell.send_data "sh mac-address-table address " + mac + "\n"
		while true
			if shell.stdout?
				buf += shell.stdout
			end
			if buf.length > 160 && buf =~ /\n\w\d*-\d+\#$/
				break
			end
			sleep 0.1
		end

		lines = buf.split(/\n/)
		description = lines[-1].sub(/\#/, '')
		i = 9
		while i + 1 < lines.length
			if /^Total Mac Addresses ... this criterion:/.match(lines[i])
				break
			end
			linia = lines[i].gsub(/\s+/, ' ').sub(/^\s/, '')
			vlan = linia.split(/\s/)[0]
			port = linia.split(/\s/)[3]
			puts "ip(#{ipaddr}) desc(#{description}) vlan(#{vlan}) port(#{port})"
			i += 1
		end
	end
	print "\n"
end
