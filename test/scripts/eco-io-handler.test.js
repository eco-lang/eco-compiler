// Regression tests for bugs in compiler/bin/eco-io-handler.js (recomment-bugs.txt),
// all fixed:
//   1. Console.readLine answers twice (rl.close() fires 'close' -> respond("") before respond(line)).
//   2. Process.spawn / Process.spawnProcess of a missing command crash the host (no 'error' listener).
//   3. Process.wait never answers if the child already exited.
//   4. Process.wait reports a signal-killed child (code null) as exit 0.
// Run: node --test test/scripts/eco-io-handler.test.js
"use strict";
const test = require("node:test");
const assert = require("node:assert");
const path = require("path");
const { spawnSync } = require("child_process");
const HANDLER = path.resolve(__dirname, "../../compiler/bin/eco-io-handler.js");

// Run a snippet in a fresh node process with the handler loaded as `h`.
function runSnippet(body, input) {
  const code = `const h = require(${JSON.stringify(HANDLER)});
const out = []; const respond = (s, b) => { out.push([s, b]); };
${body}`;
  return spawnSync(process.execPath, ["-e", code], { input: input || "", encoding: "utf8", timeout: 10000 });
}

test("Console.readLine answers exactly once with the line", () => {
  const r = runSnippet(`h.handleEcoIO({op:"Console.readLine",args:{}}, respond);
setTimeout(() => { console.log(JSON.stringify(out)); process.exit(0); }, 500);`, "hello\n");
  const out = JSON.parse(r.stdout.trim().split("\n").pop());
  assert.deepStrictEqual(out, [[200, JSON.stringify({ value: "hello" })]]);
});

for (const op of ["Process.spawn", "Process.spawnProcess"]) {
  test(`${op} of a missing command does not crash the host`, () => {
    const r = runSnippet(`h.handleEcoIO({op:${JSON.stringify(op)},args:{cmd:"/nonexistent/eco-no-such-cmd",args:[],stdin:"inherit",stdout:"inherit",stderr:"inherit"}}, respond);
setTimeout(() => { console.log("ALIVE"); process.exit(0); }, 500);`);
    assert.strictEqual(r.status, 0, "host crashed: " + r.stderr.split("\n").slice(0, 6).join("\n"));
    assert.match(r.stdout, /ALIVE/);
  });
}

test("Process.wait answers when the child has already exited", () => {
  const r = runSnippet(`h.handleEcoIO({op:"Process.spawn",args:{cmd:"true",args:[]}}, respond);
const id = JSON.parse(out[0][1]).value;
setTimeout(() => {
  h.handleEcoIO({op:"Process.wait",args:{handle:id}}, respond);
  setTimeout(() => { console.log(JSON.stringify(out.slice(1))); process.exit(0); }, 500);
}, 1000);`);
  const out = JSON.parse(r.stdout.trim().split("\n").pop());
  assert.deepStrictEqual(out, [[200, JSON.stringify({ value: 0 })]]);
});

test("Process.wait reports a signal-killed child as a failure", () => {
  const r = runSnippet(`h.handleEcoIO({op:"Process.spawn",args:{cmd:"sh",args:["-c","kill -9 $$"]}}, respond);
const id = JSON.parse(out[0][1]).value;
h.handleEcoIO({op:"Process.wait",args:{handle:id}}, respond);
setTimeout(() => { console.log(JSON.stringify(out.slice(1))); process.exit(0); }, 1500);`);
  const out = JSON.parse(r.stdout.trim().split("\n").pop());
  assert.strictEqual(out.length, 1);
  assert.notStrictEqual(JSON.parse(out[0][1]).value, 0, "signal-killed child reported as exit 0");
});
