module ConsoleReadLineNonBlockingTest exposing (main)

{-| CONSOLE-04 (plans/kernel-lib-bug-fixes.md, decision D19): `Eco.Console.readLine` blocks the
thread that runs Elm. The native kernel (`readLineBody`, eco-kernel-cpp/src/eco-kernel/Console.cpp)
calls `std::getline` on the eco thread itself, so while stdin is open and empty no timer fires
and no other message is delivered. Here stdin stays open and empty for 500 ms
(`-- STDIN-DELAY-MS:`) while a 50 ms `Process.sleep` is pending: a non-blocking readLine lets
`tick` arrive first; before the fix `line: hello` arrived first and `tick` only after it. D19
(user, 2026-11-04) made readLine/readAll asynchronous: the read now runs on the Console kernel's
stdin reader thread.
-}

-- STDIN: hello\n
-- STDIN-DELAY-MS: 500
-- EXIT: 0
-- CHECK: tick
-- CHECK-NEXT: line: hello

import Eco.Console
import Platform
import Process
import Task


type Msg
    = Tick
    | Line (Result String String)


init : () -> ( (), Cmd Msg )
init _ =
    ( ()
    , Cmd.batch
        [ Process.sleep 50 |> Task.perform (\_ -> Tick)
        , Eco.Console.readLine
            |> Task.mapError (\_ -> "readLine failed")
            |> Task.attempt Line
        ]
    )


update : Msg -> () -> ( (), Cmd Msg )
update msg _ =
    case msg of
        Tick ->
            let
                _ =
                    Debug.log "tick" ()
            in
            ( (), Cmd.none )

        Line (Ok s) ->
            let
                _ =
                    Debug.log ("line: " ++ s) ()
            in
            ( (), Cmd.none )

        Line (Err e) ->
            let
                _ =
                    Debug.log ("line error: " ++ e) ()
            in
            ( (), Cmd.none )


main : Program () () Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = \_ -> Sub.none
        }
