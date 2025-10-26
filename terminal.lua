local ffi = require("ffi")
local terminal = {}

if jit.os == "Windows" then
	local STD_INPUT_HANDLE = -10
	local STD_OUTPUT_HANDLE = -11
	local ENABLE_VIRTUAL_TERMINAL_INPUT = 0x0200
	local DISABLE_NEWLINE_AUTO_RETURN = 0x0008
	local ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0004
	ffi.cdef([[
	struct COORD {
		short X;
		short Y;
	};

	struct KEY_EVENT_RECORD {
		int bKeyDown;
		unsigned short wRepeatCount;
		unsigned short wVirtualKeyCode;
		unsigned short wVirtualScanCode;
		union {
			wchar_t UnicodeChar;
			char AsciiChar;
		} uChar;
		unsigned long dwControlKeyState;
	};

	struct MOUSE_EVENT_RECORD {
	struct COORD dwMousePosition;
	unsigned long dwButtonState;
	unsigned long dwControlKeyState;
	unsigned long dwEventFlags;
	};

	struct WINDOW_BUFFER_SIZE_RECORD {
	struct COORD dwSize;
	};

	struct MENU_EVENT_RECORD {
	unsigned int dwCommandId;
	};

	struct FOCUS_EVENT_RECORD {
	int bSetFocus;
	};

	struct INPUT_RECORD {
	unsigned short  EventType;
	union {
		struct KEY_EVENT_RECORD KeyEvent;
		struct MOUSE_EVENT_RECORD MouseEvent;
		struct WINDOW_BUFFER_SIZE_RECORD WindowBufferSizeEvent;
		struct MENU_EVENT_RECORD MenuEvent;
		struct FOCUS_EVENT_RECORD FocusEvent;
	} Event;
	};


	int PeekConsoleInputA(
		void* hConsoleInput,
		struct INPUT_RECORD* lpBuffer,
		unsigned long nLength,
		unsigned long * lpNumberOfEventsRead
	);

	int ReadConsoleInputA(
		void* hConsoleInput,
		struct INPUT_RECORD* lpBuffer,
		unsigned long nLength,
		unsigned long * lpNumberOfEventsRead
	);

	struct SMALL_RECT {
		uint16_t Left;
		uint16_t Top;
		uint16_t Right;
		uint16_t Bottom;
		};


	struct CONSOLE_SCREEN_BUFFER_INFO {
	struct COORD dwSize;
	struct COORD dwCursorPosition;
	uint16_t wAttributes;
		struct SMALL_RECT srWindow;
	struct COORD dwMaximumWindowSize;
	};

	struct CONSOLE_CURSOR_INFO {
		unsigned long dwSize;
		int bVisible;
	};

	int SetConsoleCursorInfo(
		void *hConsoleOutput,
		const struct CONSOLE_CURSOR_INFO *lpConsoleCursorInfo
	);

	int GetConsoleScreenBufferInfo(
		void* hConsoleOutput,
		struct CONSOLE_SCREEN_BUFFER_INFO* lpConsoleScreenBufferInfo
	);

	int SetConsoleCursorPosition(
		void* hConsoleOutput,
		struct COORD  dwCursorPosition
	);


	int SetConsoleMode(void*, uint16_t);
	int GetConsoleMode(void*, uint16_t*);
	void* GetStdHandle(unsigned long nStdHandle);
	int SetConsoleTitleA(const char*);

	uint32_t GetLastError();

	uint32_t FormatMessageA(
		uint32_t dwFlags,
		const void* lpSource,
		uint32_t dwMessageId,
		uint32_t dwLanguageId,
		char* lpBuffer,
		uint32_t nSize,
		va_list *Arguments
	);

	struct CHAR_INFO {
		union {
			wchar_t UnicodeChar;
			char AsciiChar;
		} Char;
		uint16_t Attributes;
	} CHAR_INFO;
]])
	local error_str = ffi.new("uint8_t[?]", 1024)
	local FORMAT_MESSAGE_FROM_SYSTEM = 0x00001000
	local ENABLE_WINDOW_INPUT = 0x0008
	local FORMAT_MESSAGE_IGNORE_INSERTS = 0x00000200
	local error_flags = bit.bor(FORMAT_MESSAGE_FROM_SYSTEM, FORMAT_MESSAGE_IGNORE_INSERTS)

	local function throw_error()
		local code = ffi.C.GetLastError()
		local numout = ffi.C.FormatMessageA(error_flags, nil, code, 0, error_str, 1023, nil)
		local err = numout ~= 0 and ffi.string(error_str, numout)

		if err and err:sub(-2) == "\r\n" then return err:sub(0, -3) end

		return err
	end

	local mode_flags = {
		ENABLE_ECHO_INPUT = 0x0004,
		ENABLE_EXTENDED_FLAGS = 0x0080,
		ENABLE_INSERT_MODE = 0x0020,
		ENABLE_LINE_INPUT = 0x0002,
		ENABLE_MOUSE_INPUT = 0x0010,
		ENABLE_PROCESSED_INPUT = 0x0001,
		ENABLE_QUICK_EDIT_MODE = 0x0040,
		ENABLE_WINDOW_INPUT = 0x0008,
		ENABLE_VIRTUAL_TERMINAL_INPUT = 0x0200,
		ENABLE_PROCESSED_OUTPUT = 0x0001,
		ENABLE_WRAP_AT_EOL_OUTPUT = 0x0002,
		ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0004,
		DISABLE_NEWLINE_AUTO_RETURN = 0x0008,
		ENABLE_LVB_GRID_WORLDWIDE = 0x0010,
	}
	local stdin = ffi.C.GetStdHandle(STD_INPUT_HANDLE)
	local stdout = ffi.C.GetStdHandle(STD_OUTPUT_HANDLE)
	local old_flags = {}

	local function add_flags(handle, tbl)
		local ptr = ffi.C.GetStdHandle(handle)

		if ptr == nil then throw_error() end

		local flags = ffi.new("uint16_t[1]")

		if ffi.C.GetConsoleMode(ptr, flags) == 0 then throw_error() end

		old_flags[handle] = tonumber(flags[0])
		flags[0] = utility.TableToFlags(tbl, mode_flags, function(out, val)
			return bit.bor(out, val)
		end)

		if ffi.C.SetConsoleMode(ptr, flags[0]) == 0 then throw_error() end
	end

	function terminal.Initialize()
		io.stdin:setvbuf("no")
		io.stdout:setvbuf("no")
		add_flags(
			STD_INPUT_HANDLE,
			{
				--"ENABLE_PROCESSED_OUTPUT",
				--"ENABLE_LINE_INPUT",
				--"ENABLE_QUICK_EDIT_MODE",
				--"ENABLE_EXTENDED_FLAGS",
				--"ENABLE_WRAP_AT_EOL_OUTPUT",
				--"ENABLE_PROCESSED_INPUT",
				--"ENABLE_ECHO_INPUT",
				--"ENABLE_VIRTUAL_TERMINAL_PROCESSING",
				"ENABLE_INSERT_MODE",
			--"ENABLE_VIRTUAL_TERMINAL_INPUT", -- this seems broken to me
			--"ENABLE_WINDOW_INPUT",
			},
			mode_flags
		)
		add_flags(
			STD_OUTPUT_HANDLE,
			{
				--"ENABLE_PROCESSED_OUTPUT",
				"ENABLE_PROCESSED_INPUT",
				--"ENABLE_WRAP_AT_EOL_OUTPUT",
				--"ENABLE_LINE_INPUT",
				"ENABLE_VIRTUAL_TERMINAL_PROCESSING",
			--"DISABLE_NEWLINE_AUTO_RETURN"
			--"DISABLE_NEWLINE_AUTO_RETURN",
			},
			mode_flags
		)
		terminal.suppress_first = true
		terminal.EnableCaret(true)
	end

	local function revert_flags(handle)
		local ptr = ffi.C.GetStdHandle(handle)

		if ptr == nil then throw_error() end

		if ffi.C.SetConsoleMode(ptr, old_flags[handle]) == 0 then throw_error() end
	end

	function terminal.Shutdown()
		revert_flags(STD_INPUT_HANDLE)
		revert_flags(STD_OUTPUT_HANDLE)
	end

	function terminal.EnableCaret(b)
		if
			ffi.C.SetConsoleCursorInfo(
				stdout,
				ffi.new("struct CONSOLE_CURSOR_INFO[1]", {{dwSize = 100, bVisible = b and 1 or 0}})
			) ~= 0
		then

		--error(throw_error())
		end
	end

	function terminal.Write(str)
		if terminal.writing then return end

		terminal.writing = true

		if terminal.OnWrite and terminal.OnWrite(str) ~= false then io.write(str) end

		terminal.writing = false
	end

	function terminal.GetCaretPosition()
		local out = ffi.new("struct CONSOLE_SCREEN_BUFFER_INFO[1]")
		ffi.C.GetConsoleScreenBufferInfo(stdout, out)
		return out[0].dwCursorPosition.X + 1, out[0].dwCursorPosition.Y + 1
	end

	function terminal.SetCaretPosition(x, y)
		local w, h = terminal.GetSize()
		x = math.clamp(math.floor(x) - 1, 0, w)
		y = math.clamp(math.floor(y) - 1, 0, h)
		ffi.C.SetConsoleCursorPosition(stdout, ffi.new("struct COORD", {X = x, Y = y}))
	end

	function terminal.SetCaretPosition(x, y)
		x = math.max(math.floor(x), 0)
		y = math.max(math.floor(y), 0)
		terminal.Write("\27[" .. y .. ";" .. x .. "f")
	end

	function terminal.WriteStringToScreen(x, y, str)
		terminal.Write("\27[s\27[" .. y .. ";" .. x .. "f" .. str .. "\27[u")
	end

	function terminal.SetTitle(str)
		ffi.C.SetConsoleTitleA(str)
	end

	function terminal.Clear()
		os.execute("cls")
	end

	function terminal.GetSize()
		local out = ffi.new("struct CONSOLE_SCREEN_BUFFER_INFO[1]")
		ffi.C.GetConsoleScreenBufferInfo(stdout, out)
		return out[0].dwSize.X, out[0].dwSize.Y
	end

	function terminal.ForegroundColor(r, g, b)
		r = math.floor(r * 255)
		g = math.floor(g * 255)
		b = math.floor(b * 255)
		terminal.Write("\27[38;2;" .. r .. ";" .. g .. ";" .. b .. "m")
	end

	function terminal.ForegroundColorFast(r, g, b)
		terminal.Write(string.format("\27[38;2;%i;%i;%im", r, g, b))
	end

	function terminal.BackgroundColor(r, g, b)
		r = math.floor(r * 255)
		g = math.floor(g * 255)
		b = math.floor(b * 255)
		terminal.Write("\27[48;2;" .. r .. ";" .. g .. ";" .. b .. "m")
	end

	function terminal.ResetColor()
		terminal.Write("\27[0m")
	end

	local keys = {
		MOD_ALT = 0x0001,
		MOD_CONTROL = 0x0002,
		MOD_SHIFT = 0x0004,
		MOD_WIN = 0x0008,
		MOD_NOREPEAT = 0x4000,
		VK_LBUTTON = 0x01,
		VK_RBUTTON = 0x02,
		VK_CANCEL = 0x03,
		VK_MBUTTON = 0x04,
		VK_XBUTTON1 = 0x05,
		VK_XBUTTON2 = 0x06,
		VK_BACK = 0x08,
		VK_TAB = 0x09,
		VK_CLEAR = 0x0C,
		VK_RETURN = 0x0D,
		VK_SHIFT = 0x10,
		VK_CONTROL = 0x11,
		VK_MENU = 0x12,
		VK_PAUSE = 0x13,
		VK_CAPITAL = 0x14,
		VK_KANA = 0x15,
		VK_JUNJA = 0x17,
		VK_FINAL = 0x18,
		VK_KANJI = 0x19,
		VK_ESCAPE = 0x1B,
		VK_CONVERT = 0x1C,
		VK_NONCONVERT = 0x1D,
		VK_ACCEPT = 0x1E,
		VK_MODECHANGE = 0x1F,
		VK_SPACE = 0x20,
		VK_PRIOR = 0x21,
		VK_NEXT = 0x22,
		VK_END = 0x23,
		VK_HOME = 0x24,
		VK_LEFT = 0x25,
		VK_UP = 0x26,
		VK_RIGHT = 0x27,
		VK_DOWN = 0x28,
		VK_SELECT = 0x29,
		VK_PRINT = 0x2A,
		VK_EXECUTE = 0x2B,
		VK_SNAPSHOT = 0x2C,
		VK_INSERT = 0x2D,
		VK_DELETE = 0x2E,
		VK_HELP = 0x2F,
		VK_LWIN = 0x5B,
		VK_RWIN = 0x5C,
		VK_APPS = 0x5D,
		VK_SLEEP = 0x5F,
		VK_NUMPAD0 = 0x60,
		VK_NUMPAD1 = 0x61,
		VK_NUMPAD2 = 0x62,
		VK_NUMPAD3 = 0x63,
		VK_NUMPAD4 = 0x64,
		VK_NUMPAD5 = 0x65,
		VK_NUMPAD6 = 0x66,
		VK_NUMPAD7 = 0x67,
		VK_NUMPAD8 = 0x68,
		VK_NUMPAD9 = 0x69,
		VK_MULTIPLY = 0x6A,
		VK_ADD = 0x6B,
		VK_SEPARATOR = 0x6C,
		VK_SUBTRACT = 0x6D,
		VK_DECIMAL = 0x6E,
		VK_DIVIDE = 0x6F,
		VK_F1 = 0x70,
		VK_F2 = 0x71,
		VK_F3 = 0x72,
		VK_F4 = 0x73,
		VK_F5 = 0x74,
		VK_F6 = 0x75,
		VK_F7 = 0x76,
		VK_F8 = 0x77,
		VK_F9 = 0x78,
		VK_F10 = 0x79,
		VK_F11 = 0x7A,
		VK_F12 = 0x7B,
		VK_F13 = 0x7C,
		VK_F14 = 0x7D,
		VK_F15 = 0x7E,
		VK_F16 = 0x7F,
		VK_F17 = 0x80,
		VK_F18 = 0x81,
		VK_F19 = 0x82,
		VK_F20 = 0x83,
		VK_F21 = 0x84,
		VK_F22 = 0x85,
		VK_F23 = 0x86,
		VK_F24 = 0x87,
		VK_NUMLOCK = 0x90,
		VK_SCROLL = 0x91,
		VK_OEM_NEC_EQUAL = 0x92,
		VK_LSHIFT = 0xA0,
		VK_RSHIFT = 0xA1,
		VK_LCONTROL = 0xA2,
		VK_RCONTROL = 0xA3,
		VK_LMENU = 0xA4,
		VK_RMENU = 0xA5,
		VK_BROWSER_BACK = 0xA6,
		VK_BROWSER_FORWARD = 0xA7,
		VK_BROWSER_REFRESH = 0xA8,
		VK_BROWSER_STOP = 0xA9,
		VK_BROWSER_SEARCH = 0xAA,
		VK_BROWSER_FAVORITES = 0xAB,
		VK_BROWSER_HOME = 0xAC,
		VK_VOLUME_MUTE = 0xAD,
		VK_VOLUME_DOWN = 0xAE,
		VK_VOLUME_UP = 0xAF,
		VK_MEDIA_NEXT_TRACK = 0xB0,
		VK_MEDIA_PREV_TRACK = 0xB1,
		VK_MEDIA_STOP = 0xB2,
		VK_MEDIA_PLAY_PAUSE = 0xB3,
		VK_LAUNCH_MAIL = 0xB4,
		VK_LAUNCH_MEDIA_SELECT = 0xB5,
		VK_LAUNCH_APP1 = 0xB6,
		VK_LAUNCH_APP2 = 0xB7,
		VK_OEM_1 = 0xBA,
		VK_OEM_PLUS = 0xBB,
		VK_OEM_COMMA = 0xBC,
		VK_OEM_MINUS = 0xBD,
		VK_OEM_PERIOD = 0xBE,
		VK_OEM_2 = 0xBF,
		VK_OEM_3 = 0xC0,
		VK_OEM_4 = 0xDB,
		VK_OEM_5 = 0xDC,
		VK_OEM_6 = 0xDD,
		VK_OEM_7 = 0xDE,
		VK_OEM_8 = 0xDF,
		VK_OEM_AX = 0xE1,
		VK_OEM_102 = 0xE2,
		VK_ICO_HELP = 0xE3,
		VK_ICO_00 = 0xE4,
		VK_PROCESSKEY = 0xE5,
		VK_ICO_CLEAR = 0xE6,
		VK_PACKET = 0xE7,
		VK_OEM_RESET = 0xE9,
		VK_OEM_JUMP = 0xEA,
		VK_OEM_PA1 = 0xEB,
		VK_OEM_PA2 = 0xEC,
		VK_OEM_PA3 = 0xED,
		VK_OEM_WSCTRL = 0xEE,
		VK_OEM_CUSEL = 0xEF,
		VK_OEM_ATTN = 0xF0,
		VK_OEM_FINISH = 0xF1,
		VK_OEM_COPY = 0xF2,
		VK_OEM_AUTO = 0xF3,
		VK_OEM_ENLW = 0xF4,
		VK_OEM_BACKTAB = 0xF5,
		VK_ATTN = 0xF6,
		VK_CRSEL = 0xF7,
		VK_EXSEL = 0xF8,
		VK_EREOF = 0xF9,
		VK_PLAY = 0xFA,
		VK_ZOOM = 0xFB,
		VK_NONAME = 0xFC,
		VK_PA1 = 0xFD,
		VK_OEM_CLEAR = 0xFE,
	}
	local modifiers = {
		CAPSLOCK_ON = 0x0080,
		ENHANCED_KEY = 0x0100,
		LEFT_ALT_PRESSED = 0x0002,
		LEFT_CTRL_PRESSED = 0x0008,
		NUMLOCK_ON = 0x0020,
		RIGHT_ALT_PRESSED = 0x0001,
		RIGHT_CTRL_PRESSED = 0x0004,
		SCROLLLOCK_ON = 0x0040,
		SHIFT_PRESSED = 0x0010,
	}

	local function read()
		local events = ffi.new("unsigned long[1]")
		local rec = ffi.new("struct INPUT_RECORD[128]")

		if ffi.C.PeekConsoleInputA(stdin, rec, 128, events) == 0 then
			error(throw_error())
		end

		if events[0] > 0 then
			local rec = ffi.new("struct INPUT_RECORD[?]", events[0])

			if ffi.C.ReadConsoleInputA(stdin, rec, events[0], events) == 0 then
				error(throw_error())
			end

			if terminal.suppress_first then
				terminal.suppress_first = false
				return
			end

			return rec, events[0]
		end
	end

	terminal.event_buffer = {}

	function terminal.ReadEvents()
		local events, count = read()

		if events then
			for i = 1, count do
				local evt = events[i - 1]

				--[[
				print("==========================================================")
				print(i, "bKeyDown: ", evt.Event.KeyEvent.bKeyDown)
				print(i, "wRepeatCount: ", evt.Event.KeyEvent.wRepeatCount)
				print(i, "wVirtualKeyCode: ", evt.Event.KeyEvent.wVirtualKeyCode)
				print(i, "wVirtualScanCode: ", evt.Event.KeyEvent.wVirtualScanCode)
				print(i, "uChar UnicodeChar: ", evt.Event.KeyEvent.uChar.UnicodeChar)
				print(i, "uChar AsciiChar: ", evt.Event.KeyEvent.uChar.AsciiChar)
				print(i, "dwControlKeyState: ", evt.Event.KeyEvent.dwControlKeyState)
				print(i, "char: ", utf8.from_uint32(evt.Event.KeyEvent.uChar.UnicodeChar))
				print(i, "mod: ", utility.FlagsToTable(evt.Event.KeyEvent.dwControlKeyState, modifiers))

				print("==========================================================")
			--]]
				if evt.EventType == 1 then
					if evt.Event.KeyEvent.bKeyDown == 1 then
						local str = utf8.from_uint32(evt.Event.KeyEvent.uChar.UnicodeChar)
						local key = evt.Event.KeyEvent.wVirtualKeyCode
						local mod = utility.FlagsToTable(evt.Event.KeyEvent.dwControlKeyState, modifiers)
						--print(evt.Event.KeyEvent.uChar.UnicodeChar)
						--for k,v in pairs(keys) do if v == key then print(k) end end
						--table.print(mod)
						local CTRL = mod.LEFT_CTRL_PRESSED or mod.RIGHT_CTRL_PRESSED
						local SHIFT = mod.SHIFT_PRESSED or mod.SHIFT_PRESSED

						if
							mod.SHIFT_PRESSED and
							mod.LEFT_ALT_PRESSED and
							evt.Event.KeyEvent.uChar.UnicodeChar == 68
						then
							CTRL = true
							SHIFT = false
							key = keys.VK_DELETE
							mod.SHIFT_PRESSED = nil
							mod.LEFT_ALT_PRESSED = nil
						end

						if SHIFT and evt.Event.KeyEvent.uChar.UnicodeChar ~= 0 then
							list.insert(terminal.event_buffer, {"string", str})
						else
							if str == "\3" then
								list.insert(terminal.event_buffer, {"ctrl_c"})
							elseif CTRL then
								if key == keys.VK_RIGHT then
									list.insert(terminal.event_buffer, {"ctrl_right"})
								elseif key == keys.VK_LEFT then
									list.insert(terminal.event_buffer, {"ctrl_left"})
								elseif key == keys.VK_BACK or evt.Event.KeyEvent.uChar.UnicodeChar == 23 then
									list.insert(terminal.event_buffer, {"ctrl_backspace"})
								elseif key == keys.VK_DELETE or evt.Event.KeyEvent.uChar.UnicodeChar == 68 then
									list.insert(terminal.event_buffer, {"ctrl_delete"})
								end
							else
								if key == keys.VK_RETURN then
									list.insert(terminal.event_buffer, {"enter"})
								elseif key == keys.VK_DELETE then
									list.insert(terminal.event_buffer, {"delete"})
								elseif key == keys.VK_LEFT then
									list.insert(terminal.event_buffer, {"left"})
								elseif key == keys.VK_RIGHT then
									list.insert(terminal.event_buffer, {"right"})
								elseif key == keys.VK_UP then
									list.insert(terminal.event_buffer, {"up"})
								elseif key == keys.VK_DOWN then
									list.insert(terminal.event_buffer, {"down"})
								elseif key == keys.VK_HOME then
									list.insert(terminal.event_buffer, {"home"})
								elseif key == keys.VK_END then
									list.insert(terminal.event_buffer, {"end"})
								elseif key == keys.VK_BACK then
									list.insert(terminal.event_buffer, {"backspace"})
								elseif evt.Event.KeyEvent.uChar.UnicodeChar > 31 then
									list.insert(terminal.event_buffer, {"string", str})
								end
							end
						end
					end
				end
			end
		end

		return terminal.event_buffer
	end
else
	if jit.os ~= "OSX" then
		ffi.cdef([[
            struct termios
            {
                unsigned int c_iflag;		/* input mode flags */
                unsigned int c_oflag;		/* output mode flags */
                unsigned int c_cflag;		/* control mode flags */
                unsigned int c_lflag;		/* local mode flags */
                unsigned char c_line;			/* line discipline */
                unsigned char c_cc[32];		/* control characters */
                unsigned int c_ispeed;		/* input speed */
                unsigned int c_ospeed;		/* output speed */
            };
        ]])
	else
		ffi.cdef([[
            struct termios
            {
                unsigned long c_iflag;		/* input mode flags */
                unsigned long c_oflag;		/* output mode flags */
                unsigned long c_cflag;		/* control mode flags */
                unsigned long c_lflag;		/* local mode flags */
                unsigned char c_cc[20];		/* control characters */
                unsigned long c_ispeed;		/* input speed */
                unsigned long c_ospeed;		/* output speed */
            };
        ]])
	end

	ffi.cdef([[
        int tcgetattr(int, struct termios *);
        int tcsetattr(int, int, const struct termios *);

        typedef struct FILE FILE;
        size_t fwrite(const char *ptr, size_t size, size_t nmemb, FILE *stream);
        size_t fread( char * ptr, size_t size, size_t count, FILE * stream );

        ssize_t read(int fd, void *buf, size_t count);
        int fileno(FILE *stream);

        int ferror(FILE*stream);
    ]])
	local VMIN = 6
	local VTIME = 5
	local TCSANOW = 0
	local flags

	if jit.os ~= "OSX" then
		flags = {
			ECHOCTL = 512,
			EXTPROC = 65536,
			ECHOK = 32,
			NOFLSH = 128,
			FLUSHO = 4096,
			ECHONL = 64,
			ECHOE = 16,
			ECHOKE = 2048,
			ECHO = 8,
			ICANON = 2,
			IEXTEN = 32768,
			PENDIN = 16384,
			XCASE = 4,
			ECHOPRT = 1024,
			TOSTOP = 256,
			ISIG = 1,
		}
	else
		VMIN = 16
		VTIME = 17
		flags = {
			ECHOKE = 0x00000001,
			ECHOE = 0x00000002,
			ECHOK = 0x00000004,
			ECHO = 0x00000008,
			ECHONL = 0x00000010,
			ECHOPRT = 0x00000020,
			ECHOCTL = 0x00000040,
			ISIG = 0x00000080,
			ICANON = 0x00000100,
			ALTWERASE = 0x00000200,
			IEXTEN = 0x00000400,
			EXTPROC = 0x00000800,
			TOSTOP = 0x00400000,
			FLUSHO = 0x00800000,
			NOKERNINFO = 0x02000000,
			PENDIN = 0x20000000,
			NOFLSH = 0x80000000,
		}
	end

	local stdin = 0
	local old_attributes

	function terminal.Initialize()
		io.stdin:setvbuf("no")
		io.stdout:setvbuf("no")

		if not old_attributes then
			old_attributes = ffi.new("struct termios[1]")
			ffi.C.tcgetattr(stdin, old_attributes)
		end

		local attr = ffi.new("struct termios[1]")

		if ffi.C.tcgetattr(stdin, attr) ~= 0 then error(ffi.strerror(), 2) end

		attr[0].c_lflag = bit.band(
			tonumber(attr[0].c_lflag),
			bit.bnot(
				bit.bor(
					flags.ICANON,
					flags.ECHO,
					flags.ISIG,
					flags.ECHOE,
					flags.ECHOCTL,
					flags.ECHOKE,
					flags.ECHOK
				)
			)
		)
		attr[0].c_cc[VMIN] = 0
		attr[0].c_cc[VTIME] = 0

		if ffi.C.tcsetattr(stdin, TCSANOW, attr) ~= 0 then error(ffi.strerror(), 2) end

		if ffi.C.tcgetattr(stdin, attr) ~= 0 then error(ffi.strerror(), 2) end

		if attr[0].c_cc[VMIN] ~= 0 or attr[0].c_cc[VTIME] ~= 0 then
			terminal.Shutdown()
			error("unable to make stdin non blocking", 2)
		end

		terminal.EnableCaret(true)
	end

	function terminal.Shutdown()
		if old_attributes then
			ffi.C.tcsetattr(stdin, TCSANOW, old_attributes)
			old_attributes = nil
		end
	end

	function terminal.EnableCaret(b) end

	function terminal.Clear()
		os.execute("clear")
	end

	do
		local buff = ffi.new("char[512]")
		local buff_size = ffi.sizeof(buff)

		function terminal.Read()
			do
				return io.read()
			end

			local len = ffi.C.read(stdin, buff, buff_size)

			if len > 0 then return ffi.string(buff, len) end
		end
	end

	function terminal.Write(str)
		if terminal.writing then return end

		terminal.writing = true

		if terminal.OnWrite and terminal.OnWrite(str) ~= false then
			terminal.WriteNow(str)
		end

		terminal.writing = false
	end

	function terminal.WriteNow(str)
		ffi.C.fwrite(str, 1, #str, io.stdout)
	end

	function terminal.SetTitle(str)
		--terminal.Write("\27[s\27[0;0f" .. str .. "\27[u")
		io.write(str, "\n")
	end

	function terminal.SetCaretPosition(x, y)
		x = math.max(math.floor(x), 0)
		y = math.max(math.floor(y), 0)
		terminal.Write("\27[" .. y .. ";" .. x .. "f")
	end

	local function add_event(...)
		list.insert(terminal.event_buffer, {...})
	end

	local function process_input(str)
		if str == "" then
			add_event("enter")
			return
		end

		local buf = utility.CreateBuffer(str)
		buf:SetPosition(0)

		while true do
			local c = buf:ReadChar()

			if not c then break end

			if c:byte() < 32 then
				if c == "\27" then
					local c = buf:ReadChar()

					if c == "[" then
						local c = buf:ReadChar()

						if c == "D" then
							add_event("left")
						elseif c == "1" then
							local c = buf:ReadString(3)

							if c == ";5D" then
								add_event("ctrl_left")
							elseif c == ";5C" then
								add_event("ctrl_right")
							elseif c == ";5F" then
								add_event("home")
							elseif c == ";5H" then
								add_event("end")
							end
						elseif c == "C" then
							add_event("right")
						elseif c == "A" then
							add_event("up")
						elseif c == "B" then
							add_event("down")
						elseif c == "H" then
							add_event("home")
						elseif c == "F" then
							add_event("end")
						elseif c == "3" then
							add_event("delete")
							local c = buf:ReadChar()

							if c == ";" then
								-- prevents alt and meta delete key from spilling ;9 and ;3
								buf:Advance(2)
							elseif c ~= "~" then
								-- spill all other keys except ~
								buf:Advance(-1)
							end
						elseif c == "2" then
							add_event("backspace")
						else
							wlog("unhandled control character %q", c)
						end
					elseif c == "b" then
						add_event("ctrl_left")
					elseif c == "f" then
						add_event("ctrl_right")
					elseif c == "d" then
						add_event("ctrl_delete")
					else
						wlog("unhandled control character %q", c)
					end
				elseif c == "\r" or c == "\n" then
					add_event("enter")
				elseif c == "\3" then
					add_event("ctrl_c")
				elseif c == "\23" or c == "\8" then -- ctrl backspace
					add_event("ctrl_backspace")
				elseif c == "\22" then
					add_event("ctrl_v")
				elseif c == "\1" then
					add_event("home")
				elseif c == "\5" then
					add_event("end")
				elseif c == "\21" then
					add_event("ctrl_backspace")
				else
					wlog("unhandled control character %q", c)
				end
			elseif c == "\127" then
				add_event("backspace")
			elseif utf8.byte_length(c) then
				buf:Advance(-1)
				add_event("string", buf:ReadString(utf8.byte_length(c)))
			end

			if buf:GetPosition() >= buf:GetSize() then break end
		end
	end

	local function read_coordinates()
		while true do
			local str = terminal.Read()

			if str then
				local a, b = str:match("^\27%[(%d+);(%d+)R$")

				if a then return tonumber(a), tonumber(b) end
			end
		end
	end

	do
		local _x, _y = 0, 0

		function terminal.GetCaretPosition()
			terminal.WriteNow("\x1b[6n")
			local y, x = read_coordinates()

			if y then _x, _y = x, y end

			return _x, _y
		end
	end

	do
		local STDOUT_FILENO = 1
		ffi.cdef([[
            struct terminal_winsize
            {
                unsigned short int ws_row;
                unsigned short int ws_col;
                unsigned short int ws_xpixel;
                unsigned short int ws_ypixel;
            };
        
            int ioctl(int fd, unsigned long int req, ...);    
        ]])
		local TIOCGWINSZ = 0x5413

		if jit.os == "OSX" then TIOCGWINSZ = 0x40087468 end

		local size = ffi.new("struct terminal_winsize[1]")

		function terminal.GetSize()
			ffi.C.ioctl(STDOUT_FILENO, TIOCGWINSZ, size)
			return size[0].ws_col, size[0].ws_row
		end
	end

	function terminal.WriteStringToScreen(x, y, str)
		terminal.Write("\27[s\27[" .. y .. ";" .. x .. "f" .. str .. "\27[u")
	end

	function terminal.ForegroundColor(r, g, b)
		r = math.floor(r * 255)
		g = math.floor(g * 255)
		b = math.floor(b * 255)
		terminal.Write("\27[38;2;" .. r .. ";" .. g .. ";" .. b .. "m")
	end

	function terminal.ForegroundColorFast(r, g, b)
		terminal.Write(string.format("\27[38;2;%i;%i;%im", r, g, b))
	end

	function terminal.BackgroundColor(r, g, b)
		r = math.floor(r * 255)
		g = math.floor(g * 255)
		b = math.floor(b * 255)
		terminal.Write("\27[48;2;" .. r .. ";" .. g .. ";" .. b .. "m")
	end

	function terminal.ResetColor()
		terminal.Write("\27[0m")
	end

	terminal.event_buffer = {}

	function terminal.ReadEvents()
		local str = terminal.Read()

		if str then process_input(str) end

		return terminal.event_buffer
	end
end

return terminal
