/**
 * eco-io-handler.js
 *
 * Answers the IO requests of the XHR-based bootstrap compiler (Stage 1) for
 * the eco/kernel modules it still uses: MVars, explicit GC and crashes.
 *
 * Request format (JSON body):
 *   { "op": "MVar.new", "args": {} }
 *
 * Response format (JSON body):
 *   { "value": <result> }
 *
 * For unit-returning operations, the response is just HTTP 200 with no body.
 *
 * Files, the console, the environment, exit and HTTP are not served here: the
 * compiler does that IO through eco/system, whose own JavaScript kernels are
 * linked into Stage 1 (compiler/scripts/link-stage1-system-kernels.js,
 * plans/compiler-io-on-eco-system.md).
 */

const mVars = {};
let mVarNextId = 0;

// The MVar stash (src-xhr/Eco/MVar.elm, "STASH"; patched into guida.js by the
// kernel-overrides/MVar*.js value overrides): `put` sends a 12-byte token, two magic words and an
// id, and the value itself stays here as the Elm program's own object, so it is
// never encoded or decoded. An MVar holds the token as it held encoded bytes.
// A stashed value lives until a `take` returns it or its MVar is dropped.
const STASH_MAGIC_0 = 0xec0a5745;
const STASH_MAGIC_1 = 0x4d566172; // "MVar"
const STASH_TOKEN_WIDTH = 12;
const stashedValues = new Map();
let stashNextId = 0;

/** The id of the token at `offset` of DataView `view`, or 0 when there is none. */
function stashTokenId(view, offset) {
  if (view.byteLength - offset < STASH_TOKEN_WIDTH) return 0;
  if (view.getUint32(offset) !== STASH_MAGIC_0 || view.getUint32(offset + 4) !== STASH_MAGIC_1) return 0;
  return view.getUint32(offset + 8);
}

const mVarStash = {
  /** Stashes `value` and returns its token as a DataView. */
  stash(value) {
    const id = ++stashNextId;
    stashedValues.set(id, value);
    const token = new DataView(new ArrayBuffer(STASH_TOKEN_WIDTH));
    token.setUint32(0, STASH_MAGIC_0);
    token.setUint32(4, STASH_MAGIC_1);
    token.setUint32(8, id);
    return token;
  },
  /**
   * For a token at `offset` of `view`: `{ value, width }`, releasing the value
   * when `taken`; for anything else, undefined. Throws for a token whose value
   * is gone (the decode then fails, which crashes the program in Eco.XHR).
   */
  unstash(view, offset, taken) {
    const id = stashTokenId(view, offset);
    if (id === 0) return undefined;
    if (!stashedValues.has(id)) throw new Error("eco-io: MVar stash token " + id + " has no value");
    const value = stashedValues.get(id);
    if (taken) stashedValues.delete(id);
    return { value, width: STASH_TOKEN_WIDTH };
  },
};
globalThis.__ecoMVarStash = mVarStash;

/** Releases the stashed value of MVar bytes `body`, if they are a token. */
function releaseStashed(body) {
  if (body === undefined) return;
  const buf = toArrayBuffer(body);
  if (!(buf instanceof ArrayBuffer)) return;
  const id = stashTokenId(new DataView(buf), 0);
  if (id !== 0) stashedValues.delete(id);
}

// Set when a driver's eco-io route catches an exception (the request is
// answered 500). The compiler may still go on to exit 0 and leave a truncated
// .mlir behind, so a failed handler forces a non-zero exit status.
let handlerFailed = false;
function markHandlerFailed() {
  handlerFailed = true;
  process.exitCode = 1;
}
function handlerFailedFlag() {
  return handlerFailed;
}

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
 * Run an explicit garbage collection for Eco.GC (plans/frontend-heap-release.md
 * §5.2) and build the GCReport object (same keys as Eco/GC.elm's decoder and
 * the C++ kernel). Without node --expose-gc no collection runs: collected = 0.
 * Report values are observations only (HEAP_076).
 * @param {boolean} major - true for a full (last-resort) collection
 * @returns {object} the GCReport
 */
function runGc(major) {
  const g = typeof globalThis.gc === "function" ? globalThis.gc : null;
  const b = process.memoryUsage();
  const t0 = process.hrtime.bigint();
  if (g) {
    try {
      g(major ? { type: "major", execution: "sync", flavor: "last-resort" }
              : { type: "minor", execution: "sync" });
    } catch (_) {
      g(); // older V8: options unsupported -> full GC
    }
  }
  const ns = g ? Number(process.hrtime.bigint() - t0) : 0;
  const a = process.memoryUsage();
  return {
    kind: major ? "major" : "minor", collected: g ? 1 : 0,
    totalNs: ns, gcNs: ns, sweepNs: 0, shrinkNs: 0, discardNs: 0, trimNs: 0,
    rssBefore: b.rss, rssAfterDiscard: a.rss, rssAfter: a.rss,
    oldInUseBefore: b.heapUsed, oldInUseAfter: a.heapUsed,
    oldPendingBefore: 0, oldPendingAfter: 0, oldHighWater: a.heapTotal,
    liveAfterMark: g && major ? a.heapUsed : 0,
    releasedBytes: 0, shrinkReleasedBytes: 0, discardedBytes: 0, nurseryCommitted: 0,
    minorCount: 0, majorCount: 0, majorsRun: g && major ? 1 : 0, trimResult: -1,
  };
}

/**
 * Wrap a driver's respond callback so an exception thrown by the Elm program
 * itself is fatal. respond() delivers the response synchronously, so it runs
 * the program's continuation up to its next IO request; an exception from
 * there (e.g. a Debug.todo crash in codegen) would otherwise land in the
 * catch of whichever op was answering (most wrap respond(200) in their own
 * try), get answered as an IO error, and leave the Elm scheduler wedged: node
 * then drains its event loop and exits 0 with a truncated output file.
 * @param {function} respond - respond(statusCode, body)
 * @returns {function} respond, exiting with status 1 if the program throws
 */
function fatalOnProgramThrow(respond) {
  return (status, body) => {
    try {
      respond(status, body);
    } catch (e) {
      console.error("eco-io: the program threw while handling a response:", e);
      process.exit(1);
    }
  };
}

/**
 * Handle an eco-io JSON request.
 * @param {object} parsed - The parsed JSON request { op, args }
 * @param {function} rawRespond - Function to send the response: respond(statusCode, body)
 * @returns {void}
 */
function handleEcoIO(parsed, rawRespond) {
  const respond = fatalOnProgramThrow(rawRespond);
  const { op, args } = parsed;

  switch (op) {
    // --- Crash ---
    case "Crash.crash": {
      Error.stackTraceLimit = Infinity;
      console.error(new Error(args.message).stack);
      process.exit(1);
      break;
    }

    // --- GC (Eco.GC) ---
    case "GC.minor":
    case "GC.major": {
      respond(200, JSON.stringify({ value: runGc(op === "GC.major") }));
      break;
    }

    // --- MVar ---
    case "MVar.new": {
      mVarNextId++;
      mVars[mVarNextId] = { value: undefined, waiters: [] };
      respond(200, JSON.stringify({ value: mVarNextId }));
      break;
    }

    case "MVar.drop": {
      const dropped = mVars[args.id];
      delete mVars[args.id];
      respond(200, JSON.stringify({ value: null }));
      if (dropped) {
        releaseStashed(dropped.value);
        for (const w of dropped.waiters) {
          if (w.action === "put") releaseStashed(w.value);
        }
        // A waiter on a dropped MVar can never be answered with a value.
        for (const w of dropped.waiters) {
          w.respond(500, JSON.stringify({ error: "MVar " + args.id + " was dropped while waited on" }));
        }
      }
      break;
    }

    case "MVar.read": {
      const mvar = mVars[args.id];
      if (!mvar) {
        respond(500, JSON.stringify({ error: "unknown MVar " + args.id }));
        break;
      }
      if (mvar.value !== undefined) {
        respond(200, toArrayBuffer(mvar.value));
      } else {
        mvar.waiters.push({ action: "read", respond });
      }
      break;
    }

    case "MVar.take": {
      const mvar = mVars[args.id];
      if (!mvar) {
        respond(500, JSON.stringify({ error: "unknown MVar " + args.id }));
        break;
      }
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

    default:
      respond(404, JSON.stringify({ error: "Unknown eco-io operation: " + op }));
  }
}

/**
 * Handle an eco-io binary request (raw bytes in body, op in X-Eco-Op header).
 * @param {string} op - The operation name from X-Eco-Op header
 * @param {object} request - The mock-xmlhttprequest request object (body is ArrayBuffer/Buffer)
 * @param {function} rawRespond - Function to send the response: respond(statusCode, body)
 * @returns {void}
 */
function handleEcoIOBinary(op, request, rawRespond) {
  const respond = fatalOnProgramThrow(rawRespond);
  switch (op) {
    case "MVar.put": {
      const id = parseInt(request.requestHeaders.getHeader("X-Eco-MVar-Id"));
      const mvar = mVars[id];
      if (!mvar) {
        releaseStashed(request.body);
        respond(500, JSON.stringify({ error: "unknown MVar " + id }));
        break;
      }
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

module.exports = { handleEcoIO, handleEcoIOBinary, markHandlerFailed, handlerFailedFlag };
