# Bug: `Cmd.map` with a non-identity tagger over an elm/http command crashes (native)

Status: **fixed 2026-10-10.** Regression tests: `test/elm-http/src/HttpCmdMapTest.elm` (`Cmd.map`)
and `test/elm-http/src/HttpSubMapTest.elm` (the sibling `Sub.map` bug). Both failed before the fix:
SIGSEGV, and `progress: False`.

## Symptom (as found)
On the native target, an `Http` command passed through `Cmd.map` with any tagger other than
`identity` delivered a corrupted message:
- a bare constructor tagger: the app got a message matching the wrong branch, or crashed;
- a lambda tagger: SIGSEGV;
- `identity`: worked.

gdb: `Elm::StringOps::append (a=0x6873692d, …)`, the bytes `-ish` of the message's own label read
as a pointer.

## Root cause
The native Http effect manager (`elm-kernel-cpp/src/http/HttpEffectManager.cpp`) is C++, not
elm/http's Elm source. Its `cmdMap` (`httpCmdMapEvaluator`) only mapped commands that were already a
`Task`. elm/http's real command, `Request {…}` (Custom ctor 1), came back unchanged, so the
`Cmd.map` tagger (PlatformRuntime's applyTaggers closure, PORT_005) was silently dropped. The app
then received the inner message as if it were its own `Msg`: constructor indices compared across two
different types, so for example `Got label result` was decoded as `GotServer server`, and the label
string was read as a record. `identity` survived only because dropping it changes nothing.
`Elm_Kernel_Http_mapExpect` was correct, but nothing ever called it.

The same manager registered `subMap = Nil`. The runtime's fallback then applied `Sub.map` taggers
to the `MySub` value itself, so `Http.track` progress under `Sub.map` never reached the app.

## Fix
- **`httpCmdMapEvaluator`:** as stock elm/http's `cmdMap`. `Cancel` passes through unchanged, and
  `Request r` becomes `Request { r | expect = mapExpect func r.expect }`. The record is rebuilt with
  the same fields and slot kinds; only `expect` (field 2, alphabetical order) is replaced. The
  `Task` fallback is kept.
- **New `httpSubMapEvaluator`, registered as `subMap`:** as stock
  `subMap func (MySub tracker toMsg) = MySub tracker (toMsg >> func)`. The composition is a
  closure, `httpSubComposeEvaluator`.
- **Registration:** the manager's closures are now rooted across the later allocations.

## Why nothing caught it
No test used `Cmd.map` or `Sub.map` over an Http command. The tests use Http directly from their
own `Msg` type, and the JS target uses elm/http's own Elm effect manager.
