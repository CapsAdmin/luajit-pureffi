local ffi = require("ffi")
local threads = {}

function threads.run_thread(ptr, udata)
	error("NYI")
end

function threads.join_thread(id)
	error("NYI")
end

function threads.get_cpu_threads(id)
	error("NYI")
end

if ffi.os == "Windows" then
	ffi.cdef[[
		typedef uint32_t (*thread_callback)(void*);

        void* CreateThread(
            void* lpThreadAttributes,
            size_t dwStackSize,
            thread_callback lpStartAddress,
            void* lpParameter,
            uint32_t dwCreationFlags,
            uint32_t* lpThreadId
        );
        uint32_t WaitForSingleObject(void* hHandle, uint32_t dwMilliseconds);
        int CloseHandle(void* hObject);
        uint32_t GetLastError(void);
        int32_t GetExitCodeThread(void* hThread, uint32_t* lpExitCode);

		typedef struct _SYSTEM_INFO {
            union {
                uint32_t dwOemId;
                struct {
                    uint16_t wProcessorArchitecture;
                    uint16_t wReserved;
                };
            };
            uint32_t dwPageSize;
            void* lpMinimumApplicationAddress;
            void* lpMaximumApplicationAddress;
            size_t dwActiveProcessorMask;
            uint32_t dwNumberOfProcessors;
            uint32_t dwProcessorType;
            uint32_t dwAllocationGranularity;
            uint16_t wProcessorLevel;
            uint16_t wProcessorRevision;
        } SYSTEM_INFO;

        void GetSystemInfo(SYSTEM_INFO* lpSystemInfo);
    ]]
	local kernel32 = ffi.load("kernel32")

	local function check_win_error(success)
		if success ~= 0 then return end

		local error_code = kernel32.GetLastError()
		local error_messages = {
			[5] = "Access denied",
			[6] = "Invalid handle",
			[8] = "Not enough memory",
			[87] = "Invalid parameter",
			[1455] = "Page file quota exceeded",
		}
		local err_msg = error_messages[error_code] or "unknown error"
		error(string.format("Thread operation failed: %s (Error code: %d)", err_msg, error_code), 2)
	end

	-- Constants
	local INFINITE = 0xFFFFFFFF
	local THREAD_ALL_ACCESS = 0x1F03FF

	function threads.run_thread(func_ptr, udata)
		local thread_id = ffi.new("uint32_t[1]")
		local thread_handle = kernel32.CreateThread(
			nil, -- Security attributes (default)
			0, -- Stack size (default)
			ffi.cast("thread_callback", func_ptr),
			udata, -- Thread parameter
			0, -- Creation flags (run immediately)
			thread_id -- Thread identifier
		)

		if thread_handle == nil then check_win_error(0) end

		-- Return both handle and ID for Windows
		return {handle = thread_handle, id = thread_id[0]}
	end

	function threads.join_thread(thread_data)
		local wait_result = kernel32.WaitForSingleObject(thread_data.handle, INFINITE)

		if wait_result == INFINITE then check_win_error(0) end

		local exit_code = ffi.new("uint32_t[1]")

		if kernel32.GetExitCodeThread(thread_data.handle, exit_code) == 0 then
			check_win_error(0)
		end

		if kernel32.CloseHandle(thread_data.handle) == 0 then check_win_error(0) end

		return exit_code[0]
	end

	function threads.get_thread_count()
		local sysinfo = ffi.new("SYSTEM_INFO")
		kernel32.GetSystemInfo(sysinfo)
		return tonumber(sysinfo.dwNumberOfProcessors)
	end
else
	ffi.cdef[[
		typedef uint64_t pthread_t;

		typedef struct {
			uint32_t flags;
			void * stack_base;
			size_t stack_size;
			size_t guard_size;
			int32_t sched_policy;
			int32_t sched_priority;
		} pthread_attr_t;

		int pthread_create(pthread_t *thread, const pthread_attr_t *attr, void *(*start_routine)(void *), void *arg);
		int pthread_join(pthread_t thread, void **value_ptr);

		long sysconf(int name);
	]]
	local pt = ffi.load("pthread")

	-- Enhanced pthread error checking
	local function check_pthread(int)
		if int == 0 then return end

		local error_messages = {
			[11] = "System lacks resources or reached thread limit",
			[22] = "Invalid thread attributes specified",
			[1] = "Insufficient permissions to set scheduling parameters",
			[3] = "Thread not found",
			[35] = "Deadlock condition detected",
			[12] = "Insufficient memory to create thread",
		}
		local err_msg = error_messages[int] or "unknown error"

		if err_msg then
			error(string.format("Thread operation failed: %s (Error code: %d)", err_msg, int), 2)
		end
	end

	function threads.run_thread(func_ptr, udata)
		local thread_id = ffi.new("pthread_t[1]", 1)
		check_pthread(pt.pthread_create(thread_id, nil, func_ptr, udata))
		return thread_id[0]
	end

	function threads.join_thread(id)
		local out = ffi.new("void*[1]")
		check_pthread(pt.pthread_join(id, out))
		return out[0]
	end

	local FLAG_SC_NPROCESSORS_ONLN = 83

	if ffi.os == "OSX" then FLAG_SC_NPROCESSORS_ONLN = 58 end

	function threads.get_thread_count()
		return tonumber(ffi.C.sysconf(FLAG_SC_NPROCESSORS_ONLN))
	end
end

do
	local LUA_GLOBALSINDEX = -10002
    ffi.cdef[[
        typedef struct lua_State lua_State;
        lua_State *luaL_newstate(void);
        void luaL_openlibs(lua_State *L);
        void lua_close(lua_State *L);
        int luaL_loadstring(lua_State *L, const char *s);
        int lua_pcall(lua_State *L, int nargs, int nresults, int errfunc);
        void lua_getfield(lua_State *L, int index, const char *k);
        void lua_settop(lua_State *L, int index);
        void lua_pop(lua_State *L, int n);
        const char *lua_tolstring(lua_State *L, int index, size_t *len);
        ptrdiff_t lua_tointeger(lua_State *L, int index);
        int lua_gettop(lua_State *L);
        void lua_pushstring(lua_State *L, const char *s);
        const void *lua_topointer(lua_State *L, int index);
        double lua_tonumber(lua_State *L, int index);
        void *lua_touserdata(lua_State *L, int idx);
        void lua_pushlstring(lua_State *L, const char *p, size_t len);
    ]]

	local function create_state()
		local L = ffi.C.luaL_newstate()

		if L == nil then error("Failed to create new Lua state: Out of memory", 2) end

		ffi.C.luaL_openlibs(L)
		return L
	end

	local function close_state(L)
		ffi.C.lua_close(L)
	end

	local function check_error(L, ret)
		if ret == 0 then return end

		local chr = ffi.C.lua_tolstring(L, -1, nil)
		local msg = ffi.string(chr)
		error(msg, 2)
	end

	local function get_function_pointer(L, code, func)
		check_error(L, ffi.C.luaL_loadstring(L, code))
		local str = string.dump(func)
		ffi.C.lua_pushlstring(L, str, #str)
		check_error(L, ffi.C.lua_pcall(L, 1, 1, 0))
		local ptr = ffi.C.lua_topointer(L, -1)
		ffi.C.lua_settop(L, -2)
		local box = ffi.cast("uintptr_t*", ptr)
		return box[0]
	end

	local buffer = require("string.buffer")
	local meta = {}
	meta.__index = meta
	
	-- Automatic cleanup when thread object is garbage collected
	function meta:__gc()
		if self.lua_state then
			close_state(self.lua_state)
			self.lua_state = nil
		end
	end
	
	local thread_func_signature = "void *(*)(void *)"

	function threads.new(func)
		local self = setmetatable({}, meta)
		local L = create_state()
		local func_ptr = get_function_pointer(
			L,
			[[
            local run = assert(load(...))
            local ffi = require("ffi")
            local buffer = require("string.buffer")

            local function main(udata)
                local udata = ffi.cast("uint64_t *", udata)
                local buf = buffer.new()
                buf:set(ffi.cast("const char *", udata[0]), udata[1])
                local input = buf:decode()

                local buf = buffer.new()
                buf:encode(run(input))
                local ptr, len = buf:ref()
                return ffi.new("uint64_t[2]", ffi.cast("uint64_t", ptr), len)
            end
            
            return ffi.new("uintptr_t[1]", ffi.cast("uintptr_t", ffi.cast("void *(*)(void *)", main)))
        ]],
			func
		)
		self.lua_state = L
		self.func_ptr = ffi.cast(thread_func_signature, func_ptr)
		return self
	end

	function meta:run(obj)
		local buf = buffer.new()
		buf:encode(obj)
		self.buffer = buf
		local ptr, len = buf:ref()
		local data = ffi.new("uint64_t[2]", ffi.cast("uint64_t", ptr), len)
		self.input_data = data  -- Keep alive until join to prevent premature GC
		self.id = threads.run_thread(self.func_ptr, data)
	end

	function meta:join()
		local out = threads.join_thread(self.id)
		local data = ffi.cast("uint64_t *", out)
		local buf = buffer.new()
		buf:set(ffi.cast("const char*", data[0]), data[1])
		local result = buf:decode()
		
		-- Clear references to allow GC
		self.buffer = nil
		self.input_data = nil
		
		return result
	end

	function meta:close()
        close_state(self.lua_state)
	end
end

return threads
