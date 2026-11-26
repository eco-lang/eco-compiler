#!/usr/bin/env node

const { newServer } = require("mock-xmlhttprequest");
const { handleEcoIO, handleEcoIOBinary, markHandlerFailed, handlerFailedFlag } = require("./eco-io-handler");

const server = newServer();

// --- Eco IO handler (new-style JSON + binary protocol) ---
server.post("eco-io", (request) => {
  try {
    const binaryOp = request.requestHeaders.getHeader("X-Eco-Op");
    if (binaryOp) {
      handleEcoIOBinary(binaryOp, request, (status, body) => {
        request.respond(status, null, body);
      });
    } else {
      const parsed = JSON.parse(request.body);
      handleEcoIO(parsed, (status, body) => {
        request.respond(status, null, body);
      });
    }
  } catch (e) {
    console.error("eco-io handler error:", e);
    markHandlerFailed();
    request.respond(500, null, JSON.stringify({ error: e.message }));
  }
});

server.install();

// The compiler ends through eco/system's System.exitWithCodeTask, which calls process.exit itself.
// A failed eco-io handler may have left a truncated output behind, so an exit with success becomes
// a failure then, as the old eco-io "Process.exit" op made it (process.exitCode set in an 'exit'
// listener is the code the process ends with).
process.on("exit", (code) => {
  if (handlerFailedFlag() && code === 0) process.exitCode = 1;
});

// guida.js is the Stage 1 output now produced under ${CMAKE_BINARY_DIR}/compiler/build-xhr/bin/.
// CMake passes the absolute path via GUIDA_JS_PATH when invoking index.js; the
// default targets the `build/` preset for ad-hoc invocations from a shell.
const path = require("path");
const guidaPath = process.env.GUIDA_JS_PATH ||
    path.join(__dirname, "../../build/compiler/build-xhr/bin/guida.js");
const { Elm } = require(guidaPath);

Elm.Terminal.Main.init();
