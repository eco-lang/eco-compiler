module CoreIssue1123NestedCmdBatchStackOverflowTest exposing (main)

{-| A deeply nested `Cmd.batch` overflows the stack in `_Platform_gatherEffects`.

<https://github.com/elm/core/issues/1123>

Elm 0.19.1 recurses once per nesting level and throws `RangeError: Maximum call stack size
exceeded`. Folding many `( model, Cmd )` updates with `Cmd.batch [ cmd, nextCmd ]` builds such a
nesting; it is a valid command and the program must run it.

-}

-- CHECK: got: 1

import Task


nested : Int -> Cmd Int
nested depth =
    List.foldl (\_ acc -> Cmd.batch [ acc, Cmd.none ]) (Task.perform identity (Task.succeed 1)) (List.range 1 depth)


main : Program () () Int
main =
    Platform.worker
        { init = \_ -> ( (), nested 100000 )
        , update = \msg model -> ( Debug.log "got" msg |> always model, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
