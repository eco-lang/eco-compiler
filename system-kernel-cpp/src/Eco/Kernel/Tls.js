/*
import Elm.Kernel.Scheduler exposing (binding, succeed)
import Elm.Kernel.Utils exposing (Tuple3)
import Elm.Kernel.List exposing (toArray)
import Maybe exposing (Just, Nothing)
import Eco.Kernel.Socket exposing (conns, ferr, message, codeOf, netModule, inetEp, materialize, tcpListenWith, onConnection)
import Eco.Kernel.Stream exposing (noteActivity)
*/

// Tls — JS twin of src/eco-system/Tls/ (eco/system), plans/eco-system-sockets.md
// Appendix B.3 and E, phase S6c. Node's `tls` over the connection and listener tables of
// Socket.js, with the native boundary shapes (§3.2) and codes (§D.5):
//   * connect: our own net.Socket (allowHalfOpen, paused) is connected first, then handed
//     to tls.connect({ socket }), so the TLSSocket wraps its TCP handle (ref/unref and
//     pause/resume on the TLSSocket reach it) and Socket.reset can call the raw socket's
//     resetAndDestroy() (it throws on a TLSSocket, SF15). The connect timeout is one timer
//     over the TCP connect and the handshake (ETIMEDOUT). An IP-literal server name sends
//     no SNI and is checked against the certificate's IP addresses (`host`); a DNS name is
//     sent and checked (`servername`); "" checks no name (as OpenSSL's SSL_set1_host("")).
//     Verification: SystemCertificates = the file SSL_CERT_FILE names if set (plus the
//     system store when SSL_CERT_DIR is set too), else tls.getCACertificates('system'),
//     read once per process; TrustedCertificates = only the PEM's certificates;
//     NoVerification = rejectUnauthorized false. The task succeeds after 'secureConnect'
//     once the handshake's last flight (the client Finished) has left: an empty write
//     completes only when TLSWrap's pending output is flushed, so a Socket.close right
//     away cannot drop it (the server would never finish its handshake).
//   * listen: the certificate and key checked first (native builds the context before
//     listening), then tls.createServer({ cert, key, ALPNProtocols, allowHalfOpen,
//     pauseOnConnect }) through Socket.js's listener table (the §3.4 delivery rule, held
//     FIFO, closeListener). A connection enters the delivery rule on 'secureConnection';
//     a failed or timed-out handshake (Node's 120 s handshakeTimeout) is dropped silently
//     (tlsClientError), as natively; closeListener destroys the handshakes in progress.
//   * info: captured when the handshake ends (getProtocol(), alpnProtocol,
//     getCipher().name, OpenSSL's names as natively); EINVAL for a non-TLS (or finished)
//     connection.
//   * Socket.close is destroy() (no close_notify), Socket.reset resets the raw socket
//     (client: ours; server: tlsSocket._parent); Stream.closeWritable is end()
//     (close_notify, then FIN), all through Socket.js's duplex helper.
// Codes: Node's verification codes are native's where native names them; the others
// (e.g. CERT_UNTRUSTED, INVALID_CA) become CERT_VERIFY_FAILED, as natively. OpenSSL errors
// Node reports as ERR_OSSL_<LIB>_<REASON> become ERR_SSL_<REASON> (native's form, from the
// error's `reason`); Node's ERR_SSL_<REASON> and ECONNRESET ("Client network socket
// disconnected before secure TLS connection was established") are native's already.

var _Tls_tls = null;

function _Tls_module()
{
	return _Tls_tls || (_Tls_tls = require('tls'));
}

// Native's (and Socket.errorIsCertificateInvalid's) verification codes.
var _Tls_nativeVerifyCodes = [
	'CERT_HAS_EXPIRED', 'CERT_NOT_YET_VALID', 'DEPTH_ZERO_SELF_SIGNED_CERT',
	'SELF_SIGNED_CERT_IN_CHAIN', 'UNABLE_TO_GET_ISSUER_CERT_LOCALLY',
	'UNABLE_TO_VERIFY_LEAF_SIGNATURE', 'CERT_REVOKED', 'ERR_TLS_CERT_ALTNAME_INVALID',
	'CERT_VERIFY_FAILED'
];

// The other X509 verification codes Node reports (crypto_common X509_ERROR_CODES).
var _Tls_otherVerifyCodes = [
	'UNABLE_TO_GET_ISSUER_CERT', 'UNABLE_TO_GET_CRL', 'UNABLE_TO_DECRYPT_CERT_SIGNATURE',
	'UNABLE_TO_DECRYPT_CRL_SIGNATURE', 'UNABLE_TO_DECODE_ISSUER_PUBLIC_KEY',
	'CERT_SIGNATURE_FAILURE', 'CRL_SIGNATURE_FAILURE', 'CRL_NOT_YET_VALID', 'CRL_HAS_EXPIRED',
	'ERROR_IN_CERT_NOT_BEFORE_FIELD', 'ERROR_IN_CERT_NOT_AFTER_FIELD',
	'ERROR_IN_CRL_LAST_UPDATE_FIELD', 'ERROR_IN_CRL_NEXT_UPDATE_FIELD', 'OUT_OF_MEM',
	'CERT_CHAIN_TOO_LONG', 'INVALID_CA', 'PATH_LENGTH_EXCEEDED', 'INVALID_PURPOSE',
	'CERT_UNTRUSTED', 'CERT_REJECTED', 'UNSPECIFIED'
];

// §D.5 code of a Node TLS error (`tlsSocket`: the client socket, or null).
function _Tls_code(e, tlsSocket)
{
	var code = __Socket_codeOf(e);
	if (code === 'HOSTNAME_MISMATCH' || code === 'IP_ADDRESS_MISMATCH')
	{
		return 'ERR_TLS_CERT_ALTNAME_INVALID';
	}
	if (_Tls_nativeVerifyCodes.indexOf(code) >= 0) return code;
	if (_Tls_otherVerifyCodes.indexOf(code) >= 0 || (tlsSocket && tlsSocket.authorizationError))
	{
		return 'CERT_VERIFY_FAILED';   // native: any other verify error
	}
	if (code.lastIndexOf('ERR_OSSL_', 0) === 0 && e && typeof e.reason === 'string' && e.reason)
	{
		// Node: ERR_OSSL_<LIB>_<REASON>; native: ERR_SSL_<REASON> (ERR_reason_error_string).
		return 'ERR_SSL_' + e.reason.toUpperCase().replace(/ /g, '_');
	}
	return code;
}

function _Tls_errorMessage(e)
{
	var text = e && e.message ? String(e.message) : 'unknown TLS error';
	return text.replace(/\s+$/, '');
}

// Native's ALPN check: every protocol name is 1 to 255 bytes. A failure ( code, message )
// or null.
function _Tls_alpnError(alpn)
{
	for (var i = 0; i < alpn.length; i++)
	{
		var n = Buffer.byteLength(alpn[i], 'utf8');
		if (n < 1 || n > 255)
		{
			return __Socket_ferr('EINVAL', 'alpn EINVAL: a protocol name must be 1 to 255 bytes');
		}
	}
	return null;
}

// The certificates of a PEM text that parse (native: PEM_read_bio_X509 in a loop).
function _Tls_pemCertificates(pem)
{
	var crypto = require('crypto');
	var blocks = String(pem).match(/-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----/g) || [];
	var out = [];
	for (var i = 0; i < blocks.length; i++)
	{
		try
		{
			new crypto.X509Certificate(blocks[i]);
			out.push(blocks[i]);
		}
		catch (e) { /* skipped, as natively */ }
	}
	return out;
}

var _Tls_systemCache = null;

// SystemCertificates (§3.6, Appendix E): read once per process.
function _Tls_systemCertificates()
{
	if (_Tls_systemCache) return _Tls_systemCache;
	var tls = _Tls_module();
	var file = process.env.SSL_CERT_FILE;
	var dir = process.env.SSL_CERT_DIR;
	var list = [];
	if (file)
	{
		// As native: the environment replaces the defaults; a file that does not load
		// leaves an empty store (the handshake then fails verification).
		try
		{
			list = _Tls_pemCertificates(require('fs').readFileSync(file, 'utf8'));
		}
		catch (e) { list = []; }
		if (dir)
		{
			try { list = list.concat(tls.getCACertificates('system')); } catch (e) { /* none */ }
		}
	}
	else
	{
		try { list = tls.getCACertificates('system'); } catch (e) { list = []; }
	}
	_Tls_systemCache = list;
	return list;
}

// The handshake's outcome, as native's TlsInfo (protocol, alpn or "", cipher).
function _Tls_capture(tlsSocket)
{
	var cipher = null;
	try { cipher = tlsSocket.getCipher(); } catch (e) { cipher = null; }
	return {
		__protocol: tlsSocket.getProtocol() || '',
		__alpn: typeof tlsSocket.alpnProtocol === 'string' ? tlsSocket.alpnProtocol : '',
		__cipher: (cipher && cipher.name) || ''
	};
}


// --- B.3 ---------------------------------------------------------------------------------

// connect : ( String, Int, Int ) -> ( Bool, Int ) -> ( String, ( Int, String ), List String ) -> Task FErr ConnT
var _Tls_connect = F3(function(target, settings, tlsArgs)
{
	return __Scheduler_binding(function(callback)
	{
		var address = target.a;
		var port = target.b;
		var timeoutMs = target.c;
		var noDelay = settings.a;
		var keepAliveSec = settings.b;
		var serverName = tlsArgs.a;
		var mode = tlsArgs.b.a;
		var pem = tlsArgs.b.b;
		var alpn = __List_toArray(tlsArgs.c);
		var what = address + ':' + port;

		// The context first (native builds it on the pool before connecting).
		var bad = _Tls_alpnError(alpn);
		if (bad)
		{
			callback(bad);
			return;
		}
		var ca = null;
		if (mode === 1)
		{
			ca = _Tls_pemCertificates(pem);
			if (!ca.length)
			{
				callback(__Socket_ferr('ERR_SSL_NO_CERTIFICATES', 'trusted certificates: no certificate found'));
				return;
			}
		}
		else if (mode !== 2)
		{
			ca = _Tls_systemCertificates();
		}

		__Stream_noteActivity();
		var net = __Socket_netModule();
		var settled = false;
		var timer = null;
		var tlsSocket = null;
		var raw = new net.Socket({ allowHalfOpen: true });
		raw.pause();   // no reading until a read is requested (§3.3.3)

		function cleanup()
		{
			if (timer) clearTimeout(timer);
			timer = null;
			if (tlsSocket && !tlsSocket.destroyed) tlsSocket.destroy();
			if (!raw.destroyed) raw.destroy();
		}

		function fail(code, text)
		{
			if (settled) return;
			settled = true;
			cleanup();
			callback(__Socket_ferr(code, text));
		}

		function onTlsError(e)
		{
			fail(_Tls_code(e, tlsSocket), _Tls_errorMessage(e));
		}

		function succeed()
		{
			if (settled) return;
			settled = true;
			if (timer) clearTimeout(timer);
			timer = null;
			callback(__Scheduler_succeed(__Socket_materialize(
				tlsSocket, false,
				__Socket_inetEp(raw.localAddress, raw.localPort),
				__Socket_inetEp(raw.remoteAddress, raw.remotePort),
				0,
				{ raw: raw, tlsInfo: _Tls_capture(tlsSocket) }
			)));
		}

		raw.on('error', function(e)
		{
			// Before the handshake starts: a TCP connect failure, with native's message.
			// After it: the TLSSocket reports the failure (this one is then ignored).
			if (!tlsSocket)
			{
				var code = __Socket_codeOf(e);
				fail(code, __Socket_message('connect', code, what));
			}
		});
		raw.once('connect', function()
		{
			if (settled) return;
			try
			{
				if (noDelay) raw.setNoDelay(true);
				if (keepAliveSec > 0) raw.setKeepAlive(true, keepAliveSec * 1000);
			}
			catch (e) { /* as native: options at connect are best effort */ }
			var options = {
				socket: raw,
				rejectUnauthorized: mode !== 2
			};
			if (ca) options.ca = ca;
			if (alpn.length) options.ALPNProtocols = alpn;
			if (net.isIP(serverName))
			{
				options.host = serverName;   // no SNI; checked against the IP addresses
			}
			else if (serverName !== '')
			{
				options.servername = serverName;   // SNI + name check
			}
			else
			{
				// Node would check "localhost"; native (SSL_set1_host("")) checks no name.
				options.checkServerIdentity = function() { return undefined; };
			}
			try
			{
				tlsSocket = _Tls_module().connect(options);
			}
			catch (e)
			{
				onTlsError(e);
				return;
			}
			tlsSocket.on('error', onTlsError);   // a no-op once settled; the duplex has its own
			tlsSocket.once('secureConnect', function()
			{
				if (settled) return;
				// Flush the handshake's last flight before handing the connection out: an
				// empty write completes once TLSWrap's pending output is written.
				try
				{
					tlsSocket.write(Buffer.alloc(0), function(e)
					{
						if (e) onTlsError(e);
						else succeed();
					});
				}
				catch (e)
				{
					onTlsError(e);
				}
			});
		});
		if (timeoutMs > 0)
		{
			timer = setTimeout(function()
			{
				fail('ETIMEDOUT', __Socket_message('connect', 'ETIMEDOUT', what));
			}, timeoutMs);
		}
		try
		{
			raw.connect({ host: address, port: port });
		}
		catch (e)
		{
			var code = __Socket_codeOf(e);   // thrown synchronously, e.g. ERR_SOCKET_BAD_PORT
			fail(code, __Socket_message('connect', code, what));
		}
		return function()
		{
			// Process.kill: abort the attempt; the task never completes.
			if (settled) return;
			settled = true;
			cleanup();
		};
	});
});

// Checks the server certificate and key before listening: { __error: null } or
// { __error: the failing task }, in native's order and with its labels ("certificateChain:
// ...", "privateKey: ..."; a key that does not match the certificate fails at the key).
function _Tls_serverContext(chain, key)
{
	var crypto = require('crypto');
	var failure = function(what, e)
	{
		return { __error: __Socket_ferr(_Tls_code(e, null), what + ': ' + _Tls_errorMessage(e)) };
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
		_Tls_module().createSecureContext({ cert: chain, key: key });   // the pair matches
		return { __error: null };
	}
	catch (e)
	{
		return failure('privateKey', e);
	}
}

// listen : ( String, Int ) -> ( Int, Bool ) -> ( String, String, List String ) -> Task FErr ListenT
var _Tls_listen = F3(function(target, settings, tlsArgs)
{
	return __Scheduler_binding(function(callback)
	{
		var alpn = __List_toArray(tlsArgs.c);
		var bad = _Tls_alpnError(alpn);
		if (bad)
		{
			callback(bad);
			return;
		}
		var ctx = _Tls_serverContext(tlsArgs.a, tlsArgs.b);
		if (ctx.__error)
		{
			callback(ctx.__error);
			return;
		}
		__Socket_tcpListenWith(callback, target, settings, function(L)
		{
			// tls.Server ignores a `secureContext` option (it builds its own from the
			// options), so the checked certificate and key are passed again.
			var options = {
				cert: tlsArgs.a,
				key: tlsArgs.b,
				allowHalfOpen: true,
				pauseOnConnect: true
			};
			// No list: the client's offer is ignored. Otherwise Node picks the first of the
			// server's protocols the client offers and fails the handshake with a
			// no_application_protocol alert when there is none (as native).
			if (alpn.length) options.ALPNProtocols = alpn;
			var server = _Tls_module().createServer(options);
			var handshaking = new Set();   // raw sockets whose handshake is in progress
			server.on('connection', function(raw)
			{
				handshaking.add(raw);
				raw.once('close', function() { handshaking.delete(raw); });
			});
			server.on('secureConnection', function(tlsSocket)
			{
				var raw = tlsSocket._parent;
				handshaking.delete(raw);
				__Socket_onConnection(L, tlsSocket, { raw: raw, tlsInfo: _Tls_capture(tlsSocket) });
			});
			server.on('tlsClientError', function() { /* dropped; Node destroys the socket */ });
			L.abortPending = function()
			{
				handshaking.forEach(function(raw) { raw.destroy(); });
				handshaking.clear();
			};
			return server;
		});
	});
});

// info : Int -> Task FErr InfoT
var _Tls_info = function(connId)
{
	return __Scheduler_binding(function(callback)
	{
		var c = __Socket_conns[connId];
		if (!c || !c.tlsInfo)
		{
			callback(__Socket_ferr('EINVAL', 'info EINVAL: not a TLS connection'));
			return;
		}
		var i = c.tlsInfo;
		callback(__Scheduler_succeed(__Utils_Tuple3(
			i.__protocol,
			i.__alpn ? __Maybe_Just(i.__alpn) : __Maybe_Nothing,
			i.__cipher
		)));
	});
};
