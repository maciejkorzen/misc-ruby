#!/usr/bin/env ruby
# encoding: utf-8
##### DESCRIPTION ###########################################################
# Swiss-knife all-in-one tool kind of script to do batch processing of
# messages at IMAP account(s). It can do filtering, move messages from one
# account to other and other fancy things. You need to know Ruby to use it.
#
##### USAGE #################################################################
# 1) Install following Ruby modules:
#      - rfc2047
# 2) Review the script and modify variables and filters to suit your needs.
# 3) Run it.
#
##### LICENSE ###############################################################
# Copyright 2013 Maciej Korzen
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
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
require 'pp'
require 'rfc2047'
require 'tempfile'
require 'thread'

OpenSSL::SSL::VERIFY_PEER = OpenSSL::SSL::VERIFY_NONE

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

def moveTo(imap, message_id, target)
	problem = false
	begin
		imap.uid_copy(message_id, target)
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
	date2 = DateTime.parse(envelope.date).strftime("%Y.%m.%d %H.%M.%S")
	if (i >= 0) && (count >= 0)
		print "[#{i}/#{count}]"
	else
		print "[+]"
	end
	puts " #{date2} - #{subject.strip} - #{from} - #{to}"
	return 0
end

def downloadMessage(imap, message_id)
	file = Tempfile.new(['imap-batch', '.eml'])
	begin
		file.write(imap.uid_fetch(message_id, "BODY.PEEK[]")[0].attr["BODY[]"])
	ensure
		file.close
		file.unlink
	end
end

def processResult(searchResult, description, imap, trashName)
	count = searchResult.length
	if count > 0
		puts "#{description}"
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

def connectImapAccount(address, login, password)
	imap = Net::IMAP.new(address, 993, true)
	imap.login(login, password)
	trashName = detectTrash(imap)
	return [ imap, trashName ]
end

def getMessageData(imap, message_id)
	body = imap.uid_fetch(message_id, "BODY.PEEK[]")[0].attr["BODY[]"].encode('utf-8', 'binary', :invalid => :replace, :undef => :replace, :replace => '')
	envelope = imap.uid_fetch(message_id, "ENVELOPE")[0].attr["ENVELOPE"]
	if !body
		body = "NONE"
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
		date = DateTime.parse(envelope.date)
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
#		moveTo(imap, message_id, 'backup-exec-messages')
#		return
#	end

#	if /(\broot@)/.match(from) && /(\/etc\/cron\.daily|CRON-APT|Cron .* (run-parts \/etc\/cron\.daily)\b|HylaFAX Usage Report)/.match(subject)
#		puts "\nDEBUG: cron"
#		moveTo(imap, message_id, 'INBOX/system-messages')
#		return
#	end
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
	if options.has_key?("age")
		age = options["age"]
	else
		age = -1
	end
	puts "DEBUG: handleImapDir(): dir(#{dir}) trashName(#{trashName})"
	imap.select(dir)
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
			handleMessage({ "imap" => imap, "message_id" => message_id, "trashName" => trashName, "age" => age })
			i += 1
		end
		puts ""
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
	imap.list("", "*").each do |foo|
		puts foo.name
	end
end

def moveDirContentBetweenServers(srcImap, srcDir, dstImap, dstDir)
	puts "DEBUG: moveDirContentBetweenServers()"
	srcImap.select(srcDir)
	dstImap.select(dstDir)
	searchResult = srcImap.uid_search(["ALL"])
	count = searchResult.length
	if count > 0
		i = 1
		searchResult.each do |message_id|
			describe(srcImap, message_id, i, count)
			file = Tempfile.new(['imap-batch', '.eml'])
			begin
				file.write(srcImap.uid_fetch(message_id, "BODY.PEEK[]")[0].attr["BODY[]"])
				file.rewind
				problem = false
				begin
					dstImap.append(dstDir, file.read)
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
	puts "DEBUG: deleteOld(): dir #{dir}"
	imap.select(dir)
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
	end
	imap.expunge
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

##############################################################
# Do the actual work.

firstAccountImap, firstAccountTrashName = connectImapAccount('first.server.com', 'foobar', 'This Is Ex4mple Password')
secondAccountImap, secondAccountTrashName = connectImapAccount('imap.two.net', 'john@two.net', 'E4ample Password This Is')

moveDirContentBetweenServers(firstAccountImap, 'INBOX/system-messages', secondAccountImap, 'INBOX/system-messages')

uploadFromDisk(firstAccountImap, "/home/mylogin/imap-import/new", "imported")

firstAccountImap.logout
firstAccountImap.disconnect
secondAccountImap.logout
secondAccountImap.disconnect
