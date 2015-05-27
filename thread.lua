
--hi-level thread primitives based on pthread and luastate.
--Written by Cosmin Apreutesei. Public Domain.

if not ... then require'thread_test'; return; end

local pthread = require'pthread'
local luastate = require'luastate'
local glue = require'glue'
local ffi = require'ffi'
local cast = ffi.cast
local addr = glue.addr
local ptr = glue.ptr

local thread = {}

--shareable objects ----------------------------------------------------------

--objects that implement the shareable interface can be shared
--between Lua states when passing args in and out of Lua states.

local typemap = {} --{ctype_name = {identify=f, decode=f, encode=f}}

--shareable pointers
local function pointer_class(in_ctype, out_ctype)
	local class = {}
	function class.identify(p)
		return ffi.istype(in_ctype, p)
	end
	function class.encode(p)
		return {addr = glue.addr(p)}
	end
	function class.decode(t)
		return glue.ptr(out_ctype or in_ctype, t.addr)
	end
	return class
end

function thread.shared_object(name, class)
	if typemap[name] then return end --ignore duplicate registrations
	typemap[name] = class
end

function thread.shared_pointer(in_ctype, out_ctype)
	thread.shared_object(in_ctype, pointer_class(in_ctype, out_ctype))
end

thread.shared_pointer'lua_State*'
thread.shared_pointer('pthread_mutex_t', 'pthread_mutex_t*')
thread.shared_pointer('pthread_rwlock_t', 'pthread_rwlock_t*')
thread.shared_pointer('pthread_cond_t', 'pthread_cond_t*')

--identify a shareable object and encode it.
local function encode_shareable(x)
	for typename, class in pairs(typemap) do
		if class.identify(x) then
			local t = class.encode(x)
			t.type = typename
			return t
		end
	end
end

--decode an encoded shareable object
local function decode_shareable(t)
	return typemap[t.type].decode(t)
end

--encode all shareable objects in a packed list of args
function thread._encode_args(t)
	t.shared = {} --{i1,...}
	for i=1,t.n do
		local e = encode_shareable(t[i])
		if e then
			t[i] = e
			--put the indices of encoded objects aside for identification
			--and easy traversal when decoding
			table.insert(t.shared, i)
		end
	end
	return t
end

--decode all encoded shareable objects in a packed list of args
function thread._decode_args(t)
	for _,i in ipairs(t.shared) do
		t[i] = decode_shareable(t[i])
	end
	return t
end

--events ---------------------------------------------------------------------

ffi.cdef[[
typedef struct {
	int flag;
	pthread_mutex_t mutex;
	pthread_cond_t cond;
} thread_event_t;
]]

function thread.event(set)
	local e = ffi.new'thread_event_t'
	pthread.mutex(nil, e.mutex)
	pthread.cond(nil, e.cond)
	e.flag = set and 1 or 0
	return e
end

local event = {}

local function set(self, val)
	self.mutex:lock()
	self.flag = val
	self.cond:broadcast()
	self.mutex:unlock()
end

function event:set()
	set(self, 1)
end

function event:clear()
	set(self, 0)
end

function event:isset()
	self.mutex:lock()
	local ret = self.flag == 1
	self.mutex:unlock()
	return ret
end

function event:wait(timeout)
	self.mutex:lock()
	local cont = true
	while cont do
		if self.flag == 1 then
			self.mutex:unlock()
			return true
		end
		if timeout then
			cont = self.cond:timedwait(self.mutex, timeout)
		else
			self.cond:wait(self.mutex)
		end
	end
	self.mutex:unlock()
	return false
end

ffi.metatype('thread_event_t', {__index = event})

thread.shared_pointer('thread_event_t', 'thread_event_t*')

--queues ---------------------------------------------------------------------

--TODO: turn this trivial impl. into a circular buffer to support large queues.

local queue = {}
queue.__index = queue

function thread.queue(maxlen)
	assert(not maxlen or (math.floor(maxlen) == maxlen and maxlen >= 1),
		'invalid queue max. length')
	local state = luastate.open() --values will be kept on the state's stack
	return setmetatable({
		state          = state,
		mutex          = pthread.mutex(),
		cond_not_empty = pthread.cond(),
		cond_not_full  = pthread.cond(),
		maxlen         = maxlen,
	}, queue)
end

function queue:free()
	self.cond_not_full:free();  self.cond_not_full = nil
	self.cond_not_empty:free(); self.cond_not_empty = nil
	self.state:close();         self.state = nil
	self.mutex:free();          self.mutex = nil
end

local function queue_length(self)
	return self.state:gettop()
end

local function queue_isfull(self)
	return self.maxlen and queue_length(self) == self.maxlen
end

local function queue_isempty(self)
	return queue_length(self) == 0
end

--method wrapper that locks the mutex, calls the method and unlocks
--the mutex before returning, even when the method raises an error.
local function pass(self, ok, ...)
	self.mutex:unlock()
	if ok then
		return ...
	else
		error(..., 3)
	end
end
local function synched(func)
	return function(self, ...)
		self.mutex:lock()
		return pass(self, xpcall(func, debug.traceback, self, ...))
	end
end

queue.length  = synched(queue_length)
queue.isfull  = synched(queue_isfull)
queue.isempty = synched(queue_isempty)

function queue:maxlength()
	return self.maxlen
end

--normalize index and check if within offsetted range
local function queue_checkindex(self, i, ofs0, ofs1)
	local i1 = self.state:gettop()
	--normalize the index: negative indices are relative to the tail
	if i <= 0 then
		i = i1 + i + 1
	end
	--offset the index range at both ends
	local i0 =  1 + ofs0
	local i1 = i1 + ofs1
	--check index in range
	if i < i0 or i > i1 then
		error('index out of range', 3)
	end
	return i
end

queue.insert = synched(function(self, v, index, timeout)
	index = queue_checkindex(self, index or 0, 0, 1)
	while queue_isfull(self) do
		if not self.cond_not_full:wait(self.mutex, timeout) then
			return false, 'timeout'
		end
	end
	local was_empty = queue_isempty(self)
	self.state:push(v)
	self.state:insert(index)
	local len = queue_length(self)
	if was_empty then
		self.cond_not_empty:broadcast()
	end
	return len
end)

queue.remove = synched(function(self, index, timeout)
	index = queue_checkindex(self, index or -1, 0, 0)
	while queue_isempty(self) do
		if not self.cond_not_empty:wait(self.mutex, timeout) then
			return false, 'timeout'
		end
	end
	local was_full = queue_isfull(self)
	local v = self.state:get(index)
	--print('>>>>', index > 0, self.state:gettop() > 0)
	self.state:remove(index)
	local len = queue_length(self)
	if was_full then
		self.cond_not_full:broadcast()
	end
	return v, len
end)

queue.replace = synched(function(self, index)
	index = queue_checkindex(self, index, 0, 0, 0)
	self.state:push(v)
	self.state:replace(index)
end)

function queue:push(v, timeout)
	return self:insert(v, nil, timeout)
end

function queue:pop(timeout)
	return self:remove(nil, timeout)
end

function queue:shift(timeout)
	return self:remove(1, timeout)
end

--queues / shareable interface

function queue:identify()
	return getmetatable(self) == queue
end

function queue:encode()
	return {
		state_addr          = glue.addr(self.state),
		mutex_addr          = glue.addr(self.mutex),
		cond_not_full_addr  = glue.addr(self.cond_not_full),
		cond_not_empty_addr = glue.addr(self.cond_not_empty),
		maxlen              = self.maxlen,
	}
end

function queue.decode(t)
	return setmetatable({
		state          = glue.ptr('lua_State*',       t.state_addr),
		mutex          = glue.ptr('pthread_mutex_t*', t.mutex_addr),
		cond_not_full  = glue.ptr('pthread_cond_t*',  t.cond_not_full_addr),
		cond_not_empty = glue.ptr('pthread_cond_t*',  t.cond_not_empty_addr),
		maxlen         = t.maxlen,
	}, queue)
end

thread.shared_object('queue', queue)

--timers


--threads --------------------------------------------------------------------

function thread.new(func, ...)
	local state = luastate.open()
	state:openlibs()
	state:push(function(args)

		local pthread = require'pthread'
		local luastate = require'luastate'
		local glue = require'glue'
		local thread = require'thread'
	   local ffi = require'ffi'
	   local cast = ffi.cast
	   local addr = glue.addr

		local function pass(ok, ...)
			local retvals = ok and thread._encode_args(glue.pack(...)) or {err = ...}
			rawset(_G, '__ret', retvals) --is this the only way to get them out?
		end
	   local function worker()
	   	local t = thread._decode_args(args.func_args)
	   	pass(xpcall(args.func, debug.traceback, glue.unpack(t)))
	   end

		--worker_cb is anchored by luajit along with the function it frames.
	   local worker_cb = cast('void *(*)(void *)', worker)
	   return addr(worker_cb)
	end)
	local args = {
		func = func,
		func_args = thread._encode_args(glue.pack(...)),
	}
	local worker_cb_ptr = ptr(state:call(args))
	local pthread = pthread.new(worker_cb_ptr)

	return glue.inherit({
			pthread = pthread,
			state = state,
		}, thread)
end

function thread:join()
	self.pthread:join()
	--get the return values of worker function
	self.state:getglobal'__ret'
	local retvals = self.state:get()
	self.state:close()
	--propagate the error
	if retvals.err then
		error(retvals.err, 2)
	end
	return glue.unpack(thread._decode_args(retvals))
end

return thread

------------------------------------------------------------------------------

--[[
thread.new(worker, 1, 2)

shared = {}

function worker(shared)
	--
end

t1 = thread.new(worker, 1, 2)
t2 = thread.new(worker, 'a', {x = 1})
local r1, r2 = t1:join()
local r1, r2 = t2:join()

local shared = thread.shared()

t1 = thread.new(worker, shared)

mutex:lock()
state:push()
state:setglobal()
mutex:unlock()

mutex:lock()
state:getglobal()
state:get()
mutex:unlock()
]]
