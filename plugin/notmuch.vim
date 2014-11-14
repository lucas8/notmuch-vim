if exists("g:loaded_notmuch")
	finish
endif

if !has("ruby") || version < 700
	finish
endif

let g:loaded_notmuch = "yep"

let g:notmuch_folders_maps = {
	\ '<Enter>':	'folders_show_search()',
	\ 's':		'folders_search_prompt()',
	\ 'A':		'folders_tag_all("-inbox -unread")',
	\ '=':		'folders_refresh()',
	\ 'c':		'compose("")',
	\ }

let g:notmuch_search_maps = {
	\ 'q':		'kill_this_buffer()',
	\ '<Enter>':	'search_show_thread(1)',
	\ '<Space>':	'search_show_thread(2)',
	\ 'A':		'search_tag_all("-inbox -unread")',
	\ 'a':		'search_tag("-inbox -unread")',
	\ 'I':		'search_tag("-unread")',
	\ 't':		'search_tag("")',
	\ 's':		'search_search_prompt()',
	\ '=':		'search_refresh()',
	\ '?':		'search_info()',
	\ 'c':		'compose("")',
	\ }

let g:notmuch_show_maps = {
	\ 'q':		'kill_this_buffer()',
	\ 'a':		'show_tag("-inbox -unread")',
	\ 'I':		'show_tag("-unread")',
	\ 't':		'show_tag("")',
	\ 'o':		'show_open_msg()',
	\ 'e':		'show_extract_msg()',
	\ '<Enter>':	'show_view_magic()',
	\ 's':		'show_save_msg()',
	\ 'p':		'show_save_patches()',
	\ 'r':		'show_reply()',
	\ '?':		'show_info()',
	\ '<S-Tab>':	'show_prev_msg()',
	\ '<Tab>':	'show_next_msg("unread")',
	\ 'c':		'compose("")',
	\ }

let g:notmuch_compose_maps = {
	\ ',s':		'compose_send()',
	\ ',q':		'compose_quit()',
	\ }

let s:notmuch_folders_default = [
	\ [ 'new', 'tag:inbox and tag:unread' ],
	\ [ 'inbox', 'tag:inbox' ],
	\ [ 'unread', 'tag:unread' ],
	\ ]

let s:notmuch_show_headers_default = [
	\ 'Subject',
	\ 'To',
	\ 'Cc',
	\ 'Date',
	\ 'Message-ID',
	\ ]

let s:notmuch_date_format_default = '%d.%m.%y'
let s:notmuch_datetime_format_default = '%d.%m.%y %H:%M:%S'
let s:notmuch_reader_default = 'mutt -f %s'
let s:notmuch_sendmail_default = 'sendmail'
let s:notmuch_view_attachment_default = 'xdg-open'
let s:notmuch_attachment_tmpdir_default = '~/.notmuch/tmp'
let s:notmuch_save_sent_locally_default = 1
let s:notmuch_save_sent_mailbox_default = 'Sent'
let s:notmuch_folders_count_threads_default = 0
let s:notmuch_compose_start_insert_default = 0
let s:notmuch_show_folded_full_headers_default = 1
let s:notmuch_show_folded_threads_default = 1
let s:notmuch_open_uri_default = 'xdg-open'

function! s:new_file_buffer(type, fname)
	exec printf('edit %s', a:fname)
	execute printf('set filetype=notmuch-%s', a:type)
	execute printf('set syntax=notmuch-%s', a:type)
	ruby $curbuf.init(VIM::evaluate('a:type'))
endfunction

function! s:on_compose_delete()
	if b:compose_done
		return
	endif
	if input('[s]end/[q]uit? ') =~ '^s'
		call s:compose_send()
	endif
endfunction

"" actions

function! s:compose_quit()
	let b:compose_done = 1
	call s:kill_this_buffer()
endfunction

function! s:compose_send()
	let b:compose_done = 1
	let fname = expand('%')
	let lines = getline(7, '$')

ruby << EOF
	# Generate proper mail to send
	text = VIM::evaluate('lines').join("\n")
	fname = VIM::evaluate('fname')
	nm = Mail.new(text)
	nm.message_id = generate_message_id
	nm.charset = 'utf-8'
	attachment = nil
	files = []
	nm.header.fields.each do |f|
		if f.name == 'Attach' and f.value.length > 0 and f.value !~ /^\s+/
			# We can't just do the attachment here because it screws up the
			# headers and makes our loop incorrect.
			files.push(f.value)
			attachment = f
		end
	end

	files.each do |f|
		vim_puts("Attaching file #{f}")
		nm.add_file(f)
	end

	if attachment
		# This deletes them all as it matches the key 'name' which is
		# 'Attach'.  We want to do this because we don't really want
		# those to be part of the header.
		nm.header.fields.delete(attachment)
		# Force a multipart message.  I actually think this might be
		# a bug in the mail ruby gem but..
		nm.text_part = Mail::Part.new(nm.body)
		nm.html_part = Mail::Part.new(nm.body)
	end

	File.write(fname, nm.to_s)
EOF

	let cmdtxt = g:notmuch_sendmail . ' -t -f ' . s:reply_from . ' < ' . fname
	let out = system(cmdtxt)
	let err = v:shell_error
	if err
		echohl Error
		echo 'Eeek! unable to send mail'
		echo out
		echohl None
		return
	endif

	if g:notmuch_save_sent_locally
		let out = system('notmuch insert --create-folder --folder=' . g:notmuch_save_sent_mailbox . ' +sent -unread -inbox < ' . fname)
		let err = v:shell_error
		if err
			echohl Error
			echo 'Eeek! unable to save sent mail'
			echo out
			echohl None
			return
		endif
	endif
	call delete(fname)
	echo 'Mail sent successfully.'
	call s:kill_this_buffer()
endfunction

function! s:show_prev_msg()
ruby << EOF
	r, c = $curwin.cursor
	n = $curbuf.line_number
	messages = $curbuf.messages
	i = messages.index { |m| n >= m.start && n < m.end }
	m = messages[i - 1] if i > 0
	if m
		fold = VIM::evaluate("foldclosed(#{m.start})")
		if fold > 0
			# If we are moving to a fold then we don't want to move
			# into the fold as it doesn't seem right once you open it.
			VIM::command("normal #{m.start}zt")
		else
			r = m.body_start + 1
			scrolloff = VIM::evaluate("&scrolloff")
			VIM::command("normal #{m.start + scrolloff}zt")
			$curwin.cursor = r + scrolloff, c
		end
	end
EOF
endfunction

function! s:show_next_msg(matching_tag)
ruby << EOF
	matching_tag = VIM::evaluate('a:matching_tag')

	r, c = $curwin.cursor
	n = $curbuf.line_number
	messages = $curbuf.messages
	i = messages.index { |m| n >= m.start && n < m.end }
	i = i + 1
	found_msg = nil
	while i < messages.length and found_msg == nil
		m = messages[i]
		if matching_tag.length > 0
			m.tags.each do |tag|
				if tag == matching_tag
					found_msg = m
					break
				end
			end
		else
			found_msg = m
			break
		end
		i = i + 1
	end

	if found_msg
		fold = VIM::evaluate("foldclosed(#{found_msg.start})")
		if fold > 0
			# If we are moving to a fold then we don't want to move
			# into the fold as it doesn't seem right once you open it.
			VIM::command("normal #{found_msg.start}zt")
		else
			r = found_msg.body_start + 1
			scrolloff = VIM::evaluate("&scrolloff")
			VIM::command("normal #{found_msg.start + scrolloff}zt")
			$curwin.cursor = r + scrolloff, c
		end
	end
EOF
endfunction

function! s:show_reply()
	ruby open_reply get_message.mail
	let b:compose_done = 0
	call s:set_map(g:notmuch_compose_maps)
	autocmd BufDelete <buffer> call s:on_compose_delete()
	if g:notmuch_compose_start_insert
		startinsert!
	end
endfunction

function! s:compose(to_email)
	ruby open_compose(VIM::evaluate('a:to_email'))
	let b:compose_done = 0
	call s:set_map(g:notmuch_compose_maps)
	autocmd BufDelete <buffer> call s:on_compose_delete()
	if g:notmuch_compose_start_insert
		startinsert!
	end
endfunction

function! s:show_info()
	ruby vim_puts get_message.inspect
endfunction

function! s:show_view_magic()
	let line = getline(".")
	let pos = getpos(".")
	let lineno = pos[1]
	let fold = foldclosed(lineno)
ruby << EOF
	line = VIM::evaluate('line')
	lineno = VIM::evaluate('lineno')
	fold = VIM::evaluate('fold')
	# Also use enter to open folds.  After using 'enter' to get
	# all the way to here it feels very natural to want to use it
	# to open folds too.
	if fold > 0
		VIM::command('foldopen')
		scrolloff = VIM::evaluate("&scrolloff")
		vim_puts("Moving to #{lineno} + #{scrolloff} zt")
		# We use relative movement here because of the folds
		# within the messages (header folds).  If you use absolute movement the
		# cursor will get stuck in the fold.
		VIM::command("normal #{scrolloff}j")
		VIM::command("normal zt")
	else
		# Easiest to check for 'Part' types first..
		match = line.match(/^Part (\d*):/)
		if match and match.length == 2
			VIM::command('call s:show_view_attachment()')
		else
			VIM::command('call s:show_open_uri()')
		end
	end
EOF
endfunction

function! s:show_view_attachment()
	let line = getline(".")
ruby << EOF
	m = get_message
	line = VIM::evaluate('line')

	match = line.match(/^Part (\d*):/)
	if match and match.length == 2
		# Set up the tmpdir
		tmpdir = VIM::evaluate('g:notmuch_attachment_tmpdir')
		tmpdir = File.expand_path(tmpdir)
		Dir.mkdir(tmpdir) unless Dir.exists?(tmpdir)

		p = m.mail.parts[match[1].to_i - 1]
		if p == nil
			# Not a multipart message, use the message itself.
			p = m.mail
		end
		if p.filename and p.filename.length > 0
			filename = p.filename
		else
			suffix = ''
			if p.mime_type == 'text/html'
				suffix = '.html'
			end
			filename = "part-#{match[1]}#{suffix}"
		end

		# Sanitize just in case..
		filename.gsub!(/[^0-9A-Za-z.\-]/, '_')

		fullpath = File.expand_path("#{tmpdir}/#{filename}")
		vim_puts "Viewing attachment #{fullpath}"
		File.open(fullpath, 'w') do |f|
			f.write p.body.decoded
			cmd = VIM::evaluate('g:notmuch_view_attachment')
			system(cmd, fullpath)
		end
	else
		vim_puts "No attachment on this line."
	end
EOF
endfunction

function! s:show_extract_msg()
	let line = getline(".")
ruby << EOF
	m = get_message
	line = VIM::evaluate('line')

	# If the user is on a line that has an 'Part'
	# line, we just extract the one attachment.
	match = line.match(/^Part (\d*):/)
	if match and match.length == 2
		a = m.mail.parts[match[1].to_i - 1]
		File.open(a.filename, 'w') do |f|
			f.write a.body.decoded
			vim_puts "Extracted #{a.filename}"
		end
	else
		# Extract them all..
		m.mail.attachments.each do |a|
			File.open(a.filename, 'w') do |f|
				f.write a.body.decoded
				vim_puts "Extracted #{a.filename}"
			end
		end
	end
EOF
endfunction

function! s:show_open_uri()
	let line = getline(".")
	let pos = getpos(".")
	let col = pos[2]
ruby << EOF
	m = get_message
	line = VIM::evaluate('line')
	col = VIM::evaluate('col') - 1
	uris = URI.extract(line)
	wanted_uri = nil
	if uris.length == 1
		wanted_uri = uris[0]
	else
		uris.each do |uri|
			# Check to see the URI is at the present cursor location
			idx = line.index(uri)
			if col >= idx and col <= idx + uri.length
				wanted_uri = uri
				break
			end
		end
	end

	if wanted_uri
		uri = URI.parse(wanted_uri)
		if uri.class == URI::MailTo
			vim_puts("Composing new email to #{uri.to}.")
			VIM::command("call s:compose('#{uri.to}')")
		elsif uri.class == URI::MsgID
			msg = $curbuf.message(uri.opaque)
			if !msg
				vim_puts("Message not found in NotMuch database: #{uri.to_s}")
			else
				vim_puts("Opening message #{msg.message_id} in thread #{msg.thread_id}.")
				VIM::command("call s:show('thread:#{msg.thread_id}', '#{msg.message_id}')")
			end
		else
			vim_puts("Opening #{uri.to_s}.")
			cmd = VIM::evaluate('g:notmuch_open_uri')
			system(cmd, uri.to_s)
		end
	else
		vim_puts('URI not found.')
	end
EOF
endfunction

function! s:show_open_msg()
ruby << EOF
	m = get_message
	mbox = File.expand_path('~/.notmuch/vim_mbox')
	cmd = VIM::evaluate('g:notmuch_reader') % mbox
	system "notmuch show --format=mbox id:#{m.message_id} > #{mbox} && #{cmd}"
EOF
endfunction

function! s:show_save_msg()
	let file = input('File name: ')
ruby << EOF
	file = VIM::evaluate('file')
	m = get_message
	system "notmuch show --format=mbox id:#{m.message_id} > #{file}"
EOF
endfunction

function! s:show_save_patches()
	let dir = input('Save to directory: ', getcwd(), 'dir')
ruby << EOF
	dir = VIM::evaluate('dir')
	if File.exists?(dir)
		q = $curbuf.query($curbuf.cur_thread)
		t = q.search_threads.first
		n = 0
		m = get_message
		t.messages.each do |m|
			next if not m['subject'] =~ /\[PATCH.*\]/
			next if m['subject'] =~ /^Re:/
			subject = m['subject']
			# Sanitize for the filesystem
			subject.gsub!(/[^0-9A-Za-z.\-]/, '_')
			# Remove leading underscores.
			subject.gsub!(/^_+/, '')
			# git style numbered patchset format.
			file = "#{dir}/%04d-#{subject}.patch" % [n += 1]
			vim_puts "Saving patch to #{file}"
			system "notmuch show --format=mbox id:#{m.message_id} > #{file}"
		end
		vim_puts "Saved #{n} patch(es)"
	else
		VIM::command('redraw')
		vim_puts "ERROR: Invalid directory: #{dir}"
	end
EOF
endfunction

function! s:show_tag(intags)
	if empty(a:intags)
		let tags = input('tags: ')
	else
		let tags = a:intags
	endif
	ruby do_tag(get_cur_view, VIM::evaluate('l:tags'))
	call s:show_next_thread()
endfunction

function! s:search_search_prompt()
	let text = input('Search: ')
	if text == ""
	  return
	endif
	setlocal modifiable
ruby << EOF
	$cur_search = VIM::evaluate('text')
	$curbuf.reopen
	search_render($cur_search)
EOF
	setlocal nomodifiable
endfunction

function! s:search_info()
	ruby vim_puts get_thread_id
endfunction

function! s:search_refresh()
	setlocal modifiable
	ruby $curbuf.reopen
	ruby search_render($cur_search)
	setlocal nomodifiable
endfunction

function! s:search_tag(intags)
	if empty(a:intags)
		let tags = input('tags: ')
	else
		let tags = a:intags
	endif
	ruby do_tag(get_thread_id, VIM::evaluate('l:tags'))
	norm j
endfunction

function! s:search_tag_all(intags)
	if empty(a:intags)
		let tags = input('tags: ')
	else
		let tags = a:intags
	endif
	ruby do_tag($cur_search, VIM::evaluate('l:tags'))
	echo 'Tagged all search results with '.a:intags
endfunction

function! s:folders_search_prompt()
	let text = input('Search: ')
	call s:search(text)
endfunction

function! s:folders_refresh()
	setlocal modifiable
	ruby $curbuf.reopen
	ruby folders_render()
	setlocal nomodifiable
endfunction

"" basic

function! s:show_cursor_moved()
ruby << EOF
	if $render.is_ready?
		VIM::command('setlocal modifiable')
		$render.do_next
		VIM::command('setlocal nomodifiable')
	end
EOF
endfunction

function! s:show_next_thread()
	call s:kill_this_buffer()
	if line('.') != line('$')
		norm j
		call s:search_show_thread(0)
	else
		echo 'No more messages.'
	endif
endfunction

function! s:kill_this_buffer()
ruby << EOF
	$curbuf.close
	VIM::command("bdelete!")
EOF
endfunction

function! s:set_map(maps)
	nmapclear <buffer>
	for [key, code] in items(a:maps)
		let cmd = printf(":call <SID>%s<CR>", code)
		exec printf('nnoremap <buffer> %s %s', key, cmd)
	endfor
endfunction

function! s:new_buffer(type)
	enew
	setlocal buftype=nofile bufhidden=hide
	keepjumps 0d
	execute printf('set filetype=notmuch-%s', a:type)
	execute printf('set syntax=notmuch-%s', a:type)
	ruby $curbuf.init(VIM::evaluate('a:type'))
endfunction

function! s:set_menu_buffer()
	setlocal nomodifiable
	setlocal cursorline
	setlocal nowrap
endfunction

"" main

function! s:show(thread_id, msg_id)
	call s:new_buffer('show')
	setlocal modifiable
ruby << EOF
	show_full_headers = VIM::evaluate('g:notmuch_show_folded_full_headers')
	show_threads_folded = VIM::evaluate('g:notmuch_show_folded_threads')

	thread_id = VIM::evaluate('a:thread_id')
	msg_id = VIM::evaluate('a:msg_id')
	$curbuf.cur_thread = thread_id
	messages = $curbuf.messages
	messages.clear
	$curbuf.render do |b|
		q = $curbuf.query(get_cur_view)
		q.sort = Notmuch::SORT_OLDEST_FIRST
		msgs = q.search_messages
		msgs.each do |msg|
			m = Mail.read(msg.filename)
			part = m.find_first_text
			nm_m = Message.new(msg, m)
			messages << nm_m
			date_fmt = VIM::evaluate('g:notmuch_datetime_format')
			date = Time.at(msg.date).strftime(date_fmt)
			nm_m.start = b.count
			b << "From: %s %s (%s)" % [msg['from'], date, msg.tags]
			showheaders = VIM::evaluate('g:notmuch_show_headers')
			showheaders.each do |h|
				b << "%s: %s" % [h, m.header[h]]
			end
			if show_full_headers
				# Now show the rest in a folded area.
				nm_m.full_header_start = b.count
				m.header.fields.each do |k|
					# Only show the ones we haven't already printed out.
					if not showheaders.include?(k.name)
					    b << '%s: %s' % [k.name, k.to_s]
					end
				end
				nm_m.full_header_end = b.count
			end
			cnt = 0
			m.parts.each do |p|
				cnt += 1
				b << "Part %d: %s (%s)" % [cnt, p.mime_type, p.filename]
			end
			# Add a special case for text/html messages.  Here we show the
			# only 'part' so that we can view it in a web browser if we want.
			if m.parts.length == 0 and part.mime_type == 'text/html'
				b << "Part 1: text/html"
			end
			nm_m.body_start = b.count
			b << "--- %s ---" % part.mime_type
			part.convert.each_line do |l|
				b << l.chomp
			end
			b << ""
			nm_m.end = b.count
			if !msg_id.empty? and nm_m.message_id == msg_id
				VIM::command("normal #{nm_m.start}zt")
			end
		end
		b.delete(b.count)
	end
	messages = $curbuf.messages
	messages.each_with_index do |msg, i|
		VIM::command("syntax region nmShowMsg#{i}Desc start='\\%%%il' end='\\%%%il' contains=@nmShowMsgDesc" % [msg.start, msg.start + 1])
		VIM::command("syntax region nmShowMsg#{i}Head start='\\%%%il' end='\\%%%il' contains=@nmShowMsgHead" % [msg.start + 1, msg.full_header_start])
		VIM::command("syntax region nmShowMsg#{i}Body start='\\%%%il' end='\\%%%dl' contains=@nmShowMsgBody" % [msg.body_start, msg.end])
		if show_full_headers
			VIM::command("syntax region nmFold#{i}Headers start='\\%%%il' end='\\%%%il' fold transparent contains=@nmShowMsgHead" % [msg.full_header_start, msg.full_header_end])
		end
		# Only fold the whole message if there are multiple emails in this thread.
		if messages.count > 1 and show_threads_folded
			VIM::command("syntax region nmShowMsgFold#{i} start='\\%%%il' end='\\%%%il' fold transparent contains=ALL" % [msg.start, msg.end])
		end
	end
EOF
	setlocal nomodifiable
	setlocal foldmethod=syntax
	call s:set_map(g:notmuch_show_maps)
endfunction

function! s:search_show_thread(mode)
ruby << EOF
	mode = VIM::evaluate('a:mode')
	id = get_thread_id
	case mode
	when 0;
	when 1; $cur_filter = nil
	when 2; $cur_filter = $cur_search
	end
	VIM::command("call s:show('#{id}', '')")
EOF
endfunction

function! s:search(search)
	call s:new_buffer('search')
ruby << EOF
	$cur_search = VIM::evaluate('a:search')
	search_render($cur_search)
EOF
	call s:set_menu_buffer()
	call s:set_map(g:notmuch_search_maps)
	autocmd CursorMoved <buffer> call s:show_cursor_moved()
endfunction

function! s:folders_show_search()
ruby << EOF
	n = $curbuf.line_number
	s = $searches[n - 1]
	if s.length > 0
		VIM::command("call s:search('#{s}')")
	end
EOF
endfunction

function! s:folders_tag_all(tags)
ruby << EOF
	n = $curbuf.line_number
	s = $searches[n - 1]
	t = VIM::evaluate('a:tags')
	do_tag(s, t)
EOF
	call s:folders_refresh()
endfunction

function! s:folders()
	call s:new_buffer('folders')
	ruby folders_render()
	call s:set_menu_buffer()
	call s:set_map(g:notmuch_folders_maps)
	autocmd BufEnter,WinEnter,BufWinEnter <buffer>
		    \ call s:folders_refresh()
	augroup END
endfunction

"" root

function! s:set_defaults()
	if !exists('g:notmuch_save_sent_locally')
		let g:notmuch_save_sent_locally = s:notmuch_save_sent_locally_default
	endif

	if !exists('g:notmuch_save_sent_mailbox')
		let g:notmuch_save_sent_mailbox = s:notmuch_save_sent_mailbox_default
	endif

	if !exists('g:notmuch_date_format')
		let g:notmuch_date_format = s:notmuch_date_format_default
	endif

	if !exists('g:notmuch_datetime_format')
		let g:notmuch_datetime_format = s:notmuch_datetime_format_default
	endif

	if !exists('g:notmuch_open_uri')
		let g:notmuch_open_uri = s:notmuch_open_uri_default
	endif

	if !exists('g:notmuch_reader')
		let g:notmuch_reader = s:notmuch_reader_default
	endif

	if !exists('g:notmuch_sendmail')
		let g:notmuch_sendmail = s:notmuch_sendmail_default
	endif

	if !exists('g:notmuch_attachment_tmpdir')
		let g:notmuch_attachment_tmpdir = s:notmuch_attachment_tmpdir_default
	endif

	if !exists('g:notmuch_view_attachment')
		let g:notmuch_view_attachment = s:notmuch_view_attachment_default
	endif

	if !exists('g:notmuch_folders_count_threads')
		let g:notmuch_folders_count_threads = s:notmuch_folders_count_threads_default
	endif

	if !exists('g:notmuch_compose_start_insert')
		let g:notmuch_compose_start_insert = s:notmuch_compose_start_insert_default
	endif

	if !exists('g:notmuch_custom_search_maps') && exists('g:notmuch_rb_custom_search_maps')
		let g:notmuch_custom_search_maps = g:notmuch_rb_custom_search_maps
	endif

	if !exists('g:notmuch_custom_show_maps') && exists('g:notmuch_rb_custom_show_maps')
		let g:notmuch_custom_show_maps = g:notmuch_rb_custom_show_maps
	endif

	if exists('g:notmuch_custom_search_maps')
		call extend(g:notmuch_search_maps, g:notmuch_custom_search_maps)
	endif

	if exists('g:notmuch_custom_show_maps')
		call extend(g:notmuch_show_maps, g:notmuch_custom_show_maps)
	endif

	if !exists('g:notmuch_folders')
		let g:notmuch_folders = s:notmuch_folders_default
	endif

	if !exists('g:notmuch_show_headers')
		let g:notmuch_show_headers = s:notmuch_show_headers_default
	endif

	if !exists('g:notmuch_show_folded_threads')
		let g:notmuch_show_folded_threads = s:notmuch_show_folded_threads_default
	endif

	if !exists('g:notmuch_show_folded_full_headers')
		let g:notmuch_show_folded_full_headers = s:notmuch_show_folded_full_headers_default
	endif

endfunction

let s:plug = expand("<sfile>:h")
let s:script = s:plug . '/notmuch.rb'

function! s:NotMuch(...)
	call s:set_defaults()

ruby << EOF
	notmuch = VIM::evaluate('s:script')
	require notmuch
EOF

	if a:0
	  call s:search(join(a:000))
	else
	  call s:folders()
	endif
endfunction

command -nargs=* NotMuch call s:NotMuch(<f-args>)

" vim: set noexpandtab:
