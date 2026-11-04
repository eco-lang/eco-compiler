---
status: done
updated: 2026-11-04
---

# Kernel library bug fixes: expose every confirmed bug with a test, then fix

## Goal

`eco-lib-bugs-triage.md` (2026-11-04) classified 345 suspected defects in the C++ kernel libraries
(`elm-kernel-cpp`, `eco-kernel-cpp`, `system-kernel-cpp`) and the runtime code they call. This plan
covers the 193 rated CERTAIN, LIKELY or UNSURE (5 HIGH). Following the project rule (expose bugs as
tests first, then fix), it has two phases that must not overlap:

1. **Phase 1, tests only.** Write a test for every bug, run them all once, record which tests
   expose their bug, then re-examine the bugs no test exposed and try again (Phase 1b). No product
   code changes, except the test-only hooks and harness features listed under "Shared
   infrastructure".
2. **Phase 2, fixes.** Starts only when Phase 1 (with 1b) is complete. Fix each bug so its test
   passes, in the order and groupings under "Phase 2".

Each bug's proposed test and fix, with file:line evidence, is in the appendix, one block per bug
(written by 20 parallel read-only reviews of the code; nothing was built or run while planning).

| Proposed test | Bugs |
|---|---|
| E2E | 74 |
| C++ unit | 58 |
| static check | 43 |
| none | 18 |
| **Total** | **193** |

"none" is mostly dead code (its test is the build plus the existing suites after the deletion) and
code no test can reach (Windows-only, more than 4 GiB of data, out-of-memory at one exact point
without a hook).

## Rules for the tests

- **Prefer an E2E program** (`test/<suite>/src/<Name>Test.elm` with `-- CHECK:` lines, run by
  `test/ElmE2ETestBase.hpp`). Where Eco should behave like Elm, the expected output is what stock
  Elm 0.19.1 produces: put the test in `test/elm-conformance` and record it with
  `node test/scripts/run-js-e2e.js --project elm-conformance --record <Name>`. For eco-only APIs
  (eco/kernel, eco/system) the reference is the API documentation and the JS backend's behaviour.
- **Mark a failing E2E test `-- XFAIL-NATIVE: <bug id>`** until its fix lands, so the suite stays
  green and an unexpected pass (XPASS) is reported. The JS runner ignores XFAIL-NATIVE, so a test
  whose JS twin has the same bug (HTTPSRV-02/04, HASH-01, FS-01, most HTTPS-*, PROC-03,
  PROC-NEW-1) is either run once and recorded as failing and landed with both fixes in Phase 2, or
  temporarily `-- SKIP-JS` (decision D5).
- **C++ unit tests** go in the `test` binary (`test/main.cpp`, `test/XfailGuard.hpp`,
  `XfailGuard::report("<id>")`) where it links the code, or in `eco-system-core-test`
  (`test/eco-system-core/EcoSystemCoreTest.cpp`) for system-kernel-cpp code, which needs the new
  XFAIL helper below.
- **Static checks** are grep scripts under `test/scripts/` wired into `check` and `full`, or
  `static_assert`s. A `static_assert` cannot be XFAIL'd: it is written, seen to fail in one local
  compile, recorded, and landed with its fix.
- **Tests run once**, output to a file (`2>&1 | tee /tmp/test_output.txt`), with `ulimit -c 0`
  (some tests abort on purpose).

## Shared infrastructure (Phase 1, first)

These are needed by several tests and are built before the tests that use them. Each is a test
harness feature or a test-only hook; none changes product behaviour.

| Item | Needed by |
|---|---|
| E2E directives `-- ENV: NAME=VALUE` and `-- UNSETENV: NAME`, parsed in `test/CheckPatterns.hpp`, applied to the child in `runElmChild` (`test/ElmE2ETestBase.hpp`, `ChildJob.env`) and in `test/scripts/run-js-e2e.js`; modelled on `// UNSETENV:` of `test/codegen/CodegenIsolatedTest.hpp` | ECO-NEW-1, FILE-04/09/10/11, SOCK-15, TIME-05/06, HTTPS-NEW-1, WS-21, FILE-03 (small heap) |
| E2E directives `-- RLIMIT-FSIZE:` and `-- STDIN-DELAY-MS:` | FILE-07 (short write), CONSOLE-04 |
| An XFAIL helper for `eco-system-core-test` with the `ECO_TEST_XFAIL=strict` behaviour of `XfailGuard` (which depends on the `test` binary's framework) | every C++ unit test in that binary (CORE-*, WS-*, WATCH-*, SOCK-*, SIG-*, PROC-06, FD-*, HTTPSRV-06, RESET-04..11) |
| A self-spawn `--child <scenario>` mode in `eco-system-core-test`, started with `posix_spawn` (not `fork`: a forked child has no worker threads), for scenarios that need fresh singletons (pool, reactor, watcher mode, heap) | CORE-01/08/14/18, RESET-04..11, WATCH-04/05 (poll mode via `ECO_SYSTEM_WATCH_POLL=1`) |
| Link `EcoSystem_FileSystem`, `EcoSystem_ChildProcess` (and `EcoSystem_System` for RESET-11) into `eco-system-core-test` | WATCH-*, PROC-06, RESET-* |
| New test executable `elm-kernel-time-test` (`test/elm-kernel-time/`), since `test` does not link elm-kernel-cpp | TIME-01, TIME-NEW-1 |
| New unit file `test/kernel/JsArrayKernelTest.cpp` (in `test`) | ARRAY-01/02/03/05 |
| Test-only hooks, compiled in debug/test builds only: fail-next in `KillHandle` (SOCK-12); event-loop startup failure env var in `IoReactor` (SOCK-15); throw-on-next-submit in `SysWorkPool` (FS-03) and a replaceable worker-start function (CORE-01); a throwing hook in `ChildProcess` (PROC-06); overflow-record injection in `WatchService` (WATCH-07); stage-1 result builder and table counter in `Tls` (TLS-10); `getaddrinfo` override in `HttpServerService` (HTTPSRV-06); a replacement `operator new` armed to fail once, in the test binary (CORE-18, SIG-03); a `PlatformRuntime` accessor for registered closures (TASK-01) | as listed (decision D11) |
| `test/TestHttpServer.hpp` routes: `/package-short.zip`, `/status-zip/404`, `/redirect-empty-location`, a CONNECT relay | HTTP-10/11, HTTPS-04, HTTPS-NEW-1 |
| `test/elm-conformance/elm.json`: add `elm/url`, `elm/parser`, `elm/time` | URL-*, PARSE-03/04, TIME-07/09 |
| A refactor-only move of Int add/sub/mul/pow into `runtime/src/allocator/IntArith.hpp` (no behaviour change) | BASICS-01/02/NEW-1 static checks |
| A refactor-only extraction of the inline server-open code in `WebSocket.cpp` into a named function | WS-NEW-1 unit test |

## Phase 1: write the tests

Write every test in the appendix's "Test" line, area by area (the per-area tables below). Tests
whose expected output depends on a decision (marked "blocks tests" under "Decisions") are written
after that decision. Bugs no test can expose (test kind "none") get no test; they are listed in the
Phase 1 results as "no test" so Phase 1b looks at them.

### Run them all

When every test is written, run, once each, with output kept:

1. `cmake --build build --target full 2>&1 | tee /tmp/test_output.txt` (all E2E suites, the static
   checks wired into `check`, the unit binaries `full` runs).
2. `build/test/test` and `build/test/eco-system-core-test` (and `elm-kernel-time-test`) with
   `ECO_TEST_XFAIL=strict` to see each XFAIL fail as expected.
3. The JS E2E runner (`node test/scripts/run-js-e2e.js`) for the E2E tests with a JS twin.
4. The one-off sanitizer builds the appendix names (UBSan for TIME-08 and BASICS; a heap-validate
   tree for ARRAY-NEW-1 and the GC-rooting tests).

Record the outcome of every bug in a "Phase 1 results" table appended to this plan: **exposed**
(its test fails, or XFAILs, for the stated reason), **not exposed** (the test passes: the triage
was wrong, or the test misses), or **no test**.

### Phase 1b: re-examine what no test exposed

For each "not exposed" or "no test" bug: re-read the code with the test's result in hand. Either
(a) write a better test (another trigger, a hook, a sanitizer, GC pressure), (b) downgrade it in
`eco-lib-bugs-triage.md` to WEAK (the test shows the defect is not there) and drop it from Phase 2,
or (c) keep it as "fix by inspection" with a written reason (dead code, Windows-only, OOM). ARRAY-NEW-1
is the first case to settle: if its E2E test passes in both the normal and the heap-validate
trees, it is refuted and ARRAY-05 becomes hardening only. Phase 1 ends when every bug is
exposed, refuted or explicitly fix-by-inspection.

## Phase 2: fix the bugs

Starts when Phase 1b is complete. Each fix removes its test's XFAIL marker (an XPASS otherwise
fails the run). Groups that share a fix land together; the order matters where noted:

1. **ABI-NEW-1 first:** catch exceptions around Task bodies (the binding trampolines in
   `runtime/src/platform/TaskBinding.hpp`) and move `reportFatal` into a runtime header. ABI-03,
   ABI-04, HTTP-05's OOM path and TERM-04 (terminal restore in `reportFatal`) build on it.
2. **The five HIGH bugs:** TIME-01 with TIME-07 (both rewrite `timerTickEvaluator`), HEAP-01 (one
   empty-string check in `listToStringVector` for all six callers; with HEAP-02 and a grep sweep for
   other `resolve` calls on possible constants), PARSE-01 (`parserFlatten` uses
   `StringOps::flattenToLeaf`), UTILS-05 (restore the deferred-pair stack of elm/core's `eqHelp`;
   update `EqDepthCutoffTest`, which pins the wrong answer).
3. **Shared fixes**, one change each:
   - TASK-01 + TIME-NEW-1: root each closure after `allocClosure`, as the Http registrar does.
   - JSON-01 + JSON-NEW-1 (+ JSON-05's round trip): a `JSON.stringify`-like serializer replacing
     `j.dump()`; update `EncodeFloatTest`, which pins `"0.0"`.
   - JSON-05 + JSON-06: one `Decode.int` acceptance rule.
   - REGEX-03 → REGEX-06 → REGEX-08, in that order or as one regex-kernel change (REGEX-06 moves to
     `srell::u16regex`, which matches Elm's UTF-16 `.`, and drops the `Utf16Index` converter).
   - URL-01 + URL-03 + URL-04: take the unreserved set and strict UTF-8 decoder from the dead
     `Url.cpp`, then delete it.
   - FS-01 + FS-03 (+ RESET-04): opaque, never-reused file handle ids with an in-flight count; the
     JS twin too.
   - FILE-03 + FILE-08 + FILE-NEW-1: one read helper (`fstat`, reject directories, 4 GiB cap).
   - FILE-07: one write-all loop for `writeString`, `writeBytes`, `hWriteString`.
   - FILE-04 + FILE-05 + FILE-11 + ECO-NEW-1: one `appDataDir` rewrite.
   - WATCH-02 + WATCH-03 + WATCH-08 together; WATCH-04 + WATCH-05.
   - WS-12 + WS-13 + WS-16 (the close-state flags); WS-21 + WS-NEW-1 (failed-open cleanup); WS-18 +
     WS-19.
   - CORE-01 + CORE-18 (`SysWorkPool.cpp`); CONSOLE-02 + CONSOLE-03 (one `writeAll`); FD-01 + FD-05;
     HTTP-10 + HTTP-11; HTTPS-03 + HTTPS-NEW-2; TIME-08 + TIME-09 (one delay-clamp helper);
     BASICS-01/02/NEW-1 (`IntArith.hpp`); ZLIB-01 (one ≤1 GiB feeding helper for its three call
     sites); RESET-06 + RESET-08 (`releaseOrphan` releases the hold).
4. **Dead code last**, in a few commits by file, so each license-pinned file is re-audited once
   (below). Ordering constraint: PROC-NEW-1's fix starts using `s_streamHandles`, so DEAD-17 must
   not delete it. DEAD-26 is not dead (a unit test calls `Listener::openConnections()`) and is
   closed, not deleted.
5. **JS twins** of a fixed bug land in the same commit as the native fix.

**License manifest.** Many touched files are hash-pinned (`check-kernel-license-manifest.sh` runs in
the default build and fails on any byte change; e.g. `String.cpp`, `ListExports.cpp`, `Utils.cpp`,
`ExportHelpers.hpp`, `Char.cpp`, eco-kernel `File.cpp`, `MVar.cpp`, `Runtime.cpp`). Per D15 the
re-audit is done once, after every fix has landed: one row per changed pinned file in
`kernel-license-audit.csv`, then `check-kernel-license-manifest.sh --update`. Until then, builds that
run the check fail on it; fix work builds the targets it needs without that gate. Invariant texts to amend with their
fixes: CGEN_084 (if D1 = return 0), IO_ERR_001 (FILE-04).

**Divergence documentation:** with the fixes of PARSE-03 (hex/octal/binary wrap), JSON-05/06 (`Decode.int` range) and UTILS-06 (§4.1 decided), update `design_docs/elm-divergence.md` and its summary table.

**Gates for Phase 2:** one `cmake --build build --target full`, the unit binaries, the JS runner
and a full bootstrap at the end; every Phase 1 test passes with no XFAIL left except deliberate
divergences (recorded in `design_docs/elm-divergence.md`).

## Findings beyond the triage

The reviews found these while planning; each needs a triage row and, where it is a bug, a test:

- `Basics::modBy` (`E/core/Basics.cpp`) has no final `return answer;` (UB); fix with ABI-01.
- `Json.Decode.decodeString D.string "\"\\ud83d\""` is probably rejected by the parser where Elm
  returns `Ok` (lone-surrogate escape).
- The non-stream Http kernel (`runtime/src/platform/HttpService.cpp:251`) has HTTPS-NEW-2's
  unvalidated custom method too.
- The Scheduler, PlatformRuntime and PortRuntime register their root scanners once; after a heap
  reset (tests only) they still hold pointers into the dead heap (bears on D21).
- The WebSocket event queue's `releaseOrphan` (`WsEvents.cpp`) probably has RESET-06's missing hold
  release.
- `File.readString "/proc/self/status"` returns `""` (size 0), where Node and Haskell read to EOF.
- `Debug.todo` exits with the same `exit(1)` pattern as CRASH-01.
- Once the dead `List.cpp` helpers go, the runtime `ListOps::sortBy`/`sortWith` have no callers.
- Other `assert(false` stubs (`Utils.cpp`, `JsonExports.cpp`, `Time.cpp`, `File.cpp`, `Browser.cpp`)
  need the BROWSER-01 treatment after their own triage.
- DEAD-26 is not dead (see Phase 2, step 4).

## Decisions

Settle these before the tests or fixes they affect. "Blocks tests" means the test's expected
output depends on the answer. The recommended option is first. Decided rows say so; as of
2026-11-04 every decision is decided.

| Id | Bug(s) | Question | Options (recommended first) |
|---|---|---|---|
| D31 | BASICS-01/02/NEW-1 | Int overflow semantics | **Decided (user, 2026-11-04): wrap**, as already documented (`elm-divergence.md` §1); the fix only removes the C++ signed-overflow UB by computing in `uint64_t` |
| D1 | ABI-01 | Kernel `modBy 0` | **Decided (user, 2026-11-04): return 0**, like the inline lowering: a wrong answer rather than a crash, a documented divergence from Elm (amend CGEN_084 and `elm-divergence.md`); fix the missing `return` in `Basics::modBy` with it |
| D2 | ABI-04 | `canonicalize ""` | **Decided (user, 2026-11-04):** fail with an IOError (ENOENT/EINVAL) |
| D3 | TERM-04 | Terminal restore scope | **Decided (user, 2026-11-04, recommendation taken):** restore the terminal in `reportFatal` only |
| D4 | HTTPSRV-12 | Upgrade after client disconnect | **Decided (user, 2026-11-04, recommendation taken):** (b) keep a marker entry so the error is "socket closed" (`Cancelled`) |
| D5 | JS twins | Committing red tests on JS | **Decided (user, 2026-11-04, recommendation taken):** land each test with both backends' fixes in one commit; remove the temporary `-- SKIP-JS` lines of Phase 1 then |
| D6 | SYNC-02 | Shared klog copies | **Decided (user, 2026-11-04, recommendation taken):** keep `check-SYNC-02.sh` and wire it into `check`/`full` |
| D7 | REGEX-03 | `catch (...)` in replaceAtMost also swallows replacer exceptions | **Decided (user, 2026-11-04, recommendation taken):** narrow the `catch (...)` to the regex engine's exceptions |
| D8 | REGEX-08 | Interning compiled regexes (off-heap memo; makes equal patterns `==`, check Elm) | **Decided (user, 2026-11-04, recommendation taken):** intern compiled regexes by (pattern, flags) (check Elm's `==` on equal patterns first) |
| D9 | BROWSER-01 | Native browser-only stubs | **Decided (user, 2026-11-04):** a browser-only function that returns a `Task` that can fail fails its task; a pure one (or a `Task Never`) exits with a clear "X is not supported natively" message |
| D10 | ECO-NEW-1, FILE-04/05/11 | `appDataDir` and other `Task Never` kernels that can fail | **Decided (user, 2026-11-04):** for kernels of **eco/kernel or eco/system**, change the Elm type to a failing `Task` (`Task IOError …` or the module's error type) so the failure reaches the program, updating the compiler's and tests' callers; for **elm-kernel-cpp** kernels (Elm's own API, not ours) keep the type and crash with a clear message. This applies to `appDataDir`, `getCwd`, `Runtime.dirname`, MVar read/take/put after `drop` (all eco/kernel); the Phase 1 tests that expect a crash change to expect the error |
| D11 | many | Test-only hooks in kernel code (list under "Shared infrastructure") | **Decided (user, 2026-11-04, recommendation taken):** keep the `ECO_TEST_HOOKS` hooks, debug/test builds only |
| D12 | DEAD-32, DEAD-39, DEAD-43 | Dead branch handling | **Decided (user, 2026-11-04, recommendation taken):** keep the dead branch and add a debug assert in front of it |
| D13 | DEAD-35, WS-20 | Handshake role | **Decided (user, 2026-11-04, recommendation taken):** kernel role check using the stored `server` field, before any state is created |
| D14 | DEAD-18, 20, 22, 25 | Small cleanup choices (optional empty-POST E2E; Scheduler's own `encodeHP`; `kEndedMarker`; `hasBufferedRead` plus a deviation note in `plans/eco-system-sockets.md`) | **Decided (user, 2026-11-04, recommendation taken):** DEAD-18 pin kept; leave the Scheduler's own `encodeHP`; build the two strings from `kEndedMarker`; delete `hasBufferedRead` (and the test override) with a deviation note in `plans/eco-system-sockets.md` |
| D15 | dead code, all fixes | Form of the license re-audit note for edits to pinned files | **Decided (user, 2026-11-04):** re-audit the license manifest **once, after all bugs are fixed**, not per batch (builds in between will fail `check-kernel-license-manifest.sh` and are run without that gate) |
| D16 | PARSE-03 | Hex/octal/binary literal beyond 64 bits | **Decided (user, 2026-11-04): wrap to the bit pattern** (`0xFFFFFFFFFFFFFFFF` gives `-1`), made well-defined by unsigned accumulation; a documented divergence |
| D17 | PARSE-01, PARSE-04 | Copy large ropes at each parser primitive (correct, slower on huge input); also match Elm's 2-unit advance for a lone surrogate | **Decided (user, 2026-11-04, recommendation taken):** accept the rope copy (a rope view later if a benchmark shows the cost); match Elm's 2-unit advance for a lone surrogate |
| D18 | ARRAY-NEW-1, ARRAY-05 | Fix route if NEW-1 is confirmed; primitive pushed into a boxed array | **Decided (user, 2026-11-04, recommendation taken):** kernel route (typed map/initialize variants chosen by result element type); ARRAY-05 converts the array |
| D19 | CONSOLE-02/04 | Also handle EAGAIN on a non-blocking stderr; make `readLine`/`readAll` asynchronous | **Decided (user, 2026-11-04):** CONSOLE-02 handles EINTR only and documents non-blocking stderr; **CONSOLE-04: reimplement `readLine`/`readAll` asynchronously** (the eco thread no longer blocks; the CONSOLE-04 test stays) |
| D20 | TLS-04/05/06/10 | Load OpenSSL's default for the unset one of `SSL_CERT_FILE`/`DIR`; corrupt PEM code; TLS-06 (uniform `ERR_SSL_` prefix); TLS-10 approach | **Decided (user, 2026-11-04):** TLS-04 also loads OpenSSL's default for the unset one of `SSL_CERT_FILE`/`SSL_CERT_DIR`, as OpenSSL does; TLS-05 reports `NO_CERTIFICATES` for a corrupt PEM too, and the Elm classifier is fixed so it gives `CertificateUnusable`; TLS-06 closed as by-design; TLS-10 removes the second connect stage, or the fallback (evict by age/cap) if the investigation shows the first is not feasible |
| D21 | RESET-01, 06..10 | Heap reset in the platform layer (test-only) | **Decided (user, 2026-11-04, recommendation taken):** (b) a Scheduler-wide reset on a heap-generation change (drop holds and parked closures, re-register the Scheduler, PlatformRuntime and PortRuntime scanners) |
| D22 | FILE-10, FILE-03, `/proc`, JS MVar | Empty PATH entries; zero-size/non-regular files; FILE-03 test heap; JS MVar after `drop` | **Decided (user, 2026-11-04):** an empty PATH entry means `.` everywhere (POSIX and Haskell), returning `./name`; read to EOF when a file is not regular or reports size 0; run FILE-03 with a small heap via `-- ENV:` (confirm E2E children read heap config from the environment); the JS MVar crashes after `drop` like native |
| D23 | HTTPS-01/03/09, HTTPS-NEW-1 | Unknown stream id; empty method with a body; HEAD with a stream body; CONNECT relay | **Decided (user, 2026-11-04):** an empty method is not legal HTTP and is **rejected** before sending (`BadUrl`/request error) on both backends, by the same token validation as HTTPS-NEW-2 (this supersedes the appendix's POST proposal for HTTPS-03); HTTPS-01 keeps "missing = ended" and pins it with a test; HTTPS-09 accepts and discards a HEAD upload at once (run the JS twin first); the CONNECT relay is built as test infrastructure |
| D24 | UTILS-06, JSON-05/06 | `==` on two functions; `Decode.int` beyond 64 bits | **Decided (user, 2026-11-04):** `==` on functions returns `False`, a documented divergence (`elm-divergence.md` §4.1, its TODO resolved); `Decode.int` fails to decode an integer outside the 64-bit range, a documented divergence |
| D25 | WS-08, WS-18/19, WS-21 | RNG failure; late `onClose` subscriber; WS-21 test strength | **Decided (user, 2026-11-04):** a close nobody was subscribed to is delivered once to a later `onClose` subscriber, as JS does (delivered flag on the recently-closed records); a failing system RNG aborts with a clear message (no mt19937 fallback); the memory-based WS-21 test is acceptable |
| D26 | FD-03, HTTP-11 | O_NONBLOCK leaking to inherited fds; pass "HTTP 404" text through to the compiler diagnostic | **Decided (user, 2026-11-04, recommendation taken):** FD-03 `send(MSG_DONTWAIT)` for sockets, O_NONBLOCK only on fds the channel opened; HTTP-11 no pass-through |
| D27 | CORE-07 | Show the start-failure message to Elm | **Decided (user, 2026-11-04, recommendation taken):** C++-only fix (message in stderr) |
| D28 | PROC-03, PROC-NEW-1 | `CreatePipe` for stdout/stderr; `Console.write` to an unknown handle (blocks tests) | **PROC-03 decided (user, 2026-11-04): option A**, remove the `stdout`/`stderr` fields from `Eco.Process.spawnProcess` (record `{ cmd, args, stdin }`; the child always inherits stdout/stderr) in `Eco/Process.elm`, `spawnProcessBody` (K/Process.cpp), `Process.js` and the `KernelSetFacts.elm` row, both backends in one commit; the test becomes a compile check that the fields are gone. PROC-NEW-1 decided (user, 2026-11-04): `Console.write` to an unknown handle fails with an IOError (EBADF) on both backends; child stdin handles work as in JS |
| D29 | WATCH-05/07 | Poll mode after the watched directory disappears; inotify overflow | **Decided (user, 2026-11-04):** poll mode matches inotify (one path-less Moved, then the watch is finished); an overflow is reported as one path-less Moved per watch, meaning "rescan", with the `watch`/`watchRecursive` docs updated. JS-watcher differences are settled per test after its first Node run (accept both behaviours, or `-- SKIP-JS` with a reason) |
| D30 | TIME-06/08/09, STREAM-03/07 | Delay clamping; TZ name; concatenated gzip; erasing Errored pairs | **Decided (user, 2026-11-04):** `Time.every` intervals are clamped to at least 1 ms like Node; `Process.sleep` sanitises only NaN, ±inf and huge values (to 1 ms) and keeps `sleep 0` as a yield; `TZ` is a zone Name only when IANA-shaped (or present under the zoneinfo dir), else the `Offset` fallback; concatenated gzip members stay rejected (documented, WHATWG): pin with a test and close STREAM-03; Errored pairs are erased with a bounded store of their reasons (confirm ids are never reused) |

## Phase 1 results (2026-11-04)
All tests were written by 20 parallel agents, one per group (`fixplan/resultNN.md`), on the
shared infrastructure of Stage A (E2E directives `-- ENV:`/`-- UNSETENV:`/`-- RLIMIT-FSIZE:`/
`-- STDIN-DELAY-MS:`, test-server routes and a CONNECT proxy, per-group registration files in `test`
(`test/libbugs/LibBugsGroupNN.cpp`), `eco-system-core-test` (`test/eco-system-core/libbugs/CoreGroupNN.cpp`,
`XfailCore.hpp`, a posix_spawn child-scenario mode) and the new `elm-kernel-time-test`, the static runners
`test/scripts/run-libbugs-checks.sh` and `run-libbugs-static.sh`, and the `ECO_TEST_HOOKS` test hooks in
`runtime/src/platform/TestHooks.hpp`). No bug was fixed. Two behaviour-neutral refactors landed for
testability (`runtime/src/allocator/IntArith.hpp`, `wsOpenOnConn`), and `BasicsExports.cpp` was re-audited
in the license manifest for the first.

**Combined run, once each** (`scratchpad/p1run/`):

| Run | Result |
|---|---|
| `build/test/test` (all unit tests and every E2E suite) | 2,700 run, 0 failed; every new bug test reports XFAIL / XFAIL-NATIVE |
| `ECO_TEST_XFAIL=strict build/test/test --filter libbugs-` | 23 of 29 fail (the 6 passes are pins and controls) |
| `eco-system-core-test` / strict `--only-libbugs` | pass / 49 failures (each an expected failure) |
| `elm-kernel-time-test` / strict | pass / 4 failures |
| `aot-e2e-runner` for the 5 tests needing kernels the JIT binary does not link (Console, NativeDriver) | all XFAIL-NATIVE as expected |
| JS runner, `elm-conformance` | pass (expected lines recorded from stock Elm on node) |
| JS runner, `eco-system` | 221 / 223: `FileHandleStaleTest` and `HttpStreamMethodValidationTest` fail on JS because the JS twins have the same bugs (FS-01; HTTPS-03/NEW-2): they land with both fixes (D5) |
| `run-libbugs-checks.sh` | 46 checks FAIL (bug present), 1 PASS (SYNC-02, a drift guard, correct today) |
| `run-libbugs-static.sh` | 6 compile-fail (BASICS-01/02/NEW-1, DEAD-22, DEAD-45, TLS-01), 1 compile-ok (SYNC-03, a guard) |

**Per bug:** 164 EXPOSED, 22 NO-TEST, 7 NOT-EXPOSED, 0 BLOCKED.
All five HIGH bugs are exposed: TIME-01 (child aborts applying the stale tagger after a forced minor
GC), TIME-07 (duplicate `Time.every` intervals: one subscriber gets no ticks), HEAP-01 (an empty string
argument aborts, at all three entry points), PARSE-01 (`Parser.run` on a 140,000-unit rope aborts),
UTILS-05 (unequal values more than 100 deep compare equal). Three UNSURE bugs are confirmed:
FILE-NEW-1 (`readString` of a directory tries to allocate 2^63 bytes), FD-01 (a closed channel closes a
reused fd), ARRAY-NEW-1 (`Array.map (Debug.log "x")` stores Int results boxed; `get` returns pointer bits
and a later `push` aborts, which also makes ARRAY-05 reachable).

The 7 NOT-EXPOSED are all expected: HTTPS-01 and UTILS-06 pin behaviour decided as correct (D23, D24);
DEAD-43 tests the live branches around dead code; SYNC-02 and SYNC-03 are drift guards, correct today;
FILE-12 and PROC-07 are Windows-only and pass on Linux.

### Findings from Phase 1

- **New bugs:** `Url.fromString` rejects IPv6 hosts, so an IPv6 `Host` request reaches the program with an
  empty URL (group 08); `copyForUnsafeSet` (`JsArrayExports.cpp:849`) is a second stray exported C symbol of
  ABI-02's kind (group 09); the Elm-side TLS classifier (`Socket/Tls.elm` `certificateProblem`) maps every
  code containing `_CERT`, `ERR_SSL_NO_CERTIFICATES` included, to `VerificationFailed`, so TLS-05's
  documented `CertificateUnusable` cannot appear even after the kernel fix (group 10); each successful
  native WebSocket open and close retains about 140 KiB (not investigated; group 05); the hold census is
  probably enabled in release builds too (`Scheduler.cpp:552` tests `defined(ECO_HEAP_VALIDATE)`, which
  `AllocatorCommon.hpp` always defines; Stage A3).
- **Triage corrections:** decimal `Parser.int` does not go through `String.toInt`; it uses the same
  accumulation loop and also wraps (`"99999999999999999999"` gives `Ok 7766279631452241919`), consistent
  with D16 applied to every base; ABI-01's kernel `modBy` is unreachable from compiled Elm (every call
  shape lowers to `eco.int.modby`), exposed only by a direct C++ test (lower its reachability); HTTPS-09's
  real symptom is a 10 s Timeout (HEAD still sends `Transfer-Encoding: chunked`); HTTPSRV-12's JS twin has
  the same bug; FILE-08's `/proc` read returns an error, not `""`; DEAD-19 has 4 unnamed scanners, not 5.
- **Decisions to revisit:** STREAM-03 (D30): node's `DecompressionStream` decodes concatenated gzip members,
  so "matches WHATWG" does not hold on node and native and JS disagree (test marked `SKIP-JS`);
  HTTPSRV-12's test assumes D4 option (b); RESET-01's second case assumes D21 re-registers the scanner;
  CONSOLE-04's test should be deleted if D19 keeps the blocking design.
- **Infrastructure fixed during Phase 1:** the `/package-short.zip` route understated the entry size (16, below the 34 stored),
  so HTTP-10's path was unreachable; it now states 64. `test` now whole-archives `EcoKernel_Console` and
  `EcoKernel_Crash`, so the Console and Crash E2E tests run under the JIT (they had XFAILed on missing
  symbols). Still not linked into `test`: `EcoKernel_NativeDriver` (HEAP-02 runs on the AOT runner only).
- **Temporary `-- SKIP-JS`** (D5 option, decision still open): HTTPSRV-02/04, HTTPSRV-12, PROC-05; remove
  with the fixes to both twins.

### Phase 1b candidates

Every bug is exposed, refuted by decision, or a fix by inspection, so Phase 1 is complete. Phase 1b should
still look at: FILE-08 (stale errno: no deterministic trigger), CRASH-01, CONSOLE-03, FD-05, FILE-12,
HTTP-12, PROC-07, TIME-05 (Windows/macOS-only: run on those hosts if one is available), and the ZLIB-01
StreamCodec half (needs the refactor that is part of its fix). The DEAD-* NO-TEST entries are fixes by
inspection whose test is the build.

### Per-bug results

| ID | Group | Test kind | Test location | Result | Evidence |
|---|---|---|---|---|---|
| ABI-01 | 09 | C++ unit (isolated, fork) + E2E pin | test/libbugs/LibBugsGroup09.cpp `libbugs-09 ABI-01 [xfail ABI-01]: kernel modBy 0 returns 0 instead of throwing`; test/elm/src/ModByZeroKernelPathTest.elm (passing pin) | EXPOSED (unit); E2E path NOT reachable | unit: `XFAIL ABI-01: Elm_Kernel_Basics_modBy(0, x): exit 99, stderr: exception: Elm.Kernel.Basics.modBy: modulus was zero`; strict: `FAILED: ABI-01 reproduces`. E2E: the proposed `-- CHECK-MLIR: Elm_Kernel_Basics_modBy` FAILED (`Missing pattern`): `List.map (modBy 0)`, `modBy` picked from a list at run time, and `List.map2 modBy` all go through `Basics_modBy_$_2`, whose body is `eco.int.modby` (In |
| ABI-02 | 09 | static (nm + source) | test/scripts/libbugs/check-ABI-02.sh | EXPOSED | `unmangled non-export C symbol: kernelListMapN (ListExports.cpp.o in build/elm-kernel-cpp/libElmKernel_List.a)`; source part lists ListExports.cpp:425 kernelListMapN, :660 listToKindedVectors, :702 listFromPermutation inside `extern "C"`. Also flags `copyForUnsafeSet` (JsArrayExports.cpp:849, `inline` in an anonymous namespace inside that file's `extern "C"` block, exported as W symbol) -- same de |
| ABI-03 | 09 | static (python in sh) | test/scripts/libbugs/check-ABI-03.sh | EXPOSED | `21 unguarded export(s) in: CrashExports.cpp, EnvExports.cpp, HashExports.cpp, HttpExports.cpp, MVarExports.cpp, NativeDriverExports.cpp, RuntimeExports.cpp` (exactly the triage list); `// no-guard: <reason>` waiver supported |
| ABI-04 | 09 | E2E x2 | test/eco-kernel/src/FileCanonicalizeEmptyTest.elm, test/eco-kernel/src/FileCanonicalizeDeletedCwdTest.elm (both `-- XFAIL-NATIVE: ABI-04`, deleted-cwd also `-- LINUX-ONLY`) | EXPOSED | `OK (XFAIL: ABI-04 ... -- filesystem error: cannot make absolute path: Invalid argument [])` and `... -- filesystem error: cannot make absolute path: No such file or directory [rel])`. Split into two programs because the first throw ends the process. Expected after fix (D2): `empty: "Err ...` / `deleted-cwd: "Err ...`. No JS run: run-js-e2e.js knows only eco-system and elm-conformance, not eco-ker |
| ABI-05 | 09 | static (python in sh) | test/scripts/libbugs/check-ABI-05.sh | EXPOSED | `C bool at the kernel ABI: elm-kernel-cpp/src/KernelExports.h:605: HPtr Elm_Kernel_Browser_reload(bool skipCache)` and BrowserExports.cpp:36; scans both KernelExports.h headers and every *Exports.cpp in the three kernel trees (337 + 59 + eco-system declarations parsed) |
| ABI-NEW-1 | 09 | C++ unit (isolated, fork) x2 | test/libbugs/LibBugsGroup09.cpp `libbugs-09 ABI-NEW-1 [xfail ABI-NEW-1]: a throwing sync / async binding body ends in [eco-runtime] FATAL` | EXPOSED | `XFAIL ABI-NEW-1: sync binding body threw: exit 99, FATAL line absent, stdout flushed, stderr: body-ran ... exception: boom` (same for async): the exception unwinds out of `Scheduler::drain` uncaught; precondition "body-ran" asserted with TEST_FAIL. Strict: both `FAILED: ABI-NEW-1 reproduces` |
| ARRAY-01 | 13 | C++ unit (isolated, 3 forked children) | test/libbugs/LibBugsGroup13.cpp `testArray01WideIndex` | EXPOSED | `XFAIL ARRAY-01: unsafeSet_Int(2^32+1): child signal 11; unsafeSet(boxed 2^32+1): child signal 11; unsafeGet_Int(2^32+1): child exit 10, stderr: unsafeGet_Int(2^32+1) returned element 1 (20)`. Both set variants SIGSEGV and the get returns element 1. |
| ARRAY-02 | 13 | C++ unit (isolated) | LibBugsGroup13.cpp `testArray02BoxedUnsafeSetKind` | EXPOSED | `Float: kind 1 (want 2), elements[0].f 9.25, unsafeGet 1 tag 0 (want Tag_Float 1); Char: kind 1 (want 3), elements[0] 0x7a, unsafeGet 0 tag 0 (want Tag_Char 2)`. The boxed-String control (kind 0, pointers kept) passes. |
| ARRAY-03 | 13 | C++ unit (isolated) | LibBugsGroup13.cpp `testArray03BoxedPushKind` | EXPOSED | `Char: kind 1 (want 3), elements[1] 0xffffffff00000062 (want 0x62), unsafeGet 1 tag 0; Float: kind 1 (want 2), elements[1].f 3.75, unsafeGet 1 tag 0` |
| ARRAY-05 | 13 | C++ unit (isolated, forked child) + E2E (shared with NEW-1) | LibBugsGroup13.cpp `testArray05PushIntIntoBoxed`; test/elm-conformance/src/ArrayMapDebugLogKindTest.elm | EXPOSED | unit: `child exit 10, stderr: result kind 0 len 3 [0x10500000010,0x10500000000,0x4]` (raw 4 in a boxed slot). E2E: `Array.push 4` on an `Array.map (Debug.log "x")` / `Array.initialize 3 (Debug.log "i")` array, then `Array.toList`, aborts with `RuntimeExports.cpp:2506 spliceArgsForSaturatedCall: Assertion 'hp_ptr && "cannot un-box null/embedded HPointer"'` (SIGABRT). So ARRAY-05 is reachable from E |
| ARRAY-NEW-1 | 13 | E2E (elm-conformance, recorded on JS) | test/elm-conformance/src/ArrayMapDebugLogKindTest.elm (`-- XFAIL-NATIVE: ARRAY-NEW-1 ...`) | EXPOSED (NEW-1 confirmed) | native JIT: `OK (XFAIL: ARRAY-NEW-1 ... -- Test crashed: SIGABRT)`. JS: PASS. Single-binding probes, since deleted: `Array.get 2 (Array.initialize 3 (Debug.log "i"))` gives `get2i: Just 1120986465016` (pointer bits, want `Just 2`); `Array.get 35 (Array.map (Debug.log "y") (Array.fromList (List.range 1 40)))` gives `bigGet: Just 1120986467376` (want `Just 36`); push+toList on either aborts (ARRAY-0 |
| BASICS-01 | 15 | static_assert TU (+ runtime regression in `test`) | test/libbugs-static/BASICS-01.cpp; test/libbugs/LibBugsGroup15.cpp | EXPOSED | run-libbugs-static: compile-fail, 4x "static_assert expression is not an integral constant expression", notes "value 9223372036854775808 is outside the range of representable values of type 'long'" (IntArith.hpp:22/25/28). Runtime regression `libbugs-15 BASICS-01` passes (code wraps today) |
| BASICS-02 | 15 | static_assert TU (+ runtime regression) | test/libbugs-static/BASICS-02.cpp; LibBugsGroup15.cpp | EXPOSED | compile-fail on 2^62, 3^39, (-2)^63 (controls 5^-1, 0^0, 2^10 compile); note "value 18446744073709551616 is outside the range ... int64_t" at IntArith.hpp:40 (`b *= b`). Runtime regression passes |
| BASICS-NEW-1 | 15 | static_assert TU (+ runtime regression on `eco_int_pow`) | test/libbugs-static/BASICS-NEW-1.cpp; LibBugsGroup15.cpp | EXPOSED | compile-fail on ecoIntPow(7,22), (-3,39) (eco_int_pow delegates to ecoIntPow); runtime case `libbugs-15 BASICS-NEW-1` calls the real `eco_int_pow`, passes (pins the delegation) |
| BROWSER-01 | 14 | C++ unit (forked child) x2 + static grep check | LibBugsGroup14.cpp `libbugs-14 BROWSER-01 [xfail BROWSER-01]: Browser.Navigation.load ...` / `File.Select.file ...`; test/scripts/libbugs/check-BROWSER-01.sh | EXPOSED (E2E as proposed: BLOCKED) | Child killed by signal 6: "BrowserExports.cpp:32: ... Assertion `false && "Elm_Kernel_Browser_load not implemented - requires platform"' failed." The same for FileExports.cpp:82 uploadOne. Want: exit 1 plus "<fn> is not supported natively". FAILS under strict. Grep check FAIL: 27 / 12 `assert(false` sites. The planned E2E is BLOCKED because no test suite's elm.json has elm/browser or elm/file as a |
| BYTES-04 | 11 | C++ unit, `test` binary (isolated suite) | test/libbugs/LibBugsGroup11.cpp `libbugs-11 BYTES-04 [xfail BYTES-04]` | EXPOSED | `XFAIL BYTES-04: elm_encoder_size of a sequence encoder of width 2^32 + 8 returned 8 (truncated to u32)`. Strict mode: FAILED, as expected. |
| BYTES-05 | 11 | static grep check | test/scripts/libbugs/check-BYTES-05.sh | EXPOSED | FAIL: no little-endian `static_assert` in BytesExports.cpp (10 swap sites), BytesOps.hpp (10), BFToLLVM.cpp (4 `ByteSwapOp`). It is a grep check, not a static_assert TU, because the assert itself is the fix and cannot fail on a little-endian host. |
| CONSOLE-01 | 13 | E2E (eco-kernel, process mode, STDIN) | test/eco-kernel/src/ConsoleReadAllRawTest.elm (`-- XFAIL-NATIVE: CONSOLE-01 ...`) | EXPOSED (AOT); JIT harness BLOCKED | AOT (`build/test/aot-e2e-runner --filter Console`): output `len: 5` / `lines: ["a","","b",""]`, want `len: 8` / `lines: ["","","a","","b","",""]`, so it reports XFAIL. JIT (`build/test/test --filter ConsoleReadAllRaw`) XFAILs for the WRONG reason: `JIT session error: Symbols not found: [ Eco_Kernel_Console_readAll ]`. The `test` binary does not link EcoKernel_Console. Fixing this needs EcoKernel_C |
| CONSOLE-02 | 13 | C++ unit (isolated, forked child; compiles eco-kernel Console.cpp into the TU because `test` does not link EcoKernel_Console) | LibBugsGroup13.cpp `testConsole02LogShortWrite` | EXPOSED | `child exit 10, stderr: received 65536, 65536, 65536 of 1048577 bytes` (3 of 3 runs short: one 64 KiB pipe write, then SIGUSR1 without SA_RESTART, and the rest is dropped) |
| CONSOLE-03 | 13 | none (runtime); static grep check added | test/scripts/libbugs/check-CONSOLE-03.sh | NO-TEST (Windows-only, >2 GiB message); grep check FAILs today, as expected | No runtime test: it needs a >2 GiB log on Windows (Windows is low priority). The grep check `sh test/scripts/run-libbugs-checks.sh /work CONSOLE-03` gives FAIL: `log()` writes directly with `_eco_write` at Console.cpp:171 (Windows) and :175 (POSIX). It passes once `log` goes through the CONSOLE-02 `writeAll` helper. |
| CONSOLE-04 | 13 | E2E (eco-kernel, STDIN + STDIN-DELAY-MS 500) | test/eco-kernel/src/ConsoleReadLineNonBlockingTest.elm (`-- XFAIL-NATIVE: CONSOLE-04 ...`) | EXPOSED (AOT); JIT harness BLOCKED (same as CONSOLE-01) | AOT: output `line: hello: ()` then `tick: ()`. The 50 ms timer fires only after the 500 ms blocked read, so `CHECK: tick` / `CHECK-NEXT: line: hello` fail and the test XFAILs. The binary run by hand with `(sleep 0.5; printf 'hello\n') \ ` gives the same order. JIT: same missing `Eco_Kernel_Console_*` symbols. Caveat: D19 is not marked decided, and its recommended option is "keep blocking, document |
| CORE-01 | 15 | C++ unit, child scenario (worker-start hook) | test/eco-system-core/libbugs/CoreGroup15.cpp, scenario `CORE-01/partial-start` | EXPOSED | child exit 1: "core01: first instance() threw: test: cannot start thread: Resource temporarily unavailable" / "starter calls 2 after first, 6 after second; threadCount 4" (the constructor ran twice; thread 0 of the first one runs on freed memory) |
| CORE-07 | 15 | C++ unit, in process | CoreGroup15.cpp `testRunErrKeepsMessage` | EXPOSED | `XFAIL CORE-07: RunErr stderr field is "", expected "spawn table full"` (outer kind 0, "EIO", exit -1 CHECKed OK). Kernel level only: Elm's decodeFailedRun ignores stderr for kind 0 (D27 still open) |
| CORE-08 | 15 | C++ unit, in process (variant A) + child `CORE-08/counted` (variant B) | CoreGroup15.cpp | EXPOSED | A: "resume called 2 times, last ctor 1 (Task_Fail \"late\")"; B: child SIGABRT, stderr "eco: liveness: second release of a hold (token 0x1, acquired at test.core08)". Synthetic body; the real Stream path (transformCodec throw hook) not written (optional in the proposal) |
| CORE-14 | 15 | C++ unit, child `CORE-14/reactor-init-fd-leak` (RLIMIT_NOFILE leaves one fd) | CoreGroup15.cpp | EXPOSED | child exit 1: "core14: f0 4 f1 5; after IoReactor::instance() f0 is open (anon_inode:[eventpoll])"; precondition "cannot create the event loop" seen on stderr. Only the eventfd branch on Linux/epoll; epoll_ctl and kqueue branches not reachable |
| CORE-18 | 15 | C++ unit, child `CORE-18/pool-oom-in-handler` with a weak replacement `operator new` armed once per thread | CoreGroup15.cpp | EXPOSED | child SIGABRT, stderr "terminate called after throwing an instance of 'std::bad_alloc'". Deque-node (`ready_.push_back`) arm not written (proposal: fragile, optional) |
| CRASH-01 | 19 | none (Windows-only) + POSIX regression pins | /work/test/eco-kernel/src/ProcessExitPendingTimerTest.elm, /work/test/elm/src/DebugTodoPendingTimerTest.elm | NO-TEST | The hang is Windows-only and nondeterministic; nothing on Linux reaches it. Pins (pass today): `Eco.Process.exit (ExitFailure 3)` and `Debug.todo` with a pending 60 s timer exit 3 / 1, no later output. The planned `Eco.Crash.crash` pin is BLOCKED in the JIT E2E harness: `JIT session error: Symbols not found: [ Eco_Kernel_Crash_crash ]` (EcoKernel Crash is not linked into the test JIT; needs a CMak |
| DEAD-01 | 01 | grep check + E2E guard | test/scripts/libbugs/check-DEAD-01.sh; test/elm-conformance/src/CharFromCodeWideIntTest.elm | EXPOSED (check); E2E guard passes by design | check FAIL: `present: elm-kernel-cpp/src/browser/Browser.{hpp,cpp}`, `core/Debug.{hpp,cpp}`, `Char.hpp:24 char32_t fromCode(int32_t code);`, `DebugExports.cpp:8 #include "Debug.hpp"`. E2E: `wide: 65533`, `neg: 65533`, ... matches stock Elm on JS + native (dead code cannot be exposed by a program) |
| DEAD-02 | 01 | grep check | test/scripts/libbugs/check-DEAD-02.sh | EXPOSED | `ExportHelpers.hpp:21 #include <cstdio>` with no stdio identifier; `time/TimeExports.cpp:125 FILE* f = fopen(...)` without its own `<cstdio>` (triage correction confirmed) |
| DEAD-03 | 01 | grep check | test/scripts/libbugs/check-DEAD-03.sh | EXPOSED | `present: elm-kernel-cpp/src/core/{Scheduler,Platform,Process}.hpp`; precondition (no bare include of them in core/) held |
| DEAD-04 | 01 | compile-warning check | test/scripts/libbugs/check-DEAD-04.sh | EXPOSED | `DebugExports.cpp:30:14: warning: unused variable 'value_bits' [-Wunused-variable]` (TU recompiled -fsyntax-only from ninja compdb) |
| DEAD-05 | 01 | grep check | test/scripts/libbugs/check-DEAD-05.sh | EXPOSED | `47: exit(1);` and no `#include <cstdlib>` in DebugExports.cpp |
| DEAD-06 | 01 | grep check | test/scripts/libbugs/check-DEAD-06.sh | EXPOSED | `Char.cpp:3 #include <stdexcept>`, no throw/exception type used |
| DEAD-07 | 01 | grep check (+ existing E2E AppendTypeSplitTest as guard) | test/scripts/libbugs/check-DEAD-07.sh | EXPOSED | `Utils.cpp:798  alloc::isNil(Allocator::instance().wrap(a))`, `:786 if (!a && !b) return alloc::emptyString();` |
| DEAD-08 | 01 | grep check (+ existing String fold E2E guards) | test/scripts/libbugs/check-DEAD-08.sh | EXPOSED | `String.cpp:129/148 HPointer foldl/foldr(FoldFunc ...)`, `String.hpp:103 using FoldFunc` |
| DEAD-09 | 01 | compile-warning check | test/scripts/libbugs/check-DEAD-09.sh | EXPOSED | `String.cpp:41:12: warning: unused function 'consCellChar' [-Wunused-function]` |
| DEAD-10 | 01 | grep check + E2E guard | test/scripts/libbugs/check-DEAD-10.sh; test/elm-conformance/src/StringWordsUnicodeSpaceTest.elm | EXPOSED (check); E2E guard passes by design | check FAIL: `String.cpp:310` and `:355 if (ranges.empty()) return alloc::listNil();`. E2E (UTF-16 branch, U+00A0/U+3000/U+2028): `nbsp around: ["a"]`, `ideographic only: [""]`... same on stock Elm, JS backend, native |
| DEAD-11 | 01 | grep check | test/scripts/libbugs/check-DEAD-11.sh | EXPOSED | `ListExports.cpp:426 static_assert(true, "n_args ∈ {2,3,4,5}");` |
| DEAD-12 | 01 | grep check (+ existing ListOpsTest / sort E2E as guards) | test/scripts/libbugs/check-DEAD-12.sh | EXPOSED | `ListExports.cpp:112 listToVector`, `:123 getConsHead`; `List.hpp:35/53/69 fromArray/sortBy/sortWith`, `KeyFunc`/`CmpFunc`; precondition (no callers in elm/eco kernels, runtime, test) held |
| DEAD-14 | 02 | C++ unit pin (isolated, passes today) | test/libbugs/LibBugsGroup02.cpp (`libbugs-02 DEAD-14: live read_bytes export rejects a negative length (pin)`) | NO-TEST | The dead `Elm::Kernel::Bytes::read_bytes` has no callers, so nothing can reach it. The optional pin on the live export passes (1/1, /tmp/libbugs-02.txt): `Elm_Kernel_Bytes_read_bytes(-1 / INT64_MIN length, -1 offset, overrun)` throws `BytesDecodeFailure`, and an in-range read succeeds. Gate: the build links after `Bytes.cpp/.hpp` are deleted. |
| DEAD-15 | 02 | grep check | test/scripts/libbugs/check-DEAD-15.sh | EXPOSED | FAIL: `727:static u16 jsonValueCtor`, `930:static uint64_t makeDecoder1i`. A by-hand clang `-fsyntax-only -Wunused-function` on JsonExports.cpp also warns `unused function 'jsonValueCtor'` (:727) and `'makeDecoder1i'` (:930). |
| DEAD-16 | 02 | none | - | NO-TEST | Dead namespace API (File.cpp/hpp, Browser.cpp/hpp). The only check is that the build and link still work after deletion. DEAD-01's existing check also reports Browser.hpp/.cpp as present. |
| DEAD-17 | 02 | none | - | NO-TEST | A map that is written but never read can't be seen from Elm. Gate: the eco-kernel/eco-system spawn E2E tests. |
| DEAD-18 | 02 | E2E regression pin (no XFAIL) | test/eco-kernel/src/HttpEmptyPostTest.elm | NO-TEST (pin passes, as intended) | Native run PASSED 1/1 (/tmp/libbugs-02-dead18.txt). A body-less `Eco.Http.fetch "POST"` to `/anything` reaches the server with method POST, `content-length: 0` and an empty body. There was no existing eco fetch POST test: the two POST hits in eco-system are HttpServer tests. There is no JS run because run-js-e2e.js has no `eco-kernel` project (it only knows eco-system and elm-conformance). |
| DEAD-19 | 02 | grep/python check | test/scripts/libbugs/check-DEAD-19.sh | EXPOSED | FAIL: UNNAMED at runtime/src/platform/Scheduler.cpp:57, elm-kernel-cpp/src/http/HttpExports.cpp:428, eco-kernel-cpp/src/eco-kernel/Runtime.cpp:92, eco-kernel-cpp/src/eco-kernel/MVar.cpp:308. Triage correction: **PlatformRuntime.cpp:99 is already named "platform-runtime"**, so 4 sites are unnamed, not 5. Registry.hpp:118 passes its `name_` member (a static `const char*`), and the check accepts it.  |
| DEAD-20 | 02 | none | - | NO-TEST | The duplicate `encodeHP`/`decodeHP` copies behave identically, so there is nothing to expose. Gate: an E2E run of elm-http, elm-time and elm-core. |
| DEAD-21 | 02 | E2E (existing tests, regression pin) | test/elm-http/src/HttpTrackProgressTest.elm, HttpTrackChunkedTest.elm | NO-TEST (pin passes, as intended) | `build/test/test --filter HttpTrack` gives 3/3 PASSED (/tmp/libbugs-02-dead21.txt; this includes eco-system LiveHttpTrackerReuseTest). The optional build-validate/GC-pressure run was not done: no build-validate tree exists, and it would have to be recreated. |
| DEAD-22 | 02 | grep check + static_assert TU | test/scripts/libbugs/check-DEAD-22.sh; test/libbugs-static/DEAD-22.cpp | EXPOSED | Grep check FAIL: `kEndedMarker` is defined at Core.hpp:127 and never used. The hard-coded `"\x02..."` literals are at Stream.cpp:61 and :63 and StreamPipe.cpp:50. The grep check passes under either fix option (marker used, or marker deleted). The static TU gives compile-fail: `no member named 'kWritableClosed' in namespace 'Eco::System'` (lines 16 and 18). Its first assert (marker == "\x02") compi |
| DEAD-23 | 02 | grep check | test/scripts/libbugs/check-DEAD-23.sh | EXPOSED | FAIL: `Stream.cpp:92:std::string describeErrno(int err)`. A by-hand clang `-Wunused-function` also warns `unused function 'describeErrno'` (Stream.cpp:92:13). |
| DEAD-24 | 02 | none | - | NO-TEST | Deleting the field is its own compile check. Gate: the build, eco-system-core-test, and the TLS/WS E2E tests. |
| DEAD-25 | 02 | none | - | NO-TEST | Dead virtual method. Deleting it is its own compile check. Note: the fix must also remove the `override` in test/eco-system-core/EcoSystemCoreTest.cpp:2120. |
| DEAD-26 | 03 | none | - | NO-TEST | Not dead: test/eco-system-core/EcoSystemCoreTest.cpp (max-connections credit test) calls `Listener::openConnections()`, so the build guards it. Close as "not dead". |
| DEAD-27 | 03 | static check | /work/test/scripts/libbugs/check-DEAD-27.sh | EXPOSED | FAIL: `unused definition: .../Socket/SocketTables.cpp:65:bool resumeToken(uint64_t token, HPointer& task) {` (no other `resumeToken(` in system-kernel-cpp/src or test/). Passes (rc 0) on a /tmp copy with the fix applied. |
| DEAD-29 | 03 | static check | /work/test/scripts/libbugs/check-DEAD-29.sh | EXPOSED | FAIL: socketNotImplementedTask, socketDoneTask, notImplementedBody and doneBody have no user outside Socket.cpp:35,42,180,182 / Socket.hpp:45,49. Passes on a fixed copy. Overlaps group DEAD-NEW-1's check (same stub). |
| DEAD-30 | 03 | static check | /work/test/scripts/libbugs/check-DEAD-30.sh | EXPOSED (drift only, no behaviour bug) | FAIL: EP_T_MASK, CONN_IDS_MASK, CONN_ENDPOINTS_MASK and CONN_T_MASK are unused in SocketTables.cpp. The literals are at :280 `0x11`, :295 `0x5`, :298 `0` and :299 `0x1`. Passes on a fixed copy. |
| DEAD-31 | 03 | static check | /work/test/scripts/libbugs/check-DEAD-31.sh | EXPOSED (drift only) | FAIL: DGRAM_T_MASK and DGRAM_FROM_MASK are unused in Udp.cpp. The literals are at :418 `0x4` and :419 `0`. Passes on a fixed copy. |
| DEAD-32 | 03 | static check | /work/test/scripts/libbugs/check-DEAD-32.sh | EXPOSED (drift only) | FAIL: SPEC_TRIPLE_MASK is defined (ChildProcessManager.hpp:53) but appears only in a comment (ChildProcessManager.cpp:85). The check accepts either D12 option: an assert that uses it, or deleting the constant. Passes on a fixed copy (assert variant). |
| DEAD-34 | 03 | none | - | NO-TEST | Unused parameters (`headDone` ok/err) with one internal caller. Compilation and the WebSocket dial E2E tests cover it. Fix by inspection. |
| DEAD-35 | 03 | C++ unit, child scenario | /work/test/eco-system-core/libbugs/CoreGroup03.cpp (`testWsRoleMismatch`, scenario `DEAD-35/role-mismatch`) | EXPOSED | 3 XFAILs. `client-open-as-server: parked sockets+1 hsLeft=0`, `server-open-as-client: parked sockets+1 hsLeft=0`, `client-reject: parked sockets+0 hsLeft=0`. A role mismatch is accepted (task parked, handshake consumed, WebSocket entry created) where EINVAL at once is expected. Under ECO_TEST_XFAIL=strict: 3 failures (`FAIL DEAD-35 reproduces (strict)`). |
| DEAD-36 | 03 | none | - | NO-TEST | Write-only local `resumed` in `onClosed`. No behaviour; the WebSocket close E2E tests cover the function. Fix by inspection. |
| DEAD-37 | 03 | none | - | NO-TEST | Write-only member `Http2Client::closeCode_`. No behaviour; compilation and the WS-over-h2 tests cover it. Fix by inspection. |
| DEAD-39 | 03 | static check | /work/test/scripts/libbugs/check-DEAD-39.sh | EXPOSED | FAIL: `H2StreamPort.cpp:26:constexpr int64_t kDefaultDrainMs = 2000;` and its use at :140. All 4 callers (WsProtocol.cpp:232,239,1052,1083) pass `kDrainMs`. Passes on a fixed copy. |
| DEAD-40 | 03 | static check | /work/test/scripts/libbugs/check-DEAD-40.sh | EXPOSED | FAIL: `wsNotImplementedBody` has no user (WebSocket.cpp:233, WebSocket.hpp:52). Passes on a fixed copy. |
| DEAD-41 | 17 | static grep check | /work/test/scripts/libbugs/check-DEAD-41.sh | EXPOSED | `run-libbugs-checks.sh /work DEAD-41` → FAIL: HttpServer.cpp:371 `HPointer httpServerNotImplementedBody(...)`, HttpServer.hpp:79 declaration |
| DEAD-43 | 17 | C++ unit (eco-system-core-test, in-process) | /work/test/eco-system-core/libbugs/CoreGroup17.cpp `testFaceCloseWriteThenShutdown` | NOT-EXPOSED (by design) | No behaviour bug: the branch is dead. The test pins both reachable paths and passes today with 0 failures: (a) queued 8 MiB write, close-write parked, then `writeFaceShutdown` gives exactly 1 close result with ECANCELED; (b) empty queue gives exactly 1 close with err 0, and the peer sees the FIN. It is a plain CHECK (no XFAIL) and must stay green once the fix adds `assert(!closePending_)`. The tri |
| DEAD-44 | 17 | static grep check | /work/test/scripts/libbugs/check-DEAD-44.sh | EXPOSED | FAIL: "expected exactly one definition of CTOR_TIME_EVERY, found 2": TimeEffectManager.cpp:54, TimeExports.cpp:48 |
| DEAD-45 | 17 | static_assert TU | /work/test/libbugs-static/DEAD-45.cpp (ref PlatformRuntime.cpp) | EXPOSED | `run-libbugs-static.sh /work/build DEAD-45` → compile-fail with the single error `static_assert failed ... 'kRouter != kConstantTag' "DEAD-45: CTOR_Router equals CONSTANT_TAG (0xFFFD)"`. The other 5 pairwise asserts hold. |
| DEAD-NEW-1 | 17 | static grep check | /work/test/scripts/libbugs/check-DEAD-NEW-1.sh | EXPOSED | FAIL: Socket.cpp:34-35 `notImplementedBody`, :180 `socketNotImplementedTask`, Socket.hpp:45. It uses a word match, so `wsNotImplementedBody` and `httpServerNotImplementedBody` are excluded. It is the same deletion as DEAD-29. |
| DEBUG-01 | 16 | C++ unit (`test`, isolated suite) | test/libbugs/LibBugsGroup16.cpp `testDebugTodoMessageUnderCapture` (name `libbugs-16 DEBUG-01 [xfail DEBUG-01]: ...`) | EXPOSED | `XFAIL DEBUG-01: exit 1, stderr ""`. Strict: `FAILED: DEBUG-01 reproduces`. Variant: the plan's `--isolated-child debug-todo` kind needs test/main.cpp, which this group may not edit. Instead the isolated case forks with XfailGuard::runInChild, installs an ostringstream with eco_set_output_stream, and calls Elm_Kernel_Debug_todo("boom"). The child is guarded by alarm(30). |
| ECO-NEW-1 | 17 | E2E (native) | /work/test/eco-kernel/src/FileAppDataDirTaskNeverTest.elm (`-- UNSETENV: HOME ECO_HOME`, `Task.perform`, `-- XFAIL-NATIVE: ECO-NEW-1`) | EXPOSED | Output: `[eco-runtime] unhandled top-level Task.fail (no surrounding Task.onError) — failure value dropped`; `GotDir` never arrives → `OK (XFAIL: ECO-NEW-1 ... Missing pattern: FileAppDataDirTaskNeverTest: dir ends with /.ecotest: True)`. The "started" CHECK matched. eco-kernel has no JS project in run-js-e2e.js, so there was no JS run. |
| FD-01 | 16 | C++ unit (eco-system-core-test) | test/eco-system-core/libbugs/CoreGroup16.cpp `testFdChannelReusedFdNotClosed` | EXPOSED | `XFAIL FD-01: after the channel's close, fd 4 (reused for /dev/null) is closed (errno 9)`. Preconditions checked: both reads failed with EBADF, the Close result arrived. Strict run: `FAIL FD-01 reproduces (strict)`. This settles the UNSURE triage: the bug is real. |
| FD-03 | 16 | C++ unit (eco-system-core-test, Linux) | test/eco-system-core/libbugs/CoreGroup16.cpp `testFdChannelTtyWriteDoesNotStall` | EXPOSED | `XFAIL FD-03: no result 2000 ms after shutdown(): the channel thread is blocked in write() on the full pty`. Preconditions checked: data reached the pty master, and the 1 MiB write had not completed. The thread unblocks once the master is drained, and the late result is checked. Strict: `FAIL FD-03 reproduces (strict)`. The pty is opened with posix_openpt, so no -lutil is needed. |
| FD-05 | 16 | none | - | NO-TEST | macOS-only: Linux poll never returns POLLNVAL for an open fd, and macOS is not in CI. |
| FILE-01 | 00 | static grep check | test/scripts/libbugs/check-FILE-01.sh | EXPOSED | FAIL: "dead code still present: elm-kernel-cpp/src/file/File.cpp", "…File.hpp", "CMakeLists.txt still builds src/file/File.cpp" (line 216). The reference gate (nothing outside File.{cpp,hpp} names `Elm::Kernel::File` / `file/File.hpp`) passes today, so the deletion is safe. |
| FILE-02 | 00 | none (covered by check-FILE-01) | test/scripts/libbugs/check-FILE-01.sh | NO-TEST | Dead code with no caller, so nothing runs it. The FILE-01 check fails while File.cpp:33-78 exists. |
| FILE-03 | 00 | E2E | test/eco-kernel/src/FileReadHugeFileTest.elm | EXPOSED | `eco: out of memory: cannot allocate a 1099511627784-byte large byte buffer body (… after a minor and a major GC)`, SIGABRT. Variant: a 1 TiB+1 sparse file instead of 4 GiB+1 under a small heap. `-- ENV: ECO_HEAP_CONFIG=` needs a JSON *file* path, and no fixed path for one is available to a test. A size above the 24 GiB heap cap shows the same missing check without touching memory. The readBytes c |
| FILE-04 | 00 | E2E (4 programs) | test/eco-kernel/src/MVarReadAfterDropCrashesTest.elm, MVarPutAfterDropCrashesTest.elm, FileGetCwdDeletedCrashesTest.elm, FileAppDataDirNoHomeTest.elm | EXPOSED | read: `MVarReadAfterDropCrashesTest: reached Err`, no "Eco crash", exit 0. put: `MVarPutAfterDropCrashesTest: reached Err`. getCwd: `FileGetCwdDeletedCrashesTest: reached Err`. appDataDir with HOME unset: `result Err` / `FileAppDataDirNoHomeTest: False`. Runtime.dirname: no test, as the plan says (/proc/self/exe). |
| FILE-05 | 00 | static grep check | test/scripts/libbugs/check-FILE-05.sh | EXPOSED | FAIL: `failString(` at File.cpp:373 (Windows APPDATA), File.cpp:382 (HOME), Runtime.cpp:36 (dirname). |
| FILE-06 | 00 | E2E | test/eco-kernel/src/FileTouchErrorClassTest.elm | EXPOSED | `FileTouchErrorClassTest: wrong`: touch in /proc reports FileNotFound (the ENOENT of last_write_time), not the open error. |
| FILE-07 | 00 | E2E (2 programs, one with -- RLIMIT-FSIZE) | test/eco-kernel/src/FileWriteDevFullTest.elm, FileHWriteShortWriteTest.elm | EXPOSED | /dev/full: `writeString Ok`, `writeBytes Ok`, control `hWriteString NoSpaceLeft`. Short write at RLIMIT_FSIZE 1 MiB with a 2 MiB string: `FileHWriteShortWriteTest: Ok`. |
| FILE-08 | 00 | none for the stale-errno defect; E2E for the D22 /proc half | test/eco-kernel/src/FileReadProcFileTest.elm (XFAIL-NATIVE: FILE-08) | NO-TEST (stale errno); /proc half EXPOSED | The stale errno has no deterministic trigger (0 and EIO both map to tag 0). D22 (read to EOF): `readString "/proc/self/status"` does not start with "Name:" (`FileReadProcFileTest length: 7` = the test's `<error>` sentinel). Today it **fails** with an IOError, not the `""` the plan predicted; either way the content is not returned. |
| FILE-09 | 00 | E2E (-- ENV: PATH=) | test/eco-kernel/src/FileFindExecutableSkipsDirTest.elm | EXPOSED | `Ok (Just "/tmp/eco-kernel-FileFindExecutableSkipsDirTest/shadow/sh")`, a directory, so the test logs False. |
| FILE-10 | 00 | E2E (2 programs, -- ENV: PATH=) | test/eco-kernel/src/FileFindExecutableEmptyPathLeadingTest.elm, FileFindExecutableEmptyPathTrailingTest.elm | EXPOSED | Expected `Just "./ecoprobe"` (D22: empty entry = "."). Leading: `Just "ecoprobe"`. Trailing: `Nothing`. |
| FILE-11 | 00 | E2E (-- ENV: HOME=) | test/eco-kernel/src/FileAppDataDirEmptyHomeTest.elm | EXPOSED | `FileAppDataDirEmptyHomeTest result Ok /.ecotest` / `False`. |
| FILE-12 | 12 | E2E (Linux regression guard, no XFAIL) | test/eco-kernel/src/FileErrorTagsTest.elm | NOT-EXPOSED on Linux (Windows-only bug, as expected; low priority) | Linux passes: `list missing: FileNotFound`, `list file: NotADirectory`, `createDir over file: AlreadyExists`, `setCwd missing: FileNotFound`. It should fail only on a win-build, which was not run. The optional portable unit helper check was not written, because the helper `ioErrorTagFromErrorCode` does not exist yet |
| FILE-NEW-1 | 00 | E2E | test/eco-kernel/src/FileReadDirectoryTest.elm | EXPOSED (UNSURE triage confirmed) | readString of the child's cwd (/work/build/test/eco-kernel, ext4): `eco: out of memory: cannot allocate a 9223372036854775808-byte large byte buffer body`, SIGABRT. The per-directory log lines for "/" and "/tmp" are not in the captured output, since the harness drops output after a crash. |
| FS-01 | 12 | E2E, `-- XFAIL-NATIVE: FS-01` (JS twin has the same bug, D5) | test/eco-system/src/FileHandleStaleTest.elm | EXPOSED (native XFAIL; JS fails the same way) | both backends: `stale write: ok`, `b after stale write: ok [STALE]`, `stale read: ok data`, `b after stale truncate: ok []` |
| FS-03 | 12 | C++ unit, eco-system-core-test child scenario `FS-03/close-submit-fails`, hook `SysWorkPool::failNextSubmitForTest()` | test/eco-system-core/libbugs/CoreGroup12.cpp | EXPOSED (XFAIL; fails under ECO_TEST_XFAIL=strict) | child: `close with failing submit: err:EIO:out of memory in kernel`, `fd still open: 1, retried close: err:EBADF`, `verdict: leaked` |
| HASH-01 | 15 | E2E, `-- XFAIL-NATIVE: HASH-01` | test/eco-kernel/src/HashNegativeSeedTest.elm | EXPOSED | native XFAIL "Missing pattern: negEmpty: 66108864"; actual output negEmpty -1000000, negA -32999896, negAb -15254639, negHello -60029390, inRange False, pos 943378 (control OK). Expected values from the pure twin compiled with stock Elm 0.19.1 + node (all 6 lines match the CHECKs) |
| HEAP-01 | 10 | E2E x3 (one per entry point) | test/eco-system/src/ProcessRunEmptyArgTest.elm, test/eco-kernel/src/ProcessSpawnEmptyArgTest.elm, test/eco-system/src/SocketTlsAlpnEmptyTest.elm (all XFAIL-NATIVE) | EXPOSED | all three native: `Test crashed: SIGABRT`, stderr `Allocator.hpp:661: fromPointerRaw: Assertion 'ptr.ptr_ind == 0 && "Cannot convert an embedded constant HPointer to a pointer"' failed`. JS: ProcessRunEmptyArgTest PASS, SocketTlsAlpnEmptyTest PASS (`empty alpn name: err SocketError InvalidInput`); the eco-kernel suite has no JS runner project |
| HEAP-02 | 10 | E2E | test/eco-kernel/src/NativeDriverEmptyBytesTest.elm (XFAIL-NATIVE) | EXPOSED (AOT runner only) | `build/test/aot-e2e-runner --filter NativeDriverEmptyBytesTest`: `XFAIL ... ELF crashed (signal 6)`, output `width: 0: ()` then the same fromPointerRaw embedded-constant assertion. In the JIT `test` binary it XFAILs for the WRONG reason: `JIT session error: Symbols not found: [ Eco_Kernel_NativeDriver_lowerAndLinkBytes ]` (test/CMakeLists.txt does not whole-archive EcoKernel_NativeDriver), so it w |
| HTTP-06 | 16 | E2E (XFAIL-NATIVE) | test/elm-http/src/HttpBadUrlStringTest.elm | EXPOSED | Native run (XFAIL off, temporarily): `first: "BadUrl "`, `second: "NetworkError"`. With the mark on: `OK (XFAIL: HTTP-06 ... Missing pattern: first: "BadUrl not a url")`. Stock elm 0.19.1 + node + js-e2e-xhr.js shim prints `first: "BadUrl not a url"` and `second: "BadUrl foo://example.invalid/x"`, the CHECK lines. (elm-http is not a run-js-e2e.js project, and elm-conformance has no elm/http, so th |
| HTTP-09 | 16 | static grep check | test/scripts/libbugs/check-HTTP-09.sh | EXPOSED | `run-libbugs-checks.sh /work HTTP-09` gives FAIL: `186: static_cast<Record*>(rp)->values[6]`, `320/321/330: kReqExpect`, `missing: elm-kernel-cpp/src/http/HttpRequestLayout.hpp`. Drift risk only, no behaviour bug. |
| HTTP-10 | 16 | E2E (XFAIL-NATIVE, shared with HTTP-11) | test/eco-kernel/src/HttpGetArchiveErrorsTest.elm (`short:` line) | EXPOSED | After the `/package-short.zip` route was corrected (entry size 64 > 34 stored), the native output is `short: "Ok 64"`: the short entry is zero-padded and accepted (XFAIL-NATIVE, missing `short: "Err"`). |
| HTTP-11 | 16 | E2E (XFAIL-NATIVE, shared with HTTP-10) | test/eco-kernel/src/HttpGetArchiveErrorsTest.elm (`notfound:`, `zip404:` lines) | EXPOSED | Native output: `notfound: "Failed to open zip archive"` (expected `"HTTP 404"`), `zip404: "Ok"` (expected `"HTTP 404"`): a valid zip served with status 404 is accepted. With the mark on: `OK (XFAIL: HTTP-10/HTTP-11 ...)`. |
| HTTP-12 | 16 | none | - | NO-TEST | Windows-only BCryptHash path, needs more than 4 GiB in memory. Plan: fix may land unverified (Windows low priority). The optional chunked-shim unit test needs a refactor of product code first. |
| HTTPS-01 | 12 | E2E (pinning, no XFAIL; D23 = keep "missing = ended") | test/eco-system/src/HttpStreamUploadConsumedTest.elm | NOT-EXPOSED (by design: the pinning test passes, as D23 intends) | native and JS both print `first upload: [abc] PUT` / `second upload: [] PUT` (a consumed readable uploads as an empty body) |
| HTTPS-03 | 12 | E2E, `-- XFAIL-NATIVE: HTTPS-03/HTTPS-NEW-2` (D23 = reject an empty method) | test/eco-system/src/HttpStreamMethodValidationTest.elm | EXPOSED (native XFAIL; JS fails too, D5) | native: `empty method with body: BadStatus 404` (request line ` /anything HTTP/1.1`), `empty method no body: GoodStatus GET`; JS: `GoodStatus GET` for both. Expected `{{(BadUrl\ NetworkError)}}` |
| HTTPS-04 | 12 | E2E, `-- XFAIL-NATIVE: HTTPS-04` | test/eco-system/src/HttpStreamEmptyLocationTest.elm (route /redirect-empty-location already in TestHttpServer) | EXPOSED (native XFAIL; JS passes) | native: `kind: BadStatus 302`, `statusText: []`, `content-type: -`; JS: `statusText: [Found]`, `content-type: text/plain` |
| HTTPS-09 | 12 | E2E, `-- XFAIL-NATIVE: HTTPS-09` | test/eco-system/src/HttpStreamHeadStreamBodyTest.elm | EXPOSED, but with a different symptom than the triage says (native XFAIL; JS passes) | native: `close: ok`, `response: Timeout`, `order: close first (close at 1 ms, response at 10002 ms)`. The HEAD carries `Transfer-Encoding: chunked` (buildHeaderList) under CURLOPT_NOBODY, so the server waits for a body that never comes and the request times out. The close of the identity transformation succeeds at once, so the late ECANCELED close the triage describes is not visible from Elm. The  |
| HTTPS-NEW-1 | 12 | E2E with `-- ENV: https_proxy=${ECO_TEST_PROXY_URL}` and `-- UNSETENV`, `-- SKIP-JS` (JS runner has no HTTPS server and no proxy), `-- XFAIL-NATIVE: HTTPS-NEW-1` | test/eco-system/src/HttpStreamProxyTest.elm | EXPOSED (native XFAIL) | native: `via proxy: GoodStatus 200 Connection established`, `content-type: -`, `tunnelled: True` (a proxy tunnel really opened). Expected `BadStatus 404 Status` |
| HTTPS-NEW-2 | 12 | E2E (same file and XFAIL as HTTPS-03) | test/eco-system/src/HttpStreamMethodValidationTest.elm | EXPOSED (native XFAIL; JS already rejects) | native: `injected method: GoodStatus GET x-injected` (request injection), `space in method: BadStatus 404`; JS: `NetworkError` for both |
| HTTPSRV-02 | 08 | E2E (XFAIL-NATIVE + temporary SKIP-JS, D5) | /work/test/eco-system/src/HttpServerHostStrictTest.elm | EXPOSED (native and JS) | `Host: [zz!$:]`, `[:]` and `[1::2::3]` all got `client: bracket junk: 200 keep-alive ok` and were delivered (`server: host [zz!$:]`); native XFAIL "Missing pattern: client: bracket junk: 400 close". JS run once with SKIP-JS removed: same output, FAIL |
| HTTPSRV-03 | 08 | E2E (XFAIL-NATIVE) | /work/test/eco-system/src/HttpServerExpectHttp10Test.elm | EXPOSED (native only) | native: `client: 1.0 continue: 100 -`, then `closed after HTTP/1.1 200 OK`; `client: 1.0 other: 417 close`; `PUT /d` never reached the program (XFAIL "Missing pattern: server: PUT /d body abc"). JS: PASS, as predicted |
| HTTPSRV-04 | 08 | E2E, same file as HTTPSRV-02 | /work/test/eco-system/src/HttpServerHostStrictTest.elm | EXPOSED (native and JS) | `server: url http://other.test/HTTP://Other.test/abs2 path /HTTP://Other.test/abs2`, and the same for `HttpS://` (abs3); expected `http://Other.test/abs2` / `https://Other.test/abs3`. Both targets give the same output |
| HTTPSRV-06 | 08 | C++ unit (eco-system-core-test, XfailCore, setListenResolverForTest hook) | /work/test/eco-system-core/libbugs/CoreGroup08.cpp `testListenGaiCodes` | EXPOSED | `XFAIL HTTPSRV-06: EAI_AGAIN -> ENOTFOUND (getaddrinfo ENOTFOUND some.host), EAI_MEMORY -> ENOTFOUND, EAI_SYSTEM/ECONNREFUSED -> ENOTFOUND`; under strict: `FAIL HTTPSRV-06 reproduces (strict)`, rc 1. Checked preconditions: every stub was called, and EAI_NONAME gives ENOTFOUND |
| HTTPSRV-12 | 08 | E2E (XFAIL-NATIVE + temporary SKIP-JS, D5) | /work/test/eco-system/src/LiveHttpUpgradeLateTest.elm | EXPOSED (native and JS) | both: `upgrade: SocketError InvalidInput` / `upgrade text: EINVAL: upgradeRequest EINVAL: the request was answered already or is not an upgrade request`; expected `SocketError Cancelled`. The request did arrive (no `no request` timeout), so the RST timing worked |
| HTTPSRV-14 | 08 | grep check (optional, file-level) | /work/test/scripts/libbugs/check-HTTPSRV-14.sh | EXPOSED (static only; no runtime test possible) | FAIL: `297: const char* m = std::strerror(lastErr);` in HttpServerService.cpp. listenOn runs on SysWorkPool (HttpServer.cpp:182-186). The race itself cannot be shown on musl or current glibc |
| HTTPSRV-16 | 08 | none | - | NO-TEST | per plan: the stray empty `taggers[serverId]` node has no observable effect (hasSubscribers checks emptiness, the scanner sees an empty vector, onEffects replaces the map). Regression checks: LiveHttpServerUnsubscribedTest / LiveHttpServerOnRequestTest |
| JSON-01 | 19 | E2E (conformance, XFAIL-NATIVE) | /work/test/elm-conformance/src/JsonEncodeLoneSurrogateTest.elm | EXPOSED | native: `OK (XFAIL: JSON-01 ... -- [json.exception.type_error.316] invalid UTF-8 byte at index 1: 0xA0)`; without the marker it fails with that exception and logs nothing. JS (recorded from node): `lone high: "\"\\ud83d\""` etc., 4/4 rows |
| JSON-05 | 19 | E2E (conformance + eco-only elm-json, both XFAIL-NATIVE) | /work/test/elm-conformance/src/JsonLargeUnsignedTest.elm, /work/test/elm-json/src/DecodeIntRangeTest.elm | EXPOSED | conformance actual: `float 2^63: "-9223372036854776000"`, `float 2^64-1: "-1"`, `value 2^63: "-9223372036854775808"` (Elm: 9223372036854776000 / 18446744073709552000). elm-json actual: `2^63: Just -9223372036854775808`, `2^64-1: Just -1` (want Nothing, D24); `int max`/`int min`/`1e300` rows already pass |
| JSON-06 | 19 | E2E (conformance, XFAIL-NATIVE) | /work/test/elm-conformance/src/JsonDecodeIntIntegralFloatTest.elm | EXPOSED | actual: `1.0: "Err (Failure \"Expecting an INT\" <internals>)"`, same for 1e3, 1E2, -0.0, `[2.0,3]` (Index 0), `decodeValue (E.float 1)`; the two `Nothing` rows pass |
| JSON-NEW-1 | 19 | E2E (conformance, XFAIL-NATIVE) | /work/test/elm-conformance/src/JsonEncodeFloatFormatTest.elm | EXPOSED | actual: `0.0`, `3.0`, `-0.0`, `123456789.0`, `1.5e-07`, `1e-06`, `[1.0,2.5]`, `value 1.0: Ok "1.0"`, `int round trip: Err ... Expecting an INT` (Elm: 0, 3, 0, 123456789, 1.5e-7, 0.000001, [1,2.5], "1", Ok 3); 1e+21, 0.30000000000000004, NaN/inf -> null already match |
| LIST-01 | 14 | static grep check | test/scripts/libbugs/check-LIST-01.sh | EXPOSED | `run-libbugs-checks.sh /work LIST-01` FAIL: "ElmArray branch still in Elm_Kernel_List_fromArray": ListExports.cpp:337 `if (hdr->tag != Tag_Array)`, :341/:355 `ElmArray*`. No behavioural test is possible (the branch can't be reached from Elm). The String.split E2E coverage stays the behavioural guard. |
| LIST-03 | 14 | static grep check | test/scripts/libbugs/check-LIST-03.sh | EXPOSED (deadness) | FAIL: List.cpp:15/23/49 and List.hpp:35/53/69 still define `fromArray`/`sortBy`/`sortWith`. The script's caller grep finds no callers outside List.cpp/hpp. |
| LIST-04 | 14 | static grep check | test/scripts/libbugs/check-LIST-04.sh | EXPOSED (deadness) | FAIL: List.cpp:23/49 and List.hpp:53/69 `sortBy`/`sortWith` still present. No runtime test, as the plan says. |
| LIST-05 | 14 | static grep check | test/scripts/libbugs/check-LIST-05.sh | EXPOSED (deadness) | FAIL: List.cpp:23 `sortBy`, List.hpp:47 `using KeyFunc`, :53 still present. |
| LIST-08 | 14 | static grep check | test/scripts/libbugs/check-LIST-08.sh | EXPOSED (deadness) | FAIL: List.cpp:49 `sortWith`, List.hpp:62 `using CmpFunc`, :69 still present. |
| PARSE-01 | 18 | E2E (native, elm-parser), XFAIL-NATIVE | test/elm-parser/src/ParserLargeRopeInputTest.elm | EXPOSED | `HeapHelpers.hpp:2180: flatStringView ... Assertion '(hdr->tag == Tag_String \ \ hdr->tag == Tag_LargeStringHeader)' failed` -> `XFAIL: PARSE-01 ... Test crashed: SIGABRT`. Expected lines (Ok 140000 / 140000 / 140000 / 139999) confirmed with stock `elm make` + node. |
| PARSE-03 | 18 | E2E pin (passes today) + grep check | test/elm-parser/src/ParserIntOverflowTest.elm; test/scripts/libbugs/check-PARSE-03.sh | EXPOSED (by the static check); E2E NOT-EXPOSED (by design) | check FAILs: `310: i64 total = 0;` `316: total = base * total + digit;` `328`, `341` (signed accumulation = UB). E2E passes natively: at -O2 the UB happens to wrap, giving exactly the D16 (wrap) values, e.g. `hex 64 ones: "Ok -1"`, `hex 17 digits: "Ok 2541551405711093505"`, so it is a plain pin for the fix, no XFAIL. |
| PARSE-04 | 18 | E2E conformance, XFAIL-NATIVE | test/elm-conformance/src/ParserLoneLowSurrogateTest.elm | EXPOSED | recorded on node: `code is DC00: "Ok"`, `code above 10FFFF: "Err"`, `chomped length: "Ok 2"`; native: `XFAIL: PARSE-04 ... -- Missing pattern: code is DC00: "Ok"` |
| PARSE-NEW-1 | 18 | grep check + unit pin (test, isolated, fork) | test/scripts/libbugs/check-PARSE-NEW-1.sh; test/libbugs/LibBugsGroup18.cpp (`libbugs-18 PARSE-NEW-1: Allocator::resolve of an embedded constant dies, never returns null`) | EXPOSED (static) | check FAILs: `82 dead null guard(s) after Allocator::resolve` (assert lines excluded), incl. HttpEffectManager.cpp:160, SystemManager.cpp:168, HttpServerManager.cpp:162, ParserExports.cpp:70/79. Unit pin passes: forked `resolve(Empty)` and `resolve(True)` both die by signal (contract the fix documents). Not an XFAIL (no wrong behaviour today). |
| PROC-02 | 07 | C++ unit (`test`, isolated) | /work/test/libbugs/LibBugsGroup07.cpp `testWaitResultKeepsPidUntilPopped` ("libbugs-07 PROC-02 [xfail PROC-02]") | EXPOSED | `XFAIL PROC-02: waitid(WNOWAIT) on pid 1263086 with its exit queued but not popped: rc=-1 errno=No child processes`. Under ECO_TEST_XFAIL=strict: `FAILED: PROC-02 reproduces ...` (rc 1). Pop + reap-after-pop asserts pass. |
| PROC-03 | 07 | static grep check (per D28 option A: "a compile check that the fields are gone") | /work/test/scripts/libbugs/check-PROC-03.sh | EXPOSED | `PROC-03 FAIL`: `Eco/Process.elm:71: , stdout : StdStream`, `:72 , stderr : StdStream`; `Process.js:44: var _Process_spawnProcess = F5(...)`; `Process.cpp:86-93` reads stdoutHP/stderrHP and ignores them. No behavioural E2E: under option A the "CHECK-NOT leaked" test would be wrong, and an E2E with the new record would be a compile failure, which the harness cannot XFAIL. |
| PROC-05 | 07 | E2E (eco-system) | /work/test/eco-system/src/ProcessKillExitedRunTest.elm | EXPOSED | Native JIT: `OK (XFAIL: PROC-05 ... -- Missing pattern: prompt: True)`. The JS twin fails too: `prompt: False` after 6043 ms, so the test has a temporary `-- SKIP-JS:` (D5). |
| PROC-06 | 07 | C++ unit (eco-system-core-test, child scenario `PROC-06/fault-after-park`, run fault hook) | /work/test/eco-system-core/libbugs/CoreGroup07.cpp `testRunFaultAfterPark` | EXPOSED | `XFAIL PROC-06: BeforeJobWatch fired=1 resumeFailed=1 jobs=0->1 holds=0->1; BeforeWaitSubmit fired=1 resumeFailed=1 jobs=1->2 holds=1->3` (job + run hold leaked; at the second site the timer hold leaked as well). Strict: `FAIL PROC-06 reproduces (strict)`. |
| PROC-07 | 07 | E2E (eco-system) | /work/test/eco-system/src/ProcessRunLargeOutputTest.elm | NOT-EXPOSED (Windows-only; cannot run here) | Passes natively (JIT) and on JS on Linux: `CHECK: bytes: 200000 stderr: 4 result: ok`. The defect is in the `_WIN32` branch of `startCollector`, so it can only show on a Windows host (it picks powershell from `env.platform`). Triage not refuted. Low priority per WINDOWS LOW PRIORITY; fix by inspection. No XFAIL mark (it passes here). |
| PROC-08 | 07 | E2E (eco-kernel) | /work/test/eco-kernel/src/ProcessWaitKillTest.elm | EXPOSED | Native JIT: `OK (XFAIL: PROC-08 killed Eco.Process.wait keeps its hold -- Unexpected pattern (CHECK-NOT): late-child-output)`. eco-kernel has no JS project. |
| PROC-NEW-1 | 07 | E2E (eco-kernel), 2 files | /work/test/eco-kernel/src/ProcessStdinPipeWriteTest.elm (stdin-pipe write); /work/test/eco-kernel/src/ConsoleWriteUnknownHandleTest.elm (D28: unknown handle -> IOError) | EXPOSED (AOT); the JIT harness cannot run it | AOT (`build/test/aot-e2e-runner --filter ...`): `XFAIL ... Missing pattern: got:[hello]`, and the program printed `got:[]` / `waited: ExitSuccess, write ok, close ok`. Unknown handle: `Missing pattern: unknown handle: error` (it printed `ok`). JIT (`build/test/test`): both XFAIL only because of `JIT session error: Symbols not found: [ Eco_Kernel_Console_write ]`. EcoKernel_Console is not whole-arc |
| REGEX-03 | 14 | C++ unit (isolated, legacy nursery) x2 | test/libbugs/LibBugsGroup14.cpp: `libbugs-14 REGEX-03 [xfail REGEX-03]: replaceAtMost ...` and `... splitAtMost ...` | EXPOSED | replace: "replaceAtMost catch path returned 0x10500000070 = the pre-GC word 0x10500000070, not the forwarded subject 0x10580000058". split: "splitAtMost catch path's element is 0x10500000080 (pre-GC word ...), not the forwarded subject 0x10580079928". Preconditions asserted: replacer called twice, the subject moved, and split took the catch path (srell error_complexity on `,\ (a+)+b`). Both cases  |
| REGEX-06 | 14 | E2E (elm-conformance, CHECKs recorded on node) | test/elm-conformance/src/RegexNonAsciiTest.elm (`-- XFAIL-NATIVE: REGEX-06`) | EXPOSED | Native: "OK (XFAIL: REGEX-06 ... -- Missing pattern: dot on e-acute: "1 [1] [E9]")". JS runner: PASS. |
| REGEX-08 | 14 | C++ unit (isolated) | LibBugsGroup14.cpp `libbugs-14 REGEX-08 [xfail REGEX-08]` | EXPOSED | "same pattern+flags compiled twice gave ids 1 and 2; never twice gave 5 and 6". Controls (different flags or pattern give a different id) asserted. FAILS under strict. |
| RESET-01 | 04 | C++ unit (`test`, isolated), 2 cases | test/libbugs/LibBugsGroup04.cpp `testRuntimeLoadStateAfterReset`, `testRuntimeSavedStateRootedAfterReset` | EXPOSED | (a) "loadState after reset returned word 1120986464256 (the pre-reset saved HPointer), expected the JSON-null constant 7"; (b) legacy nursery, no hook re-call: "the saved word now points at an object with tag 0 (Int) after a reset, two minor GCs and garbage (scanners after the reset: (none))". Negative control for (b) (hook re-called after the reset) read "x" -> XPASS, so (b) measures the scanner |
| RESET-02 | 04 | C++ unit (`test`, isolated) | test/libbugs/LibBugsGroup04.cpp `testTimeScannerAfterReset` | EXPOSED | "time-effects scanner absent (scanners: (none)); holds acquired by the post-reset onEffects: 0 (want 1, a fresh tick); pendingAsync 1" |
| RESET-04 | 04 | C++ unit (eco-system-core-test child scenario) | test/eco-system-core/libbugs/CoreGroup04.cpp `RESET-04/fs-handles-after-reset` | EXPOSED | "fd 4 opened before the reset is still open (leaked) after it; close of it in the new heap succeeded (stale table entry)" |
| RESET-05 | 04 | C++ unit (child scenario) | CoreGroup04.cpp `RESET-05/watch-after-reset` | EXPOSED | "pendingAsync 0 before the watch, 1 with it, 1 after the reset and an empty onEffects; inotify watches 1 with the watch, 1 after" |
| RESET-06 | 04 | C++ unit (child scenario) | CoreGroup04.cpp `RESET-06/socket-tables-after-reset` | EXPOSED | "pendingAsync 0 before injection, 2 with a close token and a pending connect, 2 after the reset; close token live, pending connect live" |
| RESET-07 | 04 | C++ unit (child scenario) | CoreGroup04.cpp `RESET-07/http-tables-after-reset` | EXPOSED | "pendingAsync 0 before, 2 with a closing server and an in-flight respond, 2 after the reset and a drain; respond token live, close token live" |
| RESET-08 | 04 | C++ unit (child scenario) | CoreGroup04.cpp `RESET-08/socket-orphans-after-reset` | EXPOSED | "pendingAsync 0 before, 2 with an OpDone and a Connected in flight, 2 after the reset and a drain; OpDone token live, Connected token live" |
| RESET-09 | 04 | C++ unit (child scenario) | CoreGroup04.cpp `RESET-09/ws-tables-after-reset` | EXPOSED | "pendingAsync 0 before, 4 with a close hold, a closed waiter, a pending dial and an in-flight OpDone, 4 after the reset; close hold live, waiter live, dial live, OpDone live" (includes the WsEvents orphan path RESET-08 flagged) |
| RESET-10 | 04 | C++ unit (child scenario) | CoreGroup04.cpp `RESET-10/ws-manager-after-reset` | EXPOSED | "pendingAsync 0 before, 1 with an OnClose subscription, 1 after the reset and an empty onEffects" |
| RESET-11 | 04 | C++ unit (child scenario; optional per plan) | CoreGroup04.cpp `RESET-11/sigint-after-reset` | EXPOSED | "survived two SIGINTs after the reset (SIGINT listeners: 1): the default action was not restored" (fixed = child dies of SIGINT) |
| SIG-03 | 07 | C++ unit (eco-system-core-test, child scenario `SIG-03/push-back-oom`) | /work/test/eco-system-core/libbugs/CoreGroup07.cpp `testAddListenerPushBackOom` | EXPOSED | `XFAIL SIG-03: threw=1 extra=0 subscribers=32769 listeners=32768 restored=0 left=1`. Strict: `FAIL SIG-03 reproduces (strict)`. A RLIMIT_AS window (512 KiB headroom with `listeners_` at full power-of-two capacity) makes the 2 MiB `push_back` growth throw. This replaces the planned replacement global `operator new`, which does not exist yet and could collide with another group (CORE-18). |
| SIG-04 | 07 | C++ unit (eco-system-core-test, in-process) | /work/test/eco-system-core/libbugs/CoreGroup07.cpp `testChainToPreviousSecondInstance` | EXPOSED | `XFAIL SIG-04: previous handler ran 2x, Eco queue got 0`. Strict: `FAIL SIG-04 reproduces (strict)`. |
| SOCK-03 | 17 | C++ unit (eco-system-core-test, in-process) | CoreGroup17.cpp `testConnSetInterestFailureAfterWriteError` | EXPOSED | `XFAIL SOCK-03: 2 write errors reported, want 1: error:write EPIPE; error:read EPERM; error:write EPERM;`. Under strict it is `FAIL SOCK-03 reproduces (strict)`. Trigger: the peer is closed, so the write fails with EPIPE; then `dup2(regular file, connFd)` plus a transport `hasPendingWrite()=true` and `updateInterest()` make `epoll_ctl` ADD fail with EPERM. Preconditions are CHECKed (exactly one `w |
| SOCK-12 | 17 | C++ unit, child scenario (posix_spawn) | CoreGroup17.cpp `testConnectKillHandleThrow`, scenario `SOCK-12/killhandle-throw` | EXPOSED | `XFAIL SOCK-12: killed by signal 6 (Aborted)`; child stdout `after body: resumed=1 (fail) pendingConnects=1 holds=0`; stderr `eco: liveness: second release of a hold (token 0x1, acquired at Socket.connect)`. Strict: FAIL. It uses the `killHandleFailNextForTest()` hook and drives `socketUnixConnectBody` to a listening Unix socket, then `socketEventsDrain()`. |
| SOCK-15 | 17 | E2E (native; JS skipped) | /work/test/eco-system/src/UdpBindNoReactorTest.elm (`-- ENV: ECO_IOR_FAIL_INIT_FOR_TEST=1`, `-- XFAIL-NATIVE: SOCK-15`, `-- SKIP-JS`) | EXPOSED | `build/test/test --filter UdpBindNoReactorTest`: stderr `[eco-system] IoReactor: cannot create the event loop (ECO_IOR_FAIL_INIT_FOR_TEST)`, then `UdpBindNoReactorTest: bind ok` and `receive parked after 2 s` (watchdog, exit 3) → `OK (XFAIL: SOCK-15 ... Missing pattern: UdpBindNoReactorTest: bind failed)`. JS: SKIP (the hook is native-only). |
| STREAM-03 | 06 | E2E (pin, per D30) | test/eco-system/src/StreamCodecGzipMultiMemberTest.elm (no XFAIL, `-- SKIP-JS`) | EXPOSED (pinned; closed by D30) | Native passes with `err Failed: Junk found after end of compressed data.` for one chunk, the boundary split and 1-byte chunks. The JS backend disagrees: node's DecompressionStream prints `hello world` three times. So the "matches WHATWG" rationale does not hold on node, and the test is SKIP-JS with that reason. |
| STREAM-07 | 06 | C++ unit (eco-system-core-test, in-process) | test/eco-system-core/libbugs/CoreGroup06.cpp `testErroredPairsErased` | EXPOSED | XFAIL: `table size 0 -> 200 after 200 errored mapped sources -> 400 after 200 errored text sinks; channels destroyed: sources 0/200, sinks 0/200`. The stored Stream.Failed reason is still returned after the error (200/200 for each kind, CHECKed; the fix must keep that). Fails under strict. |
| STRING-01 | 11 | static grep check (dead code) | test/scripts/libbugs/check-STRING-01.sh | EXPOSED | FAIL: `using FoldFunc` at String.hpp:103, decls :110/:115, defs String.cpp:129/:148. No other use of `FoldFunc` exists in elm-kernel-cpp, runtime/src or system-kernel-cpp, which confirms the code is dead. |
| SYNC-02 | 08 | grep check (copy divergence guard) | /work/test/scripts/libbugs/check-SYNC-02.sh | NOT-EXPOSED (expected: latent, nothing diverges today) | PASS: each of the 3 files has 2 identical definitions. Negative control on a /tmp copy with one format string changed: exit 1 with a diff. Not wired into check/full (CMake is off limits); the plan wants it next to check-ctor-tags.sh if D6 picks the check |
| SYNC-03 | 08 | static_assert TU | /work/test/libbugs-static/SYNC-03.cpp | NOT-EXPOSED (expected: latent, correct today) | `SYNC-03.cpp compile-ok`. Negative control (`HandshakeGone + 2`, a temporary file I then deleted): compile-fail "WsEvent::kKinds must equal ...". It still cannot catch an enumerator appended after the named last one; only the `Count_` sentinel fix closes that |
| TASK-01 | 10 | C++ unit, `test` isolated (legacy + region nursery), hook PlatformRuntime::findManagerForTest | test/libbugs/LibBugsGroup10.cpp | EXPOSED | bump limit set so exactly one arity-0 closure fits, so the registrar's 2nd allocClosure collects; preconditions: exactly one minor, onEffects allocated elsewhere; control (rooted closure, same arming) moves. `XFAIL TASK-01: legacy nursery: init word -> 1123133947984, pre-collection address 1123133947984, tag at word 11` and same for region; strict fails both |
| TERM-04 | 09 | C++ unit (child scenario + pty) | test/eco-system-core/libbugs/CoreGroup09.cpp, scenario `TERM-04/raw-then-fatal` | EXPOSED | `XFAIL TERM-04: after reportFatal (killed by signal 6 (Aborted)) the pty is still raw (ECHO ICANON clear)`; preconditions (child printed `raw-on 1`, SIGABRT) CHECKed. Info lines (D3 second option, not guarded): after `abort` and after `sighup` the pty is also still raw. Strict: `FAIL TERM-04 reproduces` |
| TERM-05 | 09 | C++ unit (in-process) | CoreGroup09.cpp `testTitleKeepsC1Controls` | EXPOSED | `XFAIL TERM-05: terminalTitleSequence: C2 9C kept, C2 9B kept, C2 80 kept`; regression CHECKs (ESC/DEL stripped, U+011C and U+00A0 kept) pass. Strict: FAIL |
| TERM-06 | 09 | C++ unit (child scenario + pty) | CoreGroup09.cpp, scenario `TERM-06/false-then-stty` | EXPOSED | `XFAIL TERM-06: after exit ECHOE is set again (restored the mode saved at the first False call)`; preconditions (fresh pty has ECHOE, child exit 0 with `raw-on 1`, cooked mode restored) CHECKed. Strict: FAIL |
| TIME-01 | 06 | C++ unit (child scenario, region + legacy nursery) | test/elm-kernel-time/TimeGroup.cpp `TIME-01/tick-tagger-across-minor` | EXPOSED | XFAIL in both nurseries. Child killed by SIGABRT: `Allocator::resolve: Assertion hdr->tag < Tag_Forward` failed. gdb backtrace: `eco_apply_closure` <- `timerTickEvaluator` (TimeEffectManager.cpp:203, the tagger apply) on the stale, poisoned tagger copy after the minor forced at `taskSucceed(unit())`. Fails under ECO_TEST_XFAIL=strict. |
| TIME-05 | 06 | E2E | test/elm-time/src/TimeHereTzUtcTest.elm (`-- ENV: TZ=UTC0`, unmarked) | NO-TEST | Windows-only bug (`_timezone` without `_tzset`). The Linux regression pin passes (`hour: 0` / `minute: 0`, same as Elm on node). The DST half needs a manual check on Windows. |
| TIME-06 | 06 | E2E | test/elm-time/src/TimeZoneNamePosixTzTest.elm, TimeZoneNamePathTzTest.elm (`-- XFAIL-NATIVE: TIME-06`, LINUX-ONLY) | EXPOSED | Both XFAIL. Native output: `zone: "Name CET-1CEST,M3.5.0,M10.5.0/3"` and `zone: "Name /usr/share/zoneinfo/Europe/Paris"`. CHECK lines follow D30: `Offset (60\ 120)` and `Name Europe/Paris`. Node is no oracle here: it gives `Name UTC` and `Name undefined`. Native-only suite. |
| TIME-07 | 06 | E2E (elm-conformance) | test/elm-conformance/src/TimeEveryDuplicateIntervalTest.elm (`-- XFAIL-NATIVE: TIME-07`) | EXPOSED | Native XFAIL: `Missing pattern: dup: "a ticked: True"`. Stock elm 0.19.1 on node prints all True with `first round: A,B,C`. The JS runner passes. |
| TIME-08 | 06 | (a) C++ unit in `test` (isolated); (b) E2E (shared with TIME-09); (c) E2E regression | (a) test/libbugs/LibBugsGroup06.cpp `libbugs-06 TIME-08: TimerService non-finite and huge delays fire at once`; (b) TimeEveryZeroIntervalTest `inf bounded`; (c) test/elm-core/src/ProcessSleepNonFiniteTest.elm | EXPOSED (UBSan one-off and the Time.every part) | (a) Passes in the normal build, as predicted (x86 UB gives "fire at once"). A one-off build of TimerService.cpp with `-fsanitize=float-cast-overflow,signed-integer-overflow -fsanitize-trap=all`, linked into a probe under /tmp/g06-ubsan, traps (SIGILL, rc 132) in `schedule` for inf, -inf, nan, 1e300 and -1e300; 50 and 1e12 return normally. The clang install has no UBSan runtime, so the trap mode wa |
| TIME-09 | 06 | E2E (elm-conformance) | test/elm-conformance/src/TimeEveryZeroIntervalTest.elm (`-- XFAIL-NATIVE: TIME-09`) | EXPOSED | Native (ecoc JIT): `zero bounded: False`, `negative bounded: False`, `inf bounded: False`, `zero ticked: True` (more than 400 ticks in 200 ms). The harness XFAILs on `Missing pattern: zero: "zero bounded: True"`. Stock elm on node prints all True. The JS runner passes. |
| TIME-NEW-1 | 06 | C++ unit (child scenario, region + legacy nursery) | test/elm-kernel-time/TimeGroup.cpp `TIME-NEW-1/register-across-minor` | EXPOSED | XFAIL in both nurseries. Child prints `minors 1, poisoned 1, init at bump start 1`: exactly one minor ran during registration, and the registered `init` word still names the pre-collection copy. `setupEffects` then aborts: region mode in `spliceArgsForSaturatedCall: argument count mismatch`, legacy mode in `resolve: Invalid tag after forward resolution`. Fails under strict. |
| TLS-01 | 10 | static_assert TU (includes TlsTransport.cpp to see the anonymous-namespace class) | test/libbugs-static/TLS-01.cpp | EXPOSED | `run-libbugs-static.sh build TLS-01` -> compile-fail: `static_assert failed ... '!std::is_copy_constructible_v<Eco::System::(anonymous namespace)::TlsTransport>'` and `... !is_move_constructible_v<...TlsTransport>` (copy-assign assert holds already). Cannot be XFAILed; land with the fix |
| TLS-04 | 10 | C++ unit, eco-system-core-test child scenario `TLS-04/issuer-found` (env SSL_CERT_FILE/SSL_CERT_DIR per child) + control | test/eco-system-core/libbugs/CoreGroup10.cpp | EXPOSED | control (SSL_CERT_DIR only) exit 0 = CA found; `XFAIL TLS-04: missing SSL_CERT_FILE: exit 3; garbage SSL_CERT_FILE: exit 3 (exit 3 = CA in SSL_CERT_DIR not found)`; fails under ECO_TEST_XFAIL=strict |
| TLS-05 | 10 | E2E + C++ unit | test/eco-system/src/SocketTlsTrustedEmptyTest.elm (XFAIL-NATIVE), CoreGroup10.cpp `testTls05NoCertificatesCode` | EXPOSED | native: `empty: err TlsError (CertificateUnusable NO_START_LINE)` (XFAIL, missing pattern); JS: PASS. Unit: `XFAIL TLS-05: "" -> ERR_SSL_NO_START_LINE ...; "not a certificate" -> ERR_SSL_NO_START_LINE`; strict fails. See note 1 |
| TLS-06 | 10 | none | - | NO-TEST | by-design (D20: close TLS-06 as by-design); classifiers and Stream.js depend on the uniform ERR_SSL_ prefix |
| TLS-08 | 10 | C++ unit (Linux), drives TlsTransport by hand over a socketpair | CoreGroup10.cpp `testTls08SendErrorOverwritten` | EXPOSED | peer queue pre-filled so the ClientHello stays pending; own end SHUT_WR (send -> EPIPE), peer closed with unread data (recv -> ECONNRESET); preconditions checked (pending before, broken after read, read/write -2). `XFAIL TLS-08: write after a failed send reports ECONNRESET (read left ECONNRESET); expected EPIPE`; strict fails |
| TLS-10 | 10 | C++ unit, hook TlsTesting::prepareConnectForTest / pendingConnectCount | CoreGroup10.cpp `testTls10DroppedStage2Kept` | EXPOSED | `XFAIL TLS-10: 100 of 100 dropped stage-2 entries still in the table (before 0)`; strict fails. Note: an age-limit fix (30 s) would still show 100 here; the guard only XPASSes for a cap < 100 or the decided D20 route (drop stage 2, which also removes the hook) |
| URL-01 | 18 | E2E conformance, XFAIL-NATIVE | test/elm-conformance/src/UrlPercentEncodeReservedTest.elm | EXPOSED | node: `encode reserved: "a(b)!*'~"`, `builder: "/x(y)?k=v!"`; native: `XFAIL: URL-01 ... -- Missing pattern: encode reserved: "a(b)!*'~"` |
| URL-02 | 18 | E2E conformance, XFAIL-NATIVE | test/elm-conformance/src/UrlPercentDecodePlusTest.elm | EXPOSED | node: `decode plus: "Just \"a+b\""`, `query plus: "Just (Just \"c++\")"`; native: `XFAIL: URL-02 ... -- Missing pattern: decode plus: "Just \"a+b\""` |
| URL-03 | 18 | E2E conformance, XFAIL-NATIVE | test/elm-conformance/src/UrlPercentDecodeInvalidUtf8Test.elm | EXPOSED | node: `Nothing` for %FF, %E2%82, %ED%A0%80, %C0%AF; `valid euro: "Just [20AC]"`; native: `XFAIL: URL-03 ... -- Missing pattern: bad lead FF: "Nothing"` |
| URL-04 | 18 | none (dead code) | - | NO-TEST | Dead code: `grep Url::percentEncode\ Url::percentDecode\ url/Url.hpp\ "Url.hpp"` finds only `elm-kernel-cpp/src/url/Url.cpp:1`. Gate is the build linking after deletion. |
| UTILS-02 | 19 | C++ unit (`test`, isolated, XfailGuard) | /work/test/libbugs/LibBugsGroup19.cpp `testMixedFloatListCompare` | EXPOSED | `XFAIL UTILS-02: compare [1.0](unboxed) [NaN](boxed) = GT (want LT), reversed = GT (want GT), [NaN](unboxed) vs [NaN](boxed) = GT / GT (want EQ), cmp3 = GT / GT (want LT / EQ)`; precondition (both-unboxed reference LT / EQ) holds; fails under ECO_TEST_XFAIL=strict |
| UTILS-03 | 19 | C++ unit (`test`, isolated, XfailGuard) | /work/test/libbugs/LibBugsGroup19.cpp `testMixedTupleSlotCompare` | EXPOSED | `XFAIL UTILS-03: compare (1u,7) (1b,7) = GT (want EQ, == says True), (1u,7) vs (2b,7) = GT (want LT), reversed = LT (want GT), Tuple3 Float slot = GT (want EQ), Tuple3 Char slot = LT (want EQ), cmp3 = GT / GT (want EQ / LT)`; `==` preconditions hold; fails under strict |
| UTILS-05 | 19 | E2E (conformance, XFAIL-NATIVE) | /work/test/elm-conformance/src/DeepEqualityTest.elm | EXPOSED | actual: `nat 150 vs 200: "True"`, `nest 120: "True"`, `nest 500 /=: "False"`, `record chain 300: "True"`, `dict nest 150: "True"` (Elm: False/False/True/False/False). Part (b), editing EqDepthCutoffTest.elm, belongs to the fixing commit |
| UTILS-06 | 19 | E2E pin (passes) | /work/test/elm/src/FunctionEqualityFalseTest.elm | NOT-EXPOSED (by decision) | D24 (user, 2026-11-04) keeps `==` on functions = False as a documented divergence, so the proposed crash test does not apply. The pin passes: `same ref: True`, `distinct: False`, `record distinct: False`, `record same ref: True`, `maybe distinct: False`, `dict distinct: False`, exit 0 (covers the section 4.1 TODO: functions nested in records, custom types, Dict). Nothing to fix except the docs |
| WATCH-02 | 11 | E2E + C++ twin (child scenario, inotify) | test/eco-system/src/FileWatchRenameDirTest.elm (`-- XFAIL-NATIVE: WATCH-02`); test/eco-system-core/libbugs/CoreGroup11.cpp scenario `WATCH-02/rename-dir` | EXPOSED | E2E native: output `event: [moved a/x]`, so the check fails with "Missing pattern: event: [moved b/x]" (shown as XFAIL). Unit: `DEFECT=1 ... file events [moved a/x, changed a/x] (expected b/x)`. JS (Node) gives `[moved b/x]` and passes. Poll mode passes too. |
| WATCH-03 | 11 | E2E + C++ twin (inotify) | test/eco-system/src/FileWatchMoveOutTest.elm (`XFAIL-NATIVE: WATCH-03`); CoreGroup11.cpp `WATCH-03/move-out` | EXPOSED | E2E native: `event: [moved sub/x]`, `[changed sub/x]`, so "Unexpected pattern (CHECK-NOT): sub/x]". Unit: `then [moved sub/x, changed sub/x, moved marker, changed marker]`. JS and poll mode pass. |
| WATCH-04 | 11 | C++ unit (child scenarios: inotify cross-check + poll guard) | CoreGroup11.cpp `WATCH-04/symlink-root` (env ECO_SYSTEM_WATCH_POLL=0 plain CHECK, =1 XFAIL guard) | EXPOSED | inotify sees `f` (cross-check passes). Poll: `events of the watch on L -> d after writing d/f: [] (expected one for f)`. |
| WATCH-05 | 11 | C++ unit (child scenarios, poll guard + inotify cross-check) | CoreGroup11.cpp `WATCH-05/root-vanishes` | EXPOSED | Poll: `removal [moved -]; after re-creation [moved -, moved a, moved s, moved s/b] (expected none)` (D29 semantic). Inotify cross-check is silent after re-creation and passes. These are the 4 Moved events ("", a, s, s/b) the triage predicted. |
| WATCH-07 | 11 | C++ unit (child scenario, inotify; hook `injectQueueOverflowForTest`) | CoreGroup11.cpp `WATCH-07/queue-overflow` | EXPOSED | `events after an injected overflow: [] (expected a path-less Moved for each of watches 1 and 2)`. This goes through the test seam, not a real kernel overflow (as the triage said). |
| WATCH-08 | 11 | E2E + C++ twin (inotify) | test/eco-system/src/FileWatchNewTreeTest.elm (`XFAIL-NATIVE: WATCH-08`); CoreGroup11.cpp `WATCH-08/new-tree` | EXPOSED | E2E native: only `[moved a]`, `[moved a/b/c/f]`, `[changed a/b/c/f]`, so "Missing pattern: event: [moved a/b]". Unit: `events [moved a] (expected a, a/b, a/b/c, a/b/c/f)`. JS passes. Poll mode gives all four, so the test XPASSes there, as expected. |
| WS-08 | 05 | static grep check | test/scripts/libbugs/check-WS-08.sh | EXPOSED | `run-libbugs-checks.sh /work WS-08` -> FAIL: `WsHandshake.cpp:171: static thread_local std::mt19937_64 rng{std::random_device{}()};` |
| WS-11 | 05 | C++ unit (fake WsPort), eco-system-core-test | test/eco-system-core/libbugs/CoreGroup05.cpp `testWsCoreHeartbeatResume` | EXPOSED | `XFAIL WS-11: pong deadline after resume = now + 0 ms` (precondition checked: ping deadline was now+30000, pause recorded kTimerPong<-0) |
| WS-12 | 05 | C++ unit (fake WsPort) | CoreGroup05.cpp `testWsCoreCloseWriteFails` (a)(b) + (c) pin | EXPOSED | (a) `writeClose after a failed Close write: err 0`; (b) `Closed after a failed Close write: code 1000 clean true`; (c) startClose OpDone success pin passes (plain CHECK) |
| WS-13 | 05 | C++ unit (fake WsPort) | CoreGroup05.cpp `testWsCoreLateCloseAfterAbnormalEnd` | EXPOSED | `late writeClose: err 0; control: err 125 (ECANCELED) reason "socket closed"` |
| WS-16 | 05 | C++ unit (fake WsPort) | CoreGroup05.cpp `testWsCoreSingleCloseFrame` (a)(b) | EXPOSED | (a) reserved opcode after our Close: `2 Close frames written`; (b) heartbeat timeout after our Close: `2 Close frames written` |
| WS-18 | 05 | E2E (eco-system) | test/eco-system/src/WebSocketCloseChurnTest.elm (`-- XFAIL-NATIVE: WS-18`) | EXPOSED | JS: PASS (`first close...`, `second close after resubscribe: Normal "" clean True`). Native: `second close never delivered` -> `OK (XFAIL: WS-18 ...)` |
| WS-19 | 05 | E2E (eco-system) | test/eco-system/src/WebSocketLateOnCloseRetiredTest.elm (`-- XFAIL-NATIVE: WS-19`) | EXPOSED | JS: PASS (both lines). Native: `alive: late onClose Normal "bye" clean True` / `retired: late onClose none` -> XFAIL |
| WS-21 | 05 | C++ unit (table count; the plan's "stronger alternative") | CoreGroup05.cpp `testWsFailedOpenLeavesEntry` | EXPOSED | real `wsOpenBody` on a server handshake whose watch-mode Conn was aborted: Task fails ("err"), then `XFAIL WS-21: after the failed open: 1 WsEntry and 2 stream pairs left`. The memory-based E2E was written, run and dropped (see notes) |
| WS-NEW-1 | 05 | C++ unit (real `wsOpenOnConn`, Conn with EPIPE-writing transport, HoldProtocol watch mode) | CoreGroup05.cpp `testWsOpenWriteFails` | EXPOSED | `XFAIL WS-NEW-1: Opened succeeded, reqRead: no answer within 500 ms, conn phase not Open, aborted` |
| ZLIB-01 | 18 | C++ unit, eco-system-core-test, XfailCore | test/eco-system-core/libbugs/CoreGroup18.cpp (`testDeflaterOver4GiB`) | EXPOSED (Deflater); StreamCodec part BLOCKED | `XFAIL ZLIB-01: deflated 4294971392 bytes (25 compressed), inflated back 4096`; strict run: `11 checks, 1 failures`. StreamCodec `deflateRun`/`inflateRun` are file-local and take `const std::string&` (4 GiB commit): unreachable without the refactor the plan's fix proposes. |

## Phase 2 results (2026-11-04)

Sixteen fix packages ran in parallel in one tree (scratchpad `fix/<WP>.md` → `fix/<WP>-result.md`). Every
CERTAIN/LIKELY/UNSURE bug is FIXED or CLOSED by decision. Every expected-failure marker the Phase 1 tests
carried is removed (`XfailGuard::report`/`XfailCore::report` → plain checks; `-- XFAIL-NATIVE:` lines gone),
and both static runners (`run-libbugs-checks.sh` 48/48, `run-libbugs-static.sh` 7/7) are wired into
`check`/`full` together with `check-scanner-names.py`.

Closed without a code change: UTILS-06 (D24), DEAD-17 (no longer dead after PROC-NEW-1), STREAM-03 (D30),
DEAD-26 (not dead), TLS-06 (D20), HTTPS-01 (D23). PARSE-NEW-1 was PARTIAL in B2 until WPZ removed the
last two dead `if (cbPtr)` guards in TaskBinding.hpp; its check now passes.

Uncompiled platform paths (no host here, per the Windows-low-priority rule): FD-05 (macOS), PROC-07,
FILE-12, TIME-05 and the WS-08 `BCryptGenRandom` path (Windows).

Behaviour and API changes beyond the decisions' text:
- C1: `MVar.new`/`drop` are typed `Task x` (cannot fail); `read`/`take`/`put`, `getCwd`, `Runtime.dirname`,
  `appDataDir` are `Task IOError` (D10). The compiler's `Utils/Main.elm` wraps them with `IO.crashOnError`.
  The JS MVar now fails like native instead of crashing (D22 asked for parity; native no longer crashes).
  Renamed tests: `MVarRead/PutAfterDropCrashesTest` → `…FailsTest`, `FileGetCwdDeletedCrashesTest` →
  `FileGetCwdDeletedFailsTest`, `FileAppDataDirTaskNeverTest` → `FileAppDataDirNoHomeVarsTest`. FILE-06's
  trigger moved from `/proc` to `/sys` (the Phase 1 trigger failed for an unrelated reason).
- D3 WS-NEW-1: when the 101 write fails, `open` succeeds on an already-ended WebSocket; it fails only when
  the codec could not be installed.
- D5: a `runDuration` above 2^31-1 ms means no limit (native and JS). File handles are never-reused ids.
- WPZ (D21): a heap-generation change resets Scheduler, PlatformRuntime and PortRuntime state and voids
  holds; this also fixed a latent missing-scanner bug after `EcoRunner::reset()` in the JIT codegen suite.
  Invariants PORT_004, LIVE_003, LIVE_006 amended.

Follow-ups found during Phase 2 (fixed in a second round, see below): DEBUGLOG-INT-CMP, `kernelListMapN`
result kinds, JSON lone-surrogate decode, TLS corrupt+good PEM divergence, HTTP tracker scanner reset,
RESET-03, `handleSpawn` leak, HTTP/2 `:authority` validation, IPv6 Host `Request.url`. HTTPS-04's fallback body
and `List.mapN` passed as a value were fixed in a third round (below). Not pursued: sharing the listen-message
helper with Socket.cpp.

Static checks retired (2026-11-04, user): the per-bug grep checks (`test/scripts/libbugs/check-<ID>.sh`)
and `static_assert` files (`test/libbugs-static/`) cited in the Phase 1 tables below were deleted once the
fixes landed. A check that a named symbol is gone tests nothing after the deletion. The checks that state a
codebase-wide rule were kept under rule names in `test/scripts/` and wired into `check`/`full` directly:
ABI-02 → `check-kernel-c-symbols.sh` (after the build), ABI-03 → `check-eco-kernel-guard.sh`, ABI-04 →
`check-filesystem-nothrow.sh`, ABI-05 → `check-kernel-abi-bool.sh`, PARSE-NEW-1 → `check-resolve-null-guards.sh`,
SYNC-02 → `check-klog-copies.sh`, WS-08 → `check-ws-rng.sh`, HTTPSRV-14 → `check-httpserver-strerror.sh`
(DEAD-19's `check-scanner-names.py` was already one). BASICS-01/02/NEW-1 merged into
`test/static-asserts/IntArith.cpp`, run by `test/scripts/run-static-asserts.sh`. SYNC-03 and TLS-01 were
dropped: the `Count_` sentinels and the deleted `Transport` copy operations now state those properties in the
source itself. `run-libbugs-checks.sh` is gone.

Final gates (2026-11-04, each once, after moving `build/test/*/eco-stuff`, the package `*artifacts.dat` and
the `eco/kernel`, `eco/system` package copies aside to `/tmp/eco-cache-aside-nov4`):

| gate | result |
|---|---|
| `full` (clean rebuild, all rule checks, static asserts, eco-system-core-test, elm-kernel-time-test, JIT E2E, JS E2E, node addon, driver CLI) | rc 0: core 2,735 checks / 0 failures; time 19 / 0; JIT E2E 2,714 / 2,714; JS E2E 269 passed / 0 failed / 8 skipped (eco-system + elm-conformance 40/40) |
| `elm-tests` | 21,374 passed / 0 failed |
| `bootstrap` | rc 0: JS fixed point 4b and native fixed point 8c hold, 9b OK |
| `run-aot-e2e` (Gate B) | 1,346 / 1,346 (5 deliberate-divergence XFAILs) |
| `stress` | 114 / 114 |
| license manifest (D15) | one re-audit of all 226 changed pins: 226 KEEP, 0 demoted; 10 new pins (`NotSupportedNatively.hpp`, `JsArray.hpp`, eco-kernel `Process.cpp`); stamp 2026-11-04T16:53:40 |
| TLA+ canary | M1: no model change (per-generation scanner registration stays on the mutator thread, outside pauses); `F.externalRoots` grep widened to system-kernel-cpp |

Second round (X1, X2), each exposed by a new test first:
- DEBUGLOG-INT-CMP FIXED: list literals took each head's kind from the value, not the element type, so
  `[ Debug.log "d" n ]` built a `List Int` with a boxed head (compiler `GenerateMlir/Expr.elm`; `Debug.log`
  now returns its argument unboxed). `kernelListMapN` FIXED with typed `List.map2..5_Int/_Float/_Char`
  variants, as ARRAY-NEW-1 (HEAP_046 amended). The function-value route was fixed in the third round.
- JSON-NEW-2 (lone `\u` surrogate decode), TLS-NEW-2 (JS now stops at the first corrupt PEM block, like
  native/Node/OpenSSL), RESET-12 (Http tracker scanner per heap generation), RESET-03 (MVar table per
  generation), PROC-06 spawn path, HTTPSRV-NEW-3 (HTTP/2 `:authority` validated like HTTP/1 Host): FIXED.
  IPv6 Host `Request.url`: CLOSED (matches elm/url, documented).
- Noted, not fixed: native `IssuerNotTrusted` vs Node `LeafNotVerifiable` for a leaf-only trust store;
  nlohmann parse errors may show the `\ufdd0` placeholder for a lone surrogate.

Third round (2026-11-04), each exposed first by a new test that failed natively:
- `List.mapN` passed as a value FIXED. A reference that is not a saturated call (the alias body
  `map2 = Elm.Kernel.List.map2`, reached from a record field, a list, a pass-through function or a partial
  application) got the boxed kernel ABI type, so one erased `List.map2` specialization served every element
  type and called the untyped kernel. With `Debug.log` as the callback the `List Int` had boxed heads (sums
  near 2.2e12). `List.map2..5` are now in `Compiler.IR.Kernel.Abi.suffixSelectingKernels`, so the reference
  keeps its concrete type and names `map2_Int` and friends. They are also in a new `boxedAbiKernels` set:
  the concrete type is kept only when its top-level ABI equals the boxed one
  (`Compiler.Monomorphize.KernelAbi.sameTopLevelAbi`, in both mono engines), because an unsigned raw kernel
  reference in a kernel module can otherwise make a list argument an Int and give the kernel a second ABI
  (SourceIR `KernelHigherOrderCases` caught it). HEAP_046 amended. Test:
  test/elm-conformance/src/ListMapNFunctionValueKindTest.elm. `Array.map` was never affected: elm/core's
  Array.elm calls the JsArray kernels saturated, and user code cannot name them.
- HTTPS-04 fallback body FIXED. libcurl 7.88 does not follow `Location: \v` (blank after its whitespace trim)
  or `Location : /` (not its exact field name), while `headerCb` took both for followed redirects, so the
  302's head was posted only by `finishTransfer` and its body was dropped. libcurl passes no body of an interim
  response or a followed redirect to the write callback (checked with a C probe), so `writeCb` now takes body
  bytes that arrive before the head as the final response's and posts that header block's head first
  (HttpTransfer.cpp; `CURLOPT_WRITEDATA` is now the `HeaderState`). Test:
  test/eco-system/src/HttpStreamFallbackBodyTest.elm, routes `/redirect-vt-location` and
  `/redirect-spaced-location` in TestHttpServer.hpp and js-e2e-http-server.js; `-- SKIP-JS` because Node's
  parser rejects both header forms.
- Gates after the third round, once each: `full` rc 0 (JIT E2E 2,716/2,716, JS E2E 270 passed/0 failed/9
  skipped, core 2,735/0, time 19/0), `elm-tests` 21,374/0, `bootstrap` rc 0 (4b and 8c fixed points),
  `run-aot-e2e` 1,348/1,348 (5 deliberate XFAILs). `stress` was not rerun.

Unit tests reorganised by subject (2026-11-04): the group files (`test/libbugs/LibBugsGroupNN.cpp`,
`test/eco-system-core/libbugs/CoreGroupNN.cpp`, `test/elm-kernel-time/TimeGroup.cpp`) and their scaffolding
are gone; each case now lives in a file named for the code it tests, under a `<subject>/<behaviour>` name, with
its bug id in a comment. The file and test names cited in the Phase 1 tables below are the old ones; see
"Appendix: unit-test reorganisation map" at the end for where each case went.

### Per-bug status

| package | bug | status |
|---|---|---|
| WP00 | ABI-NEW-1 | FIXED |
| WP00 | ABI-03 | FIXED |
| WP00 | TERM-04 | FIXED (D3: reportFatal only) |
| A1 | ABI-01 | FIXED |
| A1 | ABI-02 | FIXED |
| A1 | ABI-05 | FIXED |
| A1 | BASICS-01 | FIXED |
| A1 | BASICS-02 | FIXED |
| A1 | BASICS-NEW-1 | FIXED |
| A1 | DEAD-01 | FIXED |
| A1 | DEAD-02 | FIXED |
| A1 | DEAD-03 | FIXED |
| A1 | DEAD-04 | FIXED |
| A1 | DEAD-05 | FIXED |
| A1 | DEAD-06 | FIXED |
| A1 | DEAD-07 | FIXED |
| A1 | DEAD-08 | FIXED |
| A1 | DEAD-09 | FIXED |
| A1 | DEAD-10 | FIXED |
| A1 | DEBUG-01 | FIXED |
| A1 | STRING-01 | FIXED (by removal, DEAD-08) |
| A1 | UTILS-02 | FIXED |
| A1 | UTILS-03 | FIXED |
| A1 | UTILS-05 | FIXED |
| A1 | UTILS-06 | CLOSED (D24) |
| A2 | ARRAY-01 | FIXED |
| A2 | ARRAY-02 | FIXED |
| A2 | ARRAY-03 | FIXED |
| A2 | ARRAY-05 | FIXED |
| A2 | ARRAY-NEW-1 | FIXED (D18 kernel route) |
| A2 | DEAD-11 | FIXED |
| A2 | DEAD-12 | FIXED |
| A2 | LIST-01 | FIXED |
| A2 | LIST-03 | FIXED |
| A2 | LIST-04 | FIXED |
| A2 | LIST-05 | FIXED |
| A2 | LIST-08 | FIXED |
| B1 | DEAD-15 | FIXED |
| B1 | JSON-01 | FIXED |
| B1 | JSON-05 | FIXED |
| B1 | JSON-06 | FIXED |
| B1 | JSON-NEW-1 | FIXED |
| B2 | PARSE-01 | FIXED |
| B2 | PARSE-03 | FIXED (D16: wrap) |
| B2 | PARSE-04 | FIXED (D17) |
| B2 | PARSE-NEW-1 | PARTIAL |
| B2 | REGEX-03 | FIXED (D7) |
| B2 | REGEX-06 | FIXED |
| B2 | REGEX-08 | FIXED (D8) |
| B3 | BROWSER-01 | FIXED |
| B3 | BYTES-04 | FIXED |
| B3 | BYTES-05 | FIXED |
| B3 | DEAD-14 | FIXED |
| B3 | DEAD-16 | FIXED |
| B3 | FILE-01 | FIXED |
| B3 | FILE-02 | FIXED |
| B3 | URL-01 | FIXED |
| B3 | URL-02 | FIXED |
| B3 | URL-03 | FIXED |
| B3 | URL-04 | FIXED |
| B4 | DEAD-44 | FIXED |
| B4 | TASK-01 | FIXED |
| B4 | TIME-01 | FIXED |
| B4 | TIME-05 | FIXED (by inspection, Windows-only, uncompiled here) |
| B4 | TIME-06 | FIXED |
| B4 | TIME-07 | FIXED |
| B4 | TIME-08 | FIXED |
| B4 | TIME-09 | FIXED |
| B4 | TIME-NEW-1 | FIXED |
| B5 | HTTP-06 | FIXED |
| B5 | HTTP-09 | FIXED |
| B5 | HTTP-10 | FIXED |
| B5 | HTTP-11 | FIXED |
| B5 | HTTP-12 | FIXED (unverified on Windows, per the Windows-low-priority rule) |
| C1 | ABI-04 | FIXED |
| C1 | ECO-NEW-1 | FIXED (D10) |
| C1 | FILE-03 | FIXED |
| C1 | FILE-04 | FIXED (D10 retype instead of crash) |
| C1 | FILE-05 | FIXED |
| C1 | FILE-06 | FIXED |
| C1 | FILE-07 | FIXED |
| C1 | FILE-08 | FIXED |
| C1 | FILE-09 | FIXED |
| C1 | FILE-10 | FIXED (D22 `.` policy) |
| C1 | FILE-11 | FIXED |
| C1 | FILE-12 | FIXED (Windows path unverified, low priority) |
| C1 | FILE-NEW-1 | FIXED |
| C1 | HEAP-01 | FIXED |
| C1 | HEAP-02 | FIXED |
| C2 | CONSOLE-01 | FIXED |
| C2 | CONSOLE-02 | FIXED |
| C2 | CONSOLE-03 | FIXED (Windows path not compiled here) |
| C2 | CONSOLE-04 | FIXED (D19: async) |
| C2 | CRASH-01 | FIXED (POSIX unchanged; Windows code not compiled here) |
| C2 | DEAD-17 | CLOSED (no longer dead) |
| C2 | DEAD-18 | FIXED |
| C2 | HASH-01 | FIXED |
| C2 | PROC-02 | FIXED |
| C2 | PROC-03 | FIXED (D28 option A) |
| C2 | PROC-08 | FIXED |
| C2 | PROC-NEW-1 | FIXED |
| D1 | CORE-01 | FIXED |
| D1 | CORE-07 | FIXED (C++ only, D27) |
| D1 | CORE-08 | FIXED |
| D1 | CORE-14 | FIXED |
| D1 | CORE-18 | FIXED |
| D1 | DEAD-22 | FIXED (D14: strings built from the marker) |
| D1 | DEAD-23 | FIXED |
| D1 | STREAM-03 | CLOSED (D30: rejection by design, pinned) |
| D1 | STREAM-07 | FIXED (native + JS twin) |
| D1 | SYNC-02 | FIXED (D6: check kept and wired) |
| D1 | SYNC-03 | FIXED |
| D1 | ZLIB-01 | FIXED (Deflater and StreamCodec) |
| D2 | DEAD-24 | FIXED |
| D2 | DEAD-25 | FIXED (D14) |
| D2 | DEAD-26 | CLOSED (not dead) |
| D2 | DEAD-27 | FIXED |
| D2 | DEAD-29 | FIXED |
| D2 | DEAD-30 | FIXED |
| D2 | DEAD-31 | FIXED |
| D2 | DEAD-34 | FIXED |
| D2 | DEAD-36 | FIXED |
| D2 | DEAD-37 | FIXED |
| D2 | DEAD-43 | FIXED (D12: branch kept, assert added) |
| D2 | DEAD-NEW-1 | FIXED (with DEAD-29) |
| D2 | SOCK-03 | FIXED |
| D2 | SOCK-12 | FIXED |
| D2 | SOCK-15 | FIXED |
| D2 | TLS-01 | FIXED |
| D2 | TLS-04 | FIXED (D20: unset one keeps OpenSSL default) |
| D2 | TLS-05 | FIXED (D20: corrupt PEM too) |
| D2 | TLS-06 | CLOSED (D20 by design) |
| D2 | TLS-08 | FIXED |
| D2 | TLS-10 | FIXED (D20 preferred route: second stage removed) |
| D3 | DEAD-40 | FIXED |
| D3 | WS-08 | FIXED |
| D3 | WS-11 | FIXED |
| D3 | WS-12 | FIXED |
| D3 | WS-13 | FIXED |
| D3 | WS-16 | FIXED |
| D3 | WS-18 | FIXED |
| D3 | WS-19 | FIXED (D25) |
| D3 | WS-21 | FIXED |
| D3 | WS-NEW-1 | FIXED |
| D4 | DEAD-39 | FIXED |
| D4 | DEAD-41 | FIXED |
| D4 | HTTPS-01 | CLOSED |
| D4 | HTTPS-03 | FIXED |
| D4 | HTTPS-NEW-2 | FIXED |
| D4 | HTTPS-04 | FIXED |
| D4 | HTTPS-09 | FIXED |
| D4 | HTTPS-NEW-1 | FIXED |
| D4 | HTTPSRV-02 | FIXED |
| D4 | HTTPSRV-03 | FIXED |
| D4 | HTTPSRV-04 | FIXED |
| D4 | HTTPSRV-06 | FIXED |
| D4 | HTTPSRV-14 | FIXED |
| D4 | HTTPSRV-12 | FIXED |
| D4 | HTTPSRV-16 | FIXED |
| D5 | FD-01 | FIXED |
| D5 | FD-03 | FIXED (D26) |
| D5 | FD-05 | FIXED (by inspection, NO-TEST) |
| D5 | FS-01 | FIXED (native + JS) |
| D5 | FS-03 | FIXED |
| D5 | PROC-05 | FIXED (native + JS) |
| D5 | PROC-06 | FIXED |
| D5 | PROC-07 | FIXED (by inspection, Windows, uncompiled) |
| D5 | SIG-03 | FIXED |
| D5 | SIG-04 | FIXED |
| D5 | TERM-05 | FIXED (native + JS) |
| D5 | TERM-06 | FIXED |
| D5 | WATCH-02 | FIXED |
| D5 | WATCH-03 | FIXED |
| D5 | WATCH-04 | FIXED |
| D5 | WATCH-05 | FIXED (D29) |
| D5 | WATCH-07 | FIXED (D29) |
| D5 | WATCH-08 | FIXED |
| WPZ | DEAD-19 | FIXED |
| WPZ | DEAD-20 | FIXED |
| WPZ | DEAD-21 | FIXED |
| WPZ | DEAD-32 | FIXED (D12, assert) |
| WPZ | DEAD-45 | FIXED |
| WPZ | RESET-01 | FIXED |
| WPZ | RESET-02 | FIXED |
| WPZ | RESET-04 | FIXED |
| WPZ | RESET-05 | FIXED |
| WPZ | RESET-06 | FIXED (D21) |
| WPZ | RESET-07 | FIXED (D21) |
| WPZ | RESET-08 | FIXED (D21) |
| WPZ | RESET-09 | FIXED (D21) |
| WPZ | RESET-10 | FIXED (D21) |
| WPZ | RESET-11 | FIXED |

## Bugs by area


One row per bug; the full proposal is in the appendix.

### ABI

| ID | Triage | Test | Confidence | Title |
|---|---|---|---|---|
| ABI-01 | CERTAIN · LOW | E2E | high | modBy throws across an extern "C" export |
| ABI-02 | CERTAIN · LOW | static check | high | C++ helpers declared inside extern "C" in ListExports |
| ABI-03 | LIKELY · LOW | static check | high | eco exports not under ECO_KERNEL_GUARD |
| ABI-04 | CERTAIN · MEDIUM | E2E | high | filesystem_error thrown outside the guard |
| ABI-05 | CERTAIN · LOW | static check | high | Browser_reload takes a C bool |
| ABI-NEW-1 | CERTAIN · MEDIUM | C++ unit | high | binding-body exceptions are never caught; ECO_KERNEL_GUARD on Task-returning exports is in |

### ARRAY

| ID | Triage | Test | Confidence | Title |
|---|---|---|---|---|
| ARRAY-01 | CERTAIN · LOW | C++ unit | medium | unsafeSet range check truncates the index to 32 bits |
| ARRAY-02 | CERTAIN · LOW | C++ unit | high | boxed unsafeSet marks Float/Char sources Int-kind |
| ARRAY-03 | CERTAIN · LOW | C++ unit | high | push reads Char padding as part of a 64-bit value |
| ARRAY-05 | UNSURE · MEDIUM | E2E | high | elm_array_push_* writes raw words into a boxed array |
| ARRAY-NEW-1 | UNSURE · MEDIUM | E2E | medium | JsArray map/initialize store results in the closure's result kind, so an Int array can be  |

### BASICS

| ID | Triage | Test | Confidence | Title |
|---|---|---|---|---|
| BASICS-01 | CERTAIN · LOW | static check | high | Int arithmetic relies on signed overflow |
| BASICS-02 | CERTAIN · LOW | static check | high | pow_Int overflows even when the result fits |
| BASICS-NEW-1 | CERTAIN · LOW | static check | high | runtime eco_int_pow has the same UB as pow_Int (the more reachable path) |

### BROWSER

| ID | Triage | Test | Confidence | Title |
|---|---|---|---|---|
| BROWSER-01 | CERTAIN · LOW | E2E | high | Browser stubs return word 0 under NDEBUG |

### BYTES

| ID | Triage | Test | Confidence | Title |
|---|---|---|---|---|
| BYTES-04 | CERTAIN · LOW | C++ unit | high | encoder size narrowed size_t to u32 unchecked |
| BYTES-05 | CERTAIN · LOW | static check | high | byte swaps ignore host endianness |

### CONSOLE

| ID | Triage | Test | Confidence | Title |
|---|---|---|---|---|
| CONSOLE-01 | CERTAIN · MEDIUM | E2E | high | readAllBody drops leading empty lines |
| CONSOLE-02 | CERTAIN · LOW | C++ unit | medium | log ignores write result |
| CONSOLE-03 | CERTAIN · LOW | none | n/a | Windows tag >0x7fffffff truncated |
| CONSOLE-04 | CERTAIN · LOW (documented behaviour) | E2E | medium | readLine/readAll block |

### CORE

| ID | Triage | Test | Confidence | Title |
|---|---|---|---|---|
| CORE-01 | CERTAIN · MEDIUM | C++ unit | high | SysWorkPool partial thread start use-after-free |
| CORE-07 | CERTAIN · LOW | C++ unit | high | failureFor(RunErr) drops the message |
| CORE-08 | LIKELY · LOW | C++ unit | high | asyncFailure may complete a Task twice |
| CORE-14 | CERTAIN · LOW | C++ unit | medium-high | backendInit partial failure leaks fds |
| CORE-18 | CERTAIN · LOW | C++ unit | medium-high | PoolResult::of throwing in catch -> terminate |

### CRASH

| ID | Triage | Test | Confidence | Title |
|---|---|---|---|---|
| CRASH-01 | LIKELY · LOW (Windows only) | none | low | ::exit(1) with live threads |

### DEAD

| ID | Triage | Test | Confidence | Title |
|---|---|---|---|---|
| DEAD-01 | CERTAIN · LOW | static check | low | dead namespace APIs divergent from exports |
| DEAD-02 | CERTAIN · LOW | static check | medium | unused <cstdio> |
| DEAD-03 | CERTAIN · LOW | static check | low | unused/dead Scheduler.hpp and Platform.hpp |
| DEAD-04 | CERTAIN · LOW | static check | high | DebugExports value_bits unused |
| DEAD-05 | CERTAIN · LOW | static check | low | DebugExports calls exit without <cstdlib> |
| DEAD-06 | CERTAIN · LOW | static check | low | Char.cpp <stdexcept> unused |
| DEAD-07 | CERTAIN · LOW | E2E | low | dead isNil(wrap(a)) in append |
| DEAD-08 | CERTAIN · LOW | E2E | low | String foldl/foldr unused |
| DEAD-09 | CERTAIN · LOW | static check | high | consCellChar unused |
| DEAD-10 | CERTAIN · LOW | E2E | low | words ranges.empty() unreachable |
| DEAD-11 | CERTAIN · LOW | static check | low | static_assert(true) checks nothing |
| DEAD-12 | CERTAIN · LOW | C++ unit | low | dead List.cpp helpers |
| DEAD-14 | CERTAIN · LOW | none | low | namespace read_bytes no negative-length check |
| DEAD-15 | CERTAIN · LOW | static check | high | Json makeDecoder1i, jsonValueCtor unused |
| DEAD-16 | CERTAIN · LOW | none | low | File and Browser namespace APIs unused |
| DEAD-17 | CERTAIN · LOW | none | low | s_streamHandles written never read |
| DEAD-18 | CERTAIN · LOW | E2E | low | redundant POST assignments |
| DEAD-19 | CERTAIN · LOW | static check | high | Runtime scanner unnamed |
| DEAD-20 | CERTAIN · LOW | none | low | TaskEffectManager duplicates encodeHP/decodeHP |
| DEAD-21 | CERTAIN · LOW | E2E | low | HttpEffectManager onSelfMsg double-roots |
| DEAD-22 | CERTAIN · LOW | static check | medium | kEndedMarker unused, literal hard-coded |
| DEAD-23 | CERTAIN · LOW | static check | high | describeErrno unused |
| DEAD-24 | CERTAIN · LOW | none | low | Conn isTls never read |
| DEAD-25 | CERTAIN · LOW | none | low | hasBufferedRead never called |
| DEAD-26 | CERTAIN · LOW. **Re-triage: the claim is WRONG, so do not delete.** The getter has callers in the unit tests: test/eco-system-core/EcoSystemCoreTest.cpp:2385 and :2396 (the max-connections credit test reads `l->openConnections()` and checks `open == 1`, then waits for `n == 0`). The triage grep covered only system-kernel-cpp and missed test/. | none | n/a | Listener openConnections no caller |
| DEAD-27 | CERTAIN · LOW | static check | high | SocketTables resumeToken unused |
| DEAD-29 | CERTAIN · LOW | static check | high | socketNotImplementedTask/socketDoneTask unused |
| DEAD-30 | CERTAIN · LOW (drift risk, no current bug) | static check | high | SocketManager mask constants unused |
| DEAD-31 | CERTAIN · LOW | static check | high | UdpManager masks unused |
| DEAD-32 | CERTAIN · LOW | static check | medium | SPEC_TRIPLE_MASK unused |
| DEAD-34 | CERTAIN · LOW | none | n/a | WsHandshake headDone ok/err unused |
| DEAD-35 | CERTAIN · LOW | C++ unit | medium | WsHandshakeEntry::server never read |
| DEAD-36 | CERTAIN · LOW | none | n/a | onClosed resumed unused |
| DEAD-37 | CERTAIN · LOW | none | n/a | Http2Client closeCode_ never read |
| DEAD-39 | CERTAIN · LOW | static check | high | kDefaultDrainMs duplicates WsCore::kDrainMs |
| DEAD-40 | CERTAIN · LOW | static check | high | wsNotImplementedBody dead |
| DEAD-41 | CERTAIN · LOW | static check | high | httpServerNotImplementedBody dead |
| DEAD-43 | CERTAIN · LOW | C++ unit | medium | writeFaceShutdown branch unreachable |
| DEAD-44 | CERTAIN · LOW | static check | high | CTOR_TIME_EVERY defined twice |
| DEAD-45 | CERTAIN · LOW | static check | high | 0xFFFD shared by CONSTANT_TAG and CTOR_Router |
| DEAD-NEW-1 | CERTAIN · LOW | static check | high | socketNotImplementedTask / notImplementedBody dead |

### DEBUG

| ID | Triage | Test | Confidence | Title |
|---|---|---|---|---|
| DEBUG-01 | CERTAIN · LOW | C++ unit | high | Debug.todo exits without stderr/eco_crash |

### ECO

| ID | Triage | Test | Confidence | Title |
|---|---|---|---|---|
| ECO-NEW-1 | LIKELY · MEDIUM | E2E | high | appDataDir fails a `Task Never` |

### FD

| ID | Triage | Test | Confidence | Title |
|---|---|---|---|---|
| FD-01 | UNSURE · LOW | C++ unit | high | FdChannel closes a possibly reused fd after POLLNVAL |
| FD-03 | LIKELY · LOW | C++ unit | medium | PIPE_BUF write can block |
| FD-05 | CERTAIN · LOW (cosmetic, macOS-only) | C++ unit | low | fd >= FD_SETSIZE gets misleading EBADF |

### FILE

| ID | Triage | Test | Confidence | Title |
|---|---|---|---|---|
| FILE-01 | CERTAIN · LOW | static check | high | dead File accessors use alphabetical slot numbers |
| FILE-02 | CERTAIN · LOW | none | n/a | dead File accessors treat void* as Record* without decoding |
| FILE-03 | CERTAIN · LOW | E2E | high | readStringBody has no size cap |
| FILE-04 | CERTAIN · MEDIUM | E2E | high | Task Never wrappers over failing kernels |
| FILE-05 | CERTAIN · LOW | static check | medium | appDataDir fails with a plain String |
| FILE-06 | CERTAIN · LOW | E2E | high | touch ignores open failure |
| FILE-07 | CERTAIN · MEDIUM | E2E | high | write functions ignore write errors |
| FILE-08 | CERTAIN · LOW | none | low | readStringBody uses errno after ifstream failure |
| FILE-09 | CERTAIN · LOW | E2E | high | findExecutable matches directories |
| FILE-10 | CERTAIN · LOW | E2E | high | empty PATH entry tests the name against cwd |
| FILE-11 | CERTAIN · LOW | E2E | high | appDataDir accepts empty HOME on POSIX |
| FILE-12 | CERTAIN · MEDIUM (Windows only; Windows is low priority per the user rule) | E2E | high | Windows strerror on non-errno codes |
| FILE-NEW-1 | UNSURE · MEDIUM | E2E | high | readString of a directory or >4 GiB file is unguarded (huge allocation, abort) |

### FS

| ID | Triage | Test | Confidence | Title |
|---|---|---|---|---|
| FS-01 | CERTAIN · MEDIUM | E2E | high | stale FileHandle accepted after fd reuse |
| FS-03 | CERTAIN · LOW | C++ unit | medium | close erases fd before submit |

### HASH

| ID | Triage | Test | Confidence | Title |
|---|---|---|---|---|
| HASH-01 | CERTAIN · LOW | E2E | high | negative seed gives negative narrow hash |

### HEAP

| ID | Triage | Test | Confidence | Title |
|---|---|---|---|---|
| HEAP-01 | CERTAIN · HIGH | E2E | high | listToStringVector resolves the empty-string constant |
| HEAP-02 | CERTAIN · MEDIUM | E2E | high | NativeDriver resolves Bytes without the empty-Bytes check |

### HTTP

| ID | Triage | Test | Confidence | Title |
|---|---|---|---|---|
| HTTP-06 | CERTAIN · LOW | E2E | high | BadUrl_ string always empty |
| HTTP-09 | CERTAIN · LOW (drift risk; no current defect) | static check | high | HttpEffectManager uses unchecked field literals |
| HTTP-10 | CERTAIN · LOW | E2E | medium-high | archive short read zero-padded |
| HTTP-11 | CERTAIN · LOW | E2E | high | getArchive ignores HTTP status |
| HTTP-12 | CERTAIN · LOW (Windows-only, practically unreachable) | C++ unit | low | Windows SHA-1 shim limited to 4 GiB |

### HTTPS

| ID | Triage | Test | Confidence | Title |
|---|---|---|---|---|
| HTTPS-01 | CERTAIN · LOW (design decision; the behaviour is deliberate and documented) | E2E | high | HttpStream unknown stream id not rejected |
| HTTPS-03 | LIKELY · LOW | E2E | high | empty method with body sets CUSTOMREQUEST "" |
| HTTPS-04 | LIKELY · LOW | E2E | medium | finishTransfer fallback drops response data |
| HTTPS-09 | CERTAIN · LOW (real variant: HEAD with a stream body) | E2E | medium | close for bodyKind != 2 answered late |
| HTTPS-NEW-1 | LIKELY · MEDIUM | E2E | high | proxy CONNECT response posted as the final response |
| HTTPS-NEW-2 | LIKELY · MEDIUM | E2E | high | method string not validated (request-line injection) |

### HTTPSRV

| ID | Triage | Test | Confidence | Title |
|---|---|---|---|---|
| HTTPSRV-02 | CERTAIN · LOW | E2E | high | bracketed host accepts any reg-name chars |
| HTTPSRV-03 | CERTAIN · LOW | E2E | high | 100 Continue sent to HTTP/1.0 |
| HTTPSRV-04 | CERTAIN · LOW | E2E | high | absolute-form recognised only lower-case |
| HTTPSRV-06 | CERTAIN · LOW | C++ unit | high | every getaddrinfo failure reported ENOTFOUND |
| HTTPSRV-12 | CERTAIN · LOW | E2E | medium | HttpUpgrade EINVAL message incomplete |
| HTTPSRV-14 | CERTAIN · LOW | none | low | strerror on worker thread |
| HTTPSRV-16 | CERTAIN · LOW | none | low | taggers[serverId] inserts empty vector |

### JSON

| ID | Triage | Test | Confidence | Title |
|---|---|---|---|---|
| JSON-01 | CERTAIN · MEDIUM | E2E | high | Json.encode throws on invalid UTF-8 |
| JSON-05 | CERTAIN · MEDIUM | E2E | high | JSON ints above INT64_MAX wrap |
| JSON-06 | CERTAIN · MEDIUM | E2E | high | Decode.int rejects 1.0 |
| JSON-NEW-1 | CERTAIN · MEDIUM | E2E | high | Encode.float of an integral value prints a trailing ".0" |

### LIST

| ID | Triage | Test | Confidence | Title |
|---|---|---|---|---|
| LIST-01 | CERTAIN · LOW | static check | low | List.fromArray conses Float/Char as Int-kind cells |
| LIST-03 | CERTAIN · LOW | static check | high | dead sortWith resolves raw bits after a boxed first node |
| LIST-04 | CERTAIN · LOW | static check | high | dead List.cpp sorts resolve embedded constants |
| LIST-05 | CERTAIN · LOW | static check | high | dead sortBy boxes unboxed elements as Int |
| LIST-08 | CERTAIN · LOW | static check | high | dead sortWith narrows i64 to int |

### PARSE

| ID | Triage | Test | Confidence | Title |
|---|---|---|---|---|
| PARSE-01 | CERTAIN · HIGH | E2E | high | long UTF-16 ropes reach flatStringView unflattened |
| PARSE-03 | CERTAIN · MEDIUM | E2E | high | consumeBase accumulation overflows int64 |
| PARSE-04 | CERTAIN · LOW | E2E | high | isHighSurrogate accepts low surrogates |
| PARSE-NEW-1 | CERTAIN · LOW | C++ unit | high | Allocator::resolve on an embedded constant crashes in every build; the kernels' "if (!ptr) |

### PROC

| ID | Triage | Test | Confidence | Title |
|---|---|---|---|---|
| PROC-02 | CERTAIN · LOW | C++ unit | high | killJob can signal a reused pid |
| PROC-03 | CERTAIN · LOW | E2E | high | spawnProcess ignores stdout_/stderr_ |
| PROC-05 | LIKELY · MEDIUM | E2E | high | kill on exited run with open output does nothing |
| PROC-06 | LIKELY · LOW | C++ unit | medium | exception after parkResume leaks job hold |
| PROC-07 | CERTAIN · MEDIUM | E2E | medium | Windows startCollector leaks pipe read ends |
| PROC-08 | CERTAIN · LOW | E2E | medium-high | Process.wait not cancellable |
| PROC-NEW-1 | CERTAIN · MEDIUM | E2E | high | Console.write to a spawnProcess stdin handle is a silent no-op |

### REGEX

| ID | Triage | Test | Confidence | Title |
|---|---|---|---|---|
| REGEX-03 | CERTAIN · MEDIUM | E2E | high | replaceAtMost/splitAtMost catch paths use unrooted strings |
| REGEX-06 | CERTAIN · MEDIUM | E2E | high | regex engine is byte-wise over UTF-8 |
| REGEX-08 | CERTAIN · MEDIUM | C++ unit | high | regexTable never freed |

### RESET

| ID | Triage | Test | Confidence | Title |
|---|---|---|---|---|
| RESET-01 | LIKELY · LOW | C++ unit | high | Runtime root scanner not re-registered after reset |
| RESET-02 | LIKELY · LOW | C++ unit | high | Time root scanner not re-registered after reset |
| RESET-04 | CERTAIN · LOW | C++ unit | high | FileSystem handle table never cleared on reset |
| RESET-05 | CERTAIN · LOW | C++ unit | medium | FileSystemManager reset without stopWatch |
| RESET-06 | CERTAIN · LOW | C++ unit | high | SocketTables reset keeps holds |
| RESET-07 | CERTAIN · LOW | C++ unit | high | HttpTables reset keeps holds |
| RESET-08 | CERTAIN · LOW | C++ unit | high | Udp reset keeps in-flight OpDone holds |
| RESET-09 | CERTAIN · LOW | C++ unit | high | WsTables reset keeps holds |
| RESET-10 | CERTAIN · LOW | C++ unit | medium | WsManager aux() reset keeps subscription holds |
| RESET-11 | CERTAIN · LOW | C++ unit | medium | listener/g_quiescenceRegistered survive reset |

### SIG

| ID | Triage | Test | Confidence | Title |
|---|---|---|---|---|
| SIG-03 | CERTAIN · LOW | C++ unit | medium-high | addListener push_back throw leaks subscription |
| SIG-04 | CERTAIN · LOW | C++ unit | high | chainToPrevious window runs old disposition |

### SOCK

| ID | Triage | Test | Confidence | Title |
|---|---|---|---|---|
| SOCK-03 | CERTAIN · LOW | C++ unit | high | Conn second write onError |
| SOCK-12 | CERTAIN · LOW | C++ unit | medium | pending connect left if makeKillHandle throws |
| SOCK-15 | LIKELY · LOW | E2E | medium | Udp handler refused by reactor never reads |

### STREAM

| ID | Triage | Test | Confidence | Title |
|---|---|---|---|---|
| STREAM-03 | CERTAIN · LOW | E2E | high | concatenated gzip members rejected |
| STREAM-07 | CERTAIN · MEDIUM | C++ unit | high | maybeErase never erases some pairs |

### STRING

| ID | Triage | Test | Confidence | Title |
|---|---|---|---|---|
| STRING-01 | CERTAIN · LOW | static check | high | String foldl/foldr resolve a possibly-constant accumulator |

### SYNC

| ID | Triage | Test | Confidence | Title |
|---|---|---|---|---|
| SYNC-02 | CERTAIN · LOW | static check | low | ECO_KLOG defined three times |
| SYNC-03 | CERTAIN · LOW | static check | low | kKinds = 9 unchecked |

### TASK

| ID | Triage | Test | Confidence | Title |
|---|---|---|---|---|
| TASK-01 | CERTAIN · MEDIUM | C++ unit | medium-high | task effect manager closures unrooted at registration |

### TERM

| ID | Triage | Test | Confidence | Title |
|---|---|---|---|---|
| TERM-04 | CERTAIN · MEDIUM | C++ unit | high | no restore on _exit/abort/SIGHUP/SIGQUIT |
| TERM-05 | LIKELY · LOW | C++ unit | high | title filter keeps 0x80-0x9F |
| TERM-06 | CERTAIN · LOW | C++ unit | high | first setStdInRawMode False saves mode |

### TIME

| ID | Triage | Test | Confidence | Title |
|---|---|---|---|---|
| TIME-01 | CERTAIN · HIGH | C++ unit | high | tagger/router encodings decoded after an allocation |
| TIME-05 | CERTAIN · MEDIUM | E2E | medium | Windows _timezone ignores DST |
| TIME-06 | CERTAIN · LOW | E2E | high | any non-empty TZ becomes a Name |
| TIME-07 | CERTAIN · HIGH | E2E | high | duplicate intervals with different taggers |
| TIME-08 | CERTAIN · LOW | E2E | low | non-finite intervals reach TimerService |
| TIME-09 | CERTAIN · LOW | E2E | high | zero/negative intervals busy-loop |
| TIME-NEW-1 | CERTAIN · MEDIUM | C++ unit | medium | Time effect manager closures unrooted at registration (same as TASK-01) |

### TLS

| ID | Triage | Test | Confidence | Title |
|---|---|---|---|---|
| TLS-01 | CERTAIN · LOW | static check | high | TlsTransport copyable while owning SSL* |
| TLS-04 | CERTAIN · LOW | C++ unit | high | bad SSL_CERT_FILE disables good SSL_CERT_DIR |
| TLS-05 | LIKELY · LOW | E2E | high | ERR_SSL_NO_CERTIFICATES likely unreachable |
| TLS-06 | CERTAIN · LOW | none | n/a | ERR_SSL_ prefix on all libraries' errors |
| TLS-08 | LIKELY · LOW | C++ unit | medium | failed send error overwritten by reads |
| TLS-10 | LIKELY · LOW | C++ unit | medium | stage-2 entry kept until generation change |

### URL

| ID | Triage | Test | Confidence | Title |
|---|---|---|---|---|
| URL-01 | CERTAIN · LOW | E2E | high | percentEncode escapes !*'() |
| URL-02 | CERTAIN · MEDIUM | E2E | high | percentDecode decodes + as space |
| URL-03 | CERTAIN · MEDIUM | E2E | high | percentDecode returns Just on invalid UTF-8 |
| URL-04 | CERTAIN · LOW | none | n/a | dead percentEncode encodes lone surrogates |

### UTILS

| ID | Triage | Test | Confidence | Title |
|---|---|---|---|---|
| UTILS-02 | LIKELY · LOW | C++ unit | high | mixed boxed/unboxed Float comparison uses raw operators |
| UTILS-03 | LIKELY · LOW | C++ unit | high | compare and == disagree on tuples with one boxed slot |
| UTILS-05 | CERTAIN · HIGH | E2E | high | eqHelp assumes equal past depth 100 |
| UTILS-06 | CERTAIN · LOW | E2E | high | function equality returns false |

### WATCH

| ID | Triage | Test | Confidence | Title |
|---|---|---|---|---|
| WATCH-02 | CERTAIN · MEDIUM | E2E | high | renamed sub-dir keeps stale relative path |
| WATCH-03 | CERTAIN · MEDIUM | E2E | high | directory moved out keeps reporting |
| WATCH-04 | CERTAIN · MEDIUM | C++ unit | high | inotify vs poll disagree on symlinked root |
| WATCH-05 | CERTAIN · LOW | C++ unit | high | poll-mode vanished root events |
| WATCH-07 | CERTAIN · MEDIUM | C++ unit | medium | IN_Q_OVERFLOW dropped silently |
| WATCH-08 | CERTAIN · MEDIUM | E2E | high | files in new sub-dir before watch added missed |

### WS

| ID | Triage | Test | Confidence | Title |
|---|---|---|---|---|
| WS-08 | CERTAIN · LOW | static check | high | wsRandomBytes falls back to mt19937_64 |
| WS-11 | CERTAIN · LOW | C++ unit | high | resume path skips default heartbeat timeout |
| WS-12 | CERTAIN · MEDIUM | E2E | high | closeFrameWritten ignores err |
| WS-13 | CERTAIN · LOW | C++ unit | high | ended sets closeWritten_ without a write |
| WS-16 | LIKELY · LOW | C++ unit | high | failWith no close deadline, may send second Close |
| WS-18 | LIKELY · LOW | E2E | medium | deliverClose marks delivered before deliver |
| WS-19 | LIKELY · LOW | E2E | medium | close with no subscriber lost after retire |
| WS-21 | LIKELY · MEDIUM | E2E | medium | failed open may leave WsEntry |
| WS-NEW-1 | LIKELY · MEDIUM | E2E | high | open over HTTP/1.1 can report success while the core is never attached (permanent hang) |

### ZLIB

| ID | Triage | Test | Confidence | Title |
|---|---|---|---|---|
| ZLIB-01 | CERTAIN · LOW | C++ unit | high | uInt casts truncate >4 GiB input |

## Appendix: test and fix proposals, per bug

### Area ABI

#### ABI-01: modBy throws across an extern "C" export
- **Triage:** CERTAIN · LOW
- **Test kind:** E2E · **Exposes it:** high confidence (medium on reachability until the CHECK-MLIR line confirms the kernel symbol is called)
- **Test:** new `test/elm/src/ModByZeroKernelPathTest.elm`. It reaches the kernel symbol through non-intrinsified uses: `List.map (modBy 0) [5, -3]`, `let f = modBy in f 0 7` (pass `f` through a function argument so the inliner cannot saturate it), and `List.map2 modBy [0, 4] [9, -7]`. For contrast it also runs the inline path `modBy 0 5`. Every result is reduced to an Int/String and logged. Directives:
  - `-- CHECK-MLIR: Elm_Kernel_Basics_modBy` proves the kernel path is exercised. If this line fails, the bug is unreachable from Elm and the test should become a C++ unit test, see below.
  - `-- SKIP-JS: elm/core crashes on modBy 0 (hint 11); eco's total division is a deliberate divergence (CGEN_084)`.
  - The expected lines depend on the user decision under Fix:
    - Option A (kernel returns 0): `-- CHECK: map: [0,0]`, `-- CHECK: value: 0`, `-- CHECK: map2: [0,1]`, `-- CHECK: inline: 0`.
    - Option B (kernel crashes cleanly): `-- EXIT: 1` and `-- CHECK: modBy` against the crash message, with only the crashing case in the program.
  - Today the process dies with SIGABRT from `std::terminate` ("terminate called after throwing an instance of 'std::runtime_error'"). The harness reports a signalled child as a failure, so mark the test `-- XFAIL-NATIVE: ABI-01 kernel modBy 0 throws through extern "C"` until the fix lands.
  - Also extend `test/kernel/KernelExportsTest.cpp::test_kernel_int_division_total` with `Elm_Kernel_Basics_modBy(zero, seven) == 0` (Option A). Under Option B, add a fork-based death check with `XfailGuard::runInChild` instead.
  - Elm reference: `build/toolchain/bin/elm make` + node shows Elm crashing for each case. That crash is why the test is SKIP-JS and lives in test/elm, not elm-conformance.
- **Fix:** `elm-kernel-cpp/src/core/Basics.cpp::modBy`. The function has a second defect: it has no `return answer;` after the final `if` (Basics.cpp:96-99 falls off the end, which is UB). Fix that in the same change.
  - Option A: `if (modulus == 0) return 0;`, which makes the kernel agree with the inline lowering. Then amend CGEN_084's "except that the kernel modBy 0 still throws" clause in `design_docs/invariants.csv`.
  - Option B: keep Elm's crash, but call the runtime crash path (`eco_crash` with a message, exit 1, atexit runs) instead of `throw`. Optionally also wrap `Elm_Kernel_Basics_modBy` in `ECO_KERNEL_GUARD` as defence.
  - Risk: low. Option A changes documented semantics, so it needs the invariant row edited.
- **Shares:** -

#### ABI-02: C++ helpers declared inside extern "C" in ListExports
- **Triage:** CERTAIN · LOW
- **Test kind:** static check · **Exposes it:** high confidence
- **Test:** new `test/scripts/check-kernel-c-symbols.sh`.
  - It runs `nm -g --defined-only` over the kernel static archives: elm-kernel-cpp `ElmKernel_*`, eco-kernel and eco-system.
  - It fails when a defined global text symbol is neither C++-mangled (`_Z`) nor in the export namespace: prefixes `Elm_Kernel_`, `Eco_Kernel_`, `EcoSystem_`, `eco_`, plus an allowlist of the existing runtime ABI names.
  - Today it reports `kernelListMapN` from ListExports.cpp.o. It also gives ABI-05-style hygiene a home.
  - Wire it as a CTest/cmake check next to `check-kernel-homes.sh`. No XFAIL is needed if it lands with the fix. Otherwise put `kernelListMapN` on a temporary allowlist with the bug id.
- **Fix:** in `elm-kernel-cpp/src/core/ListExports.cpp`, move `kernelListMapN` (:425), `listToKindedVectors` (:660) and `listFromPermutation` (:702) out of the `extern "C" {` block (:285-828) and into the existing anonymous namespace that ends just above :285. Drop the redundant `static`. Callers are only at :574-611 in the same file, so nothing else changes. Risk: none.
- **Shares:** -

#### ABI-03: eco exports not under ECO_KERNEL_GUARD
- **Triage:** LIKELY · LOW
- **Test kind:** static check · **Exposes it:** high confidence (as a coverage check; the OOM behaviour itself is not practically testable)
- **Test:** extend `test/scripts/check-kernel-c-symbols.sh`, or add a small Python checker like `check-root-bounded.py`.
  - For every `extern "C"` function definition in `eco-kernel-cpp/src/eco-kernel/*Exports.cpp`, check that its body is an `ECO_KERNEL_GUARD(...)`. Allow an explicit `// no-guard: <reason>` waiver for trivially non-throwing ones (for example `Hash_*`, if kept).
  - Today it lists Crash, Env, Http, NativeDriver, Runtime, MVar and Hash exports.
  - The behaviour (an exception escaping into `std::terminate`) could only be shown with allocation fault injection. No such hook exists, so this is not proposed.
- **Fix:** wrap the bodies of the listed exports in `ECO_KERNEL_GUARD(...)` (KernelExports.h:68). Watch out for top-level commas in bodies, which split the macro argument (documented at :66). This adds coverage only for Task construction. The meaningful protection for bodies is ABI-NEW-1. Risk: none. A `try` costs nothing on the no-throw path.
- **Shares:** ABI-NEW-1 (complementary). The static checker is shared with ABI-02.

#### ABI-04: filesystem_error thrown outside the guard
- **Triage:** CERTAIN · MEDIUM
- **Test kind:** E2E · **Exposes it:** high confidence for canonicalize (libstdc++ build), low for the `list` mid-iteration path
- **Test:** new `test/eco-kernel/src/FileCanonicalizeErrorTest.elm`, using `Eco.File` (canonicalize is exposed only there, not in eco-system's FileSystem).
  - (1) `File.canonicalize ""`. libstdc++'s `std::filesystem::absolute("")` throws "cannot make absolute path", which the fallback at File.cpp:353 reaches after `canonical("", ec)` fails.
  - (2) Make `/tmp/eco-kernel-FileCanonicalizeErrorTest/gone`, `File.setCwd` into it, `File.removeDir` it, then `File.canonicalize "rel"`. `absolute` calls the throwing `current_path()`, and getcwd fails with ENOENT. Each test is its own spawned child, so changing the cwd is safe.
  - Print `Ok`/`Err` with the IOError kind.
  - Expected after the fix: `-- CHECK: empty: Err` (or the chosen result, see Fix) and `-- CHECK: deleted-cwd: Err`.
  - Current behaviour: SIGABRT via `std::terminate`. Mark `-- XFAIL-NATIVE: ABI-04 canonicalize throws filesystem_error from a binding body`, and `-- LINUX-ONLY:` because it needs removable-cwd semantics.
  - The default `build` preset uses clang++ with libstdc++. The `release` preset uses libc++, where `absolute("")` may not throw, but case (2) still does.
  - For `listBody`'s throwing `operator++`, an E2E trigger (readdir EIO) is not reliably constructible. Cover it with the static check in the Fix instead.
- **Fix:** in `eco-kernel-cpp/src/eco-kernel/File.cpp`:
  - In `canonicalizeBody`, use `std::filesystem::absolute(pathStr, ec)` and map `ec` to `failErrno(ec.value(), pathStr, "could not make path absolute")`. Decide whether `""` fails (EINVAL/ENOENT, recommended) or resolves to the cwd.
  - In `listBody`, replace the range-for with `for (auto it = begin(iter), end = {}; it != end; it.increment(ec)) { if (ec) return failErrno(...); ... }`, checking `ec` after each increment.
  - Grep the rest of eco-kernel and eco-system for other throwing `std::filesystem` overloads in bodies, such as `file_size`, `status` and `last_write_time` without `ec`. A one-line grep in the static checker can enforce "every std::filesystem call in a *Body takes an error_code".
  - Invariant: IO_ERR_002 (the kernel failure tuple shape).
  - Risk: low.
- **Shares:** ABI-NEW-1. The same test program turns from SIGABRT into a clean `[eco-runtime] FATAL` after ABI-NEW-1, and into a pass only after ABI-04, so keep the XFAIL until ABI-04 lands.

#### ABI-05: Browser_reload takes a C bool
- **Triage:** CERTAIN · LOW
- **Test kind:** static check · **Exposes it:** high confidence
- **Test:** add a check, in `check-kernel-c-symbols.sh` or a grep step in a CTest, that no `extern "C"` kernel export declaration in `elm-kernel-cpp/src/KernelExports.h`, `eco-kernel-cpp/src/eco-kernel/KernelExports.h` or the eco-system export headers has a `bool` parameter or return type (REP_ABI_001). Today it flags `Elm_Kernel_Browser_reload(bool skipCache)` (KernelExports.h:605).
  - An E2E test is not useful. Native programs never run `Browser.Navigation.reload` (there is no navigation), and a Browser program cannot be driven by the native harness.
- **Fix:**
  - Change the signature to `HPtr Elm_Kernel_Browser_reload(HPtr skipCache)` in `elm-kernel-cpp/src/KernelExports.h:605` and `elm-kernel-cpp/src/browser/BrowserExports.cpp:36`.
  - Drop the "except the parameter of Browser.reload" clause from the ABI comment at KernelExports.h:25.
  - The compiler has no special case for `reload` (grep finds none in compiler/src), so it already passes `!eco.value`. No compiler change is needed. `RuntimeSymbols.cpp:993` needs no change.
  - Replace the `assert(false && ...)` stubs (load, reload, pushUrl, replaceUrl, go, ...) with an explicit fatal that survives NDEBUG release builds: the runtime crash path with "Browser.reload is not supported natively". Otherwise release builds return word 0 as a Task and crash later.
  - Risk: none.
- **Shares:** the static checker is shared with ABI-02 and ABI-03.

#### ABI-NEW-1: binding-body exceptions are never caught; ECO_KERNEL_GUARD on Task-returning exports is ineffective
- **Triage:** CERTAIN · MEDIUM
- **Test kind:** C++ unit · **Exposes it:** high confidence
- **Test:** new case in `test/platform/SchedulerPidTest.cpp`, or a sibling `test/platform/BindingExceptionTest.cpp` registered the same way, run in the `test` binary.
  - Define a `BindingBody` that does `std::printf("before-throw"); throw std::runtime_error("boom");`.
  - Spawn `Elm::Platform::makeBinding<ThrowBody>(unit)` with `rawSpawn`, the way SchedulerPidTest drives the Scheduler, and step the scheduler.
  - Run the scenario in `XfailGuard::runInChild`, which forks and captures stderr.
  - Expected after the fix: the child dies by SIGABRT with stderr containing `[eco-runtime] FATAL: boom`, and "before-throw" reaches stdout, because `reportFatal` flushes it. To check stdout, redirect it to a pipe or file in the child as well.
  - Current behaviour: stderr has libstdc++'s "terminate called after throwing an instance of 'std::runtime_error'" and no FATAL line.
  - Report through `XfailGuard::report("ABI-NEW-1", defect = !contains("[eco-runtime] FATAL"), ...)` until fixed.
  - Do the same for an async binding body, through `makeAsyncBinding`.
  - The ABI-04 E2E test is also an end-to-end witness.
- **Fix:** in `runtime/src/platform/TaskBinding.hpp`, wrap the `Body(...)` call in both `detail::bindingTrampoline` and `detail::asyncBindingTrampoline` in try/catch. The catch sets mirror `ECO_KERNEL_GUARD`: `bad_alloc`, then `std::exception`, then `...`.
  - Minimum: call a runtime-side `reportFatal` equivalent. The runtime cannot include eco-kernel's KernelExports.h, so move `reportFatal` to a runtime header, for example `runtime/src/allocator/RuntimeExports.h` or a new `platform/Fatal.hpp`, and make eco-kernel's version forward to it.
  - Better, for the sync trampoline: turn the exception into a failed Task only where the error shape is known. Leave that per kernel. A generic `Task.fail` with an arbitrary value would break typed `IOError` decoders, so do not do it generically.
  - Optionally add the same catch around `callClosure1(bindCallback, ...)` at Scheduler.cpp:982-997, which covers bindings not built with these templates.
  - Keep the `StackRootGuard` scope intact (HEAP root rules). The catch must not touch the HPointers after an exception without re-resolving them.
  - Risk: low. Zero cost on the no-throw path.
- **Shares:** ABI-03, ABI-04, TERM-04. After this fix, reportFatal is the single fatal path, which is where TERM-04's restore hook goes.

### Area ARRAY

#### ARRAY-01: unsafeSet range check truncates the index to 32 bits
- **Triage:** CERTAIN · LOW
- **Test kind:** C++ unit · **Exposes it:** medium confidence
- **Test:** Add a new file test/kernel/JsArrayKernelTest.cpp (with a .hpp), registered in test/main.cpp the same way KernelExportsTest is. ARRAY-02, ARRAY-03 and ARRAY-05 also go in this file.
  - (a) Build a length-2 Int array: `Elm_Kernel_JsArray_push_Int` twice from an empty array, values 10 and 20.
  - (b) Inside `XfailGuard::runInChild`, call `Elm_Kernel_JsArray_unsafeSet_Int((1LL<<32) + 1, 7, arr)`, and also the boxed `Elm_Kernel_JsArray_unsafeSet` with a boxed index of the same value.
  - Correct behaviour: the child exits 0 and the result equals the source, `[10,20]`. Today the store lands 32 GiB past the array. That usually gives SIGSEGV in the child, which counts as the defect.
  - Why only medium confidence: the write can land silently in mapped memory, and then the test cannot see it.
  - Add a second, deterministic sub-check on the read side: `Elm_Kernel_JsArray_unsafeGet_Int((1LL<<32)+1, arr)` returns 20 today, because it reads index 1 after truncation. After the fix it must not return an in-range element. The fix asserts or traps instead, so run this sub-check in a child too.
  - Report both through `XfailGuard::report("ARRAY-01", defect, how)`. The test passes as XFAIL until the fix lands; `ECO_TEST_XFAIL=strict` makes it assert the fixed behaviour.
  - No Elm-level test is possible: elm/core always masks the index to 0..31.
- **Fix:** In elm-kernel-cpp/src/core/JsArrayExports.cpp, replace `static_cast<uint32_t>(idx) < len` with `idx >= 0 && static_cast<uint64_t>(idx) < len` in four places: the boxed `Elm_Kernel_JsArray_unsafeSet` (:238), `_Int` (:882), `_Float` (:892) and `_Char` (:901). Keep the 64-bit store index. For `Elm_Kernel_JsArray_unsafeGet` (:205) and `unsafeGet_Int`, add an `assert(idx >= 0 && (uint64_t)idx < arr->length)`, since an out-of-range get has no defined result. A shared inline `inRange(idx, len)` helper is cleanest. No invariant changes. Risk: none, because no well-typed caller passes an index outside 0..31.
- **Shares:** Same test file as ARRAY-02, ARRAY-03 and ARRAY-05 (test/kernel/JsArrayKernelTest.cpp). Same edit region as the ARRAY-02 fix (boxed unsafeSet).

#### ARRAY-02: boxed unsafeSet marks Float/Char sources Int-kind
- **Triage:** CERTAIN · LOW
- **Test kind:** C++ unit · **Exposes it:** high confidence
- **Test:** In test/kernel/JsArrayKernelTest.cpp:
  - Float case: build a Float array with `Elm_Kernel_JsArray_push_Float(1.5, empty)` and `(2.5, …)`, so it is kind 2. Call the boxed `Elm_Kernel_JsArray_unsafeSet(boxedInt(0), boxedFloat(9.25), arr)`.
    - Check that the result has `header.unboxed & 3 == 2`. Today it is 1.
    - Check that `elements[0].f == 9.25`.
    - Check that the boxed `Elm_Kernel_JsArray_unsafeGet(boxedInt(1), result)` returns an object with `Tag_Float` and value 2.5. Today it returns an ElmInt that holds the double's bits.
  - Char case: do the same with a Char array (`push_Char`) and a boxed Char `'z'`. Expect kind 3 and `ElmChar` 'z' from `unsafeGet`.
  - Boxed control: a kind-0 array of boxed strings must stay kind 0 and keep its pointers.
  - Mark it with `XfailGuard::report("ARRAY-02", …)` until the fix lands.
  - E2E cannot reach it: the compiler always selects `_Int/_Float/_Char` or the intrinsic.
- **Fix:** Rewrite the boxed `Elm_Kernel_JsArray_unsafeSet` (JsArrayExports.cpp:215-256) on top of `copyForUnsafeSet`:
  - Read `kind = header.unboxed & 3` before the allocation.
  - Decode the value per kind, before the allocation, from the boxed object: `ElmInt::value`, `ElmFloat::value`, or `ElmChar::value` through `alloc::unboxedChar`.
  - Store through the matching member, write `dst->header.unboxed = kind`, and apply the ARRAY-01 range check.
  - Keep rooting `valHP` across `allocArray`, which the current StackRootGuard already does.
  - Alternatively, and more simply, assert `kind == 0` and delegate kinds 1-3 to the typed variants.
  
  Invariants: REP_HEAP_002 (Char upper 32 bits zero). Risk: low, because the function is dead under the current codegen.
- **Shares:** Same test file as ARRAY-01/03/05. The fix mirrors ARRAY-03 (same per-kind decode helper `unboxByKind(valHP, kind)`), so write ARRAY-02 and ARRAY-03 as one commit.

#### ARRAY-03: push reads Char padding as part of a 64-bit value
- **Triage:** CERTAIN · LOW
- **Test kind:** C++ unit · **Exposes it:** high confidence
- **Test:** In test/kernel/JsArrayKernelTest.cpp:
  - Build a Char array (kind 3) with `Elm_Kernel_JsArray_push_Char('a', empty)`.
  - Allocate a boxed Char with `alloc::allocChar('b')`, then deliberately write `0xFFFFFFFF` into its `ElmChar::padding`. This simulates nursery poison deterministically, so the test does not depend on the zeroing mode.
  - Call the boxed root `Elm_Kernel_JsArray_push(boxedChar, arr)` and check:
    - the result has kind 3 (today it is 1);
    - `(uint64_t)elements[1].i >> 32 == 0` (today it is 0xFFFFFFFF);
    - `unsafeGet` of index 1 gives an `ElmChar` 'b'.
  - Repeat with a Float array and a boxed Float: expect kind 2 and the value preserved.
  - Mark it with `XfailGuard::report("ARRAY-03", …)` until fixed.
- **Fix:** In `Elm_Kernel_JsArray_push` (JsArrayExports.cpp:258-310):
  - Keep `srcKind = header.unboxed & 3`.
  - Read the payload per kind before the allocation, using the shared `unboxByKind` from ARRAY-02: for kind 3 use `alloc::unboxedChar(ElmChar::value)`, so the high bits are zero, and for kind 2 use the f64.
  - Write `dst->header.unboxed = srcKind`.
  - Handle the `len == 0` source the way `elm_array_push_box` does: the kind of an empty array is unbound.
  - Alternatively, assert `srcKind == 0` and route the primitive kinds to `elm_array_push_int/_float/_char`.
  
  Invariants: REP_HEAP_002 and HEAP_019 (2-bit kinds). Risk: low.
- **Shares:** ARRAY-02 (same per-kind decode helper and the same commit). Same test file as ARRAY-01/02/05.

#### ARRAY-05: elm_array_push_* writes raw words into a boxed array
- **Triage:** UNSURE · MEDIUM
- **Test kind:** C++ unit (the code defect) + E2E (reachability, shared with ARRAY-NEW-1) · **Exposes it:** high confidence (unit); medium (E2E, depends on NEW-1)
- **Test:**
  - (1) Unit test in test/kernel/JsArrayKernelTest.cpp:
    - Build a nonempty kind-0 array holding two boxed ElmInts, 1 and 2, with `Elm_Kernel_JsArray_push` on an empty array plus boxed values (or `elm_array_push_box`).
    - Call `elm_array_push_int(4, arr)`.
    - Correct: the result is either uniformly kind 1 `[1,2,4]` (the convert option) or the call aborts in a child (the assert option). Today it is kind 0 with raw `4` in slot 2.
    - Detect the defect by `header.unboxed == 0 && elements[2].i == 4`. In an ECO_HEAP_VALIDATE build, calling `alloc::validateNurseryHPtr(elements[2].p)` aborts.
    - Run it in `XfailGuard::runInChild`, with id "ARRAY-05".
  - (2) The end-to-end trigger is the ArrayMapDebugLogKindTest.elm program described under ARRAY-NEW-1. Its `pushed:` line and a forced minor GC exercise this path.
- **Fix:** In JsArrayExports.cpp `elm_array_push_int/_float/_char` (:713-741), after `copyAndExtendForPush`:
  - if `len == 0`, bind the kind (as today);
  - else if `kind == wanted`, write as today;
  - else if `kind == 0`, convert. Before the allocation, read each boxed prefix element's primitive value (all prefix elements are ElmInt/ElmFloat/ElmChar objects of the wanted kind), rewrite the copied slots in place in the fresh array (no further allocation, so this is GC-safe), then set kind = wanted. Assert in debug builds that every prefix object has the matching tag.
  - any other kind mismatch (e.g. 2 vs 1) is a type error: `assert`/abort.
  
  The same "kind-0 nonempty, primitive wanted" conversion belongs in `unsafeSet_Int/_Float/_Char` (ARRAY-04, which is outside this chunk). The proper fix is still ARRAY-NEW-1, so that kind-0 Int arrays are never produced. The conversion here is defence in depth. Invariants: REP_HEAP_002, HEAP_019; GC safety is that no allocation happens between the copy and the last slot write (the existing contract of `copyAndExtendForPush`). Risk: low to medium, because it adds a slow path to a hot push. Keep the check a single compare of `kind != wanted` on the fast path.
- **Shares:** ARRAY-NEW-1 (shared E2E program; the NEW-1 fix removes the producer). Unit test file shared with ARRAY-01/02/03. ARRAY-04 (another chunk) shares the conversion helper.

#### ARRAY-NEW-1: JsArray map/initialize store results in the closure's result kind, so an Int array can be kind 0
- **Triage:** UNSURE · MEDIUM
- **Test kind:** E2E · **Exposes it:** medium confidence (that is the open question; the test settles it)
- **Test:** New file test/elm-core/src/ArrayMapDebugLogKindTest.elm (a `text "done"` main, like ArrayEqAfterPushTest.elm).
  - The program's bindings:
    - `m = Array.map (Debug.log "x") (Array.fromList [1,2,3])` (a point-free polymorphic-result kernel)
    - `i = Array.initialize 3 (Debug.log "i")`
    - `big = Array.map (Debug.log "y") (Array.fromList (List.range 1 40))` (this goes through the tree, not just the tail)
  - It then logs these values:
    - `get0` = `Array.get 0 m`
    - `get2i` = `Array.get 2 i`
    - `pushed` = `Array.toList (Array.push 4 m)`
    - `sum` = `Array.foldl (+) 0 m`
    - `eq` = `m == Array.fromList [1,2,3]`
    - `bigGet` = `Array.get 35 big`
    - `gc`: between the push and the final log, an allocation-heavy expression forces minor GCs while the pushed array is live (e.g. `List.sum (List.map (\k -> k * 2) (List.range 1 300000))`). The pushed array must be used after that, e.g. log `Array.toList pushed` last.
  - CHECK lines, from stock Elm 0.19.1:
    - `x: 1`, `x: 2`, `x: 3`, `i: 0`, `i: 1`, `i: 2`
    - `get0: Just 1`, `get2i: Just 2`
    - `pushed: [1,2,3,4]`, `sum: 6`, `eq: True`
    - `bigGet: Just 36`
    - `after-gc: [1,2,3,4]`
  - Use CHECK-DAG for the `x:`/`y:` lines in case the evaluation order of the Debug.log side effects differs. Verify the expected output with `build/toolchain/bin/elm make` + node; the JS runner (test/scripts/run-js-e2e.js) checks it as well.
  - Expected failure today, if NEW-1 holds: `get0` prints pointer bits as an Int, and `pushed`/`after-gc` crash or misprint (ARRAY-05).
  - Run it once normally with `TEST_FILTER=ArrayMapDebugLogKind cmake --build build --target full`. If it passes, also run it once in the ECO_HEAP_VALIDATE tree (build-validate, recreated on demand) under a gc-pressure heap config, before declaring NEW-1 refuted.
  - If it fails, add `-- XFAIL-NATIVE: ARRAY-NEW-1 kernel-PAP closure result kind 0 makes Array Int kind 0` until the fix lands. If it passes everywhere, keep it unmarked as a regression guard, close NEW-1 as refuted, and leave ARRAY-05 as hardening only.
- **Fix:** The goal is that `JsArray.map/initialize/indexedMap/initializeFromList` produce arrays in the call-site element kind, not the closure's `result_kind`.
  - Preferred approach: let the kernel ask for the element kind.
    - In compiler/src/Compiler/GenerateMlir/KernelAbi.elm (the suffix dispatch, :290-307) and compiler/src/Compiler/IR/Kernel/Intrinsics.elm, select a typed variant from the Mono result element type. Do this the same way unsafeSet/push already pick `_Int/_Float/_Char`: `Elm_Kernel_JsArray_map_Int`/`_Float`/`_Char`, with the same for initialize, indexedMap and initializeFromList; `_Int` names already exist for initialize/indexedMap at :925/:975, so check what those suffixes currently mean. The alternative is to pass the desired kind as an extra i8 argument.
    - In JsArrayExports.cpp, the kernel then calls `eco_apply_closure_eval` with `desired_kind` = that element kind instead of `readClosureResultKind` (:60-64). The runtime already converts a boxed result to the requested primitive (`deliverPrimitiveFromBoxed`, runtime/src/allocator/RuntimeExports.cpp:2195), so `pushTypedResult` receives the right kind.
    - The boxed root variant keeps kind 0 for genuinely boxed element types.
  - Alternative (compiler-only): have codegen (Expr.elm `instanceClosureResult`, :1067-1095) wrap a kernel used as a function value whose ABI result is `CEcoValue`, but whose instance result type is Int/Float/Char, in a typed adapter lambda whose `_result_kind` matches the instance type. This fixes every higher-order kernel consumer (List/Dict kernels too) at one stroke, but touches CGEN_034 (generic papExtend result kind) and CGEN_056. It also costs an extra closure per such site.
  - Do not "guess" the kind in the kernel from the boxed object's tag. That conflates real kind-0 arrays with this bug.
  - Invariants to check: CGEN_034, CGEN_056/058, HEAP_019, HEAP_078 (closure result_kind field), REP_HEAP_002.
  - Risk: medium. The change touches kernel ABI naming, typed-artifact compatibility (bump the cache format if kernel signatures change), and every array-map site. Run full E2E + elm-tests + bootstrap afterwards.
- **Shares:** ARRAY-05 (same E2E program; this fix removes ARRAY-05's only producer). ARRAY-04 (another chunk) has the same root cause.

### Area BASICS

#### BASICS-01: Int arithmetic relies on signed overflow
- **Triage:** CERTAIN · LOW
- **Test kind:** static check · **Exposes it:** high confidence (the constant evaluation rejects signed overflow at compile time); a runtime/E2E test cannot expose it, since the generated code wraps today
- **Test:** Do a behaviour-neutral refactor first. Move the Int bodies into a header-only `constexpr` helper set, for example /work/runtime/src/allocator/IntArith.hpp with `ecoIntAdd/Sub/Mul/Pow(int64_t,int64_t)`, keeping today's bodies verbatim. Call them from `Elm_Kernel_Basics_add_Int/sub_Int/mul_Int/pow_Int` (E/core/BasicsExports.cpp:120-159) and from `eco_int_pow` (runtime/src/allocator/RuntimeExports.cpp:4709-4727).
  - Then add /work/test/kernel/IntArithStaticTest.cpp, compiled into `test/test`, with these assertions:
    - `static_assert(ecoIntAdd(INT64_MAX, 1) == INT64_MIN)`
    - `static_assert(ecoIntSub(INT64_MIN, 1) == INT64_MAX)`
    - `static_assert(ecoIntMul(INT64_MAX, 2) == -2)`
    - `static_assert(ecoIntMul(INT64_MIN, -1) == INT64_MIN)`
  - Clang and GCC both reject signed overflow in a constant expression, so with the current bodies these do not compile. That compile error is the visible failure. Once the bodies are fixed, they compile.
  - Add runtime CHECKs in /work/test/kernel/KernelExportsTest.cpp (`registerKernelExportsTests`) that call the real `extern "C"` symbols with the same values. They pass today and are kept as a regression.
  - Optional E2E regression: /work/test/elm/src/IntOverflowWrapTest.elm. It applies first-class `(+)` and `(*)` to `maxInt` (`List.foldl (+) 0 [ 9223372036854775807, 1 ]`, so the kernel `_Int` symbol is used; check the MLIR for the call). It has `-- CHECK: addWrap: -9223372036854775808`. This is eco's 64-bit semantics. Stock Elm (JS doubles) prints 9223372036854775808, so the test belongs with the documented 64-bit divergences and must not be compared against node.
  - There is no XFAIL: a static_assert cannot be expected to fail, so land the test with the fix after one local failing compile.
- **Fix:** In IntArith.hpp, compute in `uint64_t` and cast back. For example, `static_cast<int64_t>(static_cast<uint64_t>(a) + static_cast<uint64_t>(b))`, which C++20 defines as modular. The same pattern applies to sub and mul. Update the comments at BasicsExports.cpp:55 and :144-145. No `-fwrapv` is needed. Codegen is unchanged (a plain `add`/`imul`). The MLIR intrinsics `eco.int.add/mul` are a separate path: their LLVM lowering must not use `nsw` flags. Check runtime/src/codegen/Passes/EcoToLLVMArith.cpp while there, and look for a CGEN_* invariant about Int wrap. Risk: none.
- **Shares:** BASICS-02 and BASICS-NEW-1 (the same IntArith.hpp refactor, the same static test file and the same commit).

#### BASICS-02: pow_Int overflows even when the result fits
- **Triage:** CERTAIN · LOW
- **Test kind:** static check · **Exposes it:** high confidence
- **Test:** In the same /work/test/kernel/IntArithStaticTest.cpp:
  - `static_assert(ecoIntPow(2, 62) == 4611686018427387904)`
  - `static_assert(ecoIntPow(3, 39) == 4052555153018976267)`
  - `static_assert(ecoIntPow(-2, 63) == INT64_MIN)`
  - `static_assert(ecoIntPow(5, -1) == 0)`
  - `static_assert(ecoIntPow(0, 0) == 1)`

  With today's loop the final unconditional `b *= b` overflows during constant evaluation, so the assertion does not compile. Add runtime CHECKs on `Elm_Kernel_Basics_pow_Int(2, 62)` and `eco_int_pow(3, 39)` in KernelExportsTest.cpp. An optional E2E regression in test/elm/src (`Debug.log "pow62" (2 ^ 62)`, CHECK 4611686018427387904) passes today. Stock Elm prints the same value for 2^62, which is an exact double, but not for 3^39, so compare only 2^62 against node.
- **Fix:** In `ecoIntPow`, run the loop in `uint64_t`: `while (e) { if (e & 1) r *= b; e >>= 1; if (e) b *= b; }`, then cast back. Keep the `exp < 0 -> 0` rule. Both callers go through the one helper. Risk: none.
- **Shares:** BASICS-01, BASICS-NEW-1.

#### BASICS-NEW-1: runtime eco_int_pow has the same UB as pow_Int (the more reachable path)
- **Triage:** CERTAIN · LOW
- **Test kind:** static check · **Exposes it:** high confidence
- **Test:** This is covered by the BASICS-02 static asserts once `eco_int_pow` delegates to `ecoIntPow`. Add a runtime CHECK in /work/test/kernel/KernelExportsTest.cpp that calls `eco_int_pow` directly; it is declared in runtime/src/allocator/RuntimeExports.h, which that test already includes. This guards the delegation itself.
- **Fix:** Make `eco_int_pow` (runtime/src/allocator/RuntimeExports.cpp:4709-4727) `return ecoIntPow(base, exp);`. It must stay `extern "C"`, keep its symbol and keep its `gcLeaf` declaration, because EcoToLLVMArith.cpp:236-248 lowers `eco.int.pow` to it. Read design_docs/invariants.csv (CGEN_* rows on runtime helpers/gc-leaf) before editing. Risk: none.
- **Shares:** BASICS-01, BASICS-02.

### Area BROWSER

#### BROWSER-01: Browser stubs return word 0 under NDEBUG
- **Triage:** CERTAIN · LOW
- **Test kind:** E2E (plus a static check) · **Exposes it:** high confidence for the E2E in any build, since it checks the diagnostic and exit code; the NDEBUG segfault itself shows only in release
- **Test:**
  - **(a) E2E, `test/elm/src/BrowserNativeUnsupportedTest.elm`.** Use test/eco-system or another suite whose elm.json has elm/browser; test/elm doesn't list it, so add the dependency or pick an existing suite that has it. The program is a `Platform.worker` whose `init` returns `( (), Browser.Navigation.load "https://example.com" )`.
    - Directives: `-- CHECK: Browser.Navigation.load is not supported natively` and `-- EXIT: 1`.
    - Today: an assert abort (SIGABRT, exit 134, message "not implemented - requires platform") in the asserts-on presets, and a segfault or stray behaviour in release.
    - Mark it `-- XFAIL-NATIVE: BROWSER-01 browser stubs assert/return word 0` until fixed. Make it `-- LINUX-ONLY:` if exit-code handling differs on Windows.
    - Optionally add a second program for one File API (e.g. `File.Select.file`) to cover FileExports.
  - **(b) Static check.** `grep -c "assert(false" E/browser/BrowserExports.cpp E/file/FileExports.cpp` gives 27 and 12 today and must give 0 afterwards. It could go into a check-*.sh script beside the other test/scripts/check-*.sh. Note that Utils.cpp, JsonExports.cpp, Time.cpp, File.cpp and Browser.cpp also contain `assert(false`. Triage those separately and don't widen this fix blindly.
- **Fix:** Add one `[[noreturn]] void unsupportedNatively(const char* fn)` helper in elm-kernel-cpp. It prints "<fn> is not supported natively" to stderr/`eco_output_text` and exits with 1, the way `Elm_Kernel_Debug_todo` does (E/core/DebugExports.cpp:41-48); alternatively reuse `explicitFatal` (runtime/src/allocator/Allocator.cpp:1337). Replace each `assert(false && ...); return HPtr::fromBits(0);` in E/browser/BrowserExports.cpp:30-195 and E/file/FileExports.cpp:18-80 with a call to it, naming the user-facing Elm function (e.g. `Browser.Navigation.load`). Keep the `element/document/application` passthroughs (:18-28). If kernels must not exit directly, throw inside `ECO_KERNEL_GUARD` instead. That is a user/design decision; match whatever Debug.todo/crash conventions the project uses. Invariant: no word-0 HPointer may escape (Heap.hpp:340-342; FORBID_* rows on null pointers). Risk: none for working programs.
- **Shares:** The same helper and commit cover the FileExports stubs. The static grep could later also cover the other `assert(false` sites.

### Area BYTES

#### BYTES-04: encoder size narrowed size_t to u32 unchecked
- **Triage:** CERTAIN · LOW
- **Test kind:** C++ unit · **Exposes it:** high confidence (for the narrowing; the overflow write itself is not run)
- **Test:** Extend /work/test/kernel/KernelExportsTest.cpp, which already has K1 for `elm_encoder_size`. Forge an `ENC_SEQ` encoder node: a Custom with ctor 8, values[0] unboxed Int `(1LL<<32) + 8`, values[1] = Nil, unboxed mask 0x1. Nothing is written, because the child list is empty, so no 4 GiB buffer is needed. Then call `elm_encoder_size(enc)`. Today it returns 8, the silent truncation. Correct: a clean fatal error. Put the post-fix assertion in `registerKernelExportsCrasherTests` (IsolatedTestRunner, isolated child): `elm_encoder_size` and `Elm_Kernel_Bytes_encode` on the forged node must die with the new "exceeds the 4 GiB Bytes limit" message, not return. Until the fix, add an `[xfail BYTES-04]` guard (test/XfailGuard.hpp) in the normal suite: defect = `elm_encoder_size(forged) == 8`. Do not call `Elm_Kernel_Bytes_encode` or `allocByteBufferBlank(>4 GiB)` before the fix, because they would really allocate and zero 4 GiB. An E2E program is unsuitable: it would need a real 4 GiB+ encoding, and stock Elm's own behaviour there is a JS RangeError, so the outputs cannot be compared.
- **Fix:** In /work/elm-kernel-cpp/src/bytes/BytesExports.cpp, add a `[[noreturn]]` helper `bytesTooLarge(size_t)` that prints "eco: Bytes.Encode: an encoding of N bytes exceeds the 4 GiB Bytes limit" and aborts, matching the style of `ThreadLocalHeap::heapExhausted`. Call it in `elm_encoder_size` (:390), `elm_encoder_write_into` (:397; check the final offset as a backstop) and `Elm_Kernel_Bytes_encode` (:410) when the size is `> UINT32_MAX`. Then delete the "narrowed with no check" comment at :386-388. In /work/runtime/src/allocator/HeapHelpers.hpp `allocByteBufferBlank` (:1508), and in its siblings `allocByteBufferZero`/`allocByteBuffer` if they cast the same way, add the same check before the casts. The fused path (BFToLLVM.cpp:160, :1047-1097) needs no change once `elm_encoder_size` refuses. Invariant touchpoint: the u32 `header.size` of ByteBuffer (HEAP_026 large bytes); no row change. Risk: none for sizes under 4 GiB.
- **Shares:** -

#### BYTES-05: byte swaps ignore host endianness
- **Triage:** CERTAIN · LOW
- **Test kind:** static check · **Exposes it:** high confidence (as a build-time guard; no runtime test is possible on the little-endian hosts we have)
- **Test:** The `static_assert` itself is the check. A big-endian build fails to compile with a clear message, and every existing build must still compile; the KernelExportsTest K2/K3 endianness cases stay green. No XFAIL.
- **Fix:** Add `#include <bit>` and `static_assert(std::endian::native == std::endian::little, "Eco assumes a little-endian host (Bytes swaps, HPointer layout)");` at file scope in /work/elm-kernel-cpp/src/bytes/BytesExports.cpp (near the comment at :487-489, which can then point to it), in /work/runtime/src/allocator/BytesOps.hpp, and in /work/runtime/src/codegen/Passes/BFToLLVM.cpp, so each swap site is covered. Do not make the swaps conditional on the host. That would be untested code for an unsupported target, and the HPointer bit-field layout (Heap.hpp, BitmapScan.hpp:14) is little-endian anyway. Keep `getHostEndianness` and Bytes.cpp `isLittleEndian`, which implement Elm's `Bytes.getHostEndianness`. Risk: none.
- **Shares:** -

### Area CONSOLE

#### CONSOLE-01: readAllBody drops leading empty lines
- **Triage:** CERTAIN · MEDIUM
- **Test kind:** E2E · **Exposes it:** high confidence
- **Test:** New file test/eco-kernel/src/ConsoleReadAllRawTest.elm, a `Platform.worker` like ProcessSpawnWaitTest.elm.
  - `init` runs `Task.attempt Done Eco.Console.readAll`. `update` logs `Debug.log "readAll" (Debug.toString s)`, or logs `String.length s` and `String.split "\n" s` so the expected text has no ambiguous escapes.
  - Directives:
    - `-- STDIN: \n\na\n\nb\n\n`
    - `-- EXIT: 0` (this puts the test into process mode, where STDIN is honoured; see test/CheckPatterns.hpp:655-680)
  - CHECK lines:
    - `-- CHECK: len: 8`
    - `-- CHECK: lines: ["","","a","","b","",""]`
  - Today it outputs `len: 5` and `lines: ["a","","b",""]` (the content is `"a\n\nb\n"`).
  - Eco.Console is not stock Elm, so the reference is the XHR/JS backend, which returns stdin unchanged. Run the same program through test/scripts/run-js-e2e.js, after checking that it feeds `-- STDIN:`; if it does not, compute the expected output by hand from the byte-exact contract. Linux/macOS only: the harness throws for STDIN on Windows.
  - Mark it `-- XFAIL-NATIVE: CONSOLE-01 readAll drops leading blank lines and final newline` until fixed.
  - Optionally add a `readLine` sibling test with STDIN `\nx\n`: two `readLine`s must give `""` then `"x"`. This guards that the fix's raw read does not break line mode.
- **Fix:** In eco-kernel-cpp/src/eco-kernel/Console.cpp `readAllBody` (:106-116), read raw bytes to EOF and return them unchanged. Use either `std::string content{std::istreambuf_iterator<char>(std::cin), {}}` (keeps sharing std::cin's buffer with `readLine`, which is important if a program calls readLine then readAll) or a `read(0, …)` loop with EINTR retry. Prefer the istreambuf form, because mixing a raw `read(0)` with buffered `std::getline` would lose already-buffered bytes. Update the contract text in eco-kernel-cpp/src/eco-kernel/KernelExports.h:210-213, and the Console.hpp doc if it repeats it. Check whether `succeedString` decodes UTF-8 and handles a `\r` the same way the XHR backend does. Risk: low. Programs that relied on the trailing newline being stripped will see one more `"\n"`. Grep compiler/ and eco-kernel-cpp Elm sources for `Console.readAll` callers, e.g. a compiler reading stdin, and check them.
- **Shares:** -

#### CONSOLE-02: log ignores write result
- **Triage:** CERTAIN · LOW
- **Test kind:** C++ unit · **Exposes it:** medium confidence (signal timing)
- **Test:** No eco-kernel Console unit test exists. Add test/kernel/EcoConsoleLogTest.cpp, registered in test/main.cpp, which already links the eco-kernel. Inside `XfailGuard::runInChild`:
  1. `pipe()`, then `dup2` the write end onto fd 2. If needed, make `_eco_stderr_fd()` return 2.
  2. Install a SIGUSR1 handler with `sa_flags = 0` (no SA_RESTART).
  3. Start a reader thread that sleeps 200 ms and then drains the pipe to EOF, counting bytes.
  4. Start a signaller thread that sleeps 50 ms and then sends `pthread_kill(main, SIGUSR1)`.
  5. On the main thread, call `Eco::Kernel::Console::log(encode(String of 1 MiB 'a')), unit)`. The 1 MiB message is far more than the 64 KiB pipe buffer, so the write blocks and the signal interrupts it after a partial write.
  6. Close fd 2, join, and check `received == 1 MiB + 1`.
  
  Today Linux returns a short count (about 64 KiB) and the tail is lost. Repeat the scenario a few times (e.g. 3) inside the one test run to reduce timing flakiness. Use `XfailGuard::report("CONSOLE-02", …)`. Linux/macOS only (`#if !defined(_WIN32)`). The EAGAIN case (a non-blocking stderr) is deterministic: set O_NONBLOCK on the pipe and write 1 MiB with no reader. Use it only if the fix also handles EAGAIN, which needs a poll/wait and so is a user decision. Otherwise test only EINTR.
- **Fix:** In eco-kernel-cpp/src/eco-kernel/Console.cpp, take the write loop out of `writeBody` (:72-90) into a static `writeAll(int fd, const char*, size_t) -> int errno_or_0` that retries on EINTR, advances on short writes, and applies the 0x7fffffff Windows clamp per call. Use it in both `writeBody` (map a nonzero result to `failErrno`) and `log` (:165-178, ignore the final error). Risk: none.
- **Shares:** CONSOLE-03 (the same fix; writeAll's per-call clamp loops past 2 GiB).

#### CONSOLE-03: Windows tag >0x7fffffff truncated
- **Triage:** CERTAIN · LOW
- **Test kind:** none · **Exposes it:** n/a
- **Test:** None practical. It needs a log message over 2 GiB on Windows, and Windows fixes may stay unverified per project policy. After the CONSOLE-02 fix, the static check is that `log` contains no direct `_eco_write` call: `grep -n "_eco_write" eco-kernel-cpp/src/eco-kernel/Console.cpp` must show only the one inside `writeAll`.
- **Fix:** Covered by the CONSOLE-02 `writeAll` helper, which loops with the per-call `0x7fffffff` clamp. There is no separate change.
- **Shares:** CONSOLE-02 (the same fix).

#### CONSOLE-04: readLine/readAll block
- **Triage:** CERTAIN · LOW (documented behaviour)
- **Test kind:** E2E (only after a design decision, and needs a harness extension) · **Exposes it:** medium confidence
- **Test:** The current harness cannot expose it. With `-- STDIN:` the pipe is closed right after the text, and without it stdin is /dev/null, so `readLine` returns at once either way.
  - Harness change: add a process directive `-- STDIN-DELAY-MS: <n>` that waits N ms before writing the `-- STDIN:` text and then closing the pipe. It goes in test/CheckPatterns.hpp next to `extractStdinDirective`, plus `redirectChildStdin` in test/ChildStdin.hpp. Under the "fix tooling, don't wait" rule this extension is in scope.
  - Test program: test/eco-kernel/src/ConsoleReadLineNonBlockingTest.elm.
    - `init` starts `Process.sleep 50 |> Task.perform (\_ -> Tick)` and `Task.attempt Line Eco.Console.readLine` in a `Cmd.batch`.
    - `update` logs each event in arrival order.
    - Directives: `-- STDIN: hello\n`, `-- STDIN-DELAY-MS: 500`, `-- EXIT: 0`.
    - `-- CHECK: tick` must come before `-- CHECK: line: hello`, so use CHECK + CHECK-NEXT ordering.
  - Today the read blocks the eco thread, so `line: hello` prints first and `tick` second.
  - Mark it XFAIL-NATIVE until the async implementation lands. Not Windows.
- **Fix:** Needs a user decision. Either:
  - (a) Keep the blocking design, which is documented in K/Console.cpp:8 and Console.hpp:30-35. Then strengthen the Eco.Console.elm doc for `readLine`/`readAll` to say they freeze timers and subscriptions and point to eco/system `env.stdin` (Stream). Add no test.
  - (b) Reimplement both as `makeAsyncBinding` bodies that run the read on a worker thread, or on the reactor via the eco/system FdChannel machinery (S/Stream/Stream.cpp `createFdSource`). Then deliver the String result back through the scheduler. Keep a single owner of `std::cin`, or switch both to raw fd 0 reads with a module-level leftover buffer, so that readLine/readAll sharing remains correct (this interacts with the CONSOLE-01 fix). Watch HEAP_040-style off-heap rules: the worker thread must not allocate on the Elm heap, so it must hand back a std::string.
  
  Risk for (b): medium. It adds threading in the kernel and needs the "second mutator forbidden" rule (CR-012 option F) to be respected.
- **Shares:** The CONSOLE-01 fix (the reading strategy must be chosen jointly).

### Area CORE

#### CORE-01: SysWorkPool partial thread start use-after-free
- **Triage:** CERTAIN · MEDIUM
- **Test kind:** C++ unit · **Exposes it:** high confidence (the escaping exception and the second construction); the UAF itself shows reliably only under ASan
- **Test:** Extend /work/test/eco-system-core/EcoSystemCoreTest.cpp, the binary `build/system-kernel-cpp/eco-system-core-test`, which `full` runs. That binary has a plain sequential `int main()`, and `testPool1000` builds the pool singleton early. So the test needs a fresh process. Add a self-spawn mode: `main(int argc, char** argv)` dispatches `--child <scenario>` before the normal test list runs (after the Allocator/Scheduler init). The parent `posix_spawn`s `/proc/self/exe --child <scenario>` and `waitpid`s it. Do not use `fork()`: the pool and reactor workers do not exist in a forked child, and the binary is multithreaded. The test also needs a seam, because thread creation cannot be made to fail reliably from outside (RLIMIT_NPROC counts every thread the user owns). Add a file-scope function pointer `detail::g_startWorker` (default: `std::thread(f).detach()`) in S/Core/SysWorkPool.cpp/.hpp. It must stay behaviour-neutral in production. Scenario `pool-partial-start`: set `g_startWorker` to a function that starts thread 0 normally and throws `std::system_error(EAGAIN)` on the second call. Then call `SysWorkPool::instance()` twice.
  - Expected (fixed): no exception escapes. `threadCount() == 1` (if hardware_concurrency >= 2). The constructor ran once, so the starter is called no more than nThreads times in total. A submitted job completes.
  - Current: the first `instance()` throws `std::system_error`, and the second call runs the constructor again (the starter call count grows). The child reports this with exit code 1. In an ASan build it also reports heap-use-after-free from the first worker.
  - Linux/POSIX only (`#if !defined(_WIN32)`). The binary has no XFAIL convention, so write the test, see it fail once, then land the fix in the same change. Alternatively, wrap it in `XfailGuard::report("CORE-01", …)` style if XfailGuard.hpp is linked into this binary (today it lives in test/ for `test/test`).
- **Fix:** In `SysWorkPool::SysWorkPool()` (S/Core/SysWorkPool.cpp:29-38), wrap each thread start in `try { … } catch (const std::system_error&) { break; }` and count the threads that started.
  - If at least one started, set `nThreads_ = started` and log once to stderr, the way FdChannel does (S/Core/FdChannel.cpp:403-412).
  - If none started, rethrow. That is safe because no thread holds `this`, and a later `instance()` may retry.
  - A more robust variant also tolerates the zero case: construct the pool (empty) first and start the workers in `instance()` after the `new` returns. But then the zero-thread case needs `submit` to fail the job instead of queueing it forever.
  - No heap/codegen invariants are touched. Risk: low.
- **Shares:** The test infrastructure (`--child` self-spawn in EcoSystemCoreTest main) is shared with CORE-08 (counted variant), CORE-14 and CORE-18. The fix is in the same file as CORE-18.

#### CORE-07: failureFor(RunErr) drops the message
- **Triage:** CERTAIN · LOW
- **Test kind:** C++ unit · **Exposes it:** high confidence (at the kernel level only)
- **Test:** In /work/test/eco-system-core/EcoSystemCoreTest.cpp, next to `throwingBody`/`throwingSErrBody` (:609-620), add a `throwingRunErrBody` that runs `ECO_SYSTEM_BODY_GUARD(RunErr, throw std::runtime_error("spawn table full");)`. In `testGuardsAndHelpers`, check the following on the resulting Task:
  - `outer->a.i == 0`
  - `toStdString(outer->b.p) == "EIO"`
  - `inner->a.i == -1`
  - `toStdBytes(inner->c.p) == "spawn table full"`

  Current: `inner->c` is the empty Bytes constant, so the last CHECK fails. No E2E test is possible: only a C++ exception inside `childProcessRunBody` (bad_alloc) reaches this path. Note also that Elm's `ChildProcess.decodeFailedRun` (system-kernel-cpp/src/ChildProcess.elm:489-494) maps kind 0 to `InitError { error = toStartError "EIO" }` = `OtherStartError "EIO"` and **ignores stderr for kind 0**. So the suggested C++ fix alone is invisible to Elm programs.
- **Fix:** In S/Core/Core.cpp:123, use `failRun(0, "EIO", -1, "", w)`. Update the doc comments at S/Core/Core.hpp:186-191 and S/ChildProcess/ChildProcess.hpp:134-135, which now say the message is dropped. For Elm users to see the message, `decodeFailedRun` would also need to carry it, for example `OtherStartError (code ++ ": " ++ message-from-stderr)` when the code is "EIO". That changes the eco/system API semantics, and the ecosyskernel repo is the normative API, so it needs a user decision. Risk: none for the C++ part.
- **Shares:** -

#### CORE-08: asyncFailure may complete a Task twice
- **Triage:** LIKELY · LOW
- **Test kind:** C++ unit · **Exposes it:** high confidence (with a synthetic body that reproduces the pattern; reproducing the real Stream path needs fault injection in `transformCodec`, medium)
- **Test:** In /work/test/eco-system-core/EcoSystemCoreTest.cpp, add the async body `completesThenThrowsBody(HPointer resume)`. It declares `uint64_t token = 0; bool counted = false;` and runs `ECO_SYSTEM_ASYNC_GUARD(FErr, resume, token, counted, …)`. Inside the guard it does three things:
  1. It parks the resume, either as `token = sched.registerPendingResume(resume);` (variant A, uncounted) or as `token = sched.parkResume(resume, HoldKind::Task, "test.core08"); counted = true;` (variant B).
  2. It completes the Task synchronously the way `pumpStream` does, through `streamCompleteOk(token, counted, alloc::unit())` (StreamTable.hpp:205) or the equivalent take, callClosure1 and releaseHold sequence.
  3. It throws `std::runtime_error("late")`.

  `resume` is a `nativeClosure1` (helper at :1720) that counts its calls and records the Task ctor.
  - Variant A runs in process: expected (fixed) 1 resume call with `Task_Succeed`; current 2 calls, and the last one is `Task_Fail` "late".
  - Variant B checks `pendingAsync()` before and after. Expected (fixed): unchanged, with 1 call. Current, in the hold-census builds (`build` preset is -UNDEBUG, so `kHoldCensus` is on; runtime/src/platform/Scheduler.cpp:552): `holdFatal("second release of a hold")` aborts. So run variant B through the `--child core08-counted` self-spawn and check that the child exits 0 and its stderr has no "second release". In NDEBUG builds the defect shows as `pendingAsync()` dropping by 2.
  - Optional real-path test: a test-only throw hook in `transformCodec` (S/Stream/StreamCodec.cpp:~272) that is armed for one call, driving `writeOrEnqueue`'s in-memory path. Lower value; the synthetic body covers the guard contract.
- **Fix:** In `detail::asyncFailure` (S/Core/Core.cpp:129-141):
  - When `token != 0`, `HPointer parked = s.takePendingResume(token);`. If `alloc::isNil(parked)`, the Task has already been completed (or cancelled): return `alloc::unit()` without calling `resume` or `releaseHold`.
  - Otherwise proceed as today: call `resume` with the failure, then `releaseHold` if `counted`.
  - When `token == 0`, nothing was parked, so resume as today.
  - Update the contract comment in Core.hpp:199-205 ("it is called whether or not …"). One case needs auditing: a body that sets `token` but whose pending resume was taken by its own synchronous completion path *without* completing the Task. I know of no such case; check all `ECO_SYSTEM_ASYNC_GUARD` users (grep) for one.
  - No representation invariants are involved. Risk: low-medium, because every async kernel uses this path. Run the full eco-system E2E plus eco-system-core-test.
- **Shares:** `--child` self-spawn infrastructure with CORE-01/14/18.

#### CORE-14: backendInit partial failure leaks fds
- **Triage:** CERTAIN · LOW
- **Test kind:** C++ unit · **Exposes it:** medium-high confidence on Linux/epoll for the `eventfd` failure branch; the `epoll_ctl` failure branch and the kqueue path are not reachable from a test
- **Test:** Add the self-spawned child scenario `reactor-init-fd-leak` to /work/test/eco-system-core/EcoSystemCoreTest.cpp. It needs a fresh process, because `IoReactor::instance()` is a leaky singleton that later tests construct. In the child, before anything touches the reactor:
  1. Find the lowest free fd `f0` and the next free fd `f1` (probe with `fcntl(fd, F_GETFD)`).
  2. Set the soft `RLIMIT_NOFILE` to `f1`, so exactly one descriptor (`f0`) can be opened.
  3. Call `IoReactor::instance()`. `epoll_create1` takes `f0`, and `eventfd` fails with EMFILE.
  4. Restore the limit.
  5. Check `fcntl(f0, F_GETFD) == -1 && errno == EBADF`.

  Expected (fixed): `f0` is closed. Current: `f0` is still open (leaked epoll fd), and the child exits 1. Also check that the reactor reports itself unavailable (`ok == false`) through whatever public accessor exists, or the stderr line "cannot create the event loop". Linux only (`#if defined(ECO_IOR_EPOLL)`). The reactor `Impl()` constructor must open no fds before `backendInit`; verify that when writing the test.
- **Fix:** In `IoReactor::Impl::backendInit` (S/Core/IoReactor.cpp:308-318), on each failure return close and reset the fds already opened: `if (wakeFd >= 0) { ::close(wakeFd); wakeFd = -1; } ::close(pollFd); pollFd = -1;`. Do the same for the kqueue `backendInit` (:387-397). Preserve `errno` across the `close` calls, because the caller prints `strerror(errno)` (save it and restore it). Risk: none.
- **Shares:** `--child` self-spawn infrastructure with CORE-01/08/18.

#### CORE-18: PoolResult::of throwing in catch -> terminate
- **Triage:** CERTAIN · LOW
- **Test kind:** C++ unit · **Exposes it:** medium-high confidence (needs an allocation-failure hook)
- **Test:** Add the self-spawned child scenario `pool-oom-in-handler` to /work/test/eco-system-core/EcoSystemCoreTest.cpp. In that test binary only, define a replacement global `operator new(size_t)` (plus the `new[]` and nothrow forms delegating to it) that throws `std::bad_alloc` while a `thread_local int g_failNextNews` is > 0, decrementing it. Otherwise it calls `malloc`. The hook must be armed only by this scenario so that the rest of the binary is unaffected.
  - The child submits one pool job. That job first builds `std::runtime_error e(std::string(100, 'x'))`, long enough to defeat SSO, then sets `g_failNextNews = 1` on the worker thread and `throw e;`. The exception object comes from `__cxa_allocate_exception`, i.e. malloc, not `operator new`. The worker's `catch` then builds `PoolException{e.what()}`, whose `std::string` allocation fails.
  - Current: `std::terminate`, so the child dies with SIGABRT and "terminate called after throwing an instance of 'std::bad_alloc'".
  - Expected (fixed): `tryPop` yields an item holding a `PoolException` (with the fallback message), and the child exits 0.
  - A second arm can fail the `ready_.push_back` deque-node allocation instead, with a larger `g_failNextNews` count tuned to the deque's block allocation; this is fragile and lower confidence.
  - Linux/POSIX, any build.
- **Fix:** In `SysWorkPool::workerLoop` (S/Core/SysWorkPool.cpp:87-102), build the exception result inside a nested `try`. On `std::bad_alloc` (or any throw), store `PoolResult::of(PoolException{})`. An empty `std::string` does not allocate, and `PoolException` fits inline in `PoolResult` (<= 64 bytes, nothrow move), so this cannot throw. Have `poolDrain` map an empty `what` to "out of memory in kernel".
  - `ready_.push_back` cannot be made allocation-free with a `std::deque`. Wrap it, and on failure call `Eco::Kernel::reportFatal("[eco-system] out of memory in SysWorkPool worker")`. That is a clear fatal instead of a bare terminate, and it avoids a silent hang from an unreleased hold.
  - Alternatively, switch `ready_` to an intrusive list whose node lives inside the `Job`, which is preallocated at `submit` time, on the eco thread, where `bad_alloc` is already guarded.
  - Risk: low.
- **Shares:** The same file and the same commit as the CORE-01 fix; `--child` self-spawn infrastructure with CORE-01/08/14.

### Area CRASH

#### CRASH-01: ::exit(1) with live threads
- **Triage:** LIKELY · LOW (Windows only)
- **Test kind:** none · **Exposes it:** low confidence
- **Test:** No reliable test exists. The hang is Windows-only and nondeterministic: it needs a detached service thread to hold a lock that DLL detach needs. The project marks Windows low priority, so verification may stay open. The best available is a Windows-only E2E that loops `Crash.crash` / `Process.exit 3` while timers or HTTP are active and checks `-- EXIT:` within the harness timeout; it would expose the hang only occasionally. On POSIX, add a regression E2E before refactoring, to pin the current behaviour across the change: test/eco-kernel/src/CrashExitTest.elm calls `Eco.Crash.crash "boom"` with `-- CHECK: Eco crash: boom` and `-- EXIT: 1`, and a twin uses `Process.exit 3` with `-- EXIT: 3`. Both pass today, so no XFAIL is needed. Check test/eco-system/src/ExitWithCodeTest.elm first; it may already cover `Process.exit`.
- **Fix:** Add one runtime helper, e.g. `[[noreturn]] void eco_terminate_process(int code)` in runtime/src/allocator/RuntimeExports.h, with its implementation next to `eco_crash`:
  - **Windows:** flush `std::cout`, `std::cerr` and stdio, then `TerminateProcess` and `Sleep` forever. Move this from runtime/src/codegen/eco_entry.cpp:388-399 and have eco_entry call the helper.
  - **POSIX:** flush, then `std::exit(code)`, so the atexit stats and GC gang shutdown still run.

  Call it from K/Crash.cpp `crash` (:29), K/Process.cpp `exit` (:186), `eco_crash`, and also E/core/DebugExports.cpp `Elm_Kernel_Debug_todo` (`exit(1)`, the same pattern, not listed in the entry), plus UTILS-06's new crash if it lands. Risk: low on POSIX, where behaviour is unchanged. On Windows the build is unverified (Windows code here has gone uncompiled before).
- **Shares:** UTILS-06 should use the same exit helper if it adds a crash.

### Area DEAD

#### DEAD-01: dead namespace APIs divergent from exports
- **Triage:** CERTAIN · LOW
- **Test kind:** static check (build/link) · **Exposes it:** low confidence (nothing can expose dead code; the build only proves the deletion is safe)
- **Test:** No exposing test. Gate: the build on `build` (plus `mac-build`/`win-build` when available, low priority) must still compile and link `ElmKernel_Browser`, `ElmKernel_Debug` and `ElmKernel_Char` and every executable linking them (compiler/CMakeLists.txt:885/945/980). Existing E2E guards for the live exports: Debug.log is used throughout (e.g. test/elm/src/MaybeNothingTest.elm), Char.fromCode in test/elm/src/CharAstralCodeTest.elm. Optional new guard that pins the export semantics the dead `Char::fromCode(int32_t)` would have broken: `test/elm-core/src/CharFromCodeWideIntTest.elm`, `_ = Debug.log "wide" (Char.toCode (Char.fromCode 0x100000041))` and `_ = Debug.log "neg" (Char.toCode (Char.fromCode -1))`, with `-- CHECK: wide: 65533` and `-- CHECK: neg: 65533`. Stock Elm gives 65533 for both (JS `_Char_fromCode` range-checks the full double). Verify with build/toolchain/bin/elm make + node. It passes today, so it needs no XFAIL.
- **Fix:** Delete `elm-kernel-cpp/src/browser/Browser.hpp` and `Browser.cpp`, and remove `src/browser/Browser.cpp` from `ElmKernel_Browser` in elm-kernel-cpp/CMakeLists.txt:187. Keep BrowserExports.cpp, and keep `Json.hpp`, which File.hpp:13 still includes. Delete `src/core/Debug.hpp` and `Debug.cpp`, remove `src/core/Debug.cpp` from `ElmKernel_Debug` (CMakeLists.txt:112), and **remove `#include "Debug.hpp"` from DebugExports.cpp:8**; that file uses nothing from it. In Char.hpp/Char.cpp delete only `fromCode` and `toCode`. Keep `toLower/toUpper/toLocaleLower/toLocaleUpper` (used by CharExports), and update Char.hpp's header comment ("Of the functions below they call only the four case mappers") and the CharExports.cpp:10 comment that mentions `Char::fromCode`. Update design_docs/debug-log-ordering-policy.md:14 and plans/kernel-opt-11-mono-dce-cost-model.md:128/238, which cite the deleted Debug.cpp, as already-stale line refs. Char.cpp is license-pinned (4 rows), so it needs a re-audit (see note 1). Risk: very low. No invariant is touched.
- **Shares:** DEAD-06 (same Char.cpp edit and re-audit; do both together), DEAD-04/DEAD-05 (same DebugExports.cpp edit).

#### DEAD-02: unused <cstdio>
- **Triage:** CERTAIN · LOW
- **Test kind:** static check (build) · **Exposes it:** medium confidence
- **Test:** A compile of every TU on every preset. **Correction to the triage:** `elm-kernel-cpp/src/time/TimeExports.cpp:125-134` uses `FILE`/`fopen`/`fgets`/`fclose` and does not include `<cstdio>` itself. It gets `<cstdio>` only through ExportHelpers.hpp:23, or by accident through `<string>`. A grep over direct includers (elm/eco/system kernels, runtime, test) for stdio identifiers without their own `<cstdio>`/`<stdio.h>` found only this file (the other hits were words like "puts" in comments). libstdc++ may still pull it in through `<string>`, so the Linux build might not catch the omission. libc++ (mac) and MSVC differ.
- **Fix:** Add `#include <cstdio>` to TimeExports.cpp, then delete ExportHelpers.hpp:21 (`#include <cstdio>`). ExportHelpers.hpp is license-pinned (6 rows), so it needs a re-audit. Risk: low, with a compile break on some toolchain if another transitive user was missed. The build shows it immediately.
- **Shares:** -

#### DEAD-03: unused/dead Scheduler.hpp and Platform.hpp
- **Triage:** CERTAIN · LOW
- **Test kind:** static check (build) · **Exposes it:** low confidence (dead file)
- **Test:** A build only. I checked include resolution: the bare `#include "Scheduler.hpp"` lines are all in runtime/src/platform/*.{cpp,hpp} and resolve to the includer's own directory first. eco-kernel's `#include "Process.hpp"` (eco-kernel-cpp/src/eco-kernel/Process.cpp:15, ProcessExports.cpp:4) resolves to its own `eco-kernel/Process.hpp`, not the core one. `ElmKernel_Scheduler`/`_Platform` add `${RUNTIME_INCLUDE_DIR}/platform` to the include path, but no file under src/core uses a bare include of these names. No CMake, script or manifest names the headers.
- **Fix:** Delete `elm-kernel-cpp/src/core/Scheduler.hpp`, `core/Platform.hpp` and `core/Process.hpp`. Do NOT delete `core/Platform.cpp`, `PlatformExports.cpp`, `SchedulerExports.cpp`, `Process.cpp` or `ProcessExports.cpp`, all of which are in CMake source lists. Optionally (separate item) drop the empty `core/Process.cpp` TU that the Process.hpp comment describes, after checking its CMake target still has a source. plans/platform-scheduler-implementation.md:93/664 mention core/Scheduler.hpp historically and need no change. Risk: very low.
- **Shares:** -

#### DEAD-04: DebugExports value_bits unused
- **Triage:** CERTAIN · LOW
- **Test kind:** static check · **Exposes it:** high confidence (as a warning)
- **Test:** A one-off `-Wunused-variable` compile of elm-kernel-cpp/src/core/DebugExports.cpp shows "unused variable 'value_bits'" before and nothing after. No behaviour change, so no E2E is needed. Debug.log output is covered by many existing E2E CHECK lines (e.g. test/elm-core/src/StringWordsLinesTest.elm).
- **Fix:** Delete DebugExports.cpp:30 (`uint64_t value_bits = value.toBits();`). The file is not license-pinned. Risk: none.
- **Shares:** DEAD-05 and DEAD-01 (same file; do one edit).

#### DEAD-05: DebugExports calls exit without <cstdlib>
- **Triage:** CERTAIN · LOW
- **Test kind:** static check (build) · **Exposes it:** low confidence (it builds today; it would only break on a toolchain whose headers stop leaking `exit`)
- **Test:** A build on every preset. The behaviour is identical. If any E2E asserts that `Debug.todo` exits 1, it stays green. None was found that executes `Debug.todo` (test/eco-system/src/PackageLinksTest.elm only references it), so do not add a test just for this.
- **Fix:** Add `#include <cstdlib>` to DebugExports.cpp's includes (:6-12) and change `exit(1)` at :47 to `std::exit(1)`. Keep the unreachable `return HPtr::fromBits(0);`, because the function's declared return type is HPtr. Risk: none.
- **Shares:** DEAD-04, DEAD-01 (same file).

#### DEAD-06: Char.cpp <stdexcept> unused
- **Triage:** CERTAIN · LOW
- **Test kind:** static check (build) · **Exposes it:** low confidence
- **Test:** A build only.
- **Fix:** Delete Char.cpp:3 (`#include <stdexcept>`) in the same edit as DEAD-01's `fromCode`/`toCode` removal. After both, Char.cpp holds only the four case mappers. Re-audit the 4 Char.cpp license pins once for both changes.
- **Shares:** DEAD-01 (same file, same re-audit).

#### DEAD-07: dead isNil(wrap(a)) in append
- **Triage:** CERTAIN · LOW
- **Test kind:** static check (build) + existing E2E · **Exposes it:** low confidence (unreachable code)
- **Test:** Existing guards: test/elm/src/AppendTypeSplitTest.elm (has `Debug.log "listBothEmpty" ([] ++ [])` and the mixed-empty cases) and the other `++` tests. They must stay green after the change. The asserting build (`build` preset keeps asserts) turns the optional assert into a live check on those tests.
- **Fix:** In elm-kernel-cpp/src/core/Utils.cpp `Utils::append` (:784-805), reduce the condition at :796-797 to `if (tagA == Tag_Cons || tagA == Tag_ConsChunk)`. Replace `if (!a && !b) return alloc::emptyString();` (:785) with `assert((a || b) && "Utils::append: both operands are constants; the export returns one of them")`, and add `#include <cassert>` if needed. Keep the `!a` and `!b` single-null returns, which are reachable (`[] ++ xs`, `"" ++ s`). The emptyString return is type-wrong for lists (REP_CONSTANT_001: Nil and EmptyString are the merged Empty constant, so it happens to be bit-identical, but relying on that is fragile). Utils.cpp is license-pinned (9 rows, including Elm.List.sortBy), so it needs a re-audit. Risk: very low.
- **Shares:** -

#### DEAD-08: String foldl/foldr unused
- **Triage:** CERTAIN · LOW
- **Test kind:** static check (build) + existing E2E · **Exposes it:** low confidence (dead code; the latent GC bugs STRING-01/02 inside it cannot be reached from Elm)
- **Test:** No exposing test, since no Elm program reaches these helpers. The live `Elm_Kernel_String_foldl/foldr` stay covered by test/elm/src/CharToCodeFoldStringTest.elm, test/elm-core/src/StringRopeFoldlSliceTest.elm and test/elm-conformance/src/NonBmpStringTest.elm. test/allocator Utf8StringTest.cpp:495-498 uses `StringOps::foldl/foldr` (runtime) and must not be touched.
- **Fix:** Delete `Elm::Kernel::String::foldl` and `foldr` (String.cpp:129-162), the `FoldFunc` typedef (String.hpp:103; it has no other user) and their declarations and comments (String.hpp:14-17, 21, 75, 110-115). Do NOT delete `StringOps::foldl/foldr` or `callFoldClosure`. This closes STRING-01/02 as "removed, not fixed". String.cpp is license-pinned (23 rows), so batch it with DEAD-09, DEAD-10 and every other String.cpp fix into one re-audit. Risk: none.
- **Shares:** DEAD-09, DEAD-10 (same file, one re-audit); closes STRING-01, STRING-02.

#### DEAD-09: consCellChar unused
- **Triage:** CERTAIN · LOW
- **Test kind:** static check · **Exposes it:** high confidence (as a warning)
- **Test:** A one-off `-Wunused-function` compile of String.cpp reports `consCellChar` defined but not used. It reports nothing after the deletion.
- **Fix:** Delete String.cpp:39-47 (the comment and `static u32 consCellChar`). Keep `elemChar` (:52). It goes in the same String.cpp re-audit as DEAD-08. Risk: none.
- **Shares:** DEAD-08, DEAD-10.

#### DEAD-10: words ranges.empty() unreachable
- **Triage:** CERTAIN · LOW
- **Test kind:** E2E (existing, as a guard) · **Exposes it:** low confidence (unreachable branch)
- **Test:** Existing guards: test/elm-core/src/StringZeroLenSplitTest.elm:101 (`String.words "   "`, `"\t\n\u{000D} "`, `""`), test/elm-conformance/src/StringKernelEdgeTest.elm (`String.words ""` is `[""]`) and test/elm-core/src/StringWordsLinesTest.elm. With the assert in an asserting build, these would abort if the reasoning were wrong. Optionally extend StringZeroLenSplitTest with a UTF-16-branch case where non-ASCII whitespace surrounds a word, e.g. `String.words "\u{00A0}a\u{3000}"`. Stock Elm gives `["a"]`; check with elm + node, since JS `\s` includes both characters.
- **Fix:** In elm-kernel-cpp/src/core/String.cpp `words`, replace `if (ranges.empty()) return alloc::listNil();` at :310 (UTF-8 branch) and :355 (UTF-16 branch) with `assert(!ranges.empty());`. The early return at :282-285 already gives `[""]`. This relies on HEAP_032 (UTF-8 forms are all-ASCII) for the byte scan, and on `StringOps::trim` and the scan using the same `isJsWhitespace` set. If the two whitespace sets ever diverge, the assert fires instead of returning a wrong `[]`. It goes in the String.cpp re-audit. Risk: very low.
- **Shares:** DEAD-08, DEAD-09.

#### DEAD-11: static_assert(true) checks nothing
- **Triage:** CERTAIN · LOW
- **Test kind:** static check · **Exposes it:** low confidence (all callers pass literals 2 to 5)
- **Test:** None can fail today. Existing guards for the mapN paths: test/elm/src/RootStackMapNTest.elm and test/elm/src/ListMap5FloatAggregateTest.elm, plus map2/map3 users.
- **Fix:** In elm-kernel-cpp/src/core/ListExports.cpp `kernelListMapN` (:426), delete `static_assert(true, ...)` and add `assert(n_args >= 2 && n_args <= kMaxArgs);` right after `constexpr int kMaxArgs = 5;`. Change the doc comment at :419 from "nothing checks it" to "asserted". ListExports.cpp is license-pinned (11 rows), so batch it with DEAD-12's ListExports.cpp edit into one re-audit. Risk: none.
- **Shares:** DEAD-12 (same file, one re-audit).

#### DEAD-12: dead List.cpp helpers
- **Triage:** CERTAIN · LOW
- **Test kind:** static check (build) + C++ unit (existing) · **Exposes it:** low confidence (dead code)
- **Test:** A build plus the `test` unit binary (`cmake --build build --target test`, run once and tee'd). test/allocator/ListOpsTest.cpp uses only `ListOps::sort`, not `sortBy/sortWith`. E2E guards for the live `Elm_Kernel_List_sortBy/sortWith/fromArray` exports: test/elm/src/SortWithCompareEmptyListTest.elm, NullConsOrderTest.elm and the other sort tests.
- **Fix:** In ListExports.cpp, delete `listToVector` (:110-118) and `getConsHead` (:120-129) and keep `listToVectorU64`. In List.cpp/List.hpp, delete `List::fromArray`, `sortBy` and `sortWith`, their `KeyFunc`/`CmpFunc` typedefs (List.hpp:47, 62) and their declarations (List.hpp:35, 53, 69). Rewrite the List.hpp:12-15 comment and keep `List::cons`, which the exports use. Follow-up: grep confirms `ListOps::sortBy/sortWith` (runtime/src/allocator/ListOps.cpp:496, 521; ListOps.hpp:332-347, with `KeyExtractor`/`Comparator` typedefs) have no other caller once List.cpp's are gone. Delete them too, in the same change or a separate runtime commit, and keep `ListOps::sort`, `reverse`, `maximum` and `minimum`. Both List.cpp (1 row, Elm.List.cons) and ListExports.cpp (11 rows) are license-pinned, so this needs a re-audit, batched with DEAD-11. Risk: low. The only hazard is a Windows-only or test-only user, and the grep covered test/.
- **Shares:** DEAD-11 (ListExports.cpp re-audit).

#### DEAD-14: namespace read_bytes no negative-length check
- **Triage:** CERTAIN · LOW
- **Test kind:** none · **Exposes it:** low confidence (no test can reach it: there are no callers)
- **Test:** None. The only check is that the build and link still succeed after the deletion: `cmake --build build`, then the existing regression gate `TEST_FILTER=elm-bytes cmake --build build --target full`, which also runs the `test/kernel/KernelExportsTest.cpp` K7 case (`Elm_Kernel_Bytes_read_bytes` -> slice). The live export `Elm_Kernel_Bytes_read_bytes` (BytesExports.cpp:579) already rejects `length < 0`. If the user wants that guarded, add one case to KernelExportsTest.cpp next to K7: `Elm_Kernel_Bytes_read_bytes(-1, bb, 0)` must throw `Elm::BytesDecodeFailure`. That case should pass today, so it is a pin, not an XFAIL.
- **Fix:** The whole `Elm::Kernel::Bytes` namespace API is dead, not just `read_bytes`. Bytes.hpp:4 says "Nothing calls it", and a grep finds `Bytes.hpp` included only by Bytes.cpp, with no `Kernel::Bytes::` reference anywhere. Delete `/work/elm-kernel-cpp/src/bytes/Bytes.cpp` and `/work/elm-kernel-cpp/src/bytes/Bytes.hpp`, and remove `src/bytes/Bytes.cpp` from `add_library(ElmKernel_Bytes ...)` in `/work/elm-kernel-cpp/CMakeLists.txt` (about line 196). Do NOT delete: `BytesExports.cpp`, the `Elm_Kernel_Bytes_read_bytes` declaration in `KernelExports.h:823-824`, its `KERNEL_SYM` in `runtime/src/codegen/RuntimeSymbols.cpp:1085`, or the MSVC `/EHs /EHc-` option block on ElmKernel_Bytes. Some design_docs/plans mention Bytes.hpp; they are historical and can stay. Risk: very low. No invariant is involved.
- **Shares:** DEAD-16 (same pattern: delete a dead namespace-API .cpp/.hpp pair and keep the *Exports.cpp; do both in one commit)

#### DEAD-15: Json makeDecoder1i, jsonValueCtor unused
- **Triage:** CERTAIN · LOW
- **Test kind:** static check · **Exposes it:** high confidence (as a warning check)
- **Test:** No behavioural test is possible. Two optional ways to check it: (a) compile JsonExports.cpp with `-Wunused-function` (clang or gcc) and see that both functions are reported, and that the warning is gone after the fix; (b) `grep -c 'makeDecoder1i\|jsonValueCtor' /work/elm-kernel-cpp/src/json/JsonExports.cpp` is 2 today and must be 0 afterwards. Regression gate: `TEST_FILTER=elm-json cmake --build build --target full`.
- **Fix:** In `/work/elm-kernel-cpp/src/json/JsonExports.cpp`, delete `static u16 jsonValueCtor` (around :725-733, with its comment) and `static uint64_t makeDecoder1i` (around :929-939, with its comment). Keep the neighbours: `makeDecoder1`/`makeDecoder2`, and the "JSON Value ADT - Query Helpers" section header if other helpers still sit under it (check first; delete the header if the section ends up empty). Risk: none.
- **Shares:** -

#### DEAD-16: File and Browser namespace APIs unused
- **Triage:** CERTAIN · LOW
- **Test kind:** none · **Exposes it:** low confidence (nothing to expose; it is a build/link check only)
- **Test:** None. Gate: `cmake --build build` links. Then `TEST_FILTER=elm-html cmake --build build --target full`, plus any file/browser E2E suites (`test/elm-html`, and `test/kernel/VirtualDomKernelTest.cpp` inside the `test` binary), to confirm the exports still work.
- **Fix:** Delete `/work/elm-kernel-cpp/src/file/File.cpp`, `/work/elm-kernel-cpp/src/file/File.hpp`, `/work/elm-kernel-cpp/src/browser/Browser.cpp` and `/work/elm-kernel-cpp/src/browser/Browser.hpp`. In `/work/elm-kernel-cpp/CMakeLists.txt`, remove `src/browser/Browser.cpp` from `ElmKernel_Browser` (:187) and `src/file/File.cpp` from `ElmKernel_File` (:216). Keep `BrowserExports.cpp` and `FileExports.cpp`. Also delete the comment at BrowserExports.cpp:5 that says they "do not use `Browser.hpp`", or reword it. Do NOT touch `/work/eco-kernel-cpp/src/eco-kernel/File.cpp`, `File.hpp` or `FileExports.cpp`: that is the separate, live eco/kernel File module, and its FileExports.cpp includes its own local `File.hpp`. Risk: very low. Before deleting, re-run a grep for `File.hpp` and `Browser.hpp` under `elm-kernel-cpp` and `test` to make sure only the eco-kernel include matches.
- **Shares:** DEAD-14 (same cleanup pattern, same CMakeLists.txt edit)

#### DEAD-17: s_streamHandles written never read
- **Triage:** CERTAIN · LOW
- **Test kind:** none · **Exposes it:** low confidence (the growth is one int pair per piped spawn and cannot be observed from Elm)
- **Test:** None. Regression gate: the eco-kernel Process E2E tests that spawn with stdin "pipe" (`TEST_FILTER=eco-kernel cmake --build build --target full`, and the eco-system suites that use spawn and stdin piping, such as `StreamPipeStdioTest`).
- **Fix:** In `/work/eco-kernel-cpp/src/eco-kernel/Process.cpp`, delete the comment and declaration at :29-31 (`static std::unordered_map<int64_t, int> s_streamHandles;`) and the write at :105 (`s_streamHandles[handleId] = child.stdinFd;`). Keep `handleId` and `stdinMaybe = justKind(unboxedInt(handleId), 1)`, since the handle id IS the fd. `unordered_map` appears in the file only in the include and this declaration, so remove `#include <unordered_map>` too. Risk: none. The fd lifetime is managed elsewhere and does not depend on the map.
- **Shares:** -

#### DEAD-18: redundant POST assignments
- **Triage:** CERTAIN · LOW
- **Test kind:** E2E · **Exposes it:** low confidence (this is a regression pin, not an exposing test; behaviour is already correct)
- **Test:** Optional pin for the behaviour the comment protects. A body-less POST through eco/kernel Http `fetch` must reach the test server with `Content-Length: 0` and not be refused with 411. First check whether an existing test already does a POST with an empty body: grep `test/eco-kernel/src` and `test/eco-system/src` for the eco Http fetch with method "POST". If none does, add `/work/test/eco-kernel/src/HttpEmptyPostTest.elm`: it POSTs with an empty body to the test server's echo or headers endpoint (see TestHttpServer.hpp) and prints the status, with `-- CHECK: status: 200`. This is eco-specific behaviour, so there is no stock-Elm comparison. It must pass both before and after the deletion, so no XFAIL.
- **Fix:** In `/work/eco-kernel-cpp/src/eco-kernel/Http.cpp:368-372`, delete the `if (method == "POST") { req.body = ""; req.contentType = ""; }` block and replace the two-line comment with one line: "A body-less POST/PUT/PATCH gets `Content-Length: 0` from HttpService (CURLOPT_POSTFIELDSIZE 0)." That behaviour lives in `runtime/src/platform/HttpService.cpp:257-262`; do not change it. Risk: none (`Request` default-constructs both strings empty).
- **Shares:** -

#### DEAD-19: Runtime scanner unnamed
- **Triage:** CERTAIN · LOW
- **Test kind:** static check · **Exposes it:** high confidence
- **Test:** New `/work/test/scripts/check-scanner-names.py`, modelled on `check-root-bounded.py`, scanning the same DIRS (runtime/src, elm-kernel-cpp/src, eco-kernel-cpp/src, system-kernel-cpp/src). For each `addExternalRootScanner(` call outside RootSet.hpp/.cpp, it finds the matching close paren across lines and fails unless the last argument is a string literal. Wire it into the `check` and `full` targets in `/work/CMakeLists.txt` next to check-root-bounded.py (:1493, :1574). Today it fails on five sites, not three: Runtime.cpp:92, MVar.cpp:308, HttpExports.cpp:428, plus runtime/src/platform/Scheduler.cpp:57 and runtime/src/platform/PlatformRuntime.cpp:99, which also pass no name. The named sites are TimeEffectManager ("time-effects"), RuntimeExports.cpp:4425 ("list-scratch") and PortRuntime ("port-runtime"). Run the script once by hand before the fix to see it fail, rather than marking it XFAIL. A C++ unit test that reads `getExternalRootScannerNames()` is possible but fragile, because unit tests reset the RootSet; the static check is the better tool. Note that RootSet.cpp:148-153 already replaces "unnamed" with `unnamed@<symbol or address>` through dladdr, so the impact is lower than the entry says. In a static or no-`-rdynamic` binary the label is usually just an address.
- **Fix:** Pass a static string literal at all five sites: `"eco-runtime-state"` (eco-kernel Runtime.cpp), `"eco-mvar"` (MVar.cpp), `"http-effects"` (HttpExports.cpp), `"scheduler"` (Scheduler.cpp) and `"platform-runtime"` (PlatformRuntime.cpp). The name must have static lifetime (RootSet.hpp:345), which literals do. This touches runtime/ GC diagnostics only, with no HEAP_* behaviour change. Risk: none. Check whether any GC event-log consumer or test matches on an `unnamed@...` label (grep test/ and benchmarks/ for "unnamed").
- **Shares:** -

#### DEAD-20: TaskEffectManager duplicates encodeHP/decodeHP
- **Triage:** CERTAIN · LOW
- **Test kind:** none · **Exposes it:** low confidence (the copies behave the same; there is nothing to expose)
- **Test:** None. Regression gate: `TEST_FILTER=elm-http`, `TEST_FILTER=elm-time` and `TEST_FILTER=elm-core` runs of `--target full` (one run with no filter covers all three).
- **Fix:** Delete the local `static inline encodeHP`/`decodeHP` pairs in `/work/elm-kernel-cpp/src/core/TaskEffectManager.cpp:33-45`, `/work/elm-kernel-cpp/src/http/HttpEffectManager.cpp:58-70`, `/work/elm-kernel-cpp/src/http/HttpExports.cpp:224-235` and `/work/elm-kernel-cpp/src/time/TimeEffectManager.cpp:57-68`. Replace their uses with `Export::encode`/`Export::decode`: `sed -i 's/\bencodeHP(/Export::encode(/g; s/\bdecodeHP(/Export::decode(/g'` on those four files only. Include `"../ExportHelpers.hpp"` where it is missing; HttpEffectManager.cpp already includes it, so check the other three. `Export::` resolves under `using namespace Elm::Kernel`, otherwise spell `Elm::Kernel::Export::`. Do NOT touch `runtime/src/platform/Scheduler.cpp`, which has its own `encodeHP` in runtime/ (a different layer that cannot include elm-kernel-cpp's ExportHelpers), unless the user wants that too. Risk: very low, compile-only. The behaviour is byte-identical.
- **Shares:** -

#### DEAD-21: HttpEffectManager onSelfMsg double-roots
- **Triage:** CERTAIN · LOW
- **Test kind:** E2E · **Exposes it:** low confidence (nothing is broken; this is a regression pin for the deletion)
- **Test:** Use the existing `/work/test/elm-http/src/HttpTrackProgressTest.elm` (`-- CHECK: track: True`) and `HttpTrackChunkedTest.elm`, which drive `httpOnSelfMsgEvaluator` through `Http.track`. Run them in the normal tree (`TEST_FILTER=HttpTrack cmake --build build --target full`). Ideally also run them once in `build-validate` (ECO_HEAP_VALIDATE) with a GC-pressure heap config, raising `ECO_TEST_TIMEOUT_SECONDS`, so that a collection happens inside the `toMsg`/`sendToApp` loop. The point is to show that `router` and `progress` stay correctly rooted by `topRoots`/`msgRoots` alone. Expected: they pass both before and after. No XFAIL.
- **Fix:** In `/work/elm-kernel-cpp/src/http/HttpEffectManager.cpp:249-250`, delete `Elm::StackRootGuard walkRoots(&router, &progress);` and change the comment above it to say that `router` (topRoots) and `progress` (msgRoots) are already rooted across the Elm calls in the loop. Keep `topRoots`, `msgRoots`, `iterRoots` and `sg` unchanged. Guard destruction order (LIFO) is unaffected: walkRoots sits between msgRoots and the loop guards, so removing it does not reorder the others. Related invariants: the HEAP_* root-stack rules. Run `check-root-bounded.py`, which is wired into `full`; the guard is outside the loop, so it is unaffected. Risk: low.
- **Shares:** -

#### DEAD-22: kEndedMarker unused, literal hard-coded
- **Triage:** CERTAIN · LOW
- **Test kind:** static check · **Exposes it:** medium confidence (it guards the protocol byte; there is no current bug to expose)
- **Test:** After the fix, add compile-time `static_assert`s next to the shared constants, e.g. `static_assert(kWritableClosed[0] == kEndedMarker[0]);` and the same for `kTerminated`. Use `constexpr char[]` arrays, or `std::string_view` constants, so the asserts are constant expressions. Behavioural regression gate: the eco-system stream suites that decode `Stream.Closed` and ended reasons (`StreamPipeToTest`, `StreamPipeErrorTest`, `WebSocketCloseOrderTest`, `StreamPipeStdioTest`): `TEST_FILTER=eco-system cmake --build build --target full`, plus `eco-system-core-test`.
- **Fix:** In `/work/system-kernel-cpp/src/eco-system/Core/Core.hpp:126`, define the marker as a macro-free literal that can be concatenated, e.g. `#define ECO_ENDED_MARKER "\x02"` (or keep `inline constexpr char kEndedMarker[] = "\x02";`). Add `inline constexpr char kWritableClosed[] = ECO_ENDED_MARKER "WritableStream is closed";` there. Literal concatenation is safe: escapes are resolved before concatenation, so `"\x02" "W..."` does not form a longer hex escape. Delete the duplicate `kWritableClosed` in `Stream/Stream.cpp:61` and `Stream/StreamPipe.cpp:50`, and build `kTerminated` (Stream.cpp:63) the same way. Keep `kTerminated` file-local in Stream.cpp. Alternative, smaller fix: delete `kEndedMarker` and leave the literals as they are; the user should choose. The reason text must stay byte-identical, because `Stream.Internal.decodeReason` (Elm side) parses it. Risk: low.
- **Shares:** DEAD-23 (both are Stream.cpp anonymous-namespace cleanup; one commit)

#### DEAD-23: describeErrno unused
- **Triage:** CERTAIN · LOW
- **Test kind:** static check · **Exposes it:** high confidence (as a warning check)
- **Test:** Compiling Stream.cpp with `-Wunused-function` reports it, since it is in an anonymous namespace. After the fix, `grep -rn describeErrno /work/system-kernel-cpp` returns nothing. Gate: build plus `eco-system-core-test`.
- **Fix:** Delete `describeErrno` and its doc comment at `/work/system-kernel-cpp/src/eco-system/Stream/Stream.cpp:90-95`. Keep `errnoFailureReason` (Core.hpp:119) and `errnoName`. Check that `<cstring>` (`std::strerror`) is still used in Stream.cpp before dropping the include; otherwise leave the include alone. Risk: none.
- **Shares:** DEAD-22

#### DEAD-24: Conn isTls never read
- **Triage:** CERTAIN · LOW
- **Test kind:** none · **Exposes it:** low confidence (it is a compile check: removing the field makes any hidden reader fail to compile)
- **Test:** None. Removing the field is its own check, because any reader would stop compiling. Gate: build, then `eco-system-core-test` and the TLS and WebSocket E2E tests (`TEST_FILTER=eco-system`, which covers `wss`/TLS tests and `Tls.info`, the latter reading the live `ConnEntry::isTls`).
- **Fix:** Remove `bool isTls = false;` from `ConnectSpec` in `/work/system-kernel-cpp/src/eco-system/Socket/Conn.hpp:147`. Remove the two writes to it: `spec.isTls = true;` at `Tls/Tls.cpp:190` (where `spec` is a `ConnectSpec`) and `cs.isTls = spec_.isTls;` at `WebSocket/WsHandshake.cpp:440`. Do NOT touch the live same-named fields: `ConnEntry::isTls` (SocketTables.hpp:84; read at Tls.cpp:283, written at SocketTables.cpp:263), the WsHandshake dial spec's `isTls` (WsHandshake.hpp:176; written at WebSocket.cpp:165 and read at WsHandshake.cpp:440, 492 and 519; it stays live through 492/519), and `WsEvents::isTls` (WsEvents.hpp:79). No test in test/eco-system-core references `ConnectSpec::isTls` (checked). Risk: very low.
- **Shares:** -

#### DEAD-25: hasBufferedRead never called
- **Triage:** CERTAIN · LOW
- **Test kind:** none · **Exposes it:** low confidence (the method is dead, so there is nothing to expose)
- **Test:** None. Gate: build and `eco-system-core-test`, plus the TLS E2E tests. These confirm that buffered TLS plaintext is still delivered through the `setProtocol` and `updateInterest` paths (Conn.cpp:497-498 and 601-603).
- **Fix:** Delete `virtual bool hasBufferedRead() const { return false; }` and its comment at `/work/system-kernel-cpp/src/eco-system/Socket/Conn.hpp:106-108`, and the override at `/work/system-kernel-cpp/src/eco-system/Tls/TlsTransport.cpp:216-218`. ALSO delete the `override` in the test transport at `/work/test/eco-system-core/EcoSystemCoreTest.cpp:2120` (`bool hasBufferedRead() const override { return !buf_.empty(); }`). The triage missed that one, and without its removal the `override` stops `eco-system-core-test` compiling. `plans/eco-system-sockets.md` (status: done) describes `hasBufferedRead` at :240, :255 and :642. Either add a one-line deviation note there, bumping `updated:`, or leave the plan as history. Alternative: keep the method as a documented debug hook; the choice is cosmetic and up to the user. Risk: low once the test override is removed too.
- **Shares:** -

#### DEAD-26: Listener openConnections no caller
- **Triage:** CERTAIN · LOW. **Re-triage: the claim is WRONG, so do not delete.** The getter has callers in the unit tests: test/eco-system-core/EcoSystemCoreTest.cpp:2385 and :2396 (the max-connections credit test reads `l->openConnections()` and checks `open == 1`, then waits for `n == 0`). The triage grep covered only system-kernel-cpp and missed test/.
- **Test kind:** none · **Exposes it:** n/a (there is no bug)
- **Test:** No new test. The existing EcoSystemCoreTest max-connections case already uses the accessor. If it were deleted, the `stress-test`/`test` build of test/eco-system-core would fail to compile, so the build itself is the guard.
- **Fix:** No change. Optionally reword the doc comment at S/Socket/Listener.hpp:96 to say it is a test/diagnostic accessor. Close the entry as "not dead (used by tests)".
- **Shares:** -

#### DEAD-27: SocketTables resumeToken unused
- **Triage:** CERTAIN · LOW
- **Test kind:** static check · **Exposes it:** high confidence
- **Test:** Check with `grep -rn "resumeToken(" /work/system-kernel-cpp /work/test`. The only hit should be the definition at S/Socket/SocketTables.cpp:65; `ChildJob::resumeToken` is a field, not a call. As a build check, `cmake --build build` with `-Wunused-function` (clang flags unused functions in an anonymous namespace) should warn on it today and stay clean afterwards. No XFAIL.
- **Fix:** Delete `resumeToken(uint64_t, HPointer&)` and its comment (S/Socket/SocketTables.cpp:63-71). Keep `resumeFail` and the other resume helpers in the same anonymous namespace. The risk is none: the symbol has internal linkage, so if it compiles it links.
- **Shares:** Same cleanup commit as DEAD-29, DEAD-36, DEAD-37, DEAD-40 (Socket/WebSocket dead-code sweep).

#### DEAD-29: socketNotImplementedTask/socketDoneTask unused
- **Triage:** CERTAIN · LOW
- **Test kind:** static check · **Exposes it:** high confidence
- **Test:** Run `grep -rn "socketNotImplementedTask\|socketDoneTask\|notImplementedBody\|doneBody" /work --include=*.cpp --include=*.hpp --include=*.elm --include=*.js`. The only hits should be S/Socket/Socket.cpp:34-46 and :180-182 and S/Socket/Socket.hpp:45,49; I checked that test/ has none. The link check after deletion is a full `cmake --build build` plus the eco-system-core test binary build.
- **Fix:** Delete these from S/Socket/Socket.cpp: `notImplementedBody` (:34-39), `doneBody` (:41-46), the "Stubs (Socket.hpp)" banner, and the two makers (:180, :182). Delete their declarations and doc comments at S/Socket/Socket.hpp:43-49. Keep the "Socket.hpp helpers" section at Socket.cpp:176 and everything that follows it, such as `ListenFd`. If deletion leaves `failFErr`/`succeedUnit` includes unused, check whether other code still needs them before removing any includes. Risk: none.
- **Shares:** DEAD-40 (the same ENOTSUP stub pattern in WebSocket); the same sweep commit as DEAD-27.

#### DEAD-30: SocketManager mask constants unused
- **Triage:** CERTAIN · LOW (drift risk, no current bug)
- **Test kind:** static check · **Exposes it:** high confidence (for the drift; there is no behaviour bug)
- **Test:** Add `static_assert`s next to the constants in S/Socket/SocketManager.hpp that tie each mask to its layout. If the masks are built from `alloc`'s kind helpers, or written as `(1u << 0) | (1u << 4)` with a REP_HEAP_002 comment, the literals become derivations. After the fix the grep `grep -n "0x11\|0x5)\|, 0)\|0x1)" S/Socket/SocketTables.cpp` near `buildEndpoint`/`buildConnT` should find no bare mask literals. Behaviour is already covered by the existing eco-system socket E2E tests (test/eco-system ConnT/endpoint decoding), which must stay green. No XFAIL.
- **Fix:** In S/Socket/SocketTables.cpp, make these replacements:
  - `buildEndpoint` (:279): `0x11` becomes `EP_T_MASK`.
  - `buildConnT` (:295): `0x5` becomes `CONN_IDS_MASK`.
  - `buildConnT` (:298): `0` becomes `CONN_ENDPOINTS_MASK`.
  - `buildConnT` (:299): `0x1` becomes `CONN_T_MASK`.

  Include SocketManager.hpp if it is not already included. Drop the "masks mark ..." comment at :284 or point it at the constants. Values are unchanged, so MLIR and the heap layout are identical. Invariant: REP_HEAP_002. Risk: none.
- **Shares:** DEAD-31 and DEAD-32 (the same "named mask vs literal" pattern; one commit).

#### DEAD-31: UdpManager masks unused
- **Triage:** CERTAIN · LOW
- **Test kind:** static check · **Exposes it:** high confidence (drift only)
- **Test:** After the fix, `grep -n "DGRAM_T_MASK\|DGRAM_FROM_MASK" S/Socket/Udp.cpp` must find both uses. The existing UDP E2E/unit tests (the datagram receive path, test/eco-system and EcoSystemCoreTest UDP cases) must stay green.
- **Fix:** In S/Socket/Udp.cpp `buildDgramT` (:419-420), use `DGRAM_FROM_MASK` in place of `0x4` and `DGRAM_T_MASK` in place of `0`; include UdpManager.hpp if needed. In S/Socket/UdpManager.hpp:46-51, delete the "Nothing reads it; `buildDgramT` writes the literal ..." sentences. Invariant: REP_HEAP_002. Risk: none, because the values are identical.
- **Shares:** DEAD-30 and DEAD-32 (the same commit).

#### DEAD-32: SPEC_TRIPLE_MASK unused
- **Triage:** CERTAIN · LOW
- **Test kind:** static check (debug assert) · **Exposes it:** medium confidence (it catches a future layout drift, not a current bug)
- **Test:** No new test. If the assert variant is chosen, the existing ChildProcess E2E tests (test/eco-system ChildProcess spawn tests) run the decode path in the default `build` preset, which keeps asserts on (-UNDEBUG), so a wrong layout would abort there.
- **Fix:** I recommend keeping the constant and putting it to use. At S/ChildProcess/ChildProcessManager.cpp:85, after `Tuple3* t = asTuple3(tripleHP);`, add `assert(t->header.unboxed == SPEC_TRIPLE_MASK && "spec triple layout drifted");`, and delete the `// mask SPEC_TRIPLE_MASK` comment. Note that `Header.unboxed` is a 6-bit field holding the three 2-bit kinds (runtime/src/allocator/Heap.hpp:131,155), so 0x14 compares directly. The alternative is to delete the constant (SPEC_TRIPLE_MASK at ChildProcessManager.hpp:51-53) and the comment. Invariant: REP_HEAP_002. Risk is low: if compiler codegen ever stored Int fields boxed here, the assert would fire, and that would be a real REP violation surfaced rather than a false alarm.
- **Shares:** DEAD-30 and DEAD-31 (the same commit).

#### DEAD-34: WsHandshake headDone ok/err unused
- **Triage:** CERTAIN · LOW
- **Test kind:** none · **Exposes it:** n/a
- **Test:** None. Compilation and the existing WebSocket dial E2E tests (test/eco-system WebSocket client tests) cover the only caller.
- **Fix:** Change the signature to `void headDone(Conn& c, HttpHead head);` in S/WebSocket/WsHandshake.hpp:222 and in the definition at S/WebSocket/WsHandshake.cpp:504. Change the call at :353 to `job_->headDone(c, std::move(head));`. Leave the `fail(...)` path at :345-347 alone. Also check the HPP comment at :206 that lists `headDone`; its name is unchanged. Risk: none, because it is a member of an internal class with one caller.
- **Shares:** -

#### DEAD-35: WsHandshakeEntry::server never read
- **Triage:** CERTAIN · LOW
- **Test kind:** C++ unit · **Exposes it:** medium confidence
- **Test:** An E2E test cannot expose this. The Elm wrapper hard-codes role 0 for dial and role 1 for accept (WebSocket.elm:1117-1119, :1408-1416), and `kReject` only gets server Upgrades, so well-typed Elm cannot produce a mismatch (WS-20 is WEAK). Instead, add a case to test/eco-system-core/EcoSystemCoreTest.cpp:
  1. Register a client handshake (dial path, `server = false`) and call the `wsOpen` kernel body with role 1 (or `wsReject`) on its hsId, building the payload in C++ as the existing kernel-body tests there do.
  2. Expect the task to fail with EINVAL.
  3. Also expect the reverse (a server hsId opened with role 0) to fail.

  Today both cases are accepted. Mark the case XFAIL with test/XfailGuard.hpp until the fix lands, and it then XPASSes.
- **Fix:** Implement the WS-20 check instead of deleting the field. In S/WebSocket/WebSocket.cpp `wsOpenBody` (role read at :412), fail with `failFErr("EINVAL", "role does not match handshake")` when `role != (entry.server ? 1 : 0)`. In `wsRejectBody` (:544-609), fail EINVAL unless `entry.server`. Both checks must run before anything is emplaced (before :468), so the failure path does not hit the WS-21 leak. A simpler option is to derive the role from `entry.server` and drop it from the Elm payload; that changes the kernel ABI, the WebSocket.elm wrapper and the eco/system stubs (memory: the kernel API is authoritative, so keep src-xhr in sync), so I prefer the check. Risk is low: the check is defence in depth and well-typed programs never hit it.
- **Shares:** WS-20 (the same fix and test); keep it in mind next to WS-21 (failure path ordering).

#### DEAD-36: onClosed resumed unused
- **Triage:** CERTAIN · LOW
- **Test kind:** none · **Exposes it:** n/a
- **Test:** None. The existing WebSocket close E2E tests (closed-waiter resume) cover the function.
- **Fix:** In S/WebSocket/WsTables.cpp `onClosed`, delete `bool resumed = false;` (:212), `resumed = true;` (:225) and `(void)resumed;` (:229). Keep `Scheduler::instance().drain()` after each resume and keep `return false;` as documented at :200-201. Risk: none.
- **Shares:** The sweep commit with DEAD-27, DEAD-29, DEAD-37, DEAD-40.

#### DEAD-37: Http2Client closeCode_ never read
- **Triage:** CERTAIN · LOW
- **Test kind:** none · **Exposes it:** n/a
- **Test:** None. Compilation and the existing WebSocket-over-h2 tests are enough.
- **Fix:** Delete the member `uint32_t closeCode_` at S/WebSocket/Http2Client.hpp:166 and its writes at Http2Client.cpp:383 (`streamGone`) and :456 (`onCloseAll`). Keep the `port->streamReset(code)` calls at :390 and :459, and do not touch `WsProtocol::closeCode_` (WsProtocol.hpp:503, which WsProtocol.cpp:1152 reads). Risk: none.
- **Shares:** The sweep commit with DEAD-27/29/36/40.

#### DEAD-39: kDefaultDrainMs duplicates WsCore::kDrainMs
- **Triage:** CERTAIN · LOW
- **Test kind:** static check · **Exposes it:** high confidence (all callers pass kDrainMs)
- **Test:** `grep -rn "portCloseGraceful(" /work/system-kernel-cpp /work/test` should find only WsProtocol.cpp:232, 239, 1052 and 1083, all passing `kDrainMs`, plus the two override declarations (WsProtocol.hpp:150 is the pure virtual and :545 is the other override, H2StreamPort.hpp:133). No behaviour test is needed.
- **Fix:** In S/WebSocket/H2StreamPort.cpp, delete `kDefaultDrainMs` (:25-26). At :140, use `assert(drainMs > 0 && "portCloseGraceful: callers pass WsCore::kDrainMs");` with `reactor().nowMs() + drainMs`. Alternatively, keep the fallback but write it as `WsCore::kDrainMs`. Check that the other `portCloseGraceful` override (WsProtocol.hpp:545) treats `drainMs <= 0` the same way, so the two stay consistent. Risk: none.
- **Shares:** -

#### DEAD-40: wsNotImplementedBody dead
- **Triage:** CERTAIN · LOW
- **Test kind:** static check · **Exposes it:** high confidence
- **Test:** `grep -rn "wsNotImplementedBody" /work` should find only S/WebSocket/WebSocket.cpp:233 and WebSocket.hpp:50; I checked that test/ has none. Because the function is declared in a public header, rebuild everything (`cmake --build build` plus the test/eco-system-core binary) after the deletion to prove there is no out-of-tree user.
- **Fix:** Delete the definition at S/WebSocket/WebSocket.cpp:233-237 and the declaration and doc comment at WebSocket.hpp:48-50. Keep the "Kernel bodies" section banners and every real body. Risk: none.
- **Shares:** DEAD-29 (the same stub pattern); the sweep commit with DEAD-27/36/37.

#### DEAD-41: httpServerNotImplementedBody dead
- **Triage:** CERTAIN · LOW
- **Test kind:** static check · **Exposes it:** high confidence
- **Test:** `grep -rn "httpServerNotImplementedBody" /work --exclude-dir=build --exclude-dir=.git` currently finds only S/HttpServer/HttpServer.cpp:371 and HttpServer.hpp:79, plus the two bug-list .md files. I verified that it has no hits in test/, in any .elm/.js file, or in the kernel-license CSVs. After the deletion, the link check is `cmake --build build` plus building the `test` and `stress-test` binaries by name, since they are not in `all`. No XFAIL is needed.
- **Fix:** Delete the definition at S/HttpServer/HttpServer.cpp:371-375 and the declaration with its doc comment at HttpServer.hpp:76-79 ("Returns a Task that fails with ENOTSUP ... Nothing in the project binds this body"). Keep everything around it, in particular the WebSocket handshake declaration that follows at :81. If `failFErr` has no other user in HttpServer.cpp afterwards, the include it came from may still be needed by other code, so leave the includes alone. Risk: none.
- **Shares:** DEAD-40 (`wsNotImplementedBody`, S/WebSocket/WebSocket.cpp:233 and .hpp:50, the same pattern) and DEAD-NEW-1/DEAD-29. Do all of them in one "ENOTSUP stub sweep" commit.

#### DEAD-43: writeFaceShutdown branch unreachable
- **Triage:** CERTAIN · LOW
- **Test kind:** C++ unit · **Exposes it:** medium confidence (there is no behaviour bug; the test checks that the new assert holds on the reachable paths)
- **Test:** Extend test/eco-system-core/EcoSystemCoreTest.cpp next to the Conn protocol tests (`testConnProtocolHandoff`, :2196). Add `testFaceCloseWriteThenAbort`, which covers the two paths the analysis names:
  - (a) Open a Conn over a socketpair (`openConn`). Request a close-write while there are queued writes and the peer does not read: fill the peer's buffer, so that `Conn::shutdownWrite` defers its callback onto `shutDone_`. Then abort the Conn or run `onCloseAll`, so that `writeFaceShutdown` runs `cancelWrites(ECANCELED)`.
  - (b) The same sequence with an empty queue, so the shutdown callback runs synchronously.

  Check that the close Task is completed exactly once, with ECANCELED in (a) and 0 in (b). With the fix in place, the `assert(!closePending_)` runs on both paths. The default `build` preset keeps asserts on (-UNDEBUG), so a broken premise aborts the test. Run it through the `test` binary. No XFAIL: it must pass both before and after the change.
- **Fix:** In S/Socket/FaceProtocol.cpp `writeFaceShutdown` (:241-244), replace the `if (closePending_) { ... postClose(...) }` block with `assert(!closePending_ && "cancelWrites completes a pending close via finishShutdown")`. Update the comment to cite the two paths: the synchronous `closeDone`, and `failOutbound -> finishShutdown` (Conn.cpp:605-620). Alternatively, keep the branch and only reword the comment to "unreachable today; kept as defence". This is a style choice for the user. No invariants are touched. Risk: low. In an NDEBUG release build the assert disappears, so if the premise is ever wrong the close Task would stay parked, where today the branch completes it. A safer variant keeps the branch and adds the assert before it.
- **Shares:** -

#### DEAD-44: CTOR_TIME_EVERY defined twice
- **Triage:** CERTAIN · LOW
- **Test kind:** static check · **Exposes it:** high confidence (for the duplication; there is no behaviour bug today)
- **Test:** After the fix, `grep -rn "CTOR_TIME_EVERY *=" /work/elm-kernel-cpp/src` must find exactly one definition. The behaviour is already covered by test/elm-time/src/TimeEveryTest.elm (the tick count over `Time.every`), which must stay green under `cmake --build build --target full` (TEST_FILTER=time). Optional fail-first check: change one copy to 1 locally and see TimeEveryTest fail. That shows the existing E2E guards the agreement, but it is not a committed test.
- **Fix:** Move `static constexpr u16 CTOR_TIME_EVERY = 0;` into a header that both TUs include. elm-kernel-cpp/src/time/Time.hpp exists, but it holds assert-stubs for the `Elm::Kernel::Time` namespace, so a new small `time/TimeCtors.hpp` (`inline constexpr u16 CTOR_TIME_EVERY = 0;`) is cleaner. Include it from TimeExports.cpp and TimeEffectManager.cpp, and delete both local definitions: TimeExports.cpp:47-48 with its "nothing checks the two agree" comment, and TimeEffectManager.cpp:54. Update the reference in the doc comment at KernelExports.h:747 if it names the file. Risk: none, because the value is unchanged.
- **Shares:** -

#### DEAD-45: 0xFFFD shared by CONSTANT_TAG and CTOR_Router
- **Triage:** CERTAIN · LOW
- **Test kind:** static check · **Exposes it:** high confidence (a compile-time guard against the latent trap)
- **Test:** Add `static_assert`s that the reserved ctor values are pairwise distinct: `CTOR_Router != CONSTANT_TAG`, plus `CTOR_StackFrame` (0xFFFE) and `CTOR_DICT_RBNODE` (0xFFFF). Today the assert `CTOR_Router != CONSTANT_TAG` fails to compile, which exposes the collision; it passes after the fix. Optionally extend test/scripts/check-ctor-tags.sh (it already compares `constantTag` across CtorTag.elm, Heap.hpp and EcoToLLVMInternal.h:353) with a "no runtime-private ctor equals CONSTANT_TAG" check. The existing platform E2E tests (every Platform.worker program builds a router at PlatformRuntime.cpp:195) must stay green under `--target full`.
- **Fix:** Change `CTOR_Router` in runtime/src/allocator/HeapHelpers.hpp:1940 to 0xFFFC; I checked that the value is unused anywhere in runtime/, the kernels and compiler/. Put the static_asserts next to it, after including Heap.hpp for CONSTANT_TAG. Update the comments that state the coincidence: HeapHelpers.hpp:1938-1939, RuntimeExports.h:769 ("`CONSTANT_TAG` is also `CTOR_Router`'s value") and E/core/Utils.cpp:36-37. Record the reserved range 0xFFFC-0xFFFF in one place, the Heap.hpp:386 comment block. Check that the compiler never emits a ctor tag of 0xFFFC; compiler tags are small indices, and Custom ctor fields allow up to 2040 (wide objects). No MLIR change is expected, since the router is runtime-only and nothing switches on its tag (CGEN/REP invariants unaffected). Risk: very low.
- **Shares:** -

#### DEAD-NEW-1: socketNotImplementedTask / notImplementedBody dead
- **Triage:** CERTAIN · LOW
- **Test kind:** static check · **Exposes it:** high confidence
- **Test:** `grep -rn "socketNotImplementedTask\|notImplementedBody" /work --exclude-dir=build --exclude-dir=.git` currently finds only S/Socket/Socket.cpp:34-39 and :180, S/Socket/Socket.hpp:43-45 (and `wsNotImplementedBody` for DEAD-40). After the deletion, the link check is a full `cmake --build build` plus the `test`/`stress-test` binaries.
- **Fix:** This is a **duplicate of DEAD-29**, which already plans deleting `notImplementedBody`, `doneBody`, both makers and their Socket.hpp declarations. Do it once, under DEAD-29: delete Socket.cpp:34-39 (`notImplementedBody` and its comment), :180 (`socketNotImplementedTask`) and Socket.hpp:43-45. Do NOT delete `ListenFd` or the other "Socket.hpp helpers" after :176. Risk: none.
- **Shares:** DEAD-29 (the same deletion), DEAD-40 and DEAD-41 (the same sweep commit).

### Area DEBUG

#### DEBUG-01: Debug.todo exits without stderr/eco_crash
- **Triage:** CERTAIN · LOW
- **Test kind:** C++ unit · **Exposes it:** high confidence
- **Test:** An E2E program cannot show it.
  - In "process" mode (any test with `-- EXIT:`), the harness installs its own leaked stream plus an atexit hook (test/ElmE2ETestBase.hpp:813-913), which publishes the stream on `std::exit`, so the message survives there.
  - In "test" mode, the child's `exit(1)` fails the test regardless.
  - Instead, add a spawned-self unit test to the `test` binary:
    - In test/main.cpp `runIsolatedChild` (:722), add a tiny kind, e.g. `debug-todo`. It initializes the runtime, calls `eco_set_output_stream(new std::ostringstream)` (the state of the JIT runner's `startOutputCapture`), allocates the Elm String "boom", and calls `Elm_Kernel_Debug_todo`.
    - In test/kernel/KernelExportsTest.cpp, add a crasher-suite case, `registerKernelExportsCrasherTests`, named "K20 Debug.todo message reaches stderr under output capture". It spawns `/proc/self/exe --isolated-child <tmp> debug-todo` with `StdioMode::ToFile`, following the `spawnChild`/`waitChild` pattern of test/platform/SpawnTest.cpp:104-113.
    - It CHECKs exit code 1 and that the output file contains `Debug.todo: boom`. Today the file is empty because the text sat in the never-flushed capture stream.
  - Linux path (`/proc/self/exe`); guard with `#if !defined(_WIN32)` like SpawnTest.
  - Name it with `[fail-now DEBUG-01]` like the K11/K13 entries, or use test/XfailGuard.hpp, until the fix lands.
- **Fix:** E/core/DebugExports.cpp `Elm_Kernel_Debug_todo` (:40-48):
  - Write directly to stderr, bypassing `eco_output_text`: `fprintf(stderr, "Debug.todo: %s\n", msgStr.c_str()); fflush(stderr); std::exit(1);`.
  - Or, for consistency with other runtime crashes, use the same `Elm runtime error: ` prefix as `eco_crash` (runtime/src/allocator/RuntimeExports.cpp:2791-2807).
  - Keep `std::exit(1)`, not abort: RuntimeExports.cpp:2805 explains that LLVM's SIGABRT handler would add its own report.
  - Mark the function `[[noreturn]]` if its declaration allows, and drop the dead `return`.
  - Check that no E2E test CHECKs a `Debug.todo:` line on the eco-thread stream: `grep -rn "Debug.todo" test/*/src`. The only hit is PackageLinksTest's `CHECK-NOT: Debug.todo`, which stays satisfied because the combined process output includes stderr.
  - Risk: none for generated code. Invariants: none (no heap or representation change).
- **Shares:** -

### Area ECO

#### ECO-NEW-1: appDataDir fails a `Task Never`
- **Triage:** LIKELY · MEDIUM
- **Test kind:** E2E (with new harness support) · **Exposes it:** high confidence
- **Test:** Add a new E2E test, test/eco-kernel/src/FileAppDataDirNoHomeTest.elm. It is a Platform.worker that runs `Task.perform GotDir (Eco.File.appDataDir "ecotest")` and prints the result. It also prints `-- CHECK: started` before the task, so the output shows how far the program got.
  - It needs a new directive `-- UNSETENV: HOME ECO_HOME`, honoured by the E2E child runner in test/ElmE2ETestBase.hpp. The child calls `unsetenv` before it runs the program; this mirrors the codegen harness's `// UNSETENV:` (test/codegen/CodegenIsolatedTest.hpp:304-311). Document it with the other directives in test/CheckPatterns.hpp:660-672. The test also needs `-- LINUX-ONLY:` (macOS also uses HOME, but Windows reads APPDATA/USERPROFILE).
  - Current: the kernel returns a failed Task with a String inside a `Task Never`. The `GotDir` message never arrives, and the output is whatever the scheduler does with a failure under `Task.perform`: a silent drop, or a confusing crash. Running the test before the fix records this.
  - Correct, if the getpwuid fallback in the fix is taken: `-- CHECK: dir ends with /.ecotest: True`. The CHECK should compare only the suffix, since the home directory differs between machines.
  - Correct, if the "clear crash" option is taken: `-- EXIT: <n>` plus a check that stderr names HOME/ECO_HOME. First confirm that CHECK lines see stderr in this harness.

  Stock Elm has no `Eco.File`, so there is nothing to compare against node. The reference is the Haskell `directory` package, used by elm 0.19.1's own `getAppUserDataDirectory`: it uses `$HOME`, then falls back to `getpwuid`. You can check this with `env -u HOME build/toolchain/bin/elm make` on a tiny project and see where elm-stuff/ELM_HOME resolves. Also add a compiler-level smoke check: `env -i PATH=$PATH <eco> make` in a small project should give a clear message instead of an obscure failure. That is a manual check, not a committed test. Mark the E2E test `-- XFAIL-NATIVE:` until the fix lands.
- **Fix:** **User decision:** keep `Task Never` and make it total, or change the API type.
  - Recommended, which keeps `Task Never` sound and matches elm/Haskell: in K/File.cpp `appDataDirBody` (:362-391), on POSIX fall back from HOME to `getpwuid_r(getuid())->pw_dir`. On Windows the chain stays APPDATA, then USERPROFILE, then HOME. If no base can be found, crash with a clear fatal message ("cannot find a home directory: set HOME or ECO_HOME") through the kernel crash path used for other `Task Never` kernels, instead of `failString`. Update the doc comments in File.cpp/File.hpp/KernelExports.h and Eco/File.elm:268-273. Keep the JS twin, eco-kernel-cpp/src/Eco/Kernel/File.js, consistent with it.
  - Alternative: change the type to `Task IOError String` (or `Task String String`) in Eco/File.elm. Then compiler/src/Utils/Main.elm:1020-1022 (`dirGetAppUserDataDirectory`) and Builder/Stuff.elm:496 (`getElmHome`) must handle the error, which ripples into every `Task Never` caller chain, and the kernel-license CSVs and KernelSetFacts.elm that mention appDataDir must be rechecked. Risk: medium, since it changes the API and the compiler.

  Either way, follow the memory note on stale caches: wipe the eco-stuff and ~/.eco kernel copies before trusting the E2E results.
- **Shares:** The new `-- UNSETENV:`/`-- ENV:` E2E directive is shared with SOCK-15.

### Area FD

#### FD-01: FdChannel closes a possibly reused fd after POLLNVAL
- **Triage:** UNSURE · LOW
- **Test kind:** C++ unit · **Exposes it:** high confidence (of the mechanism; it also settles the UNSURE)
- **Test:** Add `testFdChannelReusedFdNotClosed()` to test/eco-system-core/EcoSystemCoreTest.cpp next to `testFdChannelShutdownWakes` and call it from main (:3497-3499). Steps:
  1. `makeCloexecPipe(p)`, then `auto* r = new FdChannel(p[0]); r->requestRead(70, 10);`. The thread now polls p[0]. Sleep 50 ms.
  2. Close p[0] behind the channel's back with `::close(p[0])`. Then `r->requestRead(71, 10)`; the wake makes the thread re-poll, get POLLNVAL, see `fcntl == -1`, and fail both reads.
  3. `popChannel(2)` and CHECK both results have `err == EBADF`.
  4. Reuse the number deterministically: `int dn = ::open("/dev/null", O_RDONLY); CHECK(::dup2(dn, oldFd) == oldFd); ::close(dn);`.
  5. `r->close(72)`, then `popChannel(1)` for the Close result.
  6. `CHECK(::fcntl(oldFd, F_GETFD) != -1)`. Today the channel thread's finish block `::close`s the reused fd, so this CHECK fails.
  7. Clean up by closing oldFd and p[1], then `delete r`.
  - This is a Linux/macOS test; the file is POSIX-only for FdChannel anyway. Build and run it with `cmake --build build --target eco-system-core-test`, then run build/system-kernel-cpp/eco-system-core-test once, tee'd to /tmp/test_output.txt.
  - The binary has no XFAIL mechanism. Either land the test and the fix in the same commit, or keep the test in the commit before the fix and note the expected failure there. Follow the existing XfailGuard.hpp pattern only if that binary adopts it.
- **Fix:** S/Core/FdChannel.cpp `channelThread` POLLNVAL branch (:339-346):
  - When `::fcntl(st.fd, F_GETFD) == -1 && errno == EBADF`, the fd is no longer ours. Set `st.fd = -1` under `st.m` (or as a thread-owned field, since only this thread reads it after construction; check `FdChannel::fd()` (:75), which reads `st_->fd` from the eco thread, and make it an atomic or document it). Then `failPending(st, EBADF)`.
  - With `st.fd = -1` the loop must not poll it again: `pfd[0].fd = -1` already makes poll skip it.
  - The finish block's `st.fd > 2` test then skips truncate, fsync and close.
  - Also make later requests fail fast with EBADF rather than queue forever. Verify `requestRead`/`requestWrite` still post a result when `st.fd < 0`; add an early `failPending` at the top of the loop if `st.fd < 0`.
  - Risk: low.
- **Shares:** FD-05 (same POLLNVAL branch; one change should distinguish "fd closed" (EBADF, fd = -1) from "open but not pollable and select can't take it" (FD-05's errno)).

#### FD-03: PIPE_BUF write can block
- **Triage:** LIKELY · LOW
- **Test kind:** C++ unit · **Exposes it:** medium confidence (Linux pty semantics)
- **Test:** Add `testFdChannelTtyWriteDoesNotStall()` to test/eco-system-core/EcoSystemCoreTest.cpp. Linux only (`#if defined(__linux__)`); needs `<pty.h>`/`openpty`, linked with -lutil if required. Steps:
  1. `openpty(&master, &slave, ...)` and `cfmakeraw` on the slave.
  2. `auto* w = new FdChannel(dup(slave))`, a blocking fd the channel owns.
  3. `w->requestWrite(80, std::string(1 << 20, 'x'))` and never read the master. On Linux the pty slave reports POLLOUT whenever any write room exists (there is no `chars_in_buffer` for ptys), so once the buffer is nearly full a 4096-byte blocking `write` blocks inside `doWrite`.
  4. Sleep 300 ms, then `w->shutdown()` (it does not join, see FdChannel.cpp:464) and `popChannel(1, 2000)`.
  5. CHECK that the write is reported cancelled (or as partial) within 2 s. Today the channel thread stays blocked in `write`, never drains its wake pipe, and the CHECK times out.
  6. Afterwards, in either outcome, drain the master on a helper thread until the channel's result arrives, so the thread unblocks. Only then `delete w` and close master/slave, so the test binary never hangs.
  - A socketpair is a weaker vehicle: AF_UNIX reports POLLOUT only when a quarter of sndbuf is free, which a 4096-byte write fits. Use the pty.
  - I have not run this, hence medium confidence. If the pty sizes differ by kernel, shrink the wake check to "the shutdown completes within 2 s".
- **Fix:** Options, which need a user decision because of shared open-file-description semantics:
  - (a) For **sockets**, write with `send(fd, ..., MSG_DONTWAIT | MSG_NOSIGNAL)` in `doWrite` (S/Core/FdChannel.cpp:231-236). This is per-call, touches nothing shared, and EAGAIN is already handled at :240. Detect a socket once at construction with `fstat` + `S_ISSOCK`.
  - (b) For **ttys and pipes the channel opened itself** (FileSystem stream fds), set O_NONBLOCK at construction.
  - (c) Do **not** set O_NONBLOCK on fds dup'd from inherited stdio by `createFdSource`/`createFdSink` (Stream.cpp:1051-1079). `F_DUPFD_CLOEXEC` shares the open file description, so O_NONBLOCK would leak to the parent shell's terminal, and other processes would see EAGAIN. For an inherited blocking tty, accept the stall or cap the chunk using `ioctl(TIOCOUTQ)`/write room. That is still racy, so leave it documented.
  - Recommendation: (a) plus (b), with (c) documented as a known limitation in FdChannel.hpp.
  - Risk: medium for (b), since reads also become non-blocking. `doRead` must handle EAGAIN, which needs checking. Low for (a).
- **Shares:** -

#### FD-05: fd >= FD_SETSIZE gets misleading EBADF
- **Triage:** CERTAIN · LOW (cosmetic, macOS-only)
- **Test kind:** none (optional macOS C++ unit) · **Exposes it:** low confidence
- **Test:** It cannot be exposed on Linux: Linux `poll` never returns POLLNVAL for an open fd.
  - An optional macOS-only case in test/eco-system-core/EcoSystemCoreTest.cpp (`#if defined(__APPLE__)`):
    1. Raise `RLIMIT_NOFILE` to over 1100.
    2. `dup2(open("/dev/tty" or "/dev/null"), 1100)`. Pick a device for which macOS poll gives POLLNVAL; it needs checking on a Mac.
    3. Wrap it in `FdChannel`, `requestRead`, and check the result's err is the new code (not EBADF) and that `fcntl(1100) != -1` afterwards.
  - Per the "Windows low priority" spirit, and since macOS is not CI here, the fix may land without it.
- **Fix:** In the same POLLNVAL branch as FD-01 (S/Core/FdChannel.cpp:339-346):
  - When `fcntl(st.fd, F_GETFD) != -1` but select can't be used (`st.fd` or `st.wakeR >= FD_SETSIZE`), `failPending(st, ENOTSUP)` (or EMFILE; pick one and document it on FdChannel.hpp).
  - Keep EBADF only for the closed-fd case, and there also set `st.fd = -1` (FD-01).
  - A larger alternative is a dynamically sized fd_set (macOS allows `_DARWIN_UNLIMITED_SELECT`) or kqueue. Not worth it for a cosmetic bug.
  - Risk: none; it only changes the error code.
- **Shares:** FD-01 (one edit of the POLLNVAL branch).

### Area FILE

#### FILE-01: dead File accessors use alphabetical slot numbers
- **Triage:** CERTAIN · LOW
- **Test kind:** static check · **Exposes it:** high confidence (that the code is dead; nothing at runtime to expose)
- **Test:** No behavioural test is possible because nothing calls the code. Gate the deletion with: (1)
  `grep -rn "Elm::Kernel::File\b\|file/File.hpp" elm-kernel-cpp runtime eco-kernel-cpp system-kernel-cpp test compiler/src`
  finds nothing outside elm-kernel-cpp/src/file/File.{cpp,hpp} (checked: true today); (2) `cmake --build build` links
  every target that links `ElmKernel_File` (compiler/CMakeLists.txt:887, 947, 982; elm-kernel-cpp/CMakeLists.txt:331,
  347); (3) one `cmake --build build --target full` run. No XFAIL needed.
- **Fix:** Delete elm-kernel-cpp/src/file/File.cpp and elm-kernel-cpp/src/file/File.hpp, and remove the
  `src/file/File.cpp` line from `add_library(ElmKernel_File …)` (elm-kernel-cpp/CMakeLists.txt:216). Do NOT delete:
  `src/file/FileExports.cpp` (the live `extern "C"` stubs `Elm_Kernel_File_*`, declared in KernelExports.h; it does
  not include File.hpp, and its sha256 is pinned in kernel-license-files.csv rows `Elm.File.mime/name/size`, which
  must stay unchanged); the `ElmKernel_File` library target and its link lines; `json/Json.hpp`, which
  browser/Browser.hpp still includes (plans/elm-html-native-kernel.md F18). The plans that mention `file/File.cpp`
  (wide-object-tail-kind-words-phase-1.md, 2-bit-unboxed-migration.md, runtime-cpp-gc-rooting-audit.md,
  defer-eager-kernel-tasks-via-binding.md) are historical, so leave them. Risk: nil.
- **Shares:** FILE-02 (same deletion)

#### FILE-02: dead File accessors treat void* as Record* without decoding
- **Triage:** CERTAIN · LOW
- **Test kind:** none · **Exposes it:** n/a (dead code, no caller)
- **Test:** None. The FILE-01 static check and link check cover it.
- **Fix:** Covered by the FILE-01 deletion (`Elm::Kernel::File::name/mime/size/lastModified` in File.cpp:33-78 go
  with the file).
- **Shares:** FILE-01

#### FILE-03: readStringBody has no size cap
- **Triage:** CERTAIN · LOW
- **Test kind:** E2E · **Exposes it:** high confidence (it is expensive before the fix; see conditions)
- **Test:** New test/eco-kernel/src/FileReadHugeFileTest.elm, `-- LINUX-ONLY: sparse file via truncate(1)`. It
  creates `/tmp/eco-kernel-FileReadHugeFileTest/big` as a sparse file of 4294967297 bytes with
  `Eco.Process.spawn "/usr/bin/truncate" [ "-s", "4294967297", p ]` then `Eco.Process.wait`. It then runs
  `File.readString p` and `File.readBytes p` and logs a summary per call: `Ok <String.length>` / `Err <ctor>`.
  CHECK lines: `-- CHECK: FileReadHugeFileTest: readBytes Err OtherIOError` (the existing control, which passes
  today through EFBIG) and `-- CHECK: FileReadHugeFileTest: readString Err OtherIOError`. The tag is EFBIG, so
  `ioErrorTagFromErrno` gives 0; also check that the message contains `too large`. Finally remove the file. Current
  behaviour: readString allocates a ~4 GiB ByteBuffer and reads 4 GiB of zeros. All of it is ASCII, so it becomes a
  Utf8 view of length `size mod 2^32` = 1 and the program logs `Ok 1`. With a heap cap it is instead a fatal
  `largeBodyExhausted` abort. To keep the XFAIL run cheap, add `-- SETENV: ECO_HEAP_CONFIG=<max heap ~1 GiB>` via
  [H]; first verify that E2E children honour the environment heap config. That makes the current code abort fast
  instead of using 4+ GiB of RSS. After the fix, nothing is allocated. Keep `-- XFAIL-NATIVE: FILE-03` until fixed.
- **Fix:** Rewrite readStringBody (eco-kernel-cpp/src/eco-kernel/File.cpp:89-131) and readBytesBody (:134-170) around
  one shared helper, e.g. `readWholeFileInto(pathStr, kindName) -> {BlankByteBuffer, size} | failure`. The helper
  does `::open` + `fstat`, rejects `S_ISDIR` with EISDIR (FILE-NEW-1), rejects `st_size > UINT32_MAX` with
  EFBIG ("file too large for String"/"…Bytes"), reads in an EINTR-retrying `_eco_read` loop, and uses `err ? err : EIO`
  everywhere (FILE-08). The two bodies differ only in the final step (Utf8 view or String copy, or the Bytes
  result). This also drops `std::ifstream`, which never promised to set errno. Keep the "no allocation between
  allocByteBufferBlank and makeUtf8View/succeed" property and its comments. HEAP rules: ByteBuffer `header.size` is
  u32 (runtime/src/allocator/HeapHelpers.hpp:1508-1527, ThreadLocalHeap.cpp:529). The cap makes the length
  fit. [L] applies. Risk: low; FileReadBytesRoundtripTest and test/eco-system File*Test cover regressions.
- **Shares:** FILE-08, FILE-NEW-1 (same helper rewrite); [H] (optional heap env)

#### FILE-04: Task Never wrappers over failing kernels
- **Triage:** CERTAIN · MEDIUM
- **Test kind:** E2E · **Exposes it:** high confidence (MVar, getCwd, appDataDir); none for Runtime.dirname
- **Test:** Three new programs in test/eco-kernel/src/:
  1. `MVarReadAfterDropCrashesTest.elm`: `MV.new |> andThen (\m -> MV.drop m |> andThen (\_ -> MV.read dec m))`
     under `Task.attempt`. On `Ok`/`Err` the update logs `MVarReadAfterDropCrashesTest: reached`. Directives:
     `-- CHECK: Eco crash: eco-io: MVar not found`, `-- CHECK-NOT: MVarReadAfterDropCrashesTest: reached`,
     `-- EXIT: 1`. Current: `resumeNotFound` (eco-kernel-cpp/src/eco-kernel/MVar.cpp:112-119) fails the
     `Task Never` with a tuple, `Task.attempt` delivers `Err`, the program logs "reached" and exits 0, so the test
     FAILS. Optionally add `MVarPutAfterDropCrashesTest.elm` because put has its own evaluator (:202). take shares
     `resumeNotFound` with read. The existing MVarDropReleasesSlotTest stays unchanged.
  2. `FileGetCwdDeletedCrashesTest.elm`, `-- LINUX-ONLY: getcwd ENOENT after rmdir of cwd`: `createDir True d`,
     `setCwd d`, `removeDir d`, then `getCwd` under `Task.attempt`, logging `…: reached`. Directives:
     `-- CHECK: Eco crash: eco-io: could not get current working directory`, `-- CHECK-NOT: …: reached`,
     `-- EXIT: 1`. Current: Err tuple delivered, exit 0.
  3. `FileAppDataDirNoHomeTest.elm`, `-- UNSETENV: HOME` ([H]): `appDataDir "ecotest"` under `Task.attempt`, logging
     `Ok s -> String.endsWith "/.ecotest" s && s /= "/.ecotest"` and `Err _ -> False`. Directive
     `-- CHECK: FileAppDataDirNoHomeTest: True`. Current: `failString` → `Err` → `False`. With the
     getpwuid fallback (see FILE-11) it succeeds with `<pw_dir>/.ecotest`. This matches the Node twin, whose
     `os.homedir()` falls back to the passwd entry. Caveat: it fails on a host whose uid has no passwd entry; there
     the fixed code crashes.
  Runtime.dirname: no test. `currentExecutableDir()` comes from /proc/self/exe and cannot be made empty from a test.
  All three tests are `-- XFAIL-NATIVE: FILE-04` until fixed.
- **Fix:** Use [C]. (a) MVar.cpp `resumeNotFound`: replace the `taskFailIO` resume with
  `crashWithMessage("eco-io: MVar not found: " + id)`. Update the comments in MVar.hpp:24 and KernelExports.h:269,
  and amend IO_ERR_001 (design_docs/invariants.csv:588: the missing-MVar path is no longer "recoverable per
  IO_ERR_002" but a crash). (b) File.cpp `getCwdBody`: crash instead of `failErrno`. (c) Runtime.cpp
  `dirnameBody`: crash instead of `failString`. (d) File.cpp `appDataDirBody`: add the getpwuid fallback (FILE-11),
  and crash only when no home can be found. Alternative, which needs a user decision: retype these leaves to
  `Task IOError` with `Task.mapError IOErr.ofKernelTuple`. That is an API change across the compiler's callers
  (e.g. Utils/Main.elm:1298/1439, Builder/Stuff.elm:496), the XHR twin, docs and IO_ERR_001, and it needs FILE-05's
  tuple shape first; not recommended. The JS kernel's MVar returns `succeed(undefined)` for a missing id
  (eco-kernel-cpp/src/Eco/Kernel/MVar.js:15-34), a separate divergence; consider crashing there too. [L] applies to
  File.cpp, MVar.cpp and Runtime.cpp. Risk: low. Any code that currently relies on Err from a dropped MVar would now
  crash, and grep finds none (Utils/Main.elm:1298 only drops).
- **Shares:** FILE-05, FILE-11 (appDataDir fix and test); [H]; [C] helper shared by all four kernels

#### FILE-05: appDataDir fails with a plain String
- **Triage:** CERTAIN · LOW
- **Test kind:** static check · **Exposes it:** medium confidence (the wrong shape cannot be observed through
  `Task Never`)
- **Test:** No E2E test can see the failure value: under `Task Never` the String never reaches a decoder. Use a
  one-off review grep at fix time: `grep -n "failString" eco-kernel-cpp/src/eco-kernel/File.cpp
  eco-kernel-cpp/src/eco-kernel/Runtime.cpp` should return nothing after the fix. Optionally make it permanent as a
  line in an existing kernel check script, e.g. next to test/scripts/check-kernel-homes.sh, asserting that eco-kernel
  bodies fail only through `failErrno`/`taskFailIO` (IO_ERR_002). The FILE-04 appDataDir test covers the behaviour.
- **Fix:** Covered by the FILE-04 change. appDataDir and Runtime.dirname stop calling `failString`: they succeed via
  the fallback or crash via [C]. If the user picks the retype alternative instead, they must fail with
  `failErrno(ENOENT, "", "HOME environment variable not set")` so the IO_ERR_002 tuple shape holds. If `failString`
  then has no callers left in eco-kernel, delete it from KernelHelpers.hpp; grep first, because system-kernel-cpp
  may use its own copy.
- **Shares:** FILE-04, FILE-11

#### FILE-06: touch ignores open failure
- **Triage:** CERTAIN · LOW
- **Test kind:** E2E · **Exposes it:** high confidence (Linux)
- **Test:** New test/eco-kernel/src/FileTouchErrorClassTest.elm, `-- LINUX-ONLY: procfs has no create op`. It runs
  `File.touch "/proc/eco-kernel-touch-test"` under `Task.attempt` and logs `Err FileNotFound` → `"wrong"`,
  `Err _` → `"ok"`, `Ok` → `"created"`. Directive: `-- CHECK: FileTouchErrorClassTest: ok`. On Linux
  `open(O_CREAT)` in /proc fails with EACCES even as root (the dir has no `->create`), or with EROFS if /proc is
  mounted read-only. `last_write_time` then fails with ENOENT, so the current result is `FileNotFound` ("wrong").
  After the fix it is `PermissionDenied`/`OtherIOError` ("ok"). /proc is used rather than a chmod-ed directory so
  the test works under root (CI containers). `-- XFAIL-NATIVE: FILE-06` until fixed.
- **Fix:** In `touchBody` (File.cpp:426-446), save `openErr = errno` when `_eco_open` fails. If `last_write_time`
  then fails with ENOENT and `openErr != 0`, report `failErrno(openErr, …)`. Keep ignoring a failed open of an
  existing file (EISDIR, read-only), matching touch(1). [L] applies. Risk: nil.
- **Shares:** -

#### FILE-07: write functions ignore write errors
- **Triage:** CERTAIN · MEDIUM
- **Test kind:** E2E (+ E2E with an rlimit directive for the short write) · **Exposes it:** high confidence
- **Test:** (a) New test/eco-kernel/src/FileWriteDevFullTest.elm, `-- LINUX-ONLY: /dev/full`. It runs
  `File.writeString "/dev/full" "hello"`, `File.writeBytes "/dev/full" <5 bytes>`, and, as a control, `File.open
  "/dev/full" WriteMode |> andThen (\h -> File.hWriteString h "hello")`, each under `Task.attempt` and mapped to
  `NoSpaceLeft`/other/`Ok`. Directives: `-- CHECK: FileWriteDevFullTest: writeString NoSpaceLeft`,
  `-- CHECK: FileWriteDevFullTest: writeBytes NoSpaceLeft`, `-- CHECK: FileWriteDevFullTest: hWriteString NoSpaceLeft`.
  Current: the ofstream buffers the data, the ENOSPC from the destructor's flush is lost, and writeString/writeBytes
  log `Ok` (FAIL). The hWriteString control passes today. (b) The short write in hWriteString: /dev/full cannot
  produce one (the first write already returns -1). Add a harness directive `-- RLIMIT-FSIZE: <bytes>`, the same
  kind of change as [H] in `runElmChild`: `setrlimit(RLIMIT_FSIZE)` plus `signal(SIGXFSZ, SIG_IGN)`, POSIX only.
  New test `FileHWriteShortWriteTest.elm` with `-- RLIMIT-FSIZE: 1048576` opens
  `/tmp/eco-kernel-FileHWriteShortWriteTest/f` in WriteMode and calls `hWriteString` with a 2 MiB string
  (`String.repeat`). Expected: `Err (OtherIOError …)` (EFBIG from the second write of the loop). Current: one
  `write` returns 1 MiB and the call reports `Ok` (FAIL). Before relying on it, check that the JIT child writes no
  other file above 1 MiB: the shared result file is ~13 KB (ElmSharedTestResult) and stdout is small. Medium-high
  confidence. Both tests `-- XFAIL-NATIVE: FILE-07` until fixed.
- **Fix:** Add one `writeAllFd(int fd, const void*, size_t) -> int /*errno or 0*/` helper to File.cpp's anonymous
  namespace: an EINTR-retrying loop over `_eco_write` that treats a 0 return as EIO. It is the loop already in
  `writeBytesAtomicBody` (:567-577); make that function use it too. `hWriteStringBody` (:645-667) calls it.
  `writeStringBody`/`writeBytesBody` (:483-541) drop `std::ofstream` for `_eco_open(O_WRONLY|O_CREAT|O_TRUNC, 0644)`
  + `writeAllFd` + a checked `_eco_close`, failing with `failErrno(err ? err : EIO, path, …)`. On Windows the
  `_eco_open` wrapper already adds `_O_BINARY`, which writeString's text-mode ofstream did not. Keep the existing
  Windows newline behaviour deliberately (check how writeString's text mode is relied on; probably not at all,
  since the compiler writes `\n`). Callers include the compiler's own output (Builder/File.elm:436-449 via
  `hWriteString`), so a full disk now surfaces as an error instead of a truncated .mlir. That is intended, and
  IO_ERR_001 maps it to an Exit report. [L] applies. Risk: low-medium (Windows path unverified: low priority per
  user rule).
- **Shares:** writeAllFd shared with writeBytesAtomic; RLIMIT directive is a sibling of [H]

#### FILE-08: readStringBody uses errno after ifstream failure
- **Triage:** CERTAIN · LOW
- **Test kind:** none · **Exposes it:** low confidence
- **Test:** No deterministic test. errno 0 and EIO both map to tag 0 (`OtherIOError`, KernelHelpers.hpp
  `ioErrorTagFromErrno`), so the fix is invisible except when errno is stale, and a stale errno cannot be set up
  from Elm. The shared-helper rewrite in FILE-03 removes the risk structurally, because readString and readBytes
  then use the same code path. Optional characterisation test, not a bug exposer: `readString` of a sysfs file whose
  `st_size` (4096) exceeds its content. Related finding that needs a user decision: `readString "/proc/self/status"`
  returns `""` today, because `tellg()` is 0, and a sysfs file fails with a short read. Node's `fs.readFileSync` (the
  JS/XHR twin) and Haskell's `readFile` return the content. If the user wants parity, the shared helper should read
  until EOF when `st_size == 0` or the file is not regular. Then add an E2E
  `FileReadProcFileTest.elm` (`-- LINUX-ONLY`, CHECK that `readString "/proc/self/status"` starts with `Name:`),
  which fails today with high confidence.
- **Fix:** Part of the FILE-03 rewrite: `err ? err : EIO` on every failure path, and fstat/read-loop errno handling
  in place of ifstream's.
- **Shares:** FILE-03, FILE-NEW-1

#### FILE-09: findExecutable matches directories
- **Triage:** CERTAIN · LOW
- **Test kind:** E2E · **Exposes it:** high confidence
- **Test:** New test/eco-kernel/src/FileFindExecutableSkipsDirTest.elm with
  `-- SETENV: PATH=/tmp/eco-kernel-FileFindExecutableSkipsDirTest/shadow:/usr/bin:/bin` ([H]) and
  `-- LINUX-ONLY: POSIX access(X_OK)`. It runs `File.createDir True "/tmp/eco-kernel-FileFindExecutableSkipsDirTest/shadow/sh"`
  (a directory named `sh`), then `File.findExecutable "sh"`, and logs
  `case r of Just p -> not (String.contains "/shadow/" p) && String.endsWith "/sh" p; Nothing -> False`.
  Directive: `-- CHECK: FileFindExecutableSkipsDirTest: True`. Current: `Just ".../shadow/sh"` → `False`.
  Expected: `Just "/usr/bin/sh"` (or `/bin/sh`), as Haskell's `findExecutable` gives. `-- XFAIL-NATIVE: FILE-09`.
- **Fix:** POSIX `isExecutableCandidate` (File.cpp:202-205): require `stat()` success with `S_ISREG(st.st_mode)`
  in addition to `access(X_OK) == 0`, and update the doc comment ("A searchable directory passes too"). [L]
  applies. Risk: nil. The Windows branch already checks `is_regular_file`.
- **Shares:** FILE-10 (same function, same harness directive [H])

#### FILE-10: empty PATH entry tests the name against cwd
- **Triage:** CERTAIN · LOW
- **Test kind:** E2E · **Exposes it:** high confidence (exact expectation needs a policy decision)
- **Test:** Two new programs, because [H] sets one environment per program:
  `FileFindExecutableEmptyPathLeadingTest.elm` (`-- SETENV: PATH=:/nonexistent-eco`) and
  `FileFindExecutableEmptyPathTrailingTest.elm` (`-- SETENV: PATH=/nonexistent-eco:`), both `-- LINUX-ONLY`. Each
  creates `/tmp/eco-kernel-<Name>/`, copies an executable into it with
  `Eco.Process.spawn "/bin/cp" [ "/bin/true", dir ++ "/ecoprobe" ]` + `wait` (absolute path, since PATH is
  replaced), runs `setCwd dir`, then `findExecutable "ecoprobe"` and logs the `Maybe String`. Expected under the
  recommended Haskell-compatible policy (`System.FilePath.splitSearchPath` maps every empty entry, trailing ones
  included, to `"."`; `findExecutable` returns `"." </> name`): `-- CHECK: <Name>: Just "./ecoprobe"` in both.
  Current: the leading test gives `Just "ecoprobe"` and the trailing test gives `Nothing`, so both fail. Under the
  alternative "skip empty entries" policy: `Nothing` in both, and only the leading test fails today. Both tests
  `-- XFAIL-NATIVE: FILE-10` (or only the leading one under the skip policy).
- **Fix:** In `findExecutableBody` (File.cpp:209-251), split PATH so that a trailing separator yields a final empty
  entry: loop `while (pos <= size)` with an explicit end flag. Then either map `""` to `"."` and return
  `(dir / name).generic_string()`, which gives `./ecoprobe` because `"." / "ecoprobe"` keeps the dot (Haskell
  policy), or `continue` on empty entries (skip policy). Apply the same to the Windows `;` split, low priority.
  Check the compiler's callers of `Eco.File.findExecutable`: a relative result such as `./x` should work with
  `Eco.Process.spawn`. [L] applies. Risk: low.
- **Shares:** FILE-09 (same function; [H]). **Needs user decision:** Haskell-compatible `.` vs skip empty entries.

#### FILE-11: appDataDir accepts empty HOME on POSIX
- **Triage:** CERTAIN · LOW
- **Test kind:** E2E · **Exposes it:** high confidence
- **Test:** New test/eco-kernel/src/FileAppDataDirEmptyHomeTest.elm with `-- SETENV: HOME=` ([H], empty value). It is
  the same program as FILE-04's `FileAppDataDirNoHomeTest`: log `Ok s -> String.endsWith "/.ecotest" s && s /= "/.ecotest"`.
  Directive: `-- CHECK: FileAppDataDirEmptyHomeTest: True`. Current: `Ok "/.ecotest"` → `False`. After the fix it
  uses the passwd home. On macOS the suffix is `/Library/Application Support/ecotest`, so either keep the test
  LINUX-ONLY or branch on the suffix. `-- XFAIL-NATIVE: FILE-11`.
- **Fix:** In the POSIX branch of `appDataDirBody` (File.cpp:378-389), treat `!home || !*home` as unset and fall
  back to `getpwuid_r(getuid())->pw_dir`, again requiring a non-empty value. If both are missing, crash via [C]
  (FILE-04) instead of `failString` (FILE-05). This affects the compiler's cache home (Builder/Stuff.elm:496 when
  `ECO_HOME` is unset), which now resolves correctly in sandboxes with an empty HOME. musl's getpwuid reads
  /etc/passwd, so it is fine for the static release build. Windows is unchanged. [L] applies. Risk: low.
- **Shares:** FILE-04, FILE-05 (one appDataDir rewrite); FILE-04's appDataDir test is the UNSETENV twin of this one

#### FILE-12: Windows strerror on non-errno codes
- **Triage:** CERTAIN · MEDIUM (Windows only; Windows is low priority per the user rule)
- **Test kind:** E2E (meaningful only on a Windows build) + C++ unit (portable helper) · **Exposes it:** high confidence on Windows; low on Linux, where it already passes
- **Test:**
  - New test/eco-kernel/src/FileErrorTagsTest.elm using `Eco.File` and `Eco.IO.Error`. Use relative paths under a temporary directory created by the test. It checks:
    - `list "missing-parent/missing"` → `-- CHECK: list missing: FileNotFound`. On Windows this is ERROR_PATH_NOT_FOUND=3, which is wrongly tagged Other today.
    - `list` on a regular file → `-- CHECK: list file: NotADirectory`. ERROR_DIRECTORY=267 is tagged Other.
    - `createDir False` on a path that is an existing **file** → `-- CHECK: createDir over file: AlreadyExists` (183 → Other).
    - `setCwd "missing"` → `FileNotFound`.

    On Linux it passes today and acts as a regression guard. On the `win-build` preset it fails until fixed (no XFAIL, because XFAIL-NATIVE would also flip Linux). Use `std::filesystem` behaviour on Linux as the reference; the JS twin uses node `err.code`.
  - Optional portable unit check in the kernel unit tests (test/kernel/): the new helper `ioErrorTagFromErrorCode(std::error_code)` maps `std::make_error_code(std::errc::no_such_file_or_directory)` → 1, `errc::file_exists` → 5, and so on. Under `#ifdef _WIN32`, it also maps `std::error_code(3, std::system_category())` → 1, `(5, system)` → 2 and `(183, system)` → 5.
- **Fix:**
  - In K/KernelHelpers.hpp, add `int ioErrorTagFromErrorCode(const std::error_code& ec)`. It compares `ec` against `std::errc` values (`ec == std::errc::no_such_file_or_directory`, which uses `default_error_condition` and so maps Win32 codes correctly on MSVC STL) and also maps `errc::not_a_directory`, `permission_denied`/`operation_not_permitted`, `file_exists`, `is_a_directory`, `no_space_on_device`, `too_many_files_open*`, `broken_pipe` and `bad_file_descriptor`.
  - Add a `failErrorCode(ec, path, msg)` that uses it and puts `ec.message()` in the text.
  - Use it at every `std::filesystem` failure in K/File.cpp: `listBody` (:258-266), `getCwdBody` (:317-320), `setCwdBody` (:330-334), `touch` (:438-441), `removeDirBody` (:418), `createDir` (:691), and any others at :175-196 that pass `ec.value()`.
  - Keep `failErrno`/`ioErrorTagFromErrno` for real errno sources (`_eco_open` and others).
  - The tag numbers are unchanged, so `Eco.IO.Error.decodeIOError` and the JS kernels need no change.

  Risk: low. On POSIX `generic`/`system` codes map one-to-one, so Linux behaviour is identical.
- **Shares:** -

#### FILE-NEW-1: readString of a directory or >4 GiB file is unguarded (huge allocation, abort)
- **Triage:** UNSURE · MEDIUM
- **Test kind:** E2E · **Exposes it:** high confidence on ext4 (/work is ext4 on this host; /tmp is overlayfs)
- **Test:** New test/eco-kernel/src/FileReadDirectoryTest.elm, `-- LINUX-ONLY: directory lseek semantics`. It gets
  `File.getCwd` (the harness child's cwd, under the build tree on /work, ext4), and also uses `"/tmp"` (overlayfs)
  and `"/"`. For each directory it runs `File.readString dir` and `File.readBytes dir` under `Task.attempt`, mapping
  `Err (IsADirectory _)` → `"isdir"` and anything else to its constructor name. Directive: one
  `-- CHECK: FileReadDirectoryTest: [{{"isdir",? ?}}…]` line, or simpler, log `List.all ((==) "isdir") results`
  with `-- CHECK: FileReadDirectoryTest: True`. Current: on ext4, `tellg` returns ~2^63, and readString's
  `allocByteBufferBlank` runs minor+major GCs and then `largeBodyExhausted` (fatal; the test fails with a crash).
  readBytes gives `OtherIOError` (EFBIG). On tmpfs/overlay, readString gives `OtherIOError` (EINVAL). After the
  fix every case is `IsADirectory`. Since the crash depends on the filesystem, the ext4 cwd case resolves the
  UNSURE triage on a single run: an abort confirms the bug. Write nothing to the repo. `-- XFAIL-NATIVE: FILE-NEW-1`.
  The >4 GiB half is FILE-03's test.
- **Fix:** In the FILE-03 shared helper, `fstat` before any allocation. `S_ISDIR` → `failErrno(EISDIR, path,
  "is a directory")`. Other non-regular files are handled by the read-until-EOF decision in FILE-08 (or rejected).
  Add the `> UINT32_MAX` → EFBIG guard to readString. [L] applies. Risk: low.
- **Shares:** FILE-03, FILE-08

### Area FS

#### FS-01: stale FileHandle accepted after fd reuse
- **Triage:** CERTAIN · MEDIUM
- **Test kind:** E2E (plus an optional concurrency stress test) · **Exposes it:** high confidence for the sequential case; low for the in-flight race
- **Test:** New test/eco-system/src/FileHandleStaleTest.elm, using FileTestHelp. The program:
  1. `h1 <- openForWrite a`, `close h1`.
  2. `h2 <- openForReadAndWrite b` (b is empty).
  3. `FileHandle.write h1 (bytes "STALE")`, which should print `-- CHECK: stale write: err HandleClosed @`.
  4. `FileSystem.read b`, which should print `-- CHECK: b after stale write: ok ` (empty).
  5. Repeats with `readFromOffset` and `truncate` on h1.

  POSIX and libuv both reuse the lowest free fd, so h2 gets h1's number in practice. Today both twins print `stale write: ok` and `b after: ok STALE`; JS has the same set-of-fds design (FileSystem.js:474-548). The test fails on JS until both twins are fixed, so land the test and both fixes together, with native `-- XFAIL-NATIVE: FS-01` during the expose step. Optional race test: FileHandleCloseRaceTest.elm, which runs many concurrent `write h1` tasks, then `close h1`, `open b`, and checks that b stays empty. It is timing-dependent and unlikely to fail reliably (low confidence).
- **Fix:**
  - Native: in S/FileSystem/FileSystem.cpp, replace `openHandles()` (:35-38), an `unordered_set<int64_t>` of fds, with an `unordered_map<int64_t id, Entry{int fd; int inFlight; bool closing;}>` whose ids come from a monotonically increasing counter, so they are never reused. `fsCompleteOpen` (:138-142) inserts a new id and returns that id to Elm instead of `r.n`.
  - `fsPoolSubmit` (:178-201) translates id to fd (unknown or `closing` → EBADF) and increments `inFlight`. The completion (`fsComplete`, on the Eco thread) decrements it.
  - `Close` marks the entry `closing` and submits the real `::close` only when `inFlight` reaches 0, deferring it from the last completion if needed. This also closes the in-flight window.
  - JS: the same id→fd map in FileSystem.js, around `_FileSystem_openHandles`/`handleTask`/`close`.
  - Elm: `Handle Int` and `fdOf` (Handle.elm:94, :426) stay as they are, because they become the opaque id.

  Risk: medium. Every handle op and the open/close paths change, and a close deferred past `inFlight` must still resume the close Task. FileHandleTest.elm must stay green.
- **Shares:** FS-03 (the same restructuring of close fixes it).

#### FS-03: close erases fd before submit
- **Triage:** CERTAIN · LOW
- **Test kind:** C++ unit (needs a fault-injection hook) · **Exposes it:** medium confidence
- **Test:** The trigger is only a `std::bad_alloc` inside `parkResume`/`SysWorkPool::submit`, so no E2E program can reach it. Option: add a test-only hook, `SysWorkPool::failNextSubmitForTest()` (compiled under the existing test/validate config or a `ECO_SYSTEM_TESTING` macro), that throws `std::bad_alloc` from the next `submit`. Then add a case to test/eco-system-core/EcoSystemCoreTest.cpp, next to the pool tests at :139-250. The case:
  1. Runs a `FsKind::Open` through `fsPoolSubmit` (the file already has `callBody`/`drainResults` helpers).
  2. Arms the hook and runs `Close`. The Task should fail with "out of memory in kernel".
  3. Asserts that the fd is either closed (`fcntl(fd, F_GETFD) == -1 && errno == EBADF`) or still in the table, i.e. a second close succeeds.

  Today the fd is still open and untracked, so the assertion fails. Wrap the assertion with XfailGuard (test/XfailGuard.hpp) until fixed. If the user does not want a test hook, use **none** and fix by inspection. The bug is a one-fd leak on OOM only.
- **Fix:** In `fsPoolSubmit` (:187), erase the entry only after `submit` returns. Or, in the FS-01 design, set `closing` before `parkResume` and clear it in a local catch that rethrows into the guard. Once FS-01's restructuring lands, this falls out of it. Risk: none.
- **Shares:** FS-01 (the same fix); **user decision** on whether a fault-injection hook is acceptable.

### Area HASH

#### HASH-01: negative seed gives negative narrow hash
- **Triage:** CERTAIN · LOW
- **Test kind:** E2E · **Exposes it:** high confidence
- **Test:** Add /work/test/eco-kernel/src/HashNegativeSeedTest.elm, a Platform/Html program using `Eco.Hash.stringWithSeed` with these CHECK lines:
  - `-- CHECK: negEmpty: 66108864` (seed -1000000, "")
  - `-- CHECK: negA: 34108968` (seed -1000000, "a")
  - `-- CHECK: negAb: 51854225` (seed -1000000, "ab")
  - `-- CHECK: negHello: 7079474` (seed -5, "hello")
  - `-- CHECK: inRange: True` (all results in `[0, 2^26)`)
  - `-- CHECK: pos: <value>` (control: seed 23, "abc"; unchanged)

  Values from the documented `modBy` formula: current native output is -1000000, -32999896, -15254639, -60029390 and `inRange: False`. Note that (-1, "a") gives 71 on both, so it is useless as a probe. Verify the reference with stock Elm: copy compiler/src-xhr/Eco/Hash.elm (pure Elm, `modBy`) next to the same program, then `build/toolchain/bin/elm make --output=h.js` and run with node. For ASCII strings the pure twin and the kernel must agree. Mark `-- XFAIL-NATIVE: HASH-01 negative seed` until fixed; the harness flips it to XPASS after the fix, so the line must be removed then. If the eco-kernel suite is also run on the JS target, the same test exposes the identical bug in the JS twin.
- **Fix:**
  - K/Hash.cpp:28: `int64_t h = ((seed % kBase) + kBase) % kBase;`. `mix` then stays non-negative, since `h >= 0` and the code unit `x >= 0`. Update the `mix` comment (|h| becomes 0 <= h).
  - Make the same change in the JS twin eco-kernel-cpp/src/Eco/Kernel/Hash.js:12: `var h = ((seed % 67108864) + 67108864) % 67108864;`.
  - Drop the "can reduce a negative seed to a negative starting value" caveat from compiler/src-xhr/Eco/Hash.elm:15-18. State in eco-kernel-cpp/src/Eco/Hash.elm that the result is in `[0, 2^26)` for every seed.

  The compiler uses only seeds 23 and 7919, so compiler hashes and the bootstrap stay byte-identical. The memory says to wipe the ~/.eco package artifact caches before trusting E2E after a kernel change. Risk: none.
- **Shares:** -

### Area HEAP

#### HEAP-01: listToStringVector resolves the empty-string constant
- **Triage:** CERTAIN · HIGH
- **Test kind:** E2E · **Exposes it:** high confidence
- **Test:** One E2E per kernel entry point (the empty string literal compiles to the `Const_Empty` embedded constant, HEAP_014):
  - (a) New test/eco-system/src/ProcessRunEmptyArgTest.elm, modelled on ProcessRunEchoTest.elm. Using `ProcessTestHelp.simpleRun`/`describeRun`/`noShell`, run `( "empty arg", describeRun (P.run "printf" [ "[%s][%s]", "a", "" ] noShell) )` and `( "only empty", describeRun (P.run "sh" [ "-c", "echo $#", "sh", "" ] noShell) )`. CHECK lines: `-- CHECK: empty arg: ok stdout=[a][] stderr=`, `-- CHECK: only empty: ok stdout=1| stderr=` (match the helper's formatting), `-- EXIT: 0`.
  - (b) Extend test/eco-kernel/src/ProcessSpawnWaitTest.elm (Eco.Process, K/Process.cpp:67/:90) with `P.spawn "sh" [ "-c", "exit $#", "sh", "" ]` → `wait`, and `-- CHECK: empty arg: ExitFailure 1`.
  - (c) ALPN: extend test/eco-system/src/SocketTlsAlpnTest.elm (or a new SocketTlsAlpnEmptyTest.elm) with `T.tryCase (T.server []) (T.trusted "localhost" [ "" ])`. The expected line is what the JS backend gives for an empty ALPN name; Tls.js validates names and returns the `EINVAL` failure (`bad`, Tls.js:195-198). Native should give the same, because `buildTlsClientConfig` rejects an empty name with EINVAL.

  Expected values for (a)/(b) are plain POSIX behaviour; the reference for (c) is the JS backend via test/scripts/run-js-e2e.js. These are eco/system APIs, so stock Elm is not the reference. Current native: an assertion abort in `fromPointerRaw` (`build` preset keeps asserts) or SIGSEGV, shown as a failed test in its isolated child. Mark each new file `-- XFAIL-NATIVE: HEAP-01 empty string in kernel list` until fixed. Put (b) in its own file if extending would hide the existing cases behind the crash; a separate file is preferred.
- **Fix:** K/KernelHelpers.hpp:214-221 `listToStringVector`: in the lambda, `if (Elm::alloc::isEmptyString(head.p)) { result.emplace_back(); return; }` before `resolve`, or simply `result.push_back(toString(Export::encode(head.p)))`, reusing `toString` (:45-52). Fix the comment at :212-213. This one change covers every caller: K/Process.cpp:67/:90, S/ChildProcess/ChildProcess.cpp:67, S/Tls/Tls.cpp:186/:246, S/WebSocket/WebSocket.cpp:272. While there, grep for other `resolve(head.p)` / `toStdString(resolve(` sites on String elements in K/ and S/, e.g. `toStdString` helpers in S/; check they handle `isEmptyString`. Invariants: HEAP_014 / REP_CONSTANT_002 (test `ptr_ind`, never resolve a constant). Risk: very low.
- **Shares:** HEAP-02 (same class of bug: an embedded constant passed to `resolve`)

#### HEAP-02: NativeDriver resolves Bytes without the empty-Bytes check
- **Triage:** CERTAIN · MEDIUM
- **Test kind:** E2E · **Exposes it:** high confidence
- **Test:** New test/eco-kernel/src/NativeDriverEmptyBytesTest.elm. Get a guaranteed empty-Bytes constant through `Eco.File.writeString p ""` then `Eco.File.readBytes p` (K/File.cpp:153-155 returns `emptyBytes()` for a 0-byte file). `BE.encode (BE.sequence [])` may allocate a 0-length buffer instead of the constant, so do not rely on it. Then run `Eco.NativeDriver.lowerAndLinkBytes bytes "/tmp/eco-kernel-NativeDriverEmptyBytesTest/out"` and print `"empty mlir: failed"` on `Err _`, or `"empty mlir: ok"`. Also print `Bytes.width bytes` as a sanity line. CHECK lines:
  - `-- CHECK: width: 0`
  - `-- CHECK: empty mlir: failed`
  - `-- CHECK-NOT: empty mlir: ok`

  The JS backend always fails this Task ("not available in the JS bootstrap", Eco/Kernel/NativeDriver.js:20-24), so JS passes. Native passes after the fix whether the JIT links the weak stub (rc=-1, runtime/src/codegen/eco_native_stub.cpp) or the real driver (empty MLIR fails to parse). Current native: assertion abort / SIGSEGV in `resolve`. Mark `-- XFAIL-NATIVE: HEAP-02` until fixed. Files under /tmp only.
- **Fix:** K/NativeDriver.cpp:68: `void* ptr = Elm::alloc::resolveBytesOrNull(bytesHP);`. `byteBufferLength`/`byteBufferData` accept null (HeapHelpers.hpp:1552-1554), giving len 0 and data null. Check that `eco::compileMlirBytesToExecutable` handles `(nullptr, 0)`: it should fail cleanly; if it does not, return the failure Task early when `len == 0`. Invariant: HEAP_014. Risk: very low.
- **Shares:** HEAP-01 (same bug class)

### Area HTTP

#### HTTP-06: BadUrl_ string always empty
- **Triage:** CERTAIN · LOW
- **Test kind:** E2E · **Exposes it:** high confidence
- **Test:** Add test/elm-http/src/HttpBadUrlStringTest.elm, modelled on test/elm-http/src/HttpBadUrlTest.elm. That test's `errLabel` drops the payload, which is why it passes today. The new test issues two `Http.get` requests in sequence (`init` sends the first, and `update` sends the second after the first result comes back, so the output order is fixed). The first uses `url = "not a url"` (libcurl returns `CURLE_URL_MALFORMAT`, as the existing test shows). The second uses `url = "foo://example.invalid/x"`, an unknown scheme, so libcurl returns `CURLE_UNSUPPORTED_PROTOCOL`. Each result is logged with `Http.BadUrl u -> "BadUrl " ++ u`, and the other constructors are logged as in errLabel.
  - CHECK lines: `-- CHECK: first: "BadUrl not a url"` and `-- CHECK: second: "BadUrl foo://example.invalid/x"`.
  - Expected under Elm: the JS reference is elm/http's `__Http_BadUrl_(request.url)` when `xhr.open` throws. The Node XHR shim (test/scripts/js-e2e-xhr.js:46-48) throws on `new URL("not a url")` and on any protocol other than http/https, so stock Elm 0.19.1 gives both lines above. Verify with test/scripts/run-js-e2e.js on this one test; it compiles with build/toolchain/bin/elm and runs under node with the shim.
  - Current native output: `first: "BadUrl "` and `second: "NetworkError"`.
  - Mark the file `-- XFAIL-NATIVE: HTTP-06 BadUrl payload empty / unsupported scheme -> NetworkError` until fixed. Remove the mark with the fix; XPASS enforces that.
- **Fix:** runtime/src/platform/HttpService.cpp `HttpService::perform` (~:296-308):
  - In the `CURLE_URL_MALFORMAT` branch, set `result.finalUrl = req.url;`. Setting it unconditionally before the branches also works, but buildResponse only reads it for Ok/BadUrl.
  - Add `CURLE_UNSUPPORTED_PROTOCOL` to the BadUrl branch. The JS shim maps a non-http(s) scheme to BadUrl, and so does a browser.
  - Check E/http/HttpExports.cpp `buildResponse` (:375-380): it already builds `BadUrl_ r.finalUrl`, so it needs no change.
  - Check the other consumers of `ErrorKind::BadUrl`: K/Http.cpp `buildGetArchiveResponse` maps it to "Bad URL", and the Http.Stream kernel in S/ is exercised by test/eco-system/src/HttpStreamBadUrlTest.elm. Make sure the extra curl code does not change HttpStreamBadUrlTest's expectations; if it reports a scheme error as NetworkError today, update that test with the fix.
  - Risk: low. No heap or GC change (the Result is plain C++ data).
- **Shares:** -

#### HTTP-09: HttpEffectManager uses unchecked field literals
- **Triage:** CERTAIN · LOW (drift risk; no current defect)
- **Test kind:** static check · **Exposes it:** high confidence (for the drift; there is no behaviour bug)
- **Test:** The guard is compile-time. After the fix, `grep -nE 'values\[[0-9]+\]|kReqExpect' /work/elm-kernel-cpp/src/http/HttpEffectManager.cpp` must find no Request-record slot literals. Behaviour is already covered by existing E2E tests, which must stay green: test/elm-http/src/HttpTrackProgressTest.elm and HttpTrackChunkedTest.elm read the tracker slot, and HttpCmdMapTest.elm / HttpSubMapTest.elm go through the cmd mapper, which rewrites `expect`. No XFAIL.
- **Fix:** Create elm-kernel-cpp/src/http/HttpRequestLayout.hpp holding the `REQ_*` constants (now file-static at E/http/HttpExports.cpp:116-128) as `inline constexpr int` in a namespace, plus `REQ_FIELD_COUNT = 8`.
  - Put a comment on it giving the field list and the reason the slots follow alphabetical order: every field is boxed, and Bool is boxed per the REP_* rules (CLAUDE.md "Only Int, Float, and Char are unboxed"). Add `static_assert(REQ_EXPECT == 2 && REQ_TRACKER == 6 && REQ_URL == 7)` there as a tripwire.
  - Include the header in HttpExports.cpp, deleting the local constants.
  - Include it in HttpEffectManager.cpp and use `values[REQ_TRACKER]` at :186 and `REQ_EXPECT` at :320-330 in place of `kReqExpect`. Delete the "must agree" comments at :179-180 and :318-319.
  - Generated code is identical. Invariants: REP_HEAP_* record layout (read design_docs/invariants.csv for the record-field-order row first). Risk: none.
- **Shares:** -

#### HTTP-10: archive short read zero-padded
- **Triage:** CERTAIN · LOW
- **Test kind:** E2E · **Exposes it:** medium-high confidence
- **Test:** Extend the in-process test server test/TestHttpServer.hpp with a route `/package-short.zip` serving a copy of `kDummyPackageZip` with one byte changed: the central-directory "uncompressed size" of the first entry (pkg-1.0.0/elm.json). By my offset count that is byte 184 (central directory at 0xa0 = 160, plus 24), changed from 0x22 to 0x40. Assert in the server code that byte 160 begins `PK\1\2` so a wrong offset fails loudly.
  - libzip then reports `st.size = 64` while only 34 stored bytes exist, so `zip_fread` returns 34 or -1 (an inconsistency error) and `got != st.size`.
  - Add test/eco-kernel/src/HttpGetArchiveErrorsTest.elm, modelled on HttpGetArchiveTest.elm. It calls `Eco.Http.getArchive (baseUrl ++ "/package-short.zip")` and logs `Err e -> "Err"`, or for `Ok` the length of the elm.json entry's `data`.
  - CHECK line: `-- CHECK: short: "Err"`. Current behaviour is `short: "Ok 64"`: the 34 real bytes padded with 30 NULs, returned as success. The truncated-entry read I can't fully confirm without running it, hence medium-high confidence; the test prints the observed length so a different libzip outcome is visible.
  - This is eco-only (Eco.Http has no stock-Elm counterpart), so the expected output comes from the spec in Http.hpp's `getArchive` doc. No JS check; add `-- LINUX-ONLY` only if the suite's JS runner tries to run eco-kernel tests (it does not today, as far as I can tell).
  - Mark the file `-- XFAIL-NATIVE: HTTP-10/HTTP-11` until both fixes land.
- **Fix:** K/Http.cpp `buildGetArchiveResponse` (:205-231):
  - Check `zip_stat_index(archive, i, 0, &st) == 0 && (st.valid & ZIP_STAT_SIZE)`. Otherwise close the archive and return `err("Failed to stat zip entry <name>")`.
  - On `!f` (:216-220), stop silently skipping the entry: return an error. A skipped file is also a corrupt package.
  - On `got != (zip_int64_t)st.size`, `zip_fclose`, `zip_close`, `zip_error_fini`, then return `err("Failed to read zip entry <name>")`.
  - Build the error string after libzip is closed: the comment at :180 says no heap allocation happens while libzip is open, so keep `allocStringFromUTF8` after `zip_close`. Collect the message into a `std::string` first.
  - Every error is the same `err(boxed(str), true)` shape already used, and Builder/Http.elm maps it to `PP_BadArchiveContent`, so the compiler is unaffected. Risk: low.
- **Shares:** HTTP-11 (the same new test file HttpGetArchiveErrorsTest.elm and the same function).

#### HTTP-11: getArchive ignores HTTP status
- **Triage:** CERTAIN · LOW
- **Test kind:** E2E · **Exposes it:** high confidence
- **Test:** In the same new test/eco-kernel/src/HttpGetArchiveErrorsTest.elm, chain two more requests after the HTTP-10 case. Print the `Err` string itself; the `Ok` case prints `"Ok"`.
  1. `getArchive (baseUrl ++ "/status/404")`. The route exists (TestHttpServer.hpp:258) and returns a text body. CHECK: `-- CHECK: notfound: "HTTP 404"`. Today it gives `notfound: "Failed to open zip archive"`.
  2. A new server route `/status-zip/404` that serves `kDummyPackageZip` with status 404, i.e. a valid zip with an error status. CHECK: `-- CHECK: zip404: "HTTP 404"`. Today it gives `zip404: "Ok"`: the archive is accepted. This is the case that matters most.
  - The XFAIL mark is shared with HTTP-10.
- **Fix:** K/Http.cpp `buildGetArchiveResponse`: right after the `r.error` check (:140-152) and before hashing, add `if (r.status < 200 || r.status > 299) return err(boxed(allocStringFromUTF8("HTTP " + std::to_string(r.status))), true);` with the same `StackRootGuard` pattern.
  - Redirects are already followed by curl, so the final status is what is checked.
  - Optional: carry the message into the user error in compiler Builder/Http.elm:290-303. That is an Elm compiler change that alters a diagnostic; leave it for a separate decision.
  - Risk: low. Registry and package hosts return 200 on success.
- **Shares:** HTTP-10 (same test file and function, one commit).

#### HTTP-12: Windows SHA-1 shim limited to 4 GiB
- **Triage:** CERTAIN · LOW (Windows-only, practically unreachable)
- **Test kind:** none (optional Windows C++ unit) · **Exposes it:** low confidence
- **Test:** No practical test of the original symptom: it needs a >4 GiB archive in memory on Windows. Per the user rule (Windows low priority), the fix may land unverified.
  - Optional: move the shim into a small header with the per-call chunk size as a parameter, e.g. `sha1Chunked(data, len, out, maxChunk)`. A Windows-only unit test in test/win32/ could then check the FIPS 180 vectors ("abc" -> a9993e36..., and the 1,000,000 x 'a' vector) with `maxChunk = 7`, so the chunk loop is exercised without 4 GiB.
  - Linux CI cannot run it.
- **Fix:** K/Http.cpp:37-51, the `_WIN32` branch:
  - Replace `BCryptHash` with `BCryptOpenAlgorithmProvider` -> `BCryptCreateHash` -> a loop of `BCryptHashData` over `min(remaining, ULONG_MAX)` chunks -> `BCryptFinishHash`.
  - Check each NTSTATUS (`BCRYPT_SUCCESS`). On failure keep the all-zero digest, documented. The registry-hash mismatch then reports it, which is the existing behaviour on provider failure.
  - Update the doc comment that says only the first 0xffffffff bytes are hashed.
  - Risk: low, but uncompiled on Linux.
- **Shares:** -

### Area HTTPS

#### HTTPS-01: HttpStream unknown stream id not rejected
- **Triage:** CERTAIN · LOW (design decision; the behaviour is deliberate and documented)
- **Test kind:** E2E · **Exposes it:** high confidence (it pins whichever behaviour is chosen)
- **Test:** New test/eco-system/src/HttpStreamUploadConsumedTest.elm, using HttpStreamTestHelp. The program uploads `Stream.fromList [bytesOf "abc"]` with PUT to `/anything`, which drains the pair, and `maybeErase` (S/Stream/Stream.cpp:243) then erases it. It uploads the same `source` a second time and prints the outcome: `-- CHECK: first upload: abc`, then `-- CHECK: second upload: <X>`, where the second line shows the echoed body or the error kind. Today both twins print `second upload: ` (an empty body, sent chunked). The JS twin (S/../Eco/Kernel/HttpStream.js:124-149) has the same "missing = ended" rule, so the two agree. Two choices:
  - (a) Keep the design. Write the CHECK as `second upload: ` (empty body), so the documented "consumed readable = Closed = empty body" rule is pinned and no XFAIL is needed. This matches `Stream.read source` returning Closed, as HttpStreamUploadTest already checks.
  - (b) Reject the upload. The CHECK becomes `second upload: NetworkError`; mark it `-- XFAIL-NATIVE: HTTPS-01` until both twins change. The JS runner ignores XFAIL, so the JS change has to land in the same commit as the test.

  The other trigger, an id left over from a previous heap generation, happens only in in-process unit tests. Programs never see it.
- **Fix:** For (a): none beyond the pinning test. For (b): in S/HttpStream/HttpStream.cpp `httpStreamSendBody` (:244-252), turn the guard into `if (!src || streamReadLocked(src))` → resume with NetworkError and a reason such as "the stream body has already been consumed". Make the same change in HttpStream.js:126-127 (`if (!src || ...)`). Update the comments at HttpStream.hpp:315-316 and HttpStream.cpp:262. Leave `pipeStreams` and its "missing = ended" contract (Stream.hpp:127-130) alone, because `Stream.pipeTo`/`pipeThrough` rely on it. Risk: low. With (b), an upload of an already-closed but not yet erased readable would still succeed with an empty body, so the outcome would depend on erase timing. That inconsistency is the main argument for (a).
- **Shares:** - (**needs a user decision: (a) keep the design, or (b) reject**)

#### HTTPS-03: empty method with body sets CUSTOMREQUEST ""
- **Triage:** LIKELY · LOW
- **Test kind:** E2E · **Exposes it:** high confidence
- **Test:** New test/eco-system/src/HttpStreamMethodValidationTest.elm. Case 1 sends `Http.Stream.task { method = Http.Method.UNKNOWN "", body = Http.Stream.bytesBody "text/plain" (bytesOf "x"), url = H.url server "/anything", ... }` and prints the echoed `method`. `-- CHECK: empty method with body: POST`. Today on native, curl sends the request line ` /anything HTTP/1.1`. The test server's `ls >> method >> path` (test/TestHttpServer.hpp:143-146) then reads the method as `/anything` and routes `HTTP/1.1`, so native prints `empty method with body: BadStatus 404`. Add `-- CHECK: empty method no body: GET` as a control; it already passes. Mark `-- XFAIL-NATIVE: HTTPS-03/HTTPS-NEW-2` until fixed. JS caveat: node's `(method || 'GET')` sends **GET** with the body, so the JS runner prints `GET`. The JS twin has to change in the same commit (see Fix), or the test fails on JS.
- **Superseded by D23:** an empty method is rejected before sending (both backends), not sent as POST; the test expects that error.
- **Fix:** In S/HttpStream/HttpTransfer.cpp `configure`, change :534 to `if (m != "POST" && !m.empty())`. An empty method with a body is then sent as curl's own POST, as HttpTransfer.hpp:67-71 documents and as the non-stream kernel already does (runtime/src/platform/HttpService.cpp:248-253). In Eco/Kernel/HttpStream.js, where `__method` is set (:105), map an empty method to `'POST'` when `bodyKind != 0` and to `'GET'` otherwise, so the twins agree. Risk: none.
- **Shares:** HTTPS-NEW-2 (same test file; the fix touches the same lines). **User decision:** confirm that empty + body means POST, as the header and the non-stream kernel say, and not GET, which is what JS does today.

#### HTTPS-04: finishTransfer fallback drops response data
- **Triage:** LIKELY · LOW
- **Test kind:** E2E · **Exposes it:** medium confidence (depends on the libcurl version)
- **Test:** A concrete trigger exists: a 3xx with an **empty** `Location:`. `headerCb` sets `sawLocation = true` for any `location` header, even an empty one (HttpTransfer.cpp:378), so `isFollowedRedirect` holds and no head is posted. libcurl ignores an empty Location and finishes CURLE_OK with status 302, which lands in the fallback (:559-566). A 305 is probably not a trigger, because curl follows any 3xx that has a non-empty Location.
  - Add a route to test/TestHttpServer.hpp: `/redirect-empty-location` → `sendResponse(conn, 302, "Found", "text/plain", "moved", "Location: \r\nX-Test: kept\r\n")`.
  - New test/eco-system/src/HttpStreamEmptyLocationTest.elm requests it with `streamResolver` and prints the kind, status, statusText, the `x-test` header and the body:
    - `-- CHECK: kind: BadStatus 302`
    - `-- CHECK: statusText: Found`
    - `-- CHECK: x-test: kept`
    - `-- CHECK: body: moved`
  - Expected: what the JS twin gives today. `res.headers.location` is `""`, which is falsy (HttpStream.js:321), so the response is treated as final with full headers and body.
  - Native today: statusText `""`, x-test `-`, body `""`.
  - Mark `-- XFAIL-NATIVE: HTTPS-04`.
- **Fix:** Two parts:
  1. In `headerCb` (:378), set `sawLocation` only when the trimmed value is non-empty, so it matches curl's own rule.
  2. As a safety net in `finishTransfer` (:556-566), post the head from the last `HeaderState`: pass `hs` (statusText and headers) into `finishTransfer` from `runTransfer`, instead of an empty head. Optionally keep the body bytes `writeCb` dropped while `!headersPosted` for the final hop: buffer them per hop and clear the buffer at each `HTTP/` line.

  Part 1 alone fixes the reachable case. Part 2 covers any other mismatch between curl's follow rule and `isFollowedRedirect`. Risk: low. The extra buffer is bounded by the cap on redirect bodies.
- **Shares:** -

#### HTTPS-09: close for bodyKind != 2 answered late
- **Triage:** CERTAIN · LOW (real variant: HEAD with a stream body)
- **Test kind:** E2E · **Exposes it:** medium confidence
- **Test:** New test/eco-system/src/HttpStreamHeadStreamBodyTest.elm, modelled on HttpStreamUploadErrorTest. The program:
  1. Builds an identity `Stream.Transformation` and uploads its readable as `streamBody` with method `HEAD` to `/slow?ms=1500`.
  2. At the same time, `writeString "x"` into the writable and then `closeWritable` it.
  3. Logs which finishes first and the close's result.

  Expected: `-- CHECK: close: ok`, then `-- CHECK: response: GoodStatus 200`, in that order. "HEAD sends no body even if one is given", so the body should be accepted and discarded at once. Native today: the close is answered only when the transfer ends, with ECANCELED "the HTTP response ended before the request body was sent". The identity pipe is then cancelled, so the program prints `response` first and then `close: err ...`. Mark `-- XFAIL-NATIVE: HTTPS-09`. Before fixing the CHECKs, run the JS twin once and confirm what it does. Node may write a chunked body on a HEAD request, in which case JS needs the same "discard" change.
- **Fix:** When `spec.method == "HEAD" && spec.bodyKind == 2`:
  - In S/HttpStream/HttpTransfer.cpp, mark the transfer `upDiscard`. In `serviceLocked` (:225-247), acknowledge and drop upload writes at once, and answer a requested close with success immediately (set `upEofSent`).
  - In `buildHeaderList` (:480-483), leave out `Transfer-Encoding: chunked` / `Expect:`.

  The other option is to reject the stream body up front with NetworkError in `httpStreamSendBody`. That is simpler but contradicts the documented "HEAD ignores the body". Make the matching change in HttpStream.js. Risk: low, the change is limited to HEAD.
- **Shares:** -

#### HTTPS-NEW-1: proxy CONNECT response posted as the final response
- **Triage:** LIKELY · MEDIUM
- **Test kind:** E2E (needs harness support) · **Exposes it:** high confidence once the harness can set the env
- **Test:** Two pieces of infrastructure are needed:
  - (1) A CONNECT handler in test/TestHttpServer.hpp `handleConnection`. On `req.method == "CONNECT"` it replies `HTTP/1.1 200 Connection established\r\n\r\n`, opens a socket to 127.0.0.1:`httpsPort()`, and relays bytes both ways (two threads or a poll loop) until either side closes.
  - (2) A new process directive `-- ENV: NAME=VALUE` in test/CheckPatterns.hpp, applied when ElmE2ETestBase.hpp spawns the child and also by test/scripts/run-js-e2e.js. It needs `${ECO_TEST_HTTP_URL}` substitution, because the port is dynamic, and it must also clear `no_proxy`/`NO_PROXY`.

  Then add test/eco-system/src/HttpStreamProxyTest.elm with `-- ENV: https_proxy=${ECO_TEST_HTTP_URL}`. It requests `H.url` on the **https** server at `/status/404` (CURL_CA_BUNDLE is already set by the harness) and prints `-- CHECK: via proxy: BadStatus 404 Status` and `-- CHECK: headers non-empty: True`. Native today prints `GoodStatus 200 Connection established` with no headers. Node's https ignores `https_proxy` unless NODE_USE_ENV_PROXY is set, so JS passes as-is. Mark `-- XFAIL-NATIVE: HTTPS-NEW-1`.
- **Fix:** In S/HttpStream/HttpTransfer.cpp `configure`, add `curl_easy_setopt(easy, CURLOPT_SUPPRESS_CONNECT_HEADERS, 1L)`; it is available since libcurl 7.54, so guard it with `LIBCURL_VERSION_NUM >= 0x073600`. As defence in depth, `headerCb` could ignore a 2xx block that answers a CONNECT, but the option is enough. Also check runtime/src/platform/HttpService.cpp. Its `headerCb` (:157) resets on each `HTTP/` line and takes the status from CURLINFO_RESPONSE_CODE, so it is probably right, but setting the same option there costs nothing. The same test with an `Http.get` variant in test/elm-http would confirm it. Risk: none.
- **Shares:** The `-- ENV:` directive and the CONNECT relay are new harness infrastructure (**the user should approve adding them**).

#### HTTPS-NEW-2: method string not validated (request-line injection)
- **Triage:** LIKELY · MEDIUM
- **Test kind:** E2E · **Exposes it:** high confidence
- **Test:** Extend test/eco-system/src/HttpStreamMethodValidationTest.elm, the same file as HTTPS-03.
  - Case 2 sends method `UNKNOWN "GET /anything HTTP/1.1\r\nX-Injected: 1\r\n\r\nGET"` to `/anything`. It prints the kind and, on a 200, whether the echoed headers contain `x-injected`. The expected line is `-- CHECK: injected method: NetworkError`: JS node `http.request` throws ERR_INVALID_HTTP_TOKEN, which HttpStream.js:243-249 maps to NetworkError. Native today: the test server parses the first request line as `GET /anything`, sees header `x-injected: 1`, and the program prints `injected method: GoodStatus x-injected`.
  - Case 3 sends `UNKNOWN "PRO PFIND"`: `-- CHECK: space in method: NetworkError`.
  - A control, `UNKNOWN "PROPFIND"`, is already covered by HttpMethodOptionsTest.

  Shares `-- XFAIL-NATIVE` with HTTPS-03.
- **Fix:**
  - In S/HttpStream/HttpStream.cpp `httpStreamSendBody` (before `parkResume`, alongside the read-lock check), or at the top of `HttpTransfer` start, reject a method that is not empty and not an RFC 9110 token. Resume with NetworkError and reason "network error: invalid HTTP method", matching node's message class. An empty method stays allowed: it means GET without a body and POST with one (HTTPS-03).
  - Write the tchar check as one small helper, `isHttpToken`, beside `buildHeaderList`.
  - The non-stream kernel (runtime/src/platform/HttpService.cpp:251) has the same hole. Stock elm/http catches `xhr.open` throwing SyntaxError and fails with `BadUrl url`. Verify with build/toolchain/bin/elm and the node XHR shim used by the elm-http JS runner. Then add a twin test, test/elm-http/src/HttpInvalidMethodTest.elm, with `-- CHECK: BadUrl` and the same validation in HttpService. Treat it as a separate follow-up entry.

  Risk: low. Valid tokens such as PROPFIND are unaffected.
- **Shares:** HTTPS-03 (same test file, adjacent code).

### Area HTTPSRV

#### HTTPSRV-02: bracketed host accepts any reg-name chars
- **Triage:** CERTAIN · LOW
- **Test kind:** E2E · **Exposes it:** high confidence
- **Test:** new `/work/test/eco-system/src/HttpServerHostStrictTest.elm`. It uses the same pattern as `HttpServerHostTest.elm` (`HttpServerRawHelp` program, `bad`/`good` helpers, the handler logs `url <requestToString url>`). Cases:
  - `bad server "bracket junk" ("Host: [zz!$:]" ++ crlf)` with `-- CHECK: client: bracket junk: 400 close` and `-- CHECK: client: bracket junk: closed`.
  - `bad` for `[:]` and for `[1::2::3]`, each with the same 400 / closed CHECK pair.
  - Good IPv6 literals: `good ... "Host: [::1]:8080"` → `-- CHECK: server: url http://[::1]:8080/v6`, and a zone id `Host: [fe80::1%25eth0]` → 200.
  - Good IPvFuture: `Host: [v1.fe:x]` → 200.
  - `-- CHECK-NOT: server: url http://[zz` to make sure the junk Host never reaches the program.

  Expected (RFC 3986 §3.2.2 IP-literal = IPv6address / IPvFuture, RFC 6874 zone): junk gets 400 and the connection closes. Current: native answers 200 and delivers `http://[zz!$:]/never`. The JS twin (`system-kernel-cpp/src/Eco/Kernel/HttpServer.js:205` `_HttpServer_validHost`, the same lenient regex) does the same. This is not stock-Elm behaviour; the RFC is the oracle. Because both targets fail and the JS runner (`test/scripts/run-js-e2e.js`) has no XFAIL directive, do not commit the test red. Write it, run it once on both targets and see it FAIL, then land it together with the fix to both twins, with no marker. If a red commit is wanted first, put `-- XFAIL-NATIVE:` plus a temporary `-- SKIP-JS:` in this file (the runner's doc says SKIP-JS is for native-only behaviour, so this needs agreement). An optional native-only guard can also go in `testHttp1Limits` in `/work/test/eco-system-core/EcoSystemCoreTest.cpp`: `rejected(a.port, "GET / HTTP/1.1\r\nHost: [zz!$:]\r\n\r\n").rfind("HTTP/1.1 400 ",0)==0`.
- **Fix:** `/work/system-kernel-cpp/src/eco-system/HttpServer/Http1.cpp` `validHost`, bracket branch (:76-86):
  - If the content starts with `v`/`V`, check IPvFuture: `v` 1*HEXDIG `.` 1*(unreserved / sub-delims / `:`).
  - Otherwise split off an optional `%25<zone>` (zone = 1*(unreserved / pct-encoded)) and require `inet_pton(AF_INET6, addr, &buf) == 1`. Windows has `InetPtonA`, but the server is POSIX-only today.

  Mirror this in `HttpServer.js` `_HttpServer_validHost`: for the IP-literal arm use `net.isIPv6(addr)` after stripping the zone, plus an IPvFuture regex. Update the comment at Http1.cpp:68-72, which currently says the leniency is deliberate. Is HTTP/2 `:authority` validated through the same `validHost`? Grep `validHost` in `HttpServer/Http2*.cpp`; if it is, the fix covers it. No invariants involved. Risk: low. Clients that sent malformed bracketed hosts now get 400.
- **Shares:** HTTPSRV-04 (same new test file and the same "fix both twins together" approach)

#### HTTPSRV-03: 100 Continue sent to HTTP/1.0
- **Triage:** CERTAIN · LOW
- **Test kind:** E2E · **Exposes it:** high confidence
- **Test:** new `/work/test/eco-system/src/HttpServerExpectHttp10Test.elm`. Handler as in `HttpServerLimitsTest.elm`: log `METHOD path body <body>` and answer `Server.setBody "ok"`. Client cases:
  - `H.connect server |> Task.andThen (H.exchange ("PUT /c HTTP/1.0" ++ crlf ++ "Content-Length: 3" ++ crlf ++ "Expect: 100-continue" ++ crlf ++ crlf ++ "abc") 1 True)`, labelled "1.0 continue".
  - The same request with `Expect: later`, labelled "1.0 other".
  - A control: the HTTP/1.1 request with `Host: h` and `Expect: 100-continue` still gets `100 -` first, as in LimitsTest.

  CHECK lines:
  - `-- CHECK: server: PUT /c body abc`
  - `-- CHECK: client: 1.0 continue: 200 close ok`
  - `-- CHECK: client: 1.0 continue: closed`
  - `-- CHECK: client: 1.0 other: 200 close ok`
  - `-- CHECK: client: 1.1 continue: 100 -`

  Current native: "1.0 continue" first describes `100 -`, then `closed after HTTP/1.1 200 OK...`; "1.0 other" gets `417 close`. The JS twin uses Node's `checkContinue`/`checkExpectation`, and Node's http server only handles Expect for HTTP/1.1, so JS should already pass. Verify once with `node test/scripts/run-js-e2e.js --build-dir build --project eco-system --record HttpServerExpectHttp10Test` and use its output as the reference for the CHECK lines. Mark `-- XFAIL-NATIVE: HTTPSRV-03 100 Continue / 417 sent to HTTP/1.0` until the fix; the harness reports XPASS once it is fixed. Keep it a separate file so the XFAIL does not mask `HttpServerLimitsTest`.
- **Fix:** `/work/system-kernel-cpp/src/eco-system/HttpServer/Http1.cpp` `headersComplete` (:215-222): guard the whole Expect block with `if (parser_.http_minor >= 1)`. That covers both the 417 and the 100 write, so a 1.0 request's Expect is ignored (RFC 9110 §10.1.1, §15.2). Leave the 413 check before it unchanged. Update the doc in `HttpServerLimitsTest.elm` / the plans if they describe the 1.0 behaviour. Risk: very low.
- **Shares:** -

#### HTTPSRV-04: absolute-form recognised only lower-case
- **Triage:** CERTAIN · LOW
- **Test kind:** E2E · **Exposes it:** high confidence
- **Test:** add to `/work/test/eco-system/src/HttpServerHostStrictTest.elm` (shared with HTTPSRV-02):
  - `good server "absolute upper" ("GET HTTP://Other.test/abs2 HTTP/1.1" ++ crlf ++ "Host: other.test" ++ crlf ++ crlf)` with `-- CHECK: server: url http://Other.test/abs2` and `-- CHECK: client: absolute upper: 200 keep-alive ok`.
  - A `HttpS://...` variant on the plain server, which must be kept as `https://...` the way the lower-case `https://` form is kept today.
  - `-- CHECK-NOT: /HTTP://`

  Current: native and JS both give `http://other.test/HTTP://Other.test/abs2`. Lower-case the scheme in the delivered URL: `Url.fromString`, which Elm-side code applies to the URL, only accepts lower-case `http://`/`https://`, so passing the raw `HTTP://` through would make `request.url` unparseable. Check how Http/Server.elm builds `request.url`, and log `request.url.path` as well to prove it parses. The oracle is RFC 3986 §3.1, not stock Elm. Both twins are wrong, so handle it as in HTTPSRV-02: run once and see it fail, then land it with the fix to both twins, no marker.
- **Fix:** `/work/system-kernel-cpp/src/eco-system/HttpServer/Http1.cpp` `absoluteUrl` (:333-339): compare the first 7/8 characters case-insensitively (the existing `iequals` on a prefix) and return `lower(scheme) + rest`. Mirror this in `HttpServer.js` `_HttpServer_absoluteUrl` (:214): `/^https?:\/\//i.test(target)`, then lower-case the scheme. Check whether an HTTP/2 `:scheme` path has the same comparison (grep `"http://"` in `HttpServer/`). Risk: low.
- **Shares:** HTTPSRV-02 (test file, both-twins approach)

#### HTTPSRV-06: every getaddrinfo failure reported ENOTFOUND
- **Triage:** CERTAIN · LOW
- **Test kind:** C++ unit · **Exposes it:** high confidence (needs a test seam)
- **Test:** an E2E test cannot force EAI_AGAIN reliably, because it needs a resolver outage, and in a network-less container the result depends on the environment. The binaries are static musl, so no LD_PRELOAD either. Add a test-only resolver hook in `/work/system-kernel-cpp/src/eco-system/HttpServer/HttpServerService.{hpp,cpp}`: `using GetaddrinfoFn = int(*)(const char*, const char*, const addrinfo*, addrinfo**); void setListenResolverForTest(GetaddrinfoFn)`, defaulting to `::getaddrinfo`. Then add `testHttpListenGaiCodes()` to `/work/test/eco-system-core/EcoSystemCoreTest.cpp`, next to the `gaiCode` checks at :1005. It injects stubs that return EAI_AGAIN, EAI_MEMORY, and EAI_SYSTEM with `errno=ECONNREFUSED`, then calls `HttpSrvT::listenOn("some.host", 0)`. Expected (node's format, which `Socket.cpp:113-117` already follows):
  - `code == "EAI_AGAIN"` and `message == "getaddrinfo EAI_AGAIN some.host"`;
  - `"ENOMEM"` and `"ECONNREFUSED"` for the other two;
  - EAI_NONAME stays `"ENOTFOUND"`.

  Current: all four give `ENOTFOUND`. Reset the hook afterwards. The binary has no XFAIL helper, so either land the test with the fix, or add a small local `xfail(id, defect, how)` that mirrors `/work/test/XfailGuard.hpp::report` (that header pulls in `TestSuite.hpp`, which is probably not linked into `eco-system-core-test`). The existing E2E `HttpServerStartErrorTest.elm` (`third: ENOTFOUND` for `no-such-host.invalid`) must stay green as the regression check.
- **Fix:** in `HttpServerService.cpp` `listenOn` (:226-231), save `int sysErr = errno` right after the call, then `res.code = ::Eco::System::gaiCode(gai, sysErr); res.message = "getaddrinfo " + res.code + " " + host;`. Consider factoring out one helper shared with `Socket/Socket.cpp:113-117`. Update the doc comment at `HttpServerService.hpp:56-62`. `Http/Server.elm:903-909` already maps `EAI_AGAIN` to `HostLookupTryAgain`. The JS twin passes node's `err.code` through; confirm `HttpServer.js:1274`'s error path does not hard-code ENOTFOUND. Risk: low.
- **Shares:** HTTPSRV-14 (same function; do both edits together)

#### HTTPSRV-12: HttpUpgrade EINVAL message incomplete
- **Triage:** CERTAIN · LOW
- **Test kind:** E2E · **Exposes it:** medium confidence (timing-based, but with wide margins)
- **Test:** new `/work/test/eco-system/src/LiveHttpUpgradeLateTest.elm`, modelled on `LiveHttpUpgradeGoneTest.elm`.
  - A detached Node client (`L.node`) connects, writes the WebSocket opening request, and resets the connection 200 ms later with `s.resetAndDestroy()` (Node >= 16.17/18.3). An RST is needed: a FIN alone does not produce ConnGone for a pending request, because Http1 answers half-closed peers.
  - On `GotRequest` the handler drops the `onRequest` subscription and runs `Process.sleep 600 |> Task.andThen (\_ -> Server.upgradeRequest request response)`. The 600 ms lets the ConnGone event drain and erase the key.
  - The program logs `upgrade: ` ++ `ErrorNames.webSocketError e`, then calls `System.exit`.

  Expected after the fix: `-- CHECK: upgrade: SocketError Cancelled` (ECANCELED "socket closed", the same kind HttpUpgrade.cpp:208 reports when the connection is found gone after the take). Current: `SocketError InvalidInput` with "answered already or is not an upgrade request". Mark `-- XFAIL-NATIVE: HTTPSRV-12 gone upgrade key reported EINVAL`. Before relying on the JS target, check what the twin does for a gone upgrade socket (`HttpServer.js` upgrade take). If JS already says Cancelled, the XFAIL-NATIVE marking is right; if it also says EINVAL, fix both twins together. Risk to exposure: if the RST is processed before the request bytes are read, no request is delivered and the test hangs or times out. The 200 ms delay makes that unlikely; add a 10 s exit timer that logs "no request".
- **Fix:** `HttpTables.cpp` `httpTablesTakeUpgrade` (:463-473) returns an enum `{Taken, NotUpgrade, Unknown}`. `HttpUpgrade.cpp:201-204` maps it as follows:
  - `NotUpgrade` (or parked) → EINVAL "the request is not an upgrade request";
  - `Unknown` → see below.

  Two designs, which need a user decision:
  - **(a)** Message-only. Keep EINVAL and say "the request was answered already, its connection is gone, or it is not an upgrade request". No state changes.
  - **(b)** Real distinction. On `ConnGone` (HttpTables.cpp:348-350), an entry whose `req.upgrade` is non-empty is turned into a tombstone (`gone = true`; `req`, `conn` and `hold` are released) instead of being erased, and is erased at the take or at server close. The take then reports ECANCELED "socket closed" for tombstones and EINVAL "answered already" for truly unknown keys. Tombstones are bounded by the number of undelivered/untaken upgrade requests: one small entry each, and only if the program never calls `upgradeRequest` for them.

  Recommendation: (b). Key-unknown because of an older heap generation stays EINVAL. Make sure the hold released on ConnGone is not released twice (eraseKey vs the tombstone path). Risk: low for (a), medium for (b) (liveness holds, plans/program-liveness-rule.md).
- **Shares:** -

#### HTTPSRV-14: strerror on worker thread
- **Triage:** CERTAIN · LOW
- **Test kind:** none · **Exposes it:** low confidence (no practical test)
- **Test:** none. A race needs an old glibc (< 2.32) or a libc with a shared static buffer, an unknown errno value, and a concurrent `strerror` on the eco thread. musl and current glibc return constant strings or thread-local buffers, and TSan does not flag `strerror` itself. An optional static guard is a grep in a `test/scripts/` check: forbid `strerror(` in `HttpServerService.cpp`, or more generally in any function called from a `SysWorkPool::submit` lambda. A general rule is hard to express textually, so this would be a file-level allow list only. The regression check for the message format is the existing `HttpServerStartErrorTest.elm` (`second: EADDRINUSE: listen EADDRINUSE:`).
- **Fix:** carry the errno back instead of formatting on the worker. Add `int sysErr = 0; const char* syscall = nullptr;` (and `where`) to `ListenResult` in `HttpServerService.hpp:33-39`, and have `listenOn` fill `code` but leave the strerror part of `message` to the caller. Build the message in `createComplete` in `HttpServer.cpp`, which runs on the eco thread, with `std::strerror`. Alternatively, a Core helper `threadSafeStrerror(int)` wrapping `strerror_r`, with the GNU char*-vs-XSI int overload trick, if other worker paths need the same; grep `strerror` under `system-kernel-cpp/src/eco-system` for other worker callers while doing it. Unit tests call `listenOn` directly on the main thread, so check that they do not assert on the old message text. Risk: low.
- **Shares:** HTTPSRV-06 (same function `listenOn`)

#### HTTPSRV-16: taggers[serverId] inserts empty vector
- **Triage:** CERTAIN · LOW
- **Test kind:** none · **Exposes it:** low confidence (no observable effect)
- **Test:** none. The stray empty map node is invisible: `hasSubscribers` checks emptiness, the root scanner iterates an empty vector, and `onEffects` replaces the map. Existing `LiveHttpServerUnsubscribedTest.elm` and `LiveHttpServerOnRequestTest.elm` are the regression check after the change.
- **Fix:** `/work/system-kernel-cpp/src/eco-system/HttpServer/HttpServerManager.cpp` `deliver` (:126): `auto it = st.taggers.find(serverId); if (it == st.taggers.end() || it->second.empty()) return;`. Do this before building `arg` (move the lookup above the allocations at :115-121, keeping the "nothing allocates between decodes and range push" ordering for the tagger decode). Check what the caller expects when nobody is subscribed: if `deliver` must still release a hold or park the request, keep that behaviour and only skip the tagger loop. Risk: low (GC rooting order; HEAP_* root-scanner rules).
- **Shares:** -

### Area JSON

#### JSON-01: Json.encode throws on invalid UTF-8
- **Triage:** CERTAIN · MEDIUM
- **Test kind:** E2E · **Exposes it:** high confidence
- **Test:** Add a new file, test/elm-conformance/src/JsonEncodeLoneSurrogateTest.elm. Build it on `ConformanceHelp.logAll`/`worker`, and keep the source ASCII by writing the emoji as `Char.fromCode 0x1F600`. Record the CHECK lines from Elm on node (`node test/scripts/run-js-e2e.js --project elm-conformance --record JsonEncodeLoneSurrogateTest`, with build/toolchain/bin/elm 0.19.1). Expected Elm values:
  - `lone high`: `E.encode 0 (E.string (String.left 1 emoji))` → `"\"\\ud83d\""`
  - `lone low`: `E.encode 0 (E.string (String.fromChar (Char.fromCode 0xDC00)))` → `"\"\\udc00\""`
  - `lone key`: `E.encode 0 (E.object [ ( String.left 1 emoji, E.int 1 ) ])` → `"{\"\\ud83d\":1}"`
  - `pair intact`: `String.fromInt (String.length (E.encode 0 (E.string emoji)))` → `"4"` (the valid pair stays raw)

  Today eco aborts: nlohmann `type_error.316` escapes the `extern "C"` export, so `std::terminate` runs, and nothing after the first case is logged. Mark the file `-- XFAIL-NATIVE: JSON-01 json::dump throws on a lone surrogate` until the fix lands; the harness then reports XPASS. Keep this case in its own file so that the crash does not hide the other JSON CHECKs. A possible related bug for a separate file: `D.decodeString D.string "\"\\ud83d\""` is `Ok` in Elm, but nlohmann's parser rejects lone-surrogate escapes. Record it and file it separately; it is not part of JSON-01.
- **Fix:** In E/json/JsonExports.cpp, replace the `j.dump(...)` calls in `Elm_Kernel_Json_encode` (:1900-1912) with a hand-written serializer, `writeJsJson(const json&, int indent, int level, std::string& out)`, that mirrors `JSON.stringify(v, null, indent)`:
  - **Strings:** escape `"`, `\\`, `\b\f\n\r\t`, and other characters below 0x20 as `\u00xx` (lower-case hex, as JS does).
  - **Lone surrogates:** decode the WTF-8 sequence that `StringOps::toStdString` writes for them (`ED A0-BF xx`) and emit it as `\udxxx`. Copy valid UTF-8 through unchanged.
  - **Layout:** for `indent > 0`, use JS layout: `"key": value`, one entry per line, and `[]` and `{}` when empty. The keys are already in JS order (the ordered_json from `OrderedDomBuilder`/`elmToJson`).

  The output is then always valid UTF-8 for `allocElmString`. As defence in depth, have the export never let a C++ exception out: wrap it in try/catch that crashes with a message, never an unwind through generated code. This touches no heap-layout invariants (the export allocates only the result String). Risk: low to medium, because the whole encoder's text output changes. Re-run the elm-json suite and the JsonObjectOrderTest/JsonDecodeErrorTest conformance tests; the indent-4 rows there pin the layout.
- **Shares:** The fix is shared with JSON-NEW-1 (the same custom writer formats numbers) and enables part of JSON-05's test.

#### JSON-05: JSON ints above INT64_MAX wrap
- **Triage:** CERTAIN · MEDIUM
- **Test kind:** E2E · **Exposes it:** high confidence
- **Test:** Write two files.
  - **(a) Conformance part.** New file test/elm-conformance/src/JsonLargeUnsignedTest.elm, recorded from node. Elm values:
    - `float 2^63`: `D.decodeString D.float "9223372036854775808" |> Result.map String.fromFloat` → `"Ok \"9223372036854776000\""`, or log the inner string directly.
    - `float 2^64-1`: `"18446744073709551615"` → `"18446744073709552000"`
    - `value 2^63`: `D.decodeString D.value "9223372036854775808" |> Result.map (E.encode 0)` → `"9223372036854776000"`
    - `int max`: `"9223372036854775807"` as Float → `"9223372036854775807"`; JS rounds to `9223372036854776000`, so record whatever node gives.

    Today eco gives `-9223372036854775808` (sign flipped). Mark it `-- XFAIL-NATIVE: JSON-05` until this fix and JSON-NEW-1 have both landed: the `value` row also needs the JS number formatting, because nlohmann would print `9.223372036854776e+18`.
  - **(b) eco-only part, `Decode.int` range.** New file test/elm-json/src/DecodeIntRangeTest.elm with eco expectations:
    - `D.decodeString D.int "9223372036854775807"` → `Ok 9223372036854775807`
    - `"-9223372036854775808"` → `Ok -9223372036854775808`
    - `"9223372036854775808" |> Result.toMaybe` → `Nothing` (today it is `Just -9223372036854775808`)

    Mark this file XFAIL-NATIVE until the fix.
- **Fix:** In `jsonToHeap` (E/json/JsonExports.cpp:755), test `j.is_number_unsigned()` before the integer branch. If `j.get<uint64_t>() > INT64_MAX`, return `makeJsonFloat(static_cast<f64>(u))`; otherwise use the i64 path. The alternative is to do this in `OrderedDomBuilder::number_unsigned` (:337) by storing `json(static_cast<double>(n))` when `n > INT64_MAX`. That fixes every consumer at the source, and I prefer it. `DEC_INT` then rejects the value unless JSON-06's integral-float acceptance applies, and its i64-range check must reject 2^63. Risk: low.
- **Shares:** test (a) depends on the JSON-NEW-1 fix. The `DEC_INT` range rule is shared with JSON-06.
- **User decision:** Elm/JS answers `Ok 9223372036854775808` (a JS double) for `Decode.int`. eco's 64-bit Int cannot hold it, so rejecting with "Expecting an INT" is a deliberate divergence. Record it in the conformance notes.

#### JSON-06: Decode.int rejects 1.0
- **Triage:** CERTAIN · MEDIUM
- **Test kind:** E2E · **Exposes it:** high confidence
- **Test:** Add a new file, test/elm-conformance/src/JsonDecodeIntIntegralFloatTest.elm, recorded from node, logging `Debug.toString` of each Result. Elm values:
  - `"1.0"` → `Ok 1`
  - `"1e3"` → `Ok 1000`
  - `"1E2"` → `Ok 100`
  - `"-0.0"` → `Ok 0` (JS prints -0 as `0`; check that eco's Int also prints `0`)
  - `D.list D.int` on `"[2.0,3]"` → `Ok [2,3]`
  - `D.decodeValue D.int (E.float 1)` → `Ok 1`
  - `"1.5" |> Result.toMaybe` → `Nothing`
  - `D.decodeValue D.int (E.float 1.5) |> Result.toMaybe` → `Nothing`

  Today every "Ok" row gives `Err ... Expecting an INT`. Mark the file `-- XFAIL-NATIVE: JSON-06` until the fix. Keep out-of-i64 integral floats such as `"1e300"` out of this file: Elm gives `Ok 1e+300`, eco cannot represent it, and that case goes in the eco-only DecodeIntRangeTest from JSON-05 (expect `Nothing`).
- **Fix:** In `runDecoder` `DEC_INT` (E/json/JsonExports.cpp:1090), also accept `CTOR_JSON_FLOAT` when `d` is finite, `std::trunc(d) == d`, and `-9223372036854775808.0 <= d && d < 9223372036854775808.0`. Then `allocInt(static_cast<i64>(d))`; `-0.0` becomes 0. Any other value keeps `expecting("an INT", ...)`. Also check that `oneOf` error paths and `Decode.value` are unaffected. Risk: low.
- **Shares:** JSON-05 (the same i64-range check, and DecodeIntRangeTest). JSON-NEW-1 makes eco's own `Encode.float 3` round-trip through `Decode.int` even without this fix, because the output becomes `3`.

#### JSON-NEW-1: Encode.float of an integral value prints a trailing ".0"
- **Triage:** CERTAIN · MEDIUM
- **Test kind:** E2E · **Exposes it:** high confidence
- **Test:** Add a new file, test/elm-conformance/src/JsonEncodeFloatFormatTest.elm, recorded from node. Elm values:
  - `E.float 0` → `"0"`
  - `E.float 3` → `"3"`
  - `E.float -0` → `"0"`
  - `E.float 123456789` → `"123456789"`
  - `E.float 1e21` → `"1e+21"`
  - `E.float 1.5e-7` → `"1.5e-7"`
  - `E.float 1e-6` → `"0.000001"`
  - `E.float (0.1+0.2)` → `"0.30000000000000004"`
  - `E.float (0/0)` → `"null"`
  - `E.float (1/0)` → `"null"`
  - `E.list E.float [1, 2.5]` → `"[1,2.5]"`
  - `D.decodeString D.value "1.0" |> Result.map (E.encode 0)` → `Ok "1"`
  - `D.decodeString D.int (E.encode 0 (E.float 3))` → `Ok 3`

  Today eco prints `0.0`, `3.0`, `-0.0`, `1e-07`, and so on. Mark the file `-- XFAIL-NATIVE: JSON-NEW-1` until the fix. Also change test/elm-json/src/EncodeFloatTest.elm:9 from `zero: "0.0"` to `zero: "0"` in the fixing commit; it pins the bug today.
- **Fix:** In the JSON-01 custom serializer, write `number_float` with `StringOps::formatFloatShortest` (runtime/src/allocator/StringOps.hpp:1298, JS `Number.prototype.toString` semantics), and NaN/±Infinity as `null` (JSON.stringify). Write `number_integer`/`number_unsigned` as decimal. Keep the Int formatting 64-bit exact: JS rounds above 2^53, and that is the existing deliberate 64-bit-Int divergence. No invariants are touched. Risk: low, but every float in JSON output changes, so grep the CHECK lines in test/ for `.0` JSON floats; only EncodeFloatTest was found.
- **Shares:** The fix is shared with JSON-01 (one serializer). JSON-05's conformance test depends on it.

### Area LIST

#### LIST-01: List.fromArray conses Float/Char as Int-kind cells
- **Triage:** CERTAIN · LOW
- **Test kind:** static check · **Exposes it:** low confidence. No Elm program can reach the ElmArray branch, so no behavioural test can expose the bug.
- **Test:** No E2E is possible. `Elm.Kernel.List.fromArray` is typed `List a -> List a` (compiler/src/Compiler/Type/KernelIntrinsics.elm:166-171), and its only use is elm/core String.elm:191, which passes a list and so takes the Tag_Cons/ConsChunk passthrough at E/core/ListExports.cpp:332-334. The guard is the existing String.split coverage: test/elm, test/elm-core and test/elm-regex RegexSplitTest all go through `fromArray (String.split ...)`. Those suites must stay green after the branch is removed. As a static check, after the fix `grep -n "Tag_Array\|ElmArray" E/core/ListExports.cpp` should show nothing inside `Elm_Kernel_List_fromArray`. No XFAIL.
- **Fix:** In `Elm_Kernel_List_fromArray` (E/core/ListExports.cpp:318-359), delete the ElmArray branch (:337-358). Keep the constant passthrough (:321-323), the null-to-Nil case and the Cons/ConsChunk passthrough. Any other tag should be a hard error rather than a silent Nil: `assert` + `explicitFatal`, or simply return `array`. Update the comment at :346-348. If the branch is kept instead, replace `List::cons(head, result, !isUnboxed)` with `alloc::cons(head, result, kind)`, taking the kind from the array header the way `Elm_Kernel_List_cons_Char` passes `head_kind` (REP_HEAP_* slot-kind rules, CGEN invariants on Int/Float/Char unboxing). I recommend deletion. Risk: very low, because only the unreachable branch changes. After the deletion, `List::cons`'s only caller (ListExports.cpp:293) passes `true`, so its `headIsBoxed=false` path becomes dead too. Its doc comment in List.hpp:31 should then say "boxed only", or the bool parameter should go.
- **Shares:** The same commit as the List.cpp dead-code deletion (LIST-03/04/05/08), since both edit List.hpp's doc.

#### LIST-03: dead sortWith resolves raw bits after a boxed first node
- **Triage:** CERTAIN · LOW
- **Test kind:** static check · **Exposes it:** high confidence (for the deadness; the bug itself can't be reached)
- **Test:** Run `grep -rn "Kernel::List::sort\|List::sortBy\|List::sortWith\|List::fromArray" /work/elm-kernel-cpp /work/eco-kernel-cpp /work/system-kernel-cpp /work/runtime /work/test --include=*.cpp --include=*.hpp`. Today it should hit only E/core/List.cpp and List.hpp. After the deletion, the link check is a full `cmake --build build` plus the `test` binary build. No XFAIL.
- **Fix:** Delete these from E/core/List.cpp: `fromArray` (:15-21), `sortBy` (:23-47) and `sortWith` (:49-86). Delete their declarations, the `KeyFunc`/`CmpFunc` typedefs and their docs from E/core/List.hpp (:33-69). Rewrite the List.hpp header comment (:11-14) so it says only `cons` remains. Keep `List::cons` (ListExports.cpp:293 uses it) and the List.cpp entry in elm-kernel-cpp/CMakeLists.txt:79. Do NOT delete the live exports `Elm_Kernel_List_sortBy/sortWith` in ListExports.cpp:720/780, which have the same names. After the deletion, `ListOps::sortBy`/`ListOps::sortWith` (runtime/src/allocator/ListOps.cpp:496,521; ListOps.hpp:337,347) have no callers left: test/allocator/ListOpsTest.cpp uses only `ListOps::sort`. Record them as a new DEAD candidate to triage separately; don't delete them in this commit (rule: triage before delete). Risk: none, apart from the include fallout if List.cpp loses its only use of ListOps.hpp.
- **Shares:** The same deletion fixes LIST-04, LIST-05 and LIST-08. One commit with LIST-01.

#### LIST-04: dead List.cpp sorts resolve embedded constants
- **Triage:** CERTAIN · LOW
- **Test kind:** static check · **Exposes it:** high confidence (for the deadness)
- **Test:** The same grep and link check as LIST-03. A runtime test would need a C++ caller that doesn't exist. Writing one only to watch it assert on `resolve(Nothing)` would pin code we are deleting, so don't.
- **Fix:** Covered by the LIST-03 deletion of `sortBy`/`sortWith`. Nothing else changes.
- **Shares:** LIST-03, LIST-05, LIST-08 (one deletion)

#### LIST-05: dead sortBy boxes unboxed elements as Int
- **Triage:** CERTAIN · LOW
- **Test kind:** static check · **Exposes it:** high confidence (for the deadness)
- **Test:** The same grep and link check as LIST-03.
- **Fix:** Covered by the LIST-03 deletion of `sortBy` and the `KeyFunc` typedef.
- **Shares:** LIST-03, LIST-04, LIST-08

#### LIST-08: dead sortWith narrows i64 to int
- **Triage:** CERTAIN · LOW
- **Test kind:** static check · **Exposes it:** high confidence (for the deadness)
- **Test:** The same grep and link check as LIST-03. The live `List.sortWith` export already has E2E coverage in test/elm-core and test/elm. Optionally, check that one of those tests has a comparator built from an Int `compare` on values 2^32 apart. That exercises the live path, not this dead one.
- **Fix:** Covered by the LIST-03 deletion of `sortWith` and the `CmpFunc` typedef.
- **Shares:** LIST-03, LIST-04, LIST-05

### Area PARSE

#### PARSE-01: long UTF-16 ropes reach flatStringView unflattened
- **Triage:** CERTAIN · HIGH
- **Test kind:** E2E · **Exposes it:** high confidence (`build` preset: the tag assert in `flatStringView` aborts; release: the output is wrong or the program segfaults)
- **Test:** Add test/elm-parser/src/ParserLargeRopeInputTest.elm. It builds sources above `string_flatten_limit` (131,072 units) at run time with `++`, which always makes a rope above the limit (StringOps.cpp:524/617), and runs one parser per kernel primitive on each:
  - `big = String.repeat 70000 "ab" ++ "x"` (140,001 units; an ASCII rope).
  - `wide = String.repeat 70000 "\u{00E9}b" ++ "x"` (a rope with UTF-16 leaves).
  - `sliced = String.dropLeft 1 big` (a slice above the limit).

  Take the repeat count from `List.length (List.range 1 70000)` or similar, so no front-end constant folding (CGEN_082) can turn the source into a flat literal. The parsers:
  - `chompWhile (\c -> c /= 'x') |> getChompedString |> map String.length` (`isSubChar`), followed by `|. symbol "x" |. end` (`isSubString`).
  - `chompUntil "x"` followed by `getOffset` (`findSubString`).
  - The same `chompWhile` on `wide` and on `sliced`.

  CHECK lines:
  - `-- CHECK: rope chompWhile: Ok 140000`
  - `-- CHECK: rope chompUntil: Ok 140000`
  - `-- CHECK: wide rope chompWhile: Ok 140000`
  - `-- CHECK: slice chompWhile: Ok 139999`

  These are Elm's results, which are plain arithmetic here. Confirm them once by compiling the program with `build/toolchain/bin/elm make` and running it on node (elm-parser is not a project in run-js-e2e.js). Today the native run aborts with the `flatStringView` tag assertion on the first primitive. Mark the file `-- XFAIL-NATIVE: PARSE-01 rope above string_flatten_limit reaches flatStringView` until the fix lands. The harness then reports XPASS once the fix works, so remove the mark in the same commit as the fix.
- **Fix:** In E/parser/ParserExports.cpp, make `parserFlatten` (:67-72) keep its constant and UTF-8 early returns and call `StringOps::flattenToLeaf(hp)` instead of `StringOps::ensureFlat(hp)`. `flattenToLeaf` turns every form, including slices and ropes above the limit, into a UTF-16 leaf or a large String. Update the comment at :61-66, and add `assert(tag is Tag_String || Tag_LargeStringHeader)` in `parserView` before `flatStringView` so a future regression fails loudly. Invariants: HEAP_025 (string forms). `parserFlatten` is already a GC point, and the callers (`isSubString`/`findSubString` :203-211, :246-254) already re-derive both views after flattening both strings, so the GC discipline does not change. Risk: performance only. A rope above the limit is now copied at every primitive call, which is O(n) per call and the same thing that already happens today for ropes at or below the limit. Correctness comes first (user rule). A segment-aware `ParserStr` or a once-per-run flatten could be a follow-up if a benchmark shows the cost.
- **Shares:** -

#### PARSE-03: consumeBase accumulation overflows int64
- **Triage:** CERTAIN · MEDIUM
- **Test kind:** E2E · **Exposes it:** high confidence (today `0xFFFFFFFFFFFFFFFF` gives `Ok -1`, and longer inputs give garbage)
- **Test:** Two files.
  1. test/elm-parser/src/ParserIntOverflowTest.elm pins eco's chosen semantics. It uses `Parser.number` with hex, octal and binary enabled (as ParserHexIntTest/ParserOctalBinaryIntTest do) on:
     - `0x7FFFFFFFFFFFFFFF` (the boundary; it must stay `Ok 9223372036854775807`)
     - `0xFFFFFFFFFFFFFFFF`
     - `0x1FFFFFFFFFFFFFFFF`
     - 22 octal sevens
     - 65 binary ones

     It also runs a decimal `Parser.int` on `"99999999999999999999"` for comparison. Under the recommended semantics (below), each overflowing case gives `Err` with the `invalid` problem, exactly what the decimal case already gives through `String.toInt` returning `Nothing`. Write the CHECK lines from the native run after the fix, checked by hand against that rule. Until the fix, mark the file XFAIL-NATIVE.
  2. Optional: test/elm-conformance/src/ParserIntOverflowDivergenceTest.elm records Elm's double results (for example `Ok 18446744073709552000`) with `node test/scripts/run-js-e2e.js --project elm-conformance --record ParserIntOverflowDivergenceTest`. It carries a permanent `-- XFAIL-NATIVE: deliberate 64-bit Int divergence`, like FloatDivergenceTest. This needs `elm/parser` added to test/elm-conformance/elm.json.

  Running the build with UBSan (`-fsanitize=signed-integer-overflow`) would also flag the current code, but no preset has it, so the E2E test is the gate.
- **Fix:** In E/parser/ParserExports.cpp, `Elm_Kernel_Parser_consumeBase` (:316) and `Elm_Kernel_Parser_consumeBase16` (:341) should accumulate with `__builtin_mul_overflow`/`__builtin_add_overflow` on `i64`. On overflow, keep consuming the digit run, then return `(startOffset, 0)`. elm/parser's `finalizeInt` treats `startOffset == endOffset` as the `invalid` problem, so the outcome matches the decimal path. Update the doc comments ("must fit ... not checked"). No invariant is touched. Risk: low; inputs that fit are unchanged. **This needs a user decision on the semantics.** The options are:
  - `invalid`, which is consistent with decimal and is my recommendation;
  - wrap as a uint64 bit pattern, so `0xFFFF...` gives -1;
  - saturate to maxInt.

  None of these can match JS doubles.
- **Shares:** -

#### PARSE-04: isHighSurrogate accepts low surrogates
- **Triage:** CERTAIN · LOW
- **Test kind:** E2E · **Exposes it:** high confidence
- **Test:** Add test/elm-conformance/src/ParserLoneLowSurrogateTest.elm, and add `elm/parser` 1.1.0 to that project's elm.json. Record its CHECK lines from Elm on node with `node test/scripts/run-js-e2e.js --project elm-conformance --record ParserLoneLowSurrogateTest`. Use `src = String.fromList [Char.fromCode 0xDC00, Char.fromCode 0xDC01]` and log:
  - `Parser.run (chompIf (\c -> Char.toCode c == 0xDC00)) src`. JS gives `Ok ()`, because JS's `Char.toCode` of the 2-unit Char is 0xDC00; eco gives `Err` (its code is 0x110001).
  - `Parser.run (chompIf (\c -> Char.toCode c > 0x10FFFF)) src`. JS gives `Err`; eco gives `Ok ()`.
  - `Parser.run (getChompedString (chompIf (\_ -> True)) |> map String.length) src`. JS gives `Ok 2`, because it advances 2 units.

  Compare only code points with `<`/`==` on Ints, never Chars, so the mode guard has nothing to object to. Today the first two lines fail natively. Mark the file XFAIL-NATIVE until the fix.
- **Fix:** In E/parser/ParserExports.cpp `Elm_Kernel_Parser_isSubChar` (:164-175), keep the `isHighSurrogate` (0xF800) pairing test and `advance = 2`, which match JS's `substr(offset, 2)` advance. Combine the pair into a code point only when `(c0 & 0xFC00) == 0xD800` (a real high surrogate); otherwise pass `c0` itself, which is what JS `Char.toCode` returns for that 2-unit Char. Rename `isHighSurrogate` to `isSurrogate` (its comment already says 0xD800-0xDFFF) and leave `advancePosition`/`isSubString` as they are for JS parity. Risk: very low; only lone-low-surrogate input changes. A lone *high* or low surrogate followed by a non-surrogate already advances 1 here where JS advances 2. That divergence is out of scope; record it in the test as a second divergence only if the user wants it closed.
- **Shares:** The elm-conformance `elm/parser` dependency addition is shared with PARSE-03's optional divergence test.

#### PARSE-NEW-1: Allocator::resolve on an embedded constant crashes in every build; the kernels' "if (!ptr)" guards after it are dead
- **Triage:** CERTAIN · LOW
- **Test kind:** static check (plus an optional C++ unit death test) · **Exposes it:** high confidence for the dead-guard pattern; medium for the crash (assert builds only)
- **Test:**
  - **Static check:** add test/scripts/check-resolve-null-guard.sh (same style as the other test/scripts/check-*.sh scripts). It greps E/, K/, S/ and runtime/src for `resolve(` whose result is tested with `if (!x)` or `x ? ... :` within the next few lines, and fails while any listed site remains. Known hits: E/http/HttpEffectManager.cpp:160, S/System/SystemManager.cpp:169, S/HttpServer/HttpServerManager.cpp:162, and the others found by the grep.
  - **Optional unit test:** in test/allocator/AllocatorTest.cpp, fork (the pattern used in IncrementalMarkTest.cpp:197) and call `Allocator::instance().resolve(<Unit/Nil/True constant>)` in the child. Expect the child to die with SIGABRT in the `build`/`dev` presets. This documents that `resolve` never returns null. Run it with `ulimit -c 0`, or the core dumps fill /work (memory: core dumps).
  - No XFAIL: no behaviour is wrong today, since none of the reviewed sites can receive a constant.
- **Fix:**
  - Document on `Allocator::resolve` (Allocator.hpp near :660 and Allocator.cpp:1140) that it never returns null and must not be given an embedded constant.
  - Promote the file-local `resolveOrNull` from E/http/HttpExports.cpp:239 to a shared helper, such as `alloc::resolveOrNull(HPointer)` in HeapHelpers.hpp, returning nullptr for an embedded constant.
  - At each dead-guard site, either delete the dead `if (!p)` branch (the value can never be a constant) or switch to `resolveOrNull` (it can be a constant). Decide per site by reading it.

  This is related to HEAP_* embedded-constant rules; check that invariants.csv has no row stating otherwise. Risk: low; this is documentation plus dead-branch removal.
- **Shares:** -

### Area PROC

#### PROC-02: killJob can signal a reused pid
- **Triage:** CERTAIN · LOW
- **Test kind:** C++ unit · **Exposes it:** high confidence (deterministic for the root cause, the pid being freed before the eco thread learns of the exit; the actual pid reuse is not reproduced)
- **Test:** extend `/work/test/platform/PlatformServicesTest.cpp` (already in the `test` binary, has `spawnExit` and `waitFor`) with `test_wait_result_keeps_pid_until_popped`: `pid = spawnExit(0)`, `ws.submit(pid, 401, WaitLane::EcoSystem)`, `waitFor(hasReady(EcoSystem))`, and then, before `tryPopReady`, probe with `::waitid(P_PID, pid, &info, WEXITED | WNOHANG | WNOWAIT)`. Today it returns -1/ECHILD: the wait thread's `waitpid(pid, &status, 0)` has already freed the pid while the result is still queued, so `killJob` could `kill()` a reused pid. With the fix it returns 0 with `info.si_pid == pid`, because the pid is still a zombie owned by us. Then `tryPopReady` and assert `r.exitCode == 0`, and assert that a second `waitid(... WNOHANG)` now gives ECHILD (the pop reaped it, so no zombie leaks). Report through `XfailGuard::report("PROC-02", defect = (rc != 0 && errno == ECHILD), ...)` until the fix lands. Then turn it into plain asserts. POSIX only (`#if !defined(_WIN32)`; Windows waits on a process HANDLE, which pins the process object, so it has no reuse problem). Run with `build/test/test --filter "xfail "` (ulimit -c 0, per the core-dump memory note).
- **Fix:** `/work/runtime/src/platform/WaitService.cpp` `submit` (POSIX lambda, :76-86): wait with `waitid(P_PID, pid, &info, WEXITED | WNOWAIT)` (EINTR loop) so the child stays a zombie, and queue a `Ready` that carries the pid (add `int64_t pid` to `WaitService::Ready` in WaitService.hpp). In `tryPopReady` (eco thread, both lanes), reap with `waitpid(pid, &status, WNOHANG)` and fill `rawStatus`/`exitCode` there. The pid is then freed only after the consumer runs on the eco thread. `waitDrain` (S/ChildProcess/ChildProcess.cpp:412) and `killJob` both run on that thread, so `killJob` can no longer see `!exited` for a freed pid: before the pop it signals a zombie, which is harmless. This also covers the EcoKernel lane (K/Process.cpp `waitServiceDrain`) and the "job gone after heap reset" `continue` (the pop still reaps). A Ready that is never popped leaves a zombie until exit, which is acceptable. Keep the ECHILD path. Alternative (Linux ≥5.3 only): `pidfd_open` right after `spawnChild` in `childProcessRunBody`/the manager's spawn, kept in `ChildJob`, with `killJob` using `pidfd_send_signal`. Portable WNOWAIT is preferred. Invariants: SYS_003 (services see only plain data and tokens; unchanged), SYS_007. The existing `test_wait_*` tests must still pass (`test_wait_exited_before_submit_is_delivered` already uses WNOWAIT itself, which is compatible). Risk: low. macOS supports `waitid` + `WNOWAIT`.
- **Shares:** -

#### PROC-03: spawnProcess ignores stdout_/stderr_
- **Triage:** CERTAIN · LOW
- **Test kind:** E2E · **Exposes it:** high confidence
- **Test:** new `/work/test/eco-kernel/src/ProcessStdoutPipeTest.elm`. `Eco.Process.spawnProcess { cmd = "sh", args = [ "-c", "echo leaked-stdout; echo leaked-stderr >&2" ], stdin = Inherit, stdout = CreatePipe, stderr = CreatePipe }`, then `wait`, then `Debug.log` either the result (`"stdout pipe: ExitSuccess"`) or the spawn error (`"stdout pipe: OtherProcessError ..."`). Directives: `-- EXIT: 0` (process mode, so the grandchild's raw output, which lands in the per-test output file, is part of what CHECK sees), `-- CHECK-NOT: leaked-stdout`, `-- CHECK-NOT: leaked-stderr`, plus one `-- CHECK:` line that depends on the fix chosen (see Fix). Today both "leaked" lines appear, so the test fails. Mark it `-- XFAIL-NATIVE: PROC-03 stdout/stderr CreatePipe is ignored (child inherits)` until fixed. Stock Elm cannot run this (it is an eco/kernel API), so the expected output comes from the API contract, not from node. Linux/macOS only (`sh`). Add `-- LINUX-ONLY:` if the Windows harness would pick it up.
- **Fix:** **needs a user decision**, because no backend can ever read such a pipe: the record returns only `{ stdinHandle, processHandle }`, and the JS twin (`/work/eco-kernel-cpp/src/Eco/Kernel/Process.js:44-66`) makes a real pipe that nobody reads, so a child blocks once it fills that pipe's buffer. Options: (A) remove the `stdout`/`stderr` fields from `spawnProcess` (`/work/eco-kernel-cpp/src/Eco/Process.elm:66-90`, the F5 kernel arity in Process.js, `spawnProcessBody` K/Process.cpp:78-114, and the `spawnProcess` row in `compiler/.../KernelSetFacts.elm:1404`). This is an API break, but the compiler is the only reference and it does not call it. The test is then unnecessary because the type checker enforces it. (B) Fail the spawn when stdout or stderr is `CreatePipe` (C++: return `failErrno`/an `OtherProcessError` before `startChild`; JS: `callback(__Scheduler_fail(...))` with the same tuple). The test then expects `-- CHECK: stdout pipe: OtherProcessError`. (C) Treat `CreatePipe` for stdout/stderr as "discard" (new `StdioMode` that maps 1/2 to the null device in runtime/src/platform/Spawn.cpp, and `'ignore'` in JS). The test then expects `-- CHECK: stdout pipe: ExitSuccess`, but the constructor name lies. Recommendation: (A), or (B) if the API must stay stable. Whichever is chosen, both twins (C++ and JS) must change together. Risk: low.
- **Shares:** PROC-NEW-1 (same module and the same `s_streamHandles`/spawnProcess code; it could be one fix commit, but keep separate test files so the XFAIL marks can be lifted independently)

#### PROC-05: kill on exited run with open output does nothing
- **Triage:** LIKELY · MEDIUM
- **Test kind:** E2E · **Exposes it:** high confidence
- **Test:** new `/work/test/eco-system/src/ProcessKillExitedRunTest.elm`, modelled on `ProcessKillTest.elm` and `LiveDetachedRunDurationTest.elm`. `Process.spawn (P.run "sh" [ "-c", "sleep 6 & exit 0" ] { shell = P.NoShell, workingDirectory = P.InheritWorkingDirectory, environmentVariables = P.InheritEnvironmentVariables, maximumBytesWrittenToStreams = 0, runDuration = P.NoLimit } |> ... Stream.logLine "run completed")`, then `Process.sleep 300` (sh has exited by then and `waitDrain` has set `exited`; the backgrounded `sleep 6` still holds stdout/stderr), then `Process.kill pid`, then record `Time.now` as t1 in the model. `subscriptions = \_ -> System.onEmptyEventLoop Empty`; on `Empty`, `Task.perform Ended Time.now` and `Debug.log "prompt" (t - t1 < 3000)`. Directives: `-- CHECK: prompt: True`, `-- CHECK-NOT: run completed`, `-- EXIT: 0`. Today the job's hold lives until the grandchild closes the pipes (~6 s), so the loop first empties at about 6 s and the log is `prompt: False`. The run is still well under the 60 s watchdog. Mark `-- XFAIL-NATIVE: PROC-05 kill of an exited run with open output keeps its hold` until fixed. POSIX only (on Windows the output is never collected and nothing waits on it; add `-- LINUX-ONLY:` if needed). This is the test the triage entry itself suggested.
- **Fix:** `/work/system-kernel-cpp/src/eco-system/ChildProcess/ChildProcess.cpp` `cancelRunByToken` (:464-473). When the matching job has `exited && !outputDone`, set `job.killed = true` and call `advanceJob(id)` (this wakes the collector via `stopRequested`, then `runOutputDrain` leads to `completeRun`, which finds the resume already taken and releases `j->hold`). Otherwise call `killJob(id)` as today. Return immediately after the call (`advanceJob` may erase the job, which invalidates the map iterator). This is the same logic as `runDurationEval` (:254-256), so factor both into one `killRun(jobId)` helper. Update the header doc of `childProcessRunBody` ("Killing the Task kills the job, unless the exit has already been seen"). Invariants: LIVE_001 (a killed task is no longer waited for), LIVE_003 (the hold is still released exactly once, by `completeRun`). Risk: low. The background grandchild keeps running but gets EPIPE/SIGPIPE on its next write, as with the runDuration path.
- **Shares:** -

#### PROC-06: exception after parkResume leaks job hold
- **Triage:** LIKELY · LOW
- **Test kind:** C++ unit · **Exposes it:** medium confidence (needs a test seam. Real OOM in this window cannot be produced reliably)
- **Test:** in `/work/test/eco-system-core/EcoSystemCoreTest.cpp` (the `eco-system-core-test` target; add `EcoSystem_ChildProcess` to its `target_link_libraries` in `/work/system-kernel-cpp/CMakeLists.txt:354`). Add a test-only fault hook in ChildProcess.cpp, e.g. `namespace Eco::System::testing { inline void (*g_runAfterPark)() = nullptr; }`, declared in ChildProcess.hpp and called right before `startJobWatch` in `childProcessRunBody`, and again inside `startJobWatch` before `submit`. The test does `initRuntime`, builds the `captured` tuple for `( ( "sh", [ "-c", "sleep 1" ] ), ( NoShell, Inherit ), ( Inherit, ( 0, 500 ) ) )` (runDuration > 0 also arms the timer), and passes a resume closure that records the failure Task. It sets the hook to `throw std::bad_alloc()`, calls `childProcessRunBody`, and asserts: the resume got the RunErr failure (this already works today), `childJobs().size()` is back to its value before the call, and no hold is left (`Scheduler::instance().reportHolds` text, or a pending-async count if the test has one; otherwise check the job's `hold == kNoHold`). Today the job and its hold stay in the table: defect. The binary has no xfail convention, so add a local `xfailReport(id, defect, how)` mirroring `/work/test/XfailGuard.hpp` (`ECO_TEST_XFAIL=strict`). Run once: `cmake --build build --target eco-system-core-test` then `build/system-kernel-cpp/eco-system-core-test 2>&1 | tee /tmp/test_output.txt`.
- **Fix:** ChildProcess.cpp `childProcessRunBody` (:592-604) and `startJobWatch` (:489-504). Wrap everything after `parkResume` in a local try/catch. On an exception: (1) if the runDuration timer was parked, withdraw it (`cancelTimer(j->timerToken)`); (2) if `submit` did not complete, SIGTERM the child, close the collector's fds or stop it, and erase the job; if `submit` did complete, keep the job so the exit is still reaped but mark it killed; (3) release `j->hold` exactly once and set `j->hold = kNoHold`, `j->resumeToken = 0`; (4) rethrow so `ECO_SYSTEM_ASYNC_GUARD` takes the resume and fails the Task. Simpler variant: call `WaitService::submit` before `parkResume`. This is safe because all drains run on the eco thread after the body returns. Then allocate the timer closure last, so the only throws after the park are the timer's, which the catch withdraws. Invariant: LIVE_003 (exactly-once release on every path; census builds abort on a double release, which also catches mistakes in this fix). Risk: low-medium (exception paths are easy to get subtly wrong; the census build is the guard).
- **Shares:** -

#### PROC-07: Windows startCollector leaks pipe read ends
- **Triage:** CERTAIN · MEDIUM
- **Test kind:** E2E · **Exposes it:** medium confidence (Windows-only; per the WINDOWS LOW PRIORITY rule it may stay unverified)
- **Test:** new `/work/test/eco-system/src/ProcessRunLargeOutputTest.elm`. `P.run` a command that writes about 200 KB to stdout and 1 line to stderr, with `runDuration = P.Milliseconds 20000` so a hang ends as a kill and not a watchdog timeout. Log `"bytes: " ++ String.fromInt (Bytes.width out)` and the result kind. The command is picked from the platform the program reports (as `PlatformArchTest.elm` reads it): POSIX `sh -c "head -c 200000 /dev/zero"`, Windows a `cmd /c` loop or `powershell -Command "[Console]::Out.Write('x' * 200000)"`. `-- CHECK: bytes: 200000`. On POSIX it passes today, which makes it a useful regression guard for the collector. On Windows today the child blocks in `WriteFile` once the pipe buffer is full, the 20 s limit kills it, and the log shows a killed run with `bytes: 0`. The test therefore fails on Windows only. If the Windows harness is ever run, a per-platform XFAIL would be needed. XFAIL-NATIVE is file-wide, so either leave it unmarked and note it in `test/win32` or skip it via an existing Windows-skip directive. A Windows unit check for the fd leak (count open CRT fds before and after N runs) is possible in `test/win32` but not worth it at this priority.
- **Fix:** `/work/system-kernel-cpp/src/eco-system/ChildProcess/ChildProcess.cpp` `startCollector` (:447-461). Minimum: on `_WIN32`, `_close(col->outFd)` and `_close(col->errFd)` before setting them to -1. This stops the leak and the hang; the child then gets a broken pipe, which some programs treat as an error, so runs may fail. Real fix: a Windows collector, i.e. one `std::thread` per run calling blocking `_read` (or `ReadFile` on `_get_osfhandle`) on both fds (two threads, or one thread per fd), posting to the same `RunOutput` queue. For `stopRequested`, use `CancelSynchronousIo` on the reader thread(s), or close the handles, in place of the POSIX `wake` pipe write in `advanceJob` (:396-401 is `#ifndef _WIN32`). Update the header comment ("On Windows the output is never collected"). Unverified on Windows is acceptable per project policy. Risk: medium (Windows, cannot be built here).
- **Shares:** -

#### PROC-08: Process.wait not cancellable
- **Triage:** CERTAIN · LOW
- **Test kind:** E2E · **Exposes it:** medium-high confidence (relies on a 4 s timing margin)
- **Test:** new `/work/test/eco-kernel/src/ProcessWaitKillTest.elm` (eco/system's `onEmptyEventLoop` is not available to the eco-kernel suite, and the eco-system suite does not depend on eco/kernel, so it uses a "late output" probe). `Eco.Process.spawn "sh" [ "-c", "sleep 4; echo late-child-output" ]`, then `Process.spawn (P.wait h)` (elm/core Process), then `Process.sleep 100`, then `Process.kill waiterPid`, then `Debug.log "killed" ()`. Directives: `-- EXIT: 0`, `-- CHECK: killed`, `-- CHECK-NOT: late-child-output`. The harness reads the per-test output file as soon as the program exits (test/SpawnedChildren.hpp `StdioMode::ToFile`). Today the wait's hold keeps the program alive until the child exits, so `late-child-output` is written before exit and the CHECK-NOT fails. With the fix the program ends about 100 ms in, and the orphaned `sh` writes 4 s later, after the harness has read the file. Mark `-- XFAIL-NATIVE: PROC-08 killed Eco.Process.wait keeps its hold` until fixed. POSIX only.
- **Fix:** `/work/eco-kernel-cpp/src/eco-kernel/Process.cpp` `waitBody` (:165-179). Return a real kill handle in place of `unit()`: an `allocClosureK` evaluator capturing the token, modelled on `/work/system-kernel-cpp/src/eco-system/Core/KillHandle.cpp` (eco-kernel cannot link eco-system, so copy the roughly 15 lines). When the task is killed, it calls `takePendingResume(token)`, records the token in a file-static `std::unordered_set<uint64_t> s_withdrawnWaits` (eco thread only), and calls `releaseHold(token)`. In `waitServiceDrain` (:120-146), when `takePendingResume` returns nil, release the hold only if the token is not in `s_withdrawnWaits`; otherwise erase it from the set and skip the release. Without this change it would be a double release. Do not kill the child: Elm/Node semantics are that killing a waiter does not kill the waited-for process (the JS twin does not either). The detached WaitService thread stays blocked in `waitpid` until the child exits. That is harmless, and the process exit ends it. Invariants: LIVE_001, LIVE_003 (exactly-once release; census/Debug builds abort on a double release, so run the test on a `dev` build once as well), LIVE_006 (use only the hold API). Risk: low.
- **Shares:** -

#### PROC-NEW-1: Console.write to a spawnProcess stdin handle is a silent no-op
- **Triage:** CERTAIN · MEDIUM
- **Test kind:** E2E · **Exposes it:** high confidence
- **Test:** new `/work/test/eco-kernel/src/ProcessStdinPipeWriteTest.elm`. `spawnProcess { cmd = "sh", args = [ "-c", "read line; echo \"got:[$line]\"" ], stdin = CreatePipe, stdout = Inherit, stderr = Inherit }`; on `Just fd`: `Eco.Console.write (Console.Handle fd) "hello\n"`, then `Eco.File.close (File.Handle fd)`, then `wait`, then `Debug.log "waited"` with the exit code. Errors from write/close are mapped to strings and logged. Directives: `-- EXIT: 0` (so the child's inherited stdout is in the checked output), `-- CHECK: got:[hello]`, `-- CHECK-NOT: got:[]`, `-- CHECK: waited`. Today `Console.writeBody` (K/Console.cpp:65-72) returns `succeedUnit()` for any handle other than 1 or 2, so the child reads EOF and prints `got:[]`, and the first CHECK fails. Mark `-- XFAIL-NATIVE: PROC-NEW-1 Console.write ignores spawnProcess stdin handles` until fixed. Optional second case (only if the user picks "fail on unknown handle"): `Console.write (Console.Handle 987654) "x"` should log an IOError, not `Ok`. The expected output comes from the Process.elm doc (":63-65 ... can be used with Console.write and File.close"), not from stock Elm. POSIX only (`sh`).
- **Fix:** make the documented path work, as the JS twin already does (`/work/eco-kernel-cpp/src/Eco/Kernel/Console.js:17-31` writes to `_Process_streamHandles[handle]`). In `/work/eco-kernel-cpp/src/eco-kernel/Process.{hpp,cpp}`, expose `int streamHandleFd(int64_t handle)` (returns -1 when absent) and `void forgetStreamHandle(int64_t handle)` over `s_streamHandles` (eco thread only). In K/Console.cpp `writeBody`, use `fd = streamHandleFd(handle)` for handles other than 1 and 2, and loop `_eco_write` with EINTR/EPIPE handling as for stdout. Note the test children ignore SIGPIPE (SpawnedChildren.hpp:136), but production programs may not; consider `MSG_NOSIGNAL`-like handling, or accept EPIPE as an IOError. In K/File.cpp `closeBody` (:455), call `forgetStreamHandle(fd)` so a reused fd number is not written to later (the JS twin `delete`s the entry, File.js:112-114). Unknown handle: **user decision** between keeping the silent success (what JS does today) and failing with an EBADF IOError in both twins. Recommendation: fail, which matches "silent data loss" being the bug. Cross-reference: this makes `s_streamHandles` live, so a DEAD-17 fix that deletes it must not land with, or after, this fix (if it lands first, re-add the map). The cheaper alternative is a doc-only fix (Process.elm doc names `Eco.File.hWriteString`). That leaves `Console.write` silently succeeding, so the doc fix alone is not recommended. Invariant: KERNEL_TASK_IO_001 (the write stays inside the binding body). Risk: low.
- **Shares:** PROC-03 (same module), DEAD-17 (s_streamHandles)

### Area REGEX

#### REGEX-03: replaceAtMost/splitAtMost catch paths use unrooted strings
- **Triage:** CERTAIN · MEDIUM
- **Test kind:** C++ unit (primary) and E2E (secondary) · **Exposes it:** high confidence for the unit test, medium for the E2E
- **Test:**
  - **(a) C++ unit test, deterministic.** Add a new `test/allocator/RegexCatchRootingTest.cpp`/.hpp, or extend test/kernel/KernelExportsTest.cpp, registered with `XfailGuard::report("REGEX-03", ...)` while the bug is open.
    - Allocate a fresh nursery string `s` = "a,b,c,d" with `utf8ToElmString`, and keep a rooted copy `sRoot` under `StackRootGuard`.
    - Compile `,` with `Elm_Kernel_Regex_fromStringWith`.
    - Build a 1-arity closure whose C evaluator follows the pattern in test/allocator/EcoApplyClosureEvalChainTest.cpp. On call 1 it runs `Allocator::instance().minorGC()` and returns a string. On call 2 it throws `std::runtime_error`.
    - Call `Elm_Kernel_Regex_replaceAtMost(-1, re, s, closure)`.
    - Assert that the returned word equals `Export::encode(sRoot)`, the forwarded address. Today it returns the pre-GC address, so `defect = (ret != sRoot)`.
    - For `splitAtMost`: use a pattern that throws `regex_error(error_complexity)` on a later search, e.g. `,|(a+)+b`. Note that srell throws from the iterator when its 1<<21 failure counter runs out (vendor/srell.hpp:22052, :22365). Use subject "x,y," followed by 30 'a's, and call `minorGC()` between iterations. That needs a hook, so do it indirectly: make the parts so large that `utf8ToElmString` triggers a GC, or wrap the test in a tiny nursery via ECO_HEAP_CONFIG with an explicit `initAllocator` (memory: unit tests ignore ECO_HEAP_CONFIG unless they own the init). Then check that the single-element result list holds a string equal to `sRoot`'s address and contents.
    - Run under `build/test/test --filter "xfail "`, plus `ECO_TEST_XFAIL=strict` to see the failure.
  - **(b) E2E, `test/elm-regex/src/RegexCatchRootingTest.elm`.**
    - Build the subject at runtime so it lives in the nursery: `String.repeat 50 "x," ++ String.repeat 30 "a"`.
    - Use the regex `,|(a+)+b`.
    - The replacer allocates heavily on each match, e.g. `String.fromInt (List.sum (List.range 0 20000))`, to force minor GCs.
    - Log `String.length result` and `String.left 6 result`.
    - The same goes for `Regex.split`.
    - Expected eco behaviour after the fix: the catch path returns the original string, `-- CHECK: len: 130` and `-- CHECK: head: "x,x,x,"`. Today it returns garbage, crashes, or (more likely) trips an ECO_HEAP_VALIDATE build.
    - This is eco-only behaviour (JS would backtrack for a long time, not "fail"), so put it in test/elm-regex, not elm-conformance.
    - Mark it `-- XFAIL-NATIVE: REGEX-03 catch path returns unrooted str` only if it actually fails today. Without a validate build the stale nursery word may still read correctly, so this is medium confidence and the unit test is the real guard.
- **Fix:** In E/regex/RegexExports.cpp, `Elm_Kernel_Regex_replaceAtMost` (:427-430) and `Elm_Kernel_Regex_splitAtMost` (:486-490):
  - Before the first GC point, decode `str` into `HPointer strHP = Export::decode(strEnc)` under an `Elm::StackRootGuard strRoot(&strHP)`.
  - In the catch, return or `cons(boxed(strHP), ...)` from it, re-encoding.
  - Alternatively, rebuild the string from the `strUtf8` copy in the catch with `utf8ToElmString(strUtf8)`. That allocates but needs no root, which makes it simpler.
  - Separately (a semantics decision for the user): `catch (...)` also swallows C++ exceptions thrown from the user's replacer, such as kernel crashes. Narrow it to `catch (const srell::regex_error&)` and `std::bad_alloc`, and let everything else propagate.
  - Invariants: HEAP_* rooting rules (shadow-root stack, kernel-root-stack-bounded-rooting); check-root-bounded.py must still pass, since one extra guard per call is bounded.
  - Risk: low.
- **Shares:** The ECO_HEAP_CONFIG small-nursery unit-test scaffold could be reused by other kernel rooting entries. The fix is independent of REGEX-06, but if REGEX-06 moves to u16regex the catch code gets rewritten anyway, so do REGEX-03 first or fold it into that rewrite.

#### REGEX-06: regex engine is byte-wise over UTF-8
- **Triage:** CERTAIN · MEDIUM
- **Test kind:** E2E (elm-conformance) · **Exposes it:** high confidence
- **Test:** New `test/elm-conformance/src/RegexNonAsciiTest.elm`, styled like RegexUtf16IndexTest.elm (ConformanceHelp `logAll`, `re` helper). Rows:
  - `List.map .match (Regex.find (re ".") "é")`, which gives 1 match with Elm/JS and 2 bytes today. Record lengths and code points, not raw strings, so lone surrogates print stably.
  - `List.length (Regex.find (re ".") emoji)`. JS without the `u` flag gives 2, one per surrogate. Today eco gives 4.
  - `Regex.contains (re "^[éü]$") "ü"`, which is True with Elm.
  - `Regex.contains (re "\\u00e9") "é"`, True.
  - `Regex.contains (fromStringWith {caseInsensitive=True, multiline=False} "é") "É"`, True with JS (non-unicode canonicalize uses toUpperCase).
  - `Regex.contains (re "^.{3}$") "aéb"`, True.
  - `Regex.replace (re ".") (\_ -> "x") "é中"`, which gives "xx".
  - `Regex.split (re "") "é中"` (JS: ["é","中"]).
  - `Regex.split (re "é") "aéb"`.

  The CHECK lines must be recorded from stock Elm 0.19.1 on node with `node test/scripts/run-js-e2e.js --project elm-conformance --record RegexNonAsciiTest`, which uses build/toolchain/bin/elm. Do not hand-write them. The test passes on node and fails natively today. Add `-- XFAIL-NATIVE: REGEX-06 srell basic_regex<char> matches UTF-8 bytes` until the fix lands. The harness reports XPASS when it starts passing.
- **Fix:** In E/regex/RegexExports.cpp, switch from `srell::regex` (basic_regex<char>) to `srell::u16regex` / `u16cregex` over the Elm string's UTF-16 code units. `u8cregex` is the wrong choice: JS regexes without the `u` flag (elm/regex never passes `u`) treat `.` as one UTF-16 unit, so an emoji is two matches. Only a UTF-16 engine reproduces that and the surrogate halves. The work:
  - Change the table type (:54-60) and the two `new` sites (:200, :249). Compile the pattern from UTF-16 units as Regex.cpp:14-39 already sketches.
  - Iterate with `u16sregex_iterator` over a `std::u16string` copy of the subject (:281, :316 and the replace/split loops).
  - `match.position()` is then already a UTF-16 index, so `Utf16Index` (:159-190) can be deleted.
  - Build match, submatch and replacement strings straight from u16 ranges. A lone surrogate must survive, so check that the u16-to-ElmString helper doesn't run a UTF-8 round trip that would replace it with U+FFFD.
  - Confirm that srell's icase for u16 without unicode mode matches JS Canonicalize (toUpperCase-based). If it doesn't, record the difference in CaseMappingDivergenceTest-style divergence docs.

  Run the existing test/elm-regex and elm-conformance RegexMatchRecordTest/RegexUtf16IndexTest as regressions. Risk: medium. It is a rewrite of every regex entry point, and the dead `Regex.cpp` u16 sketch should either be adopted or deleted in the same change. Check the license manifest if a different srell header part is needed (same vendored file).
- **Shares:** It touches the same functions as REGEX-03 and REGEX-08. Sequence them as REGEX-03 first, then REGEX-08 (the intern key becomes `(u16 pattern, flags)`), then REGEX-06, or do all three as one regex-kernel change.

#### REGEX-08: regexTable never freed
- **Triage:** CERTAIN · MEDIUM
- **Test kind:** C++ unit · **Exposes it:** high confidence
- **Test:** Add a case to test/kernel/KernelExportsTest.cpp, or to a new regex kernel unit test shared with REGEX-03, under `XfailGuard::report("REGEX-08", ...)`:
  - Call `Elm_Kernel_Regex_fromStringWith(opts, "ab+")` twice with identical options and decode both `Just (Regex ...)` Customs.
  - Read field 0, the side-table id. Today the ids differ (1 then 2), so `defect = id1 != id2`. After the fix they are equal.
  - Also call `Elm_Kernel_Regex_never()` twice and expect the same id.
  - Add a control: different flags (caseInsensitive) or a different pattern must give a different id.

  An E2E RSS test (compile 10^6 regexes in a loop) would also show it, but it is noisy and slow, so don't use it. No platform conditions apply.
- **Fix:** In E/regex/RegexExports.cpp, add an intern map next to `regexTable()` (:54-64), `std::unordered_map<std::string, int64_t>` keyed by pattern + '\0' + flag bits. `fromStringWith` looks the key up before `new srell::regex` and reuses the id on a hit. A compile failure (Nothing) is not cached, or it is cached as a negative entry. `never` uses one function-local static id.
  - Entries are still never removed, so ids stay valid for any Regex value in the heap or in snapshots. Growth becomes bounded by the number of distinct patterns.
  - This is off-heap C++ memoisation of a pure function and is not Elm-visible state, so it does not conflict with the "Elm stays immutable / no mutable kernel stores" rule. Still flag it to the user, since the rule's spirit is close.
  - Equal patterns now share an id, so Elm `==` on two Regex values built from the same pattern becomes True. elm/regex on JS compares RegExp objects structurally via `_Utils_eq`, so this probably moves closer to Elm. Verify on node: `Regex.fromString "a" == Regex.fromString "a"`.
  - The table is unsynchronised today. If eco/system runs Elm on more than one thread, both maps need the same (or a new) mutex. Check for multi-mutator use (CR-012 says a second mutator is forbidden, so this is likely fine).
  - Risk: low.
- **Shares:** The unit-test file is shared with REGEX-03(a). The key format must follow REGEX-06 if that lands first.

### Area RESET

#### RESET-01: Runtime root scanner not re-registered after reset
- **Triage:** LIKELY · LOW
- **Test kind:** C++ unit · **Exposes it:** high confidence
- **Test:** new test/platform/HeapResetKernelStateTest.cpp (+ .hpp, `registerHeapResetKernelStateTests`; add it to the
  platform source list in test/CMakeLists.txt:155-157 and register it in test/main.cpp next to
  `registerSchedulerPidTests`, line 629). The test binary already whole-archives EcoKernel_Runtime
  (test/CMakeLists.txt:236/258). Two cases:
  (a) "xfail RESET-01 loadState after reset": `initAllocator(); Scheduler::instance();
  Eco_Kernel_register_all_gc_roots();` spawn `Eco::Kernel::Runtime::saveState(encode(allocStringFromUTF8("x")))` and
  drain. Then `initAllocator()` (the reset), register all gc roots again (what a test must do after a reset), spawn
  `loadState()`, drain, and read the finished process's value (the "drain, then read the finished process"
  pattern of test/platform/SchedulerPidTest.cpp:183-193). Correct: the value is the JSON-null constant
  (`nullConsWordFor(0)`, what a fresh heap gives). Current: `s_hasState` is still true, so the value is the stale
  pre-reset HPointer. This is a deterministic word comparison, with no GC needed.
  (b) "xfail RESET-01 saved state rooted after reset": after the reset, but WITHOUT calling the register hook again,
  `saveState` a fresh string, run `minorGC()` twice, overwrite the nursery with `allocInt(-1)` garbage (the trick
  ChunkedListTest.cpp:270-292 uses), then `loadState` and check that the string still reads "x". Current: the scanner
  died with the old RootSet, so the word is not evacuated. Two minors return allocation to the old semispace, so the
  value reads as garbage or fails `resolve`. High confidence in the legacy nursery (`initLegacyAllocator`); with the
  region nursery check that the slice is reused, or assert instead that "unnamed"/the scanner's label is absent from
  `getRootSet().getExternalRootScannerNames()` (RootSet.hpp:359). Case (b) depends on the fix's design (lazy
  registration); if the user picks "tests must re-call the hook", drop (b).
  Must avoid any GC between the reset and the read in (a) (see the trap above).
- **Fix:** eco-kernel-cpp/src/eco-kernel/Runtime.cpp. Record `s_stateGen` (the `heapGeneration()` at the last
  `saveStateBody`) and `s_scannerGen`. Make `registerGcRootScanner` idempotent per generation: register only if
  `s_scannerGen != heapGeneration()`. `saveStateBody` calls it before storing, as `listScratchRegistered` does
  (runtime/src/allocator/RuntimeExports.cpp:4410-4430). `loadStateBody` treats `s_stateGen != heapGeneration()` as
  "no state". The scanner checks the generation too. Update the "Nothing clears it" comment (Runtime.cpp:27) and
  Runtime.hpp:13/37. Touches HEAP_040 (off-heap state rooted by an external scanner); no codegen. Risk: very low. Call
  sites in production still register once, because the generation never changes.
- **Shares:** test file with RESET-02; fix pattern (generation-keyed lazy registration) with RESET-02 and RESET-03
  (MVar, chunk03, WEAK); depends on the summary's decision about the Scheduler/PlatformRuntime scanners.

#### RESET-02: Time root scanner not re-registered after reset
- **Triage:** LIKELY · LOW
- **Test kind:** C++ unit · **Exposes it:** high confidence
- **Test:** same file as RESET-01, case "xfail RESET-02 time-effects scanner after reset". `initAllocator();`
  `eco_register_time_effect_manager(); setupEffects(sendToApp closure)` (as PS9 does, PlatformServicesTest.cpp:572-588),
  then `enqueueEffects(nil, subBag)`, where the sub bag is one Platform leaf for home "Time" holding `Every 1.0e9
  tagger` (Custom ctor 0, Float field + tagger closure; TimeEffectManager.cpp:54, :251), and drain. Check that
  "time-effects" is in `getRootSet().getExternalRootScannerNames()`. Then `initAllocator()` (reset), register the
  manager again, `setupEffects`, enqueue the same subscription, and check again. Correct: the name is present in the
  new RootSet. Current: `std::call_once` already fired, so it is absent. This is deterministic and needs no GC. A second
  assertion covers the stale table: when `g_intervals` already has the 1e9 entry from the old heap, onEffects takes
  the "already present" branch (TimeEffectManager.cpp:303-306) and schedules no new tick, so check that
  `pendingAsync()` went up by exactly one Task hold after the post-reset enqueue. Today it does not, because the old
  tick's hold is still counted and no new one is taken.
  Special conditions: no GC after the reset (the PlatformRuntime scanner is lost too; see the trap); 1e9 ms so no
  tick fires.
- **Fix:** elm-kernel-cpp/src/time/TimeEffectManager.cpp. Replace `timerRegisterScannerOnce` with a check on
  `g_scannerGen != Allocator::instance().heapGeneration()`. On a change it registers the scanner on the current
  RootSet and, under `g_timerMutex`, collects every `tickToken` and clears `g_intervals`. After unlocking it drops each
  token: `takePendingResume` and then `releaseHold` (not `withdrawParkedTimer` alone if that resumes; only release).
  The stale ticks then end, and their parked closure is never called. Same pattern as RuntimeExports.cpp:4410-4430.
  Touches HEAP_040; Time semantics are unchanged in production. Risk: low. The tick generation check
  (timerTickEvaluator) already guards ticks that race the reset.
- **Shares:** test file with RESET-01; fix pattern with RESET-01.

#### RESET-04: FileSystem handle table never cleared on reset
- **Triage:** CERTAIN · LOW
- **Test kind:** C++ unit · **Exposes it:** high confidence
- **Test:** eco-system-core-test reset scenario "RESET-04" (forked child; see the common notes). Add EcoSystem_FileSystem
  to `target_link_libraries(eco-system-core-test ...)` in system-kernel-cpp/CMakeLists.txt:354. In the child:
  initialize the heap and Scheduler, run `Eco_Kernel_FileSystem_open(...)` on a temp file under /tmp (spawn the
  Task, `runEventLoop()` until it is quiescent, and read the Int fd from the finished process). Then reset
  (`AllocatorTestAccess::reset(a); a.initThread();`). Then (1) assert `fcntl(fd, F_GETFD) == -1` after the first FS
  call of the new generation (the fd must be closed). Currently it is still open: a leak. (2) Run
  `Eco_Kernel_FileSystem_close(fd)` and expect the EBADF failure (FileSystem.cpp:178-186). Currently the stale number
  is still in `openHandles()`, so the close is accepted. Both are deterministic. Report with `xfailReport("RESET-04")`.
  Special conditions: Linux; no GC after the reset.
- **Fix:** system-kernel-cpp/src/eco-system/FileSystem/FileSystem.cpp `openHandles()`: wrap the set in a struct
  `{set, gen, init}` as `socketTables()` does (Socket/SocketTables.cpp:221-229). On a generation change it closes each fd
  with `::close` (not on the eco thread's pool, since nothing references them any more) and clears the set. Simpler
  still: fold it into the FS-01 opaque-id fix, if that lands first, by making the table a `Registry`
  (Core/Registry.hpp), keyed by an id that carries the generation. Risk: low. The generation never changes in
  production.
- **Shares:** test harness (forked reset scenarios in eco-system-core-test) with RESET-05..RESET-11; fix overlaps FS-01
  (other chunk).

#### RESET-05: FileSystemManager reset without stopWatch
- **Triage:** CERTAIN · LOW
- **Test kind:** C++ unit · **Exposes it:** medium confidence
- **Test:** eco-system-core-test reset scenario "RESET-05" (forked child; needs EcoSystem_FileSystem linked, as for
  RESET-04). Register the FileSystem effect manager and `setupEffects`. Enqueue a `FileSystem.watch` subscription on a
  /tmp directory and drain. Record `pendingAsync()` (one Subscription hold) and the inotify watch count from
  `/proc/self/fdinfo/<inotify fd>` (the lines starting "inotify wd:"), or `WatchService` internals if they expose a
  count. Reset; call the manager's onEffects again with an empty subscription list (or simply touch `state()`
  through any manager call). Correct: `pendingAsync()` is back to the baseline and the old inotify wd is removed.
  Current: the hold is still counted and the wd is still there, because `Registry::ensure` cleared the `WatchEntry`
  without `stopWatch` (Registry.hpp:110-116). Medium confidence because it needs the manager's sub encoding and a
  readable WatchService count. The hold-count half alone is high confidence.
- **Fix:** system-kernel-cpp/src/eco-system/Core/Registry.hpp: add an optional `void (*onDiscard)(Entry&)` (a constructor
  argument, null by default), called for each entry in `ensure()` before `m_.clear()`. In FileSystemManager.cpp
  `registry()`, pass a discard hook that runs `stopWatch` on every `WatchEntry` of the discarded `ManagerState`
  (FileSystemManager.cpp:154-160). The hook must not allocate on the Elm heap: `stopWatch` only calls
  `WatchService::remove` and `releaseHold`, which is fine. Risk: low. Other `Registry` users keep the null hook.
- **Shares:** Registry discard hook reusable for RESET-10 and RESET-11 (Terminal/System registries); test harness with
  RESET-04.

#### RESET-06: SocketTables reset keeps holds
- **Triage:** CERTAIN · LOW
- **Test kind:** C++ unit · **Exposes it:** high confidence
- **Test:** eco-system-core-test reset scenario "RESET-06" (forked child; Socket is already linked). It injects
  directly into the public tables (SocketTables.hpp:107), so no real socket is needed:
  (1) `ensureSocketTables()`; a listener entry `socketTables().listeners[1]` whose `closeTokens` gets
  `t1 = sched.parkResume(anyHeapValue, HoldKind::Task, "reset06.close")`;
  (2) a pending connect: register a real non-blocking connect to an unroutable/closed port through the kernel, or,
  more simply, insert a `Conn::makeClient` entry under token `t2 = parkResume(...)` into `pendingConnects` the way
  Socket.cpp:317 does.
  Record `pendingAsync()`, reset, call `socketTables()` (which runs `resetTables`). Correct: `pendingAsync()` is
  back to its value before the injection, and `!holdIsLive(t1/t2)`. Current: t1 is never released, and t2 is
  released only if `cancelConnect()` lost the race. Assert t1 deterministically; assert t2 only when
  `cancelConnect()` returned true (instrument it by checking that no Connected event is queued).
  The in-flight OpDone half is covered by the RESET-08 scenario.
- **Fix:** system-kernel-cpp/src/eco-system/Socket/SocketTables.cpp `resetTables` (:40-61): for each listener,
  `for (token : e.closeTokens) { (void)sched.takePendingResume(token); sched.releaseHold(token); }`. For each pending
  connect: `if (kv.second->cancelConnect()) { takePendingResume(kv.first); releaseHold(kv.first); }`. When cancel
  loses, the Connected event is posted and the RESET-08 fix releases it as an orphan. Update the comments at :37-39
  and SocketTables.hpp:35. Never call the resumed closure: it lives in the dead heap. Risk: low; the census
  double-release check (holdFatal) catches mistakes.
- **Shares:** harness with RESET-04..RESET-11; the in-flight part is fixed by RESET-08's `releaseOrphan` change;
  alternative generic fix (Scheduler generation reset) for RESET-06..RESET-10, see the summary.

#### RESET-07: HttpTables reset keeps holds
- **Triage:** CERTAIN · LOW
- **Test kind:** C++ unit · **Exposes it:** high confidence
- **Test:** eco-system-core-test reset scenario "RESET-07" (forked child; HttpServer is linked). Two parts:
  (a) RespondDone: `ensureHttpTables()`; `t = parkResume(anyHeapValue, Task, "reset07.respond")`;
  `postHttpEvent({kind=RespondDone, gen=currentHeapGeneration(), token=t})`; reset; `runDrainSources()`
  (AsyncSources.hpp:42, which runs `httpDrain`). Correct: t released. Current: the event is skipped at
  HttpTables.cpp:337, so t stays live. Deterministic.
  (b) closeServer: start a server on a loopback listener (the helpers testHttp1KeepAlivePipeline uses,
  EcoSystemCoreTest.cpp:2485ff); `t2 = parkResume(...)`; `httpTablesCloseServer(id, 0, t2)`; reset before draining;
  `httpTablesSubscriptionsChanged()` (any call that reaches `tables()`), then `runDrainSources()` after a short wait.
  Correct: t2 released. Current: it stays live. Assert both through `pendingAsync()`/`holdIsLive`.
- **Fix:** system-kernel-cpp/src/eco-system/HttpServer/HttpTables.cpp. In `resetTables` (:118-138), for every server,
  `takePendingResume` + `releaseHold` each `closeTokens` entry. In `httpDrain` (:337), replace the bare `continue` with:
  if `ev.kind == RespondDone`, `takePendingResume(ev.token)` + `releaseHold(ev.token)`; then continue. (The close
  tokens of an old-generation ServerClosed are already released by `resetTables`, so that event must stay ignored to
  avoid a double release.) Update the comments at HttpTables.cpp:116-117 and HttpTables.hpp:36-41. Risk: low.
- **Shares:** harness with RESET-04..RESET-11; alternative generic fix (summary).

#### RESET-08: Udp reset keeps in-flight OpDone holds
- **Triage:** CERTAIN · LOW
- **Test kind:** C++ unit · **Exposes it:** high confidence
- **Test:** eco-system-core-test reset scenario "RESET-08" (forked child). `ensureSocketEvents()`;
  `t = parkResume(anyHeapValue, Task, "reset08.opdone")`; `postSocketEvent({kind=OpDone, gen=currentHeapGeneration(),
  token=t})` (exactly what `UdpHandler::postOpDone` posts, Udp.cpp:97-109); reset; `socketEventsDrain()` (public,
  SocketEvents.hpp). Correct: `!holdIsLive(t)` and `pendingAsync()` is back to baseline. Current: `releaseOrphan`
  (SocketEvents.cpp:71-76) drops the event without releasing anything. Also post a Connected event carrying a token
  (`t3`) to cover RESET-06's lost-cancel case. Fully deterministic; no real UDP socket needed. An optional second
  part binds a real UDP socket with a queued send and checks the same counter after reset, for the ECANCELED path
  (Udp.cpp:251).
- **Fix:** system-kernel-cpp/src/eco-system/Socket/SocketEvents.cpp `releaseOrphan`: for `Kind::OpDone` and
  `Kind::Connected` with `ev.token != 0`: `(void)Scheduler::instance().takePendingResume(ev.token);
  Scheduler::instance().releaseHold(ev.token);`, then abort the conn as now. Do NOT do this for the "no dispatch
  function" orphan of the current generation unless the token's hold is known to be live there too; keep the change
  to the `ev.gen != current` branch (pass a flag). Update SocketEvents.hpp:13-17 ("tokens and counts that died with
  the old heap" is false, because the Scheduler survives). Risk: low. A token released twice would trip holdFatal in
  census builds; RESET-06's fix only releases connects whose cancel won, so they never post.
- **Shares:** same scenario covers the in-flight part of RESET-06; the analogous WsEvents `releaseOrphan`
  (WebSocket/WsEvents.cpp:117) likely has the same gap for Dialed/OpDone/PingDone tokens. Check it with RESET-09.

#### RESET-09: WsTables reset keeps holds
- **Triage:** CERTAIN · LOW
- **Test kind:** C++ unit · **Exposes it:** high confidence
- **Test:** eco-system-core-test reset scenario "RESET-09" (forked child; WebSocket is linked). `ensureWsTables()`;
  inject `wsTables().sockets[1]` with `closed=false`, `core=nullptr` (so `abortCore` is a no-op; check that it tolerates
  null, or use `closed=true`), `closeHold = acquireHold(HoldKind::Item, "reset09.close")`, and
  `closedWaiters = {parkResume(anyHeapValue, Task, "reset09.waiter")}`. Also inject a `pendingDials` entry keyed by a
  parked token, with a DialJob whose `cancel()` succeeds (or test the dial part via a real dial to a closed port).
  Reset; call `wsTables()`. Correct: all three holds released and `pendingAsync()` back to baseline. Current: none
  are (WsTables.cpp:45-60; deliberate per WsTables.hpp:24-26). Also post an old-generation WsEvent OpDone with a
  token and run `wsEventsDrain()`, to check the WsEvents orphan path that RESET-08 notes.
- **Fix:** system-kernel-cpp/src/eco-system/WebSocket/WsTables.cpp `resetTables`: for each socket, `HoldRelease(closeHold)`
  and, for each `closedWaiters` token, `takePendingResume` + `releaseHold`. For `pendingDials`, release
  `takePendingResume(kv.first)` + `releaseHold(kv.first)` when `cancel()` returns true. If the WsEvents orphan path
  drops token holds, mirror the RESET-08 change in `WsEvents.cpp releaseOrphan`. Rewrite the WsTables.hpp:22-26
  comment. Risk: low.
- **Shares:** harness; RESET-08 (orphan release pattern); alternative generic fix (summary).

#### RESET-10: WsManager aux() reset keeps subscription holds
- **Triage:** CERTAIN · LOW
- **Test kind:** C++ unit · **Exposes it:** medium confidence
- **Test:** eco-system-core-test reset scenario "RESET-10" (forked child). An `Aux` hold is taken only by
  `reconcile` (WsManager.cpp:203-230) when an `OnClose`/`OnMessage` subscription names a WebSocket that has a
  `wsTables()` entry. Drive it through the manager. Register the WebSocket effect manager and `setupEffects`, inject a
  `wsTables().sockets[1]` entry (`closed=false`, `readableId=0`), and enqueue a sub bag holding one `OnClose 1 tagger`
  leaf (the onEffects at WsManager.cpp:270-300). `pendingAsync()` should rise by one Subscription hold. Reset; call
  onEffects again with an empty sub list (this reaches `aux()`). Correct: back to baseline. Current: the hold of the
  discarded entry is never released (WsManager.cpp:91, :99). Medium confidence only because building the sub bag
  and registering the manager needs care. If that proves awkward, add a narrow test seam
  `Eco::System::wsManagerReconcileForTest(int64_t wsId, bool hasClose)` in WsManager.hpp, and you get high confidence.
- **Fix:** system-kernel-cpp/src/eco-system/WebSocket/WsManager.cpp `aux()`: before `t->m.clear()`, loop over the
  entries and `if (a.hold != kNoHold) Scheduler::instance().releaseHold(a.hold)`. Readers attached to the old
  generation's readables need no detach: the stream tables reset themselves. Update the comment at :91. Risk: very low.
- **Shares:** harness; alternative generic fix (summary).

#### RESET-11: listener/g_quiescenceRegistered survive reset
- **Triage:** CERTAIN · LOW
- **Test kind:** none (optional C++ unit) · **Exposes it:** medium confidence (if written)
- **Test:** none required: the behaviour is deliberate and only "Ctrl-C ignored until the next onEffects inside a
  test process that reset its heap". If a guard is wanted, add an eco-system-core-test reset scenario "RESET-11"
  (forked child; link EcoSystem_System). Register the System manager, subscribe to `onSignalInterrupt`, reset, then
  `raise(SIGINT)` in a grandchild-safe way (the `raiseAndDrain` helper, EcoSystemCoreTest.cpp:406) and assert the
  process terminates, i.e. the default action is restored. Current: the listener survives with an empty msg list
  and swallows the signal. Run it in its own forked child so the expected termination is observable as WIFSIGNALED.
- **Fix:** optional. Preferred: when `state()` in SystemManager.cpp / TerminalManager.cpp creates a fresh
  `ManagerState` after a registry clear, also remove the process-wide listeners (`g_sigintListener`,
  `g_sigtermListener`, `g_winchListener`) and zero them, so the listeners match the (empty) subscriptions. Leave
  `g_quiescenceRegistered` as is; its listener is harmless with an empty state. Can be implemented with the
  RESET-05 `Registry` discard hook. Alternative, as the triage suggests: `onSignal` chains to the previous handler
  when its msg list is empty. Risk: low; the signal code is subtle, so keep `SignalService` itself untouched.
- **Shares:** Registry discard hook with RESET-05; harness with RESET-04..RESET-10.

### Area SIG

#### SIG-03: addListener push_back throw leaks subscription
- **Triage:** CERTAIN · LOW
- **Test kind:** C++ unit · **Exposes it:** medium-high confidence (needs allocation-failure injection)
- **Test:** in `/work/test/eco-system-core/EcoSystemCoreTest.cpp` (single TU, its own binary). Add replacement global `operator new`/`operator new[]` (plus the matching deletes) that throw `std::bad_alloc` while a `thread_local bool g_failNew` is set, and otherwise forward to `malloc`. `testSignalServiceAddListenerOom`: install `SIG_IGN` for SIGUSR2; add one ordinary listener first, so the service is started and `saved_[SIGUSR2]` exists and `subscribe` itself allocates nothing; then loop: set `g_failNew = true`, call `svc.addListener(SIGUSR2, &listenerB, nullptr)` inside try/catch, clear the flag. If it returned an id (the vector had spare capacity), keep the id and repeat. The first throw is guaranteed within capacity+1 iterations. After the throw, remove every listener that was added. Defect: `currentHandler(SIGUSR2) != SIG_IGN`, because `counts_` was left at +1 and the handler was never restored. Fixed: `== SIG_IGN`. Report through a local xfail helper (as for PROC-06) until fixed. Restore SIG_DFL at the end. If replacing global new in this binary is unwelcome, the fallback is a static check: a code review/grep rule that `addListener` does no throwing operation after `subscribe`, with low confidence as a test.
- **Fix:** `/work/system-kernel-cpp/src/eco-system/Core/SignalService.cpp` `addListener` (:236-242). Call `listeners_.reserve(listeners_.size() + 1)` (the only throwing step) before `subscribe(signo)`, then `push_back`, which can no longer throw. Alternatively wrap the `push_back` in try { } catch (...) { unsubscribe(signo); throw; }. Prefer reserve-first: there is nothing to undo. Callers (SystemManager.cpp:137, Terminal.cpp:164) need no change. Invariant: SYS_003. Risk: negligible.
- **Shares:** SIG-04 (same file and test binary; can be one commit), PROC-06 (local xfail helper in eco-system-core-test)

#### SIG-04: chainToPrevious window runs old disposition
- **Triage:** CERTAIN · LOW
- **Test kind:** C++ unit · **Exposes it:** high confidence (deterministic)
- **Test:** extend `testSignalServiceChainToPrevious` in `/work/test/eco-system-core/EcoSystemCoreTest.cpp` (or add `testSignalServiceChainToPreviousSecondInstance`). Install as the previous SIGUSR2 disposition a handler `prevHandlerReraise` that bumps an atomic counter and, on its first call only, does `pthread_kill(pthread_self(), SIGUSR2)`. Use a thread-directed signal, not `kill()`, so it cannot land on another thread. While the handler runs, SIGUSR2 is blocked (sa_mask), so the second instance is pending and is delivered when the handler returns, while `old` is still installed. Then `addListener(SIGUSR2, &listenerB, nullptr)` and `chainToPrevious(SIGUSR2)`, sleep about 20 ms. Today: prev counter == 2 and `!svc.hasReady()`; the second instance bypassed the Eco listener. Fixed: prev counter == 1 and `svc.hasReady()`; the second instance was queued to Eco. Drain it with `tryPop`, remove the listener, and restore SIG_DFL. Report via the local xfail helper until fixed. Linux and macOS.
- **Fix:** `/work/system-kernel-cpp/src/eco-system/Core/SignalService.cpp` `chainToPrevious` (:281-289). Do not swap dispositions when the previous one is a handler. Instead, block `signo` with `pthread_sigmask`, call the old handler directly (`old->sa_handler(signo)`, or for `SA_SIGINFO` `old->sa_sigaction(signo, &si, nullptr)` with a synthesized `siginfo_t{si_signo = signo, si_code = SI_USER, si_pid = getpid()}`, applying `old->sa_mask` around the call), then restore the mask. Our handler stays installed throughout, so a concurrent or pending instance goes to the Eco queue. For `SIG_IGN`: do nothing (today the raise is a no-op anyway). For `SIG_DFL`: keep swap + `raise` + reinstall, but only for signals whose default action terminates or stops (for ignore-by-default signals such as SIGCHLD/SIGWINCH/SIGURG, skip it). In that window an extra instance under SIG_DFL also terminates, which is the intended outcome. Honour `SA_RESETHAND` in `old` by switching `saved_[signo]` to SIG_DFL after the call. Risk: low-medium. A foreign handler that reads `ucontext` would get nullptr. Document this. The only caller is Terminal raw-mode SIGINT/SIGTERM (Terminal.cpp:146), which runs on the eco thread outside signal context, so calling the handler directly is legitimate. The existing chainToPrevious test cases (handler run once, SIG_IGN survives, unsubscribed no-op) must still pass. Invariant: SYS_003.
- **Shares:** SIG-03 (same file and test binary)

### Area SOCK

#### SOCK-03: Conn second write onError
- **Triage:** CERTAIN · LOW
- **Test kind:** C++ unit · **Exposes it:** high confidence
- **Test:** Add `testConnSetInterestFailureAfterWriteError` to test/eco-system-core/EcoSystemCoreTest.cpp, using the existing helpers `ProtoLog`, `openConn` and `ChunkTransport` (:2050-2195):
  1. Open a Conn over a socketpair, with a protocol that logs every `onError` code, like ProtoLine's `"A:error:" + code`, and keeps `wantsRead` true.
  2. Close the peer, then queue a write. `ChunkTransport::write` gets EPIPE, so `writeFailed` delivers `write EPIPE` once.
  3. On the reactor thread (`onReactor`), make `epoll_ctl` fail: `dup2(regularFileFd, connFd)`. epoll refuses a regular file with EPERM, and the old description is dropped from the epoll set. Then force an interest change, for example by toggling the protocol's `wantsRead` and calling `c->updateInterest()`, or with `R().injectEventForTest(key, true, false, false)`. `applyInterest` then sees a nonzero `setInterest` result.
  4. Wait for the close hook, then count the log entries that start with `A:error:write`.

  Correct: 1. Current: 2 (`write EPIPE` and then `write EPERM`). Linux-only (epoll); guard the test the way the other reactor tests are guarded. Mark it with the XfailGuard (test/XfailGuard.hpp) convention until the fix lands, so that an XPASS is flagged afterwards.
- **Fix:** In S/Socket/Conn.cpp `applyInterest` (:762-784), add `bool writeWasDone = writeDone_;` beside `readWasDone`, and call the write `onError` only `if (protocol_ && phase_ == Phase::Open && !writeWasDone)`. Keep `failOutbound(e)`; it is harmless when the queue is already failed. Update the contract in Conn.hpp:179-180 to "a write error is reported unless writing had already ended". Consumers (FaceProtocol, Http1, Http2, WsProtocol) need no change, and WsProtocol's `portError` path becomes single-shot. Risk: low.
- **Shares:** -

#### SOCK-12: pending connect left if makeKillHandle throws
- **Triage:** CERTAIN · LOW
- **Test kind:** C++ unit · **Exposes it:** medium confidence (it needs a fault-injection hook; a genuine heap OOM at exactly that allocation is not reproducible)
- **Test:** No existing allocator fault injection fits: `max_heap_size` exhaustion would throw at earlier allocations first. Proposal:
  - Add a test-only countdown to S/Core/KillHandle.cpp, for example `void killHandleFailNextForTest()`, compiled under `!NDEBUG || ECO_HEAP_VALIDATE` like the hold census. It makes the next `makeKillHandle` throw `std::bad_alloc`.
  - In EcoSystemCoreTest, add `testConnectKillHandleThrow`. Start a listener on loopback, arm the hook, and drive `socketStartConnect` through the Socket.connect kernel body (`ECO_SYSTEM_ASYNC_GUARD` -> `asyncFailure`). Then wait until the connect completes on the reactor (`onConnected`).
  - Expected (correct): the task fails once, `pendingConnects` is empty, no connect is in flight, and `Scheduler::liveHoldCount()` is back to the baseline.
  - Current: in a census build (the `dev` preset, or `build`, which is -UNDEBUG) `holdFatal("second release of a hold")` aborts the process, which the harness reports as a crash. In a release build the pending-async count ends one too low.

  The test must run in an isolated child (IsolatedTestRunner), because holdFatal aborts the process. Mark it XFAIL until the fix lands.
- **Fix:** In S/Socket/Socket.cpp `socketStartConnect` (:311-321), match the accept path (:487-490). Right after `parkResume`/`counted = true`, call `HPointer kill = makeKillHandle(token, &cancelPendingConnect);` and root it (`Elm::StackRootGuard g(&kill)`) across `Conn::makeClient`. Then insert into `pendingConnects` and submit `startConnect`, and return `kill`. `Conn::makeClient` and the map insert are C++-heap only and do not allocate on the GC heap, but root `kill` anyway, because `std::bad_alloc` from the map is still possible. A throw there now leaves nothing to clean up except the hold, which `asyncFailure` releases. Re-check `cancelPendingConnect`: it must tolerate a token that is not yet in `pendingConnects`, which can only happen if killed before the insert, and that is impossible within one kernel call. Invariants: the HEAP rooting rules for kernel allocations (the kill handle is live across the C++ work). Risk: low.
- **Shares:** The fault hook can be reused for any other `makeKillHandle`-after-submit ordering bugs found in the same sweep.

#### SOCK-15: Udp handler refused by reactor never reads
- **Triage:** LIKELY · LOW
- **Test kind:** E2E (with new harness support) · **Exposes it:** medium confidence
- **Test:** The reachable trigger is a reactor whose `ok` is false. That state is decided once per process in the singleton's constructor (S/Core/IoReactor.cpp:477-497), so the in-process EcoSystemCoreTest cannot use it without breaking the other reactor tests. Proposal:
  - Add a debug-only test knob, read in the `IoReactor` constructor under `!NDEBUG`: an env var such as `ECO_IOR_FAIL_INIT_FOR_TEST=1` that skips `backendInit` and leaves `ok=false`. Or, without a new knob, an isolated child that exhausts RLIMIT_NOFILE before the first `reactor()` call and then closes a few fds before binding; that is more fragile.
  - Add a new E2E test, test/eco-system/src/UdpBindNoReactorTest.elm. It binds a UDP socket on 127.0.0.1:0, as LiveUdpOnMessageTest does, and prints the bind result: `-- CHECK: bind failed: ENOSYS` (or `EIO`, whichever code the fix picks), then `-- CHECK: done`. It needs `-- LINUX-ONLY:` (Windows bind already fails with ENOTSUP) and the env directive described below.
  - Current: bind succeeds, then the receive or send parks forever. The harness times out (ECO_TEST_TIMEOUT_SECONDS), so the test fails with a timeout rather than hanging the suite.
  - Correct: bind fails fast.

  This needs a new E2E directive `-- ENV: NAME=VALUE`, applied by the spawned child in test/ElmE2ETestBase.hpp before it runs the program. It mirrors the codegen harness's `// UNSETENV:` (test/codegen/CodegenIsolatedTest.hpp:304-311); see ECO-NEW-1. Mark the test `-- XFAIL-NATIVE:` until the fix lands. Optionally add TCP connect and listen variants (SocketSmokeTest-style) to the same program.
- **Fix:**
  1. Add `bool IoReactor::ok() const` (S/Core/IoReactor.hpp/.cpp; it returns `impl_->ok`).
  2. In the UDP bind, Socket connect, listen and accept-start kernels, check `reactor().ok()` before parking or submitting, and fail immediately with an FErr such as `("ENOSYS", "socket IO unavailable: event loop could not be created")`. This covers `udpBindComplete` (S/Socket/Udp.cpp:511-527) and `socketStartConnect`/listen in Socket.cpp; the check is best placed in one helper.
  3. As defence in depth, make `IoReactor::submit` return `bool`, so callers that park a hold before submitting (send, membership) can release the hold on `false` instead of leaking it.

  Risk: low to medium. It touches every socket kernel entry point. The hold-release paths must not double-release; see SOCK-12 for the census check.
- **Shares:** The `-- ENV:`/`-- UNSETENV:` E2E directive is shared with ECO-NEW-1. The "check before park" pattern relates to SOCK-12.

### Area STREAM

#### STREAM-03: concatenated gzip members rejected
- **Triage:** CERTAIN · LOW
- **Test kind:** E2E · **Exposes it:** high confidence
- **Test:** New file `test/eco-system/src/StreamCodecGzipMultiMemberTest.elm`. A base64 constant holds `zlib.gzipSync('hello ')` followed by `zlib.gzipSync('world')`, generated with node in the way of system-kernel-cpp/scripts/gen-stream-codec-fixture.js and checked in. The program pipes it through `Stream.Transformation.gunzip` three ways: as one chunk, split exactly at the member boundary, and split into 1-byte chunks (the next member's `1f 8b` straddles a chunk boundary). It reuses `StreamCodecHelp.splitBytes` and `readAll` and logs the decoded text or the error. Checks:
  - `-- CHECK: one chunk: hello world`
  - `-- CHECK: boundary split: hello world`
  - `-- CHECK: byte chunks: hello world`
  - `-- EXIT: 0`

  Current native output: `err Failed: Junk found after end of compressed data.` On the JS backend, run it through run-js-e2e.js `--project eco-system`; the result depends on node's DecompressionStream, so record it. Mark the test `-- XFAIL-NATIVE: STREAM-03` until fixed.
- **Fix:** **User decision first**, because the behaviour is deliberate and documented (system-kernel-cpp/src/Stream/Transformation.elm:279-282, matching WHATWG). Options:
  - If kept by design: turn the test into a pin of the rejection, with `-- CHECK: one chunk: err Failed: Junk found after end of compressed data.` and `-- SKIP-JS: JS backend behaviour is data-dependent (Transformation.elm)`, and close the bug.
  - If implemented: in S/Stream/StreamCodec.cpp `inflateRun`, for `kCodecGzip` only, a `Z_STREAM_END` with input left that starts `1f 8b` triggers `inflateReset(&zs)`, clears `zEnded` and continues. If the remaining input is empty, or only one byte, at a chunk end, keep a "between members" state and decide on the next chunk; at close, end cleanly in that state. Any other trailing data is still an error. Update the Transformation.elm doc.

  Risk: low.
- **Shares:** -

#### STREAM-07: maybeErase never erases some pairs
- **Triage:** CERTAIN · MEDIUM
- **Test kind:** C++ unit · **Exposes it:** high confidence
- **Test:** Add `testErroredPairsErased()` to test/eco-system-core/EcoSystemCoreTest.cpp and call it from `main` before `testReactorQuiesce`. Build target `eco-system-core-test` and run it once. Steps:
  1. Record `size_t base = streamTable().size()`.
  2. Loop N=200 times:
     - create a mapped source on a `TestChannel` (`createMappedSource`);
     - answer its read-ahead with `ECONNRESET` (`answerRead(..., ECONNRESET, false, "read ECONNRESET")`) and `channelDrain()`;
     - do one `streamRead(id)` and check that it still returns the stored `Stream.Failed` reason. The existing `testMappedSource` asserts this, and the fix must keep it.
  3. Do the same for a ChannelSink whose write fails, and for a Custom pair ended by `terminatePair`, if it is reachable from the unit-level helpers.
  4. Check `streamTable().size() == base` and that every `TestChannel` was destroyed (`log->destroyed`).

  Today the size grows by N per scenario and the channels are never destroyed. The test is a plain `CHECK`; wrap it in an `XfailGuard`-style report only if the suite needs to stay green before the fix. The Open-but-unreachable case is inherent (no finalization) and is not tested.
- **Fix:** S/Stream/Stream.cpp `maybeErase`: treat a side as "done" when it is Closed or Errored (`w ∈ {Closed, Errored}`, `r ∈ {Closed, Errored}`), keeping the other conditions (nothing parked, queued or in flight, not pinned, no pipe refs). Before erasing a pair with an Errored side, store its reasons in a small bounded tombstone map (id → wReason/rReason, an LRU of for example 4096 entries, holding plain strings and no heap words). Change the missing-id paths (read gives Closed; write fails with `kWritableClosed`) to consult the tombstone first, so later operations still return the stored error. Call `maybeErase` after `errorPair`, after `terminatePair`, and in `channelDispatch`'s error branches (around :691-697 and :720-726). Update the lifetime rule in S/Stream/StreamTable.hpp:38-41. Invariants: HEAP_005 (erasing the pair drops `mapFnEnc` and the action-closure words from the scanned registry, which is the intended release). Risk: medium, because an id may be reused after erase while a stale Elm handle still names it (check that ids are never reused) and the observable reasons change. Run the eco-system E2E suite and the validate gate after the change.
- **Shares:** -

### Area STRING

#### STRING-01: String foldl/foldr resolve a possibly-constant accumulator
- **Triage:** CERTAIN · LOW
- **Test kind:** static check · **Exposes it:** high confidence (it is dead code; the check proves there are no callers)
- **Test:** No behaviour test. Check: `grep -rn "FoldFunc\|String::foldl\|String::foldr" /work --include=*.cpp --include=*.hpp --include=*.h` (excluding build/). Today the only hits are the definitions at E/core/String.cpp:129,148 and the declarations at E/core/String.hpp:103,110,115. After deletion there are none. The build is the link check: `cmake --build build` plus the `test` binary.
- **Fix:** Delete `Elm::Kernel::String::foldl` and `foldr` (E/core/String.cpp:124-161, the "Folding" section), the `FoldFunc` alias and both declarations with their doc comments (E/core/String.hpp:97-115). Then fix up the header prose that names them: String.hpp:14-17 ("`foldl`, `foldr` ... are written here ... `foldl` and `foldr` are the exception") and :21-23 and :70-75 (drop `foldl`/`foldr` from the lists). Do NOT delete `Elm_Kernel_String_foldl`/`foldr` in E/core/StringExports.cpp (:347 etc., the live closure-based exports), or `StringOps::foldl`/`foldr` in runtime/src/allocator/StringOps.cpp:1028-1048, which test/allocator/Utf8StringTest.cpp:495 uses. The header says `map`/`filter`/`any`/`all` in the same section (`CharMapper`, `CharPredicate`) are equally uncalled. Delete them in the same commit only if another triage entry covers them or after the same grep; otherwise leave them. Risk: none.
- **Shares:** Possibly the DEAD-* entries for the other uncalled String function-pointer helpers, if any (same commit).

### Area SYNC

#### SYNC-02: ECO_KLOG defined three times
- **Triage:** CERTAIN · LOW
- **Test kind:** static check · **Exposes it:** low confidence (nothing is divergent today; this is a guard)
- **Test:** new `/work/test/scripts/check-klog-copies.sh`, in the style of `check-ctor-tags.sh`. It extracts the two `#define ECO_KLOG` definitions (with their continuation lines, whitespace-normalised) from `elm-kernel-cpp/src/KernelDebug.hpp`, `eco-kernel-cpp/src/eco-kernel/KernelDebug.hpp` and `runtime/src/platform/HttpService.cpp`, and fails if they differ. Wire it into the `check` and `full` targets in `/work/CMakeLists.txt` (~:1497 and ~:1579), next to `check-ctor-tags.sh`. It passes today; to see it work, edit one copy locally and confirm the check fails, then revert.
- **Fix:** none is required. The alternative to the check is one shared header, e.g. `runtime/src/platform/KernelLog.hpp`, included by all three. First verify that `runtime/src` (or `runtime/src/platform`) is really on the include path of ElmKernel_* and EcoKernel_* targets, which the triage asserts. Then delete the three local definitions and update the comment at E/KernelDebug.hpp:10-13. Prefer the shared header if the include path holds (it removes the duplication), otherwise the check. Risk: nil (debug builds only).
- **Shares:** -

#### SYNC-03: kKinds = 9 unchecked
- **Triage:** CERTAIN · LOW
- **Test kind:** static check · **Exposes it:** low confidence (latent; correct today)
- **Test:** the compile-time assertion is the test. Add after the struct definitions:
  - `static_assert(WsEvent::kKinds == static_cast<int>(WsEvent::Kind::HandshakeGone) + 1, "...");` in `/work/system-kernel-cpp/src/eco-system/WebSocket/WsEvents.hpp`;
  - `static_assert(SocketEvent::kKinds == static_cast<int>(SocketEvent::Kind::UdpClosed) + 1, "...");` in `.../Socket/SocketEvents.hpp`.

  Both hold today, so the build stays green. The check is verified by temporarily appending an enumerator and seeing the build fail. Note it still misses a new enumerator appended after the named last one; the fix below closes that.
- **Fix:** add a trailing sentinel to each enum (`..., HandshakeGone, Count_` / `..., UdpClosed, Count_`) and define `kKinds = static_cast<int>(Kind::Count_)`. Then grep `switch` statements over these `Kind`s: `-Wswitch` would want a `Count_` case. If there are switches, keep the explicit static_assert form instead. Also add a bounds `assert(static_cast<int>(kind) < WsEvent::kKinds)` in `setWsEventDispatch` (WsEvents.cpp:94-96) and the Socket equivalent. Asserts are on in the `build` preset. Update the header comments that say "Nothing checks that the two agree". Risk: nil.
- **Shares:** -

### Area TASK

#### TASK-01: task effect manager closures unrooted at registration
- **Triage:** CERTAIN · MEDIUM
- **Test kind:** C++ unit · **Exposes it:** medium-high confidence
- **Test:** An E2E cannot steer a minor GC into registration at startup. Add an isolated unit case to the `test` binary, next to test/allocator/GcSafetyReproTest.cpp, using its "force the collection at the one point the defect needs" approach. The case runs in a fresh child so `initAllocator` and the registry are clean:
  1. Using `NurserySpaceTestAccess`/`AllocatorTestAccess`, fill the nursery so that the space left before the collection limit equals exactly one 0-capture closure. Allocate a filler sized from the bump pointer and end; sweep the remainder over a small range (say 0..256 bytes, step 8) and re-run, so the miss lands after `initCl` on some iteration. Check `nursery->minorSeq()` advanced, so the case cannot pass vacuously.
  2. Call `eco_register_task_effect_manager()`.
  3. Read the registered words back. This needs a small accessor such as `const ManagerInfo* PlatformRuntime::findManager(const std::string&)` next to `hasManager` (runtime/src/platform/PlatformRuntime.hpp:86), or test access.
  4. Check that `init` (and `onEffects` and the others) points at a live closure: `getHeader(resolve(word))->tag == Tag_Closure`, not `Tag_Forward`. In region mode, also check it is not inside the evacuated eden.

  Expected (fixed): every word points at a live closure. Current: on the iteration where the minor falls after `initCl`, `init` points at a forwarded or stale copy. Use `XfailGuard::report("TASK-01", ...)` until fixed. Run the same case for `eco_register_time_effect_manager()` (TIME-NEW-1). Unit tests pin the legacy nursery via initAllocator (memory notes), so run the sweep in both semi-space and region mode if both are reachable from the test. An ECO_HEAP_VALIDATE build would also catch the stale word, as a stronger optional run.
- **Fix:** E/core/TaskEffectManager.cpp:199-215: root each closure as soon as it is allocated, exactly like `eco_register_http_effect_manager` (E/http/HttpEffectManager.cpp:415-437). That means `HPointer initCl = allocClosure(...); Elm::StackRootGuard g1(&initCl);` and so on for each later closure, or one guard over all four locals initialised to a constant first (e.g. `listNil()`). Remove the comment at :197-198. Apply the same change to E/time/TimeEffectManager.cpp:413-430. Then grep `eco_register_*_effect_manager` for other registrars with the same pattern. Invariant: FORBID_HEAP_003 (non-stackmap stack rooting via `RootSet` stack roots, i.e. `StackRootGuard`). Risk: very low.
- **Shares:** TIME-NEW-1 (same test, same fix pattern)

### Area TERM

#### TERM-04: no restore on _exit/abort/SIGHUP/SIGQUIT
- **Triage:** CERTAIN · MEDIUM
- **Test kind:** C++ unit · **Exposes it:** high confidence
- **Test:** new pty-based case in `test/eco-system-core/EcoSystemCoreTest.cpp`, run by the `eco-system-core-test` target. LINUX/POSIX only, `#ifndef _WIN32`.
  - The parent makes a pty with `openpty`, then forks.
  - The child: `dup2(slave, 0)`, set up the heap as the file already does, call `terminalSetStdInRawModeBody(True)` (Terminal.hpp:47) and run the returned Task's effect or resume path, or expose a test hook for `setRaw`. Then call `Eco::Kernel::reportFatal("test")`.
  - The parent `waitpid`s, then `tcgetattr(slave)` and asserts `ECHO|ICANON` are set again.
  - Variants: the child raises SIGABRT via `std::abort()` (assert path), and SIGHUP or SIGSEGV if handlers are added.
  - Current behaviour: the termios stays raw (`ECHO` clear). Report through `XfailGuard::report("TERM-04", ...)` until fixed. XfailGuard is header-only and can be included there.
  - E2E is not possible: the harness gives the program no terminal (stdin is /dev/null or a pipe), so `setRaw` returns at `isatty(0)`.
- **Fix:** in `system-kernel-cpp/src/eco-system/Terminal/Terminal.cpp`:
  - Add a process-wide "pre-fatal hook" registry in a runtime header next to the relocated `reportFatal` (see ABI-NEW-1). It is an async-signal-safe function pointer that `reportFatal` calls before `std::abort()`. Register `restoreAtExit` there in `setRaw` when it first saves.
  - Install SIGABRT, SIGSEGV, SIGBUS and SIGHUP handlers through `SignalService` (or `sigaction` with SA_RESETHAND) only while raw mode is on. Each handler does `tcsetattr(0, TCSANOW, &original)` and then re-raises. `tcsetattr` is async-signal-safe; use TCSANOW, not TCSADRAIN, in signal context.
  - Watch for interaction with the GC's own SIGSEGV use, if any (guard pages: the root-stack guard page). Chain to the previous handler.
  - Update the documented limitation in Terminal.elm:149-156.
  - Risk: medium, because signal-handler chaining in a GC'd runtime.
- **Shares:** pty harness shared with TERM-06. Depends on ABI-NEW-1's relocation of `reportFatal`.

#### TERM-05: title filter keeps 0x80-0x9F
- **Triage:** LIKELY · LOW
- **Test kind:** C++ unit · **Exposes it:** high confidence
- **Test:** new case in `test/eco-system-core/EcoSystemCoreTest.cpp`, calling the public `terminalTitleSequence` (Terminal.hpp:69):
  - `terminalTitleSequence("a\xC2\x9C" "b") == "\x1b]2;ab\x07"` (U+009C ST stripped)
  - same for `"\xC2\x9B"` (CSI) and `"\xC2\x80"`
  - regression guards: `"\xC4\x9C"` (U+011C, a continuation byte 0x9C) and `"\xC2\xA0"` (U+00A0) are kept byte-for-byte; `"a\x1b" "b"` and `"\x7f"` are stripped as today
  - Current behaviour: the C1 cases pass through, so the test fails. Use `XfailGuard::report("TERM-05", ...)` until fixed, or land it with the fix.
- **Fix:** in `terminalTitleSequence` (Terminal.cpp:80-88), iterate by index. When `c == 0xC2 && i+1 < n && 0x80 <= s[i+1] <= 0x9F`, skip both bytes. Keep the existing `< 0x20` / `0x7F` filter. The input is valid UTF-8 from `toStdString`, so a lone 0xC2 at the end cannot occur. Keep it anyway (or drop it) defensively. Risk: none.
- **Shares:** -

#### TERM-06: first setStdInRawMode False saves mode
- **Triage:** CERTAIN · LOW
- **Test kind:** C++ unit · **Exposes it:** high confidence
- **Test:** same pty harness and file as TERM-04 (`EcoSystemCoreTest.cpp`).
  - The child gets the pty slave as fd 0, then:
    - calls raw mode False first;
    - changes the termios externally, like `stty` would, for example by clearing `ECHOE` or changing `VERASE` with `tcsetattr`;
    - calls raw mode True;
    - exits with `std::exit(0)`, which runs `restoreAtExit`.
  - The parent asserts the slave's termios equals the externally changed mode, which is what the user had just before going raw.
  - Current behaviour: it restores the stale mode captured at the first False call, so the changed flag is undone. Report through `XfailGuard::report("TERM-06", ...)` until fixed.
- **Fix:** in `setRaw` (Terminal.cpp:152-174), add `if (!on && !s.raw) return;` right after the `isatty` check, before the save and `std::atexit` registration. Optional and low value. Risk: none.
- **Shares:** pty harness shared with TERM-04.

### Area TIME

#### TIME-01: tagger/router encodings decoded after an allocation
- **Triage:** CERTAIN · HIGH
- **Test kind:** C++ unit · **Exposes it:** high confidence
- **Test:** New file `test/elm-kernel-time/TimeEffectManagerTest.cpp`, built as a new `elm-kernel-time-test` executable. The `test` binary does not link elm-kernel-cpp (see the PS12 comment in test/platform/PlatformServicesTest.cpp), so the target follows the `eco-system-core-test` pattern: `EXCLUDE_FROM_ALL` in elm-kernel-cpp/CMakeLists.txt, linking `ElmKernel_Time ElmKernel_Platform ElmKernel_Scheduler EcoRuntimeStatic Threads::Threads`, with `-UNDEBUG` when `ECO_ASSERTS_ON` is set. Build and run it by name, once. The test `TimeTickTaggerAcrossMinor`:
  1. Calls `Allocator::instance().initialize()`, `initThread()` and `Scheduler::instance()` once. The heap must not be reset (RESET-02).
  2. Calls `eco_register_time_effect_manager()`, then `PlatformRuntime::setupEffects(sendToApp)`. `sendToApp` is a C++ closure that records each message.
  3. Allocates a fresh nursery tagger closure (a C++ evaluator that returns its argument and bumps a counter) and builds `Custom{CTOR_TIME_EVERY, f=1.0, p=tagger}`. Wraps it with `Elm_Kernel_Platform_leaf("Time", sub)`, calls `enqueueEffects(nil, leaf)` and drains. After that the test drops its own root, so `g_intervals` is the only reference to the tagger.
  4. Pops the ready timer token (`TimerService::tryPopReadyToken`, waiting up to 1 s) and takes the tick closure with `Scheduler::takePendingResume(token)`.
  5. Records `orig = resolve(tagger)` and registers a one-shot external root scanner that `memset`s the old copy to 0xDD after it has been evacuated (the GcSafetyReproTest.cpp `sliceAcrossCollection` trick).
  6. Calls `nursery->requestMinor()` and applies the tick closure with one argument. The first allocation inside the evaluator is `taskSucceed(unit())`, so the minor runs exactly there.
  7. Runs the scenario under `XfailGuard::runInChild` and reports `XfailGuard::report("TIME-01", defect, ...)`, where `defect` means the child crashed or the tagger counter / recorded-message count is not 1.

  Correct behaviour: one message is delivered and nothing crashes. Today `eco_apply_closure` gets the stale, poisoned tagger, so the child crashes or no message is delivered. The test stays XFAIL-guarded until the fix lands, then becomes a plain test. It needs no env vars; to see the semi-space path deterministically, also run it with `initLegacyAllocator` (`gc_minor_threads=1`). Optional secondary: `test/stress-elm/src/TimeEveryGcPressure.elm`, a `Time.every 1` program whose tagger is `Sub.map identity (Time.every 1 Tick)` (a fresh `composedTagger` per `subscriptions` call) and whose `update` allocates a varying amount. Run it as `ECO_NURSERY_POISON=1 ECO_HEAP_CONFIG=$PWD/benchmarks/heap-config-gc-pressure.json build-validate/test/stress-test --filter TimeEvery`. That one is only medium confidence, because it is probabilistic: about one hit per task-size/nursery-size ticks.
- **Fix:** E/time/TimeEffectManager.cpp `timerTickEvaluator`: decode `taggerEnc`/`routerEnc` into `taggerHP`/`routerHP` and root them (`StackRootGuard`) before any allocation. Then call `taskSucceed(unit())` inside the guarded block, with `succeedTask` already in the guard list. Alternative: call `taskSucceed` first and copy the words under `g_timerMutex` after it. Fix the comment at :183-184. Invariants: FORBID_HEAP_003 (stack rooting via StackRootGuard), KERNEL_TASK_IO_002 and HEAP_005 (no write barrier: encoded words are only valid until the next GC point). Risk: low. TIME-07 rewrites this function as well, so land TIME-01 first, or do both in one change.
- **Shares:** TIME-NEW-1 (same new test executable), TIME-07 (same function rewritten), TASK-01 / RESET-02 (same rooting pattern and same heap-reset caveat)

#### TIME-05: Windows _timezone ignores DST
- **Triage:** CERTAIN · MEDIUM
- **Test kind:** E2E · **Exposes it:** medium confidence (Windows host required)
- **Test:** New file `test/elm-time/src/TimeHereTzUtcTest.elm`. It needs a new `-- ENV: TZ=UTC0` directive, which is a small harness change:
  - add an `extractEnvDirectives` function in test/CheckPatterns.hpp;
  - fill the existing `ChildJob.env` in ElmE2ETestBase.hpp (around :1150);
  - mirror the directive in test/scripts/run-js-e2e.js.

  The program does `Task.perform Here Time.here` and logs `Time.toHour zone (Time.millisToPosix 0)` and `Time.toMinute ...`. Its checks are `-- CHECK: hour: 0` and `-- CHECK: minute: 0`. Elm on node with `TZ=UTC0` gives 0/0, which can be verified with `build/toolchain/bin/elm make` plus node, or `run-js-e2e.js --project elm-time --record`. On Linux it passes today. On Windows `_tzset` is never called, so `_timezone` holds the CRT default 28800 and the program prints hour 16 (UTC-8). The UCRT `_tzset` honours `TZ=UTC0`, so after the fix it gives 0. The DST half cannot be pinned without a date-dependent expectation: verify it by hand on Windows in a DST zone (compare with `[System.TimeZoneInfo]::Local.GetUtcOffset((Get-Date))`). Mark the test `-- XFAIL-NATIVE:` only on Windows. The directive is not platform-conditional, so a `-- WINDOWS-XFAIL` variant may be needed. Simpler: leave it unmarked, since it passes on Linux and Windows is low priority.
- **Fix:** E/time/TimeExports.cpp `getLocalTimezoneOffset` (`#else`/`_WIN32` branch): call `_tzset()` once (`std::call_once`), then `localtime_s(&lt, &now)` and return `(_mkgmtime(&lt) - now) / 60`. That includes DST. An alternative is `GetDynamicTimeZoneInformation` with `Bias + (DaylightBias if TIME_ZONE_ID_DAYLIGHT)`. Update the doc comment at :79-80. No invariants involved. Risk: low; the change is Windows-only and its compile cannot be checked on this Linux host.
- **Shares:** TIME-06 (same `-- ENV:` harness directive and same file)

#### TIME-06: any non-empty TZ becomes a Name
- **Triage:** CERTAIN · LOW
- **Test kind:** E2E · **Exposes it:** high confidence (Linux)
- **Test:** New files `test/elm-time/src/TimeZoneNamePosixTzTest.elm` (`-- ENV: TZ=CET-1CEST,M3.5.0,M10.5.0/3`) and `TimeZoneNamePathTzTest.elm` (`-- ENV: TZ=:/usr/share/zoneinfo/Europe/Paris`), using the `-- ENV:` directive from TIME-05. Each does `Task.perform Got Time.getZoneName` and logs `Name s` or `Offset n`. The CHECK lines must be recorded from Elm on node (`TZ=... node <Name>.run.js`, or `run-js-e2e.js --project elm-time --record`), because the output is ICU's resolution:
  - the path form most likely gives `Name "Europe/Paris"`;
  - the POSIX form likely gives `Etc/Unknown`, `UTC` or an `Offset`; this must be verified.

  Eco today gives `Name "CET-1CEST,M3.5.0,M10.5.0/3"` and `Name "/usr/share/zoneinfo/Europe/Paris"`, so both tests fail. Mark them `-- XFAIL-NATIVE: TIME-06` until fixed, and add `-- LINUX-ONLY:` because macOS/Windows need separate expectations.
- **Fix:** E/time/TimeExports.cpp `getTimezoneName`, factored into one helper for all three platform branches:
  - strip one leading `:`;
  - if the value contains `/zoneinfo/`, take the part after it;
  - accept the value as a Name only if it is an IANA-shaped id (letters, `/`, `_`, `-`, `+` only in `Etc/GMT±N`, no `,`, no leading `/`, no digit-letter POSIX offset), or if `<zoneinfo dir>/<value>` exists;
  - otherwise return "" so the caller falls back to `Offset`.

  The doc comment at :95-103 needs updating. Risk: low. **User decision:** whether to match node/ICU exactly (for example `Etc/Unknown` for an unknown POSIX string) or use the simpler "fall back to Offset" rule. The test's CHECK lines follow that choice. If eco deliberately diverges from node, use `XFAIL-NATIVE` as a documented divergence instead.
- **Shares:** TIME-05 (`-- ENV:` directive)

#### TIME-07: duplicate intervals with different taggers
- **Triage:** CERTAIN · HIGH
- **Test kind:** E2E · **Exposes it:** high confidence
- **Test:** New file `test/elm-time/src/TimeEveryDuplicateIntervalTest.elm`. A worker program with `subscriptions = if done then Sub.none else Sub.batch [ Time.every 20 A, Time.every 20 B, Sub.map Wrap (Time.every 20 C) ]`. `update` counts messages per tagger and records the Posix of each. It stops (sets `done`) once any counter reaches 5, so the run ends either way, then logs:
  - `a ticked: True`, `b ticked: True` and `c ticked: True` (count >= 4 each);
  - `same time per round: True` (A, B and C of one round carry the same Posix, as elm/time's single `Time.now` per tick does);
  - optionally `order: ...`, the tagger order of the first round, which must be recorded from node. elm/time sends in `Dict` list order, which is the reverse of the order of `addMySub` insertion.

  Expected (Elm on node): all True. Current eco: only C, the last-declared tagger, is delivered, so `a ticked: False` and `b ticked: False`. Record or verify the CHECK lines with `build/toolchain/bin/elm make` plus node. Better still, put the test in test/elm-conformance (add `elm/time` to its elm.json) so the JS runner checks it automatically. Mark it `-- XFAIL-NATIVE: TIME-07` until fixed.
- **Fix:** E/time/TimeEffectManager.cpp:
  - `IntervalState.taggerEnc` becomes `std::vector<uint64_t> taggerEncs`, in Elm's order;
  - `timeOnEffectsEvaluator` builds `std::unordered_map<double, std::vector<uint64_t>>` and, for an existing entry, replaces the whole vector;
  - the "time-effects" root scanner evacuates every element;
  - `timerTickEvaluator` copies the vector under the mutex and decodes each word into a rooted container before any allocation. A `std::vector<HPointer>` is not rootable by StackRootGuard, so use a bounded rooted buffer per RootedSlots / `check-root-bounded.py`, or a cons list built once and rooted. It then builds one Posix and, for each tagger, applies it and calls `sendToApp` in Elm's order.

  Invariants: FORBID_HEAP_003, HEAP_005, the PORT_004 pattern (encoded words under an external scanner), and the root-bounded check (test/scripts/check-root-bounded.py). Risk: medium, because the GC-point ordering is subtle. Re-run the validate gate (`ECO_NURSERY_POISON=1 ECO_HEAP_CONFIG=benchmarks/heap-config-gc-pressure.json build-validate/test/test --filter elm-time`).
- **Shares:** TIME-01 (same `timerTickEvaluator` rewrite; implement both together)

#### TIME-08: non-finite intervals reach TimerService
- **Triage:** CERTAIN · LOW
- **Test kind:** C++ unit (+ E2E for the `Time.every` part) · **Exposes it:** low confidence for the UB in a normal build (x86 happens to give "fire at once"); high for `Time.every (1/0)`, via the TIME-09 E2E test
- **Test:**
  - (a) Add a `test_timer_nonfinite_delays` case to test/platform/PlatformServicesTest.cpp. It schedules `+inf`, `-inf`, `NaN`, `1e300` and `-1e300` with bogus tokens, together with a 50 ms reference timer, and asserts the documented post-fix semantics: which tokens pop before the reference timer, and that nothing crashes. Today the UB only shows under a sanitizer. To expose it, run that one test once in a tree configured with `-fsanitize=float-cast-overflow,signed-integer-overflow -fno-sanitize-recover=all` on TimerService.cpp. No sanitizer preset exists, so this is a one-off `cmake -B /tmp/build-ubsan ...`.
  - (b) For `Time.every (1/0)`, use the TIME-09 E2E test with an extra `Time.every (1/0)` counter. On Elm/node, `setInterval(Infinity)` ticks every 1 ms; eco today spins.
  - (c) Add a regression E2E test, `test/elm-core/src/ProcessSleepNonFiniteTest.elm`. It races `Process.sleep (1/0)`, `Process.sleep (0/0)` and `Process.sleep 1e300` each against `Process.sleep 2000` and logs which finishes first. Node fires each after 1 ms (TimeoutOverflowWarning on stderr), so the checks are `-- CHECK: inf: woke first` etc. This passes today by luck and guards the fix.
- **Fix:** add one helper, `TimerService::sanitizeDelayMs(double)`, and call it in runtime/src/platform/TimerService.cpp `schedule`. Its rule: NaN, ±inf or out-of-range values map to a finite value, and the result is clamped so `duration_cast` and `now + d` cannot overflow. Update the contract comment in TimerService.hpp:41-47. **User decision:** match Node exactly (any delay outside [1, 2^31-1] becomes 1 ms, for both `Process.sleep` and `Time.every`) or treat +inf and huge values as "never". Node-exact is the Elm-conformant choice. Risk: low.
- **Shares:** TIME-09 (same E2E test and same clamp helper)

#### TIME-09: zero/negative intervals busy-loop
- **Triage:** CERTAIN · LOW
- **Test kind:** E2E · **Exposes it:** high confidence
- **Test:** New file `test/elm-time/src/TimeEveryZeroIntervalTest.elm`, or the same file in elm-conformance with `elm/time` added:
  - init starts `Task.perform (\_ -> Stop) (Process.sleep 200)`;
  - while not stopped, `subscriptions = Sub.batch [ Time.every 0 Z, Time.every -5 N, Time.every (1/0) I ]`, with three separate counters;
  - on `Stop` it unsubscribes and logs `zero bounded: True`, `negative bounded: True` and `inf bounded: True` (each count <= 400; node gives about 200 at most at a 1 ms clamp) and `zero ticked: True` (count >= 1).

  Expected on node: all True; verify with `build/toolchain/bin/elm make` plus node. Current eco: thousands of ticks, so the three `bounded` checks print False. Mark it `-- XFAIL-NATIVE: TIME-09` until fixed. The upper bound is generous so a loaded machine cannot fail it; only a lower count can occur under load.
- **Fix:** E/time/TimeEffectManager.cpp `scheduleTimerTick`: schedule with `sanitizeDelayMs(intervalMs)`, using the same rule as TIME-08 (at least 1 ms, the Node `setInterval` behaviour). The map key stays the raw interval, so `onEffects` matching is unchanged. **User decision:** whether `Process.sleep 0` should also become 1 ms as in Node. Eco programs and tests use it as a yield (test/elm-core/src/ProcessYieldThrashingTest.elm), so the recommendation is to clamp only `Time.every` and to sanitize only the non-finite/huge cases for sleep. Risk: low.
- **Shares:** TIME-08

#### TIME-NEW-1: Time effect manager closures unrooted at registration (same as TASK-01)
- **Triage:** CERTAIN · MEDIUM
- **Test kind:** C++ unit · **Exposes it:** medium confidence
- **Test:** Add `TimeRegisterAcrossMinor` to the same `test/elm-kernel-time/TimeEffectManagerTest.cpp`. It forces a minor at the second `allocClosure` in `eco_register_time_effect_manager`:
  1. Lowers `bumpState().end` to `ptr + <size of one arity-0 closure>`, so `initCl` fits and the `onEffectsCl` allocation collects. This is the same mechanism as `requestMinor`, with an offset.
  2. A one-shot scanner poisons the old `initCl` copy, as in TIME-01. It finds that copy through a pre-registration scan of the nursery top (`orig = bump ptr` before the call).
  3. Calls `setupEffects(sendToApp)`, which applies the stale `init` closure.

  Runs in `XfailGuard::runInChild` and reports `XfailGuard::report("TIME-NEW-1", crashed || initStateWrong, ...)`. Correct behaviour: the manager starts and its state is `[]`. Today: a crash or garbage. Confidence is medium because the test depends on the exact closure size and on there being no other allocation between the closures. The test must assert `minorSeq` advanced by exactly 1 during registration, so a vacuous pass is caught.
- **Fix:** E/time/TimeEffectManager.cpp `eco_register_time_effect_manager`: declare the four HPointers first and wrap each `allocClosure` in a `StackRootGuard`, as the Http registrar does (E/http/HttpEffectManager.cpp:415-437). Encode them into `info` only after the last allocation. Invariant: FORBID_HEAP_003. Risk: none. Audit the other registrars in E/EffectManagerRegistry.cpp at the same time (TASK-01).
- **Shares:** TASK-01 (identical fix pattern; the same test shape can be used for the Task manager), TIME-01 (same test executable)

### Area TLS

#### TLS-01: TlsTransport copyable while owning SSL*
- **Triage:** CERTAIN · LOW
- **Test kind:** static check · **Exposes it:** high confidence
- **Test:** No runtime test is possible because nothing copies the object today. Add compile-time checks, landed in the same commit as the fix (a check that fails to compile cannot be committed in XFAIL form). In S/Tls/TlsTransport.cpp, directly after the class: `static_assert(!std::is_copy_constructible_v<TlsTransport> && !std::is_copy_assignable_v<TlsTransport> && !std::is_move_constructible_v<TlsTransport>);`. If the fix goes on the base instead, also add `static_assert(!std::is_copy_constructible_v<Transport>)` in S/Socket/Conn.hpp next to `class Transport`. To confirm the check bites, build once without the fix: the static_assert fails. The build must be the normal `cmake --build build` (any preset).
- **Fix:** Preferred: delete copying on the base `Transport` (S/Socket/Conn.hpp:94): `Transport() = default; Transport(const Transport&) = delete; Transport& operator=(const Transport&) = delete;`. Deleting the copy operations also suppresses the implicit moves. The subclasses `FailedTransport` (TlsTransport.cpp:35), `TlsTransport` (:53) and `PlainTransport` (Conn.cpp:79/:137) are all built with `make_unique` and held as `unique_ptr<Transport>`, so nothing needs a copy. Before deleting, grep for `Transport(` / `*transport_` copies. Minimal alternative: delete copy and assignment on `TlsTransport` only. Platform independent, and the Windows `#else` branch is unaffected. Risk: nil.
- **Shares:** -

#### TLS-04: bad SSL_CERT_FILE disables good SSL_CERT_DIR
- **Triage:** CERTAIN · LOW
- **Test kind:** C++ unit · **Exposes it:** high confidence
- **Test:** The E2E harness cannot set per-test environment variables: CheckPatterns.hpp has only EXIT/STDIN/LINUX-ONLY/XFAIL-NATIVE directives, and the mode-0 context is cached for the whole process. Use an isolated case in the `test` binary instead. It runs in a spawned child (IsolatedTestRunner), so the shared mode-0 context is built fresh. `test` whole-archives every `EcoSystem_*` library (test/CMakeLists.txt:273-290). Register it beside the other isolated guards (`registerReviewBugIsolatedGuards` in test/allocator/ReviewBugGuardsTest.cpp), or in a new test/eco-system-tls/TlsContextEnvTest.cpp added to the `test` sources, which needs OpenSSL include dirs/link (`OpenSSL::SSL`). The case does this:
  1. Write the test CA PEM (copy `caPem` from test/eco-system/src/TlsFixtures.elm into a C++ raw string) into `/tmp/eco-tls04-<pid>/dir/<X509_NAME_hash(subject)>.0`.
  2. `setenv("SSL_CERT_FILE", "/tmp/eco-tls04-<pid>/missing.pem")` (a nonexistent file; also try a file holding garbage) and `setenv("SSL_CERT_DIR", ".../dir")`.
  3. `ensureTlsInit()`, then `buildTlsClientConfig(0, "", "localhost", {}, err)`.
  4. Build an `X509_STORE_CTX` on `SSL_CTX_get_cert_store(cfg->ctx.get())` with the fixture leaf `serverCertPem`, and check `X509_STORE_CTX_get1_issuer(&issuer, sctx, leaf) == 1` (or `X509_verify_cert` == 1).

  Expected (fixed): the issuer is found through the directory. Current: 0, because the directory was never added (OpenSSL 3.0.20 here returns from `SSL_CTX_load_verify_locations` when the file load fails). Wrap it in `XfailGuard::report("TLS-04", defect = issuer not found, ...)` until fixed; then drop the guard and assert. Add a control case (no SSL_CERT_FILE, same dir) that must pass today, to show the fixture works. Linux/macOS only (no OpenSSL on Windows). Files go under /tmp only.
- **Fix:** S/Tls/TlsContext.cpp:80-91 `makeSystemContext`: replace the single call with `if (file) (void)SSL_CTX_load_verify_file(ctx, file); if (dir) (void)SSL_CTX_load_verify_dir(ctx, dir); ERR_clear_error();`. Both are OpenSSL 3 APIs; use `SSL_CTX_load_verify_locations(ctx, file, nullptr)` / `(ctx, nullptr, dir)` if 1.1.1 must still build, e.g. for macOS brew. Update the comment at :86-87 and the file comment in TlsContext.hpp:10-11 ("a file that fails to load stops the directory being added"). Optional follow-up for the related point: when only one variable is set, also load the default for the other (`X509_get_default_cert_dir()` / `_file()`), as `X509_STORE_set_default_paths` does. That is a behaviour change, so the user decides. No heap invariants involved. Risk: low.
- **Shares:** TLS-05 (same TLS unit-test file, if a new one is created)

#### TLS-05: ERR_SSL_NO_CERTIFICATES likely unreachable
- **Triage:** LIKELY · LOW
- **Test kind:** E2E · **Exposes it:** high confidence
- **Test:** New test/eco-system/src/SocketTlsTrustedEmptyTest.elm, modelled on SocketTlsVerifyTest.elm. It uses `SocketTlsHelp.tryCase (T.server [])` with client options `{ serverName = "localhost", verification = Socket.Tls.TrustedCertificates pem, alpn = [] }` for three PEM texts:
  - `""`
  - `"not a certificate"`
  - a `-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----` corrupt block (optional; see Fix)

  CHECK lines (exact text depends on the helper's `failure` formatting; take them from a JS-backend run):
  - `-- CHECK: empty: err TlsError (CertificateUnusable "NO_CERTIFICATES")`
  - `-- CHECK: garbage: err TlsError (CertificateUnusable "NO_CERTIFICATES")`
  - `-- EXIT: 0`

  The reference is the JS backend, not stock Elm: Eco/Kernel/Tls.js:203-207 (and WebSocket.js:2413) already yield `ERR_SSL_NO_CERTIFICATES` whenever no certificate is found. Get it with test/scripts/run-js-e2e.js on this test. Native today gives `CertificateUnusable "NO_START_LINE"`. Mark `-- XFAIL-NATIVE: TLS-05 native reports NO_START_LINE` until fixed; JS must pass. Optional extra: a C++ check `buildTlsClientConfig(1, "", "x", {}, err)` → `err.code == "ERR_SSL_NO_CERTIFICATES"` in test/eco-system-core/EcoSystemCoreTest.cpp, which links EcoSystem_Tls.
- **Fix:** S/Tls/TlsContext.cpp:138-153 `makeTrustedContext`: when `added == 0`, always set `err.code = "ERR_SSL_NO_CERTIFICATES"` and put the OpenSSL text in the message (e.g. `"trusted certificates: no certificate found (" + tlsErrorMessage(ERR_peek_error()) + ")"`), then `ERR_clear_error()`. The user decides whether a corrupt PEM block should keep its ASN1 code; JS's `_Tls_pemCertificates` would likely also give NO_CERTIFICATES, so follow JS. The Elm classifier (Socket/Tls.elm:431, message starts with "trusted certificates" → `CertificateUnusable`) keeps working because the message prefix is kept. The docs at Socket/Tls.elm:328/379 and Http/Server.elm:861 then become true. Risk: low.
- **Shares:** TLS-04 (unit-test file, optional)

#### TLS-06: ERR_SSL_ prefix on all libraries' errors
- **Triage:** CERTAIN · LOW
- **Test kind:** none · **Exposes it:** n/a
- **Test:** None proposed. The behaviour is the documented design (TlsContext.hpp:38, :123-124), and both Elm classifiers (Socket/Tls.elm:431, Http/Server.elm:928) and Eco/Kernel/Stream.js:257 depend on the uniform prefix. If the user chooses to change it, add a CHECK to an E2E listen test with a garbage `privateKey` (e.g. extend HttpServerStartErrorTest.elm or SocketTlsVerifyTest.elm). The CHECK would assert the `CertificateUnusable "<reason>"` produced by the JS backend run (run-js-e2e.js).
- **Fix:** Recommend leaving it as is and closing it as by-design. If changed: map non-SSL libraries in `tlsErrorCode` (S/Tls/TlsContext.cpp:265-274) via `ERR_GET_LIB` to `ERR_OSSL_<LIB>_<REASON>`. In the same change, update `classify` in Socket/Tls.elm:425-440, Http/Server.elm:928 and Stream.js:257 to accept both prefixes, plus the docs. Risk: medium, because user programs matching on code strings would break. **Needs user decision.**
- **Shares:** -

#### TLS-08: failed send error overwritten by reads
- **Triage:** LIKELY · LOW
- **Test kind:** C++ unit · **Exposes it:** medium confidence
- **Test:** New case in test/eco-system-core/EcoSystemCoreTest.cpp (it links EcoSystem_Tls and drives transports by hand, with no scheduler):
  1. `socketpair(AF_UNIX, SOCK_STREAM)`, non-blocking, with small `SO_SNDBUF` on the client end and small `SO_RCVBUF` on the peer.
  2. `auto cfg = buildTlsClientConfig(2 /*NoVerification*/, "", "localhost", {}, err)`, then `auto t = makeTlsClientFactory(cfg)(fdA, false)`.
  3. Call `t->handshake()` until it returns 1 with `wantWrite`, so part of the ClientHello stays pending. If one send takes the whole ClientHello, add padding by offering many ALPN names to grow it.
  4. Close the peer without reading. On Linux, `unix_release_sock` sets ECONNRESET on the survivor when unread data remains, and a later send gets EPIPE.
  5. Call `t->read(buf, n)`: its best-effort `sendOut()` fails with EPIPE, then `fill()`'s `recv` fails with ECONNRESET and overwrites it.
  6. Call `t->write("x", 1)` → -2, then inspect `t->errCode`.

  Expected (fixed): `"EPIPE"`, the send failure. Current: `"ECONNRESET"`. Wrap it in an XfailGuard-style check (include test/XfailGuard.hpp, or a local "xfail" print), because the socket semantics are Linux-specific. Mark it `#ifdef __linux__`, and skip with a message if the steps above do not produce a send failure followed by a recv failure, so the test cannot pass vacuously. The confidence is medium because it relies on Linux AF_UNIX error ordering.
- **Fix:** S/Tls/TlsTransport.cpp: add `int sendErrNo_ = 0; std::string sendErrCode_, sendErrMsg_;` set in `sendOut` at the `broken_ = true` point (:300-306), next to `failErrno(e)`. In `write()` (:160) and in the shutdown/flush paths that return -2 because `broken_`, copy the saved send error back into `errNo/errCode/errMessage` before returning. That way `Conn::writeFailed` (S/Socket/Conn.cpp:727-730) and the shutdown path (:715-722) report the send's own errno. Read failures keep using the shared fields. Risk: low; it only affects error text.
- **Shares:** -

#### TLS-10: stage-2 entry kept until generation change
- **Triage:** LIKELY · LOW
- **Test kind:** C++ unit · **Exposes it:** medium confidence (it confirms the mechanism; the real kill race is not reproduced deterministically)
- **Test:** An E2E program cannot observe the table and cannot reliably land a `Process.kill` between stage-1 completion and the binding's evaluation. Instead, add a small test seam to S/Tls/Tls.cpp, in a `Eco::System::TlsTesting` namespace declared in Tls.hpp, with two functions:
  - `size_t pendingConnectCount()`
  - `HPointer prepareConnectForTest()`, which runs `connectPrepared` on a successful `ConnectPrep` (a dummy spec, `cfg` from `buildTlsClientConfig(2, ...)`) and returns the binding.

  A test in test/eco-system-core/EcoSystemCoreTest.cpp calls the prepare function N=100 times and drops each binding without evaluating it, which is exactly what a kill in the window does. It then checks `pendingConnectCount()`. Expected (fixed): bounded (0 after the sweep/age limit, or ≤ cap). Current: 100. Use an XfailGuard pattern until fixed. Heap generation must stay unchanged during the test (no `resetHeap`).
- **Fix:** Preferred (needs a short investigation): drop the second stage. If the SysWorkPool completion hook can reach the original Task's `resume`/token, start `socketStartConnect` directly from the stage-1 completion on the eco thread, so nothing is parked. Fallback: give `PendingConnect` a creation timestamp (or sequence number). On each `connectPrepared`, erase entries older than e.g. 30 s, and/or cap the table (e.g. 1024, evicting the oldest). A real stage 2 runs in the same scheduler step as its stage 1 completes, so a live entry is never old. An evicted entry's binding already resumes with ECANCELED (Tls.cpp:104-106), so correctness is kept. Update the file comment at Tls.cpp:3-7. Do not hold Elm heap values in the table (HEAP_005: no mutable heap objects; the entry holds only C++ data). Risk: low.
- **Shares:** -

### Area URL

#### URL-01: percentEncode escapes !*'()
- **Triage:** CERTAIN · LOW
- **Test kind:** E2E · **Exposes it:** high confidence
- **Test:** Add test/elm-conformance/src/UrlPercentCodingTest.elm, and add `elm/url` 1.0.0 to that project's elm.json. Record its CHECK lines with `node test/scripts/run-js-e2e.js --project elm-conformance --record UrlPercentCodingTest`. Log `Url.percentEncode "a(b)!*'~"`, which Elm gives as `"a(b)!*'~"` and eco as `"a%28b%29%21%2A%27~"`. Also log `Url.Builder.absolute ["x(y)"] [Url.Builder.string "k" "v!"]`, which is `"/x(y)?k=v!"`. The same file also holds the URL-02 and URL-03 lines. Because XFAIL-NATIVE marks a whole file, either keep one file XFAIL-NATIVE until all three fixes land or, better, split it into UrlPercentEncodeReservedTest.elm, UrlPercentDecodePlusTest.elm and UrlPercentDecodeInvalidUtf8Test.elm, each XFAIL-NATIVE until its own fix lands. Also extend the existing test/elm-url/src/UrlPercentEncodeTest.elm with an `encode3` line once the fix lands.
- **Fix:** In E/url/UrlExports.cpp `shouldEncode` (:38-44), add `! * ' ( )` to the unreserved set. That is `encodeURIComponent`'s set, the same as `Url.cpp::isUnreserved`. Update the file header (:7-9, :17), which documents the old behaviour. Risk: low. An Http request URL changes textually but decodes the same on servers. Check E2E tests that compare built URLs (test/elm-url, test/elm-http) for expectations that encode those characters.
- **Shares:** The test file (or split set) is shared with URL-02 and URL-03. The fix shares the Url.cpp salvage with URL-04.

#### URL-02: percentDecode decodes + as space
- **Triage:** CERTAIN · MEDIUM
- **Test kind:** E2E · **Exposes it:** high confidence
- **Test:** In the UrlPercentCodingTest set (see URL-01), log three things:
  - `Url.percentDecode "a+b"`, which Elm gives as `Just "a+b"` and eco as `Just "a b"`.
  - `Url.percentDecode "c%2B%2B"`, which is `Just "c++"`.
  - The query parser result for `Url.fromString "http://x/?q=c++"` with `Url.Parser.Query.string "q"`, wrapped through `Url.Parser.query` and `Url.Parser.parse`. That is `Just (Just "c++")`.

  Record the CHECK lines from node. The file is XFAIL-NATIVE until the fix. Also add `decode3: Just "a+b"` to test/elm-url/src/UrlPercentDecodeTest.elm with the fix.
- **Fix:** Delete the `'+'` branch at E/url/UrlExports.cpp:100-102 together with its comment, and update the header comment. Risk: low. Look for any eco-own code (eco/system Http server form parsing, S/) that relied on `Url.percentDecode` treating `+` as a space for `application/x-www-form-urlencoded`. If there is any, it must replace `+` itself before decoding.
- **Shares:** Test with URL-01 and URL-03. The fix is in the same function as URL-03.

#### URL-03: percentDecode returns Just on invalid UTF-8
- **Triage:** CERTAIN · MEDIUM
- **Test kind:** E2E · **Exposes it:** high confidence
- **Test:** In the UrlPercentCodingTest set (see URL-01), log `Url.percentDecode` of five inputs:
  - `"%FF"`
  - `"%E2%82"` (a truncated sequence)
  - `"%ED%A0%80"` (an encoded surrogate)
  - `"%C0%AF"` (an overlong encoding)
  - `"%E2%82%AC"`, a valid control that must give `Just "€"`

  Elm (JS `decodeURIComponent` throws URIError) gives `Nothing` for the first four. Eco gives `Just ""` / `Just "\u{2080}"` / ... today. Record the CHECK lines with `--record` on node. The file is XFAIL-NATIVE until the fix.
- **Fix:** In E/url/UrlExports.cpp `Elm_Kernel_Url_percentDecode`, validate `decoded` strictly before allocating. Return `nothing()` on any of these:
  - a bad lead byte
  - a missing or bad continuation byte
  - an overlong form
  - a surrogate (U+D800-DFFF)
  - a value above U+10FFFF

  Move the strict decoder `utf8ToUtf16` from E/url/Url.cpp:83-133 into UrlExports.cpp's anonymous namespace, or use an existing strict validator in StringOps if one exists. Then build the String from the validated units with `alloc::allocString(u16*, n)`, not the lenient `allocStringFromUTF8`. Risk: low; only invalid input changes.
- **Shares:** Test with URL-01 and URL-02. The fix reuses Url.cpp code (see URL-04).

#### URL-04: dead percentEncode encodes lone surrogates
- **Triage:** CERTAIN · LOW
- **Test kind:** none (build/link check) · **Exposes it:** n/a (dead code)
- **Test:** None. Before deleting, confirm with `grep -rn "Url::percentEncode\|Url::percentDecode\|url/Url.hpp\|\"Url.hpp\"" /work --include=*.cpp --include=*.hpp --include=*.h`. The only hits should be Url.cpp itself and the comment at UrlExports.cpp:17. After deleting, `cmake --build build` (including the `test` and `stress-test` targets) must link. The existing test/elm-url E2E tests stay green.
- **Fix:** First carry the useful parts into UrlExports.cpp: the JS-correct unreserved set (URL-01) and `utf8ToUtf16`/the strict decoder (URL-03). Then delete E/url/Url.cpp and E/url/Url.hpp, remove `src/url/Url.cpp` from elm-kernel-cpp/CMakeLists.txt:290, and drop the "unused namespace functions" sentence at UrlExports.cpp:17. Do NOT delete UrlExports.cpp or its CMake line (:291), or anything in E/url beyond these two files. Check the kernel license manifest and home checks (test/scripts/check-kernel-license-manifest.sh, check-kernel-homes.sh) for entries naming Url.cpp, and remove those entries too. Risk: none once the build links.
- **Shares:** One commit with the URL-01 and URL-03 fixes, which take code from this file.

### Area UTILS

#### UTILS-02: mixed boxed/unboxed Float comparison uses raw operators
- **Triage:** LIKELY · LOW
- **Test kind:** C++ unit · **Exposes it:** high confidence (for the code defect; compiled Elm cannot reach it, per REP_HEAP_001/MONO_029)
- **Test:** Extend test/kernel/UtilsAppendEqualityTest.cpp, or add test/kernel/UtilsMixedSlotCompareTest.cpp registered in the same `test` binary. Build two one-element Float lists by hand:
  - A: `cons(unboxedFloat(1.0), Nil, 2)` (unboxed head)
  - B: `cons(boxed allocFloat(NaN), Nil, 0)` (boxed head)

  Then check:
  - `Elm_Kernel_Utils_compare(A, B)` must equal `compare` of two unboxed lists `[1.0]` vs `[NaN]`, which is LT (`compareFloat`: NaN is above every number). Today it is GT.
  - Mixed `[NaN]` vs `[NaN]` must be EQ; today it is GT.
  - Check `cmp3` the same way.

  Root both lists with `StackRootGuard` between allocations. Wrap the test in `XfailGuard::report("UTILS-02", defect, ...)` until fixed, so that it shows XFAIL today and XPASS after. Run with `build/test/test --filter "UTILS-0"`. Remember that the `test` target is not in `all`, so build it by name, and set `ulimit -c 0`.
- **Fix:** In E/core/Utils.cpp `compareListElem` (:241-245), replace both raw ternaries with `compareFloat(bv, uv)` / `compareFloat(uv, bv)`. Rename the function to `compareMixedSlot` so that UTILS-03 can reuse it. Also update the Utils.hpp:81-82 comment ("except that a boxed and an unboxed ... raw `<`"). Risk: none; it is NaN-only.
- **Shares:** UTILS-03 (same test file, same helper).

#### UTILS-03: compare and == disagree on tuples with one boxed slot
- **Triage:** LIKELY · LOW
- **Test kind:** C++ unit · **Exposes it:** high confidence (for the code defect; compiled Elm cannot reach it)
- **Test:** Use the same unit test file as UTILS-02. Build:
  - `t1 = tuple2(unboxedInt(1), unboxedInt(7), mask with both kinds Int)`
  - `t2 = tuple2(boxed allocInt(1), unboxedInt(7), slot0 kind 0)`

  Then assert:
  - `Elm_Kernel_Utils_equal(t1, t2)` is True; this already holds through `eqUnboxableSlot`.
  - `Elm_Kernel_Utils_compare(t1, t2)` is EQ; today it is LT/GT by kind.
  - `Elm_Kernel_Utils_compare(t1, t3)`, where `t3` has a boxed 2 in slot 0, is LT.

  Write the same cases for a Tuple3 slot 2, with a Float and a Char. Use the XfailGuard id "UTILS-03".
- **Fix:** In `cmp` Tag_Tuple2 (:342, :349) and Tag_Tuple3 (:363), when `aKind != bKind`, return `compareMixedSlot(allocator, aSlot, bSlot, aKind, bKind)` (the renamed `compareListElem`) instead of ordering by kind. That keeps `cmp` consistent with `eqUnboxableSlot`. Kind-ordering is still the fallback inside the helper for genuinely different types, which cannot happen for well-typed values. Check whether `cmp3` and `eco_*_cmp3` share this code path. Invariants: REP_HEAP_001 (unchanged; this is only defensive). Risk: low.
- **Shares:** UTILS-02 (the test file and the helper rename).

#### UTILS-05: eqHelp assumes equal past depth 100
- **Triage:** CERTAIN · HIGH
- **Test kind:** E2E · **Exposes it:** high confidence
- **Test:** Write two tests.
  - **(a) New conformance file.** test/elm-conformance/src/DeepEqualityTest.elm, recorded from node, with `type Nat = Z | S Nat` built by a fold and `type Nest = Leaf Int | Wrap Nest`. Elm values:
    - `S^150 Z == S^200 Z` → `"False"`
    - `S^150 Z == S^150 Z` → `"True"`
    - `nest 120 1 == nest 120 2` → `"False"`
    - `nest 500 1 /= nest 500 2` → `"True"`
    - a record chain `{ next : Maybe Chain, v : Int }`, 300 deep, differing only at the bottom: `==` → `"False"`
    - a `Dict Int Nest` whose values differ at depth 150 → `"False"`

    Today eco answers `True` for every unequal row. Mark the file `-- XFAIL-NATIVE: UTILS-05 eqHelp assumes equal past depth 100`.
  - **(b) Existing test.** test/elm/src/EqDepthCutoffTest.elm pins the bug (`aboveLimit: True`). In the fixing commit, change that CHECK to `aboveLimit: False` and rewrite its doc comment, or delete the test in favour of (a).

  Run both with `TEST_FILTER=elm cmake --build build --target full`.
- **Fix:** Do it the elm/core JS way. In E/core/Utils.cpp, give `eqHelp` a `std::vector<std::pair<void*,void*>>& deferred` parameter, threaded through `eqUnboxableSlot`, `eqListHybrid` and `dictEq`. At `depth > 100`, push `(a, b)` and return true, instead of returning true outright. The top-level `equal` (:434) loops: it starts with `eqHelp(a, b, 0, stack)`, then pops each deferred pair and calls `eqHelp(pair, 0, stack)` until the stack is empty or a call returns false. Recursion stays bounded at about 100 frames, so the change adds no C-stack-overflow risk, unlike making the recursion unbounded. Raw pointers in the vector are safe only because equality allocates nothing and no GC can run during it, which is the existing premise of `resolveAndCompare`/`safeResolve`. State that in a comment, and keep the vector off the GC heap. Every caller of `eqHelp`/`equal` gets the fix, including `eco.value.eq` arm 3 (the same kernel), `List.member` and Dict/Set. Optionally, `cmp` has no depth limit and is plain recursive; check that it cannot overflow on these inputs (`compare` is not allowed on custom types, so it probably cannot). Risk: low to medium, on the hot path of `==`. Run a benchmark only if the plan's perf gate requires it.
- **Shares:** -

#### UTILS-06: function equality returns false
- **Triage:** CERTAIN · LOW
- **Test kind:** E2E · **Exposes it:** high confidence (once the intended behaviour is decided)
- **Test:** Add a new eco-specific file, test/elm/src/FunctionEqualityCrashTest.elm. Elm JS crashes here, and the conformance recorder may not capture a crash, so the file goes in test/elm rather than elm-conformance. Its program:
  - `let f = \x -> x + 1 in Debug.log "same ref" (f == f)` → `True` (JS checks `x === y` first)
  - `Debug.log "distinct" ((\x -> x) == (\x -> x))`, which crashes

  Directives:
  - `-- CHECK: same ref: True`
  - `-- CHECK:` with the first line of the elm/core message ("Trying to use `(==)` on functions."); copy it exactly from node running `build/toolchain/bin/elm make` output, in dev mode
  - `-- CHECK-NOT: distinct:`
  - `-- EXIT: 1`

  Today eco logs `distinct: False` and exits with 0. Mark it XFAIL-NATIVE until the fix. Add a record case (`{ g = f1 } == { g = f2 }`) as a second file if you want both paths pinned; a crash ends the program after the first.
- **Fix:** Needs a user decision first.
  - **If eco should match Elm:** in E/core/Utils.cpp `eqHelp`, make `case Tag_Closure:` (:678) report the elm/core message through the runtime output and `std::exit(1)`, as `Elm_Kernel_Debug_todo` does (E/core/DebugExports.cpp:41), or through `eco_crash`. Do this without throwing a C++ exception across `extern "C"`. `a == b` identity is already handled at :491. Also check whether the compiler folds `==` at function types itself (the `eco.value.eq` lowering); if it does, add the same crash there.
  - **If the divergence is kept:** record it in design_docs/ conformance notes, and add the test expecting `distinct: False`.

  Risk: low; only programs that are buggy in stock Elm are affected.
- **Shares:** -

### Area WATCH

#### WATCH-02: renamed sub-dir keeps stale relative path
- **Triage:** CERTAIN · MEDIUM
- **Test kind:** E2E · **Exposes it:** high confidence
- **Test:** New /work/test/eco-system/src/FileWatchRenameDirTest.elm. It runs `watchRecursive` on a fresh `makeTempDirectory` dir. Steps: sleep 100; `makeDirectory a`; sleep 300 (a drain maps IN_CREATE and adds the watch on `a`); `File.move (child dir "b") (child dir "a")`; sleep 300; `writeFile (child dir "b/x")`. It finishes on the first event whose path ends in `/x`, or at the 3 s deadline. CHECK lines: `-- CHECK: watching`, `-- CHECK: event: moved a`, `-- CHECK: event: moved b`, `-- CHECK: event: moved b/x`, `-- CHECK-NOT: a/x`, `-- CHECK: watch: done`, `-- EXIT: 0`. The event order "moved a" (MOVED_FROM) then "moved b" (MOVED_TO) is deterministic. The correct output reports `b/x`. Today `addDir` returns early at WatchService.cpp:206 and keeps rel "a", so the file event is `moved a/x` and the CHECK fails. Default inotify mode, Linux. Poll mode passes, because it re-snapshots paths. Mark it `-- XFAIL-NATIVE: WATCH-02 inotify keeps the pre-rename relative path` until fixed. Optional deterministic twin in EcoSystemCoreTest.cpp: add(D, true); mkdir D/a; drain; rename D/a D/b; drain; touch D/b/x; wait for `hasEvents()`, settle 50 ms, drain; expect the path "b/x" (today "a/x").
- **Fix:** In /work/system-kernel-cpp/src/eco-system/FileSystem/WatchService.cpp `Impl::mapInotify`, for a record with `IN_ISDIR` and `IN_MOVED_FROM` on a recursive watch, compute `old = u.rel.empty() ? r.name : u.rel + "/" + r.name`. Then call a new `dropSubtree(id, old)`: for every wd in `iwatches[id].wds` whose use by `id` has `rel == old` or `rel` starting with `old + "/"`, call `dropWd(id, wd, /*rmWatch=*/true)` and erase the wd from `iwatches[id].wds`. Never drop rel "" (the watch's own root). The existing IN_MOVED_TO|IN_ISDIR branch (:283-286) then re-adds `b` and its tree under the new rels. After `inotify_rm_watch` the kernel gives the same inode a fresh wd, and the old wd's later IN_IGNORED finds no `wdUses` entry and is ignored. Records already queued for the old wd (changes inside the directory between the rename and the drain) are lost. Covering them is WATCH-08's synthesise-on-add walk, which also emits `b/...` entries, so do WATCH-08 in the same change. Keep the "already watched" early return in `addDir`, because the root and nested-root cases rely on it, but update its comment. Update WatchService.hpp (inotify bullet) to say that a renamed or moved-out directory stops being reported under its old path. Rename cookies are not needed. No invariant row; the risk is a dropped use that belongs to another watch, which `dropWd` already prevents by removing only `id`'s uses.
- **Shares:** WATCH-03 (same `dropSubtree` fix); WATCH-08 (re-add of the moved-in tree should synthesise events); same unit-test scaffold as WATCH-03/04/05/07/08.

#### WATCH-03: directory moved out keeps reporting
- **Triage:** CERTAIN · MEDIUM
- **Test kind:** E2E · **Exposes it:** high confidence
- **Test:** New /work/test/eco-system/src/FileWatchMoveOutTest.elm. It creates two temp dirs with `makeTempDirectory`: the watched root R and an outside dir O, both under the same /tmp so `move` is a rename. Steps: `watchRecursive R`; sleep 100; mkdir R/sub; sleep 300; `move (O/gone) (R/sub)`; sleep 300; `writeFile O/gone/x`; sleep 1200; `writeFile R/marker`. It finishes on the event `moved marker`, or at the deadline. CHECK lines: `-- CHECK: event: moved sub`, `-- CHECK-NOT: x`, `-- CHECK: event: moved marker`, `-- CHECK: watch: done`; the CHECK-NOT is placed before the marker line, so it covers the window. Correct: nothing about `x`. Today: `moved sub/x` (and possibly `changed sub/x`), because the sub-directory's wd still has its use with rel "sub". Linux inotify only. Mark it `-- XFAIL-NATIVE: WATCH-03 moved-out sub-directory still reported`. Clean up both temp dirs at the end. A deterministic C++ twin is possible as for WATCH-02.
- **Fix:** Same as WATCH-02: drop the subtree's uses on `IN_MOVED_FROM|IN_ISDIR` with `rmWatch=true`. Also make the sub-directory's own `IN_MOVE_SELF`, now skipped at :276, a no-op as it is today; the parent's MOVED_FROM is the trigger. This also frees the leaked wds and the `iwatches[id].wds` entries. Risk is as for WATCH-02. When a directory is moved out and back in before a drain, the MOVED_TO re-adds it correctly.
- **Shares:** WATCH-02 (one fix, one commit); unit scaffold.

#### WATCH-04: inotify vs poll disagree on symlinked root
- **Triage:** CERTAIN · MEDIUM
- **Test kind:** C++ unit · **Exposes it:** high confidence
- **Test:** In /work/test/eco-system-core/EcoSystemCoreTest.cpp, add `testWatchSymlinkRoot`. It creates /tmp/eco-watch-XXXXXX/d and a symlink L -> d. The inotify part runs in-process (the parent's default mode, Linux): add(L, false); write d/f; wait up to 3 s for an event with path "f" (passes today). The poll part runs in a spawned child with `ECO_SYSTEM_WATCH_POLL=1` and the same steps, waiting up to 3 s, since the poll period is 1 s. The correct result is an event "f" in both modes. Today the poll child sees none, because `takeSnapshot` `lstat`s the root, sees S_IFLNK and returns at :93. Use XFAIL ("WATCH-04") until fixed. Optional E2E /work/test/eco-system/src/FileWatchSymlinkRootTest.elm (uses the link API exercised by FileLinksTest.elm; CHECK `event: moved f`). It passes on Linux inotify today and would expose the bug on macOS hosts, where poll is the only mode. That makes it a cross-backend pin, not the Linux reproducer.
- **Fix:** In WatchService.cpp `takeSnapshot`, take the root entry with `stat` (follow), and keep `lstat` for entries below it. One way is to give `sigOf` a `follow` flag, used only for `out[""]`. The `recursive_directory_iterator(root)` already opens through the link, and `fs::relative` canonicalises both sides, so the relative paths are unaffected. Do not use `realpath` in `add`: with `stat` per poll, retargeting the link reports a pathless Moved (the inode changes), which is the better behaviour. Update WatchService.hpp (poll bullet: "the watched path itself is followed if it is a symbolic link; entries below it are not") and the inotify bullet to say the same. Risk: low. A watched symlink to a file now watches the file, which matches inotify.
- **Shares:** WATCH-05 (same poll-mode child scaffold).

#### WATCH-05: poll-mode vanished root events
- **Triage:** CERTAIN · LOW
- **Test kind:** C++ unit · **Exposes it:** high confidence
- **Test:** In EcoSystemCoreTest.cpp, add `testWatchPollRootVanishes`, which runs in the poll child (`ECO_SYSTEM_WATCH_POLL=1`). Steps: make d with files a and s/b; add(d, true); wait 1.5 s and drain (nothing); `rm -rf d` (std::filesystem::remove_all); wait 1.5 s and drain, expecting exactly one pathless Moved; recreate d, d/a and d/s/b; wait 2.5 s and drain. Under the recommended semantic (match inotify, the watch goes silent after its vanish event) the last drain has 0 events. Today it has 4 Moved events ("", "a", "s", "s/b"). As a cross-check, run the same scenario in-process in inotify mode: one pathless Moved, then silence (passes today). Use XFAIL ("WATCH-05") until fixed.
- **Fix:** This needs a decision on the semantic (see the final reply). Recommended: match inotify. In `pollThread`, when `!exists && !old.empty()` queue the pathless Moved and then mark the watch finished: add a `bool gone` to `PollWatch` and skip it in the `todo` collection. Do not erase it, because `remove(id)` must stay a harmless no-op. The alternative is to keep watching and on reappearance report one pathless Moved, then seed `old` from `now` silently. Either way, update WatchService.hpp (poll bullet) and the `FileSystem.watch` docs in system-kernel-cpp/src/FileSystem.elm, which should say what happens after the watched path disappears, and check that FileSystem.js (Node) behaves the same. Risk: low, poll mode only.
- **Shares:** WATCH-04 (poll child scaffold).

#### WATCH-07: IN_Q_OVERFLOW dropped silently
- **Triage:** CERTAIN · MEDIUM
- **Test kind:** C++ unit · **Exposes it:** medium confidence (exercises the mapping path deterministically through a test seam; a real kernel queue overflow is not reproduced)
- **Test:** A real overflow is not practical here. `max_queued_events` (16384) is a global sysctl that needs root, and the reader thread drains the kernel queue promptly into an unbounded deque. So add a test seam to WatchService. It can be a public `void injectRawForTesting(int wd, uint32_t mask, std::string name)` that calls `impl_->push`, documented as test-only; another option is a separate internal header used by the test. In EcoSystemCoreTest.cpp `testWatchQueueOverflow` (inotify mode, in-process): add two watches (dirs d1 and d2); inject `(wd=-1, IN_Q_OVERFLOW, "")`; drain. The correct result is one pathless Moved for each of the two watch ids. Today there are none, because `wdUses.find(-1)` fails at :250 before the check at :267. Use XFAIL ("WATCH-07") until fixed. A best-effort real reproducer (low confidence, do not gate on it) is a stress-test that creates and deletes 100k files in a watched dir with the scheduler thread blocked, then checks that a pathless Moved arrives.
- **Fix:** In `mapInotify`, test `r.mask & IN_Q_OVERFLOW` first, before the `wdUses` lookup. For every entry in `iwatches`, emit `WatchEvent{id, 1, false, ""}` and return. Remove the dead check at :267. Update WatchService.hpp:22 ("A queue overflow ... reported as one Moved with no path for every watch, meaning rescan") and the Elm docs of `watch`/`watchRecursive`. A pathless Moved currently means "the watched path itself changed"; its meaning widens to "rescan". Risk: low. Poll mode has no overflow.
- **Shares:** Unit scaffold with WATCH-02/03/04/05/08.

#### WATCH-08: files in new sub-dir before watch added missed
- **Triage:** CERTAIN · MEDIUM
- **Test kind:** E2E · **Exposes it:** high confidence (for the nested directories; the file part is timing-dependent)
- **Test:** New /work/test/eco-system/src/FileWatchNewTreeTest.elm. Steps: `watchRecursive dir`; sleep 100; `makeDirectory { recursive = True } (child dir "a/b/c")` and then immediately `writeFile (child dir "a/b/c/f")`. One recursive mkdir creates b and c before any drain can add a watch on a, so missing `a/b` and `a/b/c` is deterministic. It finishes when it has seen `moved a/b/c/f`, or at the deadline. Unordered checks: `-- CHECK-DAG: event: moved a`, `-- CHECK-DAG: event: moved a/b`, `-- CHECK-DAG: event: moved a/b/c`, `-- CHECK-DAG: event: moved a/b/c/f`, then `-- CHECK: watch: done`. With a fix, duplicate Moved events (walk plus real IN_CREATE) are allowed; CHECK-DAG tolerates them. Today only `moved a` arrives, and `a/b/c/f` arrives only if the write lands after the drain that ran `addTree`. Mark it `-- XFAIL-NATIVE: WATCH-08 entries of a new sub-tree created before its watch are not reported`. Poll mode passes. A fully deterministic C++ twin: add(D, true); `create_directories(D/a/b/c)`; write D/a/b/c/f; wait for `hasEvents`; drain. Today the only event is "a"; the expected events are a, a/b, a/b/c, a/b/c/f.
- **Fix:** In `mapInotify`'s new-directory branch (:283-286), after `addDir` and `addTree`, walk the new directory, which can be merged into `addTree`: give it an `std::vector<WatchEvent>* synth` out-param. For every entry found (files, directories, symlinks; do not descend into symlinked directories), push `WatchEvent{id, 1, true, ev.path + "/" + rel}` after the directory's own event. The walk must come after the watch is added, so nothing is lost in between (the standard idiom). The same branch runs on IN_MOVED_TO, so a moved-in tree is also reported entry by entry, which completes WATCH-02. Update WatchService.hpp (inotify bullet). Risk: a large extracted tree produces many events (that is the intended behaviour), and duplicates are possible.
- **Shares:** WATCH-02/03 (same branch; do in one change); unit scaffold.

### Area WS

#### WS-08: wsRandomBytes falls back to mt19937_64
- **Triage:** CERTAIN · LOW
- **Test kind:** static check · **Exposes it:** high confidence
- **Test:** Add a line to the static checks run by `--target full` (next to
  `test/scripts/check-kernel-homes.sh`, e.g. a new `test/scripts/check-ws-rng.sh`): fail if
  `grep -nE 'mt19937|random_device' /work/system-kernel-cpp/src/eco-system/WebSocket/` finds
  anything. It fails today on WsHandshake.cpp:171. A runtime test cannot expose this on Linux,
  because `RAND_bytes` does not fail on a seeded OpenSSL. A unit test would need a test seam (a
  replaceable RNG function pointer) that exists only for this purpose, which is not worth it.
  Optional extra: a unit test in EcoSystemCoreTest.cpp checking that 1,000 `nextMask` keys are not
  all equal is a sanity check only, not a test of this bug. No XFAIL needed: add the check together
  with the fix, or mark it "expected to fail" in the script until then.
- **Fix:** S/WebSocket/WsHandshake.cpp `wsRandomBytes`: drop the mt19937 fallback. Make it
  `bool wsRandomBytes(...)` (true on success). On POSIX it is `RAND_bytes`. On `_WIN32` use
  `BCryptGenRandom(nullptr, out, n, BCRYPT_USE_SYSTEM_PREFERRED_RNG)`, and do the same in `wsNewKey`,
  which today returns "" on Windows. `nextMask` (WsProtocol.cpp:35) is reached from `buildFrame`
  inside reactor-side write paths, including `failWith`, so throwing there is unsafe. On failure,
  print a message to stderr and `std::abort()`: a broken system RNG is a fatal environment fault,
  as in OpenSSL's own policy, and it can no longer be silent. A gentler alternative is a
  `rngFailed_` flag checked in `buildFrame` that turns into `failConnection(1011, ...)` on the next
  entry point, but that adds re-entrancy risk for no practical gain. Risk: low. The Windows part may
  stay unverified (memory: Windows is low priority; the Windows client dial is ENOTSUP anyway).
- **Shares:** -

#### WS-11: resume path skips default heartbeat timeout
- **Triage:** CERTAIN · LOW
- **Test kind:** C++ unit · **Exposes it:** high confidence
- **Test:** EcoSystemCoreTest.cpp, new `testWsCoreHeartbeatResume()` on the shared fake-port harness.
  A black-box E2E cannot reach this: entering a pause always needs received bytes (`held_` is set
  only on data end, and queue limits grow only with input), and those bytes arrive after the
  heartbeat ping, so `rxBytes_ > rxAtPing_` saves it. The unit test instead looks at the deadline:
  1. Client core with `cfg.heartbeatInterval = 50`, `heartbeatTimeout = 0`; `attach(&fake)`.
  2. Sleep 60 ms, then `portTimer(Conn::kTimerHeartbeat)`. A ping is now outstanding; check the
     recorded `kTimerPong` deadline ≈ now + 30000.
  3. `portData` with 1,100 small unmasked server text frames. This pauses (`kReadHighCount` 1024),
     and the fake records `kTimerPong ← 0`.
  4. Issue `reqRead` about 200 times and pop the results until it unpauses.
  5. Check the last recorded `kTimerPong` deadline is ≥ `nowMs() + 29000`.

  Today the deadline is ≈ `nowMs()` (the defect). Mark it xfail `WS-11` until fixed.
- **Fix:** S/WebSocket/WsProtocol.cpp:685 in `WsCore::checkPause` should read
  `if (hbPingSent_) hbDeadline_ = t + (cfg_.heartbeatTimeout > 0 ? cfg_.heartbeatTimeout : kDefaultPingTimeoutMs);`.
  Better, hoist `pingTimeout` (computed on line 687) above that line and use it on both lines, or
  add a `WsCore::pingTimeoutMs()` helper and use it at :685, :687, :1190 and :1227 so the four
  sites cannot drift again. No invariant affected. Risk: trivial.
- **Shares:** test harness with WS-12, WS-13, WS-16 (same new section of EcoSystemCoreTest.cpp).

#### WS-12: closeFrameWritten ignores err
- **Triage:** CERTAIN · MEDIUM
- **Test kind:** C++ unit (E2E as optional secondary) · **Exposes it:** high confidence (unit)
- **Test:** EcoSystemCoreTest.cpp `testWsCoreCloseWriteFails()`, on the fake-port harness, with
  `portOutbound() = 0` so the Close frame is handed to the port:
  - (a) Client core, `attach`; `writeClose(chan=7, token=1)`. The fake records the Close write; do
    not complete it. Then call that `done(EPIPE)` and `portError(EPIPE, "write EPIPE")`. Expected:
    the ChannelResult for token 1 has `err == ECANCELED` and reason "socket closed"
    (`kSocketClosed`), the contract in `writeClose`/`ended`. Today it has `err == 0`.
  - (b) As (a), but first `portData` a server Close 1000 frame, so `closeReceived_` is set. Then
    `done(ECANCELED)` (what `Conn::closeNow` → `failOutbound` does), then `portClosed()`. Expected:
    the posted `Closed` WsEvent is unclean (Abnormal 1006, clean false). Today it is clean 1000.
  - (c) The same with `startClose(1000, "", token=2)`. The fixed behaviour must match what `ended`
    gives `closeOps_`: `postOpDone` (success), because Elm `WebSocket.close` is `Task.mapError never`
    and documented to succeed on an ended connection. So (c) is a regression pin, not part of the
    defect.

  Mark (a) and (b) xfail `WS-12`. An E2E (`WebSocketCloseFailTest.elm`) is possible but timing
  dependent. The Close must sit inside Conn's pending buffer, not in `outQ_`, when the raw peer
  calls `Socket.reset`. That window is between the kernel send buffer filling and Conn's 64 KiB
  high-water mark, so a test would be flaky: low confidence. Not recommended.
- **Fix:** S/WebSocket/WsProtocol.cpp:1028 `WsCore::closeFrameWritten(int err)`. If `err != 0`, do
  not set `closeWritten_` and do not complete the waiters with success. Leave `closeOps_` and
  `closeWaiters_` in place, so the `ended()` branch at :1099 (reached from the `onError` that
  follows any write failure or abort) completes them: ops as OpDone, waiters as ECANCELED
  "socket closed". Also skip `finishIfDone()` on error. If some error path might reach the port
  without a later `ended`/`portClosed` (check `H2StreamPort` write-failure handling and
  `WsProtocol::onError`), then on `err != 0` call a small `failCloseWaiters()` shared with `ended()`.
  Extract it as a helper from :1101-1113 and use it from both places. Optionally set a
  `closeWriteFailed_` flag so `postClosed()` records unclean. Risk: low to medium, because three
  call sites pass this callback (:216 echo, :739 pumpWrites, :1078 failWith). The fix interacts with
  WS-13 (same flag) and WS-16 (`closeSent_`), so do the three together.
- **Shares:** test harness with WS-11, WS-13, WS-16; fix overlaps WS-13 and WS-16 (close-state flags).

#### WS-13: ended sets closeWritten_ without a write
- **Triage:** CERTAIN · LOW
- **Test kind:** C++ unit · **Exposes it:** high confidence
- **Test:** EcoSystemCoreTest.cpp `testWsCoreLateCloseAfterAbnormalEnd()`, on the fake-port harness,
  with `portOutbound() = 1 MiB` so the Close stays in `outQ_`:
  - (a) `writeClose(chan, 1)`, then `portError(ECONNRESET, "read ECONNRESET")`. Token 1 gets
    ECANCELED, which is already correct.
  - Then `writeClose(chan, 2)`. Expected ECANCELED "socket closed"; today `err == 0` (the defect).
  - (b) Control: a fresh core, `portError` with no earlier close, then `writeClose(chan, 3)`. This
    gives ECANCELED today.

  The test asserts that (a)'s second result equals (b)'s. Mark xfail `WS-13`.
- **Fix:** S/WebSocket/WsProtocol.cpp `WsCore::ended` (:1099-1101): stop setting
  `closeWritten_ = true`. The swaps already empty `closeOps_`/`closeWaiters_`, so no flag is needed
  to avoid completing them twice. Then `writeClose`'s early branch (:976, `!clean_ && !closeWritten_`)
  gives ECANCELED regardless of history. Check that nothing else reads `closeWritten_` after `ended`
  as "a Close was attempted": `finishIfDone` is guarded by `failed_`/`closedPosted_`, and
  `failWith`'s `!closeWritten_` returns early on `closedPosted_` anyway. Should a separate
  `closeAttempted_` turn out to be needed, add it. Risk: low.
- **Shares:** test harness with WS-11/12/16; fix in the same flag cluster as WS-12/WS-16.

#### WS-16: failWith no close deadline, may send second Close
- **Triage:** LIKELY · LOW
- **Test kind:** C++ unit · **Exposes it:** high confidence
- **Test:** EcoSystemCoreTest.cpp `testWsCoreSingleCloseFrame()`, on the fake-port harness, with
  `portOutbound() = 0` and write callbacks left uncompleted, so the port is "backpressured":
  - (a) Client core `startClose(1000, "bye", 1)`; the Close is handed to the fake. Then `portData`
    a frame with a reserved opcode (0x3). Close frames are still decoded after our Close (only data
    is discarded), so this leads to `failConnection(1002)` → `failWith`. Decode all recorded writes
    and count opcode-8 frames: expected 1, today 2.
  - (b) Same, but the second path is the heartbeat. Use `heartbeatInterval = 30`,
    `heartbeatTimeout = 30`, call `startClose` after the ping was sent, sleep 40 ms, then
    `portTimer(kTimerPong)` → `heartbeatTimeout()` → `failWith`. Count Close frames.
  - (c) Optional: a peer-Close echo after our Close was handed over. `closeQueued_` blocks this
    today, so (c) is a pin, not a reproduction.

  The "no deadline" half of the claim is refuted in the analysis (both ports bound it with
  `kDrainMs`), so it gets no test. Mark (a)/(b) xfail `WS-16`.
- **Fix:** S/WebSocket/WsProtocol.cpp. Add `bool closeSent_` and set it wherever a Close frame is
  handed to the port: `pumpWrites` isClose branch (:736-740), the `onControl` echo (:216), and
  `failWith` itself (:1074). In `failWith`, replace `if (!closeWritten_)` with `if (!closeSent_)`.
  `closeQueued_` is not enough: it is true while the Close is still in `outQ_`, where
  `failQueued` drops it, and then `failWith` must still write its own Close. Do the same
  `closeSent_` check in `heartbeatTimeout`'s path, which goes through `failWith`. Risk: low.
  Combine with WS-12/WS-13 so the four flags (`closeQueued_`, `closeSent_`, `closeWritten_`,
  waiter lists) get one coherent comment block in WsProtocol.hpp.
- **Shares:** test harness with WS-11/12/13; fix cluster with WS-12/WS-13.

#### WS-18: deliverClose marks delivered before deliver
- **Triage:** LIKELY · LOW
- **Test kind:** E2E · **Exposes it:** medium confidence
- **Test:** New `/work/test/eco-system/src/WebSocketCloseChurnTest.elm`, a `Platform.worker` with
  subscriptions, in the style of `WebSocketSubscriptionTest.elm`:
  1. Open two client/server pairs A and B (`W.connect`/`W.acceptOne`). Close both and wait for both
     with `WebSocket.awaitClose`, so both are ended and their closes undelivered. The model keeps
     both `WebSocket` values, so the stream faces stay alive and the entries stay in the table.
  2. In one update, subscribe `WebSocket.onClose` for both client sockets. `onEffects` then runs
     `deliverHeldCloses` with ids [A, B].
  3. The handler for the first close (whichever arrives first, so the result does not depend on
     order) removes the *other* socket's `onClose` from `subscriptions` and starts
     `Process.sleep 50`.
  4. After the sleep, subscribe that onClose again. The program waits up to 500 ms for its close,
     then prints.

  CHECK lines:
  `-- CHECK: first close: Normal "" clean True`
  `-- CHECK: second close after resubscribe: Normal "" clean True`
  `-- CHECK-NOT: second close never delivered`
  `-- EXIT: 0`

  Today natively the second id is marked delivered with nothing sent, so the program prints
  "second close never delivered". Add `-- XFAIL-NATIVE: WS-18 close marked delivered with no
  subscriber`. **Precondition:** run the program on the JS backend first; it must pass there (JS
  delivers held closes through `_WebSocket_holdClose`/`W.held`). If JS also drops the close, the
  promised semantics (WebSocket.elm:577-584) need a user decision. Confidence is medium because the
  defect needs the dropped subscription to reach `state().subs` inside `deliver`'s
  `Scheduler::drain()`, before the loop gets to the next id. Before trusting an XFAIL, confirm by
  adding a temporary stderr print in `deliverClose` (`subsOf(id)==nullptr`).
- **Fix:** S/WebSocket/WsManager.cpp. Make `deliverClose` set `e->closeDelivered = true` only when a
  tagger will run: re-check `subsOf(wsId)` and `!closes.empty()` (and `routerEnc != 0`) inside
  `deliverClose`, before setting the flag. Doing it there instead of only in `deliverHeldCloses`
  covers all three callers. Alternatively make `deliver` return the number of taggers run and set
  the flag only when it is > 0. The flag must still be set *before* the first tagger runs (the
  comment at :186 says so, to avoid re-entrant double delivery). So: check first, then set, then
  `deliver`. Risk: low.
- **Shares:** fix touches the same code as WS-19 (`deliverHeldCloses`/`reconcile`). One E2E file
  could hold both scenarios, but separate files keep the XFAILs independent.

#### WS-19: close with no subscriber lost after retire
- **Triage:** LIKELY · LOW
- **Test kind:** E2E · **Exposes it:** medium confidence
- **Test:** New `/work/test/eco-system/src/WebSocketLateOnCloseRetiredTest.elm`:
  - Case "faces alive" (control; works today): client/server pair, the server closes, the client
    `awaitClose`s, and only then subscribes `onClose`.
    `-- CHECK: alive: late onClose Normal "bye" clean True`.
  - Case "faces gone": the same, but the client first reads its readable to EOF (`W.readAll`) and
    closes its writable (`Stream.closeWritable`), so both stream pairs reach `Closed` and are erased.
    This runs `~WsReadChannel`/`~WsWriteChannel`, so `facesAlive` reaches 0 and `maybeRetire` erases
    the entry. Then wait `Process.sleep 50`, subscribe `onClose`, and print a timeout line after
    500 ms. `-- CHECK: retired: late onClose Normal "bye" clean True`.
    Native today: "retired: late onClose none".

  JS reference: `_WebSocket_ws[wsId]` is never deleted (only assigned, WebSocket.js:2836), and
  `attachCloseListener` delivers `W.held` to a late subscriber, so JS should pass both cases.
  **Verify on JS first.** Mark `-- XFAIL-NATIVE: WS-19 late onClose after the entry retired`.
  Confidence is medium: the pairs' erasure (Stream.cpp `maybeErase`) must really happen before the
  subscription is added. A 50 ms sleep should cover it, but confirm with a temporary stderr print in
  `maybeRetire`.
- **Fix:** **Needs a user decision on semantics.** The recommendation is to match JS: a close nobody
  was subscribed to is held for the next subscriber. Implementation: give `recentlyClosed` entries
  (S/WebSocket/WsTables.cpp:78, the `std::pair<int64_t, WsCloseInfo>` deque) a `delivered` flag.
  When `findWs(id)` is null, have `reconcile` (WsManager.cpp:206) and `deliverHeldCloses` (:243)
  look up `recentlyClosed`, deliver once, and mark it delivered. `deliverClose` needs a variant that
  takes the info from there. Holds: none needed (the close is ready at once). The bound of 4096
  `recentlyClosed` entries is already documented as a caveat in `awaitClose`. Extend that doc
  sentence to `onClose` in WebSocket.elm and its `.docs-package` copy. The alternative (document
  "never delivered" and stop the held-close path delivering when faces are alive) would contradict
  JS and the existing `WebSocketSubscriptionTest` "late onClose" CHECK, so it is not recommended.
  Risk: low to medium (manager bookkeeping).
- **Shares:** fix area with WS-18 (`deliverHeldCloses`/`deliverClose`).

#### WS-21: failed open may leave WsEntry
- **Triage:** LIKELY · MEDIUM
- **Test kind:** E2E (RSS-based), optionally backed by a C++ count accessor · **Exposes it:** medium confidence
- **Test:** New `/work/test/eco-system/src/WebSocketFailedOpenLeakTest.elm`. No Elm-visible
  handle exists for the leaked entry or pairs: Elm never received the ids, and they hold no
  Scheduler hold. So the observable is memory.
  - Phase 0 (warm-up, unmeasured): 500 iterations of the loop below.
  - Phase 1: N = 5,000 iterations of: `W.upgrade listener` on the server, while a raw client sends
    the upgrade request; the raw client then calls `Socket.reset`; the server sleeps 10 ms and
    calls `WebSocket.accept`. Expect `Err` "socket closed" (the reactor `phase()/aborted()` branch,
    WebSocket.cpp:504-510). Measure `W.rssKiB` before and after.
  - Control phase: N successful accept + client close + `awaitClose` iterations, also measured.
  - Print `failed opens: N failed, bounded True` with "bounded" meaning growth < 8 MiB, and the same
    for the control. Also add one killed-task case: `Process.spawn` an accept and `Process.kill` it.

  `-- CHECK: failed opens: 5000 failed, bounded True`, `-- CHECK: control: bounded True`,
  `-- EXIT: 0`, `-- XFAIL-NATIVE: WS-21`, and `-- LINUX-ONLY: VmRSS from /proc` (check how
  `WebSocketStreamedMemoryTest` gets away without it; `rssKiB` reads /proc/self/status). **First
  measure the per-iteration leak** (WsCore + two mapped pairs + channels, plus rooted `fromWire`/
  `toWire` closures) and size N so the leak is ≥ 4x the bound. The Elm heap growing and not
  shrinking can mask it, which is why confidence is medium.

  Stronger alternative (high confidence): add test-only C++ accessors `wsTablesLiveCount()` and
  `streamTableLiveCount()`, and an `ECO_SYSTEM_TABLE_CENSUS=1` exit print to stderr. That needs
  harness support for an env/stderr check, which the E2E harness lacks today (no `-- ENV:` or
  stderr directive), so it is more tooling work. Mention it to the user as an option.
- **Fix:** S/WebSocket/WsTables.cpp `onOpened` (:149-173). When `ev.failed` (:161), and on the
  killed-task path (`alloc::isNil(resume)`, :153-155, both failed and not), the pairs Elm never saw
  must be torn down:
  - `discardReadable(e->readableId)` (Stream.hpp:57).
  - The sink equivalent: Stream.hpp has none today. Add `discardWritable(id)`, or close the sink side
    so `maybeErase` can run.
  - Then erase the `WsEntry`, either directly (it was never published) or by forcing
    `facesAlive = 0` + `closed = true` and calling `maybeRetire`.

  On the killed-and-not-failed path, `abortCore` already runs; the pairs still need discarding
  there. Watch for `discardReadable` allocating or calling Elm code (Stream.hpp:21 says it may), so
  call it outside any raw-HPointer window in `onOpened`. That window is already rooted by a
  `StackRootGuard`; do the cleanup after `callClosure1` or before taking `resume`. Invariants: the
  HEAP_040-style external root scanners of the mapped pairs (rooted `mapFnEnc`) must be
  unregistered by the discard; check the pair destructor does that. Risk: medium. The same teardown
  also covers WS-NEW-1's fixed path, where `Opened` becomes failed after `setProtocol` fails.
- **Shares:** fix shared with WS-NEW-1 (the failed-`Opened` cleanup runs for both).

#### WS-NEW-1: open over HTTP/1.1 can report success while the core is never attached (permanent hang)
- **Triage:** LIKELY · MEDIUM
- **Test kind:** C++ unit (after a small refactor), E2E as a secondary · **Exposes it:** high (unit) / low (E2E)
- **Test:**
  - Unit, primary. First refactor the h1 reactor lambda in `wsOpenBody` (S/WebSocket/WebSocket.cpp:495-531)
    into a named function in an internal header, e.g. `void openOnConn(const std::shared_ptr<Conn>& c,
    const std::shared_ptr<WsCore>& core, std::string response, uint64_t tok, uint64_t gen, int64_t wsId)`.
    The refactor alone changes no behaviour. The new test `testWsOpenWriteFails()` in
    EcoSystemCoreTest.cpp:
    1. Opens a Conn on a socketpair with a custom `Transport` (like the existing `ChunkTransport`,
       Conn.hpp:92) whose `write` returns -2 with `errNo = EPIPE`. Its reads return -1 (would
       block), so nothing is noticed before the write.
    2. Installs `HoldProtocol([]{})` (watch mode) via `setProtocol`.
    3. Calls `openOnConn(c, core, "HTTP/1.1 101 ...", tok, gen, wsId)` inside `onReactor`.
    4. Captures the posted `Opened` WsEvent.

    Expected: `ev.failed == true`, or else the core has ended, i.e. a later `core->reqRead`
    answers ECANCELED. Today `Opened` is a success and a `reqRead` never answers: check with
    `popChannel(1, 500)` returning empty. Mark xfail `WS-NEW-1`.
  - E2E, secondary, low confidence: in `WebSocketHandshakeServerTest`-style, the raw client sends
    the upgrade request followed by more than 1 MiB of extra bytes. That exceeds
    `HoldProtocol::kWatchCap`, so watch mode stops reading and the reset goes unnoticed by reads.
    The client then calls `Socket.reset`, and the server calls `WebSocket.accept` after a sleep.
    Expected: `accept` fails, or `awaitClose` returns Abnormal. Today it may hang, and the harness
    timeout is the failure signal. Low confidence, because epoll may still report EPOLLERR/EPOLLHUP
    and take the already-correct WS-21 branch.
- **Fix:** In the (refactored) h1 path, install the protocol before posting `Opened`, and only post
  success if it took. Order: `setProtocol(std::make_unique<WsProtocol>(core), left)`, then check
  `c->phase() == Conn::Phase::Open && !c->closing() && !c->aborted()` (and that `WsProtocol::onOpen`
  ran, e.g. the core is attached). On failure, `core->portClosed()` and post `Opened` failed with
  ECONNRESET "socket closed"; that failed `Opened` then goes through WS-21's cleanup. Writing the
  101 response must also happen after `onOpen`, or the response write's failure must be seen. The
  simplest is to write the response through the Conn *after* `setProtocol` from inside
  `WsProtocol::onOpen` (pass `response` to the protocol), so a write failure reaches
  `WsProtocol::onError` → `core->portError` and the core ends. Also check `H2StreamPort`'s
  `bind(nullptr, ...)` path and `Http2ClientProtocol::bindPort`. They already "close the core" on
  failure, but post `Opened` success first: the same window, lower risk. Risk: medium. The order of
  reactor commands matters (the comment at :493-494: pairs' first requests must reach an installed
  codec), and moving the post after `setProtocol` keeps that order.
- **Shares:** fix shares WS-21's failed-`Opened` cleanup; WS-14/WS-15 (other chunks) describe the
  hangs this causes; unit file shared with WS-11/12/13/16.

### Area ZLIB

#### ZLIB-01: uInt casts truncate >4 GiB input
- **Triage:** CERTAIN · LOW
- **Test kind:** C++ unit · **Exposes it:** high confidence for `Deflater`; medium for StreamCodec (only after a refactor)
- **Test:** An E2E test is impractical: it needs a single Elm Bytes or String of at least 4 GiB.
  - **Deflater:** add a case to test/eco-system-core/EcoSystemCoreTest.cpp next to the existing `ws::Deflater` cases (:3285-3360). Make it `stress-test`-only, or behind a "slow" label, because it deflates about 4 GiB, roughly 10-30 s.
    - Input: `mmap` an anonymous `MAP_PRIVATE|MAP_NORESERVE` region of `(1ull << 32) + 4096` bytes. It is never written, so it reads as the shared zero page and adds almost nothing to RSS.
    - Call `ws::Deflater(15, true).message(p, n, out)`. The output is about 4 MB.
    - Inflate `out` with raw zlib (`inflateInit2(-15)`), appending the `00 00 FF FF` tail, into a small reused buffer, and count the bytes produced. Expect `(1ull<<32) + 4096` and all zeros. Today it is 4096.
    - No XFAIL needed if the test lands with the fix; otherwise mark it with test/XfailGuard.hpp.
  - **StreamCodec:** `deflateRun`/`inflateRun` (S/Stream/StreamCodec.cpp:110/135) take `const std::string&` and live in a file-local namespace. A 4 GiB std::string would commit 4 GiB, so test them through the refactor below. That covers them with a unit test that sets a tiny slice limit, or with the same mmap trick once they take `(const char*, size_t)`.
- **Fix:** Feed zlib in slices of at most `kZlibMaxSlice = 1u << 30` (the Inflater's existing cap, WsDeflate.cpp:160).
  - Put one shared helper in a small header, such as S/Stream/ZlibFeed.hpp: `inline void zlibRefill(z_stream& s, const char*& p, size_t& left)`. When `avail_in == 0 && left > 0`, it sets `next_in`/`avail_in = min(left, kZlibMaxSlice)` and advances `p`/`left`.
  - Use it in `Deflater::chunk` (WsDeflate.cpp:49-60), `deflateRun` (StreamCodec.cpp:114-129) and `inflateRun` (:138).
  - Change each loop's "done" condition so it requires `left == 0` as well as `avail_in == 0`. In `deflateRun`'s non-finish branch, break only when `avail_out != 0 && avail_in == 0 && left == 0`.
  - Optionally change `deflateRun`/`inflateRun` to `(const char*, size_t)` and declare them in a detail header for the unit test.

  No REP/HEAP invariants are involved, because these buffers are off-heap. Risk: low. The existing WebSocket deflate E2E tests (WebSocketDeflate*Test, StreamCodec*Test) and EcoSystemCoreTest deflate cases must stay green.
- **Shares:** -

## Appendix: unit-test reorganisation map

Reorganised 2026-11-04. Paths are under `test/`. Bug ids stay in a comment above each case.

### `test` binary (old: `libbugs/LibBugsGroupNN.cpp`, name `libbugs-NN <ID>: <what>`)

| group | old case | new file :: name |
|---|---|---|
| 02 | `DEAD-14: live read_bytes export rejects a negative length (pin)` | `kernel/BytesKernelTest.cpp` :: `bytes-kernel/read-bytes-rejects-negative-length` |
| 04 | `RESET-01: loadState after a heap reset` | `platform/HeapResetKernelStateTest.cpp` :: `heap-reset/runtime-load-state-gives-null` |
| 04 | `RESET-01: saved state rooted after a heap reset` | `platform/HeapResetKernelStateTest.cpp` :: `heap-reset/runtime-saved-state-rooted` |
| 04 | `RESET-02: time-effects scanner after a heap reset` | `platform/HeapResetKernelStateTest.cpp` :: `heap-reset/time-effects-scanner` |
| 04 | `RESET-12: http-effects scanner after a heap reset` | `platform/HeapResetKernelStateTest.cpp` :: `heap-reset/http-effects-scanner` |
| 04 | `RESET-03: MVars after a heap reset` | `platform/HeapResetKernelStateTest.cpp` :: `heap-reset/mvar-scanner-and-old-mvars-gone` |
| 06 | `TIME-08: TimerService non-finite and huge delays fire at once` | `platform/TimerServiceTest.cpp` :: `timer-service/non-finite-and-huge-delays-fire-at-once` |
| 07 | `PROC-02: wait result keeps the pid until popped` | `platform/WaitServiceTest.cpp` :: `wait-service/result-keeps-pid-until-popped` |
| 09 | `ABI-01: kernel modBy 0 returns 0 instead of throwing` | `kernel/IntArithTest.cpp` :: `int-arith/mod-by-zero-returns-zero` |
| 09 | `ABI-NEW-1: a throwing sync binding body ends in [eco-runtime] FATAL` | `platform/TaskBindingTest.cpp` :: `task-binding/throwing-sync-body-ends-in-fatal` |
| 09 | `ABI-NEW-1: a throwing async binding body ends in [eco-runtime] FATAL` | `platform/TaskBindingTest.cpp` :: `task-binding/throwing-async-body-ends-in-fatal` |
| 10 | `TASK-01: Task manager closures rooted across a minor (legacy nursery)` | `kernel/TaskEffectManagerTest.cpp` :: `task-effect-manager/closures-rooted-across-a-minor (legacy nursery)` |
| 10 | `TASK-01: Task manager closures rooted across a minor (region nursery)` | `kernel/TaskEffectManagerTest.cpp` :: `task-effect-manager/closures-rooted-across-a-minor (region nursery)` |
| 11 | `BYTES-04: elm_encoder_size refuses a width over 4 GiB` | `kernel/BytesKernelTest.cpp` :: `bytes-kernel/encoder-size-refuses-width-over-4-gib` |
| 11 | `BYTES-04: Bytes.encode refuses a width over 4 GiB` | `kernel/BytesKernelTest.cpp` :: `bytes-kernel/encode-refuses-width-over-4-gib` |
| 13 | `ARRAY-01: JsArray unsafeSet/unsafeGet index 2^32+1 passes the 32-bit range check` | `kernel/JsArrayKernelTest.cpp` :: `js-array-kernel/index-checked-on-all-64-bits` |
| 13 | `ARRAY-02: boxed JsArray unsafeSet keeps a Float/Char array's kind` | `kernel/JsArrayKernelTest.cpp` :: `js-array-kernel/boxed-unsafe-set-keeps-float-char-kind` |
| 13 | `ARRAY-03: boxed JsArray push keeps a Char/Float array's kind and zero Char padding` | `kernel/JsArrayKernelTest.cpp` :: `js-array-kernel/boxed-push-keeps-kind-and-zero-char-padding` |
| 13 | `ARRAY-05: elm_array_push_int into a nonempty boxed array` | `kernel/JsArrayKernelTest.cpp` :: `js-array-kernel/push-int-into-nonempty-boxed-array` |
| 13 | `CONSOLE-02: Console.log keeps writing after a signal-interrupted short write` | `kernel/ConsoleKernelTest.cpp` :: `console-kernel/log-keeps-writing-after-signal-interrupted-short-write` |
| 14 | `REGEX-03: replaceAtMost error path returns the rooted subject after a GC` | `kernel/RegexKernelTest.cpp` :: `regex-kernel/replace-at-most-error-path-returns-rooted-subject` |
| 14 | `REGEX-03: replaceAtMost lets a replacer exception propagate (D7)` | `kernel/RegexKernelTest.cpp` :: `regex-kernel/replace-at-most-propagates-replacer-exception` |
| 14 | `REGEX-03: splitAtMost error path returns the rooted subject after a GC` | `kernel/RegexKernelTest.cpp` :: `regex-kernel/split-at-most-error-path-returns-rooted-subject` |
| 14 | `REGEX-08: equal pattern and flags compile to one interned regex id` | `kernel/RegexKernelTest.cpp` :: `regex-kernel/equal-pattern-and-flags-intern-to-one-id` |
| 14 | `BROWSER-01: Browser.Navigation.load natively exits 1 with a clear message` | `kernel/BrowserKernelTest.cpp` :: `browser-kernel/navigation-load-exits-1-natively` |
| 14 | `BROWSER-01: File.Select.file natively exits 1 with a clear message` | `kernel/BrowserKernelTest.cpp` :: `browser-kernel/file-select-file-exits-1-natively` |
| 14 | `BROWSER-01: Browser.Dom tasks that can fail fail with NotFound` | `kernel/BrowserKernelTest.cpp` :: `browser-kernel/dom-tasks-that-can-fail-fail-with-not-found` |
| 15 | `BASICS-01: Int add/sub/mul kernel exports wrap` | `kernel/IntArithTest.cpp` :: `int-arith/add-sub-mul-wrap` |
| 15 | `BASICS-02: pow_Int exact when the result fits` | `kernel/IntArithTest.cpp` :: `int-arith/pow-int-exact-when-it-fits` |
| 15 | `BASICS-NEW-1: eco_int_pow exact when the result fits` | `kernel/IntArithTest.cpp` :: `int-arith/eco-int-pow-exact-when-it-fits` |
| 16 | `DEBUG-01: Debug.todo message reaches stderr under output capture` | `kernel/DebugKernelTest.cpp` :: `debug-kernel/todo-message-reaches-stderr-under-output-capture` |
| 18 | `PARSE-NEW-1: Allocator::resolve of an embedded constant dies, never returns null` | `allocator/ResolveConstantTest.cpp` :: `allocator/resolve-of-embedded-constant-dies-never-returns-null` |
| 19 | `UTILS-02: mixed boxed/unboxed Float list heads order by compareFloat` | `kernel/UtilsCompareTest.cpp` :: `utils-compare/mixed-float-list-heads-order-by-compare-float` |
| 19 | `UTILS-03: mixed boxed/unboxed tuple slot orders by value, as == does` | `kernel/UtilsCompareTest.cpp` :: `utils-compare/mixed-tuple-slot-orders-by-value-as-equal-does` |

Suites: `IntArith` (in-process: the three int-arith wrap/pow cases); `KernelIsolated` (new isolated suite: kernel/* and allocator/ResolveConstantTest); `PlatformServices` (existing isolated suite: heap-reset, timer-service, wait-service, task-binding). They replace `LibBugs` and `LibBugsIsolated`.

### `eco-system-core-test` (old: `eco-system-core/libbugs/CoreGroupNN.cpp`)

In-process cases (the heading each prints), files under `test/eco-system-core/`:

| group | old heading | new file :: heading |
|---|---|---|
| 03 | `DEAD-35 / WS-20: wsOpen/wsReject with a role that does not match the handshake` | `WebSocketTest.cpp` :: `websocket/open-or-reject-with-a-role-that-does-not-match-the-handshake` |
| 04 | `RESET-04 RESET-04/fs-handles-after-reset` | `HeapResetTest.cpp` :: `heap-reset/filesystem-handles` |
| 04 | `RESET-05 RESET-05/watch-after-reset` | `HeapResetTest.cpp` :: `heap-reset/watch` |
| 04 | `RESET-06 RESET-06/socket-tables-after-reset` | `HeapResetTest.cpp` :: `heap-reset/socket-tables` |
| 04 | `RESET-07 RESET-07/http-tables-after-reset` | `HeapResetTest.cpp` :: `heap-reset/http-tables` |
| 04 | `RESET-08 RESET-08/socket-orphans-after-reset` | `HeapResetTest.cpp` :: `heap-reset/socket-orphans` |
| 04 | `RESET-09 RESET-09/ws-tables-after-reset` | `HeapResetTest.cpp` :: `heap-reset/websocket-tables` |
| 04 | `RESET-10 RESET-10/ws-manager-after-reset` | `HeapResetTest.cpp` :: `heap-reset/websocket-manager` |
| 04 | `RESET-11 RESET-11/sigint-after-reset` | `HeapResetTest.cpp` :: `heap-reset/sigint-listener` |
| 05 | `WS-11/12/13/16/21/NEW-1 WsCore and open-path checks (child WS-group05/core)` | `WebSocketTest.cpp` :: `websocket/core-and-open-path checks (child)` |
| 05 | `WS-11 heartbeat ping deadline after a read pause (heartbeatTimeout 0)` | `WebSocketTest.cpp` :: `websocket/heartbeat-ping-deadline-after-a-read-pause` |
| 05 | `WS-12 a failed Close write completes writeClose / the close handshake as success` | `WebSocketTest.cpp` :: `websocket/failed-close-write-fails-write-close-and-handshake` |
| 05 | `WS-13 writeClose after an abnormal end that dropped a queued Close` | `WebSocketTest.cpp` :: `websocket/write-close-after-an-abnormal-end` |
| 05 | `WS-16 failWith writes a second Close while ours is still being written` | `WebSocketTest.cpp` :: `websocket/fail-with-writes-no-second-close` |
| 05 | `WS-NEW-1 h1 open whose 101 response write fails` | `WebSocketTest.cpp` :: `websocket/h1-open-whose-101-response-write-fails` |
| 05 | `WS-21 a failed open leaves its WsEntry and stream pairs` | `WebSocketTest.cpp` :: `websocket/failed-open-leaves-no-entry-or-stream-pairs` |
| 06 | `STREAM-07 errored pairs are erased` | `StreamTest.cpp` :: `stream/errored-pairs-are-erased` |
| 07 | `PROC-06 exception after parkResume in ChildProcess.run` | `ChildProcessTest.cpp` :: `child-process/run-exception-after-park-leaks-no-job-or-hold` |
| 07 | `PROC-06 exception after the hold in the ChildProcess manager's spawn` | `ChildProcessTest.cpp` :: `child-process/spawn-exception-after-the-hold-leaks-nothing` |
| 07 | `SIG-03 addListener push_back throw leaks the subscription` | `SignalTest.cpp` :: `signal/add-listener-push-back-throw-leaks-no-subscription` |
| 07 | `SIG-04 chainToPrevious: a signal arriving in the window` | `SignalTest.cpp` :: `signal/chain-to-previous-queues-a-signal-arriving-in-the-window` |
| 08 | `HTTPSRV-06 listenOn getaddrinfo error codes` | `HttpServerTest.cpp` :: `http-server/listen-on-getaddrinfo-error-codes` |
| 09 | `TERM-05 terminalTitleSequence and C1 controls` | `TerminalTest.cpp` :: `terminal/title-sequence-strips-c1-controls` |
| 09 | `TERM-04 raw mode restored on a fatal end` | `TerminalTest.cpp` :: `terminal/raw-mode-restored-on-a-fatal-end` |
| 09 | `TERM-06 first setStdInRawMode False saves the mode` | `TerminalTest.cpp` :: `terminal/raw-mode-false-first-does-not-save-the-mode` |
| 10 | `TLS-04 a bad SSL_CERT_FILE does not stop a good SSL_CERT_DIR being loaded` | `TlsTest.cpp` :: `tls/bad-ssl-cert-file-does-not-stop-a-good-ssl-cert-dir` |
| 10 | `TLS-05 TrustedCertificates with no certificate gives ERR_SSL_NO_CERTIFICATES` | `TlsTest.cpp` :: `tls/trusted-certificates-with-no-certificate-gives-err-ssl-no-certificates` |
| 10 | `TLS-08 a failed send's errno is what the next write reports` | `TlsTest.cpp` :: `tls/failed-send-errno-is-what-the-next-write-reports` |
| 10 | `TLS-10 a killed TLS connect leaves no pending entry, connect or hold` | `TlsTest.cpp` :: `tls/killed-connect-leaves-no-pending-entry-connect-or-hold` |
| 11 | `cross-check WATCH-02/rename-dir` | `WatchTest.cpp` :: `cross-check watch/rename-dir` |
| 11 | `cross-check WATCH-03/move-out` | `WatchTest.cpp` :: `cross-check watch/move-out` |
| 11 | `cross-check WATCH-04/symlink-root` | `WatchTest.cpp` :: `cross-check watch/symlink-root` |
| 11 | `cross-check WATCH-05/root-vanishes` | `WatchTest.cpp` :: `cross-check watch/root-vanishes` |
| 11 | `cross-check WATCH-07/queue-overflow` | `WatchTest.cpp` :: `cross-check watch/queue-overflow` |
| 11 | `cross-check WATCH-08/new-tree` | `WatchTest.cpp` :: `cross-check watch/new-tree` |
| 12 | `FS-03 close: fd erased from the handle table before a submit that throws` | `FileSystemTest.cpp` :: `filesystem/close-whose-submit-throws-keeps-the-fd-tracked` |
| 15 | `CORE-07 failureFor(RunErr) keeps the exception message` | `CoreServicesTest.cpp` :: `core/failure-for-run-err-keeps-the-exception-message` |
| 15 | `CORE-08 asyncFailure after a synchronous completion (uncounted park)` | `CoreServicesTest.cpp` :: `core/async-failure-after-a-synchronous-completion (uncounted park)` |
| 15 | `CORE-08 asyncFailure after a synchronous completion (counted park, child)` | `CoreServicesTest.cpp` :: `core/async-failure-after-a-synchronous-completion (counted park, child)` |
| 15 | `CORE-01 SysWorkPool survives a worker that cannot be started (child)` | `CoreServicesTest.cpp` :: `work-pool/survives-a-worker-that-cannot-be-started (child)` |
| 15 | `CORE-14 IoReactor backendInit failure closes what it opened (child)` | `CoreServicesTest.cpp` :: `io-reactor/backend-init-failure-closes-what-it-opened (child)` |
| 15 | `CORE-18 SysWorkPool worker survives bad_alloc while recording an exception (child)` | `CoreServicesTest.cpp` :: `work-pool/worker-survives-bad-alloc-while-recording-an-exception (child)` |
| 16 | `FD-01 FdChannel does not close a reused fd number after POLLNVAL` | `FdChannelTest.cpp` :: `fd-channel/does-not-close-a-reused-fd-number-after-pollnval` |
| 16 | `FD-03 FdChannel write to a full blocking pty: shutdown still cancels` | `FdChannelTest.cpp` :: `fd-channel/write-to-a-full-blocking-pty-shutdown-still-cancels` |
| 17 | `DEAD-43 FaceProtocol: close-write then writeFaceShutdown completes the close exactly once` | `SocketTest.cpp` :: `socket/face-close-write-then-shutdown-completes-the-close-once` |
| 17 | `SOCK-03 Conn: a refused setInterest after a write error reports no second write error` | `SocketTest.cpp` :: `socket/refused-set-interest-after-a-write-error-reports-no-second-error` |
| 17 | `SOCK-12 Socket.connect: makeKillHandle throwing leaves no pending connect or double release` | `SocketTest.cpp` :: `socket/connect-kill-handle-throw-leaves-no-pending-connect-or-double-release` |
| 18 | `ZLIB-01 zlib input fed in 7-byte slices` | `ZlibTest.cpp` :: `zlib/input-fed-in-7-byte-slices` |
| 18 | `ZLIB-01 Deflater message over 4 GiB` | `ZlibTest.cpp` :: `zlib/deflater-message-over-4-gib` |

Child scenarios (`--list-scenarios`):

| group | old scenario | new file :: scenario |
|---|---|---|
| 15 | `CORE-01/partial-start` | `CoreServicesTest.cpp` :: `work-pool/partial-start` |
| 15 | `CORE-08/counted` | `CoreServicesTest.cpp` :: `core/async-failure-counted-park` |
| 15 | `CORE-14/reactor-init-fd-leak` | `CoreServicesTest.cpp` :: `io-reactor/init-failure-fd-leak` |
| 15 | `CORE-18/pool-oom-in-handler` | `CoreServicesTest.cpp` :: `work-pool/oom-in-exception-handler` |
| 03 | `DEAD-35/role-mismatch` | `WebSocketTest.cpp` :: `websocket/role-mismatch` |
| 12 | `FS-03/close-submit-fails` | `FileSystemTest.cpp` :: `filesystem/close-submit-fails` |
| 07 | `PROC-06/fault-after-park` | `ChildProcessTest.cpp` :: `child-process/run-fault-after-park` |
| 07 | `PROC-06/spawn-fault` | `ChildProcessTest.cpp` :: `child-process/spawn-fault` |
| 04 | `RESET-04/fs-handles-after-reset` | `HeapResetTest.cpp` :: `heap-reset/filesystem-handles` |
| 04 | `RESET-05/watch-after-reset` | `HeapResetTest.cpp` :: `heap-reset/watch` |
| 04 | `RESET-06/socket-tables-after-reset` | `HeapResetTest.cpp` :: `heap-reset/socket-tables` |
| 04 | `RESET-07/http-tables-after-reset` | `HeapResetTest.cpp` :: `heap-reset/http-tables` |
| 04 | `RESET-08/socket-orphans-after-reset` | `HeapResetTest.cpp` :: `heap-reset/socket-orphans` |
| 04 | `RESET-09/ws-tables-after-reset` | `HeapResetTest.cpp` :: `heap-reset/websocket-tables` |
| 04 | `RESET-10/ws-manager-after-reset` | `HeapResetTest.cpp` :: `heap-reset/websocket-manager` |
| 04 | `RESET-11/sigint-after-reset` | `HeapResetTest.cpp` :: `heap-reset/sigint-listener` |
| 07 | `SIG-03/push-back-oom` | `SignalTest.cpp` :: `signal/add-listener-push-back-oom` |
| 17 | `SOCK-12/killhandle-throw` | `SocketTest.cpp` :: `socket/connect-kill-handle-throw` |
| 09 | `TERM-04/raw-then-fatal` | `TerminalTest.cpp` :: `terminal/raw-then-fatal` |
| 09 | `TERM-06/false-then-stty` | `TerminalTest.cpp` :: `terminal/false-then-stty` |
| 10 | `TLS-04/issuer-found` | `TlsTest.cpp` :: `tls/issuer-found` |
| 10 | `TLS-10/no-stage-2` | `TlsTest.cpp` :: `tls/connect-no-stage-2` |
| 11 | `WATCH-02/rename-dir` | `WatchTest.cpp` :: `watch/rename-dir` |
| 11 | `WATCH-03/move-out` | `WatchTest.cpp` :: `watch/move-out` |
| 11 | `WATCH-04/symlink-root` | `WatchTest.cpp` :: `watch/symlink-root` |
| 11 | `WATCH-05/root-vanishes` | `WatchTest.cpp` :: `watch/root-vanishes` |
| 11 | `WATCH-07/queue-overflow` | `WatchTest.cpp` :: `watch/queue-overflow` |
| 11 | `WATCH-08/new-tree` | `WatchTest.cpp` :: `watch/new-tree` |
| 05 | `WS-group05/core` | `WebSocketTest.cpp` :: `websocket/core-and-open-path` |

`--group NN`, `--only-libbugs` and `--skip-libbugs` are gone; `--only <area>` runs one area file (areas: websocket heap-reset stream child-process signal http-server terminal tls watch filesystem core-services fd-channel socket zlib). Env vars `ECO_LIBBUGS09_PTY`/`_END` are now `ECO_CORE_TEST_PTY`/`_END`.

### `elm-kernel-time-test` (old: `elm-kernel-time/TimeGroup.cpp`, group 06)

New file `test/elm-kernel-time/TimeKernelTest.cpp`.

| old heading | new heading |
|---|---|
| `TIME-01 TIME-01/tick-tagger-across-minor (default nursery)` | `time/tick-tagger-across-minor (default nursery)` |
| `TIME-01 TIME-01/tick-tagger-across-minor (legacy nursery)` | `time/tick-tagger-across-minor (legacy nursery)` |
| `TIME-NEW-1 TIME-NEW-1/register-across-minor (default nursery)` | `time/register-across-minor (default nursery)` |
| `TIME-NEW-1 TIME-NEW-1/register-across-minor (legacy nursery)` | `time/register-across-minor (legacy nursery)` |

| old scenario | new scenario |
|---|---|
| `TIME-01/tick-tagger-across-minor` | `time/tick-tagger-across-minor` |
| `TIME-NEW-1/register-across-minor` | `time/register-across-minor` |
