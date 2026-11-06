module TailRecClosureAccTest exposing (main)

{-| A tail-recursive accumulator loop defined as a local function in a `let` gives the
right result: `go` adds `m` to `acc` while counting `m` down to 0, so `recursiveLet 5` is
5 + 4 + 3 + 2 + 1 = 15.
-}

-- CHECK: result: 15

import Html exposing (text)


recursiveLet : Int -> Int
recursiveLet n =
    let
        go acc m =
            if m <= 0 then acc else go (acc + m) (m - 1)
    in
    go 0 n


main =
    let
        result = recursiveLet 5
        _ = Debug.log "result" result
    in
    text "done"
