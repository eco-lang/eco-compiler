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

const { Elm } = require("../build-xhr/bin/guida.js");

Elm.Terminal.Main.init();
