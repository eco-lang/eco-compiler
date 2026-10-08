/*
import Elm.Kernel.Scheduler exposing (binding, succeed, fail, rawSpawn)
import Elm.Kernel.Utils exposing (Tuple0, Tuple2, Tuple3)
import Elm.Kernel.List exposing (fromArray)
import Eco.Kernel.Stream exposing (createChannelSource, createChannelSink, nodeDuplexChannels, noteActivity, toBytes, toUint8Array)
*/

// Socket — JS twin of src/eco-system/Socket/ (eco/system), plans/eco-system-sockets.md
// Appendix B.1, B.2 and E, phase S6.
//
// Stream sockets (B.1) on node:net / node:dns / node:fs, with the native boundary shapes
// (§3.2) and error codes and messages (§D.5: "<syscall> <CODE> <address or path>"):
//   * lookup: dns.lookup(name, { all, order: 'verbatim', hints: 0 }); "" fails ENOTFOUND
//     without calling; duplicates removed.
//   * tcpConnect / unixConnect: a net.Socket with allowHalfOpen; the connect timeout is a
//     timer that destroys the socket and fails ETIMEDOUT (Node's own `timeout` is an idle
//     timeout); Process.kill destroys the socket. Unix endpoints come from the arguments
//     (§D.3: Node reports none), paths of sizeof(sun_path) bytes or more fail ENAMETOOLONG
//     before any call.
//   * tcpListen / unixListen: net.createServer({ allowHalfOpen, pauseOnConnect }). Unix:
//     an existing path fails EADDRINUSE unless removeExisting and it is a socket; the
//     permissions are applied with chmod once Node has bound and listened (Node has no
//     hook between bind and listen), before the task succeeds.
//   * Node accepts eagerly, so every accepted socket goes through the §3.4 delivery rule
//     at once: the oldest parked `accept`, else the manager's listener (the onConnection
//     subscriptions), else the listener's held FIFO (bounded at the backlog; beyond it the
//     newest is destroyed). A connection becomes a Connection (stream pair over
//     _Stream_nodeDuplexChannels) only when it is handed out.
//   * closeListener: held connections destroyed, parked accepts fail ECANCELED, the
//     listening handle closed (Node frees the port and unlinks the Unix path at once), the
//     task completes on the next turn. Node's 'close' event would also wait for every
//     accepted connection to end, which native closeListener does not.
//   * close / reset: abort the duplex ("socket closed"); reset sends RST on TCP
//     (resetAndDestroy) and is a plain destroy on Unix.
//   * setNoDelay / setKeepAlive: Unix (and closed connections) succeed doing nothing.
//   * peerCredentials: ENOTSUP on a Unix connection (Node has none), EINVAL otherwise.
//
// UDP (B.2) on node:dgram (phase S6b), with native's codes and messages ("bind <CODE>
// addr:port", "send <CODE> addr:port", "addMembership <CODE>", "dropMembership <CODE>",
// "receive ECANCELED"):
//   * udpBind: dgram.createSocket({ type udp4/udp6 by the address family, reuseAddr,
//     ipv6Only (udp6 only) }); after the bind setBroadcast and buffer sizes raised to
//     65 536 (never lowered, as native). A bound socket is ref'd until closed, so it keeps
//     the program alive (native: a pendingAsync count, §3.3.8).
//   * udpSend: §D.4 (IPv4 destination on udp6 -> ::ffff:a.b.c.d; IPv6 on udp4 ->
//     EAFNOSUPPORT, where Node would say EINVAL); Node's own send errors otherwise
//     (EMSGSIZE, EACCES without broadcast).
//   * Node reads eagerly, so every datagram goes through the §3.4 delivery rule at once:
//     the oldest parked receive, else the manager's listener, else the held FIFO (max 64,
//     the oldest dropped).
//   * udpClose: idempotent; held datagrams dropped, parked receives and sends in flight
//     fail ECANCELED; later operations fail ECANCELED.
//   * udpMembership: Node's addMembership/dropMembership (synchronous; EADDRNOTAVAIL when
//     leaving a group not joined); IPv6 interface "::%<ifname>".
//
// TLS (B.3, Tls.js, phase S6c) reuses the connection table (_Socket_materialize with a
// TLS `extra`: the raw net.Socket under the TLSSocket, for reset and endpoints, and the
// handshake info) and the listener table (_Socket_tcpListenWith with a server factory).
//
// The JS-only kernels at the end are used by the Elm effect-manager bodies of Socket and
// Socket.Udp (Appendix E). Every kernel that starts IO calls _Stream_noteActivity().

var _Socket_net = null;

function _Socket_netModule()
{
	return _Socket_net || (_Socket_net = require('net'));
}

function _Socket_done()
{
	return __Scheduler_succeed(__Utils_Tuple0);
}

function _Socket_ferr(code, message)
{
	return __Scheduler_fail(__Utils_Tuple2(code, message));
}

// "<syscall> <CODE>" plus " <what>" when there is one (native codeMessage).
function _Socket_message(syscall, code, what)
{
	return syscall + ' ' + code + (what ? ' ' + what : '');
}

function _Socket_codeOf(e)
{
	return (e && typeof e.code === 'string' && e.code) ? e.code : 'EIO';
}

// sizeof(sun_path): a path whose UTF-8 length reaches it fails ENAMETOOLONG (§D.3).
function _Socket_unixPathError(path)
{
	if (path === '') return 'ENOENT';
	var limit = process.platform === 'darwin' ? 104 : 108;
	return Buffer.byteLength(path, 'utf8') >= limit ? 'ENAMETOOLONG' : null;
}

// EpT
function _Socket_inetEp(address, port)
{
	return __Utils_Tuple3(0, address || '', port || 0);
}

function _Socket_unixEp(path)
{
	return __Utils_Tuple3(1, path, 0);
}


// --- Connections -------------------------------------------------------------------------

var _Socket_conns = {};
var _Socket_nextConnId = 1;

// Turns a connected socket into a connection-table entry and its ConnT. `extra` is null
// for plain sockets; for a TLSSocket it is { raw: the net.Socket underneath (reset goes
// through it, Appendix E), tlsInfo: what the handshake agreed on, opaque here (Tls.info
// answers from the entry's `tlsInfo`, as native's ConnEntry) }. Objects shared with Tls.js
// use plain property names: the compiler shortens double-underscore field names per
// kernel file, so such a field written in one file is not the same field in another.
function _Socket_materialize(socket, isUnix, local, remote, seq, extra)
{
	var duplex = __Stream_nodeDuplexChannels(socket, extra ? { raw: extra.raw } : null);
	var readableId = __Stream_createChannelSource(duplex.read);
	var writableId = __Stream_createChannelSink(duplex.write);
	var id = _Socket_nextConnId++;
	var c = {
		__socket: socket,
		__duplex: duplex,
		__isUnix: isUnix,
		__seq: seq,
		tlsInfo: extra ? extra.tlsInfo : null
	};
	_Socket_conns[id] = c;
	socket.once('close', function() { delete _Socket_conns[id]; });
	return __Utils_Tuple3(id, __Utils_Tuple2(readableId, writableId), __Utils_Tuple2(local, remote));
}

function _Socket_tcpEndpoints(socket)
{
	return {
		__local: _Socket_inetEp(socket.localAddress, socket.localPort),
		__remote: _Socket_inetEp(socket.remoteAddress, socket.remotePort)
	};
}

// Starts a client connect. `connectArgs` is net.Socket#connect's options; `target` is the
// address text of the messages; `endpoints(socket)` gives { __local, __remote }.
function _Socket_connect(callback, connectArgs, target, timeoutMs, isUnix, endpoints, onConnected)
{
	__Stream_noteActivity();
	var net = _Socket_netModule();
	var settled = false;
	var timer = null;
	var socket = new net.Socket({ allowHalfOpen: true });
	socket.pause();   // no reading until a read is requested (§3.3.3)

	function fail(code)
	{
		if (settled) return;
		settled = true;
		if (timer) clearTimeout(timer);
		socket.removeListener('connect', onConnect);
		if (!socket.destroyed) socket.destroy();
		callback(_Socket_ferr(code, _Socket_message('connect', code, target)));
	}

	function onError(e)
	{
		fail(_Socket_codeOf(e));
	}

	function onConnect()
	{
		if (settled) return;
		settled = true;
		if (timer) clearTimeout(timer);
		socket.removeListener('error', onError);
		if (onConnected) onConnected(socket);
		var eps = endpoints(socket);
		callback(__Scheduler_succeed(_Socket_materialize(socket, isUnix, eps.__local, eps.__remote, 0)));
	}

	socket.once('connect', onConnect);
	socket.once('error', onError);
	if (timeoutMs > 0)
	{
		timer = setTimeout(function() { fail('ETIMEDOUT'); }, timeoutMs);
	}
	try
	{
		socket.connect(connectArgs);
	}
	catch (e)
	{
		fail(_Socket_codeOf(e));
	}
	return function()
	{
		// Process.kill: abort the attempt; the task never completes.
		if (settled) return;
		settled = true;
		if (timer) clearTimeout(timer);
		socket.destroy();
	};
}


// --- B.1 stream sockets ----------------------------------------------------------------

// lookup : String -> Task FErr (List String)
var _Socket_lookup = function(name)
{
	return __Scheduler_binding(function(callback)
	{
		if (name === '')
		{
			// As Node and native: without calling the resolver.
			callback(_Socket_ferr('ENOTFOUND', 'getaddrinfo ENOTFOUND ' + name));
			return;
		}
		__Stream_noteActivity();
		var killed = false;
		var fail = function(code)
		{
			callback(_Socket_ferr(code, 'getaddrinfo ' + code + ' ' + name));
		};
		try
		{
			require('dns').lookup(name, { all: true, order: 'verbatim', hints: 0 }, function(err, results)
			{
				if (killed) return;
				if (err)
				{
					var code = _Socket_codeOf(err);
					if (code === 'EAI_NONAME' || code === 'EAI_NODATA') code = 'ENOTFOUND';
					else if (code === 'EAI_MEMORY') code = 'ENOMEM';
					else if (code !== 'EAI_AGAIN' && code !== 'ENOTFOUND' && code.lastIndexOf('EAI_', 0) === 0) code = 'EAI_FAIL';
					fail(code);
					return;
				}
				var out = [];
				for (var i = 0; i < results.length; i++)
				{
					if (out.indexOf(results[i].address) < 0) out.push(results[i].address);
				}
				if (!out.length)
				{
					fail('ENOTFOUND');
					return;
				}
				callback(__Scheduler_succeed(__List_fromArray(out)));
			});
		}
		catch (e)
		{
			fail(_Socket_codeOf(e));   // e.g. ERR_INVALID_ARG_VALUE for a name with NUL
			return;
		}
		return function() { killed = true; };
	});
};

// tcpConnect : ( String, Int, Int ) -> ( Bool, Int ) -> Task FErr ConnT
var _Socket_tcpConnect = F2(function(target, settings)
{
	return __Scheduler_binding(function(callback)
	{
		var address = target.a;
		var port = target.b;
		var timeoutMs = target.c;
		var noDelay = settings.a;
		var keepAliveSec = settings.b;
		return _Socket_connect(
			callback,
			{ host: address, port: port },
			address + ':' + port,
			timeoutMs,
			false,
			_Socket_tcpEndpoints,
			function(socket)
			{
				try
				{
					if (noDelay) socket.setNoDelay(true);
					if (keepAliveSec > 0) socket.setKeepAlive(true, keepAliveSec * 1000);
				}
				catch (e) { /* as native: options at connect are best effort */ }
			}
		);
	});
});

// unixConnect : String -> Task FErr ConnT
var _Socket_unixConnect = function(path)
{
	return __Scheduler_binding(function(callback)
	{
		var bad = _Socket_unixPathError(path);
		if (bad)
		{
			callback(_Socket_ferr(bad, _Socket_message('connect', bad, path)));
			return;
		}
		return _Socket_connect(
			callback,
			{ path: path },
			path,
			0,
			true,
			function() { return { __local: _Socket_unixEp(''), __remote: _Socket_unixEp(path) }; },
			null
		);
	});
};


// --- Listeners ---------------------------------------------------------------------------

var _Socket_listeners = {};
var _Socket_nextListenerId = 1;
var _Socket_nextSeq = 1;

// The plain server factory: every accepted socket goes to _Socket_onConnection at once.
function _Socket_plainServer(L)
{
	var server = _Socket_netModule().createServer({ allowHalfOpen: true, pauseOnConnect: true });
	server.on('connection', function(socket)
	{
		_Socket_onConnection(L, socket, null);
	});
	return server;
}

// Creates a listening server; `ready(server)` runs after 'listening' and returns an error
// code (the listen then fails) or null; `bound(server)` gives the EpT. `createServer(L)`
// makes the (not yet listening) server and routes its connections to
// _Socket_onConnection(L, socket, extra); it may set L.abortPending, which
// closeListener calls (TLS: destroy the connections still handshaking). Null: plain.
function _Socket_listen(callback, listenArgs, what, isUnix, path, maxHeld, ready, bound, createServer)
{
	__Stream_noteActivity();
	var started = false;
	var L = {
		__id: 0,
		__server: null,
		__isUnix: isUnix,
		__path: path,
		__maxHeld: maxHeld,
		__held: [],          // { __seq, __socket, __connT }, oldest first
		__parked: [],        // { __callback }, oldest first
		__listener: null,    // function(connT), while the Elm manager listens
		__closing: false,
		__closeCallbacks: [],
		abortPending: null   // function(), set by a server factory (plain name: Tls.js sets it)
	};
	var server = (createServer || _Socket_plainServer)(L);
	L.__server = server;

	function fail(code)
	{
		if (started) return;
		started = true;
		try { server.close(); } catch (e) { /* not listening */ }
		callback(_Socket_ferr(code, _Socket_message('listen', code, what)));
	}

	server.on('error', function(e)
	{
		fail(_Socket_codeOf(e));   // later errors are ignored (the server stays as it is)
	});
	try
	{
		server.listen(listenArgs, function()
		{
			if (started) return;
			var code = ready ? ready(server) : null;
			if (code)
			{
				fail(code);
				return;
			}
			started = true;
			L.__id = _Socket_nextListenerId++;
			_Socket_listeners[L.__id] = L;
			callback(__Scheduler_succeed(__Utils_Tuple2(L.__id, bound(server))));
		});
	}
	catch (e)
	{
		fail(_Socket_codeOf(e));   // thrown synchronously, e.g. ERR_SOCKET_BAD_PORT
	}
}

// An accepted connection (`extra` as _Socket_materialize's) enters the delivery rule.
function _Socket_onConnection(L, socket, extra)
{
	if (L.__closing)
	{
		socket.destroy();
		return;
	}
	__Stream_noteActivity();
	socket.on('error', function() {});   // until the duplex takes over
	_Socket_deliver(L, { __seq: _Socket_nextSeq++, __socket: socket, __extra: extra, __connT: null });
}

function _Socket_materializeHeld(L, item)
{
	if (!item.__connT)
	{
		var socket = item.__socket;
		var local, remote;
		if (L.__isUnix)
		{
			local = _Socket_unixEp(L.__path);
			remote = _Socket_unixEp('');
		}
		else
		{
			var eps = _Socket_tcpEndpoints(item.__extra ? item.__extra.raw : socket);
			local = eps.__local;
			remote = eps.__remote;
		}
		item.__connT = _Socket_materialize(socket, L.__isUnix, local, remote, item.__seq, item.__extra);
	}
	return item.__connT;
}

function _Socket_dropHeld(item)
{
	if (item.__connT)
	{
		var c = _Socket_conns[item.__connT.a];
		if (c) c.__duplex.abort('socket closed');
	}
	else if (!item.__socket.destroyed)
	{
		item.__socket.destroy();
	}
}

// §3.4: the oldest parked accept, else every subscription (through the manager's
// listener), else the held FIFO.
function _Socket_deliver(L, item)
{
	if (L.__parked.length)
	{
		var p = L.__parked.shift();
		p.__callback(__Scheduler_succeed(_Socket_materializeHeld(L, item)));
		return;
	}
	if (L.__listener)
	{
		L.__listener(_Socket_materializeHeld(L, item));
		return;
	}
	L.__held.push(item);
	L.__held.sort(function(x, y) { return x.__seq - y.__seq; });
	if (L.__held.length > L.__maxHeld)
	{
		_Socket_dropHeld(L.__held.pop());   // the newest
	}
}

// tcpListen : ( String, Int ) -> ( Int, Bool ) -> Task FErr ListenT
var _Socket_tcpListen = F2(function(target, settings)
{
	return __Scheduler_binding(function(callback)
	{
		_Socket_tcpListenWith(callback, target, settings, null);
	});
});

// tcpListen with a server factory (_Socket_listen's createServer; null: plain, Tls.listen
// passes a TLS one). An address Node's isIP rejects fails EINVAL before listening.
function _Socket_tcpListenWith(callback, target, settings, createServer)
{
	var address = target.a;
	var port = target.b;
	var backlog = settings.a < 1 ? 1 : (settings.a > 65535 ? 65535 : settings.a);
	var ipv6Only = settings.b;
	var what = address + ':' + port;
	if (!_Socket_netModule().isIP(address.split('%')[0]))
	{
		callback(_Socket_ferr('EINVAL', _Socket_message('listen', 'EINVAL', what)));
		return;
	}
	_Socket_listen(
		callback,
		{ host: address, port: port, backlog: backlog, ipv6Only: ipv6Only },
		what,
		false,
		'',
		backlog,
		null,
		function(server)
		{
			var a = server.address();
			return a && typeof a === 'object'
				? _Socket_inetEp(a.address, a.port)
				: _Socket_inetEp(address, port);
		},
		createServer
	);
}

// unixListen : String -> ( Bool, Int ) -> Task FErr ListenT
var _Socket_unixListen = F2(function(path, settings)
{
	return __Scheduler_binding(function(callback)
	{
		var removeExisting = settings.a;
		var mode = settings.b;
		var bad = _Socket_unixPathError(path);
		if (bad)
		{
			callback(_Socket_ferr(bad, _Socket_message('listen', bad, path)));
			return;
		}
		var fs = require('fs');
		var st = null;
		try { st = fs.lstatSync(path); } catch (e) { st = null; }
		if (st)
		{
			// §D.3: an existing path fails EADDRINUSE unless removeExisting, which removes
			// only a socket.
			if (!removeExisting || !st.isSocket())
			{
				callback(_Socket_ferr('EADDRINUSE', _Socket_message('listen', 'EADDRINUSE', path)));
				return;
			}
			try
			{
				fs.unlinkSync(path);
			}
			catch (e)
			{
				if (e.code !== 'ENOENT')
				{
					var code = _Socket_codeOf(e);
					callback(_Socket_ferr(code, _Socket_message('listen', code, path)));
					return;
				}
			}
		}
		_Socket_listen(
			callback,
			{ path: path, backlog: 511 },
			path,
			true,
			path,
			511,
			function()
			{
				if (mode < 0) return null;
				try
				{
					fs.chmodSync(path, mode & 4095);   // 0o7777
					return null;
				}
				catch (e)
				{
					return _Socket_codeOf(e);   // the failed listen closes (and unlinks)
				}
			},
			function() { return _Socket_unixEp(path); },
			null
		);
	});
});

// accept : Int -> Task FErr ConnT
var _Socket_accept = function(listenerId)
{
	return __Scheduler_binding(function(callback)
	{
		var L = _Socket_listeners[listenerId];
		if (!L || L.__closing)
		{
			callback(_Socket_ferr('ECANCELED', 'accept ECANCELED'));
			return;
		}
		if (L.__held.length)
		{
			callback(__Scheduler_succeed(_Socket_materializeHeld(L, L.__held.shift())));
			return;
		}
		__Stream_noteActivity();
		var entry = { __callback: callback };
		L.__parked.push(entry);
		return function()
		{
			var i = L.__parked.indexOf(entry);
			if (i >= 0) L.__parked.splice(i, 1);
		};
	});
};

// closeListener : Int -> Task FErr ()
var _Socket_closeListener = function(listenerId)
{
	return __Scheduler_binding(function(callback)
	{
		var L = _Socket_listeners[listenerId];
		if (!L)
		{
			callback(_Socket_done());   // closed already: idempotent
			return;
		}
		L.__closeCallbacks.push(callback);
		if (L.__closing) return;
		L.__closing = true;
		__Stream_noteActivity();
		var held = L.__held;
		L.__held = [];
		for (var i = 0; i < held.length; i++)
		{
			_Socket_dropHeld(held[i]);
		}
		var parked = L.__parked;
		L.__parked = [];
		for (var j = 0; j < parked.length; j++)
		{
			parked[j].__callback(_Socket_ferr('ECANCELED', 'accept ECANCELED'));
		}
		if (L.abortPending) L.abortPending();
		// Closing the listening handle frees the address (and Node unlinks the Unix path)
		// at once; 'close' would also wait for the accepted connections.
		try { L.__server.close(); } catch (e) { /* not listening */ }
		setImmediate(function()
		{
			if (L.__isUnix)
			{
				try
				{
					var st = require('fs').lstatSync(L.__path);
					if (st.isSocket()) require('fs').unlinkSync(L.__path);
				}
				catch (e) { /* gone already */ }
			}
			delete _Socket_listeners[L.__id];
			var cbs = L.__closeCallbacks;
			L.__closeCallbacks = [];
			for (var k = 0; k < cbs.length; k++)
			{
				cbs[k](_Socket_done());
			}
		});
	});
};

// close : Int -> Task Never ()
var _Socket_close = function(connId)
{
	return __Scheduler_binding(function(callback)
	{
		var c = _Socket_conns[connId];
		if (c) c.__duplex.abort('socket closed');
		callback(_Socket_done());
	});
};

// reset : Int -> Task Never ()
var _Socket_reset = function(connId)
{
	return __Scheduler_binding(function(callback)
	{
		var c = _Socket_conns[connId];
		if (c)
		{
			if (c.__isUnix) c.__duplex.abort('socket closed');
			else c.__duplex.reset('socket closed');
		}
		callback(_Socket_done());
	});
};

// The socket of a TCP connection that is still open, or null (Unix, unknown or closed
// connections: the option kernels then succeed doing nothing, as natively).
function _Socket_tcpSocket(connId)
{
	var c = _Socket_conns[connId];
	return c && !c.__isUnix && !c.__socket.destroyed ? c.__socket : null;
}

function _Socket_option(connId, apply)
{
	return __Scheduler_binding(function(callback)
	{
		var socket = _Socket_tcpSocket(connId);
		if (socket)
		{
			try
			{
				apply(socket);
			}
			catch (e)
			{
				var code = _Socket_codeOf(e);
				callback(_Socket_ferr(code, _Socket_message('setsockopt', code, '')));
				return;
			}
		}
		callback(_Socket_done());
	});
}

// setNoDelay : Bool -> Int -> Task FErr ()
var _Socket_setNoDelay = F2(function(noDelay, connId)
{
	return _Socket_option(connId, function(socket) { socket.setNoDelay(noDelay); });
});

// setKeepAlive : Int -> Int -> Task FErr ()   (seconds; 0 off)
var _Socket_setKeepAlive = F2(function(seconds, connId)
{
	return _Socket_option(connId, function(socket)
	{
		if (seconds > 0) socket.setKeepAlive(true, seconds * 1000);
		else socket.setKeepAlive(false);
	});
});

// peerCredentials : Int -> Task FErr CredT
var _Socket_peerCredentials = function(connId)
{
	return __Scheduler_binding(function(callback)
	{
		var c = _Socket_conns[connId];
		if (!c || !c.__isUnix)
		{
			callback(_Socket_ferr('EINVAL', 'peerCredentials EINVAL'));
			return;
		}
		callback(_Socket_ferr('ENOTSUP', 'peerCredentials ENOTSUP'));   // none in Node
	});
};


// --- B.2 UDP ---------------------------------------------------------------------------

var _Socket_udps = {};
var _Socket_nextUdpId = 1;
var _Socket_kMaxHeldDatagrams = 64;
var _Socket_kUdpBuffer = 65536;

// The seq of a DgramT (arrival order), so a datagram handed back by holdDatagram goes into
// the held FIFO in order. A WeakMap keeps the tuple itself unchanged (Elm equality).
var _Socket_dgramSeq = new WeakMap();

// 4, 6, or 0 for an address text that is neither (the scope is not part of the test).
function _Socket_family(address)
{
	return _Socket_netModule().isIP(address.split('%')[0]);
}

function _Socket_scopeOf(address)
{
	var i = address.indexOf('%');
	return i < 0 ? '' : address.slice(i + 1);
}

// Node (libuv) takes an interface name as IPv6 scope; native also accepts a decimal index.
function _Socket_scopeName(scope)
{
	if (!/^[0-9]+$/.test(scope)) return scope;
	try
	{
		var ifs = require('os').networkInterfaces();
		for (var name in ifs)
		{
			var list = ifs[name] || [];
			for (var i = 0; i < list.length; i++)
			{
				if (list[i].scopeid === +scope) return name;
			}
		}
	}
	catch (e) { /* no interface list: pass the index through */ }
	return scope;
}

// udpBind : ( String, Int ) -> ( Bool, Bool, Bool ) -> Task FErr UdpT
var _Socket_udpBind = F2(function(target, settings)
{
	return __Scheduler_binding(function(callback)
	{
		var address = target.a;
		var port = target.b;
		var reuseAddress = settings.a;
		var broadcast = settings.b;
		var ipv6Only = settings.c;
		var what = address + ':' + port;
		var fam = _Socket_family(address);
		if (!fam)
		{
			callback(_Socket_ferr('EINVAL', _Socket_message('bind', 'EINVAL', what)));
			return;
		}
		__Stream_noteActivity();
		var options = { type: fam === 6 ? 'udp6' : 'udp4', reuseAddr: reuseAddress };
		if (fam === 6) options.ipv6Only = ipv6Only;
		var settled = false;
		var socket;
		function fail(code)
		{
			if (settled) return;
			settled = true;
			try { socket.close(); } catch (e) { /* not running */ }
			callback(_Socket_ferr(code, _Socket_message('bind', code, what)));
		}
		try
		{
			socket = require('dgram').createSocket(options);
		}
		catch (e)
		{
			callback(_Socket_ferr(_Socket_codeOf(e), _Socket_message('bind', _Socket_codeOf(e), what)));
			return;
		}
		var U = {
			__id: 0,
			__socket: socket,
			__isV6: fam === 6,
			__held: [],          // DgramT, oldest first
			__parked: [],        // { __callback }, oldest first
			__listener: null,    // function(dgramT), while the Elm manager listens
			__sends: [],         // { __fail } of the sends in flight
			__closed: false
		};
		socket.on('error', function(e) { fail(_Socket_codeOf(e)); });   // later errors: ignored
		socket.on('message', function(msg, rinfo) { _Socket_onDatagram(U, msg, rinfo); });
		try
		{
			socket.bind({ address: address, port: port, exclusive: true }, function()
			{
				if (settled) return;
				try
				{
					if (broadcast) socket.setBroadcast(true);
					// >= 65 536 so a maximal datagram fits (as native: only ever raised;
					// Node's sendBufferSize/recvBufferSize options would also lower them).
					if (socket.getSendBufferSize() < _Socket_kUdpBuffer) socket.setSendBufferSize(_Socket_kUdpBuffer);
					if (socket.getRecvBufferSize() < _Socket_kUdpBuffer) socket.setRecvBufferSize(_Socket_kUdpBuffer);
				}
				catch (e)
				{
					fail(_Socket_codeOf(e));
					return;
				}
				settled = true;
				U.__id = _Socket_nextUdpId++;
				_Socket_udps[U.__id] = U;
				var a = socket.address();
				// The bound socket stays ref'd: it keeps the program alive until it is
				// closed (native: a pendingAsync count until the UdpClosed drain, §3.3.8).
				callback(__Scheduler_succeed(__Utils_Tuple2(U.__id, __Utils_Tuple2(a.address, a.port))));
			});
		}
		catch (e)
		{
			fail(_Socket_codeOf(e));   // thrown synchronously, e.g. ERR_SOCKET_BAD_PORT
		}
		return function()
		{
			// Process.kill before the bind completed: close the socket (native: the
			// orphaned pool result closes its fd).
			if (settled) return;
			settled = true;
			try { socket.close(); } catch (e) { /* not running */ }
		};
	});
});

function _Socket_onDatagram(U, msg, rinfo)
{
	if (U.__closed || !U.__id) return;
	__Stream_noteActivity();
	var dgram = __Utils_Tuple2(
		__Stream_toBytes(new Uint8Array(msg.buffer, msg.byteOffset, msg.length)),
		__Utils_Tuple2(rinfo.address, rinfo.port)
	);
	_Socket_dgramSeq.set(dgram, _Socket_nextSeq++);
	_Socket_deliverDatagram(U, dgram);
}

// §3.4: the oldest parked receive, else every subscription (through the manager's
// listener), else the held FIFO (max 64; on overflow the oldest is dropped).
function _Socket_deliverDatagram(U, dgram)
{
	if (U.__parked.length)
	{
		U.__parked.shift().__callback(__Scheduler_succeed(dgram));
		return;
	}
	if (U.__listener)
	{
		U.__listener(dgram);
		return;
	}
	U.__held.push(dgram);
	U.__held.sort(function(x, y) { return (_Socket_dgramSeq.get(x) || 0) - (_Socket_dgramSeq.get(y) || 0); });
	while (U.__held.length > _Socket_kMaxHeldDatagrams)
	{
		U.__held.shift();   // the oldest
	}
}

// udpSend : ( String, Int ) -> Bytes -> Int -> Task FErr ()
var _Socket_udpSend = F3(function(to, data, socketId)
{
	return __Scheduler_binding(function(callback)
	{
		var address = to.a;
		var port = to.b;
		var what = address + ':' + port;
		var fail = function(code)
		{
			callback(_Socket_ferr(code, _Socket_message('send', code, what)));
		};
		var U = _Socket_udps[socketId];
		if (!U || U.__closed)
		{
			fail('ECANCELED');
			return;
		}
		// §D.4: an IPv4 destination on an IPv6 socket goes to ::ffff:a.b.c.d (Node fails
		// EINVAL otherwise, SF15); an IPv6 destination on an IPv4 socket fails EAFNOSUPPORT
		// (native's code; Node would report EINVAL).
		var fam = _Socket_family(address);
		if (!fam)
		{
			fail('EINVAL');
			return;
		}
		var dest = address;
		if (fam === 6 && !U.__isV6)
		{
			fail('EAFNOSUPPORT');
			return;
		}
		if (fam === 4 && U.__isV6) dest = '::ffff:' + address;
		__Stream_noteActivity();
		var settled = false;
		var entry = {
			__fail: function(code)
			{
				if (settled) return;
				settled = true;
				fail(code);
			}
		};
		U.__sends.push(entry);
		var u8 = __Stream_toUint8Array(data);
		try
		{
			U.__socket.send(Buffer.from(u8.buffer, u8.byteOffset, u8.byteLength), port, dest, function(err)
			{
				var i = U.__sends.indexOf(entry);
				if (i >= 0) U.__sends.splice(i, 1);
				if (settled) return;
				if (err)
				{
					entry.__fail(_Socket_codeOf(err));
					return;
				}
				settled = true;
				callback(_Socket_done());
			});
		}
		catch (e)
		{
			var j = U.__sends.indexOf(entry);
			if (j >= 0) U.__sends.splice(j, 1);
			entry.__fail(_Socket_codeOf(e));   // e.g. ERR_SOCKET_BAD_PORT
		}
	});
});

// udpReceive : Int -> Task FErr DgramT
var _Socket_udpReceive = function(socketId)
{
	return __Scheduler_binding(function(callback)
	{
		var U = _Socket_udps[socketId];
		if (!U || U.__closed)
		{
			callback(_Socket_ferr('ECANCELED', 'receive ECANCELED'));
			return;
		}
		if (U.__held.length)
		{
			callback(__Scheduler_succeed(U.__held.shift()));
			return;
		}
		__Stream_noteActivity();
		var entry = { __callback: callback };
		U.__parked.push(entry);
		return function()
		{
			var i = U.__parked.indexOf(entry);
			if (i >= 0) U.__parked.splice(i, 1);
		};
	});
};

// udpClose : Int -> Task Never ()
// Idempotent: held datagrams are dropped, parked receives and sends in flight fail
// ECANCELED, the socket is closed (Node closes the fd at once and unrefs the loop).
var _Socket_udpClose = function(socketId)
{
	return __Scheduler_binding(function(callback)
	{
		var U = _Socket_udps[socketId];
		if (U && !U.__closed)
		{
			U.__closed = true;
			delete _Socket_udps[socketId];
			U.__held = [];
			U.__listener = null;
			var sends = U.__sends;
			U.__sends = [];
			for (var i = 0; i < sends.length; i++)
			{
				sends[i].__fail('ECANCELED');
			}
			var parked = U.__parked;
			U.__parked = [];
			for (var j = 0; j < parked.length; j++)
			{
				parked[j].__callback(_Socket_ferr('ECANCELED', 'receive ECANCELED'));
			}
			try { U.__socket.close(); } catch (e) { /* closed already */ }
		}
		callback(_Socket_done());
	});
};

// udpMembership : Bool -> String -> String -> Int -> Task FErr ()
// IPv4: the interface is its address. IPv6: the interface is the scope of the interface
// address (its address bits ignored), else the group's own scope, else none; Node takes it
// as "::%<ifname>" (SF15).
var _Socket_udpMembership = F4(function(join, group, iface, socketId)
{
	return __Scheduler_binding(function(callback)
	{
		var syscall = join ? 'addMembership' : 'dropMembership';
		var fail = function(code)
		{
			callback(_Socket_ferr(code, _Socket_message(syscall, code, '')));
		};
		var U = _Socket_udps[socketId];
		if (!U || U.__closed)
		{
			fail('ECANCELED');
			return;
		}
		var gfam = _Socket_family(group);
		var ifam = iface === '' ? 0 : _Socket_family(iface);
		if (!gfam || (iface !== '' && ifam !== gfam))
		{
			fail('EINVAL');   // as native: unparsable, or an interface of the other family
			return;
		}
		var nodeIface;
		if (gfam === 4)
		{
			nodeIface = iface === '' ? undefined : iface;
		}
		else
		{
			var scope = iface === '' ? _Socket_scopeOf(group) : _Socket_scopeOf(iface);
			nodeIface = scope === '' ? (iface === '' ? undefined : '::') : '::%' + _Socket_scopeName(scope);
		}
		__Stream_noteActivity();
		try
		{
			if (join) U.__socket.addMembership(group.split('%')[0], nodeIface);
			else U.__socket.dropMembership(group.split('%')[0], nodeIface);
		}
		catch (e)
		{
			fail(_Socket_codeOf(e));   // e.g. EADDRNOTAVAIL when leaving a group not joined
			return;
		}
		callback(_Socket_done());
	});
});


// --- JS-only kernels (Appendix E) ------------------------------------------------------

// attachConnectionListener : Int -> (ConnT -> Task Never ()) -> Task Never ()
// A binding that never completes: while it runs, every connection of listener
// `listenerId` that no parked accept takes (first those held so far) spawns `toTask connT`.
// Killing its process detaches it; later connections are held again. An unknown or closed
// listener never delivers anything.
var _Socket_attachConnectionListener = F2(function(listenerId, toTask)
{
	return __Scheduler_binding(function(callback)
	{
		var L = _Socket_listeners[listenerId];
		if (!L || L.__closing)
		{
			return;
		}
		var listener = function(connT)
		{
			__Scheduler_rawSpawn(toTask(connT));
		};
		L.__listener = listener;
		var held = L.__held;
		L.__held = [];
		for (var i = 0; i < held.length; i++)
		{
			listener(_Socket_materializeHeld(L, held[i]));
		}
		return function()
		{
			if (L.__listener === listener)
			{
				L.__listener = null;
			}
		};
	});
});

// holdConnection : Int -> ConnT -> Task Never ()
// A connection the manager received after the listener's last subscriber went away goes
// through the delivery rule again (a parked accept, a new listener, or the held FIFO in
// arrival order). A closed listener closes it.
var _Socket_holdConnection = F2(function(listenerId, connT)
{
	return __Scheduler_binding(function(callback)
	{
		var L = _Socket_listeners[listenerId];
		var c = _Socket_conns[connT.a];
		if (!L || L.__closing)
		{
			if (c) c.__duplex.abort('socket closed');
		}
		else if (c)
		{
			_Socket_deliver(L, { __seq: c.__seq, __socket: c.__socket, __connT: connT });
		}
		callback(_Socket_done());
	});
});

// attachMessageListener : Int -> (DgramT -> Task Never ()) -> Task Never ()
// As attachConnectionListener: a binding that never completes; while it runs, every
// datagram of socket `socketId` that no parked receive takes (first those held so far)
// spawns `toTask dgramT`. Killing its process detaches it; later datagrams are held again.
// An unknown or closed socket never delivers anything.
var _Socket_attachMessageListener = F2(function(socketId, toTask)
{
	return __Scheduler_binding(function(callback)
	{
		var U = _Socket_udps[socketId];
		if (!U || U.__closed)
		{
			return;
		}
		var listener = function(dgram)
		{
			__Scheduler_rawSpawn(toTask(dgram));
		};
		U.__listener = listener;
		var held = U.__held;
		U.__held = [];
		for (var i = 0; i < held.length; i++)
		{
			listener(held[i]);
		}
		return function()
		{
			if (U.__listener === listener)
			{
				U.__listener = null;
			}
		};
	});
});

// holdDatagram : Int -> DgramT -> Task Never ()
// A datagram the manager received after the socket's last subscriber went away goes
// through the delivery rule again (a parked receive, a new listener, or the held FIFO in
// arrival order). A closed socket drops it.
var _Socket_holdDatagram = F2(function(socketId, dgram)
{
	return __Scheduler_binding(function(callback)
	{
		var U = _Socket_udps[socketId];
		if (U && !U.__closed)
		{
			_Socket_deliverDatagram(U, dgram);
		}
		callback(_Socket_done());
	});
});
