#!/usr/bin/env ruby

# Program do zliczania ilosci wiadomosci w katalogu INBOX na koncie IMAP.
# -- Maciej Korzen, 2012.07.12

require 'net/imap'
require 'openssl'

OpenSSL::SSL::VERIFY_PEER = OpenSSL::SSL::VERIFY_NONE

limit = 2

if ARGV
	if ARGV[0]
		if /^[0-9]+$/.match(ARGV[0])
			limit = ARGV[0].to_i
		else
			puts "Usage: #{$0} [count]"
			exit 1
		end
	end
end

blad = false
begin
	imap = Net::IMAP.new("imap.my.server.com", 993, true)
	imap.login("mylogin", "this is my EXAMPLE p@ssw0rD")
	imap.select('INBOX')
	searchResult = imap.uid_search(["ALL"])
	count = searchResult.length
	imap.logout
	imap.disconnect
	if count > limit
		puts "Error. Count #{count} > #{limit}"
		exit 2
	else
		puts "OK. Count #{count} <= #{limit}"
		exit 0
	end
rescue => detail
	blad = true
	print "Error! "
	print detail.backtrace
	puts ""
	exit 3
end
