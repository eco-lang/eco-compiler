module AccessorFunctionFieldTailCallTest exposing (main)

{-| A record accessor of a function field, passed as a tail-call argument.

Bug (finding F8): Compiler.Monomorphize.ResolveAccessorValues rewrote
tail-call arguments with no expected type, and an accessor whose field is
itself a function is always deferred, so `.f` passed in a tail call survived
as a MonoAccessorValue and MLIR generation crashed on it. Fixed 2026-11-04:
a tail-call argument takes the type of the parameter it is passed to.

`loop` is a top-level tail-recursive function, `pick` passes the accessor in
the middle argument, and `inner` is a local tail-recursive function.

-}

-- CHECK: results: [2,11,142,42]

import Html exposing (text)


type alias Ops =
    { f : Int -> Int }


loop : (Ops -> Int -> Int) -> Int -> Int
loop g n =
    if n <= 0 then
        g { f = \x -> x + 1 } 1

    else
        loop .f (n - 1)


pick : Int -> ({ fn : Int -> Int } -> (Int -> Int)) -> { fn : Int -> Int } -> Int
pick n g r =
    if n <= 0 then
        g r 1

    else
        pick (n - 1) .fn r


wrapper : Int -> Int
wrapper n =
    let
        inner : (Ops -> Int -> Int) -> Int -> Int
        inner g k =
            if k <= 0 then
                g { f = \x -> x * 2 } 21

            else
                inner .f (k - 1)
    in
    inner (\o x -> o.f x + 100) n


main =
    let
        _ =
            Debug.log "results"
                [ loop .f 3
                , pick 3 (\r -> r.fn) { fn = \x -> x + 10 }
                , wrapper 0
                , wrapper 2
                ]
    in
    text "done"
