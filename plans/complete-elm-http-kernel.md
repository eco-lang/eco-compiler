# Plan: Tidy up, complete & E2E-test the `elm/http` kernel (libcurl + OpenSSL)

> Revised twice after code investigation + user decisions. Verified facts cite
> `file:line`. The "Resolved decisions" section records the Q-A…Q-F answers that
> now constrain the work.

## Resolved decisions (from the user)
- **Q-A — MUST keep stock `elm/http`; match its contract.** The *same* `elm/http`
  Elm code must run on both the JS and C++ kernels. We do **not** control that API,
  so the C++ exports must conform to stock `Http.elm`'s kernel call contract
  (arities + value shapes). **No Eco-authored `Http.elm` override.**
- **Q-B — current `HttpExports.cpp` may be rewritten wholesale.** Only the two
  pure-constructor E2E tests exist; trust nothing about the arity-1 contract.
- **Q-C — the test server lives in the test runner** (`test/elm-http/ElmHttpTest.hpp`):
  start a server with a known test API, run tests against it, shut it down at end.
- **Q-D — the scheduler must run async `Cmd`/`Task` IO to completion.** This already
  works for other kernels — **`elm/time` is the template** (see below).
- **Q-E — HTTPS via a throwaway CA at test time** is approved if it works.
- **Q-F — eco-kernel `getArchive` is IN scope** and must work fully.

## 0. Hard architectural invariant: the heap is single-threaded
**Only the main scheduler thread may touch the Eco heap** — allocation, reading
heap records, building values, and applying closures all run on the main thread.
A worker/service thread must **never** see or pass an `HPointer`. This is exactly
why `elm/time` works (`TimeEffectManager.cpp:4-6`: "All HPointer / GC interaction
runs on the main scheduler thread; the TimerService worker thread only ever sees
`(deadline, uint64_t token)` pairs").

The marshaling pattern (mirror it for HTTP):
1. **Main thread**, in the kernel fn: read everything needed out of the heap into
   plain C++ data (no retained `HPointer`s); `registerPendingResume(resumeClosure)`
   → `uint64_t token` (the closure stays in `Scheduler::pendingResumes_`,
   `Scheduler.hpp:137`, on the main thread); `incrementPendingAsync` to keep the
   event loop alive while IO is in flight.
2. Hand only `(POD request, token)` to the worker/service.
3. **Worker thread**: do blocking IO into plain buffers; push `(token, POD result)`
   onto a ready queue and wake the scheduler (`Scheduler.hpp:45`,
   `TimerService::tryPopReadyToken`).
4. **Main thread** scheduler loop drains ready tokens, looks up the closure by
   token, **builds the heap response values here**, and resumes the Task.
Discipline carried from `elm/time`: never call the Allocator while holding the
service mutex (GC's scanner re-enters on the main thread → deadlock).

**The current `HttpExports.cpp` violates this** and must be rewritten (Q-B). The
sin is NOT that it roots in-flight contexts — those genuinely need rooting — but
that the **worker thread** holds heap pointers and builds values + applies closures
off-thread (`createResponse`, `utf8ToElmString`, `eco_apply_closure`,
`HttpExports.cpp:254-366`), and its `ExternalRootScanner`
(`HttpExports.cpp:204-218`) roots a registry shared with the worker. Keep the
rooting; move it (and all heap work) onto the main thread.

### Rooting in-flight requests (main-thread only)
The in-flight context is **never shared with the worker**: it is a main-thread-only
registry keyed by `uint64_t token`, holding the heap pointers needed to *finish* the
request on the main thread — the `resultToTask` continuation, the `Expect` record's
`toBody`/`toValue`, and (for progress) `router`. Two rooting paths, both
main-thread scanners:
- **One-shot continuation (get/post/task) → reuse `pendingResumes_`.** Bundle
  `resultToTask`+`expect` into a single heap object and `registerPendingResume`
  → token. The Scheduler's existing external scanner already evacuates
  `pendingResumes_` (`Scheduler.cpp:51-64`), and `registerPendingResume` is
  lock-only/heap-free → safe from any thread (`Scheduler.cpp:81-86`). On completion
  the main thread `takePendingResume(token)` returns the evacuated bundle (same path
  timers use, `Scheduler.cpp:542`). **No new scanner needed.**
- **Effect-manager / `router` state (phase-2, with `track`) → a dedicated
  main-thread scanner.** Keep a `map<token, …>` under an HTTP mutex and
  `addExternalRootScanner` over it — a verbatim mirror of `timerRegisterScannerOnce`
  (`TimeEffectManager.cpp:76-90`), `RootSet::addExternalRootScanner`
  (`RootSet.hpp:92-94`). Mutated/read only on the main thread.
The worker (`HttpService`) only exchanges `(POD request, token)` → `(token, POD
result)` + `notifyWorkAvailableFromAsync()`; it never touches the registry or any
`HPointer`. Evacuation is handled by `evacuate()` in the scanner (moving-GC safe).
Cancellation is keyed by token: drop the root + signal `HttpService` to abort the
handle.

## 1. Current state (verified findings)

### Two independent HTTP stacks (confirmed)
- **`elm-kernel-cpp/src/http/`** — kernel for the standard `elm/http` package
  (CMake target `ElmKernel_Http`):
  - `Http.cpp` / `Http.hpp`: **dead stub** (`namespace Elm::Kernel::Http`,
    `toTask()` = `assert(false)`). Referenced *only by itself* (verified). Delete.
  - `HttpExports.cpp`: the real impl. `extern "C"` exports the 8 symbols
    (`HttpExports.cpp:505-719`) `Elm_Kernel_Http_{emptyBody, pair, toTask, expect,
    mapExpect, bytesToBlob, toDataView, toFormData}`, over libcurl(+OpenSSL), with a
    worker-thread model + cross-thread GC rooting. **Written to an arity-1 contract
    that does NOT match stock `elm/http` (see "real blocker").** Gated on
    `HTTP_CURL_AVAILABLE`.
  - `HttpEffectManager.cpp`: effect manager + `eco_register_http_effect_manager()`.
- **`eco-kernel-cpp/src/eco/`** — compiler-internal `Eco.Http` (`fetch`/`getArchive`),
  used by the bootstrap package downloader (`compiler/src/Builder/Http.elm:194-196`).

### Bridge mechanism (the first draft was wrong here)
- **Kernel calls bind to C symbols by a pure naming convention, not via the JS
  shim.** `canonicalToMLIRName` does `String.replace "." "_"`
  (`compiler/src/Compiler/Generate/MLIR/Names.elm:18-20`): `Elm.Kernel.Http.toTask`
  → external symbol `Elm_Kernel_Http_toTask`. eco-kernel follows the same rule
  (`Eco.Kernel.Http.getArchive` → `Eco_Kernel_Http_getArchive`,
  `eco-kernel-cpp/src/eco/HttpExports.cpp:13`). **So the names are correct/required,
  not arbitrary — do not rename.**
- **All 8 C exports are already JIT-registered** (`RuntimeSymbols.cpp:881-888`),
  consumed by `EcoRunner::registerRuntimeSymbols` (`EcoRunner.cpp:218`).
- **The downloaded shim is NOT empty.** `~/.elm/0.19.1/packages/elm/http/2.0.0/
  src/Elm/Kernel/Http.js` is the 4265-byte *stock browser/XHR* impl. `Http.elm`
  references exactly the 8 implemented fns and no others. The first draft's
  "0-byte / 6 missing functions" claims were false.

### Registration / linkage (RESOLVED — positive)
- Suite registered (`test/main.cpp:797`); builder passes no extra flags so it uses
  the stock package (`test/elm-http/ElmHttpTest.hpp:7`).
- Effect manager registered (`EffectManagerRegistry.cpp:18`) + JIT-exposed
  (`RuntimeSymbols.cpp:953`).

### Async DOES work — `elm/time` is the template (Q-D)
`test/elm-time/src/TimeEveryTest.elm` is a `Platform.worker` that uses a
`Time.every` subscription, logs per tick, and stops after N — and it passes through
the *same* in-process JIT harness (`EcoRunner.runFile`, forked child,
`-- CHECK:` per tick). It exercises `Scheduler::pendingResumes_` + a service thread
+ effect-manager delivery. Kernel sources to mirror: `elm-kernel-cpp/src/time/
{TimeExports.cpp, TimeEffectManager.cpp, Time.cpp}` and
`plans/time-every-via-scheduler-timerservice.md`. **Conclusion:** the harness pumps
the scheduler to completion; HTTP must use the same Scheduler-binding +
cross-thread-resume pattern rather than the current synchronous shape.

### eco-kernel `getArchive` (Q-F) — far more complete than the first draft claimed
`Http.cpp:111-232` already does: libcurl GET with `CURLOPT_FOLLOWLOCATION`, SHA1 via
OpenSSL, libzip extraction, and builds the `(sha, archive)` result. libzip + OpenSSL
are already wired (`eco-kernel-cpp/CMakeLists.txt:23,38,49-50`, vendored under
`ECO_STATIC`). It is **not** a `fetch(url,0,0)` stub. Real issues to fix:
- Double-gated on `HTTP_CURL_AVAILABLE` **and** `LIBZIP_AVAILABLE`, each with an
  error-returning `#else` stub.
- **Likely tuple-ordering bug:** inner file entry is built as `(content,
  relativePath)` (`Http.cpp:206-212`) but stock JS builds `Tuple2(entryName,
  content)` = `(path, content)` — looks swapped. Outer `(archive, sha)` vs Elm
  `(Sha, Zip.Archive)` (`Builder/Http.elm:194`) also needs field-order verification.
- Synchronous `curl_easy_perform` runs **on the main thread**, so it is heap-safe
  (no §0 violation) — unlike the `elm/http` worker model. The only concern is that
  it blocks the event loop; acceptable for the bootstrap downloader. Leave
  synchronous unless blocking proves to be a problem.

### The REAL blocker for `elm/http`: arity / contract mismatch
Kernel-decl arity comes from the **call site** (`info.abiArgTypes`,
`Functions.elm:1124-1190`). Stock `Http.elm` calls
`Elm.Kernel.Http.toTask () resultToTask {request}` → **arity 3** (also line 996),
and stock JS declares `_Http_toTask = F3` / `_Http_expect = F3`. But `HttpExports.cpp`
exports `toTask(request)` / `expect(responseToResult)` → **arity 1**. So the current
C contract is wrong for stock `elm/http`. `pair`/`mapExpect` (`F2`) appear to line
up; the rest need per-fn confirmation. **Per-function arity+value-shape audit is the
first real work item.**

## 2. Goals
- One clean libcurl+OpenSSL(+libzip) build: no `HTTP_CURL_AVAILABLE` /
  `LIBZIP_AVAILABLE` flags, no dead stub, no `#else` fallbacks.
- C++ `Elm_Kernel_Http_*` exports that satisfy the **stock** `elm/http` kernel
  contract, so unmodified `Http.get`/`post`/`task` round-trip — async path proven
  via the `elm/time` pattern.
- A fully-working eco-kernel `getArchive`.
- E2E tests against an in-runner local server, including HTTPS with real verification.

## Part A — Tidy up (clean build, low risk)
- **A1. Drop `HTTP_CURL_AVAILABLE` and `LIBZIP_AVAILABLE`.** Make libcurl, OpenSSL,
  and libzip hard deps (`find_package(... REQUIRED)` / required `pkg_check_modules`,
  keeping the `ECO_STATIC` vendored branches) in both `elm-kernel-cpp/CMakeLists.txt`
  and `eco-kernel-cpp/CMakeLists.txt`. Delete every `#ifdef`/`#else` stub branch in
  `HttpExports.cpp` and `eco/Http.cpp`.
- **A2. Delete the dead stub.** Remove `src/http/Http.cpp` + `Http.hpp`; drop from
  `add_library(ElmKernel_Http …)`. Verified unreferenced → clean delete.
- **A3. Document the naming convention (no rename).** Add one comment in
  `HttpExports.cpp` pointing at `Names.elm:18` so the dot→underscore binding is
  discoverable.

## Part B — Make the `elm/http` bridge match the stock contract (Q-A, Q-B)
- **B1. Arity/value-shape audit.** For each of the 8 kernel fns, tabulate: stock
  `Http.elm` call-site arity, stock JS `_Http_*` body semantics + the value shape it
  returns/consumes (`Response`, `Metadata`, `GoodStatus_`/`BadStatus_`, `Expect`
  record `{__type,__toBody,__toValue}`), and the matching Eco heap layout. Output a
  table that drives B2.
- **B2a. Add an `HttpService` (mirror `TimerService`).** New
  `runtime/src/platform/HttpService.{hpp,cpp}` modeled on
  `runtime/src/platform/TimerService.{hpp,cpp}`: a worker thread (or small pool)
  whose request/response types are **plain C++ PODs only** — request `{method, url,
  headers, body bytes, timeout, expect-type, caInfo, token}`, result `{token,
  status, statusText, headers, body bytes, errorKind}`. Worker does the libcurl IO;
  pushes ready results onto a queue + wakes the scheduler. Wire it into the
  scheduler's ready-token drain (alongside the TimerService drain, `Scheduler.hpp:94`).
- **B2b. Rewrite `HttpExports.cpp` to the stock contract on the single-threaded
  heap (per §0).** No heap pointers on the worker; rooting stays on the main thread
  (reuse `pendingResumes_` for the continuation; dedicated scanner only for phase-2
  router state):
  - `toTask(router, resultToTask, request)` (arity 3): on the **main thread**, read
    the `request` record into a POD; bundle `resultToTask`+`expect` and
    `registerPendingResume(bundle)` → token; `incrementPendingAsync`;
    `HttpService::submit(POD, token)`. When the scheduler drains the ready result
    (**main thread**), `takePendingResume(token)`, build the `Response`/`Metadata`/
    body heap values, and resume with `resultToTask(expect.toValue(response))`.
    Progress (`track`) posts plain `(token, sent, total)` to the router via
    `HttpEffectManager` (rooted by the phase-2 dedicated scanner) — phase-2.
  - `expect(type, toBody, toValue)` (arity 3) → build the `Expect` record;
    `mapExpect`, `emptyBody`, `pair`, `bytesToBlob`, `toDataView`, `toFormData` to
    their stock arities/shapes (these are synchronous, main-thread, heap-local).
  - Build `Response`/`Metadata` records with the exact Eco field layout the stock
    `Http.elm` decoders expect.
  Keep `RuntimeSymbols.cpp:881-888` registrations (names unchanged; update shapes if
  a signature's arity changes).
- **B3. Prove async completion first.** Before C2, add one hand-written
  `Platform.worker` + `Http.get` test (modeled on `TimeEveryTest.elm`) and confirm
  `EcoRunner.runFile` delivers the HTTP result via the effect loop. If a gap exists
  in scheduler/effect wiring, fix it here.

## Part C — E2E testing (in-runner server + HTTPS)  (Q-C, Q-E)
Each test is its own `.elm` file = a `Platform.worker` that issues a request, logs
the outcome with `Debug.log`, and asserts via `-- CHECK:` (the harness pumps the
scheduler until the async `Cmd` drains — proven by `elm/time`). Default assertion
style: `expectString` + substring `-- CHECK:` (robust, decoder-free); `expectJson`
is exercised only in its dedicated tests.

### C1. In-runner test server, owned by the suite
Start a tiny C++ HTTP(S) server thread from `test/elm-http/ElmHttpTest.hpp`, kept
alive for the suite's lifetime (RAII guard owned by the returned suite; runs in the
**parent** test process, so forked test children reach it via `127.0.0.1`). Shut
down on teardown.
- **URL injection:** the suite knows the bound port; before the compile phase it
  writes a generated `src/TestServerConfig.elm` (`baseUrl = "http://127.0.0.1:<port>"`).
  Test `.elm` files import it. (No `main` → skipped by `discoverTests`/run, still
  importable.) Avoids fixed-port fragility and needs no `StressFlags` plumbing;
  fixed well-known port is the fallback if generation is awkward.

**Test API (httpbin-style reflector; same routes over HTTP and, for C3, HTTPS):**

| Route | Methods | Behavior | Exercises |
|---|---|---|---|
| `/anything` | GET/POST/PUT/DELETE (all) | 200 `application/json` reflecting `{"method","contentType","body","headers"}` | verb round-trip, request body + header echo |
| `/status/{code}` | all | status `{code}`, body `status {code}` | 2xx variety + `BadStatus` |
| `/echo-headers` | GET | 200 JSON of received request headers; sets response header `X-Test-Server: eco` | reading `Metadata.headers` |
| `/bytes/{n}` | GET | 200 `application/octet-stream`, `n` deterministic bytes (byte i = `i & 0xff`) | `expectBytes` |
| `/slow?ms={n}` | all | sleeps `n` ms (default > client timeout) then 200 | `Timeout` |
| `/redirect` | GET | 302 `Location: /anything` | `CURLOPT_FOLLOWLOCATION` |

`NetworkError` (unbound port) and `BadUrl` (malformed URL) need no route. `/anything`
is the workhorse: one behavior verifies all four verbs.

### C2. Request test cases (new `.elm` in `test/elm-http/src/`)
**Phase 1 — verbs + full error model (needs `toTask`/`expect`/bodies + `expectString`):**

| File | Request | Asserts (`-- CHECK:`) | Aspect |
|---|---|---|---|
| `HttpGetTest.elm` | `Http.get` → `/anything` | `"method":"GET"` | end-to-end round-trip (= B3 smoke test) |
| `HttpPostJsonTest.elm` | `Http.post` `jsonBody {key:"value"}` → `/anything` | `"method":"POST"`, `"key":"value"`, `application/json` | POST + `jsonBody` |
| `HttpPutTest.elm` | `Http.request` PUT `stringBody "text/plain" "ping"` | `"method":"PUT"`, `body":"ping"` | verb + `stringBody` |
| `HttpDeleteTest.elm` | `Http.request` DELETE `emptyBody` | `"method":"DELETE"` | verb + `emptyBody` |
| `HttpRequestHeaderTest.elm` | `Http.request` `headers=[header "X-Client" "abc"]` → `/echo-headers` | reflected `"x-client":"abc"` | request header plumbing |
| `HttpBadStatusTest.elm` | `Http.get` → `/status/404` | `err: BadStatus 404` | `BadStatus Int` |
| `HttpTimeoutTest.elm` | `Http.request` `timeout=Just 100` → `/slow?ms=3000` | `err: Timeout` | `Timeout`, abort path |
| `HttpNetworkErrorTest.elm` | `Http.get` → `http://127.0.0.1:1` | `err: NetworkError` | connect failure (no server) |
| `HttpBadUrlTest.elm` | `Http.get` → `"not a url"` | `err: BadUrl` | `BadUrl` (no server) |
| `HttpTaskTest.elm` | `Http.task` + `stringResolver`, `Task.attempt` | `task ok: …` | `Http.task` resolver path |

Covers GET/PUT/POST/DELETE and all five `Http.Error` variants (with `BadBody` below).

**Phase 2 — richer expect/body/progress (lands with `track`/multipart/bytes):**

| File | Request | Asserts | Aspect |
|---|---|---|---|
| `HttpExpectJsonTest.elm` | `Http.get` `expectJson` → `/anything` | decoded `method: GET` | `expectJson` success |
| `HttpBadBodyTest.elm` | `expectJson` decoder expecting a missing field | `err: BadBody` | `BadBody String` |
| `HttpExpectWhateverTest.elm` | `Http.post` `expectWhatever` → `/status/204` | `ok: ()` | `expectWhatever` |
| `HttpResponseHeadersTest.elm` | `expectStringResponse` → `/echo-headers` | `Metadata.headers` has `x-test-server: eco` | `Metadata`/`Response` build |
| `HttpExpectBytesTest.elm` | `Http.get` `expectBytes` → `/bytes/8` | decoded byte values | `expectBytes` + `toDataView` |
| `HttpMultipartTest.elm` | `Http.post` `multipartBody [stringPart…]` | server echoes both parts | `toFormData` + `pair` |
| `HttpRedirectTest.elm` | `Http.get` → `/redirect` | final 200 body `"method":"GET"` | `FOLLOWLOCATION` |
| `HttpTrackProgressTest.elm` | `Http.request` `tracker=Just "x"` + `Http.track` sub | ≥1 `Sending`/`Receiving` | effect-manager router + dedicated scanner |

The existing `HttpHeaderTest.elm` / `HttpJsonBodyTest.elm` (pure constructors) stay
as cheap unit checks that don't need the server.

### C3. HTTPS with real verification
Generate a throwaway CA + server cert at suite setup (openssl one-liner), serve TLS
from the in-runner server, point libcurl at the test CA via the **`CURL_CA_BUNDLE`
env var** (honored with no code change) or `CURLOPT_CAINFO`. Keep verification ON;
make HTTPS a separate skippable case.

| File | Request | Asserts | Aspect |
|---|---|---|---|
| `HttpsGetTest.elm` | `Http.get` → TLS base URL, CA via `CURL_CA_BUNDLE` | `"method":"GET"` | OpenSSL path, peer verification ON |
| `HttpsBadCertTest.elm` *(optional)* | `Http.get` → untrusted cert host | `err: NetworkError` | verification actually rejects |

## Part F — Complete eco-kernel `getArchive` (Q-F)
- **F1.** Fold flag removal in via A1 (libzip/curl hard deps; delete the
  `not available` `#else` branches).
- **F2. Fix the tuple ordering.** Verify against `Builder/Http.elm` + the `Zip`
  decoder: inner entries should be `(path, content)` and the outer result
  `(Sha, Archive)`. Correct `Http.cpp:206-223` field order if the audit confirms the
  suspected swap.
- **F3. Verify end-to-end.** Identify/the bootstrap path that calls `getArchive`
  (package download) and add a targeted test (can reuse the Part-C in-runner server
  serving a small canned `.zip`) so "working fully" is demonstrable, not assumed.

## Sequencing
1. **A1 + A2 + A3** — clean build, delete stub, document naming.
   `cmake --build build --target full` to confirm green.
2. **B1** — arity/value-shape audit table.
3. **B3** — prove async completion with one hand-written `Http.get` test (mirror
   `elm/time`); fix any scheduler/effect gap.
4. **B2a + B2b** — add `HttpService` (plain-data, mirror `TimerService`), then
   rewrite `HttpExports.cpp` to the stock contract on the single-threaded heap (§0);
   first real GET passes.
5. **C1 + C2 Phase 1** — in-runner server + verb/error-model HTTP E2E.
6. **B2b `track`/multipart + C2 Phase 2** — richer expect/body/progress tests.
7. **C3** — HTTPS.
8. **F1–F3** — finish/verify `getArchive` (can run in parallel with C once A1 lands).

## Remaining assumptions to confirm during implementation
- The exact Eco heap field layout for stock `Response`/`Metadata`/`Expect` records
  (B1 output) — derive from the stock `Http.elm` decoders + Eco record codegen.
- URL-injection mechanism choice (generated `TestServerConfig.elm` vs fixed port);
  default to the generated module.
- `getArchive` stays synchronous-on-main-thread (heap-safe per §0); revisit only if
  blocking the event loop becomes a problem.

## Environment note
`/work/.claude/settings.json` has a `PostToolUse` Bash hook that echoes a spurious
"bytes were valid but may be in the wrong order" / "terminal garbled" warning and
`exit 2` after Bash commands, corrupting Bash stdout relay (not files). Worth
disabling while doing this work.
