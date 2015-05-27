---
tagline: hi-level threads
---

## `local thread = require'thread'`

Threads and threaded primitives based on [pthread] and [luastate].

## API

--------------------------------------- --------------------------------------
__threads__
thread.new(func, args...) -> th         create and start a thread
th:join() -> retvals...                 wait on a thread to finish
__queues__
thread.queue([maxlength]) -> q          create a synchronized queue
q:length() -> n                         queue length
q:maxsize() -> n                        queue max. size
q:push(val[, timeout]) -> true, len     add value to the top (*)
q:shift([timeout]) -> true, val, len    remove bottom value (*)
q:pop([timeout]) -> true, val, len      remove top value (*)
q:free()                                free queue and its resources
__events__
thread.event() -> e                     create an event
e:set()                                 set the flag
e:clear()                               reset the flag
e:isset() -> true | false               check if the flag is set
e:wait([timeout]) -> true | false       wait until the flag is set
e:free()                                free event
--------------------------------------- --------------------------------------

> (*) the `timeout` arg is an os.time() or [time].time() timestamp,
not a time period; when a timeout is passed, the function can return
`false, 'timeout'` if the specified timeout expires before the underlying
mutex is locked.

## Threads

### `thread.new(func, args...) -> th`

Create a new thread and Lua state, push `func` and `args` to the Lua state
and execute `func(args...)` in the context of the thread. The return values
of func can be retreived by calling `th:join()` (see below).

  * the function's upvalues are not copied to the Lua state along with it.
  * args can be of two kinds: copiable types and shareable types.
  * copiable types are: nils, booleans, strings, functions without upvalues,
  tables without cyclic references or multiple references to the same
  table inside.
  * shareable types are: pthread threads, mutexes, cond vars and rwlocks,
  top level Lua states, threads, queues and events.

Copiable objects are copied over to the Lua state, while shareable
objects are only shared with the thread. All args are kept from being
garbage-collected up until the thread is joined.

The returned thread object must not be discarded and `th:join()`
must be called on it to release the thread resources.

### `th:join() -> retvals...`

Wait on a thread to finish and return the return values of its worker
function. Same rules apply for copying return values as for args.
Errors are propagated to the calling thread.

## Queues

### `thread.queue([maxlength]) -> q`

Create a queue that can be safely shared and used between threads.
Elements can be popped from both ends, so it can act as both a LIFO
or a FIFO queue, as needed.

## Events

### `thread.event() -> e`

Events are a simple way to make multiple threads block on a flag.
Setting the flag unblocks any threads that are blocking on `e:wait()`.

## Programming Notes

### Threads are slow

Creating hi-level threads is slow because Lua modules must be loaded
every time for each thread. For best results, use a thread pool.

### Environment

On Windows, the current directory is per thread, believe it!
On every other platform on earth is per process of course.
Same goes for env vars.

