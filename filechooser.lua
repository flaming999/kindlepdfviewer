require "rendertext"
require "keys"
require "graphics"
require "font"
require "filesearcher"
require "filehistory"
require "fileinfo"
require "inputbox"
require "selectmenu"
require "dialog"
require "readerchooser"
require "battery"

FileChooser = {
	title_H = 40,	-- title height
	spacing = 36,	-- spacing between lines
	foot_H = 28,	-- foot height
	margin_H = 10,	-- horisontal margin

	-- state buffer
	dirs = nil,
	files = nil,
	items = 0,
	path = "",
	page = 1,
	current = 1,
	oldcurrent = 0,
	exception_message = nil,

	pagedirty = true,
	markerdirty = false,
	perpage,

	clipboard = lfs.currentdir() .. "/clipboard", -- NO finishing slash
	before_clipboard, -- NuPogodi, 30.09.12: to store the path where jump to clipboard was made from

	-- modes that configures the filechoser for users with various purposes & skills
	filemanager_mode, -- the value is set in reader.lua
	-- symbolic definitions for filemanager_mode
	RESTRICTED = 1, -- the filemanager content is restricted by files with reader-related extensions; safe renaming (no extension)
	UNRESTRICTED = 2, -- no extension-based filtering; renaming with extensions; appreciable danger to crash crengine by improper docs
}

-- NuPogodi, 29.09.12: simplified the code
function getProperTitleLength(txt, font_face, max_width)
	while sizeUtf8Text(0, G_width, font_face, txt, true).x > max_width do
		txt = txt:sub(2, -1)
	end
	return txt
end

-- NuPogodi, 29.09.12: avoid using widgets
function DrawTitle(text, lmargin, y, height, color, font_face)
	local r = 6	-- radius for round corners
	color = 3	-- redefine to ignore the input for background color

	fb.bb:paintRect(1, 1, G_width-2, height - r, color)
	blitbuffer.paintBorder(fb.bb, 1, height/2, G_width-2, height/2, height/2, color, r)

	local t = BatteryLevel() .. os.date(" %H:%M")
	r = sizeUtf8Text(0, G_width, font_face, t, true).x
	renderUtf8Text(fb.bb, G_width-r-lmargin, height-10, font_face, t, true, color/15, 1.0)

	r = G_width - r - 2 * lmargin - 10 -- let's leave small gap
	if sizeUtf8Text(0, G_width, font_face, text, true).x <= r then
		renderUtf8Text(fb.bb, lmargin, height-10, font_face, text, true, color/15, 1.0)
	else
		t = renderUtf8Text(fb.bb, lmargin, height-10, font_face, "...", true, color/15, 1.0)
		text = getProperTitleLength(text, font_face, r-t)
		renderUtf8Text(fb.bb, lmargin+t, height-10, font_face, text, true, color/15, 1.0)
	end
end

function DrawFooter(text,font_face,h)
	local y = G_height - 7
	-- just dirty fix to have the same footer everywhere
	local x = FileChooser.margin_H --(G_width / 2) - 50
	renderUtf8Text(fb.bb, x, y, font_face, text.._(" - Press H for help"), true)
end

function DrawFileItem(name,x,y,image)
	-- define icon file for
	if name == ".." then image = "upfolder" end
	local fn = "./resources/"..image..".png"
	-- check whether the icon file exists or not
	if not io.open(fn, "r") then fn = "./resources/other.png" end
	local iw = ImageWidget:new({ file = fn })
	iw:paintTo(fb.bb, x, y - iw:getSize().h + 1)
	-- then drawing filenames
	local cface = Font:getFace("cfont", 22)
	local xleft = x + iw:getSize().w + 9 -- the gap between icon & filename
	local width = G_width - xleft - x
	-- now printing the name
	if sizeUtf8Text(xleft, G_width - x, cface, name, true).x < width then
		renderUtf8Text(fb.bb, xleft, y, cface, name, true)
	else
		local lgap = sizeUtf8Text(0, width, cface, " ...", true).x
		local handle = renderUtf8TextWidth(fb.bb, xleft, y, cface, name, true, width - lgap - x)
		renderUtf8Text(fb.bb, handle.x + lgap + x, y, cface, " ...", true)
	end
	iw:free()
end

function getAbsolutePath(aPath)
	local abs_path
	if not aPath then
		abs_path = aPath
	elseif aPath:match('^//') then
		abs_path = aPath:sub(2)
	elseif aPath:match('^/') then
		abs_path = aPath
	elseif #aPath == 0 then
		abs_path = '/'
	else
		local curr_dir = lfs.currentdir()
		abs_path = aPath
		if lfs.chdir(aPath) then
			abs_path = lfs.currentdir()
			lfs.chdir(curr_dir)
		end
		--Debug("rel: '"..aPath.."' abs:'"..abs_path.."'")
	end
	return abs_path
end

function FileChooser:readDir()
	self.dirs = {}
	self.files = {}
	for f in lfs.dir(self.path) do
		if lfs.attributes(self.path.."/"..f, "mode") == "directory" and f ~= "." and f~=".."
			and not string.match(f, "^%.[^.]") then
				table.insert(self.dirs, f)
		elseif lfs.attributes(self.path.."/"..f, "mode") == "file"
			and not string.match(f, "^%.[^.]") then
			local file_type = string.lower(string.match(f, ".+%.([^.]+)") or "")
			if ReaderChooser:getReaderByType(file_type) then
				table.insert(self.files, f)
			end
		end
	end
	table.sort(self.dirs)
	if self.path~="/" then table.insert(self.dirs,1,"..") end
	table.sort(self.files)
end

function FileChooser:setPath(newPath, reset_pos)
	local oldPath = self.path
	local search_position = false

	-- We only need to re-scan the directory for the correct
	-- position if we are entering it via ".." entry.
	-- Unfortunately, ".." reaches us in the form of an absolute path,
	-- but we can use the following trick: if we are traversing via "..",
	-- then the new pathname will always be shorter than the old pathname.
	if oldPath ~= "" and #newPath < #oldPath then
		search_position = true
	end

	-- treat ".." entry in the clipboard as
	-- a special case, namely return to the directory saved
	-- in self.before_clipboard
	if self.before_clipboard then
		newPath = self.before_clipboard
		self.before_clipboard = nil
	end

	-- convert to the absolute path so that we can
	-- traverse up to the parent via ".."
	self.path = getAbsolutePath(newPath)

	-- read the whole self.path directory
	-- the error message is stored for display in the header.
	local ret, msg = pcall(self.readDir, self)
	if not ret then
		self.exception_message = msg
		return self:setPath(oldPath)
	else
		self.items = #self.dirs + #self.files

		if newPath == oldPath then
			if reset_pos then
				self.page = 1
				self.current = 1
			end
			return
		end

		if search_position then
			-- extract the base part of oldPath, i.e. the actual directory name
			local pos, _, oldPathBase = string.find(oldPath, "^.*/(.*)$")

			-- now search for the base part of oldPath among self.dirs[]
			for k, v in ipairs(self.dirs) do
				if v == oldPathBase then
					self.current, self.page = gotoTargetItem(k, self.items, self.current, self.page, self.perpage)
					break
				end
			end
		else
			-- point the current position to ".." entry
			self.page = 1
			self.current = 1
		end
	end
end

function FileChooser:choose()
	local ypos = 0

	self.pagedirty = true
	self.markerdirty = false

	self:addAllCommands()

	while true do
		local tface = Font:getFace("tfont", 25)
		local fface = Font:getFace("ffont", 16)
		local cface = Font:getFace("cfont", 22)
		local wlen = G_width - 2*self.margin_H
		self.perpage = math.floor(G_height / self.spacing) - 2

		if self.pagedirty then
			fb.bb:paintRect(0, ypos, G_width, G_height, 0)
			local c
			for c = 1, self.perpage do
				local i = (self.page - 1) * self.perpage + c
				if i <= #self.dirs then
					DrawFileItem(self.dirs[i],self.margin_H,ypos+self.title_H+self.spacing*c,"folder")
				elseif i <= self.items then
					local file_type = string.lower(string.match(self.files[i-#self.dirs], ".+%.([^.]+)") or "")
					DrawFileItem(self.files[i-#self.dirs],self.margin_H,ypos+self.title_H+self.spacing*c,file_type)
				end
			end
			-- draw footer
			all_page = math.ceil(self.items/self.perpage)
			DrawFooter(string.format(_("Page %d of %d"), self.page, all_page),
				fface, self.foot_H)
			-- draw menu title
			local msg = self.exception_message and self.exception_message:match("[^%:]+:%d+: (.*)") or self.path
			self.exception_message = nil
			-- draw header
			DrawTitle(msg,self.margin_H,ypos,self.title_H,3,tface)
			self.markerdirty = true
		end

		if self.markerdirty then
			local ymarker = ypos + 8 + self.title_H
			if not self.pagedirty then
				if self.oldcurrent > 0 then
					fb.bb:paintRect(self.margin_H, ymarker+self.spacing*self.oldcurrent, wlen, 3, 0)
					Screen:refresh(1, nil, self.margin_H, ymarker+self.spacing*self.oldcurrent, wlen, 3)
				end
			end
			fb.bb:paintRect(self.margin_H, ymarker+self.spacing*self.current, wlen, 3, 15)
			if not self.pagedirty then
				Screen:refresh(1, nil, self.margin_H, ymarker+self.spacing*self.current, wlen, 3)
			end
			self.oldcurrent = self.current
			self.markerdirty = false
		end

		if self.pagedirty then
			Screen:refresh(0, nil, 0, ypos, G_width, G_height)
			self.pagedirty = false
		end

		local ev = input.saveWaitForEvent()
		--Debug("key code:"..ev.code)
		ev.code = adjustKeyEvents(ev)
		if ev.type == EV_KEY and ev.value ~= EVENT_VALUE_KEY_RELEASE then
			keydef = Keydef:new(ev.code, getKeyModifier())
			Debug("key pressed: "..tostring(keydef))

			command = self.commands:getByKeydef(keydef)
			if command ~= nil then
				Debug("command to execute: "..tostring(command))
				ret_code = command.func(self, keydef)
			else
				Debug("command not found: "..tostring(command))
			end

			if ret_code == "break" then break end

			if self.selected_item ~= nil then
				Debug("# selected "..self.selected_item)
				return self.selected_item
			end
		end -- if ev.type ==
	end -- while
end

function FileChooser:backToParentDir()
	local path = string.gsub(self.path, "(.*)/[^/]+/?$", "%1")
	self:setPath(path)
end

-- add available commands
function FileChooser:addAllCommands()
	self.commands = Commands:new{}

	self.commands:add(KEY_SPACE, nil, "Space",
		_("refresh file list"),
		function(self)
			self:setPath(self.path)
			self.pagedirty = true
		end
	)
	self.commands:add(KEY_FW_DOWN, nil, "joypad down",
		_("next item"),
		function(self)
			if self.current == self.perpage then
				if self.page < (self.items / self.perpage) then
					self.current = 1
					self.page = self.page + 1
					self.pagedirty = true
				end
			else
				if self.page ~= math.floor(self.items / self.perpage) + 1
					or self.current + (self.page-1)*self.perpage < self.items then
					self.current = self.current + 1
					self.markerdirty = true
				end
			end
		end
	)
	self.commands:add(KEY_FW_UP, nil, "joypad up",
		_("previous item"),
		function(self)
			if self.current == 1 then
				if self.page > 1 then
					self.current = self.perpage
					self.page = self.page - 1
					self.pagedirty = true
				end
			else
				self.current = self.current - 1
				self.markerdirty = true
			end
		end
	)
	-- NuPogodi, 01.10.12: fast jumps to items at positions 10, 20, .. 90, 0% within the list
	local numeric_keydefs, i = {}
	for i=1, 10 do numeric_keydefs[i]=Keydef:new(KEY_1+i-1, nil, tostring(i%10)) end
	self.commands:addGroup("[1, 2 .. 9, 0]", numeric_keydefs,
		_("item at position 0%, 10% .. 90%, 100%"),
		function(self)
			local target_item = math.ceil(self.items * (keydef.keycode-KEY_1) / 9)
			self.current, self.page, self.markerdirty, self.pagedirty =
				gotoTargetItem(target_item, self.items, self.current, self.page, self.perpage)
		end
	)
	self.commands:add({KEY_PGFWD, KEY_LPGFWD}, nil, ">",
		_("next page"),
		function(self)
			if self.page < (self.items / self.perpage) then
				if self.current + self.page*self.perpage > self.items then
					self.current = self.items - self.page*self.perpage
				end
				self.page = self.page + 1
				self.pagedirty = true
			else
				self.current = self.items - (self.page-1)*self.perpage
				self.markerdirty = true
			end
		end
	)
	self.commands:add({KEY_PGBCK, KEY_LPGBCK}, nil, "<",
		_("previous page"),
		function(self)
			if self.page > 1 then
				self.page = self.page - 1
				self.pagedirty = true
			else
				self.current = 1
				self.markerdirty = true
			end
		end
	)
	self.commands:add(KEY_G, nil, "G", -- NuPogodi, 01.10.12: goto page No.
		_("goto page"),
		function(self)
			local n = math.ceil(self.items / self.perpage)
			local page = NumInputBox:input(G_height-100, 100, "Page:", "current page "..self.page.." of "..n, true)
			if pcall(function () page = math.floor(page) end) -- convert string to number
			and page ~= self.page and page > 0 and page <= n then
				self.page = page
				if self.current + (page-1)*self.perpage > self.items then
					self.current = self.items - (page-1)*self.perpage
				end
			end
			self.pagedirty = true
		end
	)
	self.commands:add(KEY_FW_LEFT, nil, "joypad left",
		_("go back to parent directory"),
		function(self)
			self:backToParentDir()
			self.pagedirty = true
		end
	)
	self.commands:add(KEY_FW_RIGHT, nil, "joypad right",
		_("show document information"),
		function(self)
			local folder = self.dirs[self.perpage*(self.page-1)+self.current]
			if folder then
				if folder == ".." then
					warningUnsupportedFunction()
				else
					folder = self.path.."/"..folder
					if FileInfo:show(folder) == "goto" then
						self:setPath(folder)
					end
				end
			else -- file info
				FileInfo:show(self.path, self.files[self.perpage*(self.page-1)+self.current-#self.dirs])
			end
			self.pagedirty = true
		end
	)
	self.commands:add({KEY_ENTER, KEY_FW_PRESS}, nil, "Enter",
		_("open document / goto folder"),
		function(self)
			local newdir = self.dirs[self.perpage*(self.page-1)+self.current]
			if newdir == ".." then
				self:backToParentDir()
			elseif newdir then
				self:setPath(self.path.."/"..newdir)
			else
				self.pathfile = self.path.."/"..self.files[self.perpage*(self.page-1)+self.current - #self.dirs]
				openFile(self.pathfile)
			end
			self.pagedirty = true
		end
	)
	-- modified to delete both files and empty folders
	self.commands:add(KEY_DEL, nil, "Del",
		_("delete selected item"),
		function(self)
			local pos = self.perpage*(self.page-1)+self.current
			if pos > #self.dirs then -- file
				if InfoMessage.InfoMethod[MSG_CONFIRM] == 0 then	-- silent regime
					self:deleteFileAtPosition(pos)
				else
					InfoMessage:inform("Press 'Y' to confirm ", DINFO_NODELAY, 0, MSG_CONFIRM)
					if ReturnKey() == KEY_Y then self:deleteFileAtPosition(pos) end
				end
			elseif self.dirs[pos] == ".." then
				warningUnsupportedFunction()
			else -- other folders
				if InfoMessage.InfoMethod[MSG_CONFIRM] == 0 then -- silent regime
					self:deleteFolderAtPosition(pos)
				else
					InfoMessage:inform("Press 'Y' to confirm ", DINFO_NODELAY, 0, MSG_CONFIRM)
					if ReturnKey() == KEY_Y then self:deleteFolderAtPosition(pos) end
				end
			end
			self.pagedirty = true
		end -- function
	)
	self.commands:add(KEY_R, MOD_SHIFT, "R",
		_("rename file"),
		function(self)
			local oldname = self:FullFileName()
			if oldname then
				local name_we = self.files[self.perpage*(self.page-1)+self.current-#self.dirs]
				local ext = ""
				-- in RESTRICTED mode don't allow renaming extension
				if self.filemanager_mode == self.RESTRICTED then
					ext = "."..string.lower(string.match(oldname, ".+%.([^.]+)") or "")
					name_we = string.sub(name_we, 1, -1-string.len(ext))
				end
				local newname = InputBox:input(0, 0, "New filename:", name_we)
				if newname then
					newname = self.path.."/"..newname..ext
					os.rename(oldname, newname)
					os.rename(DocToHistory(oldname), DocToHistory(newname))
					self:setPath(self.path)
				end
				self.pagedirty = true
			end
		end
	)
	self.commands:add(KEY_M, MOD_ALT, "M",
		_("set file manager mode"),
		function(self)
			self:setFileManagerMode()
		end
	)
	self.commands:add(KEY_E, nil, "E",
		_("configure event notifications"),
		function(self)
			InfoMessage:chooseNotificatonMethods()
			self.pagedirty = true
		end
	)
	self.commands:addGroup("Vol-/+", {Keydef:new(KEY_VPLUS,nil), Keydef:new(KEY_VMINUS,nil)},
		_("decrease/increase sound volume"),
		function(self)
			InfoMessage:incrSoundVolume(keydef.keycode == KEY_VPLUS and 1 or -1)
		end
	)
	self.commands:addGroup(MOD_SHIFT.."Vol-/+", {Keydef:new(KEY_VPLUS,MOD_SHIFT), Keydef:new(KEY_VMINUS,MOD_SHIFT)},
		_("decrease/increase TTS-engine speed"),
		function(self)
			InfoMessage:incrTTSspeed(keydef.keycode == KEY_VPLUS and 1 or -1)
		end
	)
	self.commands:add({KEY_F, KEY_AA}, nil, "F, Aa",
		_("change font faces"),
		function(self)
			Font:chooseFonts()
			self.pagedirty = true
		end
	)
	self.commands:add(KEY_H,nil,"H",
		_("show help page"),
		function(self)
			HelpPage:show(0, G_height, self.commands, "Hotkeys  "..G_program_version)
			self.pagedirty = true
		end
	)
	self.commands:add(KEY_L, nil, "L",
		_("show last documents"),
		function(self)
			FileHistory:init()
			FileHistory:choose("")
			self.pagedirty = true
			return nil
		end
	)
	self.commands:add(KEY_S, nil, "S",
		_("search files (single space matches all)"),
		function(self)
			local keywords = InputBox:input(0, 0, "Search:")
			if keywords then
				InfoMessage:inform("Searching... ", DINFO_NODELAY, 1, MSG_AUX)
				FileSearcher:init( self.path )
				FileSearcher:choose(keywords)
			end
			self.pagedirty = true
		end
	)
	self.commands:add(KEY_C, MOD_SHIFT, "C",
		_("copy file to 'clipboard'"),
		function(self)
			local file = self:FullFileName()
			if file then
				os.execute("cp "..InQuotes(file).." "..self.clipboard)
				local fn = self.files[self.perpage*(self.page-1)+self.current - #self.dirs]
				os.execute("cp "..InQuotes(DocToHistory(file)).." "
					..InQuotes(DocToHistory(self.clipboard.."/"..fn)) )
				InfoMessage:inform("File copied to clipboard ", DINFO_DELAY, 1, MSG_WARN)
			end
		end
	)
	self.commands:add(KEY_X, MOD_SHIFT, "X",
		_("move file to 'clipboard'"),
		function(self)
			-- TODO (NuPogodi, 27.09.12): overwrite?
			local file = self:FullFileName()
			if file then
				local fn = self.files[self.perpage*(self.page-1)+self.current - #self.dirs]
				os.rename(file, self.clipboard.."/"..fn)
				os.rename(DocToHistory(file), DocToHistory(self.clipboard.."/"..fn))
				InfoMessage:inform("File moved to clipboard ", DINFO_DELAY, 0, MSG_WARN)
				local pos = self.perpage*(self.page-1)+self.current
				table.remove(self.files, pos-#self.dirs)
				self.items = self.items - 1
				self.current, self.page = gotoTargetItem(pos, self.items, pos, self.page, self.perpage)
				self.pagedirty = true
			end
		end
	)
	self.commands:add(KEY_V, MOD_SHIFT, "V",
		_("paste file(s) from 'clipboard'"),
		function(self)
			-- TODO (NuPogodi, 27.09.12): first test whether the clipboard is empty & answer respectively
			-- TODO (NuPogodi, 27.09.12): overwrite?
			InfoMessage:inform("Moving files from clipboard...", DINFO_NODELAY, 0, MSG_AUX)
			for f in lfs.dir(self.clipboard) do
				if lfs.attributes(self.clipboard.."/"..f, "mode") == "file" then
					os.rename(self.clipboard.."/"..f, self.path.."/"..f)
					os.rename(DocToHistory(self.clipboard.."/"..f), DocToHistory(self.path.."/"..f))
				end
			end
			self:setPath(self.path)
			self.pagedirty = true
		end
	)
	self.commands:add(KEY_DOT, MOD_ALT, ".",
		_("toggle battery level logging"),
		function(self)
			G_battery_logging = not G_battery_logging
			InfoMessage:inform("Battery logging "..(G_battery_logging and "on " or "off "), DINFO_DELAY, 1, MSG_AUX)
			G_reader_settings:saveSetting("G_battery_logging", G_battery_logging)
		end
	)
	self.commands:add(KEY_B, MOD_SHIFT, "B",
		_("show content of 'clipboard'"),
		function(self)
			-- save the current directory in order to
			-- return from clipboard via ".." entry
			local current_path = self.path
			if self.clipboard ~= self.path then
				self:setPath(self.clipboard)
				self.before_clipboard = current_path
			end
			self.pagedirty = true
		end
	)
	self.commands:add(KEY_N, MOD_SHIFT, "N",
		_("make new folder"),
		function(self)
			local folder = InputBox:input(0, 0, "New Folder:")
			if folder then
				if lfs.mkdir(self.path.."/"..folder) then
					self:setPath(self.path)
				end
			end
			self.pagedirty = true
		end
	)
	self.commands:add(KEY_K, MOD_SHIFT, "K",
		_("run calculator"),
		function(self)
			local CalcBox = InputBox:new{ inputmode = MODE_CALC }
			CalcBox:input(0, 0, "Calc ")
			self.pagedirty = true
		end
	)
	self.commands:addGroup("Home, Alt + Back", { Keydef:new(KEY_HOME, nil),Keydef:new(KEY_BACK, MOD_ALT)},
		_("exit"),
		function(self)
			return "break"
		end
	)
end

-- returns full filename or nil (if folder)
function FileChooser:FullFileName()
	local pos = self.current + self.perpage*(self.page-1) - #self.dirs
	return pos > 0 and self.path.."/"..self.files[pos] or warningUnsupportedFunction()
end

-- returns the keycode of released key
function ReturnKey()
	while true do
		ev = input.saveWaitForEvent()
		ev.code = adjustKeyEvents(ev)
		if ev.type == EV_KEY and ev.value ~= EVENT_VALUE_KEY_RELEASE then
			break
		end
	end
	return ev.code
end

function InQuotes(text)
	return "\""..text.."\""
end

function FileChooser:setFileManagerMode()
	local modes_menu = SelectMenu:new{
		menu_title = _("Set file manager mode"),
		item_array = {
			_("Restricted"),
			_("Unrestricted"),
		},
		current_entry = self.filemanager_mode - 1,
		}
	local m = modes_menu:choose(0, G_height)
	if m and m ~= self.filemanager_mode then
		self.filemanager_mode = m
		self:setPath(self.path,true)
		G_reader_settings:saveSetting("filemanager_mode", self.filemanager_mode)
	end
	self.pagedirty = true
end

-- NuPogodi, 28.09.12: two following functions are extracted just to make the code more compact
function FileChooser:deleteFolderAtPosition(pos)
	if lfs.rmdir(self.path.."/"..self.dirs[pos]) then
		table.remove(self.dirs, pos) -- to avoid showing just deleted file
		self.items = #self.dirs + #self.files
		self.current, self.page = gotoTargetItem(pos, self.items, pos, self.page, self.perpage)
	else
		InfoMessage:inform(_("Directory not empty "), DINFO_DELAY, 1, MSG_ERROR)
	end
end

function FileChooser:deleteFileAtPosition(pos)
	local fullpath = self.path.."/"..self.files[pos-#self.dirs]
	os.remove(fullpath)			-- delete the file itself
	os.remove(DocToHistory(fullpath))	-- and its history file, if any
	table.remove(self.files, pos-#self.dirs)	-- to avoid showing just deleted file
	self.items = self.items - 1
	self.current, self.page = gotoTargetItem(pos, self.items, pos, self.page, self.perpage)
end

-- NuPogodi, 01.10.12: jump to defined item in the itemlist
function gotoTargetItem(target_item, all_items, current_item, current_page, perpage)
	target_item = math.max(math.min(target_item, all_items), 1)
	local target_page = math.ceil(target_item/perpage)
	local target_curr = (target_item -1) % perpage + 1
	local pagedirty, markerdirty = false, false
	if target_page ~= current_page then
		current_page = target_page
		pagedirty = true
		markerdirty = true
	elseif target_curr ~= current_item then
		markerdirty = true
	end
	return target_curr, current_page, markerdirty, pagedirty
end

function warningUnsupportedFunction()
	InfoMessage:inform(_("Unsupported function "), DINFO_DELAY, 1, MSG_WARN)
	return nil
end
