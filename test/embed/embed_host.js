/* A host that drives the same Elm program built two ways, for the JS backend (a .js file) and as a
 * Node addon (the .js shim of a .node), through the same API: Elm.<Root>.init({ flags }) and
 * app.ports.<port>.subscribe / unsubscribe / send. run-node-addon-tests.sh runs every scenario in
 * both modes and requires both runs to pass and their stdout transcripts to be identical, which is
 * the demonstration that the addon behaves as the JS backend does.
 *
 * Run:
 *   node --expose-gc test/embed/embed_host.js <js|node> <shim.js> <scenario>
 *   node test/embed/embed_host.js list        (one `<fixture> <scenario>` line per scenario)
 *
 * stdout is the transcript: only what must be the same in both modes. stderr carries what may
 * differ: the mode's own details, and the KNOWN DIVERGENCES, which are asserted per mode (so a fix
 * makes the check fail until it is updated) and printed as `DIVERGENCE ...` lines.
 *
 * Scenarios, by the fixture program they need:
 *
 *   BytesEchoService.elm   bytes        the bytes ports (PORT_008): the four start-up payloads (the
 *                                       empty Bytes, 1 byte, 100,000 bytes, a 50,000-byte slice),
 *                                       every value send takes (a Uint8Array, an ArrayBuffer, a
 *                                       DataView), rejected sends, unsubscribe and a
 *                                       new subscriber, and a leak soak
 *                          unit-flags:N a `()` program started with flags variant N
 *   ValuesService.elm      values       record flags echoed back, and a round trip of each JSON
 *                                       payload type (String, Int, Float, Bool, (), Maybe, List,
 *                                       Array, 2- and 3-tuples, a record, Json.Value), and sends
 *                                       that throw at once
 *                          bad-flags    flags that do not decode: init throws, and may be retried
 *                          bad-send     sends of values of the wrong type: each throws at once
 *                          order        a send from inside a subscriber, against a Task in the same batch
 *   JsonFlagsService.elm   json-flags:N any JSON as flags, echoed back, variant N
 *
 * In every scenario the addon must have app.stop() and stop with exit code 0; the JS backend has
 * no stop, and the program is simply left to Node, which exits once nothing is pending.
 *
 * KNOWN DIVERGENCES (2026-11-06; report in plans/native-bytes-ports.md):
 *   D1  (closed 2026-11-06) a port delivered a Cmd.batch's commands first first natively, last
 *       first in Elm; the native managers now handle them last first, as Elm does (PORT_005). The
 *       start-up payloads check the order in both modes.
 *   D2  (closed 2026-11-06) bad flags aborted the addon's process; the addon now checks them before
 *       it starts the program, and init throws as on JS (PORT_009).
 *   D3  (closed 2026-11-06) a send that did not decode aborted the addon's process later; the addon
 *       now checks it on the sending thread, and send throws at once as on JS (PORT_009).
 *   D4  Bytes sent in: on JS the program's Bytes alias the sender's buffer, so a write to it after
 *       the send shows through; the addon copies at the send.
 *   D5  (not observed, 2026-11-06) predicted from elm/core: a send from inside an outgoing subscriber
 *       runs `update` at once on JS but is queued natively. The `order` scenario pins what both do
 *       with such a send and a Task of the same batch: each handles the Task's message first, so the
 *       transcripts match (plans/native-bytes-ports-2.md §2.10).
 */

'use strict';

const path = require('path');

const [MODE, SHIM, SCENARIO] = process.argv.slice(2);
const IS_NODE = MODE === 'node';
const MIB = 1024 * 1024;

process.exitCode = 1;

function fail(msg) {
    console.error('HOST error: ' + msg);
    process.exit(1);
}

function say(line) {
    console.log('HOST ' + line);
}

function note(line) {
    console.error(MODE + ': ' + line);
}

/* Asserts this mode's side of a known divergence and reports it. */
function divergence(id, holds, js, node) {
    if (!holds) fail(id + ' no longer holds in ' + MODE + ' mode (expected: ' + (IS_NODE ? node : js) + ')');
    console.error('DIVERGENCE ' + id + ' (' + MODE + '): ' + (IS_NODE ? node : js));
}

if (MODE !== 'js' && MODE !== 'node' && MODE !== 'list') fail('mode must be js, node or list');

const guard = setTimeout(function () {
    fail('timeout: scenario ' + SCENARIO + ' did not finish within 120s');
}, 120000);
guard.unref();

/* The root module: the name the program was built from, or a sole exported module (the addon
 * may export it as Main). */
function loadRoot() {
    const mod = require(path.resolve(SHIM));
    const names = Object.keys((mod && mod.Elm) || {});
    if (names.length !== 1) fail('expected one module in Elm, found {' + names.join(', ') + '}');
    return mod.Elm[names[0]];
}

function checkStopShape(app) {
    if (IS_NODE && typeof app.stop !== 'function') fail('the addon app has no stop()');
    if (!IS_NODE && app.stop !== undefined) fail('the JS app has a stop; update embed_host.js');
}

/* Ends the scenario: the addon is stopped and must exit 0; the JS program is left to Node. */
async function finish(app) {
    if (IS_NODE) {
        const code = await app.stop();
        if (code !== 0) fail('app.stop() resolved to ' + code);
        note('app.stop() resolved to 0');
    } else {
        note('no app.stop() on the JS backend; Node exits once nothing is pending');
    }
    clearTimeout(guard);
    process.exitCode = 0;
}

function delay(ms) {
    return new Promise(function (r) { setTimeout(r, ms); });
}

/* The deliveries of one outgoing port, in order: next() takes the oldest or waits for it. Each
 * delivery is kept as given and, for a Uint8Array, as a copy taken when it arrived. */
function collector(port) {
    const queue = [];
    let waiter = null;
    let active = true;
    let late = 0;
    function onValue(value) {
        if (!active) {
            late += 1;
            return;
        }
        const item = { value: value, copy: value instanceof Uint8Array ? Uint8Array.from(value) : undefined };
        if (waiter) {
            const w = waiter;
            waiter = null;
            w(item);
        } else {
            queue.push(item);
        }
    }
    port.subscribe(onValue);
    return {
        next: function () {
            return queue.length > 0 ? Promise.resolve(queue.shift()) : new Promise(function (r) { waiter = r; });
        },
        stop: function () {
            port.unsubscribe(onValue);
            active = false;
        },
        late: function () { return late; },
    };
}

function deepEqual(a, b) {
    if (a === b) return true;
    if (typeof a !== typeof b || a === null || b === null || typeof a !== 'object') return false;
    if (Array.isArray(a) !== Array.isArray(b)) return false;
    const ka = Object.keys(a);
    const kb = Object.keys(b);
    if (ka.length !== kb.length) return false;
    return ka.every(function (k) { return Object.prototype.hasOwnProperty.call(b, k) && deepEqual(a[k], b[k]); });
}

/* deepEqual, and for a Json.Value also the same key order, which Json.Value keeps. A port
 * record comes out with its fields in name order, in both modes. */
function sameJson(a, b) {
    return deepEqual(a, b) && JSON.stringify(a) === JSON.stringify(b);
}

function throws(f) {
    try {
        f();
        return null;
    } catch (e) {
        return e;
    }
}

// ---------------------------------------------------------------------------------------------
// bytes

function bytesOf(value) {
    const view = value instanceof ArrayBuffer
        ? new Uint8Array(value)
        : new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
    return Uint8Array.from(view);
}

function sameBytes(a, b) {
    if (a.length !== b.length) return false;
    for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
    return true;
}

function pattern(length, offset) {
    const a = new Uint8Array(length);
    for (let i = 0; i < length; i++) a[i] = (i + offset) % 251;
    return a;
}

async function scenarioBytes() {
    const app = loadRoot().init({ flags: null });
    checkStopShape(app);
    const out = collector(app.ports.bytesOut);
    const inp = app.ports.bytesIn;

    /* The four start-up payloads, sent before this subscription. */
    const want = [new Uint8Array(0), Uint8Array.of(7), pattern(100000, 0), pattern(50000, 10)];
    const got = [];
    for (let i = 0; i < 4; i++) got.push((await out.next()).copy);
    /* A Cmd.batch reaches its manager last first, as in Elm (PORT_005). */
    want.reverse();
    for (let i = 0; i < 4; i++) {
        if (!sameBytes(got[i], want[i])) fail('start-up payload ' + i + ': ' + got[i].length + ' bytes, expected ' + want[i].length);
    }
    say('bytes start-up: ' + JSON.stringify(got.map(function (g) { return g.length; })) + ' byte for byte, last first');

    /* Every value send takes. */
    const ten = Uint8Array.from([0, 1, 2, 3, 4, 5, 6, 7, 8, 9]);
    const eight = new ArrayBuffer(8);
    new Uint8Array(eight).set([0, 1, 2, 3, 4, 5, 6, 7]);
    const big = new Uint8Array(MIB);
    for (let i = 0; i < big.length; i++) big[i] = (i * 7 + 3) & 0xff;
    const inputs = [
        ['Uint8Array', Uint8Array.of(1, 2, 3)],
        ['Uint8Array sub-view', ten.subarray(3, 7)],
        ['ArrayBuffer', Uint8Array.of(4, 5, 6, 7).buffer],
        ['DataView with an offset', new DataView(Uint8Array.of(9, 8, 7, 6, 5).buffer, 1, 3)],
        ['empty Uint8Array', new Uint8Array(0)],
        ['empty ArrayBuffer', new ArrayBuffer(0)],
        ['empty DataView', new DataView(new ArrayBuffer(4), 4, 0)],
        ['1 MiB Uint8Array', big],
    ];
    let aliased = 0;
    for (const [label, value] of inputs) {
        const sent = bytesOf(value);
        inp.send(value);
        /* A write to the source after the send: D4. */
        if (sent.length > 0) {
            const view = value instanceof ArrayBuffer
                ? new Uint8Array(value)
                : new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
            view[0] ^= 0xff;
        }
        const written = bytesOf(value);
        const item = await out.next();
        if (!(item.value instanceof Uint8Array)) fail(label + ': delivered ' + Object.prototype.toString.call(item.value));
        /* The addon's echo is the bytes as sent. The JS backend's is a view of the sender's own
         * buffer (D4), whenever it arrives, so it shows the write. */
        const want = IS_NODE ? sent : written;
        if (!sameBytes(item.value, want)) {
            fail(label + ': the echo ' + JSON.stringify(Array.from(item.value.slice(0, 8))) + ' (' + item.value.length +
                 ' bytes) is not ' + JSON.stringify(Array.from(want.slice(0, 8))) + ' (' + want.length + ' bytes)');
        }
        if (sent.length > 0 && !sameBytes(sent, written)) aliased += IS_NODE ? 0 : 1;
    }
    say('bytes send: ' + inputs.length + ' kinds of value echoed byte for byte');
    const written = inputs.filter(function (i) { return bytesOf(i[1]).length > 0; }).length;
    divergence('D4', IS_NODE || aliased === written,
               'the program\'s Bytes alias the sent buffer: a write after the send shows through (' + aliased + ' of ' + written + ')',
               'send copies: a write after the send does not show through (' + written + ' of ' + written + ')');

    /* Values send rejects. */
    const rejected = [
        ['a plain array', [1, 2, 3]],
        ['a string', 'bytes'],
        ['undefined', undefined],
        ['an object', { length: 1, 0: 1 }],
        ['a SharedArrayBuffer', new SharedArrayBuffer(4)],
        ['an Int16Array', new Int16Array(eight, 2, 2)],
        ['a Float64Array', Float64Array.of(1.5, -2.25)],
        ['a Uint8ClampedArray', Uint8ClampedArray.of(1, 2)],
    ];
    for (const [label, value] of rejected) {
        const e = throws(function () { inp.send(value); });
        if (!e) fail('send of ' + label + ' did not throw');
        note('send of ' + label + ' threw ' + e.constructor.name);
    }
    say('bytes rejected sends: ' + rejected.length + ' throw');

    /* No leak over 600 round trips of 1 MiB, measured once the heaps have reached their working
     * size (RSS levels off within the first 150 or so). Leaking either direction's copy adds
     * 600 MiB; checked with negative controls 2026-11-06. */
    const rss = function () {
        global.gc();
        return process.memoryUsage().rss;
    };
    for (let i = 0; i < 200; i++) {
        inp.send(big);
        await out.next();
        if (i % 50 === 49) global.gc();
    }
    const before = rss();
    for (let i = 0; i < 600; i++) {
        inp.send(big);
        if ((await out.next()).value.length !== MIB) fail('soak round trip ' + i);
        if (i % 50 === 49) global.gc();
    }
    await delay(100);
    const growth = (rss() - before) / MIB;
    note('soak RSS ' + (growth >= 0 ? '+' : '') + growth.toFixed(1) + ' MiB');
    if (growth > 64) fail('RSS grew ' + growth.toFixed(1) + ' MiB over 600 round trips of 1 MiB');
    say('bytes soak: 600 x 1 MiB round trips, RSS within 64 MiB');

    /* Unsubscribe, then a new subscriber. */
    out.stop();
    inp.send(Uint8Array.of(42));
    await delay(250);
    if (out.late() > 1) fail('the unsubscribed function was called ' + out.late() + ' times');
    const second = collector(app.ports.bytesOut);
    inp.send(Uint8Array.of(43));
    if (!sameBytes((await second.next()).value, Uint8Array.of(43))) fail('new subscriber got the wrong bytes');
    second.stop();
    say('bytes unsubscribe: at most one trailing call; a new subscriber is served');

    await finish(app);
}

// ---------------------------------------------------------------------------------------------
// values

const FLAGS = {
    name: 'Zoë ☃ 😀 "q" \\ \n',
    count: -42,
    ratio: 0.1,
    on: true,
    some: 7,
    none: null,
    ints: [1, -2, 2147483647, 9007199254740991],
    strings: ['', 'a', 'é'],
    pair: [3, 'three'],
    nested: { inner: { deep: [[true, 1.5], [false, -0.25]] } },
    json: { z: 1, a: [null, true, { m: 'x' }], k: 1.25 },
    unit: null,
};

/* Port name prefix, the values sent, and how each must come back (the value itself when absent). */
const VALUES = [
    ['string', ['', 'hello', 'Zoë ☃ 😀', 'quote " backslash \\ newline \n tab \t', '\u0000 \u001f \u007f', 'x'.repeat(100000)]],
    ['int', [0, -1, 42, 2147483647, -2147483648, 9007199254740991, -9007199254740991]],
    ['float', [0, 1.5, -2.25, 0.1, 1 / 3, 1e300, 5e-324, -1e-7, 3]],
    ['bool', [true, false]],
    ['unit', [null]],
    ['maybe', [null, 0, 5]],
    ['list', [[], [1, 2, 3], Array.from({ length: 1000 }, function (_, i) { return i * 3; })]],
    ['array', [[], ['a', 'b', 'ü']]],
    ['tuple2', [[1, 'x'], [-5, '']]],
    ['tuple3', [[true, 2.5, 'z'], [false, -0.5, '']]],
    ['record', [{ id: 1, tags: ['a', 'b'], child: { ok: true } },
                [{ id: 2, tags: [], child: { ok: false }, extra: 9 }, { id: 2, tags: [], child: { ok: false } }]]],
    ['json', [null, true, 3, -1.5, 'str', [], {}, [1, 'two', null, { three: [3] }],
              { z: 1, a: 2, m: { y: [true, false], b: null } }, { 'ü key': 'v', '': 0 },
              JSON.parse('[' + '['.repeat(50) + ']'.repeat(50) + ']')]],
];

async function scenarioValues() {
    const app = loadRoot().init({ flags: FLAGS });
    checkStopShape(app);

    const flagsOut = collector(app.ports.flagsOut);
    const echoed = (await flagsOut.next()).value;
    if (!deepEqual(echoed, FLAGS) || JSON.stringify(echoed.json) !== JSON.stringify(FLAGS.json)) {
        fail('flags came back as ' + JSON.stringify(echoed));
    }
    flagsOut.stop();
    say('values flags: ' + JSON.stringify(echoed));

    for (const [kind, cases] of VALUES) {
        const out = collector(app.ports[kind + 'Out']);
        const inp = app.ports[kind + 'In'];
        for (const c of cases) {
            const [sent, want] = kind === 'record' && Array.isArray(c) ? c : [c, c];
            inp.send(sent);
            const got = (await out.next()).value;
            if (!(kind === 'json' ? sameJson(got, want) : deepEqual(got, want))) fail(kind + ' ' + JSON.stringify(sent).slice(0, 80) + ' came back as ' + JSON.stringify(got).slice(0, 80));
            const shown = JSON.stringify(got);
            say('values ' + kind + ': ' + (shown.length > 100 ? shown.slice(0, 60) + '... (' + shown.length + ' chars)' : shown));
        }
        out.stop();
    }

    /* Sends that throw at once in both modes: values that are not JSON. */
    const bad = [
        ['undefined into intIn', 'intIn', undefined],
        ['a function into stringIn', 'stringIn', function () {}],
    ];
    for (const [label, port, value] of bad) {
        const e = throws(function () { app.ports[port].send(value); });
        if (!e) fail('send of ' + label + ' did not throw');
        note('send of ' + label + ' threw ' + e.constructor.name);
        say('values send of ' + label + ': throws');
    }

    await finish(app);
}

/* Which `update` runs first, the one for a send made inside a subscriber or the one for a Task of the
 * same batch (D5, not observed): the order is in the transcript, which must match. */
async function scenarioOrder() {
    const app = loadRoot().init({ flags: FLAGS });
    checkStopShape(app);
    const flagsOut = collector(app.ports.flagsOut);
    await flagsOut.next();
    flagsOut.stop();

    const log = collector(app.ports.orderLog);
    app.ports.orderOut.subscribe(function () { app.ports.orderIn.send(null); });
    app.ports.orderGo.send(null);
    const order = (await log.next()).value;
    log.stop();
    if (order !== 'in,task' && order !== 'task,in') fail('order log was ' + JSON.stringify(order));
    say('order: ' + order);
    await finish(app);
}

/* Flags that do not decode (formerly D2): init throws the JS backend's Error, nothing starts, and init
 * may be called again (PORT_009: the addon checks the flags before it starts the program). */
async function scenarioBadFlags() {
    const root = loadRoot();
    const bad = [
        ['a wrong field type', Object.assign({}, FLAGS, { name: 1 })],
        ['a missing field', (function () { const f = Object.assign({}, FLAGS); delete f.count; return f; })()],
        ['no flags', undefined],
        ['a non-integral Int', Object.assign({}, FLAGS, { count: 1.5 })],
        ['a short tuple', Object.assign({}, FLAGS, { pair: [3] })],
        ['a bad nested value', Object.assign({}, FLAGS, { nested: { inner: { deep: [[true, 'x']] } } })],
    ];
    for (const [label, flags] of bad) {
        const e = throws(function () { root.init(flags === undefined ? {} : { flags: flags }); });
        if (!(e instanceof Error) || !/^Problem with the flags given to your Elm program on initialization\./.test(e.message)) {
            fail('init with ' + label + ' did not throw the flags Error: ' + e);
        }
        note('init with ' + label + ': ' + e.message.split('\n').slice(0, 4).join(' | '));
        say('bad flags, ' + label + ': init throws');
    }
    /* Nothing started, so a retry with good flags starts the program. */
    const app = root.init({ flags: FLAGS });
    checkStopShape(app);
    const out = collector(app.ports.flagsOut);
    if (!deepEqual((await out.next()).value, FLAGS)) fail('the retried init did not start with its flags');
    out.stop();
    say('bad flags: a retry with good flags starts the program');
    await finish(app);
}

/* Sends that do not decode (formerly D3): send throws the JS backend's Error at once, and the program
 * carries on (PORT_009: the addon checks the value before it queues it). */
const BAD_SENDS = [
    ['intIn', 'x'], ['intIn', 1.5], ['intIn', null], ['intIn', true],
    ['floatIn', '1.5'], ['boolIn', 0], ['stringIn', 5], ['unitIn', 0],
    ['maybeIn', 'x'], ['listIn', [1, 'two']], ['listIn', { 0: 1 }], ['arrayIn', [1]],
    ['tuple2In', [1]], ['tuple2In', ['x', 'y']], ['tuple3In', [true, 2.5]],
    ['recordIn', { id: 1, tags: ['a'] }], ['recordIn', { id: 1, tags: [2], child: { ok: true } }],
    ['recordIn', { id: 1, tags: [], child: { ok: 'yes' } }], ['recordIn', [1]],
];

async function scenarioBadSend() {
    const app = loadRoot().init({ flags: FLAGS });
    checkStopShape(app);
    const flagsOut = collector(app.ports.flagsOut);
    await flagsOut.next();
    flagsOut.stop();
    for (const [port, value] of BAD_SENDS) {
        const e = throws(function () { app.ports[port].send(value); });
        const first = 'Trying to send an unexpected type of value through port `' + port + '`:';
        if (!(e instanceof Error) || e.message.split('\n')[0] !== first) {
            fail('send of ' + JSON.stringify(value) + ' into ' + port + ' did not throw at once: ' + e);
        }
        note('send of ' + JSON.stringify(value) + ' into ' + port + ': ' + e.message.split('\n').slice(1).filter(Boolean).join(' | '));
        say('bad send of ' + JSON.stringify(value) + ' into ' + port + ': throws');
    }
    /* The program carries on. */
    const out = collector(app.ports.intOut);
    app.ports.intIn.send(7);
    if ((await out.next()).value !== 7) fail('the program did not carry on after the refused sends');
    out.stop();
    say('bad send: the program carries on');
    await finish(app);
}

// ---------------------------------------------------------------------------------------------
// json-flags, unit-flags

const JSON_FLAGS = [
    { a: 1, b: [true, null, 'x'], c: { d: 1.5 } },
    [1, 'two', null, { three: 3 }],
    'just a string: Zoë ☃ 😀',
    3.25,
    -7,
    true,
    null,
    {},
    [],
    { z: 1, a: 2, m: 3 },
    JSON.parse('{"a":' + '{"a":'.repeat(40) + '0' + '}'.repeat(40) + '}'),
];

async function scenarioJsonFlags(n) {
    const flags = JSON_FLAGS[n];
    const app = loadRoot().init({ flags: flags });
    checkStopShape(app);
    const out = collector(app.ports.flagsOut);
    const got = (await out.next()).value;
    if (!sameJson(got, flags)) fail('flags ' + JSON.stringify(flags) + ' came back as ' + JSON.stringify(got));
    out.stop();
    say('json flags ' + n + ': ' + JSON.stringify(got));
    await finish(app);
}

/* The ways a host may give a `()` program its flags; every one starts it. */
const UNIT_FLAGS = [
    function (root) { return root.init(); },
    function (root) { return root.init({}); },
    function (root) { return root.init({ flags: undefined }); },
    function (root) { return root.init({ flags: null }); },
    function (root) { return root.init({ flags: { any: 'thing' } }); },
];

async function scenarioUnitFlags(n) {
    const app = UNIT_FLAGS[n](loadRoot());
    checkStopShape(app);
    /* Started: the start-up payloads come out. */
    const out = collector(app.ports.bytesOut);
    for (let i = 0; i < 4; i++) await out.next();
    out.stop();
    say('unit flags ' + n + ': started');
    await finish(app);
}

// ---------------------------------------------------------------------------------------------

/* `embed_host.js list` prints, for the runner, one `<fixture> <scenario>` line per scenario. */
function list() {
    const lines = ['BytesEchoService bytes', 'ValuesService values', 'ValuesService bad-flags', 'ValuesService bad-send',
                   'ValuesService order']
        .concat(JSON_FLAGS.map(function (_, i) { return 'JsonFlagsService json-flags:' + i; }))
        .concat(UNIT_FLAGS.map(function (_, i) { return 'BytesEchoService unit-flags:' + i; }));
    console.log(lines.join('\n'));
    clearTimeout(guard);
    process.exitCode = 0;
}

const scenarios = {
    'bytes': scenarioBytes,
    'values': scenarioValues,
    'bad-flags': scenarioBadFlags,
    'bad-send': scenarioBadSend,
    'order': scenarioOrder,
};

let run = MODE === 'list' ? list : scenarios[SCENARIO];
const m = /^(json-flags|unit-flags):(\d+)$/.exec(SCENARIO || '');
if (m) {
    const n = Number(m[2]);
    if (m[1] === 'json-flags' && n < JSON_FLAGS.length) run = function () { return scenarioJsonFlags(n); };
    if (m[1] === 'unit-flags' && n < UNIT_FLAGS.length) run = function () { return scenarioUnitFlags(n); };
}
if (!run) fail('unknown scenario ' + SCENARIO);
if (SCENARIO === 'bytes' && typeof global.gc !== 'function') fail('run node with --expose-gc');

Promise.resolve().then(run).catch(function (e) {
    fail('unexpected exception: ' + (e && e.stack ? e.stack : e));
});
