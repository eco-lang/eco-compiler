#!/usr/bin/env node

const { newServer } = require("mock-xmlhttprequest");
const { handleEcoIO, handleEcoIOBinary } = require("./eco-io-handler");

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
    request.respond(500, null, JSON.stringify({ error: e.message }));
  }
});

server.install();

// guida.js is the Stage 1 output now produced under ${CMAKE_BINARY_DIR}/compiler/build-xhr/bin/.
// CMake passes the absolute path via GUIDA_JS_PATH when invoking index.js; the
// default targets the `build/` preset for ad-hoc invocations from a shell.
const path = require("path");
const guidaPath = process.env.GUIDA_JS_PATH ||
    path.join(__dirname, "../../build/compiler/build-xhr/bin/guida.js");
const { Elm } = require(guidaPath);

Elm.Terminal.Main.init();
