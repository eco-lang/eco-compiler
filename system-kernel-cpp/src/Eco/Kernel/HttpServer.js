/*
import Elm.Kernel.Scheduler exposing (binding, succeed, fail, rawSpawn)
import Elm.Kernel.Utils exposing (Tuple0, Tuple2, Tuple3)
import Elm.Kernel.List exposing (fromArray)
import Maybe exposing (Nothing)
import Eco.Kernel.Stream exposing (noteActivity, toBytes, toUint8Array)
import Eco.Kernel.Tls exposing (code, errorMessage)
import Eco.Kernel.WebSocket exposing (parkUpgrade, parkH2Upgrade)
*/

// HttpServer — JS twin of src/eco-system/HttpServer/ (eco/system), plans/eco-system-library.md
// Appendix B.6, C.5, E.5 and plans/eco-system-websockets.md §3.4, Appendix B.2, E.2 (phase
// WS2). node:http does the parsing (llhttp, strict: insecureHTTPParser is never set), with
// the native rules on top:
//
//   createServer host port   listens on host:port with the default limits (§7); fails with
//                            ( code, message ) such as ( "EADDRINUSE", "listen EADDRINUSE:
//                            address already in use 127.0.0.1:8080" ). Result ( serverId,
//                            boundPort ). A listening server keeps the program alive (ref'd)
//                            until closeServer.
//   createServerWith         the same with ServerOptions (Appendix A.2): address text from
//                            Socket.Address, maxConnections (Node's server.maxConnections:
//                            connections over the limit are dropped, where native leaves them
//                            in the backlog), body/header limits, timeouts. http2 without
//                            tls: EINVAL. tls (WS3, §3.5): https.createServer with the
//                            certificate chain and key (checked first, failing with native's
//                            ERR_SSL_* codes as Socket.Tls.listen); the user's alpn is
//                            ignored: the server offers ['http/1.1'] (E.2), or with http2
//                            ['h2', 'http/1.1'] through http2.createSecureServer({ allowHTTP1:
//                            true }) (WS8, §3.8; TLS 1.2 restricted to ECDHE + AEAD suites).
//   * HTTP/2 (WS8): h2 requests arrive through Node's compatibility API ('request',
//     'checkContinue', 'checkExpectation' and, for (extended) CONNECT, 'connect' with
//     httpVersionMajor 2) and are handled per stream (_HttpServer_onH2Request: no per-socket
//     queue; header list 431, :authority vs Host 400, :protocol other than websocket 501,
//     content-length / body over maxBodySize 413, pseudo fields dropped, cookies joined) and
//     answered with stream.respond (_HttpServer_writeH2: toH2Nv's filtering; Node adds date).
//     Differences from native (Node's own HTTP/2 handling): streams over maxConcurrentStreams
//     are refused (native holds the input instead and counts unanswered reset streams), Node
//     resets a header list over twice maxHeaderSize itself (ENHANCE_YOUR_CALM), no per-stream
//     requestTimeout and no h2 idle timeout. closeServer: session.close() (GOAWAY) on every
//     session, session.destroy() at the deadline.
//   * alpnFallback = NoAck (§3.5): Node answers a client whose ALPN offer has nothing in
//     common with ALPNProtocols with a fatal no_application_protocol alert (and so does an
//     ALPNCallback returning undefined); native continues without ALPN. So the listener
//     reads each connection's ClientHello first (_HttpServer_alpnOffer), puts the bytes
//     back (unshift: TLSSocket feeds a raw socket's buffered data to the handshake) and
//     hands the socket to tls.Server's own connection listener with the server's
//     ALPNProtocols set for that one connection: the server's list when the client offers
//     one of them (or no ALPN), none otherwise (the offer is then ignored, as native's
//     SSL_TLSEXT_ERR_NOACK). tls.Server reads `ALPNProtocols` when the connection arrives
//     (internal/tls/wrap tlsConnectionListener, Node 22). A connection whose TLS handshake
//     has not finished is destroyed by closeServer (native: the listener aborts it).
//   * Timeouts: Node's keepAliveTimeout / headersTimeout / requestTimeout set to the options
//     (0 or less: none; headersTimeout clamped to requestTimeout, which Node requires), with
//     connectionsCheckingInterval a quarter of the shortest (at most Node's 30 s), so short
//     test values work; Node answers 408 + close as natively.
//   * One request in flight per connection (§3.4): Node parses pipelined requests eagerly,
//     so each socket has a queue of entries; only its head is handed to Elm, the next one
//     after the head is answered. `Expect: 100-continue` (checkContinue) is answered when
//     its entry reaches the head (never before an earlier response), not at all when the
//     Content-Length exceeds maxBodySize (413); other Expect values (checkExpectation): 417.
//   * Limits: maxHeaderSize is Node's (431); a Content-Length over maxBodySize, or a body
//     whose running total exceeds it: 413. Host: an HTTP/1.1 request needs exactly one Host
//     header, HTTP/1.0 at most one, with a valid `host[:port]` value, else 400 (Node's own
//     requireHostHeader is off so the rule is the same on both backends). Every such answer
//     carries Connection: close and closes the connection.
//   * The URL is absolute (E.5): an absolute-form target is kept, otherwise "http://"
//     ("https://" under TLS) + the Host value (or host:port of the server) + the target.
//   respond key status headers body
//                            writes the response with the native rules (serializeH1): a
//                            status outside 200..999 (including a final 1xx) becomes 500;
//                            headers in list order, one line per value, names as given;
//                            empty names and names/values with CR/LF/NUL (or that Node
//                            rejects) are dropped, and so are Content-Length, Connection and
//                            Transfer-Encoding; Date is added unless given; Content-Length
//                            except for 204/304; HEAD gets the headers only. "Connection:
//                            keep-alive" unless the request does not allow it (HTTP/1.0
//                            without keep-alive, Connection: close), the user's headers say
//                            Connection: close, the server is closing, or the request was an
//                            upgrade or CONNECT: then "Connection: close" and the connection
//                            closes after the response. The task completes once the response
//                            is written (or the client is gone); an unknown or answered key
//                            completes at once.
//   * Upgrade requests ('upgrade' listener: Upgrade + Connection: upgrade) are handed over as
//     requests with the lower-cased first Upgrade token; the socket and the bytes after the
//     request are kept for takeUpgrade. CONNECT ('connect' listener) is handed over without a
//     token. Their answers (a declined upgrade) are written as raw HTTP/1.1 with Connection:
//     close and the socket is closed.
//   takeUpgrade key          (Http.Server.upgradeRequest, WS5) the kept socket of an upgrade
//                            request leaves the server (no longer closed by closeServer, its
//                            HTTP timeouts off) and becomes a WebSocket handshake id
//                            (WebSocket.js parkUpgrade) with the bytes read past the request;
//                            the key is consumed, so a later respond on it does nothing. Node
//                            delivers the upgrade only after the earlier requests of the
//                            socket were answered (its queue), so the 101 follows them.
//                            EINVAL for an unknown, answered or non-upgrade key, ECANCELED
//                            when the socket is gone. An HTTP/2 extended CONNECT (WS9): its
//                            Http2Stream (paused since it arrived) becomes the handshake id
//                            (WebSocket.js parkH2Upgrade); it stays in its session.
//   closeServer id deadline  server.close() (the port is free when the task completes, on the
//                            next turn), idle connections closed (closeIdleConnections),
//                            held requests (no subscriber) answered 503, requests in flight
//                            answered with Connection: close; at the deadline every remaining
//                            connection is destroyed. Closing twice completes at once.
//
// Requests reach the Elm manager (Http.Server's onEffects / onSelfMsg, JS only) through the
// JS-only kernels at the end: while a server has subscribers the manager keeps one listener
// process per server (attachRequestListener); requests that arrive while there is none are
// held (bounded by maxBodySize × 4 bytes, beyond it 503) until one attaches. The listener
// hands each request over as the tagger argument of plans/eco-system-websockets.md C.1
// ( ( method, absoluteUrl ), ( headers, body ), ( responseKey, flags, upgradeToken ) ): flags
// bits 0-1 the HTTP version (0 = 1.0, 1 = 1.1), bit 2 TLS; the upgrade token is the
// lower-cased protocol an upgrade request asks for, or ""; headers are one
// ( name, [ value ] ) entry per occurrence in arrival order with the name as sent.

var _HttpServer_servers = {};
var _HttpServer_nextServerId = 1;
var _HttpServer_pending = {};   // response key -> entry delivered to Elm (or held), until answered
var _HttpServer_nextKey = 1;

// §7 defaults (plans/eco-system-websockets.md), as Http.Server.defaultServerOptions.
function _HttpServer_defaults()
{
	return {
		__maxConnections: -1,
		__maxBody: 16 * 1024 * 1024,
		__maxHeader: 64 * 1024,
		__keepAlive: 5000,
		__headersT: 60000,
		__requestT: 300000,
		__maxStreams: -1
	};
}

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

function _HttpServer_hostHeaders(rawHeaders)
{
	var hosts = [];
	for (var i = 0; i + 1 < rawHeaders.length; i += 2)
	{
		if (rawHeaders[i].toLowerCase() === 'host')
		{
			hosts.push(rawHeaders[i + 1].trim());
		}
	}
	return hosts;
}

// RFC 9110 §7.2 Host = uri-host [ ":" port ] (as Http1.cpp validHost).
function _HttpServer_validHost(h)
{
	if (!h) return false;
	var m = /^(\[[0-9A-Za-z:.%\-_~!$&'()*+,;=]+\]|(?:[A-Za-z0-9\-._~!$&'()*+,;=]|%[0-9A-Fa-f]{2})+)(?::([0-9]*))?$/.exec(h);
	if (!m) return false;
	if (m[1].charAt(0) === '[' && m[1].indexOf(':') < 0) return false;
	return m[2] === undefined || m[2].length <= 5;
}

function _HttpServer_absoluteUrl(s, target, host)
{
	if (target.lastIndexOf('http://', 0) === 0 || target.lastIndexOf('https://', 0) === 0)
	{
		return target;
	}
	var authority = host || s.__authority;
	var path = target.charAt(0) === '/' ? target : '/' + (target === '*' ? '' : target);
	return (s.__tls ? 'https://' : 'http://') + authority + path;
}

// True when a Connection header value lists `token` (case-insensitive).
function _HttpServer_hasToken(value, token)
{
	if (!value) return false;
	var parts = String(value).split(',');
	for (var i = 0; i < parts.length; i++)
	{
		if (parts[i].trim().toLowerCase() === token) return true;
	}
	return false;
}

// llhttp_should_keep_alive for a request.
function _HttpServer_requestKeepAlive(req)
{
	var c = req.headers.connection;
	if (req.httpVersionMajor === 1 && req.httpVersionMinor >= 1)
	{
		return !_HttpServer_hasToken(c, 'close');
	}
	return _HttpServer_hasToken(c, 'keep-alive');
}

// The response headers of `headers` (an Elm List ( String, List String )) as Node raw pairs,
// with native's filtering, and whether they ask to close the connection.
function _HttpServer_userHeaders(headers)
{
	var http = require('http');
	var raw = [];
	var askClose = false;
	var bad = /[\r\n\0]/;
	for (var hs = headers; hs.b; hs = hs.b)
	{
		var name = hs.a.a;
		var lower = name.toLowerCase();
		for (var vs = hs.a.b; vs.b; vs = vs.b)
		{
			var value = vs.a;
			if (lower === 'connection' && _HttpServer_hasToken(value, 'close'))
			{
				askClose = true;
			}
			if (!name || bad.test(name) || bad.test(value)
				|| lower === 'content-length' || lower === 'connection' || lower === 'transfer-encoding')
			{
				continue;
			}
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
	return { __raw: raw, __askClose: askClose };
}

function _HttpServer_finalStatus(status)
{
	return (status < 200 || status > 999) ? 500 : status;
}

// A response as raw HTTP/1.1 text (serializeH1), for sockets taken from the HTTP parser
// (upgrade, CONNECT) and the server's own answers on them.
function _HttpServer_serialize(st, raw, bytes, keepAlive)
{
	var http = require('http');
	var noBody = st === 204 || st === 304;
	var out = 'HTTP/1.1 ' + st + ' ' + (http.STATUS_CODES[st] || 'unknown') + '\r\n';
	var hasDate = false;
	for (var i = 0; i + 1 < raw.length; i += 2)
	{
		if (raw[i].toLowerCase() === 'date') hasDate = true;
		out += raw[i] + ': ' + raw[i + 1] + '\r\n';
	}
	if (!hasDate) out += 'Date: ' + new Date().toUTCString() + '\r\n';
	if (!noBody) out += 'Content-Length: ' + bytes.byteLength + '\r\n';
	out += 'Connection: ' + (keepAlive ? 'keep-alive' : 'close') + '\r\n\r\n';
	var head = Buffer.from(out, 'latin1');
	return noBody ? head : Buffer.concat([head, Buffer.from(bytes.buffer, bytes.byteOffset, bytes.byteLength)]);
}

// The server's own answer (400, 413, 417, 503) with Connection: close, then the connection
// closes. `entry` (optional) leaves its socket queue.
function _HttpServer_reject(res, status)
{
	try
	{
		if (!res.headersSent)
		{
			res.writeHead(status, { 'Content-Length': '0', 'Connection': 'close' });
		}
		res.end();
	}
	catch (e)
	{
		/* gone */
	}
}

// --- Connections: one request in flight -------------------------------------------------

function _HttpServer_socketQueue(socket)
{
	if (!socket.__httpQ)
	{
		socket.__httpQ = [];
	}
	return socket.__httpQ;
}

// Hands the head entry of the socket's queue to Elm once it is complete; answers its
// 100-continue when it becomes the head.
function _HttpServer_pump(socket)
{
	var q = _HttpServer_socketQueue(socket);
	while (q.length > 0)
	{
		var e = q[0];
		if (e.__dropped)
		{
			q.shift();
			continue;
		}
		if (e.__delivered)
		{
			return;   // in flight
		}
		if (e.__needsContinue && !e.__continued)
		{
			e.__continued = true;
			try { e.__res.writeContinue(); } catch (err) { /* gone */ }
		}
		if (!e.__ready)
		{
			return;
		}
		e.__delivered = true;
		_HttpServer_pending[e.__key] = e;
		_HttpServer_deliver(e.__server, e);
		return;
	}
}

// The head of its socket's queue was answered (or dropped): the next one may go.
function _HttpServer_done(e)
{
	e.__dropped = true;
	if (e.__socket)
	{
		_HttpServer_pump(e.__socket);
	}
}

function _HttpServer_makeArg(e, method, url, rawHeaders, body, flags, upgrade)
{
	var headers = [];
	for (var i = 0; i + 1 < rawHeaders.length; i += 2)
	{
		headers.push(__Utils_Tuple2(rawHeaders[i], __List_fromArray([rawHeaders[i + 1]])));
	}
	return __Utils_Tuple3(
		__Utils_Tuple2(method, url),
		__Utils_Tuple2(__List_fromArray(headers), __Stream_toBytes(new Uint8Array(body.buffer, body.byteOffset, body.byteLength))),
		__Utils_Tuple3(e.__key, flags, upgrade)
	);
}

// C.1 flags: bits 0-1 the version, bit 2 TLS.
function _HttpServer_flagsOf(s, req)
{
	return (req.httpVersionMinor === 0 ? 0 : 1) | (s.__tls ? 4 : 0);
}

// 'request' / 'checkContinue': checks, then the body, then the queue.
function _HttpServer_onRequest(s, req, res, expectContinue)
{
	__Stream_noteActivity();
	var cfg = s.__cfg;
	var hosts = _HttpServer_hostHeaders(req.rawHeaders);
	var http11 = req.httpVersionMajor === 1 && req.httpVersionMinor >= 1;
	if (hosts.length > 1 || (hosts.length === 0 && http11) || (hosts.length === 1 && !_HttpServer_validHost(hosts[0])))
	{
		_HttpServer_reject(res, 400);
		return;
	}
	var cl = req.headers['content-length'];
	if (cl !== undefined && Number(cl) > cfg.__maxBody)
	{
		_HttpServer_reject(res, 413);   // before any 100-continue
		return;
	}
	var e = {
		__key: _HttpServer_nextKey++,
		__server: s,
		__socket: req.socket,
		__res: res,
		__raw: null,
		__isHead: req.method === 'HEAD',
		__keepAlive: _HttpServer_requestKeepAlive(req),
		__mustClose: false,
		__needsContinue: expectContinue,
		__continued: false,
		__ready: false,
		__delivered: false,
		__dropped: false,
		__size: 0,
		__arg: null
	};
	var q = _HttpServer_socketQueue(req.socket);
	q.push(e);
	var chunks = [];
	var size = 0;
	var failed = false;
	req.on('data', function(c)
	{
		if (failed) return;
		size += c.length;
		if (size > cfg.__maxBody)
		{
			failed = true;
			chunks = [];
			_HttpServer_reject(res, 413);   // the running total of a chunked body
			_HttpServer_done(e);
			return;
		}
		chunks.push(c);
	});
	req.on('error', function()
	{
		failed = true;   // the client went away mid-body
		_HttpServer_done(e);
	});
	req.on('end', function()
	{
		if (failed) return;
		__Stream_noteActivity();
		var body = Buffer.concat(chunks);
		var host = hosts.length === 1 ? hosts[0] : '';
		e.__size = body.length + 256;
		e.__arg = _HttpServer_makeArg(e, req.method, _HttpServer_absoluteUrl(s, req.url, host),
			req.rawHeaders, body, _HttpServer_flagsOf(s, req), '');
		e.__ready = true;
		_HttpServer_pump(req.socket);
	});
	_HttpServer_pump(req.socket);
}

// 'upgrade' / 'connect': the socket leaves Node's HTTP parser. The request is handed over
// (behind earlier requests of the same socket); its answer is written raw.
function _HttpServer_onUpgrade(s, req, socket, head, isConnect)
{
	__Stream_noteActivity();
	var hosts = _HttpServer_hostHeaders(req.rawHeaders);
	var http11 = req.httpVersionMajor === 1 && req.httpVersionMinor >= 1;
	var bad = hosts.length > 1 || (hosts.length === 0 && http11) || (hosts.length === 1 && !_HttpServer_validHost(hosts[0]));
	if (bad)
	{
		socket.end(_HttpServer_serialize(400, [], new Uint8Array(0), false));
		return;
	}
	var token = '';
	if (!isConnect)
	{
		token = String(req.headers.upgrade || '').split(',')[0].trim().toLowerCase();
	}
	var e = {
		__key: _HttpServer_nextKey++,
		__server: s,
		__socket: socket,
		__res: null,
		__raw: socket,
		__head: head,
		__upgrade: token,
		__method: req.method,
		__target: req.url,
		__version: req.httpVersionMajor + '.' + req.httpVersionMinor,
		__rawHeaders: req.rawHeaders,
		__onError: function() { /* reported by the next write, if any */ },
		__isHead: req.method === 'HEAD',
		__keepAlive: false,
		__mustClose: true,
		__needsContinue: false,
		__continued: false,
		__ready: true,
		__delivered: false,
		__dropped: false,
		__size: 256,
		__arg: null
	};
	e.__arg = _HttpServer_makeArg(e, req.method,
		_HttpServer_absoluteUrl(s, req.url, hosts.length === 1 ? hosts[0] : ''),
		req.rawHeaders, Buffer.alloc(0), _HttpServer_flagsOf(s, req), token);
	socket.on('error', e.__onError);
	_HttpServer_socketQueue(socket).push(e);
	_HttpServer_pump(socket);
}

// To the manager's listener, else held (bounded; beyond the budget answered 503).
function _HttpServer_deliver(s, e)
{
	if (s.__listener)
	{
		s.__listener(e);
		return;
	}
	if (s.__closing)
	{
		_HttpServer_answerOwn(e, 503);
		return;
	}
	var budget = Math.max(0, s.__cfg.__maxBody) * 4;
	if (s.__queue.length > 0 && s.__heldBytes + e.__size > budget)
	{
		_HttpServer_answerOwn(e, 503);
		return;
	}
	s.__heldBytes += e.__size;
	s.__queue.push(e);
	s.__queue.sort(function(x, y) { return x.__key - y.__key; });
}

// The server answers a delivered entry itself (503) and forgets the key.
function _HttpServer_answerOwn(e, status)
{
	delete _HttpServer_pending[e.__key];
	_HttpServer_writeAnswer(e, status, [], new Uint8Array(0), true, function() {});
}

// Writes an answer for entry `e` (status already final-checked by the caller or not) and
// calls `complete` once written (or when the client is gone).
function _HttpServer_writeAnswer(e, status, raw, bytes, forceClose, complete)
{
	var done = false;
	var finish = function()
	{
		if (done) return;
		done = true;
		complete();
	};
	var st = _HttpServer_finalStatus(status);
	var s = e.__server;
	var keepAlive = !forceClose && !e.__mustClose && e.__keepAlive && !s.__closing;
	if (e.__h2)
	{
		_HttpServer_writeH2(e.__h2, st, raw, bytes, e.__isHead, e.__mustClose, finish);
		return;
	}
	if (e.__raw)
	{
		var socket = e.__raw;
		_HttpServer_done(e);
		if (socket.destroyed || !socket.writable)
		{
			finish();
			return;
		}
		var data = _HttpServer_serialize(st, raw, e.__isHead ? new Uint8Array(0) : bytes, false);
		socket.write(data, function() { finish(); });
		socket.end();
		var t = setTimeout(function() { socket.destroy(); }, 10000);   // bounded linger (as native)
		if (t.unref) t.unref();
		socket.once('close', function() { clearTimeout(t); finish(); });
		return;
	}
	var http = require('http');
	var res = e.__res;
	_HttpServer_done(e);
	if (res.destroyed || res.writableEnded || (res.socket && res.socket.destroyed))
	{
		finish();   // the client is gone: not an error of the task
		return;
	}
	var noBody = st === 204 || st === 304;
	var headers = raw.slice();
	if (!noBody)
	{
		headers.push('Content-Length', String(bytes.byteLength));
	}
	headers.push('Connection', keepAlive ? 'keep-alive' : 'close');
	res.once('close', finish);
	res.once('error', finish);
	try
	{
		// Node adds Date unless a Date header is among `headers`.
		res.writeHead(st, http.STATUS_CODES[st] || 'unknown', headers);
		if (noBody || e.__isHead)
		{
			res.end(finish);
		}
		else
		{
			res.end(Buffer.from(bytes.buffer, bytes.byteOffset, bytes.byteLength), finish);
		}
	}
	catch (err)
	{
		_HttpServer_reject(res, 500);
		finish();
	}
}


// --- TLS (WS3, §3.5) ---------------------------------------------------------------------

// The ALPN protocols an https server offers: its own, never the user's (§3.5):
// ['h2', 'http/1.1'] with http2 (WS8), else ['http/1.1'].
function _HttpServer_alpnList(http2)
{
	return http2 ? ['h2', 'http/1.1'] : ['http/1.1'];
}

// RFC 9113 §9.2.2 for http2: TLS 1.2 suites with ECDHE and AEAD only (the TLS 1.3 suites are
// listed too: without them Node would disable TLS 1.3). Native: the same TLS 1.2 list.
var _HttpServer_h2Ciphers = [
	'TLS_AES_256_GCM_SHA384', 'TLS_CHACHA20_POLY1305_SHA256', 'TLS_AES_128_GCM_SHA256',
	'ECDHE-ECDSA-AES128-GCM-SHA256', 'ECDHE-RSA-AES128-GCM-SHA256',
	'ECDHE-ECDSA-AES256-GCM-SHA384', 'ECDHE-RSA-AES256-GCM-SHA384',
	'ECDHE-ECDSA-CHACHA20-POLY1305', 'ECDHE-RSA-CHACHA20-POLY1305'
].join(':');

// The certificate chain and key checked before listening, in native's order and with its
// labels (as Tls.js's listen): null, or the failure ( code, message ).
function _HttpServer_tlsError(chain, key)
{
	var crypto = require('crypto');
	var failure = function(what, e)
	{
		return __Utils_Tuple2(__Tls_code(e, null), what + ': ' + __Tls_errorMessage(e));
	};
	try
	{
		new crypto.X509Certificate(chain);   // the first (leaf) certificate must parse
	}
	catch (e)
	{
		return failure('certificateChain', e);
	}
	try
	{
		crypto.createPrivateKey(key);
	}
	catch (e)
	{
		return failure('privateKey', e);
	}
	try
	{
		require('tls').createSecureContext({ cert: chain, key: key });   // the pair matches
		return null;
	}
	catch (e)
	{
		return failure('privateKey', e);
	}
}

// The ALPN offer of a TLS ClientHello at the start of `buf`: undefined while incomplete,
// null when it has no ALPN extension or is not a ClientHello, else the offered names.
// The handshake message may span several records (RFC 8446 §5.1).
function _HttpServer_alpnOffer(buf)
{
	try
	{
		if (buf.length < 1) return undefined;
		if (buf[0] !== 22) return null;   // not a handshake record
		var hs = [];
		var have = 0;
		var need = -1;
		var p = 0;
		while (need < 0 || have < need)
		{
			if (buf.length < p + 5) return undefined;
			if (buf[p] !== 22) return null;
			var len = buf.readUInt16BE(p + 3);
			if (buf.length < p + 5 + len) return undefined;
			hs.push(buf.subarray(p + 5, p + 5 + len));
			have += len;
			p += 5 + len;
			if (need < 0 && have >= 4)
			{
				var head = Buffer.concat(hs);
				if (head[0] !== 1) return null;   // not a ClientHello
				need = 4 + head.readUIntBE(1, 3);
			}
		}
		var h = Buffer.concat(hs);
		var q = 4 + 2 + 32;                  // type, length, version, random
		q += 1 + h[q];                       // session id
		q += 2 + h.readUInt16BE(q);          // cipher suites
		q += 1 + h[q];                       // compression methods
		if (q + 2 > need) return null;       // no extensions
		var end = Math.min(need, q + 2 + h.readUInt16BE(q));
		q += 2;
		while (q + 4 <= end)
		{
			var type = h.readUInt16BE(q);
			var elen = h.readUInt16BE(q + 2);
			q += 4;
			if (type === 16)   // application_layer_protocol_negotiation
			{
				var names = [];
				var e = Math.min(q + elen, end);
				for (var i = q + 2; i < e; )
				{
					var n = h[i];
					names.push(h.toString('latin1', i + 1, Math.min(e, i + 1 + n)));
					i += 1 + n;
				}
				return names;
			}
			q += elen;
		}
		return null;
	}
	catch (err)
	{
		return null;   // malformed: the TLS handshake reports it
	}
}

// Replaces tls.Server's connection listener: reads the ClientHello (at most 64 KiB, within
// the handshake timeout), puts it back and hands the socket to the original listener with
// ALPNProtocols chosen for this connection (NoAck fallback, see the header).
function _HttpServer_alpnFallback(s, server, list)
{
	var originals = server.listeners('connection');
	server.removeAllListeners('connection');
	server.on('connection', function(raw)
	{
		s.__handshaking.add(raw);
		raw.once('close', function() { s.__handshaking.delete(raw); });
		raw.on('error', function() { /* reported to the handshake, if any */ });
		var chunks = [];
		var size = 0;
		var handed = false;
		var hand = function(offer)
		{
			if (handed) return;
			handed = true;
			raw.removeListener('data', onData);
			raw.setTimeout(0);
			raw.pause();
			if (size > 0)
			{
				raw.unshift(Buffer.concat(chunks));
			}
			var common = offer === null || offer === undefined || offer.some(function(p) { return list.indexOf(p) >= 0; });
			server.ALPNProtocols = common ? list : undefined;
			for (var i = 0; i < originals.length; i++)
			{
				originals[i].call(server, raw);
			}
			server.ALPNProtocols = list;
		};
		var onData = function(chunk)
		{
			chunks.push(chunk);
			size += chunk.length;
			var offer = _HttpServer_alpnOffer(chunks.length === 1 ? chunk : Buffer.concat(chunks));
			if (offer !== undefined || size >= 64 * 1024)
			{
				hand(offer === undefined ? null : offer);
			}
		};
		raw.setTimeout(120000, function() { raw.destroy(); });   // Node's handshake timeout
		raw.on('data', onData);
		raw.once('end', function() { hand(null); });
	});
}


// --- HTTP/2 (WS8, §3.8, E.2) -------------------------------------------------------------

// http2.createSecureServer({ allowHTTP1: true }): h2 for clients that choose it, HTTP/1.1 (the
// same rules as https, through Node's HTTP/1 connection listener, configured by the server's
// properties) for the others. SETTINGS: ENABLE_CONNECT_PROTOCOL 1, ENABLE_PUSH 0, a 64 KiB
// stream window, MAX_CONCURRENT_STREAMS only when maxConcurrentStreams is set (W19). Node
// enforces MAX_HEADER_LIST_SIZE itself (resetting the stream with ENHANCE_YOUR_CALM), so it is
// set to twice maxHeaderSize and the header list is checked here (431), as natively.
function _HttpServer_createH2Server(options, cfg)
{
	var settings = {
		enableConnectProtocol: true,
		enablePush: false,
		initialWindowSize: 65536,
		maxHeaderListSize: Math.min(0xffffffff, Math.max(1, cfg.__maxHeader) * 2)
	};
	if (cfg.__maxStreams >= 0)
	{
		settings.maxConcurrentStreams = cfg.__maxStreams;
	}
	var h2options = {
		allowHTTP1: true,
		cert: options.cert,
		key: options.key,
		ALPNProtocols: options.ALPNProtocols,
		ciphers: options.ciphers,
		settings: settings,
		maxHeaderListPairs: 1 << 20
	};
	var server = require('http2').createSecureServer(h2options);
	// The HTTP/1.1 side reads these from the server object (Node 22).
	server.maxHeaderSize = options.maxHeaderSize;
	server.requestTimeout = options.requestTimeout;
	server.headersTimeout = options.headersTimeout;
	server.keepAliveTimeout = options.keepAliveTimeout;
	server.connectionsCheckingInterval = options.connectionsCheckingInterval;
	server.requireHostHeader = false;
	server.joinDuplicateHeaders = false;
	return server;
}

// An HTTP/2 request (compatibility API: Http2ServerRequest / Http2ServerResponse). Checks as
// Http2.cpp: the header list size (name + value + 32 per field, pseudo fields included; 431),
// :authority against Host (400), :protocol of an extended CONNECT (websocket, else 501), the
// body size (413). Pseudo fields are dropped from the list, cookie crumbs joined with "; ".
// Delivered when the body is complete; an (extended) CONNECT at once.
function _HttpServer_onH2Request(s, req, res)
{
	__Stream_noteActivity();
	var http2 = require('http2');
	var cfg = s.__cfg;
	var stream = req.stream;
	var raw = req.rawHeaders;
	var size = 0;
	var fields = [];
	var cookieAt = -1;
	var pseudo = {};
	for (var i = 0; i + 1 < raw.length; i += 2)
	{
		var name = String(raw[i]);
		var value = String(raw[i + 1]);
		size += Buffer.byteLength(name) + Buffer.byteLength(value) + 32;
		if (name.charAt(0) === ':')
		{
			pseudo[name] = value;
		}
		else if (name === 'cookie')
		{
			if (cookieAt < 0)
			{
				cookieAt = fields.length;
				fields.push(name, value);
			}
			else
			{
				fields[cookieAt + 1] += '; ' + value;
			}
		}
		else
		{
			fields.push(name, value);
		}
	}
	var method = pseudo[':method'] || req.method;
	var isConnect = method === 'CONNECT';
	var own = function(status)
	{
		_HttpServer_writeH2(stream, status, [], new Uint8Array(0), false, true, function() {});
	};
	if (size > cfg.__maxHeader)
	{
		own(431);
		return;
	}
	var authority = pseudo[':authority'] || '';
	for (var j = 0; j + 1 < fields.length; j += 2)
	{
		if (fields[j] === 'content-length' && Number(fields[j + 1]) > cfg.__maxBody)
		{
			own(413);   // before any body
			return;
		}
		if (fields[j] !== 'host') continue;
		var host = fields[j + 1].trim();
		if (authority === '') authority = host;
		else if (host.toLowerCase() !== authority.toLowerCase())
		{
			own(400);
			return;
		}
	}
	var upgrade = '';
	if (isConnect && pseudo[':protocol'] !== undefined)
	{
		if (String(pseudo[':protocol']).toLowerCase() !== 'websocket')
		{
			own(501);   // RFC 9220 §3
			return;
		}
		upgrade = 'websocket';
	}
	var path = pseudo[':path'] || '';
	var scheme = pseudo[':scheme'] === 'http' || pseudo[':scheme'] === 'https' ? pseudo[':scheme'] : 'https';
	var url = scheme + '://' + (authority || s.__authority)
		+ (path === '' || path === '*' ? '/' : (path.charAt(0) === '/' ? path : '/' + path));
	var e = {
		__key: _HttpServer_nextKey++,
		__server: s,
		__socket: null,
		__session: stream.session,
		__h2: stream,
		__res: res,
		__raw: null,
		__isHead: method === 'HEAD',
		__keepAlive: true,
		__mustClose: isConnect,   // the request side stays open: RST_STREAM(NO_ERROR) after
		__needsContinue: false,
		__continued: false,
		__ready: false,
		__delivered: false,
		__dropped: false,
		__size: 256,
		__arg: null,
		// WS9: an extended CONNECT is kept for takeUpgrade (the stream, paused).
		__upgrade: upgrade,
		__method: method,
		__target: path,
		__rawHeaders: fields
	};
	var deliver = function(body)
	{
		e.__size = body.length + 256;
		e.__arg = _HttpServer_makeArg(e, method, url, fields, body, 2 | (s.__tls ? 4 : 0), upgrade);
		e.__ready = true;
		e.__delivered = true;
		_HttpServer_pending[e.__key] = e;
		_HttpServer_deliver(s, e);
	};
	stream.on('error', function() { /* reset: a later answer completes at once */ });
	if (isConnect)
	{
		stream.pause();   // tunnel bytes wait (WS9)
		deliver(Buffer.alloc(0));
		return;
	}
	var chunks = [];
	var total = 0;
	var failed = false;
	stream.on('data', function(c)
	{
		if (failed) return;
		total += c.length;
		if (total > cfg.__maxBody)
		{
			failed = true;
			chunks = [];
			own(413);
			return;
		}
		chunks.push(c);
	});
	stream.on('end', function()
	{
		if (failed) return;
		__Stream_noteActivity();
		deliver(Buffer.concat(chunks));
	});
}

// Writes an HTTP/2 response on `stream` (toH2Nv rules, as Http2.cpp): names lower-cased;
// connection-specific fields, content-length and te other than "trailers" dropped; Node adds
// date unless given; content-length except 204/304; HEAD, 204, 304 and empty bodies as HEADERS
// with END_STREAM. `closeAfter`: RST_STREAM(NO_ERROR) once the response is out (own answers,
// CONNECT). `complete` runs once (written, or the stream is gone).
function _HttpServer_writeH2(stream, st, raw, bytes, isHead, closeAfter, complete)
{
	var http2 = require('http2');
	var done = false;
	var finish = function()
	{
		if (done) return;
		done = true;
		if (closeAfter && !stream.destroyed)
		{
			try { stream.close(http2.constants.NGHTTP2_NO_ERROR); } catch (err) { /* gone */ }
		}
		complete();
	};
	if (stream.destroyed || stream.closed || stream.headersSent)
	{
		finish();   // reset by the client, or answered already
		return;
	}
	var noBody = st === 204 || st === 304;
	var headers = {};
	for (var i = 0; i + 1 < raw.length; i += 2)
	{
		var name = String(raw[i]).toLowerCase();
		var value = raw[i + 1];
		if (name === '' || name.charAt(0) === ':' || name === 'connection' || name === 'keep-alive'
			|| name === 'proxy-connection' || name === 'transfer-encoding' || name === 'upgrade'
			|| name === 'content-length' || (name === 'te' && String(value).trim().toLowerCase() !== 'trailers'))
		{
			continue;
		}
		if (headers[name] === undefined) headers[name] = value;
		else if (Array.isArray(headers[name])) headers[name].push(value);
		else headers[name] = [headers[name], value];
	}
	headers[':status'] = st;
	if (!noBody)
	{
		headers['content-length'] = String(bytes.byteLength);
	}
	var endStream = noBody || isHead || bytes.byteLength === 0;
	stream.once('close', finish);
	try
	{
		try
		{
			stream.respond(headers, { endStream: endStream });
		}
		catch (err)
		{
			if (err && err.code === 'ERR_HTTP2_HEADER_SINGLE_VALUE')
			{
				for (var k in headers)
				{
					if (Array.isArray(headers[k])) headers[k] = headers[k][headers[k].length - 1];
				}
				stream.respond(headers, { endStream: endStream });
			}
			else
			{
				throw err;
			}
		}
		if (endStream)
		{
			setImmediate(finish);
		}
		else
		{
			stream.end(Buffer.from(bytes.buffer, bytes.byteOffset, bytes.byteLength), finish);
		}
	}
	catch (err)
	{
		try
		{
			if (!stream.headersSent) stream.respond({ ':status': 500, 'content-length': '0' }, { endStream: true });
		}
		catch (err2)
		{
			/* gone */
		}
		finish();
	}
}


// --- B.6 / B.2 --------------------------------------------------------------------------

// Listens (host may be '' for all interfaces) and registers the server; callback gets
// the task result. `tls`: null, or { __chain, __key, __http2 } (https, WS3).
function _HttpServer_start(host, port, cfg, tls, callback)
{
	__Stream_noteActivity();
	var http = require('http');
	var timeouts = [cfg.__headersT, cfg.__requestT, cfg.__keepAlive].filter(function(t) { return t > 0; });
	var shortest = timeouts.length > 0 ? Math.min.apply(null, timeouts) : 30000;
	var requestT = cfg.__requestT > 0 ? cfg.__requestT : 0;
	var headersT = cfg.__headersT > 0 ? cfg.__headersT : 0;
	if (requestT > 0 && (headersT === 0 || headersT > requestT))
	{
		headersT = requestT;   // Node requires headersTimeout <= requestTimeout
	}
	var server;
	var alpn = tls ? _HttpServer_alpnList(tls.__http2) : null;
	try
	{
		var options = {
			maxHeaderSize: Math.max(1, cfg.__maxHeader),
			requestTimeout: requestT,
			headersTimeout: headersT,
			keepAliveTimeout: cfg.__keepAlive > 0 ? cfg.__keepAlive : 0,
			connectionsCheckingInterval: Math.max(25, Math.min(30000, Math.floor(shortest / 4))),
			requireHostHeader: false,   // the Host rules are checked here, as natively
			joinDuplicateHeaders: false
		};
		if (tls)
		{
			options.cert = tls.__chain;
			options.key = tls.__key;
			options.ALPNProtocols = alpn;
			if (tls.__http2)
			{
				options.ciphers = _HttpServer_h2Ciphers;
				server = _HttpServer_createH2Server(options, cfg);
			}
			else
			{
				server = require('https').createServer(options);
			}
		}
		else
		{
			server = http.createServer(options);
		}
	}
	catch (e)
	{
		callback(__Scheduler_fail(__Utils_Tuple2(e.code || 'EUNKNOWN', e.message || String(e))));
		return;
	}
	if (cfg.__maxConnections >= 0)
	{
		server.maxConnections = cfg.__maxConnections;
	}
	var id = _HttpServer_nextServerId++;
	var s = {
		__id: id,
		__server: server,
		__cfg: cfg,
		__authority: _HttpServer_authorityOf(host, port),
		__listener: null,   // function(entry), while the Elm manager listens
		__queue: [],        // entries waiting for a listener, oldest first
		__heldBytes: 0,
		__closing: false,
		__sockets: new Set(),
		__tls: !!tls,
		__handshaking: new Set(),  // TLS: raw sockets before their 'secureConnection'
		__sessions: new Set()      // HTTP/2 sessions (WS8)
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
	var track = function(socket)
	{
		s.__sockets.add(socket);
		socket.on('close', function()
		{
			s.__sockets.delete(socket);
			// ConnGone (native): the keys of this connection are forgotten; a later respond
			// completes at once.
			var q = socket.__httpQ || [];
			for (var i = 0; i < q.length; i++)
			{
				if (_HttpServer_pending[q[i].__key] === q[i])
				{
					delete _HttpServer_pending[q[i].__key];
				}
			}
			s.__queue = s.__queue.filter(function(e)
			{
				if (e.__socket !== socket) return true;
				s.__heldBytes -= Math.min(s.__heldBytes, e.__size);
				return false;
			});
		});
	};
	if (tls)
	{
		// Requests arrive on the TLSSocket (its queue and keys); the raw socket is tracked
		// too, so the deadline of closeServer reaches it.
		_HttpServer_alpnFallback(s, server, alpn);
		server.on('connection', track);
		server.on('secureConnection', function(socket)
		{
			if (socket._parent)
			{
				s.__handshaking.delete(socket._parent);
			}
			track(socket);
		});
	}
	else
	{
		server.on('connection', track);
	}
	// HTTP/2 (WS8): requests arrive through the compatibility API ('request', 'connect', ...)
	// with httpVersionMajor 2; they are handled per stream (no per-socket queue).
	server.on('request', function(req, res)
	{
		if (req.httpVersionMajor === 2) _HttpServer_onH2Request(s, req, res);
		else _HttpServer_onRequest(s, req, res, false);
	});
	server.on('checkContinue', function(req, res)
	{
		if (req.httpVersionMajor === 2) _HttpServer_onH2Request(s, req, res);
		else _HttpServer_onRequest(s, req, res, true);
	});
	server.on('checkExpectation', function(req, res)
	{
		if (req.httpVersionMajor === 2) _HttpServer_onH2Request(s, req, res);   // as native: Expect is not read
		else _HttpServer_reject(res, 417);
	});
	server.on('upgrade', function(req, socket, head) { _HttpServer_onUpgrade(s, req, socket, head, false); });
	server.on('connect', function(req, socketOrRes, head)
	{
		if (req.httpVersionMajor === 2) _HttpServer_onH2Request(s, req, socketOrRes);
		else _HttpServer_onUpgrade(s, req, socketOrRes, head, true);
	});
	server.on('session', function(session)
	{
		s.__sessions.add(session);
		session.on('error', function() { /* reported to its streams */ });
		session.once('close', function()
		{
			s.__sessions.delete(session);
			// ConnGone (native): the keys of this connection are forgotten.
			for (var k in _HttpServer_pending)
			{
				if (_HttpServer_pending[k].__session === session) delete _HttpServer_pending[k];
			}
			s.__queue = s.__queue.filter(function(e)
			{
				if (e.__session !== session) return true;
				s.__heldBytes -= Math.min(s.__heldBytes, e.__size);
				return false;
			});
		});
		if (s.__closing)
		{
			session.close();
		}
	});
	try
	{
		server.listen(port, host || undefined, function()
		{
			if (started) return;
			started = true;
			var addr = server.address();
			var bound = addr && typeof addr === 'object' ? addr.port : port;
			s.__authority = _HttpServer_authorityOf(host, bound);
			_HttpServer_servers[id] = s;
			callback(__Scheduler_succeed(__Utils_Tuple2(id, bound)));
		});
	}
	catch (e)
	{
		// e.g. ERR_SOCKET_BAD_PORT, thrown synchronously
		started = true;
		callback(__Scheduler_fail(__Utils_Tuple2(e.code || 'EUNKNOWN', e.message || String(e))));
	}
}

// createServer : String -> Int -> Task ( String, String ) ( Int, Int )
var _HttpServer_createServer = F2(function(host, port)
{
	return __Scheduler_binding(function(callback)
	{
		_HttpServer_start(host, port, _HttpServer_defaults(), null, callback);
	});
});

// createServerWith : ( ( String, Int ), ( Bool, Int ) ) -> Maybe ( String, String )
//     -> ( ( Int, Int, Int ), ( Int, Int, Int ) ) -> Task ( String, String ) ( Int, Int )
var _HttpServer_createServerWith = F3(function(target, tls, limits)
{
	return __Scheduler_binding(function(callback)
	{
		var hasTls = tls !== __Maybe_Nothing && tls.$ !== __Maybe_Nothing.$;
		if (target.b.a && !hasTls)
		{
			callback(__Scheduler_fail(__Utils_Tuple2('EINVAL', 'createServerWith: http2 requires tls')));
			return;
		}
		var cfg = {
			__maxConnections: target.b.b,
			__keepAlive: limits.a.a,
			__headersT: limits.a.b,
			__requestT: limits.a.c,
			__maxBody: limits.b.a,
			__maxHeader: limits.b.b,
			__maxStreams: limits.b.c
		};
		var tlsCfg = null;
		if (hasTls)
		{
			var bad = _HttpServer_tlsError(tls.a.a, tls.a.b);
			if (bad)
			{
				callback(__Scheduler_fail(bad));
				return;
			}
			tlsCfg = { __chain: tls.a.a, __key: tls.a.b, __http2: target.b.a };
		}
		_HttpServer_start(target.a.a, target.a.b, cfg, tlsCfg, callback);
	});
});

// respond : Int -> Int -> List ( String, List String ) -> Bytes -> Task Never ()
var _HttpServer_respond = F4(function(key, status, headers, body)
{
	return __Scheduler_binding(function(callback)
	{
		var complete = function()
		{
			callback(__Scheduler_succeed(__Utils_Tuple0));
		};
		var e = _HttpServer_pending[key];
		if (!e)
		{
			complete();   // unknown or already answered
			return;
		}
		delete _HttpServer_pending[key];
		__Stream_noteActivity();
		var user = _HttpServer_userHeaders(headers);
		_HttpServer_writeAnswer(e, status, user.__raw, __Stream_toUint8Array(body), user.__askClose, complete);
	});
});

// closeServer : Int -> Int -> Task Never ()
var _HttpServer_closeServer = F2(function(serverId, deadlineMs)
{
	return __Scheduler_binding(function(callback)
	{
		var s = _HttpServer_servers[serverId];
		var complete = function()
		{
			callback(__Scheduler_succeed(__Utils_Tuple0));
		};
		if (!s || s.__closing)
		{
			complete();
			return;
		}
		__Stream_noteActivity();
		s.__closing = true;
		s.__server.close();   // stop accepting: the port is free
		// Held requests (no subscriber): 503 + close.
		var held = s.__queue;
		s.__queue = [];
		s.__heldBytes = 0;
		for (var i = 0; i < held.length; i++)
		{
			_HttpServer_answerOwn(held[i], 503);
		}
		// Idle connections: closed now (in-flight ones answer with Connection: close); TLS
		// handshakes in progress: aborted (as native's listener).
		if (s.__server.closeIdleConnections) s.__server.closeIdleConnections();
		s.__handshaking.forEach(function(raw) { raw.destroy(); });
		s.__handshaking.clear();
		// HTTP/2: GOAWAY, open streams finish (session.close is graceful).
		s.__sessions.forEach(function(session) { session.close(); });
		var t = setTimeout(function()
		{
			if (s.__server.closeAllConnections) s.__server.closeAllConnections();
			s.__sessions.forEach(function(session) { session.destroy(); });
			s.__sockets.forEach(function(socket) { socket.destroy(); });
		}, Math.max(0, deadlineMs));
		if (t.unref) t.unref();
		setImmediate(complete);
	});
});

// takeUpgrade : Int -> Task ( String, String ) ( Int, ( String, String, String ), ( List ( String, List String ), Bool, EpT ) )
var _HttpServer_takeUpgrade = function(key)
{
	return __Scheduler_binding(function(callback)
	{
		var e = _HttpServer_pending[key];
		if (e && e.__h2 && e.__upgrade)
		{
			// WS9: an HTTP/2 extended CONNECT: the stream stays in its session (closeServer's
			// GOAWAY leaves it open; the session ends with it or at the deadline).
			delete _HttpServer_pending[key];
			_HttpServer_done(e);
			var stream = e.__h2;
			if (stream.destroyed || stream.closed)
			{
				callback(__Scheduler_fail(__Utils_Tuple2('ECANCELED', 'socket closed')));
				return;
			}
			__Stream_noteActivity();
			callback(__Scheduler_succeed(__WebSocket_parkH2Upgrade(stream, e.__method, e.__target, e.__rawHeaders)));
			return;
		}
		if (!e || !e.__raw || !e.__upgrade)
		{
			callback(__Scheduler_fail(__Utils_Tuple2('EINVAL',
				'upgradeRequest EINVAL: the request was answered already or is not an upgrade request')));
			return;
		}
		delete _HttpServer_pending[key];
		var socket = e.__raw;
		var s = e.__server;
		_HttpServer_done(e);
		if (socket.destroyed)
		{
			callback(__Scheduler_fail(__Utils_Tuple2('ECANCELED', 'socket closed')));
			return;
		}
		__Stream_noteActivity();
		// The socket leaves the server: closeServer's deadline no longer reaches it (§3.4,
		// Node's behaviour), and no HTTP timeout remains armed on it.
		var raw = socket._parent || socket;
		s.__sockets.delete(socket);
		s.__sockets.delete(raw);
		socket.removeListener('error', e.__onError);
		try { socket.setTimeout(0); } catch (err) { /* destroyed */ }
		callback(__Scheduler_succeed(__WebSocket_parkUpgrade(socket, raw, e.__head,
			e.__method, e.__target, e.__version, e.__rawHeaders)));
	});
};


// --- JS-only: the request listener of the Elm Http.Server manager ------------------------

// attachRequestListener : Int -> (( ( String, String ), ( List ( String, List String ), Bytes ), ( Int, Int, String ) ) -> Task Never ()) -> Task Never ()
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
		s.__heldBytes = 0;
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
