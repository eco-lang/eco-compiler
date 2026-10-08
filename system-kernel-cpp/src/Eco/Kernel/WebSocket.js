/*
import Elm.Kernel.Scheduler exposing (binding, succeed, fail, rawSpawn)
import Elm.Kernel.Utils exposing (Tuple0, Tuple2, Tuple3)
import Elm.Kernel.List exposing (fromArray, toArray)
import Eco.Kernel.Stream exposing (createMappedSource, createMappedSink, createChannelSource, createChannelSink, createTextChannelSink, discardReadable, attachReader, detachReader, noteActivity, toBytes)
import Eco.Kernel.Socket exposing (detach)
import Eco.Kernel.Tls exposing (code, errorMessage, pemCertificates, systemCertificates)
*/

// WebSocket — JS twin of src/eco-system/WebSocket/ (eco/system), plans/eco-system-websockets.md
// Appendix B.1, D and E.3: phases WS4 (Whole mode), WS6 (streamed messages: bodies,
// outgoing streams) and WS7 (permessage-deflate).
//
//   * The codec (_WebSocket_codec) is a port of the C++ WsCore over a Node Duplex (a
//     net.Socket or a TLSSocket): a frame decoder with the D.1 header rules checked before
//     any payload is buffered, Whole messages up to maxMessage (1009 above it), text
//     validated by a fatal streaming TextDecoder (fail fast, also inside fragments, BOM
//     kept); control frames answered ahead of queued data; data messages queued and handed
//     to the socket in fragments of at most 256 KiB while its buffer is below 64 KiB, so a
//     pong never waits behind more than one fragment; client frames masked with keys from
//     a pooled crypto.randomFillSync buffer (D.8); the close handshake, the close timeout,
//     failing the connection (D.5, D.9 reasons), heartbeat and ping (D.6, W5), reading
//     paused (socket.pause) while 1 MiB or 1024 messages wait for Elm, with the heartbeat
//     and pong deadlines suspended meanwhile.
//   * Streams: the readable is a mapped source over the codec's read channel (chunks
//     { tag: 1, text } / { tag: 2, bytes }), the writable a mapped sink over its write
//     channel (requestWriteTagged), with Stream.js's plain property names.
//   * Keep-alive (native: pendingAsync, §3.6): the socket is ref'd only while something
//     holds it: a waiting read (setDemand), a write in flight, the close handshake from a
//     local close, a ping, a parked `closed`, a subscription. Timers are unref'd.
//   * dial: our own net.Socket per address in order (connected before tls.connect, Tls.js's
//     rules: certificates, SNI or an IP check, ALPN http/1.1), one timer for the whole
//     handshake, the request written, the response head read (at most 64 KiB). The
//     handshake id then holds the paused socket and the bytes read past the head.
//   * HTTP/2 (RFC 8441, WS9): with `http2 = True` (wss) ALPN offers h2 first. When the
//     server chose h2: http2.connect with createConnection returning our TLS socket, wait
//     for 'remoteSettings'; enableConnectProtocol → the extended CONNECT (:protocol
//     websocket, the fields of the HTTP/1.1 request without Host, Upgrade, Connection and
//     the key), any final status is returned with isH2 = True (Elm accepts 2xx); otherwise
//     the session is closed (GOAWAY) and the same address is dialed again with ALPN
//     http/1.1, within the same timer. ALPN http/1.1: the HTTP/1.1 Upgrade on the same
//     connection. The handshake id then holds the stream, paused (_WebSocket_h2Duplex: the
//     codec runs on it unchanged; end = END_STREAM, destroy = RST_STREAM(CANCEL); the
//     session ends with its one stream). Server side (parkH2Upgrade, HttpServer.js
//     takeUpgrade of an extended CONNECT): open answers :status 200 without END_STREAM,
//     reject a complete response followed by RST_STREAM(NO_ERROR).
//   * readUpgrade: Socket.js's detach takes the connection's socket away from its streams
//     (EBUSY while one has an operation in flight; they then fail "upgraded to WebSocket";
//     Socket.close on the old connection still destroys the socket), then the request head
//     is read within the timeout; a request that is not HTTP is answered 400.
//   * parkUpgrade (HttpServer.js takeUpgrade, WS5): an HTTP/1.1 upgrade request's socket
//     from node:http's 'upgrade' event becomes a handshake id like readUpgrade's.
//   * open writes the 101 (server) and starts the codec with the bytes read past the head;
//     reject writes the answer and ends the socket; abandon destroys it.
//   * The JS-only manager kernels (attachMessageListener, attachCloseListener, holdClose)
//     serve the Elm manager bodies of WebSocket.elm: a subscription reader on the readable
//     (retried while a read is parked), the close delivered once or held.

var _WebSocket_GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';
var _WebSocket_kMaxHead = 64 * 1024;
var _WebSocket_kReadHighBytes = 1024 * 1024;
var _WebSocket_kReadHighCount = 1024;
var _WebSocket_kWriteHighBytes = 64 * 1024;
var _WebSocket_kFragment = 256 * 1024;
var _WebSocket_kBodyChunk = 256 * 1024;
var _WebSocket_kDrainMs = 2000;
var _WebSocket_kPingTimeoutMs = 30000;
var _WebSocket_kSocketClosed = 'socket closed';

function _WebSocket_acceptOf(key)
{
	return require('crypto').createHash('sha1').update(key + _WebSocket_GUID).digest('base64');
}

function _WebSocket_ferr(code, message)
{
	return __Scheduler_fail(__Utils_Tuple2(code, message));
}

function _WebSocket_done()
{
	return __Scheduler_succeed(__Utils_Tuple0);
}

// An error for a stream channel: `reason` becomes the stream's Cancelled reason.
function _WebSocket_error(reason, code)
{
	var e = new Error(reason);
	e.code = code || 'ECANCELED';
	e.reason = reason;
	return e;
}

function _WebSocket_codeOf(e)
{
	return (e && typeof e.code === 'string' && e.code) ? e.code : 'EIO';
}

function _WebSocket_unref(timer)
{
	if (timer && timer.unref) timer.unref();
	return timer;
}

// EpT
function _WebSocket_endpoint(socket, isUnix, local)
{
	if (isUnix) return __Utils_Tuple3(1, '', 0);
	return local
		? __Utils_Tuple3(0, socket.localAddress || '', socket.localPort || 0)
		: __Utils_Tuple3(0, socket.remoteAddress || '', socket.remotePort || 0);
}


// --- HTTP heads (WsHandshake.cpp) ----------------------------------------------------

var _WebSocket_tokenRe = /^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/;

function _WebSocket_headLength(buf)
{
	var a = buf.indexOf('\r\n\r\n');
	var b = buf.indexOf('\n\n');
	var x = a < 0 ? -1 : a + 4;
	var y = b < 0 ? -1 : b + 2;
	if (x < 0) return y < 0 ? 0 : y;
	if (y < 0) return x;
	return Math.min(x, y);
}

function _WebSocket_headLines(text)
{
	var lines = [];
	var all = text.split('\n');
	for (var i = 0; i < all.length; i++)
	{
		var line = all[i];
		if (line.length && line.charCodeAt(line.length - 1) === 13) line = line.slice(0, -1);
		if (line === '') break;
		lines.push(line);
	}
	return lines;
}

function _WebSocket_parseVersion(v)
{
	var m = /^HTTP\/([0-9])\.([0-9])$/.exec(v);
	return m ? m[1] + '.' + m[2] : null;
}

// [ [ name, value ] ] or an error string.
function _WebSocket_parseFields(lines)
{
	var out = [];
	for (var i = 1; i < lines.length; i++)
	{
		var line = lines[i];
		if (line[0] === ' ' || line[0] === '\t') return 'obsolete line folding';
		var colon = line.indexOf(':');
		if (colon < 0) return 'a header line without a colon';
		var name = line.slice(0, colon);
		if (!_WebSocket_tokenRe.test(name)) return 'an invalid header name';
		var value = line.slice(colon + 1).replace(/^[ \t]+|[ \t]+$/g, '');
		if (/[\x00-\x08\x0A-\x1F\x7F]/.test(value)) return 'a control character in a header value';
		out.push([name, value]);
	}
	return out;
}

function _WebSocket_parseRequestHead(text)
{
	var lines = _WebSocket_headLines(text);
	if (!lines.length) return { error: 'an empty request' };
	var parts = lines[0].split(' ');
	if (parts.length !== 3 || !_WebSocket_tokenRe.test(parts[0]) || parts[1] === ''
		|| /[\x00-\x20\x7F]/.test(parts[1]))
	{
		return { error: 'an invalid request line' };
	}
	var version = _WebSocket_parseVersion(parts[2]);
	if (!version) return { error: 'an invalid request line' };
	var fields = _WebSocket_parseFields(lines);
	if (typeof fields === 'string') return { error: fields };
	return { method: parts[0], target: parts[1], version: version, headers: fields };
}

function _WebSocket_parseResponseHead(text)
{
	var lines = _WebSocket_headLines(text);
	if (!lines.length) return { error: 'an empty response' };
	var m = /^(HTTP\/[0-9]\.[0-9]) ([0-9]{3})(?: (.*))?$/.exec(lines[0]);
	if (!m) return { error: 'an invalid status line' };
	var fields = _WebSocket_parseFields(lines);
	if (typeof fields === 'string') return { error: fields };
	return { status: parseInt(m[2], 10), headers: fields };
}

function _WebSocket_headerValid(name, value)
{
	return _WebSocket_tokenRe.test(name) && !/[\r\n\x00]/.test(value);
}

function _WebSocket_headerText(pairs, skipFraming)
{
	var out = '';
	for (var i = 0; i < pairs.length; i++)
	{
		var name = pairs[i][0], value = pairs[i][1];
		if (!_WebSocket_headerValid(name, value)) continue;
		var lower = name.toLowerCase();
		if (skipFraming && (lower === 'content-length' || lower === 'transfer-encoding' || lower === 'connection')) continue;
		out += name + ': ' + value + '\r\n';
	}
	return out;
}

var _WebSocket_reasons = {
	101: 'Switching Protocols', 200: 'OK', 204: 'No Content', 301: 'Moved Permanently',
	302: 'Found', 307: 'Temporary Redirect', 308: 'Permanent Redirect', 400: 'Bad Request',
	401: 'Unauthorized', 403: 'Forbidden', 404: 'Not Found', 405: 'Method Not Allowed',
	408: 'Request Timeout', 409: 'Conflict', 426: 'Upgrade Required', 429: 'Too Many Requests',
	431: 'Request Header Fields Too Large', 500: 'Internal Server Error', 501: 'Not Implemented',
	503: 'Service Unavailable'
};

function _WebSocket_statusReason(status)
{
	if (_WebSocket_reasons[status]) return _WebSocket_reasons[status];
	if (status < 200) return 'Informational';
	if (status < 300) return 'Success';
	if (status < 400) return 'Redirection';
	if (status < 500) return 'Client Error';
	return 'Server Error';
}

function _WebSocket_serializeResponse(status, pairs, withBody, body)
{
	var text = 'HTTP/1.1 ' + status + ' ' + _WebSocket_statusReason(status) + '\r\n'
		+ _WebSocket_headerText(pairs, withBody);
	if (!withBody) return Buffer.from(text + '\r\n', 'utf8');
	var b = Buffer.from(body, 'utf8');
	text += 'Content-Length: ' + b.length + '\r\nConnection: close\r\n\r\n';
	return Buffer.concat([Buffer.from(text, 'utf8'), b]);
}

// List ( String, String ) → [ [ name, value ] ]
function _WebSocket_pairs(list)
{
	var arr = __List_toArray(list);
	var out = [];
	for (var i = 0; i < arr.length; i++) out.push([arr[i].a, arr[i].b]);
	return out;
}

// [ [ name, value ] ] → List ( String, List String ), one element per header line.
function _WebSocket_headerList(fields)
{
	var out = [];
	for (var i = 0; i < fields.length; i++)
	{
		out.push(__Utils_Tuple2(fields[i][0], __List_fromArray([fields[i][1]])));
	}
	return __List_fromArray(out);
}


// --- Frames (WsFrame.cpp) -------------------------------------------------------------

var _WebSocket_maskPool = null;
var _WebSocket_maskAt = 0;

function _WebSocket_nextMask()
{
	if (!_WebSocket_maskPool || _WebSocket_maskAt + 4 > _WebSocket_maskPool.length)
	{
		_WebSocket_maskPool = require('crypto').randomFillSync(Buffer.alloc(4096));
		_WebSocket_maskAt = 0;
	}
	var key = _WebSocket_maskPool.subarray(_WebSocket_maskAt, _WebSocket_maskAt + 4);
	_WebSocket_maskAt += 4;
	return key;
}

function _WebSocket_unmask(buf, key, offset)
{
	for (var i = 0; i < buf.length; i++) buf[i] ^= key[(offset + i) & 3];
}

function _WebSocket_frame(fin, opcode, payload, masked, rsv1)
{
	var n = payload.length;
	var ext = n < 126 ? 0 : (n <= 0xFFFF ? 2 : 8);
	var hlen = 2 + ext + (masked ? 4 : 0);
	var out = Buffer.allocUnsafe(hlen + n);
	out[0] = (fin ? 0x80 : 0) | (rsv1 ? 0x40 : 0) | opcode;
	var m = masked ? 0x80 : 0;
	if (n < 126)
	{
		out[1] = m | n;
	}
	else if (n <= 0xFFFF)
	{
		out[1] = m | 126;
		out.writeUInt16BE(n, 2);
	}
	else
	{
		out[1] = m | 127;
		out.writeUInt32BE(Math.floor(n / 4294967296), 2);
		out.writeUInt32BE(n >>> 0, 6);
	}
	payload.copy(out, hlen);
	if (masked)
	{
		var key = _WebSocket_nextMask();
		key.copy(out, hlen - 4);
		for (var i = 0; i < n; i++) out[hlen + i] ^= key[i & 3];
	}
	return out;
}

function _WebSocket_closeCodeValid(code)
{
	return (code >= 1000 && code <= 1003) || (code >= 1007 && code <= 1014) || (code >= 3000 && code <= 4999);
}

// The longest prefix of a UTF-8 buffer of at most `limit` bytes ending on a character boundary.
function _WebSocket_truncate(buf, limit)
{
	if (buf.length <= limit) return buf;
	var cut = limit;
	while (cut > 0 && (buf[cut] & 0xC0) === 0x80) cut--;
	return buf.subarray(0, cut);
}

function _WebSocket_closePayload(code, reason)
{
	if (!code) return Buffer.alloc(0);
	var r = _WebSocket_truncate(Buffer.from(reason || '', 'utf8'), 123);
	var out = Buffer.alloc(2 + r.length);
	out.writeUInt16BE(code, 0);
	r.copy(out, 2);
	return out;
}

// { code, reason } or { failCode, failText } (D.5).
function _WebSocket_parseClose(payload)
{
	if (payload.length === 0) return { code: 1005, reason: '' };
	if (payload.length === 1) return { failCode: 1002, failText: 'a Close frame with a 1-byte payload' };
	var code = payload.readUInt16BE(0);
	if (!_WebSocket_closeCodeValid(code)) return { failCode: 1002, failText: 'invalid close code ' + code };
	try
	{
		var reason = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(payload.subarray(2));
		return { code: code, reason: reason };
	}
	catch (e)
	{
		return { failCode: 1007, failText: 'the close reason is not valid UTF-8' };
	}
}

// The incremental frame decoder (WsDecoder). `sink` gets onMessage(opcode, data) (a string
// for text, a Buffer for binary) and onControl(opcode, payload). In raw data mode (`raw`:
// streamed messages or permessage-deflate, WS6/WS7) data messages are not assembled or
// checked as UTF-8: the sink gets onDataStart(opcode, compressed), onDataChunk(buffer) (an
// unmasked view of the input) and onDataEnd(); the size is checked from the frame headers only
// for uncompressed messages. `allowRsv1`: RSV1 is allowed on the first frame of a data
// message (permessage-deflate negotiated). feed(buf) returns the bytes consumed (fewer after
// stop(): the rest of the current frame is consumed, then it returns).
function _WebSocket_decoder(expectMasked, maxMessage, sink, raw, allowRsv1)
{
	var hdr = Buffer.alloc(14);
	var hdrHave = 0;
	var inPayload = false;
	var fin = false, opcode = 0, masked = false;
	var key = Buffer.alloc(4);
	var remaining = 0, maskOffset = 0, isControl = false;
	var control = [];
	var inMessage = false, msgOpcode = 0, msgSize = 0, msgCompressed = false;
	var parts = [], textParts = [], text = null;
	var discard = false, stopped = false;
	var self = { failCode: 0, failText: '' };

	function fail(code, why)
	{
		if (!self.failCode)
		{
			self.failCode = code;
			self.failText = why;
		}
		return false;
	}

	function startFrame()
	{
		var b0 = hdr[0], b1 = hdr[1];
		fin = (b0 & 0x80) !== 0;
		opcode = b0 & 0x0F;
		masked = (b1 & 0x80) !== 0;
		var len = b1 & 0x7F;
		var at = 2;
		if (len === 126)
		{
			len = hdr.readUInt16BE(2);
			at = 4;
		}
		else if (len === 127)
		{
			var hi = hdr.readUInt32BE(2), lo = hdr.readUInt32BE(6);
			if (hi & 0x80000000) return fail(1002, 'a 64-bit length with the most significant bit set');
			len = hi * 4294967296 + lo;
			at = 10;
		}
		if (masked) hdr.copy(key, 0, at, at + 4);
		var rsv1 = (b0 & 0x40) !== 0;
		if (b0 & 0x30) return fail(1002, 'RSV2 or RSV3 is set');
		if (rsv1 && !allowRsv1) return fail(1002, 'RSV1 is set without a negotiated extension');
		if (!(opcode <= 2 || (opcode >= 8 && opcode <= 10))) return fail(1002, 'a reserved opcode');
		if (masked !== expectMasked)
		{
			return fail(1002, expectMasked ? 'an unmasked client frame' : 'a masked server frame');
		}
		isControl = opcode >= 8;
		if (rsv1 && (isControl || opcode === 0))
		{
			return fail(1002, isControl ? 'RSV1 is set on a control frame' : 'RSV1 is set on a continuation frame');
		}
		if (isControl)
		{
			if (!fin) return fail(1002, 'a fragmented control frame');
			if (len > 125) return fail(1002, 'a control frame longer than 125 bytes');
			control = [];
		}
		else if (opcode === 0)
		{
			if (!inMessage) return fail(1002, 'a continuation frame without a message in progress');
		}
		else
		{
			if (inMessage) return fail(1002, 'a new data frame inside a fragmented message');
			inMessage = true;
			msgOpcode = opcode;
			msgCompressed = rsv1;
			msgSize = 0;
			parts = [];
			textParts = [];
			text = opcode === 1 && !discard && !raw ? new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }) : null;
		}
		if (!isControl)
		{
			if (!discard && !(raw && msgCompressed) && len > maxMessage - Math.min(msgSize, maxMessage))
			{
				return fail(1009, 'the message is larger than maxMessageSize');
			}
			msgSize += len;
		}
		remaining = len;
		maskOffset = 0;
		return true;
	}

	self.feed = function(buf)
	{
		stopped = false;
		var pos = 0, n = buf.length;
		while (!self.failCode && !stopped)
		{
			if (!inPayload)
			{
				var need = 2;
				if (hdrHave >= 2)
				{
					var len7 = hdr[1] & 0x7F;
					need = 2 + (len7 === 126 ? 2 : len7 === 127 ? 8 : 0) + ((hdr[1] & 0x80) ? 4 : 0);
				}
				if (hdrHave < need)
				{
					if (pos >= n) break;
					var want = Math.min(need - hdrHave, n - pos);
					buf.copy(hdr, hdrHave, pos, pos + want);
					hdrHave += want;
					pos += want;
					continue;
				}
				hdrHave = 0;
				var wasInMessage = inMessage;
				if (!startFrame()) break;
				inPayload = true;
				if (raw && !discard && !isControl && !wasInMessage)
				{
					sink.onDataStart(msgOpcode, msgCompressed);
					if (self.failCode) break;
				}
			}
			if (remaining > 0)
			{
				if (pos >= n) break;
				var take = Math.min(remaining, n - pos);
				var chunk = buf.subarray(pos, pos + take);
				var rawChunk = null;
				if (raw && !isControl && !discard)
				{
					// Unmasked in place (the input buffers are ours) and passed as a view:
					// whoever keeps it keeps that input buffer.
					if (masked) _WebSocket_unmask(chunk, key, maskOffset);
				}
				else if (masked && (isControl || !discard))
				{
					chunk = Buffer.from(chunk);
					_WebSocket_unmask(chunk, key, maskOffset);
				}
				if (isControl)
				{
					control.push(chunk);
				}
				else if (!discard && raw)
				{
					rawChunk = chunk;
				}
				else if (!discard)
				{
					if (msgOpcode === 1)
					{
						try
						{
							textParts.push(text.decode(chunk, { stream: true }));
						}
						catch (e)
						{
							fail(1007, 'invalid UTF-8 in a text message');
							break;
						}
					}
					else
					{
						parts.push(masked ? chunk : Buffer.from(chunk));
					}
				}
				pos += take;
				remaining -= take;
				maskOffset += take;
				if (rawChunk)
				{
					sink.onDataChunk(rawChunk);
					if (self.failCode) break;
				}
				if (remaining > 0) break;
			}
			inPayload = false;
			if (isControl)
			{
				var payload = control.length === 1 ? control[0] : Buffer.concat(control);
				control = [];
				sink.onControl(opcode, payload);
				continue;
			}
			if (!fin) continue;
			inMessage = false;
			msgSize = 0;
			if (discard) continue;
			if (raw)
			{
				sink.onDataEnd();
				continue;
			}
			if (msgOpcode === 1)
			{
				try
				{
					textParts.push(text.decode());
				}
				catch (e)
				{
					fail(1007, 'invalid UTF-8 in a text message');
					break;
				}
				var s = textParts.join('');
				textParts = [];
				text = null;
				sink.onMessage(1, s);
			}
			else
			{
				var data = parts.length === 1 ? parts[0] : Buffer.concat(parts);
				parts = [];
				sink.onMessage(2, data);
			}
		}
		return pos;
	};
	self.stop = function() { stopped = true; };
	self.inMessage = function() { return inMessage; };
	self.setDiscard = function()
	{
		discard = true;
		parts = [];
		textParts = [];
		text = null;
	};
	return self;
}


// --- permessage-deflate (WsDeflate.cpp, plans/eco-system-websockets.md §3.7) --------------
//
// Node's zlib objects driven synchronously through their handles, as Stream.js's codecs:
// handle.writeSync(flush, input, inOff, availIn, out, outOff, availOut) and z._writeState =
// [ availOut, availIn ] afterwards. Deflate: raw, windowBits max(9, bits), Z_SYNC_FLUSH per
// message or chunk, the trailing 00 00 ff ff stripped from a whole message ("\0" when
// empty), reset after every message without context takeover. Inflate: raw, 15 bits,
// 00 00 ff ff appended at the end of a message, at most `maxOut` bytes per step; a final
// block (BFINAL) inside a message starts a new stream that keeps the window (Node can only
// set a dictionary when a zlib object is made, so a new one is made with the last 32 KiB of
// output as its dictionary); reset after every message without context takeover.

var _WebSocket_kZStep = 64 * 1024;
var _WebSocket_TAIL = Buffer.from([0x00, 0x00, 0xff, 0xff]);

function _WebSocket_deflater(bits, noContext)
{
	var zlib = require('zlib');
	var z = null, err = null;

	function make()
	{
		z = new zlib.DeflateRaw({
			windowBits: Math.max(9, Math.min(15, bits)),
			memLevel: 8,
			level: zlib.constants.Z_DEFAULT_COMPRESSION,
			chunkSize: _WebSocket_kZStep
		});
		z._handle.onerror = function(message, errno) { err = message || ('zlib error ' + errno); };
	}

	// Compresses `input` with a sync flush; null on a zlib failure.
	function chunk(input)
	{
		if (!z) make();
		var outs = [];
		var inOff = 0, availIn = input.length;
		for (;;)
		{
			var out = Buffer.allocUnsafe(_WebSocket_kZStep);
			z._handle.writeSync(zlib.constants.Z_SYNC_FLUSH, input, inOff, availIn, out, 0, _WebSocket_kZStep);
			if (err) return null;
			var availOut = z._writeState[0], availInAfter = z._writeState[1];
			var have = _WebSocket_kZStep - availOut;
			if (have > 0) outs.push(out.subarray(0, have));
			inOff += availIn - availInAfter;
			availIn = availInAfter;
			if (availOut !== 0) break;
		}
		return outs.length === 1 ? outs[0] : Buffer.concat(outs);
	}

	function endMessage()
	{
		if (noContext && z) z._handle.reset();
	}

	return {
		chunk: chunk,
		message: function(input)
		{
			var o = chunk(input);
			if (!o) return null;
			var n = o.length;
			if (n >= 4 && o[n - 4] === 0 && o[n - 3] === 0 && o[n - 2] === 0xff && o[n - 1] === 0xff) o = o.subarray(0, n - 4);
			if (!o.length) o = Buffer.from([0]);
			endMessage();
			return o;
		},
		endMessage: endMessage
	};
}

function _WebSocket_inflater(noContext)
{
	var zlib = require('zlib');
	var z = null, err = null;
	var input = [], inLen = 0, curOff = 0;
	var finished = false, sawFinal = false;
	var tail = [], tailLen = 0;   // the last (at least) 32 KiB of output: the window

	function make(dict)
	{
		var options = { windowBits: 15, chunkSize: _WebSocket_kZStep };
		if (dict && dict.length) options.dictionary = dict;
		z = new zlib.InflateRaw(options);
		z._handle.onerror = function(message, errno) { err = message || ('zlib error ' + errno); };
	}

	function remember(out)
	{
		tail.push(out);
		tailLen += out.length;
		while (tail.length > 1 && tailLen - tail[0].length >= 32768)
		{
			tailLen -= tail[0].length;
			tail.shift();
		}
	}

	function resetStream(keepWindow)
	{
		if (!z) return;
		if (keepWindow)
		{
			var all = Buffer.concat(tail);
			var w = Buffer.from(all.subarray(Math.max(0, all.length - 32768)));
			try { z.close(); } catch (e) { /* closed */ }
			make(w);
			tail = w.length ? [w] : [];
			tailLen = w.length;
			return;
		}
		z._handle.reset();
		tail = [];
		tailLen = 0;
	}

	return {
		push: function(buf)
		{
			if (buf.length)
			{
				input.push(buf);
				inLen += buf.length;
			}
		},
		finish: function()
		{
			input.push(_WebSocket_TAIL);
			inLen += 4;
			finished = true;
		},
		hasInput: function() { return inLen > 0; },
		abandon: function()
		{
			input = [];
			inLen = 0;
			curOff = 0;
			finished = false;
			sawFinal = false;
			if (z) z._handle.reset();
			tail = [];
			tailLen = 0;
		},
		error: function() { return err || 'invalid compressed data'; },
		// { out: Buffer } | { need: true } | { done: true } | { error: true }
		step: function(maxOut)
		{
			if (!z) make(null);
			for (;;)
			{
				if (inLen === 0)
				{
					input = [];
					curOff = 0;
					if (!finished) return { need: true };
					if (noContext) resetStream(false);
					else if (sawFinal) resetStream(true);
					finished = false;
					sawFinal = false;
					return { done: true };
				}
				var buf = input[0];
				var availIn = buf.length - curOff;
				var out = Buffer.allocUnsafe(maxOut);
				z._handle.writeSync(zlib.constants.Z_SYNC_FLUSH, buf, curOff, availIn, out, 0, maxOut);
				if (err) return { error: true };
				var availOut = z._writeState[0], availInAfter = z._writeState[1];
				var produced = maxOut - availOut, consumed = availIn - availInAfter;
				curOff += consumed;
				inLen -= consumed;
				if (curOff >= buf.length)
				{
					input.shift();
					curOff = 0;
				}
				var o = produced > 0 ? out.subarray(0, produced) : null;
				if (o) remember(o);
				if (availOut !== 0 && availInAfter > 0)
				{
					// The stream ended (a final block, §7.2.3.4): a new one follows.
					sawFinal = true;
					resetStream(true);
					if (o) return { out: o };
					continue;
				}
				if (o) return { out: o };
				if (consumed > 0) continue;
				err = err || 'invalid compressed data';
				return { error: true };
			}
		}
	};
}


// --- The codec (WsProtocol.cpp) ------------------------------------------------------------
//
// cfg: { server, maxMessage, hbInterval, hbTimeout, closeTimeout, streamed, threshold (-1: no
// permessage-deflate), ourNoContext, ourBits, peerNoContext, peerBits }. onClosed(info) once,
// info = { code, reason, clean }.
//
// Streamed receive (WS6, as WsCore): every data message is announced on the readable as
// { tag: 3 / 4, text: <body pair id> }; its body is a channel source (text bodies give JS
// strings: whole characters, a streaming fatal TextDecoder) created when the message starts.
// After the message's last frame the input is held (the socket paused) until the body was
// read to its end or cancelled. Streamed send: openOutgoing returns the channel of one
// outgoing stream, whose place in the data FIFO is taken at once; its chunks go out as
// non-FIN fragments, its close as the FIN frame, an abort after the first fragment fails the
// connection with 1011. permessage-deflate (WS7): raw data mode, RSV1 on first frames,
// inflate in steps of 64 KiB (maxMessage checked on the inflated size; a streamed body pauses
// inflating while it is full), whole messages of at least `threshold` bytes and every
// streamed chunk compressed.

function _WebSocket_codec(socket, cfg, onClosed)
{
	var self = {};
	var gone = false;          // the transport is gone (destroyed / closed)
	var holds = 0;             // keep-alive holders
	var reffed = null;

	// Input.
	var inputDone = false;
	var rxBytes = 0;
	var lastRx = Date.now();
	var pendingIn = null;      // input not decoded yet (held after a streamed message)
	var processing = false;

	// Raw data mode (streamed, deflate): the message being received.
	var rx = null;             // { op, compressed, endPending, size, parts, utf8 }
	var inflater = null, deflater = null, pumpingInflate = false;

	// Streamed receive.
	var body = null;           // { text, q, qBytes, reads, end, cancelled, endDelivered, messageDone, pairId }
	var held = false;
	var discardAfterMessage = false;

	// The readable.
	var msgQ = [];
	var msgQBytes = 0;
	var readReqs = [];
	var readEnd = null;        // { eof: true } | { err }
	var readShut = false;
	var paused = false;
	var demand = false;

	// The writable.
	var outQ = [];
	var pumping = false;
	var writeClosed = false;
	var closeWaiters = [];     // closeWritable dones
	var closeOps = [];         // close kernel dones

	// Close state.
	var closeQueued = false, closeWritten = false, closeReceived = false, failed = false;
	var info = null;
	var closedPosted = false;
	var tcpClosing = false;
	var closeTimer = null, drainTimer = null, closeHold = false;

	// Ping / heartbeat.
	var pingCounter = 0;
	var pings = [];            // { payload: Buffer, done, sent, deadline }
	var hbPingSent = false, rxAtPing = 0, hbDeadline = 0;
	var hbTimer = null, pongTimer = null;

	var deflate = cfg.threshold >= 0;
	var decoder = _WebSocket_decoder(cfg.server, cfg.streamed ? Infinity : cfg.maxMessage, {
		onMessage: onMessage,
		onControl: onControl,
		onDataStart: onDataStart,
		onDataChunk: onDataChunk,
		onDataEnd: onDataEnd
	}, cfg.streamed || deflate, deflate);

	function updateRef()
	{
		var want = holds > 0 && !gone;
		if (want === reffed) return;
		reffed = want;
		try
		{
			if (want) socket.ref(); else socket.unref();
		}
		catch (e) { /* destroyed */ }
	}

	self.hold = function(delta)
	{
		holds += delta;
		if (delta > 0) __Stream_noteActivity();
		updateRef();
	};

	function closeHoldOnce()
	{
		if (closeHold || closedPosted) return;
		closeHold = true;
		self.hold(1);
	}

	// --- input

	function onSocketData(chunk)
	{
		rxBytes += chunk.length;
		lastRx = Date.now();
		if (inputDone) return;
		pendingIn = pendingIn ? Buffer.concat([pendingIn, chunk]) : chunk;
		processInput();
	}

	// Decodes the queued input until it is used up, held, or the input ends.
	function processInput()
	{
		if (processing) return;
		processing = true;
		try
		{
			while (!inputDone && !decoder.failCode && !held && pendingIn && pendingIn.length)
			{
				var buf = pendingIn;
				pendingIn = null;
				var used = decoder.feed(buf);
				if (used < buf.length && !inputDone && !decoder.failCode)
				{
					var rest = buf.subarray(used);
					pendingIn = pendingIn ? Buffer.concat([rest, pendingIn]) : rest;
				}
			}
			if (inputDone || decoder.failCode) pendingIn = null;
		}
		finally
		{
			processing = false;
		}
		if (decoder.failCode && !failed) failConnection(decoder.failCode, decoder.failText);
	}

	function onMessage(op, data)
	{
		if (inputDone || readShut) return;
		var size = typeof data === 'string' ? data.length : data.length;
		msgQBytes += size;
		msgQ.push({ op: op, data: data, size: size });
		deliverReads();
	}

	// --- raw data mode (streamed messages, permessage-deflate)

	function onDataStart(op, compressed)
	{
		if (inputDone) return;
		rx = {
			op: op,
			compressed: compressed,
			endPending: false,
			size: 0,
			parts: [],
			utf8: op === 1 ? new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }) : null
		};
		if (compressed && !inflater) inflater = _WebSocket_inflater(cfg.peerNoContext);
		if (cfg.streamed) startBody(op);
	}

	function onDataChunk(buf)
	{
		if (inputDone || !rx) return;
		if (rx.compressed)
		{
			inflater.push(buf);
			pumpInflate();
		}
		else
		{
			deliverData(buf);
		}
	}

	function onDataEnd()
	{
		if (inputDone || !rx) return;
		if (cfg.streamed)
		{
			if (discardAfterMessage)
			{
				discardAfterMessage = false;
				decoder.setDiscard();
			}
			else
			{
				held = true;   // the next message waits until this body is finished
				decoder.stop();
			}
		}
		if (rx.compressed)
		{
			inflater.finish();
			rx.endPending = true;
			pumpInflate();
		}
		else
		{
			messageComplete();
		}
		checkPause();
	}

	function deliverData(buf)
	{
		// A message that arrived whole may still be inflating after a Close.
		if (!rx || failed || (inputDone && !rx.endPending)) return;
		var text = null;
		if (rx.utf8)
		{
			try
			{
				text = rx.utf8.decode(buf, { stream: true });
			}
			catch (e)
			{
				failConnection(1007, 'invalid UTF-8 in a text message');
				return;
			}
		}
		if (!cfg.streamed)
		{
			rx.size += buf.length;
			if (rx.size > cfg.maxMessage)
			{
				failConnection(1009, 'the message is larger than maxMessageSize');
				return;
			}
			if (!readShut) rx.parts.push(text !== null ? text : buf);
			return;
		}
		var b = body;
		if (!b || b.cancelled || b.end) return;   // skipped: validated only
		if (b.text)
		{
			if (text.length)
			{
				b.q.push({ data: text, size: buf.length });
				b.qBytes += buf.length;
			}
		}
		else
		{
			b.q.push({ data: buf, size: buf.length });
			b.qBytes += buf.length;
		}
		deliverBody();
	}

	function pumpInflate()
	{
		if (pumpingInflate) return;
		pumpingInflate = true;
		try
		{
			while (rx && rx.compressed && inflater && !failed && (!inputDone || rx.endPending))
			{
				if (cfg.streamed && body && !body.cancelled && !body.end && body.qBytes >= _WebSocket_kReadHighBytes) break;
				var r = inflater.step(_WebSocket_kZStep);
				if (r.out)
				{
					deliverData(r.out);
					continue;
				}
				if (r.need) break;
				if (r.done)
				{
					messageComplete();
					break;
				}
				failConnection(1007, 'invalid compressed data: ' + inflater.error());
				break;
			}
		}
		finally
		{
			pumpingInflate = false;
		}
		checkPause();
	}

	function messageComplete()
	{
		var m = rx;
		if (!m) return;
		rx = null;
		if (m.utf8)
		{
			var restText;
			try
			{
				restText = m.utf8.decode();
			}
			catch (e)
			{
				failConnection(1007, 'invalid UTF-8 in a text message');
				return;
			}
			if (restText.length)
			{
				if (!cfg.streamed) m.parts.push(restText);
				else if (body && !body.cancelled && !body.end) body.q.push({ data: restText, size: restText.length });
			}
		}
		if (!cfg.streamed)
		{
			if (readShut) return;
			onMessage(m.op, m.op === 1 ? m.parts.join('') : (m.parts.length === 1 ? m.parts[0] : Buffer.concat(m.parts)));
			return;
		}
		var b = body;
		if (b)
		{
			b.messageDone = true;
			if (!b.end) b.end = { eof: true };
			deliverBody();
			maybeFinishBody();
		}
	}

	function abandonRx()
	{
		rx = null;
		if (inflater) inflater.abandon();
	}

	// --- streamed bodies (WS6)

	function startBody(op)
	{
		var b = {
			text: op === 1,
			q: [],
			qBytes: 0,
			reads: [],
			end: null,
			cancelled: false,
			endDelivered: false,
			messageDone: false,
			pairId: 0
		};
		body = b;
		var channel = {
			requestRead: function(maxBytes, done)
			{
				if (body !== b || b.cancelled)
				{
					done(_WebSocket_error('operation canceled', 'ECANCELED'), null);
					return;
				}
				self.hold(1);   // a waiting body read keeps the program alive
				b.reads.push(function(e, c)
				{
					self.hold(-1);
					done(e, c);
				});
				deliverBody();
			},
			requestWrite: function(bytes, done)
			{
				done(new Error('not a writable channel'));
			},
			close: function(done)
			{
				if (done) done(null);
			},
			shutdown: function()
			{
				bodyCancel(b);
			}
		};
		b.pairId = __Stream_createChannelSource(channel);
		msgQ.push({ op: b.text ? 3 : 4, data: String(b.pairId), size: 0 });
		deliverReads();
	}

	function bodyCancel(b)
	{
		if (body !== b || b.cancelled) return;
		b.cancelled = true;
		b.q = [];
		b.qBytes = 0;
		var reads = b.reads;
		b.reads = [];
		for (var i = 0; i < reads.length; i++) reads[i](_WebSocket_error('operation canceled', 'ECANCELED'), null);
		if (rx && rx.compressed) pumpInflate();   // the rest is still inflated and validated
		maybeFinishBody();
		checkPause();
	}

	function deliverBody()
	{
		var b = body;
		if (!b) return;
		while (b.reads.length)
		{
			if (b.q.length)
			{
				var first = b.q.shift();
				var size = first.size;
				var r = b.reads.shift();
				if (b.text)
				{
					var text = first.data;
					while (b.q.length && size + b.q[0].size <= _WebSocket_kBodyChunk)
					{
						var n = b.q.shift();
						text += n.data;
						size += n.size;
					}
					b.qBytes -= size;
					r(null, text);
				}
				else
				{
					var parts = [first.data];
					while (b.q.length && size + b.q[0].size <= _WebSocket_kBodyChunk)
					{
						var m = b.q.shift();
						parts.push(m.data);
						size += m.size;
					}
					b.qBytes -= size;
					var buf = parts.length === 1 ? parts[0] : Buffer.concat(parts);
					r(null, new Uint8Array(buf.buffer, buf.byteOffset, buf.length));
				}
				continue;
			}
			if (b.end)
			{
				b.endDelivered = true;
				var last = b.reads.shift();
				if (b.end.eof) last(null, null);
				else last(b.end.err, null);
				break;
			}
			break;
		}
		if (rx && rx.compressed && inflater && (inflater.hasInput() || rx.endPending)) pumpInflate();
		checkPause();
		maybeFinishBody();
	}

	function bodyFail(err)
	{
		var b = body;
		if (!b) return;
		if (!b.end) b.end = { err: err };   // what already arrived stays readable first
		b.messageDone = true;
		deliverBody();
	}

	function maybeFinishBody()
	{
		var b = body;
		if (!b) return;
		var over = b.messageDone || (b.end && b.end.err);
		if (!(b.endDelivered || (b.cancelled && over))) return;
		body = null;
		releaseHold();
	}

	function releaseHold()
	{
		if (!held) return;
		held = false;
		checkPause();
		processInput();
	}

	function onControl(op, payload)
	{
		if (inputDone) return;
		if (op === 9)
		{
			if (!closeQueued) writeRaw(frameOf(true, 10, payload), null);
			return;
		}
		if (op === 10)
		{
			var now = Date.now();
			if (hbPingSent && payload.length === 8 && (payload[0] & 0x80))
			{
				hbPingSent = false;
				hbDeadline = 0;
				armHeartbeat(now + cfg.hbInterval);
			}
			var idx = -1;
			for (var i = 0; i < pings.length; i++)
			{
				if (pings[i].payload.equals(payload))
				{
					idx = i;
					break;
				}
			}
			if (idx >= 0)
			{
				var done = pings.splice(0, idx + 1);
				for (var j = 0; j < done.length; j++)
				{
					self.hold(-1);
					done[j].done(null, now - done[j].sent);
				}
			}
			armPongTimer();
			return;
		}
		if (op === 8)
		{
			closeReceived = true;
			inputDone = true;
			decoder.stop();
			var parsed = _WebSocket_parseClose(payload);
			if (parsed.failCode)
			{
				failConnection(parsed.failCode, parsed.failText);
				return;
			}
			setInfo(parsed.code, parsed.reason, true);
			if (rx && !rx.endPending)
			{
				// A Close in the middle of a message (WS6): its body fails.
				if (body && !body.messageDone) bodyFail(_WebSocket_error(_WebSocket_kSocketClosed, 'ECANCELED'));
				abandonRx();
			}
			endReadable({ eof: true });
			if (!closeQueued)
			{
				closeQueued = true;
				writeClosed = true;
				failQueued(_WebSocket_kSocketClosed);
				startCloseTimer();
				var echo = parsed.code === 1005 ? Buffer.alloc(0) : _WebSocket_closePayload(parsed.code, '');
				writeRaw(frameOf(true, 8, echo), closeFrameWritten);
			}
			finishIfDone();
		}
	}

	function onSocketEnd()
	{
		if (closeReceived || failed)
		{
			closeTcp();
			return;
		}
		ended(_WebSocket_error(_WebSocket_kSocketClosed, 'ECONNRESET'));
		closeTcp();
	}

	function onSocketError(e)
	{
		var code = _WebSocket_codeOf(e);
		ended(_WebSocket_error('read ' + code, code));
		if (!socket.destroyed) socket.destroy();
	}

	function onSocketClose()
	{
		gone = true;
		ended(_WebSocket_error(_WebSocket_kSocketClosed, 'ECANCELED'));
		clearTimeout(hbTimer);
		clearTimeout(pongTimer);
		clearTimeout(closeTimer);
		clearTimeout(drainTimer);
		updateRef();
	}

	// --- the readable

	function deliverReads()
	{
		while (readReqs.length)
		{
			var done;
			if (msgQ.length)
			{
				var m = msgQ.shift();
				msgQBytes -= m.size;
				done = readReqs.shift();
				if (m.op === 1 || m.op >= 3)
				{
					done(null, { tag: m.op, text: m.data, bytes: null });
				}
				else
				{
					done(null, { tag: 2, text: '', bytes: new Uint8Array(m.data.buffer, m.data.byteOffset, m.data.length) });
				}
				continue;
			}
			if (readEnd)
			{
				done = readReqs.shift();
				if (readEnd.eof) done(null, null);
				else done(readEnd.err, null);
				continue;
			}
			break;
		}
		checkPause();
	}

	function endReadable(end)
	{
		if (readEnd) return;
		readEnd = end;
		deliverReads();
	}

	function checkPause()
	{
		var high = !inputDone && (msgQBytes >= _WebSocket_kReadHighBytes || msgQ.length >= _WebSocket_kReadHighCount || held
			|| (body && body.qBytes >= _WebSocket_kReadHighBytes)
			|| (rx && rx.compressed && inflater && inflater.hasInput()));
		if (high && !paused)
		{
			paused = true;
			if (!gone) socket.pause();
			clearTimeout(hbTimer);
			clearTimeout(pongTimer);
			return;
		}
		if (!high && paused)
		{
			paused = false;
			var now = Date.now();
			lastRx = now;
			if (hbPingSent) hbDeadline = now + cfg.hbTimeout;
			else if (cfg.hbInterval > 0) armHeartbeat(now + cfg.hbInterval);
			var t = cfg.hbTimeout > 0 ? cfg.hbTimeout : _WebSocket_kPingTimeoutMs;
			for (var i = 0; i < pings.length; i++) pings[i].deadline = now + t;
			armPongTimer();
			if (!gone && !tcpClosing) socket.resume();
		}
	}

	self.readChannel = {
		requestRead: function(maxBytes, done)
		{
			if (readShut)
			{
				done(_WebSocket_error('operation canceled', 'ECANCELED'), null);
				return;
			}
			readReqs.push(done);
			deliverReads();
		},
		requestWrite: function(bytes, done)
		{
			done(new Error('not a writable channel'));
		},
		close: function(done)
		{
			if (done) done(null);
		},
		shutdown: function()
		{
			if (readShut) return;
			readShut = true;
			if (cfg.streamed && decoder.inMessage())
			{
				discardAfterMessage = true;   // a body being received continues to its end
			}
			else
			{
				decoder.setDiscard();
				// Whole mode: drop the message in progress; streamed: a body whose message
				// arrived whole (still inflating) completes.
				if (rx && !cfg.streamed) abandonRx();
			}
			// Announced bodies nobody will read.
			for (var k = 0; k < msgQ.length; k++)
			{
				if (msgQ[k].op >= 3)
				{
					var pid = parseInt(msgQ[k].data, 10);
					queueMicrotask(function() { __Stream_discardReadable(pid); });
				}
			}
			if (held) releaseHold();
			msgQ = [];
			msgQBytes = 0;
			var reqs = readReqs;
			readReqs = [];
			for (var i = 0; i < reqs.length; i++) reqs[i](_WebSocket_error('operation canceled', 'ECANCELED'), null);
			checkPause();
		},
		setDemand: function(on)
		{
			if (on === demand) return;
			demand = on;
			self.hold(on ? 1 : -1);
		}
	};

	// --- the writable

	function frameOf(fin, op, payload, rsv1)
	{
		return _WebSocket_frame(fin, op, payload, !cfg.server, rsv1);
	}

	function getDeflater()
	{
		if (!deflater) deflater = _WebSocket_deflater(cfg.ourBits, cfg.ourNoContext);
		return deflater;
	}

	function writeRaw(buf, cb)
	{
		if (gone || socket.destroyed || socket.writableEnded)
		{
			if (cb) cb(_WebSocket_error(_WebSocket_kSocketClosed, 'ECANCELED'));
			return;
		}
		socket.write(buf, function(e)
		{
			if (cb) cb(e ? _WebSocket_error(gone ? _WebSocket_kSocketClosed : 'write ' + _WebSocket_codeOf(e), _WebSocket_codeOf(e)) : null);
		});
	}

	function pump()
	{
		if (pumping || gone) return;
		pumping = true;
		while (outQ.length && !gone && socket.writableLength < _WebSocket_kWriteHighBytes)
		{
			var it = outQ[0];
			if (it.isClose)
			{
				outQ.shift();
				writeRaw(it.frame, closeFrameWritten);
				continue;
			}
			if (it.stream)
			{
				// An outgoing stream (WS6): chunks as non-FIN fragments, then the FIN frame;
				// everything behind it waits.
				var st = it.stream;
				if (st.dead)
				{
					outQ.shift();
					continue;
				}
				if (st.chunks.length)
				{
					var c = st.chunks[0];
					if (!c.prepared)
					{
						c.prepared = true;
						if (st.compress)
						{
							var cz = getDeflater().chunk(c.payload);
							if (!cz)
							{
								pumping = false;
								failConnection(1011, 'compression failed');
								return;
							}
							c.payload = cz;
						}
					}
					var cn = Math.min(_WebSocket_kFragment, c.payload.length - c.offset);
					var cfirst = !st.started;
					st.started = true;
					var cframe = frameOf(false, cfirst ? st.op : 0, c.payload.subarray(c.offset, c.offset + cn), cfirst && st.compress);
					c.offset += cn;
					if (c.offset < c.payload.length)
					{
						writeRaw(cframe, null);
						continue;
					}
					st.chunks.shift();
					writeRaw(cframe, c.done);
					continue;
				}
				if (!st.closing) break;   // waiting for the stream's next chunk
				// A compressed message ends with 0x00 (an empty stored block's header, which the
				// receiver's appended 00 00 ff ff completes, RFC 7692 §7.2.3.6).
				var fframe = frameOf(true, st.started ? 0 : st.op, st.compress && st.started ? Buffer.from([0]) : Buffer.alloc(0), false);
				if (st.compress && st.started && deflater) deflater.endMessage();
				st.dead = true;
				st.finished = true;
				outQ.shift();
				var closeDone = st.closeDone;
				st.closeDone = null;
				writeRaw(fframe, closeDone);
				continue;
			}
			if (!it.prepared)
			{
				it.prepared = true;
				if (deflate && it.payload.length >= cfg.threshold)
				{
					var z = getDeflater().message(it.payload);
					if (!z)
					{
						pumping = false;
						failConnection(1011, 'compression failed');
						return;
					}
					it.payload = z;
					it.compressed = true;
				}
			}
			var n = Math.min(_WebSocket_kFragment, it.payload.length - it.offset);
			var first = it.offset === 0;
			var fin = it.offset + n >= it.payload.length;
			var frame = frameOf(fin, first ? it.op : 0, it.payload.subarray(it.offset, it.offset + n), first && it.compressed);
			it.offset += n;
			if (!fin)
			{
				writeRaw(frame, null);
				continue;
			}
			outQ.shift();
			writeRaw(frame, it.done);
		}
		pumping = false;
	}

	function failQueued(reason)
	{
		var q = outQ;
		outQ = [];
		for (var i = 0; i < q.length; i++)
		{
			if (q[i].stream) failStream(q[i].stream, reason);
			else if (!q[i].isClose) q[i].done(_WebSocket_error(reason, 'ECANCELED'));
		}
	}

	// --- outgoing streams (WS6)

	function failStream(st, reason)
	{
		st.dead = true;
		var chunks = st.chunks;
		st.chunks = [];
		for (var i = 0; i < chunks.length; i++) chunks[i].done(_WebSocket_error(reason, 'ECANCELED'));
		if (st.closeDone)
		{
			var d = st.closeDone;
			st.closeDone = null;
			d(_WebSocket_error(reason, 'ECANCELED'));
		}
	}

	// The channel of one outgoing stream (openOutgoing): its place in the FIFO is taken now.
	self.openOutgoing = function(op)
	{
		var st = { op: op, started: false, compress: deflate, closing: false, closeDone: null, dead: false, finished: false, chunks: [] };
		if (writeClosed || gone) st.dead = true;
		else outQ.push({ stream: st });
		pump();
		return {
			requestRead: function(maxBytes, done)
			{
				done(new Error('not a readable channel'), null);
			},
			requestWrite: function(data, done)
			{
				if (st.dead || st.closing || gone)
				{
					done(_WebSocket_error(_WebSocket_kSocketClosed, 'ECANCELED'));
					return;
				}
				var payload = typeof data === 'string' ? Buffer.from(data, 'utf8') : Buffer.from(data.buffer, data.byteOffset, data.byteLength);
				if (!payload.length)
				{
					done(null);
					return;
				}
				self.hold(1);
				st.chunks.push({ payload: payload, offset: 0, prepared: false, done: function(e) { self.hold(-1); done(e); } });
				pump();
			},
			close: function(done)
			{
				done = done || function() {};
				if (st.dead || st.closing || gone)
				{
					done(_WebSocket_error(_WebSocket_kSocketClosed, 'ECANCELED'));
					return;
				}
				st.closing = true;
				self.hold(1);
				st.closeDone = function(e) { self.hold(-1); done(e); };
				pump();
			},
			shutdown: function()
			{
				if (st.finished || (st.dead && !st.chunks.length && !st.closeDone)) return;
				if (st.started && !failed && !closedPosted && !gone)
				{
					failConnection(1011, 'an outgoing message stream was cancelled');
					return;
				}
				failStream(st, 'the message was cancelled');
				for (var i = 0; i < outQ.length; i++)
				{
					if (outQ[i].stream === st)
					{
						outQ.splice(i, 1);
						break;
					}
				}
				pump();
			}
		};
	};

	function queueMessage(op, payload, done)
	{
		if (writeClosed || gone)
		{
			done(_WebSocket_error(_WebSocket_kSocketClosed, 'ECANCELED'));
			return;
		}
		self.hold(1);
		outQ.push({ op: op, payload: payload, offset: 0, done: function(e) { self.hold(-1); done(e); } });
		pump();
	}

	self.writeChannel = {
		requestRead: function(maxBytes, done)
		{
			done(new Error('not a readable channel'), null);
		},
		requestWrite: function(bytes, done)
		{
			queueMessage(2, Buffer.from(bytes.buffer, bytes.byteOffset, bytes.byteLength), done);
		},
		requestWriteTagged: function(chunk, done)
		{
			if (chunk.tag === 1)
			{
				queueMessage(1, Buffer.from(chunk.text, 'utf8'), done);
			}
			else
			{
				var b = chunk.bytes || new Uint8Array(0);
				queueMessage(2, Buffer.from(b.buffer, b.byteOffset, b.byteLength), done);
			}
		},
		close: function(done)
		{
			done = done || function() {};
			if (closeWritten || closedPosted || gone)
			{
				done(closeWritten || (info && info.clean) ? null : _WebSocket_error(_WebSocket_kSocketClosed, 'ECANCELED'));
				return;
			}
			closeWaiters.push(done);
			queueGracefulClose(1000, '');
		},
		shutdown: function()
		{
			if (writeClosed || failed || closedPosted || gone) return;
			failConnection(1011, 'the writable was cancelled');
		}
	};

	function startCloseTimer()
	{
		closeHoldOnce();
		if (closeTimer) return;
		closeTimer = _WebSocket_unref(setTimeout(function()
		{
			ended(_WebSocket_error(_WebSocket_kSocketClosed, 'ETIMEDOUT'));
			if (!socket.destroyed) socket.destroy();
		}, cfg.closeTimeout));
	}

	function queueGracefulClose(code, reason)
	{
		if (closeQueued) return;
		closeQueued = true;
		writeClosed = true;
		decoder.setDiscard();
		if (rx && !rx.endPending)
		{
			// Data after our Close is discarded: a body in progress fails (WS6).
			if (body && !body.messageDone) bodyFail(_WebSocket_error(_WebSocket_kSocketClosed, 'ECANCELED'));
			abandonRx();
		}
		releaseHold();
		outQ.push({ isClose: true, frame: frameOf(true, 8, _WebSocket_closePayload(code, reason)) });
		startCloseTimer();
		pump();
	}

	function closeFrameWritten()
	{
		closeWritten = true;
		var ops = closeOps;
		closeOps = [];
		for (var i = 0; i < ops.length; i++) ops[i]();
		var ws = closeWaiters;
		closeWaiters = [];
		for (var j = 0; j < ws.length; j++) ws[j](null);
		finishIfDone();
	}

	function finishIfDone()
	{
		if (!closeWritten || !closeReceived || failed) return;
		postClosed();
		if (cfg.server) closeTcp();
	}

	// FIN after the queued writes, then the socket is destroyed when the peer's FIN arrives
	// or after the drain time.
	function closeTcp()
	{
		if (tcpClosing || gone) return;
		tcpClosing = true;
		try
		{
			socket.end();
		}
		catch (e) { /* destroyed */ }
		socket.resume();   // discard input until the peer's FIN
		drainTimer = _WebSocket_unref(setTimeout(function()
		{
			if (!socket.destroyed) socket.destroy();
		}, _WebSocket_kDrainMs));
	}

	// --- failing and ending

	function failConnection(code, text)
	{
		var reason = code === 1007 ? 'ERR_WS_INVALID_DATA: ' + text
			: code === 1009 ? 'ERR_WS_MESSAGE_TOO_BIG'
			: code === 1011 ? 'ERR_WS_INTERNAL_ERROR: ' + text
			: 'ERR_WS_PROTOCOL: ' + text;
		failWith(code, text, code, text, _WebSocket_error(reason, code === 1009 ? 'EMSGSIZE' : 'EPROTO'));
	}

	function failWith(frameCode, frameText, infoCode, infoReason, readErr)
	{
		if (failed || closedPosted) return;
		failed = true;
		inputDone = true;
		decoder.stop();
		setInfo(infoCode, _WebSocket_truncate(Buffer.from(infoReason, 'utf8'), 123).toString('utf8'), false);
		if (body && !body.messageDone) bodyFail(readErr);
		abandonRx();
		endReadable({ err: readErr });
		writeClosed = true;
		failQueued(_WebSocket_kSocketClosed);
		if (!closeWritten)
		{
			closeQueued = true;
			writeRaw(frameOf(true, 8, _WebSocket_closePayload(frameCode, frameText)), closeFrameWritten);
		}
		postClosed();
		closeTcp();
	}

	function ended(err)
	{
		setInfo(1006, '', false);
		if (body && !body.messageDone) bodyFail(err);
		if (rx) abandonRx();
		endReadable({ err: err });
		writeClosed = true;
		failQueued(_WebSocket_kSocketClosed);
		if (!closeWritten && (closeOps.length || closeWaiters.length))
		{
			closeWritten = true;
			var ops = closeOps;
			closeOps = [];
			for (var i = 0; i < ops.length; i++) ops[i]();
			var ws = closeWaiters;
			closeWaiters = [];
			for (var j = 0; j < ws.length; j++) ws[j](_WebSocket_error(_WebSocket_kSocketClosed, 'ECANCELED'));
		}
		postClosed();
	}

	function setInfo(code, reason, clean)
	{
		if (info) return;
		info = { code: code, reason: reason, clean: clean };
	}

	function postClosed()
	{
		if (closedPosted) return;
		closedPosted = true;
		setInfo(1006, '', false);
		var ps = pings;
		pings = [];
		for (var i = 0; i < ps.length; i++)
		{
			self.hold(-1);
			ps[i].done(__Utils_Tuple2('ECANCELED', 'ping ECANCELED: the WebSocket closed'), 0);
		}
		clearTimeout(hbTimer);
		clearTimeout(pongTimer);
		hbPingSent = false;
		if (closeHold)
		{
			closeHold = false;
			self.hold(-1);
		}
		onClosed(info);
	}

	// --- ping / heartbeat

	function armHeartbeat(at)
	{
		if (!(cfg.hbInterval > 0) || gone) return;
		clearTimeout(hbTimer);
		hbTimer = _WebSocket_unref(setTimeout(onHeartbeat, Math.max(0, at - Date.now())));
	}

	function armPongTimer()
	{
		clearTimeout(pongTimer);
		if (gone || paused) return;
		var earliest = hbPingSent ? hbDeadline : 0;
		for (var i = 0; i < pings.length; i++)
		{
			if (pings[i].deadline > 0 && (earliest === 0 || pings[i].deadline < earliest)) earliest = pings[i].deadline;
		}
		if (earliest > 0) pongTimer = _WebSocket_unref(setTimeout(onPongTimer, Math.max(0, earliest - Date.now())));
	}

	function payloadOf(n, heartbeat)
	{
		var b = Buffer.alloc(8);
		b.writeUInt32BE(Math.floor(n / 4294967296) & 0x7FFFFFFF, 0);
		b.writeUInt32BE(n >>> 0, 4);
		if (heartbeat) b[0] |= 0x80;
		return b;
	}

	function onHeartbeat()
	{
		if (!(cfg.hbInterval > 0) || closeQueued || closeReceived || failed || paused || hbPingSent || gone) return;
		var now = Date.now();
		if (now - lastRx < cfg.hbInterval)
		{
			armHeartbeat(lastRx + cfg.hbInterval);
			return;
		}
		hbPingSent = true;
		rxAtPing = rxBytes;
		hbDeadline = now + (cfg.hbTimeout > 0 ? cfg.hbTimeout : _WebSocket_kPingTimeoutMs);
		armPongTimer();
		writeRaw(frameOf(true, 9, payloadOf(++pingCounter, true)), null);
	}

	function onPongTimer()
	{
		if (paused || gone) return;
		var now = Date.now();
		var keep = [];
		for (var i = 0; i < pings.length; i++)
		{
			var p = pings[i];
			if (p.deadline > 0 && p.deadline <= now)
			{
				self.hold(-1);
				p.done(__Utils_Tuple2('ETIMEDOUT', 'ping ETIMEDOUT'), 0);
			}
			else
			{
				keep.push(p);
			}
		}
		pings = keep;
		if (hbPingSent && hbDeadline > 0 && hbDeadline <= now)
		{
			if (rxBytes > rxAtPing)
			{
				hbPingSent = false;
				hbDeadline = 0;
				armHeartbeat(Math.max(now, lastRx + cfg.hbInterval));
			}
			else
			{
				// W5: Close 1001 best effort, reported Abnormal.
				failWith(1001, '', 1006, '', _WebSocket_error('heartbeat ETIMEDOUT', 'ETIMEDOUT'));
				return;
			}
		}
		armPongTimer();
	}

	// --- kernels

	// done(errTuple or null, rtt)
	self.ping = function(done)
	{
		if (closeQueued || closedPosted || gone || failed)
		{
			done(__Utils_Tuple2('ECANCELED', 'ping ECANCELED: the WebSocket is closing'), 0);
			return;
		}
		var now = Date.now();
		var t = cfg.hbTimeout > 0 ? cfg.hbTimeout : _WebSocket_kPingTimeoutMs;
		var p = { payload: payloadOf(++pingCounter, false), done: done, sent: now, deadline: paused ? 0 : now + t };
		pings.push(p);
		self.hold(1);
		armPongTimer();
		writeRaw(frameOf(true, 9, p.payload), null);
	};

	self.close = function(code, reason, done)
	{
		if (closeWritten || closedPosted || gone)
		{
			done();
			return;
		}
		closeOps.push(done);
		queueGracefulClose(code, reason);
	};

	self.abort = function()
	{
		if (!socket.destroyed) socket.destroy();
	};

	self.closed = function() { return closedPosted; };

	// Starts reading: `leftover` (bytes read past the handshake) first.
	self.start = function(leftover)
	{
		socket.on('data', onSocketData);
		socket.on('end', onSocketEnd);
		socket.on('error', onSocketError);
		socket.on('close', onSocketClose);
		socket.on('drain', pump);
		updateRef();
		if (cfg.hbInterval > 0) armHeartbeat(Date.now() + cfg.hbInterval);
		if (leftover && leftover.length) onSocketData(leftover);
		if (socket.destroyed)
		{
			onSocketClose();
			return;
		}
		if (!paused) socket.resume();
	};

	return self;
}


// --- Tables -----------------------------------------------------------------------------

// hsId → { socket, raw, isUnix, leftover, local, remote, cleanup }
var _WebSocket_hs = {};
// wsId → { codec, readableId, writableId, closed, info, held, closeListener, closedWaiters }
var _WebSocket_ws = {};
var _WebSocket_nextId = 1;
var _WebSocket_nextWsId = 1;

// Parks a handshaken socket (paused, unref'd) until open / reject / abandon.
function _WebSocket_park(socket, raw, isUnix, leftover)
{
	var h = {
		socket: socket,
		raw: raw,
		isUnix: isUnix,
		leftover: leftover,
		local: _WebSocket_endpoint(raw, isUnix, true),
		remote: _WebSocket_endpoint(raw, isUnix, false),
		gone: false
	};
	h.onError = function() { /* reported when the codec starts (the socket is destroyed) */ };
	h.onClose = function() { h.gone = true; };
	socket.on('error', h.onError);
	socket.on('close', h.onClose);
	socket.pause();
	try { socket.unref(); } catch (e) { /* destroyed */ }
	var id = _WebSocket_nextId++;
	_WebSocket_hs[id] = h;
	return id;
}

// Http.Server.upgradeRequest (HttpServer.js takeUpgrade, phase WS5): parks the socket of an
// HTTP/1.1 upgrade request that node:http handed over ('upgrade'), with the bytes read past
// the request (`head`), as a handshake id for open / reject / abandon. `rawHeaders` is
// node's flat [ name, value, ... ] list. Returns readUpgrade's result shape
// ( id, ( method, target, version ), ( headers, isH2 = False, remote ) ).
function _WebSocket_parkUpgrade(socket, raw, head, method, target, version, rawHeaders)
{
	var fields = [];
	for (var i = 0; i + 1 < rawHeaders.length; i += 2)
	{
		fields.push([rawHeaders[i], rawHeaders[i + 1]]);
	}
	var id = _WebSocket_park(socket, raw, false, Buffer.from(head || Buffer.alloc(0)));
	return __Utils_Tuple3(
		id,
		__Utils_Tuple3(method, target, version),
		__Utils_Tuple3(_WebSocket_headerList(fields), false, _WebSocket_hs[id].remote)
	);
}

// The face of an Http2Stream the codec expects of a socket (WS9): END_STREAM for end(),
// RST_STREAM(CANCEL) for destroy(). `client`: the stream owns its session (one WebSocket per
// client session, W12): ref/unref go to the session, which is closed (GOAWAY) when the stream
// is. A server stream lives in Http.Server's session: ref/unref do nothing.
function _WebSocket_h2Duplex(stream, session, client)
{
	var http2 = require('http2');
	var aborted = false;
	var d = {
		__h2: stream,
		on: function(ev, fn) { stream.on(ev, fn); return d; },
		once: function(ev, fn) { stream.once(ev, fn); return d; },
		removeListener: function(ev, fn) { stream.removeListener(ev, fn); return d; },
		pause: function() { stream.pause(); return d; },
		resume: function() { stream.resume(); return d; },
		write: function(buf, cb) { return stream.write(buf, cb); },
		end: function(buf, cb)
		{
			if (typeof buf === 'function') stream.end(buf);
			else if (buf !== undefined) stream.end(buf, cb);
			else stream.end();
			return d;
		},
		destroy: function()
		{
			if (aborted) return d;
			aborted = true;
			try
			{
				if (!stream.destroyed) stream.close(http2.constants.NGHTTP2_CANCEL);
			}
			catch (e)
			{
				stream.destroy();
			}
			return d;
		},
		ref: function() { if (client) session.ref(); return d; },
		unref: function() { if (client) session.unref(); return d; }
	};
	Object.defineProperty(d, 'destroyed', { get: function() { return aborted || stream.destroyed; } });
	Object.defineProperty(d, 'writableEnded', { get: function() { return stream.writableEnded; } });
	Object.defineProperty(d, 'writableLength', { get: function() { return stream.writableLength; } });
	if (client)
	{
		stream.once('close', function()
		{
			try { session.close(); } catch (e) { /* gone */ }
		});
	}
	return d;
}

// The fields of an HTTP/2 answer from the Elm header list: names lower-cased, connection-specific
// fields dropped (RFC 9113 §8.2.2), repeated names kept as arrays.
function _WebSocket_h2Fields(pairs, status)
{
	var out = { ':status': status };
	for (var i = 0; i < pairs.length; i++)
	{
		var name = String(pairs[i][0]).toLowerCase();
		var value = pairs[i][1];
		if (name === '' || name.charAt(0) === ':' || name === 'connection' || name === 'keep-alive'
			|| name === 'proxy-connection' || name === 'transfer-encoding' || name === 'upgrade'
			|| name === 'content-length' || name === 'te')
		{
			continue;
		}
		if (!_WebSocket_headerValid(name, value)) continue;
		if (out[name] === undefined) out[name] = value;
		else if (Array.isArray(out[name])) out[name].push(value);
		else out[name] = [out[name], value];
	}
	return out;
}

// Http.Server.upgradeRequest of an HTTP/2 extended CONNECT (HttpServer.js takeUpgrade, WS9):
// parks the (paused) stream as a handshake id. `fields`: the flat [ name, value, ... ] list
// without pseudo fields. Returns ( id, ( method, target, "2" ), ( headers, isH2 = True, remote ) ).
function _WebSocket_parkH2Upgrade(stream, method, target, fields)
{
	var pairs = [];
	for (var i = 0; i + 1 < fields.length; i += 2)
	{
		pairs.push([fields[i], fields[i + 1]]);
	}
	var session = stream.session;
	var duplex = _WebSocket_h2Duplex(stream, session, false);
	var id = _WebSocket_park(duplex, session.socket, false, Buffer.alloc(0));
	_WebSocket_hs[id].h2 = stream;
	return __Utils_Tuple3(
		id,
		__Utils_Tuple3(method, target, '2'),
		__Utils_Tuple3(_WebSocket_headerList(pairs), true, _WebSocket_hs[id].remote)
	);
}

function _WebSocket_unpark(id)
{
	var h = _WebSocket_hs[id];
	if (!h) return null;
	delete _WebSocket_hs[id];
	h.socket.removeListener('error', h.onError);
	h.socket.removeListener('close', h.onClose);
	return h;
}

// Reads an HTTP head from `socket` (paused), starting with `initial`; then calls
// done(null, headText, leftover) or done({ code, message }).
function _WebSocket_readHead(socket, initial, timeoutMs, timeoutMessage, done)
{
	var buf = initial || Buffer.alloc(0);
	var settled = false;
	var timer = null;

	function finish(err, head, rest)
	{
		if (settled) return;
		settled = true;
		clearTimeout(timer);
		socket.removeListener('data', onData);
		socket.removeListener('end', onEnd);
		socket.removeListener('error', onError);
		socket.removeListener('close', onClose);
		socket.pause();
		done(err, head, rest);
	}

	function check()
	{
		var n = _WebSocket_headLength(buf);
		if (n === 0)
		{
			if (buf.length > _WebSocket_kMaxHead) finish({ code: 'ERR_WS_HANDSHAKE', message: 'the head is larger than 64 KiB', tooLarge: true });
			return;
		}
		if (n > _WebSocket_kMaxHead)
		{
			finish({ code: 'ERR_WS_HANDSHAKE', message: 'the head is larger than 64 KiB', tooLarge: true });
			return;
		}
		finish(null, buf.subarray(0, n).toString('utf8'), buf.subarray(n));
	}

	function onData(chunk)
	{
		buf = buf.length ? Buffer.concat([buf, chunk]) : chunk;
		check();
	}

	function onEnd()
	{
		finish({ code: 'ERR_WS_HANDSHAKE', message: 'the connection closed during the opening handshake', eof: true });
	}

	function onError(e)
	{
		var code = _WebSocket_codeOf(e);
		finish({ code: code, message: 'read ' + code });
	}

	function onClose()
	{
		finish({ code: 'ECANCELED', message: _WebSocket_kSocketClosed });
	}

	socket.on('data', onData);
	socket.on('end', onEnd);
	socket.on('error', onError);
	socket.on('close', onClose);
	if (timeoutMs > 0)
	{
		timer = setTimeout(function()
		{
			finish({ code: 'ETIMEDOUT', message: timeoutMessage, timeout: true });
		}, timeoutMs);
	}
	check();
	if (!settled) socket.resume();
	return function() { finish({ code: 'ECANCELED', message: _WebSocket_kSocketClosed, killed: true }); };
}


// --- B.1 -------------------------------------------------------------------------------

// handshakeKey : Task Never ( String, String )
var _WebSocket_handshakeKey = __Scheduler_binding(function(callback)
{
	var key = require('crypto').randomBytes(16).toString('base64');
	callback(__Scheduler_succeed(__Utils_Tuple2(key, _WebSocket_acceptOf(key))));
});

// acceptFor : String -> String (pure)
var _WebSocket_acceptFor = function(key)
{
	return _WebSocket_acceptOf(key);
};

// dial : ( List String, Int, Int ) -> ( ( Bool, String ), ( Int, String ), ( Bool, Bool ) )
//     -> ( String, List ( String, String ) ) -> Task FErr ( Int, ( Int, Bool ), List ( String, List String ) )
var _WebSocket_dial = F3(function(target, tlsArgs, request)
{
	return __Scheduler_binding(function(callback)
	{
		var addresses = __List_toArray(target.a);
		var port = target.b;
		var timeoutMs = target.c;
		var secure = tlsArgs.a.a;
		var serverName = tlsArgs.a.b;
		var mode = tlsArgs.b.a;
		var pem = tlsArgs.b.b;
		var requestPairs = _WebSocket_pairs(request.b);
		var requestBytes = Buffer.from('GET ' + request.a + ' HTTP/1.1\r\n'
			+ _WebSocket_headerText(requestPairs, false) + '\r\n', 'utf8');
		// WS9: RFC 8441 first (wss only); dropped for the redial over HTTP/1.1.
		var http2Now = secure && tlsArgs.c.a;
		if (!addresses.length)
		{
			callback(_WebSocket_ferr('ENOTFOUND', 'connect ENOTFOUND'));
			return;
		}
		var ca = null;
		if (secure && mode === 1)
		{
			ca = __Tls_pemCertificates(pem);
			if (!ca.length)
			{
				callback(_WebSocket_ferr('ERR_SSL_NO_CERTIFICATES', 'trusted certificates: no certificate found'));
				return;
			}
		}
		else if (secure && mode !== 2)
		{
			ca = __Tls_systemCertificates();
		}

		__Stream_noteActivity();
		var net = require('net');
		var settled = false;
		var timer = null;
		var idx = 0;
		var lastCode = 'ENOTFOUND', lastMessage = 'connect ENOTFOUND';
		var raw = null, sock = null, stopHead = null, h2Session = null;

		function what()
		{
			var a = addresses[Math.max(0, idx - 1)];
			return (a.indexOf(':') >= 0 ? '[' + a + ']' : a) + ':' + port;
		}

		function destroyCurrent()
		{
			if (stopHead) stopHead();
			if (h2Session && !h2Session.destroyed) h2Session.destroy();
			if (sock && !sock.destroyed) sock.destroy();
			if (raw && !raw.destroyed) raw.destroy();
		}

		function fail(code, message)
		{
			if (settled) return;
			settled = true;
			clearTimeout(timer);
			destroyCurrent();
			callback(_WebSocket_ferr(code, message));
		}

		function tryNext()
		{
			if (settled) return;
			if (idx >= addresses.length)
			{
				fail(lastCode, lastMessage);
				return;
			}
			var address = addresses[idx++];
			var mine = new net.Socket({ allowHalfOpen: true });
			raw = mine;
			sock = null;
			mine.pause();
			var connecting = true;
			function attemptFailed(code, message)
			{
				if (settled || raw !== mine) return;
				lastCode = code;
				lastMessage = message;
				if (sock && !sock.destroyed) sock.destroy();
				if (!mine.destroyed) mine.destroy();
				tryNext();
			}
			mine.on('error', function(e)
			{
				if (connecting)
				{
					var code = _WebSocket_codeOf(e);
					attemptFailed(code, 'connect ' + code + ' ' + what());
				}
			});
			mine.once('connect', function()
			{
				if (settled || raw !== mine) return;
				if (!secure)
				{
					connecting = false;
					exchange(mine, mine);
					return;
				}
				var options = { socket: mine, rejectUnauthorized: mode !== 2,
					ALPNProtocols: http2Now ? ['h2', 'http/1.1'] : ['http/1.1'] };
				if (ca) options.ca = ca;
				if (net.isIP(serverName)) options.host = serverName;
				else if (serverName !== '') options.servername = serverName;
				else options.checkServerIdentity = function() { return undefined; };
				var t;
				try
				{
					t = require('tls').connect(options);
				}
				catch (e)
				{
					attemptFailed(__Tls_code(e, null), __Tls_errorMessage(e));
					return;
				}
				sock = t;
				t.on('error', function(e)
				{
					if (connecting) attemptFailed(__Tls_code(e, t), __Tls_errorMessage(e));
				});
				t.once('secureConnect', function()
				{
					if (settled || raw !== mine) return;
					t.write(Buffer.alloc(0), function(e)
					{
						if (e)
						{
							if (connecting) attemptFailed(__Tls_code(e, t), __Tls_errorMessage(e));
							return;
						}
						connecting = false;
						if (http2Now && t.alpnProtocol === 'h2') h2Exchange(t, mine);
						else exchange(t, mine);
					});
				});
			});
			try
			{
				mine.connect({ host: address, port: port });
			}
			catch (e)
			{
				var code = _WebSocket_codeOf(e);
				attemptFailed(code, 'connect ' + code + ' ' + what());
			}
		}

		// The HTTP exchange on a connected socket.
		function exchange(s, r)
		{
			s.on('error', function() { /* reported by readHead */ });
			s.write(requestBytes);
			stopHead = _WebSocket_readHead(s, null, 0, '', function(err, head, rest)
			{
				stopHead = null;
				if (settled) return;
				if (err)
				{
					fail(err.code, err.eof
						? 'the server closed the connection during the opening handshake'
						: (err.tooLarge ? 'the response head is larger than 64 KiB'
						: (err.code === 'ECANCELED' ? 'connect ECANCELED ' + what() : err.message + ' ' + what())));
					return;
				}
				var parsed = _WebSocket_parseResponseHead(head);
				if (parsed.error)
				{
					fail('ERR_WS_HANDSHAKE', 'invalid HTTP response: ' + parsed.error);
					return;
				}
				settled = true;
				clearTimeout(timer);
				var id = _WebSocket_park(s, r, false, Buffer.from(rest));
				callback(__Scheduler_succeed(__Utils_Tuple3(
					id,
					__Utils_Tuple2(parsed.status, false),
					_WebSocket_headerList(parsed.headers)
				)));
			});
		}

		// WS9: the extended CONNECT on an h2 connection (Http2Client.cpp's twin).
		function h2Exchange(t, r)
		{
			var http2 = require('http2');
			var session;
			try
			{
				session = http2.connect('https://' + (serverName || 'localhost'), {
					createConnection: function() { return t; },
					settings: { enablePush: false, initialWindowSize: 64 * 1024 }
				});
			}
			catch (e)
			{
				fail('ERR_WS_HANDSHAKE', 'HTTP/2: ' + e.message);
				return;
			}
			h2Session = session;
			session.on('error', function(e)
			{
				if (h2Session === session) fail(_WebSocket_codeOf(e), 'HTTP/2 ' + _WebSocket_codeOf(e) + ' ' + what());
			});
			session.once('close', function()
			{
				if (h2Session === session) fail('ERR_WS_HANDSHAKE', 'the server closed the HTTP/2 session during the opening handshake');
			});
			session.once('remoteSettings', function(settings)
			{
				if (settled || h2Session !== session) return;
				if (!settings.enableConnectProtocol)
				{
					// No RFC 8441 there: GOAWAY, and the same address again over HTTP/1.1.
					h2Session = null;
					try { session.close(); } catch (e) { /* gone */ }
					http2Now = false;
					idx = Math.max(0, idx - 1);
					tryNext();
					return;
				}
				var authority = '';
				var fields = { ':method': 'CONNECT', ':protocol': 'websocket', ':scheme': 'https', ':path': request.a };
				for (var i = 0; i < requestPairs.length; i++)
				{
					var name = String(requestPairs[i][0]).toLowerCase();
					var value = requestPairs[i][1];
					if (name === 'host')
					{
						authority = value;
						continue;
					}
					if (name === 'upgrade' || name === 'connection' || name === 'sec-websocket-key' || name === 'keep-alive'
						|| name === 'proxy-connection' || name === 'transfer-encoding' || name === 'te' || name.charAt(0) === ':')
					{
						continue;
					}
					if (fields[name] === undefined) fields[name] = value;
					else if (Array.isArray(fields[name])) fields[name].push(value);
					else fields[name] = [fields[name], value];
				}
				fields[':authority'] = authority;
				var req;
				try
				{
					req = session.request(fields, { endStream: false });
				}
				catch (e)
				{
					fail('ERR_WS_HANDSHAKE', 'extended CONNECT refused: ' + e.message);
					return;
				}
				req.pause();   // DATA waits for open
				req.on('error', function() { /* reported by 'close' (before the answer) or the codec */ });
				req.once('close', function()
				{
					if (!settled) fail('ERR_WS_HANDSHAKE', 'the server reset the opening stream');
				});
				req.once('response', function(headers)
				{
					if (settled) return;
					settled = true;
					clearTimeout(timer);
					h2Session = null;
					var status = Number(headers[':status']) || 0;
					var pairs = [];
					for (var k in headers)
					{
						if (k.charAt(0) === ':') continue;
						var v = headers[k];
						if (Array.isArray(v)) for (var j = 0; j < v.length; j++) pairs.push([k, String(v[j])]);
						else pairs.push([k, String(v)]);
					}
					var duplex = _WebSocket_h2Duplex(req, session, true);
					var id = _WebSocket_park(duplex, r, false, Buffer.alloc(0));
					_WebSocket_hs[id].h2 = req;
					callback(__Scheduler_succeed(__Utils_Tuple3(
						id,
						__Utils_Tuple2(status, true),
						_WebSocket_headerList(pairs)
					)));
				});
			});
		}

		if (timeoutMs > 0)
		{
			timer = setTimeout(function()
			{
				fail('ETIMEDOUT', 'WebSocket handshake ETIMEDOUT ' + what());
			}, timeoutMs);
		}
		tryNext();
		return function()
		{
			// Process.kill: abort the attempt; the task never completes.
			if (settled) return;
			settled = true;
			clearTimeout(timer);
			destroyCurrent();
		};
	});
});

// readUpgrade : Int -> Int -> Task FErr ( Int, ( String, String, String ), ( List ( String, List String ), Bool, EpT ) )
var _WebSocket_readUpgrade = F2(function(connId, timeoutMs)
{
	return __Scheduler_binding(function(callback)
	{
		var d = __Socket_detach(connId, 'upgraded to WebSocket');
		if (d.error)
		{
			callback(_WebSocket_ferr(d.error, d.message));
			return;
		}
		__Stream_noteActivity();
		var socket = d.socket;
		var raw = d.raw;
		try { socket.ref(); } catch (e) { /* destroyed */ }
		if (d.eof)
		{
			socket.destroy();
			callback(_WebSocket_ferr('ERR_WS_HANDSHAKE', 'the client closed the connection before sending an opening request'));
			return;
		}
		var stop = _WebSocket_readHead(socket, d.buffered, timeoutMs, 'upgradeRequest ETIMEDOUT', function(err, head, rest)
		{
			if (err)
			{
				if (err.killed)
				{
					if (!socket.destroyed) socket.destroy();
					return;
				}
				if (err.tooLarge)
				{
					answer400();
					callback(_WebSocket_ferr('ERR_WS_HANDSHAKE', 'the request head is larger than 64 KiB'));
					return;
				}
				if (!socket.destroyed) socket.destroy();
				callback(_WebSocket_ferr(err.code, err.eof
					? 'the client closed the connection before sending an opening request'
					: err.message));
				return;
			}
			var parsed = _WebSocket_parseRequestHead(head);
			if (parsed.error)
			{
				answer400();
				callback(_WebSocket_ferr('ERR_WS_HANDSHAKE', 'invalid HTTP request: ' + parsed.error));
				return;
			}
			var id = _WebSocket_park(socket, raw, d.isUnix, Buffer.from(rest));
			var h = _WebSocket_hs[id];
			callback(__Scheduler_succeed(__Utils_Tuple3(
				id,
				__Utils_Tuple3(parsed.method, parsed.target, parsed.version),
				__Utils_Tuple3(_WebSocket_headerList(parsed.headers), false, h.remote)
			)));
		});

		function answer400()
		{
			socket.on('error', function() {});
			try
			{
				socket.end(_WebSocket_serializeResponse(400, [], true, ''));
			}
			catch (e) { /* destroyed */ }
			_WebSocket_unref(setTimeout(function() { if (!socket.destroyed) socket.destroy(); }, _WebSocket_kDrainMs));
			socket.resume();
		}

		return stop;
	});
});

// open : Int -> ( Int, List ( String, String ) ) -> ( ... ) -> (( Int, String, Bytes ) -> a)
//     -> (b -> ( Int, String, Bytes )) -> Task FErr ( Int, ( Int, Int ), ( EpT, EpT ) )
var _WebSocket_open = F5(function(id, response, params, fromWire, toWire)
{
	return __Scheduler_binding(function(callback)
	{
		if (!_WebSocket_hs[id])
		{
			callback(_WebSocket_ferr('EINVAL', 'open EINVAL: the handshake was answered already'));
			return;
		}
		var role = params.a.a, mode = params.a.b, maxMessage = params.a.c;
		if (mode !== 1 && mode !== 2)
		{
			callback(_WebSocket_ferr('EINVAL', 'open EINVAL: unknown mode'));
			return;
		}
		// ( threshold (-1: no deflate), ( ourNoContext, ourBits ), ( peerNoContext, peerBits ) )
		var threshold = params.c.a;
		var bitsOf = function(b) { return b >= 8 && b <= 15 ? b : 15; };
		var h = _WebSocket_unpark(id);
		if (h.gone || h.socket.destroyed)
		{
			callback(_WebSocket_ferr('ECONNRESET', _WebSocket_kSocketClosed));
			return;
		}
		__Stream_noteActivity();
		try
		{
			if (!h.isUnix && h.raw.setNoDelay) h.raw.setNoDelay(true);   // pongs and pings go out at once
		}
		catch (e) { /* destroyed */ }
		if (role === 1 && h.h2)
		{
			// WS9: :status 200 without END_STREAM; the stream carries the frames.
			try
			{
				h.h2.respond(_WebSocket_h2Fields(_WebSocket_pairs(response.b), response.a), { endStream: false });
			}
			catch (e)
			{
				h.socket.destroy();
				callback(_WebSocket_ferr('ECONNRESET', _WebSocket_kSocketClosed));
				return;
			}
		}
		else if (role === 1)
		{
			h.socket.write(_WebSocket_serializeResponse(response.a, _WebSocket_pairs(response.b), false, ''));
		}
		var wsId = _WebSocket_nextWsId++;
		var W = {
			codec: null,
			readableId: 0,
			writableId: 0,
			closed: false,
			info: null,
			held: null,
			closeListener: null,
			closedWaiters: []
		};
		_WebSocket_ws[wsId] = W;
		W.codec = _WebSocket_codec(h.socket, {
			server: role === 1,
			maxMessage: maxMessage > 0 ? maxMessage : 0,
			hbInterval: params.b.a > 0 ? params.b.a : 0,
			hbTimeout: params.b.b > 0 ? params.b.b : 0,
			closeTimeout: params.b.c > 0 ? params.b.c : 30000,
			streamed: mode === 2,
			threshold: threshold >= 0 ? threshold : -1,
			ourNoContext: params.c.b.a,
			ourBits: bitsOf(params.c.b.b),
			peerNoContext: params.c.c.a,
			peerBits: bitsOf(params.c.c.b)
		}, function(info) { _WebSocket_onClosed(wsId, info); });
		W.readableId = __Stream_createMappedSource(W.codec.readChannel, fromWire);
		W.writableId = __Stream_createMappedSink(W.codec.writeChannel, toWire);
		W.codec.start(h.leftover);
		callback(__Scheduler_succeed(__Utils_Tuple3(
			wsId,
			__Utils_Tuple2(W.readableId, W.writableId),
			__Utils_Tuple2(h.local, h.remote)
		)));
	});
});

function _WebSocket_onClosed(wsId, info)
{
	var W = _WebSocket_ws[wsId];
	if (!W || W.closed) return;
	W.closed = true;
	W.info = info;
	var waiters = W.closedWaiters;
	W.closedWaiters = [];
	for (var i = 0; i < waiters.length; i++) waiters[i](info);
	if (W.closeListener)
	{
		W.closeListener(info);
	}
	else
	{
		W.held = info;
	}
}

function _WebSocket_infoTuple(info)
{
	return __Utils_Tuple3(info.code, info.reason, info.clean);
}

// reject : Int -> ( Int, List ( String, String ), String ) -> Task Never ()
var _WebSocket_reject = F2(function(id, response)
{
	return __Scheduler_binding(function(callback)
	{
		var h = _WebSocket_unpark(id);
		if (!h || h.gone || h.socket.destroyed)
		{
			callback(_WebSocket_done());
			return;
		}
		var socket = h.socket;
		var status = response.a >= 100 && response.a <= 999 ? response.a : 400;
		if (h.h2)
		{
			// WS9: an ordinary HTTP/2 answer, then RST_STREAM(NO_ERROR) (the request side is
			// still open, RFC 9113 §8.1), as Http.Server answers a CONNECT it keeps.
			var stream = h.h2;
			var http2 = require('http2');
			var finished = false;
			var finish = function()
			{
				if (finished) return;
				finished = true;
				try { if (!stream.destroyed) stream.close(http2.constants.NGHTTP2_NO_ERROR); } catch (e) { /* gone */ }
				callback(_WebSocket_done());
			};
			stream.on('error', function() {});
			stream.once('close', finish);
			try
			{
				var fields = _WebSocket_h2Fields(_WebSocket_pairs(response.b), status < 200 ? 500 : status);
				var body = Buffer.from(response.c, 'utf8');
				var noBody = status === 204 || status === 304;
				if (!noBody) fields['content-length'] = String(body.length);
				stream.respond(fields, { endStream: noBody || body.length === 0 });
				if (noBody || body.length === 0) setImmediate(finish);
				else stream.end(body, finish);
			}
			catch (e)
			{
				finish();
			}
			return;
		}
		socket.on('error', function() {});
		try { socket.ref(); } catch (e) { /* destroyed */ }
		var timer = _WebSocket_unref(setTimeout(function() { if (!socket.destroyed) socket.destroy(); }, _WebSocket_kDrainMs));
		socket.once('close', function() { clearTimeout(timer); });
		socket.end(_WebSocket_serializeResponse(status, _WebSocket_pairs(response.b), true, response.c), function()
		{
			try { socket.unref(); } catch (e) { /* destroyed */ }
			callback(_WebSocket_done());
		});
		socket.resume();   // discard input until the peer's FIN
	});
});

// abandon : Int -> Task Never ()
var _WebSocket_abandon = function(id)
{
	return __Scheduler_binding(function(callback)
	{
		var h = _WebSocket_unpark(id);
		if (h && !h.socket.destroyed) h.socket.destroy();
		callback(_WebSocket_done());
	});
};

// close : Int -> Int -> String -> Task Never ()
var _WebSocket_close = F3(function(wsId, code, reason)
{
	return __Scheduler_binding(function(callback)
	{
		var W = _WebSocket_ws[wsId];
		if (!W || W.closed)
		{
			callback(_WebSocket_done());
			return;
		}
		W.codec.close(code, reason, function() { callback(_WebSocket_done()); });
	});
});

// closed : Int -> Task Never ( Int, String, Bool )
var _WebSocket_closed = function(wsId)
{
	return __Scheduler_binding(function(callback)
	{
		var W = _WebSocket_ws[wsId];
		if (!W || W.closed)
		{
			var info = W ? W.info : { code: 1006, reason: '', clean: false };
			callback(__Scheduler_succeed(_WebSocket_infoTuple(info)));
			return;
		}
		var codec = W.codec;
		codec.hold(1);   // a parked `closed` keeps the program alive (§3.6)
		var waiter = function(info)
		{
			codec.hold(-1);
			callback(__Scheduler_succeed(_WebSocket_infoTuple(info)));
		};
		W.closedWaiters.push(waiter);
		return function()
		{
			var i = W.closedWaiters.indexOf(waiter);
			if (i >= 0)
			{
				W.closedWaiters.splice(i, 1);
				codec.hold(-1);
			}
		};
	});
};

// ping : Int -> Task FErr Int
var _WebSocket_ping = function(wsId)
{
	return __Scheduler_binding(function(callback)
	{
		var W = _WebSocket_ws[wsId];
		if (!W || W.closed)
		{
			callback(_WebSocket_ferr('ECANCELED', 'ping ECANCELED: the WebSocket is closed'));
			return;
		}
		W.codec.ping(function(err, rtt)
		{
			callback(err ? __Scheduler_fail(err) : __Scheduler_succeed(rtt));
		});
	});
};

// openOutgoing : Int -> Int -> Task FErr Int  (streamed send: WS6)
// A writable for one message sent as a stream (kind 1 text: a writable of Strings; 2 binary);
// its place among the outgoing messages is taken at once.
var _WebSocket_openOutgoing = F2(function(wsId, kind)
{
	return __Scheduler_binding(function(callback)
	{
		var W = _WebSocket_ws[wsId];
		if (!W || W.closed)
		{
			callback(_WebSocket_ferr('ECANCELED', _WebSocket_kSocketClosed));
			return;
		}
		var channel = W.codec.openOutgoing(kind === 1 ? 1 : 2);
		var id = kind === 1 ? __Stream_createTextChannelSink(channel) : __Stream_createChannelSink(channel);
		callback(__Scheduler_succeed(id));
	});
});


// --- JS-only: the listeners of the Elm WebSocket manager ---------------------------------

// attachMessageListener : Int -> (( Int, String, Bytes ) -> Task Never ()) -> Task Never ()
// A binding that never completes: while it runs, a subscription reader on the readable hands
// every message to `toTask` (attached as soon as no read is parked: retried meanwhile).
// Killing its process detaches it; later messages wait on the readable again.
var _WebSocket_attachMessageListener = F2(function(wsId, toTask)
{
	return __Scheduler_binding(function(callback)
	{
		var W = _WebSocket_ws[wsId];
		if (!W)
		{
			return;
		}
		var killed = false, attached = false, timer = null, holding = false;
		var reader = function(err, chunk)
		{
			if (killed || !chunk) return;
			__Scheduler_rawSpawn(toTask(__Utils_Tuple3(
				chunk.tag,
				typeof chunk.text === 'string' ? chunk.text : '',
				__Stream_toBytes(chunk.bytes || new Uint8Array(0))
			)));
		};
		function tryAttach()
		{
			timer = null;
			if (killed) return;
			if (__Stream_attachReader(W.readableId, reader))
			{
				attached = true;
				return;
			}
			timer = _WebSocket_unref(setTimeout(tryAttach, 5));
		}
		if (!W.closed)
		{
			holding = true;
			W.codec.hold(1);   // an open connection with a subscription keeps the program alive
		}
		tryAttach();
		return function()
		{
			killed = true;
			clearTimeout(timer);
			if (attached) __Stream_detachReader(W.readableId);
			if (holding) W.codec.hold(-1);
		};
	});
});

// attachCloseListener : Int -> (( Int, String, Bool ) -> Task Never ()) -> Task Never ()
// A binding that never completes: the CloseInfo goes to `toTask` once (at once if it is
// held: the connection closed with no subscriber).
var _WebSocket_attachCloseListener = F2(function(wsId, toTask)
{
	return __Scheduler_binding(function(callback)
	{
		var W = _WebSocket_ws[wsId];
		if (!W)
		{
			return;
		}
		var holding = false;
		var listener = function(info)
		{
			if (holding)
			{
				holding = false;
				W.codec.hold(-1);
			}
			__Scheduler_rawSpawn(toTask(_WebSocket_infoTuple(info)));
		};
		if (W.held)
		{
			var info = W.held;
			W.held = null;
			listener(info);
		}
		else if (!W.closed)
		{
			holding = true;
			W.codec.hold(1);   // until the close is delivered
		}
		W.closeListener = listener;
		return function()
		{
			if (W.closeListener === listener) W.closeListener = null;
			if (holding)
			{
				holding = false;
				W.codec.hold(-1);
			}
		};
	});
});

// holdClose : Int -> ( Int, String, Bool ) -> Task Never ()
// A close the manager received after the last OnClose subscription went away: held for the
// next subscriber.
var _WebSocket_holdClose = F2(function(wsId, info)
{
	return __Scheduler_binding(function(callback)
	{
		var W = _WebSocket_ws[wsId];
		if (W) W.held = { code: info.a, reason: info.b, clean: info.c };
		callback(_WebSocket_done());
	});
});
