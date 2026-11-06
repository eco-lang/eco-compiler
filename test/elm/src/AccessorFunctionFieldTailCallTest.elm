module AccessorFunctionFieldTailCallTest exposing (main)

{-| Record accessors for function-typed fields can be passed as arguments of self-recursive tail calls.

`loop` is a top-level function that passes `.f` to itself, `pick` passes `.fn`
as the middle of its three arguments, and `inner` is a let-bound function in
`wrapper` that passes `.f` to itself. `wrapper 0` never reaches the recursive
call, so its result (142) comes from the lambda it starts with rather than from
`.f`.

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
