// test-port.js — a free TCP port per E2E test child, the Node twin of test/TestPort.hpp for
// the JS runners (run-js-e2e.js, run-elm-e2e.js), passed to the child as ECO_TEST_PORT.
//
// Nothing reserves the port between the pick and the child's listen, so the ports come from
// a block below every OS's ephemeral range (Linux 32768-60999, macOS and Windows
// 49152-65535): the kernel never gives one of them to an outgoing connection or a listen on
// port 0, which is how a port picked by listening on port 0 was once taken in that window
// (EADDRINUSE in CI). The picker walks the block from a start chosen by the process id, so
// two runners at once rarely meet, and skips a port it cannot listen on (someone else has it).

'use strict';

const net = require('net');

// The block: [FIRST, FIRST + COUNT), as in TestPort.hpp.
const FIRST = 20000;
const COUNT = 10000;

let next = process.pid % COUNT;   // offset into the block of the next candidate

// Whether 127.0.0.1:port can be listened on now.
function portFree(port) {
    return new Promise((resolve) => {
        const srv = net.createServer();
        srv.once('error', () => resolve(false));
        srv.listen({ port, host: '127.0.0.1', exclusive: true }, () => srv.close(() => resolve(true)));
    });
}

// A port from the block that was free a moment ago, or 0 if none could be found. Each call
// moves on through the block, so a port comes back only after the other 9,999.
async function pickFreePort() {
    for (let attempt = 0; attempt < 64; attempt++) {
        const port = FIRST + next;
        next = (next + 1) % COUNT;
        if (await portFree(port)) return port;
    }
    return 0;
}

module.exports = { pickFreePort };
