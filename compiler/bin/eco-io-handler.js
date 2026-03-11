/**
 * eco-io-handler.js
 *
 * Thin wrapper that translates JSON-encoded IO requests from the XHR-based
 * bootstrap compiler into calls to the eco JS kernel functions.
 *
 * Request format (JSON body):
 *   { "op": "Console.write", "args": { "handle": 1, "content": "hello" } }
 *
 * Response format (JSON body):
 *   { "value": <result> }
 *
 * For unit-returning operations, the response is just HTTP 200 with no body.
 *
 * The handler delegates to Node.js built-in modules directly, mirroring the
 * semantics of the JS kernel files in eco-kernel-cpp/src/Eco/Kernel/*.js.
 * This ensures behavioral consistency across the XHR and kernel IO paths.
 */

const fs = require("node:fs");
const path = require("node:path");
const os = require("node:os");
const http = require("node:http");
const https = require("node:https");
const zlib = require("node:zlib");
const crypto = require("node:crypto");
const child_process = require("node:child_process");
const AdmZip = require("adm-zip");
const which = require("which");

// State for server-side resources
const processes = {};
let processCounter = 0;

const streamHandles = {};
let streamHandleCounter = 1000;

const mVars = {};
let mVarNextId = 0;

/**
 * Convert a Node.js Buffer to an ArrayBuffer.
 * The Elm runtime's _Http_toDataView expects ArrayBuffer, not Buffer.
 */
function toArrayBuffer(buf) {
  if (buf instanceof ArrayBuffer) return buf;
  if (ArrayBuffer.isView(buf)) {
    // Zero-copy when the view spans the entire underlying buffer (common for
    // DataView from Elm Bytes). Only copy when it doesn't (e.g. pooled Node
    // Buffers from fs.readFileSync).
    if (buf.byteOffset === 0 && buf.byteLength === buf.buffer.byteLength) {
      return buf.buffer;
    }
    return buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength);
  }
  return buf;
}

function wakeUpMVarWaiters(mvar) {
  while (mvar.waiters.length > 0) {
    const waiter = mvar.waiters[0];
    if (waiter.action === "read") {
      if (mvar.value !== undefined) {
        mvar.waiters.shift();
        waiter.respond(200, toArrayBuffer(mvar.value));
      } else {
        break;
      }
    } else if (waiter.action === "take") {
      if (mvar.value !== undefined) {
        mvar.waiters.shift();
        const val = mvar.value;
        mvar.value = undefined;
        waiter.respond(200, toArrayBuffer(val));
      } else {
        break;
      }
    } else if (waiter.action === "put") {
      if (mvar.value === undefined) {
        mvar.waiters.shift();
        mvar.value = waiter.value;
        waiter.respond(200, "");
      } else {
        break;
      }
    } else {
      break;
    }
  }
}

/**
 * Handle an eco-io JSON request.
 * @param {object} parsed - The parsed JSON request { op, args }
 * @param {function} respond - Function to send the response: respond(statusCode, body)
 * @returns {void}
 */
function handleEcoIO(parsed, respond) {
  const { op, args } = parsed;

  switch (op) {
    // --- Console ---
    case "Console.write": {
      const { handle, content } = args;
      if (handle === 1) {
        process.stdout.write(content);
      } else if (handle === 2) {
        process.stderr.write(content);
      } else if (streamHandles[handle]) {
        streamHandles[handle].stream.write(content);
      }
      respond(200, "");
      break;
    }

    case "Console.readLine": {
      const readline = require("readline");
      const rl = readline.createInterface({
        input: process.stdin,
        output: process.stdout,
        terminal: false,
      });
      rl.once("line", (line) => {
        rl.close();
        respond(200, JSON.stringify({ value: line }));
      });
      rl.once("close", () => {
        respond(200, JSON.stringify({ value: "" }));
      });
      break;
    }

    case "Console.readAll": {
      const chunks = [];
      process.stdin.setEncoding("utf8");
      process.stdin.on("data", (chunk) => chunks.push(chunk));
      process.stdin.on("end", () => {
        respond(200, JSON.stringify({ value: chunks.join("") }));
      });
      process.stdin.resume();
      break;
    }

    // --- Crash ---
    case "Crash.crash": {
      Error.stackTraceLimit = Infinity;
      console.error(new Error(args.message).stack);
      process.exit(1);
      break;
    }

    // --- File ---
    case "File.readString": {
      try {
        const content = fs.readFileSync(args.path, "utf8");
        respond(200, JSON.stringify({ value: content }));
      } catch (e) {
        respond(500, JSON.stringify({ error: e.message }));
      }
      break;
    }

    case "File.writeString": {
      try {
        fs.writeFileSync(args.path, args.content, "utf8");
        respond(200, "");
      } catch (e) {
        respond(500, JSON.stringify({ error: e.message }));
      }
      break;
    }

    case "File.readBytes": {
      try {
        const buffer = fs.readFileSync(args.path);
        respond(200, toArrayBuffer(buffer));
      } catch (e) {
        respond(500, JSON.stringify({ error: e.message }));
      }
      break;
    }

    case "File.writeBytes": {
      // For XHR bootstrap, writeBytes is handled via a separate binary endpoint
      respond(200, "");
      break;
    }

    case "File.open": {
      try {
        const flags = ["r", "w", "a", "r+"][args.mode] || "r";
        const fd = fs.openSync(args.path, flags);
        respond(200, JSON.stringify({ value: fd }));
      } catch (e) {
        respond(500, JSON.stringify({ error: e.message }));
      }
      break;
    }

    case "File.close": {
      if (streamHandles[args.handle]) {
        streamHandles[args.handle].stream.end();
        delete streamHandles[args.handle];
        respond(200, "");
      } else {
        try {
          fs.closeSync(args.handle);
          respond(200, "");
        } catch (e) {
          respond(500, JSON.stringify({ error: e.message }));
        }
      }
      break;
    }

    case "File.hWriteString": {
      try {
        fs.writeSync(args.handle, args.content, null, "utf8");
        respond(200, "");
      } catch (e) {
        respond(500, JSON.stringify({ error: e.message }));
      }
      break;
    }

    case "File.size": {
      try {
        const stat = fs.fstatSync(args.handle);
        respond(200, JSON.stringify({ value: stat.size }));
      } catch (e) {
        respond(500, JSON.stringify({ error: e.message }));
      }
      break;
    }

    case "File.lock": {
      // TODO: implement file locking
      respond(200, "");
      break;
    }

    case "File.unlock": {
      // TODO: implement file unlocking
      respond(200, "");
      break;
    }

    case "File.fileExists": {
      try {
        const stat = fs.statSync(args.path);
        respond(200, JSON.stringify({ value: stat.isFile() }));
      } catch (e) {
        respond(200, JSON.stringify({ value: false }));
      }
      break;
    }

    case "File.dirExists": {
      try {
        const stat = fs.statSync(args.path);
        respond(200, JSON.stringify({ value: stat.isDirectory() }));
      } catch (e) {
        respond(200, JSON.stringify({ value: false }));
      }
      break;
    }

    case "File.findExecutable": {
      const found = which.sync(args.name, { nothrow: true }) ?? null;
      respond(200, JSON.stringify({ value: found }));
      break;
    }

    case "File.list": {
      try {
        const entries = fs.readdirSync(args.path);
        respond(200, JSON.stringify({ value: entries }));
      } catch (e) {
        respond(500, JSON.stringify({ error: e.message }));
      }
      break;
    }

    case "File.modificationTime": {
      try {
        const stat = fs.statSync(args.path);
        respond(200, JSON.stringify({ value: Math.floor(stat.mtimeMs) }));
      } catch (e) {
        respond(500, JSON.stringify({ error: e.message }));
      }
      break;
    }

    case "File.getCwd": {
      respond(200, JSON.stringify({ value: process.cwd() }));
      break;
    }

    case "File.setCwd": {
      try {
        process.chdir(args.path);
        respond(200, "");
      } catch (e) {
        respond(500, JSON.stringify({ error: e.message }));
      }
      break;
    }

    case "File.canonicalize": {
      try {
        const resolved = fs.realpathSync(args.path);
        respond(200, JSON.stringify({ value: resolved }));
      } catch (e) {
        // Fall back to path.resolve if realpath fails
        respond(200, JSON.stringify({ value: path.resolve(args.path) }));
      }
      break;
    }

    case "File.appDataDir": {
      const home = os.homedir();
      let dir;
      if (process.platform === "win32") {
        dir = path.join(process.env.APPDATA || home, args.name);
      } else if (process.platform === "darwin") {
        dir = path.join(home, "Library", "Application Support", args.name);
      } else {
        dir = path.join(home, "." + args.name);
      }
      respond(200, JSON.stringify({ value: dir }));
      break;
    }

    case "File.createDir": {
      try {
        fs.mkdirSync(args.path, { recursive: args.createParents });
        respond(200, "");
      } catch (e) {
        respond(500, JSON.stringify({ error: e.message }));
      }
      break;
    }

    case "File.removeFile": {
      try {
        fs.unlinkSync(args.path);
        respond(200, "");
      } catch (e) {
        respond(500, JSON.stringify({ error: e.message }));
      }
      break;
    }

    case "File.removeDir": {
      try {
        fs.rmSync(args.path, { recursive: true, force: true });
        respond(200, "");
      } catch (e) {
        respond(500, JSON.stringify({ error: e.message }));
      }
      break;
    }

    // --- Process ---
    case "Process.exit": {
      process.exit(args.code);
      break;
    }

    case "Process.spawn": {
      try {
        processCounter++;
        const child = child_process.spawn(args.cmd, args.args, {
          stdio: ["inherit", "inherit", "inherit"],
        });
        processes[processCounter] = child;
        respond(200, JSON.stringify({ value: processCounter }));
      } catch (e) {
        respond(500, JSON.stringify({ error: e.message }));
      }
      break;
    }

    case "Process.spawnProcess": {
      try {
        const { cmd, args: spawnArgs, stdin, stdout, stderr } = args;
        processCounter++;

        const stdioConfig = [
          stdin === "pipe" ? "pipe" : "inherit",
          stdout === "pipe" ? "pipe" : "inherit",
          stderr === "pipe" ? "pipe" : "inherit",
        ];

        const child = child_process.spawn(cmd, spawnArgs, { stdio: stdioConfig });
        processes[processCounter] = child;

        let stdinHandle = null;
        if (stdin === "pipe" && child.stdin) {
          streamHandleCounter++;
          streamHandles[streamHandleCounter] = {
            type: "childStdin",
            stream: child.stdin,
          };
          stdinHandle = streamHandleCounter;
        }

        respond(200, JSON.stringify({
          value: { stdinHandle, processHandle: processCounter }
        }));
      } catch (e) {
        respond(500, JSON.stringify({ error: e.message }));
      }
      break;
    }

    case "Process.wait": {
      const proc = processes[args.handle];
      if (!proc) {
        respond(200, JSON.stringify({ value: 0 }));
        break;
      }
      proc.on("exit", (code) => {
        delete processes[args.handle];
        respond(200, JSON.stringify({ value: code || 0 }));
      });
      break;
    }

    // --- Env ---
    case "Env.lookup": {
      const value = process.env[args.name];
      respond(
        200,
        JSON.stringify({ value: value !== undefined ? value : null })
      );
      break;
    }

    case "Env.rawArgs": {
      respond(200, JSON.stringify({ value: process.argv.slice(2) }));
      break;
    }

    // --- Runtime ---
    case "Runtime.dirname": {
      respond(200, JSON.stringify({ value: __dirname }));
      break;
    }

    case "Runtime.random": {
      respond(200, JSON.stringify({ value: Math.random() }));
      break;
    }

    case "Runtime.saveState": {
      global._ecoReplState = args;
      respond(200, "");
      break;
    }

    case "Runtime.loadState": {
      respond(200, JSON.stringify({ value: global._ecoReplState || null }));
      break;
    }

    // --- MVar ---
    case "MVar.new": {
      mVarNextId++;
      mVars[mVarNextId] = { value: undefined, waiters: [] };
      respond(200, JSON.stringify({ value: mVarNextId }));
      break;
    }

    case "MVar.read": {
      const mvar = mVars[args.id];
      if (mvar.value !== undefined) {
        respond(200, toArrayBuffer(mvar.value));
      } else {
        mvar.waiters.push({ action: "read", respond });
      }
      break;
    }

    case "MVar.take": {
      const mvar = mVars[args.id];
      if (mvar.value !== undefined) {
        const val = mvar.value;
        mvar.value = undefined;
        respond(200, toArrayBuffer(val));
        wakeUpMVarWaiters(mvar);
      } else {
        mvar.waiters.push({ action: "take", respond });
      }
      break;
    }

    // --- Http ---
    case "Http.fetch": {
      const { method, url: fetchUrl, headers: fetchHeaders } = args;
      const parsedUrl = new URL(fetchUrl);
      const client = parsedUrl.protocol === "https:" ? https : http;

      const headerObj = {};
      for (const [k, v] of fetchHeaders) {
        headerObj[k] = v;
      }

      const req = client.request(parsedUrl, { method, headers: headerObj }, (res) => {
        if (res.statusCode >= 200 && res.statusCode < 300) {
          const chunks = [];
          res.on("data", (chunk) => chunks.push(chunk));
          res.on("end", () => {
            const buffer = Buffer.concat(chunks);
            const encoding = res.headers["content-encoding"];
            const decode = (buf) => {
              respond(200, JSON.stringify({ value: { body: buf.toString() } }));
            };
            if (encoding === "gzip") {
              zlib.gunzip(buffer, (err, decoded) => {
                if (err) { respond(500, JSON.stringify({ error: err.message })); return; }
                decode(decoded);
              });
            } else if (encoding === "deflate") {
              zlib.inflate(buffer, (err, decoded) => {
                if (err) { respond(500, JSON.stringify({ error: err.message })); return; }
                decode(decoded);
              });
            } else {
              decode(buffer);
            }
          });
        } else {
          // Drain body, then report error
          res.resume();
          res.on("end", () => {
            respond(200, JSON.stringify({
              value: { statusCode: res.statusCode, statusText: res.statusMessage || "", url: fetchUrl }
            }));
          });
        }
      });

      req.on("error", (err) => {
        respond(200, JSON.stringify({
          value: { statusCode: 0, statusText: err.message, url: fetchUrl }
        }));
      });

      req.end();
      break;
    }

    case "Http.getArchive": {
      const { url: archiveUrl } = args;

      const download = (downloadUrl) => {
        const parsedUrl = new URL(downloadUrl);
        const client = parsedUrl.protocol === "https:" ? https : http;
        const req = client.request(parsedUrl, { method: "GET" }, (res) => {
          if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
            download(res.headers.location);
            return;
          }
          if (res.statusCode >= 200 && res.statusCode < 300) {
            const chunks = [];
            res.on("data", (chunk) => chunks.push(chunk));
            res.on("end", () => {
              try {
                const buffer = Buffer.concat(chunks);
                const zip = new AdmZip(buffer);
                const sha = crypto.createHash("sha1").update(buffer).digest("hex");
                const archive = zip.getEntries().map((entry) => ({
                  eRelativePath: entry.entryName,
                  eData: zip.readAsText(entry),
                }));
                respond(200, JSON.stringify({ value: { sha, archive } }));
              } catch (e) {
                respond(200, JSON.stringify({ value: { error: e.message } }));
              }
            });
          } else {
            res.resume();
            res.on("end", () => {
              respond(200, JSON.stringify({ value: { error: "HTTP " + res.statusCode } }));
            });
          }
        });
        req.on("error", (err) => {
          respond(200, JSON.stringify({ value: { error: err.message } }));
        });
        req.end();
      };

      download(archiveUrl);
      break;
    }

    default:
      respond(404, JSON.stringify({ error: "Unknown eco-io operation: " + op }));
  }
}

/**
 * Handle an eco-io binary request (raw bytes in body, op in X-Eco-Op header).
 * @param {string} op - The operation name from X-Eco-Op header
 * @param {object} request - The mock-xmlhttprequest request object (body is ArrayBuffer/Buffer)
 * @param {function} respond - Function to send the response: respond(statusCode, body)
 * @returns {void}
 */
function handleEcoIOBinary(op, request, respond) {
  switch (op) {
    case "File.writeBytes": {
      const filePath = request.requestHeaders.getHeader("X-Eco-Path");
      try {
        const body = request.body;
        const buffer = ArrayBuffer.isView(body)
          ? Buffer.from(body.buffer, body.byteOffset, body.byteLength)
          : Buffer.from(body);
        fs.writeFileSync(filePath, buffer);
        respond(200, "");
      } catch (e) {
        respond(500, JSON.stringify({ error: e.message }));
      }
      break;
    }

    case "MVar.put": {
      const id = parseInt(request.requestHeaders.getHeader("X-Eco-MVar-Id"));
      const mvar = mVars[id];
      if (mvar.value === undefined) {
        mvar.value = request.body;
        respond(200, "");
        wakeUpMVarWaiters(mvar);
      } else {
        mvar.waiters.push({ action: "put", value: request.body, respond });
      }
      break;
    }

    default:
      respond(404, JSON.stringify({ error: "Unknown eco-io binary operation: " + op }));
  }
}

module.exports = { handleEcoIO, handleEcoIOBinary };
