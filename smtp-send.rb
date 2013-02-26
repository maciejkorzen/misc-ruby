#!/usr/bin/ruby
require 'net/smtp'
require 'time'

rcpt = [ 'first.person@company.com', 'second.person@organization.org' ]
from = 'this.is@my.addre.ss'

if ARGV[0]
	rcpt = ARGV[0]
end

if ARGV[1]
	from = ARGV[1]
end

msgstr = <<END_OF_MESSAGE
Subject: test message
Message-ID: <custom-message-id-_RANDOM__ID_@example.net>
Date: _DATE_
From: _FROM_
To: _RCPT_
MIME-Version: 1.0
Content-Type: text/plain; charset=us-ascii
Content-Transfer-Encoding: 7bit

abc 123
END_OF_MESSAGE

msgstr.sub!(/_ID_/, Time.now.to_s)
msgstr.sub!(/_DATE_/, Time.now.rfc2822.to_s)
msgstr.sub!(/_RANDOM_/, rand(10000000000000).to_s)
msgstr.sub!(/_RCPT_/, rcpt.join(', ').to_s)
msgstr.sub!(/_FROM_/, from)
Net::SMTP.start('127.0.0.1', 25) do |smtp|
        smtp.send_message msgstr, from, rcpt
end
