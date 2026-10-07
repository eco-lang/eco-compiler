// js-e2e-http-server.js — the Node twin of test/TestHttpServer.hpp for the JS E2E runner
// (test/scripts/run-js-e2e.js, plans/eco-system-library.md Phase 10).
//
// A raw `net` server (not node:http, which would add its own headers) that serves the
// endpoints the eco-system tests use, byte for byte as TestHttpServer.hpp does: every
// response is `HTTP/1.1`, `Connection: close`, and the connection is closed after it.
//
//   /anything              200 JSON {"method","contentType","body","headers"} (headers
//                          lower-cased, sorted, last value wins; chunked request bodies
//                          are de-chunked)
//   /status/<n>            <n> "Status", text/plain "status <n>" (n <= 0 -> 200)
//   /echo-headers[?dup=1]  200 JSON of the request headers, plus X-Test-Server: eco
//                          (and X-Dup: one / X-Dup: two with dup=1)
//   /bytes/<n>             200 application/octet-stream, bytes i & 0xff
//   /slow[?ms=3000]        waits ms, then 200 "slow"
//   /drip[?bytes=1024&ms=500]          Content-Length body in 8 chunks over ~ms
//   /drip-chunked[?bytes=1024&ms=500]  chunked body in 8 chunks over ~ms
//   /truncate              promises Content-Length: 1000, sends 10 bytes, closes
//   /redirect              302 Found, Location: /anything
//   anything else          404 "Not Found", text/plain "not found"
// HTTPS (TestHttpServer's second port) and /package.zip are not served.
'use strict';

const net = require('net');

function queryLong(query, key, def) {
    const pat = key + '=';
    const pos = query.indexOf(pat);
    if (pos < 0) return def;
    const v = parseInt(query.slice(pos + pat.length), 10);
    return Number.isNaN(v) ? 0 : v;
}

// Strings here are latin1 ("binary"): one char per byte, as std::string.
function jsonEscape(s) {
    let out = '';
    for (const c of s) {
        if (c === '"' || c === '\\') out += '\\' + c;
        else if (c === '\n') out += '\\n';
        else if (c === '\r') out += '\\r';
        else out += c;
    }
    return out;
}

function headersJson(headers) {
    const keys = Object.keys(headers).sort();
    return '{' + keys.map((k) => '"' + jsonEscape(k) + '":"' + jsonEscape(headers[k]) + '"').join(',') + '}';
}

function response(status, reason, contentType, body, extraHeaders) {
    return Buffer.from(
        'HTTP/1.1 ' + status + ' ' + reason + '\r\n' +
        'Content-Type: ' + contentType + '\r\n' +
        'Content-Length: ' + Buffer.byteLength(body, 'latin1') + '\r\n' +
        'Connection: close\r\n' +
        (extraHeaders || '') +
        '\r\n' +
        body, 'latin1');
}

// Parses one request out of `buf` (a latin1 string). Returns null while incomplete.
function parseRequest(buf) {
    const headerEnd = buf.indexOf('\r\n\r\n');
    if (headerEnd < 0) return null;
    const lines = buf.slice(0, headerEnd).split('\n').map((l) => l.replace(/\r$/, ''));
    const [method = '', path = ''] = lines[0].split(/\s+/);
    const headers = {};
    for (const line of lines.slice(1)) {
        if (!line) continue;
        const colon = line.indexOf(':');
        if (colon < 0) continue;
        headers[line.slice(0, colon).toLowerCase()] = line.slice(colon + 1).replace(/^[ \t]+/, '');
    }
    const rest = buf.slice(headerEnd + 4);
    const te = headers['transfer-encoding'];
    if (te && te.includes('chunked')) {
        let pos = 0;
        let body = '';
        for (;;) {
            const eol = rest.indexOf('\r\n', pos);
            if (eol < 0) return null;
            const size = parseInt(rest.slice(pos, eol), 16) || 0;
            pos = eol + 2;
            if (size === 0) {
                if (rest.indexOf('\r\n', pos) < 0) return null;   // trailers end with an empty line
                return { method, path, headers, body };
            }
            if (rest.length < pos + size + 2) return null;
            body += rest.slice(pos, pos + size);
            pos += size + 2;
        }
    }
    const contentLength = parseInt(headers['content-length'] || '0', 10) || 0;
    if (rest.length < contentLength) return null;
    return { method, path, headers, body: rest.slice(0, contentLength) };
}

function handle(socket, req) {
    let route = req.path;
    const q = route.indexOf('?');
    const query = q < 0 ? '' : route.slice(q + 1);
    if (q >= 0) route = route.slice(0, q);
    const send = (buf) => { if (!socket.destroyed) socket.write(buf); };
    const finish = () => { if (!socket.destroyed) socket.end(); };
    const later = (ms, fn) => setTimeout(() => { if (!socket.destroyed) fn(); }, ms);

    if (route === '/anything') {
        const body = '{"method":"' + jsonEscape(req.method) + '",' +
            '"contentType":"' + jsonEscape(req.headers['content-type'] || '') + '",' +
            '"body":"' + jsonEscape(req.body) + '",' +
            '"headers":' + headersJson(req.headers) + '}';
        send(response(200, 'OK', 'application/json', body));
        finish();
    } else if (route.startsWith('/status/')) {
        let code = parseInt(route.slice(8), 10) || 0;
        if (code <= 0) code = 200;
        send(response(code, 'Status', 'text/plain', 'status ' + code));
        finish();
    } else if (route === '/echo-headers') {
        let extra = 'X-Test-Server: eco\r\n';
        if (queryLong(query, 'dup', 0) === 1) extra += 'X-Dup: one\r\nX-Dup: two\r\n';
        send(response(200, 'OK', 'application/json', headersJson(req.headers), extra));
        finish();
    } else if (route.startsWith('/bytes/')) {
        const n = Math.max(0, parseInt(route.slice(7), 10) || 0);
        let body = '';
        const parts = [];
        for (let i = 0; i < n; i++) {
            parts.push(String.fromCharCode(i & 0xff));
            if (parts.length === 65536) { body += parts.join(''); parts.length = 0; }
        }
        body += parts.join('');
        send(response(200, 'OK', 'application/octet-stream', body));
        finish();
    } else if (route === '/slow') {
        const pos = query.indexOf('ms=');
        const ms = pos < 0 ? 3000 : (parseInt(query.slice(pos + 3), 10) || 0);
        later(ms, () => { send(response(200, 'OK', 'text/plain', 'slow')); finish(); });
    } else if (route === '/drip' || route === '/drip-chunked') {
        const chunked = route === '/drip-chunked';
        const bytes = Math.max(0, queryLong(query, 'bytes', 1024));
        const ms = queryLong(query, 'ms', 500);
        const kChunks = 8;
        send(Buffer.from('HTTP/1.1 200 OK\r\n' +
            'Content-Type: application/octet-stream\r\n' +
            (chunked ? 'Transfer-Encoding: chunked\r\n' : 'Content-Length: ' + bytes + '\r\n') +
            'Connection: close\r\n\r\n', 'latin1'));
        const perChunk = Math.max(1, Math.floor((bytes + kChunks - 1) / kChunks));
        let written = 0;
        const step = () => {
            if (written >= bytes) {
                if (chunked) send(Buffer.from('0\r\n\r\n', 'latin1'));
                finish();
                return;
            }
            const n = Math.min(perChunk, bytes - written);
            const data = 'x'.repeat(n);
            send(Buffer.from(chunked ? n.toString(16) + '\r\n' + data + '\r\n' : data, 'latin1'));
            written += n;
            if (written < bytes) later(Math.floor(ms / kChunks), step);
            else step();
        };
        step();
    } else if (route === '/truncate') {
        send(Buffer.from('HTTP/1.1 200 OK\r\n' +
            'Content-Type: application/octet-stream\r\n' +
            'Content-Length: 1000\r\n' +
            'Connection: close\r\n\r\n' +
            '0123456789', 'latin1'));
        finish();
    } else if (route === '/redirect') {
        send(response(302, 'Found', 'text/plain', '', 'Location: /anything\r\n'));
        finish();
    } else {
        send(response(404, 'Not Found', 'text/plain', 'not found'));
        finish();
    }
}

// Starts the server on 127.0.0.1:<preferredPort> (0 = any; a busy preferred port falls
// back to any). Resolves to { port, close() }.
function startTestHttpServer(preferredPort) {
    const server = net.createServer((socket) => {
        let buf = '';
        let handled = false;
        socket.on('error', () => {});   // clients hang up mid-body (Http.Stream kill tests)
        socket.on('data', (chunk) => {
            if (handled) return;
            buf += chunk.toString('latin1');
            if (buf.length > (1 << 20) && buf.indexOf('\r\n\r\n') < 0) { socket.destroy(); return; }
            const req = parseRequest(buf);
            if (!req) return;
            handled = true;
            handle(socket, req);
        });
    });
    const listen = (port) => new Promise((resolve, reject) => {
        const onError = (e) => { server.removeListener('listening', onListening); reject(e); };
        const onListening = () => { server.removeListener('error', onError); resolve(); };
        server.once('error', onError);
        server.once('listening', onListening);
        server.listen(port, '127.0.0.1', 64);
    });
    return listen(preferredPort || 0)
        .catch(() => listen(0))
        .then(() => ({
            port: server.address().port,
            close: () => new Promise((resolve) => server.close(() => resolve())),
            unref: () => server.unref(),
        }));
}

module.exports = { startTestHttpServer };
