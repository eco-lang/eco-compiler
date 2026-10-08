/*
import Elm.Kernel.Scheduler exposing (binding, succeed, fail)
import Elm.Kernel.Utils exposing (Tuple0, Tuple2, Tuple3)
import Elm.Kernel.List exposing (toArray)
import Maybe exposing (Just, Nothing)
*/

// Stream — JS twin of src/eco-system/Stream/ (eco/system), plans/eco-system-library.md
// §3.5, Appendix B.2, Phase 10 (decision D15).
//
// This is a port of the C++ StreamTable state machine (Stream.cpp, StreamPipe.cpp,
// StreamCodec.cpp), not a wrapper over WHATWG streams, so the same eco-system tests pass
// on both backends: identity / custom / codec / channel-source / channel-sink pairs, the
// write vs enqueue distinction, read and write locks, capacities (readCap 0 is a
// rendezvous), custom Send overfill / Close / Cancel, codecs buffering one chunk on each
// side, pipes with the WHATWG pipeTo propagation rules and lock release, and the §10
// Phase 3/6 deviations. The kernel functions take and return exactly the Appendix B
// shapes (Int handle ids, SErr = ( Int kind, String reason ), Maybe, Bytes = DataView).
//
// ============================================================================
// THE JS BYTE-CHANNEL API (used by the other eco/system kernels: files, child
// pipes, HTTP bodies). Import the names you need, e.g.
//   import Eco.Kernel.Stream exposing (createChannelSource, nodeReadableChannel)
//
// A ByteChannel is a plain object with four methods, all called on the JS main thread:
//
//   requestRead(maxBytes, done)
//       Read at most maxBytes (> 0) bytes. Calls done(err, chunk) EXACTLY ONCE:
//       chunk is a non-empty Uint8Array, or null at end of input; err is an Error (or a
//       string) on failure. A channel that has been shut down completes with an error.
//   requestWrite(bytes, done)
//       Write all of `bytes` (a Uint8Array, possibly empty). Calls done(err) exactly once
//       (err null on success).
//   close(done)
//       Graceful close: after every queued write has completed, release the resource
//       and call done(err) once. `done` may be null (a source releasing itself after
//       end of input). Pending reads complete with an error.
//   shutdown()
//       Immediate stop: release the resource; every pending request completes with an
//       error (ECANCELED). Idempotent.
//
// Requests complete in the order they were made. A done callback may be called
// synchronously; the stream table defers such calls to a microtask. An error may carry a
// `reason` string property: it becomes the stream's Cancelled reason (e.g.
// "network error: ..."); otherwise the reason is "<code>: <message>".
//
// Creating streams over channels (each returns the Int pair id that Elm wraps with
// Stream.Internal.Readable / Writable):
//   _Stream_createChannelSource(channel) -> id   a Readable Bytes over the channel
//   _Stream_createChannelSink(channel)   -> id   a Writable Bytes over the channel
// The table owns the channel from then on (it calls close/shutdown).
// Text channels (plans/eco-system-websockets.md WS6): a channel source whose requestRead
// gives a (non-empty) JS string as the chunk yields that String instead of Bytes;
//   _Stream_createTextChannelSink(channel) -> id   a Writable String: requestWrite gets
//       each value as a JS string.
//   _Stream_discardReadable(id)   cancels the readable side with no reason (a source that
//       never reached Elm); the pair is erased once released.
//
// Value-mapped pairs (plans/eco-system-websockets.md §3.3, W16; C++: Stream.hpp). They
// carry values a kernel cannot build (e.g. WebSocket.Message) across the boundary: the
// channel speaks TAGGED chunks, plain objects { tag, text, bytes } (plain property names:
// they cross kernel files), and Elm closures convert:
//   _Stream_createMappedSource(channel, fromWire) -> id
//       A Readable whose values are fromWire ( tag, text, bytes ) for each chunk the
//       channel reads: requestRead's done(err, chunk) gives chunk = { tag: Int, text:
//       String ('' for a binary chunk), bytes: Uint8Array or null (text chunks) }, null at
//       end of input. Reads ahead one chunk (one request in flight while nothing is
//       buffered); fromWire runs when a consumer takes the chunk (a read, a parked read, a
//       pipe). Optional channel method setDemand(bool): told whether a consumer waits (a
//       parked read or a pipe), the JS twin of native's pendingAsync count (the read-ahead
//       itself must not keep the program alive).
//   _Stream_createMappedSink(channel, toWire) -> id
//       A Writable whose accepted values are passed to toWire (a -> ( Int, String, Bytes ))
//       and written with channel.requestWriteTagged({ tag, text, bytes }, done) (text: the
//       String, bytes: the Bytes as a Uint8Array); without that method a tag-0 chunk goes
//       to requestWrite(bytes, done) and any other fails ENOTSUP.
//   _Stream_attachReader(id, fn) -> Bool
//       Subscription reader of a mapped source: while attached, chunks bypass the queue
//       and fromWire and go to fn(err, chunk) (chunk null at end of input; err once on a
//       failure), read-ahead continues as fast as fn returns, and reads, pipes and
//       cancelReadable fail Locked. fn runs inside a stream operation, never inside
//       attachReader (chunks already read are handed over first, from a microtask). False
//       (nothing done) while a read is parked, the pair is piped, a reader is attached, or
//       the id is not a mapped source.
//   _Stream_detachReader(id)   back to normal reading (later chunks queue as usual).
//
// Adapters for Node streams:
//   _Stream_nodeReadableChannel(readable, options) -> channel
//   _Stream_nodeWritableChannel(writable, options) -> channel
//       `readable` / `writable` is a Node stream, or a function returning one (resolved
//       on the first request, so e.g. process.stdin is only touched when it is read).
//       options.keepOpen: never end/destroy the Node stream (stdio: fds 0-2 are never
//       closed, §3.4); close only waits for the writes in flight.
//       The readable adapter never prefetches: it resumes the Node stream only while a
//       read is pending and pauses it after each chunk (§10 Phase 3 "channel sources
//       never prefetch"), so a paused stdin does not keep the process alive.
//       The writable adapter's close is `end()` and completes on 'finish'.
//   _Stream_fromNodeReadable(readable, options) -> id   (= createChannelSource of the adapter)
//   _Stream_fromNodeWritable(writable, options) -> id   (= createChannelSink of the adapter)
//
// Other helpers:
//   _Stream_pipeStreams(src, dst) -> Bool   an internal pipeTo with no Elm task (the
//       Http.Stream upload pump); false (nothing done) if src is read-locked or dst
//       write-locked.
//   _Stream_pin(id)                     the pair is never erased (stdio).
//   _Stream_toBytes(uint8Array) -> Bytes (DataView);  _Stream_toUint8Array(bytes)
//   _Stream_noteActivity()             call when a kernel starts external IO; it re-arms
//       System.onEmptyEventLoop (§3.7: native re-arms on incrementPendingAsync).
//   _Stream_activityCount()            read by the System manager kernel.
//
// Kernel-file pitfall: every double-underscore Home_name reference in a kernel file,
// comments included, must be listed in the header imports. An unlisted one makes the
// kernel parser reject the file, and dependent builds only report "PROBLEM BUILDING
// DEPENDENCIES ... eco/system" (no detail; `make` inside system-kernel-cpp does not parse
// the kernels).
// ============================================================================

var _Stream_W_OPEN = 0, _Stream_W_CLOSING = 1, _Stream_W_CLOSED = 2, _Stream_W_ERRORED = 3;
var _Stream_R_OPEN = 0, _Stream_R_CLOSED = 1, _Stream_R_ERRORED = 2;
var _Stream_K_IDENTITY = 0, _Stream_K_CUSTOM = 1, _Stream_K_CODEC = 2,
    _Stream_K_SOURCE = 3, _Stream_K_SINK = 4, _Stream_K_MAPPED = 5;
var _Stream_E_CLOSED = 0, _Stream_E_CANCELLED = 1, _Stream_E_LOCKED = 2;

var _Stream_kWritableClosed = 'WritableStream is closed';
var _Stream_kTerminated = 'TransformStream has been terminated';
var _Stream_kChannelReadChunk = 64 * 1024;


// --- Bytes ------------------------------------------------------------------

function _Stream_toBytes(u8)
{
	return new DataView(u8.buffer, u8.byteOffset, u8.byteLength);
}

function _Stream_toUint8Array(bytes)
{
	return new Uint8Array(bytes.buffer, bytes.byteOffset, bytes.byteLength);
}


// --- Activity (System.onEmptyEventLoop re-arming, §3.7) --------------------

var _Stream_activity = 0;

function _Stream_noteActivity()
{
	_Stream_activity++;
}

function _Stream_activityCount()
{
	return _Stream_activity;
}


// --- Completions ---------------------------------------------------------------
//
// A token stands for one parked Elm task: { resume: callback | null }. Completing it
// queues the resumption; queued resumptions run when the outermost stream operation
// returns (as the C++ drain calls Scheduler::drain() after dispatching), so Elm never
// re-enters the table in the middle of a pump. Synthetic tokens (pipe and enqueue
// channel requests) have resume null.

var _Stream_resumes = [];
var _Stream_depth = 0;
var _Stream_flushing = false;

function _Stream_enter(fn)
{
	_Stream_depth++;
	try
	{
		fn();
	}
	finally
	{
		_Stream_depth--;
	}
	if (_Stream_depth === 0)
	{
		_Stream_flush();
	}
}

function _Stream_flush()
{
	if (_Stream_flushing)
	{
		return;
	}
	_Stream_flushing = true;
	try
	{
		while (_Stream_resumes.length)
		{
			var r = _Stream_resumes.shift();
			r.__f(r.__t);
		}
	}
	finally
	{
		_Stream_flushing = false;
	}
}

function _Stream_token(callback)
{
	return { __resume: callback };
}

function _Stream_resumeNow(callback, task)
{
	_Stream_resumes.push({ __f: callback, __t: task });
}

function _Stream_err(kind, reason)
{
	return __Scheduler_fail(__Utils_Tuple2(kind, reason));
}

function _Stream_completeOk(tok, value)
{
	if (tok && tok.__resume)
	{
		var f = tok.__resume;
		tok.__resume = null;
		_Stream_resumes.push({ __f: f, __t: __Scheduler_succeed(value) });
	}
}

function _Stream_completeErr(tok, kind, reason)
{
	if (tok && tok.__resume)
	{
		var f = tok.__resume;
		tok.__resume = null;
		_Stream_resumes.push({ __f: f, __t: _Stream_err(kind, reason) });
	}
}

function _Stream_failAll(toks, reason)
{
	for (var i = 0; i < toks.length; i++)
	{
		_Stream_completeErr(toks[i], _Stream_E_CANCELLED, reason);
	}
}

function _Stream_describeError(err)
{
	if (err && typeof err === 'object')
	{
		if (typeof err.reason === 'string' && err.reason.length)
		{
			return err.reason;
		}
		if (err.code)
		{
			return err.code + ': ' + (err.message || '');
		}
		return err.message || String(err);
	}
	return String(err);
}


// --- The table --------------------------------------------------------------------

var _Stream_table = {};
var _Stream_nextId = 1;

function _Stream_newPair(kind)
{
	return {
		__kind: kind,
		__writeQ: [],          // { __tok, __value, __completeOnTransform }
		__readQ: [],
		__writeCap: 1,
		__readCap: 1,
		__w: _Stream_W_OPEN,
		__r: _Stream_R_OPEN,
		__wReason: '',
		__rReason: '',
		__readLock: false,
		__writeLock: false,
		__pipedOut: false,
		__pipedIn: false,
		__pipeOutId: 0,
		__pipeInId: 0,
		__pipeRefs: 0,
		__parkedRead: null,    // token
		__waitingForRoom: [],
		__closeTok: null,
		__customFn: null,
		__customState: null,
		__codec: null,
		__channel: null,
		__pinned: false,
		__mapFn: null,         // mapped source: fromWire; mapped sink: toWire
		__rawQ: [],            // mapped source: chunks read, not mapped yet
		__readInFlight: null,  // mapped source: the read-ahead's token
		__rErr: null,          // mapped source: the error that ended reading
		__reader: null,        // mapped source: the subscription reader
		__readerKick: false,
		__readerEndSent: false,
		__demand: false,       // mapped source: last setDemand value
		__textSink: false      // channel sink of Strings (createTextChannelSink)
	};
}

function _Stream_insert(p)
{
	var id = _Stream_nextId++;
	_Stream_table[id] = p;
	return id;
}

function _Stream_find(id)
{
	return _Stream_table[id];
}

function _Stream_pin(id)
{
	var p = _Stream_table[id];
	if (p)
	{
		p.__pinned = true;
	}
}

function _Stream_readLocked(p)
{
	return p.__readLock || p.__pipedOut || !!p.__reader;
}

function _Stream_writeLocked(p)
{
	return p.__writeLock || p.__pipedIn;
}

// Collects the tokens of queued in-memory writes (and the close) of `p` and empties the
// write side. Channel writes are in flight: they complete through their channel callback.
function _Stream_drainWriteSide(p, out)
{
	var i;
	if (p.__kind !== _Stream_K_SINK)
	{
		for (i = 0; i < p.__writeQ.length; i++)
		{
			if (p.__writeQ[i].__tok) out.push(p.__writeQ[i].__tok);
		}
		p.__writeQ = [];
	}
	for (i = 0; i < p.__waitingForRoom.length; i++)
	{
		if (p.__waitingForRoom[i].__tok) out.push(p.__waitingForRoom[i].__tok);
	}
	p.__waitingForRoom = [];
	p.__writeLock = false;
	if (p.__closeTok && p.__kind !== _Stream_K_SINK)
	{
		out.push(p.__closeTok);
		p.__closeTok = null;
	}
}

// Both sides Errored with `reason` (cancelWritable, a custom Cancel, a codec failure).
function _Stream_errorPair(p, reason, out)
{
	p.__w = _Stream_W_ERRORED;
	p.__wReason = reason;
	p.__r = _Stream_R_ERRORED;
	p.__rReason = reason;
	p.__readQ = [];
	_Stream_drainWriteSide(p, out);
	if (p.__parkedRead && p.__kind !== _Stream_K_SOURCE)
	{
		out.push(p.__parkedRead);
		p.__parkedRead = null;
		p.__readLock = false;
	}
}

// A custom Close (WHATWG terminate): the readable closes once readQ drains; the writable
// errors, failing every write still queued (and a pending close).
function _Stream_terminatePair(p, out)
{
	if (p.__w === _Stream_W_OPEN || p.__w === _Stream_W_CLOSING)
	{
		p.__w = _Stream_W_ERRORED;
		p.__wReason = _Stream_kTerminated;
		_Stream_drainWriteSide(p, out);
	}
	if (p.__r === _Stream_R_OPEN)
	{
		p.__r = _Stream_R_CLOSED;
	}
}

function _Stream_maybeErase(id)
{
	var p = _Stream_table[id];
	if (!p || p.__pinned || p.__pipeRefs > 0) return;
	if (p.__w !== _Stream_W_CLOSED || p.__r !== _Stream_R_CLOSED) return;
	if (p.__readQ.length || p.__writeQ.length || p.__waitingForRoom.length) return;
	if (p.__parkedRead || p.__closeTok) return;
	if (p.__rawQ.length || p.__readInFlight || p.__readerKick) return;   // mapped source
	delete _Stream_table[id];
}


// --- pump() (§3.5) ---------------------------------------------------------------------

function _Stream_finishWrite(pw, ok, reason)
{
	if (!pw.__tok || !pw.__completeOnTransform) return;
	if (ok)
	{
		_Stream_completeOk(pw.__tok, __Utils_Tuple0);
	}
	else
	{
		_Stream_completeErr(pw.__tok, _Stream_E_CANCELLED, reason);
	}
}

// Custom step (§3.5 pump() 3). `pw` has already left writeQ.
function _Stream_transformCustom(id, pw)
{
	var p = _Stream_table[id];
	var res = A2(p.__customFn, p.__customState, pw.__value);
	var ctor = res.a;
	var newState = res.b;
	var outs = res.c.a;
	var reason = res.c.b;
	p = _Stream_table[id];
	if (!p)
	{
		_Stream_finishWrite(pw, false, _Stream_kWritableClosed);
		return;
	}
	p.__customState = newState;
	var toFail = [];
	var failReason = '';
	switch (ctor)
	{
		case 0: // UpdateState
			break;
		case 1: // Send (may overfill readQ)
			if (p.__r === _Stream_R_OPEN) _Stream_pushAll(p, __List_toArray(outs));
			break;
		case 2: // Close
			if (p.__r === _Stream_R_OPEN) _Stream_pushAll(p, __List_toArray(outs));
			_Stream_terminatePair(p, toFail);
			failReason = _Stream_kTerminated;
			break;
		default: // 3 Cancel
			_Stream_errorPair(p, reason, toFail);
			failReason = reason;
			break;
	}
	// WHATWG: the write whose transform ended or errored the stream still succeeds; the
	// writes queued behind it fail.
	_Stream_finishWrite(pw, true, '');
	_Stream_failAll(toFail, failReason);
}

function _Stream_pushAll(p, values)
{
	for (var i = 0; i < values.length; i++)
	{
		p.__readQ.push(values[i]);
	}
}

// Codec step (§3.5 pump() 4). `pw` has already left writeQ.
function _Stream_transformCodec(id, pw)
{
	var p = _Stream_table[id];
	var outs = [];
	var err = p.__codec.__transform(pw.__value, outs);
	if (err)
	{
		var toFail = [];
		_Stream_errorPair(p, err, toFail);
		_Stream_finishWrite(pw, false, err);
		_Stream_failAll(toFail, err);
		return;
	}
	if (p.__r === _Stream_R_OPEN) _Stream_pushAll(p, outs);
	_Stream_finishWrite(pw, true, '');
}

// One pump of an in-memory pair (Identity, Custom, Codec). Channel kinds are driven by
// their channel results.
function _Stream_pumpCore(id)
{
	for (;;)
	{
		var p = _Stream_table[id];
		if (!p) return;
		if (p.__kind === _Stream_K_SOURCE || p.__kind === _Stream_K_SINK) return;

		var tok, pw;

		// 0. Mapped source: a waiting consumer (a parked read, or a pipe whose
		//    destination has room) takes the next raw chunk: map it.
		if (p.__kind === _Stream_K_MAPPED && !p.__readQ.length && p.__rawQ.length &&
			(p.__parkedRead !== null || _Stream_pipeDemand(p)))
		{
			_Stream_mapHead(id);
			continue;
		}

		// 1. A parked reader takes the head of readQ directly.
		if (p.__parkedRead && p.__readQ.length)
		{
			tok = p.__parkedRead;
			p.__parkedRead = null;
			p.__readLock = false;
			_Stream_completeOk(tok, p.__readQ.shift());
			continue;
		}

		// 2. Transform one value. A waiting reader (a parked read, or a pipe whose
		//    destination has room) opens the gate even when readQ is at capacity 0.
		var demand = p.__readQ.length === 0 && (p.__parkedRead !== null || _Stream_pipeDemand(p));
		if (p.__writeQ.length && p.__r === _Stream_R_OPEN &&
			(p.__readQ.length < p.__readCap || demand))
		{
			pw = p.__writeQ.shift();
			switch (p.__kind)
			{
				case _Stream_K_CUSTOM:
					_Stream_transformCustom(id, pw);
					break;
				case _Stream_K_CODEC:
					_Stream_transformCodec(id, pw);
					break;
				default: // Identity
					p.__readQ.push(pw.__value);
					_Stream_finishWrite(pw, true, '');
					break;
			}
			continue;
		}

		// 3. Room in writeQ: admit a write that was waiting, releasing the lock once
		//    nothing waits. An enqueue completes on admission.
		if (p.__waitingForRoom.length && p.__writeQ.length < p.__writeCap)
		{
			pw = p.__waitingForRoom.shift();
			if (!p.__waitingForRoom.length) p.__writeLock = false;
			var completeNow = null;
			if (!pw.__completeOnTransform)
			{
				completeNow = pw.__tok;
				pw.__tok = null;
			}
			p.__writeQ.push(pw);
			if (completeNow) _Stream_completeOk(completeNow, __Utils_Tuple0);
			continue;
		}

		// 4. A pending close finishes once every accepted write is through. A codec
		//    flushes first.
		if (p.__w === _Stream_W_CLOSING && !p.__writeQ.length && !p.__waitingForRoom.length)
		{
			if (p.__kind === _Stream_K_CODEC && p.__codec)
			{
				var outs = [];
				var err = p.__codec.__flush(outs);
				if (err)
				{
					var toFail = [];
					_Stream_errorPair(p, err, toFail);   // fails the close too
					_Stream_failAll(toFail, err);
					continue;
				}
				if (p.__r === _Stream_R_OPEN) _Stream_pushAll(p, outs);
			}
			p.__w = _Stream_W_CLOSED;
			if (p.__r === _Stream_R_OPEN) p.__r = _Stream_R_CLOSED;
			tok = p.__closeTok;
			p.__closeTok = null;
			if (tok) _Stream_completeOk(tok, __Utils_Tuple0);
			continue;
		}

		// 5. A parked reader on a drained, terminal readable.
		if (p.__parkedRead && !p.__readQ.length && !p.__rawQ.length && p.__r !== _Stream_R_OPEN)
		{
			tok = p.__parkedRead;
			p.__parkedRead = null;
			p.__readLock = false;
			if (p.__r === _Stream_R_CLOSED)
			{
				_Stream_completeErr(tok, _Stream_E_CLOSED, '');
			}
			else
			{
				_Stream_completeErr(tok, _Stream_E_CANCELLED, p.__rReason);
			}
			continue;
		}
		break;
	}
}

// The driver's work list: pair ids (> 0) and pipe ids (stored negated).
var _Stream_work = [];
var _Stream_driving = false;

function _Stream_schedule(item)
{
	if (_Stream_work.indexOf(item) < 0) _Stream_work.push(item);
}

function _Stream_drive()
{
	if (_Stream_driving) return;
	_Stream_driving = true;
	try
	{
		while (_Stream_work.length)
		{
			var item = _Stream_work.shift();
			if (item < 0)
			{
				_Stream_runPipe(-item);
				continue;
			}
			_Stream_pumpCore(item);
			var p = _Stream_table[item];
			if (p && p.__kind === _Stream_K_MAPPED)
			{
				_Stream_mappedMaybeRead(item);
				_Stream_mappedDemand(item);
			}
			if (p)
			{
				if (p.__pipeOutId) _Stream_schedule(-p.__pipeOutId);
				if (p.__pipeInId) _Stream_schedule(-p.__pipeInId);
			}
			_Stream_maybeErase(item);
		}
	}
	catch (e)
	{
		_Stream_work = [];
		_Stream_driving = false;
		throw e;
	}
	_Stream_driving = false;
}

function _Stream_pump(id)
{
	_Stream_schedule(id);
	_Stream_drive();
}

function _Stream_schedulePipe(pipeId)
{
	_Stream_schedule(-pipeId);
	_Stream_drive();
}


// --- Channels -----------------------------------------------------------------------

// Calls `request(done)`; a synchronous `done` is deferred to a microtask, and the result
// is handled inside a stream operation (completions flushed afterwards).
function _Stream_channelCall(request, handler)
{
	var sync = true;
	request(function()
	{
		var args = arguments;
		var run = function() { _Stream_enter(function() { handler.apply(null, args); }); };
		if (sync)
		{
			queueMicrotask(run);
		}
		else
		{
			run();
		}
	});
	sync = false;
}

function _Stream_channelRead(id, ch, tok, maxBytes)
{
	_Stream_noteActivity();
	_Stream_channelCall(
		function(done) { ch.requestRead(maxBytes, done); },
		function(err, chunk) { _Stream_onReadResult(id, ch, tok, err, chunk); }
	);
}

function _Stream_channelWrite(id, ch, tok, bytes)
{
	_Stream_noteActivity();
	_Stream_channelCall(
		function(done) { ch.requestWrite(bytes, done); },
		function(err) { _Stream_onWriteResult(id, ch, tok, err); }
	);
}

function _Stream_channelClose(id, ch, tok)
{
	_Stream_noteActivity();
	_Stream_channelCall(
		function(done) { ch.close(done); },
		function(err) { _Stream_onCloseResult(id, ch, tok, err); }
	);
}

function _Stream_pairOf(id, ch)
{
	var p = _Stream_table[id];
	return p && p.__channel === ch ? p : null;
}

function _Stream_onReadResult(id, ch, tok, err, chunk)
{
	var p = _Stream_pairOf(id, ch);
	if (!p || p.__parkedRead !== tok)
	{
		tok.__resume = null;   // orphaned: drop it
		return;
	}
	p.__parkedRead = null;
	p.__readLock = false;
	if (p.__pipeOutId)
	{
		// A pipe's read (synthetic token): the chunk goes to readQ for the pipe.
		if (err)
		{
			if (p.__r === _Stream_R_OPEN)
			{
				p.__r = _Stream_R_ERRORED;
				p.__rReason = _Stream_describeError(err);
			}
			ch.shutdown();
		}
		else if (!chunk)
		{
			if (p.__r === _Stream_R_OPEN) p.__r = _Stream_R_CLOSED;
			ch.close(null);
		}
		else if (typeof chunk === 'string')
		{
			if (chunk.length) p.__readQ.push(chunk);
		}
		else if (chunk.byteLength)
		{
			p.__readQ.push(_Stream_toBytes(chunk));
		}
		_Stream_pump(id);
		return;
	}
	if (err)
	{
		if (p.__r === _Stream_R_OPEN)
		{
			p.__r = _Stream_R_ERRORED;
			p.__rReason = _Stream_describeError(err);
		}
		var kind = p.__r === _Stream_R_CLOSED ? _Stream_E_CLOSED : _Stream_E_CANCELLED;
		var reason = p.__r === _Stream_R_ERRORED ? p.__rReason : '';
		ch.shutdown();
		_Stream_completeErr(tok, kind, reason);
	}
	else if (!chunk)
	{
		p.__r = _Stream_R_CLOSED;
		ch.close(null);
		_Stream_completeErr(tok, _Stream_E_CLOSED, '');
	}
	else
	{
		_Stream_completeOk(tok, typeof chunk === 'string' ? chunk : _Stream_toBytes(chunk));
	}
	_Stream_pump(id);
}

function _Stream_onWriteResult(id, ch, tok, err)
{
	var p = _Stream_pairOf(id, ch);
	var found = false;
	if (p)
	{
		for (var i = 0; i < p.__writeQ.length; i++)
		{
			if (p.__writeQ[i].__tok === tok)
			{
				p.__writeQ.splice(i, 1);
				found = true;
				break;
			}
		}
	}
	if (!found)
	{
		tok.__resume = null;
		return;
	}
	if (err)
	{
		if (p.__w !== _Stream_W_ERRORED)
		{
			p.__w = _Stream_W_ERRORED;
			p.__wReason = _Stream_describeError(err);
			p.__r = _Stream_R_ERRORED;
			p.__rReason = p.__wReason;
			ch.shutdown();
		}
		_Stream_completeErr(tok, _Stream_E_CANCELLED, p.__wReason);
	}
	else
	{
		_Stream_completeOk(tok, __Utils_Tuple0);
	}
	_Stream_pump(id);
}

function _Stream_onCloseResult(id, ch, tok, err)
{
	var p = _Stream_pairOf(id, ch);
	if (!p || p.__closeTok !== tok)
	{
		tok.__resume = null;
		return;
	}
	p.__closeTok = null;
	if (p.__w === _Stream_W_ERRORED)
	{
		_Stream_completeErr(tok, _Stream_E_CANCELLED, p.__wReason);
	}
	else if (err)
	{
		p.__w = _Stream_W_ERRORED;
		p.__wReason = _Stream_describeError(err);
		_Stream_completeErr(tok, _Stream_E_CANCELLED, p.__wReason);
	}
	else
	{
		p.__w = _Stream_W_CLOSED;
		if (p.__r === _Stream_R_OPEN) p.__r = _Stream_R_CLOSED;
		_Stream_completeOk(tok, __Utils_Tuple0);
	}
	_Stream_pump(id);
}

function _Stream_createChannelSource(channel)
{
	var p = _Stream_newPair(_Stream_K_SOURCE);
	p.__channel = channel;
	p.__w = _Stream_W_CLOSED;   // no writable side
	return _Stream_insert(p);
}

function _Stream_createChannelSink(channel)
{
	var p = _Stream_newPair(_Stream_K_SINK);
	p.__channel = channel;
	p.__r = _Stream_R_CLOSED;   // no readable side
	return _Stream_insert(p);
}

function _Stream_createTextChannelSink(channel)
{
	var id = _Stream_createChannelSink(channel);
	_Stream_table[id].__textSink = true;
	return id;
}

function _Stream_discardReadable(id)
{
	_Stream_enter(function() { _Stream_cancelReadableNow(id, ''); });
}


// --- Value-mapped pairs (plans/eco-system-websockets.md §3.3) ------------------------

function _Stream_wireTuple(chunk)
{
	return __Utils_Tuple3(
		chunk.tag,
		typeof chunk.text === 'string' ? chunk.text : '',
		_Stream_toBytes(chunk.bytes || new Uint8Array(0))
	);
}

// Mapped source: maps the head of rawQ through fromWire into readQ.
function _Stream_mapHead(id)
{
	var p = _Stream_table[id];
	if (!p || !p.__rawQ.length) return;
	var chunk = p.__rawQ.shift();
	var v = p.__mapFn(_Stream_wireTuple(chunk));
	p = _Stream_table[id];
	if (p) p.__readQ.push(v);
}

function _Stream_mappedMaybeRead(id)
{
	var p = _Stream_table[id];
	if (!p || p.__kind !== _Stream_K_MAPPED || !p.__channel) return;
	if (p.__r !== _Stream_R_OPEN || p.__readInFlight || p.__readerKick) return;
	if (p.__rawQ.length || p.__readQ.length) return;   // read-ahead: one chunk
	var ch = p.__channel;
	var tok = { __resume: null };
	p.__readInFlight = tok;
	_Stream_channelCall(
		function(done) { ch.requestRead(_Stream_kChannelReadChunk, done); },
		function(err, chunk) { _Stream_onMappedRead(id, ch, tok, err, chunk); }
	);
}

// Tells the channel whether a consumer waits (parked read or pipe): native counts those
// in pendingAsync, so the JS channel refs its handle only then.
function _Stream_mappedDemand(id)
{
	var p = _Stream_table[id];
	if (!p || p.__kind !== _Stream_K_MAPPED || !p.__channel) return;
	var demand = p.__r === _Stream_R_OPEN && (p.__parkedRead !== null || !!p.__pipeOutId);
	if (demand === p.__demand) return;
	p.__demand = demand;
	if (demand) _Stream_noteActivity();
	if (typeof p.__channel.setDemand === 'function') p.__channel.setDemand(demand);
}

function _Stream_onMappedRead(id, ch, tok, err, chunk)
{
	var p = _Stream_pairOf(id, ch);
	if (!p || p.__readInFlight !== tok) return;   // stale
	p.__readInFlight = null;
	if (err)
	{
		if (p.__r === _Stream_R_OPEN)
		{
			p.__r = _Stream_R_ERRORED;
			p.__rReason = _Stream_describeError(err);
			p.__rErr = err;
		}
		ch.shutdown();
	}
	else if (!chunk)
	{
		if (p.__r === _Stream_R_OPEN) p.__r = _Stream_R_CLOSED;
		ch.close(null);
	}
	else if (p.__r === _Stream_R_OPEN)
	{
		p.__rawQ.push(chunk);   // mapped when a consumer takes it
	}
	if (p.__reader && !p.__readerKick)
	{
		_Stream_feedReader(id);
	}
	else
	{
		_Stream_pump(id);
	}
}

// The chunks / end the reader has not seen yet, then the next read-ahead.
function _Stream_feedReader(id)
{
	for (;;)
	{
		var p = _Stream_table[id];
		if (!p) return;
		if (!p.__reader)
		{
			_Stream_pump(id);
			return;
		}
		var fn = p.__reader;
		if (p.__rawQ.length)
		{
			fn(null, p.__rawQ.shift());
			continue;
		}
		if (p.__r !== _Stream_R_OPEN)
		{
			if (!p.__readerEndSent)
			{
				p.__readerEndSent = true;
				if (p.__r === _Stream_R_CLOSED)
				{
					fn(null, null);
				}
				else
				{
					fn(p.__rErr || _Stream_socketError(p.__rReason, 'EIO'), null);
				}
				continue;
			}
			_Stream_pump(id);   // erasure checks
			return;
		}
		_Stream_mappedMaybeRead(id);
		return;
	}
}

function _Stream_createMappedSource(channel, fromWire)
{
	var p = _Stream_newPair(_Stream_K_MAPPED);
	p.__channel = channel;
	p.__w = _Stream_W_CLOSED;   // no writable side
	p.__readCap = 1;
	p.__mapFn = fromWire;
	var id = _Stream_insert(p);
	_Stream_mappedMaybeRead(id);   // read ahead
	return id;
}

function _Stream_createMappedSink(channel, toWire)
{
	var id = _Stream_createChannelSink(channel);
	_Stream_table[id].__mapFn = toWire;
	return id;
}

// A mapped sink's channel write of value `v` (toWire first).
function _Stream_mappedWrite(id, p, tok, v)
{
	var w = p.__mapFn(v);
	var chunk = { tag: w.a, text: w.b, bytes: _Stream_toUint8Array(w.c) };
	var ch = p.__channel;
	_Stream_noteActivity();
	_Stream_channelCall(
		function(done)
		{
			if (typeof ch.requestWriteTagged === 'function')
			{
				ch.requestWriteTagged(chunk, done);
			}
			else if (chunk.tag === 0)
			{
				ch.requestWrite(chunk.bytes, done);
			}
			else
			{
				done(_Stream_socketError('write ENOTSUP', 'ENOTSUP'));
			}
		},
		function(err) { _Stream_onWriteResult(id, ch, tok, err); }
	);
}

function _Stream_attachReader(id, fn)
{
	var p = _Stream_table[id];
	if (!p || p.__kind !== _Stream_K_MAPPED || !fn) return false;
	if (p.__reader || p.__readLock || p.__pipedOut || p.__readQ.length) return false;
	p.__reader = fn;
	if (p.__rawQ.length || p.__r !== _Stream_R_OPEN)
	{
		if (!p.__readerKick)
		{
			p.__readerKick = true;
			queueMicrotask(function()
			{
				_Stream_enter(function()
				{
					var q = _Stream_table[id];
					if (!q) return;
					q.__readerKick = false;
					_Stream_feedReader(id);
				});
			});
		}
	}
	else
	{
		_Stream_mappedMaybeRead(id);
	}
	return true;
}

function _Stream_detachReader(id)
{
	var p = _Stream_table[id];
	if (!p || !p.__reader) return;
	p.__reader = null;
	_Stream_enter(function() { _Stream_pump(id); });
}


// --- Node stream adapters ------------------------------------------------------------

function _Stream_cancelledError()
{
	var e = new Error('operation canceled');
	e.code = 'ECANCELED';
	return e;
}

function _Stream_nodeReadableChannel(readableOrThunk, options)
{
	var keepOpen = !!(options && options.keepOpen);
	var readable = null;
	var buffered = [];   // Buffers received but not yet delivered
	var ended = false;
	var error = null;
	var pending = null;  // { __max, __done }
	var closed = false;

	function onData(chunk)
	{
		buffered.push(typeof chunk === 'string' ? Buffer.from(chunk) : chunk);
		readable.pause();
		deliver();
	}
	function onEnd() { ended = true; deliver(); }
	function onError(e) { error = e; deliver(); }

	function attach()
	{
		if (readable) return;
		readable = typeof readableOrThunk === 'function' ? readableOrThunk() : readableOrThunk;
		readable.pause();   // before 'data', so attaching it does not start flowing
		readable.on('data', onData);
		readable.on('end', onEnd);
		readable.on('error', onError);
		// A stream that already ended, failed or was destroyed before the first read emits
		// nothing more (a child pipe reaching EOF with nothing buffered ends at once).
		if (readable.errored)
		{
			error = readable.errored;
		}
		else if (readable.readableEnded || (readable.destroyed && readable.readableLength === 0))
		{
			ended = true;
		}
	}

	function detach()
	{
		if (!readable) return;
		readable.removeListener('data', onData);
		readable.removeListener('end', onEnd);
		// The error listener stays: a late error must not crash the process.
		if (keepOpen)
		{
			readable.pause();
		}
		else if (!readable.destroyed)
		{
			readable.destroy();
		}
	}

	function deliver()
	{
		if (!pending) return;
		var p = pending;
		if (buffered.length)
		{
			pending = null;
			var head = buffered[0];
			var chunk;
			if (head.length <= p.__max)
			{
				chunk = buffered.shift();
			}
			else
			{
				chunk = head.subarray(0, p.__max);
				buffered[0] = head.subarray(p.__max);
			}
			p.__done(null, new Uint8Array(chunk.buffer, chunk.byteOffset, chunk.byteLength));
		}
		else if (error)
		{
			pending = null;
			p.__done(error, null);
		}
		else if (ended)
		{
			pending = null;
			p.__done(null, null);
		}
		else
		{
			readable.resume();
		}
	}

	function cancelPending()
	{
		if (pending)
		{
			var p = pending;
			pending = null;
			p.__done(_Stream_cancelledError(), null);
		}
	}

	return {
		requestRead: function(maxBytes, done)
		{
			if (closed)
			{
				done(_Stream_cancelledError(), null);
				return;
			}
			attach();
			pending = { __max: maxBytes > 0 ? maxBytes : _Stream_kChannelReadChunk, __done: done };
			deliver();
		},
		requestWrite: function(bytes, done)
		{
			done(new Error('not a writable channel'));
		},
		close: function(done)
		{
			if (!closed)
			{
				closed = true;
				cancelPending();
				detach();
			}
			if (done) done(null);
		},
		shutdown: function()
		{
			if (!closed)
			{
				closed = true;
				cancelPending();
				detach();
			}
		}
	};
}

function _Stream_nodeWritableChannel(writableOrThunk, options)
{
	var keepOpen = !!(options && options.keepOpen);
	var writable = null;
	var inflight = 0;
	var dead = null;
	var closing = null;   // done callback of a close waiting for the writes in flight
	var closed = false;

	function onError(e)
	{
		if (!dead) dead = e;
	}

	function attach()
	{
		if (writable) return;
		writable = typeof writableOrThunk === 'function' ? writableOrThunk() : writableOrThunk;
		writable.on('error', onError);
	}

	function finishClose()
	{
		var done = closing;
		closing = null;
		if (keepOpen)
		{
			done(dead && dead.code !== 'ECANCELED' ? dead : null);
			return;
		}
		writable.end(function(err) { done(err || null); });
	}

	return {
		requestRead: function(maxBytes, done)
		{
			done(new Error('not a readable channel'), null);
		},
		requestWrite: function(bytes, done)
		{
			attach();
			if (dead || closed)
			{
				done(dead || _Stream_cancelledError());
				return;
			}
			inflight++;
			writable.write(Buffer.from(bytes.buffer, bytes.byteOffset, bytes.byteLength), function(err)
			{
				inflight--;
				done(err || (dead && dead.code === 'ECANCELED' ? dead : null));
				if (closing && inflight === 0) finishClose();
			});
		},
		close: function(done)
		{
			attach();
			closed = true;
			closing = done || function() {};
			if (inflight === 0) finishClose();
		},
		shutdown: function()
		{
			closed = true;
			if (!dead) dead = _Stream_cancelledError();
			if (writable && !keepOpen && !writable.destroyed) writable.destroy();
		}
	};
}

function _Stream_fromNodeReadable(readable, options)
{
	return _Stream_createChannelSource(_Stream_nodeReadableChannel(readable, options));
}

function _Stream_fromNodeWritable(writable, options)
{
	return _Stream_createChannelSink(_Stream_nodeWritableChannel(writable, options));
}


// --- Duplex sockets (plans/eco-system-sockets.md Appendix E, §3.3.3, §D.2) -----------------
//
// _Stream_nodeDuplexChannels(socket, options) -> { read, write, abort(reason), reset(reason) }
//
// Two ByteChannels over ONE connected net.Socket / tls.TLSSocket created with
// allowHalfOpen: true (the readable and writable adapters above destroy their Node stream
// on close, which would end both directions of a socket):
//   - read: never prefetches beyond Node's own buffer (resumed only while a read is
//     pending, paused after each chunk). close/shutdown stops reading without destroying.
//     A shutdown before end of input marks the read side abandoned: the final close then
//     discards incoming data for up to 2 s (or until the peer's FIN) before destroying,
//     so the kernel does not answer our FIN with RST (native §3.3.3, N8).
//   - write: close is socket.end() (FIN; TLS close_notify first), completing on 'finish';
//     shutdown fails the writes in flight and ends the socket.
//   - the socket is destroyed when both sides are done, or by abort / reset.
//   - abort(reason) (Socket.close): fails the pending read and writes with `reason`,
//     completes a pending write close, destroys the socket. Later requests fail with
//     `reason` (a read after end of input still gives end of input).
//   - reset(reason) (Socket.reset): as abort, through resetAndDestroy() (RST) on
//     options.raw (the net.Socket under a TLSSocket) or the socket; Unix sockets, where
//     Node throws, are destroyed.
//   - detach(reason) (WebSocket.upgradeRequest, plans/eco-system-websockets.md §3.2, E.3):
//     hands the socket to another protocol: { socket, raw, buffered (a Buffer of the data
//     received and not delivered), eof }; or { error, message } (ECANCELED when the socket
//     is closed or its write side ended, EBUSY while a read, write or close is in flight or
//     after an earlier detach). Afterwards the channels' requests fail with `reason`, and
//     the duplex no longer reads, refs or destroys the socket, except that abort / reset
//     (Socket.close / Socket.reset on the old connection) still destroy it.
// Errors carry `reason` (_Stream_describeError uses it): "read <CODE>" / "write <CODE>"
// for socket errors (a socket error fails later reads and writes the same way), the abort
// reason after abort / reset.
// The socket is unref'd while no request is pending, so an idle connection does not keep
// the program alive (native: an idle connection holds no pendingAsync count, §3.3.8).

function _Stream_socketError(reason, code)
{
	var e = new Error(reason);
	e.code = code || 'ECANCELED';
	e.reason = reason;
	return e;
}

function _Stream_nodeDuplexChannels(socket, options)
{
	var raw = (options && options.raw) || socket;
	var buffered = [];       // Buffers received, not yet delivered
	var eof = false;
	var errCode = null;      // a socket error's code
	var aborted = null;      // abort / reset reason
	var pendingRead = null;  // { __max, __done }
	var writes = [];         // { __done } in flight, oldest first
	var closing = null;      // done of a pending write close
	var readDone = false;
	var readAbandoned = false;
	var writeDone = false;
	var finalized = false;
	var reffed = true;
	var detached = null;     // detach reason

	function busy()
	{
		return !!pendingRead || writes.length > 0 || !!closing;
	}

	function updateRef()
	{
		if (detached) return;   // the new owner refs the socket
		var want = busy() && !socket.destroyed;
		if (want === reffed) return;
		reffed = want;
		try
		{
			if (want) socket.ref(); else socket.unref();
		}
		catch (e) { /* destroyed */ }
	}

	function readError()
	{
		if (detached) return _Stream_socketError(detached, 'ECANCELED');
		if (aborted) return _Stream_socketError(aborted, 'ECANCELED');
		if (errCode) return _Stream_socketError('read ' + errCode, errCode);
		return null;
	}

	function writeError()
	{
		if (detached) return _Stream_socketError(detached, 'ECANCELED');
		if (aborted) return _Stream_socketError(aborted, 'ECANCELED');
		if (errCode) return _Stream_socketError('write ' + errCode, errCode);
		return null;
	}

	function deliver()
	{
		if (!pendingRead) return;
		var p = pendingRead;
		var err;
		if (buffered.length && !aborted)
		{
			pendingRead = null;
			var head = buffered[0];
			var chunk;
			if (head.length <= p.__max)
			{
				chunk = buffered.shift();
			}
			else
			{
				chunk = head.subarray(0, p.__max);
				buffered[0] = head.subarray(p.__max);
			}
			updateRef();
			p.__done(null, new Uint8Array(chunk.buffer, chunk.byteOffset, chunk.byteLength));
		}
		else if (eof)
		{
			pendingRead = null;
			updateRef();
			p.__done(null, null);
		}
		else if ((err = readError()))
		{
			pendingRead = null;
			updateRef();
			p.__done(err, null);
		}
		else if (socket.destroyed)
		{
			// Closed under us without an error or a FIN we saw.
			pendingRead = null;
			updateRef();
			p.__done(_Stream_socketError('socket closed', 'ECANCELED'), null);
		}
		else
		{
			socket.resume();
		}
	}

	function failWrites(errFn)
	{
		var ws = writes;
		writes = [];
		for (var i = 0; i < ws.length; i++)
		{
			if (!ws[i].__settled)
			{
				ws[i].__settled = true;
				ws[i].__done(errFn());
			}
		}
	}

	function finishClose(err)
	{
		if (!closing) return;
		var done = closing;
		closing = null;
		writeDone = true;
		updateRef();
		done(err);
		maybeFinalize();
	}

	function maybeFinalize()
	{
		if (finalized || !readDone || !writeDone) return;
		finalized = true;
		if (socket.destroyed) return;
		if (readAbandoned && !eof && !errCode && !aborted)
		{
			// Discard incoming data until the peer's FIN or 2 s, then destroy.
			var timer = setTimeout(function() { socket.destroy(); }, 2000);
			if (timer.unref) timer.unref();
			socket.on('data', function() {});
			socket.once('end', function() { clearTimeout(timer); socket.destroy(); });
			socket.once('close', function() { clearTimeout(timer); });
			socket.resume();
			return;
		}
		socket.destroy();
	}

	socket.pause();   // before 'data', so attaching it does not start flowing
	function onData(chunk)
	{
		if (readDone) return;   // abandoned: discard
		buffered.push(typeof chunk === 'string' ? Buffer.from(chunk) : chunk);
		socket.pause();
		deliver();
	}
	function onEnd()
	{
		eof = true;
		deliver();
	}
	function onError(e)
	{
		if (!errCode && !aborted) errCode = (e && e.code) || 'EIO';
		deliver();
		failWrites(writeError);
		finishClose(writeError());
	}
	function onClose()
	{
		deliver();
		failWrites(function() { return writeError() || _Stream_socketError('socket closed', 'ECANCELED'); });
		finishClose(writeError() || _Stream_socketError('socket closed', 'ECANCELED'));
		updateRef();
	}
	socket.on('data', onData);
	socket.on('end', onEnd);
	socket.on('error', onError);
	socket.on('close', onClose);
	updateRef();

	function detach(reason)
	{
		if (detached)
		{
			return { error: 'EBUSY', message: 'upgradeRequest EBUSY: the connection was taken over already' };
		}
		if (aborted || socket.destroyed || writeDone || closing)
		{
			return { error: 'ECANCELED', message: 'socket closed' };
		}
		if (pendingRead || writes.length)
		{
			return { error: 'EBUSY', message: 'upgradeRequest EBUSY: the connection has a read, write or close in progress' };
		}
		socket.removeListener('data', onData);
		socket.removeListener('end', onEnd);
		socket.removeListener('error', onError);
		socket.removeListener('close', onClose);
		socket.pause();
		var data = buffered.length ? Buffer.concat(buffered) : Buffer.alloc(0);
		buffered = [];
		detached = reason;
		readDone = true;
		writeDone = true;
		finalized = true;
		return { socket: socket, raw: raw, buffered: data, eof: eof };
	}

	function stop(reason, useReset)
	{
		if (aborted) return;
		aborted = reason;
		buffered = [];
		readDone = true;
		writeDone = true;
		finalized = true;
		deliver();
		failWrites(writeError);
		if (closing)
		{
			var done = closing;
			closing = null;
			done(null);   // a pending closeWritable completes (native §D.2)
		}
		if (!socket.destroyed)
		{
			var resetDone = false;
			if (useReset && raw.resetAndDestroy)
			{
				try
				{
					raw.resetAndDestroy();
					resetDone = true;
				}
				catch (e) { /* Unix sockets: plain destroy */ }
			}
			if (!resetDone) socket.destroy();
			if (raw !== socket && !raw.destroyed) raw.destroy();
		}
		updateRef();
	}

	var read = {
		requestRead: function(maxBytes, done)
		{
			if (readDone && !aborted)
			{
				done(detached ? readError() : _Stream_socketError('socket closed', 'ECANCELED'), null);
				return;
			}
			pendingRead = { __max: maxBytes > 0 ? maxBytes : _Stream_kChannelReadChunk, __done: done };
			updateRef();
			deliver();
		},
		requestWrite: function(bytes, done)
		{
			done(new Error('not a writable channel'));
		},
		close: function(done)
		{
			if (!readDone)
			{
				readDone = true;
				if (!eof) readAbandoned = true;
				if (pendingRead)
				{
					var p = pendingRead;
					pendingRead = null;
					p.__done(_Stream_cancelledError(), null);
				}
				if (!socket.destroyed) socket.pause();
				updateRef();
				maybeFinalize();
			}
			if (done) done(null);
		},
		shutdown: function()
		{
			read.close(null);
		}
	};

	var write = {
		requestRead: function(maxBytes, done)
		{
			done(new Error('not a readable channel'), null);
		},
		requestWrite: function(bytes, done)
		{
			var err = writeError();
			if (err || writeDone || closing || socket.destroyed)
			{
				done(err || _Stream_socketError('socket closed', 'ECANCELED'));
				return;
			}
			var entry = { __done: done, __settled: false };
			writes.push(entry);
			updateRef();
			socket.write(Buffer.from(bytes.buffer, bytes.byteOffset, bytes.byteLength), function(e)
			{
				if (entry.__settled) return;
				entry.__settled = true;
				var i = writes.indexOf(entry);
				if (i >= 0) writes.splice(i, 1);
				if (e && !errCode && !aborted) errCode = e.code || 'EIO';
				updateRef();
				done(e ? writeError() : null);
			});
		},
		close: function(done)
		{
			done = done || function() {};
			var err = writeError();
			if (err || writeDone || closing || socket.destroyed)
			{
				done(err || (writeDone ? null : _Stream_socketError('socket closed', 'ECANCELED')));
				return;
			}
			closing = done;
			updateRef();
			socket.end(function(e)
			{
				finishClose(e ? (writeError() || _Stream_socketError('write ' + (e.code || 'EIO'), e.code)) : null);
			});
		},
		shutdown: function()
		{
			if (writeDone) return;
			writeDone = true;
			failWrites(_Stream_cancelledError);
			if (closing)
			{
				var done = closing;
				closing = null;
				done(_Stream_cancelledError());
			}
			if (!socket.destroyed && !socket.writableEnded) socket.end();
			updateRef();
			maybeFinalize();
		}
	};

	return {
		read: read,
		write: write,
		abort: function(reason) { stop(reason || 'socket closed', false); },
		reset: function(reason) { stop(reason || 'socket closed', true); },
		detach: detach
	};
}


// --- Codecs (StreamCodec.cpp) -----------------------------------------------------------
//
// A codec is { __transform(value, outs) -> error string | null, __flush(outs) -> error | null }.
//
// Compression uses node:zlib synchronously and incrementally: one zlib object per pair,
// driven through its native handle's writeSync (the loop of node's own processChunkSync,
// which cannot be reused because it closes the handle after one call). Each written chunk
// is processed with Z_NO_FLUSH, like the C++ codec, and the close flushes with Z_FINISH;
// output arrives in chunks of at most 64 KiB. Node's error messages are zlib's
// ("incorrect header check"); a decompression ended early reports "Unexpected end of
// compressed data." as the C++ codec does. Unlike the C++ codec, data after the end of a
// deflate / raw stream is ignored, and after a gzip member it must be another gzip member
// (node's multi-member handling) or it fails.

function _Stream_zlibCodec(compress, algorithm)
{
	var zlib = require('zlib');
	var ctors = compress
		? [zlib.Gzip, zlib.Deflate, zlib.DeflateRaw]
		: [zlib.Gunzip, zlib.Inflate, zlib.InflateRaw];
	var Ctor = ctors[algorithm] || ctors[2];
	var z = new Ctor({ chunkSize: 64 * 1024 });
	var state = { __err: null, __failed: false };
	z._handle.onerror = function(message, errno)
	{
		state.__err = message || ('zlib error ' + errno);
	};
	var C = zlib.constants;

	function run(input, flush, outs)
	{
		var handle = z._handle;
		var ws = z._writeState;
		var size = z._chunkSize;
		var inOff = 0;
		var availIn = input.byteLength;
		for (;;)
		{
			var out = Buffer.allocUnsafe(size);
			handle.writeSync(flush, input, inOff, availIn, out, 0, size);
			if (state.__err) return state.__err;
			var availOutAfter = ws[0];
			var availInAfter = ws[1];
			var have = size - availOutAfter;
			if (have > 0) outs.push(_Stream_toBytes(new Uint8Array(out.buffer, out.byteOffset, have)));
			inOff += availIn - availInAfter;
			availIn = availInAfter;
			if (availOutAfter !== 0) return null;
		}
	}

	function fail(err)
	{
		state.__failed = true;
		try { z.close(); } catch (e) { }
		return err;
	}

	return {
		__takesString: false,
		__transform: function(value, outs)
		{
			if (state.__failed) return 'The compression stream has failed.';
			if (!value.byteLength) return null;
			var input = Buffer.from(value.buffer, value.byteOffset, value.byteLength);
			var err = run(input, C.Z_NO_FLUSH, outs);
			return err ? fail(err) : null;
		},
		__flush: function(outs)
		{
			if (state.__failed) return 'The compression stream has failed.';
			var err = run(Buffer.alloc(0), C.Z_FINISH, outs);
			if (err)
			{
				return fail(!compress && /unexpected end of file/.test(err)
					? 'Unexpected end of compressed data.'
					: err);
			}
			try { z.close(); } catch (e) { }
			return null;
		}
	};
}

// String -> UTF-8 Bytes. Empty output produces nothing; a high surrogate at the end of a
// chunk is carried into the next one (manual carry); lone surrogates become U+FFFD (as
// TextEncoder does); a high surrogate left at close becomes EF BF BD.
function _Stream_textEncoderCodec()
{
	var encoder = new TextEncoder();
	var pendingHigh = '';
	return {
		__transform: function(value, outs)
		{
			var s = pendingHigh + value;
			pendingHigh = '';
			if (s.length)
			{
				var last = s.charCodeAt(s.length - 1);
				if (last >= 0xD800 && last <= 0xDBFF)
				{
					pendingHigh = s.slice(-1);
					s = s.slice(0, -1);
				}
			}
			if (s.length) outs.push(_Stream_toBytes(encoder.encode(s)));
			return null;
		},
		__flush: function(outs)
		{
			if (pendingHigh)
			{
				pendingHigh = '';
				outs.push(_Stream_toBytes(new Uint8Array([0xEF, 0xBF, 0xBD])));
			}
			return null;
		}
	};
}

// UTF-8 Bytes -> String with WHATWG TextDecoder semantics ({fatal: false, ignoreBOM:
// false}, stream: true): U+FFFD for invalid input, a leading BOM stripped, incomplete
// sequences carried across chunks, nothing emitted for empty output.
function _Stream_textDecoderCodec()
{
	var decoder = new TextDecoder('utf-8', { fatal: false, ignoreBOM: false });
	return {
		__transform: function(value, outs)
		{
			var s = decoder.decode(_Stream_toUint8Array(value), { stream: true });
			if (s.length) outs.push(s);
			return null;
		},
		__flush: function(outs)
		{
			var s = decoder.decode();
			if (s.length) outs.push(s);
			return null;
		}
	};
}

// A Codec pair; capacities 1/1 (§10 Phase 6: the codecs buffer one chunk on each side).
function _Stream_insertCodec(codec)
{
	var p = _Stream_newPair(_Stream_K_CODEC);
	p.__readCap = 1;
	p.__writeCap = 1;
	p.__codec = codec;
	return _Stream_insert(p);
}


// --- Pipes (StreamPipe.cpp) ----------------------------------------------------------------

var _Stream_pipes = {};
var _Stream_nextPipeId = 1;

function _Stream_dstCanAccept(d)
{
	return !!d && d.__w === _Stream_W_OPEN && !d.__waitingForRoom.length &&
		d.__writeQ.length < d.__writeCap;
}

function _Stream_pushIntoDst(dstId, d, v)
{
	if (d.__kind === _Stream_K_SINK && d.__mapFn)
	{
		var mtok = { __resume: null };
		d.__writeQ.push({ __tok: mtok, __value: null, __completeOnTransform: true });
		_Stream_mappedWrite(dstId, d, mtok, v);
		return;
	}
	if (d.__kind === _Stream_K_SINK)
	{
		var tok = { __resume: null };
		d.__writeQ.push({ __tok: tok, __value: null, __completeOnTransform: true });
		_Stream_channelWrite(dstId, d.__channel, tok, d.__textSink ? v : _Stream_toUint8Array(v));
		return;
	}
	d.__writeQ.push({ __tok: null, __value: v, __completeOnTransform: true });
}

function _Stream_closeDst(dstId, d)
{
	d.__w = _Stream_W_CLOSING;
	if (d.__kind === _Stream_K_SINK)
	{
		var tok = { __resume: null };
		d.__closeTok = tok;
		_Stream_channelClose(dstId, d.__channel, tok);
	}
	// In-memory: the dst pump finishes the close (a codec flushes first).
}

function _Stream_finishPipe(pid, ok, reason)
{
	var pp = _Stream_pipes[pid];
	if (!pp) return;
	delete _Stream_pipes[pid];
	var s = _Stream_table[pp.__src];
	if (s && s.__pipeOutId === pid)
	{
		s.__pipeOutId = 0;
		s.__pipedOut = false;
		s.__pipeRefs--;
	}
	var d = _Stream_table[pp.__dst];
	if (d && d.__pipeInId === pid)
	{
		d.__pipeInId = 0;
		d.__pipedIn = false;
		d.__pipeRefs--;
	}
	if (pp.__tok)
	{
		if (ok)
		{
			_Stream_completeOk(pp.__tok, __Utils_Tuple0);
		}
		else
		{
			_Stream_completeErr(pp.__tok, _Stream_E_CANCELLED, reason);
		}
	}
	_Stream_pump(pp.__src);   // erasure checks, now that the pipe is gone
	_Stream_pump(pp.__dst);
}

function _Stream_createPipe(src, dst, tok)
{
	var pid = _Stream_nextPipeId++;
	_Stream_pipes[pid] = { __src: src, __dst: dst, __tok: tok, __closingDst: false };
	var s = _Stream_table[src];
	if (s)
	{
		s.__pipedOut = true;
		s.__pipeOutId = pid;
		s.__pipeRefs++;
	}
	var d = _Stream_table[dst];
	if (d)
	{
		d.__pipedIn = true;
		d.__pipeInId = pid;
		d.__pipeRefs++;
	}
	return pid;
}

function _Stream_pipeDemand(src)
{
	if (!src.__pipeOutId) return false;
	var pp = _Stream_pipes[src.__pipeOutId];
	if (!pp || pp.__closingDst) return false;
	return _Stream_dstCanAccept(_Stream_table[pp.__dst]);
}

function _Stream_runPipe(pid)
{
	for (;;)
	{
		var pp = _Stream_pipes[pid];
		if (!pp) return;
		var s = _Stream_table[pp.__src];
		var d = _Stream_table[pp.__dst];
		var reason;

		// 4 (second half). Waiting for the close of dst.
		if (pp.__closingDst)
		{
			if (!d || d.__w === _Stream_W_CLOSED)
			{
				_Stream_finishPipe(pid, true, '');
			}
			else if (d.__w === _Stream_W_ERRORED)
			{
				_Stream_finishPipe(pid, false, d.__wReason);
			}
			return;
		}

		// 1. dst errored or closed -> cancel src.
		if (!d || d.__w !== _Stream_W_OPEN)
		{
			reason = (d && d.__w === _Stream_W_ERRORED) ? d.__wReason : _Stream_kWritableClosed;
			_Stream_finishPipe(pid, false, reason);
			_Stream_cancelReadableNow(pp.__src, reason);
			return;
		}

		// 2. src errored -> abort dst.
		if (s && s.__r === _Stream_R_ERRORED)
		{
			reason = s.__rReason;
			_Stream_finishPipe(pid, false, reason);
			_Stream_cancelWritableNow(pp.__dst, reason);
			return;
		}

		// 3. Move one value.
		if (s && s.__readQ.length && _Stream_dstCanAccept(d))
		{
			_Stream_pushIntoDst(pp.__dst, d, s.__readQ.shift());
			_Stream_pump(pp.__src);   // room in readQ: transform more
			_Stream_pump(pp.__dst);
			continue;
		}

		// 4. src closed and drained -> close dst.
		var srcDone = !s || (s.__r === _Stream_R_CLOSED && !s.__readQ.length && !s.__rawQ.length &&
			!s.__parkedRead);
		if (srcDone)
		{
			pp.__closingDst = true;
			_Stream_closeDst(pp.__dst, d);
			_Stream_pump(pp.__dst);
			continue;
		}

		// 5a. An in-memory source with a value waiting in writeQ: the pipe is a waiting
		//     reader now, so pump the source (readCap 0 sources transform only here).
		if (s.__kind !== _Stream_K_SOURCE && s.__kind !== _Stream_K_SINK &&
			s.__r === _Stream_R_OPEN && !s.__readQ.length && s.__writeQ.length &&
			_Stream_dstCanAccept(d))
		{
			_Stream_pump(pp.__src);
			return;
		}

		// 5c. A mapped source: a chunk read ahead is mapped by its pump (the pipe is a
		//     waiting reader); otherwise its read-ahead request is (or now goes) out.
		if (s.__kind === _Stream_K_MAPPED && s.__r === _Stream_R_OPEN && !s.__readQ.length &&
			_Stream_dstCanAccept(d))
		{
			if (s.__rawQ.length)
			{
				_Stream_pump(pp.__src);
			}
			else
			{
				_Stream_mappedMaybeRead(pp.__src);
				_Stream_mappedDemand(pp.__src);
			}
			return;
		}

		// 5b. A channel source: the pipe reads.
		if (s.__kind === _Stream_K_SOURCE && s.__r === _Stream_R_OPEN && !s.__parkedRead &&
			!s.__readQ.length && _Stream_dstCanAccept(d) && s.__channel)
		{
			var tok = { __resume: null };
			s.__parkedRead = tok;
			_Stream_channelRead(pp.__src, s.__channel, tok, _Stream_kChannelReadChunk);
		}
		return;
	}
}

function _Stream_pipeStreams(src, dst)
{
	var ok = false;
	_Stream_enter(function()
	{
		var s = _Stream_table[src];
		var d = _Stream_table[dst];
		if ((s && _Stream_readLocked(s)) || (d && _Stream_writeLocked(d))) return;
		var pid = _Stream_createPipe(src, dst, null);
		_Stream_schedulePipe(pid);
		ok = true;
	});
	return ok;
}


// --- Cancellation ----------------------------------------------------------------------

function _Stream_cancelReadableNow(id, reason)
{
	var p = _Stream_table[id];
	if (!p) return;
	var toFail = [];
	if (p.__r === _Stream_R_OPEN) p.__r = _Stream_R_CLOSED;   // later reads give Closed
	p.__readQ = [];
	p.__rawQ = [];
	if (p.__w === _Stream_W_OPEN || p.__w === _Stream_W_CLOSING)
	{
		p.__w = _Stream_W_ERRORED;
		p.__wReason = reason;
		_Stream_drainWriteSide(p, toFail);
	}
	if ((p.__kind === _Stream_K_SOURCE || p.__kind === _Stream_K_MAPPED) && p.__channel) p.__channel.shutdown();
	_Stream_failAll(toFail, reason);
	_Stream_pump(id);
}

function _Stream_cancelWritableNow(id, reason)
{
	var p = _Stream_table[id];
	if (!p) return;
	if (p.__w === _Stream_W_CLOSED || p.__w === _Stream_W_ERRORED) return;
	var toFail = [];
	_Stream_errorPair(p, reason, toFail);   // reads give Cancelled reason
	if (p.__kind === _Stream_K_SINK && p.__channel) p.__channel.shutdown();
	_Stream_failAll(toFail, reason);
	_Stream_pump(id);
}


// --- Kernel functions (B.2) ------------------------------------------------------------

// A binding whose body runs as one stream operation.
function _Stream_op(body)
{
	return __Scheduler_binding(function(callback)
	{
		_Stream_enter(function() { body(callback); });
	});
}

// identity : Int -> Int -> Task Never Int
var _Stream_identity = F2(function(readCap, writeCap)
{
	return _Stream_op(function(callback)
	{
		var p = _Stream_newPair(_Stream_K_IDENTITY);
		p.__readCap = readCap < 1 ? 1 : readCap;
		p.__writeCap = writeCap < 1 ? 1 : writeCap;
		_Stream_resumeNow(callback, __Scheduler_succeed(_Stream_insert(p)));
	});
});

// custom : (s -> a -> ( Int, s, ( List b, String ) )) -> s -> Int -> Int -> Task Never Int
var _Stream_custom = F4(function(action, initialState, readCap, writeCap)
{
	return _Stream_op(function(callback)
	{
		var p = _Stream_newPair(_Stream_K_CUSTOM);
		p.__customFn = action;
		p.__customState = initialState;
		p.__readCap = readCap < 0 ? 0 : readCap;
		p.__writeCap = writeCap < 1 ? 1 : writeCap;
		_Stream_resumeNow(callback, __Scheduler_succeed(_Stream_insert(p)));
	});
});

// textEncoder, textDecoder : Task Never Int
var _Stream_textEncoder = _Stream_op(function(callback)
{
	_Stream_resumeNow(callback, __Scheduler_succeed(_Stream_insertCodec(_Stream_textEncoderCodec())));
});

var _Stream_textDecoder = _Stream_op(function(callback)
{
	_Stream_resumeNow(callback, __Scheduler_succeed(_Stream_insertCodec(_Stream_textDecoderCodec())));
});

// compressor, decompressor : Int -> Task Never Int (0 gzip, 1 deflate, 2 deflate-raw)
var _Stream_compressor = function(algorithm)
{
	return _Stream_op(function(callback)
	{
		_Stream_resumeNow(callback, __Scheduler_succeed(_Stream_insertCodec(_Stream_zlibCodec(true, algorithm))));
	});
};

var _Stream_decompressor = function(algorithm)
{
	return _Stream_op(function(callback)
	{
		_Stream_resumeNow(callback, __Scheduler_succeed(_Stream_insertCodec(_Stream_zlibCodec(false, algorithm))));
	});
};

// read : Int -> Task SErr a
var _Stream_read = function(id)
{
	return _Stream_op(function(callback)
	{
		var p = _Stream_table[id];
		if (!p) return _Stream_resumeNow(callback, _Stream_err(_Stream_E_CLOSED, ''));
		if (_Stream_readLocked(p)) return _Stream_resumeNow(callback, _Stream_err(_Stream_E_LOCKED, ''));
		if (p.__kind === _Stream_K_MAPPED && !p.__readQ.length && p.__rawQ.length)
		{
			_Stream_mapHead(id);   // the chunk read ahead
		}
		if (p.__readQ.length)
		{
			var v = p.__readQ.shift();
			_Stream_pump(id);   // may complete writers
			return _Stream_resumeNow(callback, __Scheduler_succeed(v));
		}
		if (p.__r === _Stream_R_CLOSED) return _Stream_resumeNow(callback, _Stream_err(_Stream_E_CLOSED, ''));
		if (p.__r === _Stream_R_ERRORED) return _Stream_resumeNow(callback, _Stream_err(_Stream_E_CANCELLED, p.__rReason));
		// Park (T9).
		var tok = _Stream_token(callback);
		p.__readLock = true;
		p.__parkedRead = tok;
		if (p.__kind === _Stream_K_SOURCE)
		{
			_Stream_channelRead(id, p.__channel, tok, _Stream_kChannelReadChunk);
		}
		_Stream_pump(id);   // mapped source: read-ahead and demand
	});
};

function _Stream_writeOrEnqueue(value, id, callback, isEnqueue)
{
	var p = _Stream_table[id];
	if (!p) return _Stream_resumeNow(callback, _Stream_err(_Stream_E_CANCELLED, _Stream_kWritableClosed));
	if (_Stream_writeLocked(p)) return _Stream_resumeNow(callback, _Stream_err(_Stream_E_LOCKED, ''));
	if (p.__w === _Stream_W_CLOSING || p.__w === _Stream_W_CLOSED)
	{
		return _Stream_resumeNow(callback, _Stream_err(_Stream_E_CANCELLED, _Stream_kWritableClosed));
	}
	if (p.__w === _Stream_W_ERRORED)
	{
		return _Stream_resumeNow(callback, _Stream_err(_Stream_E_CANCELLED, p.__wReason));
	}
	var tok;
	if (p.__kind === _Stream_K_SINK && p.__mapFn)
	{
		tok = isEnqueue ? { __resume: null } : _Stream_token(callback);
		p.__writeQ.push({ __tok: tok, __value: null, __completeOnTransform: true });
		_Stream_mappedWrite(id, p, tok, value);
		if (isEnqueue) _Stream_resumeNow(callback, __Scheduler_succeed(__Utils_Tuple0));
		return;
	}
	if (p.__kind === _Stream_K_SINK)
	{
		tok = isEnqueue ? { __resume: null } : _Stream_token(callback);
		p.__writeQ.push({ __tok: tok, __value: null, __completeOnTransform: true });
		_Stream_channelWrite(id, p.__channel, tok, p.__textSink ? value : _Stream_toUint8Array(value));
		if (isEnqueue) _Stream_resumeNow(callback, __Scheduler_succeed(__Utils_Tuple0));
		return;
	}
	if (p.__kind === _Stream_K_SOURCE || p.__kind === _Stream_K_MAPPED)
	{
		// A source has no writable side (unreachable from Elm).
		return _Stream_resumeNow(callback, _Stream_err(_Stream_E_CANCELLED, _Stream_kWritableClosed));
	}
	// In-memory pair.
	if (p.__writeQ.length < p.__writeCap)
	{
		if (isEnqueue)
		{
			p.__writeQ.push({ __tok: null, __value: value, __completeOnTransform: false });
			_Stream_pump(id);
			return _Stream_resumeNow(callback, __Scheduler_succeed(__Utils_Tuple0));
		}
		p.__writeQ.push({ __tok: _Stream_token(callback), __value: value, __completeOnTransform: true });
		_Stream_pump(id);
		return;
	}
	// Full: wait for room, holding the write lock.
	p.__writeLock = true;
	p.__waitingForRoom.push({ __tok: _Stream_token(callback), __value: value, __completeOnTransform: !isEnqueue });
	_Stream_pump(id);
}

// write, enqueue : a -> Int -> Task SErr ()
var _Stream_write = F2(function(value, id)
{
	return _Stream_op(function(callback) { _Stream_writeOrEnqueue(value, id, callback, false); });
});

var _Stream_enqueue = F2(function(value, id)
{
	return _Stream_op(function(callback) { _Stream_writeOrEnqueue(value, id, callback, true); });
});

// closeWritable : Int -> Task SErr ()
var _Stream_closeWritable = function(id)
{
	return _Stream_op(function(callback)
	{
		var p = _Stream_table[id];
		if (!p) return _Stream_resumeNow(callback, _Stream_err(_Stream_E_CANCELLED, _Stream_kWritableClosed));
		if (_Stream_writeLocked(p)) return _Stream_resumeNow(callback, _Stream_err(_Stream_E_LOCKED, ''));
		if (p.__w === _Stream_W_CLOSING || p.__w === _Stream_W_CLOSED || p.__kind === _Stream_K_SOURCE ||
			p.__kind === _Stream_K_MAPPED)
		{
			return _Stream_resumeNow(callback, _Stream_err(_Stream_E_CANCELLED, _Stream_kWritableClosed));
		}
		if (p.__w === _Stream_W_ERRORED)
		{
			return _Stream_resumeNow(callback, _Stream_err(_Stream_E_CANCELLED, p.__wReason));
		}
		p.__w = _Stream_W_CLOSING;
		var tok;
		if (p.__kind === _Stream_K_SINK)
		{
			// Succeeds once the channel has written everything and released the resource.
			tok = _Stream_token(callback);
			p.__closeTok = tok;
			_Stream_channelClose(id, p.__channel, tok);
			return;
		}
		if (!p.__writeQ.length && !p.__waitingForRoom.length && p.__kind !== _Stream_K_CODEC)
		{
			p.__w = _Stream_W_CLOSED;
			if (p.__r === _Stream_R_OPEN) p.__r = _Stream_R_CLOSED;
			_Stream_pump(id);   // wakes a parked reader with Closed
			return _Stream_resumeNow(callback, __Scheduler_succeed(__Utils_Tuple0));
		}
		// Park until the queued writes are through (a codec also flushes).
		p.__closeTok = _Stream_token(callback);
		_Stream_pump(id);
	});
};

// cancelReadable : String -> Int -> Task SErr ()
var _Stream_cancelReadable = F2(function(reason, id)
{
	return _Stream_op(function(callback)
	{
		var p = _Stream_table[id];
		if (p)
		{
			if (_Stream_readLocked(p)) return _Stream_resumeNow(callback, _Stream_err(_Stream_E_LOCKED, ''));
			_Stream_cancelReadableNow(id, reason);
		}
		_Stream_resumeNow(callback, __Scheduler_succeed(__Utils_Tuple0));
	});
});

// cancelWritable : String -> Int -> Task SErr ()
var _Stream_cancelWritable = F2(function(reason, id)
{
	return _Stream_op(function(callback)
	{
		var p = _Stream_table[id];
		if (p)
		{
			if (_Stream_writeLocked(p)) return _Stream_resumeNow(callback, _Stream_err(_Stream_E_LOCKED, ''));
			_Stream_cancelWritableNow(id, reason);
		}
		_Stream_resumeNow(callback, __Scheduler_succeed(__Utils_Tuple0));
	});
});

// pipeThrough : Int -> Int -> Task SErr () — (transformation, readable)
var _Stream_pipeThrough = F2(function(dst, src)
{
	return _Stream_op(function(callback)
	{
		var s = _Stream_table[src];
		var d = _Stream_table[dst];
		if ((s && _Stream_readLocked(s)) || (d && _Stream_writeLocked(d)))
		{
			return _Stream_resumeNow(callback, _Stream_err(_Stream_E_LOCKED, ''));
		}
		_Stream_schedulePipe(_Stream_createPipe(src, dst, null));
		_Stream_resumeNow(callback, __Scheduler_succeed(__Utils_Tuple0));
	});
});

// pipeTo : Int -> Int -> Task SErr () — (writable, readable); completes when dst is closed
var _Stream_pipeTo = F2(function(dst, src)
{
	return _Stream_op(function(callback)
	{
		var s = _Stream_table[src];
		var d = _Stream_table[dst];
		if ((s && _Stream_readLocked(s)) || (d && _Stream_writeLocked(d)))
		{
			return _Stream_resumeNow(callback, _Stream_err(_Stream_E_LOCKED, ''));
		}
		_Stream_schedulePipe(_Stream_createPipe(src, dst, _Stream_token(callback)));
	});
});

// utf8ToString : Bytes -> Maybe String (strict, B5)
var _Stream_utf8Strict = null;

var _Stream_utf8ToString = function(bytes)
{
	if (!_Stream_utf8Strict)
	{
		_Stream_utf8Strict = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true });
	}
	try
	{
		return __Maybe_Just(_Stream_utf8Strict.decode(_Stream_toUint8Array(bytes)));
	}
	catch (e)
	{
		return __Maybe_Nothing;
	}
};

// stringToUtf8 : String -> Bytes
var _Stream_utf8Encoder = null;

var _Stream_stringToUtf8 = function(string)
{
	if (!_Stream_utf8Encoder)
	{
		_Stream_utf8Encoder = new TextEncoder();
	}
	return _Stream_toBytes(_Stream_utf8Encoder.encode(string));
};
