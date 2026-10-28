// Regression tests for further bugs in compiler/bin/eco-io-handler.js (S2 verification, builder batch).
// Each test pins a bug that is now fixed:
//   1. Console.readAll called again after stdin ended never answers (adds listeners for an 'end' that already fired).
//   2. File.lock is a no-op: a second lock of the same path is granted while the first is held.
//   3. Runtime.loadState returns null for a saved falsy value (`_ecoReplState || null`).
//   4. MVar.drop leaves queued waiters unanswered; a later read on the dropped id throws.
//   5. Http.fetch of a URL `new URL` rejects throws synchronously instead of answering (no BadUrl).
//   6. Http.fetch of a 2xx gzip body that fails to decompress answers 500 (crashes via orCrash).
//   7. Http.getArchive following a relative Location header kills the host with an uncaught TypeError;
//      a redirect loop is followed forever.
// Run: node --test test/scripts/eco-io-handler-builder.test.js
"use strict";
const test = require("node:test");
const assert = require("node:assert");
const path = require("path");
const { spawnSync } = require("child_process");
const HANDLER = path.resolve(__dirname, "../../compiler/bin/eco-io-handler.js");

// Run a snippet in a fresh node process with the handler loaded as `h`; `out` collects [status, body].
function runSnippet(body, input, timeout) {
  const code = `const h = require(${JSON.stringify(HANDLER)});
const http = require("http"); const zlib = require("zlib");
const out = []; const respond = (s, b) => { out.push([s, typeof b === "string" ? b : "<binary>"]); };
const done = () => { console.log("OUT " + JSON.stringify(out)); process.exit(0); };
${body}`;
  return spawnSync(process.execPath, ["-e", code], { input: input || "", encoding: "utf8", timeout: timeout || 10000 });
}
function outOf(r) {
  const line = (r.stdout || "").split("\n").find((l) => l.startsWith("OUT "));
  assert.ok(line, "host never finished: status=" + r.status + " signal=" + r.signal + "\n" + (r.stderr || "").split("\n").slice(0, 6).join("\n"));
  return JSON.parse(line.slice(4));
}

test("Console.readAll answers a second call after stdin has ended", () => {
  const r = runSnippet(`h.handleEcoIO({op:"Console.readAll",args:{}}, respond);
setTimeout(() => { h.handleEcoIO({op:"Console.readAll",args:{}}, respond); setTimeout(done, 500); }, 500);`, "abc");
  const out = outOf(r);
  assert.strictEqual(out.length, 2, "second readAll never answered: " + JSON.stringify(out));
});

test("File.lock excludes a second locker until unlock", () => {
  const r = runSnippet(`const p = require("os").tmpdir() + "/eco-lock-test-" + process.pid;
h.handleEcoIO({op:"File.lock",args:{path:p}}, (s,b) => out.push(["first", s]));
h.handleEcoIO({op:"File.lock",args:{path:p}}, (s,b) => out.push(["second", s]));
setTimeout(done, 300);`);
  const out = outOf(r);
  assert.deepStrictEqual(out.map((x) => x[0]), ["first"], "second lock granted while first held: " + JSON.stringify(out));
});

for (const v of [false, 0, ""]) {
  test(`Runtime.loadState returns saved falsy value ${JSON.stringify(v)}`, () => {
    const r = runSnippet(`h.handleEcoIO({op:"Runtime.saveState",args:${JSON.stringify(v)}}, respond);
h.handleEcoIO({op:"Runtime.loadState",args:{}}, respond); done();`);
    const out = outOf(r);
    assert.deepStrictEqual(JSON.parse(out[1][1]).value, v);
  });
}

test("MVar.drop answers queued waiters and later ops on the id do not throw", () => {
  const r = runSnippet(`h.handleEcoIO({op:"MVar.new",args:{}}, respond);
const id = JSON.parse(out[0][1]).value;
let waiterAnswered = false;
h.handleEcoIO({op:"MVar.read",args:{id}}, () => { waiterAnswered = true; });
h.handleEcoIO({op:"MVar.drop",args:{id}}, respond);
let threw = null;
try { h.handleEcoIO({op:"MVar.read",args:{id}}, respond); } catch (e) { threw = String(e); }
setTimeout(() => { out.push(["waiter", waiterAnswered]); out.push(["threw", threw]); done(); }, 300);`);
  const out = outOf(r);
  assert.deepStrictEqual(out.find((x) => x[0] === "threw"), ["threw", null]);
  assert.deepStrictEqual(out.find((x) => x[0] === "waiter"), ["waiter", true]);
});

test("Http.fetch of an invalid URL answers (BadUrl) instead of throwing", () => {
  const r = runSnippet(`let threw = null;
try { h.handleEcoIO({op:"Http.fetch",args:{method:"GET",url:"not a url",headers:[]}}, respond); } catch (e) { threw = String(e); }
setTimeout(() => { out.push(["threw", threw]); done(); }, 300);`);
  const out = outOf(r);
  assert.deepStrictEqual(out.find((x) => x[0] === "threw"), ["threw", null]);
  assert.ok(out.some((x) => x[0] === 200), "no 200 answer: " + JSON.stringify(out));
});

test("Http.fetch of a corrupt gzip 2xx body answers 200 with an error value, not 500", () => {
  const r = runSnippet(`const srv = http.createServer((q, s) => { s.writeHead(200, {"Content-Encoding":"gzip"}); s.end("garbage not gzip"); });
srv.listen(0, "127.0.0.1", () => {
  h.handleEcoIO({op:"Http.fetch",args:{method:"GET",url:"http://127.0.0.1:" + srv.address().port + "/",headers:[]}}, (s,b) => { respond(s,b); done(); });
});`);
  const out = outOf(r);
  assert.strictEqual(out[0][0], 200, "answered " + JSON.stringify(out));
});

test("Http.getArchive with a relative Location header does not kill the host", () => {
  const r = runSnippet(`process.on("exit", (c) => { if (!out.length) console.error("exited " + c); });
const srv = http.createServer((q, s) => { s.writeHead(302, {Location: "/elsewhere"}); s.end(); });
srv.listen(0, "127.0.0.1", () => {
  h.handleEcoIO({op:"Http.getArchive",args:{url:"http://127.0.0.1:" + srv.address().port + "/a.zip"}}, (s,b) => { respond(s,b); done(); });
});`);
  outOf(r);
});

test("Http.getArchive gives up on a redirect loop", () => {
  const r = runSnippet(`const srv = http.createServer((q, s) => { s.writeHead(302, {Location: "http://127.0.0.1:" + srv.address().port + "/loop"}); s.end(); });
srv.listen(0, "127.0.0.1", () => {
  h.handleEcoIO({op:"Http.getArchive",args:{url:"http://127.0.0.1:" + srv.address().port + "/loop"}}, (s,b) => { respond(s,b); done(); });
});`, "", 8000);
  outOf(r);
});
