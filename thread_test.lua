io.stdout:setvbuf'no'

local ffi = require'ffi'
local thread = require'thread'
local pthread = require'pthread'
local luastate = require'luastate'
local time = require'time'

local function test_events()
	local event = thread.event()
	local t1 = thread.new(function(event)
			local time = require'time'
			while true do
				print'set'
				event:set()
				time.sleep(0.1)
				print'clear'
				event:clear()
				time.sleep(1)
			end
		end, event)

	local t2 = thread.new(function(event)
			local time = require'time'
			while true do
				event:wait()
				print'!'
				time.sleep(0.1)
			end
		end, event)

	t1:join()
	t2:join()
end

local function test_pthread_creation()
	local state = luastate.open()
	state:openlibs()
	state:push(function()
   	local ffi = require'ffi'
	   local function worker() end
	   local worker_cb = ffi.cast('void *(*)(void *)', worker)
	   return tonumber(ffi.cast('intptr_t', worker_cb))
	end)
	local worker_cb_ptr = ffi.cast('void*', state:call())
	local t0 = time.clock()
	local n = 1000
	for i=1,n do
		local thread = pthread.new(worker_cb_ptr)
		thread:join()
	end
	local t1 = time.clock()
	state:close()
	print(string.format('time to create %d pthreads: %.2fs', n, t1 - t0))
end

local function test_luastate_creation()
	local t0 = time.clock()
	local n = 100
	for i=1,n do
		local state = luastate:open()
		state:openlibs()
		state:push(function()
		end)
		state:call()
		state:close()
	end
	local t1 = time.clock()
	print(string.format('time to create %d states: %.2fs', n, t1 - t0))
end

local function test_thread_creation()
	local t0 = time.clock()
	local n = 10
	for i=1,n do
		thread.new(function() end):join()
	end
	local t1 = time.clock()
	print(string.format('time to create %d threads: %.2fs', n, t1 - t0))
end

local function test_queue()

	local q = thread.queue(1)

	local t1 = thread.new(function(q)
		for i = 1, 20 do
			io.stdout:write(table.concat({'push', q:push('hello'..i)}, '\t')..'\n')
		end
	end, q)

	local t2 = thread.new(function(q)
		for i = 1, 20 do
			io.stdout:write(table.concat({'pop', q:pop()}, '\t')..'\n')
		end
	end, q)

	t2:join()
	t1:join()

	print'--------------------------------'
	assert(q:length() == 0)
	--ffi.gc(q.state, nil)
	--ffi.gc(q.mutex, nil)
	--ffi.gc(q.cond_not_full, nil)
	--ffi.gc(q.cond_not_empty, nil)
	--q:free()
end

--test_pthread_creation()
--test_luastate_creation()
--test_thread_creation()
test_queue()

--[[

local function test_yield()
	local mutex = pthread.mutex()
	local cond = pthread.cond()
	local event = thread.event()
	local state = luastate.state()

	local t = thread.new(function(event, state, mutex, cond)
		local coro = coroutine.create(
			function()
				local time = require'time'
				print(coroutine.yield('a', 'b', 1, 2, 3))
				return 4, 5, 6
			end)
		while true do
			local function pass(ok, ...)
				if not ok then error(..., 2) end
				mutex:lock()
				state:push(glue.pack(...))
				state:setglobal'args'
				cond:broadcast()
				mutex:unlock()
				if coroutine.status(coro) == 'dead' then
					return ...
				end
			end
			pass(coroutine.resume(coro))
		end
	end, event, state, mutex, cond)

	local function resume(...)
		mutex:lock()
		cond:broadcast()
		mutex:unlock()
	end

	print(resume())
	print(resume())
end


local th1 = ps.thread(function(api)
	local state = api:lock()
	print('th1 have state', state)
	api:unlock()
end)

local th2 = ps.thread(function(api)
	local state = api:lock()
	print('th2 have state', state)
	api:unlock()
end)

th1:join()
th2:join()


]]
