# Bug: `Cmd.map` with a non-identity tagger over an elm/http command crashes (native)

Status: **open, not investigated past localisation** (found 2026-10-10 while moving the HTTP test
server's URL to the environment; that change now avoids `Cmd.map` over Http, see below).

## Symptom
On the native target (JIT E2E; AOT not checked), an `Http` command passed through `Cmd.map` with
any tagger other than `identity` delivers a corrupted message:
- a bare constructor tagger (`Cmd.map Inner (Http.get …)`): the app gets a message that matches
  nothing, or crashes;
- a lambda tagger (`Cmd.map (\m -> Inner m) …`): SIGSEGV;
- `Cmd.map identity (Http.get …)`: works;
- `Cmd.map Inner (Task.perform …)` (the Task manager): works.

gdb on the spawned child: `Elm::StringOps::append (a=0x6873692d, …)`. `a` is the bytes `-ish` of the
message's own label string read as a pointer, so `update` destructures a value with the wrong
layout. No elm-http test used `Cmd.map` over an Http command before, so nothing covered this.

## Where to look
elm/http's effect manager maps a request with `cmdMap func (Request r) = Request { r | expect =
Elm.Kernel.Http.mapExpect func r.expect }`. Natively, `Elm_Kernel_Http_mapExpect` and
`mapExpectEvaluator` (`elm-kernel-cpp/src/http/HttpExports.cpp`) compose `func (oldToValue
response)` in a K-closure, and `httpDrain` applies the bundle's `toValue` with `callClosure1`. That
`identity` survives while every real tagger fails suggests the tagger is applied to the wrong value
(or twice), or a closure-ABI mismatch between the K-closure and the Elm tagger. Compare with JS
`_Http_mapExpect`.

## Reproducer
Save as `test/elm-http/src/CmdMapHttpTest.elm` (needs `TestServerConfig`). It should print
`probe-ok: "ctor"`; today it crashes or prints nothing.

```elm
module CmdMapHttpTest exposing (main)

-- CHECK: probe-ok

import Http
import Platform
import Task
import TestServerConfig


type Msg
    = Got String (Result Http.Error String)


type Outer
    = GotServer TestServerConfig.Server
    | Inner Msg


main : Program () () Outer
main =
    Platform.worker
        { init = \_ -> ( (), Task.perform GotServer TestServerConfig.server )
        , update = update
        , subscriptions = \_ -> Sub.none
        }


update : Outer -> () -> ( (), Cmd Outer )
update msg model =
    case msg of
        GotServer server ->
            ( model, Cmd.map Inner (Http.get { url = server.baseUrl ++ "/anything", expect = Http.expectString (Got "ctor") }) )

        Inner (Got label r) ->
            let
                _ =
                    Debug.log
                        ("probe-"
                            ++ (case r of
                                    Ok _ ->
                                        "ok"

                                    Err _ ->
                                        "err"
                               )
                        )
                        label
            in
            ( model, Cmd.none )
```

When this is fixed, add the reproducer to the elm-http suite as a regression test.
