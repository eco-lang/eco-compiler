module CaseReturningLambdaTest exposing (main)

{-| Outer case on constructor containing nested case on String that returns lambdas.
Mimics Terminal.Main lambda captures: constructor dispatch with string sub-dispatch
producing closures.
-}

-- CHECK: r1: 6
-- CHECK: r2: 5
-- CHECK: r3: 0
-- CHECK: r4: 99

import Html exposing (text)


type Command
    = ByName String
    | Default


makeOp : Command -> (Int -> Int -> Int)
makeOp cmd =
    case cmd of
        ByName name ->
            case name of
                "add" ->
                    \a b -> a + b

                "mul" ->
                    \a b -> a * b

                "const" ->
                    \_ _ -> 0

                _ ->
                    \a _ -> a

        Default ->
            \_ _ -> 99


main =
    let
        f1 = makeOp (ByName "add")
        f2 = makeOp (ByName "mul")
        f3 = makeOp (ByName "const")
        f4 = makeOp Default
        _ = Debug.log "r1" (f1 1 5)
        _ = Debug.log "r2" (f2 1 5)
        _ = Debug.log "r3" (f3 1 5)
        _ = Debug.log "r4" (f4 1 5)
    in
    text "done"
