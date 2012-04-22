if exists("g:loaded_notmuch_rb")
	finish
endif

if !has("ruby") || version < 700
	finish
endif

let g:loaded_notmuch_rb = "yep"

let g:notmuch_rb_folders_maps = {
	\ '<Enter>':	':call <SID>NM_folders_show_search()<CR>',
	\ '=':		':call <SID>NM_folders_refresh()<CR>',
	\ }

let g:notmuch_rb_search_maps = {
	\ 'q':		':call <SID>NM_kill_this_buffer()<CR>',
	\ '<Enter>':	':call <SID>NM_search_show_thread()<CR>',
	\ 'A':		':call <SID>NM_search_mark_read_then_archive_thread()<CR>',
	\ 'I':		':call <SID>NM_search_mark_read_thread()<CR>',
	\ '=':		':call <SID>NM_search_refresh()<CR>',
	\ }

let g:notmuch_rb_show_maps = {
	\ 'q':		':call <SID>NM_kill_this_buffer()<CR>',
	\ 'A':		':call <SID>NM_show_mark_read_then_archive_thread()<CR>',
	\ 'I':		':call <SID>NM_show_mark_read_thread()<CR>',
	\ }

let s:notmuch_rb_folders_default = [
	\ [ 'new', 'tag:inbox and tag:unread' ],
	\ [ 'inbox', 'tag:inbox' ],
	\ [ 'unread', 'tag:unread' ],
	\ ]

let s:notmuch_rb_date_format_default = '%d.%m.%y'
let s:notmuch_rb_datetime_format_default = '%d.%m.%y %H:%M:%S'

if !exists('g:notmuch_rb_folders')
	let g:notmuch_rb_folders = s:notmuch_rb_folders_default
endif

if !exists('g:notmuch_rb_date_format')
	let g:notmuch_rb_date_format = s:notmuch_rb_date_format_default
endif

if !exists('g:notmuch_rb_datetime_format')
	let g:notmuch_rb_datetime_format = s:notmuch_rb_datetime_format_default
endif

"" actions

function! s:NM_show_mark_read_then_archive_thread()
ruby << EOF
	do_tag($cur_thread, "-inbox -unread")
EOF
	call <SID>NM_show_next_thread()
endfunction

function! s:NM_show_mark_read_thread()
ruby << EOF
	do_tag($cur_thread, "-unread")
EOF
	call <SID>NM_show_next_thread()
endfunction

function! s:NM_search_refresh()
	setlocal modifiable
ruby << EOF
	search_render($cur_search)
EOF
	setlocal nomodifiable
endfunction

function! s:NM_search_mark_read_then_archive_thread()
ruby << EOF
	do_tag(get_thread_id, "-inbox -unread")
EOF
	norm j
endfunction

function! s:NM_search_mark_read_thread()
ruby << EOF
	do_tag(get_thread_id, "-unread")
EOF
	norm j
endfunction

function! s:NM_folders_refresh()
	setlocal modifiable
ruby << EOF
	folders_render()
EOF
	setlocal nomodifiable
endfunction

"" basic

function! s:NM_show_next_thread()
	call <SID>NM_kill_this_buffer()
	if line('.') != line('$')
		norm j
		call <SID>NM_search_show_thread()
	else
		echo 'No more messages.'
	endif
endfunction

function! s:NM_kill_this_buffer()
	bdelete!
ruby << EOF
	$buf_queue.pop
	b = $buf_queue.last
	VIM::command("buffer #{b}") if b
EOF
endfunction

function! s:NM_set_map(maps)
	nmapclear
	for [key, code] in items(a:maps)
		exec printf('nnoremap <buffer> %s %s', key, code)
	endfor
endfunction

function! s:NM_new_buffer(type)
	enew
	setlocal buftype=nofile bufhidden=hide
	keepjumps 0d
	execute printf('set filetype=notmuch-%s', a:type)
	execute printf('set syntax=notmuch-%s', a:type)
ruby << EOF
	$buf_queue.push(VIM::Buffer::current.number)
EOF
endfunction

function! s:NM_set_menu_buffer()
	setlocal nomodifiable
	setlocal cursorline
	setlocal nowrap
endfunction

"" main

function! s:NM_show(thread_id)
	call <SID>NM_new_buffer('show')
ruby << EOF
	thread_id = VIM::evaluate('a:thread_id')
	$cur_thread = thread_id
	VIM::Buffer::current.render do |b|
		do_read do |db|
			q = db.query(thread_id)
			msgs = q.search_messages
			msgs.each do |msg|
				m = Mail.read(msg.filename)
				part = m.find_first_text
				date_fmt = VIM::evaluate('g:notmuch_rb_datetime_format')
				date = Time.at(msg.date).strftime(date_fmt)
				b << "%s %s (%s)" % [msg['from'], date, msg.tags]
				b << "Subject: %s" % [msg['subject']]
				b << "To: %s" % m['to']
				b << "Cc: %s" % m['cc']
				b << "Date: %s" % m['date']
				b << "--- %s ---" % part.mime_type
				part.convert.each_line do |l|
					b << l.chomp
				end
				b << ""
			end
		end
	end
EOF
	call <SID>NM_set_map(g:notmuch_rb_show_maps)
endfunction

function! s:NM_search_show_thread()
ruby << EOF
	id = get_thread_id
	VIM::command("call <SID>NM_show('#{id}')")
EOF
endfunction

function! s:NM_search(words)
	call <SID>NM_new_buffer('search')
ruby << EOF
	$cur_search = VIM::evaluate('a:words')
	search_render($cur_search)
EOF
	call <SID>NM_set_menu_buffer()
	call <SID>NM_set_map(g:notmuch_rb_search_maps)
endfunction

function! s:NM_folders_show_search()
ruby << EOF
	n = VIM::Buffer::current.line_number
	s = $searches[n - 1]
	VIM::command("call <SID>NM_search(['#{s}'])")
EOF
endfunction

function! s:NM_folders()
	call <SID>NM_new_buffer('folders')
ruby << EOF
	folders_render()
EOF
	call <SID>NM_set_menu_buffer()
	call <SID>NM_set_map(g:notmuch_rb_folders_maps)
endfunction

"" root

function! s:NotMuchR()
ruby << EOF
	require 'notmuch'
	require 'rubygems'
	require 'mail'

	$db_name = VIM::evaluate('g:notmuch_rb_database')
	$searches = []
	$buf_queue = []
	$threads = []

	def vim_p(s)
		VIM::command("echo '#{s}'")
	end

	def author_filter(a)
		# TODO email format, aliases
		a.strip!
		a.gsub!(/[\.@].*/, '')
		a.gsub!(/^ext /, '')
		a.gsub!(/ \(.*\)/, '')
		a
	end

	def get_thread_id
		n = VIM::Buffer::current.line_number - 1
		return "thread:%s" % $threads[n]
	end

	def do_write
		db = Notmuch::Database.new($db_name, :mode => Notmuch::MODE_READ_WRITE)
		yield db
		db.close
	end

	def do_read
		db = Notmuch::Database.new($db_name)
		yield db
		db.close
	end

	def folders_render()
		VIM::Buffer::current.render do |b|
			folders = VIM::evaluate('g:notmuch_rb_folders')
			$searches.clear
			do_read do |db|
				folders.each do |name, search|
					q = db.query(search)
					$searches << search
					b << "%9d %-20s (%s)" % [q.search_threads.count, name, search]
				end
			end
		end
	end

	def search_render(search)
		VIM::Buffer::current.render do |b|
			date_fmt = VIM::evaluate('g:notmuch_rb_date_format')
			do_read do |db|
				q = db.query(search.join(" "))
				$threads.clear
				q.search_threads.each do |e|
					authors = e.authors.force_encoding('utf-8').split(/[,|]/).map { |a| author_filter(a) }.join(",")
					date = Time.at(e.newest_date).strftime(date_fmt)
					b << "%-12s %3s %-20.20s | %s (%s)" % [date, e.total_messages, authors, e.subject, e.tags]
					$threads << e.thread_id
				end
			end
		end
	end

	def do_tag(filter, tags)
		do_write do |db|
			q = db.query(filter)
			q.search_messages.each do |e|
				tags.split.each do |t|
					case t
					when /^-(.*)/
						e.remove_tag($1)
					when /^\+(.*)/
						e.add_tag($1)
					end
				end
			end
		end
	end

	class VIM::Buffer
		def <<(a)
			append(count(), a)
		end
		def render
			old_count = count
			yield self
			(1..old_count).each do
				delete(1)
			end
		end
	end

	class Notmuch::Tags
		def to_s
			to_a.join(" ")
		end
	end

	class Notmuch::Message
		def to_s
			"id:%s" % message_id
		end
	end

	# workaround for bug in vim's ruby
	class Object
		def flush
		end
	end

	class Mail::Message
		def find_first_text
			return self if not multipart?
			return text_part || html_part
		end

		def convert
			text = decoded
			if mime_type == "text/html"
				IO.popen("elinks --dump", "w+") do |pipe|
					pipe.write(text)
					pipe.close_write
					text = pipe.read
				end
			end
			text
		end
	end

EOF
	call <SID>NM_folders()
endfunction

command NotMuchR :call <SID>NotMuchR()
