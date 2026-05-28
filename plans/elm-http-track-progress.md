# Plan: Implement `Http.track` progress (elm/http)

The last unimplemented piece of the stock `elm/http` kernel. Unlike the rest of
the kernel (request/response, which is a one-shot Task), `track` is a *streaming
subscription*: an in-flight request emits `Sending`/`Receiving` progress events
that must be delivered to a `Http.track tracker toMsg` subscription. This is
effectively its own sub-project because it forces the **effect-manager
subscription + self-message delivery path** to actually work end-to-end — a path
that currently exists in the runtime but is **never exercised**.

## Resolved decisions
- **Q-A — track BOTH `reqs` and `subs`; implement `Http.cancel` (not deferred).**
  Manager state holds reqs + subs. Internal representation is a C++-manager detail
  (see P4/Q-J): use a List of `(tracker, processId)` for reqs rather than a
  red-black `Dict` (Dict insert/remove in C++ is heavy and unnecessary — the
  manager is the sole producer/consumer of its own state).
- **Q-B — the runtime self-message fix (P1) is in scope** and a necessary, general
  addition (any self-message-using manager needs it).
- **Q-C — deliver every curl progress tick** (no coalescing for now).
- **Q-D — assert "≥1 `Receiving` + final `received == size`"** (not a strict
  monotonic sequence).
- **Q-E — test known `Content-Length` first, then chunked/unknown size**
  (`size = Nothing`) — both in scope.
- **Q-F — `Http.cancel` in scope, with tests.**
- **Q-G — per-tick allocation + scheduler step is acceptable.**
- **Q-H — self-loop re-arm via a dedicated runtime step** that special-cases
  manager self-processes (auto re-arm + state write-back), not an Elm Task chain.
- **Q-I — Option 2:** the `Router` Custom's field 1 stores the self-process
  **id** (an unboxed Int) instead of a Process snapshot; `sendToSelf` reads the id
  and resolves the live process via `latestProcessById`. Avoids keeping a stale
  snapshot alive. (Safe: `Router` is kernel-internal — only `sendToApp`/`sendToSelf`
  read its fields; Elm never introspects it.)

## 0. Stock contract (what we must satisfy — do not modify Http.elm)
- `track : String -> (Progress -> msg) -> Sub msg` → `subscription (MySub tracker toMsg)`.
- `type Progress = Sending { sent : Int, size : Int } | Receiving { received : Int, size : Maybe Int }`.
- Request carries `tracker : Maybe String`. When `Just t`, the kernel routes
  progress to the manager via the router:
  - stock JS `_Http_track(router, xhr, tracker)` registers upload/download
    progress listeners that do `Scheduler.rawSpawn(sendToSelf router (Tuple2 tracker (Sending|Receiving {...})))`.
- Effect manager (`Http.elm`):
  - `type alias SelfMsg = (String, Progress)`.
  - `onSelfMsg router (tracker, progress) state = Task.sequence (List.filterMap (maybeSend router tracker progress) state.subs) |> andThen (\_ -> succeed state)`.
  - `maybeSend router subTracker progress (MySub tracker toMsg) = if tracker == subTracker then Just (sendToApp router (toMsg progress)) else Nothing`.
  - `onEffects` stores the current `subs` in `State { reqs, subs }`.
  - `subMap func (MySub tracker toMsg) = MySub tracker (toMsg >> func)`.

## 1. Current state (verified)
- **The self-message path exists but is unexercised and incomplete.**
  `setupEffects` (`PlatformRuntime.cpp:117-216`) spawns one self-process per
  manager running `taskReceive(info.onSelfMsg)` and builds a `Router` Custom
  `[sendToApp, selfProcess]`. `sendToSelf(router,msg)` (`PlatformRuntime.cpp:433-445`)
  does `rawSend(selfProcess, msg)`. **No manager currently uses it**: Time
  delivers ticks via `sendToApp` directly; the Http `onSelfMsg`/`onEffects` are
  C++ stubs — `onSelfMsg` returns state unchanged, `onEffects` ignores `subs`
  (registered `subMap = listNil`).
- **Why the router's self-process HPointer is "stale" — it is NOT a GC bug.**
  The router lives in `managerStates_.router` and is evacuated by the external
  root scanner; every new immutable Process version is registered in
  `Scheduler::latestProc_` (also scanned). So all versions are correctly rooted.
  The staleness is **logical**: `Process` is immutable (`procWith*` allocate a new
  value + `registerLatestProcess`), so the router holds one *snapshot* (the
  original self-process) while the live process advances as new values keyed by
  **id** in `latestProc_`. The router field is never "updated" because the design
  intends resolve-by-id at send time — which `sendToSelf` fails to do.
- **The self-process loop is genuinely incomplete** (confirmed by reading the
  `Task_Receive` step, `Scheduler.cpp:802-824`):
  1. **Callback not wrapped.** `setupEffects` passes `info.onSelfMsg` directly to
     `taskReceive` (comment literally says "will be wrapped later" — it is not).
     The step does `callClosure1(recvCallback, msg)` with **one** arg, but stock
     `onSelfMsg` needs `(router, selfMsg, state)` → it yields a partial
     application, not a Task.
  2. **No re-arm.** After the callback returns, the step does `setRoot(newTask)`
     and never loops back to `taskReceive`, so only the *first* self-message would
     ever be handled. `track` streams many.
  3. **No state threading.** The manager `state` (the `subs` list) is set by
     `onEffects` into `managerStates_.state`, but the self-process loop neither
     reads it nor writes back the state `onSelfMsg` returns.
- **HttpService** has no progress callback; results are one-shot PODs.
- **Existing kernel** ignores `request.tracker`.

## 2. Goal
`Http.request { tracker = Just "x", … }` together with `Http.track "x" GotProgress`
delivers `Receiving`/`Sending` progress messages to the app `update`, ending with
a final progress at completion — verified by an E2E test against a slow/streamed
endpoint.

## Part P1 — Complete the router / self-process loop (foundational, runtime)
This is the real sub-project. The self-message path is wired but incomplete (see
§1); it must become a correct, repeatable `sendToSelf → onSelfMsg(router,msg,state)
→ updated state → re-arm` loop. **None of this is a GC fix** — it is loop wiring,
state threading, and resolve-by-id.
- **P1a — Router stores the self-process id; `sendToSelf` resolves live (Q-I,
  Option 2).** Change `setupEffects` to build the `Router` Custom as
  `[sendToApp (boxed), selfProcessId (unboxed Int)]` — i.e. `custom(CTOR_Router,
  {sendToApp, id}, /*bitmap*/ 0b0100)` so slot 1 is kind-01 (Int). `sendToSelf`
  reads field 1 as the Int id and does `rawSend(latestProcessById(id), msg)`,
  delivering to the live version rather than a stale immutable snapshot. The
  external root scanner now traces only field 0 (field 1 is unboxed, correctly
  untraced). Audit every reader of the router Custom (only `sendToApp` field 0 and
  `sendToSelf` field 1) — both C++; Elm never introspects `router`.
- **P1b — Wrap the Receive callback so `onSelfMsg` gets `(router, msg, state)`.**
  In `setupEffects`, instead of `taskReceive(info.onSelfMsg)`, build a self-loop:
  the Receive callback is a wrapper that, on each `msg`, applies the real
  `onSelfMsg` as `onSelfMsg(router, msg, currentState)` (a 3-arg closure call,
  not the current 1-arg `callClosure1`). Supply `router` + `currentState` either
  via closure captures or by reading `managerStates_[home]` in a C++ wrapper
  evaluator.
- **P1c — Thread manager state across messages.** `onSelfMsg` returns
  `Task Never State`; run it, capture the produced state, and store it back into
  `managerStates_[home].state` so the next self-message sees the latest `subs`.
  (Mirror how `dispatchEffects` captures `onEffects`'s returned state,
  `PlatformRuntime.cpp:316-331`.)
- **P1d — Re-arm (dedicated runtime step, Q-H).** Special-case manager
  self-processes in the scheduler step: after the wrapped `onSelfMsg` runs and its
  returned `Task Never State` resolves, the runtime (a) writes the produced state
  back to `managerStates_[home].state` (P1c), and (b) auto re-arms the process
  root to `taskReceive(wrapper)` so it blocks for the next message. Mark the
  self-process (e.g. via a flag/registry keyed by its id, or a distinct task
  ctor) so the step loop knows to apply this protocol instead of terminating.
- **P1e — Isolated smoke test.** Before layering HTTP on top, prove the loop with
  a minimal case: drive `sendToSelf` repeatedly at a manager whose `onSelfMsg`
  logs/accumulates, and assert all N messages are handled in order with state
  carried across them. This de-risks P2–P7.

## Part P2 — HttpService progress reporting (POD-only, worker thread)
- **P2a.** Add a `CURLOPT_XFERINFOFUNCTION` (+ `CURLOPT_NOPROGRESS 0`) to
  `HttpService::perform`. The callback posts plain PODs to a **progress queue**:
  `{ token, isUpload, now, total }` (uint64s). No heap, no HPointer.
- **P2b.** Add `tryPopProgress(Progress&)` / `hasProgress()` to `HttpService`
  (mirrors the result queue). The callback also calls
  `Scheduler::notifyWorkAvailableFromAsync()` so the main loop wakes.
- **P2c.** Drain progress in the same async-source drain (registered with the
  Scheduler) that already drains results — pop progress events and route them
  (P4). Note: progress for a token can arrive **before** its final result; the
  per-request progress context (P3) must outlive individual events and be cleared
  on the final result.

## Part P3 — Track-aware request + per-request (router, tracker) state
- **P3a.** Extend `extractRequest` to read `request.tracker : Maybe String`
  (alphabetical request field index 6) and `router` (toTask arg0). Only tracked
  requests (`Just t`) need progress routing.
- **P3b.** Keep a **main-thread-only** registry `g_httpTracked[token] =
  { routerEnc, trackerEnc }` (encoded HPointers) guarded by a mutex, populated in
  `toTask`/binding for tracked requests, erased when the final result drains.
- **P3c.** Register a **dedicated `ExternalRootScanner`** over `g_httpTracked`
  (verbatim mirror of `timerRegisterScannerOnce` in `TimeEffectManager.cpp`):
  evac `routerEnc`/`trackerEnc` on the main thread during GC; never allocate under
  the mutex. This is the "dedicated main-thread scanner for router/tracker state".

## Part P4 — Progress → effect manager routing (main thread)
- **P4a.** When a progress event drains (P2c), look up `g_httpTracked[token]` →
  `(router, tracker)`. Build the `Progress` value (P5). Build the SelfMsg
  `Tuple2(tracker, progress)`. Call `PlatformRuntime::sendToSelf(router, selfMsg)`
  → the Http manager's self-process → `onSelfMsg`.
- **P4b.** Rewrite the C++ Http effect manager to the stock subs + reqs semantics.
  Manager state = a 2-field value `{ reqs, subs }` where `reqs` is a List of
  `(tracker, processId)` and `subs` is the `List (MySub msg)` (Q-A/Q-J — a List
  for reqs, not an RB-`Dict`, since the manager owns its own state). `init`
  returns `{ reqs=[], subs=[] }`.
  - `httpOnEffectsEvaluator (router, cmds, subs, state)`: for each cmd —
    `Request req` (ctor 1): spawn the request task (already done); if `req.tracker
    = Just t`, record `(t, processId)` in `reqs`. `Cancel tracker` (ctor 0): look
    up `tracker` in `reqs`, `Process.kill` (Scheduler `killTask`) that process,
    and drop it from `reqs`. Store the new `{ reqs', subs }` (subs from the arg)
    as the returned state.
  - `httpOnSelfMsgEvaluator (router, selfMsg=(tracker,progress), state)`: iterate
    `state.subs` (each `MySub subTracker toMsg`); for `subTracker == tracker`,
    `sendToApp(router, toMsg(progress))`. Return `Task.succeed(state)` unchanged.
  - Register a real `subMap`: `subMap func (MySub t toMsg) = MySub t (toMsg >> func)`
    (currently `listNil`) — needed for `Sub.map`.
  - Representations: `MySub msg = MySub String (Progress -> msg)` → Custom ctor 0,
    fields `[tracker(String), toMsg(closure)]`. `MyCmd msg = Cancel String |
    Request {...}` → `Cancel` ctor 0 `[tracker]`, `Request` ctor 1 `[record]`
    (the request path already handles `Request`; add the `Cancel` branch).

## Part P5 — Build `Progress` values (main thread)
- `Sending { sent : Int, size : Int }`: ctor 0, payload a record. Per
  `computeRecordLayout` (unboxed-first, sorted): `sent`,`size` both unboxed Int →
  fields `[sent, size]`, mask `0b0101`.
- `Receiving { received : Int, size : Maybe Int }`: ctor 1, record fields
  unboxed-first → `[received(Int, slot0), size(Maybe, slot1 boxed)]`, mask `0b01`.
  `size = total>0 ? Just total : Nothing` (`Nothing` is the embedded constant).
- Map curl callback: upload → `Sending { sent=now, size=total }`; download →
  `Receiving { received=now, size = total>0 ? Just total : Nothing }`.
- Confirm the `Progress`/`Sending`/`Receiving` ctor tags + record layouts the same
  way Metadata was confirmed (declaration order + `computeRecordLayout`).

## Part P6 — Test server: long-running / streamed endpoints
- **P6a — known length.** `/drip?bytes=N&ms=D` in `test/TestHttpServer.hpp`: set
  `Content-Length: N`, then write `N` bytes spread over `D` ms in small chunks with
  per-chunk sleeps, so curl reports incremental `Receiving` progress with a known
  `size = Just N`. (Keep `/slow` for the timeout test.)
- **P6b — unknown length (chunked).** `/drip-chunked?bytes=N&ms=D`: respond with
  `Transfer-Encoding: chunked` (no Content-Length), so curl reports `Receiving`
  with `size = Nothing` (Q-E). Drives the `Nothing` branch of `Receiving.size`.

## Part P7 — E2E tests
- **P7a — `HttpTrackProgressTest.elm`** (known length): a `Platform.worker` that
  issues `Http.request { tracker = Just "p", url = baseUrl ++ "/drip?bytes=2048&ms=400", … }`
  with `subscriptions = \_ -> Http.track "p" GotProgress`. Accumulate progress;
  on the final response assert ≥1 `Receiving` arrived and the last
  `received == size` (Q-D). Log a Bool, `track: True`. (First test to exercise a
  live Eco subscription fed by `onSelfMsg`.)
- **P7b — `HttpTrackChunkedTest.elm`** (unknown length): same shape against
  `/drip-chunked`; assert ≥1 `Receiving` with `size == Nothing`.
- **P7c — `HttpCancelTest.elm`**: start a tracked request to a slow endpoint, then
  in `update` (e.g. after the first progress tick, or via a second init Cmd) issue
  `Http.cancel "p"`; assert the request does not complete (no final `Ok`/`Err`
  response message arrives) within a bounded number of scheduler turns — i.e. the
  in-flight process was killed. (Exact assertion mechanism is Q-K.)

## Sequencing
1. **P1** — complete the router/self-process loop (`sendToSelf` → wrapped
   `onSelfMsg(router,msg,state)` → state write-back → auto re-arm). Foundational;
   prove with the isolated smoke test (P1e).
2. **P2** — HttpService progress queue + drain.
3. **P4b** — rewrite Http `onEffects`/`onSelfMsg`/`subMap` to stock `{reqs,subs}`
   semantics (incl. the `Cancel` branch + `Process.kill`).
4. **P3 + P4a + P5** — per-request scanner, progress routing, `Progress` values.
5. **P6 + P7** — `/drip` + `/drip-chunked` endpoints + track/chunked/cancel tests.

## Remaining open questions (surfaced by the decisions above)
- **Q-J (reqs entry / killing an in-flight process):** `reqs` stores
  `(tracker, processId)`. `Process` values are immutable snapshots (same staleness
  as the self-process, §1), so storing the spawned Process HPointer and later
  `killTask`-ing it would target a stale version. Store the process **id** and
  resolve the live version via `latestProcessById` at cancel time (consistent with
  the Q-I fix). Confirm `killTask` actually stops a process blocked in a Task
  binding (the HTTP in-flight state).
- **Q-K (cancel test assertion):** the `-- CHECK:` harness asserts the *presence*
  of expected output, not its *absence*. To assert "the cancelled request did not
  deliver a response", we need a positive signal — e.g. after issuing
  `Http.cancel`, start a `Process.sleep`/timer and, when it fires with no response
  having arrived, log `cancelled: True`. Decide the exact mechanism for a robust,
  non-flaky negative assertion.
- **Q-L (true transfer abort vs. dropping delivery):** `Http.cancel` →
  `Process.kill` stops the Elm process so the result is never delivered, but the
  `HttpService` worker thread keeps running `curl_easy_perform` to completion.
  Should cancel also *abort the transfer* — set a per-token "cancelled" flag that
  the `XFERINFOFUNCTION` checks, returning non-zero to make curl abort? Recommended
  for correctness (frees the worker), but adds cross-thread cancel signalling.
  Decide: drop-delivery-only (simpler) vs. true-abort.

## Risk note
P1 is the crux and the main unknown: the self-message → `onSelfMsg` delivery path
has never run in this codebase, and it must now be *completed* (callback wrapping,
state threading, auto re-arm, live-process resolution) — not merely "verified".
Budget real debugging time for it (stale self-process snapshot on repeated sends;
re-arm; ordering of progress vs. final result). Cancel adds a second
immutable-process-staleness case (Q-J) and optional cross-thread abort (Q-L).
Everything else (P2, P5–P7) is mechanical once P1 + the manager rewrite hold.
