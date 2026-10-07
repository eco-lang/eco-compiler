// js-e2e-xhr.js — a minimal XMLHttpRequest for Node, installed by the JS E2E runner
// (test/scripts/run-js-e2e.js) before each test starts, so that elm/http (whose JS kernel
// uses XMLHttpRequest) works in the eco-system tests on the JS target, as the native
// elm/http kernel does on the native one (the Http.Server tests use elm/http as their
// client). It covers what elm/http's Http.js uses: open/setRequestHeader/send/abort,
// timeout, responseType ('' / 'text' / 'arraybuffer' / 'json'), status, statusText,
// responseURL, getAllResponseHeaders, response, and the load/error/timeout/progress
// events. Each setRequestHeader call becomes its own header line (as libcurl sends them,
// unlike a browser's ", " join); response header names are lower-cased, one line per
// header; redirects are followed (at most 20). No cookies, no CORS, no upload progress.
'use strict';

const http = require('http');
const https = require('https');

class NodeXMLHttpRequest {
    constructor() {
        this._listeners = {};
        this.upload = { addEventListener() {} };
        this.readyState = 0;
        this.status = 0;
        this.statusText = '';
        this.response = null;
        this.responseText = '';
        this.responseURL = '';
        this.responseType = '';
        this.timeout = 0;
        this.withCredentials = false;
        this._headers = [];
        this._responseHeaders = [];
        this._req = null;
        this._done = false;
    }

    addEventListener(type, fn) {
        (this._listeners[type] = this._listeners[type] || []).push(fn);
    }

    _emit(type, extra) {
        const ev = Object.assign({ type, target: this }, extra || {});
        for (const fn of this._listeners[type] || []) fn.call(this, ev);
        const prop = this['on' + type];
        if (typeof prop === 'function') prop.call(this, ev);
    }

    open(method, url) {
        const u = new URL(url);   // throws on a bad URL: elm/http reports BadUrl_
        if (u.protocol !== 'http:' && u.protocol !== 'https:') throw new TypeError('unsupported protocol ' + u.protocol);
        this._method = String(method);
        this._url = u;
        this.readyState = 1;
    }

    setRequestHeader(name, value) {
        this._headers.push([String(name), String(value)]);
    }

    getAllResponseHeaders() {
        return this._responseHeaders.map(([k, v]) => k + ': ' + v + '\r\n').join('');
    }

    getResponseHeader(name) {
        const lower = String(name).toLowerCase();
        const values = this._responseHeaders.filter(([k]) => k === lower).map(([, v]) => v);
        return values.length ? values.join(', ') : null;
    }

    abort() {
        this._finish();
        if (this._req) this._req.destroy();
    }

    _finish() {
        if (this._done) return false;
        this._done = true;
        if (this._timer) clearTimeout(this._timer);
        return true;
    }

    send(body) {
        Promise.resolve(toBuffer(body)).then(
            (buf) => this._start(this._method, this._url, buf, 0),
            () => { if (this._finish()) this._emit('error'); });
        if (this.timeout > 0) {
            this._timer = setTimeout(() => {
                if (!this._finish()) return;
                if (this._req) this._req.destroy();
                this._emit('timeout');
            }, this.timeout);
        }
    }

    _start(method, url, body, redirects) {
        if (this._done) return;
        const req = (url.protocol === 'https:' ? https : http).request(url, { method, agent: false });
        this._req = req;
        for (const [k, v] of this._headers) {
            try {
                if (k.toLowerCase() === 'host') req.setHeader(k, v); else req.appendHeader(k, v);
            } catch (e) { /* invalid header: dropped */ }
        }
        if (body && !req.hasHeader('content-length')) req.setHeader('Content-Length', String(body.length));
        req.on('error', () => { if (this._finish()) this._emit('error'); });
        req.on('response', (res) => {
            if (this._done) { res.destroy(); return; }
            const loc = res.headers.location;
            if (loc && [301, 302, 303, 307, 308].includes(res.statusCode) && redirects < 20) {
                res.destroy();
                let next;
                try { next = new URL(loc, url); } catch (e) { if (this._finish()) this._emit('error'); return; }
                const toGet = res.statusCode === 303 || ((res.statusCode === 301 || res.statusCode === 302) && method === 'POST');
                this._start(toGet ? 'GET' : method, next, toGet ? null : body, redirects + 1);
                return;
            }
            const chunks = [];
            res.on('data', (c) => chunks.push(c));
            res.on('error', () => { if (this._finish()) this._emit('error'); });
            res.on('end', () => {
                if (!this._finish()) return;
                const buf = Buffer.concat(chunks);
                this.status = res.statusCode;
                this.statusText = res.statusMessage || '';
                this.responseURL = url.href;
                const raw = res.rawHeaders;
                this._responseHeaders = [];
                for (let i = 0; i + 1 < raw.length; i += 2) this._responseHeaders.push([raw[i].toLowerCase(), raw[i + 1]]);
                if (this.responseType === 'arraybuffer') {
                    this.response = buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength);
                } else if (this.responseType === 'json') {
                    try { this.response = JSON.parse(buf.toString('utf8')); } catch (e) { this.response = null; }
                } else {
                    this.responseText = buf.toString('utf8');
                    this.response = this.responseText;
                }
                this.readyState = 4;
                this._emit('progress', { loaded: buf.length, total: buf.length, lengthComputable: true });
                this._emit('load');
            });
        });
        if (body) req.end(body); else req.end();
    }
}

function toBuffer(body) {
    if (body === null || body === undefined) return null;
    if (typeof body === 'string') return Buffer.from(body, 'utf8');
    if (body instanceof ArrayBuffer) return Buffer.from(body);
    if (ArrayBuffer.isView(body)) return Buffer.from(body.buffer, body.byteOffset, body.byteLength);
    if (typeof Blob !== 'undefined' && body instanceof Blob) return body.arrayBuffer().then((ab) => Buffer.from(ab));
    return Buffer.from(String(body), 'utf8');
}

if (typeof globalThis.XMLHttpRequest === 'undefined') {
    globalThis.XMLHttpRequest = NodeXMLHttpRequest;
}

module.exports = { NodeXMLHttpRequest };
