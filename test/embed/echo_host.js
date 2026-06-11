/* Node host for the PortEchoTest program compiled as a .node addon.
 *
 * JS twin of echo_host.c: exercises the N-API embedding (eco_node_addon.cpp)
 * end-to-end through the generated CommonJS shim:
 *   - shim require (module shape: exports.Elm.<RootModule>.init)
 *   - flags handshake (PortEchoTest is a `Program ()` — flags are null)
 *   - buffer-until-first-subscribe semantics (the init command `echoOut 42`
 *     fires during init(), before any subscriber exists)
 *   - port introspection via the app.ports object
 *   - echo bounce: payloads from the outgoing `echoOut` port are fed back
 *     into the incoming `echoIn` port, where the Elm side logs + finishes —
 *     the E2E convention of test/ElmE2ETestBase.hpp (the program initiates,
 *     the host echoes)
 *   - sends to a port whose subscription has gone away are dropped
 *     silently, never thrown (JS parity)
 *   - unsubscribe, allowing the documented one trailing callback
 *     (eco_node_addon.cpp, portUnsubscribe)
 *   - cooperative app.stop()
 *
 * Run:
 *   node test/embed/echo_host.js [shim.js]      (default: ./build/elm.js)
 *
 * where shim.js is the sibling shim of an
 * `eco make test/elm/src/PortEchoTest.elm --output=<dir>/elm.node` build.
 *
 * Expected output lines (asserted by the smoke harness; the program's own
 * `PortEchoTest got: 42` / `PortEchoTest done: "ok"` logs land on stderr):
 *   HOST ports: echoOut=out echoIn=in
 *   HOST echoOut: 42
 *   HOST done
 *   HOST exit: 0
 */

'use strict';

const path = require('path');

/* Sends into echoIn: the first is the echo bounce (the program consumes it
 * and drops its echoIn subscription); the remaining N-1 must be swallowed
 * silently. */
const N = 5;

/* Fail-by-default: the addon's threadsafe functions are unref'd (JS parity:
 * port subscriptions alone do not keep the Node loop alive), so a missing
 * delivery would otherwise drain the loop and exit 0 — a false green. */
process.exitCode = 1;
let failed = false;

function fail(msg) {
    failed = true;
    console.error('HOST error: ' + msg);
    process.exit(1);
}

/* 10s guard: unref'd so the timer itself never holds the process open. */
const guard = setTimeout(function () {
    fail('timeout: echo round trip did not complete within 10s');
}, 10000);
guard.unref();

/* Pin the event loop until the test settles (see fail-by-default above). */
const keepalive = setInterval(function () {}, 50);

process.on('exit', function (code) {
    if (code !== 0 && !failed) {
        console.error('HOST error: exited before the echo round trip completed');
    }
});

/* Load the generated shim (it requires the sibling .node addon, and on
 * musl-libc Node reports that glibc-ABI addons are unsupported there). */
const shimPath = process.argv[2] || './build/elm.js';
let mod;
try {
    mod = require(path.resolve(shimPath));
} catch (e) {
    fail('cannot load ' + shimPath + ': ' + e.message);
}
if (!mod || typeof mod.Elm !== 'object') {
    fail(shimPath + ' does not export an Elm namespace');
}

/* The root module name is baked into the addon (__eco_root_module). Pair
 * with PortEchoTest, falling back to a sole exported module so the harness
 * survives a test-program rename. */
const rootNames = Object.keys(mod.Elm);
const root = mod.Elm.PortEchoTest ||
    (rootNames.length === 1 ? mod.Elm[rootNames[0]] : null);
if (!root) {
    fail('no PortEchoTest module in Elm.{' + rootNames.join(', ') + '}');
}

const app = root.init({ flags: null });

/* Ready handshake: init returned, so ports are registered. Direction is
 * reflected in the per-port surface (subscribe vs send). */
const out = app.ports && app.ports.echoOut;
const inp = app.ports && app.ports.echoIn;
if (!out || !inp) {
    fail('expected ports echoOut/echoIn, found: ' +
         Object.keys(app.ports || {}).join(', '));
}
console.log('HOST ports: echoOut=' +
            (typeof out.subscribe === 'function' ? 'out' : 'BAD') +
            ' echoIn=' + (typeof inp.send === 'function' ? 'in' : 'BAD'));

let deliveries = 0;

function onEchoOut(value) {
    deliveries += 1;
    if (deliveries > 1) {
        /* Unsubscribed below — the contract allows one trailing callback. */
        if (deliveries > 2) fail('echoOut fired ' + deliveries + ' times');
        return;
    }
    if (value !== 42) {
        fail('echoOut delivered ' + JSON.stringify(value) + ', expected 42');
    }
    console.log('HOST echoOut: ' + value);
    out.unsubscribe(onEchoOut);

    /* Bounce it back (send #1: the Elm side logs + finishes) and keep
     * sending: the program consumes the first message and unsubscribes
     * echoIn, so sends #2..N must be dropped silently, never thrown. */
    for (let i = 0; i < N; i++) {
        inp.send(value + i);
    }

    /* The program's half of the round trip is observable only as its
     * Debug.log lines on stderr; give the eco thread a beat to drain the
     * queued sends before stopping it. */
    setTimeout(function () {
        clearTimeout(guard);
        clearInterval(keepalive);
        console.log('HOST done');
        app.stop();
        console.log('HOST exit: 0');
        process.exitCode = 0;
    }, 250);
}

/* Subscribe AFTER init returned: the init-time `echoOut 42` had no
 * subscriber yet, so it was buffered and must flush, in order, to this
 * first subscriber. */
out.subscribe(onEchoOut);
