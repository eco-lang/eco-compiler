/*
import Elm.Kernel.Scheduler exposing (binding, succeed, fail, rawSpawn)
import Elm.Kernel.Utils exposing (Tuple0, Tuple2, Tuple3)
import Elm.Kernel.List exposing (fromArray)
import Eco.Kernel.Stream exposing (noteActivity, toBytes, toUint8Array)
*/

// HttpServer — JS twin of src/eco-system/HttpServer/ (eco/system), plans/eco-system-library.md
// Appendix B.6, C.5, E.5, Phase 7 and Phase 10 (decision D15).
//
// node:http does the parsing (as llhttp does natively: unknown methods and malformed
// requests get 400, oversized headers 431 with the same 64 KiB limit, `Expect:
// 100-continue` is answered by the server). The B.6 kernels keep the native shapes:
//
//   createServer host port   listens; fails with ( code, message ) such as
//                            ( "EADDRINUSE", "listen EADDRINUSE: address already in use
//                            127.0.0.1:8080" ). A listening server keeps the program alive
//                            (Node semantics, as the native pendingAsync held forever).
//   respond key status headers body
//                            writes the response with the native rules
//                            (HttpServerService.cpp serializeResponse): a status outside
//                            100..999 becomes 500; headers in list order, one line per
//                            value, names as given; empty names and names/values with
//                            CR/LF/NUL (or that node rejects) are dropped, and so are
//                            Content-Length, Connection and Transfer-Encoding; a Date
//                            header is added unless one was given; Content-Length is the
//                            body length except for 1xx/204/304 (no body); HEAD gets the
//                            headers only; always `Connection: close`, and the connection
//                            is closed after the response (no keep-alive). The task
//                            completes once the response is written (or the client is
//                            gone); an unknown or already answered key completes at once.
//
// Requests reach the Elm manager (Http.Server's onEffects / onSelfMsg, JS only) through the
// JS-only kernels at the end: while a server has subscribers the manager keeps one
// listener process per server (attachRequestListener); requests that arrive while there
// is none are held until one attaches (the native manager parks them the same way). The
// listener hands each request over as the C.5 tagger argument
// ( ( method, absoluteUrl ), ( headers, body ), responseKey ): headers are one
// ( name, [ value ] ) entry per occurrence in arrival order with the name as sent, and
// the URL is absolute (E.5): an absolute request target is kept, otherwise
// "http://" + the first Host header (or host:port of the server) + the target.

var _HttpServer_kMaxHeaderBytes = 64 * 1024;

var _HttpServer_servers = {};
var _HttpServer_nextServerId = 1;
var _HttpServer_pending = {};   // response key -> request entry, until respond
var _HttpServer_nextKey = 1;

// The authority for request URLs without a Host header (E.5); IPv6 literals bracketed.
function _HttpServer_authorityOf(host, port)
{
	var h = host || 'localhost';
	if (h.indexOf(':') >= 0 && h.charAt(0) !== '[')
	{
		h = '[' + h + ']';
	}
	return h + ':' + port;
}

function _HttpServer_absoluteUrl(target, rawHeaders, fallbackAuthority)
{
	if (target.lastIndexOf('http://', 0) === 0 || target.lastIndexOf('https://', 0) === 0)
	{
		return target;
	}
	var authority = fallbackAuthority;
	for (var i = 0; i + 1 < rawHeaders.length; i += 2)
	{
		if (rawHeaders[i].toLowerCase() === 'host')
		{
			if (rawHeaders[i + 1])
			{
				authority = rawHeaders[i + 1];   // the first Host header only
			}
			break;
		}
	}
	var path = target.charAt(0) === '/' ? target : '/' + (target === '*' ? '' : target);
	return 'http://' + authority + path;
}


// --- B.6 -------------------------------------------------------------------------------

// createServer : String -> Int -> Task ( String, String ) Int
var _HttpServer_createServer = F2(function(host, port)
{
	return __Scheduler_binding(function(callback)
	{
		__Stream_noteActivity();
		var http = require('http');
		var server;
		try
		{
			server = http.createServer({
				maxHeaderSize: _HttpServer_kMaxHeaderBytes,
				requestTimeout: 0,      // no request timeouts (§10 Phase 7)
				headersTimeout: 0,
				keepAliveTimeout: 0
			});
		}
		catch (e)
		{
			callback(__Scheduler_fail(__Utils_Tuple2(e.code || 'EUNKNOWN', e.message || String(e))));
			return;
		}
		var id = _HttpServer_nextServerId++;
		var s = {
			__id: id,
			__server: server,
			__authority: _HttpServer_authorityOf(host, port),
			__listener: null,   // function(entry), while the Elm manager listens
			__queue: []         // entries waiting for a listener, oldest first
		};
		var started = false;
		server.on('error', function(e)
		{
			if (!started)
			{
				started = true;
				callback(__Scheduler_fail(__Utils_Tuple2(e.code || 'EUNKNOWN', e.message || String(e))));
			}
		});
		server.on('request', function(req, res)
		{
			_HttpServer_onRequest(s, req, res);
		});
		// An Expect header other than 100-continue is ignored, as natively (node would
		// answer 417 without this listener).
		server.on('checkExpectation', function(req, res)
		{
			_HttpServer_onRequest(s, req, res);
		});
		try
		{
			server.listen(port, host || undefined, function()
			{
				if (started) return;
				started = true;
				_HttpServer_servers[id] = s;
				callback(__Scheduler_succeed(id));
			});
		}
		catch (e)
		{
			// e.g. ERR_SOCKET_BAD_PORT, thrown synchronously
			started = true;
			callback(__Scheduler_fail(__Utils_Tuple2(e.code || 'EUNKNOWN', e.message || String(e))));
		}
	});
});

function _HttpServer_onRequest(s, req, res)
{
	var chunks = [];
	var failed = false;
	req.on('data', function(c) { chunks.push(c); });
	req.on('error', function() { failed = true; });   // the client went away mid-body
	req.on('end', function()
	{
		if (failed) return;
		__Stream_noteActivity();
		var body = Buffer.concat(chunks);
		var raw = req.rawHeaders;
		var headers = [];
		for (var i = 0; i + 1 < raw.length; i += 2)
		{
			headers.push(__Utils_Tuple2(raw[i], __List_fromArray([raw[i + 1]])));
		}
		var key = _HttpServer_nextKey++;
		var entry = {
			__key: key,
			__res: res,
			__isHead: req.method === 'HEAD',
			__arg: __Utils_Tuple3(
				__Utils_Tuple2(req.method, _HttpServer_absoluteUrl(req.url, raw, s.__authority)),
				__Utils_Tuple2(__List_fromArray(headers), __Stream_toBytes(new Uint8Array(body.buffer, body.byteOffset, body.byteLength))),
				key
			)
		};
		_HttpServer_pending[key] = entry;
		_HttpServer_deliver(s, entry);
	});
}

function _HttpServer_deliver(s, entry)
{
	if (s.__listener)
	{
		s.__listener(entry);
	}
	else
	{
		s.__queue.push(entry);
		s.__queue.sort(function(x, y) { return x.__key - y.__key; });
	}
}

// respond : Int -> Int -> List ( String, List String ) -> Bytes -> Task Never ()
var _HttpServer_respond = F4(function(key, status, headers, body)
{
	return __Scheduler_binding(function(callback)
	{
		var done = false;
		var complete = function()
		{
			if (done) return;
			done = true;
			callback(__Scheduler_succeed(__Utils_Tuple0));
		};
		var entry = _HttpServer_pending[key];
		if (!entry)
		{
			complete();   // unknown or already answered
			return;
		}
		delete _HttpServer_pending[key];
		__Stream_noteActivity();
		var http = require('http');
		var res = entry.__res;
		var st = (status < 100 || status > 999) ? 500 : status;
		var noBody = (st >= 100 && st < 200) || st === 204 || st === 304;
		var bytes = __Stream_toUint8Array(body);
		var raw = [];
		var bad = /[\r\n\0]/;
		for (var hs = headers; hs.b; hs = hs.b)
		{
			var name = hs.a.a;
			var lower = name.toLowerCase();
			if (!name || bad.test(name)
				|| lower === 'content-length' || lower === 'connection' || lower === 'transfer-encoding')
			{
				continue;
			}
			for (var vs = hs.a.b; vs.b; vs = vs.b)
			{
				var value = vs.a;
				if (bad.test(value)) continue;
				try
				{
					http.validateHeaderName(name);
					http.validateHeaderValue(name, value);
				}
				catch (e)
				{
					continue;
				}
				raw.push(name, value);
			}
		}
		if (!noBody)
		{
			raw.push('Content-Length', String(bytes.byteLength));
		}
		raw.push('Connection', 'close');
		if (res.destroyed || res.writableEnded || (res.socket && res.socket.destroyed))
		{
			complete();   // the client is gone: not an error of the task
			return;
		}
		res.once('close', complete);
		res.once('error', complete);
		try
		{
			// node adds Date unless a Date header is among `raw`.
			res.writeHead(st, http.STATUS_CODES[st] || 'unknown', raw);
			if (noBody || entry.__isHead)
			{
				res.end(complete);
			}
			else
			{
				res.end(Buffer.from(bytes.buffer, bytes.byteOffset, bytes.byteLength), complete);
			}
		}
		catch (e)
		{
			if (!res.headersSent)
			{
				try { res.writeHead(500, 'Internal Server Error', ['Content-Length', '0', 'Connection', 'close']); } catch (e2) { /* gone */ }
			}
			try { res.end(); } catch (e3) { /* gone */ }
			complete();
		}
	});
});


// --- JS-only: the request listener of the Elm Http.Server manager ------------------------

// attachRequestListener : Int -> (( ( String, String ), ( List ( String, List String ), Bytes ), Int ) -> Task Never ()) -> Task Never ()
// A binding that never completes: while it runs, every request of server `serverId`
// (first those held so far) spawns `toTask arg`. Killing its process detaches it; later
// requests are held again.
var _HttpServer_attachRequestListener = F2(function(serverId, toTask)
{
	return __Scheduler_binding(function(callback)
	{
		var s = _HttpServer_servers[serverId];
		if (!s)
		{
			return;   // no such server: nothing will ever arrive
		}
		var listener = function(entry)
		{
			__Scheduler_rawSpawn(toTask(entry.__arg));
		};
		s.__listener = listener;
		var held = s.__queue;
		s.__queue = [];
		for (var i = 0; i < held.length; i++)
		{
			listener(held[i]);
		}
		return function()
		{
			if (s.__listener === listener)
			{
				s.__listener = null;
			}
		};
	});
});

// holdRequest : Int -> Int -> Task Never ()
// ( serverId, responseKey ): a request the manager received after its last subscriber
// went away is held again until a listener attaches.
var _HttpServer_holdRequest = F2(function(serverId, key)
{
	return __Scheduler_binding(function(callback)
	{
		var s = _HttpServer_servers[serverId];
		var entry = _HttpServer_pending[key];
		if (s && entry)
		{
			_HttpServer_deliver(s, entry);
		}
		callback(__Scheduler_succeed(__Utils_Tuple0));
	});
});
