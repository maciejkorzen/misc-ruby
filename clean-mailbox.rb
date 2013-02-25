#!/usr/bin/ruby

# Delete everything (directories and messages) from IMAP mailbox.

require 'net/imap'
require 'pp'

imap = Net::IMAP.new('my.imap.server.com', 993, true)

imap.login('mylogin', 'my p@ssw0rd')
imap.list("", "*").each do |m|
	puts m.name
	imap.delete m.name unless m.name == 'INBOX' || m.name =~ /Shared Folders.*/
	imap.examine(m.name)
	imap.search(["OR", "NOT", "NEW", "NEW"]).each do |n|
		puts n
		imap.store(n, "+FLAGS", [:DELETED])
	end
end
imap.expunge
