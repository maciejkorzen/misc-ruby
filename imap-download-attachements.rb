#!/usr/bin/ruby
require 'net/imap'
require 'pp'
require 'base64'

Dir.chdir("/directory/for/attachements")
imap = Net::IMAP.new('imap.my.server.com', 993, true)
imap.login('mylogin', 'my p@ssw0rD example')
imap.examine('imap-dir-name')
all = imap.search(["SUBJECT", "some subject"]).length
i = 1
imap.search(["SUBJECT", "some subject"]).each do |message_id|
	fileName = imap.fetch(message_id, "BODYSTRUCTURE")[0].attr["BODYSTRUCTURE"].parts[1].disposition.param["FILENAME"]
	puts "[#{i}/#{all}] processing #{fileName}"
	File.new(fileName, "w").puts(Base64.decode64(imap.fetch(message_id, "BODY[2]")[0][1]["BODY[2]"]))
	i += 1
end
