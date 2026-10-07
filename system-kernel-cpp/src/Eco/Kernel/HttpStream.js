/*
import Elm.Kernel.Scheduler exposing (binding, succeed)
import Elm.Kernel.Utils exposing (Tuple2, Tuple3)
import Elm.Kernel.List exposing (fromArray)
import Eco.Kernel.Stream exposing (createChannelSource, createChannelSink, pipeStreams, find, readLocked, noteActivity, toUint8Array, cancelledError)
*/

// HttpStream — JS twin of src/eco-system/HttpStream/ (eco/system), plans/eco-system-library.md
// Appendix B.7, E.6, Phase 8 and Phase 10 (decision D15). node:http / node:https stand in
// for the curl transfer thread (HttpTransfer.cpp); the rules are the native ones:
//
//   * Only http: and https: URLs (also for redirects); anything else, or a URL that does
//     not parse, is BadUrl_ with the URL as given.
//   * Redirects (3xx other than 304, with a Location) are followed, at most 20; only the
//     final hop's status, headers and URL are reported. A 303 turns any method but HEAD
//     into a bodiless GET, and so does a 301/302 after a POST (curl's rules); other
//     redirects keep the method and resend a bytes body, while a stream body cannot be
//     resent and fails with NetworkError_ (curl's "rewind" failure).
//   * Request headers: Content-Type of the body first (body kinds 1 and 2), then the
//     Http.Header values in order, one line each (B1a). Headers whose name is empty or
//     contains CR, LF or ':' and values with CR or LF are dropped, as are those node
//     rejects. A stream body is sent with `Transfer-Encoding: chunked` and no
//     Content-Length (E.6); a bytes body with its Content-Length.
//   * Response header names are lower-cased, in arrival order (Elm joins duplicates).
//   * The timeout (ms, 0 = none) covers only the wait for the final response's headers.
//   * discardNon2xx (expectStream) on a non-2xx status: the transfer is aborted at the
//     headers and the body stream reads Closed at once.
//   * The task resolves when the headers arrive, with a channel-source body stream. A
//     network error after that reaches the stream as Cancelled "network error: <msg>".
//     After the headers only a pending read of the body keeps the program alive (the
//     §3.4 keep-alive rule): the socket is unref'd while nobody waits on it.
//   * The kill handle (Process.kill before the headers) aborts the transfer.
//   * A stream body is piped (Stream's pipeStreams) into a channel sink over the request;
//     a read-locked body stream resolves with NetworkError_ at once; cancelling the body
//     stream aborts the transfer (NetworkError_ before the headers). Upload writes and
//     closes that can no longer complete fail with the native reasons: "the HTTP request
//     was aborted", "network error: <msg>", or "the HTTP response ended before the
//     request body was sent".
//
// Result (B.7): ( kind, badUrl, ( ( status, statusText, finalUrl ), headers, bodyId ) )
// with kind 0 BadUrl_ / 1 Timeout_ / 2 NetworkError_ / 3 BadStatus_ / 4 GoodStatus_.

var _HttpStream_kChunk = 64 * 1024;
var _HttpStream_kCap = 4 * _HttpStream_kChunk;   // download buffer before pausing
var _HttpStream_kMaxRedirs = 20;

var _HttpStream_K_BADURL = 0, _HttpStream_K_TIMEOUT = 1, _HttpStream_K_NETWORK = 2,
    _HttpStream_K_BADSTATUS = 3, _HttpStream_K_GOODSTATUS = 4;

var _HttpStream_kAborted = 'the HTTP request was aborted';
var _HttpStream_kEndedFirst = 'the HTTP response ended before the request body was sent';

function _HttpStream_result(kind, badUrl, status, statusText, url, headers, bodyId)
{
	return __Utils_Tuple3(kind, badUrl, __Utils_Tuple3(
		__Utils_Tuple3(status, statusText, url),
		__List_fromArray(headers),
		bodyId
	));
}

function _HttpStream_reasonError(reason)
{
	var e = new Error(reason);
	e.code = 'ECANCELED';
	e.reason = reason;
	return e;
}


// --- send (B.7) --------------------------------------------------------------------------

// send : ( String, String, Int ) -> List Http.Header -> ( Int, String, ( Bytes, Int ) ) -> Bool
//     -> Task Never ( Int, String, ( ( Int, String, String ), List ( String, String ), Int ) )
var _HttpStream_send = F4(function(request, headers, body, discard)
{
	return __Scheduler_binding(function(callback)
	{
		__Stream_noteActivity();
		var spec = {
			__url: request.b,
			__timeoutMs: request.c > 0 ? request.c : 0,
			__headers: [],
			__contentType: body.b,
			__bytes: null,
			__streamId: body.a === 2 ? body.c.b : -1,
			__discard: !!discard
		};
		for (var hs = headers; hs.b; hs = hs.b)
		{
			spec.__headers.push([hs.a.a, hs.a.b]);   // Http.Header name value (B1a)
		}
		if (body.a === 1)
		{
			var u8 = __Stream_toUint8Array(body.c.a);
			spec.__bytes = Buffer.from(u8.buffer, u8.byteOffset, u8.byteLength);
		}
		var t = {
			__spec: spec,
			__callback: callback,
			__resolved: false,
			__aborted: false,
			__timedOut: false,
			__finished: false,     // the response ended, or the transfer failed
			__errReason: '',       // "network error: ..." once failed
			__method: request.a,
			__bodyKind: body.a,
			__url: null,           // URL of the current hop
			__urlString: spec.__url,
			__redirects: 0,
			__req: null,
			__res: null,
			__timer: null,
			__up: null,            // upload channel state (stream bodies)
			__down: null           // download channel state
		};

		var url = _HttpStream_parseUrl(spec.__url);
		if (!url)
		{
			_HttpStream_resolveError(t, _HttpStream_K_BADURL);
			return;
		}
		t.__url = url;
		if (t.__bodyKind === 2)
		{
			var src = __Stream_find(spec.__streamId);
			if (src && __Stream_readLocked(src))
			{
				// The Readable is in use elsewhere: it cannot be consumed.
				_HttpStream_resolveError(t, _HttpStream_K_NETWORK);
				return;
			}
		}
		if (spec.__timeoutMs > 0)
		{
			t.__timer = setTimeout(function()
			{
				t.__timer = null;
				if (t.__resolved) return;
				t.__timedOut = true;
				_HttpStream_resolveError(t, _HttpStream_K_TIMEOUT);
				_HttpStream_abort(t);
			}, spec.__timeoutMs);
		}
		_HttpStream_startHop(t);
		if (t.__bodyKind === 2 && !t.__aborted)
		{
			var sink = __Stream_createChannelSink(_HttpStream_uploadChannel(t));
			__Stream_pipeStreams(spec.__streamId, sink);   // checked above
		}
		return function()
		{
			// Process.kill before the headers: nobody resumes; stop the transfer.
			t.__resolved = true;
			_HttpStream_abort(t);
		};
	});
});

function _HttpStream_parseUrl(s, base)
{
	var u;
	try
	{
		u = base ? new URL(s, base) : new URL(s);
	}
	catch (e)
	{
		return null;
	}
	return (u.protocol === 'http:' || u.protocol === 'https:') ? u : null;
}

function _HttpStream_clearTimer(t)
{
	if (t.__timer)
	{
		clearTimeout(t.__timer);
		t.__timer = null;
	}
}

function _HttpStream_resolve(t, value)
{
	if (t.__resolved) return;
	t.__resolved = true;
	_HttpStream_clearTimer(t);
	t.__callback(__Scheduler_succeed(value));
}

function _HttpStream_resolveError(t, kind)
{
	_HttpStream_resolve(t, _HttpStream_result(
		kind, kind === _HttpStream_K_BADURL ? t.__spec.__url : '', 0, '', '', [], -1));
}

// Stops the transfer for good: kill, timeout, a cancelled body stream (either side), or a
// discarded body. A task still waiting gets NetworkError_ (deferred: this may run inside a
// stream operation).
function _HttpStream_abort(t)
{
	if (t.__aborted) return;
	t.__aborted = true;
	_HttpStream_clearTimer(t);
	if (t.__req) t.__req.destroy();
	if (t.__res) t.__res.destroy();
	if (!t.__resolved)
	{
		setImmediate(function() { _HttpStream_resolveError(t, _HttpStream_K_NETWORK); });
	}
	_HttpStream_serviceUpload(t);
	if (t.__down) t.__down.__fail('network error: ' + _HttpStream_kAborted);
}

// The transfer ended (response complete, or a network error).
function _HttpStream_finish(t, errReason)
{
	if (t.__finished) return;
	t.__finished = true;
	if (errReason && !t.__errReason) t.__errReason = errReason;
	_HttpStream_clearTimer(t);
	_HttpStream_serviceUpload(t);
}


// --- One request (hop) ---------------------------------------------------------------------

function _HttpStream_startHop(t)
{
	var spec = t.__spec;
	var u = t.__url;
	var https = u.protocol === 'https:';
	var options = { method: t.__method, agent: false };
	if (https && process.env.CURL_CA_BUNDLE)
	{
		// As natively (and elm/http's native kernel): CURL_CA_BUNDLE replaces the CA roots.
		try { options.ca = require('fs').readFileSync(process.env.CURL_CA_BUNDLE); } catch (e) { /* default roots */ }
	}
	var req;
	try
	{
		req = require(https ? 'https' : 'http').request(u, options);
	}
	catch (e)
	{
		// e.g. a method that is not an HTTP token
		t.__errReason = 'network error: ' + (e.message || String(e));
		_HttpStream_resolveError(t, _HttpStream_K_NETWORK);
		_HttpStream_abort(t);
		return;
	}
	t.__req = req;
	var add = function(name, value)
	{
		if (!name || /[\r\n:]/.test(name) || /[\r\n]/.test(value)) return;
		try
		{
			if (name.toLowerCase() === 'host')
			{
				req.setHeader(name, value);   // replaces node's own Host
			}
			else
			{
				req.appendHeader(name, value);
			}
		}
		catch (e)
		{
			// rejected by node: dropped
		}
	};
	if (t.__bodyKind !== 0 && spec.__contentType)
	{
		add('Content-Type', spec.__contentType);
	}
	for (var i = 0; i < spec.__headers.length; i++)
	{
		add(spec.__headers[i][0], spec.__headers[i][1]);
	}
	if (t.__bodyKind === 2)
	{
		req.removeHeader('content-length');
		req.setHeader('Transfer-Encoding', 'chunked');
	}
	else if (t.__bodyKind === 1 && !req.hasHeader('content-length'))
	{
		req.setHeader('Content-Length', String(spec.__bytes.length));
	}
	req.on('response', function(res) { _HttpStream_onResponse(t, req, res); });
	req.on('error', function(e) { _HttpStream_onRequestError(t, req, e); });
	if (t.__bodyKind === 1)
	{
		req.end(spec.__bytes);
	}
	else if (t.__bodyKind === 0)
	{
		req.end();
	}
	else
	{
		req.flushHeaders();   // the body follows through the upload channel
	}
}

function _HttpStream_onRequestError(t, req, e)
{
	if (req !== t.__req || t.__aborted) return;
	var reason = 'network error: ' + (e && e.message ? e.message : String(e));
	_HttpStream_resolveError(t, t.__timedOut ? _HttpStream_K_TIMEOUT : _HttpStream_K_NETWORK);
	_HttpStream_finish(t, reason);
	if (t.__down) t.__down.__fail(reason);
}

function _HttpStream_onResponse(t, req, res)
{
	if (req !== t.__req || t.__aborted)
	{
		res.destroy();
		return;
	}
	var status = res.statusCode;
	var location = res.headers.location;
	if (location && status >= 300 && status < 400 && status !== 304)
	{
		_HttpStream_redirect(t, req, res, location, status);
		return;
	}
	t.__res = res;
	var raw = res.rawHeaders;
	var headers = [];
	for (var i = 0; i + 1 < raw.length; i += 2)
	{
		headers.push(__Utils_Tuple2(raw[i].toLowerCase(), raw[i + 1]));
	}
	var ok = status >= 200 && status < 300;
	var bodyId;
	if (t.__spec.__discard && !ok)
	{
		// expectStream, non-2xx: the body is never delivered; stop the transfer now
		// instead of downloading it. The stream reads Closed.
		bodyId = __Stream_createChannelSource(_HttpStream_emptyChannel());
		_HttpStream_resolve(t, _HttpStream_result(
			_HttpStream_K_BADSTATUS, '', status, res.statusMessage || '', t.__urlString, headers, bodyId));
		_HttpStream_abort(t);
		return;
	}
	bodyId = __Stream_createChannelSource(_HttpStream_downloadChannel(t, res));
	_HttpStream_resolve(t, _HttpStream_result(
		ok ? _HttpStream_K_GOODSTATUS : _HttpStream_K_BADSTATUS, '',
		status, res.statusMessage || '', t.__urlString, headers, bodyId));
}

function _HttpStream_redirect(t, req, res, location, status)
{
	res.destroy();
	req.destroy();
	if (t.__redirects >= _HttpStream_kMaxRedirs)
	{
		t.__errReason = 'network error: Maximum (' + _HttpStream_kMaxRedirs + ') redirects followed';
		_HttpStream_resolveError(t, _HttpStream_K_NETWORK);
		_HttpStream_abort(t);
		return;
	}
	var next = _HttpStream_parseUrl(location, t.__url);
	if (!next)
	{
		// curl: unsupported protocol or malformed URL, reported as BadUrl_
		_HttpStream_resolveError(t, _HttpStream_K_BADURL);
		_HttpStream_abort(t);
		return;
	}
	var m = t.__method;
	var dropBody = (status === 303 && m !== 'HEAD') || ((status === 301 || status === 302) && m === 'POST');
	if (dropBody)
	{
		t.__method = 'GET';
		if (t.__bodyKind === 2 && t.__up)
		{
			t.__up.__detached = true;   // the body is no longer wanted
		}
		t.__bodyKind = 0;
	}
	else if (t.__bodyKind === 2)
	{
		// A stream body cannot be sent again (curl: "necessary data rewind wasn't possible").
		t.__errReason = 'network error: the request body stream cannot be resent after a redirect';
		_HttpStream_resolveError(t, _HttpStream_K_NETWORK);
		_HttpStream_abort(t);
		return;
	}
	t.__redirects++;
	t.__url = next;
	t.__urlString = next.href;
	_HttpStream_startHop(t);
	_HttpStream_serviceUpload(t);
}


// --- The body channels ---------------------------------------------------------------------

// A source that is already at its end (a discarded body).
function _HttpStream_emptyChannel()
{
	var closed = false;
	return {
		requestRead: function(maxBytes, done) { done(closed ? __Stream_cancelledError() : null, null); },
		requestWrite: function(bytes, done) { done(new Error('not a writable channel')); },
		close: function(done) { closed = true; if (done) done(null); },
		shutdown: function() { closed = true; }
	};
}

// The response body. Data is buffered up to kCap (then the response is paused, like the
// blocking curl write callback); reads take up to maxBytes of it. The socket keeps the
// program alive only while a read is pending.
function _HttpStream_downloadChannel(t, res)
{
	var chunks = [];
	var bytes = 0;
	var ended = false;
	var failed = null;    // reason
	var pending = null;   // { __max, __done }
	var shut = false;

	function keepAlive(on)
	{
		var s = res.socket;
		if (s && !s.destroyed)
		{
			if (on) s.ref(); else s.unref();
		}
	}

	function deliver()
	{
		if (!pending) return;
		var p = pending;
		if (bytes > 0)
		{
			var want = Math.max(1, p.__max);
			var parts = [];
			var got = 0;
			while (chunks.length && got < want)
			{
				var c = chunks[0];
				var take = Math.min(c.length, want - got);
				if (take === c.length)
				{
					chunks.shift();
				}
				else
				{
					chunks[0] = c.subarray(take);
				}
				parts.push(c.subarray(0, take));
				got += take;
			}
			bytes -= got;
			if (bytes < _HttpStream_kCap && !ended && !failed && res.isPaused())
			{
				res.resume();
			}
			pending = null;
			keepAlive(false);
			var out = parts.length === 1 ? parts[0] : Buffer.concat(parts, got);
			p.__done(null, new Uint8Array(out.buffer, out.byteOffset, out.byteLength));
		}
		else if (failed)
		{
			pending = null;
			keepAlive(false);
			p.__done(_HttpStream_reasonError(failed), null);
		}
		else if (ended)
		{
			pending = null;
			keepAlive(false);
			p.__done(null, null);
		}
	}

	function fail(reason)
	{
		if (ended || failed || shut) return;
		failed = reason;
		deliver();
	}

	t.__down = { __fail: fail };
	res.on('data', function(c)
	{
		if (shut) return;
		chunks.push(c);
		bytes += c.length;
		if (bytes >= _HttpStream_kCap) res.pause();
		deliver();
	});
	res.on('end', function()
	{
		if (failed || shut) return;
		ended = true;
		_HttpStream_finish(t, '');
		deliver();
	});
	res.on('error', function(e)
	{
		var reason = 'network error: ' + (e && e.message ? e.message : String(e));
		_HttpStream_finish(t, reason);
		fail(reason);
	});
	res.on('close', function()
	{
		if (!ended && !failed && !shut)
		{
			var reason = 'network error: the connection closed before the response was complete';
			_HttpStream_finish(t, reason);
			fail(reason);
		}
	});
	keepAlive(false);   // until somebody reads

	return {
		requestRead: function(maxBytes, done)
		{
			if (shut)
			{
				done(__Stream_cancelledError(), null);
				return;
			}
			pending = { __max: maxBytes > 0 ? maxBytes : _HttpStream_kChunk, __done: done };
			keepAlive(true);
			deliver();
		},
		requestWrite: function(bytes, done)
		{
			done(new Error('not a writable channel'));
		},
		close: function(done)
		{
			// The reader is done (end or error seen).
			if (!shut)
			{
				shut = true;
				chunks = [];
				bytes = 0;
				if (pending)
				{
					var p = pending;
					pending = null;
					p.__done(__Stream_cancelledError(), null);
				}
				if (!ended && !t.__finished) _HttpStream_abort(t);
			}
			if (done) done(null);
		},
		shutdown: function()
		{
			// The body stream was cancelled: stop the transfer.
			if (shut) return;
			shut = true;
			chunks = [];
			bytes = 0;
			if (pending)
			{
				var p = pending;
				pending = null;
				p.__done(__Stream_cancelledError(), null);
			}
			if (!t.__finished) _HttpStream_abort(t);
		}
	};
}

// Why the upload can take no more, or null while it can.
function _HttpStream_uploadFailure(t)
{
	var up = t.__up;
	if (t.__aborted || (up && up.__shut)) return _HttpStream_kAborted;   // kill / cancel
	if (t.__errReason) return t.__errReason;                              // network error
	if (t.__finished || (up && up.__detached)) return _HttpStream_kEndedFirst;
	return null;
}

// Fails the upload requests that can no longer complete.
function _HttpStream_serviceUpload(t)
{
	var up = t.__up;
	if (!up) return;
	var reason = _HttpStream_uploadFailure(t);
	if (!reason) return;
	var writes = up.__writes;
	up.__writes = [];
	for (var i = 0; i < writes.length; i++)
	{
		writes[i](_HttpStream_reasonError(reason));
	}
	if (up.__close)
	{
		var c = up.__close;
		up.__close = null;
		c(_HttpStream_reasonError(reason));
	}
}

// The request body of a stream upload (written by the pipe from the body stream).
function _HttpStream_uploadChannel(t)
{
	var up = { __writes: [], __close: null, __closeRequested: false, __shut: false, __detached: false };
	t.__up = up;

	// A one-shot completion that is also failed by serviceUpload.
	function track(list, done)
	{
		var settled = false;
		var f = function(err)
		{
			if (settled) return;
			settled = true;
			var i = up.__writes.indexOf(f);
			if (i >= 0) up.__writes.splice(i, 1);
			if (up.__close === f) up.__close = null;
			done(err);
		};
		if (list) list.push(f);
		return f;
	}

	return {
		requestRead: function(maxBytes, done)
		{
			done(new Error('not a readable channel'), null);
		},
		requestWrite: function(bytes, done)
		{
			if (up.__closeRequested)
			{
				done(__Stream_cancelledError());
				return;
			}
			var reason = _HttpStream_uploadFailure(t);
			if (reason)
			{
				done(_HttpStream_reasonError(reason));
				return;
			}
			if (!bytes.byteLength)
			{
				done(null);
				return;
			}
			var f = track(up.__writes, done);
			t.__req.write(Buffer.from(bytes.buffer, bytes.byteOffset, bytes.byteLength), function(err)
			{
				f(err ? _HttpStream_reasonError(_HttpStream_uploadFailure(t) || 'network error: ' + err.message) : null);
			});
		},
		close: function(done)
		{
			done = done || function() {};
			if (up.__closeRequested)
			{
				done(__Stream_cancelledError());
				return;
			}
			up.__closeRequested = true;
			var reason = _HttpStream_uploadFailure(t);
			if (reason)
			{
				done(_HttpStream_reasonError(reason));
				return;
			}
			var f = track(null, done);
			up.__close = f;
			t.__req.end(function() { f(null); });   // the end of the chunked body
		},
		shutdown: function()
		{
			if (up.__shut) return;
			up.__shut = true;
			if (!t.__finished)
			{
				_HttpStream_abort(t);   // a cancelled body stream ends the transfer
			}
			else
			{
				_HttpStream_serviceUpload(t);
			}
		}
	};
}
