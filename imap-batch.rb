#!/usr/bin/env ruby
# encoding: utf-8
##### DESCRIPTION ###########################################################
# Swiss-knife all-in-one tool kind of script to do batch processing of
# messages at IMAP account(s). It can do filtering, move messages from one
# account to other and other fancy things. You need to know Ruby to use it.
# Each message is processed only once in a lifetime (or until it's IMAP
# message id is changed. List of seen modules is stored in sqlite3 database.
# SpamAssassin is being used to detect SPAM. You need to have working
# SpamAssassin, check the code for details.
#
##### USAGE #################################################################
# 1) Install following Ruby gems:
#      - rfc2047
#      - sqlite3
# 2) Review the script and modify variables and filters to suit your needs.
# 3) Run it.
#
##### LICENSE ###############################################################
# Copyright 2013 Maciej Korzen
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; version 2 dated June, 1991.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
#
##### AUTHOR ################################################################
# Maciej Korzen
# maciek@korzen.org, mkorzen@gmail.com
# http://www.korzen.org/

require 'base64'
require 'date'
require 'net/imap'
require 'nkf'
require 'openssl'
require 'optparse'
require 'pp'
require 'rfc2047'
require 'sqlite3'
require 'tempfile'
require 'thread'

OpenSSL::SSL::VERIFY_PEER = OpenSSL::SSL::VERIFY_NONE
ENV["LANG"] = "C"
ENV["LC_ALL"] = "C"

$alternative = false
OptionParser.new do |opts|
	opts.banner = "Usage: imap-batch.rb [options]"

	opts.on("-a", "--alternative", "Run alternative tasks") do |a|
		$alternative = true
	end
	
	opts.on_tail("-h", "--help", "Show help") do
		puts opts
		exit
	end
end.parse!

$hashes = [ ]

# List of known SPAM from/to values that you want to immediately delete.
$fromAlwaysDelete = [ "totaljobsmail\\.co\\.uk",
"@jobpolska\\.pl",
"@polandjobs\\.com",
"@eurojobs\\.com",
"@jobsinhubs\\.com",
"@mailing\\.grono\\.net\\.pl",
"gronek@grono\\.net",
"@grono\\.net\\.pl",
"noreply@ajo\\.pl",
"noreply@mailing\\.ajo\\.pl",
"noreply@yoyo\\.pl",
"@brightpinkgorilla\.com",
"noreply@rolex\\.com",
"mailing@interia\\.pl",
"bok@firma\\.interia\\.pl",
"wp@wp\\.pl",
"Netia@netia\\.pl",
"@badoo\\.com" ]

$toAlwaysDelete = [ "-@-\\.-",
"info@o2\\.pl",
"users@interia\\.pl",
"@jobpolska\\.pl" ]

$fromAlwaysDeleteRegex =  "(" + $fromAlwaysDelete.join('|') + ")"
$toAlwaysDeleteRegex =  "(" + $toAlwaysDelete.join('|') + ")"

def myDecode(s)
	problem = false
	ret = "NONE"
	if s
		begin
			ret = NKF.nkf("-mw", Rfc2047.decode(s))
		rescue => detail
			problem = true
			ret = "ERROR"
			puts "Error during decoding!"
			print detail.backtrace.join("\n")
			puts ""
		end
	end
	return ret
end

def myParseDate(arg)
	problemParse = false
	date = nil
	if arg
		begin
			date = DateTime.parse(arg)
		rescue => detail
			problemParse = true
			puts "Problem while parsing date '#{arg}'! Moving on..."
		end
	end
	if (!date) || (problemParse == true)
		date = DateTime.now
	end
	return date
end
def moveTo(imap, message_id, target, options = {})
	if options.has_key?("markreaded")
		markreaded = options["markreaded"]
	else
		markreaded = false
	end
	problem = false
	begin
		imap.uid_copy(message_id, target)
		if markreaded == true
			imap.uid_store(message_id, "+FLAGS", [:Seen])
		end
	rescue => detail
		problem = true
		puts "Error while copying messages between folders on the same account!"
		print detail.backtrace.join("\n")
		puts ""
	end
	if problem == false
		begin
			imap.uid_store(message_id, "+FLAGS", [:Deleted])
		rescue => detail
			problem = true
			puts "Error while marking message as deleted!"
			print detail.backtrace.join("\n")
			puts ""
		end
	end
	return 0
end

def describe(imap, message_id, i = -1, count = -1)
	envelope = imap.uid_fetch(message_id, "ENVELOPE")[0].attr["ENVELOPE"]
	subject = myDecode(envelope.subject)
	if envelope.from
		from = "#{envelope.from[0].mailbox}@#{envelope.from[0].host}"
	else
		from = "NONE"
	end
	if envelope.to
		to = "#{envelope.to[0].mailbox}@#{envelope.to[0].host}"
	else
		to = "NONE"
	end
	date2 = myParseDate(envelope.date).strftime("%Y.%m.%d %H.%M.%S")
	if (i >= 0) && (count >= 0)
		print "[#{i}/#{count}]"
	else
		print "[+]"
	end
	print " "
	print date2
	print " - "
	print subject.strip
	print " - "
	print from
	print " - "
	puts to
	return 0
end

def messageLearn(imap, message_id, type)
	begin
		file = Tempfile.new(['imap-batch', '.eml'])
		file.sync = true
		file.write(imap.uid_fetch(message_id, "BODY.PEEK[]")[0].attr["BODY[]"])
		system("sa-learn --#{type} #{file.path}")
	rescue => detail
		puts "\nException in messageLearn()!"
		print detail.backtrace.join("\n")
		puts ""
	ensure
		file.close
		file.unlink
	end
end

def downloadMessage(imap, message_id)
	file = Tempfile.new(['imap-batch', '.eml'])
	file.sync = true
	file.write(imap.uid_fetch(message_id, "BODY.PEEK[]")[0].attr["BODY[]"])
	return file
end

def processResult(searchResult, description, imap, trashName)
	imap.expunge
	count = searchResult.length
	if count > 0
		i = 1
		searchResult.each do |message_id|
			describe(imap, message_id, i, count)
			moveTo(imap, message_id, trashName)
			i += 1
		end
		puts ""
	end
	imap.expunge
end

def processResult2(header, values, imap, trashName)
	values.each do |value|
		processResult(imap.uid_search([header, value]), "SPAM #{header} #{value}", imap, trashName)
	end
end

def detectTrash(imap)
	imap.list("", "*").each do |imapDir|
		# Probably you want to customize following regular expression.
		if /^(Trash|Deleted Items|\[Gmail\]\/Trash)$/.match(imapDir.name)
			return imapDir.name
		end
	end
	puts "Can't find trash directory!"
	puts "exit"
	exit
end

def detectJunk(imap)
	imap.list("", "*").each do |foo|
		if /^(Junk|Junk E-Mail|\[Gmail\]\/Spam)$/.match(foo.name)
			return foo.name
		end
	end
	puts "Can't find Junk directory!"
	puts "exit"
	exit
end

def deleteFromDirBySearch(imap, dir, trashName, description, searchCondition)
	puts "DEBUG: deleteFromDirBySearch(dir:(#{dir}) search:(#{searchCondition}) description:(#{description}))"
	imap.select(dir)
	searchResult = imap.uid_search(searchCondition)
	processResult(searchResult, description, imap, trashName)
end

def connectImapAccount(address, login, password, port=993)
	imap = Net::IMAP.new(address, port, true)
	imap.login(login, password)
	trashName = detectTrash(imap)
	junkName = detectJunk(imap)
	return [ imap, trashName, junkName ]
end

def getMessageData(imap, message_id)
	body = imap.uid_fetch(message_id, "BODY.PEEK[]")[0].attr["BODY[]"].encode('utf-8', 'binary', :invalid => :replace, :undef => :replace, :replace => '')
	envelope = imap.uid_fetch(message_id, "ENVELOPE")[0].attr["ENVELOPE"]
	if !body
		body = "NONE"
	else
		body = body.gsub(/\r/, "")
	end
	subject = myDecode(envelope.subject)
	if envelope.from
		from = "#{envelope.from[0].mailbox}@#{envelope.from[0].host}"
	else
		from = "NONE"
	end
	if envelope.to
		to = "#{envelope.to[0].mailbox}@#{envelope.to[0].host}"
	else
		to = "NONE"
	end
	if envelope.date
		date = myParseDate(envelope.date)
	else
		date = Time.now
	end
	return [ subject, from, to, date, body ]
end

def handleMessage(options)
	if options.has_key?("imap")
		imap = options["imap"]
	else
		puts "handleMessage(): error: no 'imap' parameter"
		return 0
	end
	if options.has_key?("message_id")
		message_id = options["message_id"]
	else
		puts "handleMessage(): error: no 'message_id' parameter"
		return 0
	end
	if options.has_key?("trashName")
		trashName = options["trashName"]
	else
		puts "handleMessage(): error: no 'trashName' parameter"
		return 0
	end
	if options.has_key?("junkName")
		junkName = options["junkName"]
	else
		puts "handleMessage(): error: no 'junkName' parameter"
		return 0
	end
	if options.has_key?("spamassassin")
		spamassassin = options["spamassassin"]
	else
		spamassassin = false
	end
	if options.has_key?("age")
		age = options["age"]
	else
		age = -1
	end
	subject, from, to, date, body = getMessageData(imap, message_id)
	if age > 0
		dateMinimum = DateTime.now - age;
		if date < dateMinimum
			puts "\nDEBUG: this message is too old and will be deleted"
			describe(imap, message_id)
			moveTo(imap, message_id, trashName)
		end
	end

	# Example filters
#	if from == "sampleService@mydomain.com" && /Subject example/.match(subject)
#		moveTo(imap, message_id, 'sample-imap-directory')
#		return
#	end

#	service2 = [ "\\[something\\] ", "\\[other example\\] whatever", " i do not want to read this messages " ]
#	service2Regex =  "(" + service2.join('|') + ")"
#	if ((from == "serviceTwo@second.domain.com") || (from == "other@client.com")) && /#{service2Regex}/.match(subject)
#		puts "\nDEBUG: message from service2: subject(#{subject})"
#		moveTo(imap, message_id, 'system-messages/service2')
#		return
#	end

#	if from == "BackupExec@domain.local" && /Backup Exec Alert: (Backup Job Contains No Data|Job (Failed|Canceled|Success|Cancellation|Completed with Exceptions)|Media Warning) /.match(subject) && (! /do not ignore this/.match(subject))
#		puts "\nDEBUG: BackupExec"
#		describe(imap, message_id)
#		moveTo(imap, message_id, 'backup-exec-messages', { "markreaded" => true})
#		return
#	end

#	if /(\broot@)/.match(from) && /(\/etc\/cron\.daily|CRON-APT|Cron .* (run-parts \/etc\/cron\.daily)\b|HylaFAX Usage Report)/.match(subject)
#		puts "\nDEBUG: cron"
#		moveTo(imap, message_id, 'INBOX/system-messages')
#		return
#	end
#	if /postmaster@mail.company-2.net/.match(from) && /Some king od notification/.match(subject)
#		# Delete without moving to trash.
#		imap.uid_store(message_id, "+FLAGS", [:Deleted])
#		return
#	end
	if foo = (/(?i:#{$fromAlwaysDeleteRegex})/.match(from))
		puts "\nDEBUG: detected unwanted FROM #{foo[1]}"
		describe(imap, message_id)
		messageLearn(imap, message_id, "spam")
		moveTo(imap, message_id, "spam-archive", { "markreaded" => true })
		return
	end
	if foo = (/(?i:#{$toAlwaysDeleteRegex})/.match(to))
		puts "\nDEBUG: detected unwanted TO #{foo[1]}"
		describe(imap, message_id)
		messageLearn(imap, message_id, "spam")
		moveTo(imap, message_id, "spam-archive", { "markreaded" => true })
		return
	end
	if spamassassin == true
		puts "\nDEBUG: handleMessage(): spamassassin: downloading message"
		file = downloadMessage(imap, message_id)
		describe(imap, message_id)
		command = "spamassassin -e '" + file.path + "' >/dev/null"
		ret = system(command)
		puts "DEBUG: handleMessage(): spamassassin: spamassassin returned: #{ret}, $?: (#{$?})"
		if ret != true
			moveTo(imap, message_id, junkName)
		end
		file.close
		file.unlink
	end
end

def directoryLearn3(i, imap, db, message_id, count, type, moveToDir, allMessages)
	statement = "NONE"
	myhash = "NONE"
	problem = false
	begin
		if i % 100 == 0
			imap.expunge
		end
		envelope = imap.uid_fetch(message_id, "ENVELOPE")[0].attr["ENVELOPE"]
		myhash = calculateMessageId(envelope, message_id.to_s)
		if myhash == "NONE"
			puts "\nError while calculating my message id!"
			return
		end
		if (!myhash) || (myhash == "")
			puts "\nDEBUG: directoryLearn3(): myhash is empty!!!"
			describe(imap, message_id, i, count)
		end
		found = false
		statement = "select * from ids where messageid = ?"
		db.execute(statement, myhash) do |row|
			found = true
		end
		if (found == false) || (allMessages == true)
			if found == false
				statement = "insert into ids values(NULL, ?)"
				db.execute_batch(statement, myhash)
			end
			messageLearn(imap, message_id, type)
			if moveToDir != "NONE"
				moveTo(imap, message_id, moveToDir)
			end
		end
	rescue => detail
		puts "\nException in directoryLearn3()!"
		puts "Last value of 'statement' variable: (#{statement})"
		puts "Last value of 'myhash' variable: (#{myhash})"
		print detail.backtrace.join("\n")
		puts ""
		problem = true
	end
	if problem == true
		exit
	end
end

def directoryLearn2(dir, imap, type, moveToDir, allMessages)
	puts "DEBUG: directoryLearn2(): dir(#{dir}) type(#{type}) moveToDir(#{moveToDir}) allMessages(#{allMessages})"
	imap.select(dir)
	imap.expunge
	searchResult = imap.uid_search(["ALL"])
	count = searchResult.length
	if count > 0
		print "#{count}: "
		i = 1
		SQLite3::Database.new("imap-batch-seen-sqlite.db") do |db|
			searchResult.each do |message_id|
				if i % 10 == 0
					print "#{i}"
				else
					print "."
				end
				directoryLearn3(i, imap, db, message_id, count, type, moveToDir, allMessages)
				i += 1
			end
			puts ""
		end
	end
	imap.expunge
end

def directoryLearn(options)
	if options.has_key?("imap")
		imap = options["imap"]
	else
		puts "directoryLearn(): error: no 'imap' parameter"
		return 0
	end
	if options.has_key?("type")
		type = options["type"]
	else
		puts "directoryLearn(): error: no 'type' parameter"
		return 0
	end
	if options.has_key?("moveToDir")
		moveToDir = options["moveToDir"]
	else
		moveToDir = "NONE"
	end
	if options.has_key?("allMessages")
		allMessages = options["allMessages"]
	else
		allMessages = false
	end
	if options.has_key?("recursive")
		recursive = options["recursive"]
	else
		recursive = false
	end
	if options.has_key?("dir")
		dir = options["dir"]
	else
		puts "directoryLearn(): error: no 'dir' parameter"
		return 0
	end
	puts "DEBUG: directoryLearn(): dir(#{dir}) type(#{type}) recursive(#{recursive}) moveToDir(#{moveToDir}) allMessages(#{allMessages})"
	dirs = [ dir ]
	if recursive == true
		dirs = listDirs(imap, dir)
	end
	dirs.each do |dir2|
		directoryLearn2(dir2, imap, type, moveToDir, allMessages)
	end
end

def handleImapDir(options)
	if options.has_key?("imap")
		imap = options["imap"]
	else
		puts "handleImapDir(): error: no 'imap' parameter"
		return 0
	end
	if options.has_key?("dir")
		dir = options["dir"]
	else
		puts "handleImapDir(): error: no 'dir' parameter"
		return 0
	end
	if options.has_key?("trashName")
		trashName = options["trashName"]
	else
		puts "handleImapDir(): error: no 'trashName' parameter"
		return 0
	end
	if options.has_key?("junkName")
		junkName = options["junkName"]
	else
		junkName = "Junk"
	end
	if options.has_key?("age")
		age = options["age"]
	else
		age = -1
	end
	if options.has_key?("spamassassin")
		spamassassin = options["spamassassin"]
	else
		spamassassin = false
	end
	if options.has_key?("allMessages")
		allMessages = options["allMessages"]
	else
		allMessages = false
	end
	puts "DEBUG: handleImapDir(): dir(#{dir}) trashName(#{trashName}) allMessages(#{allMessages})"
	imap.select(dir)
	imap.expunge
	searchResult = imap.uid_search(["ALL"])
	count = searchResult.length
	if count > 0
		print "#{count}: "
		i = 1
		SQLite3::Database.new("imap-batch-seen-sqlite.db") do |db|
			searchResult.each do |message_id|
				if i % 10 == 0
					print "#{i}"
				else
					print "."
				end
				if i % 100 == 0
					imap.expunge
				end
				envelope = imap.uid_fetch(message_id, "ENVELOPE")[0].attr["ENVELOPE"]
				myhash = calculateMessageId(envelope, message_id.to_s)
				if myhash == "NONE"
					puts "\nError while calculating my message id!"
					return
				end
				found = false
				statement = "select * from ids where messageid = ?"
				db.execute(statement, myhash) do |row|
					found = true
				end
				if (found == false) || (allMessages == true)
					if found == false
						statement = "insert into ids values(NULL, ?)"
						db.execute_batch(statement, myhash)
					end
					handleMessage({ "imap" => imap, "message_id" => message_id, "trashName" => trashName, "age" => age, "spamassassin" => spamassassin, "junkName" => junkName })
				end
				i += 1
			end
			puts ""
		end
	end
	imap.expunge
end

def listDirectoryContent(imap, dir)
	imap.select(dir)
	searchResult = imap.uid_search(["ALL"])
	count = searchResult.length
	if count > 0
		i = 1
		searchResult.each do |message_id|
			describe(imap, message_id, i, count)
			i += 1
		end
		puts ""
	end
end

def listDirs(imap, dir = "")
	ret = Array.new
	imap.list("", "*").each do |foo|
		ret << foo.name
	end
	return ret
end

def moveDirContentBetweenServers(srcImap, srcDir, dstImap, dstDir, options = {})
	if options.has_key?("markreaded")
		markreaded = options["markreaded"]
	else
		markreaded = false
	end
	puts "DEBUG: moveDirContentBetweenServers(srcDir(#{srcDir}), dstDir(#{dstDir}))"
	srcImap.select(srcDir)
	dstImap.select(dstDir)
	srcImap.expunge
	searchResult = srcImap.uid_search(["ALL"])
	count = searchResult.length
	if count > 0
		i = 1
		searchResult.each do |message_id|
			describe(srcImap, message_id, i, count)
			file = Tempfile.new(['imap-batch', '.eml'])
			file.sync = true
			begin
				file.write(srcImap.uid_fetch(message_id, "BODY.PEEK[]")[0].attr["BODY[]"])
				file.rewind
				problem = false
				begin
					if markreaded == true
						dstImap.append(dstDir, file.read, [:Seen])
					else
						dstImap.append(dstDir, file.read)
					end
				rescue => detail
					problem = true
					puts "Error while uploadning message to server!"
					print detail.backtrace.join("\n")
					puts ""
				end
				if problem == false
					srcImap.uid_store(message_id, "+FLAGS", [:Deleted])
				end
			ensure
				file.close
				file.unlink
			end
			i += 1
		end
		puts "Expunge"
		srcImap.expunge
		puts ""
	end
end

def deleteOld(options)
	puts "DEBUG: deleteOld()"
	if options.has_key?("imap")
		imap = options["imap"]
	else
		puts "deleteOld(): error: no 'imap' parameter"
		return 0
	end
	if options.has_key?("dir")
		dir = options["dir"]
	else
		puts "deleteOld(): error: no 'dir' parameter"
		return 0
	end
	if options.has_key?("days")
		days = options["days"]
		if days < 0
			puts "deleteOld(): error: days < 0"
			return 0
		end
	else
		puts "deleteOld(): error: no 'days' parameter"
		return 0
	end
	if options.has_key?("trashName")
		trashName = options["trashName"]
	else
		puts "deleteOld(): error: no 'trashName' parameter"
		return 0
	end
	puts "DEBUG: deleteOld(): dir #{dir}, imap time based deletion"
	imap.select(dir)
	imap.expunge
	myTime = Time.now - 60 * 60 * 24 * days;
	searchResult = imap.uid_search(["BEFORE", Net::IMAP.format_date(myTime)])
	count = searchResult.length
	if count > 0
		i = 1
		searchResult.each do |message_id|
			describe(imap, message_id, i, count)
			moveTo(imap, message_id, trashName)
			i += 1
		end
		puts ""
		imap.expunge
	end

	dateMin = DateTime.now - days;
	puts "DEBUG: deleteOld(): dir #{dir}: header date based deletion; dateMin(#{dateMin}), days(#{days})"
	searchResult = imap.uid_search(["ALL"])
	count = searchResult.length
	if count > 0
		print "#{count}: "
		i = 1
		searchResult.each do |message_id|
			if i % 10 == 0
				print "#{i}"
			else
				print "."
			end
			if i % 100 == 0
				imap.expunge
			end
			subject, from, to, date, body = getMessageData(imap, message_id)
			if date < dateMin
				puts "\nDEBUG: this message will be deleted because it's too old"
				describe(imap, message_id)
				imap.uid_store(message_id, "+FLAGS", [:Deleted])
			end
			i += 1
		end
		puts ""
		imap.expunge
	end
end

def calculateMessageId(envelope, imap_message_id)
	if envelope.message_id
		messageid = envelope.message_id
	else
		messageid = "NONE"
	end
	if envelope.subject
		subject = envelope.subject
	else
		subject = "NONE"
	end
	if envelope.from
		from = ""
		envelope.from.each do |z|
			if z.mailbox
				from << z.mailbox
			end
			from << "@"
			if z.host
				from << z.host
			end
			from << ","
		end
	else
		from = "NONE"
	end
	if envelope.to
		to = ""
		envelope.to.each do |z|
			if z.mailbox
				to << z.mailbox
			end
			to << "@"
			if z.host
				to << z.host
			end
			to << ","
		end
	else
		to = "NONE"
	end
	if envelope.date
		date = myParseDate(envelope.date).strftime("%Y.%m.%d %H.%M.%S")
	else
		date = Time.now
	end
	if ((from == "NONE") && (to == "NONE") && (subject == "NONE") && (messageid == "NONE"))
		puts "\nError! from, to, subject and message id are empty!"
		return "NONE"
	end
	myhash = from + ":" + to + ":" + date + ":" + subject + ":" + messageid + ":" + imap_message_id
	myhash.downcase!
	return myhash
end

def removeDuplicates3(message_id, i, imap, trashName)
	if i % 100 == 0
		imap.expunge
	end
	envelope = imap.uid_fetch(message_id, "ENVELOPE")[0].attr["ENVELOPE"]
	myhash = calculateMessageId(envelope, message_id.to_s)
	if myhash == "NONE"
		puts "\nError while calculating my message id!"
		return
	end
	if $hashes.include?(myhash)
		print "d"
		if i % 10 == 0
			print "#{i}"
		end
		moveTo(imap, message_id, trashName)
	else
		if i % 10 == 0
			print "#{i}"
		else
			print "."
		end
		$hashes << myhash
	end
end

def removeDuplicates2(a, imap, trashName)
	# Adjust following regexp. Put here list of directories names
	# that you do not want to be scanned for duplicates.
	if ! /(Contacts|Junk|Chats|Trash).*/.match(a.name)
		puts "\nremoveDuplicates(): processing directory #{a.name}"
		imap.select(a.name)
		imap.expunge
		searchResult = imap.uid_search(["ALL"])
		count = searchResult.length
		if count > 0
			i = 1
			print "#{count}: "
			searchResult.each do |message_id|
				begin
					removeDuplicates3(message_id, i, imap, trashName)
				rescue => detail
					puts "\nException in removeDuplicates, messages loop, removeDuplicates3() function!"
					print detail.backtrace.join("\n")
					puts ""
				end
				i += 1
			end
			imap.expunge
		end
	end
end

def removeDuplicates(options)
	puts "DEBUG: removeDuplicates()"
	if options.has_key?("imap")
		imap = options["imap"]
	else
		puts "removeDuplicates(): error: no 'imap' parameter"
		return 0
	end
	if options.has_key?("trashName")
		trashName = options["trashName"]
	else
		puts "removeDuplicates(): error: no 'trashName' parameter"
		return 0
	end
	imap.list("", "*").each do |a|
		begin
			removeDuplicates2(a, imap, trashName)
		rescue => detail
			puts "\nException in removeDuplicates(), directories loop, removeDuplicates2() function, directory #{a.name}!"
			print detail.backtrace.join("\n")
			puts ""
		end
	end
	puts ""
end

# Uploads messages from local directory to imap directory.
# Each message needs to be in separate file (like in Maildir).
# Warning!!! After successfull upload file is removed!
def uploadFromDisk(imapConn, importDir, imapDir)
	i = 1
	Dir.foreach(importDir) do |f|
		if f == "." || f == ".."
			next
		end
		puts "[#{i}] #{f}"
		file = File.open("#{importDir}/#{f}")
		problem = false
		begin
			imapConn.append(imapDir, file.read)
		rescue => detail
			problem = true
			puts "Error while uploadning message to server!"
			print detail.backtrace.join("\n")
			puts ""
		end
		file.close
		if problem == false
			File.unlink("#{importDir}/#{f}")
		end
		i += 1
	end
	puts "Expunge"
	imapConn.expunge
end

def initiate
	puts "Connecting to first account"
	firstAccountImap, firstAccountTrashName, secondAccountJunkName = connectImapAccount('first.server.com', 'foobar', 'This Is Ex4mple Password', 993)
	puts "Connecting to second account"
	secondAccountImap, secondAccountTrashName, secondAccountJunkName = connectImapAccount('imap.two.net', 'john@two.net', 'E4ample Password This Is')

	puts "All connections are up."
	return {
		"firstAccountImap" => firstAccountImap,
		"firstAccountTrashName" => firstAccountTrashName,
		"firstAccountJunkName" => firstAccountJunkName,
		"secondAccountImap" => secondAccountImap,
		"secondAccountTrashName" => secondAccountTrashName,
		"secondAccountJunkName" => secondAccountJunkName,
	}
end

def mainPart(options)
	puts ""
	puts "=== Running. " + Time.now.to_s + " ==="
	firstAccountImap = options["firstAccountImap"]
	firstAccountTrashName = options["firstAccountTrashName"]
	firstAccountJunkName = options["firstAccountJunkName"]
	secondAccountImap = options["secondAccountImap"]
	secondAccountTrashName = options["secondAccountTrashName"]
	secondAccountJunkName = options["secondAccountJunkName"]
	if $alternative == false
		##############################################################
		# First account
		puts ""
		puts "[!] First account"
		handleImapDir({ "imap" => firstAccountImap, "dir" => 'INBOX', "trashName" => firstAccountTrashName, "junkName" => firstAccountJunkName, "spamassassin" => true })
		przeczesz({ "imap" => firstAccountImap, "dir" => 'Junk E-Mail', "trashName" => firstAccountTrashName, "age" => 30 })
		deleteOld({ "imap" => firstAccountImap, "dir" => dir, "days" => 30, "trashName" => firstAccountTrashName })
		directoryLearn({ "imap" => firstAccountImap, "dir" => "imap-batch-auto/learn-as-ham", "type" => "ham", "moveTo" => "imap-batch-auto/learn-as-ham/done", "allMessages" => true })
		directoryLearn({ "imap" => firstAccountImap, "dir" => "imap-batch-auto/learn-as-spam", "type" => "spam", "moveTo" => "imap-batch-auto/learn-as-spam/done", "allMessages" => true })
		##############################################################
		# Second account
		puts ""
		puts "[!] Second account"
		moveDirContentBetweenServers(secondAccountImap, '[Gmail]/Spam', firstAccountImap, 'Junk/gmail')
		moveDirContentBetweenServers(secondAccountImap, '[Gmail]/Sent Mail', firstAccountImap, 'Sent', { "markreaded" => true })
		deleteFromDirBySearch(firstAccountImap, "Sent", firstAccountTrashName, "note from me to me", ["TO", "my@first.address", "FROM", "my@second.address", "SUBJECT", "note" ])
	else
		# Some examples
		uploadFromDisk(firstAccountImap, "/home/mylogin/imap-import/new", "imported")
		removeDuplicates({ "imap" => secondAccountImap, "trashName" => secondAccountTrashName })
		directoryLearn({ "imap" => firstAccountImap, "dir" => "Archives", "type" => "ham", "recursive" => true })
	end
end

def closeConnections(options)
	firstAccountImap = options["firstAccountImap"]
	secondAccountImap = options["secondAccountImap"]
	begin
		puts "Logout, disconnect: First account"
		firstAccountImap.logout
		firstAccountImap.disconnect
	rescue => detail
		puts "Exception!"
		print detail.backtrace.join("\n")
		puts ""
	end

	begin
		puts "Logout, disconnect: Second account"
		secondAccountImap.logout
		secondAccountImap.disconnect
	rescue => detail
		puts "Exception!"
		print detail.backtrace.join("\n")
		puts ""
	end
end

while true
	initiateError = false
	begin
		options = initiate
	rescue => detail
		initiateError = true
		puts "Error while initiating connections!"
		print detail.backtrace.join("\n")
		puts ""
	end

	wantToQuit = false
	begin
		if initiateError == false
			while true
				mainPart(options)
				puts "Sleep."
				sleep(600)
			end
		end
	rescue Interrupt => detail
		puts "Interrupt (ctrl+c?) in main loop!"
		print detail.backtrace.join("\n")
		puts ""
		wantToQuit = true
	rescue StandardError => detail
		puts "Exception in main loop!"
		print detail.backtrace.join("\n")
		puts ""
	end

	closeConnections(options)
	if wantToQuit == true
		exit
	end
	puts "Sleep 360."
	sleep(360)
end
