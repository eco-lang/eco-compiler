/* Node host for the lifecycle of a program compiled as a .node addon (eco_node_addon.cpp): that
 * app.stop() returns a Promise, and that nothing the addon creates keeps Node's event loop alive
 * once the program has stopped or failed to start.
 *
 * Run:
 *   node test/embed/lifecycle_host.js <shim.js> <mode> [go-file]
 *
 * where shim.js is the sibling shim of an
 * `eco make test/elm/src/PortEchoTest.elm --output=<dir>/elm.node` build, and mode is one of:
 *
 *   stop-promise     app.stop() returns a Promise that resolves to the program's exit code (0),
 *                    and Node then exits by itself.
 *   send-after-stop  a send on an incoming port after the stop has resolved (and the stopped
 *                    program's last idle report has been handled) does not hold the event loop:
 *                    Node exits by itself.
 *   failed-start     waits until <go-file> exists (the harness, test/embed/run-node-addon-tests.sh,
 *                    first lowers this process's RLIMIT_NPROC so that the eco thread cannot be
 *                    created), then init() must throw, a retried init() must throw, and Node must
 *                    exit by itself.
 *
 * Each mode prints `HOST ok: <mode>` and exits 0 on success. Every wait the script itself makes is
 * unreferenced, so a handle the addon leaks is what keeps the process alive, and the unreferenced
 * guard timer then fails the run.
 */

'use strict';

const fs = require('fs');
const path = require('path');

process.exitCode = 1;

function fail(msg) {
    console.error('HOST error: ' + msg);
    process.exit(1);
}

/* Fires only while something else holds the loop: a leaked keepalive. */
const guard = setTimeout(function () {
    fail('timeout: the event loop was still held after 10s');
}, 10000);
guard.unref();

const shimPath = process.argv[2];
const mode = process.argv[3];
const goFile = process.argv[4];
if (!shimPath || !mode) fail('usage: lifecycle_host.js <shim.js> <mode> [go-file]');

const mod = require(path.resolve(shimPath));
const rootNames = Object.keys(mod.Elm);
const root = mod.Elm.PortEchoTest || (rootNames.length === 1 ? mod.Elm[rootNames[0]] : null);
if (!root) fail('no PortEchoTest module in Elm.{' + rootNames.join(', ') + '}');

function succeed() {
    console.log('HOST ok: ' + mode);
    process.exitCode = 0;
}

/* Starts the program and calls `then(app)` once its init-time `echoOut 42` has arrived, so the
 * program is known to be running. */
function startAndWait(then) {
    const app = root.init({ flags: null });
    let seen = false;
    app.ports.echoOut.subscribe(function onOut(value) {
        if (seen) return;
        seen = true;
        if (value !== 42) fail('echoOut delivered ' + JSON.stringify(value));
        app.ports.echoOut.unsubscribe(onOut);
        then(app);
    });
}

function stopToPromise(app) {
    const p = app.stop();
    if (!p || typeof p.then !== 'function') fail('app.stop() returned ' + p + ', not a Promise');
    return p;
}

if (mode === 'stop-promise') {
    startAndWait(function (app) {
        stopToPromise(app).then(function (code) {
            if (code !== 0) fail('app.stop() resolved to ' + code + ', expected 0');
            succeed();
        }, function (e) {
            fail('app.stop() rejected: ' + e);
        });
    });
} else if (mode === 'send-after-stop') {
    startAndWait(function (app) {
        /* Promise.resolve, not stopToPromise: this mode tests the send, whatever stop returns. */
        Promise.resolve(app.stop()).then(function () {
            /* After the stopped program's last idle report has been handled, which would
             * otherwise unreference the keepalive this send references. */
            setTimeout(function () {
                try {
                    app.ports.echoIn.send(7);
                } catch (e) {
                    /* Refusing the send is fine; holding the loop is not. */
                }
                succeed();
            }, 300);
        });
    });
} else if (mode === 'failed-start') {
    if (!goFile) fail('failed-start needs a go-file');
    /* Referenced poll: holds the loop until the harness has lowered the limit. */
    const poll = setInterval(function () {
        if (!fs.existsSync(goFile)) return;
        clearInterval(poll);
        let threw = 0;
        try { root.init({ flags: null }); } catch (e) { threw += 1; }
        try { root.init({ flags: null }); } catch (e) { threw += 1; }
        if (threw !== 2) fail('init() threw ' + threw + ' of 2 times with no thread available');
        succeed();
    }, 20);
    console.log('HOST waiting: ' + process.pid);
} else {
    fail('unknown mode ' + mode);
}
