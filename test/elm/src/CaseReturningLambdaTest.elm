module CaseReturningLambdaTest exposing (main)

{-| Checks a `case` on a custom type whose first branch holds a nested `case` on a
`String`, where every branch of both returns a two-argument lambda.

`makeOp` returns addition for `"add"`, multiplication for `"mul"`, a constant 0
for `"const"`, and a constant 99 for `Default`. Each returned function is bound
first and applied to 1 and 5 afterwards.

Among what is not tested: the wildcard `String` branch, `\a _ -> a`.

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
